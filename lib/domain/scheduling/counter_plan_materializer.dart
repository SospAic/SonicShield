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
/// ## 动作形态：只出随机噪音，不出 TTS（2026-10 产品决策）
/// 守护反击一律播放随机音效（"尤其是噪音"）：可识别语音会暴露意图、
/// 录音取证价值低，与「不可预测」的目标相反。`CounterPlan.ttsTexts`
/// 字段为兼容旧 JSON 而保留，但本物化器**不再生成 TTS 动作** ——
/// 即便导入的 plan 带 ttsTexts，也全部物化为音效播放。
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
    // 弃 TTS 后音效是主资源，但**震动不需要音源** —— 无音源时不直接返回空，
    // 是否产出交给窗口配比决定（震动能出就出，全不可用才跳过该时刻）。

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
      // **弃 TTS（2026-10 产品决策）**：反击一律出随机噪音，不播 TTS 语音。
      // 保留「动作配比」框架（震动 / 音效），TTS 类**整体移除** ——
      // `plan.ttsTexts` 与 `w.ttsWeight` 不再参与配比（导入的文案会被忽略，
      // 见 [CounterPlan.defaultTtsTexts]）。不可用的一类权重置零后**重新归一化**，
      // 只要任一类可用就一定抽得到。
      final arng = Random(planSeed('$taskId#act', fireAt));
      final hasAudio = audioPool.isNotEmpty;
      final wVib = w.vibrateWeight;
      final wAud = hasAudio ? w.audioWeight : 0.0;
      final total = wVib + wAud;
      // 无音源且该窗口不排震动 ⇒ 该时刻没有任何可用动作，跳过。
      if (total <= 0) continue;
      final roll = arng.nextDouble() * total;
      final ActionConfig action;
      final ActionType type;
      final List<String> assetIds;
      if (wVib > 0 && roll < wVib) {
        assetIds = const <String>[];
        action = RandomVibrateAction(
          durationSecMin: w.durationSecMin,
          durationSecMax: w.durationSecMax,
          amplitudeMin: w.vibrateAmplitudeMin,
          amplitudeMax: w.vibrateAmplitudeMax,
          // R93：显式 USAGE_ALARM。反击计划是用户**自己开**的，等价闹钟；
          // 跟随勿扰会撞上"静默失败"（系统吞掉振动、回执仍 success）。
          // 声音动作仍 respectDnd=true（不炸别人的耳朵），见下一分支。
          respectDnd: false,
        );
        type = ActionType.randomVibrate;
      } else {
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
        // v79 规格（docs/20 §8.1）：「反击计划生成的任务**一律** `null`
        // （跟随本机主开关）」。旧写法是 `plan.respectQuietHours ? false : null`
        // —— 而 `respectQuietHours` 默认 `true` ⇒ 物化出来的任务几乎总是
        // `quietExempt: false`（**强制不豁免**）。于是用户在设置页打开
        // 「夜间豁免主开关」后，反击计划任务**照样不在夜间执行**，
        // 用户直接感知为"豁免开关没用"（真机双线证实的第二根因）。
        //
        // 改为一律 `null` 后，是否豁免完全由**本机主开关**决定：
        // fail-safe 方向不降级（主开关默认 false ⇒ 默认全不豁免），
        // 且任何对端/计划配置都无法单方面绕过本机合规护栏（docs/08 §2）。
        //
        // ⚠️ `CounterPlanParams.respectQuietHours` 字段保留（远程配置/导入
        // 导出兼容），但**不再映射到 `quietExempt`** —— 已在字段 doc 注明。
        quietExempt: null,
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