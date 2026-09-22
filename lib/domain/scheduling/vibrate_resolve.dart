/// 振动计划：**物化期随机** + **能力降级决策**（docs/20 §4.4 / §5.2）。
///
/// 本文件是**纯函数**（无 I/O、无平台通道），因此可以完全单测 ——
/// 这是本项目对"计划即审计"的一贯做法（docs/04 §3）。
///
/// 两条主线：
/// 1. [resolveVibratePlan]：物化期用 DPRNG 敲定**总时长 / 基准强度 / 波动种子**，
///    写入 occurrence。任何时刻都能回答"为什么 9 月 22 日 14:37 是 0.72 强度"。
/// 2. [planVibrateChunk]：执行期把计划翻译成**一次原生调用**。
///    持续振动按 ≤[VibrateRuntime.chunkMs] 分片，由执行层续发（docs/20 §7.2）。
library;

import 'dart:math';

import '../../core/utils/random.dart';
import '../models/action.dart';
import '../models/vibrate_caps.dart';

/// 振动运行期参数（编译期常量，调优入口）。
abstract final class VibrateRuntime {
  /// **分片时长**：每次下发给原生的最长振动时长。
  ///
  /// 为什么是分片而不是一次 `repeat=0` 无限循环 —— 见 docs/20 §7.2 S1：
  /// 分片续发让"进程一死就没人续发"，振动在 ≤[chunkMs] 内自然停止；
  /// 而无限循环在进程死亡后**可能还在震**，那是不可接受的失效模式。
  static const int chunkMs = 20000;

  /// 续发定时器周期。必须**显著小于** [chunkMs] 才有容错余量
  /// （20s 片 / 3s 检查 ⇒ 17s 余量）。
  ///
  /// ⚠️ 刻意**不复用** `SchedulerConfig.engineTick`（15s）：片长若取 10s < tick 15s
  /// 会出现 5s 可见空隙；而把 engineTick 改小会牵连 NFR-04 性能基线。
  static const Duration keepAliveTick = Duration(seconds: 3);

  /// 单片包络控制点上限（防数组爆炸）。
  static const int maxEnvelopePointsPerChunk = 200;

  /// 超过该时长需 UI 二次确认（软护栏，不阻止使用，只阻止误配）。
  static const int confirmThresholdSec = 300;
}

/// 物化期确定的振动执行参数（写入 occurrence 的 `duration_ms` / `volume`）。
class VibratePlan {
  const VibratePlan({
    required this.durationMs,
    required this.baseAmplitude,
    required this.jitterSeed,
    required this.truncated,
  });

  final int durationMs;

  /// 基准强度（区间内随机取一个）。**exec_logs.volume 列在振动动作下承载它**。
  final double baseAmplitude;

  /// 强度波动序列的种子。执行期用 `Random(jitterSeed)` 复现同一条曲线。
  final int jitterSeed;

  /// 是否因 `maxPulses` 上限而截断（true 时执行层必须写审计）。
  final bool truncated;

  @override
  String toString() => 'VibratePlan(${durationMs}ms, amp=$baseAmplitude, '
      'seed=$jitterSeed, truncated=$truncated)';
}

/// 原生振动命令形态。
enum VibrateMode {
  /// Android 16 包络（强度 + 锐度）。
  envelope,

  /// 波形 + 振幅数组（强度生效）。
  waveformAmplitude,

  /// 波形 on/off（强度被系统一律拉满）。
  waveformOnOff,

  /// API 26 以下的旧接口（强度忽略）。
  legacy,
}

/// 包络控制点（intensity/sharpness ∈ [0,1]）。
class EnvelopePoint {
  const EnvelopePoint({
    required this.intensity,
    required this.sharpness,
    required this.durationMs,
  });

  final double intensity;
  final double sharpness;
  final int durationMs;

  Map<String, dynamic> toMap() => {
        'intensity': intensity,
        'sharpness': sharpness,
        'durationMs': durationMs,
      };

  @override
  String toString() =>
      '(${intensity.toStringAsFixed(2)}, ${sharpness.toStringAsFixed(2)}, ${durationMs}ms)';
}

/// 一次原生振动调用（一片）。
class VibrateCommand {
  const VibrateCommand({
    required this.mode,
    required this.chunkMs,
    this.timings = const [],
    this.amplitudes,
    this.points,
    this.repeat = -1,
    this.useAlarmUsage = false,
  });

  final VibrateMode mode;
  final int chunkMs;

  /// waveform：交替的「静止/振动」时长，首元素为起始静止。
  final List<int> timings;

  /// waveform：与 [timings] 等长；静止段必须为 0。null = on/off 模式。
  final List<int>? amplitudes;

  /// envelope：控制点序列，**最后一个必须 intensity == 0**。
  final List<EnvelopePoint>? points;

  /// -1 = 不重复；0 = 无限循环（本设计不使用，见 [VibrateRuntime.chunkMs] 注释）。
  final int repeat;

  /// true ⇒ 原生侧用 `USAGE_ALARM`（**穿透勿扰**，需 UI 显式提示）。
  final bool useAlarmUsage;

  @override
  String toString() => 'VibrateCommand(${mode.name}, ${chunkMs}ms, '
      'timings=${timings.length}, amps=${amplitudes?.length}, '
      'points=${points?.length}, alarm=$useAlarmUsage)';
}

/// 0..1 强度 → Android 振幅（1..255；0 保留给"静止"）。
///
/// ⚠️ 不能用 `(a*255).round()` 直接当"开启"值：强度 0 会被算成 0 = 静止，
/// 于是"低强度"静默变成"不振动"。故**开启段最低取 1**。
int amplitudeToNative(double a) => (a * 255).round().clamp(1, 255);

/// 强度区间 → 本片可用的基准强度（含渐强缩放）。
///
/// [elapsedMs] / [totalMs] 用于渐强/渐弱：线性爬升与线性回落。
double _scaledAmplitude({
  required double value,
  required int elapsedMs,
  required int totalMs,
  required int rampUpSec,
  required int rampDownSec,
}) {
  var v = value;
  if (rampUpSec > 0) {
    final upMs = rampUpSec * 1000;
    final p = (elapsedMs / upMs).clamp(0.0, 1.0);
    // 从 5% 起爬（与 PlayAudioAction.rampUpSec 的既有语义一致）
    v *= 0.05 + 0.95 * p;
  }
  if (rampDownSec > 0) {
    final downMs = rampDownSec * 1000;
    final left = totalMs - elapsedMs;
    if (left < downMs) {
      v *= (left / downMs).clamp(0.0, 1.0);
    }
  }
  return v.clamp(0.0, 1.0);
}

// ---------------------------------------------------------------- 物化期

/// 脉冲串是否会被 `maxPulses` 截断。
///
/// **单一事实源**：物化期（[resolveVibratePlan]）与执行期（引擎写审计）都用它，
/// 避免两处各写一遍估算而漂移。判定用**最短可能脉冲周期**估上界 ——
/// 只要最短周期都撑得下 maxPulses 个脉冲，就一定不会截断。
bool randomVibrateTruncated(RandomVibrateAction a, int totalMs) {
  final minCycle = a.pulseOnMsMin + a.pulseOffMsMin;
  if (minCycle <= 0) return false; // 周期为 0 ⇒ 由 maxPulses 自身封顶
  return totalMs ~/ minCycle > a.maxPulses;
}

/// 物化期敲定振动执行参数。
///
/// [occurrenceId] 参与波动种子派生，保证"同一次执行 → 同一条波动曲线"。
/// 非振动动作返回 null（调用方按既有路径处理）。
VibratePlan? resolveVibratePlan(
  ActionConfig action,
  Random rng,
  String occurrenceId,
) {
  switch (action) {
    case final RandomVibrateAction a:
      final totalMs = nextIntBetween(
        rng,
        a.durationSecMin * 1000,
        a.durationSecMax * 1000 + 1,
      );
      return VibratePlan(
        durationMs: totalMs,
        baseAmplitude: nextDoubleBetween(rng, a.amplitudeMin, a.amplitudeMax),
        jitterSeed: stringSeed('$occurrenceId#jitter'),
        truncated: randomVibrateTruncated(a, totalMs),
      );
    case final ContinuousVibrateAction a:
      final totalMs = nextIntBetween(
        rng,
        a.durationSecMin * 1000,
        a.durationSecMax * 1000 + 1,
      );
      return VibratePlan(
        durationMs: totalMs,
        baseAmplitude: nextDoubleBetween(rng, a.amplitudeMin, a.amplitudeMax),
        jitterSeed: stringSeed('$occurrenceId#jitter'),
        truncated: false,
      );
    default:
      return null;
  }
}

// ---------------------------------------------------------------- 降级说明

/// 该设备上这条动作会发生的**降级**（空列表 = 完整生效）。
///
/// ⚠️ 返回值非空 ⇒ 调用方**必须**让用户看见（审计 + UI 提示条）。
/// 这正是 FR-34 口径修正的落地点：**不得静默降级**
/// （对齐 BUG-048/056/059 的通则"承诺了就必须做到，做不到必须留痕并让用户知道"）。
List<String> vibrateDegradations(VibrateCaps caps, ActionConfig action) {
  final out = <String>[];
  if (!caps.hasVibrator) {
    out.add('本机无振动器，振动不会发生');
    return out;
  }
  final wantsAmplitude = switch (action) {
    RandomVibrateAction() || ContinuousVibrateAction() => true,
    _ => false,
  };
  final wantsSharpness = switch (action) {
    final ContinuousVibrateAction a =>
      a.sharpnessMax > 0 || a.sharpnessMin > 0,
    _ => false,
  };
  if (wantsAmplitude && !caps.canExpressAmplitude) {
    out.add('本机不支持振幅控制，强度设置已失效（系统一律按满格振动）');
  }
  if (wantsSharpness && !caps.hasEnvelope) {
    out.add('本机不支持振动锐度（需 Android 16 及以上），锐度设置已忽略');
  }
  if (!caps.backgroundSupported) {
    out.add('本平台在后台无法振动（系统限制），仅在应用处于前台时生效');
  }
  return out;
}

// ---------------------------------------------------------------- 执行期

/// 随机振动：**一次性**生成整段波形。
///
/// 为什么不分片：脉冲串的**脉冲数**已被 `maxPulses`（≤1000）封顶，
/// 最坏 2000 个时间点，单次原生调用完全承受得住；分片反而会把脉冲切在
/// 片边界上，产生可听见/可感知的接缝。
VibrateCommand buildRandomVibrateCommand({
  required VibrateCaps caps,
  required RandomVibrateAction a,
  required Random rng,
  required int totalMs,
  required bool useAlarmUsage,
}) {
  final timings = <int>[];
  final amps = <int>[];
  var cursor = 0;
  var pulses = 0;

  while (pulses < a.maxPulses) {
    final off = nextIntBetween(rng, a.pulseOffMsMin, a.pulseOffMsMax + 1);
    final on = nextIntBetween(rng, a.pulseOnMsMin, a.pulseOnMsMax + 1);
    if (cursor + off + on > totalMs) break;
    final raw = nextDoubleBetween(rng, a.amplitudeMin, a.amplitudeMax);
    final amp = _scaledAmplitude(
      value: raw,
      elapsedMs: cursor,
      totalMs: totalMs,
      rampUpSec: a.rampUpSec,
      rampDownSec: 0,
    );
    timings..add(off)..add(on);
    amps..add(0)..add(amplitudeToNative(amp));
    cursor += off + on;
    pulses++;
  }

  // 尾部补一段静止，使总时长与物化期一致（否则实际振动时长会短于审计值）。
  if (cursor < totalMs) {
    timings.add(totalMs - cursor);
    amps.add(0);
  }
  if (timings.isEmpty) {
    // 极端配置（脉冲时长 > 总时长）→ 退化为一次等长振动，不返回空命令。
    timings.addAll([0, totalMs]);
    amps.addAll([0, amplitudeToNative(a.amplitudeMax)]);
  }

  final mode = switch (caps) {
    final c when c.hasEnvelope => VibrateMode.envelope,
    final c when c.hasAmplitudeControl => VibrateMode.waveformAmplitude,
    final c when c.hasVibrator => VibrateMode.waveformOnOff,
    _ => VibrateMode.legacy,
  };

  // 包络设备：把脉冲串表达为控制点（强度在脉冲内取平台值）。
  if (mode == VibrateMode.envelope) {
    return VibrateCommand(
      mode: mode,
      chunkMs: totalMs,
      points: _pointsFromWaveform(
        timings: timings,
        amplitudes: amps,
        minControlPointMs: caps.minControlPointMs,
      ),
      useAlarmUsage: useAlarmUsage,
    );
  }
  return VibrateCommand(
    mode: mode,
    chunkMs: totalMs,
    timings: timings,
    amplitudes: mode == VibrateMode.waveformAmplitude ? amps : null,
    useAlarmUsage: useAlarmUsage,
  );
}

/// 持续振动：生成**一片**（≤ [VibrateRuntime.chunkMs]）。
///
/// [elapsedMs] 为本次执行已振动时长，用于渐强/渐弱与波动序列定位；
/// 波动强度由 `Random(jitterSeed)` 复现（同一次执行 → 同一条曲线）。
VibrateCommand buildContinuousChunk({
  required VibrateCaps caps,
  required ContinuousVibrateAction a,
  required Random rng,
  required int chunkMs,
  required int elapsedMs,
  required int totalMs,
  required bool useAlarmUsage,
}) {
  final len = min(chunkMs, max(0, totalMs - elapsedMs));
  final mode = switch (caps) {
    final c when c.hasEnvelope => VibrateMode.envelope,
    final c when c.hasAmplitudeControl => VibrateMode.waveformAmplitude,
    final c when c.hasVibrator => VibrateMode.waveformOnOff,
    _ => VibrateMode.legacy,
  };

  if (mode == VibrateMode.envelope) {
    final interval = a.jitterMs > 0
        ? max(a.jitterMs, caps.minControlPointMs)
        : max(1000, caps.minControlPointMs);
    final points = <EnvelopePoint>[];
    var t = 0;
    while (t < len && points.length < VibrateRuntime.maxEnvelopePointsPerChunk - 1) {
      final dur = min(interval, len - t);
      final atMs = elapsedMs + t;
      var intensity = a.jitterMs > 0
          ? nextDoubleBetween(rng, a.amplitudeMin, a.amplitudeMax)
          : _baseOrRandom(rng, a);
      intensity = _scaledAmplitude(
        value: intensity,
        elapsedMs: atMs,
        totalMs: totalMs,
        rampUpSec: a.rampUpSec,
        rampDownSec: a.rampDownSec,
      );
      if (a.dutyCyclePct < 100) {
        // 占空比：按周期把一半时间压到 0
        final phase = t % max(1, interval * 2);
        if (phase >= interval) intensity = 0;
      }
      final sharp = a.sharpnessMax > 0
          ? nextDoubleBetween(rng, a.sharpnessMin, a.sharpnessMax)
          : a.sharpnessMin;
      points.add(EnvelopePoint(
        intensity: intensity,
        sharpness: sharp,
        durationMs: max(dur, caps.minControlPointMs),
      ));
      t += dur;
    }
    // ⚠️ 官方文档：基础包络效果**必须以 intensity == 0 收尾**，否则抛
    // IllegalStateException。这里无条件追加收尾点（原生侧另有兜底，双保险）。
    points.add(EnvelopePoint(
      intensity: 0,
      sharpness: a.sharpnessMin,
      durationMs: max(caps.minControlPointMs, 20),
    ));
    return VibrateCommand(
      mode: mode,
      chunkMs: len,
      points: points,
      useAlarmUsage: useAlarmUsage,
    );
  }

  // 波形：按占空比展开成等长 on/off
  final timings = <int>[];
  final amps = <int>[];
  const cycle = 1000; // 1s 周期，占空比在其内切分
  final onMs = max(1, (cycle * a.dutyCyclePct / 100).round());
  final offMs = cycle - onMs;
  var t = 0;
  var first = true;
  while (t < len) {
    final on = min(onMs, len - t);
    final atMs = elapsedMs + t;
    var intensity = a.jitterMs > 0
        ? nextDoubleBetween(rng, a.amplitudeMin, a.amplitudeMax)
        : _baseOrRandom(rng, a);
    intensity = _scaledAmplitude(
      value: intensity,
      elapsedMs: atMs,
      totalMs: totalMs,
      rampUpSec: a.rampUpSec,
      rampDownSec: a.rampDownSec,
    );
    // 波形首元素必须是"起始静止"；首段静止取 0ms。
    timings.add(first ? 0 : min(offMs, len - t));
    amps.add(0);
    first = false;
    timings.add(on);
    amps.add(amplitudeToNative(intensity));
    t += on;
    if (t >= len) break;
    final off = min(offMs, len - t);
    timings.add(off);
    amps.add(0);
    t += off;
  }

  return VibrateCommand(
    mode: mode,
    chunkMs: len,
    timings: timings,
    amplitudes: mode == VibrateMode.waveformAmplitude ? amps : null,
    useAlarmUsage: useAlarmUsage,
  );
}

/// 恒定模式下取一个基准强度（波动关闭时每次重取会变成"波动"，故此处
/// 只用于 jitterMs == 0 的场景，取一次即可；由调用方保证语义）。
double _baseOrRandom(Random rng, ContinuousVibrateAction a) =>
    nextDoubleBetween(rng, a.amplitudeMin, a.amplitudeMax);

/// 把「波形（时长/振幅）」翻译成包络控制点。
///
/// 每个波形段变成一个控制点；静止段强度 0。结尾保证 intensity == 0。
List<EnvelopePoint> _pointsFromWaveform({
  required List<int> timings,
  required List<int> amplitudes,
  required int minControlPointMs,
}) {
  final out = <EnvelopePoint>[];
  for (var i = 0; i < timings.length; i++) {
    final dur = timings[i];
    if (dur <= 0) continue;
    final amp = i < amplitudes.length ? amplitudes[i] : 0;
    out.add(EnvelopePoint(
      intensity: (amp / 255).clamp(0.0, 1.0),
      sharpness: 0,
      durationMs: max(dur, minControlPointMs),
    ));
    if (out.length >= VibrateRuntime.maxEnvelopePointsPerChunk - 1) break;
  }
  out.add(EnvelopePoint(
    intensity: 0,
    sharpness: 0,
    durationMs: max(minControlPointMs, 20),
  ));
  return out;
}
