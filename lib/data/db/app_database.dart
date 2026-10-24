import 'dart:convert';
import 'dart:developer' as developer;

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

  /// v6（R94）：`quiet_exempt` 语义迁移回填 + `occurrences(task_id, fire_at)` 索引。
  ///
  /// 版本史：v1 基础表 → v2 条件层 → v3/v4 夜间豁免列 → v5 总开关例外
  /// → **v6 免打扰护栏收紧（DAT-01）+ 按任务查询索引（DAT-07）**。
  static const int dbVersion = 6;

  static AppDatabase? _instance;

  /// 打开数据库（**有界重试**，DAT-08）。
  ///
  /// ## 为什么需要重试
  /// 两个 FlutterEngine（主 UI + `flutter_background_service`）各持一条原生连接
  /// 写同一个库文件（见下方 `singleInstance: false` 的论证）。`busy_timeout=5000`
  /// 只在**单条语句/事务**内等待锁；但 `openDatabase` 自身还要跑 `onConfigure`
  /// 的 PRAGMA（`journal_mode=WAL` 需要写锁）与 `onUpgrade` 迁移事务 ——
  /// 对端恰好在大删除（`purgeOlderThan`）或 `reconcile` 长事务里时，
  /// 开库这一步就会抛 `database is locked`。
  ///
  /// 而 `databaseProvider` 是 `FutureProvider`，**不会自动重试**：一次锁冲突
  /// 会把错误缓存下来，整页数据为空、且看起来像"库坏了"。这里退避重试 3 次
  /// （每次 500ms，总计 ≤1s，不会拖到 ANR），且**只**重试锁冲突
  /// （`database is locked` / `SQLITE_BUSY`）—— 迁移语法错误、文件损坏等
  /// 确定性失败必须立刻暴露，重试只会让用户多等。
  static Future<AppDatabase> open([String? dirOverride]) async {
    if (_instance != null) return _instance!;
    // 特殊路径（如测试用 ':memory:'）直接作为数据库文件名，不做目录拼接。
    final String path;
    if (dirOverride != null && dirOverride.startsWith(':')) {
      path = dirOverride;
    } else {
      path = p.join(dirOverride ?? await _defaultDir(), 'sonic_shield.db');
    }
    const attempts = 3;
    const backoff = Duration(milliseconds: 500);
    for (var i = 0; i < attempts; i++) {
      try {
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
        final opened = AppDatabase._(db);
        // DAT-14：版本号到位 ≠ schema 齐全（外部工具删表 / 半恢复的备份）。
        // 校验失败不阻断开库（只记录 + 尽力补），否则一次坏库会让应用永远打不开。
        await opened._assertSchemaIntegrity();
        _instance = opened;
        return opened;
      } on DatabaseException catch (e) {
        if (i == attempts - 1 || !_isLockedError(e)) rethrow;
        await Future<void>.delayed(backoff);
      }
    }
    // 不可达：循环内要么 return 要么 rethrow。
    throw StateError('unreachable');
  }

  /// 是否为"锁冲突"这类**可重试**错误。
  ///
  /// sqflite 没有跨平台的错误码常量（Android 抛 `SQLITE_BUSY`，FFI 抛
  /// `database is locked`），只能按文案判定 —— 因此刻意写得宽松但**只认锁**。
  static bool _isLockedError(DatabaseException e) {
    final m = e.toString().toLowerCase();
    return m.contains('database is locked') ||
        m.contains('database_locked') ||
        m.contains('sqlite_busy') ||
        m.contains('database is busy');
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
        --
        -- 新库默认仍是 0：新库**不存在**"老语义遗留行"，而 0 在新语义下就是
        -- "跟随主开关"（主开关默认 false ⇒ 不豁免），已是安全侧。
        -- v6 的回填（见 _onUpgrade）只针对**升级库的历史行**，把语义漂移的
        -- 老值统一收紧为 2；两者刻意不同，别把这里改成 2 —— 那会让新装用户
        -- 的"跟随主开关"彻底失效（docs/20 §8 的核心语义）。
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
    // DAT-07（v6）：按任务取计划/取最近一次成功执行的索引。
    //
    // 旧库只有 `fire_at` / `status` 两个单列索引，而 `lastDoneFor`
    // （`task_id=? AND status='done' ORDER BY fire_at DESC LIMIT 1`）、
    // `deleteForTask`、`deletePendingForTask`、`skipNextForTask` 全部按
    // `task_id` 过滤 ⇒ 每次都是**全表扫描 + 排序**。声音事件路径
    // （`onSoundEvent` 对每个声音任务各调一次 `lastDoneFor`）因此是
    // O(任务数 × 计划行数)，守卫常开 + 反击计划数千行时会把 15s tick 拖爆。
    //
    // 列序取 `(task_id, fire_at)`：task_id 等值前缀命中，fire_at 承接排序，
    // 两者都不需要在内存里再建临时 B 树。
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_occ_task ON occurrences(task_id, fire_at)');
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
    //
    // DAT-14：旧实现是裸 `ALTER TABLE ... ADD COLUMN`。若该库**已有**该列
    // （异常写入 / 手工改库 / 跨版本恢复的备份），这里会抛
    // `duplicate column name` ⇒ 迁移事务整体回滚 ⇒ **每次启动都失败**，
    // 应用永远进不去（`onCreate` 只在 `user_version==0` 时跑，救不了它）。
    // 改成按列存在性幂等补齐（与 v4/v5 的做法统一）。
    if (oldV < 2) {
      await _addColumnIfMissing(db, 'tasks', 'condition_json', 'TEXT');
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
    // v5 → v6：**免打扰护栏收紧**（DAT-01 / RCA-6，老板裁决"收紧方向"）。
    //
    // ## 为什么必须回填，而不是"补列即完事"
    // v3 时代 `quiet_exempt` 是**布尔开关**，判据 `master && task`（两者皆开才
    // 豁免）；v79 改成**三态覆盖**，判据变成 `task ?? master`。v3→v4 的迁移
    // 只补了列、没回填，于是老值在新语义下**单向放宽**：
    //   老 0（旧"不豁免"）→ 新 `null`（跟随主开关）→ 主开关开着就变成"豁免"；
    //   老 1（旧"豁免"）  → 新 `true`（强制豁免）  → 主开关关着也豁免。
    // 两条路径都让 22:00–07:00 的护栏静默失效（合规红线），且用户无法从 UI
    // 看出"这是升级带来的"。
    //
    // ## 裁决：统一收紧为 2（强制不豁免）
    // 宁可少响一次，也不能让未经授权的夜间出声继续发生（与 S2「重启绝不续发」
    // 同一哲学）。代价：v5 用户在 v79 里**显式**设过"强制豁免"的任务也会被
    // 收紧 —— 这是已知且被接受的回归方向，用户可在任务编辑页重新显式开启
    // （届时写的是 1，不再经过迁移）。
    //
    // `occurrences.quiet_exempt` 仍是 bool（0/1），回填 0 = 不豁免：
    // 已物化的夜间豁免计划若继续保留 `1`，执行层会照样放行（`executeDue`
    // 只看行上的标记），等于护栏在"计划层面"仍被绕过。
    if (oldV < 6) {
      await db.update('tasks', {'quiet_exempt': 2});
      await db.update('occurrences', {'quiet_exempt': 0});
      // DAT-07：老库补索引（`_onCreate` 只在新库跑，升级库必须在这里补）。
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_occ_task ON occurrences(task_id, fire_at)');
      // 迁移留痕（幂等标记 + 一次性的 UI 告知标记）。
      //
      // ⚠️ 键名是与 F6（`lib/core/app_keys.dart`）约定的**字面量**：
      //   - `migrated_quiet_exempt_v6`：迁移已执行（避免将来重复回填）；
      //   - `quiet_exempt_migrated_notice_pending`：需要向用户提示一次
      //     "夜间豁免语义已收紧"，由设置页读取后清除。
      await _kvMark(db, 'migrated_quiet_exempt_v6', 'true');
      await _kvMark(db, 'quiet_exempt_migrated_notice_pending', 'true');
    }
  }

  /// 迁移期写一条 kv 标记。kv 表可能尚未建（极端残缺库）—— 标记不是关键路径，
  /// 写不进去**不得**阻断迁移（否则整库打不开，比丢一条提示严重得多）。
  static Future<void> _kvMark(Database db, String k, String v) async {
    try {
      await db.insert('kv', {'k': k, 'v': v},
          conflictAlgorithm: ConflictAlgorithm.replace);
    } on DatabaseException catch (e) {
      developer.log('kv 标记写入失败（$k）：$e', name: 'AppDatabase');
    }
  }

  /// 幂等补一个列：列已存在则原样返回、不抛（DAT-14）。
  ///
  /// 存在性判据用 `PRAGMA table_info` —— 表不存在时它返回**空集而非抛异常**。
  static Future<void> _addColumnIfMissing(
      Database db, String table, String column, String decl) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final names = {for (final r in cols) r['name']};
    if (names.contains(column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $decl');
  }

  /// 幂等补一个 `INTEGER NOT NULL DEFAULT 0` 列：列已存在则原样返回、不抛。
  static Future<void> _addIntColumnIfMissing(
      Database db, String table, String column) =>
      _addColumnIfMissing(db, table, column, 'INTEGER NOT NULL DEFAULT 0');

  /// schema 必需列清单（DAT-14 的校验基线）。
  ///
  /// 只列**代码会直接读**的列：少一列就是 `no such column`，整条业务链
  /// （物化/执行/审计）每轮必抛。`condition_json` 允许为 NULL 但列必须存在。
  static const Map<String, List<String>> _requiredColumns = {
    'tasks': [
      'id', 'name', 'enabled', 'trigger_type', 'trigger_json', 'action_type',
      'action_json', 'asset_ids', 'cooldown_sec', 'quiet_policy', 'quiet_exempt',
      'force_run', 'priority', 'condition_json', 'created_at', 'updated_at',
    ],
    'occurrences': [
      'id', 'task_id', 'fire_at', 'status', 'volume', 'duration_ms',
      'quiet_exempt',
    ],
    'audio_assets': [
      'id', 'name', 'path', 'duration_ms', 'size_bytes', 'tags', 'weight',
      'created_at',
    ],
    'exec_logs': [
      'id', 'task_id', 'occurrence_id', 'source', 'action', 'status', 'volume',
      'duration_ms', 'message', 'created_at',
    ],
    'sound_profiles': [
      'id', 'name', 'threshold_db', 'min_duration_ms', 'cooldown_sec',
      'only_while_charging', 'enabled',
    ],
    'kv': ['k', 'v'],
  };

  /// 开库后校验 schema 完整性（DAT-14）。
  ///
  /// ## 为什么需要
  /// `onCreate` 只在 `user_version==0` 跑、`onUpgrade` 只在版本前进时跑。
  /// 于是"**版本号已是 6、但某张表/列被删掉**"（外部工具清理、半恢复的备份、
  /// root 设备）没有任何自愈路径：所有仓储直接 `no such table`，引擎每轮
  /// `stepGuarded` 失败，用户只看到"全都不响"。
  ///
  /// 这里用 `PRAGMA table_info` 做**只读**校验（6 次 schema 查询，微秒级），
  /// 只有发现缺失才进入补建分支（`_onCreate` 全 `IF NOT EXISTS`，可安全重入）。
  /// 任何失败都**不抛**：打不开库比缺一张表更糟。
  Future<void> _assertSchemaIntegrity() async {
    try {
      final missing = <String>[];
      for (final e in _requiredColumns.entries) {
        final cols = await db.rawQuery('PRAGMA table_info(${e.key})');
        final have = {for (final r in cols) r['name']};
        if (have.isEmpty) {
          missing.add('表 ${e.key}');
          continue;
        }
        for (final c in e.value) {
          if (!have.contains(c)) missing.add('${e.key}.$c');
        }
      }
      if (missing.isEmpty) return;
      developer.log('schema 缺失：${missing.join('、')}，尝试补建',
          name: 'AppDatabase');
      // 先补表/索引（幂等），再补列（ALTER 不能补表）。
      await _onCreate(db, dbVersion);
      for (final e in _requiredColumns.entries) {
        final cols = await db.rawQuery('PRAGMA table_info(${e.key})');
        final have = {for (final r in cols) r['name']};
        if (have.isEmpty) continue;
        for (final c in e.value) {
          if (have.contains(c)) continue;
          // 只有这两列有"补列即正确"的确定默认值；其余列补成 NULL/TEXT 只是
          // 为了让查询不抛，真实数据仍缺失 —— 由上面的日志留痕供排障。
          if (c == 'quiet_exempt' || c == 'force_run') {
            await _addIntColumnIfMissing(db, e.key, c);
          } else if (c == 'condition_json' || c == 'volume' ||
              c == 'duration_ms' || c == 'message' || c == 'task_id' ||
              c == 'occurrence_id') {
            await _addColumnIfMissing(db, e.key, c, 'TEXT');
          }
        }
      }
      try {
        await db.insert('exec_logs', {
          'source': 'db',
          'action': 'schemaIntegrity',
          'status': 'failed',
          'message': 'schema 缺失已尝试补建：${missing.join('、')}',
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      } on DatabaseException {
        // exec_logs 本身不可用：只留 developer.log。
      }
    } on Object catch (e) {
      developer.log('schema 完整性校验失败（不阻断开库）：$e', name: 'AppDatabase');
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
