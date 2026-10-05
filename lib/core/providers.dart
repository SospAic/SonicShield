import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/app_database.dart';
import '../data/repositories/log_repository.dart';
import '../data/repositories/occurrence_repository.dart';
import '../data/repositories/task_repository.dart';
import '../domain/models/task.dart';
import '../services/background_service_manager.dart';

/// 全局单例数据库（main 阶段 open；UI 层只读句柄）。
final databaseProvider = FutureProvider<AppDatabase>((_) => AppDatabase.open());

final taskRepoProvider = FutureProvider<TaskRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return TaskRepository(db);
});

final occurrenceRepoProvider =
    FutureProvider<OccurrenceRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return OccurrenceRepository(db);
});

final logRepoProvider = FutureProvider<LogRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return LogRepository(db);
});

/// 本月夜间豁免次数（v1.9，docs/20 §8.2 约束 2：不得静默生效）。
///
/// 独立成 provider 而不是在设置页 `initState` 里直接查库，有两个原因：
/// 1. 页面**只消费**结果，不关心怎么算；
/// 2. **widget 测试必须能把它换掉** —— 真实 sqflite 往返跑在 `FakeAsync` 里
///    会留下未完成的锁超时 `Timer`，让整页用例连带失败（见
///    `flutter-widget-test-harness` 技能第 ③ 类假故障）。
///    测试里 `overrideWith((ref) async => 0)` 即可，无需打桩数据库。
///
/// ⚠️ **刻意不加 `autoDispose`**：`autoDispose` 的 provider 在最后一个监听者
/// 离开时会走 `Timer(Duration.zero)` 延迟销毁；在 `FakeAsync` 里这个零延时
/// Timer 常常来不及被 elapse，于是**任何渲染过设置页的用例**都可能在收尾时
/// 判「A Timer is still pending」（实测：`router_test` RTR-06 因它变红）。
/// 新鲜度由设置页在进入时 `ref.invalidate` 保证，不依赖自动销毁。
final quietExemptCountProvider = FutureProvider<int>((ref) async {
  final repo = await ref.watch(logRepoProvider.future);
  final now = DateTime.now();
  return repo.countQuietExemptSince(DateTime(now.year, now.month));
});

/// 音源仓储（音源库界面的**唯一**数据入口：列表/批量导入/删除都走它，
/// 界面不再直接持有 `db` —— 否则批量写入与原子性无从复用）。
final assetRepoProvider = FutureProvider<AssetRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return AssetRepository(db);
});

/// 任务列表流（数据库层主动刷新；简单起见以 ref.invalidate 触发）。
final taskListProvider =
    FutureProvider.autoDispose<List<TaskWithMeta>>((ref) async {
  final repo = await ref.watch(taskRepoProvider.future);
  final occ = await ref.watch(occurrenceRepoProvider.future);
  final tasks = await repo.listAll();
  final now = DateTime.now();
  // P2-12：一次 GROUP BY 拿到**所有**任务的最近 pending，替代此前「逐任务各查
  // 一次 `pendingWithin` + 全局 limit 200」的 N+1 —— 后者任务/计划一多既慢，
  // 又会因全局截断让部分任务永远显示不出「下次触发」。
  final next = await occ.nextPendingByTask(now, now.add(const Duration(days: 7)));
  return [
    for (final t in tasks)
      TaskWithMeta(task: t, nextFireAt: next[t.id]),
  ];
});

class TaskWithMeta {
  const TaskWithMeta({required this.task, this.nextFireAt});

  final Task task;
  final DateTime? nextFireAt;
}

/// 引擎状态流。
final engineStateProvider = StreamProvider((ref) {
  return BackgroundServiceManager.instance.state;
});

/// 日志流。
final logListProvider =
    FutureProvider.autoDispose<List<Map<String, Object?>>>((ref) async {
  final repo = await ref.watch(logRepoProvider.future);
  return repo.recent(limit: 200);
});
