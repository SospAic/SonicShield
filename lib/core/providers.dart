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

/// 任务列表流（数据库层主动刷新；简单起见以 ref.invalidate 触发）。
final taskListProvider =
    FutureProvider.autoDispose<List<TaskWithMeta>>((ref) async {
  final repo = await ref.watch(taskRepoProvider.future);
  final occ = await ref.watch(occurrenceRepoProvider.future);
  final tasks = await repo.listAll();
  final now = DateTime.now();
  return [
    for (final t in tasks)
      TaskWithMeta(
        task: t,
        nextFireAt: await _nextOf(occ, t.id, now),
      ),
  ];
});

Future<DateTime?> _nextOf(
    OccurrenceRepository occ, String taskId, DateTime now) async {
  final rows = await occ.pendingWithin(now, now.add(const Duration(days: 7)),
      limit: 200);
  for (final r in rows) {
    if (r.taskId == taskId) return r.fireAt;
  }
  return null;
}

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
