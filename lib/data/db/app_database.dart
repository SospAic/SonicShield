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

  static const int dbVersion = 5;
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
      // 🔴 R89：**必须显式关掉 singleInstance**（sqflite 默认 true）。
      //
      // sqflite_android 的 `_singleInstancesByPath` 是**进程级静态表、只按
      // 路径键**（SqflitePlugin.java:59,349-373）：主 UI 引擎先打开本库后，
      // 后台引擎再打开同一路径会**直接收养主引擎那条原生连接**（连 readOnly
      // 标志都被忽略），于是两个引擎共用一条连接 —— 与上面 BUG-022 注释
      // 宣称的"两个引擎各自持有独立原生连接"**相反**。后果（R89 真机实证）：
      // ① `TaskRepository` / `OccurrenceRepository` 的 `transaction()` 在
      //    UI 与引擎两端交错 BEGIN/COMMIT ⇒ "cannot start a transaction
      //    within a transaction" 或事务被对端提前提交；
      // ② 任何一端（含一次只读 dump）`close()` ⇒ 对端立刻
      //    `DatabaseException(database_closed <id>)`：探针的只读 dump
      //    收养并关闭了引擎连接，引擎随后在 stop 清理链暴死、`stopSelf()`
      //    未执行 ⇒ 前台服务孤儿化 ⇒ 引擎永久无法二次启动。
      //
      // 关掉后每个引擎各持一条原生连接，跨连接并发由 WAL + busy_timeout
      // 承接（正是 BUG-022 引入这二者 PRAGMA 的原因）。`:memory:` 在插件
      // 侧本就强制单实例（isInMemoryPath），不受影响。
      singleInstance: false,
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

  /// 建表（仅新库）。
  ///
  /// 🔴 **R89：必须幂等（`IF NOT EXISTS`）。**
  ///
  /// 本进程内同时存在**两个 FlutterEngine**：主 UI 引擎与
  /// `flutter_background_service` 的后台引擎（BUG-022：两者各持一条独立
  /// 原生连接写同一个库文件）。sqflite 的 `onCreate` 判据**只有**
  /// `PRAGMA user_version == 0`，**不判表是否存在**。于是「两引擎并发
  /// 打开同一新库」时胜负手取决于 `user_version` 的提交时序：败者连接
  /// 可能在事务外已读到 0、进入独占事务后撞上胜者刚提交的 `CREATE TABLE`，
  /// 直接抛 `DatabaseException(table tasks already exists)`。
  ///
  /// R89 真机实证（API 36 模拟器，1.9.7+30 探针）：后台引擎在
  /// `m2-db-open` 前被该异常杀死 ⇒ 状态零回投、首页守护开关点不动且
  /// 全程无任何提示（用户报障「开关不动、零提示」的根因）。
  ///
  /// 加 `IF NOT EXISTS` 后重复进入 `onCreate` 变成空操作；sqflite 在
  /// 事务内还会**重读一次版本号**，正常路径下后入库者读到胜者写入的
  /// `dbVersion` 会直接跳过 `onCreate` —— 双保险。
  static Future<void> _onCreate(Database db, int v) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tasks (
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
        -- 三值编码（v79）：0=跟随主开关 / 1=强制豁免 / 2=强制不豁免。
        -- 注意 occurrences.quiet_exempt 仍是 bool（0/1），两列同名不同义。
        quiet_exempt INTEGER NOT NULL DEFAULT 0,
        force_run INTEGER NOT NULL DEFAULT 0,
        priority INTEGER NOT NULL DEFAULT 0,
        condition_json TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tasks_enabled ON tasks(enabled)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS audio_assets (
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
      CREATE TABLE IF NOT EXISTS occurrences (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        fire_at INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        volume REAL,
        duration_ms INTEGER,
        quiet_exempt INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_occ_fire ON occurrences(fire_at)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_occ_status ON occurrences(status)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS exec_logs (
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
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_logs_created ON exec_logs(created_at)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sound_profiles (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        threshold_db REAL NOT NULL DEFAULT -35,
        min_duration_ms INTEGER NOT NULL DEFAULT 800,
        cooldown_sec INTEGER NOT NULL DEFAULT 120,
        only_while_charging INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS kv (
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
    // v3 → v4：**修复"已升到 v3、却在 occurrences 上缺列"的历史库**（BUG-079 残留）。
    //
    // 任务级 `quiet_exempt` 为**三值**（v79）：0=跟随主开关 / 1=强制豁免 /
    // 2=强制不豁免；主开关 `quiet_exempt_master` 另存于 prefs，任务级可**双向覆盖**
    // （`exempt = taskExemptOverride ?? allowQuietExempt`）。老库补列后全部为 0
    // = 跟随主开关，行为与升级前一致（主开关默认 false ⇒ 不豁免）。
    // ⚠️ `occurrences.quiet_exempt` 仍是 bool（0/1），两列**同名不同义**。
    //
    // 为什么必须有 v4：v3 刚上线时 `_onUpgrade` **只补了 tasks.quiet_exempt**，
    // occurrences.quiet_exempt 是第五十三轮才补上的（BUG-079）。**在那之前升到 v3
    // 的库，`user_version` 已经是 3**，`oldV < 3` 这道闸再也进不去 ⇒ 列永远补不上
    // ⇒ 远程 `task.upsert` / 本地重算触发的 `commitAll`（`INSERT INTO occurrences`
    // 带 quiet_exempt）每次必抛 `no such column`，任务物化整链失败（三机实机取证）。
    //
    // 因此这里不再用版本闸做唯一判据，而是**按列存在性幂等补齐**（SQLite 的
    // `ALTER TABLE ADD COLUMN` 不支持 `IF NOT EXISTS`）：列已在则为空操作，
    // 对 v1/v2/v3 及全新库都安全。
    if (oldV < 4) {
      await _addIntColumnIfMissing(db, 'tasks', 'quiet_exempt');
      await _addIntColumnIfMissing(db, 'occurrences', 'quiet_exempt');
    }
    // v4 → v5：「全局执行总开关」的任务级强制例外（2026-10，v1.9，docs/20 §9）。
    //
    // 单向布尔 `force_run`，**默认 0 = 受总开关约束**（更安全的一侧）。老库补列后
    // 全部为 0，等价于"没有例外"，行为与升级前一致（总开关默认 auto，
    // 且 auto 在非暂停窗口内恒为"允许执行"）。仍按列存在性幂等补齐，
    // 对全新库/缺列库均安全。
    if (oldV < 5) {
      await _addIntColumnIfMissing(db, 'tasks', 'force_run');
    }
  }

  /// 幂等补一个 `INTEGER NOT NULL DEFAULT 0` 列：列已存在则原样返回、不抛。
  ///
  /// 存在性判据用 `PRAGMA table_info` —— 表不存在时它返回**空集而非抛异常**，
  /// 因此对全新库/缺表库同样安全。
  static Future<void> _addIntColumnIfMissing(
      Database db, String table, String column) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final names = {for (final r in cols) r['name']};
    if (names.contains(column)) return;
    await db.execute(
        'ALTER TABLE $table ADD COLUMN $column INTEGER NOT NULL DEFAULT 0');
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
