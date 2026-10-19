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

/// R89 · 「守护开关不好使了」根因回归锁。
///
/// ## 现场症状（2026-10-18，用户实测 1.9.6+29）
///
/// 点守护页总开关 → **开关不动、零提示、通知栏也没有前台服务通知**。
/// 三个判据合起来说明：引擎压根没起来，而且失败被**静默**掉了。
///
/// ## 根因（本轮修复）
///
/// | # | 位置 | 缺陷 |
/// |---|---|---|
/// | 1 | `background_service_manager.start()` | `await _svc.startService()` **无超时**。原生侧不回执 ⇒ 永久挂起 ⇒ 连失败提示都出不来（不是抛错，是永不返回） |
/// | 2 | 同上 | `startService()` 抛 `PlatformException`（前台服务被系统/厂商拒绝）时**无 catch**，异常穿透 `onChanged` 的 async 闭包 ⇒ 未捕获异步错误 ⇒ 开关弹回、零提示（与 BUG-061 同形） |
/// | 3 | `background_service_manager.init()` | `main.dart` 对 init 做了降级 catch，但失败原因**无处可见**；此时 `startService()` 必然无效，UI 却只会说「后台服务未响应」 |
/// | 4 | `background_service_manager.stop()` | 只有一句 fire-and-forget `invoke('stop')`。引擎**已死**时无人回投 `running:false` ⇒ `_last` 永远停在 true ⇒ 开关卡在「守护已开启」，再点也关不掉 |
/// | 5 | `dashboard_screen._EngineCard.onChanged` | 整条链路**无 try/catch**（守卫开关早在 BUG-061 就有）⇒ 任何一步抛错都变成静默失败 |
///
/// ## 断言准则
///
/// 每条都断言「失败真的发生了，且原因真的说出来了」，不写恒真断言。
/// 宿主上 `init()` 必抛（`_svc.configure()` 非移动平台 `UnsupportedError`），
/// 所以用 `initErrorForTest` 注入「已初始化/初始化失败」两态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 复位全部静态缝。单例跨用例复用，漏复位会串状态。
  void resetSeams() {
    BackgroundServiceManager.startHook = null;
    BackgroundServiceManager.startServiceHook = null;
    BackgroundServiceManager.invokeHook = null;
    BackgroundServiceManager.lastForTest = null;
    BackgroundServiceManager.stateForTest = null;
    BackgroundServiceManager.startServiceTimeout = const Duration(seconds: 12);
    BackgroundServiceManager.initErrorForTest = null;
    BackgroundServiceManager.startErrorForTest = null;
  }

  /// 合规已同意 + 权限全给 + 原生通道回 null。
  Future<void> primeHost() async {
    SharedPreferences.setMockInitialValues({'compliance_accepted_v1': true});
    await SharedPreferences.getInstance();
    stubPermissions({
      Permission.notification: PermissionStatus.granted,
      Permission.microphone: PermissionStatus.granted,
    });
    // 宿主无原生实现：不桩的话 `setServiceShouldRun` 的 future 可能永不 resolve。
    messenger().setMockMethodCallHandler(
        const MethodChannel('sonic_shield/native'), (call) async => null);
    addTearDown(() {
      clearPermissionStub();
      messenger().setMockMethodCallHandler(
          const MethodChannel('sonic_shield/native'), null);
    });
  }

  group('R89-ENG start() 失败分类（每种都要说清原因）', () {
    setUp(() async {
      resetSeams();
      await primeHost();
    });
    tearDown(resetSeams);

    test('R89-ENG-01 未同意合规 → false，且原因为「未同意」', () async {
      // 覆盖 start() 的第一道准入闸（合规门 P1-02）。
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance();
      final ok = await BackgroundServiceManager.instance.start();
      expect(ok, isFalse);
      expect(BackgroundServiceManager.instance.startError, contains('合规'),
          reason: '未同意必须给出「合规」原因，不能只说"未响应"');
    });

    test('R89-ENG-02 init 失败 → 直接 false，原因指向初始化（不再空等 startService）',
        () async {
      // 覆盖新增的 initError 短路分支：初始化坏了，startService 必然无效。
      BackgroundServiceManager.initErrorForTest = 'configure boom';
      var platformCalled = false;
      BackgroundServiceManager.startServiceHook = () async {
        platformCalled = true;
        return true;
      };
      final ok = await BackgroundServiceManager.instance.start();
      expect(ok, isFalse);
      expect(BackgroundServiceManager.instance.startError,
          allOf(contains('未初始化'), contains('configure boom')));
      expect(platformCalled, isFalse,
          reason: '初始化已坏时不该再去碰平台通道（那正是永久挂起的来源）');
    });

    test('R89-ENG-03 startService 返回 false → false，原因说明服务未接受',
        () async {
      BackgroundServiceManager.startServiceHook = () async => false;
      final ok = await BackgroundServiceManager.instance.start();
      expect(ok, isFalse);
      expect(BackgroundServiceManager.instance.startError, contains('未接受'));
    });

    test('R89-ENG-04 startService 抛 PlatformException → false，原因原样转达',
        () async {
      // 这正是真机上最可能的形态：Android 14+ 前台服务类型限制 / 厂商后台
      // 策略会让原生侧直接拒绝。旧实现让它穿透成未捕获异步错误。
      BackgroundServiceManager.startServiceHook = () async => throw
          PlatformException(
              code: 'ForegroundServiceStartNotAllowedException',
              message: 'FGS start not allowed');
      final ok = await BackgroundServiceManager.instance.start();
      expect(ok, isFalse);
      expect(BackgroundServiceManager.instance.startError, contains('被拒'),
          reason: '必须区分"被拒"与"没回音"，两者用户指引完全不同');
      expect(BackgroundServiceManager.instance.startError,
          contains('ForegroundServiceStartNotAllowedException'));
    });

    test('R89-ENG-05 startService 永不回执 → 超时兜底 false（旧实现永久挂起）',
        () async {
      // 这是「点了完全没反应」最直接的机器形态：Completer 永不完成。
      BackgroundServiceManager.startServiceTimeout =
          const Duration(milliseconds: 40);
      final never = Completer<bool>();
      BackgroundServiceManager.startServiceHook = () => never.future;
      final sw = Stopwatch()..start();
      final ok = await BackgroundServiceManager.instance.start();
      sw.stop();
      expect(ok, isFalse);
      expect(BackgroundServiceManager.instance.startError, contains('无回执'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: '必须在注入的超时窗口内返回，不能真的挂住');
    });

    test('R89-ENG-06 成功路径 → true，且残留的旧错误被清空', () async {
      BackgroundServiceManager.startErrorForTest = '上一次的陈旧错误';
      BackgroundServiceManager.startServiceHook = () async => true;
      final ok = await BackgroundServiceManager.instance.start();
      expect(ok, isTrue);
      expect(BackgroundServiceManager.instance.startError, isNull,
          reason: '成功必须清掉旧原因，否则下次失败会显示过期文案');
    });
  });

  group('R89-ENG stop() 关闭兜底（引擎已死也要能关掉）', () {
    setUp(() async {
      resetSeams();
      await primeHost();
      BackgroundServiceManager.invokeHook = (_, __) async {};
    });
    tearDown(resetSeams);

    test('R89-ENG-07 引擎已死（无人回投）→ 本地兜底置 running:false', () async {
      // 现场形态：进程被厂商清理，UI 的 `_last` 仍是陈旧的 running:true。
      final firedAt = DateTime(2026, 10, 18, 23, 0);
      BackgroundServiceManager.lastForTest = EngineState(
          running: true, pendingCount: 3, nextFireAt: firedAt);
      BackgroundServiceManager.stateForTest = const Stream<EngineState>.empty();
      await BackgroundServiceManager.instance.stop();
      final last = BackgroundServiceManager.instance.last;
      expect(last?.running, isFalse,
          reason: '引擎已死也必须能关掉开关，否则用户永远卡在"已开启"');
      expect(last?.nextFireAt, isNull,
          reason: '引擎已停 ⇒ 倒计时不再成立，必须清掉，否则首页显示幽灵计划');
      expect(last?.guardActive, isFalse, reason: '引擎停了守卫必然不在跑');
    });

    test('R89-ENG-08 引擎本来就没跑 → 不进入等待、不动既有状态', () async {
      // 判据：兜底会把 nextFireAt 清空，而"本来没跑"必须原样保留，
      // 否则这两个分支无法区分（同结果 ≠ 同路径）。
      final firedAt = DateTime(2026, 10, 18, 23, 30);
      BackgroundServiceManager.lastForTest =
          EngineState(running: false, pendingCount: 7, nextFireAt: firedAt);
      await BackgroundServiceManager.instance.stop();
      expect(BackgroundServiceManager.instance.last?.nextFireAt, firedAt,
          reason: '没在跑就直接返回，不该走兜底改写状态');
    });

    test('R89-ENG-09 连续两次 stop 幂等，且兜底保留 lastAction', () async {
      BackgroundServiceManager.lastForTest = const EngineState(
          running: true, pendingCount: 5, lastAction: '播放助眠音');
      await BackgroundServiceManager.instance.stop();
      final first = BackgroundServiceManager.instance.last;
      expect(first?.running, isFalse);
      expect(first?.lastAction, '播放助眠音',
          reason: '兜底只该改「运行态相关」字段，最近动作仍是有效信息');
      expect(first?.pendingCount, 5, reason: '计划数不因停机而清零');
      // 第二次：已经是 false ⇒ 直接返回，不该抛也不该再改写状态。
      await BackgroundServiceManager.instance.stop();
      expect(BackgroundServiceManager.instance.last?.running, isFalse);
    });
  });

  group('R89-ENG UI：失败必须可见（不许静默弹回）', () {
    /// pump 出守护页；开关初始为关。
    Future<void> pumpDashboard(WidgetTester tester) async {
      BackgroundServiceManager.lastForTest =
          const EngineState(running: false, pendingCount: 0);
      BackgroundServiceManager.stateForTest =
          Stream<EngineState>.value(
              const EngineState(running: false, pendingCount: 0));
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: DashboardScreen(),
          ),
        ),
      );
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
    }

    /// 有界等待某个文案出现。
    ///
    /// ⚠️ 不能用 `pumpAndSettle` 当"等数据"：`start()` 内部有 800ms 的
    /// 「给状态回投一次事件循环」延迟，那是 **Timer 不是帧**，
    /// `pumpAndSettle` 在没有 pending frame 时会立刻返回，断言就会落空。
    Future<bool> waitForText(WidgetTester tester, String text,
        {int ticks = 60}) async {
      for (var i = 0; i < ticks; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.textContaining(text).evaluate().isNotEmpty) return true;
      }
      return false;
    }

    testWidgets('R89-ENG-10 启动失败 → SnackBar 说出真实原因（不再是一句"未响应"）',
        (tester) async {
      resetSeams();
      await primeHost();
      // 用最内层钩子制造失败：`start()` 走真实分类逻辑，只有平台调用被替换。
      BackgroundServiceManager.startServiceHook = () async => false;
      await pumpDashboard(tester);

      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      expect(await waitForText(tester, '守护启动失败'), isTrue,
          reason: '失败必须有提示 —— 这就是"点了完全没反应"的正面判据');
      expect(find.textContaining('未接受'), findsOneWidget,
          reason: '必须带上 start() 分类出的真实原因，而不是万能文案');
    });

    testWidgets('R89-ENG-11 onChanged 内抛异常 → SnackBar 兜底提示（不许穿透）',
        (tester) async {
      resetSeams();
      await primeHost();
      // startHook 在 start() 的 try 之外，异常会一路穿到 onChanged ——
      // 正是旧实现里「未捕获异步错误 ⇒ 开关弹回 + 零提示」的形状。
      BackgroundServiceManager.startHook = () async =>
          throw StateError('boom-r89');
      await pumpDashboard(tester);

      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      expect(await waitForText(tester, '守护开关操作失败'), isTrue,
          reason: '任何未预期异常都必须变成看得见的原因');
      expect(find.textContaining('boom-r89'), findsOneWidget,
          reason: '原始异常信息要保留，否则排查又回到猜');
    });
  });
}
