@Tags(['perf'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:sonic_shield/services/export_crypto.dart';

import 'perf_bench.dart';

/// 第二轮性能压测（v1.4–v2.0 新模块，docs/17）。
/// 覆盖：条件层 / 扫码配对解析 / 加密备份 / 统计聚合 / 指令组序列 / 内存基准。
///
/// ## ⚠️ 测量模式说明（同 `performance_test.dart`）
///
/// 本文件跑在 `flutter test`（**JIT**）下，墙钟数字不是 NFR 的有效证据；
/// 已统一用 [benchMs] / [benchMsAsync]（预热 + 取最小值）对准算法成本。
/// **定位：JIT 回归护栏**；**绝对验收在 AOT**：
/// `integration_test/perf_nfr_test.dart`（`flutter drive --profile`）。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('WT-白盒 · 条件层与扫码配对', () {
    const cond = TaskCondition(
      requireCharging: true,
      minBatteryPct: 20,
      windowStartMin: 8 * 60,
      windowEndMin: 21 * 60,
    );
    final now = DateTime(2026, 9, 15, 12); // 12:00，在窗口内

    test('WT-01 TaskCondition.evaluate 10 万次 ≤ 800ms', () {
      final sw = Stopwatch()..start();
      var pass = 0;
      for (var i = 0; i < 100000; i++) {
        if (cond.evaluate(charging: true, batteryLevel: 80, now: now)) {
          pass++;
        }
      }
      sw.stop();
      expect(pass, 100000);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(800),
          reason: '条件评估 10 万次耗时 ${sw.elapsedMilliseconds}ms');
    });

    test('WT-02 parseUri 1 万次（有效/无效混合）≤ 300ms', () {
      const valid =
          'sonicshield://pair/0123456789abcdef/%E5%A3%B0%E7%9B%BE-A1/AB2CD5EF';
      final sw = Stopwatch()..start();
      var ok = 0;
      for (var i = 0; i < 10000; i++) {
        if (PairQrProtocol.parseUri(valid) != null) ok++;
        if (PairQrProtocol.parseUri('sonicshield://pair/bad') == null) ok++;
      }
      sw.stop();
      expect(ok, 20000); // 每轮两断言均计入
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(300));
    });

    test('WT-03 配对码/设备 ID 生成各 1 万次 ≤ 800ms', () {
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10000; i++) {
        expect(RcCodec.generatePairingCode().replaceAll('-', '').length, 8);
        expect(RcCodec.generateDeviceId().length, 16);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(800));
    });
  });

  group('GT-灰盒 · 加密备份（PBKDF2 120k + AES-GCM）', () {
    /// 本组三条用例的**工作量完全相同**：120k 次 PBKDF2 派生 + 一次 50KB 的
    /// AES-256-GCM 运算（错密码只是最后 GCM 校验失败，KDF 一次都不会少跑）。
    /// 因此它们**必须共用同一个预算**。
    ///
    /// ⚠️ 这正是一条缺陷（BUG-057）的成因：GT-03 曾单独写 `1500`，
    /// 而实测三条都在 1.05–1.13s —— 于是 GT-03 只剩 **1.33×** 余量，
    /// 兄弟用例却有 3.5×+。机器一有 CPU 争用就先红（实测被一次残留进程
    /// 拖到 3229ms），表现为"同一份代码时红时绿"。
    ///
    /// 取值依据：干净机器实测 ≈1.05–1.13s（JIT），取 ~3.5× 余量。
    /// ⚠️ 这是 **JIT 护栏**，不是绝对性能验收 —— 绝对验收在 AOT 层
    /// （`integration_test/perf_nfr_test.dart` 的 NFR-04）。
    /// 一致性由 `test/perf_budget_consistency_test.dart` 上锁。
    const kdfBudgetMs = 4000;

    // ~50KB 任务备份（100 任务全字段）。
    final bigPayload = const JsonEncoder().convert({
      'app': 'sonic_shield',
      'version': 1,
      'tasks': [
        for (var i = 0; i < 100; i++)
          {
            'id': 't$i',
            'name': '压测任务$i（含中文字段与较长描述内容以扩大体积）',
            'trigger_json':
                '{"kind":"randomWindow","timesPerDay":3,"minGapSec":1800}',
            'action_json': '{"kind":"play","volumeMin":0.3,"volumeMax":0.9}',
            'condition_json': '{"requireCharging":true,"minBatteryPct":20}',
          }
      ],
    });

    test('GT-01 加密 50KB 备份（含 KDF 12 万次，纯 Dart 实现）≤ 4s', () async {
      final sw = Stopwatch()..start();
      final enc = await ExportCrypto.encrypt(bigPayload, 'stress-pass');
      sw.stop();
      expect(enc.length, greaterThan(40000));
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(kdfBudgetMs),
          reason: 'GT-01 加密实测 ${sw.elapsedMilliseconds}ms'
              '（预算 ${kdfBudgetMs}ms = 实测 ≈1.1s × ~3.5）');
    });

    test('GT-02 解密 50KB 备份（含 KDF 12 万次，纯 Dart 实现）≤ 4s', () async {
      final enc = await ExportCrypto.encrypt(bigPayload, 'stress-pass');
      final sw = Stopwatch()..start();
      final back = await ExportCrypto.decrypt(enc, 'stress-pass');
      sw.stop();
      expect(back, bigPayload);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(kdfBudgetMs),
          reason: 'GT-02 解密实测 ${sw.elapsedMilliseconds}ms'
              '（预算 ${kdfBudgetMs}ms = 实测 ≈1.05s × ~3.8）');
    });

    test('GT-03 错误密码解密（含 KDF+失败）≤ 4s', () async {
      final enc = await ExportCrypto.encrypt(bigPayload, 'right');
      final sw = Stopwatch()..start();
      final back = await ExportCrypto.decrypt(enc, 'wrong');
      sw.stop();
      expect(back, isNull);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(kdfBudgetMs),
          reason: 'GT-03 错密码解密实测 ${sw.elapsedMilliseconds}ms'
              '（预算 ${kdfBudgetMs}ms —— 与 GT-01/02 **同一份工作量**，'
              '故必须同一预算；曾单独写 1500ms，只剩 1.33× 余量）');
    });
  });

  group('GT-灰盒 · 统计聚合（万级日志）', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(inMemoryDatabasePath);
      final base = DateTime.now().subtract(const Duration(days: 3));
      final batch = db.db.batch();
      for (var i = 0; i < 10000; i++) {
        batch.insert('exec_logs', {
          'source': 'schedule',
          'action': i % 3 == 0 ? 'play' : (i % 3 == 1 ? 'tts' : 'notify'),
          'status': i % 10 == 0 ? 'failed' : 'success',
          'created_at': base.add(Duration(minutes: i)).millisecondsSinceEpoch,
        });
      }
      await batch.commit(noResult: true);
    });
    tearDown(() async {
      await db.close();
    });

    test('GT-04 dailyCounts 万级 ≤ 50ms', () async {
      final logs = LogRepository(db);
      // 单次测量测的是"首次调用的 SQL 准备 + JIT 编译"（实测 333ms），
      // 与用例意图（稳态聚合延迟）不是一回事 → 预热后取最小值。
      final best = await benchMsAsync(() async {
        await logs.dailyCounts(days: 7);
      });
      final daily = await logs.dailyCounts(days: 7);
      expect(daily, isNotEmpty);
      expect(best, lessThanOrEqualTo(50), reason: 'dailyCounts 最优 ${best}ms');
    });

    test('GT-05 actionBreakdown 万级 ≤ 50ms', () async {
      final logs = LogRepository(db);
      final best = await benchMsAsync(() async {
        await logs.actionBreakdown();
      });
      final actions = await logs.actionBreakdown();
      expect(actions, isNotEmpty);
      expect(best, lessThanOrEqualTo(50),
          reason: 'actionBreakdown 最优 ${best}ms');
    });
  });

  group('GT-灰盒 · 指令组序列与 outbox', () {
    test('GT-06 50 步指令组 toPayload × 100 ≤ 200ms', () {
      final steps = [
        for (var i = 0; i < 50; i++)
          i.isEven
              ? const RcStep(RcStepKind.play, {
                  'volume': 0.8,
                  'durationSec': 10,
                  'presetCategory': 'ambient'
                })
              : const RcStep(RcStepKind.delay, {'seconds': 30}),
      ];
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        final payload = RcScript(
          scriptId: 's$i',
          name: '压测',
          fromName: 'A',
          sentAt: DateTime.now().millisecondsSinceEpoch,
          steps: steps,
        ).toJson();
        expect(payload['steps'], isNotNull);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(200));
    });

    // 第十七轮修复（BUG-053）：原实现用**裸 Stopwatch 单次采样**，而本文件
    // 头部明确要求"统一用 benchMs/benchMsAsync（预热 + 取最小值）"。
    // 后果：同一份代码在全套件负载下测到 455ms（红）、单独跑 6/6 绿且 <1s ——
    // 单次采样测的是 JIT 编译 + GC + 调度噪声，不是该路径的成本。
    // 改造后实测基线：全套件负载 51ms / 单独 53ms（**min-of-5 高度可复现**，
    // 两种场景差 <4%），阈值按本套件约定取「基线 × 3」。
    // 净效果：既不再假红，又比旧阈值（400ms ≈ 基线 × 7.8）**收紧约 2.5 倍**。
    test('GT-07 outbox 200 条 + 二次 drain 幂等 ≤ 160ms（JIT 护栏 = 基线 × 3）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = RemoteStore(prefs);
      var d1Len = 0;
      var d2Len = -1;
      // 这条路径是**往返受限**的：200 次 `enqueue` = 200 次
      // `prefs.setString` 平台往返（外加对递增列表的整体 jsonEncode）。
      final best = await benchMsAsync(() async {
        for (var i = 0; i < 200; i++) {
          await store.enqueue('w$i', 'dev');
        }
        final d1 = store.drainOutbox('dev');
        final d2 = store.drainOutbox('dev');
        d1Len = d1.length;
        d2Len = d2.length;
      });
      expect(d1Len, 200);
      expect(d2Len, 0); // 幂等：冲刷后不再重复
      expect(best, lessThanOrEqualTo(160),
          reason: 'outbox 200 条 + 二次 drain 最优 ${best}ms（基线 51ms × 3）');
    });
  });

  group('MT-内存基准', () {
    test('MT-01 1000 任务物化 1.2 万条（JIT 护栏 ≤16000ms，分配量代理）', () {
      const engine = ScheduleEngine();
      final now = DateTime(2026, 9, 14, 12);

      Task memTask(int i) => Task(
            id: 'mem-$i',
            name: '内存压测$i',
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
            action: const PlayAudioAction(),
            assetIds: const [],
            cooldownSec: 300,
            quietPolicy: QuietPolicy.skip,
            priority: 0,
            createdAt: now,
            updatedAt: now,
          );

      // 分配量统计（非计时）：确认物化规模符合预期。
      var count = 0;
      var footprint = 0; // 分配量代理：occurrenceId 字符总量
      for (var i = 0; i < 1000; i++) {
        for (final e in engine.materialize(memTask(i), now)) {
          count++;
          footprint += e.occurrenceId.length;
        }
      }

      // JIT 预热已由 memTask 的构造 + 上一轮物化完成；取最小值过滤 GC 噪声。
      final best = benchMs(() {
        for (var i = 0; i < 1000; i++) {
          engine.materialize(memTask(i), now);
        }
      }, runs: 3, warmUpRuns: 0);

      expect(count, greaterThanOrEqualTo(6000),
          reason: '48h 视界 × 3 次/天 ≈ 6 条/任务');
      // 分配量代理：1.2 万条 ID ≈ 300KB 字符量级，远低于泄漏阈值。
      expect(footprint, lessThan(500000));
      // ── 时间断言的口径（BUG-034 → BUG-036，2026-09-18 定稿） ─────────
      // 本用例是**分配量基准**，时间断言只是次要护栏。
      // 曾两次调阈值：4000ms（无法从规范推导）→ 5000ms（NFR-04 线性外推）。
      // 两者都错在同一处：**把 AOT 的绝对预算套在 JIT 测量上**。
      // 2026-09-18 首次取得 AOT 数据：同一份代码 1000 任务物化
      // **140–204ms**（`integration_test/perf_nfr_test.dart`，预算 5000ms，
      // 25–35× 余量），而 JIT 下稳定在 4500–5700ms —— 相差约 30 倍。
      // 因此"JIT ≤5000ms"等价于要求 JIT 达到 AOT 速度，不可满足，
      // 表现为边缘随机红绿（本次实测 5207ms 红）。
      // 现口径：JIT 侧取**实测基线的 3 倍**作数量级护栏；绝对验收在 AOT。
      const jitGuard1000 = 16000; // 基线 ~5200ms × 3
      expect(best, lessThanOrEqualTo(jitGuard1000),
          reason: 'JIT 基线 ~5200ms，护栏 16000ms；实测 ${best}ms（数量级劣化）');
    });
  });
}
