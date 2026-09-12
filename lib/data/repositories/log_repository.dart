import '../db/app_database.dart';

/// 执行日志仓储（审计与排障核心）。
class LogRepository {
  LogRepository(this._db);

  final AppDatabase _db;

  Future<void> append({
    required String source,
    required String action,
    required String status,
    String? taskId,
    String? occurrenceId,
    double? volume,
    int? durationMs,
    String? message,
  }) =>
      _db.db.insert('exec_logs', {
        'task_id': taskId,
        'occurrence_id': occurrenceId,
        'source': source,
        'action': action,
        'status': status,
        'volume': volume,
        'duration_ms': durationMs,
        'message': message,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

  Future<List<Map<String, Object?>>> recent(
          {int limit = 200, int offset = 0}) =>
      _db.db.query('exec_logs',
          orderBy: 'created_at DESC', limit: limit, offset: offset);

  Future<int> countSince(DateTime t) async {
    final r = await _db.db.rawQuery(
      'SELECT COUNT(*) AS c FROM exec_logs WHERE created_at >= ?',
      [t.millisecondsSinceEpoch],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  Future<int> purgeOlderThan(DateTime t) => _db.db.delete('exec_logs',
      where: 'created_at < ?', whereArgs: [t.millisecondsSinceEpoch]);
}
