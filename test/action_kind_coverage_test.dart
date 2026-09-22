import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';

/// 「每个动作类型都能在编辑器里被创建/回填」锁（BUG-071）。
///
/// ## 为什么需要它
///
/// 任务编辑器的动作选项是 `ActionKindChoice` 枚举，领域动作类型是
/// `ActionType` 枚举 —— **两个枚举，各写各的**。在 v1.9 之前，
/// `ActionKindChoice` 里**根本没有震动**，于是：
///
/// 1. 用户在别处（远程任务 / 导入 / 随机指令集）造出一个 `ActionType.vibrate`
///    的任务；
/// 2. 打开编辑器 → `_applyTask` 里没有 `a is VibrateAction` 分支 →
///    `_actionKind` 停在默认的 `play`；
/// 3. 用户改了名字再保存 → `_save()` 按 `play` 生成 `PlayAudioAction`，
///    **原震动配置被静默覆盖**。
///
/// 这类缺陷的共同点：**两边枚举不同步，且没有任何东西会报错**。
/// `switch` 的穷尽性只能保证"已枚举的值都被处理"，保证不了
/// "领域里的每个值都有对应的编辑器入口" —— 后者只能靠这条锁。
///
/// 断言方向刻意是「**满射**」：`ActionType.values` 的每个值都必须
/// 至少被一个 `ActionKindChoice` 映射到。新增动作类型而不加编辑器选项
/// ⇒ 本文件立刻变红。
void main() {
  group('AK 编辑器动作选项覆盖', () {
    test('AK-01 每个 ActionType 都有可产生它的编辑器选项（满射）', () {
      final produced = <ActionType>{
        for (final c in ActionKindChoice.values) actionTypeOfChoice(c),
      };
      final missing =
          ActionType.values.where((t) => !produced.contains(t)).toList();
      expect(missing, isEmpty,
          reason: '这些动作类型在编辑器里没有入口：$missing —— '
              '意味着"打开编辑器再保存"会把这类任务静默改成别的动作类型');
    });

    test('AK-02 映射是单射（没有两个选项产生同一个 ActionType）', () {
      final byType = <ActionType, List<ActionKindChoice>>{};
      for (final c in ActionKindChoice.values) {
        byType.putIfAbsent(actionTypeOfChoice(c), () => []).add(c);
      }
      final dup = byType.entries.where((e) => e.value.length > 1).toList();
      expect(dup, isEmpty,
          reason: '两个编辑器选项映射到同一动作类型：$dup —— '
              '回填时无法判断该选哪一个（`_applyTask` 只能按类型分支）');
    });

    test('AK-03 震动族的选项都标了 isVibrate（用于分组与能力提示）', () {
      for (final c in ActionKindChoice.values) {
        final isVibType = actionTypeOfChoice(c).isVibrateFamily;
        expect(c.isVibrate, isVibType,
            reason: '${c.name} 的 isVibrate=${c.isVibrate} 与领域类型 '
                '${actionTypeOfChoice(c).name} 的 isVibrateFamily=$isVibType 不一致');
      }
    });

    test('AK-04 ActionType.label 覆盖全部枚举值且两两不同', () {
      final labels = {for (final t in ActionType.values) t.label};
      expect(labels.length, ActionType.values.length,
          reason: '存在两个动作类型共用同一 label —— 用户在下拉/统计里无法区分');
      for (final l in labels) {
        expect(l.trim(), isNotEmpty);
      }
    });

    test('AK-05 随机/持续振动在"随机指令集"里不可表示（必须保留而非降级）', () {
      // `RcStepKind.vibrate` 的控件只会生成 `VibrateAction`（固定节奏）。
      // 若把随机/持续振动映射过去，保存时会把它们**静默降级**成固定节奏。
      // 因此必须返回 null → 由 `_setPreserved` 原样保留（BUG-058 同族）。
      expect(stepKindOfAction(const RandomVibrateAction()), isNull);
      expect(stepKindOfAction(const ContinuousVibrateAction()), isNull);
      expect(stepKindOfAction(const VibrateAction()), isNotNull,
          reason: '固定节奏是可表示的，不应被误判为不可表示');
    });
  });
}
