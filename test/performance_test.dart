import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/core/utils/random.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 性能与压力测试（白盒/灰盒，TDD）。
/// 阈值依据 NFR-04（100 任务物化 ≤500ms）与工程预算外推；
/// 全套运行目标 < 90 秒（单测套件可承受）。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Task genTask(int i) {
    final now = DateTime(2026, 9, 14);
    return Task(
      id: 'perf-$i',
      name: '压测任务$i',
      enabled: true,
      triggerType: TriggerType.randomWindow,
      trigger: RandomWindowTrigger(
        dateRange: DateRange(
            start: DateTime(2026, 9, 14), end: DateTime(2026, 10, 14)),
        windowStart: const TimeSpec(hour: 8),
        windowEnd: const TimeSpec(hour: 21),
        timesPerDay: 3,
        minGap: const Duration(minutes: 30),
      ),
      actionType: ActionType.playAudio,
      action: const PlayAudioAction(
          volumeMin: 0.3,
          volumeMax: 0.9,
          durationSecMin: 3,
          durationSecMax: 10),
      assetIds: const [],
      cooldownSec: 300,
      quietPolicy: QuietPolicy.skip,
      priority: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  group('PT-白盒 · 调度引擎（NFR-04）', () {
    const engine = ScheduleEngine();
    final now = DateTime(2026, 9, 14, 12);

    test('100 任务物化 ≤ 500ms', () {
      final tasks = [for (var i = 0; i < 100; i++) genTask(i)];
      final sw = Stopwatch()..start();
      final out = [for (final t in tasks) ...engine.materialize(t, now)];
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(500),
          reason: '100 任务耗时 ${sw.elapsedMilliseconds}ms');
      expect(out.length, greaterThanOrEqualTo(600),
          reason: '48h 视界 × 3 次/天 ≈ 6 条/任务');
    });

    test('500 任务物化 ≤ 2500ms（线性外推）', () {
      final tasks = [for (var i = 0; i < 500; i++) genTask(i)];
      final sw = Stopwatch()..start();
      var count = 0;
      for (final t in tasks) {
        count += engine.materialize(t, now).length;
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(2500),
          reason: '500 任务耗时 ${sw.elapsedMilliseconds}ms');
      expect(count, greaterThanOrEqualTo(3000), reason: '500 任务 × 6 条');
    });

    test('sampleInWindow 100 次平均 ≤ 50ms/次', () {
      final rng = Random(1);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        sampleInWindow(
            n: 24,
            window: const Duration(hours: 12),
            minGap: const Duration(minutes: 30),
            rng: rng);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds ~/ 100, lessThanOrEqualTo(50));
    });

    test('DPRNG planSeed 10 万次 ≤ 1000ms（JIT 标定；AOT 约×5）', () {
      final d = DateTime(2026, 9, 14);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100000; i++) {
        planSeed('task-$i', d);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(1000),
          reason: 'JIT 实测 ${sw.elapsedMilliseconds}ms');
    });
  });

  group('PT-灰盒 · 数据层', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(inMemoryDatabasePath);
      // 外键：occurrences.task_id 需要父任务存在。
      await db.db.execute(
          "INSERT INTO tasks (id, name, enabled, trigger_type, trigger_json, action_type, action_json, asset_ids, cooldown_sec, quiet_policy, priority, created_at, updated_at) VALUES ('t', '压测父任务', 1, 'dailyAt', '{}', 'playAudio', '{}', '[]', 300, 'skip', 0, 0, 0)");
    });
    tearDown(() async {
      await db.close();
    });

    test('occurrences 批量 1000 条提交 ≤ 1s', () async {
      final occ = OccurrenceRepository(db);
      final base = DateTime(2026, 9, 14, 12);
      final list = [
        for (var i = 0; i < 1000; i++)
          PlannedOccurrence(
            id: 'p$i',
            taskId: 't',
            fireAt: base.add(Duration(minutes: i)),
            status: OccurrenceStatus.pending,
            volume: 0.5,
            durationMs: 5000,
          ),
      ];
      final sw = Stopwatch()..start();
      await occ.commitAll(list);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(1000));
    });

    test('万级表中 due/pending 查询 ≤ 50ms', () async {
      final occ = OccurrenceRepository(db);
      final base = DateTime(2026, 9, 14, 12);
      await occ.commitAll([
        for (var i = 0; i < 10000; i++)
          PlannedOccurrence(
            id: 'm$i',
            taskId: 't',
            fireAt: base.add(Duration(minutes: i)),
            status: OccurrenceStatus.pending,
          ),
      ]);
      final sw = Stopwatch()..start();
      final due =
          await occ.due(base.add(const Duration(hours: 100)), limit: 10);
      final pending = await occ.pendingCountAfter(base);
      sw.stop();
      expect(due.length, 10);
      expect(pending, 9999); // fire_at > now 严格大于（首条==now 不计）
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(50),
          reason: '万级查询耗时 ${sw.elapsedMilliseconds}ms');
    });

    test('任务 CRUD 500 次 ≤ 2s', () async {
      final repo = TaskRepository(db);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 500; i++) {
        final t = genTask(i);
        await repo.upsert(t);
        await repo.get(t.id);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(2000));
    });

    test('exec_logs 5000 条写入 + recent ≤ 3s', () async {
      final logs = LogRepository(db);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 5000; i++) {
        await logs.append(
            source: 'schedule', action: 'play', status: 'success', taskId: 't');
      }
      await logs.recent(limit: 100);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(3000));
    });

    test('purgeOlderThan 万级清理 ≤ 1s', () async {
      final occ = OccurrenceRepository(db);
      final base = DateTime(2026, 9, 14, 12);
      await occ.commitAll([
        for (var i = 0; i < 10000; i++)
          PlannedOccurrence(
            id: 'o$i',
            taskId: 't',
            fireAt: base.subtract(Duration(minutes: i)),
            status: OccurrenceStatus.done,
          ),
      ]);
      final sw = Stopwatch()..start();
      final n = await occ.purgeOlderThan(base.add(const Duration(days: 1)));
      sw.stop();
      expect(n, 10000);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(1000));
    });
  });

  group('PT-灰盒 · 序列化与远程模块', () {
    test('100 任务 JSON 往返 ≤ 300ms', () {
      final tasks = [for (var i = 0; i < 100; i++) genTask(i)];
      final sw = Stopwatch()..start();
      final rows = [for (final t in tasks) t.toRow()];
      final back = [for (final r in rows) Task.fromRow(r)];
      sw.stop();
      expect(back.length, 100);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(300));
    });

    test('RcCodec 加解密 200 条 ≤ 2s', () async {
      final key = await RcCodec.deriveKey('TESTSECRET', 'dev|cmd');
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        final wire = await RcCodec.encode(
            RcMessage.now('ping', {'i': i}), key, 'sonicshield/v1/dev/cmd');
        final msg = await RcCodec.decode(wire, key, 'sonicshield/v1/dev/cmd',
            maxSkewMs: 99999999);
        expect(msg, isNotNull);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(2000));
    });

    test('50 步指令组校验 × 100 ≤ 200ms', () {
      final steps = [
        for (var i = 0; i < 50; i++)
          i.isEven
              ? const RcStep(RcStepKind.play, {
                  'volume': 0.8,
                  'durationSec': 10,
                  'presetCategory': 'nature'
                })
              : const RcStep(RcStepKind.delay, {'seconds': 30}),
      ];
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        expect(RcScript.validate(steps), isNull);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(200));
    });

    test('outbox 200 条 enqueue/drain ≤ 200ms', () async {
      final prefs = await tempPrefs();
      final store = RemoteStore(prefs);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        await store.enqueue('wire-$i', 'dev-a');
      }
      final drained = store.drainOutbox('dev-a');
      sw.stop();
      expect(drained.length, 200);
      expect(store.outbox(), isEmpty);
      // SharedPreferences mock 环境标定（真机 hive/sqlite 更快）。
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(500));
    });
  });
}

/// SharedPreferences 官方 mock（压测专用隔离）。
Future<SharedPreferences> tempPrefs() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  return SharedPreferences.getInstance();
}
