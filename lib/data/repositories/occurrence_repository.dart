import 'package:sqflite/sqflite.dart';
import 'package:sonic_shield/domain/models/task.dart';

import '../db/app_database.dart';

/// 已提交计划条目仓储：调度引擎与原生闹钟之间的持久化契约。
class OccurrenceRepository {
  OccurrenceRepository(this._db);

  final AppDatabase _db;

  /// 幂等合并：同 id 的条目不重复写入。
  ///
  /// ## 去重口径（DAT-13 更正）
  /// 旧注释写的是"同 id **或**同 fire_at+task 不重复"，但 schema 上
  /// `occurrences` **只有 `id` 主键**，没有 `UNIQUE(task_id, fire_at)`
  /// —— `ConflictAlgorithm.ignore` 因此**只按主键**生效，同刻不同 id 的两行
  /// 可以并存。注释描述的是设计意图，不是实现事实，会误导维护者。
  ///
  /// 这里**不**加 `UNIQUE(task_id, fire_at)`：存量库可能已有重复行（历史
  /// 版本、远程 `@remote@` id 方案），迁移期建唯一索引会直接失败 ⇒ 整库打不开。
  /// 改为在 Dart 侧按 `(taskId, fireAtMs)` 去重（成本 O(n)，n = 单批条目数），
  /// 让"同刻不重复"成为**本方法**的保证，而不是 schema 的假设。
  Future<void> commitAll(List<PlannedOccurrence> list) async {
    if (list.isEmpty) return;
    final seenIds = <String>{};
    final seenSlots = <String>{};
    final batch = _db.db.batch();
    for (final o in list) {
      final slot = '${o.taskId}@${o.fireAt.millisecondsSinceEpoch}';
      if (!seenIds.add(o.id) || !seenSlots.add(slot)) continue;
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

  /// **条件更新（CAS）**：把 [id] 置为 [to]，返回**受影响行数**。
  ///
  /// ## 返回值的含义（F2 调用契约）
  /// - `1` = **我抢到了**这条计划，可以继续执行动作；
  /// - `0` = 这条计划**已被别人改过**（另一条连接先抢到 / 用户刚跳过 /
  ///   已终态），调用方**必须放弃执行**，不得回写终态。
  ///
  /// ## 为什么必须是 CAS（DAT-03）
  /// 旧实现是 `UPDATE ... WHERE id = ?`（无条件、且丢弃返回值）。而
  /// `AppDatabase` 刻意 `singleInstance:false`（R89）—— 主 UI 引擎与后台引擎
  /// 各持一条连接：两条连接同时 `due()` 会拿到**同一批** pending 行，
  /// 两者都"置状态成功"、两者都执行 ⇒ **同一计划播两次**。
  /// "UPDATE 成功"不等于"我抢到了"，只有"**从 pending 抢到**"才是。
  ///
  /// ## [from] 语义
  /// 非空时追加 `AND status IN (...)`：只有当前状态在集合内才更新。
  /// 传空集合等价于"任何状态都不可能匹配"（返回 0），这是刻意的 ——
  /// 调用方写出空集合通常是 bug，静默成功会更难查。
  ///
  /// ## [note]
  /// 可选的**诊断文案**：非 null 时额外写一条 `exec_logs`（`source='db'`、
  /// `action='markStatus'`、`status='info'`）。用于记录"CAS 落空"这类
  /// 难以复现的并发事件；默认 null = 零额外写入（热路径不受影响）。
  Future<int> markStatus(
    String id,
    OccurrenceStatus to, {
    Set<OccurrenceStatus>? from,
    String? note,
    double? volume,
    int? durationMs,
  }) async {
    var where = 'id = ?';
    final args = <Object?>[id];
    if (from != null) {
      if (from.isEmpty) return 0;
      final ph = List.filled(from.length, '?').join(', ');
      where = 'id = ? AND status IN ($ph)';
      args.addAll(from.map((s) => s.name));
    }
    final n = await _db.db.update(
      'occurrences',
      {
        'status': to.name,
        if (volume != null) 'volume': volume,
        if (durationMs != null) 'duration_ms': durationMs,
      },
      where: where,
      whereArgs: args,
    );
    if (note != null) {
      // 诊断留痕**不得**影响状态机：写日志失败只吞掉。
      try {
        await _db.db.insert('exec_logs', {
          'occurrence_id': id,
          'source': 'db',
          'action': 'markStatus',
          'status': 'info',
          'message': '${to.name} affected=$n${note.isEmpty ? '' : '：$note'}',
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      } on DatabaseException {
        // 忽略：审计缺失不能反过来让 CAS 失败。
      }
    }
    return n;
  }

  /// 把上次进程中断遗留的 [OccurrenceStatus.running] 统一改回 `failed`，
  /// 返回条数（SCH-04 / DAT-03 配套）。
  ///
  /// ## 为什么需要
  /// `running` 是"某条连接已抢占、正在执行动作"的占用态。执行者若在
  /// `runAction` 期间被杀（系统回收后台服务、崩溃、重启），那一行会**永久**
  /// 停在 `running`：`due()` 只看 `pending` ⇒ 它永远不会再被执行，
  /// 也不会进入 `failed` 审计，`retention` 的 `status != 'pending'` 清理
  /// 会把它当历史静默删掉 —— 用户看到的是"那次没响，日志里什么都没有"。
  ///
  /// 启动时调用一次即可（同一时刻只有一个新引擎在启动，不需要 CAS 循环：
  /// 此刻不该有别的执行者在跑，真跑着的那条会在 `runAction` 结束后写终态）。
  Future<int> recoverInterrupted() => _db.db.update(
        'occurrences',
        {'status': OccurrenceStatus.failed.name},
        where: 'status = ?',
        whereArgs: [OccurrenceStatus.running.name],
      );

  /// **原子替换**某任务的未来计划（DAT-05 / RCA-7）：单事务内
  /// 「删旧 pending（`fire_at > now`）→ 插新条目」，返回真实计数。
  ///
  /// ## 为什么必须单事务
  /// 远程 `task.upsert` 的旧实现是
  /// `tasks.upsert` → `deletePendingForTask` → `_rematerialize(commitAll)`
  /// **三段独立写**。第二段提交后、第三段失败（锁超时/磁盘满/进程被杀）就留下
  /// "任务已改、旧计划已删、新计划一条没有"的**零计划任务**。
  /// 而引擎的续算判据是**全局** `MAX(fire_at)`（`latestPendingFireAt`）：
  /// 只要别的任务（反击计划动辄数百条）把覆盖维持在 48h，
  /// `planNeedsExtend` 恒 false ⇒ 这个任务**永远不会**被重新物化 ⇒ 长期静默。
  ///
  /// ## 语义
  /// - 只动 `fire_at > now` 的 pending：`fire_at <= now` 的**已到期**计划正由
  ///   `executeDue` 补执行，删掉会漏触发（陈旧判定交给执行层 10 分钟上限）；
  /// - `done/failed/skipped/running` 一律不动（审计 + 占用态）；
  /// - [entries] 内部按 `id` / `(taskId, fireAtMs)` 去重（与 [commitAll] 同口径）。
  ///
  /// 返回 `(inserted, keptDue, dropped)`：`keptDue` = 因 `fire_at <= now` 被
  /// 保留的旧 pending 条数（调用方据此判断"是否还有到期未跑的计划"）。
  Future<({int inserted, int keptDue, int dropped})> replacePendingForTask(
    String taskId,
    List<PlannedOccurrence> entries,
    DateTime now,
  ) async {
    final nowMs = now.millisecondsSinceEpoch;
    return _db.db.transaction((txn) async {
      final kept = await txn.rawQuery(
        'SELECT COUNT(*) AS c FROM occurrences '
        "WHERE task_id = ? AND status = 'pending' AND fire_at <= ?",
        [taskId, nowMs],
      );
      final keptDue = (kept.first['c'] as int?) ?? 0;
      final dropped = await txn.delete(
        'occurrences',
        where: "task_id = ? AND status = 'pending' AND fire_at > ?",
        whereArgs: [taskId, nowMs],
      );
      final seenIds = <String>{};
      final seenSlots = <String>{};
      final batch = txn.batch();
      var inserted = 0;
      for (final o in entries) {
        if (o.taskId != taskId) continue; // 只接受本任务的条目，防止串味
        final slot = '${o.taskId}@${o.fireAt.millisecondsSinceEpoch}';
        if (!seenIds.add(o.id) || !seenSlots.add(slot)) continue;
        batch.insert('occurrences', o.toRow(),
            conflictAlgorithm: ConflictAlgorithm.ignore);
        inserted++;
      }
      if (inserted > 0) await batch.commit(noResult: true);
      return (inserted: inserted, keptDue: keptDue, dropped: dropped);
    });
  }

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

  /// 清理历史（保留 N 天），**分批**删除（DAT-11）。
  ///
  /// ## 为什么必须分批
  /// 旧实现是一条无 `LIMIT` 的 `DELETE ... WHERE status != 'pending' AND
  /// fire_at < ?`。积累数十万行时这条语句会**一次持写锁数秒**，
  /// 对端（UI 保存任务 / 远程 upsert / 引擎 tick）在 `busy_timeout=5000`
  /// 内拿不到锁就抛 `database is locked` —— 清理本来是为了省空间，
  /// 结果变成一次可感知的"保存失败"。
  ///
  /// 改为 `DELETE ... WHERE rowid IN (SELECT rowid ... LIMIT ?)` 循环：
  /// 每批独立提交，批间可被其它写者插入（SQLite 的写锁按事务释放）。
  /// 上界 `fire_at < t` 固定，因此"删的过程中新写入的行"不会被误删。
  ///
  /// [batchLimit] 可调（测试/低端机可调小）；≤0 视为不清理，直接返回 0。
  Future<int> purgeOlderThan(DateTime t, {int batchLimit = 500}) async {
    if (batchLimit <= 0) return 0;
    final cutoff = t.millisecondsSinceEpoch;
    var total = 0;
    while (true) {
      final n = await _db.db.rawDelete(
        'DELETE FROM occurrences WHERE rowid IN ('
        "SELECT rowid FROM occurrences WHERE status != 'pending' AND fire_at < ? "
        'LIMIT ?)',
        [cutoff, batchLimit],
      );
      total += n;
      if (n < batchLimit) return total;
    }
  }

  /// 任务删除时级联清理其计划。
  Future<void> deleteForTask(String taskId) =>
      _db.db.delete('occurrences', where: 'task_id = ?', whereArgs: [taskId]);

  /// 重新物化前清掉该任务的**未执行**计划（保留 done/failed/skipped 审计）。
  ///
  /// 远程 `task.upsert` 改了触发器/免打扰策略后，旧计划已与新定义不符；
  /// 不清理会出现"改了每天 8:00 却仍在 7:00 响"的幽灵计划（docs/14 §2.1）。
  ///
  /// [fireAtAfter]（DAT-05 配套）：只删 `fire_at >` 该时刻的 pending。
  /// 传 null = 删全部 pending（旧行为）。**远程路径已改用原子化的
  /// [replacePendingForTask]**，本方法保留给"只清不建"的场景
  /// （如任务被停用时清空未来计划）—— 那里同样应传 `fireAtAfter: now`，
  /// 否则会把已到期、正待补执行的那几条一起删掉（漏触发）。
  Future<int> deletePendingForTask(String taskId, {DateTime? fireAtAfter}) {
    var where = "task_id = ? AND status = 'pending'";
    final args = <Object?>[taskId];
    if (fireAtAfter != null) {
      where = '$where AND fire_at > ?';
      args.add(fireAtAfter.millisecondsSinceEpoch);
    }
    return _db.db.delete('occurrences', where: where, whereArgs: args);
  }

  /// 「跳过下一次」：把该任务最近的**未执行**计划标记为 skipped。
  /// 返回真实被跳过的条数（0 或 1）。
  ///
  /// ## 为什么候选集包含 `running`（R94）
  /// 用户点"跳过下一次"时，那一条可能**正在执行**（`running` 占用态）。
  /// 旧实现只找 `pending`，于是会跳掉**再下一次**，而"这一次"照响 ——
  /// 与用户意图相反。现在命中 `running` 时把它置 `skipped`：执行者的终态 CAS
  /// （`from: {running}`）会因此落空，**不会**把 skipped 覆盖成 done/failed，
  /// 审计如实保留"用户跳过了"。
  ///
  /// ## 为什么包事务（DAT-17）
  /// 旧实现是 `SELECT ... LIMIT 1` → `markStatus`，两条独立语句、无状态条件。
  /// 本地点击与远程 `task.skipNext` 并发时两者读到同一行、各自"成功"、都返回 1，
  /// 实际只跳了一条。放进单事务（`BEGIN IMMEDIATE` 一开始就持写锁）后
  /// 读-改-写不可能被插入；再叠加 `WHERE status = ?` 条件，返回值即事实。
  Future<int> skipNextForTask(String taskId) =>
      _db.db.transaction((txn) async {
        final rows = await txn.query(
          'occurrences',
          where: "task_id = ? AND status IN ('pending', 'running') "
              'AND fire_at >= ?',
          whereArgs: [taskId, DateTime.now().millisecondsSinceEpoch],
          orderBy: 'fire_at ASC',
          limit: 1,
        );
        if (rows.isEmpty) return 0;
        final id = rows.first['id'] as String;
        final cur = rows.first['status'] as String;
        return txn.update(
          'occurrences',
          {'status': OccurrenceStatus.skipped.name},
          where: 'id = ? AND status = ?',
          whereArgs: [id, cur],
        );
      });

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
