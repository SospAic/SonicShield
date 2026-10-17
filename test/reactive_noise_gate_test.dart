import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';

/// 「守护反击不出 TTS」的纯逻辑锁（2026-10 产品决策）。
///
/// 背景：可识别语音会暴露反击意图、取证价值低，与「不可预测」目标相反。
/// 契约变化（显式作废旧行为）：
/// - 出厂 TTS 文案池清空（`CounterPlan.defaultTtsTexts` 恒为空）；
/// - 物化器**忽略** `plan.ttsTexts`，绝不生成 `TtsAction`；
/// - 动作由窗口配比决定：**震动 / 音效** 两类（无音源时只剩震动）。
void main() {
  group('RCT-TTS 弃用：反击动作不出 TTS', () {
    test('RCT-01 出厂 TTS 文案池恒为空', () {
      expect(CounterPlan.defaultTtsTexts, isEmpty,
          reason: '出厂不应再带 TTS 文案池；字段保留仅为兼容旧 JSON');
    });

    test('RCT-02 导入的旧 plan 带 ttsTexts ⇒ 物化全部忽略，绝不出 TtsAction', () {
      const plan = CounterPlan(
        presetIds: ['annoy_cough_fit'],
        ttsTexts: ['干啥呢？', '小点声行不行？'], // 旧 JSON 兼容输入
        workdayDay: CounterWindow(
            volumeMin: 0.5, volumeMax: 0.8, durationSecMin: 3, durationSecMax: 8),
      );
      final tasks = CounterPlanMaterializer.materialize(
        plan,
        planId: 'p',
        from: DateTime(2026, 3, 10),
        days: 3,
        assetIdPool: const {'a1', 'a2'},
        now: DateTime(2026, 3, 9),
      );
      expect(tasks, isNotEmpty);
      expect(tasks.every((t) => t.action is! TtsAction), isTrue,
          reason: '不允许任何 TtsAction 漏出（关闭后依然出声的旧形态）');
      expect(tasks.every((t) => t.actionType != ActionType.tts), isTrue);
      // 出音效的必须绑定具体音源；震动类不绑。
      final audio = tasks.where((t) => t.actionType == ActionType.playAudio);
      expect(audio, isNotEmpty, reason: '有音源池时应排出音效');
      expect(audio.every((t) => t.assetIds.length == 1), isTrue,
          reason: '每条音效反击必须绑定一个具体音效');
    });

    test('RCT-03 无可用音效 ⇒ 一条音效都不排（不空转、不假装成功）', () {
      const plan = CounterPlan(
        presetIds: ['annoy_cough_fit'],
        ttsTexts: ['干啥呢？'],
      );
      final tasks = CounterPlanMaterializer.materialize(
        plan,
        planId: 'p',
        from: DateTime(2026, 3, 10),
        days: 3,
        assetIdPool: const {},
        now: DateTime(2026, 3, 9),
      );
      // 到点必失败的音效动作一条都不能有；无音源时可退化为震动（既有契约）。
      expect(tasks.every((t) => t.actionType != ActionType.playAudio), isTrue,
          reason: '无音源池时绝不能排音效动作');
      expect(tasks.every((t) => t.action is! TtsAction), isTrue,
          reason: '弃 TTS 后不得退化到喊话');
    });

    test('RCT-04 无音源池时也不退化到 TTS（旧兜底路径彻底关闭）', () {
      const plan = CounterPlan(presetIds: ['x']);
      final tasks = CounterPlanMaterializer.materialize(
        plan,
        planId: 'p',
        from: DateTime(2026, 3, 10),
        days: 3,
        assetIdPool: const {},
      );
      expect(tasks.every((t) => t.action is! TtsAction), isTrue,
          reason: '旧实现「无音源 ⇒ 退到 TTS」的路径必须彻底关闭');
      expect(tasks.every((t) => t.actionType != ActionType.playAudio), isTrue);
    });
  });
}
