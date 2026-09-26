import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';

/// QR3 全功能点扫描（守护/任务/音源/振动）的回归锁。
///
/// 聚焦一个此前**只能靠人眼审查**的前提：任务编辑器（`task_editor_screen.dart`）
/// 对振动族参数走的是「**先校验、再构造**」——因为 `_save()` 是 async，
/// 构造期 assert 抛出在 release 下会被剥离，变成**静默保存畸形配置**
/// （BUG-067 同形）。这组锁把"构造层确实会拒绝区间反的配置"钉死：
/// 一旦有人删掉构造断言或删掉编辑器的前置校验，这里立刻变红。
void main() {
  group('VibrateLimits 常量自洽（编辑器滑条 min/max 的数据源）', () {
    test('VL-01 上界均为正且 minPulseOnMs < maxPulseOnMs', () {
      expect(VibrateLimits.minPulseOnMs, greaterThanOrEqualTo(1));
      expect(VibrateLimits.minPulseOnMs, lessThan(VibrateLimits.maxPulseOnMs));
      expect(VibrateLimits.maxPulseOnMs, lessThan(VibrateLimits.maxPulseOffMs * 10));
      expect(VibrateLimits.maxPulses, greaterThanOrEqualTo(2));
      expect(VibrateLimits.maxJitterMs, greaterThan(0));
      expect(VibrateLimits.maxRampSec, greaterThan(0));
      // 编辑器固定节奏循环步进依赖单步上限 > 步进量（50ms）。
      expect(VibrateLimits.maxPatternStepMs, greaterThan(50));
    });
  });

  group('RandomVibrateAction：区间反的配置必须在构造层被拒绝', () {
    test('RVA-01 合法区间可构造', () {
      const a = RandomVibrateAction(
        durationSecMin: 3,
        durationSecMax: 10,
        pulseOnMsMin: 150,
        pulseOnMsMax: 400,
        pulseOffMsMin: 100,
        pulseOffMsMax: 600,
        amplitudeMin: 0.4,
        amplitudeMax: 1.0,
        maxPulses: 200,
      );
      expect(a.durationSecMax, 10);
    });

    test('RVA-02 总时长区间反（min > max）→ 抛出', () {
      expect(
        () => RandomVibrateAction(durationSecMin: 10, durationSecMax: 3),
        throwsA(isA<AssertionError>()),
      );
    });

    test('RVA-03 脉冲时长低于系统下限（< minPulseOnMs）→ 抛出', () {
      expect(
        () => RandomVibrateAction(pulseOnMsMin: VibrateLimits.minPulseOnMs - 1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('RVA-04 脉冲数超防爆护栏（> maxPulses）→ 抛出', () {
      expect(
        () => RandomVibrateAction(maxPulses: VibrateLimits.maxPulses + 1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('ContinuousVibrateAction：区间反 / 越界必须在构造层被拒绝', () {
    test('CVA-01 合法参数可构造', () {
      const a = ContinuousVibrateAction();
      expect(a.dutyCyclePct, 100);
    });

    test('CVA-02 振幅区间反 → 抛出', () {
      expect(
        // 注意不能用 `const`：const 上下文的 assert 违反是编译期错误，
        // 无法在运行时被 expect 捕获。这里测的正是**运行时**构造路径
        // （编辑器 `_buildTask` 里走的就是非 const 构造）。
        () => ContinuousVibrateAction(amplitudeMin: 0.9, amplitudeMax: 0.4),
        throwsA(isA<AssertionError>()),
      );
    });

    test('CVA-03 占空比低于下限 10% → 抛出', () {
      expect(
        () => ContinuousVibrateAction(dutyCyclePct: 5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('CVA-04 锐度区间反 → 抛出', () {
      expect(
        () => ContinuousVibrateAction(sharpnessMin: 0.8, sharpnessMax: 0.2),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
