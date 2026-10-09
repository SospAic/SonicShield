/// 本机"按规则随机"生成反击计划（不调 AI，离线可用）。
///
/// ## 与 AI 生成的关系
/// 两条路产出**同一个 [CounterPlan] 结构**、遵守**同一份生成参数**
/// （[CounterPlanParams]）：
/// - 生成时在参数给定的**区间内**随机取值（音量 / 时长 / 每小时次数）；
/// - 参数还可控制四个时段是否参与（休息日两段默认关闭 = 可选）、
///   白天起止小时、两次动作的最小间隔区间；
/// - 差别只在"谁来挑具体数值"：本文件用 [Random] 在区间内取值，AI 用提示词。
/// 因此二者可以互相导入、互相下发，且**离线一定有可用计划**（AI 不可用时不空转）。
///
/// ## 随机但不失约束
/// 每个窗口先在参数区间内取**下限**，再在 `[下限, 参数上限]` 内取**上限**
/// ——不是"先随机再校验"，从而不会随机出 `volumeMin > volumeMax` 这类
/// 自相矛盾的窗口（AI 侧由 [CounterPlan.fromJson] 的夹紧兜底）。
library;

import 'dart:math';

import '../models/counter_plan.dart';
import '../models/counter_plan_params.dart';

abstract final class CounterPlanRandom {
  /// 「招人烦」预置音效池（复用 [CounterPlan.defaultPresetIds]，单一真源）。
  static const List<String> annoyPresets = CounterPlan.defaultPresetIds;

  /// 可选 TTS 文案池（复用 [CounterPlan.defaultTtsTexts]）。
  static const List<String> ttsPool = CounterPlan.defaultTtsTexts;

  /// 按 [params] 生成一份合规计划。
  ///
  /// [seed] 非空 ⇒ 完全可复现（测试用）。[params] 为空时用
  /// [CounterPlanParams.defaults]（= 出厂约定区间）。
  ///
  /// [restdayDay]/[restdayNight] 非空时**覆盖**参数里对应时段的开关
  /// （保留旧调用点的简洁写法）；[presetIds]/[ttsTexts] 同理覆盖动作池。
  static CounterPlan generate({
    int? seed,
    String name = '本机随机反击计划',
    CounterPlanParams? params,
    bool? restdayDay,
    bool? restdayNight,
    List<String>? presetIds,
    List<String>? ttsTexts,
  }) {
    final p = (params ?? CounterPlanParams.defaults()).clamped();
    final rng = Random(seed);

    CounterPlanParams eff = p;
    if (restdayDay != null) {
      eff = eff.copyWith(restdayDay: eff.restdayDay.copyWith(enabled: restdayDay));
    }
    if (restdayNight != null) {
      eff = eff.copyWith(
          restdayNight: eff.restdayNight.copyWith(enabled: restdayNight));
    }
    final pool = presetIds ?? eff.presetIds;
    final texts = ttsTexts ?? eff.ttsTexts;

    final lo = min(eff.cooldownSecMin, eff.cooldownSecMax);
    final hi = max(eff.cooldownSecMin, eff.cooldownSecMax);

    return CounterPlan(
      name: name,
      dayStartHour: eff.dayStartHour,
      dayEndHour: eff.dayEndHour,
      cooldownSec: _intIn(rng, lo, hi),
      respectQuietHours: eff.respectQuietHours,
      workdayDay: _window(rng, eff.workdayDay),
      workdayNight: _window(rng, eff.workdayNight),
      restdayDay: _window(rng, eff.restdayDay),
      restdayNight: _window(rng, eff.restdayNight),
      presetIds: _pick(rng, pool, 3, 6),
      ttsTexts: _pick(rng, texts, 3, 5),
      voiceId: eff.voiceId,
      // 排期参数由生成参数**原样带入**产物（不在随机区间内抽值）。
      scheduleMode: eff.scheduleMode,
      occurrenceCount: eff.occurrenceCount,
      spanDays: eff.spanDays,
      specificDate: eff.specificDate,
      rangeStart: eff.rangeStart,
      rangeEnd: eff.rangeEnd,
      weekdays: eff.weekdays,
    );
  }

  /// 在 [w] 给定的各区间内随机取一组具体值（下限先取、上限再取 ⇒ 恒 min ≤ max）。
  static CounterWindow _window(Random rng, PlanWindowParams w) {
    final vLo = _doubleIn(rng, w.volumeMin, w.volumeMax);
    final vHi = _doubleIn(rng, vLo, w.volumeMax);
    final dLo = _intIn(rng, w.durationSecMin, w.durationSecMax);
    final dHi = _intIn(rng, dLo, w.durationSecMax);
    final aLo = _intIn(rng, w.actionsPerHourMin, w.actionsPerHourMax);
    return CounterWindow(
      enabled: w.enabled,
      volumeMin: vLo,
      volumeMax: vHi < vLo ? vLo : vHi,
      durationSecMin: dLo,
      durationSecMax: dHi < dLo ? dLo : dHi,
      actionsPerHour: aLo,
      // 动作配比是"导向"而非抖动项：**原样带入**产物窗口（不随机）。
      ttsWeight: w.ttsWeight,
      vibrateWeight: w.vibrateWeight,
      vibrateAmplitudeMin: w.vibrateAmplitudeMin,
      vibrateAmplitudeMax: w.vibrateAmplitudeMax,
    ).clamped();
  }

  static int _intIn(Random rng, int lo, int hi) {
    final a = min(lo, hi), b = max(lo, hi);
    return a + rng.nextInt(b - a + 1);
  }

  static double _doubleIn(Random rng, double lo, double hi) {
    final a = min(lo, hi), b = max(lo, hi);
    final v = a + rng.nextDouble() * (b - a);
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
