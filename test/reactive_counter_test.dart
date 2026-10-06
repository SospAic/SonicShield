import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/services/playback_service.dart';
import 'package:sonic_shield/services/reactive_counter_service.dart';
import 'package:sonic_shield/services/sound_guard_service.dart';
import 'package:sonic_shield/services/tts_service.dart';

/// 实时随机动态反击（阶段 D）回归锁。
///
/// **零平台依赖**：播放 / TTS / 随机 / 时钟 / 定时器 / 审计全部用注入替身，
/// 因此"分级边界 / 轻忽略 / 重反击 / 静默反制 + 渐进 / 互斥 / 冷却 / 失败如实"
/// 都能在宿主上穷举。
void main() {
  // ───────────────────────── 替身 ─────────────────────────

  final clock0 = DateTime(2026, 1, 1, 12);

  test('RC-01 gradeOf 边界：轻/中/重 三条判据逐条钉住', () {
    // 重：硬阈 ≥ -12（无视时长）。
    expect(gradeOf(-6, 0), SoundGrade.heavy);
    expect(gradeOf(SoundGradeLimits.heavyDb, 0), SoundGrade.heavy);
    // 重：软阈 ≥ -20 且 ≥ 3s。
    expect(gradeOf(-20, SoundGradeLimits.heavyMs), SoundGrade.heavy);
    expect(gradeOf(-20, SoundGradeLimits.heavyMs - 1), SoundGrade.medium,
        reason: '持续差 1ms 就不该判重（否则时长这条判据是装饰）');
    // 中：硬阈 ≥ -25。
    expect(gradeOf(SoundGradeLimits.mediumDb, 0), SoundGrade.medium);
    expect(gradeOf(SoundGradeLimits.mediumDb - 0.1, 0), SoundGrade.light);
    // 中：软阈 ≥ -30 且 ≥ 2s。
    expect(gradeOf(-30, SoundGradeLimits.mediumMs), SoundGrade.medium);
    expect(gradeOf(-30, SoundGradeLimits.mediumMs - 1), SoundGrade.light);
    // 轻：既不够响也不够久（含数字静音的 -120 下限）。
    expect(gradeOf(-45, 300), SoundGrade.light);
    expect(gradeOf(-120, 60000), SoundGrade.light);
    // 满量程、极短 —— 仍是重（脆响也要被注意到）。
    expect(gradeOf(0, 5), SoundGrade.heavy);
  });

  test('RC-02 SoundEvent.grade 由既有两字段派生（构造签名未变）', () {
    final e = SoundEvent(detectedAt: clock0, peakDb: -6, durationMs: 100);
    expect(e.grade, SoundGrade.heavy);
    // 既有字段语义不变（既有测试锁它们）。
    expect(e.peakDb, -6);
    expect(e.durationMs, 100);
    expect(e.detectedAt, clock0);
  });

  group('RC 决策/执行（注入替身穷举）', () {
    late _Harness h;

    setUp(() => h = _Harness());

    SoundEvent ev(double db, int ms) =>
        SoundEvent(detectedAt: h.clock(), peakDb: db, durationMs: ms);

    test('RC-03 轻量声音 → 忽略：只留记录，绝不反击', () async {
      h.svc.start();
      final o = await h.svc.onSound(ev(-45, 300));
      expect(o.grade, SoundGrade.light);
      expect(o.acted, isFalse);
      expect(o.reason, 'light-ignored');
      expect(h.play.calls, isEmpty, reason: '轻量必须忽略（否则"轻/中/重"分级无意义）');
      expect(h.statuses, contains('ignored'));
      expect(h.statuses, contains('observed'), reason: '有声音"尽量记录"');
    });

    test('RC-04 中等声音 → 只记录不反击', () async {
      h.svc.start();
      final o = await h.svc.onSound(ev(-25, 100));
      expect(o.grade, SoundGrade.medium);
      expect(o.acted, isFalse);
      expect(o.reason, 'medium-observe-only');
      expect(h.play.calls, isEmpty);
      expect(h.statuses, isNot(contains('success')));
    });

    test('RC-05 重声音 → 随机反击：音量/时长落在配置区间内', () async {
      h.svc.start();
      final o = await h.svc.onSound(ev(-6, 500));
      expect(o.grade, SoundGrade.heavy);
      expect(o.acted, isTrue);
      expect(o.action, isNotNull);
      expect(h.play.calls, hasLength(1));
      final c = h.play.calls.single;
      expect(c.volume, inInclusiveRange(0.5, 0.8));
      expect(c.durationMs, inInclusiveRange(3000, 8000));
      expect(h.statuses, contains('success'));
    });

    test('RC-06 冷却门控：冷却期内的第二次重声音不得再反击', () async {
      h.svc.start();
      expect((await h.svc.onSound(ev(-6, 500))).acted, isTrue);
      h.clock.advance(const Duration(seconds: 30)); // 默认冷却 120s
      final o = await h.svc.onSound(ev(-6, 500));
      expect(o.acted, isFalse);
      expect(o.reason, 'cooldown');
      expect(h.play.calls, hasLength(1), reason: '冷却就是防连环，第二次必须被吃掉');
    });

    test('RC-07 与手动播放互斥：正在出声时不叠加', () async {
      h.setBusy(true);
      h.svc.start();
      final o = await h.svc.onSound(ev(-6, 500));
      expect(o.acted, isFalse);
      expect(o.reason, 'busy');
      expect(h.play.calls, isEmpty, reason: '手动/调度正在播放时反击不得叠加（复用 PlaybackService 登记表）');
      expect(h.statuses, contains('skipped'));
    });

    test('RC-08 静默 15–25 分钟随机触发动态反制，且连续静默渐进升级', () async {
      h.svc.start();
      final delay = h.timers.last.delay;
      expect(delay.inMinutes, inInclusiveRange(15, 25),
          reason: '静默反制必须在 15–25 分钟内随机（避免规律可预测）');

      // 第一次静默到期。
      h.clock.advance(const Duration(minutes: 20));
      final first = await h.svc.handleSilence();
      expect(first, isNotNull);
      expect(first!.acted, isTrue);
      expect(h.svc.escalationStep, 1);
      expect(h.play.calls, hasLength(1));
      expect(h.messages.any((m) => m.contains('升级×1')), isTrue);

      // 越过冷却 + 再次静默 → 第二次，升级到 ×2。
      h.clock.advance(const Duration(minutes: 10));
      final second = await h.svc.handleSilence();
      expect(second!.acted, isTrue);
      expect(h.svc.escalationStep, 2);
      expect(h.play.calls, hasLength(2));
      expect(h.messages.any((m) => m.contains('升级×2')), isTrue);
    });

    test('RC-09 静默计时器到期但期间有声音 → 不误触发（改期重排）', () async {
      h.svc.start();
      h.clock.advance(const Duration(minutes: 10));
      await h.svc.onSound(ev(-45, 300)); // 有声音 → 更新"最后有声时刻"
      h.clock.advance(const Duration(minutes: 5));
      final o = await h.svc.handleSilence();
      expect(o, isNull, reason: '仅静默 5 分钟达不到 15 分钟判据');
      expect(h.play.calls, isEmpty);
      expect(h.messages.any((m) => m.contains('仍有声音')), isTrue);
      expect(h.timers.created, hasLength(2), reason: '未触发时必须重新排程');
    });

    test('RC-10 动作池为空 → 不崩溃且如实记为 skipped', () async {
      final empty = _Harness(pool: const <CounterAction>[]);
      empty.svc.start();
      final o = await empty.svc.onSound(
          SoundEvent(detectedAt: empty.clock(), peakDb: -6, durationMs: 500));
      expect(o.acted, isFalse);
      expect(o.reason, 'empty-pool');
      expect(empty.statuses, contains('skipped'));
    });

    test('RC-11 TTS 动作池 → 走 TTS 通路（不加音量之外的东西）', () async {
      final ttsH = _Harness(
          pool: const [CounterAction.tts('干啥呢', voiceId: 'sys_zh_male')]);
      ttsH.svc.start();
      final o = await ttsH.svc.onSound(
          SoundEvent(detectedAt: ttsH.clock(), peakDb: -6, durationMs: 500));
      expect(o.acted, isTrue);
      expect(ttsH.play.calls, isEmpty);
      expect(ttsH.tts.calls, hasLength(1));
      final c = ttsH.tts.calls.single;
      expect(c.text, '干啥呢');
      expect(c.voiceId, 'sys_zh_male');
      expect(c.volume, inInclusiveRange(0.5, 0.8));
    });

    test('RC-12 执行失败 → 如实记为失败，不假成功', () async {
      h.play.ok = false;
      h.svc.start();
      final o = await h.svc.onSound(ev(-6, 500));
      expect(o.acted, isFalse, reason: '播放失败不得报成"已反击"');
      expect(o.reason, isNotNull);
      expect(h.statuses, contains('failed'));
      expect(h.statuses, isNot(contains('success')));
    });

    test('RC-13 未 start() → 不记录、不反击（避免"关了还在响"）', () async {
      final o = await h.svc.onSound(ev(-6, 500));
      expect(o.acted, isFalse);
      expect(o.reason, 'not-running');
      expect(h.play.calls, isEmpty);
      expect(h.svc.records, isEmpty);
    });

    test('RC-14 stop() → 取消已排定的静默定时器', () async {
      h.svc.start();
      final t = h.timers.last;
      expect(t.cancelled, isFalse);
      h.svc.stop();
      expect(t.cancelled, isTrue);
      expect(h.svc.isRunning, isFalse);
    });

    test('RC-16 生产默认依赖：不注入 rng/timer/busy/clock 也能启停与决策', () async {
      // 全部走默认：_rng=math.Random、_timerFactory=_realTimerFactory（_RealTimer）、
      // _isBusy=_defaultBusy（PlaybackService.anyPlaying）。
      final svc = ReactiveCounterService(
        pool: const [CounterAction.audio('preset.wav')],
        playAudio: ({
          required String path,
          required double volume,
          required int durationMs,
        }) async =>
            PlayResult(ok: true, playedMs: durationMs),
      );
      svc.start();
      expect(svc.isRunning, isTrue);
      // 真实定时器已排定首次静默检查（15–25 分钟随机）。
      final d = svc.lastScheduledSilenceDelay;
      expect(d, isNotNull);
      expect(d!.inMinutes, inInclusiveRange(15, 25));

      // 触发一次重声音反击 → 执行默认互斥探测 _defaultBusy（读登记表）。
      final o = await svc.onSound(
          SoundEvent(detectedAt: DateTime.now(), peakDb: -6, durationMs: 500));
      expect(o.grade, SoundGrade.heavy);
      expect(o.acted, isTrue, reason: o.reason ?? '');

      svc.stop(); // 取消真实定时器（_RealTimer.cancel）
      expect(svc.isRunning, isFalse);
    });

    test('RC-17 反击执行中的重入 → busy 跳过（_acting 防叠加）', () async {
      late _Harness rh;
      var reentered = false;
      rh = _Harness(playAudio: ({
        required String path,
        required double volume,
        required int durationMs,
      }) async {
        // 执行尚未结束（_acting=true）时再次收到重声音 → 必须被吃掉。
        if (!reentered) {
          reentered = true;
          final nested = await rh.svc.onSound(SoundEvent(
              detectedAt: rh.clock(), peakDb: -6, durationMs: 500));
          expect(nested.acted, isFalse);
          expect(nested.reason, 'busy');
        }
        return PlayResult(ok: true, playedMs: durationMs);
      });
      rh.svc.start();
      final o = await rh.svc.onSound(
          SoundEvent(detectedAt: rh.clock(), peakDb: -6, durationMs: 500));
      expect(o.acted, isTrue);
      expect(reentered, isTrue);
      expect(rh.statuses, contains('skipped'));
    });

    test('RC-18 播放通路抛异常 → 不崩溃，如实记为 failed', () async {
      final rh = _Harness(playAudio: ({
        required String path,
        required double volume,
        required int durationMs,
      }) async {
        throw StateError('boom');
      });
      rh.svc.start();
      final o = await rh.svc.onSound(
          SoundEvent(detectedAt: rh.clock(), peakDb: -6, durationMs: 500));
      expect(o.acted, isFalse);
      expect(o.reason, contains('boom'));
      expect(rh.statuses, contains('failed'));
      expect(rh.statuses, isNot(contains('success')));
    });
  });

  test('RC-15 silenceRangeFor：渐进升级单调放大并在 maxEscalation 封顶', () {
    const c = ReactiveCounterConfig();
    final s1 = silenceRangeFor(c, 1);
    final s2 = silenceRangeFor(c, 2);
    final capped = silenceRangeFor(c, c.maxEscalation + 1);
    final capped2 = silenceRangeFor(c, 100);
    expect(s2.volumeMin, greaterThanOrEqualTo(s1.volumeMin));
    expect(s2.volumeMax, greaterThan(s1.volumeMax));
    expect(s2.durationMsMin, greaterThanOrEqualTo(s1.durationMsMin));
    expect(s2.durationMsMax, greaterThan(s1.durationMsMax));
    expect(s2.volumeMax, lessThanOrEqualTo(1.0));
    // 封顶：超过上限一律与上限同值（不会无限变响）。
    expect(capped.volumeMax, capped2.volumeMax);
    expect(capped.durationMsMax, capped2.durationMsMax);
  });
}

// ───────────────────────── 测试夹具 ─────────────────────────

class _Harness {
  _Harness({
    List<CounterAction> pool = const [CounterAction.audio('preset.wav')],
    ReactiveCounterConfig config = const ReactiveCounterConfig(),
    bool busy = false,
    int seed = 7,
    CounterPlayFn? playAudio,
  }) {
    clock = _Clock(DateTime(2026, 1, 1, 12));
    timers = _FakeTimers();
    play = _PlaySpy();
    tts = _TtsSpy();
    _busy = busy;
    svc = ReactiveCounterService(
      pool: pool,
      config: config,
      audit: ({
        required String action,
        required String status,
        String? message,
      }) async {
        audits.add((action: action, status: status, message: message));
      },
      playAudio: playAudio ?? play.call,
      speak: tts.call,
      isBusy: () => _busy,
      timerFactory: timers.call,
      rng: math.Random(seed),
      clock: clock.call,
    );
  }

  late final ReactiveCounterService svc;
  late final _Clock clock;
  late final _FakeTimers timers;
  late final _PlaySpy play;
  late final _TtsSpy tts;
  final List<({String action, String status, String? message})> audits = [];
  bool _busy = false;

  void setBusy(bool v) => _busy = v;

  Iterable<String> get statuses => audits.map((a) => a.status);
  Iterable<String> get messages =>
      audits.map((a) => a.message ?? '').where((m) => m.isNotEmpty);
}

class _Clock {
  _Clock(this._t);
  DateTime _t;
  DateTime call() => _t;
  void advance(Duration d) => _t = _t.add(d);
}

class _PlaySpy {
  final List<({String path, double volume, int durationMs})> calls = [];
  bool ok = true;

  Future<PlayResult> call({
    required String path,
    required double volume,
    required int durationMs,
  }) async {
    calls.add((path: path, volume: volume, durationMs: durationMs));
    return PlayResult(ok: ok, playedMs: durationMs);
  }
}

class _TtsSpy {
  final List<({String text, String voiceId, double volume})> calls = [];

  Future<TtsResult> call(
    String text, {
    required String voiceId,
    required double volume,
  }) async {
    calls.add((text: text, voiceId: voiceId, volume: volume));
    return const TtsResult(ok: true, online: false);
  }
}

class _FakeTimers {
  final List<_FakeTimer> created = <_FakeTimer>[];

  _FakeTimer get last => created.last;

  CounterTimer call(Duration delay, void Function() onFire) {
    final t = _FakeTimer(delay, onFire);
    created.add(t);
    return t;
  }
}

class _FakeTimer implements CounterTimer {
  _FakeTimer(this.delay, this.onFire);

  final Duration delay;
  final void Function() onFire;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}