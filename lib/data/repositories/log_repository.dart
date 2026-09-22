import '../db/app_database.dart';

/// 一条待写入的执行日志（[LogRepository.appendMany] 的元素类型）。
typedef LogRecord = ({
  String source,
  String action,
  String status,
  String? taskId,
  String? occurrenceId,
  double? volume,
  int? durationMs,
  String? message,
});

/// 执行日志仓储（审计与排障核心）。
class LogRepository {
  LogRepository(this._db);

  final AppDatabase _db;

  static Map<String, Object?> _row(LogRecord e, int createdAtMs) => {
        'task_id': e.taskId,
        'occurrence_id': e.occurrenceId,
        'source': e.source,
        'action': e.action,
        'status': e.status,
        'volume': e.volume,
        'duration_ms': e.durationMs,
        'message': e.message,
        'created_at': createdAtMs,
      };

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
      _db.db.insert(
        'exec_logs',
        _row(
          (
            source: source,
            action: action,
            status: status,
            taskId: taskId,
            occurrenceId: occurrenceId,
            volume: volume,
            durationMs: durationMs,
            message: message,
          ),
          DateTime.now().millisecondsSinceEpoch,
        ),
      );

  /// 批量写入执行日志（单事务 + **单次**平台通道往返）。
  ///
  /// **为什么需要它（BUG-035，2026-09-18 AOT 实测）**：
  /// 设备上每次 sqflite 调用都要走一次
  /// `Dart → 平台通道 → 原生 SQLite` 的往返，AOT 实测 **≈1.5ms/次**
  /// （5000 条逐条 [append] = 7755ms；500 次任务 upsert+get = 1477ms，
  /// 两者每次调用成本一致 → 瓶颈是往返而非磁盘）。
  /// 逐条写入 5000 条 = 5000 次往返；本方法把整批压成 **1 次**。
  ///
  /// 同一批内 `created_at` 取同一时间戳（批量导入语义：同批同刻）。
  /// 空集合直接返回，不产生任何数据库调用。
  /// 范式与 `OccurrenceRepository.commitAll` 一致。
  Future<void> appendMany(Iterable<LogRecord> entries) async {
    final batch = _db.db.batch();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var n = 0;
    for (final e in entries) {
      batch.insert('exec_logs', _row(e, nowMs));
      n++;
    }
    if (n == 0) return;
    await batch.commit(noResult: true);
  }

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

  /// 夜间豁免次数（v1.9，docs/20 §8.2 约束 2：**不得静默生效**）。
  ///
  /// 设置页据此展示"本月豁免 N 次"——豁免是**削弱护栏**的行为，
  /// 必须让用户看得见自己用了几次，否则等于无痕绕过。
  Future<int> countQuietExemptSince(DateTime t) async {
    final r = await _db.db.rawQuery(
      'SELECT COUNT(*) AS c FROM exec_logs '
      "WHERE action = 'quietExempt' AND created_at >= ?",
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
