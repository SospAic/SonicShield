// 覆盖率攻坚（X4 · services/models 层）：power_service / notification_service /
// playback_service / vibrate_caps / background_service_manager 的行为测试。
// 平台通道一律用 mock 打桩，禁止任何"恒真断言"。
import 'dart:async';
import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:battery_plus/battery_plus.dart';
// ignore: depend_on_referenced_packages -- battery_plus 的传递依赖，打桩必须用它的平台接口
import 'package:battery_plus_platform_interface/battery_plus_platform_interface.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages -- flutter_background_service 的传递依赖，同上
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/notification_service.dart';
import 'package:sonic_shield/services/playback_service.dart';
import 'package:sonic_shield/services/power_service.dart';
import 'package:timezone/timezone.dart' as tz;

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ============================================================
  // 1. vibrate_caps —— 纯模型，无插件，应接近全绿
  // ============================================================
  group('VC · VibrateCaps.fromMap（缺失字段一律取保守值）', () {
    test('VC01 全字段回执 → 原样解析', () {
      final caps = VibrateCaps.fromMap(const {
        'hasVibrator': true,
        'hasAmplitudeControl': true,
        'hasEnvelope': false,
        'minControlPointMs': 24,
        'platform': 'android',
        'backgroundSupported': false,
      });
      expect(caps.hasVibrator, isTrue);
      expect(caps.hasAmplitudeControl, isTrue);
      expect(caps.hasEnvelope, isFalse);
      expect(caps.minControlPointMs, 24);
      expect(caps.platform, 'android');
      expect(caps.backgroundSupported, isFalse);
    });

    test('VC02 空 map → 全保守（不猜能力）', () {
      final caps = VibrateCaps.fromMap(const {});
      expect(caps.hasVibrator, isFalse);
      expect(caps.hasAmplitudeControl, isFalse);
      expect(caps.hasEnvelope, isFalse);
      expect(caps.minControlPointMs, 20, reason: '框架要求最小 20ms');
      expect(caps.platform, 'unknown');
      expect(caps.backgroundSupported, isTrue);
    });

    test('VC03 字段为 null → 同缺失', () {
      final caps = VibrateCaps.fromMap(const {
        'hasVibrator': null,
        'hasAmplitudeControl': null,
        'hasEnvelope': null,
        'minControlPointMs': null,
        'platform': null,
        'backgroundSupported': null,
      });
      expect(caps.hasVibrator, isFalse);
      expect(caps.minControlPointMs, 20);
      expect(caps.platform, 'unknown');
      expect(caps.backgroundSupported, isTrue);
    });

    test('VC04 minControlPointMs 是 double → 取整不抛', () {
      final caps = VibrateCaps.fromMap(const {'minControlPointMs': 20.9});
      expect(caps.minControlPointMs, 20);
    });
  });

  group('VC · VibrateCaps.toMap / 往返', () {
    test('VC05 toMap 键集合精确', () {
      const caps = VibrateCaps(
        hasVibrator: true,
        hasAmplitudeControl: false,
        hasEnvelope: true,
        minControlPointMs: 24,
        platform: 'android',
        backgroundSupported: false,
      );
      expect(caps.toMap(), {
        'hasVibrator': true,
        'hasAmplitudeControl': false,
        'hasEnvelope': true,
        'minControlPointMs': 24,
        'platform': 'android',
        'backgroundSupported': false,
      });
    });

    test('VC06 toMap → fromMap 往返相等', () {
      const caps = VibrateCaps(
        hasVibrator: true,
        hasAmplitudeControl: true,
        hasEnvelope: true,
        minControlPointMs: 30,
        platform: 'android',
        backgroundSupported: true,
      );
      expect(VibrateCaps.fromMap(caps.toMap()), caps);
    });
  });

  group('VC · canExpressAmplitude（vibrator 与 强度能力 缺一不可）', () {
    VibrateCaps caps(bool v, bool amp, bool env) => VibrateCaps(
        hasVibrator: v, hasAmplitudeControl: amp, hasEnvelope: env, minControlPointMs: 20);

    test('VC07 vibrator+envelope → true', () => expect(caps(true, false, true).canExpressAmplitude, isTrue));
    test('VC08 vibrator+amplitude → true', () => expect(caps(true, true, false).canExpressAmplitude, isTrue));
    test('VC09 无 vibrator 但有 envelope → false', () {
      // 变异证伪：若退化成 hasEnvelope 单独判定，此例会红。
      expect(caps(false, false, true).canExpressAmplitude, isFalse);
    });
    test('VC10 有 vibrator 无任何强度能力 → false', () {
      expect(caps(true, false, false).canExpressAmplitude, isFalse);
    });
  });

  group('VC · 预设常量 / 相等性 / toString', () {
    test('VC11 none 与 unknown 均保守但 platform 可区分', () {
      expect(VibrateCaps.none.hasVibrator, isFalse);
      expect(VibrateCaps.none.platform, 'none');
      expect(VibrateCaps.unknown.hasVibrator, isFalse);
      // 审计上必须区分"设备真没有"与"读不到"：
      expect(VibrateCaps.unknown == VibrateCaps.none, isFalse);
      expect(VibrateCaps.unknown.platform, 'unknown');
    });

    test('VC12 构造器默认值：platform=unknown / backgroundSupported=true', () {
      const caps = VibrateCaps(
          hasVibrator: true, hasAmplitudeControl: true, hasEnvelope: false, minControlPointMs: 20);
      expect(caps.platform, 'unknown');
      expect(caps.backgroundSupported, isTrue);
    });

    test('VC13 == 逐字段：任一字段不同则不等，hashCode 跟随', () {
      const base = VibrateCaps(
        hasVibrator: true,
        hasAmplitudeControl: true,
        hasEnvelope: false,
        minControlPointMs: 20,
        platform: 'android',
        backgroundSupported: true,
      );
      VibrateCaps m({
        bool vibrator = true,
        bool amp = true,
        bool env = false,
        int minMs = 20,
        String platform = 'android',
        bool bg = true,
      }) =>
          VibrateCaps(
            hasVibrator: vibrator,
            hasAmplitudeControl: amp,
            hasEnvelope: env,
            minControlPointMs: minMs,
            platform: platform,
            backgroundSupported: bg,
          );

      expect(base, m());
      expect(base.hashCode, m().hashCode);
      expect(base == m(vibrator: false), isFalse);
      expect(base == m(amp: false), isFalse);
      expect(base == m(env: true), isFalse);
      expect(base == m(minMs: 21), isFalse);
      expect(base == m(platform: 'ios'), isFalse);
      expect(base == m(bg: false), isFalse);
      expect(base == Object(), isFalse);
    });

    test('VC14 toString 含全部诊断字段', () {
      const caps = VibrateCaps(
        hasVibrator: true,
        hasAmplitudeControl: false,
        hasEnvelope: true,
        minControlPointMs: 24,
        platform: 'android',
        backgroundSupported: false,
      );
      final s = caps.toString();
      expect(s, contains('platform=android'));
      expect(s, contains('vibrator=true'));
      expect(s, contains('amplitude=false'));
      expect(s, contains('envelope=true'));
      expect(s, contains('minControlPoint=24ms'));
      expect(s, contains('bg=false'));
    });
  });

  // ============================================================
  // 2. power_service —— battery_plus 平台接口打桩 + sonic_shield/native 打桩
  // ============================================================
  group('PW · PowerService', () {
    final nativeLog = <MethodCall>[];
    const nativeChannel = MethodChannel('sonic_shield/native');

    setUp(() {
      _messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        nativeLog.add(call);
        return switch (call.method) {
          'isIgnoringBatteryOptimizations' => true,
          _ => null,
        };
      });
    });
    tearDown(() {
      _messenger.setMockMethodCallHandler(nativeChannel, null);
      nativeLog.clear();
    });

    /// 可编程电池平台：记录 batteryLevel 被读次数，支持强制抛错。
    _FakeBatteryPlatform makeBattery({int level = 100, BatteryState state = BatteryState.full, bool fail = false}) {
      final p = _FakeBatteryPlatform();
      p.level = level;
      p.state = state;
      p.fail = fail;
      BatteryPlatform.instance = p;
      return p;
    }

    test('PW01 batteryLevel / batteryState 透传', () async {
      final p = makeBattery(level: 42, state: BatteryState.charging);
      final svc = PowerService(Battery());
      expect(await svc.batteryLevel(), 42);
      expect(await svc.batteryState(), BatteryState.charging);
      expect(p.levelReads, 1);
    });

    test('PW02 isCharging：charging → true', () async {
      makeBattery(state: BatteryState.charging);
      expect(await PowerService(Battery()).isCharging(), isTrue);
    });

    test('PW03 isCharging：full 也算"在充电"（插着电不必省电）', () async {
      makeBattery(state: BatteryState.full);
      expect(await PowerService(Battery()).isCharging(), isTrue);
    });

    test('PW04 isCharging：discharging → false', () async {
      makeBattery(state: BatteryState.discharging);
      expect(await PowerService(Battery()).isCharging(), isFalse);
    });

    test('PW05 用户已选省电 → 直接省电（不读电池，避免无谓平台调用）', () async {
      final p = makeBattery(fail: true); // 若真的读了电池就会炸
      final mode = await PowerService(Battery()).effectiveMode(PowerMode.saver);
      expect(mode, PowerMode.saver);
      expect(p.levelReads, 0);
    });

    test('PW06 低电量且未充电 → saver 自动接管（performance 用户也一样）', () async {
      makeBattery(level: 10, state: BatteryState.discharging);
      expect(await PowerService(Battery()).effectiveMode(PowerMode.performance), PowerMode.saver);
    });

    test('PW07 边界：电量恰好等于阈值(15) 不触发接管', () async {
      makeBattery(level: PowerConfig.saverBatteryLevel, state: BatteryState.discharging);
      expect(await PowerService(Battery()).effectiveMode(PowerMode.balanced), PowerMode.balanced);
    });

    test('PW08 低电量但在充电 → 维持用户选择', () async {
      makeBattery(level: 5, state: BatteryState.charging);
      expect(await PowerService(Battery()).effectiveMode(PowerMode.balanced), PowerMode.balanced);
    });

    test('PW09 读电量抛异常（桌面无电池）→ 维持用户选择，不抛', () async {
      makeBattery(fail: true);
      expect(await PowerService(Battery()).effectiveMode(PowerMode.performance), PowerMode.performance);
    });

    test('PW10 PowerMode.label 三态文案', () {
      expect(PowerMode.performance.label, '性能优先');
      expect(PowerMode.balanced.label, '平衡');
      expect(PowerMode.saver.label, '省电');
    });

    test('PW11 batteryOptimizedAway 透传原生 isIgnoringBatteryOptimizations', () async {
      makeBattery();
      expect(await PowerService(Battery()).batteryOptimizedAway(), isTrue);
      expect(nativeLog.map((c) => c.method), contains('isIgnoringBatteryOptimizations'));
    });

    test('PW12 三个引导动作都打在对应方法名上（方法名拼错只会得到 null 静默失效）', () async {
      makeBattery();
      final svc = PowerService(Battery());
      await svc.requestBatteryOptimizationExemption();
      await svc.openExactAlarmSettings();
      await svc.openOemAutostart('xiaomi');
      expect(nativeLog.map((c) => c.method).toList(), [
        'requestIgnoreBatteryOptimizations',
        'openExactAlarmSettings',
        'openOemAutostart',
      ]);
      expect(nativeLog.last.arguments, {'vendor': 'xiaomi'});
    });
  });

  // ============================================================
  // 3. notification_service —— 本地通知插件 + 时区通道打桩
  // ============================================================
  group('NS · NotificationService（单例：ensure 只跑一次，顺序敏感）', () {
    final log = <MethodCall>[];
    const notifyChannel = MethodChannel('dexterous.com/flutter/local_notifications');
    const tzChannel = MethodChannel('flutter_timezone');

    setUpAll(() {
      // 模拟"宿主无时区插件"→ 覆盖 ensure 的 catch 回退 UTC 分支。
      _messenger.setMockMethodCallHandler(tzChannel, (call) async {
        throw MissingPluginException('No implementation found for ${call.method}');
      });
      _messenger.setMockMethodCallHandler(notifyChannel, (call) async {
        log.add(call);
        return call.method == 'initialize' ? true : null;
      });
    });
    tearDownAll(() {
      _messenger.setMockMethodCallHandler(tzChannel, null);
      _messenger.setMockMethodCallHandler(notifyChannel, null);
    });

    test('NS01 ensure：初始化插件；时区读不到 → 回退 UTC（不抛）', () async {
      await NotificationService.instance.ensure();
      expect(log.map((c) => c.method), contains('initialize'));
      expect(tz.local.name, 'UTC',
          reason: '时区通道不可用时必须落到 UTC 而不是崩溃；'
              '若回退分支被删，本测试会因 MissingPluginException 直接失败。');
    });

    test('NS02 ensure 幂等：第二次不重复 initialize', () async {
      log.clear();
      await NotificationService.instance.ensure();
      expect(log.map((c) => c.method), isNot(contains('initialize')));
    });

    test('NS03 requestPermission：Android 侧申请通知权限', () async {
      log.clear();
      await NotificationService.instance.requestPermission();
      expect(log.map((c) => c.method), contains('requestNotificationsPermission'));
    });

    test('NS04 createServiceChannel：五个渠道一个不少（BUG-145 增 calls）', () async {
      log.clear();
      await NotificationService.instance.createServiceChannel();
      final methods = log.map((c) => c.method).where((m) => m == 'createNotificationChannel').toList();
      expect(methods, hasLength(5));
      final ids = log
          .where((c) => c.method == 'createNotificationChannel')
          .map((c) => (c.arguments as Map)['id'] as String)
          .toList();
      expect(ids, [
        NotificationChannels.service,
        NotificationChannels.events,
        NotificationChannels.guard,
        NotificationChannels.evidence,
        // BUG-145：来电必须有独立渠道 —— 与执行日志共用渠道会被用户静音掉，
        // 那就是"后台来电完全没反应"的根因。
        NotificationChannels.calls,
      ]);
    });

    test('NS05 showEvent：id 取 title.hashCode 的非负掩码，payload 原样透传', () async {
      log.clear();
      await NotificationService.instance
          .showEvent(title: '执行事件A', body: '任务完成', payload: 'task-1');
      final call = log.singleWhere((c) => c.method == 'show');
      final args = call.arguments as Map;
      expect(args['id'], '执行事件A'.hashCode & 0x7fffffff);
      expect(args['title'], '执行事件A');
      expect(args['body'], '任务完成');
      expect(args['payload'], 'task-1');
    });

    test('NS06 showEvent 无 payload → 空串（插件契约要求非空）', () async {
      log.clear();
      await NotificationService.instance.showEvent(title: '执行事件B', body: 'b');
      expect((log.singleWhere((c) => c.method == 'show').arguments as Map)['payload'], '');
    });

    test('NS07 showGuardAlert：固定 id 0x600D 与守卫标题', () async {
      log.clear();
      await NotificationService.instance.showGuardAlert('检测到声音');
      final args = log.singleWhere((c) => c.method == 'show').arguments as Map;
      expect(args['id'], 0x600D);
      expect(args['title'], '声盾 · 守卫触发');
      expect(args['body'], '检测到声音');
    });
  });

  // ============================================================
  // 4. background_service_manager —— 平台接口整体替换为 fake
  // ============================================================
  group('BGS · BackgroundServiceManager', () {
    final fake = _FakeBgsPlatform();
    final mgr = BackgroundServiceManager.instance;
    const nativeChannel = MethodChannel('sonic_shield/native');
    final nativeLog = <MethodCall>[];

    setUpAll(() async {
      FlutterBackgroundServicePlatform.instance = fake;
      _messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        nativeLog.add(call);
        return null;
      });
      await mgr.init();
    });
    tearDownAll(() {
      _messenger.setMockMethodCallHandler(nativeChannel, null);
      // ⚠️ 静态成员不能用级联设在类名上：级联目标是 Type 对象 ⇒ undefined_setter。
      BackgroundServiceManager.startHook = null;
      BackgroundServiceManager.invokeHook = null;
      BackgroundServiceManager.replanHook = null;
      BackgroundServiceManager.lastForTest = null;
      BackgroundServiceManager.stateForTest = null;
    });
    setUp(() {
      // P1-02：`start()` 现在把「已同意合规」作为唯一准入层（未同意直接返回
      // false、不触达平台）。本组多数用例（BGS10/BGS11 等）要验证的是
      // 「同意之后」的平台调用契约，故显式置为已同意；合规门本身另由
      // dashboard_screen_test DBS-09/DBS-10 覆盖。
      SharedPreferences.setMockInitialValues({'compliance_accepted_v1': true});
      fake.invokes.clear();
      BackgroundServiceManager.lastForTest = null;
    });

    test('BGS01 init 配置契约：前台模式 / 不自启 / 渠道 id / 前台类型', () {
      final cfg = fake.androidCfg!;
      expect(cfg.isForegroundMode, isTrue);
      expect(cfg.autoStart, isFalse, reason: '由用户显式开启（合规与功耗）');
      // F-3 方案①（第 70 轮）：插件的 autoStartOnBoot **默认 true**
      // （platform_interface 5.1.2 configs.dart:73），会让插件自带 BootReceiver
      // 在开机时直接 startForegroundService(mediaPlayback)；Android 15+ 禁止
      // 从 BOOT_COMPLETED 启动该类型 ⇒ 进程被 ForegroundServiceStartNotAllowed
      // 打死并反复重启（API 36 实测）。开机恢复改由本工程 BootReceiver 排
      // 精确闹钟完成，故这里必须显式为 false。
      expect(cfg.autoStartOnBoot, isFalse,
          reason: '必须显式关掉插件自带的开机自启（其默认值是 true，'
              '会在 Android 15+ 上以 mediaPlayback 类型从 BOOT_COMPLETED 启动 FGS 而被系统打死）');
      expect(cfg.notificationChannelId, NotificationChannels.service);
      expect(cfg.foregroundServiceTypes, contains(AndroidForegroundType.mediaPlayback));
      // F-2（第 35 轮）：dataSync 型 FGS 在 Android 15+ 有「24h 内累计 6h」上限，
      // 到点回调 Service.onTimeout，而 flutter_background_service_android 6.3.1
      // 全文件 0 处 onTimeout ⇒ 到点抛 RemoteServiceException 杀进程。
      // 本引擎 7×24 常驻必然命中，故显式移除（证据见 docs/05 与 _pt/audit/E1-silent-fix.md）。
      expect(cfg.foregroundServiceTypes, isNot(contains(AndroidForegroundType.dataSync)),
          reason: 'Android 15+ 对 dataSync 有 6h/24h 上限且插件无 onTimeout');
      expect(cfg.foregroundServiceTypes, isNot(contains(AndroidForegroundType.microphone)),
          reason: 'Android 14+ 后台携带 microphone 会被拒（docs/05 §1.4）');
      expect(fake.iosCfg!.autoStart, isFalse);
    });

    test('BGS02 state 回投：字段解析与 nextFireAt 时间还原', () async {
      final states = <EngineState>[];
      final sub = mgr.state.listen(states.add);
      fake.emit('state', <String, Object?>{
        'running': true,
        'pendingCount': 2,
        'nextFireAt': DateTime(2026, 9, 24, 12).millisecondsSinceEpoch,
        'lastAction': 'sound',
        'guardActive': true,
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(mgr.last!.running, isTrue);
      expect(mgr.last!.pendingCount, 2);
      expect(mgr.last!.nextFireAt, DateTime(2026, 9, 24, 12));
      expect(mgr.last!.lastAction, 'sound');
      expect(mgr.last!.guardActive, isTrue);
      expect(mgr.isRunning, isTrue);
      expect(mgr.guardActive, isTrue);
      expect(states.single.guardActive, isTrue);
      await sub.cancel();
    });

    test('BGS03 state 消息为 null → 全默认（不炸）', () async {
      fake.emit('state', null);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(mgr.last!.running, isFalse);
      expect(mgr.last!.pendingCount, 0);
      expect(mgr.last!.nextFireAt, isNull);
      expect(mgr.isRunning, isFalse);
    });

    test('BGS04 runNow：引擎在跑 → 转交并等 rcRunResult 回投', () async {
      BackgroundServiceManager.lastForTest = const EngineState(running: true, pendingCount: 0);
      final future = mgr.runNow('task-1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final inv = fake.invokes.singleWhere((e) => e.method == 'runNow');
      final reqId = inv.args!['reqId'] as String;
      expect(inv.args!['taskId'], 'task-1');
      expect(reqId, startsWith('run'));
      // 未知 reqId（c==null 分支）+ 重复投递（isCompleted 分支）都必须无害。
      fake.emit('rcRunResult', {'reqId': 'nope', 'ok': true, 'message': 'x'});
      fake.emit('rcRunResult', {'reqId': reqId, 'ok': true, 'message': 'done'});
      fake.emit('rcRunResult', {'reqId': reqId, 'ok': false, 'message': 'late'});
      final r = await future;
      expect(r.ok, isTrue, reason: '先到的回投生效，重复投递不得覆盖');
      expect(r.message, 'done');
    });

    test('BGS05 runNow：超时是返回值而非异常', () async {
      BackgroundServiceManager.lastForTest = const EngineState(running: true, pendingCount: 0);
      final r = await mgr.runNow('task-2', timeout: const Duration(milliseconds: 60));
      expect(r.ok, isFalse);
      expect(r.message, '引擎执行超时');
    });

    test('BGS06 runNow：引擎未运行 → 直接失败且不 invoke', () async {
      final r = await mgr.runNow('task-3');
      expect(r.ok, isFalse);
      expect(r.message, '调度引擎未运行');
      expect(fake.invokes.where((e) => e.method == 'runNow'), isEmpty);
    });

    test('BGS07 runVibrateStep：未运行直接失败；在跑则转交 JSON 化的动作', () async {
      final r0 = await mgr.runVibrateStep(
          action: const PlayAudioAction(), occurrenceId: 'occ-1');
      expect(r0.ok, isFalse);
      expect(r0.message, '调度引擎未运行');

      BackgroundServiceManager.lastForTest = const EngineState(running: true, pendingCount: 0);
      final future = mgr.runVibrateStep(action: const PlayAudioAction(), occurrenceId: 'occ-2');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final inv = fake.invokes.singleWhere((e) => e.method == 'vibrateStep');
      expect(inv.args!['occurrenceId'], 'occ-2');
      expect(jsonDecode(inv.args!['action'] as String), isA<Map<dynamic, dynamic>>());
      final reqId = inv.args!['reqId'] as String;
      expect(reqId, startsWith('vib'));
      fake.emit('rcRunResult', {'reqId': reqId, 'ok': true, 'message': 'vib-done'});
      final r = await future;
      expect(r.ok, isTrue);
      expect(r.message, 'vib-done');
    });

    test('BGS08 stop / setGuard / setPowerMode：invoke 的方法名与参数', () async {
      await mgr.stop();
      await mgr.setGuard(true, micGranted: true);
      await mgr.setGuard(false);
      await mgr.setPowerMode('saver');
      expect(fake.invokes.map((e) => e.method).toList(),
          ['stop', 'guard', 'guard', 'powerMode']);
      expect(fake.invokes[1].args, {'enabled': true, 'micGranted': true});
      expect(fake.invokes[2].args, {'enabled': false},
          reason: '未授权结论不得混入 micGranted 键（区分"未问"与"拒绝"）');
      expect(fake.invokes[3].args, {'mode': 'saver'});
    });

    test('BGS09 stopVibrate：先转交引擎，再兜底直调原生 cancel', () async {
      await mgr.stopVibrate(reason: '测试停');
      expect(fake.invokes.singleWhere((e) => e.method == 'vibrateStop').args,
          {'reason': '测试停'});
      expect(nativeLog.map((c) => c.method), contains('vibrateStop'),
          reason: '引擎没跑时第 1 步发向不存在的服务；原生 cancel 必须兜底');
    });

    test('BGS10 start：默认走平台 startService；注入 startHook 则短路', () async {
      expect(await mgr.start(), isTrue);
      expect(fake.started, isTrue);

      BackgroundServiceManager.startHook = () async => false;
      expect(await mgr.start(), isFalse, reason: 'hook 结果原样返回');
      expect(fake.invokes.where((e) => e.method == 'start'), isEmpty);
    });

    test('BGS11 replan：默认走 invoke；注入 replanHook 则短路', () async {
      await mgr.replan();
      expect(fake.invokes.map((e) => e.method), contains('replan'));

      BackgroundServiceManager.replanHook = () async {};
      fake.invokes.clear();
      await mgr.replan();
      expect(fake.invokes.where((e) => e.method == 'replan'), isEmpty);
    });

    test('BGS12 waitForGuardActive：已处于期望态 → 立即 true', () async {
      BackgroundServiceManager.lastForTest =
          const EngineState(running: true, pendingCount: 0, guardActive: true);
      expect(await mgr.waitForGuardActive(true), isTrue);
    });

    test('BGS13 waitForGuardActive：流上等到期望态 → true', () async {
      final ctrl = StreamController<EngineState>.broadcast();
      // 静态成员不能用级联设在类名上（级联目标是 Type 对象）。
      BackgroundServiceManager.lastForTest =
          const EngineState(running: true, pendingCount: 0);
      BackgroundServiceManager.stateForTest = ctrl.stream;
      final future = mgr.waitForGuardActive(true);
      ctrl.add(const EngineState(running: true, pendingCount: 0, guardActive: true));
      expect(await future, isTrue);
      await ctrl.close();
    });

    test('BGS14 waitForGuardActive：引擎明确报出启动失败 → 不白等，立刻 false',
        () async {
      final ctrl = StreamController<EngineState>.broadcast();
      // 静态成员不能用级联设在类名上（级联目标是 Type 对象）。
      BackgroundServiceManager.lastForTest =
          const EngineState(running: true, pendingCount: 0);
      BackgroundServiceManager.stateForTest = ctrl.stream;
      final future = mgr.waitForGuardActive(true);
      ctrl.add(const EngineState(
          running: true, pendingCount: 0, guardError: '麦克风启动失败'));
      expect(await future, isFalse, reason: 'guardError 存在时不可能再等到 true');
      await ctrl.close();
    });

    test('BGS15 waitForGuardActive：状态不匹配且无报错 → 继续等到超时', () async {
      final ctrl = StreamController<EngineState>.broadcast();
      // 静态成员不能用级联设在类名上（级联目标是 Type 对象）。
      BackgroundServiceManager.lastForTest =
          const EngineState(running: true, pendingCount: 0);
      BackgroundServiceManager.stateForTest = ctrl.stream;
      final future = mgr.waitForGuardActive(true, timeout: const Duration(milliseconds: 80));
      ctrl.add(const EngineState(running: true, pendingCount: 0));
      expect(await future, isFalse);
      await ctrl.close();
    });
  });

  // ============================================================
  // 5. playback_service —— 焦点决策纯函数 + 宿主可达的错误/停止路径
  // ============================================================
  group('PB · PlaybackService', () {
    test('PB01 focusGainFor：alarm → gain（抢占式，闹钟必须被听见）', () {
      expect(PlaybackService.focusGainFor(AudioChannel.alarm),
          same(AndroidAudioFocusGainType.gain));
    });

    test('PB02 focusGainFor：media → mayDuck（闪避而非打断他人音乐）', () {
      // 变异证伪：若有人改回 gain，此断言立刻红。
      expect(PlaybackService.focusGainFor(AudioChannel.media),
          same(AndroidAudioFocusGainType.gainTransientMayDuck));
    });

    test('PB03 PlayResult 默认值', () {
      const r = PlayResult(ok: true);
      expect(r.playedMs, 0);
      expect(r.message, isNull);
      expect(const PlayResult(ok: false, message: 'x').message, 'x');
    });

    test('PB04 SoundscapeTrackInput 默认音量 0.6 / 循环开', () {
      const t = SoundscapeTrackInput(path: 'a.mp3');
      expect(t.volume, 0.6);
      expect(t.loop, isTrue);
      const t2 = SoundscapeTrackInput(path: 'b.mp3', volume: 0.1, loop: false);
      expect(t2.volume, 0.1);
      expect(t2.loop, isFalse);
    });

    test('PB05 playSoundscape：空轨道 → 直接失败（不碰任何插件）', () async {
      final r = await PlaybackService().playSoundscape(
          tracks: const [], durationMs: 1000, channel: AudioChannel.media);
      expect(r.ok, isFalse);
      expect(r.message, '声景无轨道');
      expect(r.playedMs, 0);
    });

    // ============================================================
    // PB06–PB08：登记表（`_playing`）的行为锁 —— 第 34 轮因缺少复位缝被删，
    // 本轮补上 `PlaybackService.resetRegistryForTest()` 后以行为锁回归
    // （登记于 docs/17 §61.5-3）。
    //
    // ⚠️ 三条用例的**共同前提**：`_playing` 是**静态**表，跨用例存活。
    // 每条用例开头先 `resetRegistryForTest()`，并在 `addTearDown` 再复位一次
    // —— 否则一条用例留下的实例会让下一条的计数虚高（第 34 轮实测形状：
    // PB07 期望 1 实得 2、PB08 期望 0 实得 2）。
    //
    // ⚠️ 宿主上 `play()` 的真实形状（**逐行核对 pub 缓存源码得出，非推测**）：
    // `AudioSession.instance`（audio_session `core.dart:26-45`）与
    // `session.configure`（同文件 `:201-214`）**都吞掉** MissingPluginException，
    // 于是必然走到 `player.setFilePath` → just_audio `load()`
    // → `_setPlatformActive(true)`；而 `_setPlatformActive` 在
    // `_pluginPlatform.init(...)`（just_audio.dart:1425）**抛出之前**就把
    // 该调用交给了 `_platform`（同文件 `:1548`），异常逃逸出 `setPlatform()`、
    // `durationCompleter`（`:1313`）**永不完成** ⇒ **`play()` 在宿主上挂起，
    // 不返回**（并伴随 just_audio 内部的未处理异步错误）。
    // 这正是第 34 轮"MissingPluginException + 30s 超时"的成因
    // （`package:test` 默认单测超时 30s）。
    //
    // 所以本组用例**只锁 `play()` 的同步部分** —— 登记发生在第一个 await
    // 之前（playback_service.dart:119 早于 :124 的 `await AudioSession.instance`），
    // 因此**不 await `play()` 的返回**，并用 `_quarantine` 把"宿主没有插件
    // 实现"这类环境错误挡在测试框架的错误通道之外（否则它会以
    // "未处理异步错误"的形式把用例判红，而它与被测行为无关）。
    // `play()` 收尾的 `finally`（:173）在宿主上**不可观测**，已登记为诚实边界
    // （`_pt/audit/C1-cov-restore.md` §5）。
    // ============================================================

    test('PB06 play 的登记必须同步发生（远程「停止指令组」据此掐断起播中的声音）',
        () async {
      PlaybackService.resetRegistryForTest();
      addTearDown(PlaybackService.resetRegistryForTest);
      final svc = PlaybackService();

      // 反面样本：空表 ⇒ 0。证明下面那个 1 来自真实登记，而不是常数。
      expect(await PlaybackService.stopAllPlaying(), 0,
          reason: '复位后无在播实例');

      // **刻意不 await**：只让 `play()` 跑到第一个 await 为止。
      // 宿主上没有插件实现，await 下去会挂起（见上方段落注释）。
      _quarantine(() {
        unawaited(svc.play(
            path: 'cov_pb06_not_a_real_file.mp3',
            channel: AudioChannel.media,
            volume: 0.5,
            maxDurationMs: 40));
      });

      // 锁：登记必须发生在 `play()` 的第一个 await **之前**
      // （playback_service.dart:119 早于 :124 的 `await AudioSession.instance`）。
      // 远程「停止指令组」拿不到实例引用，只能靠"实例一开播就在表里"才能掐断
      // 它 —— 把 `_playing.add(this)` 挪到任何一个 await 之后，这条立刻红。
      expect(await PlaybackService.stopAllPlaying(), 1,
          reason: '开播的实例必须**同步**进登记表，否则远程停止找不到它');

      // 复位缝：清表后必须回落（否则跨用例计数虚高，PB07 的 2 会变成 3）。
      PlaybackService.resetRegistryForTest();
      expect(await PlaybackService.stopAllPlaying(), 0,
          reason: 'resetRegistryForTest 必须清空登记表');
    });

    test('PB07 stopAllPlaying：逐个实例调 stop()，返回值 = 在播实例数', () async {
      PlaybackService.resetRegistryForTest();
      addTearDown(PlaybackService.resetRegistryForTest);

      // 反面样本：空表 ⇒ 0 次 stop、返回 0（证明计数与 stop 调用都不是常数）。
      expect(await PlaybackService.stopAllPlaying(), 0,
          reason: '复位后无在播实例');

      final a = _StopCountingPlayer();
      final b = _StopCountingPlayer();
      // 同上：不 await，只取 `play()` 的同步登记副作用。
      _quarantine(() {
        unawaited(a.play(
            path: 'cov_pb07_a.mp3',
            channel: AudioChannel.media,
            volume: 0.5,
            maxDurationMs: 40));
        unawaited(b.play(
            path: 'cov_pb07_b.mp3',
            channel: AudioChannel.media,
            volume: 0.5,
            maxDurationMs: 40));
      });

      expect(await PlaybackService.stopAllPlaying(), 2,
          reason: '两个在播实例 ⇒ 返回 2（不是"表里恰好有一个"的常数）');
      // 锁：`stopAllPlaying` 必须**逐个**调用 `p.stop()`（playback_service.dart:79-81）。
      // 只返回数字而不真的停，就是"回执说已静音、扬声器还在响"的谎报 ——
      // 这正是远程「停止指令组」唯一依赖的行为。
      expect(a.stops, 1, reason: '每个在播实例都必须收到 stop()');
      expect(b.stops, 1, reason: '每个在播实例都必须收到 stop()');

      // 反面样本（第二段）：复位后不得再触发 stop()，返回值必须回落。
      PlaybackService.resetRegistryForTest();
      expect(await PlaybackService.stopAllPlaying(), 0,
          reason: '登记表已空 ⇒ 0，且不得再调 stop()');
      expect(a.stops, 1, reason: '空表不得重复 stop（否则就是"停了个寂寞"的谎报）');
      expect(b.stops, 1, reason: '空表不得重复 stop');
    });

    test('PB08 stop/dispose：未播放过的实例必须无害（不抛、不污染登记表、可重复调）',
        () async {
      PlaybackService.resetRegistryForTest();
      addTearDown(PlaybackService.resetRegistryForTest);

      // 反面样本：先证明"表里有实例时计数为 1"，下面那个 0 才不是恒真。
      final probe = _StopCountingPlayer();
      _quarantine(() {
        unawaited(probe.play(
            path: 'cov_pb08_probe.mp3',
            channel: AudioChannel.media,
            volume: 0.5,
            maxDurationMs: 40));
      });
      expect(await PlaybackService.stopAllPlaying(), 1,
          reason: '反面样本：登记表非空时计数必须为 1（证明计数器是活的）');
      PlaybackService.resetRegistryForTest();

      // 被测对象：**从未播放过**的实例（`_player == null`，全程不碰插件）。
      // 锁：UI「挂断」与远程停止可能**同时**调 `stop()`，`dispose()` 也可能被
      // 重复触发（页面重建）。这两条路径都不允许抛，也不允许把实例塞回登记表
      // —— 否则每次挂断都会"凭空多出一个正在播的声音"。
      final ghost = PlaybackService();
      await ghost.stop();
      await ghost.stop();
      await ghost.dispose();
      await ghost.dispose();

      expect(await PlaybackService.stopAllPlaying(), 0,
          reason: 'stop/dispose 不得产生新的在播登记');
    });
  });
}

/// 在**隔离 zone** 里执行 [body]，吞掉"宿主没有 just_audio/audio_session
/// 平台实现"所产生的那一类**未处理异步错误**。
///
/// ## 为什么需要它
///
/// 宿主上 `AudioPlayer` 一碰插件就会在 just_audio 内部留下两个**没人接的**
/// 错误 future（`_pluginPlatform` getter 里未 await 的 `disposeAllPlayers`，
/// 以及 `_setPlatformActive` 交给 `_platform` 的那个 init 失败 future）。
/// `package:test` 把测试体跑在带 `handleUncaughtError` 的 zone 里 ⇒ 这两个
/// 错误会以"未处理异步错误"的形式把用例判红，而它们**与被测行为无关**
/// （只是宿主没有音频插件）。
///
/// ## 边界（刻意收窄）
///
/// 只包住 `play()` 的**调用**，不包 `expect` —— 断言仍在测试自己的 zone 里
/// 求值，所以隔离不会掩盖任何真实的断言失败。
void _quarantine(void Function() body) {
  runZonedGuarded<void>(body, (e, st) {});
}

/// 记录 `stop()` 被调用次数的播放器替身。
///
/// 用 `extends` 而不是 `implements`：`PlaybackService` 还有
/// `playSoundscape` / `stopSoundscape` 等成员，`extends` 只需覆写要观测的
/// 那一个（与 `test/sound_library_screen_test.dart:170` 的 `_FakePlayer` 同款，
/// 也不会因为基类新增方法而编译报错）。
///
/// 覆写 `stop()` 只计数、不碰 `_player`：`stopAllPlaying` 走的是动态派发，
/// 因此"每个在播实例都收到 stop()"这条判据可以在**不依赖任何插件**的前提下断言。
class _StopCountingPlayer extends PlaybackService {
  int stops = 0;

  @override
  Future<void> stop() async => stops++;
}

/// 可编程电池平台（battery_plus 6.x 平台接口整体替换）。
class _FakeBatteryPlatform extends BatteryPlatform {
  int level = 100;
  BatteryState state = BatteryState.full;
  bool fail = false;
  int levelReads = 0;

  @override
  Future<int> get batteryLevel async {
    levelReads++;
    if (fail) throw MissingPluginException('无电池（桌面/测试）');
    return level;
  }

  @override
  Future<BatteryState> get batteryState async {
    if (fail) throw MissingPluginException('无电池（桌面/测试）');
    return state;
  }

  @override
  Future<bool> get isInBatterySaveMode async => false;

  @override
  Stream<BatteryState> get onBatteryStateChanged => const Stream.empty();
}

/// flutter_background_service 平台接口整体替换：
/// 记录 configure 配置与全部 invoke，可编程回投 on() 流。
class _FakeBgsPlatform extends FlutterBackgroundServicePlatform {
  AndroidConfiguration? androidCfg;
  IosConfiguration? iosCfg;
  bool started = false;
  final invokes = <({String method, Map<String, dynamic>? args})>[];
  final _ctrls = <String, StreamController<Map<String, dynamic>?>>{};

  void emit(String method, Map<String, dynamic>? msg) =>
      _ctrls
          .putIfAbsent(method,
              () => StreamController<Map<String, dynamic>?>.broadcast())
          .add(msg);

  @override
  Future<bool> configure({
    required IosConfiguration iosConfiguration,
    required AndroidConfiguration androidConfiguration,
  }) async {
    iosCfg = iosConfiguration;
    androidCfg = androidConfiguration;
    return true;
  }

  @override
  Future<bool> start() async {
    started = true;
    return true;
  }

  @override
  Future<bool> isServiceRunning() async => started;

  @override
  void invoke(String method, [Map<String, dynamic>? args]) =>
      invokes.add((method: method, args: args));

  @override
  Stream<Map<String, dynamic>?> on(String method) =>
      _ctrls
          .putIfAbsent(method,
              () => StreamController<Map<String, dynamic>?>.broadcast())
          .stream;
}
