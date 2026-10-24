import 'dart:async';
import 'dart:math' as math;

import '../core/utils/random.dart';
import 'playback_service.dart';
import 'sound_guard_service.dart';
import 'tts_service.dart';

/// 实时随机动态反击（v2.0 阶段 D）—— 见计划第 20/21 条。
///
/// ## 这个服务**不**采音
///
/// 它只消费 [SoundEvent]（来源是既有的 [SoundGuardService]），**从不**创建
/// 录音器 —— 与守卫复用同一条麦克风通路，结构上就不可能出现"第二个录音器"
/// （本文件的依赖里根本没有 `AudioRecorder`）。
///
/// ## 全部 I/O 均可注入
///
/// 播放 / TTS / 随机 / 时钟 / 定时器 / 审计 sink 全部是构造参数（有安全默认）：
/// 核心决策（分级 → 忽略/记录/反击、静默反制、互斥、冷却、渐进升级）因此
/// 能在宿主测试里**穷举**，不触碰任何平台插件。
class CounterAction {
  const CounterAction.audio(String path)
      : audioPath = path,
        text = '',
        voiceId = '';

  const CounterAction.tts(this.text, {this.voiceId = ''}) : audioPath = '';

  /// 音效文件名/路径（[isTts] 为 false 时有效）。
  final String audioPath;

  /// TTS 文本（[isTts] 为 true 时有效）。
  final String text;

  /// TTS 音色 id（空串 = 系统默认，见 `TtsVoices`）。
  final String voiceId;

  bool get isTts => text.isNotEmpty;
}

/// 反击强度区间（音量 / 时长），用于随机落点。
typedef CounterIntensity = ({
  double volumeMin,
  double volumeMax,
  int durationMsMin,
  int durationMsMax,
});

/// 反击参数（全部有默认，可在构造时覆盖）。
class ReactiveCounterConfig {
  const ReactiveCounterConfig({
    this.silenceMin = const Duration(minutes: 15),
    this.silenceMax = const Duration(minutes: 25),
    this.cooldown = const Duration(seconds: 120),
    this.heavyVolumeMin = 0.5,
    this.heavyVolumeMax = 0.8,
    this.heavyDurationMsMin = 3000,
    this.heavyDurationMsMax = 8000,
    this.silenceVolumeMin = 0.3,
    this.silenceVolumeMax = 0.5,
    this.silenceDurationMsMin = 2000,
    this.silenceDurationMsMax = 5000,
    this.maxEscalation = 4,
  });

  /// 静默多久后触发动态反制（在此区间内随机，避免规律可预测）。
  final Duration silenceMin;
  final Duration silenceMax;

  /// 两次反击之间的最小间隔（防止叠加/连环）。
  final Duration cooldown;

  /// 重声音反击的随机音量区间。
  final double heavyVolumeMin;
  final double heavyVolumeMax;

  /// 重声音反击的随机时长区间。
  final int heavyDurationMsMin;
  final int heavyDurationMsMax;

  /// 静默反制的基准音量区间（随连续静默次数渐进升级）。
  final double silenceVolumeMin;
  final double silenceVolumeMax;

  /// 静默反制的基准时长区间（随连续静默次数渐进升级）。
  final int silenceDurationMsMin;
  final int silenceDurationMsMax;

  /// 渐进升级的封顶步数（防止无限变响）。
  final int maxEscalation;
}

/// 静默反制强度随**连续静默次数**渐进升级（[step] 从 1 起）。
///
/// 抽成纯函数：升级曲线要能被回归锁直接断言（不能只靠"跑一次看看"）。
/// 每升一级，音量/时长上限与下限同步放大 25%，音量再夹到 `0..1`。
CounterIntensity silenceRangeFor(ReactiveCounterConfig c, int step) {
  final s = (step - 1).clamp(0, c.maxEscalation);
  final grow = 1.0 + s * 0.25;
  double vol(double v) => (v * grow).clamp(0.0, 1.0);
  int dur(int ms) => (ms * grow).round();
  return (
    volumeMin: vol(c.silenceVolumeMin),
    volumeMax: vol(c.silenceVolumeMax),
    durationMsMin: dur(c.silenceDurationMsMin),
    durationMsMax: dur(c.silenceDurationMsMax),
  );
}

/// 一条反击审计记录（内存留痕；另可选地同步到注入的 [CounterAuditSink]）。
class CounterAuditRecord {
  const CounterAuditRecord({
    required this.at,
    required this.kind,
    required this.status,
    required this.message,
    this.grade,
    this.action,
    this.volume,
    this.durationMs,
  });

  final DateTime at;

  /// `sound`（一次声音）/ `silence`（静默检查）/ `counter`（一次反击）。
  final String kind;

  /// `observed` / `ignored` / `skipped` / `success` / `failed`。
  final String status;

  final String message;
  final SoundGrade? grade;
  final CounterAction? action;
  final double? volume;
  final int? durationMs;
}

/// 一次决策的结果。
class CounterOutcome {
  const CounterOutcome({
    required this.grade,
    required this.acted,
    this.action,
    this.reason,
  });

  final SoundGrade grade;

  /// 是否**真的执行**了一次反击（执行失败不算）。
  final bool acted;

  final CounterAction? action;

  /// 未执行时的原因（`light-ignored` / `medium-observe-only` / `cooldown` /
  /// `busy` / `empty-pool` / `not-running` / 执行失败原因…）。
  final String? reason;
}

/// 审计 sink：`action/status/message` → 完成（失败由服务自行兜底，不外泄）。
typedef CounterAuditSink = Future<void> Function({
  required String action,
  required String status,
  String? message,
});

/// 音效播放委托（默认无人注入 → 记为 failed，绝不假装成功）。
typedef CounterPlayFn = Future<PlayResult> Function({
  required String path,
  required double volume,
  required int durationMs,
});

/// TTS 播报委托（默认无人注入 → 记为 failed）。
typedef CounterTtsFn = Future<TtsResult> Function(
  String text, {
  required String voiceId,
  required double volume,
});

/// 互斥探测：是否有别的播放正在进行。默认读 [PlaybackService.anyPlaying]。
typedef CounterBusyFn = bool Function();

/// 可注入定时器（宿主测试用替身手工触发，绕开真实墙钟）。
abstract class CounterTimer {
  void cancel();
}

typedef CounterTimerFn = CounterTimer Function(
    Duration delay, void Function() onFire);

class _RealTimer implements CounterTimer {
  _RealTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// 实时随机动态反击服务。
class ReactiveCounterService {
  ReactiveCounterService({
    List<CounterAction> pool = const <CounterAction>[],
    this.config = const ReactiveCounterConfig(),
    CounterAuditSink? audit,
    CounterPlayFn? playAudio,
    CounterTtsFn? speak,
    CounterBusyFn? isBusy,
    CounterTimerFn? timerFactory,
    math.Random? rng,
    DateTime Function()? clock,
    Duration Function()? elapsed,
  })  : _pool = List<CounterAction>.unmodifiable(pool),
        _audit = audit,
        _playAudio = playAudio,
        _speak = speak,
        _isBusy = isBusy ?? _defaultBusy,
        _timerFactory = timerFactory ?? _realTimerFactory,
        _rng = rng ?? math.Random(),
        _clock = clock ?? DateTime.now,
        _elapsed = elapsed ?? _defaultElapsed(clock);

  /// 「经过时长」的**单调**时间源（R94 / SCH-10）。
  ///
  /// ## 为什么不能直接用 [clock]
  /// 冷却（`cooldown`）与静默判定（`silenceMin`）都是**间隔**语义，不是
  /// "日历时刻"语义。旧实现拿 `DateTime.now()` 做差 ⇒ 系统时间跳变时语义反转：
  /// - **前跳**（NTP 大校正 / 用户改时间）：冷却立刻过期 ⇒ 反击可以立刻再来
  ///   一次；静默判定立刻为真 ⇒ 白天有人时也可能触发静默反制；
  /// - **回跳**：`_cooldownUntil` 变成"未来" ⇒ 反击被静默禁用，回跳多久禁多久。
  ///
  /// 生产路径（不注入 [clock]）现在用 `Stopwatch`（VM 内单调，与 `Timer` 同源）；
  /// 注入了 [clock] 的调用方（宿主测试）则以注入时钟的**差值**作为单调源 ——
  /// 测试推进假时钟时行为与旧实现逐字等价，不会把既有用例改成"永远冷却中"。
  static Duration Function() _defaultElapsed(DateTime Function()? injected) {
    if (injected == null) {
      final sw = Stopwatch()..start();
      return () => sw.elapsed;
    }
    final origin = injected();
    return () => injected().difference(origin);
  }

  /// 生产默认互斥探测：复用 `PlaybackService` 的登记表（唯一真源）。
  static bool _defaultBusy() => PlaybackService.anyPlaying;

  static CounterTimer _realTimerFactory(Duration d, void Function() cb) =>
      _RealTimer(Timer(d, cb));

  final List<CounterAction> _pool;
  final ReactiveCounterConfig config;
  final CounterAuditSink? _audit;
  final CounterPlayFn? _playAudio;
  final CounterTtsFn? _speak;
  final CounterBusyFn _isBusy;
  final CounterTimerFn _timerFactory;
  final math.Random _rng;
  final DateTime Function() _clock;
  final Duration Function() _elapsed;

  final List<CounterAuditRecord> _records = <CounterAuditRecord>[];

  bool _running = false;
  bool _acting = false;
  int _escalation = 0;

  /// 最近一次"有声音"的**单调**时刻（SCH-10：静默判定只认经过时长）。
  Duration? _lastSoundElapsed;

  /// 冷却截止的**单调**时刻（不是墙钟 —— 见 [_defaultElapsed]）。
  Duration? _cooldownUntilElapsed;
  CounterTimer? _silenceTimer;
  Duration? _lastSilenceDelay;

  /// 内存审计记录（**总是**留下；sink 只是额外落盘）。
  List<CounterAuditRecord> get records =>
      List<CounterAuditRecord>.unmodifiable(_records);

  bool get isRunning => _running;

  /// 当前连续静默计数（渐进升级步数）。
  int get escalationStep => _escalation;

  /// 最近一次排定的静默检查延迟（供回归锁断言 15–25 分钟随机）。
  Duration? get lastScheduledSilenceDelay => _lastSilenceDelay;

  /// 启动：记下"最后有声时刻"，并按 15–25 分钟随机排定首次静默检查。
  ///
  /// 幂等：对**同一实例**重复 `start()` 是 no-op（`_running` 早退）。
  /// ⚠️ 跨实例不幂等 —— 引擎侧 `startReactiveCounter` 必须**先停旧实例**
  /// 再装配新实例（SCH-09：旧实现直接覆盖引用，旧 Timer 仍在跑，
  /// 表现为"关掉动态反击后仍会自己出声"）。
  void start() {
    if (_running) return;
    _running = true;
    _lastSoundElapsed = _elapsed();
    _escalation = 0;
    _scheduleSilence();
  }

  /// 停止：取消静默定时器。**不**触碰任何录音器（本服务没有）。
  void stop() {
    _running = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  /// 排定下一次静默检查（区间内均匀随机，避免规律可预测）。
  void _scheduleSilence() {
    _silenceTimer?.cancel();
    final msMin = config.silenceMin.inMilliseconds;
    final msMax = config.silenceMax.inMilliseconds;
    final delay = Duration(
        milliseconds: msMax <= msMin ? msMin : nextIntBetween(_rng, msMin, msMax));
    _lastSilenceDelay = delay;
    _silenceTimer =
        _timerFactory(delay, () => unawaited(handleSilence()));
  }

  /// 处理一次声音事件：**尽量记录**；轻忽略、中只记录、重随机反击。
  Future<CounterOutcome> onSound(SoundEvent event) async {
    final grade = event.grade;
    if (!_running) {
      return CounterOutcome(
          grade: grade, acted: false, reason: 'not-running');
    }
    // 有声音 ⇒ 静默升级归零（活动状态下的强度不该继续爬）。
    _lastSoundElapsed = _elapsed();
    _escalation = 0;

    await _record(CounterAuditRecord(
      at: _clock(),
      kind: 'sound',
      status: 'observed',
      grade: grade,
      message: '检测到${grade.label}声音 '
          '${event.peakDb.toStringAsFixed(1)}dBFS/${event.durationMs}ms',
    ));

    if (grade == SoundGrade.light) {
      await _record(CounterAuditRecord(
        at: _clock(),
        kind: 'sound',
        status: 'ignored',
        grade: grade,
        message: '轻量声音：忽略（只留记录，不反击）',
      ));
      return CounterOutcome(
          grade: grade, acted: false, reason: 'light-ignored');
    }
    if (grade == SoundGrade.medium) {
      await _record(CounterAuditRecord(
        at: _clock(),
        kind: 'sound',
        status: 'observed',
        grade: grade,
        message: '中等声音：记录但不反击',
      ));
      return CounterOutcome(
          grade: grade, acted: false, reason: 'medium-observe-only');
    }
    return _counter(grade: grade);
  }

  /// 静默到期（由排定的定时器调用；也可在宿主测试里直接调用）。
  ///
  /// 若期间其实有声音（`now - 最后有声 < silenceMin`），则**不误触发**，
  /// 改期重排 —— 这正是"静默"二字的判据。
  Future<CounterOutcome?> handleSilence() async {
    if (!_running) return null;
    final now = _clock();
    // SCH-10：判据用**单调经过时长**（不是墙钟差值）—— 系统时间前跳不得
    // 把"刚有声音"误判成"已静默 20 分钟"。
    final sinceSound = _elapsed() - (_lastSoundElapsed ?? Duration.zero);
    if (sinceSound < config.silenceMin) {
      await _record(CounterAuditRecord(
        at: now,
        kind: 'silence',
        status: 'skipped',
        message: '静默检查：近期仍有声音，改期重试（不误触发）',
      ));
      _scheduleSilence();
      return null;
    }
    final outcome = await _counter(grade: SoundGrade.heavy, escalateStep: _escalation + 1);
    _scheduleSilence();
    return outcome;
  }

  /// 统一的反击执行：互斥 + 冷却 + 随机动作/音量/时长。
  Future<CounterOutcome> _counter({
    required SoundGrade grade,
    int escalateStep = 0,
  }) async {
    if (_acting) {
      return _skip(grade, 'busy', '已有反击在执行：跳过（防叠加）');
    }
    if (_isBusy()) {
      return _skip(grade, 'busy', '手动/调度正在播放：跳过（互斥）');
    }
    final cd = _cooldownUntilElapsed;
    if (cd != null && _elapsed() < cd) {
      final left = (cd - _elapsed()).inSeconds;
      return _skip(grade, 'cooldown', '冷却中（约剩 ${left}s）：跳过');
    }
    if (_pool.isEmpty) {
      return _skip(grade, 'empty-pool', '动作池为空：无法反击');
    }

    final action = _pool[_rng.nextInt(_pool.length)];
    final range = escalateStep > 0
        ? silenceRangeFor(config, escalateStep)
        : (
            volumeMin: config.heavyVolumeMin,
            volumeMax: config.heavyVolumeMax,
            durationMsMin: config.heavyDurationMsMin,
            durationMsMax: config.heavyDurationMsMax,
          );
    final volume = nextDoubleBetween(_rng, range.volumeMin, range.volumeMax);
    final durationMs = nextIntBetween(_rng, range.durationMsMin, range.durationMsMax);

    _acting = true;
    // 冷却从"决定反击"那一刻起算：即使执行较久，也不会紧接着再来一次。
    // 基准是**单调**时刻（SCH-10）：墙钟跳变不得解除/延长冷却。
    _cooldownUntilElapsed = _elapsed() + config.cooldown;
    var ok = false;
    String? failure;
    try {
      if (action.isTts) {
        final r = await _speak?.call(action.text,
            voiceId: action.voiceId, volume: volume);
        if (r == null) {
          failure = '未注入 TTS 通路';
        } else {
          ok = r.ok;
          failure = r.message;
        }
      } else {
        final r = await _playAudio?.call(
            path: action.audioPath, volume: volume, durationMs: durationMs);
        if (r == null) {
          failure = '未注入播放通路';
        } else {
          ok = r.ok;
          failure = r.message;
        }
      }
    } on Object catch (e) {
      failure = e.toString();
    } finally {
      _acting = false;
    }

    final label = escalateStep > 0 ? '静默反制（升级×$escalateStep）' : '重声音反击';
    await _record(CounterAuditRecord(
      at: _clock(),
      kind: 'counter',
      status: ok ? 'success' : 'failed',
      grade: grade,
      action: action,
      volume: volume,
      durationMs: durationMs,
      message: '$label：${action.isTts ? 'TTS「${action.text}」' : action.audioPath} '
          '音量 ${volume.toStringAsFixed(2)} / ${durationMs}ms'
          '${ok ? '' : '（失败：${failure ?? '未知'}）'}',
    ));

    if (ok && escalateStep > 0) _escalation = escalateStep;
    return CounterOutcome(
      grade: grade,
      acted: ok,
      action: action,
      reason: ok ? null : (failure ?? '执行失败'),
    );
  }

  Future<CounterOutcome> _skip(
      SoundGrade grade, String reason, String message) async {
    await _record(CounterAuditRecord(
      at: _clock(),
      kind: 'counter',
      status: 'skipped',
      grade: grade,
      message: message,
    ));
    return CounterOutcome(grade: grade, acted: false, reason: reason);
  }

  /// 写一条审计：**先入内存**（保证"尽量记录"），sink 失败不上抛。
  Future<void> _record(CounterAuditRecord r) async {
    _records.add(r);
    final sink = _audit;
    if (sink == null) return;
    try {
      await sink(action: r.kind, status: r.status, message: r.message);
    } on Object {
      // sink 是旁路：它失败不能把反击本身拖垮（内存记录已留下）。
    }
  }
}