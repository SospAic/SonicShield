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

/// 统计聚合（v2.0 看板）。
extension LogStats on LogRepository {
  /// 最近 N 天每日执行计数（日期升序）。
  Future<List<({String day, int total, int failed})>> dailyCounts(
      {int days = 7}) async {
    final rows = await _db.db.rawQuery('''
      SELECT date(created_at/1000, 'unixepoch', 'localtime') AS d,
             COUNT(*) AS total,
             SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed
      FROM exec_logs
      WHERE created_at >= ?
      GROUP BY d
      ORDER BY d ASC
      LIMIT ?
    ''', [
      DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch,
      days
    ]);
    return [
      for (final r in rows)
        (
          day: r['d'] as String? ?? '',
          total: (r['total'] as int?) ?? 0,
          failed: (r['failed'] as int?) ?? 0,
        )
    ];
  }

  /// 按动作类型分布。
  Future<List<({String action, int count})>> actionBreakdown() async {
    final rows = await _db.db.rawQuery('''
      SELECT action, COUNT(*) AS c FROM exec_logs
      GROUP BY action ORDER BY c DESC
    ''');
    return [
      for (final r in rows)
        (action: r['action'] as String? ?? '', count: (r['c'] as int?) ?? 0)
    ];
  }

  /// 状态占比。
  Future<Map<String, int>> statusBreakdown() async {
    final rows = await _db.db.rawQuery(
        'SELECT status, COUNT(*) AS c FROM exec_logs GROUP BY status');
    return {
      for (final r in rows)
        (r['status'] as String?) ?? 'unknown': (r['c'] as int?) ?? 0
    };
  }
}
