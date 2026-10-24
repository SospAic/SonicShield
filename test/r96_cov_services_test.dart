/// R96 覆盖率补测（服务层六文件）。
///
/// 目标：把 `lib/services` 下六个文件里**剩下未被门禁覆盖**的分支补齐 ——
/// 平台通道错误/降级路径、播放优先级仲裁、后台服务初始化失败与调用失败、
/// 振动被系统吞掉的早退、保留策略的单步失败隔离、以及反击动作的两个构造函数。
///
/// ## 纪律
/// * 平台通道一律 `setMockMethodCallHandler` 打桩，`tearDown` **必须**还原；
/// * just_audio / 振动能力 / 电量 全部用替身或构造注入，不建真连接；
/// * 不依赖墙钟：超时分支由「通道直接抛 TimeoutException」触发，
///   而不是真等 70s / 45s；
/// * 数据库用内存库（本文件内只开一次），`AppDatabase.open` 已带
///   `singleInstance: false`。
library;

import 'dart:async';

// ignore: depend_on_referenced_packages -- flutter_test 的传递依赖，快进 70s 定时器必须用它
import 'package:fake_async/fake_async.dart';
// ignore: depend_on_referenced_packages -- flutter_background_service 的传递依赖，打桩必须用它
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/domain/scheduling/vibrate_resolve.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/native_bridge.dart';
import 'package:sonic_shield/services/playback_service.dart';
import 'package:sonic_shield/services/reactive_counter_service.dart';
import 'package:sonic_shield/services/retention_maintenance.dart';
import 'package:sonic_shield/services/vibrate_session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/just_audio_stub.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

const _nativeChannel = MethodChannel('sonic_shield/native');
const _castChannel = MethodChannel('sonic_shield/screencast');

/// 记录原生通道收到的调用，并按 [fn] 回值。
List<MethodCall> _installNative(Object? Function(MethodCall call) fn) {
  final log = <MethodCall>[];
  _messenger.setMockMethodCallHandler(_nativeChannel, (call) async {
    log.add(call);
    return fn(call);
  });
  return log;
}

/// `flutter_background_service` 平台替身：记录 configure 配置与全部 invoke，
/// 可按需让 `configure` / `invoke` 失败（驱动失败分支）。
class _FakeBgsPlatform extends FlutterBackgroundServicePlatform {
  AndroidConfiguration? androidCfg;
  IosConfiguration? iosCfg;

  /// 非 null 时 `configure` 抛它（模拟初始化失败）。
  Object? configureError;

  /// 非 null 时 `invoke` 同步抛它（模拟"服务已死但 isRunning 仍为 true"）。
  Object? invokeError;

  final invokes = <({String method, Map<String, dynamic>? args})>[];
  final _ctrls = <String, StreamController<Map<String, dynamic>?>>{};

  @override
  Future<bool> configure({
    required IosConfiguration iosConfiguration,
    required AndroidConfiguration androidConfiguration,
  }) async {
    final err = configureError;
    if (err != null) throw err;
    iosCfg = iosConfiguration;
    androidCfg = androidConfiguration;
    return true;
  }

  @override
  Future<bool> start() async => true;

  @override
  Future<bool> isServiceRunning() async => false;

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    final err = invokeError;
    if (err != null) throw err;
    invokes.add((method: method, args: args));
  }

  @override
  Stream<Map<String, dynamic>?> on(String method) => _ctrls
      .putIfAbsent(
          method, () => StreamController<Map<String, dynamic>?>.broadcast())
      .stream;
}

/// `ServiceInstance` 的最小实现（iOS `onBackground` 回调只忽略参数）。
class _FakeServiceInstance implements ServiceInstance {
  @override
  void invoke(String method, [Map<String, dynamic>? args]) {}

  @override
  Stream<Map<String, dynamic>?> on(String method) =>
      const Stream<Map<String, dynamic>?>.empty();

  @override
  Future<void> stopSelf() async {}
}

/// 清理必失败的日志仓储（驱动保留策略的 `onError` 分支）。
class _ThrowingLogs extends LogRepository {
  // 父类的位置参数名是私有的（`_db`），无法写成 super 参数，故显式转发。
  // ignore: use_super_parameters
  _ThrowingLogs(AppDatabase db) : super(db);

  @override
  Future<int> purgeOlderThan(DateTime t, {int batchLimit = 500}) async =>
      throw StateError('exec_logs 清理失败');
}

/// 清理必失败的计划仓储。
class _ThrowingOccurrences extends OccurrenceRepository {
  // 同上：父类位置参数私有，不能写成 super 参数。
  // ignore: use_super_parameters
  _ThrowingOccurrences(AppDatabase db) : super(db);

  @override
  Future<int> purgeOlderThan(DateTime t, {int batchLimit = 500}) async =>
      throw StateError('occurrences 清理失败');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  tearDown(() {
    _messenger.setMockMethodCallHandler(_nativeChannel, null);
    _messenger.setMockMethodCallHandler(_castChannel, null);
  });

  // ============================================================
  // 1. NativeBridge —— 直连方法 + 结构化回执 + 超时收口 + 错误解析
  // ============================================================
  group('COV-NB · NativeBridge 未覆盖分支', () {
    test('COV-01 releaseWakeLock / stopMicGuardService 必须真的打到原生通道',
        () async {
      final log = _installNative((c) => null);

      await NativeBridge.releaseWakeLock();
      await NativeBridge.stopMicGuardService();

      expect(log.map((c) => c.method).toList(),
          <String>['releaseWakeLock', 'stopMicGuardService'],
          reason: '方法名就是原生侧 when 的匹配键，拼错只会静默返回 null');
    });

    test('COV-02 isMicServiceRunning：原生回 true 采信，回 null 时 fail-closed',
        () async {
      _installNative((c) => true);
      expect(await NativeBridge.isMicServiceRunning(), isTrue);

      // 读不到（平台无此通道）⇒ 必须 false：拿不到通行证就不许采音。
      _installNative((c) => null);
      expect(await NativeBridge.isMicServiceRunning(), isFalse);
    });

    test('COV-03 alert：结构化回执按 ok 解析，失败原因留在 lastAlertReason',
        () async {
      _installNative((c) => <String, Object?>{
            'ok': true,
            'screen': true,
            'notification': true,
            'sound': true,
          });
      expect(await NativeBridge.alert(message: 'find me'), isTrue);
      expect(NativeBridge.lastAlertReason, isNull,
          reason: '成功必须清掉上一次的失败原因（不得残留）');

      _installNative((c) => <String, Object?>{
            'ok': false,
            'reason': 'notification_denied',
          });
      expect(await NativeBridge.alert(message: 'find me'), isFalse);
      expect(NativeBridge.lastAlertReason, 'notification_denied',
          reason: 'NAT-10：通知被拒必须可诊断，不能只回一个 false');
    });

    test('COV-04 screenCastStart：原生无回执 → 70s 兜底超时收口为 false', () {
      // ⚠️ 不能用"让 handler 抛 TimeoutException"来打这个分支：
      //    `TestDefaultBinaryMessenger.setMockMethodCallHandler` 会把**任何**
      //    非 PlatformException 的异常包装成 `PlatformException(code:'error')`
      //    （test_default_binary_messenger.dart:323-324），于是会落到
      //    `on PlatformException` 那一支，根本进不了 TimeoutException。
      //    这里改用**永不回执**的通道 + fakeAsync 把 70s 定时器快进掉 ——
      //    既不真等墙钟，走的又是生产里真正的那条超时路径。
      fakeAsync((async) {
        _messenger.setMockMethodCallHandler(
            _castChannel, (call) => Completer<Object?>().future);

        bool? result;
        unawaited(NativeBridge.screenCastStart().then((v) => result = v));

        async.elapse(const Duration(seconds: 71));
        async.flushMicrotasks();

        expect(result, isFalse,
            reason: '双侧超时都没兜住时按"未受理"收口，不许把异常挂到调用方');
      });
    });

    test('COV-05 AlarmScheduleResult.fromRaw：原生 PlatformException 分类',
        () {
      final unsupported = AlarmScheduleResult.fromRaw(
        null,
        expected: 3,
        nativeError: PlatformException(code: 'UNSUPPORTED', message: 'no api'),
      );
      expect(unsupported.unsupported, isTrue);
      expect(unsupported.nativeError, isNull,
          reason: 'UNSUPPORTED 是"平台不支持"，不是"原生失败"');
      expect(unsupported.scheduled, 0);

      final failed = AlarmScheduleResult.fromRaw(
        null,
        expected: 3,
        nativeError:
            PlatformException(code: 'SECURITY', message: 'alarm denied'),
      );
      expect(failed.unsupported, isFalse);
      expect(failed.nativeError, 'SECURITY: alarm denied',
          reason: '原生明确报错必须带上 code/message，供审计区分降级种类');
      expect(failed.expected, 3);
    });
  });

  // ============================================================
  // 2. PlaybackService —— ARCH-09 优先级仲裁
  // ============================================================
  group('COV-PB · PlaybackService 优先级仲裁', () {
    late FakeJustAudio audio;

    setUp(() {
      audio = FakeJustAudio(fileDuration: const Duration(seconds: 600));
      audio.install();
      PlaybackService.resetRegistryForTest();
      addTearDown(() {
        PlaybackService.resetRegistryForTest();
        audio.uninstall();
      });
    });

    const path = 'cov_r96_not_a_real_file.mp3';

    test('COV-06 低优先级向更高优先级让行：立刻返回失败且不出声', () async {
      // ⚠️ 仲裁台账（_soloPlayers/_soloPriority）是**实例级**的：
      //    两路播放必须落在同一个 PlaybackService 上，否则互相看不见。
      final svc = PlaybackService();
      // 不 await：`play()` 在第一个 await 之前就完成了登记（_soloPlayers /
      // _soloPriority），所以这里同步即可确定"已有一路在飞"。
      final highFut = svc.play(
        path: path,
        channel: AudioChannel.alarm,
        volume: 0.5,
        maxDurationMs: 60000,
        priority: PlayPriority.high,
      );

      // 等第一路**真的起播**再发第二路：登记虽是同步的，但"已起播"才是
      // 可观测的在飞证据（否则断言 `play` 次数会跟调度顺序赛跑）。
      while (audio.countOf('play') == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final low = await svc.play(
        path: path,
        channel: AudioChannel.media,
        volume: 0.5,
        maxDurationMs: 200,
        priority: PlayPriority.normal,
      );

      expect(low.ok, isFalse);
      expect(low.message, contains('让行'),
          reason: '仲裁发生在起播之前 ⇒ 让行方根本不该出声');
      expect(audio.countOf('play'), 1,
          reason: '让行方不得起播（只有高优先级那一路 play 过）');

      await svc.stop();
      await highFut;
    });

    test('COV-07 高优先级抢占在飞的低优先级：被抢占方如实报失败', () async {
      final svc = PlaybackService();
      final lowFut = svc.play(
        path: path,
        channel: AudioChannel.media,
        volume: 0.5,
        maxDurationMs: 60000,
        priority: PlayPriority.normal,
      );

      final high = await svc.play(
        path: path,
        channel: AudioChannel.alarm,
        volume: 0.9,
        maxDurationMs: 120,
        priority: PlayPriority.high,
      );
      expect(high.ok, isTrue, reason: '抢占方自己正常播完');

      final low = await lowFut;
      expect(low.ok, isFalse);
      expect(low.message, contains('抢占'),
          reason: '被掐掉的那一路必须报失败：报 success 会让排障者以为它播完了');
      expect(low.playedMs, lessThan(60000),
          reason: '抢占必须在下一个 tick（≤50ms）生效，不许等满窗口');
    });

    test('COV-08 扩展方法 stopSoundscape 置位停止标志', () {
      final svc = PlaybackService();
      // 实例成员同名且遮蔽扩展成员 ⇒ 必须显式走扩展调用才能覆盖到这一行。
      expect(() => PlaybackSoundscape(svc).stopSoundscape(), returnsNormally);
    });
  });

  // ============================================================
  // 3. BackgroundServiceManager —— 初始化/调用失败与配置回调
  // ============================================================
  group('COV-BGS · BackgroundServiceManager 未覆盖分支', () {
    final fake = _FakeBgsPlatform();
    final mgr = BackgroundServiceManager.instance;

    setUpAll(() async {
      FlutterBackgroundServicePlatform.instance = fake;
      _installNative((c) => null);
      await mgr.init();
    });

    tearDownAll(() {
      BackgroundServiceManager.lastForTest = null;
      BackgroundServiceManager.invokeHook = null;
      BackgroundServiceManager.startHook = null;
    });

    setUp(() {
      fake.invokeError = null;
      fake.configureError = null;
      fake.invokes.clear();
      BackgroundServiceManager.lastForTest = null;
    });

    test('COV-09 init 失败：原因留痕（initError）后原样 rethrow', () async {
      fake.configureError = StateError('configure 炸了');
      await expectLater(mgr.init(), throwsA(isA<StateError>()));
      expect(mgr.initError, contains('configure 炸了'),
          reason: 'R89：降级 catch 之后必须有人知道后台服务其实没配好');

      // 复原：重新配置成功 ⇒ 错误必须清空（不得残留上一次的失败）。
      fake.configureError = null;
      await mgr.init();
      expect(mgr.initError, isNull);
    });

    test('COV-10 setPowerMode：未知档位回落 balanced，且两步都执行', () async {
      final log = _installNative((c) => null);

      await mgr.setPowerMode('no_such_mode');

      expect(fake.invokes.map((e) => e.method), contains('powerMode'));
      final powerInvoke =
          fake.invokes.lastWhere((e) => e.method == 'powerMode');
      expect(powerInvoke.args!['mode'], 'no_such_mode',
          reason: '引擎侧收到的仍是原始串（解析只用于原生唤醒锁分级）');
      final nativeCall = log.singleWhere((c) => c.method == 'setPowerMode');
      expect(nativeCall.arguments['mode'], 'balanced',
          reason: '未知档位必须回落 balanced（orElse 分支），不能崩');
    });

    test('COV-11 runNow：invoke 同步抛 → 返回失败并摘表（不泄漏 completer）',
        () async {
      BackgroundServiceManager.lastForTest =
          const EngineState(running: true, pendingCount: 0);
      fake.invokeError = UnsupportedError('服务已死');

      final r = await mgr.runNow('task-x');

      expect(r.ok, isFalse);
      expect(r.message, contains('引擎调用失败'),
          reason: 'BUG-097：invoke 同步抛必须收口成失败回执，不许穿透成未捕获异步错误');
    });

    test('COV-12 iOS onBackground 回调：后台无 UI 隔离，直接返回 true', () async {
      final cb = fake.iosCfg!.onBackground;
      expect(cb, isNotNull);
      expect(await cb!(_FakeServiceInstance()), isTrue);
    });
  });

  // ============================================================
  // 4. VibrateSession —— 静音/勿扰 + 跟随勿扰 ⇒ 不下发、不记 success
  // ============================================================
  group('COV-VS · VibrateSession 被系统吞掉的早退', () {
    late AppDatabase appDb;
    late LogRepository logs;

    setUp(() async {
      appDb = await AppDatabase.open(inMemoryDatabasePath);
      logs = LogRepository(appDb);
    });

    tearDown(() async {
      await appDb.close();
    });

    test('COV-13 静音 + respectDnd ⇒ 不下发、审计 failed、返回 false', () async {
      final sent = <VibrateCommand>[];
      final session = VibrateSession(
        logs: logs,
        capsProbe: () async => const VibrateCaps(
          hasVibrator: true,
          hasAmplitudeControl: true,
          hasEnvelope: true,
          minControlPointMs: 20,
          platform: 'android',
          ringerMode: RingerMode.silent,
        ),
        send: (cmd) async {
          sent.add(cmd);
          return true;
        },
        stopNative: () async {},
        battery: () async => (level: 90, charging: false),
        now: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
        tick: const Duration(hours: 1),
      );

      final ok = await session.start(
        occurrenceId: 'cov-r96-occ',
        taskId: 'cov-r96-task',
        action: const ContinuousVibrateAction(
          durationSecMin: 60,
          durationSecMax: 60,
          amplitudeMin: 0.5,
          amplitudeMax: 0.5,
          respectDnd: true,
        ),
        durationMs: 60000,
        amplitude: 0.5,
        source: 'cov-r96',
      );

      expect(ok, isFalse, reason: 'NAT-06：不能震就绝不记 success');
      expect(sent, isEmpty, reason: '识别出必被吞就根本不下发');
      final rows = await logs.recent();
      expect(rows.first['status'], 'failed');
      final msg = rows.first['message'] as String;
      expect(msg, contains('静音'));
      expect(msg, contains('未下发'));
      expect(msg, contains('跟随勿扰'),
          reason: 'R93：系统状态必须进同一条审计行，否则"调用成功却没震"无法解释');
    });
  });

  // ============================================================
  // 5. RetentionMaintenance —— 两步 purge 互相隔离（R90-23）
  // ============================================================
  group('COV-RT · RetentionMaintenance 单步失败隔离', () {
    late AppDatabase appDb;

    setUp(() async {
      appDb = await AppDatabase.open(inMemoryDatabasePath);
    });

    tearDown(() async {
      await appDb.close();
    });

    test('COV-14 两步都失败：各自上报 onError，run 仍正常返回', () async {
      final errors = <Object>[];
      final m = RetentionMaintenance(
        logs: _ThrowingLogs(appDb),
        occurrences: _ThrowingOccurrences(appDb),
        onError: errors.add,
      );

      final outcome = await m.run();

      expect(outcome.logsRemoved, 0);
      expect(outcome.occurrencesRemoved, 0);
      expect(outcome.total, 0);
      expect(errors.length, 2,
          reason: 'R90-23：exec_logs 失败不得阻断 occurrences 清理，两步各自留痕');
      expect(errors[0], isA<StateError>());
      expect(errors[1], isA<StateError>());
    });
  });

  // ============================================================
  // 6. CounterAction —— 两个具名构造函数
  // ============================================================
  group('COV-RC · CounterAction 构造', () {
    test('COV-15 audio / tts 两个构造函数的字段投影', () {
      // ⚠️ 刻意不用 `const`：const 调用在编译期折叠，构造函数的可执行行
      //    不会被运行时覆盖率命中（本用例的目的正是覆盖那两行）。
      // ignore: prefer_const_constructors
      final a = CounterAction.audio('annoy_spit.wav');
      expect(a.audioPath, 'annoy_spit.wav');
      expect(a.text, isEmpty);
      expect(a.voiceId, isEmpty);
      expect(a.isTts, isFalse);

      // ignore: prefer_const_constructors
      final t = CounterAction.tts('请保持安静', voiceId: 'v1');
      expect(t.text, '请保持安静');
      expect(t.voiceId, 'v1');
      expect(t.audioPath, isEmpty);
      expect(t.isTts, isTrue);
    });
  });
}
