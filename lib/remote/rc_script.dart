import 'dart:convert';

import '../domain/models/action.dart';

/// 远程指令组（宏）模型：动作 + 时延的有序序列。
/// 组装器与端点执行器共用同一序列化格式（协议 docs/14）。
///
/// step kind：
/// - play    {volume(0..1), durationSec, presetCategory?}   随机播放（可指定分类）
/// - tts     {text, volume}
/// - notify  {title, body}
/// - vibrate {mode?, ...}   v1.9 参数化（docs/20 §10.1）。
///           ⚠️ `mode` 缺省 = `fixed` ⇒ **老控制器发的 `{}` 行为一字不变**
///           （协议向后兼容，不是"顺手加的默认值"）。
/// - record  {seconds}
/// - delay   {seconds}   时延元素（0.5s 粒度，单步上限 600s）

enum RcStepKind { play, tts, notify, vibrate, record, delay }

/// 振动步模式（v1.9，docs/20 §10.1）。
enum RcVibrateMode { fixed, random, continuous }

/// 解析线格式里的 `mode`。**未知/缺失一律按 `fixed`** —— 这是老协议的唯一语义，
/// 不是"降级"（真正需要明示降级的是设备能力不足，见 `vibrateDegradations`）。
RcVibrateMode rcVibrateModeOf(Object? v) {
  for (final m in RcVibrateMode.values) {
    if (m.name == v) return m;
  }
  return RcVibrateMode.fixed;
}

/// 振动步骤的执行路由。
enum RcVibrateRoute {
  /// 走老路径（`vibrateHandler`，固定节奏）。
  legacyFixed,

  /// 走参数化路径（转交引擎 `VibrateSession`）。
  actionHandler,

  /// 什么都不做，写 `skipped` 审计。
  skip,
}

/// 振动步骤该走哪条路 —— **纯函数**，所以"不会静默降级"这件事可以被断言。
///
/// ⚠️ 本函数的**全部意义**在最后一行：随机/持续振动在缺少参数化处理器时
/// **只能 skip，绝不能退回 `legacyFixed`**。退回的后果是对端要"持续振动
/// 30 秒（强度 50–100%）"、端点却震两下就结束 —— 承诺了没做到，而且用户
/// 从现象上看不出区别（FR-34 口径修正 / BUG-059 通则）。
/// 用纯函数表达后，`test/rc_vibrate_step_test.dart` 可以穷举全部组合来锁死它。
RcVibrateRoute routeRcVibrateStep(
  RcVibrateMode mode, {
  required bool hasLegacyHandler,
  required bool hasActionHandler,
}) {
  if (mode == RcVibrateMode.fixed) {
    return hasLegacyHandler ? RcVibrateRoute.legacyFixed : RcVibrateRoute.skip;
  }
  return hasActionHandler ? RcVibrateRoute.actionHandler : RcVibrateRoute.skip;
}

/// 振动步参数规格：**UI 表单与执行器共用同一份声明**。
///
/// ⚠️ 为什么用声明式，而不是在 UI 与执行器各写一遍：
/// 两处各写一遍必然漂移 —— 表单填的键名与执行器读的键名一旦不同，
/// **不抛任何异常**，只会静默取默认值（BUG-068 同类：`??` 链取到别的字段的值）。
/// 同一份声明让"表单能填"与"执行器认识"在结构上无法分叉。
class RcVibrateField {
  const RcVibrateField(
    this.key,
    this.label, {
    required this.min,
    required this.max,
    this.fraction = false,
  });

  final String key;
  final String label;
  final num min;
  final num max;

  /// true = 0..1 的小数（强度/锐度）；false = 整数。
  final bool fraction;
}

/// 固定节奏：无可编辑参数（保留 `patternMs` 的线格式兼容位，但不由 UI 暴露）。
const List<RcVibrateField> rcVibrateFixedFields = <RcVibrateField>[];

/// 随机脉冲串（`RandomVibrateAction`）。
const List<RcVibrateField> rcVibrateRandomFields = <RcVibrateField>[
  RcVibrateField('durationSecMin', '最短时长（秒）',
      min: 1, max: VibrateLimits.maxDurationSec),
  RcVibrateField('durationSecMax', '最长时长（秒）',
      min: 1, max: VibrateLimits.maxDurationSec),
  RcVibrateField('pulseOnMsMin', '单次脉冲最短（毫秒）',
      min: VibrateLimits.minPulseOnMs, max: VibrateLimits.maxPulseOnMs),
  RcVibrateField('pulseOnMsMax', '单次脉冲最长（毫秒）',
      min: VibrateLimits.minPulseOnMs, max: VibrateLimits.maxPulseOnMs),
  RcVibrateField('pulseOffMsMin', '脉冲间隔最短（毫秒）',
      min: 0, max: VibrateLimits.maxPulseOffMs),
  RcVibrateField('pulseOffMsMax', '脉冲间隔最长（毫秒）',
      min: 0, max: VibrateLimits.maxPulseOffMs),
  RcVibrateField('amplitudeMin', '最低强度（0–1）', min: 0, max: 1, fraction: true),
  RcVibrateField('amplitudeMax', '最高强度（0–1）', min: 0, max: 1, fraction: true),
  RcVibrateField('maxPulses', '脉冲数上限',
      min: 1, max: VibrateLimits.maxPulses),
  RcVibrateField('rampUpSec', '渐强（秒）',
      min: 0, max: VibrateLimits.maxRampSec),
];

/// 持续振动（`ContinuousVibrateAction`）。
const List<RcVibrateField> rcVibrateContinuousFields = <RcVibrateField>[
  RcVibrateField('durationSecMin', '最短时长（秒）',
      min: 1, max: VibrateLimits.maxDurationSec),
  RcVibrateField('durationSecMax', '最长时长（秒）',
      min: 1, max: VibrateLimits.maxDurationSec),
  RcVibrateField('amplitudeMin', '最低强度（0–1）', min: 0, max: 1, fraction: true),
  RcVibrateField('amplitudeMax', '最高强度（0–1）', min: 0, max: 1, fraction: true),
  RcVibrateField('jitterMs', '强度波动周期（毫秒，0=恒定）',
      min: 0, max: VibrateLimits.maxJitterMs),
  RcVibrateField('sharpnessMin', '最低锐度（0–1，仅 Android 16）',
      min: 0, max: 1, fraction: true),
  RcVibrateField('sharpnessMax', '最高锐度（0–1，仅 Android 16）',
      min: 0, max: 1, fraction: true),
  RcVibrateField('dutyCyclePct', '占空比（%，100=不停顿）', min: 10, max: 100),
  RcVibrateField('rampUpSec', '渐强（秒）',
      min: 0, max: VibrateLimits.maxRampSec),
  RcVibrateField('rampDownSec', '渐弱（秒）',
      min: 0, max: VibrateLimits.maxRampSec),
];

/// mode → 参数规格（唯一真源）。
const Map<RcVibrateMode, List<RcVibrateField>> rcVibrateFields =
    <RcVibrateMode, List<RcVibrateField>>{
  RcVibrateMode.fixed: rcVibrateFixedFields,
  RcVibrateMode.random: rcVibrateRandomFields,
  RcVibrateMode.continuous: rcVibrateContinuousFields,
};

List<RcVibrateField> rcVibrateFieldsFor(RcVibrateMode m) =>
    rcVibrateFields[m] ?? const <RcVibrateField>[];

/// 组装器新建振动步时的初值（UI 用；与 `fromJson` 的默认值同源）。
///
/// ⚠️ 键集合必须**恰好**等于 `rcVibrateFieldsFor(m)`（`RV-14` 锁）：
/// - 去掉 `kind`（`RcStep` 自己带）；
/// - 去掉 `respectDnd` —— 远程**不暴露**该开关（入站一律强制 true，
///   见 `RcStep.vibrateConfig`）。留着它会让参数表里出现一个"表单改不了、
///   但会随步骤一起发出去"的字段，属于隐性契约。
Map<String, dynamic> rcVibrateDefaultParams(RcVibrateMode m) {
  switch (m) {
    case RcVibrateMode.fixed:
      return <String, dynamic>{};
    case RcVibrateMode.random:
      const a = RandomVibrateAction();
      return a.toJson()
        ..remove('kind')
        ..remove('respectDnd');
    case RcVibrateMode.continuous:
      const a = ContinuousVibrateAction();
      return a.toJson()
        ..remove('kind')
        ..remove('respectDnd');
  }
}

class RcStep {
  const RcStep(this.kind, this.params);

  final RcStepKind kind;
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {'kind': kind.name, ...params};

  static RcStep fromJson(Map<String, dynamic> j) {
    final kind = RcStepKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => throw ArgumentError('未知 step kind: ${j['kind']}'),
    );
    return RcStep(kind, {...j}..remove('kind'));
  }

  /// 本步的振动模式；非振动步恒为 [RcVibrateMode.fixed]。
  RcVibrateMode get vibrateMode => kind == RcStepKind.vibrate
      ? rcVibrateModeOf(params['mode'])
      : RcVibrateMode.fixed;

  /// 由本步参数构造振动动作（**端点侧**消费点，v1.9）。
  ///
  /// 两件事必须同时成立：
  /// 1. **先夹紧再构造** —— `ActionConfig` 的区间约束靠 `assert` 表达，
  ///    而 assert 在 release 被剥离。对端发 `amplitudeMin:0.9, amplitudeMax:0.2`
  ///    在 debug 会先抛、release 会写出自相矛盾的动作，两条路径行为不一致。
  ///    统一在构造前夹紧即消除分歧（与 `TaskWire._sanitizeActionMap` 同法）。
  /// 2. **`respectDnd` 一律强制 `true`** —— 见方法内的注记。
  ActionConfig vibrateConfig() {
    final p = params;
    switch (vibrateMode) {
      case RcVibrateMode.fixed:
        final raw = p['patternMs'];
        if (raw is List &&
            raw.isNotEmpty &&
            raw.length <= VibrateLimits.maxPatternSteps) {
          final pattern = <int>[
            for (final e in raw)
              if (e is num) e.toInt().clamp(0, VibrateLimits.maxPatternStepMs)
          ];
          if (pattern.isNotEmpty) return VibrateAction(patternMs: pattern);
        }
        return const VibrateAction();

      case RcVibrateMode.random:
        final dur = _pairI(p, 'durationSecMin', 'durationSecMax', 1,
            VibrateLimits.maxDurationSec, 3, 10);
        final on = _pairI(p, 'pulseOnMsMin', 'pulseOnMsMax',
            VibrateLimits.minPulseOnMs, VibrateLimits.maxPulseOnMs, 150, 400);
        final off = _pairI(p, 'pulseOffMsMin', 'pulseOffMsMax', 0,
            VibrateLimits.maxPulseOffMs, 100, 600);
        final amp = _pairD(p, 'amplitudeMin', 'amplitudeMax', 0, 1, 0.4, 1);
        return RandomVibrateAction(
          durationSecMin: dur.$1,
          durationSecMax: dur.$2,
          pulseOnMsMin: on.$1,
          pulseOnMsMax: on.$2,
          pulseOffMsMin: off.$1,
          pulseOffMsMax: off.$2,
          amplitudeMin: amp.$1,
          amplitudeMax: amp.$2,
          maxPulses: _int(p, 'maxPulses', 1, VibrateLimits.maxPulses, 200),
          rampUpSec: _int(p, 'rampUpSec', 0, VibrateLimits.maxRampSec, 0),
          respectDnd: _inboundRespectDnd,
        );

      case RcVibrateMode.continuous:
        final dur = _pairI(p, 'durationSecMin', 'durationSecMax', 1,
            VibrateLimits.maxDurationSec, 10, 30);
        final amp = _pairD(p, 'amplitudeMin', 'amplitudeMax', 0, 1, 0.5, 1);
        final sharp = _pairD(p, 'sharpnessMin', 'sharpnessMax', 0, 1, 0, 0);
        return ContinuousVibrateAction(
          durationSecMin: dur.$1,
          durationSecMax: dur.$2,
          amplitudeMin: amp.$1,
          amplitudeMax: amp.$2,
          jitterMs: _int(p, 'jitterMs', 0, VibrateLimits.maxJitterMs, 0),
          sharpnessMin: sharp.$1,
          sharpnessMax: sharp.$2,
          dutyCyclePct: _int(p, 'dutyCyclePct', 10, 100, 100),
          rampUpSec: _int(p, 'rampUpSec', 0, VibrateLimits.maxRampSec, 0),
          rampDownSec: _int(p, 'rampDownSec', 0, VibrateLimits.maxRampSec, 0),
          respectDnd: _inboundRespectDnd,
        );
    }
  }

  /// 本步**最坏情况**占用的墙钟毫秒（`validate` 的总时长预算用）。
  ///
  /// 振动取区间**上界**：预算要挡的是"最久能占多久"，取下界会漏。
  int worstCaseMs() {
    switch (kind) {
      case RcStepKind.delay:
        return (((params['seconds'] as num?)?.toDouble() ?? 0) * 1000).round();
      case RcStepKind.vibrate:
        final m = vibrateMode;
        if (m == RcVibrateMode.fixed) return 300 + 200 + 300;
        final a = vibrateConfig();
        return switch (a) {
          RandomVibrateAction(:final durationSecMax) => durationSecMax * 1000,
          ContinuousVibrateAction(:final durationSecMax) => durationSecMax * 1000,
          _ => 0,
        };
      case RcStepKind.play:
        return ((params['durationSec'] as num?)?.toInt() ?? 10) * 1000;
      case RcStepKind.record:
        return ((params['seconds'] as num?)?.toInt() ?? 30) * 1000;
      case RcStepKind.tts:
      case RcStepKind.notify:
        return 0;
    }
  }

  /// 人类可读描述（通知/弹窗展示）。
  String describe() {
    switch (kind) {
      case RcStepKind.play:
        return '播放${params['presetCategory'] == null ? '' : '（${params['presetCategory']}）'}'
            '${params['durationSec'] == null ? '' : ' ${params['durationSec']}s'}';
      case RcStepKind.tts:
        return '播报「${params['text']}」';
      case RcStepKind.notify:
        return '通知「${params['title']}」';
      case RcStepKind.vibrate:
        // ⚠️ `fixed` 且无参数时保持 `'震动'` 一字不变 —— 老控制器/老通知栏
        // 的文案快照（`rc_script_executor_test` 有断言）不能被新功能改掉。
        switch (vibrateMode) {
          case RcVibrateMode.fixed:
            return '震动';
          case RcVibrateMode.random:
            final a = vibrateConfig() as RandomVibrateAction;
            return '随机振动 ${a.durationSecMin}–${a.durationSecMax} 秒'
                '（强度 ${_pct(a.amplitudeMin)}–${_pct(a.amplitudeMax)}'
                '｜脉冲 ${a.pulseOnMsMin}–${a.pulseOnMsMax}ms'
                '／间隔 ${a.pulseOffMsMin}–${a.pulseOffMsMax}ms'
                '｜≤${a.maxPulses} 次）';
          case RcVibrateMode.continuous:
            final a = vibrateConfig() as ContinuousVibrateAction;
            return '持续振动 ${a.durationSecMin}–${a.durationSecMax} 秒'
                '（强度 ${_pct(a.amplitudeMin)}–${_pct(a.amplitudeMax)}'
                '${a.jitterMs > 0 ? '｜波动 ${a.jitterMs}ms' : ''}'
                '${a.dutyCyclePct < 100 ? '｜占空比 ${a.dutyCyclePct}%' : ''}）';
        }
      case RcStepKind.record:
        return '录音取证 ${params['seconds']}s';
      case RcStepKind.delay:
        return '等待 ${params['seconds']}s';
    }
  }

  // ---------------- 夹紧工具（构造前） ----------------

  static String _pct(double v) => '${(v * 100).round()}%';

  /// **入站振动一律遵循勿扰**（v1.9，docs/20 §10.3 第 4 条）。
  ///
  /// `respectDnd=false` 会让原生侧改用 `USAGE_ALARM`，即**穿透系统勿扰**。
  /// 允许已配对的对端打开它，等于让对端绕过本机的合规护栏 —— 与
  /// `quietExempt`（§8.2 约束 1）是同一类问题，触碰项目红线（docs/08 §2）。
  /// 本机任务仍可由用户自己关闭（UI 有显式警告），**但远程路径不提供这个能力**。
  static const bool _inboundRespectDnd = true;

  static int _int(
      Map<String, dynamic> p, String k, int min, int max, int fallback) {
    final v = p[k];
    if (v is! num) return fallback;
    return v.toInt().clamp(min, max);
  }

  /// 区间对：各自夹紧后**保证 lo ≤ hi**（对端可能发反）。
  static (int, int) _pairI(Map<String, dynamic> p, String loKey, String hiKey,
      int min, int max, int dLo, int dHi) {
    var a = _int(p, loKey, min, max, dLo);
    var b = _int(p, hiKey, min, max, dHi);
    if (a > b) {
      final t = a;
      a = b;
      b = t;
    }
    return (a, b);
  }

  static (double, double) _pairD(Map<String, dynamic> p, String loKey,
      String hiKey, double min, double max, double dLo, double dHi) {
    var a = _dbl(p, loKey, min, max, dLo);
    var b = _dbl(p, hiKey, min, max, dHi);
    if (a > b) {
      final t = a;
      a = b;
      b = t;
    }
    return (a, b);
  }

  static double _dbl(Map<String, dynamic> p, String k, double min, double max,
      double fallback) {
    final v = p[k];
    if (v is! num) return fallback;
    return v.toDouble().clamp(min, max).toDouble();
  }
}

class RcScript {
  const RcScript({
    required this.scriptId,
    required this.name,
    required this.fromName,
    required this.sentAt,
    required this.steps,
  });

  final String scriptId;
  final String name;
  final String fromName; // 发送方名称（弹窗展示）
  final int sentAt; // 发送时间戳 ms
  final List<RcStep> steps;

  /// 指令组总时长上限（30 分钟）。
  ///
  /// ⚠️ 与 D1「持续振动**本地**不设时长硬上限」不矛盾：本上限是**指令组（宏）**
  /// 这条既有通道的护栏（"一键下发"必须有可预期的边界），而且它是**更严**的一侧 ——
  /// 本地任务能跑 2 小时的持续振动，远程指令组不能。收紧不是放宽。
  static const int maxTotalMs = 30 * 60 * 1000;

  Map<String, dynamic> toJson() => {
        'scriptId': scriptId,
        'name': name,
        'fromName': fromName,
        'sentAt': sentAt,
        'steps': [for (final s in steps) s.toJson()],
      };

  static RcScript fromJson(Map<String, dynamic> j) => RcScript(
        scriptId: j['scriptId'] as String,
        name: j['name'] as String? ?? '远程指令组',
        fromName: j['fromName'] as String? ?? '未知发送方',
        sentAt: (j['sentAt'] as num?)?.toInt() ?? 0,
        steps: [
          for (final s in (j['steps'] as List?) ?? [])
            RcStep.fromJson((s as Map).cast<String, dynamic>()),
        ],
      );

  static RcScript fromPayload(Map<String, dynamic> payload) =>
      fromJson(payload);

  /// 端点校验：步数 ≤ 50、总时长上限 30 分钟（delay 合计 ≤ 600s/步）。
  ///
  /// v1.9：振动步的时长**计入**总时长预算（此前只统计 `delay`，等于
  /// 一段 30 分钟的持续振动可以从预算旁边走过去）。
  /// 这里只挡**结构性问题**；数值越界由 `RcStep.vibrateConfig()` 夹紧 ——
  /// 与 `TaskWire` 同一哲学（夹紧优先于拒绝，拒绝留给结构错误）。
  static String? validate(List<RcStep> steps) {
    if (steps.isEmpty) return '指令组为空';
    if (steps.length > 50) return '步骤过多（上限 50）';
    var total = 0;
    for (final s in steps) {
      if (s.kind == RcStepKind.delay) {
        final sec = (s.params['seconds'] as num?)?.toDouble() ?? 0;
        if (sec < 0.5 || sec > 600) return '时延超出范围（0.5–600 秒/步）';
      }
      total += s.worstCaseMs();
    }
    if (total > maxTotalMs) return '时延与振动合计超过 30 分钟上限';
    return null;
  }

  static RcScript fromJsonString(String s) =>
      fromJson((jsonDecode(s) as Map).cast<String, dynamic>());
}
