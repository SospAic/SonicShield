import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/features/dashboard/dashboard_screen.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

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
  }) async {
    SharedPreferences.setMockInitialValues({
      if (complianceAccepted) 'compliance_accepted_v1': true,
    });
    await SharedPreferences.getInstance();

    BackgroundServiceManager.lastForTest = last;
    BackgroundServiceManager.stateForTest = stateStream;

    final requests = stubPermissions({
      Permission.notification: PermissionStatus.granted,
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
}
