import 'dart:convert';

/// 任务执行前置条件层（v1.3，借鉴 Tasker/MacroDroid 的条件段）。
///
/// 满足全部已配置条件才允许执行；任一不满足 → 计划标 skipped（审计留痕）。
/// v1.3 覆盖：充电状态 / 最低电量 / 每日时段窗口。
/// Wi-Fi 条件需 connectivity_plus 依赖，列入 v1.4（避免本轮加依赖）。
class TaskCondition {
  const TaskCondition({
    this.requireCharging = false,
    this.minBatteryPct,
    this.windowStartMin,
    this.windowEndMin,
    this.windowEndNextDay = false,
  });

  final bool requireCharging; // 仅充电时执行
  final int? minBatteryPct; // 电量 ≥ 此值（0-100，null 不限制）
  final int? windowStartMin; // 每日时段窗口（分钟 0-1439，含端点）
  final int? windowEndMin;
  final bool windowEndNextDay;

  bool get hasAny =>
      requireCharging || minBatteryPct != null || windowStartMin != null;

  Map<String, dynamic> toJson() => {
        'requireCharging': requireCharging,
        if (minBatteryPct != null) 'minBatteryPct': minBatteryPct,
        if (windowStartMin != null) 'windowStartMin': windowStartMin,
        if (windowEndMin != null) 'windowEndMin': windowEndMin,
        'windowEndNextDay': windowEndNextDay,
      };

  static TaskCondition? fromJsonOrNull(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return TaskCondition(
        requireCharging: j['requireCharging'] as bool? ?? false,
        minBatteryPct: (j['minBatteryPct'] as num?)?.toInt(),
        windowStartMin: (j['windowStartMin'] as num?)?.toInt(),
        windowEndMin: (j['windowEndMin'] as num?)?.toInt(),
        windowEndNextDay: j['windowEndNextDay'] as bool? ?? false,
      );
    } on Object {
      return null; // 解析失败视为无条件（不阻塞执行）
    }
  }

  /// 评估：全部条件满足返回 true；[reason] 给出首个不满足原因。
  bool evaluate({
    required bool charging,
    required int batteryLevel,
    required DateTime now,
    String? reasonOut,
  }) {
    if (requireCharging && !charging) return false;
    if (minBatteryPct != null && batteryLevel < minBatteryPct!) return false;
    if (windowStartMin != null && windowEndMin != null) {
      final cur = now.hour * 60 + now.minute;
      final s = windowStartMin!;
      final e = windowEndMin!;
      final inWindow = windowEndNextDay
          ? (s <= e ? cur >= s && cur < e : cur >= s || cur < e)
          : (s <= e ? cur >= s && cur < e : cur >= s || cur < e);
      if (!inWindow) return false;
    }
    return true;
  }

  String describe() {
    final parts = <String>[];
    if (requireCharging) parts.add('仅充电');
    if (minBatteryPct != null) parts.add('电量≥$minBatteryPct%');
    if (windowStartMin != null && windowEndMin != null) {
      String hm(int m) =>
          '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
      parts.add('${hm(windowStartMin!)}–${hm(windowEndMin!)}');
    }
    return parts.isEmpty ? '无条件' : parts.join(' · ');
  }
}
