import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';

/// R96 覆盖率补齐：`TaskRepository` 与 `AppDatabase` 的数据层边角。
///
/// 命中 lcov 里两文件长期为 0 的分支：
/// - `TaskRepository`：listAll 行级兜底（坏行跳过 + onRowError）、inTransaction
///   事务句柄、deleteMany（空集合 / 过滤空串 / 分块删除）、replaceCounterTasks
///   的差异删除循环、AssetRepository.insertMissingByName 的三类计数。
/// - `AppDatabase`：open 的非锁错误立即重抛（`_isLockedError` 全量求值）、
///   `_assertSchemaIntegrity` 的按列存在性补列（INT/TEXT 两类分支）。
///
/// 全部走 FFI 内存库 / 临时文件库，不依赖墙钟、随机、网络或真实设备。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  /// 固定时间构造一条合法任务（避免墙钟依赖）。
  Task makeTask(String id, {bool enabled = true}) {
    final now = DateTime(2026, 10, 25, 12);
    return Task(
      id: id,
      name: '任务$id',
      enabled: enabled,
      triggerType: TriggerType.dailyAt,
      trigger: const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)),
      actionType: ActionType.playAudio,
      action: const PlayAudioAction(volumeMin: 0.3, volumeMax: 0.7),
      assetIds: const ['a1', 'a2'],
      cooldownSec: 300,
      quietPolicy: QuietPolicy.shift,
      priority: 2,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 每个用例一个独立临时目录（真文件库才能触发 onUpgrade / schema 校验）。
  Directory newTmpDir() {
    final d = Directory.systemTemp.createTempSync('sonicshield_r96_');
    addTearDown(() async {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
      } on Object {
        // Windows 上句柄未释放时别把清理失败伪装成用例失败。
      }
    });
    return d;
  }

  group('COV TaskRepository 数据层边角', () {
    late AppDatabase appDb;

    setUp(() async {
      appDb = await AppDatabase.open(inMemoryDatabasePath);
    });

    tearDown(() async {
      await appDb.close();
    });

    test('COV-01 listAll 行级兜底：坏行跳过 + onRowError 回调，不拖垮整表', () async {
      final repo = TaskRepository(appDb);
      await repo.upsert(makeTask('good-1'));
      await repo.upsert(makeTask('bad-1'));
      // 破坏 bad-1 的 trigger_json：合法 JSON 但未知 kind → Task.fromRow 抛。
      await appDb.db.update(
        'tasks',
        {'trigger_json': '{"kind":"___unknown___"}'},
        where: 'id = ?',
        whereArgs: ['bad-1'],
      );
      final errors = <String>[];
      final list = await repo.listAll(onRowError: (id, e) => errors.add(id));
      expect(list.map((t) => t.id), ['good-1'],
          reason: '坏行必须被跳过，好行照常返回');
      expect(errors, ['bad-1'], reason: '坏行 id 必须经 onRowError 回调留痕');
    });

    test('COV-02 inTransaction 暴露共享事务句柄，body 内写入可见', () async {
      final repo = TaskRepository(appDb);
      final n = await repo.inTransaction((txn) async {
        await txn.insert('tasks', makeTask('tx-1').toRow());
        final rows = await txn.query('tasks');
        return rows.length;
      });
      expect(n, 1);
      expect((await repo.get('tx-1')), isNotNull,
          reason: '事务提交后数据必须可读');
    });

    test('COV-03 deleteMany：空集合返回 0；过滤空串；批量删除返回条数', () async {
      final repo = TaskRepository(appDb);
      expect(await repo.deleteMany(const []), 0,
          reason: '空集合不得产生任何数据库操作');
      await repo.upsert(makeTask('t1'));
      await repo.upsert(makeTask('t2'));
      await repo.upsert(makeTask('t3'));
      // 混入空串：被 where isNotEmpty 过滤，只删 t1/t2。
      final n = await repo.deleteMany(const ['', 't1', 't2']);
      expect(n, 2);
      expect(await repo.get('t1'), isNull);
      expect(await repo.get('t2'), isNull);
      expect(await repo.get('t3'), isNotNull);
    });

    test('COV-04 replaceCounterTasks 差异删除：移除不在新集合的旧 id', () async {
      final repo = TaskRepository(appDb);
      await repo.upsert(makeTask('counter:local:20260310D00'));
      await repo.upsert(makeTask('counter:local:20260311D00'));
      final r = await repo.replaceCounterTasks('local', [
        makeTask('counter:local:20260312D00'),
      ]);
      expect(r.upserted, 1);
      expect(r.removed, 2, reason: '旧有、新集合里没有的两条必须被删');
      expect(await repo.counterTaskIds('local'), ['counter:local:20260312D00']);
    });

    test('COV-05 insertMissingByName：空集合 0/0；新插/已存/批内重名分类计数', () async {
      final assetRepo = AssetRepository(appDb);
      expect(await assetRepo.insertMissingByName(const []),
          (inserted: 0, skipped: 0),
          reason: '空集合直接返回，不产生任何数据库操作');
      // 预置一个已存在名 B。
      await assetRepo.upsert(AudioAsset(
          id: 'seed-b', name: 'B', path: '/b', createdAt: DateTime(2026)));
      final r = await assetRepo.insertMissingByName([
        AudioAsset(id: 'x1', name: 'A', path: '/a1', createdAt: DateTime(2026)),
        AudioAsset(
            id: 'x2', name: 'B', path: '/b2', createdAt: DateTime(2026)), // 已存 → skip
        AudioAsset(
            id: 'x3', name: 'A', path: '/a3', createdAt: DateTime(2026)), // 批内重名 → skip
        AudioAsset(id: 'x4', name: 'C', path: '/c', createdAt: DateTime(2026)), // 新 → insert
      ]);
      expect(r.inserted, 2, reason: 'A、C 为新名，应插入');
      expect(r.skipped, 2, reason: 'B 已存、第二个 A 批内重名，应跳过');
      final names = (await assetRepo.listAll()).map((a) => a.name).toSet();
      expect(names, containsAll(['A', 'B', 'C']));
    });
  });

  test('COV-06 打开损坏文件：非锁错误 DatabaseException 立即重抛（不进重试）', () async {
    final dir = newTmpDir();
    final path = p.join(dir.path, 'sonic_shield.db');
    // 写入非 SQLite 内容（首 16 字节非 "SQLite format 3" 魔数）。
    File(path).writeAsBytesSync(List<int>.filled(4096, 0x42));
    await expectLater(
      AppDatabase.open(dir.path),
      throwsA(isA<DatabaseException>()),
      reason: '损坏文件必须抛 DatabaseException 并被 isLockedError 判为非锁 → 立即重抛',
    );
  });

  test('COV-07 schema 完整性校验：缺列库按列存在性补齐（INT/TEXT 两类补列分支）', () async {
    final dir = newTmpDir();
    final path = p.join(dir.path, 'sonic_shield.db');
    // 造 user_version=6 但若干表缺列的库：version 已到位 ⇒ onCreate/onUpgrade 都不跑，
    // 只能靠开库后的 _assertSchemaIntegrity 自愈。
    final legacy = await openDatabase(
      path,
      version: AppDatabase.dbVersion,
      singleInstance: false,
      onCreate: (db, v) async {
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
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )''');
        // occurrences 缺 volume / duration_ms（TEXT 补列分支）。
        await db.execute('''
          CREATE TABLE occurrences (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            fire_at INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            quiet_exempt INTEGER NOT NULL DEFAULT 0
          )''');
        // exec_logs 缺 occurrence_id（命中 else-if 最后一个操作数的分支）。
        await db.execute('''
          CREATE TABLE exec_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT,
            source TEXT NOT NULL,
            action TEXT NOT NULL,
            status TEXT NOT NULL,
            volume REAL,
            duration_ms INTEGER,
            message TEXT,
            created_at INTEGER NOT NULL
          )''');
      },
    );
    await legacy.close();

    final db = await AppDatabase.open(dir.path);
    addTearDown(db.close);

    Future<Set<String>> cols(String t) async => {
          for (final r in await db.db.rawQuery('PRAGMA table_info($t)'))
            r['name']! as String
        };
    final taskCols = await cols('tasks');
    expect(taskCols, contains('force_run'), reason: '缺列库必须补 force_run');
    expect(taskCols, contains('condition_json'),
        reason: '缺列库必须补 condition_json');
    final occCols = await cols('occurrences');
    expect(occCols, contains('volume'));
    expect(occCols, contains('duration_ms'));
    final logCols = await cols('exec_logs');
    expect(logCols, contains('occurrence_id'));

    // 行为锁：补列后库必须真实可用（能写能读）。
    final repo = TaskRepository(db);
    await repo.upsert(makeTask('after-fix'));
    expect((await repo.get('after-fix')), isNotNull);
  });
}
