import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';

/// 数据层测试：以 FFI 内存 SQLite 运行（TDD：测试先于实现完善）。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase appDb;

  setUp(() async {
    appDb = await AppDatabase.open(inMemoryDatabasePath);
  });

  tearDown(() async {
    await appDb.close();
  });

  Task makeTask(String id, {bool enabled = true, int cooldown = 300}) {
    final now = DateTime.now();
    return Task(
      id: id,
      name: '任务$id',
      enabled: enabled,
      triggerType: TriggerType.dailyAt,
      trigger: const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)),
      actionType: ActionType.playAudio,
      action: const PlayAudioAction(volumeMin: 0.3, volumeMax: 0.7),
      assetIds: const ['a1', 'a2'],
      cooldownSec: cooldown,
      quietPolicy: QuietPolicy.shift,
      priority: 2,
      createdAt: now,
      updatedAt: now,
    );
  }

  group('TaskRepository', () {
    test('upsert + get 往返保留全部字段（含 JSON 配置）', () async {
      final repo = TaskRepository(appDb);
      await repo.upsert(makeTask('t1'));
      final got = await repo.get('t1');
      expect(got, isNotNull);
      expect(got!.name, '任务t1');
      expect(got.enabled, isTrue);
      expect(got.trigger, isA<DailyTrigger>());
      final daily = got.trigger as DailyTrigger;
      expect(daily.time.hour, 10);
      expect(got.action, isA<PlayAudioAction>());
      final play = got.action as PlayAudioAction;
      expect(play.volumeMin, 0.3);
      expect(play.volumeMax, 0.7);
      expect(got.assetIds, ['a1', 'a2']);
      expect(got.quietPolicy, QuietPolicy.shift);
      expect(got.priority, 2);
    });

    test('setEnabled 更新且不影响其它任务', () async {
      final repo = TaskRepository(appDb);
      await repo.upsert(makeTask('t1'));
      await repo.upsert(makeTask('t2'));
      await repo.setEnabled('t1', false);
      expect((await repo.get('t1'))!.enabled, isFalse);
      expect((await repo.get('t2'))!.enabled, isTrue);
    });

    test('listAll(enabledOnly) 过滤', () async {
      final repo = TaskRepository(appDb);
      await repo.upsert(makeTask('t1'));
      await repo.upsert(makeTask('t2', enabled: false));
      expect((await repo.listAll()).length, 2);
      expect((await repo.listAll(enabledOnly: true)).length, 1);
    });

    test('delete 后 get 返回 null', () async {
      final repo = TaskRepository(appDb);
      await repo.upsert(makeTask('t1'));
      await repo.delete('t1');
      expect(await repo.get('t1'), isNull);
    });

    // ── upsertMany（BUG-042：任务导入的逐条写入）──────────────────────

    test('upsertMany 批量写入：条数与字段完整', () async {
      final repo = TaskRepository(appDb);
      await repo.upsertMany([
        makeTask('b1'),
        makeTask('b2', enabled: false),
        makeTask('b3', cooldown: 42),
      ]);
      expect((await repo.listAll()).length, 3);
      final b3 = await repo.get('b3');
      expect(b3, isNotNull);
      expect(b3!.cooldownSec, 42);
      expect(b3.assetIds, ['a1', 'a2']);
      expect(b3.trigger, isA<DailyTrigger>());
      expect(b3.action, isA<PlayAudioAction>());
      expect((await repo.get('b2'))!.enabled, isFalse);
    });

    test('upsertMany 保留条件层 JSON（含新字段）', () async {
      final repo = TaskRepository(appDb);
      final withCond = makeTask('c1').copyWith(
        condition: const TaskCondition(skipInCall: false, requireWifi: true),
      );
      await repo.upsertMany([withCond]);
      final got = await repo.get('c1');
      expect(got!.condition, isNotNull);
      expect(got.condition!.requireWifi, isTrue);
      expect(got.condition!.skipInCall, isFalse);
    });

    test('upsertMany 空集合不产生任何写入', () async {
      final repo = TaskRepository(appDb);
      await repo.upsertMany(const []);
      expect(await repo.listAll(), isEmpty);
    });

    test('upsertMany 同批重复 id 幂等（replace 语义，不产生重复行）', () async {
      final repo = TaskRepository(appDb);
      await repo.upsertMany([makeTask('dup'), makeTask('dup')]);
      expect((await repo.listAll()).length, 1);
      await repo.upsertMany([makeTask('dup')]); // 整批重放
      expect((await repo.listAll()).length, 1);
    });

    test('upsertMany 原子性：提交前失败不留下半批数据（BUG-042 回归锁）', () async {
      final repo = TaskRepository(appDb);
      // 第 3 条在构造行映射时抛错 → 批次已组好但**尚未 commit**。
      await expectLater(
        repo.upsertMany([
          makeTask('ok1'),
          makeTask('ok2'),
          _ExplodingTask(makeTask('boom')),
          makeTask('ok3'),
        ]),
        throwsA(isA<StateError>()),
      );
      expect(
        await repo.listAll(),
        isEmpty,
        reason: '整批在同一事务里提交，提交前抛错必须**一条都不落库**。'
            '旧的逐条 upsert 循环会留下 ok1/ok2 —— '
            '使用者看到"导入失败"，任务列表里却已经多了一截。',
      );
    });
  });

  group('OccurrenceRepository', () {
    test('commitAll 幂等：重复提交不产生重复行', () async {
      // 外键约束：先落父任务。
      await TaskRepository(appDb).upsert(makeTask('t1'));
      final repo = OccurrenceRepository(appDb);
      final occ = PlannedOccurrence(
        id: 't1@1000',
        taskId: 't1',
        fireAt: DateTime.fromMillisecondsSinceEpoch(1000),
        status: OccurrenceStatus.pending,
        volume: 0.5,
        durationMs: 8000,
      );
      await repo.commitAll([occ]);
      await repo.commitAll([occ]); // 幂等
      final due = await repo.due(DateTime.fromMillisecondsSinceEpoch(2000));
      expect(due.length, 1);
      expect(due.first.volume, 0.5);
    });

    test('due 只返回到期 pending，按时间升序', () async {
      await TaskRepository(appDb).upsert(makeTask('t'));
      final repo = OccurrenceRepository(appDb);
      DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
      await repo.commitAll([
        PlannedOccurrence(
            id: 'a',
            taskId: 't',
            fireAt: at(3000),
            status: OccurrenceStatus.pending),
        PlannedOccurrence(
            id: 'b',
            taskId: 't',
            fireAt: at(1000),
            status: OccurrenceStatus.pending),
        PlannedOccurrence(
            id: 'c',
            taskId: 't',
            fireAt: at(2000),
            status: OccurrenceStatus.done),
        PlannedOccurrence(
            id: 'd',
            taskId: 't',
            fireAt: at(5000),
            status: OccurrenceStatus.pending),
      ]);
      final due = await repo.due(at(4000));
      expect(due.map((e) => e.id).toList(), ['b', 'a']);
    });

    test('markStatus 状态机流转', () async {
      await TaskRepository(appDb).upsert(makeTask('t'));
      final repo = OccurrenceRepository(appDb);
      await repo.commitAll([
        PlannedOccurrence(
            id: 'a',
            taskId: 't',
            fireAt: DateTime.fromMillisecondsSinceEpoch(1000),
            status: OccurrenceStatus.pending),
      ]);
      await repo.markStatus('a', OccurrenceStatus.done,
          volume: 0.9, durationMs: 5000);
      final due = await repo.due(DateTime.fromMillisecondsSinceEpoch(9999));
      expect(due, isEmpty); // 已 done 不再是 due
    });

    test('pendingWithin 边界开闭区间', () async {
      await TaskRepository(appDb).upsert(makeTask('t'));
      final repo = OccurrenceRepository(appDb);
      DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
      await repo.commitAll([
        PlannedOccurrence(
            id: 'a',
            taskId: 't',
            fireAt: at(1000),
            status: OccurrenceStatus.pending),
        PlannedOccurrence(
            id: 'b',
            taskId: 't',
            fireAt: at(2000),
            status: OccurrenceStatus.pending),
        PlannedOccurrence(
            id: 'c',
            taskId: 't',
            fireAt: at(3000),
            status: OccurrenceStatus.pending),
      ]);
      final inRange = await repo.pendingWithin(at(1000), at(3000));
      expect(inRange.map((e) => e.id), ['b', 'c']); // from 排他、to 包含
    });

    test('任务删除级联：deleteForTask 清理其计划', () async {
      await TaskRepository(appDb).upsert(makeTask('t1'));
      await TaskRepository(appDb).upsert(makeTask('t2'));
      final repo = OccurrenceRepository(appDb);
      await repo.commitAll([
        PlannedOccurrence(
            id: 'a',
            taskId: 't1',
            fireAt: DateTime.fromMillisecondsSinceEpoch(1000),
            status: OccurrenceStatus.pending),
        PlannedOccurrence(
            id: 'b',
            taskId: 't2',
            fireAt: DateTime.fromMillisecondsSinceEpoch(1001),
            status: OccurrenceStatus.pending),
      ]);
      await repo.deleteForTask('t1');
      final rest = await repo.pendingWithin(
          DateTime.fromMillisecondsSinceEpoch(0),
          DateTime.fromMillisecondsSinceEpoch(2000));
      expect(rest.map((e) => e.id), ['b']);
    });
  });

  group('LogRepository', () {
    test('append + recent 记录完整审计字段', () async {
      final repo = LogRepository(appDb);
      await repo.append(
        source: 'schedule',
        action: 'play',
        status: 'success',
        taskId: 't1',
        occurrenceId: 't1@1',
        volume: 0.66,
        durationMs: 8000,
        message: 'ok',
      );
      final rows = await repo.recent();
      expect(rows.length, 1);
      final r = rows.first;
      expect(r['source'], 'schedule');
      expect(r['action'], 'play');
      expect(r['status'], 'success');
      expect((r['volume'] as num).toDouble(), 0.66);
      expect(r['duration_ms'], 8000);
      expect(r['message'], 'ok');
    });

    test('countSince 统计时间窗内条目', () async {
      final repo = LogRepository(appDb);
      await repo.append(source: 'manual', action: 'play', status: 'success');
      final n = await repo
          .countSince(DateTime.now().subtract(const Duration(minutes: 1)));
      expect(n, 1);
    });

    /// BUG-035 回归锁：设备上每次 sqflite 调用 ≈1.5ms（平台通道往返），
    /// 逐条 append 写 5000 条 = 7755ms（AOT 实测）。批量路径必须存在，
    /// 且语义与逐条一致（字段完整、同批同一时间戳）。
    test('appendMany 批量写入：条数与字段完整', () async {
      final repo = LogRepository(appDb);
      await repo.appendMany([
        (
          source: 'import',
          action: 'play',
          status: 'success',
          taskId: 't1',
          occurrenceId: 't1@1',
          volume: 0.5,
          durationMs: 1000,
          message: 'batch-1',
        ),
        (
          source: 'import',
          action: 'tts',
          status: 'failed',
          taskId: 't2',
          occurrenceId: null,
          volume: null,
          durationMs: null,
          message: 'batch-2',
        ),
      ]);
      final rows = await repo.recent();
      expect(rows.length, 2);
      final byMsg = {for (final r in rows) r['message'] as String: r};
      expect(byMsg['batch-1']!['source'], 'import');
      expect(byMsg['batch-1']!['task_id'], 't1');
      expect((byMsg['batch-1']!['volume'] as num).toDouble(), 0.5);
      expect(byMsg['batch-1']!['duration_ms'], 1000);
      expect(byMsg['batch-2']!['action'], 'tts');
      expect(byMsg['batch-2']!['status'], 'failed');
      expect(byMsg['batch-2']!['task_id'], 't2');
      // 同批取同一时间戳（批量导入语义：同批同刻）
      expect(byMsg['batch-1']!['created_at'], byMsg['batch-2']!['created_at']);
    });

    test('appendMany 空集合不产生任何写入', () async {
      final repo = LogRepository(appDb);
      await repo.appendMany(const []);
      expect((await repo.recent()).isEmpty, isTrue);
    });
  });

  group('AppDatabase kv', () {
    test('kvSet/kvGet 覆盖写', () async {
      expect(await appDb.kvGet('k'), isNull);
      await appDb.kvSet('k', 'v1');
      await appDb.kvSet('k', 'v2');
      expect(await appDb.kvGet('k'), 'v2');
    });
  });

  /// BUG-022 / BUG-026 回归锁：连接级 PRAGMA 必须真正生效。
  ///
  /// **重要局限（务必知晓）**：本套件跑在 `sqflite_common_ffi` 上，
  /// 其 `execute` 能容忍返回行的 PRAGMA；而 **Android 插件的 `execSQL` 不能**
  /// —— `PRAGMA busy_timeout` 会返回一行，用 `execute` 会抛
  /// `Queries can be performed using SQLiteDatabase query or rawQuery methods only.`，
  /// 该异常穿透 `openDatabase` → `AppDatabase.open()` 失败 → 白屏（BUG-026）。
  ///
  /// 也就是说：**这条缺陷无法被 `flutter test` 拦住，只能靠设备实测**。
  /// 本组测试能保证的是"PRAGMA 值确实被应用"，以及一旦有人把
  /// `rawQuery` 改回 `execute` 时至少 FFI 侧不会静默通过语义变化。
  group('AppDatabase 连接级 PRAGMA（BUG-022/026 回归锁）', () {
    test('busy_timeout / foreign_keys 已生效', () async {
      final timeout = await appDb.db.rawQuery('PRAGMA busy_timeout');
      expect(timeout.first.values.first, 5000);

      final fk = await appDb.db.rawQuery('PRAGMA foreign_keys');
      expect(fk.first.values.first, 1);
    });

    test('journal_mode 可读且非空（内存库回落为 memory，文件库应为 wal）',
        () async {
      final jm = await appDb.db.rawQuery('PRAGMA journal_mode');
      final mode = '${jm.first.values.first}'.toLowerCase();
      expect(mode, isNotEmpty);
      expect(['memory', 'wal'], contains(mode));
    });

    test('写入后仍可读（WAL 不破坏基本读写路径）', () async {
      await appDb.kvSet('pragma_probe', 'ok');
      expect(await appDb.kvGet('pragma_probe'), 'ok');
    });
  });
}

/// 在**行映射阶段**抛错的 Task —— 用来验证批量写入的原子性。
///
/// `Task.toRow()` 是普通实例方法，因此可以在测试里覆写，
/// 从而在 `upsertMany` 已经组好批次、但**尚未 `commit()`** 的位置注入失败。
/// 这是"批量路径失败后一条都不落库"这一断言的注入点：
/// 若换回逐条 `await upsert()` 循环，前两条就已经写进去了。
class _ExplodingTask extends Task {
  _ExplodingTask(Task t)
      : super(
          id: t.id,
          name: t.name,
          enabled: t.enabled,
          triggerType: t.triggerType,
          trigger: t.trigger,
          actionType: t.actionType,
          action: t.action,
          assetIds: t.assetIds,
          cooldownSec: t.cooldownSec,
          quietPolicy: t.quietPolicy,
          condition: t.condition,
          priority: t.priority,
          createdAt: t.createdAt,
          updatedAt: t.updatedAt,
        );

  @override
  Map<String, dynamic> toRow() => throw StateError('boom');
}
