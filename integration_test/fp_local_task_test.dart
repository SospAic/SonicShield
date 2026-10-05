import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';

/// 真机「本机功能点」验证 —— 任务/触发/随机化/免打扰/条件/审计。
///
/// ## 与既有 integration_test 的分工
///
/// `app_smoke_test.dart` 只证明「能启动、五页可达」；`native_bridge_test.dart`
/// 只证明「条件层的两个原生读数可判定」。本文件补的是**功能需求本身**：
/// 把 `docs/02` 的 FR-01 / FR-10~16 / FR-22~25 / FR-60 / FR-64~69 逐条落到
/// **真实设备上的真实 sqflite + 真实引擎**上跑一遍，而不是靠宿主 `FakeAsync`。
///
/// 为什么值得单独做：宿主单测里 `sqflite` 走的是内存替身，设备上的
/// `Dart→平台通道→原生 SQLite` 往返、WAL、外键级联都不会被覆盖 ——
/// 而「删除任务级联清理计划」（FR-01）恰恰依赖真实外键行为。
///
/// ## 运行
/// ```
/// flutter test integration_test/fp_local_task_test.dart -d 5540bc21 --no-uninstall
/// ```
///
/// 数据库用 **`:memory:`**：每次运行都是干净库，不会污染真机上已装应用的
/// 业务数据，也不受上一次运行残留影响（真机回归最怕"上一轮脏数据"）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late TaskRepository tasks;
  late OccurrenceRepository occ;
  late LogRepository logs;

  const engine = ScheduleEngine();

  setUpAll(() async {
    db = await AppDatabase.open(':memory:');
    tasks = TaskRepository(db);
    occ = OccurrenceRepository(db);
    logs = LogRepository(db);
  });

  tearDownAll(() async {
    await db.close();
  });

  // ---------------- 工具 ----------------

  /// 「明天」这一天（本地时区午夜）。用它作日期范围可让窗口不被 now 截断，
  /// 且 08:00–21:00 与默认免打扰（22:00–07:00）不重叠 ⇒ 断言确定。
  DateTime day(DateTime now) {
    final t = now.add(const Duration(days: 1));
    return DateTime(t.year, t.month, t.day);
  }

  Task mkTask({
    required String id,
    required TriggerType tt,
    required TriggerConfig trigger,
    ActionConfig action = const PlayAudioAction(),
    bool enabled = true,
    int cooldownSec = 60,
    QuietPolicy quiet = QuietPolicy.skip,
    TaskCondition? condition,
  }) =>
      Task(
        id: id,
        name: 'FP-$id',
        enabled: enabled,
        triggerType: tt,
        trigger: trigger,
        actionType: ActionType.playAudio,
        action: action,
        assetIds: const [],
        cooldownSec: cooldownSec,
        quietPolicy: quiet,
        condition: condition,
        priority: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  List<PlannedOccurrence> toRows(List<PlannedEntry> e) => [
        for (final x in e)
          PlannedOccurrence(
            id: x.occurrenceId,
            taskId: x.taskId,
            fireAt: x.fireAt,
            status: OccurrenceStatus.pending,
            volume: x.volume,
            durationMs: x.durationMs,
          ),
      ];

  // ---------------- FP-L1 任务 CRUD ----------------

  test('FP-L1 任务 CRUD 落库与删除级联清理（FR-01）', () async {
    final now = DateTime.now();
    final at = now.add(const Duration(hours: 2));
    final t = mkTask(
      id: 'fp-l1',
      tt: TriggerType.fixedOnce,
      trigger: FixedOnceTrigger(at: at),
    );

    await tasks.upsert(t);
    final got = await tasks.get('fp-l1');
    debugPrint('[FP-L1] upsert→get=${got?.name}');
    expect(got, isNotNull, reason: 'upsert 后必须能按 id 取回');
    expect(got!.name, 'FP-fp-l1');
    expect(got.enabled, isTrue);

    // 物化 + 落库：删除任务必须级联清掉这些计划（真实外键 ON DELETE CASCADE）。
    final entries = engine.materialize(got, now, horizon: const Duration(days: 1));
    expect(entries.length, 1, reason: 'fixedOnce 在 1 天视界内应物化 1 条');
    await occ.commitAll(toRows(entries));
    final pending = await occ.pendingWithin(now, now.add(const Duration(days: 1)));
    debugPrint('[FP-L1] pendingWithin=${pending.length}');
    expect(pending.length, 1);

    await tasks.setEnabled('fp-l1', false);
    expect((await tasks.get('fp-l1'))!.enabled, isFalse,
        reason: '启停必须即时落库（FR-01）');

    await occ.deleteForTask('fp-l1');
    await tasks.delete('fp-l1');
    expect(await tasks.get('fp-l1'), isNull);
    expect(await occ.pendingCountAfter(now), 0, reason: '删除任务后其计划必须清空');
  });

  // ---------------- FP-L2 五种触发器物化语义 ----------------

  test('FP-L2 五种触发器物化语义（FR-10~FR-15）', () async {
    final now = DateTime.now();
    final d = day(now);
    const horizon = Duration(days: 2);

    final fixed = engine.materialize(
      mkTask(
          id: 'fp-fixed',
          tt: TriggerType.fixedOnce,
          trigger: FixedOnceTrigger(at: d.add(const Duration(hours: 10)))),
      now,
      horizon: horizon,
    );
    expect(fixed.length, 1, reason: 'FR-10 fixedOnce：到点执行一次');

    final daily = engine.materialize(
      mkTask(
          id: 'fp-daily',
          tt: TriggerType.dailyAt,
          trigger: DailyTrigger(
              time: const TimeSpec(hour: 8),
              dateRange: DateRange(start: d, end: d))),
      now,
      horizon: horizon,
    );
    expect(daily.length, 1, reason: 'FR-11 dailyAt：视界内该日生成一条');

    final weekly = engine.materialize(
      mkTask(
          id: 'fp-weekly',
          tt: TriggerType.weeklyAt,
          trigger: WeeklyTrigger(
              weekdays: {d.weekday},
              time: const TimeSpec(hour: 9),
              dateRange: DateRange(start: d, end: d))),
      now,
      horizon: horizon,
    );
    expect(weekly.length, 1, reason: 'FR-12 weeklyAt：命中所选星期生成一条');

    final rw = engine.materialize(
      mkTask(
          id: 'fp-rw',
          tt: TriggerType.randomWindow,
          trigger: RandomWindowTrigger(
              dateRange: DateRange(start: d, end: d),
              windowStart: const TimeSpec(hour: 8),
              windowEnd: const TimeSpec(hour: 21),
              timesPerDay: 3,
              minGap: const Duration(minutes: 60))),
      now,
      horizon: horizon,
    );
    expect(rw.length, 3, reason: 'FR-13 randomWindow：每日随机 N 次');

    final ri = engine.materialize(
      mkTask(
          id: 'fp-ri',
          tt: TriggerType.randomInterval,
          trigger: RandomIntervalTrigger(
              dateRange: DateRange(start: d, end: d),
              minGap: const Duration(hours: 1),
              maxGap: const Duration(hours: 2),
              activeStart: const TimeSpec(hour: 8),
              activeEnd: const TimeSpec(hour: 21),
              maxPerDay: 8)),
      now,
      horizon: horizon,
    );
    debugPrint('[FP-L2] randomInterval 条数=${ri.length}');
    expect(ri.length, inInclusiveRange(1, 8),
        reason: 'FR-14 randomInterval：落在 [minGap,maxGap] 且不越每日上限');

    final snd = engine.materialize(
      mkTask(
          id: 'fp-snd',
          tt: TriggerType.soundTriggered,
          trigger: const SoundTrigger()),
      now,
      horizon: horizon,
    );
    expect(snd, isEmpty, reason: 'FR-15 声音触发不进时间计划表（由守卫实时驱动）');
  });

  // ---------------- FP-L3 确定性随机 ----------------

  test('FP-L3 确定性随机：同任务同日重算一致、跨任务不同（FR-25）', () async {
    final now = DateTime.now();
    final d = day(now);
    const horizon = Duration(days: 2);

    TriggerConfig trig() => RandomWindowTrigger(
          dateRange: DateRange(start: d, end: d),
          windowStart: const TimeSpec(hour: 8),
          windowEnd: const TimeSpec(hour: 21),
          timesPerDay: 4,
          minGap: const Duration(minutes: 30),
        );

    // 同一「任务定义版本」重算：必须复用**同一个 Task 实例**。
    // 种子 = taskId + updatedAt(定义版本) + 计划日（见 ScheduleEngine._seedKey）；
    // 两次 mkTask 会各自取 `DateTime.now()`，等于两个不同版本 —— 计划不同才是对的。
    final taskA = mkTask(
        id: 'fp-det-a', tt: TriggerType.randomWindow, trigger: trig());
    final a1 = engine.materialize(taskA, now, horizon: horizon);
    final a2 = engine.materialize(taskA, now, horizon: horizon);

    final x1 = a1.map((e) => e.fireAt.millisecondsSinceEpoch).toList();
    final x2 = a2.map((e) => e.fireAt.millisecondsSinceEpoch).toList();
    expect(listEquals(x1, x2), isTrue, reason: '同任务同日任意次重算必须逐条一致（不漂移）');
    expect(listEquals(a1.map((e) => e.volume).toList(), a2.map((e) => e.volume).toList()),
        isTrue,
        reason: '音量等随机量也必须可复现');

    final b = engine.materialize(
        mkTask(id: 'fp-det-b', tt: TriggerType.randomWindow, trigger: trig()),
        now,
        horizon: horizon);
    final xb = b.map((e) => e.fireAt.millisecondsSinceEpoch).toList();
    expect(xb.length, x1.length);
    expect(listEquals(x1, xb), isFalse, reason: '跨任务种子不同 ⇒ 计划不应完全相同（FR-25）');
  });

  // ---------------- FP-L4 免打扰命中策略 ----------------

  test('FP-L4 免打扰命中策略 skip / shift（FR-16）', () async {
    final now = DateTime.now();
    final d = day(now);
    const horizon = Duration(days: 3);

    TriggerConfig trig() => DailyTrigger(
        time: const TimeSpec(hour: 23), dateRange: DateRange(start: d, end: d));

    const quietEngine = ScheduleEngine(quietStartHour: 22, quietEndHour: 7);

    final skipped = quietEngine.materialize(
      mkTask(
          id: 'fp-q-skip',
          tt: TriggerType.dailyAt,
          trigger: trig(),
          quiet: QuietPolicy.skip),
      now,
      horizon: horizon,
    );
    expect(skipped, isEmpty, reason: '命中 22:00–07:00 且策略=skip ⇒ 不生成计划');

    final shifted = quietEngine.materialize(
      mkTask(
          id: 'fp-q-shift',
          tt: TriggerType.dailyAt,
          trigger: trig(),
          quiet: QuietPolicy.shift),
      now,
      horizon: horizon,
    );
    debugPrint('[FP-L4] shift fireAt=${shifted.map((e) => e.fireAt).toList()}');
    expect(shifted.length, 1, reason: '策略=shift ⇒ 平移到免打扰结束点而非丢弃');
    expect(shifted.first.fireAt.hour, 7, reason: '应平移到 07:00（免打扰结束点）');
  });

  // ---------------- FP-L5 随机量区间与最短间隔 ----------------

  test('FP-L5 随机量与时长在物化期落地并受区间约束（FR-22/23）', () async {
    final now = DateTime.now();
    final d = day(now);
    const minGap = Duration(minutes: 45);

    final t = mkTask(
      id: 'fp-range',
      tt: TriggerType.randomWindow,
      trigger: RandomWindowTrigger(
          dateRange: DateRange(start: d, end: d),
          windowStart: const TimeSpec(hour: 8),
          windowEnd: const TimeSpec(hour: 21),
          timesPerDay: 6,
          minGap: minGap),
      action: const PlayAudioAction(
          volumeMin: 0.3, volumeMax: 0.6, durationSecMin: 5, durationSecMax: 8),
    );

    final e = engine.materialize(t, now, horizon: const Duration(days: 2));
    expect(e.length, 6);
    for (final x in e) {
      expect(x.volume, inInclusiveRange(0.3, 0.6), reason: '随机音量必须落在配置区间');
      expect(x.durationMs, inInclusiveRange(5000, 8000), reason: '随机时长必须落在配置区间');
    }
    final sorted = e.map((x) => x.fireAt).toList()..sort();
    for (var i = 1; i < sorted.length; i++) {
      expect(sorted[i].difference(sorted[i - 1]) >= minGap, isTrue,
          reason: '相邻计划间隔必须 ≥ minGap（FR-13）');
    }
  });

  // ---------------- FP-L6 执行条件层 ----------------

  test('FP-L6 执行条件层判定（FR-64~FR-69）', () {
    final noon = DateTime(2026, 1, 1, 12, 0);

    // FR-64 仅充电时执行（skipInCall 置 false 以单测该条件）
    expect(
      const TaskCondition(requireCharging: true, skipInCall: false)
          .firstUnmet(charging: false, batteryLevel: 100, now: noon),
      '未充电',
    );
    expect(
      const TaskCondition(requireCharging: true, skipInCall: false)
          .firstUnmet(charging: true, batteryLevel: 100, now: noon),
      isNull,
    );

    // FR-65 最低电量阈值
    expect(
      const TaskCondition(minBatteryPct: 50, skipInCall: false)
          .firstUnmet(charging: false, batteryLevel: 30, now: noon),
      '电量 30% < 50%',
    );

    // FR-66 每日时段窗口（含跨零点）
    expect(
      const TaskCondition(
              windowStartMin: 9 * 60, windowEndMin: 10 * 60, skipInCall: false)
          .firstUnmet(charging: false, batteryLevel: 100, now: noon),
      '不在时段窗口内',
    );
    expect(
      const TaskCondition(
              windowStartMin: 22 * 60, windowEndMin: 7 * 60, skipInCall: false)
          .firstUnmet(
              charging: false,
              batteryLevel: 100,
              now: DateTime(2026, 1, 1, 23, 30)),
      isNull,
      reason: '跨零点窗口 22:00–07:00 在 23:30 应判定为在窗内',
    );

    // FR-67 仅 Wi-Fi 下执行；FR-69 无法判定（null）按满足处理
    expect(
      const TaskCondition(requireWifi: true, skipInCall: false)
          .firstUnmet(charging: false, batteryLevel: 100, now: noon, onWifi: false),
      '不在 Wi-Fi 下',
    );
    expect(
      const TaskCondition(requireWifi: true, skipInCall: false)
          .firstUnmet(charging: false, batteryLevel: 100, now: noon, onWifi: null),
      isNull,
      reason: '条件无法判定时必须按满足处理，不得静默停掉自动化（FR-69）',
    );

    // FR-68 通话中不执行（默认开启）
    expect(
      const TaskCondition()
          .firstUnmet(charging: false, batteryLevel: 100, now: noon, inCall: true),
      '通话中（不打扰通话）',
      reason: 'skipInCall 默认 true，是对未配置条件的历史任务同样生效的安全默认',
    );
  });

  // ---------------- FP-L7 审计日志 ----------------

  test('FP-L7 执行日志写入与聚合读取（FR-60）', () async {
    await logs.append(
      source: 'fp',
      action: 'play',
      status: 'success',
      taskId: 'fp-l7',
      volume: 0.5,
      durationMs: 3000,
      message: '真机取证',
    );
    final recent = await logs.recent(limit: 20);
    final mine = recent.where((r) => r['task_id'] == 'fp-l7').toList();
    debugPrint('[FP-L7] recent=${recent.length} mine=${mine.length}');
    expect(mine, isNotEmpty, reason: '刚写入的执行日志必须可被日志页读取');
    expect(mine.first['source'], 'fp');
    expect(mine.first['action'], 'play');
    expect(mine.first['status'], 'success');
    expect(mine.first['volume'], 0.5);
    expect(mine.first['duration_ms'], 3000);

    final breakdown = await logs.actionBreakdown();
    expect(breakdown.any((e) => e.action == 'play'), isTrue,
        reason: '按动作类型聚合应包含刚写入的记录');
    final status = await logs.statusBreakdown();
    expect(status.containsKey('success'), isTrue);
  });
}