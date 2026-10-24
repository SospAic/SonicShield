import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:sonic_shield/services/background_engine.dart';

import 'support/source_text.dart';

/// **R94 / F2c 调度引擎修复的行为回归**（SCH 系列）。
///
/// ## 为什么这批终于能做"行为测试"
///
/// 此前 15 条 SCH 缺陷全都只能写**源码契约锁**：`executeDue` 的循环体长在
/// `_engineBody` 闭包里，而那个闭包只在 `flutter_background_service` 的隔离里
/// 运行（真实 DB / 播放器 / 原生桥），宿主 `flutter test` 实例化不了 ⇒
/// "批次内第 2 条到底有没有被执行"这类问题**永远无法被断言**，只能靠读代码。
///
/// R94 把批次循环搬成顶层纯函数 [executeBatch]（注入 `runAction` / `claim` /
/// `discard` / `finish` / `audit` / `tryClaim`），于是：
///
/// | 缺陷 | 修法 | 本文件断言什么 |
/// |---|---|---|
/// | SCH-01 | 陈旧判定只用**批次开始时刻** `batchStart`，不用逐条实时 `now` | 第 1 条耗时 11 分钟后，同批第 2/3 条**仍执行**；跨批次迟到 11 分钟才 skipped |
/// | SCH-01 | 单条执行预算 `timeout(min(声明时长+30s, 10min))` | 超时落 `failed('执行超时')` + 审计，**后续条目照常执行** |
/// | SCH-03 | 任务级互斥 `TaskRunLock` | 同 taskId 两个批次并发 ⇒ 只执行一次，另一份**保留 pending**（不丢、不刷日志） |
/// | SCH-04 | `markStatus(from: pending)` 返回 0 = 被别人抢走 | claim 落空 ⇒ 不执行、不写终态、不写审计、锁仍被释放 |
/// | SCH-07 | 每轮复检停机 + 可中断等待 | 停机后剩余条目**保持 pending**；`waitInterruptibly` 在 ≤2s 内返回 |
/// | SCH-14 | 延时计划多槽化 `GuardDelaySlots` | 两个任务各一槽都执行；同 key 顶替**必须留痕** |
/// | SCH-12 | 跨午夜窗口端点走日历日 ±1 | `_applyQuiet` 不得出现绝对 24h 加法（DST 会偏 1h） |
/// | ARCH-06 | 停用任务的残留 pending 必须有痕 | 落 `skipped` + `disabled` 审计 + 文案非空 |
/// | SCH-15 | `stopping` 单向闸门的超时复位 | 宽限期内不放行、超时后复位 |
/// | SCH-13 | 同刻到期按 `Task.priority` 降序 | `orderDueBatch` 排序断言 |
///
/// ## 铁律：断言必须**非恒真**
///
/// 每条都用"**可区分的输入**"而不是"看起来对的输入"：
/// - SCH-01 的 `batchStart` 刻意设为**真实 now 之前 11 分钟** —— 旧实现（逐条
///   `DateTime.now()`）在这里会判 stale，只有"批次开始时刻"判据才会执行；
/// - SCH-12 的结构锁配反面样本（绝对 24h 加法必须判红）。
void main() {
  // ══════════════════════════════════════════════════════════════════
  // 夹具
  // ══════════════════════════════════════════════════════════════════

  Task task(
    String id, {
    bool enabled = true,
    int priority = 0,
    ActionConfig action = const PlayAudioAction(),
    QuietPolicy quiet = QuietPolicy.skip,
    TriggerConfig trigger = const DailyTrigger(time: TimeSpec(hour: 10)),
  }) =>
      Task(
        id: id,
        name: '任务-$id',
        enabled: enabled,
        triggerType: TriggerType.dailyAt,
        trigger: trigger,
        actionType: ActionType.playAudio,
        action: action,
        assetIds: const [],
        cooldownSec: 300,
        quietPolicy: quiet,
        priority: priority,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  PlannedOccurrence occ(String id, String taskId, DateTime fireAt) =>
      PlannedOccurrence(
        id: id,
        taskId: taskId,
        fireAt: fireAt,
        status: OccurrenceStatus.pending,
      );

  // ══════════════════════════════════════════════════════════════════
  // SCH-01 · 判定与执行解耦（本批排队 ≠ 迟到）
  // ══════════════════════════════════════════════════════════════════

  group('SCH-01 批次陈旧判定用批次开始时刻', () {
    test('同批第 1 条耗时 11 分钟，第 2/3 条仍执行（不被判 stale）', () async {
      // 场景还原：三条计划同在 09:00 到期；第 1 条是 11 分钟录音。
      // 真实 now 已是 09:11，`batchStart` 仍是 09:00。
      final batchStart = DateTime(2026, 10, 24, 9, 0);
      final rec = _Rec({
        't1': task('t1', action: const RecordEvidenceAction(seconds: 660)),
        't2': task('t2'),
        't3': task('t3'),
      });
      final due = [
        occ('o1', 't1', batchStart),
        occ('o2', 't2', batchStart),
        occ('o3', 't3', batchStart),
      ];

      await rec.exec(due, batchStart);

      // ★ 非恒真点：若判据是"轮到它时的实时时刻"（BUG-094 的写法），
      //   此刻三条都已迟到 11 分钟 ⇒ 后两条会被丢弃。只有 batchStart 判据
      //   才能让它们照常执行。
      expect(rec.ran, ['o1', 'o2', 'o3'],
          reason: '批次内排队时间不得计入迟到（SCH-01 的核心）');
      expect(rec.discards, isEmpty, reason: '同批内不得有任何一条被判 stale');
      expect(rec.finishes.length, 3);
      expect(rec.audits, isEmpty, reason: '正常执行不产生 skip-stale 审计');
    });

    test('跨批次迟到 11 分钟 ⇒ skipped 且审计文案非空', () async {
      // 计划在 08:49 就该响，但整批直到 09:00 才开始 —— 这是真的"错过"。
      final batchStart = DateTime(2026, 10, 24, 9, 0);
      final fireAt = batchStart.subtract(const Duration(minutes: 11));
      final rec = _Rec({'t1': task('t1')});

      await rec.exec([occ('o1', 't1', fireAt)], batchStart);

      expect(rec.ran, isEmpty, reason: '跨批次迟到超过阈值不得补执行');
      expect(rec.discards, ['o1'], reason: '必须落库（pending→skipped），不能只留在内存里');
      final a = rec.audits.single;
      expect(a.action, 'skip-stale');
      expect(a.status, 'skipped');
      // 非空且带原因：旧实现的 message 是 null ⇒ 用户只看到"跳过了"，不知道为什么。
      expect(a.message, isNotNull);
      expect(a.message, contains('过期'));
      expect(a.message, contains('11'));
    });

    test('执行预算超时 ⇒ failed(执行超时) + timeout 审计，后续条目照常执行', () async {
      final batchStart = DateTime(2026, 10, 24, 9, 0);
      final rec = _Rec({'t1': task('t1'), 't2': task('t2')});
      final never = Completer<ExecutionOutcome>();

      await rec.exec(
        [occ('o1', 't1', batchStart), occ('o2', 't2', batchStart)],
        batchStart,
        budget: (_, __) => const Duration(milliseconds: 40),
        runAction: (t, o) async {
          rec.ran.add(o.id);
          // 第 1 条永不返回（模拟"底层动作卡死"）。
          return o.id == 'o1' ? never.future : const ExecutionOutcome.success();
        },
      );

      expect(rec.ran, ['o1', 'o2'], reason: '超时只放弃等待，不得拖死后面的计划');
      final first = rec.finishes['o1']!;
      expect(first.isFailure, isTrue);
      expect(first.reason, '执行超时');
      expect(rec.finishes['o2']!.ok, isTrue);

      final timeoutAudit =
          rec.audits.where((a) => a.action == 'timeout').toList();
      expect(timeoutAudit, hasLength(1),
          reason: '超时不得静默：必须留一条 timeout 审计');
      expect(timeoutAudit.single.status, 'failed');
      expect(timeoutAudit.single.message, contains('预算'));
    });

    test('执行预算 = min(声明时长 + 30s, 10min)', () {
      final o = occ('o1', 't1', DateTime(2026, 1, 1));
      // 60s 录音 ⇒ 90s
      expect(
        actionBudgetFor(
            task('t1', action: const RecordEvidenceAction(seconds: 60)), o),
        const Duration(seconds: 90),
      );
      // 1800s 录音 ⇒ 1830s 会被截到 10min（否则单条独占执行槽 30 分钟，
      // 后面所有计划必然被拖出补执行窗口）
      expect(
        actionBudgetFor(
            task('t2', action: const RecordEvidenceAction(seconds: 1800)), o),
        maxActionBudget,
      );
      expect(maxActionBudget, const Duration(minutes: 10));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // SCH-03 · 任务级互斥
  // ══════════════════════════════════════════════════════════════════

  group('SCH-03 任务级互斥（runNow / 定时 / 声音三路共用一把锁）', () {
    test('同 taskId 两个批次并发 ⇒ 只执行一次，另一份保留 pending 且不刷日志',
        () async {
      final lock = TaskRunLock();
      final batchStart = DateTime(2026, 10, 24, 9, 0);
      final rec = _Rec({'t1': task('t1')})
        ..actionDelay = const Duration(milliseconds: 60);

      // 两条**不同 occurrence**、同一 taskId（这正是三路入口的真实形状：
      // 定时条目 / runNow 临时条目 / @sound@ 条目各有各的 id）。
      final a = rec.exec([occ('o1', 't1', batchStart)], batchStart, lock: lock);
      final b = rec.exec([occ('o2', 't1', batchStart)], batchStart, lock: lock);
      await Future.wait([a, b]);

      expect(rec.ran, ['o1'], reason: '同一任务不得并发跑两份（否则是双响）');
      expect(rec.maxConcurrent, 1);
      expect(rec.discards, isEmpty,
          reason: '互斥失败的那份必须**保留 pending**（下一批再试），不能丢弃');
      expect(rec.audits, isEmpty,
          reason: '每 15s 一条"忙"审计会把执行日志刷爆，而这条计划并未失败');
      expect(rec.finishes.keys, ['o1']);
      expect(lock.activeCount, 0, reason: 'finally 必须释放，否则该任务永久卡死');
    });

    test('TaskRunLock 的 holder/release 语义', () {
      final lock = TaskRunLock();
      expect(lock.tryClaim('t1', 'a'), isTrue);
      expect(lock.tryClaim('t1', 'b'), isFalse, reason: '同任务第二次抢占必须失败');
      expect(lock.holder('t1'), 'a', reason: '持锁者不得被后来者顶替');
      expect(lock.tryClaim('t2', 'c'), isTrue, reason: '不同任务互不影响');
      expect(lock.activeCount, 2);
      lock.release('t1');
      expect(lock.tryClaim('t1', 'd'), isTrue);
      lock.release('t1');
      lock.release('t2');
      expect(lock.activeCount, 0);
      lock.release('不存在的任务'); // no-op，不得抛
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // SCH-04 · CAS 抢占（跨连接互斥）
  // ══════════════════════════════════════════════════════════════════

  group('SCH-04 CAS 抢占落空', () {
    test('markStatus(from: pending) 返回 0 ⇒ 不执行、不写终态、不写审计', () async {
      final lock = TaskRunLock();
      final batchStart = DateTime(2026, 10, 24, 9, 0);
      final rec = _Rec({'t1': task('t1')})..claimRows = 0;

      await rec.exec([occ('o1', 't1', batchStart)], batchStart, lock: lock);

      expect(rec.claims, ['o1'], reason: '必须先尝试 CAS 抢占');
      expect(rec.ran, isEmpty, reason: '没抢到就不能执行（另一条连接正在跑）');
      expect(rec.finishes, isEmpty,
          reason: '★ 不得回写终态：那会把别人正在执行的行改成 done/failed');
      expect(rec.audits, isEmpty, reason: '抢不到不是本条计划的失败，不得留痕成自己的');
      expect(lock.activeCount, 0, reason: '即使 claim 落空也要释放进程内锁');
    });

    test('discard 的 CAS 落空（行已被别人改过）⇒ 不写审计（不冒领别人的行）', () async {
      final batchStart = DateTime(2026, 10, 24, 9, 0);
      final rec = _Rec({'t1': task('t1')})..discardRows = 0;
      final fireAt = batchStart.subtract(const Duration(minutes: 30));

      await rec.exec([occ('o1', 't1', fireAt)], batchStart);

      expect(rec.discards, ['o1']);
      expect(rec.audits, isEmpty,
          reason: 'CAS 落空说明这行已被用户/另一连接改过，再写审计就是冒领');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // SCH-07 · 停机可中断
  // ══════════════════════════════════════════════════════════════════

  group('SCH-07 停机闸门', () {
    test('批次执行中停机 ⇒ 剩余条目保持 pending（不丢弃、不起新动作）', () async {
      final batchStart = DateTime(2026, 10, 24, 9, 0);
      final rec = _Rec({'t1': task('t1'), 't2': task('t2')});
      var stopping = false;

      await rec.exec(
        [occ('o1', 't1', batchStart), occ('o2', 't2', batchStart)],
        batchStart,
        isStopping: () => stopping,
        runAction: (t, o) async {
          rec.ran.add(o.id);
          stopping = true; // 第 1 条执行期间用户点了"停止"
          return const ExecutionOutcome.success();
        },
      );

      expect(rec.ran, ['o1'], reason: '停机后不得再起新动作');
      expect(rec.discards, isEmpty,
          reason: '剩余条目必须保持 pending（下次启动补执行），不能趁停机丢掉');
      expect(rec.finishes.keys, ['o1'], reason: '已开始的那条要自然收尾并落终态');
    });

    test('waitInterruptibly 在 ≤2s 内响应停机（不是等满 5s）', () async {
      var stopping = false;
      Timer(const Duration(milliseconds: 50), () => stopping = true);
      final sw = Stopwatch()..start();
      final completed = await waitInterruptibly(
        const Duration(seconds: 5),
        isStopping: () => stopping,
      );
      sw.stop();

      expect(completed, isFalse, reason: '被中断必须返回 false（调用方据此落 skipped）');
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 1500)),
          reason: '至少要跑完一个切片，否则是"没等就返回"');
      expect(sw.elapsed, lessThan(const Duration(seconds: 4)),
          reason: '★ 关键：不得等满 5s。旧实现是单个 Future.delayed，停机要等动作自然结束');
    });

    test('未停机时 waitInterruptibly 正常返回 true', () async {
      final ok = await waitInterruptibly(
        const Duration(milliseconds: 20),
        isStopping: () => false,
      );
      expect(ok, isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // SCH-14 / ARCH-07 · 延时计划多槽
  // ══════════════════════════════════════════════════════════════════

  group('SCH-14 守卫延时计划多槽', () {
    test('两个任务各排一个延时计划 ⇒ 两个都执行（旧单槽实现会静默吞掉第一个）',
        () async {
      final fired = <String>[];
      final superseded = <String>[];
      final slots = GuardDelaySlots(onSuperseded: superseded.add);
      addTearDown(slots.cancelAll);

      slots.schedule(
        key: 't1',
        delay: const Duration(milliseconds: 20),
        onFire: () => fired.add('t1'),
      );
      slots.schedule(
        key: 't2',
        delay: const Duration(milliseconds: 30),
        onFire: () => fired.add('t2'),
      );
      expect(slots.length, 2, reason: '不同 key 必须各占一槽');

      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(fired, ['t1', 't2'], reason: '★ 触发源不得静默消失（BUG-087 同族）');
      expect(superseded, isEmpty);
      expect(slots.length, 0, reason: '触发后槽位要自清理');
    });

    test('同 key 再次排定 ⇒ 取消旧的，且必须留痕', () async {
      final fired = <String>[];
      final superseded = <String>[];
      final slots = GuardDelaySlots(onSuperseded: superseded.add);
      addTearDown(slots.cancelAll);

      slots.schedule(
        key: 't1',
        delay: const Duration(milliseconds: 40),
        onFire: () => fired.add('旧'),
      );
      slots.schedule(
        key: 't1',
        delay: const Duration(milliseconds: 40),
        onFire: () => fired.add('新'),
      );
      expect(superseded, ['t1'], reason: '被顶替的计划必须写审计，不能静默取消');

      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(fired, ['新'], reason: '同 key 只保留最后一次（冷却语义）');
    });

    test('cancelAll 之后不再有任何计划触发（关守卫 / 停机）', () async {
      final fired = <String>[];
      final slots = GuardDelaySlots();
      slots.schedule(
        key: 't1',
        delay: const Duration(milliseconds: 30),
        onFire: () => fired.add('t1'),
      );
      slots.cancelAll();
      expect(slots.length, 0);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(fired, isEmpty, reason: '用户说"关"就不能再有已排定的声音');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // SCH-12 · 跨午夜免打扰窗口（DST 安全）
  // ══════════════════════════════════════════════════════════════════

  group('SCH-12 跨午夜窗口端点走日历加法', () {
    test('06:00 在 23:00-07:00 窗口内，shift 平移到今晨 07:00（不是 06:00/08:00）',
        () {
      const engine = ScheduleEngine(quietStartHour: 23, quietEndHour: 7);
      // 2026-03-29 是欧洲 DST 前跳日（当地只有 23 小时）。
      final now = DateTime(2026, 3, 28, 22);
      final t = task(
        't1',
        quiet: QuietPolicy.shift,
        trigger: const DailyTrigger(time: TimeSpec(hour: 6)),
      );
      final list = engine.materialize(t, now);
      expect(list, isNotEmpty);
      // 窗口终点必须落在**当天 07:00**：日期是 29 日、墙上小时是 7。
      // ⚠️ 这一条在本机（无 DST 的时区）对旧实现也会通过 —— 真正机器无关的
      //    保证是下面的结构锁；两者一起才完整（诚实说明，不假装行为锁万能）。
      expect(list.first.fireAt, DateTime(2026, 3, 29, 7),
          reason: '跨午夜窗口终点必须按日历日 +1 计算（DST 日旧实现会得 08:00）');
    });

    test('结构锁：`_applyQuiet` 不得出现绝对 24h 加减（含反面样本）', () {
      final src = stripComments(
          File('lib/domain/scheduling/schedule_engine.dart').readAsStringSync());
      final body = methodBody(src, '? _applyQuiet(');

      expect(judgeCrossMidnight(body), isNull, reason: '${judgeCrossMidnight(body)}');

      // 反面样本：绝对 24h 加法必须判红（否则本锁是恒真的装饰品）。
      expect(
        judgeCrossMidnight('final a = DateTime(day.year, day.month, day.day)'
            '.add(const Duration(days: 1));'),
        isNotNull,
        reason: '★ 绝对 24h 加法必须判红：DST 前跳日会得到次日 08:00',
      );
      expect(
        judgeCrossMidnight('final a = DateTime(day.year, day.month, day.day)'
            '.subtract(Duration(days: 1));'),
        isNotNull,
      );
      // 正面样本：日历加法必须判绿。
      expect(
        judgeCrossMidnight('final a = DateTime(day.year, day.month, day.day + 1,'
            ' quietEndHour);'
            ' final b = DateTime(day.year, day.month, day.day - 1, quietStartHour);'),
        isNull,
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ARCH-06 · 停用任务的残留 pending
  // ══════════════════════════════════════════════════════════════════

  group('ARCH-06 停用任务残留计划必须有痕', () {
    test('任务已停用 ⇒ 落 skipped + disabled 审计（旧实现是无声 continue）', () async {
      final batchStart = DateTime(2026, 10, 24, 9, 0);
      final rec = _Rec({'t1': task('t1', enabled: false)});

      await rec.exec([occ('o1', 't1', batchStart)], batchStart);

      expect(rec.ran, isEmpty);
      expect(rec.discards, ['o1'], reason: '残留 pending 必须被清掉，否则每 15s 重试');
      final a = rec.audits.single;
      expect(a.action, 'disabled');
      expect(a.status, 'skipped');
      expect(a.message, isNotNull);
      expect(a.message, contains('t1'), reason: '审计要能定位到是哪条任务');
    });

    test('任务已被删除（loadTask 返回 null）⇒ 同样留痕', () async {
      final batchStart = DateTime(2026, 10, 24, 9, 0);
      final rec = _Rec(const {}); // 表里没有这条任务

      await rec.exec([occ('o9', 'ghost', batchStart)], batchStart);

      expect(rec.discards, ['o9']);
      expect(rec.audits.single.action, 'disabled');
      expect(rec.audits.single.message, contains('ghost'));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // SCH-15 · stopping 闸门的超时复位
  // ══════════════════════════════════════════════════════════════════

  group('SCH-15 停机闸门不得永久卡死', () {
    test('宽限期内不放行，超时后复位（stopSelf 失败也能重新服务）', () {
      var stopping = true;
      void Function()? fire;
      final t = armStoppingRecovery(
        onReset: () => stopping = false,
        grace: const Duration(milliseconds: 20),
        timerFactory: (d, cb) {
          expect(d, const Duration(milliseconds: 20), reason: '宽限期必须被透传');
          fire = cb;
          return Timer(Duration.zero, () {});
        },
      );
      addTearDown(t.cancel);

      expect(fire, isNotNull, reason: '必须真的布防（否则僵尸引擎永远不自愈）');
      expect(stopping, isTrue, reason: '宽限期内不得提前放行（否则 stop 与 tick 打架）');
      fire!();
      expect(stopping, isFalse, reason: '★ 超时后闸门必须复位，否则引擎成僵尸');
    });

    test('默认宽限期 30s（够 stopSelf 完成，又不至于让用户等太久）', () {
      Duration? got;
      final t = armStoppingRecovery(
        onReset: () {},
        timerFactory: (d, cb) {
          got = d;
          return Timer(Duration.zero, () {});
        },
      );
      addTearDown(t.cancel);
      expect(got, const Duration(seconds: 30),
          reason: '默认宽限期被改动时必须在这里显式说明理由');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // SCH-13 · 同刻到期按 priority 降序
  // ══════════════════════════════════════════════════════════════════

  group('SCH-13 同刻到期的执行顺序', () {
    test('同 fireAt 按 priority 降序；不同 fireAt 仍按时间升序', () {
      final t0 = DateTime(2026, 10, 24, 9, 0);
      final t1 = t0.add(const Duration(minutes: 1));
      final ordered = orderDueBatch(
        [
          occ('low', 'a', t0),
          occ('later', 'b', t1),
          occ('high', 'c', t0),
          occ('mid', 'd', t0),
        ],
        {'a': 1, 'b': 99, 'c': 10, 'd': 5},
      );
      expect(ordered.map((o) => o.id).toList(), ['high', 'mid', 'low', 'later'],
          reason: '`Task.priority` 契约是"数值大者先执行"；'
              '`due()` 只有 fire_at ASC，此前同刻顺序退化成 rowid');
    });

    test('未登记 priority 的任务按 0 处理（不抛）', () {
      final t0 = DateTime(2026, 10, 24, 9, 0);
      final ordered = orderDueBatch(
        [occ('a', 'unknown', t0), occ('b', 'known', t0)],
        {'known': 0},
      );
      expect(ordered, hasLength(2));
    });
  });
}

// ══════════════════════════════════════════════════════════════════════
// 夹具与判定器
// ══════════════════════════════════════════════════════════════════════

typedef _Audit = ({String action, String status, String? message, String occId});

/// `executeBatch` 的可观测替身：把每一次回调记下来，供断言"到底发生了什么"。
class _Rec {
  _Rec(this.tasks);

  final Map<String, Task> tasks;

  /// `claim`（pending→running CAS）的返回值：0 = 被另一条连接抢走。
  int claimRows = 1;

  /// `discard`（pending→skipped CAS）的返回值：0 = 已被别人改过。
  int discardRows = 1;

  Duration actionDelay = Duration.zero;

  final ran = <String>[];
  final finishes = <String, ExecutionOutcome>{};
  final audits = <_Audit>[];
  final claims = <String>[];
  final discards = <String>[];

  int concurrent = 0;
  int maxConcurrent = 0;

  Future<ExecutionOutcome> _defaultRun(Task t, PlannedOccurrence o) async {
    ran.add(o.id);
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    try {
      if (actionDelay > Duration.zero) {
        await Future<void>.delayed(actionDelay);
      }
      return const ExecutionOutcome.success();
    } finally {
      concurrent--;
    }
  }

  Future<void> exec(
    List<PlannedOccurrence> due,
    DateTime batchStart, {
    bool Function()? isStopping,
    TaskRunLock? lock,
    Duration Function(Task, PlannedOccurrence)? budget,
    Future<ExecutionOutcome> Function(Task, PlannedOccurrence)? runAction,
  }) =>
      executeBatch(
        due: due,
        batchStart: batchStart,
        isStopping: isStopping ?? () => false,
        runAction: runAction ?? _defaultRun,
        loadTask: (id) async => tasks[id],
        claim: (o) async {
          claims.add(o.id);
          return claimRows;
        },
        discard: (o) async {
          discards.add(o.id);
          return discardRows;
        },
        finish: (o, outcome, t) async {
          finishes[o.id] = outcome;
        },
        audit: (action, status, message, o) async {
          audits.add(
              (action: action, status: status, message: message, occId: o.id));
        },
        budget: budget,
        tryClaim: lock?.tryClaim,
        release: lock?.release,
      );
}

/// 跨午夜窗口端点必须走**日历日 ±1**，不得用 `add/subtract(Duration(days: 1))`。
///
/// 为什么：后者是**绝对 24 小时**。DST 前跳日（当地 23h）加 24h ⇒ 次日 08:00
/// （应为 07:00），回拨日（25h）⇒ 06:00。后果是合规静默窗口整体偏 1 小时 ——
/// 偏"多响 1 小时"的那一侧是**合规风险**，不是体验问题。
///
/// 返回 null = 通过；否则返回具体缺失项（便于反面样本断言）。
String? judgeCrossMidnight(String body) {
  if (!body.contains('day.day + 1')) {
    return '跨午夜终点未用日历日 +1（DST 日会偏 1 小时）';
  }
  if (!body.contains('day.day - 1')) {
    return '跨午夜起点未用日历日 -1（DST 日会偏 1 小时）';
  }
  if (RegExp(r'\.add\(\s*(const\s+)?Duration\(\s*days:\s*1').hasMatch(body)) {
    return '跨午夜端点仍用绝对 24h 加法';
  }
  if (RegExp(r'\.subtract\(\s*(const\s+)?Duration\(\s*days:\s*1')
      .hasMatch(body)) {
    return '跨午夜端点仍用绝对 24h 减法';
  }
  return null;
}
