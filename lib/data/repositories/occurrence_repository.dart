import 'package:sqflite/sqflite.dart';
import 'package:sonic_shield/domain/models/task.dart';

import '../db/app_database.dart';

/// 已提交计划条目仓储：调度引擎与原生闹钟之间的持久化契约。
class OccurrenceRepository {
  OccurrenceRepository(this._db);

  final AppDatabase _db;

  /// 幂等合并：同 id 或同 fire_at+task 的条目不重复写入。
  Future<void> commitAll(List<PlannedOccurrence> list) async {
    final batch = _db.db.batch();
    for (final o in list) {
      batch.insert('occurrences', o.toRow(),
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  /// 到期且未处理的条目（含短暂逾期的补执行，由调用方限制补执行量）。
  Future<List<PlannedOccurrence>> due(DateTime now, {int limit = 10}) async {
    final rows = await _db.db.query(
      'occurrences',
      where: "status = 'pending' AND fire_at <= ?",
      whereArgs: [now.millisecondsSinceEpoch],
      orderBy: 'fire_at ASC',
      limit: limit,
    );
    return rows.map(PlannedOccurrence.fromRow).toList();
  }

  /// 未来仍处于 pending 的条目（用于判断是否需要续算计划）。
  Future<int> pendingCountAfter(DateTime t) async {
    final r = await _db.db.rawQuery(
      "SELECT COUNT(*) AS c FROM occurrences WHERE status = 'pending' AND fire_at > ?",
      [t.millisecondsSinceEpoch],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// 供原生精确闹钟排布：未来 horizon 内的 pending 条目。
  Future<List<PlannedOccurrence>> pendingWithin(DateTime from, DateTime to,
      {int limit = 128}) async {
    final rows = await _db.db.query(
      'occurrences',
      where: "status = 'pending' AND fire_at > ? AND fire_at <= ?",
      whereArgs: [from.millisecondsSinceEpoch, to.millisecondsSinceEpoch],
      orderBy: 'fire_at ASC',
      limit: limit,
    );
    return rows.map(PlannedOccurrence.fromRow).toList();
  }

  Future<void> markStatus(String id, OccurrenceStatus status,
          {double? volume, int? durationMs}) =>
      _db.db.update(
        'occurrences',
        {
          'status': status.name,
          if (volume != null) 'volume': volume,
          if (durationMs != null) 'duration_ms': durationMs,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  /// 某任务最近一次成功执行时间（null = 无）。
  Future<DateTime?> lastDoneFor(String taskId) async {
    final rows = await _db.db.query(
      'occurrences',
      where: "task_id = ? AND status = 'done'",
      whereArgs: [taskId],
      orderBy: 'fire_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(rows.first['fire_at'] as int);
  }

  /// 清理历史（保留 N 天），由维护任务周期调用。
  Future<int> purgeOlderThan(DateTime t) => _db.db.delete(
        'occurrences',
        where: "status != 'pending' AND fire_at < ?",
        whereArgs: [t.millisecondsSinceEpoch],
      );

  /// 任务删除时级联清理其计划。
  Future<void> deleteForTask(String taskId) =>
      _db.db.delete('occurrences', where: 'task_id = ?', whereArgs: [taskId]);

  /// 重新物化前清掉该任务的**未执行**计划（保留 done/failed/skipped 审计）。
  ///
  /// 远程 `task.upsert` 改了触发器/免打扰策略后，旧计划已与新定义不符；
  /// 不清理会出现"改了每天 8:00 却仍在 7:00 响"的幽灵计划（docs/14 §2.1）。
  Future<int> deletePendingForTask(String taskId) => _db.db.delete(
        'occurrences',
        where: "task_id = ? AND status = 'pending'",
        whereArgs: [taskId],
      );

  /// 「跳过下一次」：把该任务最近的 pending 计划标记为 skipped。
  /// 返回被跳过的条目数（0 或 1）。
  Future<int> skipNextForTask(String taskId) async {
    final rows = await _db.db.query(
      'occurrences',
      where: "task_id = ? AND status = 'pending' AND fire_at >= ?",
      whereArgs: [taskId, DateTime.now().millisecondsSinceEpoch],
      orderBy: 'fire_at ASC',
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    await markStatus(rows.first['id'] as String, OccurrenceStatus.skipped);
    return 1;
  }

  /// 清除**全部**未执行的夜间豁免计划（v1.9，docs/20 §8）。
  ///
  /// ## 为什么必须存在
  /// `commitAll` 用 `ConflictAlgorithm.ignore`（"计划即审计"，已提交的计划不漂移）。
  /// 因此用户**关闭**夜间豁免主开关后，先前已落库的豁免计划**不会被重算覆盖** ——
  /// 它们会继续在 22:00–07:00 之间照常触发，直到执行完或超出 planHorizon。
  /// 那意味着"关掉开关"在最长一个 planHorizon 内**没有任何效果**：
  /// 护栏名义上恢复了，实际上还在被绕过。
  ///
  /// 所以关闭开关时必须**主动清除**，而不是等重算。方向是 fail-safe：
  /// 宁可少响一次，也不能让已撤销的授权继续生效（与 S2「重启绝不续发」同一哲学）。
  Future<int> deletePendingQuietExempt() => _db.db.delete(
        'occurrences',
        where: "status = 'pending' AND quiet_exempt = 1",
      );
}
