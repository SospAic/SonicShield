import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// SQLite 访问层（单例）。
///
/// 设计取舍（ADR-004）：
/// - 使用 sqflite 手写 SQL，零代码生成，仓库可立即静态分析；
///   后续如需类型安全迁移路径见 docs/07 的 Drift 迁移方案。
/// - 复杂嵌套配置（trigger/action）以 JSON 文本列存储，核心查询列
///   （enabled/trigger_type/fire_at/status 等）保持强类型列以便索引。
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const int dbVersion = 2;
  static AppDatabase? _instance;

  static Future<AppDatabase> open([String? dirOverride]) async {
    if (_instance != null) return _instance!;
    // 特殊路径（如测试用 ':memory:'）直接作为数据库文件名，不做目录拼接。
    final String path;
    if (dirOverride != null && dirOverride.startsWith(':')) {
      path = dirOverride;
    } else {
      path = p.join(dirOverride ?? await _defaultDir(), 'sonic_shield.db');
    }
    final db = await openDatabase(
      path,
      version: dbVersion,
      onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    _instance = AppDatabase._(db);
    return _instance!;
  }

  /// 测试/后台隔离用：注入独立实例。
  static void inject(AppDatabase instance) => _instance = instance;

  static Future<String> _defaultDir() async {
    // sqflite 默认目录在 Android/iOS 可用；桌面/测试由 FFI 实现提供路径。
    return databaseFactory.getDatabasesPath();
  }

  static Future<void> _onCreate(Database db, int v) async {
    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        trigger_type TEXT NOT NULL,
        trigger_json TEXT NOT NULL,
        action_type TEXT NOT NULL,
        action_json TEXT NOT NULL,
        asset_ids TEXT NOT NULL DEFAULT '[]',
        cooldown_sec INTEGER NOT NULL DEFAULT 300,
        quiet_policy TEXT NOT NULL DEFAULT 'skip',
        priority INTEGER NOT NULL DEFAULT 0,
        condition_json TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''');
    await db.execute('CREATE INDEX idx_tasks_enabled ON tasks(enabled)');
    await db.execute('''
      CREATE TABLE audio_assets (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        size_bytes INTEGER NOT NULL DEFAULT 0,
        tags TEXT NOT NULL DEFAULT '[]',
        weight REAL NOT NULL DEFAULT 1.0,
        created_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE occurrences (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        fire_at INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        volume REAL,
        duration_ms INTEGER
      )''');
    await db.execute('CREATE INDEX idx_occ_fire ON occurrences(fire_at)');
    await db.execute('CREATE INDEX idx_occ_status ON occurrences(status)');
    await db.execute('''
      CREATE TABLE exec_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT,
        occurrence_id TEXT,
        source TEXT NOT NULL,          -- schedule | sound | manual
        action TEXT NOT NULL,
        status TEXT NOT NULL,          -- success | failed | skipped
        volume REAL,
        duration_ms INTEGER,
        message TEXT,
        created_at INTEGER NOT NULL
      )''');
    await db.execute('CREATE INDEX idx_logs_created ON exec_logs(created_at)');
    await db.execute('''
      CREATE TABLE sound_profiles (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        threshold_db REAL NOT NULL DEFAULT -35,
        min_duration_ms INTEGER NOT NULL DEFAULT 800,
        cooldown_sec INTEGER NOT NULL DEFAULT 120,
        only_while_charging INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE kv (
        k TEXT PRIMARY KEY,
        v TEXT NOT NULL
      )''');
  }

  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    // v1 → v2：任务条件层（2026-09，v1.3）。
    if (oldV < 2) {
      await db.execute('ALTER TABLE tasks ADD COLUMN condition_json TEXT');
    }
  }

  // ---------- kv ----------
  Future<String?> kvGet(String key) async {
    final rows =
        await db.query('kv', where: 'k = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  Future<void> kvSet(String key, String value) => db.insert(
        'kv',
        {'k': key, 'v': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  // ---------- 通用 JSON 列辅助 ----------
  static String encodeList(List<String> v) => jsonEncode(v);

  static List<String> decodeList(String s) =>
      (jsonDecode(s) as List).cast<String>();

  Future<void> close() async {
    await db.close();
    _instance = null;
  }
}
