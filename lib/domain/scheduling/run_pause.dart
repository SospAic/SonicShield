/// 「全局执行总开关（节假日自动暂停）」的判定（**纯函数、无 I/O，可完全单测**）。
///
/// ## 语义
/// 总开关是三态（[RunMasterMode]）：
/// - `auto`（默认）：落在**暂停窗口**内即暂停，否则运行；
/// - `on`（强制开启）：始终运行（即使在暂停窗口内）；
/// - `off`（强制关闭）：始终暂停。
///
/// ## 暂停窗口
/// 围绕每个「连续休息日块」`[S, E]`（由 `ChinaHolidays` 判定的 `restday`，
/// **含普通周末**）：窗口 = `[S 前一天 20:00, E 当天 21:00)`。
/// 通俗说 = 「法定休息日前一天晚上 8 点 → 休息日最后一天晚上 9 点」；
/// 半开区间 ⇒ 20:00 整点进入暂停、21:00 整点恢复执行。
///
/// 逐日判定即可，**不需要枚举"块"**（见 [inWindow]）：
/// | 当天 | 次日 | 是否在窗口 |
/// |---|---|---|
/// | 非休息日 | 休息日 | `>= 当天 20:00`（假期前夜） |
/// | 休息日 | 休息日 | 恒 true（块中间） |
/// | 休息日 | 非休息日 | `< 当天 21:00`（块最后一天） |
/// | 非休息日 | 非休息日 | false |
///
/// 校验：普通周末（周六+周日）→ 周五 20:00 → 周日 21:00；
/// 国庆（10/1–10/7）→ 9/30 20:00 → 10/7 21:00；
/// 元旦单日 → 12/31 20:00 → 1/1 21:00。
///
/// ## 为什么复用 `ChinaHolidays` 的覆盖表
/// 手动/联网下发的逐日覆盖（`CounterPlanStore.overrides()/autoOverrides()`）与
/// 反击计划**共用同一份判定** —— 否则"用户把某天改成工作日"只影响一处，
/// 两处行为不一致。
library;

import '../models/counter_plan.dart';
import 'china_holidays.dart';

/// 全局执行总开关的模式。
enum RunMasterMode {
  auto('自动'),
  on('强制开启'),
  off('强制关闭');

  const RunMasterMode(this.label);

  /// 中文标签（UI 展示）。
  final String label;

  /// 容错解析（读不懂 → [auto]，与出厂默认一致，**不抛**）。
  static RunMasterMode parse(Object? raw) {
    if (raw is RunMasterMode) return raw;
    if (raw is String) {
      final t = raw.trim().toLowerCase();
      for (final m in values) {
        if (m.name == t) return m;
      }
    }
    return RunMasterMode.auto;
  }
}

abstract final class RunPause {
  RunPause._();

  /// 窗口起点钟点（休息日前一天）：20:00。
  static const int windowStartHour = 20;

  /// 窗口终点钟点（休息日最后一天）：21:00。
  static const int windowEndHour = 21;

  /// [nextStart] / [nextTransition] 的扫描上限（天），足够跨越任意连休。
  static const int scanLimitDays = 400;

  /// [at] 是否落在暂停窗口内。
  static bool inWindow(
    DateTime at, {
    Map<String, DayKind>? overrides,
    Map<String, DayKind>? autoOverrides,
  }) {
    final day = DateTime(at.year, at.month, at.day);
    final next = DateTime(at.year, at.month, at.day + 1);
    final dayRest = _isRest(day, overrides, autoOverrides);
    final nextRest = _isRest(next, overrides, autoOverrides);
    if (!dayRest && nextRest) {
      // 假期前夜：当天 20:00 起。
      return !at.isBefore(DateTime(day.year, day.month, day.day, windowStartHour));
    }
    if (dayRest && nextRest) return true; // 块中间：全天
    if (dayRest && !nextRest) {
      // 块最后一天：当天 21:00 前。
      return at.isBefore(DateTime(day.year, day.month, day.day, windowEndHour));
    }
    return false;
  }

  /// [at] 当前所在窗口的**结束时刻**（不在窗口内 → null）。
  static DateTime? windowEnd(
    DateTime at, {
    Map<String, DayKind>? overrides,
    Map<String, DayKind>? autoOverrides,
  }) {
    if (!inWindow(at, overrides: overrides, autoOverrides: autoOverrides)) {
      return null;
    }
    // 自当日起向后走到「连续休息日的最后一天」，其当天 21:00 即窗口终点。
    var d = DateTime(at.year, at.month, at.day);
    while (_isRest(DateTime(d.year, d.month, d.day + 1), overrides, autoOverrides)) {
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return DateTime(d.year, d.month, d.day, windowEndHour);
  }

  /// [at] 之后的**下一个窗口开始时刻**（未来无窗口 → null）。
  static DateTime? nextStart(
    DateTime at, {
    Map<String, DayKind>? overrides,
    Map<String, DayKind>? autoOverrides,
  }) {
    for (var i = 0; i < scanLimitDays; i++) {
      final d = DateTime(at.year, at.month, at.day + i);
      final start = DateTime(d.year, d.month, d.day, windowStartHour);
      if (!start.isAfter(at) ||
          _isRest(d, overrides, autoOverrides) ||
          !_isRest(DateTime(d.year, d.month, d.day + 1), overrides, autoOverrides)) {
        continue;
      }
      return start;
    }
    return null;
  }

  /// 有效暂停判定：`auto` 跟随窗口、`on` 恒运行、`off` 恒暂停。
  static bool paused(
    RunMasterMode mode,
    DateTime at, {
    Map<String, DayKind>? overrides,
    Map<String, DayKind>? autoOverrides,
  }) =>
      switch (mode) {
        RunMasterMode.auto =>
          inWindow(at, overrides: overrides, autoOverrides: autoOverrides),
        RunMasterMode.on => false,
        RunMasterMode.off => true,
      };

  /// 下一次**自动**状态切换时刻（供 UI 显示「下次切换」）。
  ///
  /// 强制 on/off 不会自动切换 → null；auto 模式下：暂停中给窗口终点，
  /// 运行中给下一个窗口起点。
  static DateTime? nextTransition(
    RunMasterMode mode,
    DateTime at, {
    Map<String, DayKind>? overrides,
    Map<String, DayKind>? autoOverrides,
  }) {
    if (mode != RunMasterMode.auto) return null;
    return inWindow(at, overrides: overrides, autoOverrides: autoOverrides)
        ? windowEnd(at, overrides: overrides, autoOverrides: autoOverrides)
        : nextStart(at, overrides: overrides, autoOverrides: autoOverrides);
  }

  static bool _isRest(
    DateTime d,
    Map<String, DayKind>? overrides,
    Map<String, DayKind>? autoOverrides,
  ) =>
      ChinaHolidays.dayKind(d, overrides: overrides, autoOverrides: autoOverrides) ==
      DayKind.restday;
}
