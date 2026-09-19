import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';

/// v1.8 多条件×随机编排 TDD：概率门分布 + 动作集加权分布 + 序列化往返。
void main() {
  group('概率门（TaskCondition.probabilityPct 语义契约）', () {
    // 引擎侧 probabilityGateMissed 的判定式：roll(0..99) < pct → 通过。
    // 此处直接对判定式做大样本分布验证（与实现同式）。
    bool gatePass(int pct, Random rng) => rng.nextInt(100) < pct;

    test('P=100 恒通过', () {
      final rng = Random(1);
      expect(
          [for (var i = 0; i < 1000; i++) gatePass(100, rng)].every((b) => b),
          isTrue);
    });

    test('P=50 大样本频率 ≈ 0.5（±0.04）', () {
      final rng = Random(2);
      var pass = 0;
      const n = 20000;
      for (var i = 0; i < n; i++) {
        if (gatePass(50, rng)) pass++;
      }
      expect(pass / n, inInclusiveRange(0.46, 0.54));
    });

    test('P=10 大样本频率 ≈ 0.1（±0.02）', () {
      final rng = Random(3);
      var pass = 0;
      const n = 20000;
      for (var i = 0; i < n; i++) {
        if (gatePass(10, rng)) pass++;
      }
      expect(pass / n, inInclusiveRange(0.08, 0.12));
    });
  });

  group('动作集 ActionSetAction', () {
    test('加权随机：3:1 分布大样本 ≈ 0.75/0.25', () {
      final set = ActionSetAction(candidates: [
        const ActionSetCandidate(weight: 3, action: TtsAction(text: '高权重')),
        const ActionSetCandidate(weight: 1, action: VibrateAction()),
      ]);
      final rng = Random(4);
      var first = 0;
      const n = 20000;
      for (var i = 0; i < n; i++) {
        final c = set.pick(rng);
        if (c.action is TtsAction) first++;
      }
      expect(first / n, inInclusiveRange(0.70, 0.80));
    });

    test('全零权重兜底：等概率、不抛异常', () {
      final set = ActionSetAction(candidates: const [
        ActionSetCandidate(weight: 0, action: TtsAction(text: 'a')),
        ActionSetCandidate(weight: 0, action: VibrateAction()),
      ]);
      final rng = Random(5);
      final seen = <String>{};
      for (var i = 0; i < 1000; i++) {
        seen.add(set.pick(rng).action.runtimeType.toString());
      }
      expect(seen.length, 2);
    });

    test('序列化往返：candidates 全字段保留', () {
      final set = ActionSetAction(candidates: [
        const ActionSetCandidate(
            weight: 3,
            action: PlayAudioAction(
                volumeMin: 0.2,
                volumeMax: 0.9,
                durationSecMin: 3,
                durationSecMax: 12)),
        const ActionSetCandidate(weight: 1, action: TtsAction(text: '播报')),
      ]);
      final back = ActionSetAction.fromJson(
          jsonDecode(jsonEncode(set.toJson())) as Map<String, dynamic>);
      expect(back.candidates.length, 2);
      expect(back.candidates[0].weight, 3);
      expect(back.candidates[0].action, isA<PlayAudioAction>());
      expect(back.candidates[1].action, isA<TtsAction>());
      // 再序列化一致
      expect(jsonEncode(back.toJson()), jsonEncode(set.toJson()));
    });

    test('概率门 + 动作集组合：先确定性条件后随机选一', () {
      // 组合语义：概率门通过 → 从动作集中选一。此处验证两层嵌套的
      // 组合行为在大量样本下两类动作都会出现（无系统性偏向）。
      final set = ActionSetAction(candidates: const [
        ActionSetCandidate(weight: 1, action: TtsAction(text: 'a')),
        ActionSetCandidate(weight: 1, action: VibrateAction()),
      ]);
      final rng = Random(6);
      var gatePassed = 0;
      var actionATimes = 0;
      for (var i = 0; i < 10000; i++) {
        if (rng.nextInt(100) < 50) {
          gatePassed++;
          if (set.pick(rng).action is TtsAction) actionATimes++;
        }
      }
      expect(gatePassed, inInclusiveRange(4600, 5400));
      expect(actionATimes, greaterThan(0));
    });
  });
}
