import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';

/// 「守护反击只出噪音、不出 TTS」的纯逻辑锁（2026-10 产品决策）。
///
/// 背景：可识别语音会暴露反击意图、取证价值低，与「不可预测」目标相反。
/// 契约变化（显式作废旧行为）：
/// - 出厂 TTS 文案池清空（`CounterPlan.defaultTtsTexts` 恒为空）；
/// - 物化器**忽略** `plan.ttsTexts`，只生成 `PlayAudioAction`；
/// - 无可用音效 ⇒ 不生成任何任务（由 `CounterPlanService.apply` 如实报错
///   并引导导入音源库），不再「退化 TTS 池」。
void main() {
  group('RCT-TTS 弃用：反击动作只出噪音', () {
    test('RCT-01 出厂 TTS 文案池恒为空', () {
      expect(CounterPlan.defaultTtsTexts, isEmpty,
          reason: '出厂不应再带 TTS 文案池；字段保留仅为兼容旧 JSON');
    });

    test('RCT-02 导入的旧 plan 带 ttsTexts ⇒ 物化全部忽略，只出播放动作', () {
      final plan = CounterPlan(
        presetIds: const ['annoy_cough_fit'],
        ttsTexts: const ['干啥呢？', '小点声行不行？'], // 旧 JSON 兼容输入
        workdayDay: const CounterWindow(
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
      expect(tasks.every((t) => t.action is PlayAudioAction), isTrue,
          reason: '不允许任何 TtsAction 漏出（关闭后依然出声的旧形态）');
      expect(tasks.every((t) => t.actionType == ActionType.playAudio), isTrue);
      expect(tasks.every((t) => t.assetIds.length == 1), isTrue,
          reason: '每条反击必须绑定一个具体音效');
    });

    test('RCT-03 无可用音效 ⇒ 零任务（不空转、不假装成功）', () {
      final plan = CounterPlan(
        presetIds: const ['annoy_cough_fit'],
        ttsTexts: const ['干啥呢？'],
      );
      final tasks = CounterPlanMaterializer.materialize(
        plan,
        planId: 'p',
        from: DateTime(2026, 3, 10),
        days: 3,
        assetIdPool: const {},
        now: DateTime(2026, 3, 9),
      );
      expect(tasks, isEmpty);
    });

    test('RCT-04 无音效池时 apply 的失败提示指向音源库（可操作）', () {
      // 提示文案与 CounterPlanService.apply 同源判据：池空 → 引导导入。
      // 此处锁「判据」：物料化器池空即零任务，service 据此报失败。
      final plan = CounterPlan(presetIds: const ['x']);
      final tasks = CounterPlanMaterializer.materialize(
        plan,
        planId: 'p',
        from: DateTime(2026, 3, 10),
        days: 3,
        assetIdPool: const {},
      );
      expect(tasks, isEmpty);
    });
  });
}
