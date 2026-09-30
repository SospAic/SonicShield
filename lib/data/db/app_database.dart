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

  static const int dbVersion = 3;
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
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    _instance = AppDatabase._(db);
    return _instance!;
  }

  /// 连接级 PRAGMA。
  ///
  /// **BUG-022（冷启动 `SQLITE_BUSY: database is locked`）根因**：
  /// 后台引擎跑在 `flutter_background_service` 的**独立 FlutterEngine** 里，
  /// 与主 isolate 不是同一个插件实例 —— `_instance` 这个进程内静态单例
  /// 只能在一个引擎内去重，两个引擎各自持有**一条独立的原生连接**写同一个
  /// 数据库文件，默认 rollback journal 模式下写锁互斥即直接报错。
  ///
  /// 修复：WAL（读不阻塞写、写不阻塞读）+ `busy_timeout`（写锁冲突时等待
  /// 而非立刻失败）。二者都是持久/连接级设置，主引擎与后台引擎都会生效。
  ///
  /// > **踩坑（BUG-026）**：`PRAGMA` 是否可用 `execute` 取决于它**是否返回行**。
  /// > `busy_timeout` / `journal_mode` 都会返回一行结果，而 sqflite Android 的
  /// > `execute` 走 `execSQL`，遇到返回行的语句会抛
  /// > `Queries can be performed using SQLiteDatabase query or rawQuery methods only.`
  /// > 该异常会穿透 `openDatabase`，导致 `AppDatabase.open()` 失败 ——
  /// > 而它被 `main()` 在 `runApp` **之前** await，于是整屏白屏。
  /// > 统一用 `rawQuery`（它能容忍"无行"与"有行"两种情况）。
  static Future<void> _onConfigure(Database db) async {
    // 返回行 / 无返回行都安全：rawQuery 是唯一对两类 PRAGMA 都稳妥的入口。
    await db.rawQuery('PRAGMA foreign_keys = ON');
    await db.rawQuery('PRAGMA busy_timeout = 5000');
    await db.rawQuery('PRAGMA journal_mode = WAL');
    // 平衡断电安全与写入吞吐：WAL + NORMAL 不会在每次提交都 fsync。
    await db.rawQuery('PRAGMA synchronous = NORMAL');
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
        quiet_exempt INTEGER NOT NULL DEFAULT 0,
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
        duration_ms INTEGER,
        quiet_exempt INTEGER NOT NULL DEFAULT 0
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
    // v2 → v3：夜间独立豁免（2026-09，v1.9，docs/20 §8）。
    // 任务级开关，**默认 0 = 不豁免**；主开关另存于 kv，两者皆开才放行。
    // 老库补列后全部为 0，等价于"功能未启用"，行为与升级前一致。
    // BUG-079（第五十三轮抓修）：v2 时代 occurrences 表**同样没有** quiet_exempt 列，
    // 升级时漏补 ⇒ 旧库升级后 deletePendingQuietExempt()（关闭夜间豁免主开关时的
    // fail-safe 清除）每次调用必抛 `no such column`，replan 整链失败（模拟器现场每分钟刷）。
    if (oldV < 3) {
      await db.execute(
          'ALTER TABLE tasks ADD COLUMN quiet_exempt INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE occurrences ADD COLUMN quiet_exempt INTEGER NOT NULL DEFAULT 0');
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
