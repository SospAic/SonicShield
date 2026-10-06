import '../../domain/models/counter_plan.dart';
import '../../domain/scheduling/counter_plan_materializer.dart';
import '../data/repositories/counter_plan_store.dart';
import '../data/repositories/task_repository.dart';

/// 反击计划的落库编排：**校验 → 物化 → 落库 → （可选）触发重算**。
///
/// ## 为什么把编排单独抽成一层
/// 三个入口（本机 UI、文件导入、远程 `plan.apply`）都要走**同一条**通路，
/// 否则"本机能用、远程导入却漏了一步"是最典型的静默不一致。因此：
/// - 校验前置（[CounterPlan.validate]）：不合格的计划**绝不落库**，如实回报；
/// - 物化纯函数（[CounterPlanMaterializer]）不碰 I/O，可穷举测试；
/// - 落库走命名空间整族替换（见 [apply] 的 `replace`），**绝不触碰手动任务**。
///
/// ## 不冲突、不崩溃
/// - 任务 id 前缀 `counter:{planId}:`，与 UUID 手动任务不可能碰撞；
/// - 只用「先 UPDATE 再 INSERT」的 `upsertMany`（**无 DELETE** 的手动改写路径），
///   不触发 `occurrences` 的级联删除（P2-02）；
/// - 音源解析失败（点名音效本机没装）不会生成播放任务，而是如实回报，
///   避免到点"无可用音源"的静默假成功。
class CounterPlanService {
  CounterPlanService({
    required TaskRepository tasks,
    required CounterPlanStore store,
    ResolveAudioIds? resolveAudioIds,
    Future<void> Function()? replan,
  })  : _tasks = tasks,
        _store = store,
        _resolve = resolveAudioIds ?? _noAudio,
        _replan = replan ?? _noop;

  final TaskRepository _tasks;
  final CounterPlanStore _store;

  /// 把计划点名的 manifest id 解析为**本机实际可用的音源 id** 集合。
  final ResolveAudioIds _resolve;

  /// 落库后触发的调度重算（生产传 `BackgroundServiceManager.instance.replan`）。
  ///
  /// 默认 no-op：本层不依赖 Flutter 插件，纯 Dart 可测；即使未注入，
  /// 后台引擎的下一次 tick 也会读到新任务并重算（只是晚一点生效）。
  final Future<void> Function() _replan;

  /// 计划的当前标识（用于展示 / 远程回执）。
  String get planId => _store.planId;

  CounterPlan? currentPlan() => _store.loadPlan();

  bool get enabled => _store.enabled;

  /// 应用（导入 / 启用 / 编辑后重排）一份计划。
  ///
  /// [replace] = true（默认，用户显式操作）：先按命名空间**整族删除**旧任务，
  /// 再整体重建。适用于"计划被改动/重新导入" —— 旧参数下多出来的时刻必须消失，
  /// 否则会变成幽灵计划。删除只作用于 `counter:{planId}:` 前缀，
  /// 且执行审计另存于 `logs` 表，不受影响。
  ///
  /// [replace] = false（自动续算）：只 `upsertMany`，**不删除** ——
  /// id 由「日期 + 时段 + 序号」决定，重算是幂等的：已执行的历史任务原样保留，
  /// 未来任务被覆盖为新计划，新 horizon 里的新任务被插入。
  Future<CounterApplyResult> apply(
    CounterPlan plan, {
    String? planId,
    DateTime? now,
    int days = 7,
    Map<String, DayKind>? overrides,
    bool replace = true,
  }) async {
    final errs = plan.validate();
    if (errs.isNotEmpty) {
      return CounterApplyResult.fail('计划校验未通过：${errs.join('；')}');
    }
    final id = CounterPlanMaterializer.safePlanId(planId ?? _store.planId);
    final at = now ?? DateTime.now();

    final pool = await _resolve(plan.presetIds);
    final ov = overrides ?? _store.overrides();
    final tasks = CounterPlanMaterializer.materialize(
      plan,
      planId: id,
      from: at,
      days: days,
      assetIdPool: pool,
      now: at,
      overrides: ov,
      autoOverrides: _store.autoOverrides(),
    );
    if (tasks.isEmpty) {
      final why = pool.isEmpty && plan.ttsTexts.isEmpty
          ? '计划点名的音效在本机音源库中没有找到（请先到「音源库」导入预置库），'
              '且计划里没有可用的 TTS 文案'
          : '计划未生成任何任务：请检查各时段的开关与「每小时次数」';
      return CounterApplyResult.fail(why);
    }

    if (replace) await _tasks.deleteCounterTasks(id);
    await _tasks.upsertMany(tasks);
    await _store.savePlan(plan, id: id, enabled: true);
    await _replan();
    final scope = plan.isRecurring
        ? '近 $days 天，每 ${plan.cooldownSec}s 至少间隔）'
        : '排期「${plan.scheduleMode.label}」）';
    return CounterApplyResult.ok2(
      '反击计划已生效：排入 ${tasks.length} 条计划任务（$scope',
      taskCount: tasks.length,
      planId: id,
    );
  }

  /// 下线：清空该计划的**全部**计划任务并置为未启用（保留计划本体以便恢复）。
  Future<CounterApplyResult> disable({String? planId}) async {
    final id = CounterPlanMaterializer.safePlanId(planId ?? _store.planId);
    final n = await _tasks.deleteCounterTasks(id);
    await _store.setEnabled(false);
    await _replan();
    return CounterApplyResult.ok2(
      '已下线反击计划（清除 $n 条计划任务）',
      taskCount: n,
      planId: id,
    );
  }

  /// 自动续算：当已排计划的天数不足 [minDaysAhead] 时，用**同一计划**
  /// 无删除地续排（见 [apply] 的 `replace=false`）。
  ///
  /// 为什么要它：物化是"未来 [days] 天的固定时刻"，跑完即尽。若不在剩余
  /// horizon 变短时续排，计划会在几天后**悄无声息地停掉**。本方法幂等，
  /// 可在 App 启动 / 页面进入 / 引擎 tick 时安全重复调用。
  Future<CounterApplyResult> refreshIfNeeded({
    int minDaysAhead = 3,
    int days = 7,
    DateTime? now,
  }) async {
    if (!_store.enabled) return CounterApplyResult.fail('反击计划未启用');
    final plan = _store.loadPlan();
    if (plan == null) return CounterApplyResult.fail('尚无反击计划');
    final id = _store.planId;
    // 有界排期（单次/几次/几日/指定日期/日期区间）跑完即止，**不滚动续算**；
    // 否则"单次"会在每次 tick 后不断新生，语义就错了。
    if (!plan.isRecurring) {
      return CounterApplyResult.ok2(
          '排期「${plan.scheduleMode.label}」为有界计划，无需续算',
          taskCount: 0,
          planId: id);
    }
    final at = now ?? DateTime.now();
    final last = lastPlannedDay(await _tasks.counterTaskIds(id));
    if (last != null &&
        last.isAfter(at.add(Duration(days: minDaysAhead)))) {
      return CounterApplyResult.ok2('反击计划无需续算（已排到 ${_d(last)}）',
          taskCount: 0, planId: id);
    }
    return apply(plan, planId: id, now: at, days: days, replace: false);
  }

  /// 已落库的**联网更新**节假日表（UI 展示条数与更新时间用）。
  Map<String, DayKind> autoOverrides() => _store.autoOverrides();

  /// 上次一键更新成功时间；从未更新 → null。
  DateTime? autoOverridesUpdatedAt() => _store.autoOverridesUpdatedAt();

  /// 落库一张**联网拉回的节假日表**，并（若计划已启用）立即按新表重排。
  ///
  /// 与 [apply] 的分工：本方法只负责"存表 + 触发重排"，不解析任何网络格式
  /// （解析在 `HolidayUpdateService`）。表空 ⇒ 视为清除（回到内置表）。
  /// 计划未启用 / 尚无计划本体时**不算失败**：表已存下，下次启用即生效。
  Future<CounterApplyResult> refreshHolidays(
    Map<String, DayKind> autoOv, {
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    await _store.setAutoOverrides(autoOv, at: at);
    if (autoOv.isEmpty) {
      return CounterApplyResult.ok2('已清除联网节假日表（回到内置表）');
    }
    if (!_store.enabled) {
      return CounterApplyResult.ok2(
          '已更新节假日表（${autoOv.length} 天）；反击计划未启用，启用即按新表排期');
    }
    final plan = _store.loadPlan();
    if (plan == null) {
      return CounterApplyResult.ok2(
          '已更新节假日表（${autoOv.length} 天）；尚无反击计划，生成后即按新表排期');
    }
    return apply(plan, planId: _store.planId, now: at, replace: true);
  }
}

/// 音源解析器签名：manifest id 列表 → 本机可用的音源资产 id 集合。
typedef ResolveAudioIds = Future<Set<String>> Function(List<String> presetIds);

/// 结果对象（成功/失败 + 面向用户的中文说明）。
class CounterApplyResult {
  const CounterApplyResult._({
    required this.ok,
    required this.message,
    this.taskCount = 0,
    this.planId = '',
  });

  factory CounterApplyResult.fail(String message) =>
      CounterApplyResult._(ok: false, message: message);

  factory CounterApplyResult.ok2(String message,
          {int taskCount = 0, String planId = ''}) =>
      CounterApplyResult._(
          ok: true, message: message, taskCount: taskCount, planId: planId);

  final bool ok;
  final String message;
  final int taskCount;
  final String planId;
}

/// 从任务 id 里取出它所属的**日历日**（`counter:{planId}:{yyyyMMdd}{D|N}{nn}`）。
///
/// 只看 id 的**最后一段**里前 8 位数字：命名空间归一化时已剔除分隔符歧义。
/// 畸形 id → null（跳过，不抛）。
DateTime? lastPlannedDay(Iterable<String> taskIds) {
  DateTime? max;
  for (final id in taskIds) {
    final d = dayOfCounterTaskId(id);
    if (d != null && (max == null || d.isAfter(max))) max = d;
  }
  return max;
}

/// 解析单个反击任务 id 所属日期；解析不出 → null。
DateTime? dayOfCounterTaskId(String taskId) {
  final i = taskId.lastIndexOf(':');
  if (i < 0 || i + 9 > taskId.length) return null;
  final seg = taskId.substring(i + 1);
  if (seg.length < 8) return null;
  final y = int.tryParse(seg.substring(0, 4));
  final m = int.tryParse(seg.substring(4, 6));
  final d = int.tryParse(seg.substring(6, 8));
  if (y == null || m == null || d == null) return null;
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  return DateTime(y, m, d);
}

/// 从音源库挑出计划点名音效对应的**库内资产 id**（纯函数，便于测试）。
///
/// 预置导入时已把 manifest 的稳定 id 写进音源的第三个 tag（见
/// `sound_library_screen._importPresets`），这里据此回查。
Set<String> resolvePresetAudioIds(
    Iterable<AudioAsset> assets, Iterable<String> presetIds) {
  final want = presetIds.where((e) => e.trim().isNotEmpty).toSet();
  if (want.isEmpty) return const <String>{};
  final out = <String>{};
  for (final a in assets) {
    if (a.tags.any(want.contains)) out.add(a.id);
  }
  return out;
}

String _d(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

Future<Set<String>> _noAudio(List<String> _) async => const <String>{};

Future<void> _noop() async {}