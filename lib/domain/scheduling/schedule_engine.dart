import 'dart:math';

import '../../core/constants.dart';
import '../../core/utils/random.dart';
import '../models/action.dart';
import '../models/task.dart';
import '../models/trigger.dart';

/// 物化结果：一条计划 + 其执行参数（音量/时长在物化期一并确定，
/// 保证「计划即审计」：重启后不漂移，日志可追溯）。
class PlannedEntry {
  const PlannedEntry({
    required this.occurrenceId,
    required this.taskId,
    required this.fireAt,
    required this.volume,
    required this.durationMs,
  });

  final String occurrenceId;
  final String taskId;
  final DateTime fireAt; // 本地时区时刻
  final double volume;
  final int durationMs;
}

/// 调度引擎（纯函数、无 I/O，可完全单测）。
///
/// 设计要点：
/// 1. 确定性随机：seed = planSeed(taskId, 计划日)，同一任务同一日的
///    随机计划在任意次重算中完全一致（重启/升级安全）。
/// 2. 滚动物化：每次生成 [now, now+planHorizon] 内的条目；
///    已提交的条目由仓库层幂等合并（同 id 不重复）。
/// 3. 免打扰（quiet hours）：命中者按 QuietPolicy 跳过或平移到免打扰结束点。
/// 4. 冷却：物化期即保证同任务相邻条目间隔 >= cooldownSec。
class ScheduleEngine {
  const ScheduleEngine(
      {this.quietStartHour = ComplianceGuardrails.defaultQuietStartHour,
      this.quietEndHour = ComplianceGuardrails.defaultQuietEndHour});

  final int quietStartHour;
  final int quietEndHour;

  /// 为任务物化未来计划。
  ///
  /// [existing] 为已提交未执行的 fireAt 集合（毫秒），用于幂等去重。
  List<PlannedEntry> materialize(
    Task task,
    DateTime now, {
    Duration horizon = SchedulerConfig.planHorizon,
    Set<int> existing = const {},
  }) {
    if (!task.enabled) return const [];
    final end = now.add(horizon);
    final List<DateTime> raw;

    switch (task.trigger) {
      case final FixedOnceTrigger t:
        raw = (t.at.isAfter(now) && !t.at.isAfter(end)) ? [t.at] : const [];
      case final DailyTrigger t:
        raw = _daily(t, now, end);
      case final WeeklyTrigger t:
        raw = _weekly(t, now, end);
      case final RandomWindowTrigger t:
        raw = _randomWindow(task.id, t, now, end);
      case final RandomIntervalTrigger t:
        raw = _randomInterval(task.id, t, now, end);
      case SoundTrigger():
        return const []; // 声音触发不进时间计划，由守卫服务实时驱动
    }

    final out = <PlannedEntry>[];
    for (final fire in raw) {
      final resolved = _applyQuiet(fire, task.quietPolicy, now);
      if (resolved == null) continue;
      final ms = resolved.millisecondsSinceEpoch;
      if (existing.contains(ms)) continue; // 幂等
      final a = task.action;
      final play = switch (a) {
        PlayAudioAction p => p,
        CompositeAction c => switch (c.primary) {
            final PlayAudioAction p => p,
            _ => null,
          },
        _ => null,
      };
      final rng = Random(planSeed('${task.id}#$ms', resolved));
      final volume = play == null
          ? 0.8
          : nextDoubleBetween(
              rng,
              play.volumeMin,
              min(play.volumeMax,
                  ComplianceGuardrails.maxMediaVolumePercent / 100));
      final durationMs = play == null
          ? 0
          : nextIntBetween(
              rng, play.durationSecMin * 1000, play.durationSecMax * 1000 + 1);
      out.add(PlannedEntry(
        occurrenceId: '${task.id}@$ms',
        taskId: task.id,
        fireAt: resolved,
        volume: volume,
        durationMs: durationMs,
      ));
    }
    out.sort((a, b) => a.fireAt.compareTo(b.fireAt));
    return _enforceCooldown(out, task.cooldownSec);
  }

  /// 免打扰处理。返回 null 表示跳过；平移目标已过期同样放弃（防唤醒后连响）。
  DateTime? _applyQuiet(DateTime fireAt, QuietPolicy policy, DateTime now) {
    final day = DateTime(fireAt.year, fireAt.month, fireAt.day);
    // 候选窗口：免打扰时段可能跨午夜（如 22:00-07:00），
    // 因此对任一时刻最多有两个“可能命中”的窗口（今晚 / 昨晚）。
    final List<(DateTime, DateTime)> windows;
    if (quietStartHour <= quietEndHour) {
      windows = [
        (
          DateTime(day.year, day.month, day.day, quietStartHour),
          DateTime(day.year, day.month, day.day, quietEndHour),
        ),
      ];
    } else {
      windows = [
        (
          DateTime(day.year, day.month, day.day, quietStartHour),
          DateTime(day.year, day.month, day.day, quietEndHour)
              .add(const Duration(days: 1)),
        ),
        (
          DateTime(day.year, day.month, day.day, quietStartHour)
              .subtract(const Duration(days: 1)),
          DateTime(day.year, day.month, day.day, quietEndHour),
        ),
      ];
    }
    for (final (qs, qe) in windows) {
      if (!fireAt.isBefore(qs) && fireAt.isBefore(qe)) {
        switch (policy) {
          case QuietPolicy.skip:
            return null;
          case QuietPolicy.shift:
            return qe.isAfter(now) ? qe : null;
        }
      }
    }
    return fireAt;
  }

  List<DateTime> _daily(DailyTrigger t, DateTime now, DateTime end) {
    if (t.dateRange != null) {
      final days =
          t.dateRange!.days().where((d) => t.dateRange!.contains(d)).toList();
      return [
        for (final d in days)
          if (_inRange(t.time.on(d), now, end)) t.time.on(d),
      ];
    }
    final out = <DateTime>[];
    var day = DateTime(now.year, now.month, now.day);
    final last = DateTime(end.year, end.month, end.day);
    while (!day.isAfter(last)) {
      final at = t.time.on(day);
      if (_inRange(at, now, end)) out.add(at);
      day = day.add(const Duration(days: 1));
    }
    return out;
  }

  List<DateTime> _weekly(WeeklyTrigger t, DateTime now, DateTime end) {
    final out = <DateTime>[];
    var day = DateTime(now.year, now.month, now.day);
    final last = DateTime(end.year, end.month, end.day);
    while (!day.isAfter(last)) {
      final iso = day.weekday; // Dart: 1=Mon..7=Sun
      if (t.weekdays.contains(iso)) {
        final at = t.time.on(day);
        final inRange = t.dateRange == null || t.dateRange!.contains(day);
        if (inRange && _inRange(at, now, end)) out.add(at);
      }
      day = day.add(const Duration(days: 1));
    }
    return out;
  }

  List<DateTime> _randomWindow(
      String taskId, RandomWindowTrigger t, DateTime now, DateTime end) {
    final out = <DateTime>[];
    for (final day in t.dateRange.days()) {
      final winStart = t.windowStart.on(day);
      final winEnd = t.windowEnd.on(day).add(
            t.windowEndNextDay ? const Duration(days: 1) : Duration.zero,
          );
      if (winEnd.isBefore(winStart)) continue;
      final clampedStart = winStart.isBefore(now) ? now : winStart;
      if (winEnd.isBefore(clampedStart)) continue;
      final rng = Random(planSeed(taskId, day));
      final window = winEnd.difference(clampedStart);
      final offsets = sampleInWindow(
        n: t.timesPerDay,
        window: window,
        minGap: t.minGap,
        rng: rng,
      );
      for (final off in offsets) {
        final at = clampedStart.add(off);
        if (_inRange(at, now, end)) out.add(at);
      }
    }
    return out;
  }

  List<DateTime> _randomInterval(
      String taskId, RandomIntervalTrigger t, DateTime now, DateTime end) {
    final out = <DateTime>[];
    for (final day in t.dateRange.days()) {
      final dayStart = t.activeStart.on(day);
      final dayEnd = t.activeEnd.on(day).add(
            t.activeEnd.hour <= t.activeStart.hour
                ? const Duration(days: 1)
                : Duration.zero,
          );
      final clamped = dayStart.isBefore(now) ? now : dayStart;
      if (!dayEnd.isAfter(clamped)) continue;
      final rng = Random(planSeed('$taskId#interval', day));
      var cursor = clamped;
      var count = 0;
      while (cursor.isBefore(dayEnd) && count < t.maxPerDay) {
        // 首点在活动窗口内随机，其后按随机间隔推进。
        final gap = Duration(
          milliseconds: nextIntBetween(
            rng,
            t.minGap.inMilliseconds,
            t.maxGap.inMilliseconds + 1,
          ),
        );
        cursor = count == 0
            ? clamped.add(Duration(
                milliseconds: rng.nextInt(
                dayEnd.difference(clamped).inMilliseconds ~/
                        (t.maxPerDay <= 1 ? 1 : t.maxPerDay) +
                    1,
              )))
            : cursor.add(gap);
        if (cursor.isAfter(dayEnd)) break;
        if (_inRange(cursor, now, end)) out.add(cursor);
        count++;
      }
    }
    return out;
  }

  bool _inRange(DateTime t, DateTime now, DateTime end) =>
      !t.isBefore(now) && !t.isAfter(end);

  /// 冷却约束：相邻间隔 < cooldown 的后者删除（保留优先第一条）。
  List<PlannedEntry> _enforceCooldown(
      List<PlannedEntry> entries, int cooldownSec) {
    if (cooldownSec <= 0 || entries.length < 2) return entries;
    final minGap = Duration(
        seconds: max(cooldownSec, ComplianceGuardrails.minCooldownSeconds));
    final out = <PlannedEntry>[entries.first];
    for (final e in entries.skip(1)) {
      if (e.fireAt.difference(out.last.fireAt) >= minGap) out.add(e);
    }
    return out;
  }
}
