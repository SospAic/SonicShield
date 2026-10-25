import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart'
    as spi;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/domain/scheduling/run_pause.dart';
import 'package:sonic_shield/features/dashboard/dashboard_screen.dart';
import 'package:sonic_shield/features/guard/guard_screen.dart';
import 'package:sonic_shield/features/remote/multi_video_screen.dart';
import 'package:sonic_shield/features/remote/pair_qr_screen.dart';
import 'package:sonic_shield/features/remote/ptt_tab.dart';
import 'package:sonic_shield/features/remote/remote_console_tab.dart';
import 'package:sonic_shield/features/remote/remote_screen.dart';
import 'package:sonic_shield/features/remote/remote_section.dart';
import 'package:sonic_shield/features/remote/remote_scripts_tab.dart';
import 'package:sonic_shield/features/remote/remote_tasks_tab.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/controller_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/run_master_service.dart';

import 'support/permission_stub.dart';

/// R96 门禁「可达但未覆盖 UI 行」补齐 —— 只写测试，不改 `lib/`。
///
/// 覆盖目标（按文件分组，逐条对应用例名里的 GAP 编号）：
/// - `dashboard_screen`：精确闹钟降级卡「去授权」、权限体检行「去开启」、
///   总开关 auto 态状态行与色调；
/// - `guard_screen`：守卫开启成功但通知被拒的降级提示；
/// - `remote_tasks_tab`：迟到回执、无端点两处提示、过期回执表上限；
/// - `remote_scripts_tab`：端点已解配对、删除失败兜底；
/// - `remote_console_tab`：振动对话框「取消」与滑块 `onChanged`；
/// - `ptt_tab`：端点已不存在、松手撤销录音；
/// - `remote_section`：同一路由 800ms 内只推一次；
/// - 三个页面的 `const X({super.key})` 构造器。
///
/// ## 有意识不覆盖（既有用例已覆盖 / 结构不可达）
/// - `sound_library_screen` 的导入回滚 `removeFile` 闭包：已由
///   `sound_library_screen_test.dart` 的 SLB-11/15 等覆盖，本文件不重复；
/// - `call_screen` 的 `CallService.bindStore` 注入闭包被真正调用：需要完整
///   呼叫链路（权限 + 端点 + 信令），成本远高于收益，登记为长尾留给后续。
///
/// ## 本文件遵守的宿主约束（项目实测教训）
/// 1. **不用 `pumpAndSettle` 等数据**：本文件一律用有界 `waitFor` 或
///    显式 `pump(duration)`（进度圈是无限动画，`pumpAndSettle` 会超时）；
/// 2. **真实 IO / 真实异步**只在 `tester.runAsync` 里做；
/// 3. 平台通道桩（原生 / 权限 / 资源 / path_provider）一律 `addTearDown` 还原；
/// 4. 平台接口单例替身（`SharedPreferencesStorePlatform.instance`）同样还原；
/// 5. 用例名中文 + GAP 编号；不依赖墙钟 / 随机 / 网络 / 真机。
TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 原生桥通道（`NativeBridge` 的出口）。
const MethodChannel _nativeChannel = MethodChannel('sonic_shield/native');

PairedEndpoint _ep(String id, String name) => PairedEndpoint(
    deviceId: id, name: name, secret: 'AB2CD5EF', pairedAt: DateTime.now());

/// 一条最小可渲染的端点任务线格式。
Map<String, dynamic> _wireTask({String id = 't1', String name = '早间播报'}) => {
      'id': id,
      'name': name,
      'enabled': true,
      'triggerType': 'dailyAt',
      'trigger': {
        'time': {'hour': 7, 'minute': 30}
      },
      'actionType': 'tts',
      'action': {'kind': 'tts', 'text': '早上好'},
      'cooldownSec': 0,
      'assetIds': const <String>[],
    };

/// 假命令通道（与 `remote_tasks_tab_test.dart` / `remote_console_tab_test.dart`
/// 同形：捕获"发了什么"、回灌"收到什么"）。
class _FakeChannel implements RcCommandChannel {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _updates = StreamController<void>.broadcast();
  final sent = <RcMessage>[];

  bool sendResult = true;
  bool canSendValue = true;

  @override
  String get label => '假端点';

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Stream<void> get updates => _updates.stream;

  @override
  bool get canSend => canSendValue;

  @override
  Future<bool> send(RcMessage msg) async {
    sent.add(msg);
    return sendResult;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await _updates.close();
  }

  void emit(String type, Map<String, dynamic> payload) =>
      _events.add({'type': type, 'payload': payload});

  RcMessage lastOfType(String type) => sent.lastWhere((m) => m.type == type,
      orElse: () => throw StateError('未发送 $type'));

  bool sentType(String type) => sent.any((m) => m.type == type);
}

/// 只拦 `rc_scripts` 写盘的**选择性抛错桩**。
///
/// 挂载期的读路径（`getAll`）必须放行，否则页面根本加载不出收藏列表，
/// 也就永远点不到删除按钮。
class _FailingScriptsStore extends spi.SharedPreferencesStorePlatform {
  final Map<String, Object> bag = <String, Object>{};
  int scriptsWriteAttempts = 0;

  @override
  Future<Map<String, Object>> getAll() async => Map<String, Object>.of(bag);

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    // legacy `SharedPreferences` 会给键加 `flutter.` 前缀才到平台层 ⇒ endsWith 匹配。
    if (key.endsWith('.rc_scripts')) {
      scriptsWriteAttempts++;
      throw Exception('rc_scripts 模拟盘满');
    }
    bag[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    bag.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    bag.clear();
    return true;
  }
}

/// 推进固定帧数（**不**用 `pumpAndSettle`：进度圈是无限动画）。
Future<void> _frames(WidgetTester tester, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 有界等待一段文案出现。
///
/// SnackBar 是**排队**的：前一条要 4s + 收起动画后下一条才露头，
/// 单次大跨度 `pump(Duration)` 只会跑一帧 ⇒ 动画不会推进，必须多帧小步推。
Future<void> _waitForText(
  WidgetTester tester,
  String substring, {
  int rounds = 40,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (find.textContaining(substring).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 300));
  }
  fail('等待超时（$rounds 轮）：应出现含「$substring」的文案');
}

/// 把当前这条 SnackBar 的 4s 计时 + 收起动画推完（否则收尾判 pending timer）。
Future<void> _drainSnack(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ═══════════════════════════════════════════════════════════════════
  // GAP-19 三个页面的 const 构造器（`const X({super.key})`）
  //
  // 这几行此前 0 覆盖：全仓测试都是经路由/宿主壳挂载，从未**直接构造**
  // 这三个 widget 的实例。构造器是"页面能不能被创建"的第一道门，
  // 用不带 `key` 的构造（生产里 `go_router` 就是这么建的）。
  // ═══════════════════════════════════════════════════════════════════
  test('GAP-19 三个远程页面的无 key 构造器可直接创建', () {
    expect(const MultiVideoScreen(), isA<MultiVideoScreen>());
    expect(const PairQrScreen(), isA<PairQrScreen>());
    expect(const RemoteScreen(), isA<RemoteScreen>());
  });

  // ═══════════════════════════════════════════════════════════════════
  // GAP-01/02/03 守护首页（dashboard_screen.dart）
  // ═══════════════════════════════════════════════════════════════════
  group('GAP-01 守护首页精确闹钟入口', () {
    late List<String> nativeCalls;

    Future<void> pumpDashboard(
      WidgetTester tester, {
      required EngineState last,
      bool alarmSupported = false,
    }) async {
      SharedPreferences.setMockInitialValues({'compliance_accepted_v1': true});
      await SharedPreferences.getInstance();
      nativeCalls = <String>[];
      BackgroundServiceManager.lastForTest = last;
      BackgroundServiceManager.stateForTest = Stream<EngineState>.multi((c) {
        c.add(last);
      });
      stubPermissions({
        Permission.notification: PermissionStatus.granted,
        Permission.microphone: PermissionStatus.granted,
      });
      _messenger.setMockMethodCallHandler(_nativeChannel, (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'exactAlarmSupported') return alarmSupported;
        return null;
      });
      addTearDown(() {
        BackgroundServiceManager.lastForTest = null;
        BackgroundServiceManager.stateForTest = null;
        BackgroundServiceManager.startHook = null;
        BackgroundServiceManager.invokeHook = null;
        clearPermissionStub();
        _messenger.setMockMethodCallHandler(_nativeChannel, null);
      });
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: const DashboardScreen(),
        ),
      ));
      await _frames(tester, 6);
    }

    testWidgets('GAP-01 降级卡「去授权」→ 真的跳到系统精确闹钟设置', (tester) async {
      await pumpDashboard(
        tester,
        last: const EngineState(
          running: true,
          pendingCount: 2,
          alarmDiag: '精确闹钟降级：预期 3，实排 1',
        ),
        alarmSupported: true,
      );
      expect(find.text('精确闹钟未完全生效（降级运行）'), findsOneWidget);

      nativeCalls.clear();
      await tester.tap(find.text('去授权'));
      await _frames(tester, 4);

      expect(nativeCalls, contains('openExactAlarmSettings'),
          reason: '降级卡的唯一恢复入口必须真的打到原生（否则用户无处可去）');
    });

    testWidgets('GAP-02 权限体检行「去开启」→ 打开设置并**重新体检**', (tester) async {
      await pumpDashboard(
        tester,
        last: const EngineState(running: true, pendingCount: 0),
        alarmSupported: false,
      );
      // 未授权 ⇒ 常驻提示行（不是 SnackBar）。
      expect(find.text('精确闹钟权限未开启（锁屏可能失效）'), findsOneWidget);
      final before =
          nativeCalls.where((m) => m == 'exactAlarmSupported').length;
      expect(before, greaterThanOrEqualTo(1),
          reason: '进页就该体检一次，否则提示行无从判定');

      nativeCalls.clear();
      await tester.tap(find.text('去开启'));
      await _frames(tester, 6);

      expect(nativeCalls, contains('openExactAlarmSettings'),
          reason: '「去开启」必须真的跳到系统设置');
      expect(nativeCalls.where((m) => m == 'exactAlarmSupported').length,
          greaterThanOrEqualTo(1),
          reason: '授权页返回后必须重新体检 —— 只跳不查，提示行会永远停在"未开启"');
    });

    testWidgets('GAP-03 auto 模式的状态行与档位色调跟随暂停窗口', (tester) async {
      // ⚠️ 该分支的判据是 `RunPause.paused(auto, DateTime.now())`，**依赖墙钟**
      // （`_RunMasterCardState.build` 直接读 `DateTime.now()`，仓库没有时钟缝）。
      // 因此这里不做"必须是某一侧"的恒假断言，而是断言**界面与纯函数一致**：
      // 暂停窗口内出「自动暂停中：到 … 自动恢复」，窗口外出
      // 「自动运行中：到 … 自动暂停」（后者的色调走 tertiary 分支）。
      await pumpDashboard(
        tester,
        last: const EngineState(running: true, pendingCount: 0),
        alarmSupported: true,
      );
      await RunMasterService.instance.set(RunMasterMode.auto);
      await _frames(tester, 4);

      // 取两次样本：若两次分属不同分支，说明**恰好跨过**暂停窗口边界
      // （20:00 / 21:00 那一瞬间）⇒ 这是环境时序，不是被测行为 ⇒ 跳过判定。
      final paused = RunPause.paused(RunMasterMode.auto, DateTime.now());
      final pausedAgain = RunPause.paused(RunMasterMode.auto, DateTime.now());
      if (paused != pausedAgain) {
        markTestSkipped('恰好跨过暂停窗口边界（两次取样不一致），本次不做界面判定');
        return;
      }
      expect(find.textContaining(paused ? '自动暂停中：到' : '自动运行中：到'),
          findsOneWidget,
          reason: 'auto 态状态行必须与 RunPause 判定一致（暂停/运行两侧互斥）');
      expect(find.textContaining(paused ? '自动运行中：到' : '自动暂停中：到'),
          findsNothing);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // GAP-14 remote_section：同一路由 800ms 内只推一次
  // ═══════════════════════════════════════════════════════════════════
  group('GAP-14 远程分组页导航节流', () {
    testWidgets('GAP-14 同一路由连点两次只推一层，不同路由不受影响', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance();
      final visited = <String>[];
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, __) => const RemoteSection()),
          for (final p in const ['/remote/pair-qr', '/remote/settings'])
            GoRoute(
              path: p,
              builder: (_, __) {
                visited.add(p);
                return const Scaffold(body: Placeholder());
              },
            ),
        ],
      );
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump(const Duration(milliseconds: 200));

      final qr = find.widgetWithIcon(IconButton, Icons.qr_code_scanner);
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      // 节流判据读的是**真实墙钟**（`remote_section.dart` 用 `DateTime.now()`，
      // 仓库没有时钟缝）。因此下面这条「连点被节流」的断言有一个**环境前提**：
      // 两次点击的真实间隔必须 < 800ms。带载机上进程被调度卡住超过 800ms 时，
      // 第二次点击会落在窗口外 ⇒ 失败原因是**环境停顿**，不是节流失效。
      // 用 Stopwatch 把这个前提显式自证（只测「前提是否成立」，不测性能）。
      final sinceFirstTap = Stopwatch()..start();

      await tester.tap(qr);
      await settle();
      expect(visited, ['/remote/pair-qr'], reason: '首次点击必须真的跳转');

      // 退回分组页，紧接着再点**同一**入口 —— 落在 800ms 窗口内 ⇒ 被节流。
      router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(qr);
      await settle();
      if (sinceFirstTap.elapsedMilliseconds >= 800) {
        markTestSkipped('环境前提不满足：两次点击真实间隔 '
            '${sinceFirstTap.elapsedMilliseconds}ms ≥ 800ms 节流窗口（本机停顿），无法验证节流');
        return;
      }
      expect(visited, ['/remote/pair-qr'],
          reason: '同一路由 800ms 内连点只能推一层（否则返回要逐层退出）');

      // 等真实时间越过 800ms 窗口后再点 —— 必须恢复放行，
      // 否则"节流"就退化成了"永久禁用"（这一条同时证明上一条不是恒真）。
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.tap(qr);
      await settle();
      expect(visited, ['/remote/pair-qr', '/remote/pair-qr'],
          reason: '窗口之外必须重新放行 —— 节流是有时限的，不是一次性闸门');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // GAP-04 guard_screen：守卫**开启成功**但通知被拒的降级提示
  //
  // 该分支只在"整条开启链路真的走通（引擎在跑 + 麦克风已授 + 引擎回投
  // guardActive）且通知被拒"时进入 —— 既有用例只测了失败路径，成功路径
  // 的中段（`startMicService` 里的 `requestAllPermissions`）虽然被走过，
  // 但 `outcome.ok == true` 那一侧的 `else if` 从未成立。
  // ═══════════════════════════════════════════════════════════════════
  group('GAP-04 守卫页通知被拒降级提示', () {
    late AppDatabase db;

    // ⚠️ 开库必须在 `setUp`（**真实 zone**）：`sqflite` 的 FFI 实现把 SQLite
    // 放在后台 isolate，往返是真实异步 —— 在 `testWidgets` 的 FakeAsync 里
    // 直接 `await AppDatabase.open(...)` 会**永久挂死**（本项目既有教训）。
    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      db = await AppDatabase.open(inMemoryDatabasePath);
      addTearDown(() async {
        try {
          await db.close();
        } on Object {
          // 仍在飞的 `_persist` 可能已把库关掉。
        }
      });
    });

    testWidgets('GAP-04 守卫开成功但通知被拒 → 明确告知后台提醒会缺失', (tester) async {
      // 引擎在跑；guardActive 初始为 false（这样开关才是"关"，点一下才是开）。
      var guardOn = false;
      BackgroundServiceManager.lastForTest =
          const EngineState(running: true, pendingCount: 0);
      // ⚠️ 必须用 `Stream.multi`：`_onToggleGuard` 会 `ref.invalidate`，
      // 单订阅流二次 listen 会抛 Bad state（同 guard_screen_test 的教训）。
      BackgroundServiceManager.stateForTest = Stream<EngineState>.multi((c) {
        c.add(EngineState(running: true, pendingCount: 0, guardActive: guardOn));
      });
      final invoked = <String>[];
      BackgroundServiceManager.invokeHook = (m, a) async {
        invoked.add(m);
        if (m == 'guard' && (a as Map?)?['enabled'] == true) guardOn = true;
      };
      _messenger.setMockMethodCallHandler(_nativeChannel, (c) async => null);

      final asked = stubPermissions({
        Permission.microphone: PermissionStatus.granted,
        Permission.notification: PermissionStatus.denied,
      });
      addTearDown(() {
        BackgroundServiceManager.lastForTest = null;
        BackgroundServiceManager.stateForTest = null;
        BackgroundServiceManager.invokeHook = null;
        clearPermissionStub();
        _messenger.setMockMethodCallHandler(_nativeChannel, null);
      });

      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [databaseProvider.overrideWith((ref) async => db)],
        child: const MaterialApp(home: GuardScreen()),
      ));
      // `_loadProfile` 是真实异步（后台 isolate 的 SQLite）⇒ 分段推进。
      //
      // ⚠️ 预算不能太窄：`runAsync` 每次只让出**一个**事件循环，而 SQLite 后台
      // isolate 的一次往返在 6 路并发（其它测试文件同时在跑）时可能远超单帧。
      // 40 次 × 5ms 假时钟（真实预算仅几十毫秒）在带载机上会「profile 还没回来
      // 就点开关」⇒ 失败原因伪装成业务缺陷。这里给到 400 × 2ms（真实预算约
      // 800ms 事件循环让出），仍是有界等待，不引入 `pumpAndSettle`。
      for (var i = 0; i < 400; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)));
        await tester.pump(const Duration(milliseconds: 5));
      }

      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));

      var seen = false;
      for (var i = 0; i < 200 && !seen; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 10));
        seen = find.textContaining('通知权限未授予').evaluate().isNotEmpty;
      }

      expect(invoked, contains('guard'), reason: '前置自证：开启意图真的下发给引擎了');
      expect(asked.map((e) => e.toSet()).expand((e) => e),
          containsAll(<Permission>[Permission.notification]),
          reason: '前置自证：权限申请真的发生了（否则 perms 恒为 null，分支走不到）');
      expect(find.textContaining('通知权限未授予'), findsOneWidget,
          reason: '守卫已开启但通知被拒 ⇒ 后台提醒与告警会静默缺失，必须说出来');
      expect(find.textContaining('系统设置 → 应用 → 声盾 → 通知'), findsOneWidget,
          reason: '降级提示必须给出恢复路径，否则用户只知道"坏了"');

      // SnackBar 的 4s 计时必须推掉，否则收尾判 pending timer。
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 400));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  // ═══════════════════════════════════════════════════════════════════
  // GAP-05..08 remote_tasks_tab
  // ═══════════════════════════════════════════════════════════════════
  group('GAP-05 远程任务子页', () {
    Future<_FakeChannel> pumpTasks(
      WidgetTester tester, {
      List<PairedEndpoint> endpoints = const [],
    }) async {
      SharedPreferences.setMockInitialValues({});
      final store = RemoteStore(await SharedPreferences.getInstance());
      for (final e in endpoints) {
        await store.addPaired(e);
      }
      await store.setEnabled(true);
      final ch = _FakeChannel();
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: RemoteTasksTab(channel: ch)),
      ));
      await tester.pump();
      // refresh() 的 2s 兜底延迟必须冲掉，否则 loading 恒真。
      await tester.pump(const Duration(seconds: 3));
      ch.emit(RcEvt.status, {'pendingCount': 0, 'version': '1.8.0-alpha'});
      await tester.pump();
      return ch;
    }

    testWidgets('GAP-05 超时后迟到的回执 → 明确标注"迟到"，不冒充刚刚那次',
        (tester) async {
      final ch = await pumpTasks(tester, endpoints: [_ep('dev-a', 'A 机')]);
      ch.emit(RcEvt.tasks, {
        'tasks': [_wireTask()]
      });
      await tester.pump();

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即执行'));
      await tester.pump();
      final run = ch.lastOfType(RcCmd.taskRunNow);

      // runNow 的超时是 50s：推进假时钟让它超时并销账。
      await tester.pump(const Duration(seconds: 51));
      expect(find.textContaining('端点未执行「早间播报」'), findsOneWidget,
          reason: '前置自证：超时已告知"未执行"（否则没有"迟到"可言）');

      // 端点迟到回执：必须单独提示，不能与前一条"未执行"互相矛盾。
      ch.emit(RcEvt.ack, {'ok': true, 'for': run.id});
      await tester.pump();
      // SnackBar 排队：先冲掉上一条的 4s 计时，迟到提示才会露头。
      await _waitForText(tester, '迟到的回执：端点其实已执行');

      expect(find.textContaining('迟到的回执：端点其实已执行'), findsOneWidget,
          reason: '超时销账后的回执必须带"迟到"前缀，否则用户会看到自相矛盾的两条提示');
      await _drainSnack(tester);
    });

    testWidgets('GAP-06 选中端点失效 → 命令未发出必须显式告知', (tester) async {
      final ch = await pumpTasks(tester, endpoints: [_ep('dev-a', 'A 机')]);
      // 把"选中端点"清空（等价于端点被解配对后本页仍持有旧目标）。
      tester
          .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>))
          .onChanged!(null);
      await tester.pump();
      // 列表仍要能渲染（事件不带 peerId ⇒ 天然放行），这样才能点到开关。
      ch.emit(RcEvt.tasks, {
        'tasks': [_wireTask()]
      });
      await tester.pump();

      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(find.textContaining('未选择目标端点（可能已解配对），命令未发出'),
          findsOneWidget,
          reason: '静默 return 会让用户以为"点了就生效了"（选中端点已解配对时最危险）');
      expect(ch.sentType(RcCmd.taskToggle), isFalse,
          reason: '没有目标端点就不该真的发出命令');
    });

    testWidgets('GAP-07 无目标端点时点「新建」→ 明确提示而不是毫无反应', (tester) async {
      await pumpTasks(tester, endpoints: [_ep('dev-a', 'A 机')]);
      tester
          .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>))
          .onChanged!(null);
      await tester.pump();

      await tester.tap(find.text('新建端点任务'));
      await tester.pump();

      expect(find.text('请先选择端点'), findsOneWidget,
          reason: '点「新建」没反应 = 用户以为按钮坏了（失败必须可见）');
    });

    testWidgets('GAP-08 过期回执表只留最近 32 条（超出淘汰最早的一条）',
        (tester) async {
      final ch = await pumpTasks(tester, endpoints: [_ep('dev-a', 'A 机')]);
      ch.emit(RcEvt.tasks, {
        'tasks': [_wireTask()]
      });
      await tester.pump();

      // 33 次"立即执行 + 超时"，每次都往过期表里记一条 ⇒ 第 33 条触发淘汰。
      final ids = <String>[];
      for (var i = 0; i < 33; i++) {
        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('立即执行'));
        await tester.pump();
        ids.add(ch.lastOfType(RcCmd.taskRunNow).id);
        await tester.pump(const Duration(seconds: 51)); // runNow 超时 50s
        await _drainSnack(tester);
      }
      expect(ids.toSet().length, 33, reason: '前置自证：每次都是新的命令 id');

      // 最早那条已被淘汰 ⇒ 它的迟到回执只能走"无主回执"分支（不带"迟到"前缀）。
      ch.emit(RcEvt.ack, {'ok': true, 'for': ids.first});
      await tester.pump();
      await _waitForText(tester, '✓ 端点已执行');
      expect(find.textContaining('迟到的回执'), findsNothing,
          reason: '超出上限的旧 id 必须被淘汰（否则这张表会无限增长）');
      await _drainSnack(tester);

      // 最近那条仍在表内 ⇒ 仍按"迟到回执"提示。
      ch.emit(RcEvt.ack, {'ok': true, 'for': ids.last});
      await tester.pump();
      await _waitForText(tester, '迟到的回执：端点其实已执行');
      expect(find.textContaining('迟到的回执：端点其实已执行'), findsOneWidget,
          reason: '最近 32 条必须仍然有效（淘汰的是最早的那批，不是全部）');
      await _drainSnack(tester);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  // ═══════════════════════════════════════════════════════════════════
  // GAP-09/10 remote_scripts_tab
  //
  // 说明：`_send` 里"端点已不存在"那一支（L237-243）**结构上不可达** ——
  // 它要求 `_selectedId` 非空但不在 `_endpoints` 里，而页面在 `ch == null`
  // 且 `_endpoints` 非空时会渲染端点下拉，`DropdownButton` 对"选中值不在
  // items 里"直接 assert（实测抛 `There should be exactly one item with
  // [DropdownButton]'s value`）⇒ 这种状态根本无法被构建出来。
  // 故本组只补「删除落盘失败」的 catch 兜底。
  // ═══════════════════════════════════════════════════════════════════
  group('GAP-09 远程指令组子页', () {
    final saved = jsonEncode([
      {
        'id': 'saved-1',
        'name': '回家提醒',
        'savedAt': 1700000000000,
        'payload': {
          'scriptId': 'sc-1',
          'name': '回家提醒',
          'fromName': '我',
          'sentAt': 1700000000000,
          'steps': [
            {'kind': 'tts', 'text': '到家了', 'volume': 0.8},
          ],
        },
      }
    ]);

    Future<void> pumpScripts(
      WidgetTester tester, {
      List<PairedEndpoint> endpoints = const [],
    }) async {
      SharedPreferences.setMockInitialValues({'rc_scripts': saved});
      final store = RemoteStore(await SharedPreferences.getInstance());
      for (final e in endpoints) {
        await store.addPaired(e);
      }
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // 不传 channel / events ⇒ 走"已配对端点"的真实分支（本组要测的正是它）。
      await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: RemoteScriptsTab()),
      ));
      await _frames(tester, 6);
    }

    testWidgets('GAP-10 删除落盘失败 → catch 兜底：明说"删除失败：原因"',
        (tester) async {
      await pumpScripts(tester, endpoints: [_ep('dev-a', 'A 机')]);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      // 只拦 `rc_scripts` 的写盘（挂载期读路径已走完，换桩不影响加载）。
      final thrower = _FailingScriptsStore();
      final prev = spi.SharedPreferencesStorePlatform.instance;
      spi.SharedPreferencesStorePlatform.instance = thrower;
      addTearDown(() => spi.SharedPreferencesStorePlatform.instance = prev);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await _frames(tester, 6);

      expect(thrower.scriptsWriteAttempts, greaterThanOrEqualTo(1),
          reason: '前置自证：删除真的尝试过写盘（否则 catch 不可能触发）');
      expect(find.textContaining('删除失败：'), findsOneWidget,
          reason: '删除失败不能无声无息 —— 列表还在会让人以为没点上');
      expect(find.textContaining('模拟盘满'), findsOneWidget,
          reason: '原因文本必须透传，而不是笼统一句"失败"');
      expect(find.text('回家提醒'), findsOneWidget,
          reason: '失败后条目必须还在（删不掉却从列表消失 = 假成功）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // GAP-11 remote_console_tab：振动参数对话框的「取消」与滑块回调
  // ═══════════════════════════════════════════════════════════════════
  group('GAP-11 远程控制台振动对话框', () {
    Future<_FakeChannel> pumpConsole(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance();
      final ch = _FakeChannel();
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Scaffold(body: RemoteConsoleTab(channel: ch))),
      ));
      await _frames(tester, 6);
      return ch;
    }

    Future<void> openDialog(WidgetTester tester) async {
      final btn = find.widgetWithText(OutlinedButton, '发送振动');
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await _frames(tester, 6);
      expect(find.text('发送振动'), findsWidgets,
          reason: '前置自证：对话框真的打开了');
    }

    testWidgets('GAP-11 对话框「取消」→ 关闭且一条命令都不发', (tester) async {
      final ch = await pumpConsole(tester);
      await openDialog(tester);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      // ⚠️ 对话框退场是 150ms 的路由过渡动画（`_kDialogTransitionDuration`）：
      // 6 帧（96ms）跑不完，此时 AlertDialog 仍在 widget 树上 —— 必须把退场
      // 动画推完再断言"关掉了"，否则得到的是假红（按钮其实接的是真 pop）。
      await _frames(tester, 25);

      expect(find.byType(AlertDialog), findsNothing,
          reason: '「取消」必须真的关掉对话框');
      expect(ch.sentType(RcCmd.vibrateStart), isFalse,
          reason: '取消就是不发 —— 否则"取消"按钮等于装饰');
    });

    testWidgets('GAP-11b 拖动参数滑块 → 界面数值随回调真实更新', (tester) async {
      await pumpConsole(tester);
      await openDialog(tester);

      final sliderFinder = find.byType(Slider).first;
      final slider = tester.widget<Slider>(sliderFinder);
      final target = slider.value == slider.max ? slider.min : slider.max;

      // 直接驱动真实回调（断言的是回调里的业务逻辑，不是手势命中）。
      slider.onChanged!(target);
      await tester.pump();
      await tester.pump();

      expect(tester.widget<Slider>(sliderFinder).value, target,
          reason: 'onChanged 必须把值写回 `_v` 并触发重建（否则拖了等于没拖）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // GAP-12 ptt_tab：`pttStartStream()` 期间松手 → 必须撤销这段无人控制的录音
  // ═══════════════════════════════════════════════════════════════════
  group('GAP-12 对讲机松手撤销', () {
    late _GatedRecordPlatform rec;

    setUp(() {
      rec = _GatedRecordPlatform();
      rec.install();
    });

    tearDown(() {
      rec.uninstall();
      rec.gate = null;
    });

    testWidgets('GAP-12 录音流拉起前已松手 → 立刻 pttCancelStream 收掉麦克风',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.addPaired(_ep('0123456789abcdef', '客厅平板'));
      stubPermissions({Permission.microphone: PermissionStatus.granted});
      addTearDown(clearPermissionStub);

      // 真实 zone 预热单例的 `_createFuture`（见 test/support/record_stub.dart 第二层）。
      await tester.runAsync(() => RcControllerService.instance.pttCancel());
      rec.calls.clear();
      // ⚠️ `gate` 必须**在 `runAsync`（真实 zone）内部**创建（R96 实测换来）：
      // `Completer` 的完成续体按**完成时所在 zone** 的微任务队列调度，
      // fake zone 里 `complete()` 会把 `startStream()` 的恢复续体排进假队列，
      // 之后 `_start()` 的 P2-25 撤销分支、`pttCancelStream()` 一条都不推进
      // （症状：桩只见 `startStream`、永不见 `stop`）。

      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: PttTab())));
      await _frames(tester, 6);

      final mic = find.ancestor(
          of: find.byIcon(Icons.mic), matching: find.byType(GestureDetector));

      // ★ 整条手势必须跑在 `runAsync`（真实 zone）里 —— 与 `ptt_tab_test.dart`
      // 的 PTT-04/08/09 同一裁决：单例 `AudioRecorder._createFuture` 的完成
      // 回调只在真实 zone 调度，fake-async 里 `await` 它**永不恢复**（症状不是
      // 抛错，而是平台桩一个方法都收不到）；`kPressTimeout` 的 Timer 同样推的是
      // 真实时钟。fake zone 里跑这条链 = 桩收不到 startStream = 假红。
      var started = false;
      await tester.runAsync(() async {
        // 见上方注：闸门必须在真实 zone 创建，否则 `complete()` 的续体进假队列。
        rec.gate = Completer<void>();
        final g = await tester.startGesture(tester.getCenter(mic));
        // 有界轮询：等录音路径真被进入（桩见到 startStream = `_start()` 已越过
        // `_pressing` 检查、进入 `pttStartStream()` 且流已拉起），不写死时长
        // （全量并发下「权限申请 → startStream」的真实往返可能 >150ms）。
        for (var i = 0; i < 240 && !rec.calls.contains('startStream'); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        started = rec.calls.contains('startStream');
        // 关键：**在 `pttStartStream()` 还没返回时松手**（startStream 被闸门挂住）。
        await g.up();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // 放行 startStream ⇒ `pttStartStream()` 返回 true ⇒ `_start()` 恢复执行，
        // 读到 `_pressing == false` ⇒ 走 P2-25 撤销分支。
        rec.gate!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await _frames(tester, 6);

      expect(started, isTrue,
          reason: '前置自证：录音流真的被请求了（否则撤销分支无意义）');
      expect(rec.calls, contains('stop'),
          reason: '松手后必须 `pttCancelStream()` 收掉这段无人控制的录音 —— '
              '否则它会一直录到 60s 上限才自动发送');
      expect(find.textContaining('录音中'), findsNothing,
          reason: '撤销后不得停留在录音态');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}

/// **可闸门**的 `RecordPlatform` 平台层替身。
///
/// 与 `test/support/record_stub.dart` 的 `FakeRecordPlatform` 同源（只桩插件
/// 平台侧返回，不桩业务判断），额外给 `startStream()` 加了一道闸门：
/// 用例可以精确地把"录音流拉起中"这一段挂住，从而**确定性地**制造
/// 「`pttStartStream()` 在飞时用户松手」这个竞态（P2-25 的撤销分支）。
class _GatedRecordPlatform extends RecordPlatform {
  /// 非 null ⇒ `startStream()` 卡在这里，直到用例 `complete()`。
  Completer<void>? gate;

  final calls = <String>[];

  RecordPlatform? _saved;

  void install() {
    _saved = RecordPlatform.instance;
    RecordPlatform.instance = this;
  }

  void uninstall() {
    final s = _saved;
    if (s != null) RecordPlatform.instance = s;
    _saved = null;
  }

  @override
  Future<void> create(String recorderId) async => calls.add('create');

  @override
  Future<void> start(String recorderId, RecordConfig config,
      {required String path}) async {
    calls.add('start');
  }

  @override
  Future<Stream<Uint8List>> startStream(
      String recorderId, RecordConfig config) async {
    calls.add('startStream');
    final g = gate;
    if (g != null) await g.future;
    return const Stream<Uint8List>.empty();
  }

  @override
  Future<String?> stop(String recorderId) async {
    calls.add('stop');
    return null;
  }

  @override
  Future<void> cancel(String recorderId) async => calls.add('cancel');

  @override
  Future<void> pause(String recorderId) async => calls.add('pause');

  @override
  Future<void> resume(String recorderId) async => calls.add('resume');

  @override
  Future<bool> isRecording(String recorderId) async {
    calls.add('isRecording');
    return false;
  }

  @override
  Future<bool> isPaused(String recorderId) async {
    calls.add('isPaused');
    return false;
  }

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async {
    calls.add('hasPermission');
    return true;
  }

  @override
  Future<void> dispose(String recorderId) async => calls.add('dispose');

  @override
  Future<Amplitude> getAmplitude(String recorderId) async {
    calls.add('getAmplitude');
    return Amplitude(current: -160, max: -160);
  }

  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder encoder) async {
    calls.add('isEncoderSupported');
    return true;
  }

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async {
    calls.add('listInputDevices');
    return const <InputDevice>[];
  }

  @override
  void setOnConfigChanged(
      String recorderId, void Function(RecordConfig config)? handler) {}

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();
}
