import 'dart:ui';

/// 触发方式。
enum TriggerType {
  fixedOnce, // 固定一次
  dailyAt, // 每天固定时刻
  weeklyAt, // 每周固定星期+时刻
  randomWindow, // 随机日期范围 × 每日随机 N 次于时间窗内
  randomInterval, // 随机间隔滚动触发
  soundTriggered; // 声音触发（守卫模式）

  String get label => switch (this) {
        TriggerType.fixedOnce => '固定一次',
        TriggerType.dailyAt => '每天定时',
        TriggerType.weeklyAt => '每周定时',
        TriggerType.randomWindow => '随机窗口',
        TriggerType.randomInterval => '随机间隔',
        TriggerType.soundTriggered => '声音触发',
      };
}

/// 时间窗/时刻（用毫秒存分秒，避免引入 TimeOfDay 依赖到数据层）。
class TimeSpec {
  const TimeSpec({required this.hour, this.minute = 0})
      : assert(hour >= 0 && hour < 24),
        assert(minute >= 0 && minute < 60);

  final int hour;
  final int minute;

  factory TimeSpec.fromJson(Map<String, dynamic> j) => TimeSpec(
        hour: (j['hour'] as num).toInt(),
        minute: (j['minute'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {'hour': hour, 'minute': minute};

  /// 当天该时刻的本地 DateTime。
  DateTime on(DateTime day) =>
      DateTime(day.year, day.month, day.day, hour, minute);
}

/// 日期范围（含端点，本地时区）。
class DateRange {
  const DateRange({required this.start, required this.end});

  final DateTime start; // y-m-d
  final DateTime end;

  factory DateRange.fromJson(Map<String, dynamic> j) => DateRange(
        start: DateTime.parse(j['start'] as String),
        end: DateTime.parse(j['end'] as String),
      );

  Map<String, dynamic> toJson() => {'start': _d(start), 'end': _d(end)};

  bool contains(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return !d.isBefore(DateTime(start.year, start.month, start.day)) &&
        !d.isAfter(DateTime(end.year, end.month, end.day));
  }

  /// 逐**日历日**（当地时区）遍历 `[start, end]`（含端点）。
  ///
  /// P2-29：旧写法用 `d.add(const Duration(days: 1))` —— 固定加 24 小时。
  /// 在启用夏令时的设备本地时区里，"回拨日"从当天午夜到次日午夜是 **25 小时**：
  /// 午夜 00:00 加 24h 会落在**当天 23:00**（仍是同一天），循环于是**重复上一日**
  /// 并可能**跳过日期范围末日**。改为按日历构造次日午夜
  /// （`DateTime(y, m, day + 1)` 由 Dart 自动归一并保持本地午夜语义），
  /// 无论当天是 23/24/25 小时都严格前进一步。
  Iterable<DateTime> days() sync* {
    var d = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    while (!d.isAfter(e)) {
      yield d;
      d = DateTime(d.year, d.month, d.day + 1);
    }
  }

  static String _d(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

/// 免打扰命中时的处理策略。
enum QuietPolicy { skip, shift }

/// 触发配置（sealed：编译期穷举）。
sealed class TriggerConfig {
  const TriggerConfig();

  Map<String, dynamic> toJson();

  static TriggerConfig fromJson(Map<String, dynamic> j) => switch (j['kind']) {
        'fixedOnce' => FixedOnceTrigger.fromJson(j),
        'dailyAt' => DailyTrigger.fromJson(j),
        'weeklyAt' => WeeklyTrigger.fromJson(j),
        'randomWindow' => RandomWindowTrigger.fromJson(j),
        'randomInterval' => RandomIntervalTrigger.fromJson(j),
        'sound' => SoundTrigger.fromJson(j),
        _ => throw ArgumentError('未知触发类型: ${j['kind']}'),
      };
}

class FixedOnceTrigger extends TriggerConfig {
  const FixedOnceTrigger({required this.at});

  final DateTime at; // 瞬时（本地 DateTime，但语义是"绝对时刻"）

  /// 反解：**带偏移/带 Z 的字符串按瞬时解释并转本地；无偏移的老字符串按本地墙钟**。
  ///
  /// ## DAT-10：为什么必须区分两种形态
  /// 旧实现 `toIso8601String()` 对本地 `DateTime` **不带偏移**（`2026-11-01T08:00:00.000`），
  /// 而 `DateTime.parse` 在**读回时**用当时的本地时区解释它。于是用户换时区后，
  /// "固定一次 08:00"会**平移**（+8 区写入、+9 区读出 ⇒ 实际 23:00Z 前一天），
  /// 与"固定一次"的直觉相反；而已落库的 occurrence 是 epoch（绝对时刻）不平移 ——
  /// 两者混用导致"改时区后第一次响的时刻取决于有没有触发 replan"。
  ///
  /// 新写入统一带 `Z`（见 [toJson]），读侧因此可以**按字符串形态分派**：
  /// - 有 `Z` 或 `±HH:MM` 偏移 → 是瞬时，`parse` 后 `toLocal()`；
  /// - 无偏移 → 是**老数据**（墙钟语义），保持 `parse` 的本地解释，
  ///   与升级前行为一致（不做一次性迁移：老数据的墙钟意图本身就是"本地 8 点"）。
  factory FixedOnceTrigger.fromJson(Map<String, dynamic> j) =>
      FixedOnceTrigger(at: _parseWallOrInstant(j['at'] as String));

  @override
  Map<String, dynamic> toJson() =>
      // 写 UTC 瞬时（带 Z）：跨时区/夏令时都不再漂移。
      {'kind': 'fixedOnce', 'at': at.toUtc().toIso8601String()};

  /// 见 [FixedOnceTrigger.fromJson] 的说明。
  static DateTime _parseWallOrInstant(String s) {
    final hasZone = s.endsWith('Z') ||
        s.endsWith('z') ||
        RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s);
    final d = DateTime.parse(s);
    return hasZone ? d.toLocal() : d;
  }
}

class DailyTrigger extends TriggerConfig {
  const DailyTrigger({required this.time, this.dateRange});

  final TimeSpec time;
  final DateRange? dateRange; // null = 长期有效

  factory DailyTrigger.fromJson(Map<String, dynamic> j) => DailyTrigger(
        time: TimeSpec.fromJson(j['time'] as Map<String, dynamic>),
        dateRange: j['dateRange'] == null
            ? null
            : DateRange.fromJson(j['dateRange'] as Map<String, dynamic>),
      );

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'dailyAt',
        'time': time.toJson(),
        if (dateRange != null) 'dateRange': dateRange!.toJson(),
      };
}

class WeeklyTrigger extends TriggerConfig {
  const WeeklyTrigger(
      {required this.weekdays, required this.time, this.dateRange});

  final Set<int> weekdays; // 1=周一 ... 7=周日（ISO-8601）
  final TimeSpec time;
  final DateRange? dateRange;

  factory WeeklyTrigger.fromJson(Map<String, dynamic> j) => WeeklyTrigger(
        weekdays:
            (j['weekdays'] as List).map((e) => (e as num).toInt()).toSet(),
        time: TimeSpec.fromJson(j['time'] as Map<String, dynamic>),
        dateRange: j['dateRange'] == null
            ? null
            : DateRange.fromJson(j['dateRange'] as Map<String, dynamic>),
      );

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'weeklyAt',
        'weekdays': weekdays.toList(),
        'time': time.toJson(),
        if (dateRange != null) 'dateRange': dateRange!.toJson(),
      };
}

/// 随机窗口：在 [dateRange] 的每一天，从 timeOfDay 窗口内随机抽 [timesPerDay]
/// 个时刻，相邻时刻间隔不小于 minGap；随机时长/音量在 ActionConfig 中定义。
class RandomWindowTrigger extends TriggerConfig {
  const RandomWindowTrigger({
    required this.dateRange,
    required this.windowStart,
    required this.windowEnd,
    required this.timesPerDay,
    this.minGap = const Duration(minutes: 30),
    this.windowEndNextDay = false, // 窗口可跨午夜（如 20:00-02:00）
  });

  final DateRange dateRange;
  final TimeSpec windowStart;
  final TimeSpec windowEnd;
  final int timesPerDay;
  final Duration minGap;
  final bool windowEndNextDay;

  factory RandomWindowTrigger.fromJson(Map<String, dynamic> j) =>
      RandomWindowTrigger(
        dateRange: DateRange.fromJson(j['dateRange'] as Map<String, dynamic>),
        windowStart:
            TimeSpec.fromJson(j['windowStart'] as Map<String, dynamic>),
        windowEnd: TimeSpec.fromJson(j['windowEnd'] as Map<String, dynamic>),
        timesPerDay: (j['timesPerDay'] as num).toInt(),
        minGap: Duration(seconds: (j['minGapSec'] as num? ?? 1800).toInt()),
        windowEndNextDay: j['windowEndNextDay'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'randomWindow',
        'dateRange': dateRange.toJson(),
        'windowStart': windowStart.toJson(),
        'windowEnd': windowEnd.toJson(),
        'timesPerDay': timesPerDay,
        'minGapSec': minGap.inSeconds,
        'windowEndNextDay': windowEndNextDay,
      };
}

/// 随机间隔：进入活动期后，每隔 [minGap, maxGap] 均匀随机触发一次，
/// 仅在活动窗口（每日）内生效。种子=taskId+day，重启后计划一致。
class RandomIntervalTrigger extends TriggerConfig {
  const RandomIntervalTrigger({
    required this.dateRange,
    required this.minGap,
    required this.maxGap,
    this.activeStart = const TimeSpec(hour: 0, minute: 0),
    this.activeEnd = const TimeSpec(hour: 23, minute: 59),
    this.maxPerDay = 8,
  });

  final DateRange dateRange;
  final Duration minGap;
  final Duration maxGap;
  final TimeSpec activeStart;
  final TimeSpec activeEnd;
  final int maxPerDay;

  factory RandomIntervalTrigger.fromJson(Map<String, dynamic> j) =>
      RandomIntervalTrigger(
        dateRange: DateRange.fromJson(j['dateRange'] as Map<String, dynamic>),
        minGap: Duration(seconds: (j['minGapSec'] as num).toInt()),
        maxGap: Duration(seconds: (j['maxGapSec'] as num).toInt()),
        activeStart: j['activeStart'] == null
            ? const TimeSpec(hour: 0, minute: 0)
            : TimeSpec.fromJson(j['activeStart'] as Map<String, dynamic>),
        activeEnd: j['activeEnd'] == null
            ? const TimeSpec(hour: 23, minute: 59)
            : TimeSpec.fromJson(j['activeEnd'] as Map<String, dynamic>),
        maxPerDay: (j['maxPerDay'] as num? ?? 8).toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'randomInterval',
        'dateRange': dateRange.toJson(),
        'minGapSec': minGap.inSeconds,
        'maxGapSec': maxGap.inSeconds,
        'activeStart': activeStart.toJson(),
        'activeEnd': activeEnd.toJson(),
        'maxPerDay': maxPerDay,
      };
}

/// 声音触发：麦克风守卫检测到满足条件的声音事件后执行动作。
/// 仅支持能量阈值（v1）；YAMNet 声音分类见路线图 v2。
class SoundTrigger extends TriggerConfig {
  const SoundTrigger({
    this.thresholdDb = -35, // 相对满量程 dBFS
    this.minDurationMs = 800, // 持续超过该时长才算事件
    this.cooldownSec = 120, // 触发冷却，防连环执行
    this.onlyWhileCharging = false,
  });

  final double thresholdDb;
  final int minDurationMs;
  final int cooldownSec;
  final bool onlyWhileCharging;

  factory SoundTrigger.fromJson(Map<String, dynamic> j) => SoundTrigger(
        thresholdDb: (j['thresholdDb'] as num? ?? -35).toDouble(),
        minDurationMs: (j['minDurationMs'] as num? ?? 800).toInt(),
        cooldownSec: (j['cooldownSec'] as num? ?? 120).toInt(),
        onlyWhileCharging: j['onlyWhileCharging'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'sound',
        'thresholdDb': thresholdDb,
        'minDurationMs': minDurationMs,
        'cooldownSec': cooldownSec,
        'onlyWhileCharging': onlyWhileCharging,
      };
}

/// 判断本地时刻是否落在时间窗内（支持跨午夜窗口）。
bool inDailyWindow(TimeSpec start, TimeSpec end, bool endNextDay, DateTime t) {
  final cur = t.hour * 60 + t.minute;
  final s = start.hour * 60 + start.minute;
  final e = end.hour * 60 + end.minute;
  if (!endNextDay) return cur >= s && cur < e;
  if (s < e) return cur >= s && cur < e;
  return cur >= s || cur < e;
}

/// 平移跨过免打扰时段到窗口结束点；返回 null 表示应跳过。
DateTime? resolveQuiet(DateTime fireAt, DateTime quietStart, DateTime quietEnd,
    QuietPolicy policy) {
  final hit = !fireAt.isBefore(quietStart) && fireAt.isBefore(quietEnd);
  if (!hit) return fireAt;
  switch (policy) {
    case QuietPolicy.skip:
      return null;
    case QuietPolicy.shift:
      return quietEnd;
  }
}

/// 与 Color 互转工具（供 UI 使用）。
Color lerpColorSafe(Color a, Color b, double t) => Color.lerp(a, b, t)!;
