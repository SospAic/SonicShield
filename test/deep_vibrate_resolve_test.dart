import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/domain/scheduling/vibrate_resolve.dart';

/// 第三十六轮「覆盖率冲刺」—— `vibrate_resolve.dart` 的**执行期形状**（VR 系列）。
///
/// ## 为什么单独一组
///
/// 覆盖率榜（`_pt/unc/vibrate_resolve.txt`）显示该文件 161 行里 17 行没跑过，
/// 而且**全集中在两处**：值对象的 `toString`/`toMap`，以及
/// `buildRandomVibrateCommand` 的**退化兜底分支**。
/// 后者尤其危险 —— 它是"脉冲时长装不进总时长"时的最后一条退路，
/// 一旦写错，端点会拿到**空命令**（什么都不振，却报成功）。
///
/// ## 锁的是什么
///
/// - **退化分支必须产出一次等长振动，而不是空命令**：
///   空 timings 在原生侧等于"不振动"，而审计记的是"已执行"——
///   那是**成功被误报成沉默**的同族缺陷（BUG-073 的教训）；
/// - `toString` / `toMap` 必须带上**全部**关键字段（`truncated`、
///   `useAlarmUsage`、`points.length`…）—— 审计日志靠它们还原现场，
///   少一个字段就等于"出了事查不出为什么"；
/// - 能力降级链：只有 `hasVibrator` 时必须落到 `waveformOnOff`
///   （强度被系统拉满是已知代价，不能因此就不振）。
///
/// ⚠️ 不写源码锁（既有 lock 系列已覆盖），全部为行为断言。
void main() {
  const envelopeCaps = VibrateCaps(
    hasVibrator: true,
    hasAmplitudeControl: true,
    hasEnvelope: true,
    minControlPointMs: 20,
  );

  const ampCaps = VibrateCaps(
    hasVibrator: true,
    hasAmplitudeControl: true,
    hasEnvelope: false,
    minControlPointMs: 20,
  );

  /// 只有基础振动器（API 26 以下形状）：强度不生效。
  const onOffCaps = VibrateCaps(
    hasVibrator: true,
    hasAmplitudeControl: false,
    hasEnvelope: false,
    minControlPointMs: 20,
  );

  group('VR-01 值对象的序列化必须带上全部关键字段', () {
    test('VibratePlan.toString 含时长/强度/种子/截断标志', () {
      const p = VibratePlan(
        durationMs: 4200,
        baseAmplitude: 0.75,
        jitterSeed: 12345,
        truncated: true,
      );
      final s = p.toString();
      expect(s, contains('4200ms'));
      expect(s, contains('0.75'));
      expect(s, contains('12345'));
      expect(s, contains('truncated=true'),
          reason: '截断标志是审计必查项，toString 里缺了就查不出');
    });

    test('EnvelopePoint.toMap 键名与取值（原生侧按此键名读）', () {
      const p = EnvelopePoint(
          intensity: 0.5, sharpness: 0.25, durationMs: 120);
      final m = p.toMap();
      expect(m['intensity'], 0.5);
      expect(m['sharpness'], 0.25);
      expect(m['durationMs'], 120);
      expect(m.keys.toSet(), {'intensity', 'sharpness', 'durationMs'},
          reason: '键名是跨语言契约，多一个少一个都会让原生侧读不到');
    });

    test('EnvelopePoint.toString 两位小数 + 时长', () {
      const p = EnvelopePoint(
          intensity: 0.5, sharpness: 0.25, durationMs: 120);
      expect(p.toString(), '(0.50, 0.25, 120ms)');
    });

    test('VibrateCommand.toString 含模式/片长/各类数组长度/alarm 标志', () {
      const cmd = VibrateCommand(
        mode: VibrateMode.envelope,
        chunkMs: 1500,
        points: [
          EnvelopePoint(intensity: 1, sharpness: 0.5, durationMs: 100),
          EnvelopePoint(intensity: 0, sharpness: 0, durationMs: 100),
        ],
        useAlarmUsage: true,
      );
      final s = cmd.toString();
      expect(s, contains('envelope'));
      expect(s, contains('1500ms'));
      expect(s, contains('points=2'));
      expect(s, contains('alarm=true'),
          reason: '穿透勿扰是敏感开关，日志里必须看得见');
    });
  });

  group('VR-02 buildRandomVibrateCommand 退化兜底：绝不许产出空命令', () {
    test('总时长为 0（脉冲装不进去）→ 退化为一次等长振动', () {
      final cmd = buildRandomVibrateCommand(
        caps: ampCaps,
        a: const RandomVibrateAction(),
        rng: Random(7),
        totalMs: 0,
        useAlarmUsage: false,
      );
      expect(cmd.timings, isNotEmpty,
          reason: '空 timings 在原生侧等于"不振动"，而审计仍记"已执行"'
              '—— 那是把成功误报成沉默');
      expect(cmd.timings, [0, 0]);
      expect(
        cmd.amplitudes,
        [0, amplitudeToNative(1.0)],
        reason: '退化时必须用 amplitudeMax 补一次等长振动',
      );
    });

    test('只有基础振动器 → 降级到 waveformOnOff（强度被拉满是已知代价）', () {
      final cmd = buildRandomVibrateCommand(
        caps: onOffCaps,
        a: const RandomVibrateAction(maxPulses: 5),
        rng: Random(7),
        totalMs: 3000,
        useAlarmUsage: false,
      );
      expect(cmd.mode, VibrateMode.waveformOnOff,
          reason: 'hasAmplitudeControl=false 时不得声称带强度');
      expect(cmd.amplitudes, isNull, reason: 'on/off 模式不带振幅数组');
      expect(cmd.timings.length, greaterThan(1));
    });
  });

  group('VR-03 buildContinuousChunk 包络路径：锐度必须落在配置区间内', () {
    test('sharpnessMax>0 时逐点随机锐度，且全部落在 [min,max]', () {
      final cmd = buildContinuousChunk(
        caps: envelopeCaps,
        a: const ContinuousVibrateAction(
          sharpnessMin: 0.2,
          sharpnessMax: 0.6,
          jitterMs: 300,
          dutyCyclePct: 100,
        ),
        rng: Random(11),
        chunkMs: 3000,
        elapsedMs: 0,
        totalMs: 6000,
        useAlarmUsage: false,
      );
      expect(cmd.mode, VibrateMode.envelope);
      expect(cmd.points, isNotNull);
      expect(cmd.points, isNotEmpty);
      for (final p in cmd.points!) {
        expect(p.sharpness, greaterThanOrEqualTo(0.2));
        expect(p.sharpness, lessThanOrEqualTo(0.6),
            reason: '锐度必须落在配置区间内 —— 越界说明随机取值写错了分支');
      }
    });
  });
}
