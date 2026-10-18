import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';

import '../db/app_database.dart';

/// 任务与音源仓储。
class TaskRepository {
  TaskRepository(this._db);

  final AppDatabase _db;

  Future<List<Task>> listAll({bool enabledOnly = false}) async {
    final rows = await _db.db.query(
      'tasks',
      where: enabledOnly ? 'enabled = 1' : null,
      orderBy: 'priority DESC, created_at DESC',
    );
    return rows.map(Task.fromRow).toList();
  }

  Future<Task?> get(String id) async {
    final rows =
        await _db.db.query('tasks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Task.fromRow(rows.first);
  }

  /// 任务行映射（`upsert` / `upsertMany` 共用，避免两条路径漂移）。
  static Map<String, Object?> _row(Task t) => {
        ...t.toRow(),
        'trigger_json': jsonEncode(t.trigger.toJson()),
        'action_json': jsonEncode(t.action.toJson()),
        'asset_ids': jsonEncode(t.assetIds),
      };

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

  /// 从所有任务的 `asset_ids` 里摘掉 [assetId]（BUG-148），返回被改写的任务数。
  ///
  /// ## 为什么必须做
  /// 音源被删除后，任务的 `asset_ids` 仍指向它 —— `BackgroundEngine.pickAssetFor`
  /// 按 id 查 `audio_assets` 查不到行 ⇒ 触发时**无声失败**，只写一条
  /// "无可用音源"。用户看到的是"这个任务突然不响了"，完全联想不到是自己删了音源。
  ///
  /// 摘引用后任务退化成两种都能理解的状态：还有别的音源 → 从剩下的里挑；
  /// 一个都不剩 → `assetIds` 为空（引擎按"库内全部音源"随机，见 `pickAssetFor`）。
  ///
  /// ⚠️ 用 Dart 侧过滤而不是 SQL `json_remove`：sqflite 绑定的 SQLite 版本
  /// 在 Android/iOS/桌面三端不一致，JSON1 扩展不保证存在。
  Future<int> removeAssetRef(String assetId) async {
    if (assetId.isEmpty) return 0;
    final rows = await _db.db.query('tasks', columns: ['id', 'asset_ids']);
    final batch = _db.db.batch();
    var n = 0;
    for (final r in rows) {
      final ids = _decodeAssetIdsColumn(r['asset_ids']);
      if (!ids.contains(assetId)) continue;
      batch.update(
        'tasks',
        {'asset_ids': jsonEncode(ids.where((x) => x != assetId).toList())},
        where: 'id = ?',
        whereArgs: [r['id']],
      );
      n++;
    }
    if (n == 0) return 0;
    await batch.commit(noResult: true);
    return n;
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
  Future<Set<String>> nameSet() async {
    final rows = await _db.db.query('audio_assets', columns: ['name']);
    return rows.map((r) => r['name'] as String).toSet();
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
        tags: (r['tags'] == null || (r['tags'] as String).isEmpty)
            ? const []
            : (jsonDecode(r['tags'] as String) as List).cast<String>(),
        weight: (r['weight'] as num?)?.toDouble() ?? 1.0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );
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
