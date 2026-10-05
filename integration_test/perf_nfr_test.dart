import 'dart:math';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sonic_shield/core/utils/random.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:sonic_shield/services/condition_env.dart';
import 'package:sonic_shield/services/native_bridge.dart';

/// **NFR-04 性能验收（AOT / profile 模式）**。
///
/// ## 为什么必须单独有这一个文件
///
/// `test/performance_test.dart` 与 `performance_v2_test.dart` 跑在
/// `flutter test` 下，而 `flutter test` 用的是 **JIT**（无 AOT）。这导致两个后果：
///
/// 1. 首次执行要现编译，编译成本被算进墙钟 —— 不预热时同一用例两次运行差近 2 倍；
/// 2. 即使预热 + 取 N 次最小值，JIT 的稳态吞吐仍显著低于 AOT，
///    于是"NFR-04：100 任务 ≤500ms"这类**绝对阈值**在 JIT 下测出的数字
///    与生产（release AOT）不是一回事。
///
/// **NFR 是运行时性能要求，就该在运行时（AOT）模式下验收。** 本文件用
/// `flutter drive --profile` 在真实设备/模拟器上以 AOT 编译运行，测量结果
/// 才是 NFR-04 的有效证据；`flutter test` 下的那两个套件则退回为
/// **JIT 回归护栏**（只拦数量级劣化，不承担绝对验收）。
///
/// ## 运行
/// ```
/// flutter drive --driver=test_driver/integration_test.dart \
///   --target=integration_test/perf_nfr_test.dart --profile -d emulator-5554
/// ```
///
/// ## ⚠️ 关于"本文件在受限环境下无法执行"（2026-09-18 更正）
///
/// 曾记录：沙箱把 `reg.exe` 列入程序黑名单，导致 profile/release 构建被 SIGTERM，
/// 故本文件无法执行。**该结论已被证伪**：真正的原因是当时用
/// `env "PROGRAMFILES(X86)=..." flutter` 包装命令，而 PATH 上名为 `env` 的
/// 可执行文件是 **uv 的 PATH 修补脚本**（`#!/bin/sh ... export PATH=...`），
/// 它被当作程序调用时会**吞掉全部参数并返回 0** —— 命令根本没跑。
/// 见 docs/12 §15。
///
/// 2026-09-18 实测：`flutter build apk --profile` 成功（148.0MB / 421.2s），
/// `flutter drive --profile` 正常执行并取得 AOT 数据。**不要再引用"沙箱拦截"之说。**
///
/// ## 报告口径
/// 每个用例**先打印实测值再断言**，因此即便断言失败也能从输出里读到真实数字
/// （失败时不会只剩一句 "expected ≤ 500"）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const engine = ScheduleEngine();
  // P1-05 后口径变化（与 `test/performance_test.dart` PT 组同步）：随机窗口改为
  // "**整窗抽样 + 事后按 now/end 过滤**"。基准起点必须落在**窗口边界之外**（午夜），
  // 否则首/末日窗口会被 `now`/`end` 部分裁掉 —— 那是**正确行为**，但会让
  // "≈6 条/任务"这条规模基准随 `now` 漂移、变成假红。取午夜 ⇒ 48h 恰覆盖
  // 09-14/09-15 两个完整窗口（08:00–21:00），09-16 整窗落在 end 之外 ⇒ 稳定 6 条/任务。
  final now = DateTime(2026, 9, 14);

  /// 打印一行测量结果（AOT 下的真实数字）。
  void report(String name, int ms, int budgetMs) {
    final verdict = ms <= budgetMs ? 'PASS' : 'OVER';
    debugPrint('[NFR-AOT] $name: ${ms}ms / 预算 ${budgetMs}ms → $verdict');
  }

  /// 取 N 次测量的最小值：墙钟噪声只会让测量值变大，最小值最接近真实成本。
  int best(void Function() body, {int runs = 5, int warmUp = 3}) {
    for (var i = 0; i < warmUp; i++) {
      body();
    }
    var b = 1 << 62;
    for (var i = 0; i < runs; i++) {
      final sw = Stopwatch()..start();
      body();
      sw.stop();
      if (sw.elapsedMilliseconds < b) b = sw.elapsedMilliseconds;
    }
    return b;
  }

  Task genTask(int i) => Task(
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

  testWidgets('NFR-04 调度物化（AOT 绝对验收）', (tester) async {
    final t100 = [for (var i = 0; i < 100; i++) genTask(i)];
    final t500 = [for (var i = 0; i < 500; i++) genTask(i)];

    final ms100 = best(() {
      for (final t in t100) {
        engine.materialize(t, now);
      }
    });
    final ms500 = best(() {
      for (final t in t500) {
        engine.materialize(t, now);
      }
    }, runs: 3, warmUp: 2);

    // 物化规模（防止"变快是因为没干活"）
    final count100 = [
      for (final t in t100) ...engine.materialize(t, now)
    ].length;

    report('NFR-04 · 100 任务物化', ms100, 500);
    report('NFR-04 · 500 任务物化（线性外推）', ms500, 2500);

    expect(count100, greaterThanOrEqualTo(600),
        reason: '48h 视界 × 3 次/天 ≈ 6 条/任务');
    expect(ms100, lessThanOrEqualTo(500),
        reason: 'NFR-04 未达标：100 任务物化实测 ${ms100}ms');
    expect(ms500, lessThanOrEqualTo(2500),
        reason: '线性外推未达标：500 任务物化实测 ${ms500}ms');
  });

  testWidgets('NFR-04 · 1000 任务物化（MT-01 口径核对）', (tester) async {
    final ms1000 = best(() {
      for (var i = 0; i < 1000; i++) {
        engine.materialize(genTask(i), now);
      }
    }, runs: 3, warmUp: 1);

    // BUG-034 已定口径：以 NFR-04 的线性外推（100 任务 ≤500ms → 1000 任务
    // ≤5000ms）为准。原 4000ms 无法从 NFR-04 推导，属阈值写错而非实现变慢。
    // 这里同时打印两个数字，便于日后复核。
    report('MT-01 · 1000 任务物化', ms1000, 5000);
    debugPrint('[NFR-AOT] 对照：旧阈值 4000ms（严于 NFR-04 外推，已废弃）');

    expect(ms1000, lessThanOrEqualTo(5000),
        reason: 'NFR-04 线性外推未达标：1000 任务物化实测 ${ms1000}ms');
  });

  testWidgets('NFR · DPRNG 与采样（AOT）', (tester) async {
    final d = DateTime(2026, 9, 14);
    final msSeed = best(() {
      for (var i = 0; i < 100000; i++) {
        planSeed('task-$i', d);
      }
    }, runs: 3, warmUp: 1);

    final rng = Random(1);
    final msSample = best(() {
      for (var i = 0; i < 100; i++) {
        sampleInWindow(
            n: 24,
            window: const Duration(hours: 12),
            minGap: const Duration(minutes: 30),
            rng: rng);
      }
    }, runs: 3, warmUp: 1);

    report('DPRNG planSeed 10 万次', msSeed, 1000);
    report('sampleInWindow 100 次（单次均值）', msSample ~/ 100, 50);

    expect(msSeed, lessThanOrEqualTo(1000),
        reason: 'DPRNG 未达标：${msSeed}ms');
    expect(msSample ~/ 100, lessThanOrEqualTo(50),
        reason: '采样未达标：单次 ${msSample ~/ 100}ms');
  });

  testWidgets('NFR · 数据层（AOT，真实 sqflite）', (tester) async {
    final db = await AppDatabase.open();
    try {
      final tasks = TaskRepository(db);
      final logs = LogRepository(db);

      // ── 基准：平台通道往返成本（必须最先测）────────────────────────
      //
      // 设备上**每次 sqflite 调用 = 一次 Dart→平台通道→原生 SQLite 往返**。
      // 单次往返成本**随机器状态浮动** —— 同一台机器、同一份 APK，
      // 冷启 2475µs/次、热机 1565µs/次（1.6×，BUG-043）；后续实测更宽：
      // **1963µs ↔ 4839µs（2.5×）**。任何"绝对 ms"预算都会因此红绿翻转：
      // `任务 CRUD 500 次` 冷启 3340ms 撞 2000ms 预算、热机 1764ms 通过。
      // 所以往返受限路径的预算一律**归一化**为「本次往返成本 × 调用次数 × 3」。
      //
      // ⚠️ **BUG-054（第十七轮续三修正）**：这条基准原先**自己给自己当基准** ——
      // `perCallUs = singleMs / 5000`，而 `singleMs` 正是下面那条 5000 次 append
      // 的测量值。于是被它归一化的用例自洽了，它**自己**却只能用一条硬编码的
      // 绝对护栏（20000ms = 4ms/次，按"冷启 2.475ms/次"标定）。
      // 实测该标定不成立：往返成本可到 4839µs/次 → 该护栏余量在
      // **2.0× ↔ 0.83×** 之间摆动，**跨过 1.0 就红** —— 它成了本文件
      // **唯一一条会随机器状态假红**的用例。
      //
      // 修法：**基准改用一个独立的、小规模的同类探针来测** —— 同样是
      // `logs.append`（= 一次平台往返 + 一次 INSERT），但只跑 200 次。
      // 与那条 5000 次的用例**解耦**，所以 `budgetFor(5000)` 不再是
      // `3 × singleMs` 那种恒真断言，也不再依赖任何绝对 ms。
      //
      // ⚠️ **为什么探针必须与被护栏的用例"同类"**（第一次改错的教训）：
      // 曾改用 `tasks.get(<缺失 id>)`（= 纯 1 次 SELECT）做探针，结果
      // 写入路径的每次调用要 2~3 次往返 → 探针**低估**了单位成本 →
      // `任务 500 条逐条写入` 实测 3534ms / 预算 3728ms，**只剩 1.05× 余量**
      // —— 等于把 BUG-054 搬到另一条用例上。**归一化的单位必须与被护栏的
      // 工作量同量级**，否则 3× 安全系数会被结构差异吃掉。
      //
      // 本护栏的语义（写清楚，免得被当成"绝对性能验收"）：
      // 它断言的是**规模不变性** —— 5000 次调用的每次成本不得超过
      // 200 次调用的每次成本的 3×。**均匀变慢抓不住**（两边一起变），
      // 但**超线性退化**（例如丢了索引导致 append 变 O(n)）会被抓住。
      const kProbeCalls = 200;
      for (var i = 0; i < 20; i++) {
        await logs.append(
            source: 'probe', action: 'warmup', status: 'success'); // 预热
      }
      var probeMs = 1 << 62;
      for (var r = 0; r < 3; r++) {
        final sw = Stopwatch()..start();
        for (var i = 0; i < kProbeCalls; i++) {
          await logs.append(
              source: 'probe', action: 'play', status: 'success');
        }
        sw.stop();
        if (sw.elapsedMilliseconds < probeMs) probeMs = sw.elapsedMilliseconds;
      }
      final perCallUs = probeMs * 1000 / kProbeCalls;
      int budgetFor(int calls) => (perCallUs * calls / 1000 * 3).round();
      debugPrint('[NFR-AOT] 基准：每次日志写入 ${perCallUs.round()}µs'
          '（探针 = $kProbeCalls 次 append；'
          '逐条路径预算 = 本次单次写入成本 × 调用次数 × 3）');

      // ── 被护栏的用例：5000 次 append = 5000 次往返（**不再自带基准**）──
      var singleMs = 1 << 62;
      for (var r = 0; r < 3; r++) {
        final sw = Stopwatch()..start();
        for (var i = 0; i < 5000; i++) {
          await logs.append(
              source: 'schedule',
              action: 'play',
              status: 'success',
              taskId: 't');
        }
        await logs.recent(limit: 100);
        sw.stop();
        if (sw.elapsedMilliseconds < singleMs) singleMs = sw.elapsedMilliseconds;
      }
      report('exec_logs 5000 条**逐条**写入 + recent', singleMs, budgetFor(5000));

      // 任务 CRUD 500 次 = **1000 次往返**（500 upsert + 500 get）
      var crudMs = 1 << 62;
      for (var r = 0; r < 3; r++) {
        final sw = Stopwatch()..start();
        for (var i = 0; i < 500; i++) {
          final t = genTask(i);
          await tasks.upsert(t);
          await tasks.get(t.id);
        }
        sw.stop();
        if (sw.elapsedMilliseconds < crudMs) crudMs = sw.elapsedMilliseconds;
      }
      report('任务 CRUD 500 次', crudMs, budgetFor(1000));

      // ── 任务**逐条 vs 批量**写入（BUG-042）──────────────────────────
      //
      // 同一工作量（500 条写入），唯一变量是**平台通道往返次数**：
      //   · 逐条：500 次 `upsert` = 500 次往返（≈1.5ms/次，BUG-035 已交叉验证）；
      //   · 批量：1 次 `upsertMany` = **1 次**往返。
      // "任务导入"（settings_screen 的导入流程）正是走批量路径的真实调用方，
      // 所以这两个数字的比值就是该功能的真实提速。
      var writeSingleMs = 1 << 62;
      for (var r = 0; r < 3; r++) {
        final sw = Stopwatch()..start();
        for (var i = 0; i < 500; i++) {
          await tasks.upsert(genTask(i));
        }
        sw.stop();
        if (sw.elapsedMilliseconds < writeSingleMs) {
          writeSingleMs = sw.elapsedMilliseconds;
        }
      }
      report('任务 500 条**逐条**写入', writeSingleMs, budgetFor(500));

      var writeBatchMs = 1 << 62;
      for (var r = 0; r < 3; r++) {
        final sw = Stopwatch()..start();
        await tasks.upsertMany([for (var i = 0; i < 500; i++) genTask(i)]);
        sw.stop();
        if (sw.elapsedMilliseconds < writeBatchMs) {
          writeBatchMs = sw.elapsedMilliseconds;
        }
      }
      report('任务 500 条**批量**写入（BUG-042）', writeBatchMs, 500);
      debugPrint('[NFR-AOT]   → 逐条 ${writeSingleMs}ms → 批量 ${writeBatchMs}ms'
          '（同 500 条写入，仅往返次数不同）');

      var batchMs = 1 << 62;
      for (var r = 0; r < 2; r++) {
        final sw = Stopwatch()..start();
        await logs.appendMany([
          for (var i = 0; i < 5000; i++)
            (
              source: 'schedule',
              action: 'play',
              status: 'success',
              taskId: 't',
              occurrenceId: null,
              volume: null,
              durationMs: null,
              message: null,
            )
        ]);
        await logs.recent(limit: 100);
        sw.stop();
        if (sw.elapsedMilliseconds < batchMs) batchMs = sw.elapsedMilliseconds;
      }
      report('exec_logs 5000 条**批量**写入 + recent', batchMs, 3000);

      // 万级聚合
      var aggMs = 1 << 62;
      for (var r = 0; r < 5; r++) {
        final sw = Stopwatch()..start();
        await logs.dailyCounts(days: 7);
        sw.stop();
        if (sw.elapsedMilliseconds < aggMs) aggMs = sw.elapsedMilliseconds;
      }
      report('dailyCounts 万级聚合', aggMs, 50);

      expect(crudMs, lessThanOrEqualTo(budgetFor(1000)),
          reason: 'CRUD 实测 ${crudMs}ms（本次每次往返 ${perCallUs.round()}µs'
              ' → 1000 次预算 ${budgetFor(1000)}ms，3× 余量）');
      expect(writeSingleMs, lessThanOrEqualTo(budgetFor(500)),
          reason: '任务逐条写入实测 ${writeSingleMs}ms'
              '（本次每次往返 ${perCallUs.round()}µs'
              ' → 500 次预算 ${budgetFor(500)}ms，3× 余量）');
      expect(writeBatchMs, lessThanOrEqualTo(500),
          reason: '任务批量写入实测 ${writeBatchMs}ms（批量 = 单次往返，'
              '应与往返次数解耦）');
      expect(singleMs, lessThanOrEqualTo(budgetFor(5000)),
          reason: '逐条日志写入实测 ${singleMs}ms（本次每次往返 '
              '${perCallUs.round()}µs → 5000 次预算 ${budgetFor(5000)}ms，3× 余量）');
      expect(batchMs, lessThanOrEqualTo(3000),
          reason: '批量日志写入实测 ${batchMs}ms');
      expect(aggMs, lessThanOrEqualTo(50), reason: '聚合实测 ${aggMs}ms');
    } finally {
      await db.close();
    }
  });

  testWidgets('NFR · 条件层每轮复用（AOT，真实平台读取）', (tester) async {
    // 条件层是**安全护栏**（通话中不执行 / 仅 Wi-Fi），必须用**真实**平台读取测量，
    // 否则测不出"每次读取 = 一次平台通道往返"这个真正的成本。
    final battery = Battery();
    const cond = TaskCondition(requireWifi: true, skipInCall: true);
    const taskCount = 50; // 模拟"一轮有 50 个到期任务"

    Future<ConditionEnv> readEnv() async {
      var level = 100;
      var charging = false;
      try {
        level = await battery.batteryLevel;
        final st = await battery.batteryState;
        charging = st == BatteryState.charging || st == BatteryState.full;
      } on Object {
        // 与引擎一致：无电池平台视为满足电量条件
      }
      bool? inCall;
      bool? onWifi;
      try {
        inCall = await NativeBridge.isInCall();
        onWifi = await NativeBridge.isOnWifi();
      } on Object {
        // 与引擎一致：桥不可用 → 保持 null，按"满足"处理
      }
      return ConditionEnv(
        charging: charging,
        batteryLevel: level,
        inCall: inCall,
        onWifi: onWifi,
      );
    }

    // ── 改造前：逐任务读平台（4 × N 次往返）──────────────────────────
    var perTaskMs = 1 << 62;
    for (var r = 0; r < 3; r++) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < taskCount; i++) {
        final env = await readEnv();
        cond.firstUnmetIn(env, now: DateTime.now());
      }
      sw.stop();
      if (sw.elapsedMilliseconds < perTaskMs) perTaskMs = sw.elapsedMilliseconds;
    }
    report('条件评估 $taskCount 任务**逐任务读取**（改造前）', perTaskMs, 5000);

    // ── 改造后：一轮读一次（固定 4 次往返，与 N 解耦）─────────────────
    var roundMs = 1 << 62;
    var observedReads = 0;
    for (var r = 0; r < 3; r++) {
      final sw = Stopwatch()..start();
      final env = RoundConditionEnv(read: readEnv);
      for (var i = 0; i < taskCount; i++) {
        cond.firstUnmetIn(await env.value, now: DateTime.now());
      }
      sw.stop();
      observedReads = env.readCount;
      if (sw.elapsedMilliseconds < roundMs) roundMs = sw.elapsedMilliseconds;
    }
    report('条件评估 $taskCount 任务**每轮复用**（改造后）', roundMs, 500);

    debugPrint('[NFR-AOT]   → 逐任务 ${perTaskMs}ms → 每轮复用 ${roundMs}ms'
        '（同一轮 $taskCount 个任务；本轮实际平台读取 $observedReads 次）');

    expect(observedReads, 1,
        reason: '一轮 $taskCount 个任务只应读 1 次平台环境，实测 $observedReads 次');
    expect(roundMs, lessThanOrEqualTo(500),
        reason: '每轮复用实测 ${roundMs}ms（应与任务数解耦）');
  });
}
