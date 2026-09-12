import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
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
  });

  group('AppDatabase kv', () {
    test('kvSet/kvGet 覆盖写', () async {
      expect(await appDb.kvGet('k'), isNull);
      await appDb.kvSet('k', 'v1');
      await appDb.kvSet('k', 'v2');
      expect(await appDb.kvGet('k'), 'v2');
    });
  });
}
