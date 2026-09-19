import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:sonic_shield/domain/models/task.dart';

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

  Future<void> upsert(Task t) => _db.db.insert(
        'tasks',
        _row(t),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

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
  Future<void> upsertMany(Iterable<Task> items) async {
    final batch = _db.db.batch();
    var n = 0;
    for (final t in items) {
      batch.insert(
        'tasks',
        _row(t),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
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
