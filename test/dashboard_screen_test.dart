import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/run_pause.dart';
import 'package:sonic_shield/features/dashboard/dashboard_screen.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/run_master_service.dart';

import 'support/permission_stub.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 守护仪表盘（`DashboardScreen`）宿主测试 —— 第三十二轮新建。
///
/// ## 为什么能测（干净缝，非后门）
///
/// 仪表盘的两个数据来源：`BackgroundServiceManager.instance.last`（倒计时 /
/// 引擎开关态）与 `engineStateProvider`（待执行统计）。二者在宿主测试里原本
/// 拿不到真实状态，于是本类沿用项目既有的 `@visibleForTesting` 缝：
///
/// - `BackgroundServiceManager.lastForTest` —— 注入 `last`，驱动下一触发
///   倒计时、`_countdown` / `_fmt`、引擎开关 `value` 等分支；
/// - `BackgroundServiceManager.stateForTest` —— 注入 `state` 流，驱动
///   `engineStateProvider`（`StreamProvider`）的 `data` / `error` 分支；
/// - `BackgroundServiceManager.startHook` —— 短路 `start()`，避免 `_svc
///    .startService()` 触碰 `FlutterBackgroundService` 平台实例（非 Android
///   直接 `UnsupportedError`）。
///
/// 生产代码路径完全不变；缝只在测试中设置。权限分支用 `permission_stub`
/// （通道名/方法名照抄 `permission_handler` 真实现）真实执行，不是假用例。
///
/// ## 断言准则
///
/// 每个断言都验证"回调真的跑了 / 分支真的进了"，绝不写"图标存在"这类恒真断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 设定 SharedPreferences（合规已接受→不弹红线对话框）、注入 BSM 缝、
  /// 装权限桩，pump 出仪表盘。返回权限申请记录供断言。
  Future<List<List<Permission>>> pump(
    WidgetTester tester, {
    required EngineState? last,
    required Stream<EngineState>? stateStream,
    bool complianceAccepted = true,
    PermissionStatus notificationStatus = PermissionStatus.granted,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (complianceAccepted) 'compliance_accepted_v1': true,
    });
    await SharedPreferences.getInstance();

    BackgroundServiceManager.lastForTest = last;
    BackgroundServiceManager.stateForTest = stateStream;

    final requests = stubPermissions({
      Permission.notification: notificationStatus,
      Permission.microphone: PermissionStatus.granted,
    });
    // 原生通道另一侧：宿主无真正实现，未桩时 `invokeMethod` 在部分平台会
    // 留下永不 resolve 的 future（导致 `setServiceShouldRun` 后的 `start()`
    // 永远走不到）。桩成"原生返回 null"，与 `_invoke` 的降级契约一致。
    const nativeChannel = MethodChannel('sonic_shield/native');
    _messenger.setMockMethodCallHandler(nativeChannel, (call) async => null);
    addTearDown(() {
      BackgroundServiceManager.lastForTest = null;
      BackgroundServiceManager.stateForTest = null;
      BackgroundServiceManager.startHook = null;
      BackgroundServiceManager.invokeHook = null;
      clearPermissionStub();
      _messenger.setMockMethodCallHandler(nativeChannel, null);
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          // 非 Android 平台：让 `_detectVendor`（保活引导）同步落到 'generic'，
          // 避免宿主无 DeviceInfoPlugin 实现导致的异步竞态（line 177 测试稳定）。
          theme: ThemeData(platform: TargetPlatform.linux),
          home: const DashboardScreen(),
        ),
      ),
    );
    // 仪表盘是 ListView，默认 800x600 视口下尾部卡片在折叠区；放大视口避免
    // `tester.tap` 因"不在视口"而落空（host 无真实滚动）。
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pump();
    return requests;
  }

  testWidgets('DBS-01 引擎未启动 → 引导文案 + 引擎 data 分支', (tester) async {
    await pump(
      tester,
      last: const EngineState(running: false, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: false, pendingCount: 0)),
    );
    // line 70-71：引擎未启动引导
    expect(find.text('引擎未启动，请先开启守护'), findsOneWidget);
    // line 91-98：engine.when(data:) 分支
    expect(find.text('待执行计划：0 条'), findsOneWidget);
    expect(find.text('等待任务'), findsOneWidget);
    // 未启动时不应出现倒计时（line 75 不进）
    expect(find.text('即将执行'), findsNothing);
  });

  testWidgets('DBS-02 引擎运行且有下一触发 → 倒计时 + 最近动作', (tester) async {
    final next = DateTime.now().add(const Duration(hours: 1, minutes: 2, seconds: 3));
    final s = EngineState(
      running: true,
      pendingCount: 5,
      nextFireAt: next,
      lastAction: '测试动作',
    );
    await pump(tester, last: s, stateStream: Stream.value(s));
    // line 56-57：running=true 渲染"守护已开启"
    expect(find.text('守护已开启'), findsOneWidget);
    // line 75-80：next != null → 倒计时渲染（HH:MM:SS 格式，正则抗秒级抖动）
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && w.data != null && RegExp(r'^\d\d:\d\d:\d\d$').hasMatch(w.data!),
      ),
      findsOneWidget,
      reason: 'next!=null 必须真的渲染倒计时（line 112-117 的 _countdown）',
    );
    // line 81-83 + 119-121：_fmt 时间格式化
    expect(find.textContaining('时间：'), findsOneWidget);
    // line 91-98：data 分支 + lastAction 非空
    expect(find.text('待执行计划：5 条'), findsOneWidget);
    expect(find.text('最近动作：测试动作'), findsOneWidget);
  });

  testWidgets('DBS-03 引擎运行但无下一触发 → "暂无待执行计划"', (tester) async {
    const s = EngineState(running: true, pendingCount: 0);
    await pump(tester, last: s, stateStream: Stream.value(s));
    // line 72-74：running && next==null 分支
    expect(
      find.text('暂无待执行计划（添加任务后将自动生成）'),
      findsOneWidget,
      reason: 'running 但无 nextFireAt 必须显示该占位文案',
    );
    // 与"未启动"互斥
    expect(find.text('引擎未启动，请先开启守护'), findsNothing);
  });

  testWidgets('DBS-04 引擎状态流报错 → error 分支', (tester) async {
    await pump(
      tester,
      last: const EngineState(running: false, pendingCount: 0),
      stateStream: Stream.error(Exception('boom')),
    );
    // line 100-102：engine.when(error:)
    expect(find.textContaining('引擎状态获取失败'), findsOneWidget);
  });

  testWidgets('DBS-05 下一触发在过去 → 倒计时显示"即将执行"', (tester) async {
    final past = DateTime.now().subtract(const Duration(minutes: 1));
    final s = EngineState(running: true, pendingCount: 0, nextFireAt: past);
    await pump(tester, last: s, stateStream: Stream.value(s));
    // line 114：_countdown 负差分支
    expect(find.text('即将执行'), findsOneWidget,
        reason: 'target 在过去必须显示"即将执行"（line 114）');
  });

  testWidgets('DBS-06 开启守护开关 → 申请权限 + 置位 shouldRun + 启动', (tester) async {
    var started = false;
    BackgroundServiceManager.startHook = () async {
      started = true;
      return true;
    };
    // stop 不在 true 分支，但同页其它开关可能走 stop；统一短路 FBS.invoke 的
    // 平台异常（非 Android/iOS 直接抛 UnsupportedError）。
    BackgroundServiceManager.invokeHook = (_, __) async {};
    final requests = await pump(
      tester,
      last: const EngineState(running: false, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: false, pendingCount: 0)),
    );
    // 开关当前为关（running=false）→ 点击切到开
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    // 诊断：确认手势真的触发了回调
    expect(requests.isNotEmpty, isTrue,
        reason: '开启开关必须触发 requestAllPermissions（line 144），否则 tap 未命中');
    // line 143-146：onChanged(true) 必须真的执行
    expect(started, isTrue,
        reason: 'onChanged(true) 必须真的调用 mgr.start()（line 146），开关不能空转');
  });

  testWidgets('DBS-07 关闭守护开关 → 不申请权限 + 走停止路径', (tester) async {
    var started = false;
    BackgroundServiceManager.startHook = () async {
      started = true;
      return true;
    };
    // off 分支走 stop() → _invoke('stop') → FBS.invoke 在宿主抛平台异常，需短路。
    BackgroundServiceManager.invokeHook = (_, __) async {};
    final requests = await pump(
      tester,
      last: const EngineState(running: true, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: true, pendingCount: 0)),
    );
    // 开关当前为开（running=true）→ 点击切到关
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    // line 147-149：off 分支不应再 start
    expect(started, isFalse,
        reason: 'onChanged(false) 不应调用 start()（line 146 只在 true 分支）');
    expect(requests.isEmpty, isTrue,
        reason: '关闭路径不申请权限（line 144 只在 true 分支），证明分支正确性');
  });

  testWidgets('DBS-08 点"电源白名单" → 弹出厂商保活引导', (tester) async {
    await pump(
      tester,
      last: const EngineState(running: false, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: false, pendingCount: 0)),
    );
    // line 177：_PermissionChecklist onTap
    await tester.ensureVisible(find.text('电源白名单与厂商保活引导'));
    await tester.tap(find.text('电源白名单与厂商保活引导'));
    await tester.pumpAndSettle();
    // generic 厂商的保活引导 BottomSheet 必然渲染标题与"通用步骤"文案
    // （line 177 真的执行，且 sheet 真的 build 出来）。
    expect(find.textContaining('后台保活设置'), findsOneWidget,
        reason: '点击必须真的打开保活引导 BottomSheet（line 177）');
    expect(find.textContaining('通用步骤'), findsOneWidget,
        reason: 'generic 厂商保活引导内容必须渲染（证明 sheet 真的 build）');
  });

  testWidgets('DBS-09 未同意合规 → 开启开关不启动引擎且提示（P1-02）',
      (tester) async {
    var started = false;
    BackgroundServiceManager.startHook = () async {
      started = true;
      return true;
    };
    BackgroundServiceManager.invokeHook = (_, __) async {};
    await pump(
      tester,
      last: const EngineState(running: false, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: false, pendingCount: 0)),
      complianceAccepted: false,
    );
    // 首启引导：未同意必然弹出须知对话框，先明确拒签，使准入闸保持关闭。
    await tester.pumpAndSettle();
    expect(find.text('使用前必读 · 合规红线'), findsOneWidget,
        reason: '未同意时首启必须弹出须知（else 准入闸无从生效）');
    await tester.tap(find.text('不同意'));
    await tester.pumpAndSettle();

    // 现在从"关闭"切到"开"——应被合规闸拦下，不得启动。
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    // 开关的 true 分支再次弹须知（合规是唯一准入层）；再次拒签。
    expect(find.text('使用前必读 · 合规红线'), findsOneWidget,
        reason: 'onChanged(true) 必须先过 ensureComplianceAccepted（未同意必弹）');
    await tester.tap(find.text('不同意'));
    await tester.pumpAndSettle();

    expect(started, isFalse,
        reason: '未同意《合规使用须知》绝不能启动引擎（P1-02 核心：合规门必须是准入闸）');
    expect(find.text('需先阅读并同意《合规使用须知》才能开启守护'), findsOneWidget,
        reason: '拒签后必须给出明确提示，而非静默弹回开关');
  });

  testWidgets('DBS-10 已同意合规 → 开启开关真的启动引擎（对照，证明 DBS-09 非恒真）',
      (tester) async {
    var started = false;
    BackgroundServiceManager.startHook = () async {
      started = true;
      return true;
    };
    BackgroundServiceManager.invokeHook = (_, __) async {};
    await pump(
      tester,
      last: const EngineState(running: false, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: false, pendingCount: 0)),
      complianceAccepted: true,
    );
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(started, isTrue,
        reason: '已同意合规时开关必须真的启动引擎 —— 与 DBS-09 形成区分度，'
            '证明测试不是"永远不启动"的恒真断言');
    expect(find.text('需先阅读并同意《合规使用须知》才能开启守护'), findsNothing);
  });

  testWidgets('DBS-11 精确闹钟降级 → 渲染降级卡片与恢复入口（P1-04）',
      (tester) async {
    const s = EngineState(
      running: true,
      pendingCount: 2,
      alarmDiag: '精确闹钟降级：预期 3，实排 1（未授权或系统限制）',
    );
    await pump(tester, last: s, stateStream: Stream.value(s));
    expect(find.text('精确闹钟未完全生效（降级运行）'), findsOneWidget,
        reason: 'alarmDiag!=null 必须在用户可操作位置解释降级（否则用户以为准点）');
    expect(find.textContaining('精确闹钟降级：预期 3，实排 1'), findsOneWidget,
        reason: '降级原因必须原样透出，用户才能判断该去授权');
    expect(find.text('去授权'), findsOneWidget,
        reason: '降级必须给恢复入口（跳转精确闹钟系统设置）');
  });

  testWidgets('DBS-12 无降级 → 不渲染降级卡片（对照，证明 DBS-11 非恒真）',
      (tester) async {
    const s = EngineState(running: true, pendingCount: 2);
    await pump(tester, last: s, stateStream: Stream.value(s));
    expect(find.text('精确闹钟未完全生效（降级运行）'), findsNothing,
        reason: 'alarmDiag==null（精确闹钟正常）时不得渲染降级卡片，'
            '否则降级告警会常驻而失去意义');
  });

  testWidgets('DBS-13 通知权限被拒 → 开启时给出降级提示（P2-16，不再静默）',
      (tester) async {
    var started = false;
    BackgroundServiceManager.startHook = () async {
      started = true;
      return true;
    };
    BackgroundServiceManager.invokeHook = (_, __) async {};
    await pump(
      tester,
      last: const EngineState(running: false, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: false, pendingCount: 0)),
      notificationStatus: PermissionStatus.denied,
    );
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(started, isTrue,
        reason: '通知被拒不阻断引擎启动（它只影响提醒可见性）—— 启动归启动');
    expect(find.textContaining('通知权限未授予'), findsOneWidget,
        reason: '★ 通知被拒必须显式告知后果与恢复路径，'
            '否则后台提醒全消失而用户只当功能坏了（P2-16）');
  });

  testWidgets('DBS-14 通知权限已授予 → 不弹降级提示（对照，证明 DBS-13 非恒真）',
      (tester) async {
    var started = false;
    BackgroundServiceManager.startHook = () async {
      started = true;
      return true;
    };
    BackgroundServiceManager.invokeHook = (_, __) async {};
    await pump(
      tester,
      last: const EngineState(running: false, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: false, pendingCount: 0)),
      notificationStatus: PermissionStatus.granted,
    );
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(started, isTrue);
    expect(find.textContaining('通知权限未授予'), findsNothing,
        reason: '通知已授予时不得弹出降级提示 —— 否则该提示会常驻，'
            '与 DBS-13 形成区分度，证明判据非恒真');
  });

  testWidgets('DBS-15 首页常驻「全局执行总开关」（FR-71）渲染', (tester) async {
    await pump(
      tester,
      last: const EngineState(running: true, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: true, pendingCount: 0)),
    );
    await tester.pump(); // 等 _RunMasterCard.initState 的 SharedPreferences.then
    // 标题（与设置页同源，docs/20 §9）
    expect(find.text('全局执行总开关'), findsOneWidget,
        reason: '首页必须常驻总开关标题（line 约 919，FR-71）');
    // 三态分段控件标签
    expect(find.text('自动'), findsWidgets);
    expect(find.text('强制开启'), findsWidgets);
    expect(find.text('强制关闭'), findsWidgets);
    // 自动模式说明文案（唯一、与设置页一致）
    expect(find.textContaining('自动模式：法定休息日前一天 20:00'), findsOneWidget);
    // 当前状态行前缀
    expect(find.textContaining('当前状态：'), findsOneWidget);
  });

  testWidgets('DBS-16 切到「强制关闭」→ 写回 run_master_mode=off（FR-71）',
      (tester) async {
    await pump(
      tester,
      last: const EngineState(running: true, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: true, pendingCount: 0)),
    );
    await tester.pump();
    // 出厂默认（mock 未设键）→ auto
    expect((await SharedPreferences.getInstance()).getString('run_master_mode'),
        isNull);
    // 点击「强制关闭」分段
    await tester.tap(find.text('强制关闭'));
    await tester.pump();
    // 写回同一存储（与设置页同源）
    expect((await SharedPreferences.getInstance()).getString('run_master_mode'),
        'off',
        reason: '首页切换总开关必须即时写回 PrefsKeys.runMasterMode');
    // 状态行随 mode 更新
    expect(find.textContaining('强制关闭：始终暂停'), findsOneWidget);
  });

  testWidgets('DBS-17 远程改动即时刷新首页总开关卡片（第八十二轮：补实时同步）',
      (tester) async {
    await pump(
      tester,
      last: const EngineState(running: true, pendingCount: 0),
      stateStream: Stream.value(const EngineState(running: true, pendingCount: 0)),
    );
    await tester.pump();
    // 初始 auto（出厂默认）⇒ 不显示"强制关闭"状态行。
    expect(find.textContaining('强制关闭：始终暂停'), findsNothing);

    // 模拟**远程** `run.master.set`：外部（端点处理器）经服务写 prefs 并广播。
    // 首页此前只在 initState 读一次 ⇒ 不会刷新；本轮改为监听服务 ⇒ 必须刷新。
    await RunMasterService.instance.set(RunMasterMode.off);
    await tester.pump();

    expect(find.textContaining('强制关闭：始终暂停'), findsOneWidget,
        reason: '远程改了总开关，首页卡片必须即时反映（本轮的"最后一公里"）');
  });

  // ─────────── DBS-RM 总开关例外清单（第八十四轮 FR-78：从守卫页迁入） ───────────
  //
  // 第八十四轮用户明文：总开关**从守卫页移至守护页**并美化。原守卫页的
  // 「例外清单默认折叠 5 条 + 展开/收起」能力**一并迁入首页**（重构入口，
  // 不丢功能）—— 用例随之从 `guard_screen_test.dart` 的 GRM-01/02 迁到这里。

  group('DBS-RM 总开关例外清单（第八十四轮从守卫页迁入）', () {
    Task mkForced(String id) {
      final base = DateTime(2024, 1, 1);
      return Task(
        id: id,
        name: '任务$id',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)),
        actionType: ActionType.notify,
        action: const NotifyAction(title: 'T', body: 'B'),
        assetIds: const [],
        cooldownSec: 60,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: base,
        updatedAt: base,
        forceRun: true,
      );
    }

    Future<void> pumpWithForced(
      WidgetTester tester, {
      required List<Task> forced,
      String? mode,
    }) async {
      SharedPreferences.setMockInitialValues({
        'compliance_accepted_v1': true,
        if (mode != null) PrefsKeys.runMasterMode: mode,
      });
      await SharedPreferences.getInstance();
      // 对齐 `pump`：桩权限 + 原生通道，避免权限未授予时仪表盘弹出覆盖层
      // 拦截命中测试（find 能找到底层 widget 但 tap 打空 → 段/按钮点击不生效）。
      stubPermissions({
        Permission.notification: PermissionStatus.granted,
        Permission.microphone: PermissionStatus.granted,
      });
      const nativeChannel = MethodChannel('sonic_shield/native');
      _messenger.setMockMethodCallHandler(nativeChannel, (call) async => null);
      addTearDown(() {
        clearPermissionStub();
        _messenger.setMockMethodCallHandler(nativeChannel, null);
      });
      final ctrl = StreamController<EngineState>.broadcast();
      addTearDown(() async => ctrl.close());
      BackgroundServiceManager.lastForTest =
          const EngineState(running: true, pendingCount: 0);
      BackgroundServiceManager.stateForTest = ctrl.stream;

      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          forceRunTasksProvider.overrideWith((ref) async => forced),
        ],
        // 对齐 DBS-16 等稳定用例：显式 platform=linux，避免默认平台下
        // SegmentedButton / TextButton 的命中行为差异导致 `tap` 静默不生效。
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: const DashboardScreen(),
        ),
      ));
      ctrl.add(const EngineState(running: true, pendingCount: 0));
      await tester.pump();
    }

    testWidgets('DBS-RM-01 例外清单默认最多 5 条 + 可展开/收起（迁自 GRM-01）',
        (tester) async {
      final forced = [for (var i = 0; i < 8; i++) mkForced('t$i')];
      await pumpWithForced(tester, forced: forced, mode: 'off');

      expect(find.text('全局执行总开关'), findsOneWidget);
      expect(find.textContaining('8 条暂停期间仍执行'), findsOneWidget);
      expect(find.textContaining('强制关闭：始终暂停'), findsOneWidget);

      expect(find.textContaining('· 任务t0（强制执行）'), findsOneWidget);
      expect(find.textContaining('· 任务t4（强制执行）'), findsOneWidget,
          reason: '折叠态必须展示前 5 条');
      // 折叠态不该展示第 6 条（用户要求默认 5 条）。注意：展开态把 8 条**全部**
      // 渲染进同一个 Column，折叠时第 6..8 条**根本不存在于 widget 树**，
      // 因此这里必须断言 `findsNothing`（而不是"滚出可视区"）。
      expect(find.textContaining('· 任务t5（强制执行）'), findsNothing,
          reason: '折叠态不该展示第 6 条（用户要求默认 5 条）');

      // ⚠️ 首页 ListView + 卡片高：展开/收起按钮可能落在视口外，先 `ensureVisible`
      // 滚入再点。真实根因（本轮实跑暴露）：`pumpWithForced` 未设
      // `compliance_accepted_v1: true` 时，仪表盘会弹合规模态层拦截命中测试，
      // 导致 `tap` 静默打空（find 仍能定位底层 widget，故初始断言全过）。已修。
      // 展开是同步 setState，`pumpAndSettle` 落定后第 6..8 条必入树。
      await tester.ensureVisible(find.text('展开全部（8）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('展开全部（8）'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.textContaining('· 任务t7（强制执行）'), findsExactly(1),
          reason: '点「展开全部」后必须能看到第 6..8 条');

      await tester.ensureVisible(find.text('收起'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收起'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.textContaining('· 任务t5（强制执行）'), findsNothing,
          reason: '点「收起」后回到只展示前 5 条');
    });

    testWidgets('DBS-RM-02 切「强制开启」→ 状态行改写 + 落库（迁自 GRM-02）',
        (tester) async {
      await pumpWithForced(tester, forced: const [], mode: 'off');
      expect(find.textContaining('强制关闭：始终暂停'), findsOneWidget);
      expect(find.textContaining('无：暂停期间不执行任何任务'), findsOneWidget);

      // ⚠️ `SegmentedButton` 的段是叶子 Text，`tap` 打在它身上即可触发段选择。
      // `RunMasterService.set` 是 async（`await SharedPreferences` 之后才
      // `mode.value = m`），需 `pumpAndSettle` 等异步落定再断言状态行与 prefs。
      // 真实根因（本轮实跑暴露）：`pumpWithForced` 未设 `compliance_accepted_v1`
      // 时仪表盘弹合规模态层拦截命中，`tap` 静默打空——已在 harness 修。
      final onSeg = find.text('强制开启');
      await tester.tap(onSeg, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.textContaining('强制开启：忽略自动窗口'), findsOneWidget);
      expect(
          (await SharedPreferences.getInstance())
              .getString(PrefsKeys.runMasterMode),
          'on',
          reason: '远程/本机都用同一个 prefs 键，点选必须真的落库');
    });
  });

  // ─────────────── 远程投屏可见性红线（docs/61 §1）───────────────

  /// 端点侧「不可隐蔽」红线的落地：**任何像素出屏 / 任何注入生效之前，
  /// 端点必须已有可见指示**，且端点用户**任何时刻都能一键停**。
  /// `RcEndpointService.castActive` 由端点 handler 在会话开始/停止时置位，
  /// 本横幅是它在守护首页上的消费端 —— 此前 0% 覆盖。
  group('DBS-CAST 远程投屏可见性横幅', () {
    testWidgets('DBS-CAST-01 会话进行中 → 横幅出现；点「停止」→ 会话停止且横幅消失',
        (tester) async {
      final svc = RcEndpointService.instance;
      svc.castActive.value = false;
      addTearDown(() => svc.castActive.value = false);

      await pump(
        tester,
        last: const EngineState(running: true, pendingCount: 0),
        stateStream:
            Stream.value(const EngineState(running: true, pendingCount: 0)),
      );
      expect(find.text('正在接受远程操作'), findsNothing,
          reason: '没有会话时不得显示横幅（否则是恒真的假指示）');

      svc.castActive.value = true;
      await tester.pump();

      expect(find.text('正在接受远程操作'), findsOneWidget,
          reason: '会话进行中端点必须醒目可见');
      expect(find.text('屏幕可能正被已配对设备查看；你可随时停止'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '停止'));
      await tester.pumpAndSettle();

      expect(svc.castActive.value, isFalse, reason: '端点一键停止必须真的停掉会话');
      expect(find.text('正在接受远程操作'), findsNothing);
    });
  });
  // ══════════════════════════════════════════════════════════════════════
  // DBS-10 · 一键停止当前动作（R101 用户需求）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('DBS-10 一键停止：AppBar 常驻按钮 → 停播放 + 停振动 + 如实提示',
      (tester) async {
    await pump(
      tester,
      last: const EngineState(running: true, pendingCount: 0),
      stateStream:
          Stream.value(const EngineState(running: true, pendingCount: 0)),
    );

    // 应急入口必须常驻 AppBar（列表滚到哪都能一次点到）。
    final btn = find.byKey(const ValueKey<String>('stop_current_action'));
    expect(btn, findsOneWidget);
    expect(find.byTooltip('停止当前动作（声音 + 振动）'), findsOneWidget);

    // 桩住原生通道，记录振动停止是否真的下发。
    var vibrateCalls = 0;
    _messenger.setMockMethodCallHandler(
      const MethodChannel('sonic_shield/native'),
      (call) async {
        if (call.method == 'vibrateStop') vibrateCalls++;
        return null;
      },
    );
    addTearDown(() => _messenger.setMockMethodCallHandler(
        const MethodChannel('sonic_shield/native'), null));

    await tester.tap(btn);
    await tester.pump();

    expect(vibrateCalls, 1,
        reason: '必须真的向原生下发 vibrateStop —— 只停声音会让手机还在兜里震');
    // 空操作也必须如实回一句（不许静默什么都不发生）。
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('停止'), findsWidgets);
  });
}
