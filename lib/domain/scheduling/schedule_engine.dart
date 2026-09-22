import 'dart:math';

import '../../core/constants.dart';
import '../../core/utils/random.dart';
import '../models/action.dart';
import '../models/task.dart';
import '../models/trigger.dart';
import 'vibrate_resolve.dart';

/// 归一化用户配置的免打扰窗口（v1.9，修复 **BUG-070**）。
///
/// ## 为什么需要它
/// 设置页把用户选择的起止小时写进 `SharedPreferences`，但**执行路径从不读取**：
/// `background_engine.replan()` 与 `endpoint_service._rematerialize()` 都直接
/// `ScheduleEngine()`（默认 22:00–07:00）。结果是"界面在说谎"——
/// 用户把窗口调窄，回显变了、落库也变了，**行为一点没变**。
///
/// 本函数是"从原始 int 到引擎参数"的唯一转换点，由服务层调用；
/// 放在 domain 层是为了保持**纯函数、可单测**（不 import shared_preferences）。
///
/// ## 归一化规则（合规护栏不得被损坏配置绕过）
/// - 合法区间 `[0, 23]`；越界或缺失 → **回落合规默认**（22:00–07:00），
///   而不是夹到边界。读不懂的值说明配置已损坏，此时"回到默认"比
///   "猜一个边界值"更可预期；且默认值位于护栏最严的一侧。
/// - `start == end` 视为**空窗口**（引擎会判成零长度 → 免打扰完全失效），
///   同样回落默认。这一条是护栏的兜底：不允许配置把护栏整体关掉。
({int start, int end}) normalizeQuietWindow(int? start, int? end) {
  bool valid(int? v) => v != null && v >= 0 && v <= 23;
  final s = valid(start) ? start! : ComplianceGuardrails.defaultQuietStartHour;
  final e = valid(end) ? end! : ComplianceGuardrails.defaultQuietEndHour;
  if (s == e) {
    return (
      start: ComplianceGuardrails.defaultQuietStartHour,
      end: ComplianceGuardrails.defaultQuietEndHour,
    );
  }
  return (start: s, end: e);
}

/// 物化结果：一条计划 + 其执行参数（音量/时长在物化期一并确定，
/// 保证「计划即审计」：重启后不漂移，日志可追溯）。
class PlannedEntry {
  const PlannedEntry({
    required this.occurrenceId,
    required this.taskId,
    required this.fireAt,
    required this.volume,
    required this.durationMs,
    this.quietExempted = false,
  });

  final String occurrenceId;
  final String taskId;
  final DateTime fireAt; // 本地时区时刻
  final double volume;
  final int durationMs;

  /// 本条计划是**因夜间独立豁免**才得以在免打扰时段存活（v1.9，docs/20 §8）。
  ///
  /// 落库后由执行层写一条 `action='quietExempt'` 审计 —— 豁免是**削弱护栏**
  /// 的行为，必须可计数、可回溯（docs/20 §8.2 约束 2：不得静默生效）。
  final bool quietExempted;
}

/// 调度引擎（纯函数、无 I/O，可完全单测）。
///
/// 设计要点：
/// 1. 确定性随机：seed = planSeed(taskId, 计划日)，同一任务同一日的
///    随机计划在任意次重算中完全一致（重启/升级安全）。
/// 2. 滚动物化：每次生成 [now, now+planHorizon] 内的条目；
///    已提交的条目由仓库层幂等合并（同 id 不重复）。
/// 3. 免打扰（quiet hours）：命中者按 QuietPolicy 跳过或平移到免打扰结束点。
///    例外：**双重开关皆开**的夜间独立豁免（v1.9，docs/20 §8）。
/// 4. 冷却：物化期即保证同任务相邻条目间隔 >= cooldownSec。
class ScheduleEngine {
  const ScheduleEngine(
      {this.quietStartHour = ComplianceGuardrails.defaultQuietStartHour,
      this.quietEndHour = ComplianceGuardrails.defaultQuietEndHour,
      this.allowQuietExempt = false});

  final int quietStartHour;
  final int quietEndHour;

  /// **主开关**：用户是否授权"夜间独立豁免"。
  ///
  /// 默认 false。与任务级 [Task.quietExempt] 构成 Two-Key Safety：
  /// 只有两者**同时**为真，命中免打扰时段的计划才会被放行。
  /// 单独置真不生效 —— 任一把钥匙丢失即回到受约束状态（fail-safe 方向）。
  final bool allowQuietExempt;

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
      final quiet = _applyQuiet(fire, task.quietPolicy, now,
          taskExempt: task.quietExempt);
      if (quiet == null) continue;
      final resolved = quiet.at;
      final ms = resolved.millisecondsSinceEpoch;
      if (existing.contains(ms)) continue; // 幂等
      final a = task.action;
      // 组合动作的"主动作"才是真正要执行的东西（v1.9：振动也要穿透 composite）。
      final primary = switch (a) {
        CompositeAction c => c.primary,
        _ => a,
      };
      final play = switch (primary) {
        final PlayAudioAction p => p,
        _ => null,
      };
      final rng = Random(planSeed('${task.id}#$ms', resolved));
      final occurrenceId = '${task.id}@$ms';
      // 振动动作：物化期敲定「总时长 + 基准强度 + 波动种子」（docs/20 §4.4）。
      // ⚠️ 必须放在音量/时长分支**之前**：非振动动作时它不消耗 rng，
      // 因此不改变既有动作的随机序列（向后兼容）。
      final vib = resolveVibratePlan(primary, rng, occurrenceId);
      final double volume;
      final int durationMs;
      if (vib != null) {
        volume = vib.baseAmplitude;
        durationMs = vib.durationMs;
      } else if (play != null) {
        volume = nextDoubleBetween(
            rng,
            play.volumeMin,
            min(play.volumeMax,
                ComplianceGuardrails.maxMediaVolumePercent / 100));
        durationMs = nextIntBetween(
            rng, play.durationSecMin * 1000, play.durationSecMax * 1000 + 1);
      } else {
        volume = 0.8;
        durationMs = 0;
      }
      out.add(PlannedEntry(
        occurrenceId: occurrenceId,
        taskId: task.id,
        fireAt: resolved,
        volume: volume,
        durationMs: durationMs,
        quietExempted: quiet.exempted,
      ));
    }
    out.sort((a, b) => a.fireAt.compareTo(b.fireAt));
    return _enforceCooldown(out, task.cooldownSec);
  }

  /// 免打扰处理。返回 null 表示跳过；平移目标已过期同样放弃（防唤醒后连响）。
  ///
  /// 返回值额外带 `exempted`：本条之所以**没有**被跳过/平移，是因为用户开了
  /// 夜间独立豁免。执行层据此写审计（docs/20 §8.2 约束 2）。
  ({DateTime at, bool exempted})? _applyQuiet(
    DateTime fireAt,
    QuietPolicy policy,
    DateTime now, {
    required bool taskExempt,
  }) {
    // Two-Key Safety：主开关（本引擎的 allowQuietExempt）与任务级开关（taskExempt）
    // **同时**为真才放行。任一为假 → 走原有 skip/shift 逻辑。
    final exempt = allowQuietExempt && taskExempt;
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
        if (exempt) return (at: fireAt, exempted: true);
        switch (policy) {
          case QuietPolicy.skip:
            return null;
          case QuietPolicy.shift:
            return qe.isAfter(now) ? (at: qe, exempted: false) : null;
        }
      }
    }
    return (at: fireAt, exempted: false);
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
