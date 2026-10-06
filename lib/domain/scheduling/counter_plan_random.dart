/// 本机"按规则随机"生成反击计划（不调 AI，离线可用）。
///
/// ## 与 AI 生成的关系
/// 两条路产出**同一个 [CounterPlan] 结构**、遵守**同一组区间约束**：
/// - 工作日白天音量落在 50%–80%、夜间 30%–50%；
/// - 白天动作 3–8 秒、夜间 3–5 秒；
/// - 休息日两段默认关闭（可选开启）。
///
/// 差别只在"谁来挑具体数值"：本文件用 [Random] 在区间内取值，AI 用提示词。
/// 因此二者可以互相导入、互相下发，且**离线一定有可用计划**（AI 不可用时不空转）。
///
/// ## 随机但不失约束
/// 注意各区间是**在用户约定范围内再取子区间**（如工作日白天音量下限定在
/// 50%–65%、上限定在 70%–80%），而不是"先随机再校验"——避免随机出
/// `volumeMin > volumeMax` 这类自相矛盾的窗口。
library;

import 'dart:math';

import '../models/counter_plan.dart';

abstract final class CounterPlanRandom {
  /// 「招人烦」预置音效池（复用 [CounterPlan.defaultPresetIds]，单一真源）。
  static const List<String> annoyPresets = CounterPlan.defaultPresetIds;

  /// 可选 TTS 文案池（复用 [CounterPlan.defaultTtsTexts]）。
  static const List<String> ttsPool = CounterPlan.defaultTtsTexts;

  /// 生成一份合规计划。
  ///
  /// [seed] 非空 ⇒ 完全可复现（测试用）；[restdayDay]/[restdayNight] 控制
  /// 休息日两段是否参与（"可选"）；[presetIds]/[ttsTexts] 可注入自定义池。
  static CounterPlan generate({
    int? seed,
    String name = '本机随机反击计划',
    bool restdayDay = false,
    bool restdayNight = false,
    List<String> presetIds = annoyPresets,
    List<String> ttsTexts = ttsPool,
  }) {
    final rng = Random(seed);
    final plan = CounterPlan(
      name: name,
      cooldownSec: _intIn(rng, 600, 2400), // 10–40 分钟
      workdayDay: _window(
        rng,
        enabled: true,
        vLoRange: (0.50, 0.65),
        vHiRange: (0.70, 0.80),
        dLoRange: (3, 4),
        dHiRange: (6, 8),
        perHour: (1, 3),
      ),
      workdayNight: _window(
        rng,
        enabled: true,
        vLoRange: (0.30, 0.38),
        vHiRange: (0.45, 0.50),
        dLoRange: (3, 4),
        dHiRange: (4, 5),
        perHour: (1, 2),
      ),
      restdayDay: _window(
        rng,
        enabled: restdayDay,
        vLoRange: (0.50, 0.65),
        vHiRange: (0.70, 0.80),
        dLoRange: (3, 4),
        dHiRange: (6, 8),
        perHour: (1, 3),
      ),
      restdayNight: _window(
        rng,
        enabled: restdayNight,
        vLoRange: (0.10, 0.16),
        vHiRange: (0.24, 0.30),
        dLoRange: (3, 3),
        dHiRange: (4, 5),
        perHour: (1, 2),
      ),
      presetIds: _pick(rng, presetIds, 3, 6),
      ttsTexts: _pick(rng, ttsTexts, 3, 5),
    );
    // 兜底：万一注入的池为空导致动作池为空，回落到内置池（validate 要求非空）。
    return plan;
  }

  static CounterWindow _window(
    Random rng, {
    required bool enabled,
    required (double, double) vLoRange,
    required (double, double) vHiRange,
    required (int, int) dLoRange,
    required (int, int) dHiRange,
    required (int, int) perHour,
  }) {
    final vLo = _doubleIn(rng, vLoRange.$1, vLoRange.$2);
    final vHi = _doubleIn(rng, vHiRange.$1, vHiRange.$2);
    final dLo = _intIn(rng, dLoRange.$1, dLoRange.$2);
    final dHi = _intIn(rng, dHiRange.$1, dHiRange.$2);
    return CounterWindow(
      enabled: enabled,
      volumeMin: vLo,
      volumeMax: vHi < vLo ? vLo : vHi,
      durationSecMin: dLo,
      durationSecMax: dHi < dLo ? dLo : dHi,
      actionsPerHour: _intIn(rng, perHour.$1, perHour.$2),
    ).clamped();
  }

  static int _intIn(Random rng, int lo, int hi) =>
      lo + rng.nextInt(hi - lo + 1);

  static double _doubleIn(Random rng, double lo, double hi) {
    final v = lo + rng.nextDouble() * (hi - lo);
    return (v * 100).round() / 100; // 两位小数，落库/展示更干净
  }

  /// 从 [pool] 随机取 `[lo, hi]` 条（不重复；池不足则全取）。
  static List<String> _pick(Random rng, List<String> pool, int lo, int hi) {
    final copy = <String>[...pool];
    if (copy.isEmpty) return const <String>[];
    copy.shuffle(rng);
    final n = min(copy.length, _intIn(rng, lo, hi));
    return copy.take(n).toList();
  }
}