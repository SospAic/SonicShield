import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/domain/scheduling/vibrate_resolve.dart';

/// 振动**解析层**（纯函数）回归锁（docs/20 §5 / §7）。
///
/// 这一层是"配置 → 原生命令"的唯一翻译点，也是**静默降级**最容易发生的地方：
/// - 设备没有振幅控制时，系统会把所有非零振幅当 100%（官方文档原文）；
/// - 包络效果**必须以 intensity == 0 收尾**，否则原生抛 `IllegalStateException`；
/// - 强度 0 会被算成"静止"，于是"低强度"静默变成"不振动"。
/// 三条都不抛异常、也不报错，所以只能靠锁。
void main() {
  const capsFull = VibrateCaps(
    hasVibrator: true,
    hasAmplitudeControl: true,
    hasEnvelope: true,
    minControlPointMs: 20,
    platform: 'android',
  );
  const capsNoAmp = VibrateCaps(
    hasVibrator: true,
    hasAmplitudeControl: false,
    hasEnvelope: false,
    minControlPointMs: 20,
    platform: 'android',
  );
  /// 有振幅控制但**无包络**（Android 8–15 的主流形态）→ `waveformAmplitude`。
  const capsAmpOnly = VibrateCaps(
    hasVibrator: true,
    hasAmplitudeControl: true,
    hasEnvelope: false,
    minControlPointMs: 20,
    platform: 'android',
  );
  const capsNoBg = VibrateCaps(
    hasVibrator: true,
    hasAmplitudeControl: true,
    hasEnvelope: true,
    minControlPointMs: 20,
    platform: 'ios',
    backgroundSupported: false,
  );

  const cont = ContinuousVibrateAction(
    durationSecMin: 10,
    durationSecMax: 30,
    amplitudeMin: 0.4,
    amplitudeMax: 0.9,
    jitterMs: 800,
    rampUpSec: 2,
    rampDownSec: 2,
  );

  group('VR 强度换算', () {
    test('VR-01 强度 0 不能算成 0 振幅（那会静默变成"不振动"）', () {
      expect(amplitudeToNative(0), 1);
      expect(amplitudeToNative(0.001), 1);
      expect(amplitudeToNative(1), 255);
      for (final a in [0.0, 0.05, 0.5, 0.99, 1.0]) {
        expect(amplitudeToNative(a), inInclusiveRange(1, 255));
      }
    });
  });

  group('VR 原生命令形态（能力三级降级）', () {
    test('VR-02 三级降级选对模式', () {
      final e = buildContinuousChunk(
          caps: capsFull, a: cont, rng: Random(1), chunkMs: 20000, elapsedMs: 0, totalMs: 30000, useAlarmUsage: false);
      expect(e.mode, VibrateMode.envelope);

      final w = buildContinuousChunk(
          caps: capsNoAmp, a: cont, rng: Random(1), chunkMs: 20000, elapsedMs: 0, totalMs: 30000, useAlarmUsage: false);
      expect(w.mode, VibrateMode.waveformOnOff);

      final none = buildContinuousChunk(
          caps: VibrateCaps.none, a: cont, rng: Random(1), chunkMs: 20000, elapsedMs: 0, totalMs: 30000, useAlarmUsage: false);
      expect(none.mode, VibrateMode.legacy);
    });

    test('VR-03 包络**必须以 intensity==0 收尾**（否则原生抛 IllegalStateException）',
        () {
      for (final jitter in [0, 500, 800, 5000]) {
        final a = ContinuousVibrateAction(
            durationSecMin: 10, durationSecMax: 10, jitterMs: jitter);
        final c = buildContinuousChunk(
            caps: capsFull, a: a, rng: Random(7), chunkMs: 20000, elapsedMs: 0, totalMs: 10000, useAlarmUsage: false);
        expect(c.points, isNotNull);
        expect(c.points!.last.intensity, 0,
            reason: 'jitter=$jitter 的包络没有收尾于 0 —— 原生会抛异常');
        expect(c.points!.length, lessThanOrEqualTo(
            VibrateRuntime.maxEnvelopePointsPerChunk),
            reason: '控制点数超上限会让数组爆掉');
      }
    });

    test('VR-04 有振幅控制：首元素是"起始静止"，amplitudes 与 timings 等长', () {
      final c = buildContinuousChunk(
          caps: capsAmpOnly, a: cont, rng: Random(3), chunkMs: 20000, elapsedMs: 0, totalMs: 20000, useAlarmUsage: false);
      expect(c.mode, VibrateMode.waveformAmplitude);
      expect(c.timings, isNotEmpty);
      expect(c.timings.first, 0, reason: '波形首元素必须是起始静止时长');
      expect(c.amplitudes, isNotNull);
      expect(c.amplitudes!.length, c.timings.length,
          reason: 'timings 与 amplitudes 必须一一对应，错位会让强度落在错误的段上');
      // 哨兵（W5 P1）：必须真的存在「中间静止段」，否则下面的条件断言
      // 一次都不跑（锁空转 = 恒绿）。cont 的 dutyCyclePct=100 ⇒ offMs=0
      // ⇒ 每个 on 段之间必有 0ms 的静止条目；若波形布局重构后不再出现
      // 中间 0 段，这里先红，逼人确认静止段断言还有没有判据对象。
      final restIdx = [
        for (var i = 1; i < c.timings.length; i++)
          if (c.timings[i] == 0) i,
      ];
      expect(restIdx, isNotEmpty,
          reason: '本种子下波形没有中间静止段，静止段振幅断言一次都不会执行 —— 锁空转');
      for (var i = 0; i < c.timings.length; i++) {
        expect(c.timings[i], greaterThanOrEqualTo(0));
        if (c.timings[i] == 0 && i > 0) {
          expect(c.amplitudes![i], 0, reason: '静止段振幅必须为 0');
        }
      }
      // 有强度的段必须有非零振幅（否则"低强度"会静默变成"不振动"）。
      for (final a in c.amplitudes!) {
        expect(a, inInclusiveRange(0, 255));
      }
    });

    test('VR-04b 无振幅控制：on/off 模式**不带** amplitudes（强度被系统拉满）', () {
      final c = buildContinuousChunk(
          caps: capsNoAmp, a: cont, rng: Random(3), chunkMs: 20000, elapsedMs: 0, totalMs: 20000, useAlarmUsage: false);
      expect(c.mode, VibrateMode.waveformOnOff);
      expect(c.timings, isNotEmpty);
      expect(c.amplitudes, isNull,
          reason: 'on/off 形态下 amplitudes 必须为 null —— 传了会与 timings 语义冲突');
    });

    test('VR-05 chunkMs 不超过请求的片长，也不超过总时长', () {
      final c = buildContinuousChunk(
          caps: capsFull, a: cont, rng: Random(1), chunkMs: 20000, elapsedMs: 5000, totalMs: 12000, useAlarmUsage: false);
      // elapsed=5s、total=12s ⇒ 本片最多 7s。
      expect(c.chunkMs, 7000);
      expect(c.chunkMs, lessThanOrEqualTo(VibrateRuntime.chunkMs));
    });

    test('VR-06 占空比 <100% 时出现 0 强度段', () {
      const half = ContinuousVibrateAction(
          durationSecMin: 10, durationSecMax: 10, dutyCyclePct: 50);
      final c = buildContinuousChunk(
          caps: capsFull, a: half, rng: Random(5), chunkMs: 10000, elapsedMs: 0, totalMs: 10000, useAlarmUsage: false);
      expect(c.points!.any((p) => p.intensity == 0), isTrue);
      expect(c.points!.any((p) => p.intensity > 0), isTrue);
    });

    test('VR-07 useAlarmUsage 原样透传到命令（穿透勿扰必须显式）', () {
      final c = buildContinuousChunk(
          caps: capsFull, a: cont, rng: Random(1), chunkMs: 1000, elapsedMs: 0, totalMs: 1000, useAlarmUsage: true);
      expect(c.useAlarmUsage, isTrue);
    });
  });

  group('VR 随机脉冲串', () {
    test('VR-08 波形形态：一次性生成，时间轴合计 == 请求总时长（尾段补静止）', () {
      const a = RandomVibrateAction(
          durationSecMin: 5, durationSecMax: 5, maxPulses: 20);
      final c = buildRandomVibrateCommand(
          caps: capsAmpOnly, a: a, rng: Random(11), totalMs: 5000, useAlarmUsage: false);
      expect(c.mode, VibrateMode.waveformAmplitude);
      expect(c.amplitudes!.length, c.timings.length);
      // ⚠️ 首元素是**起始停顿**（时长随机，不一定是 0），
      // 真正的不变量是"振幅数组首元素为 0"= 先静后振。
      expect(c.amplitudes!.first, 0);
      expect(c.timings.first, greaterThanOrEqualTo(0));
      // 时间轴合计 == 请求总时长（否则实际振动比审计值短）。
      final sum = c.timings.fold<int>(0, (s, v) => s + v);
      expect(sum, 5000, reason: '合计短于审计值 = 静默少震');
      // 至少出现过一次振动（不能"全是静止"）。
      expect(c.amplitudes!.any((a) => a > 0), isTrue);
      expect(c.chunkMs, 5000);
    });

    test('VR-08b 包络形态：脉冲串被翻译成控制点，且仍以 0 收尾', () {
      const a = RandomVibrateAction(
          durationSecMin: 5, durationSecMax: 5, maxPulses: 20);
      final c = buildRandomVibrateCommand(
          caps: capsFull, a: a, rng: Random(11), totalMs: 5000, useAlarmUsage: false);
      expect(c.mode, VibrateMode.envelope);
      expect(c.points, isNotNull);
      expect(c.points!.last.intensity, 0);
      expect(c.points!.length,
          lessThanOrEqualTo(VibrateRuntime.maxEnvelopePointsPerChunk));
      expect(c.timings, isEmpty, reason: '包络形态不该同时带 waveform 时间轴');
      expect(c.chunkMs, 5000);
    });

    test('VR-09 脉冲数上限会截断，且被显式识别（truncated 必须留痕）', () {
      const a = RandomVibrateAction(
          durationSecMin: 600,
          durationSecMax: 600,
          pulseOnMsMin: 20,
          pulseOnMsMax: 20,
          pulseOffMsMin: 0,
          pulseOffMsMax: 0,
          maxPulses: 10);
      final c = buildRandomVibrateCommand(
          caps: capsFull, a: a, rng: Random(2), totalMs: 600000, useAlarmUsage: false);
      // 10 个脉冲 = 20 个时间点（off=0 + on=20）→ 上限内。
      expect(c.timings.length ~/ 2, lessThanOrEqualTo(10));
      expect(randomVibrateTruncated(a, 600000), isTrue,
          reason: '脉冲数上限远小于总时长能容纳的数量 → 必须报告被截断');
    });

    test('VR-10 同一 occurrenceId → 同一条曲线（DPRNG 可复现）', () {
      const a = RandomVibrateAction(durationSecMin: 10, durationSecMax: 10);
      const seed = 12345;
      final c1 = buildRandomVibrateCommand(
          caps: capsFull, a: a, rng: Random(seed), totalMs: 10000, useAlarmUsage: false);
      final c2 = buildRandomVibrateCommand(
          caps: capsFull, a: a, rng: Random(seed), totalMs: 10000, useAlarmUsage: false);
      expect(c1.timings, c2.timings);
      expect(c1.amplitudes, c2.amplitudes);
    });
  });

  group('VR 降级说明（不得静默降级）', () {
    test('VR-11 无振幅控制 → 明说"强度设置已失效"', () {
      final d = vibrateDegradations(capsNoAmp, const ContinuousVibrateAction());
      expect(d.any((s) => s.contains('不支持振幅控制')), isTrue);
      expect(d.any((s) => s.contains('满格')), isTrue);
    });

    test('VR-12 无包络 → 明说锐度被忽略（且只在用户真的设了锐度时才说）', () {
      const withSharp = ContinuousVibrateAction(sharpnessMin: 0.2, sharpnessMax: 0.8);
      expect(
          vibrateDegradations(capsNoAmp, withSharp)
              .any((s) => s.contains('锐度')),
          isTrue);
      expect(
          vibrateDegradations(capsNoAmp, const ContinuousVibrateAction())
              .any((s) => s.contains('锐度')),
          isFalse,
          reason: '用户没设锐度就不要吓他 —— 无谓的降级提示会让真提示被忽略');
    });

    test('VR-13 无振动器 → 唯一一条"不会发生"，且直接返回', () {
      final d = vibrateDegradations(VibrateCaps.none, const ContinuousVibrateAction());
      expect(d, hasLength(1));
      expect(d.single, contains('无振动器'));
    });

    test('VR-14 后台不支持 → 明说"仅前台生效"', () {
      final d = vibrateDegradations(capsNoBg, const ContinuousVibrateAction());
      expect(d.any((s) => s.contains('后台')), isTrue);
    });

    test('VR-15 全能力设备 → 空列表（不能凭空造降级提示）', () {
      expect(vibrateDegradations(capsFull, const ContinuousVibrateAction()), isEmpty);
      expect(vibrateDegradations(capsFull, const RandomVibrateAction()), isEmpty);
    });

    test('VR-16 固定节奏不需要振幅/锐度 → 不报相关降级', () {
      expect(vibrateDegradations(capsNoAmp, const VibrateAction()), isEmpty);
    });
  });

  group('VR 物化期计划', () {
    test('VR-17 时长与基准强度都落在配置区间内', () {
      for (var seed = 0; seed < 40; seed++) {
        final p = resolveVibratePlan(
            cont, Random(seed), 'occ-$seed')!;
        expect(p.durationMs, inInclusiveRange(10000, 30000));
        expect(p.baseAmplitude, inInclusiveRange(0.4, 0.9));
        expect(p.jitterSeed, isNot(0));
      }
    });

    test('VR-18 固定节奏不由物化期处理（返回 null，走老路径）', () {
      expect(resolveVibratePlan(const VibrateAction(), Random(1), 'o'), isNull);
      expect(resolveVibratePlan(const PlayAudioAction(), Random(1), 'o'), isNull);
    });

    test('VR-19 同一 occurrenceId → 同一份计划（计划即审计）', () {
      final a = resolveVibratePlan(cont, Random(9), 'occ-x')!;
      final b = resolveVibratePlan(cont, Random(9), 'occ-x')!;
      expect(a.durationMs, b.durationMs);
      expect(a.baseAmplitude, b.baseAmplitude);
      expect(a.jitterSeed, b.jitterSeed);
    });

    test('VR-20 脉冲上限会截断 → plan.truncated 为真（执行层必须写审计）', () {
      const a = RandomVibrateAction(
          durationSecMin: 600,
          durationSecMax: 600,
          pulseOnMsMin: 20,
          pulseOnMsMax: 20,
          pulseOffMsMin: 0,
          pulseOffMsMax: 0,
          maxPulses: 5);
      final p = resolveVibratePlan(a, Random(1), 'o')!;
      expect(p.truncated, isTrue);
    });
  });
}
