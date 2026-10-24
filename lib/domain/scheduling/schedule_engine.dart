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
///    例外：夜间独立豁免（v79，docs/20 §8）—— 判据为
///    `exempt = taskExemptOverride ?? allowQuietExempt`（主开关即默认值 + 任务级双向覆盖）。
/// 4. 冷却：物化期即保证同任务相邻条目间隔 >= cooldownSec。
class ScheduleEngine {
  const ScheduleEngine(
      {this.quietStartHour = ComplianceGuardrails.defaultQuietStartHour,
      this.quietEndHour = ComplianceGuardrails.defaultQuietEndHour,
      this.allowQuietExempt = false});

  final int quietStartHour;
  final int quietEndHour;

  /// **主开关**：是否授权"夜间独立豁免"（v79 起为**全量默认值**）。
  ///
  /// 默认 false。任务的最终放行判据是
  /// `exempt = taskExemptOverride ?? allowQuietExempt`：
  /// - 任务级 [Task.quietExempt] 为 `null`（跟随，绝大多数任务）→ **完全由主开关决定**：
  ///   主开关开 = 默认全部任务豁免；关 = 默认全部任务不豁免。
  /// - 任务级为 `true`/`false` → **双向反向覆盖**主开关（主开关关也能强制豁免）。
  ///
  /// fail-safe 方向不变：主开关默认 false ⇒ 未授权 = 默认全部不豁免。
  final bool allowQuietExempt;

  /// 为任务物化未来计划。
  ///
  /// ## 为什么没有 `existing:` 参数（R94 / SCH-13）
  /// 它曾经存在（"已提交未执行的 fireAt 集合，用于幂等去重"），但自从
  /// `OccurrenceRepository.reconcile` 接手去重（`insert ignore` + 确定性
  /// `occurrenceId = '$taskId@$ms'`）后**再没有任何调用方传过它** —— 一个
  /// 死参数，注释还谎称存在这层保护。留着只会让维护者以为"去重是物化层
  /// 做的"，从而在改 reconcile 时低估风险。去重真源现在只有一处：仓库层。
  List<PlannedEntry> materialize(
    Task task,
    DateTime now, {
    Duration horizon = SchedulerConfig.planHorizon,
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
        raw = _randomWindow(task, t, now, end);
      case final RandomIntervalTrigger t:
        raw = _randomInterval(task, t, now, end);
      case SoundTrigger():
        return const []; // 声音触发不进时间计划，由守卫服务实时驱动
    }

    final out = <PlannedEntry>[];
    for (final fire in raw) {
      final quiet = _applyQuiet(fire, task.quietPolicy, now,
          taskExemptOverride: task.quietExempt);
      if (quiet == null) continue;
      final resolved = quiet.at;
      final ms = resolved.millisecondsSinceEpoch;
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
    required bool? taskExemptOverride,
  }) {
    // **主开关 = 全量默认值 + 任务级双向反向覆盖**（v79，docs/20 §8.1）：
    //   · 任务级为 null（跟随）→ 取主开关：开 = 默认全部豁免，关 = 默认全部不豁免；
    //   · 任务级为 true/false → 直接覆盖主开关（主开关关闭时也能强制豁免）。
    // fail-safe 方向仍在：主开关默认 false ⇒ 未授权即默认全不豁免。
    final exempt = taskExemptOverride ?? allowQuietExempt;
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
      // 🔴 R94 / SCH-12：跨午夜端点必须走**本地日历日 ±1**，不能用
      // `add/subtract(Duration(days: 1))`。后者是**绝对 24 小时**：DST 前跳日
      // （当地 23h）加 24h ⇒ 次日 08:00（应为 07:00），回拨日（25h）⇒ 06:00。
      // 后果是护栏窗口在海外/出国场景整体偏 1 小时（多静默 1h 或**多响 1h**，
      // 后者是合规风险）。同文件 `_daily` / `_weekly` 的游标推进早已按 BUG-096
      // 改成日历加法，这里只是把同一家族漏掉的三处补齐。
      windows = [
        (
          DateTime(day.year, day.month, day.day, quietStartHour),
          DateTime(day.year, day.month, day.day + 1, quietEndHour),
        ),
        (
          DateTime(day.year, day.month, day.day - 1, quietStartHour),
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
      // BUG-096：日历推进必须走「年/月/日 +1」，不能用 `add(Duration(days:1))`。
      // 后者是**绝对 24 小时**：DST 回拨日（当天 25 小时）会把同一日历日
      // 迭代两次（产出重复 occurrenceId，只靠 insert-ignore 兜住），
      // 前拨日则跳过一天。`trigger.dart` 的同类问题（P2-29）已修，这里是孪生。
      day = DateTime(day.year, day.month, day.day + 1);
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
      // BUG-096：同 `_daily`，日历推进走「年月日 +1」（DST 安全）。
      day = DateTime(day.year, day.month, day.day + 1);
    }
    return out;
  }

  /// 计划**版本键**（P1-05）：`taskId` + 任务定义版本（`updatedAt`）。
  ///
  /// 只要任务定义没变，同一天的重算就得到**同一批时刻**；一旦用户/远程改了
  /// 定义（触发器、动作、时长… 落库都会刷新 `updatedAt`），当天的随机计划
  /// 整体重采样 —— 于是"改计划 = 换一批时刻"，而不会新旧混叠。
  String _seedKey(Task task) =>
      '${task.id}#v${task.updatedAt.millisecondsSinceEpoch}';

  /// 随机窗口物化（P1-05：确定性重算）。
  ///
  /// ## 为什么必须"整窗抽样、事后按 now 过滤"
  /// 旧实现把抽样起点裁到 `now`（`clampedStart = max(winStart, now)`），
  /// 于是 [sampleInWindow] 的**窗口长度**成了 `now` 的函数 —— 同一天每续算一次
  /// （`now` 前进）就重采样出**另一批**时刻；再叠加 `commitAll` 的 `ignore`
  /// 语义（旧的留着、新的追加），当天候选总数与最小间隔都不再受
  /// `timesPerDay/minGap` 约束（docs/50 §4.1 P1-05）。
  ///
  /// 现在种子只由「任务 id + 定义版本 + 当地日期」决定、抽样窗口恒为**完整窗口**，
  /// `now` 只用于最后过滤 —— 重算得到的是同一批时刻的**子集**，已提交条目 id
  /// 不变，配合 `OccurrenceRepository.reconcile` 的"未来 pending 整体替换"
  /// 即可保证"计划是可重算投影"。
  List<DateTime> _randomWindow(
      Task task, RandomWindowTrigger t, DateTime now, DateTime end) {
    final out = <DateTime>[];
    for (final day in t.dateRange.days()) {
      final winStart = t.windowStart.on(day);
      // SCH-12：跨午夜窗口终点用日历日 +1（DST 安全），语义见 `_applyQuiet`。
      final winEnd = t.windowEndNextDay
          ? DateTime(day.year, day.month, day.day + 1, t.windowEnd.hour,
              t.windowEnd.minute)
          : t.windowEnd.on(day);
      if (winEnd.isBefore(winStart)) continue;
      final rng = Random(planSeed(_seedKey(task), day));
      final offsets = sampleInWindow(
        n: t.timesPerDay,
        window: winEnd.difference(winStart),
        minGap: t.minGap,
        rng: rng,
      );
      for (final off in offsets) {
        final at = winStart.add(off);
        if (_inRange(at, now, end)) out.add(at);
      }
    }
    return out;
  }

  /// 随机间隔物化（P1-05：同 [_randomWindow] 的"整日生成 + 事后过滤"）。
  ///
  /// 旧实现以 `max(dayStart, now)` 为游标起点 ⇒ 游标序列随 `now` 变化，
  /// 同一天的间隔计划在每次续算后都不一致。
  List<DateTime> _randomInterval(
      Task task, RandomIntervalTrigger t, DateTime now, DateTime end) {
    final out = <DateTime>[];
    for (final day in t.dateRange.days()) {
      final dayStart = t.activeStart.on(day);
      // BUG-095：跨午夜判据必须比**分钟**，不能只比 hour。
      // 旧写法 `activeEnd.hour <= activeStart.hour` 把 08:00–08:30
      // 这种「同一小时内的合法窗口」误判为跨午夜 ⇒ 窗口被撑成 24.5h，
      // 夜里照样触发。与 `_randomWindow`（完整时刻比较）口径对齐。
      final crossesMidnight = (t.activeEnd.hour * 60 + t.activeEnd.minute) <=
          (t.activeStart.hour * 60 + t.activeStart.minute);
      // SCH-12：跨午夜终点用日历日 +1（DST 安全），不能用绝对 24h。
      final dayEnd = crossesMidnight
          ? DateTime(day.year, day.month, day.day + 1, t.activeEnd.hour,
              t.activeEnd.minute)
          : t.activeEnd.on(day);
      if (!dayEnd.isAfter(dayStart)) continue;
      final rng = Random(planSeed('${_seedKey(task)}#interval', day));
      var cursor = dayStart;
      var count = 0;
      while (cursor.isBefore(dayEnd) && count < t.maxPerDay) {
        // 首点在活动窗口内随机，其后按随机间隔推进 —— **从窗口起点**推进，
        // 与 now 无关；now 只在下面 `_inRange` 过滤。
        final gap = Duration(
          milliseconds: nextIntBetween(
            rng,
            t.minGap.inMilliseconds,
            t.maxGap.inMilliseconds + 1,
          ),
        );
        cursor = count == 0
            ? dayStart.add(Duration(
                milliseconds: rng.nextInt(
                dayEnd.difference(dayStart).inMilliseconds ~/
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

/// 计划是否需要续算（BUG-086 修复，2026-10-18）。
///
/// ## 旧判据错在哪（必须记住，防止有人改回去）
///
/// 引擎主循环原来是：
/// ```dart
/// final pending = await occs.pendingCountAfter(DateTime.now());
/// if (pending < SchedulerConfig.planExtendThreshold.inHours) { … replan … }
/// ```
/// `pendingCountAfter` 返回的是**条数**（`SELECT COUNT(*)`），而
/// `planExtendThreshold.inHours` 是**小时数**（默认 12）——拿两个不同
/// 量纲的值比大小。任务一多，条数常年 ≥ 12 ⇒ `pending < 12` 恒为 false
/// ⇒ **续算 tick 永不触发** ⇒ 未来计划视界从 `planHorizon`（48h）只耗不补，
/// 逐轮缩进。
///
/// 真机实证（Redmi K70 Pro / Android 16，2026-10-18 取证）：
/// 本应用 pending alarm **0 条**、未来覆盖 **0 小时**、**22:00–07:00**
/// 夜间窗口 occurrence **0 条**、JobScheduler 无本应用注册任务。
/// 于是"夜间豁免主开关开与不开"表现完全一样 —— 因为**夜里根本没有任何
/// 计划条目可被豁免**。
///
/// ## 新判据
///
/// [coverEnd] = 当前最晚一条 pending 的触发时间（`null` = 一条都没有）。
/// 覆盖末端已缩进 `now + threshold` 之内（或压根没有计划）⇒ 该重新物化，
/// 把覆盖推回 `planHorizon`。
///
/// 稳态开销：每轮 replan 后覆盖 48h，要等 `now + 12h` 越过最后一条才触发
/// ⇒ 约 36h 一次全量重算；其余 tick 只付一次 `MAX(fire_at)` 查询。
/// 空表 / 新装 / 清库 / 引擎重启后，本判据返回 true ⇒ 自愈补排。
bool planNeedsExtend(
  DateTime? coverEnd, {
  required DateTime now,
  required Duration threshold,
}) {
  if (coverEnd == null) return true;
  return !coverEnd.isAfter(now.add(threshold));
}

/// 一批到期计划的**执行顺序**（R94 / SCH-13）。
///
/// ## 为什么需要它
/// `Task.priority` 的契约写的是"数值大者先执行（同刻冲突时）"（`task.dart`），
/// 但 `OccurrenceRepository.due()` 只 `ORDER BY fire_at ASC` —— 同刻多条时
/// 顺序退化成 SQLite 的物理/rowid 顺序，**不确定也不可预期**。在长动作场景
/// （SCH-01：一条 10 分钟录音会把后面的全挤到下一批）里，这个顺序甚至决定
/// "谁先被预算吃掉"。
///
/// 排序键：`fire_at` 升序（到期早的先跑，这是硬约束）→ 同刻按 `priority` 降序。
///
/// 为什么不在 SQL 里 `JOIN tasks` 排序：`due()` 是仓库层签名（F3 所有权），
/// 而这里只是一次 O(n log n) 的本地排序（n ≤ catchUpLimit = 3），
/// 把顺序规则留在**纯函数**里才能被单测直接锁住。
List<PlannedOccurrence> orderDueBatch(
  List<PlannedOccurrence> due,
  Map<String, int> priorityOfTask,
) {
  final out = List<PlannedOccurrence>.of(due);
  out.sort((a, b) {
    final byTime = a.fireAt.compareTo(b.fireAt);
    if (byTime != 0) return byTime;
    return (priorityOfTask[b.taskId] ?? 0)
        .compareTo(priorityOfTask[a.taskId] ?? 0);
  });
  return out;
}
