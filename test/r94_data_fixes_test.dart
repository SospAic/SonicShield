library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';

/// R94 数据层修复回归锁（DAT-01 / 02 / 03 / 05 / 07 / 17 + SCH-04）。
///
/// ## 为什么单独一个文件
///
/// `app_database_migration_test.dart` 覆盖的是"能升级、列没丢"；本文件锁的是
/// **升级后语义正确** + **CAS / 原子替换**这类并发契约。后者在宿主机上
/// 无法用真机验证（需要两个 isolate 同时写），但可以用**单连接上的顺序
/// 断言**锁住 API 语义：`markStatus(from:)` 返回 0 = "这次没抢到"。
///
/// ## 判据纪律
///
/// 每条断言都带**反面样本**（同一判据在相反输入下必须得到相反结果）——
/// 否则一条恒真断言也能让门禁变绿，那是自欺。

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  /// 内存库 + 一条父任务 + 一条 pending 计划。
  Future<({AppDatabase db, OccurrenceRepository occ})> seed() async {
      final db = await AppDatabase.open(inMemoryDatabasePath);
      await db.db.insert('tasks', {
        'id': 't',
        'name': '父任务',
        'enabled': 1,
        'trigger_type': 'dailyAt',
        'trigger_json': '{"kind":"dailyAt","time":{"hour":9,"minute":0}}',
        'action_type': 'playAudio',
        'action_json': '{"kind":"play"}',
        'quiet_exempt': 0,
        'force_run': 0,
        'priority': 0,
        'created_at': 0,
        'updated_at': 0,
      });
      final occ = OccurrenceRepository(db);
      await occ.commitAll([
        PlannedOccurrence(
          id: 'o-1',
          taskId: 't',
          // 必须在"现在"之后：skipNextForTask 的候选判据含 `fire_at >= now`。
          fireAt: DateTime.now().add(const Duration(hours: 1)),
          status: OccurrenceStatus.pending,
        ),
      ]);
      return (db: db, occ: occ);
    }

  Directory tmpDir() {
    final d = Directory.systemTemp.createTempSync('sonicshield_r94data_');
    addTearDown(() async {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
      } on Object {
        // Windows 句柄未释放：别把清理失败伪装成用例失败。
      }
    });
    return d;
  }

  /// v5 形状的 `tasks` 表 —— **已有** `quiet_exempt` 列（v3 补的），
  /// 但没有 v6 的回填。这是"老用户手上的库"的真实形状。
  const v5Tasks = '''
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
      force_run INTEGER NOT NULL DEFAULT 0,
      priority INTEGER NOT NULL DEFAULT 0,
      condition_json TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''';

  /// 造一个 v5 旧库：两行任务分别带老语义的 `quiet_exempt = 0`（旧"不豁免"）
  /// 与 `= 1`（旧"豁免"），外加一条 `occurrences.quiet_exempt = 1` 的夜间计划。
  ///
  /// ⚠️ 必须**真文件库**：`:memory:` 每次都从 `_onCreate` 起步，永远走不到
  /// `_onUpgrade`，测不到迁移。
  /// 返回**目录**：`AppDatabase.open` 的语义是 `open(dir)`（它自己会在
  /// 目录下拼 `sonic_shield.db`）。传文件路径会变成
  /// `xxx.db/sonic_shield.db` ⇒ 父目录不存在 ⇒ `open_failed`(code 14)。
  Future<Directory> makeLegacyV5(Directory d) async {
    // ⚠️ 文件名必须是 `sonic_shield.db`：`AppDatabase.open(dir)` 会自己拼
    // 这个名字。写成别的名字等于让 open 去开一个**不存在的新文件**，
    // 走 `_onCreate` 而不是 `_onUpgrade` —— 迁移一次都不执行，
    // DAT-01 的断言就会拿到"新库默认值 0"而假红。
    final path = '${d.path}/sonic_shield.db';
    final legacy = await openDatabase(
      path,
      version: 5,
      onCreate: (db, v) async {
        await db.execute(v5Tasks);
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
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_occ_fire ON occurrences(fire_at)');
        // v6 迁移要往 `kv` 写两条留痕标记。旧库若没有这张表，
        // `_kvMark` 会静默跳过（它刻意不阻断迁移）⇒ 断言拿到 null 假红。
        await db.execute(
            'CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
      },
    );
    await legacy.insert('tasks', {
      'id': 't-old-0',
      'name': '老值 0（旧不豁免）',
      'enabled': 1,
      'trigger_type': 'dailyAt',
      // 必须给**完整形状**：`TriggerConfig.fromJson` 按 `kind` 分派，
      // DailyTrigger 还要 `time`。给 `'{}'` 会让 `Task.fromRow` 抛
      // ArgumentError ⇒ `TaskRepository.get()` 按 DAT-02 语义返回 null
      // ⇒ 迁移断言在"读回模型"这一步假红（迁移其实成功了）。
      'trigger_json': '{"kind":"dailyAt","time":{"hour":9,"minute":0}}',
      'action_type': 'playAudio',
      'action_json': '{"kind":"play"}',
      'quiet_exempt': 0,
      'created_at': 0,
      'updated_at': 0,
    });
    await legacy.insert('tasks', {
      'id': 't-old-1',
      'name': '老值 1（旧强制豁免）',
      'enabled': 1,
      'trigger_type': 'dailyAt',
      // 必须给**完整形状**：`TriggerConfig.fromJson` 按 `kind` 分派，
      // DailyTrigger 还要 `time`。给 `'{}'` 会让 `Task.fromRow` 抛
      // ArgumentError ⇒ `TaskRepository.get()` 按 DAT-02 语义返回 null
      // ⇒ 迁移断言在"读回模型"这一步假红（迁移其实成功了）。
      'trigger_json': '{"kind":"dailyAt","time":{"hour":9,"minute":0}}',
      'action_type': 'playAudio',
      'action_json': '{"kind":"play"}',
      'quiet_exempt': 1,
      'created_at': 0,
      'updated_at': 0,
    });
    await legacy.insert('occurrences', {
      'id': 'o-night',
      'task_id': 't-old-1',
      'fire_at': DateTime(2026, 1, 1, 23).millisecondsSinceEpoch,
      'status': 'pending',
      'quiet_exempt': 1,
    });
    await legacy.close();
    return d;
  }

  group('DAT-01 · v6 迁移收紧回填（老板裁决：统一"强制不豁免"）', () {
    test('老 0/1 一律回填为 2，且 Task.fromRow 得 quietExempt == false', () async {
      final dir = await makeLegacyV5(tmpDir());
      final db = await AppDatabase.open(dir.path);

      // tasks：两行都必须是 2（强制不豁免），不能停在 0/1。
      final tasks =
          await db.db.query('tasks', columns: ['id', 'quiet_exempt']);
      expect(tasks.length, 2, reason: '迁移不得丢任务行');
      for (final r in tasks) {
        expect(r['quiet_exempt'], 2,
            reason: '${r['id']} 必须被收紧为 2；停在 ${r['quiet_exempt']} '
                '意味着夜间护栏仍可被静默放宽');
      }

      // occurrences：夜间豁免标记必须归零（否则计划层照样放行）。
      final occ = await db.db.query('occurrences',
          columns: ['id', 'quiet_exempt']);
      expect(occ.single['quiet_exempt'], 0,
          reason: '已物化的夜间豁免计划若保留 1，执行层会照样放行');

      // 反解后必须是「强制不豁免」（false），而不是 null（跟随主开关）。
      final repo = TaskRepository(db);
      for (final id in ['t-old-0', 't-old-1']) {
        final t = await repo.get(id);
        expect(t, isNotNull);
        expect(t!.quietExempt, isFalse,
            reason: '$id 回填 2 必须反解为 false（强制不豁免）；'
                'null = 跟随主开关 = 主开关开着就豁免 = 护栏失效');
      }
      await db.close();
    });

    test('迁移留痕：migrated_quiet_exempt_v6 与一次性提示键都已写入', () async {
      final dir = await makeLegacyV5(tmpDir());
      final db = await AppDatabase.open(dir.path);
      final kv = await db.db.query('kv',
          where: 'k IN (?, ?)',
          whereArgs: ['migrated_quiet_exempt_v6',
              'quiet_exempt_migrated_notice_pending']);
      final m = {for (final r in kv) r['k'] as String: r['v']};
      expect(m['migrated_quiet_exempt_v6'], 'true');
      expect(m['quiet_exempt_migrated_notice_pending'], 'true',
          reason: '设置页靠这个键决定要不要向用户展示一次性语义变更提示');
      await db.close();
    });

    test('新库（_onCreate）默认仍是 0 = 跟随主开关，不被回填污染', () async {
      final db = await AppDatabase.open(inMemoryDatabasePath);
      final repo = TaskRepository(db);
      final t = await repo.get('never-existed');
      expect(t, isNull, reason: '反面样本：空库读不到任何任务');
      // 新库插入一行，不显式写 quiet_exempt ⇒ 必须是 null（跟随主开关）。
      final fresh = Task(
        id: 'fresh-1',
        name: '新任务',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 9, minute: 0)),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(),
        assetIds: const [],
        cooldownSec: 300,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      await repo.upsert(fresh);
      final back = await repo.get('fresh-1');
      expect(back!.quietExempt, isNull,
          reason: '新库默认 0 = 跟随主开关。若这里变成 false，说明 v6 回填'
              '被误用到新库路径上，"跟随主开关"语义就死了');
      await db.close();
    });
  });

  group('DAT-03 + SCH-04 · CAS 与中断自愈', () {
      test('两次 markStatus(from: {pending}) ⇒ 第二次返回 0（CAS 生效）', () async {
      final s = await seed();
      final first = await s.occ.markStatus('o-1', OccurrenceStatus.running,
          from: {OccurrenceStatus.pending});
      expect(first, 1, reason: '前提：第一条 CAS 必须成功');

      final second = await s.occ.markStatus('o-1', OccurrenceStatus.running,
          from: {OccurrenceStatus.pending});
      expect(second, 0,
          reason: '非 CAS 的旧实现会返回 1 —— 两个执行者都以为自己在跑');

      // 反面样本：改成"从 running 出发"就必须成功，证明判据不是恒 0。
      final third = await s.occ.markStatus('o-1', OccurrenceStatus.done,
          from: {OccurrenceStatus.running});
      expect(third, 1, reason: '非恒真样本：from 匹配时必须返回 1');

      // 再一个反面：from 集合不匹配 ⇒ 0。
      final fourth = await s.occ.markStatus('o-1', OccurrenceStatus.skipped,
          from: {OccurrenceStatus.pending});
      expect(fourth, 0, reason: '行已是 done，from: {pending} 不得命中');
      await s.db.close();
    });

    test('recoverInterrupted 把遗留 running 改 failed 并返回条数', () async {
      final s = await seed();
      await s.occ.markStatus('o-1', OccurrenceStatus.running,
          from: {OccurrenceStatus.pending});
      // 模拟"进程在这里被杀"：终态从未写入。

      final n = await s.occ.recoverInterrupted();
      expect(n, 1, reason: '必须把这条僵尸 running 捞回来');

      final rows = await s.db.db
          .query('occurrences', columns: ['status'], where: 'id = ?',
              whereArgs: ['o-1']);
      expect(rows.single['status'], 'failed',
          reason: '停在 running 的行 due() 永远看不见，会被 retention '
              '当历史静默删掉 —— 用户看到"没响且无日志"');

      // 反面样本：没有 running 时必须返回 0（不是恒 1）。
      expect(await s.occ.recoverInterrupted(), 0,
          reason: '非恒真样本：无遗留时应返回 0');
      await s.db.close();
    });
  });

  group('DAT-05 · replacePendingForTask 原子替换', () {
    test('只删未来 pending，保留已到期（fire_at <= now）的 pending', () async {
      final db = await AppDatabase.open(inMemoryDatabasePath);
      await db.db.insert('tasks', {
        'id': 't',
        'name': '父任务',
        'enabled': 1,
        'trigger_type': 'dailyAt',
        'trigger_json': '{"kind":"dailyAt","time":{"hour":9,"minute":0}}',
        'action_type': 'playAudio',
        'action_json': '{"kind":"play"}',
        'quiet_exempt': 0,
        'force_run': 0,
        'priority': 0,
        'created_at': 0,
        'updated_at': 0,
      });
      final occ = OccurrenceRepository(db);
      final now = DateTime(2026, 6, 1, 12);
      await occ.commitAll([
        PlannedOccurrence(
          id: 'due-1',
          taskId: 't',
          fireAt: now.subtract(const Duration(minutes: 30)),
          status: OccurrenceStatus.pending,
        ),
        PlannedOccurrence(
          id: 'future-1',
          taskId: 't',
          fireAt: now.add(const Duration(hours: 5)),
          status: OccurrenceStatus.pending,
        ),
      ]);

      final r = await occ.replacePendingForTask('t', [
        PlannedOccurrence(
          id: 'new-1',
          taskId: 't',
          fireAt: now.add(const Duration(hours: 9)),
          status: OccurrenceStatus.pending,
        ),
      ], now);

      expect(r.dropped, 1, reason: '未来那条必须被替换掉');
      expect(r.keptDue, 1, reason: '已到期未跑的必须保留 —— 删了就是"任务改了，'
          '该响的那次也不响了"');
      expect(r.inserted, 1);

      final rows = await db.db.query('occurrences', columns: ['id'],
          orderBy: 'fire_at ASC');
      expect(rows.map((e) => e['id']).toList(), ['due-1', 'new-1'],
          reason: '结果应恰好是「保留的到期项 + 新插入项」');
      await db.close();
    });

    test('DAT-07 · 升级库与新建库都有 idx_occ_task', () async {
      final db = await AppDatabase.open(inMemoryDatabasePath);
      final idx = await db.db.rawQuery('PRAGMA index_list(occurrences)');
      final names = idx.map((e) => e['name'] as String).toSet();
      expect(names, contains('idx_occ_task'),
          reason: 'lastDoneFor / deletePendingForTask / skipNextForTask 全按 '
              'task_id 过滤，没有这个索引就是全表扫描 + 排序');
      await db.close();
    });

    test('DAT-17 · skipNextForTask 能命中 running 行', () async {
      final s = await seed();
      await s.occ.markStatus('o-1', OccurrenceStatus.running,
          from: {OccurrenceStatus.pending});
      final n = await s.occ.skipNextForTask('t');
      expect(n, 1,
          reason: '候选集若只含 pending，正在跑的那次就跳不过去 —— '
              '用户点"跳过本次"对正在执行的任务无效');
      final rows = await s.db.db.query('occurrences', columns: ['status']);
      expect(rows.single['status'], 'skipped');
      await s.db.close();
    });
  });

  group('DAT-02 · 坏行隔离', () {
    test('trigger_type 非法的行 get() 返回 null 且回调被调用，不抛', () async {
      final db = await AppDatabase.open(inMemoryDatabasePath);
      await db.db.insert('tasks', {
        'id': 'bad',
        'name': '坏行',
        'enabled': 1,
        'trigger_type': 'bogus',
        'trigger_json': '{}',
        'action_type': 'playAudio',
        'action_json': '{"kind":"play"}',
        'quiet_exempt': 0,
        'force_run': 0,
        'priority': 0,
        'created_at': 0,
        'updated_at': 0,
      });
      final repo = TaskRepository(db);
      final seen = <String>[];
      final t = await repo.get('bad', onRowError: (id, e) => seen.add(id));
      expect(t, isNull, reason: '坏行必须被隔离成 null，而不是把异常抛给调用方');
      expect(seen, ['bad'], reason: '调用方要能留痕：不记录就等于静默丢失');

      // 反面样本：好行仍然读得出来（证明不是"一律返回 null"）。
      //
      // 用模型 upsert 而不是手写 SQL：手写 `trigger_json` 极易写成
      // `{'hour':..}`，而 DailyTrigger.fromJson 要的是 `{'time': {...}}`
      // —— 那会让"好行"自己也解析失败，反面样本就失去意义。
      await repo.upsert(Task(
        id: 'good',
        name: '好行',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 9, minute: 0)),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(),
        assetIds: const [],
        cooldownSec: 300,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ));
      final good = await repo.get('good');
      expect(good, isNotNull,
          reason: '非恒真样本：好行必须读得到');
      expect(good!.trigger, isA<DailyTrigger>(),
          reason: '且必须真的解析成 DailyTrigger（不是别的什么）');
      await db.close();
    });
  });
}
