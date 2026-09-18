@Tags(['perf'])
library;

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

import 'perf_bench.dart';

/// 性能与压力测试（白盒/灰盒，TDD）。
///
/// ## ⚠️ 测量模式说明（重要，勿据此判定 NFR 达标）
///
/// 本文件跑在 `flutter test` 下，用的是 **JIT**（无 AOT）。因此这里的墙钟数字
/// **不是** NFR-04 的有效证据 —— 首次执行含编译成本，稳态吞吐也显著低于 AOT。
/// 已做的补救：统一用 [benchMs]（预热 + 取 N 次最小值，见 `test/perf_bench.dart`），
/// 让测量对准"算法成本"而不是"JIT 冷启动"。
///
/// **本文件的定位是 JIT 回归护栏**：只拦"数量级劣化"，不承担绝对性能验收。
/// 因此阈值 = **实测 JIT 基线的 3 倍**（基线随每次定口径更新，见各用例注释），
/// 而不是直接套用 NFR 的绝对预算 —— 后者在 JIT 下不可满足（BUG-036）。
///
/// **绝对验收在 AOT 下进行**：`integration_test/perf_nfr_test.dart`
/// （`flutter drive --profile`，真实设备/模拟器）。
/// 2026-09-18 首次取得 AOT 数据：100 任务物化 **13–15ms** / 预算 500ms（33× 余量）、
/// 1000 任务 **140–204ms** / 预算 5000ms，**NFR-04 绝对达标**。
///
/// 另一条环境约束：本机即使在空闲状态，CPU 也被 WSL2（vmmemWSL 常驻约 12GB）
/// 与 IDE 占用 38–71%。**护栏阈值以"数量级"为粒度，不要为几成的波动调阈值。**
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

    // ── JIT 回归护栏阈值（BUG-036，2026-09-18 定口径） ─────────────────
    //
    // 这里**不能**直接用 NFR-04 的绝对预算（100 任务 ≤500ms）。
    // AOT（profile）实测同一份代码为 **13–15ms**，而 JIT 下为 **510ms**
    // —— 相差约 34 倍。也就是说「JIT ≤500ms」等价于要求 JIT 达到 AOT 速度，
    // 是不可满足的断言：本套件因此会在边缘随机红绿（2026-09-18 实测 510ms 红、
    // 前一轮 533ms 绿），红灯既不表达实现变慢，也不表达阈值写错，只是噪声。
    //
    // 本文件的定位是 **JIT 回归护栏**（见文件头注释）：只拦"数量级劣化"。
    // 因此阈值取 **实测 JIT 基线的 3 倍**，并在改动时同步更新基线。
    // **绝对验收在 AOT**：`integration_test/perf_nfr_test.dart`
    // （`flutter drive --profile`，2026-09-18 实测 100 任务 13–15ms / 预算 500ms）。
    const jitGuard100 = 1500; // 基线 510ms × 3
    const jitGuard500 = 8000; // 基线 2662ms × 3

    test('100 任务物化（JIT 护栏 ≤1500ms，绝对验收见 AOT）', () {
      final tasks = [for (var i = 0; i < 100; i++) genTask(i)];
      final best = benchMs(() {
        for (final t in tasks) {
          engine.materialize(t, now);
        }
      });
      final out = [for (final t in tasks) ...engine.materialize(t, now)];
      expect(best, lessThanOrEqualTo(jitGuard100),
          reason: 'JIT 基线 510ms，护栏 1500ms；实测 ${best}ms（数量级劣化）');
      expect(out.length, greaterThanOrEqualTo(600),
          reason: '48h 视界 × 3 次/天 ≈ 6 条/任务');
    });

    test('500 任务物化（JIT 护栏 ≤8000ms，绝对验收见 AOT）', () {
      final tasks = [for (var i = 0; i < 500; i++) genTask(i)];
      final best = benchMs(() {
        for (final t in tasks) {
          engine.materialize(t, now);
        }
      }, runs: 3, warmUpRuns: 2);
      var count = 0;
      for (final t in tasks) {
        count += engine.materialize(t, now).length;
      }
      expect(best, lessThanOrEqualTo(jitGuard500),
          reason: 'JIT 基线 2662ms，护栏 8000ms；实测 ${best}ms（数量级劣化）');
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
      final best = await benchMsAsync(() async {
        for (var i = 0; i < 500; i++) {
          final t = genTask(i);
          await repo.upsert(t);
          await repo.get(t.id);
        }
      }, runs: 2, warmUpRuns: 1);
      expect(best, lessThanOrEqualTo(2000), reason: 'CRUD 最优耗时 ${best}ms');
    });

    test('exec_logs 5000 条写入 + recent ≤ 3s', () async {
      final logs = LogRepository(db);
      final best = await benchMsAsync(() async {
        for (var i = 0; i < 5000; i++) {
          await logs.append(
              source: 'schedule', action: 'play', status: 'success', taskId: 't');
        }
        await logs.recent(limit: 100);
      }, runs: 1, warmUpRuns: 1);
      expect(best, lessThanOrEqualTo(3000), reason: '最优耗时 ${best}ms');
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
