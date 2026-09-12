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

  Future<void> upsert(Task t) => _db.db.insert(
        'tasks',
        {
          ...t.toRow(),
          'trigger_json': jsonEncode(t.trigger.toJson()),
          'action_json': jsonEncode(t.action.toJson()),
          'asset_ids': jsonEncode(t.assetIds)
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

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

  Future<void> upsert(AudioAsset a) => _db.db.insert(
        'audio_assets',
        {
          'id': a.id,
          'name': a.name,
          'path': a.path,
          'duration_ms': a.durationMs,
          'size_bytes': a.sizeBytes,
          'tags': jsonEncode(a.tags),
          'weight': a.weight,
          'created_at': a.createdAt.millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

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
}
