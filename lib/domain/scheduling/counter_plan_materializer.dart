/// 反击计划 → 具体任务（**纯函数**，无 I/O）。
///
/// ## 设计选择：为什么"逐次展开成任务"，而不是造一条长期随机触发器
///
/// 需求要求"每天内容都随机"，且四个时段的**音量/时长区间各不相同**
/// （工作日白天 50–80%/3–8s、夜间 30–50%/3–5s，休息日夜间 10–30%/3–5s …）。
/// 若用一条跨月的随机触发器，音量/时长只能取**同一个区间**，无法按"当天是
/// 工作日还是休息日"切换；而"工作日/休息日"又**不等于星期几**（法定放假 +
/// 调休补班，见 `china_holidays.dart`）。
///
/// 因此本物化器按**日历日**逐日展开：每天判定 [DayKind]，取对应时段参数，
/// 在该时段内用可复现随机抽 [CounterWindow.actionsPerHour] × 小时数 个时刻，
/// 每次反击都落成一条 `fixedOnce` 任务。好处：
/// - 每个时刻的音量/时长区间**精确等于**该日该时段的约定值；
/// - 每天的时刻、音量、时长、动作内容都是随机的，且**可复现**
///   （种子 = planId + 日期 + 时段，见 `planSeed`）——重启/重算不漂移；
/// - **零引擎改动**：复用既有 `FixedOnceTrigger` + `ScheduleEngine` 通路，
///   不与手动任务抢语义，也不需要新增"按日切换参数"的调度分支（崩溃面最小）。
///
/// ## 命名空间隔离（不与手动内容冲突）
/// 任务 id 形如 `counter:{planId}:{yyyyMMdd}{D|N}{序号}`，前缀 [taskPrefix]。
/// 手动任务 id 是 UUID，两者不可能碰撞；下线计划时按前缀整族删除，
/// 也不会误删用户自己的任务。
library;

import 'dart:math';

import '../../core/utils/random.dart';
import '../models/action.dart';
import '../models/counter_plan.dart';
import '../models/task.dart';
import '../models/trigger.dart';
import 'china_holidays.dart';

abstract final class CounterPlanMaterializer {
  /// 任务 id 命名空间前缀（与 `CounterPlan.taskPrefix` 同源）。
  static const String taskPrefix = CounterPlan.taskPrefix;

  /// 单日展开上限（护栏）：即便 plan 填满每小时 12 次，也不会把库撑爆。
  static const int maxTasksPerDay = 96;

  /// 把 [plan] 展开为 `[from, from + days)` 内的任务列表。
  ///
  /// - [planId]：本计划的稳定标识（落库/远程下发用），决定任务 id 与随机种子；
  /// - [assetIdPool]：当前设备**实际可用**的音效 id 集合 —— 只有池非空才会生成
  ///   播放类任务（否则到点会"无可用音源"失败，属于静默假成功，必须避免）；
  /// - [now]：过滤已过时刻（null = 不过滤，便于测试）；
  /// - [overrides]：逐日工作日/休息日覆盖（手动或远程下发）；
  /// - [autoOverrides]：联网一键更新拉回的整年表（优先级低于 [overrides]）。
  static List<Task> materialize(
    CounterPlan plan, {
    required String planId,
    required DateTime from,
    int days = 7,
    Set<String> assetIdPool = const <String>{},
    DateTime? now,
    Map<String, DayKind>? overrides,
    Map<String, DayKind>? autoOverrides,
  }) {
    if (days <= 0) return const <Task>[];
    final id = safePlanId(planId);
    // [assetIdPool] 是**已解析好的本机音源 id**（不是 `plan.presetIds` 里的
    // 展示标识）：manifest id → 库内资产 id 的映射由调用方完成（需要读 manifest
    // 与音源库，属于设备/数据层职责）。排序 ⇒ 抽取可复现。
    final pool = assetIdPool.toList()..sort();
    final hasAudio = pool.isNotEmpty;
    final hasTts = plan.ttsTexts.isNotEmpty;
    if (!hasAudio && !hasTts) return const <Task>[];

    final created = now ?? DateTime.now();
    final sched = _resolveSchedule(plan, from, days);
    if (sched.days.isEmpty) return const <Task>[];

    final out = <Task>[];
    var remaining = sched.maxTasks;
    for (final day in sched.days) {
      final kind = ChinaHolidays.dayKind(day,
          overrides: overrides, autoOverrides: autoOverrides);
      final perDay = <Task>[];
      for (final isNight in const <bool>[false, true]) {
        final w = plan.windowFor(kind, isNight: isNight);
        if (!w.enabled || w.actionsPerHour <= 0) continue;
        perDay.addAll(_expandSlot(
          plan: plan,
          planId: id,
          day: day,
          kind: kind,
          isNight: isNight,
          w: w,
          audioPool: pool,
          hasAudio: hasAudio,
          hasTts: hasTts,
          created: created,
          now: now,
        ));
      }
      if (perDay.length > maxTasksPerDay) {
        perDay.removeRange(maxTasksPerDay, perDay.length);
      }
      // 全局条数上限（单次 = 1 / 几次 = N）：逐日累计，够数即止。
      if (remaining != null) {
        if (perDay.length > remaining) perDay.removeRange(remaining, perDay.length);
        remaining -= perDay.length;
      }
      out.addAll(perDay);
      if (remaining != null && remaining <= 0) break;
    }
    return out;
  }

  /// 按 [CounterPlan.scheduleMode] 解析**候选日历日**与**全局条数上限**。
  ///
  /// - 循环随机：滚动 `[from, from+days)`，并按 `weekdays` 过滤（默认周一至周日 = 全周）；
  /// - 单次 / 几次：在滚动 horizon 内生成 1 / N 条；
  /// - 几日：从 `from` 起 `spanDays` 天；
  /// - 指定日期 / 日期区间：精确到该日 / 该区间（与滚动 horizon 无关，可指向未来）。
  ///
  /// 日期非法（如指定日期为空）→ 返回空候选，调用方据此**不落库**（由
  /// `CounterPlan.validate` 在更外层如实报错）。
  static ({List<DateTime> days, int? maxTasks}) _resolveSchedule(
      CounterPlan plan, DateTime from, int days) {
    final start = DateTime(from.year, from.month, from.day);
    List<DateTime> span(int n) => <DateTime>[
          for (var i = 0; i < n; i++)
            DateTime(start.year, start.month, start.day + i),
        ];
    switch (plan.scheduleMode) {
      case PlanScheduleMode.recurringRandom:
        final wk = plan.weekdays.toSet();
        return (
          days: span(days).where((d) => wk.contains(d.weekday)).toList(),
          maxTasks: null,
        );
      case PlanScheduleMode.single:
        return (days: span(days), maxTasks: 1);
      case PlanScheduleMode.several:
        return (days: span(days), maxTasks: plan.occurrenceCount);
      case PlanScheduleMode.severalDays:
        return (days: span(plan.spanDays), maxTasks: null);
      case PlanScheduleMode.specificDate:
        final d = plan.specificDateValue;
        return (days: d == null ? const <DateTime>[] : <DateTime>[d], maxTasks: null);
      case PlanScheduleMode.dateRange:
        final s = plan.rangeStartValue;
        final e = plan.rangeEndValue;
        if (s == null || e == null || s.isAfter(e)) {
          return (days: const <DateTime>[], maxTasks: null);
        }
        return (days: DateRange(start: s, end: e).days().toList(), maxTasks: null);
    }
  }

  // ---- 内部 ----

  static List<Task> _expandSlot({
    required CounterPlan plan,
    required String planId,
    required DateTime day,
    required DayKind kind,
    required bool isNight,
    required CounterWindow w,
    required List<String> audioPool,
    required bool hasAudio,
    required bool hasTts,
    required DateTime created,
    required DateTime? now,
  }) {
    final dayStartMin = plan.dayStartHour * 60;
    final dayEndMin = plan.dayEndHour * 60;
    final dayLen = (dayEndMin - dayStartMin + 1440) % 1440;
    if (dayLen == 0) return const <Task>[];
    final nightLen = 1440 - dayLen;
    final startMin = isNight ? dayEndMin : dayStartMin;
    final lenMin = isNight ? nightLen : dayLen;
    final hours = lenMin / 60.0;
    final count = (hours * w.actionsPerHour).round().clamp(0, maxTasksPerDay);
    if (count <= 0) return const <Task>[];

    final slotKey = isNight ? 'N' : 'D';
    final rng = Random(planSeed('$planId#${ChinaHolidays.isoDate(day)}#$slotKey', day));
    final offsets = sampleInWindow(
      n: count,
      window: Duration(minutes: lenMin),
      minGap: Duration(seconds: plan.cooldownSec),
      rng: rng,
    );

    final midnight = DateTime(day.year, day.month, day.day);
    final tasks = <Task>[];
    for (var i = 0; i < offsets.length; i++) {
      final fireAt = midnight.add(
          Duration(minutes: startMin + offsets[i].inMinutes));
      if (now != null && !fireAt.isAfter(now)) continue;
      final key = '${ChinaHolidays.isoDate(day).replaceAll('-', '')}$slotKey'
          '${i.toString().padLeft(2, '0')}';
      final taskId = '$taskPrefix$planId:$key';
      // 每次反击独立抽动作（种子绑定到具体时刻 ⇒ 与排序无关，可复现）。
      //
      // **按窗口的"动作配比"抽**（TTS / 震动 / 音效）——这是"昼夜导向"的落点：
      // 白天窗口 `ttsWeight=0` ⇒ **永不喊话**（只放噪音 + 少量震动）；
      // 夜间窗口 `ttsWeight` 占主导 ⇒ **以喊话为主**。不可用的一类（无音源 /
      // 无文案）权重置零后**重新归一化**，只要任一类可用就一定抽得到。
      final arng = Random(planSeed('$taskId#act', fireAt));
      final wTts = hasTts ? w.ttsWeight : 0.0;
      final wVib = w.vibrateWeight;
      final wAud = hasAudio ? w.audioWeight : 0.0;
      final total = wTts + wVib + wAud;
      final roll = arng.nextDouble() * (total > 0 ? total : 1.0);
      final ActionConfig action;
      final ActionType type;
      final List<String> assetIds;
      if (wTts > 0 && roll < wTts) {
        assetIds = const <String>[];
        action = TtsAction(
          text: plan.ttsTexts[arng.nextInt(plan.ttsTexts.length)],
          volume: ((w.volumeMin + w.volumeMax) / 2).clamp(0.0, 1.0),
          channel: AudioChannel.media,
          voiceId: plan.voiceId,
        );
        type = ActionType.tts;
      } else if (wVib > 0 && roll < wTts + wVib) {
        assetIds = const <String>[];
        action = RandomVibrateAction(
          durationSecMin: w.durationSecMin,
          durationSecMax: w.durationSecMax,
          amplitudeMin: w.vibrateAmplitudeMin,
          amplitudeMax: w.vibrateAmplitudeMax,
        );
        type = ActionType.randomVibrate;
      } else if (wAud > 0) {
        assetIds = <String>[audioPool[arng.nextInt(audioPool.length)]];
        action = PlayAudioAction(
          volumeMin: w.volumeMin,
          volumeMax: w.volumeMax,
          durationSecMin: w.durationSecMin,
          durationSecMax: w.durationSecMax,
          channel: AudioChannel.media,
          respectDnd: true,
        );
        type = ActionType.playAudio;
      } else if (hasTts) {
        // 兜底（配比与可用性完全对不上时）：退到 TTS。
        assetIds = const <String>[];
        action = TtsAction(
          text: plan.ttsTexts[arng.nextInt(plan.ttsTexts.length)],
          volume: ((w.volumeMin + w.volumeMax) / 2).clamp(0.0, 1.0),
          channel: AudioChannel.media,
          voiceId: plan.voiceId,
        );
        type = ActionType.tts;
      } else if (hasAudio) {
        assetIds = <String>[audioPool[arng.nextInt(audioPool.length)]];
        action = PlayAudioAction(
          volumeMin: w.volumeMin,
          volumeMax: w.volumeMax,
          durationSecMin: w.durationSecMin,
          durationSecMax: w.durationSecMax,
          channel: AudioChannel.media,
          respectDnd: true,
        );
        type = ActionType.playAudio;
      } else {
        continue; // 不可达（物化入口已保证至少一类可用）。
      }
      tasks.add(Task(
        id: taskId,
        name: '反击·${kind.label}${isNight ? '夜间' : '白天'}'
            ' ${_hhmm(fireAt)}',
        enabled: true,
        triggerType: TriggerType.fixedOnce,
        trigger: FixedOnceTrigger(at: fireAt),
        actionType: type,
        action: action,
        assetIds: assetIds,
        cooldownSec: plan.cooldownSec,
        quietPolicy: QuietPolicy.skip,
        // v79 三态映射（与旧行为逐字等价，但改走"主开关默认值"语义）：
        // - 遵循免打扰（默认）= `false`（强制不豁免）—— 无论主开关如何都受护栏约束；
        // - 不遵循免打扰     = `null`（跟随主开关）—— 只有**本机**主开关开启时才豁免，
        //   任何对端/计划都无法单方面绕过本机合规护栏（docs/08 §2 红线）。
        quietExempt: plan.respectQuietHours ? false : null,
        priority: 0,
        createdAt: created,
        updatedAt: created,
      ));
    }
    tasks.sort((a, b) => a.id.compareTo(b.id));
    return tasks;
  }

  /// 归一化 planId：去掉分隔符与空白，保证它可作为任务 id 的命名空间段
  /// （也是"按前缀整族删除"时的比较基准）。
  static String safePlanId(String raw) {
    final t = raw
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return t.isEmpty ? 'plan' : t;
  }

  /// 某计划的**任务 id 前缀**（供仓库层按范围删除，见 `TaskRepository`）。
  static String taskIdPrefix(String planId) =>
      '$taskPrefix${safePlanId(planId)}:';

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}