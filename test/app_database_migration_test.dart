import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';

/// `AppDatabase` 的**库迁移与辅助面**测试（第四十轮新建）。
///
/// ## 为什么必须补这一块
///
/// `AppDatabase._onUpgrade` 里两条 `ALTER TABLE` 是**用户升级才会走到的路径**：
/// - v1 → v2：补 `condition_json`（任务条件层，v1.3）
/// - v2 → v3：补 `quiet_exempt`（夜间独立豁免，v1.9，docs/20 §8）
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
  Future<void> makeLegacyDb(String path, int version, {String? extraAlter}) async {
    final legacy = await openDatabase(
      path,
      version: version,
      onCreate: (db, v) async {
        await db.execute(v1Tasks);
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

    final row = (await db.db.query('tasks')).single;
    expect(row['id'], 'legacy-1', reason: '升级不得丢数据');
    expect(row['quiet_exempt'], 0,
        reason: '老库补列后必须为 0（= 未豁免）—— 否则升级完就静默豁免了免打扰');
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
    final row = (await db.db.query('tasks')).single;
    expect(row['condition_json'], '{"kind":"timeWindow"}',
        reason: 'v2 已有数据必须原样保留 —— 重跑 v1→v2 会抛 duplicate column name');
    expect(row['quiet_exempt'], 0);
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
