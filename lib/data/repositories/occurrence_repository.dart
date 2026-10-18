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

  /// 计划**对账**（P1-05 / P2-03）：把给定任务的**未来 pending** 整体替换为
  /// 本轮重算结果，单事务完成。
  ///
  /// ## 为什么必须"先删后插"而不是只追加
  /// 触发器/免打扰设置变更后，旧的 pending 已与新定义不符；`commitAll` 的
  /// `ignore` 语义只会**保留旧条目**（幽灵计划：改了窗口仍按旧时刻响，
  /// docs/50 §4.2 P2-03）。而计划本质是**可重算投影**：`ScheduleEngine` 的种子
  /// 只由「任务 id + 定义版本 + 当地日期」决定，重算得到同一批 `occurrenceId`，
  /// 所以"删未来 pending 再插入"对未变更的任务是**幂等**的、对已变更的是**正确替换**。
  ///
  /// 保留 `done/failed`：它们是**审计**，不是计划。
  /// 保留 `fire_at <= now` 的 pending：它们已到期、正由 `executeDue` 补执行，
  /// 删掉会漏触发（陈旧判定交给执行层的 10 分钟上限）。
  ///
  /// ## 未来 `skipped` 的处理（BUG-092 修复，2026-10-18）
  /// 旧实现**只删 pending**。而 `skipped` 有两种来源：
  /// - **用户在任务列表「跳过下一次」** —— 这是**意图**，投影内必须保留
  ///   （否则用户刚点的跳过会被一次 replan 复活）；
  /// - **定义变更留下的残影** —— 触发器/免打扰窗口改了以后，旧定义算出来的
  ///   那一条已不在本轮投影里，同 id 复现时又被 `insert ignore` 挡住
  ///   ⇒ "改回原设置后某一格永久不响"。
  ///
  /// 判据用**是否在本轮投影内**区分二者：投影内的 skipped 保留（意图），
  /// 不在投影内的删除（残影）。`fire_at <= now` 的 skipped 仍是审计，不动。
  Future<void> reconcile(
    Iterable<String> taskIds,
    List<PlannedOccurrence> entries,
    DateTime now,
  ) async {
    await _db.db.transaction((txn) async {
      final batch = txn.batch();
      for (final id in taskIds) {
        batch.delete(
          'occurrences',
          where: "task_id = ? AND status = 'pending' AND fire_at > ?",
          whereArgs: [id, now.millisecondsSinceEpoch],
        );
      }
      // BUG-092：一次查出所有"未来 skipped"，按投影归属决定去留。
      final projectedByTask = <String, Set<String>>{};
      for (final o in entries) {
        (projectedByTask[o.taskId] ??= <String>{}).add(o.id);
      }
      final scope = taskIds.toSet();
      final stale =
          await txn.query('occurrences', columns: ['id', 'task_id'], where: "status = 'skipped' AND fire_at > ?", whereArgs: [
        now.millisecondsSinceEpoch
      ]);
      for (final row in stale) {
        final tid = row['task_id'] as String?;
        final oid = row['id'] as String?;
        if (tid == null || oid == null || !scope.contains(tid)) continue;
        final projected = projectedByTask[tid] ?? const <String>{};
        if (!projected.contains(oid)) {
          batch.delete('occurrences', where: 'id = ?', whereArgs: [oid]);
        }
      }
      for (final o in entries) {
        batch.insert('occurrences', o.toRow(),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    });
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

  /// 未来 pending 的**覆盖末端**（最晚一条 pending 的 `fire_at`）。
  ///
  /// 计划续算判据的输入（BUG-086，2026-10-18）：旧判据是
  /// `pendingCountAfter(now) < planExtendThreshold.inHours` —— 拿**条数**
  /// 和**小时**比大小，任务一多恒不成立 ⇒ 续算永不触发 ⇒ 未来计划视界
  /// 只耗不补，夜间时段没有任何 plan entry（真机实证 pending alarm = 0）。
  ///
  /// 这里改为取 `MAX(fire_at)`：一条聚合查询，比把整个列表拉回来更省，
  /// 且与 [pendingCountAfter] 同样是"只看未来 pending"。
  /// 返回 null = 未来一条 pending 都没有 ⇒ 调用方应判定"需要续算"
  /// （空表 / 新装 / 清库 / 引擎重启后的自愈路径全靠它）。
  Future<DateTime?> latestPendingFireAt(DateTime after) async {
    final r = await _db.db.rawQuery(
      'SELECT MAX(fire_at) AS m FROM occurrences '
      "WHERE status = 'pending' AND fire_at > ?",
      [after.millisecondsSinceEpoch],
    );
    final m = r.first['m'];
    return m is int ? DateTime.fromMillisecondsSinceEpoch(m) : null;
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

  /// 每个任务在未来窗口内**最近的 pending 触发时间**（P2-12）。
  ///
  /// ## 为什么需要
  /// `taskListProvider` 此前对**每条任务各查一次** [pendingWithin]，且该查询带
  /// 全局 `limit`（默认 200）——任务/计划数一大，既产生 N+1 次 isolate 往返，
  /// 又会因全局截断让部分任务永远显示不出「下次触发」。这里用**单条 GROUP BY**
  /// 一次拿到所有任务的最近 pending：消除 N+1，且不受全局 limit 截断。
  ///
  /// 边界与 [pendingWithin] 一致（`from` 排他、`to` 包含）。返回
  /// `taskId -> 最近 fireAt`；窗口内无 pending 的任务不出现在 map 中。
  Future<Map<String, DateTime>> nextPendingByTask(
      DateTime from, DateTime to) async {
    final rows = await _db.db.rawQuery(
      'SELECT task_id, MIN(fire_at) AS next_at FROM occurrences '
      'WHERE status = \'pending\' AND fire_at > ? AND fire_at <= ? '
      'GROUP BY task_id',
      [from.millisecondsSinceEpoch, to.millisecondsSinceEpoch],
    );
    final out = <String, DateTime>{};
    for (final r in rows) {
      final id = r['task_id'];
      final at = r['next_at'];
      if (id is String && at is int) {
        out[id] = DateTime.fromMillisecondsSinceEpoch(at);
      }
    }
    return out;
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

  /// 某任务的**全部**计划条目（含审计态，按触发时间升序）。
  ///
  /// 为什么需要：[reconcile] 现在要区分「用户主动跳过的下一次」（保留）
  /// 与「定义变更留下的残影」（删除），二者的差别只在**行在不在**，
  /// 而 `pendingWithin` / `due` 都只看 `status = 'pending'`，
  /// 断言不到 skipped 行的存亡 ⇒ 测试无法验证这个语义。
  /// 审计侧（"那次到底跳过没有"）也缺一个读出口。
  Future<List<PlannedOccurrence>> allForTask(String taskId) async {
    final rows = await _db.db.query(
      'occurrences',
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: 'fire_at ASC',
    );
    return rows.map(PlannedOccurrence.fromRow).toList();
  }

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

  /// 清除**不再被授权**的未执行夜间豁免计划（v1.9 起，v79 改为定向清除）。
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
  ///
  /// ## v79：定向清除（`keepTaskIds`）
  /// 新语义下任务级可**双向覆盖** —— 主开关关闭时，`quietExempt == true`（强制豁免）
  /// 的任务**仍然豁免**，其计划必须保留。因此调用方（`background_engine.replan`）
  /// 必须把这类任务的 id 传进 [keepTaskIds]；传空集合时退化为旧的"全清"行为。
  Future<int> deletePendingQuietExempt(
      {Iterable<String> keepTaskIds = const []}) {
    final keep = keepTaskIds.toList();
    const base = "status = 'pending' AND quiet_exempt = 1";
    if (keep.isEmpty) {
      return _db.db.delete('occurrences', where: base);
    }
    final placeholders = List.filled(keep.length, '?').join(', ');
    return _db.db.delete('occurrences',
        where: '$base AND task_id NOT IN ($placeholders)', whereArgs: keep);
  }
}
