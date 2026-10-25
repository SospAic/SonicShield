// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/domain/scheduling/vibrate_resolve.dart';
import 'package:sonic_shield/services/sound_guard_service.dart';
import 'package:sonic_shield/services/vibrate_session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/source_text.dart';

/// 第九十五轮（R97）· **R88 审计遗留的 4 条引擎侧缺陷**回归锁。
///
/// 这四条来自 `_pt/audit/r88_bugscan_remote_services.md`（R88 只读审查），
/// 当时**只登记不修**。本轮全部修掉，并用**行为锁**（不是源码文本锁）钉住：
///
/// - `R97-VS-*`：`R88-AUD-01` —— `vibrate.stop` 落在 `vibrate.start()` 的平台
///   `await` 窗口内会被吞掉：审计说「没有进行中的振动」，随后振动**照常开始**
///   ⇒ 用户点了「停止」，振动才刚刚开始（S3「任何时刻都能停」被击穿）。
/// - `R97-SG-*`：`R88-AUD-03`（服务侧）—— 守卫「开 → 关」快速切换时，
///   关闭那一支在取流窗口内是**空操作**，开启那一支恢复后把 `_running` 置回
///   true ⇒ 麦克风继续采、`onSoundEvent` 继续被调用。
/// - `R97-EN-*`：`R88-AUD-02 / 03（引擎侧）/ 07` —— 停机链不 dispose 振动会话 /
///   守卫命令无串行化 / `guardError` 在 await 之后才更新（窗口内广播带旧错误，
///   UI 立刻判「启动失败」）。
/// - `R97-SM-01`：`background_service_manager` 的 `on Object` 兜底分支是**死代码**
///   （全仓无 `completeError` 调用点），本轮改为 `finally` 统一摘表。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase appDb;
  late LogRepository logs;

  setUp(() async {
    appDb = await AppDatabase.open(inMemoryDatabasePath);
    logs = LogRepository(appDb);
  });

  tearDown(() async {
    await appDb.close();
  });

  const continuous = ContinuousVibrateAction(
    durationSecMin: 60,
    durationSecMax: 60,
    amplitudeMin: 0.5,
    amplitudeMax: 0.5,
  );

  // ═══════════════════════════════════════════════════════════════
  // R88-AUD-01：停止请求落在启动窗口内
  // ═══════════════════════════════════════════════════════════════

  group('R88-AUD-01 停止代次闸门', () {
    /// 可把 `battery()` 卡住的会话（`battery` 是下发首片前的**最后一处**平台往返）。
    ({
      VibrateSession session,
      List<VibrateCommand> sent,
      List<String> stops,
      Completer<void> reachedBattery,
      Completer<void> batteryGate,
      void Function(Duration) advance,
    }) buildBlockingBattery() {
      final sent = <VibrateCommand>[];
      final stops = <String>[];
      final reachedBattery = Completer<void>();
      final batteryGate = Completer<void>();
      var clock = DateTime.fromMillisecondsSinceEpoch(1700000000000);

      final s = VibrateSession(
        logs: logs,
        capsProbe: () async => const VibrateCaps(
          hasVibrator: true,
          hasAmplitudeControl: true,
          hasEnvelope: true,
          minControlPointMs: 20,
          platform: 'android',
        ),
        send: (cmd) async {
          sent.add(cmd);
          return true;
        },
        stopNative: () async => stops.add('cancel'),
        battery: () async {
          if (!reachedBattery.isCompleted) reachedBattery.complete();
          await batteryGate.future;
          return (level: 90, charging: false);
        },
        kvGet: (k) async => null,
        kvSet: (k, v) async {},
        now: () => clock,
        // 真实定时器远大于用例时长：续发由测试显式驱动，不依赖墙钟。
        tick: const Duration(hours: 1),
      );
      return (
        session: s,
        sent: sent,
        stops: stops,
        reachedBattery: reachedBattery,
        batteryGate: batteryGate,
        advance: (d) => clock = clock.add(d),
      );
    }

    test('R97-VS-01 ★ 启动停在 battery 窗口时收到 stopAll ⇒ 不下发任何振动', () async {
      final h = buildBlockingBattery();

      // 启动：会停在 battery() 的 await 里（此时 _active 还是空的）。
      final pending = h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: continuous,
        durationMs: 60000,
        amplitude: 0.5,
        source: 'test',
      );

      await h.reachedBattery.future;
      // 🔴 缺陷现场：这一刻 _active 为空 ⇒ 旧实现的 stopAll 认为「没有进行中的振动」。
      expect(h.session.activeCount, 0, reason: '前置自证：停止确实落在「还没进活跃表」的窗口内');

      await h.session.stopAll(reason: '远程停止');
      h.batteryGate.complete();

      final ok = await pending;
      expect(ok, isFalse, reason: '启动途中已被停止 ⇒ 必须返回 false（没有真的振起来）');
      expect(h.sent, isEmpty,
          reason: '★ 缺陷核心：旧实现会在这里照常下发首片 ⇒「点了停，振动才开始」');
      expect(h.session.activeCount, 0);

      final rows = await logs.recent();
      final cancelled = rows.where(
          (r) => (r['message'] as String? ?? '').contains('启动过程中收到停止请求'));
      expect(cancelled, isNotEmpty,
          reason: '必须如实留痕（静默取消 = 用户与日志都看不出「点了停但没停」）');
      expect(cancelled.first['status'], 'skipped');
    });

    test('R97-VS-02 无停止请求时窗口正常通过（判据非恒真）', () async {
      final h = buildBlockingBattery();
      final pending = h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: continuous,
        durationMs: 60000,
        amplitude: 0.5,
        source: 'test',
      );
      await h.reachedBattery.future;
      h.batteryGate.complete();

      final ok = await pending;
      expect(ok, isTrue, reason: '没有停止请求时必须正常振起来（否则闸门变成「永远不震」）');
      expect(h.sent, isNotEmpty);
      expect(h.session.activeCount, 1);
    });

    test('R97-VS-03 ★ _pump 快照过期 ⇒ 不得删掉「已接管」的新会话', () async {
      final sent = <VibrateCommand>[];
      final stops = <String>[];
      final pumpGate = Completer<void>();
      var batteryCalls = 0;
      var clock = DateTime.fromMillisecondsSinceEpoch(1700000000000);

      final s = VibrateSession(
        logs: logs,
        capsProbe: () async => const VibrateCaps(
          hasVibrator: true,
          hasAmplitudeControl: true,
          hasEnvelope: true,
          minControlPointMs: 20,
          platform: 'android',
        ),
        send: (cmd) async {
          sent.add(cmd);
          return true;
        },
        stopNative: () async => stops.add('cancel'),
        battery: () async {
          batteryCalls++;
          // 第 1 次 = start(A)；第 2 次 = _pump（卡住）；第 3 次 = start(B)。
          if (batteryCalls == 2) await pumpGate.future;
          return (level: 90, charging: false);
        },
        kvGet: (k) async => null,
        kvSet: (k, v) async {},
        now: () => clock,
        tick: const Duration(hours: 1),
      );

      // A 进表。
      expect(
          await s.start(
              occurrenceId: 'o1',
              taskId: 't1',
              action: continuous,
              durationMs: 60000,
              amplitude: 0.5,
              source: 'test'),
          isTrue);
      expect(s.activeCount, 1);

      // `_pump()` 取到 [A] 快照后卡在 battery()。
      final pumping = s.pump();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // 窗口内：同 id 新会话 B 接管（BUG-126 的重入场景）。
      expect(
          await s.start(
              occurrenceId: 'o1',
              taskId: 't1',
              action: continuous,
              durationMs: 60000,
              amplitude: 0.5,
              source: 'test'),
          isTrue);

      // 把时钟推过 A 的 totalMs：旧实现会据此把 **B** 当成「A 完成了」删掉。
      clock = clock.add(const Duration(minutes: 2));
      pumpGate.complete();
      await pumping;

      expect(s.activeCount, 1,
          reason: '★ 缺陷核心：旧实现按 id 删表 ⇒ 被删掉的是刚接管的新会话 B');
      expect(s.activeIds, contains('o1'));
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // R88-AUD-03（服务侧）：守卫「开 → 关」竞态
  // ═══════════════════════════════════════════════════════════════

  group('R88-AUD-03 守卫启停竞态（服务侧）', () {
    test('R97-SG-01 ★ 取流窗口内收到 stop ⇒ 不置「运行中」并释放录音器', () async {
      final rec = _GatedRecorder();
      final svc = SoundGuardService(recorder: rec);

      final starting = svc.start(const SoundTrigger());
      await rec.reachedStream.future;
      expect(svc.isRunning, isFalse, reason: '前置自证：此刻还没拿到流');

      // 用户在窗口内把开关关掉。
      await svc.stop();
      rec.releaseStream();
      final r = await starting;

      expect(r.ok, isFalse, reason: '启动完成时已被关闭 ⇒ 必须如实失败，不许自称成功');
      expect(svc.isRunning, isFalse,
          reason: '★ 缺陷核心：旧实现无条件置 _running=true ⇒「关了还在采」');
      expect(rec.stopCalls, greaterThanOrEqualTo(1),
          reason: '刚拿到的流必须立刻释放（否则原生录音器一直采）');
      expect(r.message, contains('已被关闭请求取消'));
    });

    test('R97-SG-02 无并发停止时正常启动（判据非恒真）', () async {
      final rec = _GatedRecorder();
      final svc = SoundGuardService(recorder: rec);

      final starting = svc.start(const SoundTrigger());
      await rec.reachedStream.future;
      rec.releaseStream();
      final r = await starting;

      expect(r.ok, isTrue);
      expect(svc.isRunning, isTrue);
      await svc.stop();
      expect(svc.isRunning, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 引擎侧：AUD-02 / AUD-03 / AUD-07（源码契约锁）
  //
  // 为什么用源码锁而不是行为锁：这三处都在 `background_engine` 的
  // isolate 装配闭包里（`service.on('stop')` / `applyGuardEnabled`），
  // 宿主上要驱动它必须伪造整个 `BackgroundService`，成本远高于收益。
  // 判据本身是**结构性的**（顺序 / 存在性），源码锁是恰当粒度。
  // ⚠️ 锁的签名片段刻意避开注释（`stripComments` 先剥），避免自我中毒。
  // ═══════════════════════════════════════════════════════════════

  group('R88-AUD-02 / 03 / 07 引擎侧契约', () {
    final engine = stripComments(
        File('lib/services/background_engine.dart').readAsStringSync());

    test('R97-EN-01 ★ 停机链必须 dispose 振动会话（AUD-02：dispose 曾是死代码）', () {
      // 不用 `methodBody`：本文件里有**两处** `on('stop')` 监听器的签名同形，
      // `indexOf` 会命中先出现的那个。改为直接锚定「停机停振动」那一句，
      // 并在其后一个有限窗口内检查 `dispose()` —— 同一段清理链里顺序才有意义。
      final idx = engine.indexOf("await vibrate.stopAll(reason: '引擎停止')");
      expect(idx, greaterThanOrEqualTo(0), reason: '停机必须停振动（S3：任何时刻都能停）');
      final window = engine.substring(idx, (idx + 1200).clamp(0, engine.length));
      final disposeAt = window.indexOf('vibrate.dispose()');
      expect(disposeAt, greaterThanOrEqualTo(0),
          reason: '★ R88-AUD-02：`VibrateSession.dispose()` 此前全仓**零调用点**'
              '（BUG-127 的修复是空转的）—— 必须在这里接上');
      expect(disposeAt, greaterThan(0),
          reason: 'stopAll 在前、dispose 在后：前者会 await 原生 cancel，后者补刀');
    });

    test('R97-EN-02 ★ guardError 必须在 await 链之前清空（AUD-07）', () {
      final body = methodBody(engine, 'Future<void> applyGuardEnabled(bool enabled,');
      final clearAt = body.indexOf('guardError = null;');
      final startAt = body.indexOf('await guard.start(cfg)');
      expect(clearAt, greaterThanOrEqualTo(0),
          reason: '★ R88-AUD-07：窗口内广播带着上一轮的失败文案 ⇒ UI 立刻判「启动失败」');
      expect(startAt, greaterThanOrEqualTo(0));
      expect(clearAt < startAt, isTrue,
          reason: '清空必须发生在 `guard.start` 的 await **之前**'
              '（放在之后 = 窗口内仍然带旧错误）');
    });

    test('R97-EN-03 ★ 守卫命令必须做代次复核（AUD-03 引擎侧）', () {
      final body = methodBody(engine, 'Future<void> applyGuardEnabled(bool enabled,');
      expect(body, contains('guardGen'),
          reason: '★ R88-AUD-03：`service.on(\'guard\')` 是独立 async 监听器、'
              '没有串行化 ⇒ 必须有代次判据');
      final recheckAt = body.indexOf('gen != guardGen');
      final startAt = body.indexOf('await guard.start(cfg)');
      expect(recheckAt, greaterThanOrEqualTo(0), reason: '缺代次复核');
      expect(recheckAt > startAt, isTrue,
          reason: '复核必须发生在 `guard.start` 返回**之后**（窗口才刚关闭）');
      expect(body, contains('await guard.stop()'),
          reason: '复核不成立时必须立刻停掉刚起来的守卫（否则麦克风继续采）');
    });

    test('R97-EN-04 守卫代次字段存在且只在同步段自增', () {
      expect(engine, contains('int guardGen = 0;'));
      expect(engine, contains('final gen = ++guardGen;'),
          reason: '自增必须与取快照是同一条同步语句（任何 await 之后自增都拦不住窗口）');
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // background_service_manager：死分支 → finally
  // ═══════════════════════════════════════════════════════════════

  group('后台服务管理器：回投等待的摘表出口', () {
    final mgr = stripComments(
        File('lib/services/background_service_manager.dart').readAsStringSync());

    test('R97-SM-01 ★ 三出口统一 finally 摘表，且死分支已删', () {
      final body = methodBody(mgr, 'Future<RunNowResult> _awaitResult(String reqId,');
      expect(body, contains('finally'),
          reason: '正常回投 / 超时 / 未来新增异常，三条出口必须统一摘表');
      expect(body, isNot(contains("message: '引擎回投异常")),
          reason: '★ 该分支恒不可达：`completer.future` 的唯一完成点是回投侧的'
              '`complete(...)`，全仓**没有** `completeError` 调用点 ⇒ 死代码');
      // 正常路径的摘表不再依赖回投侧单点（回投侧 remove 仍是幂等的）。
      expect(RegExp(r'_pendingRun\.remove\(reqId\)').allMatches(body).length,
          greaterThanOrEqualTo(1));
    });
  });
}

/// 可把 `startStream` 卡住的录音器替身（用于复现「取流窗口内被停止」）。
class _GatedRecorder implements AudioRecorder {
  final _chunks = StreamController<Uint8List>.broadcast();
  final reachedStream = Completer<void>();
  final _gate = Completer<void>();
  int stopCalls = 0;
  bool _recording = false;

  void releaseStream() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    if (!reachedStream.isCompleted) reachedStream.complete();
    await _gate.future;
    _recording = true;
    return _chunks.stream;
  }

  @override
  Future<bool> isRecording() async => _recording;

  @override
  Future<String?> stop() async {
    stopCalls++;
    _recording = false;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('未预期的录音器调用：${invocation.memberName}');
}
