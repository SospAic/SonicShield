import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/counter_plan_params.dart';
import 'package:sonic_shield/services/native_bridge.dart';

/// 第八十六轮覆盖率回补 + 「反击计划参数」容错语义锁（2026-10-18）。
///
/// ## 为什么挑这两个文件
/// 覆盖率 ratchet 是可测面 **98.53% < 98.6%**（第八十六轮门禁实测），
/// 还差约 7 行。本文件挑**纯逻辑**与**可桩通道**两类缺口，各补 6 / 2 行：
/// - `counter_plan_params.dart`：`clamped()` 的权重归一化 + `validateInto`
///   的四条越界分支（`PlanWindowParams` 是生成配方，越界值被静默夹紧会让
///   「AI 生成 / 远程下发」用了错参数还以为成功）；
/// - `native_bridge.dart`：`screenCastStart()` 两个 catch 分支（投屏授权被
///   拒绝 / 桥不可用都必须如实回 false，不得抛给调用方）。
///
/// ## 宿主约束
/// 不碰 DB、不 pump 真实 UI ⇒ 不需要 `tester.runAsync`；渠道桩用
/// `TestDefaultBinaryMessengerBinding` 的 `setMockMethodCallHandler`
/// （项目里 `path_provider` 同款做法）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CPP · PlanWindowParams 容错（纯逻辑）', () {
    test('CPP-01 clamped()：权重和超过 1 时按比例归一化', () {
      // 0.8 + 0.8 = 1.6 > 1 ⇒ 两边都除以 1.6 ⇒ 0.5 / 0.5。
      const raw = PlanWindowParams(ttsWeight: 0.8, vibrateWeight: 0.8);
      final c = raw.clamped();
      expect(c.ttsWeight, closeTo(0.5, 1e-9));
      expect(c.vibrateWeight, closeTo(0.5, 1e-9));
      expect(c.ttsWeight + c.vibrateWeight, closeTo(1.0, 1e-9));
      // 归一化后音频权重归零（三者之和恒为 1）⇒ 不是"夹到 1 就完事"
      expect(c.audioWeight, closeTo(0.0, 1e-9));
    });

    test('CPP-02 clamped()：未越界时不改动（归一化分支不得误伤合法值）', () {
      const raw = PlanWindowParams(ttsWeight: 0.3, vibrateWeight: 0.2);
      final c = raw.clamped();
      expect(c.ttsWeight, 0.3);
      expect(c.vibrateWeight, 0.2);
      expect(c.audioWeight, closeTo(0.5, 1e-9));
    });

    test('CPP-03 validateInto：TTS/震动权重越界要单独报（不能只报"和超了"）', () {
      final errs = <String>[];
      const PlanWindowParams(ttsWeight: 1.5, vibrateWeight: 0.5)
          .validateInto('白天', errs);
      expect(errs, <String>['白天 动作配比（TTS/震动权重）必须在 0–1']);
    });

    test('CPP-04 validateInto：权重各自合法但和超过 1 ⇒ 报"和不能超过 1"', () {
      final errs = <String>[];
      const PlanWindowParams(ttsWeight: 0.7, vibrateWeight: 0.7)
          .validateInto('夜间', errs);
      expect(errs, <String>['夜间 TTS 与震动权重之和不能超过 1']);
    });

    test('CPP-05 validateInto：震动强度区间越界 / 下限大于上限分别报', () {
      final outOfRange = <String>[];
      const PlanWindowParams(vibrateAmplitudeMin: -0.2, vibrateAmplitudeMax: 1.4)
          .validateInto('休息日', outOfRange);
      expect(outOfRange, <String>['休息日 震动强度区间必须在 0–1']);

      final inverted = <String>[];
      const PlanWindowParams(vibrateAmplitudeMin: 0.9, vibrateAmplitudeMax: 0.2)
          .validateInto('休息日', inverted);
      expect(inverted, <String>['休息日 震动强度区间下限不能大于上限']);
    });

    test('CPP-06 validateInto：合法参数零报错（判据非恒真）', () {
      final errs = <String>[];
      const PlanWindowParams().validateInto('默认', errs);
      expect(errs, isEmpty);
    });
  });

  group('NB · screenCastStart 的如实失败（可桩通道）', () {
    const ch = MethodChannel('sonic_shield/screencast');

    testWidgets('NB-01 PlatformException / MissingPluginException / 正常三态',
        (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      // 被系统拒绝 / 用户取消：**必须回 false，不得把异常抛给调用方**。
      messenger.setMockMethodCallHandler(ch,
          (call) async => throw PlatformException(code: 'denied'));
      expect(await NativeBridge.screenCastStart(), isFalse,
          reason: '投屏授权被拒要如实回报 false');

      // 桥不可用（非 Android / 原生缺实现）：同样回 false。
      messenger.setMockMethodCallHandler(
          ch, (call) async => throw MissingPluginException());
      expect(await NativeBridge.screenCastStart(), isFalse,
          reason: '桥不可用要回 false，而不是抛出去');

      // 正向：原生回 true ⇒ 必须透传（防止"一律 false"的假实现）。
      messenger.setMockMethodCallHandler(ch, (call) async => true);
      expect(await NativeBridge.screenCastStart(), isTrue);

      // 原生回 null ⇒ 视作未启动。
      messenger.setMockMethodCallHandler(ch, (call) async => null);
      expect(await NativeBridge.screenCastStart(), isFalse);

      messenger.setMockMethodCallHandler(ch, null);
    });
  });
}
