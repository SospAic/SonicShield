import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';

import '../db/app_database.dart';

/// 任务与音源仓储。
class TaskRepository {
  TaskRepository(this._db);

  final AppDatabase _db;

  /// 列出全部任务。
  ///
  /// ## 🔴 R90-09（2026-10-19）：**单行损坏不得拖垮整表**
  ///
  /// `Task.fromRow` 里有裸 `values.byName`、`jsonDecode`、`TriggerConfig.fromJson`
  /// （未知 kind 直接 `throw ArgumentError`）。旧实现 `rows.map(Task.fromRow)`
  /// 让**任意一行**坏数据（旧版本写入的新 kind / 手工改库 / 写坏 JSON）把整个
  /// 查询炸掉 ⇒ 引擎 tick、声音事件、任务列表页**同时不可用**，用户只看到
  /// "列表空了 / 任务不响"，日志里什么都没有。
  ///
  /// 现在逐行兜底：坏行跳过并回调 [onRowError]（调用方负责留痕），其余行照常返回。
  /// **不静默**：跳过多少行由调用方决定怎么报。
  Future<List<Task>> listAll({
    bool enabledOnly = false,
    void Function(String id, Object error)? onRowError,
  }) async {
    final rows = await _db.db.query(
      'tasks',
      where: enabledOnly ? 'enabled = 1' : null,
      orderBy: 'priority DESC, created_at DESC',
    );
    final out = <Task>[];
    for (final r in rows) {
      try {
        out.add(Task.fromRow(r));
      } on Object catch (e) {
        final rawId = r['id'];
        onRowError?.call(rawId is String ? rawId : '', e);
      }
    }
    return out;
  }

  /// 按 id 取一条任务。
  ///
  /// ## DAT-02：坏行**不得**炸穿调用方
  /// [listAll] 早就做了行级兜底（R90-09），但 `get()` 没有。而
  /// `BackgroundEngine.executeDue` 的循环里是裸 `await tasksRepo.get(o.taskId)`：
  /// 一条坏行（未知 `trigger_type` / 坏 `trigger_json` / 缺必填键）就会让
  /// **整轮到期计划全部作废**（异常穿出 `for`，被 `stepGuarded` 吞成一条审计），
  /// 下一 tick 同一顺序再次抛 —— 用户感知为"所有任务突然都不响"。
  ///
  /// 现在：解析失败 → 回调 [onRowError]（调用方留痕）→ 返回 null。
  /// 调用方拿到 null 的语义是"这条任务不可用"，与"任务不存在"同路处理
  /// （跳过本条的 occurrence），**不再**影响同轮其它任务。
  Future<Task?> get(
    String id, {
    void Function(String id, Object error)? onRowError,
  }) async {
    final rows =
        await _db.db.query('tasks', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    try {
      return Task.fromRow(rows.first);
    } on Object catch (e) {
      onRowError?.call(id, e);
      return null;
    }
  }

  /// 在**同一个事务**里执行 [body]（DAT-04 / DAT-15 的共享事务句柄）。
  ///
  /// ## 为什么必须由仓储层暴露
  /// 此前所有"跨仓储多步写"（反击计划替换、批量删除、远程 `task.upsert`）
  /// 都没有共享事务，因为服务层拿不到 `Database`。sqflite 的
  /// `db.transaction` 是 `BEGIN IMMEDIATE`（开事务即持写锁），
  /// 把多步写放进来后，中途任何一步抛错都会**整体回滚**，
  /// 不会留下"旧数据已删、新数据没写"的空窗。
  ///
  /// ⚠️ [body] 里**不要**再调 `_db.db.transaction(...)`（sqflite 不支持嵌套事务，
  /// 会抛 "cannot start a transaction within a transaction"）；
  /// 需要多步时在同一个 `txn` 上继续写。
  Future<T> inTransaction<T>(Future<T> Function(DatabaseExecutor txn) body) =>
      _db.db.transaction(body);

  /// 任务行映射（`upsert` / `upsertMany` / 批量替换共用，避免多条路径漂移）。
  ///
  /// DAT-12 之后 [Task.toRow] 自己就产出可绑定的行（三列 JSON 已编码），
  /// 这里**不再**覆盖 —— 保留这个薄封装是为了让"行映射只有一处"这件事
  /// 在调用点仍然可读，而不是到处散落 `t.toRow()`。
  static Map<String, Object?> _row(Task t) => t.toRow();

  /// 写入/更新一条任务（**不使用 REPLACE**）。
  ///
  /// ## 为什么必须避开 `ConflictAlgorithm.replace`（P2-02）
  /// SQLite 的 `INSERT OR REPLACE` 在**主键冲突时先 DELETE 再 INSERT**，
  /// 而不是原地更新。而 `occurrences.task_id` 是
  /// `REFERENCES tasks(id) ON DELETE CASCADE` —— 于是**每次编辑任务**
  /// （同 id 重写）都会把那一条任务**全部历史计划/执行记录级联删掉**：
  /// 已完成审计消失、冷却基准（`lastDoneFor`）归零、跳过记录丢失。
  /// 表现为"改个名字，冷却突然不生效了 / 统计里记录没了"。
  ///
  /// 因此改为「先 UPDATE，未命中再 INSERT」：两条语句都不触发 DELETE，
  /// 外键级联不会被误触发，历史完整保留。
  Future<void> upsert(Task t) async {
    final row = _row(t);
    // BUG-147：UPDATE → INSERT 必须在**同一事务**里。
    //
    // 两条独立语句之间存在一个可观测的中间态：更新落空（行还不存在）之后、
    // 插入执行之前若进程被杀，或者另一条写路径（引擎物化 / 远程 `task.upsert`）
    // 在同一个 id 上抢先插入，就会出现"更新没命中、插入又冲突"——
    // 前者让任务保存后**凭空消失**，后者抛 `UNIQUE constraint failed`。
    // 单事务同时消除半写与竞态；`noResult` 语义不变（先 UPDATE 后 INSERT，
    // **全程无 DELETE**，不触发 `occurrences` 的级联，见上方 P2-02）。
    await _db.db.transaction((txn) async {
      final n =
          await txn.update('tasks', row, where: 'id = ?', whereArgs: [t.id]);
      if (n == 0) await txn.insert('tasks', row);
    });
  }

  /// **批量**写入（单事务 / **单次平台通道往返**）。
  ///
  /// 为什么需要它：设备上**每次 sqflite 调用 = 一次 Dart→平台通道→原生 SQLite
  /// 往返 ≈1.5ms**（BUG-035 由两条互不相干的工作负载交叉验证），
  /// 而"任务导入"是唯一会**成批**写任务的路径 —— 逐条 `await upsert()` 导入
  /// N 条就是 N 次往返。改成整批一次往返后，成本与 N 基本解耦。
  ///
  /// 另一个同样重要的收益是**原子性**：整批在同一个事务里提交，
  /// 中途任何一条出错都**不会留下半批数据**（旧的逐条循环会留下已写入的部分，
  /// 使用者看到的是"导入失败"但任务列表里多了一截）。
  ///
  /// 空集合直接返回，不产生任何数据库操作。
  /// 与单条 [upsert] 同一语义（先 UPDATE 再 INSERT），并保持
  /// **单事务 / 单次平台通道往返**：批内对每条任务依次排入
  /// `UPDATE` 与 `INSERT OR IGNORE` —— 已存在则 UPDATE 命中、INSERT 被忽略；
  /// 不存在则 UPDATE 空转、INSERT 落库。**全程无 DELETE**，
  /// 因此不会触发 `occurrences` 的 `ON DELETE CASCADE`（P2-02）。
  Future<void> upsertMany(Iterable<Task> items) async {
    final batch = _db.db.batch();
    var n = 0;
    for (final t in items) {
      final row = _row(t);
      batch.update('tasks', row, where: 'id = ?', whereArgs: [t.id]);
      batch.insert('tasks', row, conflictAlgorithm: ConflictAlgorithm.ignore);
      n++;
    }
    if (n == 0) return;
    await batch.commit(noResult: true);
  }

  Future<void> setEnabled(String id, bool enabled) => _db.db.update(
        'tasks',
        {
          'enabled': enabled ? 1 : 0,
          'updated_at': DateTime.now().millisecondsSinceEpoch
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> delete(String id) =>
      _db.db.delete('tasks', where: 'id = ?', whereArgs: [id]);

  /// **批量**删除（单事务，DAT-15）。
  ///
  /// ## 为什么需要它
  /// 任务列表的"整包删除 / 多选删除 / 单条菜单删除"此前都是 Dart 侧
  /// `for (final id in ids) { await repo.delete(id); await occ.deleteForTask(id); }`
  /// —— 中途某条失败就跳出，前面的已删、后面的还在，而提示语只说
  /// "批量删除失败：$e"，不告诉用户到底删了几条。用户看到"失败"却少了任务，
  /// 很容易误判数据状态。
  ///
  /// 单事务 `DELETE FROM tasks WHERE id IN (...)`：要么全删、要么全不删。
  /// 按 400 个一组切块，避开 `SQLITE_MAX_VARIABLE_NUMBER`（旧版 999）。
  /// `occurrences` 由外键 `ON DELETE CASCADE` 一并清理，调用方**不需要**
  /// 再逐条 `deleteForTask`（那一步本来也是冗余的）。
  Future<int> deleteMany(Iterable<String> ids) async {
    final list = ids.where((e) => e.isNotEmpty).toList();
    if (list.isEmpty) return 0;
    return _db.db.transaction((txn) async {
      var n = 0;
      for (var i = 0; i < list.length; i += 400) {
        final end = i + 400 < list.length ? i + 400 : list.length;
        final chunk = list.sublist(i, end);
        final ph = List.filled(chunk.length, '?').join(',');
        n += await txn.delete('tasks', where: 'id IN ($ph)', whereArgs: chunk);
      }
      return n;
    });
  }

  /// 从所有任务的 `asset_ids` 里摘掉 [assetId]（BUG-148 / DAT-06），
  /// 返回被改写的任务数。
  ///
  /// ## 为什么必须做
  /// 音源被删除后，任务的 `asset_ids` 仍指向它 —— `BackgroundEngine.pickAssetFor`
  /// 按 id 查 `audio_assets` 查不到行 ⇒ 触发时**无声失败**，只写一条
  /// "无可用音源"。用户看到的是"这个任务突然不响了"，完全联想不到是自己删了音源。
  ///
  /// 摘引用后任务退化成两种都能理解的状态：还有别的音源 → 从剩下的里挑；
  /// 一个都不剩 → `assetIds` 为空（引擎按"库内全部音源"随机，见 `pickAssetFor`）。
  ///
  /// ## DAT-06：为什么必须包事务 + 带乐观条件
  /// 旧实现是 `SELECT 全表`（拿快照）→ Dart 侧过滤 → `batch UPDATE` 用**旧快照**
  /// 整列覆盖。若这期间另一条写路径（用户刚在编辑器里加了新音源、或远程
  /// `task.upsert`）改了同一行的 `asset_ids`，新加的音源引用会被回退掉 ——
  /// 表现为"随机性变差"而非报错，极难排查。
  ///
  /// 现在两步在**同一个事务**里（`BEGIN IMMEDIATE` 一开始就持写锁，
  /// 读到的快照在整个事务内不可能被别的连接改动），并且 UPDATE 额外带上
  /// `AND asset_ids = <读到的原文>` 做乐观校验：万一将来有人把这段拆出事务，
  /// 条件不成立时返回 0（不算改写），也不会用旧快照覆盖新值。
  ///
  /// ⚠️ 用 Dart 侧过滤而不是 SQL `json_remove`：sqflite 绑定的 SQLite 版本
  /// 在 Android/iOS/桌面三端不一致，JSON1 扩展不保证存在。
  Future<int> removeAssetRef(String assetId) async {
    if (assetId.isEmpty) return 0;
    return _db.db.transaction((txn) async {
      final rows = await txn.query('tasks', columns: ['id', 'asset_ids']);
      var n = 0;
      for (final r in rows) {
        final raw = r['asset_ids'];
        final ids = _decodeAssetIdsColumn(raw);
        if (!ids.contains(assetId)) continue;
        final next = jsonEncode(ids.where((x) => x != assetId).toList());
        final changed = await txn.update(
          'tasks',
          {'asset_ids': next},
          // 乐观条件：只在列值仍是我们读到的那一版时才写。
          where: 'id = ? AND asset_ids = ?',
          whereArgs: [r['id'], raw],
        );
        n += changed;
      }
      return n;
    });
  }

  /// `asset_ids` 列的反解（兼容 DB 里的 JSON 字符串与内存 List）。
  static List<String> _decodeAssetIdsColumn(Object? v) {
    if (v is List) return v.whereType<String>().toList();
    if (v is String && v.isNotEmpty) {
      try {
        final j = jsonDecode(v);
        if (j is List) return j.whereType<String>().toList();
      } on Object {
        // 坏数据：当成"没有引用"，不影响其它任务。
      }
    }
    return <String>[];
  }

  // ---- 反击计划（v2.0）----
  //
  // 计划任务 id 形如 `counter:{planId}:{key}`（见 `CounterPlanMaterializer`）。
  // 读取/删除都按**前缀范围**而不是 `LIKE`：LIKE 的 `_`/`%` 是通配符，
  // 而 planId 允许含 `_`（归一化时保留），用 LIKE 会误伤其它计划。

  /// 某计划当前已落库的任务 id（用于对账/展示）。
  Future<List<String>> counterTaskIds(String planId) async {
    final p = CounterPlanMaterializer.taskIdPrefix(planId);
    final rows = await _db.db.query(
      'tasks',
      columns: ['id'],
      where: 'id >= ? AND id < ?',
      whereArgs: [p, '$p\uffff'],
    );
    return rows.map((r) => r['id'] as String).toList();
  }

  /// 删除某计划的**全部**计划任务（下线/重新导入前清场）。
  ///
  /// ⚠️ 只删 `counter:{planId}:` 命名空间内的行，绝不触碰手动任务。
  /// 外键 `occurrences.task_id → tasks.id ON DELETE CASCADE` 会把它们的
  /// 未执行计划一并带走（这正是我们要的：旧计划不该变成幽灵）。
  Future<int> deleteCounterTasks(String planId) async {
    final p = CounterPlanMaterializer.taskIdPrefix(planId);
    return _db.db.delete('tasks',
        where: 'id >= ? AND id < ?', whereArgs: [p, '$p\uffff']);
  }

  /// **原子替换**某计划的整族任务（DAT-04）：单事务内
  /// 「写新集合（UPDATE→INSERT，全程无 DELETE）→ 删掉不在新集合里的旧 id」。
  ///
  /// ## 为什么不能沿用"整族删除 + 批量插入"
  /// 旧 `CounterPlanService.apply(replace:true)` 是
  /// `deleteCounterTasks` → `upsertMany` 两条**独立**语句。删除先提交后若
  /// 插入失败（磁盘满 / `database is locked` / 进程被杀 / 行违反 NOT NULL），
  /// **旧计划已被删光、新计划一条没写** —— 用户看到"应用失败"，
  /// 但反击计划已整体消失。更糟的是 `occurrences.task_id` 是
  /// `ON DELETE CASCADE`：整族 DELETE 会把这批任务的**全部历史**
  /// （done/failed/skipped）一起抹掉，而 `exec_logs` 因无外键仍留着 ⇒
  /// 审计出现"日志说有执行、计划表里查不到"的断裂，冷却基准也归零。
  ///
  /// ## 差异删除的语义
  /// 只删"旧有、新集合里没有"的 id：仍在新计划里的任务**原地保留**，
  /// 历史与冷却基准都不受影响。真正消失的那些任务（参数变小后多出来的时刻）
  /// 仍会被级联删掉其计划 —— 那是正确且必要的（否则变幽灵计划）。
  ///
  /// 返回 `(upserted, removed)`：写入的新集合条数 / 真正删掉的旧任务条数。
  /// ⚠️ 只接受 `counter:{planId}:` 命名空间内的 id，命名空间外的条目直接忽略，
  /// 保证"绝不触碰手动任务"这条红线。
  Future<({int upserted, int removed})> replaceCounterTasks(
      String planId, Iterable<Task> tasks) async {
    final prefix = CounterPlanMaterializer.taskIdPrefix(planId);
    final list = tasks.toList();
    return _db.db.transaction((txn) async {
      final keep = <String>{};
      for (final t in list) {
        if (!t.id.startsWith(prefix)) continue;
        if (!keep.add(t.id)) continue;
        final row = _row(t);
        final n =
            await txn.update('tasks', row, where: 'id = ?', whereArgs: [t.id]);
        // 全程无 DELETE ⇒ 不触发 occurrences 的级联（P2-02）。
        if (n == 0) {
          await txn.insert('tasks', row,
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      final oldRows = await txn.query(
        'tasks',
        columns: ['id'],
        where: 'id >= ? AND id < ?',
        whereArgs: [prefix, '$prefix\uffff'],
      );
      final stale = <String>[
        for (final r in oldRows)
          if (!keep.contains(r['id'] as String)) r['id'] as String,
      ];
      var removed = 0;
      for (var i = 0; i < stale.length; i += 400) {
        final end = i + 400 < stale.length ? i + 400 : stale.length;
        final chunk = stale.sublist(i, end);
        final ph = List.filled(chunk.length, '?').join(',');
        removed +=
            await txn.delete('tasks', where: 'id IN ($ph)', whereArgs: chunk);
      }
      return (upserted: keep.length, removed: removed);
    });
  }
}

/// 音源仓储。
class AssetRepository {
  AssetRepository(this._db);

  final AppDatabase _db;

  Future<List<AudioAsset>> listAll() async {
    final rows = await _db.db.query('audio_assets', orderBy: 'created_at DESC');
    return rows.map(_fromRow).toList();
  }

  /// 库内已有音源名集合 —— 「导入预置库」的**幂等判据**。
  ///
  /// 只取 `name` 一列：预置库导入要按名字去重，把整表读进内存既慢又没必要。
  ///
  /// ⚠️ 本方法是"先读后写"的**快照**：单用它做幂等判据存在 TOCTOU 窗口
  /// （连点两次导入、或导入与另一入口并发，都会读到旧集合 ⇒ 同名重复插入）。
  /// 需要**原子**幂等时改用 [insertMissingByName]。
  Future<Set<String>> nameSet() async {
    final rows = await _db.db.query('audio_assets', columns: ['name']);
    return rows.map((r) => r['name'] as String).toSet();
  }

  /// **事务内判重 + 插入**（DAT-16）：把 [items] 里名字尚未落库的条目写入，
  /// 返回 `(inserted, skipped)`。
  ///
  /// ## 为什么不能靠 `nameSet()` + `upsertMany`
  /// 那是"先读后写"两步：两次导入并发（或用户快速连点"导入预置库"）都会读到
  /// 旧集合，各插一条同名音源。表本身也不阻止同名（`audio_assets` **没有**
  /// `UNIQUE(name)`），于是库内出现重复项 —— 权重随机被放大、列表噪音，
  /// 而且 `resolvePresetAudioIds` 会命中多条。
  ///
  /// ## 为什么不加 `UNIQUE(name)`
  /// 本地导入**允许**同名多份（同一首歌的不同片段），业务上不能一刀切；
  /// 且存量库可能已有重复行，迁移期建唯一索引会直接失败 ⇒ 整库打不开。
  ///
  /// 因此幂等只由"预置导入"这条路径在**单事务**内保证：事务一开始
  /// （`BEGIN IMMEDIATE`）就持写锁，先 `SELECT ... WHERE name IN (...)`，
  /// 再插缺失项 —— 并发的第二次调用会在锁上等待，等到的已是写完的集合。
  /// 同一批内同名条目也只取第一条（`names.add` 失败即跳过）。
  Future<({int inserted, int skipped})> insertMissingByName(
      Iterable<AudioAsset> items) async {
    final list = items.toList();
    if (list.isEmpty) return (inserted: 0, skipped: 0);
    return _db.db.transaction((txn) async {
      final wanted = <String>[];
      for (final a in list) {
        if (!wanted.contains(a.name)) wanted.add(a.name);
      }
      final existing = <String>{};
      for (var i = 0; i < wanted.length; i += 400) {
        final end = i + 400 < wanted.length ? i + 400 : wanted.length;
        final chunk = wanted.sublist(i, end);
        final ph = List.filled(chunk.length, '?').join(',');
        final rows = await txn.query('audio_assets',
            columns: ['name'], where: 'name IN ($ph)', whereArgs: chunk);
        existing.addAll(rows.map((r) => r['name'] as String));
      }
      final seen = <String>{};
      var inserted = 0;
      var skipped = 0;
      for (final a in list) {
        if (existing.contains(a.name) || !seen.add(a.name)) {
          skipped++;
          continue;
        }
        await txn.insert('audio_assets', a.toRow(),
            conflictAlgorithm: ConflictAlgorithm.replace);
        inserted++;
      }
      return (inserted: inserted, skipped: skipped);
    });
  }

  Future<void> upsert(AudioAsset a) => _db.db.insert(
        'audio_assets',
        a.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// **批量**写入（单事务 / **单次平台通道往返**）。
  ///
  /// 与 `TaskRepository.upsertMany` / `LogRepository.appendMany` 同一范式。
  /// 「导入预置库」一次要写 **60** 条，逐条 `await upsert()` 就是 60 次
  /// Dart→平台通道→原生 SQLite 往返（每次 ≈1.5ms，BUG-035 实测）。
  ///
  /// 但**第一收益仍是原子性**：逐条循环中途失败会留下**半套音源库**
  /// —— 使用者看到「导入失败」，音源列表里却已经多出一截；
  /// 单事务天然免疫（要么 60 条都在，要么一条都没有）。
  ///
  /// 空集合直接返回，不产生任何数据库操作。
  Future<void> upsertMany(Iterable<AudioAsset> items) async {
    final batch = _db.db.batch();
    var n = 0;
    for (final a in items) {
      batch.insert('audio_assets', a.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      n++;
    }
    if (n == 0) return;
    await batch.commit(noResult: true);
  }

  Future<void> delete(String id) =>
      _db.db.delete('audio_assets', where: 'id = ?', whereArgs: [id]);

  static AudioAsset _fromRow(Map<String, dynamic> r) => AudioAsset(
        id: r['id'] as String,
        name: r['name'] as String,
        path: r['path'] as String,
        durationMs: r['duration_ms'] as int? ?? 0,
        sizeBytes: r['size_bytes'] as int? ?? 0,
        // R90-26：坏 tags 不得让整张音源表抛错（旧实现裸 `jsonDecode`）。
        tags: _decodeTags(r['tags']),
        weight: (r['weight'] as num?)?.toDouble() ?? 1.0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );

  /// `tags` 列的反解（R90-26）：坏 JSON / 非字符串数组 → 空列表，不影响其它行。
  static List<String> _decodeTags(Object? v) {
    if (v is! String || v.isEmpty) return const [];
    try {
      final j = jsonDecode(v);
      if (j is List) return j.whereType<String>().toList();
    } on Object {
      // 坏数据：当成"没有标签"。
    }
    return const [];
  }
}

class AudioAsset {
  const AudioAsset({
    required this.id,
    required this.name,
    required this.path,
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.tags = const [],
    this.weight = 1.0,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String path; // 应用私有目录内的相对/绝对路径
  final int durationMs;
  final int sizeBytes;
  final List<String> tags; // 供任务按标签筛选音源
  final double weight; // 随机权重
  final DateTime createdAt;

  /// 行映射（`upsert` / `upsertMany` 共用，避免两条路径漂移）。
  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'path': path,
        'duration_ms': durationMs,
        'size_bytes': sizeBytes,
        'tags': jsonEncode(tags),
        'weight': weight,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}
