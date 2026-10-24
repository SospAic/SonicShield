import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/scheduling/guard_orchestration.dart';

/// 守卫声音编排（v1.10）的纯函数回归锁。
///
/// 这一组锁的**全部价值**在于：`resolveGuardPlan` 是纯函数，所以
/// "多选 / 随机 / 延时" 三件事可以在宿主机上**穷举断言 + 变异证伪**，
/// 不需要真机、不需要引擎隔离。
///
/// 与既有能力的分工（见 `guard_orchestration.dart` 的对照表）：
/// - 音频/动作的**内容**多选与随机由 `Task.assetIds` + `ActionSetAction` 负责，
///   本文件**不**重复实现，也不断言它们；
/// - 本文件只锁"用哪几个任务、挑几个、等多久"。
void main() {
  // ---------- 候选过滤 ----------

  test('GOP-01 taskIds 为空 = 全部候选（升级前行为，向后兼容）', () {
    final plan = resolveGuardPlan(
      candidateIds: const ['a', 'b', 'c'],
      config: const GuardOrchestration(),
      rng: math.Random(1),
    );
    expect(plan.taskIds, ['a', 'b', 'c']);
    expect(plan.delayMs, 0);
  });

  test('GOP-02 点名子集 -> 只保留交集，且保持候选顺序', () {
    final plan = resolveGuardPlan(
      candidateIds: const ['a', 'b', 'c'],
      config: const GuardOrchestration(taskIds: ['c', 'a']),
      rng: math.Random(1),
    );
    // 顺序按**候选**（即调度顺序），不按用户点选的先后 —— 否则"计划即审计"
    // 里的顺序会随 UI 点击顺序漂移。
    expect(plan.taskIds, ['a', 'c']);
  });

  test('GOP-03 点名了却一条都不在候选里 -> 空计划（绝不退回"随便挑一条"）', () {
    final plan = resolveGuardPlan(
      candidateIds: const ['a', 'b'],
      config: const GuardOrchestration(taskIds: ['zzz']),
      rng: math.Random(1),
    );
    expect(plan.taskIds, isEmpty,
        reason: 'BUG-059 判据：点名了就必须满足，满足不了要失败并留痕，'
            '不能让用户听到一段自己没配过的声音');
  });

  test('GOP-04 空候选 -> 空计划（不抛异常）', () {
    final plan = resolveGuardPlan(
      candidateIds: const [],
      config: const GuardOrchestration(taskIds: ['a']),
      rng: math.Random(1),
    );
    expect(plan.isEmpty, isTrue);
  });

  // ---------- 随机 ----------

  test('GOP-05 randomOne -> 恰好一个，且必属候选', () {
    final rng = math.Random(7);
    final seen = <String>{};
    for (var i = 0; i < 300; i++) {
      final plan = resolveGuardPlan(
        candidateIds: const ['a', 'b', 'c'],
        config: const GuardOrchestration(pick: GuardPickMode.randomOne),
        rng: rng,
      );
      expect(plan.taskIds.length, 1);
      expect(const ['a', 'b', 'c'].contains(plan.taskIds.single), isTrue);
      seen.add(plan.taskIds.single);
    }
    // 300 次只出现一个候选 ⇒ 不是随机，是固定选了第一个（变异证伪的靶子）。
    expect(seen.length, 3,
        reason: '300 次抽样只覆盖 ${seen.length} 个候选，随机选择可疑');
  });

  test('GOP-06 randomOne 的分布无明显偏斜（等概率）', () {
    final rng = math.Random(42);
    final counts = <String, int>{'a': 0, 'b': 0, 'c': 0};
    const n = 6000;
    for (var i = 0; i < n; i++) {
      final plan = resolveGuardPlan(
        candidateIds: const ['a', 'b', 'c'],
        config: const GuardOrchestration(pick: GuardPickMode.randomOne),
        rng: rng,
      );
      counts[plan.taskIds.single] = counts[plan.taskIds.single]! + 1;
    }
    for (final e in counts.entries) {
      final f = e.value / n;
      expect(f, greaterThan(0.29), reason: '${e.key} 频率 $f 偏低');
      expect(f, lessThan(0.38), reason: '${e.key} 频率 $f 偏高');
    }
  });

  test('GOP-07 all 模式必须确定性（不得偷偷随机）', () {
    final a = resolveGuardPlan(
      candidateIds: const ['a', 'b', 'c'],
      config: const GuardOrchestration(pick: GuardPickMode.all),
      rng: math.Random(1),
    );
    final b = resolveGuardPlan(
      candidateIds: const ['a', 'b', 'c'],
      config: const GuardOrchestration(pick: GuardPickMode.all),
      rng: math.Random(999),
    );
    expect(a.taskIds, b.taskIds);
    expect(a.taskIds.length, 3);
  });

  // ---------- 延时 ----------

  test('GOP-08 delaySec 换算成毫秒并夹紧到 0..600', () {
    int ms(int sec) => resolveGuardPlan(
          candidateIds: const ['a'],
          config: GuardOrchestration(delaySec: sec),
          rng: math.Random(1),
        ).delayMs;
    expect(ms(0), 0);
    expect(ms(30), 30000);
    expect(ms(600), 600000);
    // 越界值夹紧（模型层容错，UI 滑条之外还有 kv 被改坏的可能）。
    expect(ms(99999), 600000);
    expect(ms(-5), 0);
  });

  test('GOP-09 fromJson 把越界 delaySec 也夹紧', () {
    final o = GuardOrchestration.fromJson({'delaySec': 999999});
    expect(o.delaySec, GuardOrchestration.maxDelaySec);
    expect(GuardOrchestration.fromJson({'delaySec': -1}).delaySec, 0);
  });

  // ---------- 序列化 / 容错 ----------

  test('GOP-10 序列化往返全字段保留', () {
    const o = GuardOrchestration(
      taskIds: ['t1', 't2'],
      pick: GuardPickMode.randomOne,
      delaySec: 45,
    );
    final back = GuardOrchestration.decode(o.encode());
    expect(back.taskIds, o.taskIds);
    expect(back.pick, o.pick);
    expect(back.delaySec, o.delaySec);
  });

  test('GOP-11 坏 JSON / 空值 -> 退回默认编排（守卫不能因配置损坏而停摆）', () {
    for (final raw in <String?>[null, '', '{', '[]', '{"pick":123}']) {
      final o = GuardOrchestration.decode(raw);
      expect(o.isDefault, isTrue, reason: 'raw=$raw 应退回默认编排');
    }
  });

  test('GOP-12 未知 pick 值 -> all（老配置的唯一语义）', () {
    expect(guardPickModeOf('nonsense'), GuardPickMode.all);
    expect(guardPickModeOf(null), GuardPickMode.all);
    expect(guardPickModeOf('randomOne'), GuardPickMode.randomOne);
  });

  test('GOP-13 taskIds 里的非字符串/空串被丢弃（kv 可能被外部改坏）', () {
    final o = GuardOrchestration.fromJson({
      'taskIds': ['a', 1, null, '', 'b'],
    });
    expect(o.taskIds, ['a', 'b']);
  });
}
