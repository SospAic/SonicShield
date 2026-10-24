import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/domain/models/task.dart';

/// `AppDatabase` 的**库迁移与辅助面**测试（第四十轮新建）。
///
/// ## 为什么必须补这一块
///
/// `AppDatabase._onUpgrade` 里几条 `ALTER TABLE` 是**用户升级才会走到的路径**：
/// - v1 → v2：补 `condition_json`（任务条件层，v1.3）
/// - v2 → v3：补 `quiet_exempt`（夜间独立豁免，v1.9，docs/20 §8）
/// - v4 → v5：补 `force_run`（全局执行总开关的强制例外，v79，docs/20 §9）
///
/// 此前**从没有任何测试造过一个旧版库去驱动它们** —— 所有用例都从
/// `inMemoryDatabasePath`（`:memory:`）起步，落进 `_onCreate` 直接建到 v3，
/// 于是"老用户升级后列到底补上没有 / 旧数据会不会丢"零验证。
///
/// 判据刻意不做"能开就行"：开得起来只说明没抛异常，不能说明列补对了。
/// 因此每个用例都查 `PRAGMA table_info` + 读回真实数据。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  /// 每个用例一个独立临时目录（真文件库才能触发 `onUpgrade`）。
  Directory newTmpDir() {
    final d = Directory.systemTemp.createTempSync('sonicshield_mig_');
    addTearDown(() async {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
      } on Object {
        // Windows 上句柄未释放时别把清理失败伪装成用例失败；
        // 残留的只是系统临时目录。
      }
    });
    return d;
  }

  /// v1 版 `tasks` 表：**没有** `condition_json`、**没有** `quiet_exempt`。
  const v1Tasks = '''
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
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''';

  /// 造一个"老版本"的库文件并写一行真实数据，然后**关掉**（模拟用户手上的旧库）。
  ///
  /// BUG-079 修复（第五十三轮）后 v2→v3 还会 ALTER occurrences —— 真实 v1 库
  /// （v1.0 起 onCreate 就有 occurrences）一定带着这张表，所以假库也必须造
  /// （v1 形状 = 无 quiet_exempt），否则 ALTER 会抛 no such table。
  Future<void> makeLegacyDb(String path, int version, {String? extraAlter}) async {
    final legacy = await openDatabase(
      path,
      version: version,
      onCreate: (db, v) async {
        await db.execute(v1Tasks);
        await db.execute('''
          CREATE TABLE occurrences (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            fire_at INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            volume REAL,
            duration_ms INTEGER
          )''');
        if (extraAlter != null) await db.execute(extraAlter);
        await db.insert('tasks', {
          'id': 'legacy-1',
          'name': '老任务',
          'enabled': 1,
          'trigger_type': 'dailyAt',
          'trigger_json': '{"kind":"dailyAt"}',
          'action_type': 'playAudio',
          'action_json': '{"kind":"playAudio"}',
          'created_at': 1,
          'updated_at': 1,
        });
      },
    );
    await legacy.close();
  }

  Future<Set<String>> taskColumns(AppDatabase db) async {
    final rows = await db.db.rawQuery('PRAGMA table_info(tasks)');
    return {for (final r in rows) r['name']! as String};
  }

  test('MIG-01 v1 老库 → v3：两条 ALTER 都补上，且默认值等价于"功能未启用"', () async {
    final dir = newTmpDir();
    final path = p.join(dir.path, 'sonic_shield.db');
    await makeLegacyDb(path, 1);
    expect(File(path).existsSync(), isTrue, reason: '前置：旧库文件必须在');

    final db = await AppDatabase.open(dir.path);
    addTearDown(db.close);

    final cols = await taskColumns(db);
    expect(cols, contains('condition_json'), reason: 'v1→v2 必须补条件层列');
    expect(cols, contains('quiet_exempt'), reason: 'v2→v3 必须补夜间豁免列');
    expect(cols, contains('force_run'), reason: 'v4→v5 必须补总开关强制例外列');

    final row = (await db.db.query('tasks')).single;
    expect(row['id'], 'legacy-1', reason: '升级不得丢数据');
    // R94 / DAT-01 裁决：老库回填统一为 **2 = 强制不豁免**。
    // 0（跟随主开关）会让升级后的老任务**静默获得**夜间响铃能力 ——
    // 那是"能力变多"的一侧，与 fail-closed 相悖。回填到最严的一侧，
    // 需要夜间响铃的任务由使用者显式改。
    expect(row['quiet_exempt'], 2,
        reason: '老库补列后必须回填 2（强制不豁免）—— 否则升级完就静默放宽了护栏');
    expect(row['force_run'], 0,
        reason: '老库补列后必须为 0（= 受总开关约束，更安全的一侧）');
    expect(row['condition_json'], isNull, reason: '老任务没有条件层，必须是 null');
  });

  test('MIG-02 v2 老库 → v3：只补 quiet_exempt，且不重跑 v1→v2（不得抛 duplicate column）',
      () async {
    final dir = newTmpDir();
    final path = p.join(dir.path, 'sonic_shield.db');
    // v2 = v1 + condition_json，并且**已经写过**条件层数据。
    await makeLegacyDb(path, 2,
        extraAlter: 'ALTER TABLE tasks ADD COLUMN condition_json TEXT');
    final seed = await openDatabase(path, version: 2);
    await seed.update('tasks', {'condition_json': '{"kind":"timeWindow"}'},
        where: 'id = ?', whereArgs: ['legacy-1']);
    await seed.close();

    final db = await AppDatabase.open(dir.path);
    addTearDown(db.close);

    expect(await taskColumns(db), contains('quiet_exempt'));
    expect(await taskColumns(db), contains('force_run'));
    final row = (await db.db.query('tasks')).single;
    expect(row['condition_json'], '{"kind":"timeWindow"}',
        reason: 'v2 已有数据必须原样保留 —— 重跑 v1→v2 会抛 duplicate column name');
    expect(row['quiet_exempt'], 2,
        reason: 'R94 / DAT-01：回填 2 = 强制不豁免（fail-closed 一侧）');
    expect(row['force_run'], 0);
  });

  test('MIG-06 BUG-079 v2 老库 → v3：occurrences.quiet_exempt 也必须补上（fail-safe 清除不得再抛 no such column）',
      () async {
    final dir = newTmpDir();
    final path = p.join(dir.path, 'sonic_shield.db');
    // 造 v2 库：tasks（v2 形状 = +condition_json）+ occurrences（v2 形状 = **无 quiet_exempt**）
    // —— 与 09-23 首装旧包在设备上留下的库完全同构（BUG-079 现场复刻）。
    final legacy = await openDatabase(
      path,
      version: 2,
      onCreate: (db, v) async {
        await db.execute(v1Tasks);
        await db.execute('ALTER TABLE tasks ADD COLUMN condition_json TEXT');
        await db.execute('''
          CREATE TABLE occurrences (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            fire_at INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            volume REAL,
            duration_ms INTEGER
          )''');
        await db.insert('tasks', {
          'id': 'legacy-1',
          'name': '老任务',
          'enabled': 1,
          'trigger_type': 'dailyAt',
          'trigger_json': '{"kind":"dailyAt"}',
          'action_type': 'playAudio',
          'action_json': '{"kind":"playAudio"}',
          'created_at': 1,
          'updated_at': 1,
        });
        await db.insert('occurrences', {
          'id': 'occ-pending',
          'task_id': 'legacy-1',
          'fire_at': 1,
          'status': 'pending',
        });
        await db.insert('occurrences', {
          'id': 'occ-done',
          'task_id': 'legacy-1',
          'fire_at': 2,
          'status': 'done',
        });
      },
    );
    await legacy.close();

    final db = await AppDatabase.open(dir.path);
    addTearDown(db.close);

    final occCols = {
      for (final r in await db.db.rawQuery('PRAGMA table_info(occurrences)'))
        r['name']! as String
    };
    expect(occCols, contains('quiet_exempt'),
        reason: 'BUG-079：v2→v3 迁移必须同时补 occurrences 表，'
            '否则旧库升级后关闭夜间豁免主开关的 fail-safe 清除必然抛 no such column');

    // 旧行保留 + 默认值等价于"未豁免"。
    final rows = await db.db.query('occurrences', orderBy: 'fire_at ASC');
    expect(rows, hasLength(2), reason: '升级不得丢已提交计划');
    for (final r in rows) {
      expect(r['quiet_exempt'], 0, reason: '老库补列后必须为 0（fail-safe）');
    }

    // 行为锁：升级后 OccurrenceRepository.deletePendingQuietExempt() 真实可调用
    // （修复前此处必抛 DatabaseException(no such column: quiet_exempt)），
    // 且只清除 pending+exempt 行 —— done 行与未豁免的 pending 行都不受影响。
    final repo = OccurrenceRepository(db);
    final deleted = await repo.deletePendingQuietExempt();
    expect(deleted, 0, reason: '补列默认 0 ⇒ 没有任何豁免行可清，但调用本身不得抛');
  });

  test('MIG-07 v3 老库（user_version=3 但 occurrences 缺 quiet_exempt）→ v4：按列存在性补齐',
      () async {
    final dir = newTmpDir();
    final path = p.join(dir.path, 'sonic_shield.db');
    // 复刻三机实机现场：v3 刚上线时 `_onUpgrade` 只补了 tasks.quiet_exempt，
    // occurrences 那条是 BUG-079（第五十三轮）才补的 —— 在那之前升到 v3 的库
    // 因此永久缺列，且 user_version 已是 3，`oldV < 3` 闸再也进不去。
    // v3→v4 修复的正是这一类："缺列但版本号已到位"的历史库。
    final legacy = await openDatabase(
      path,
      version: 3,
      onCreate: (db, v) async {
        await db.execute(v1Tasks);
        await db.execute('ALTER TABLE tasks ADD COLUMN condition_json TEXT');
        await db.execute(
            'ALTER TABLE tasks ADD COLUMN quiet_exempt INTEGER NOT NULL DEFAULT 0');
        await db.execute('''
          CREATE TABLE occurrences (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            fire_at INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            volume REAL,
            duration_ms INTEGER
          )''');
        await db.insert('tasks', {
          'id': 'legacy-1',
          'name': '老任务',
          'enabled': 1,
          'trigger_type': 'dailyAt',
          'trigger_json': '{"kind":"dailyAt"}',
          'action_type': 'playAudio',
          'action_json': '{"kind":"playAudio"}',
          'created_at': 1,
          'updated_at': 1,
        });
        await db.insert('occurrences', {
          'id': 'occ-pending',
          'task_id': 'legacy-1',
          'fire_at': 1,
          'status': 'pending',
        });
      },
    );
    await legacy.close();

    final db = await AppDatabase.open(dir.path);
    addTearDown(db.close);

    final occCols = {
      for (final r in await db.db.rawQuery('PRAGMA table_info(occurrences)'))
        r['name']! as String
    };
    expect(occCols, contains('quiet_exempt'),
        reason: 'v3 缺列库必须被 v4 迁移补齐 —— 否则远程建任务/重算每次抛'
            'no such column，任务物化整链失败（三机实机取证）');
    // tasks 列已存在 ⇒ 幂等补列必须空操作（不得抛 duplicate column name）。
    expect(await taskColumns(db), contains('quiet_exempt'));
    expect(await taskColumns(db), contains('force_run'));

    final rows = await db.db.query('occurrences');
    expect(rows, hasLength(1), reason: '升级不得丢已提交计划');
    expect(rows.single['quiet_exempt'], 0, reason: '补列默认 0 = 未豁免（fail-safe）');

    // 行为锁：升级后 commitAll 真实可写（修复前这里必抛 no such column）。
    final occ = OccurrenceRepository(db);
    await occ.commitAll([
      PlannedOccurrence(
          id: 'new-occ',
          taskId: 'legacy-1',
          fireAt: DateTime.fromMillisecondsSinceEpoch(999),
          status: OccurrenceStatus.pending,
          quietExempt: true),
    ]);
    final inserted = await db.db
        .query('occurrences', where: 'id = ?', whereArgs: ['new-occ']);
    expect(inserted.single['quiet_exempt'], 1,
        reason: '补列后带豁免标记的计划必须能落库并读回');
  });

  test('MIG-08 v4 老库（缺 tasks.force_run）→ v5：按列存在性补齐且默认 0（受约束）',
      () async {
    final dir = newTmpDir();
    final path = p.join(dir.path, 'sonic_shield.db');
    // v4 形状 = tasks 有 condition_json + quiet_exempt，occurrences 有 quiet_exempt；
    // **没有** force_run（v79 才引入）。v4 老库升级到 v5 必须补列且默认 0。
    final legacy = await openDatabase(
      path,
      version: 4,
      onCreate: (db, v) async {
        await db.execute(v1Tasks);
        await db.execute('ALTER TABLE tasks ADD COLUMN condition_json TEXT');
        await db.execute(
            'ALTER TABLE tasks ADD COLUMN quiet_exempt INTEGER NOT NULL DEFAULT 0');
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
        await db.insert('tasks', {
          'id': 'legacy-1',
          'name': '老任务',
          'enabled': 1,
          'trigger_type': 'dailyAt',
          'trigger_json': '{"kind":"dailyAt"}',
          'action_type': 'playAudio',
          'action_json': '{"kind":"playAudio"}',
          'created_at': 1,
          'updated_at': 1,
        });
      },
    );
    await legacy.close();

    final db = await AppDatabase.open(dir.path);
    addTearDown(db.close);

    expect(await taskColumns(db), contains('force_run'),
        reason: 'v4→v5 必须补 tasks.force_run —— 否则引擎执行链每次读该列都抛'
            'no such column，任务物化整链失败');
    final row = (await db.db.query('tasks')).single;
    expect(row['force_run'], 0,
        reason: '补列默认 0 = 受总开关约束（更安全的一侧），老任务不会被静默开例外');
  });

  test('MIG-03 通用 JSON 列辅助往返 + inject 单例注入生效', () async {
    expect(AppDatabase.decodeList(AppDatabase.encodeList(const ['a', 'b'])),
        ['a', 'b']);
    expect(AppDatabase.decodeList(AppDatabase.encodeList(const [])), isEmpty);
    expect(AppDatabase.encodeList(const []), '[]');

    final db = await AppDatabase.open(inMemoryDatabasePath);
    AppDatabase.inject(db);
    final again = await AppDatabase.open(inMemoryDatabasePath);
    expect(identical(again, db), isTrue,
        reason: 'inject 后 open 必须复用注入实例，否则测试隔离/后台引擎去重失效');
    await db.close();
  });

  test('MIG-05 不传目录时落到默认数据库目录（`:memory:` 之外的常规路径）', () async {
    final defaultPath =
        p.join(await databaseFactory.getDatabasesPath(), 'sonic_shield.db');
    final preexisting = File(defaultPath).existsSync();

    try {
      final db = await AppDatabase.open();
      expect(db.db.isOpen, isTrue);
      expect(await taskColumns(db), contains('quiet_exempt'),
          reason: '走默认目录也必须建到 v3 全量 schema');
      // 显式收口：句柄必须先释放，下面的删除才不会被 Windows 文件锁挡住。
      await db.close();
    } finally {
      if (!preexisting) {
        // 只清理**本用例自己造出来**的文件。
        try {
          final f = File(defaultPath);
          if (f.existsSync()) f.deleteSync();
        } on Object {
          // 清理失败不伪装成用例失败。
        }
      }
    }
  });
}
