import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/remote/rc_script.dart';

/// 远程指令组的**振动步骤参数化**回归锁（v1.9，docs/20 §11.1）。
///
/// 两条不变量：
/// 1. **协议向后兼容**：`{"kind":"vibrate"}`（老控制器发的空参数）行为一字不变 ——
///    `mode` 缺省 = `fixed`，`describe()` 仍是 `'震动'`，下发的还是默认节奏串。
/// 2. **表单与执行器不得分叉**：`rcVibrateFields` 是唯一真源，
///    它必须**恰好**覆盖模型 `toJson()` 的可调项（去掉 `kind` 与 `respectDnd`）。
///    分叉的后果不是崩溃，而是"表单能填、执行器不认" → 静默取默认值（BUG-068 同类）。
void main() {
  group('RV 振动步骤：向后兼容', () {
    test('RV-01 空参数 = 固定节奏，describe 一字不变', () {
      const s = RcStep(RcStepKind.vibrate, {});
      expect(s.vibrateMode, RcVibrateMode.fixed);
      expect(s.describe(), '震动');
      final cfg = s.vibrateConfig();
      expect(cfg, isA<VibrateAction>());
      expect((cfg as VibrateAction).patternMs, const [0, 300, 200, 300]);
    });

    test('RV-02 未知 mode 归到 fixed（老协议的唯一语义，不是降级）', () {
      for (final bad in <Object?>[null, 'FIXED', 'randompulse', 42, <String>[]]) {
        final s = RcStep(RcStepKind.vibrate, {'mode': bad});
        expect(s.vibrateMode, RcVibrateMode.fixed, reason: 'mode=$bad');
        expect(s.describe(), '震动');
      }
    });

    test('RV-03 显式 patternMs 仍被夹紧且限制步数', () {
      const s = RcStep(RcStepKind.vibrate, {
        'patternMs': [0, 999999999, -5, 300],
      });
      final v = s.vibrateConfig() as VibrateAction;
      expect(v.patternMs, [0, VibrateLimits.maxPatternStepMs, 0, 300]);

      final tooLong = RcStep(RcStepKind.vibrate, {
        'patternMs': List<int>.filled(VibrateLimits.maxPatternSteps + 1, 100),
      });
      // 超长模式串不拒绝，退回默认（结构性问题由 validate 管）。
      expect((tooLong.vibrateConfig() as VibrateAction).patternMs,
          const [0, 300, 200, 300]);
    });
  });

  group('RV 振动步骤：参数化与夹紧', () {
    test('RV-04 random 参数逐字段夹紧，构造不抛', () {
      const s = RcStep(RcStepKind.vibrate, {
        'mode': 'random',
        'durationSecMin': -1,
        'durationSecMax': 999999999,
        'pulseOnMsMin': 1,
        'pulseOnMsMax': 999999,
        'pulseOffMsMin': -1,
        'pulseOffMsMax': 999999,
        'amplitudeMin': 3,
        'amplitudeMax': -3,
        'maxPulses': 0,
        'rampUpSec': 99999,
      });
      expect(s.vibrateMode, RcVibrateMode.random);
      final a = s.vibrateConfig() as RandomVibrateAction;
      expect(a.durationSecMin, greaterThanOrEqualTo(1));
      expect(a.durationSecMax, lessThanOrEqualTo(VibrateLimits.maxDurationSec));
      expect(a.durationSecMin, lessThanOrEqualTo(a.durationSecMax));
      expect(a.pulseOnMsMin, greaterThanOrEqualTo(VibrateLimits.minPulseOnMs));
      expect(a.pulseOnMsMax, lessThanOrEqualTo(VibrateLimits.maxPulseOnMs));
      expect(a.pulseOnMsMin, lessThanOrEqualTo(a.pulseOnMsMax));
      expect(a.amplitudeMin, lessThanOrEqualTo(a.amplitudeMax));
      expect(a.amplitudeMin, greaterThanOrEqualTo(0));
      expect(a.amplitudeMax, lessThanOrEqualTo(1));
      expect(a.maxPulses, inInclusiveRange(1, VibrateLimits.maxPulses));
      expect(a.rampUpSec, inInclusiveRange(0, VibrateLimits.maxRampSec));
    });

    test('RV-05 continuous 参数逐字段夹紧，构造不抛', () {
      const s = RcStep(RcStepKind.vibrate, {
        'mode': 'continuous',
        'durationSecMin': 100,
        'durationSecMax': 1,
        'amplitudeMin': 2,
        'amplitudeMax': -1,
        'jitterMs': -5,
        'sharpnessMin': 9,
        'sharpnessMax': -9,
        'dutyCyclePct': 1,
        'rampUpSec': -1,
        'rampDownSec': 999999,
      });
      final a = s.vibrateConfig() as ContinuousVibrateAction;
      expect(a.durationSecMin, lessThanOrEqualTo(a.durationSecMax));
      expect(a.amplitudeMin, lessThanOrEqualTo(a.amplitudeMax));
      expect(a.amplitudeMin, greaterThanOrEqualTo(0));
      expect(a.amplitudeMax, lessThanOrEqualTo(1));
      expect(a.jitterMs, inInclusiveRange(0, VibrateLimits.maxJitterMs));
      expect(a.sharpnessMin, lessThanOrEqualTo(a.sharpnessMax));
      expect(a.sharpnessMin, greaterThanOrEqualTo(0));
      expect(a.sharpnessMax, lessThanOrEqualTo(1));
      expect(a.dutyCyclePct, inInclusiveRange(10, 100));
      expect(a.rampUpSec, greaterThanOrEqualTo(0));
      expect(a.rampDownSec, lessThanOrEqualTo(VibrateLimits.maxRampSec));
    });

    test('RV-06 入站振动一律遵循勿扰（对端不得绕过本机护栏）', () {
      for (final mode in ['random', 'continuous']) {
        final s = RcStep(RcStepKind.vibrate, {
          'mode': mode,
          'respectDnd': false,
        });
        final respect = switch (s.vibrateConfig()) {
          final RandomVibrateAction a => a.respectDnd,
          final ContinuousVibrateAction a => a.respectDnd,
          final other => fail('mode=$mode 得到 ${other.runtimeType}'),
        };
        expect(respect, isTrue, reason: 'mode=$mode 让对端关掉了「遵循勿扰」');
      }
      // 缺失也必须是 true（不能因为"没写"就落成 false）。
      const dflt = RcStep(RcStepKind.vibrate, {'mode': 'random'});
      expect((dflt.vibrateConfig() as RandomVibrateAction).respectDnd, isTrue);
    });

    test('RV-07 describe 给出人话（含时长与强度区间）', () {
      final r = const RcStep(RcStepKind.vibrate, {
        'mode': 'random',
        'durationSecMin': 3,
        'durationSecMax': 10,
        'amplitudeMin': 0.4,
        'amplitudeMax': 1.0,
        'pulseOnMsMin': 150,
        'pulseOnMsMax': 400,
        'pulseOffMsMin': 100,
        'pulseOffMsMax': 600,
        'maxPulses': 200,
      }).describe();
      expect(r, contains('随机振动'));
      expect(r, contains('3–10 秒'));
      expect(r, contains('40%'));
      expect(r, contains('100%'));

      final c = const RcStep(RcStepKind.vibrate, {
        'mode': 'continuous',
        'durationSecMin': 10,
        'durationSecMax': 30,
        'amplitudeMin': 0.5,
        'amplitudeMax': 1.0,
        'jitterMs': 800,
      }).describe();
      expect(c, contains('持续振动'));
      expect(c, contains('10–30 秒'));
      expect(c, contains('波动 800ms'));
    });
  });

  group('RV 指令组时长预算', () {
    test('RV-08 振动时长计入总预算（此前只统计 delay）', () {
      // 4 段各 10 分钟 = 40 分钟 > 30 分钟上限 → 必须拒绝。
      final steps = [
        for (var i = 0; i < 4; i++)
          const RcStep(RcStepKind.vibrate, {
            'mode': 'continuous',
            'durationSecMin': 600,
            'durationSecMax': 600,
          }),
      ];
      expect(RcScript.validate(steps), isNotNull);

      // 单段 10 分钟 + 一小段 delay → 通过。
      expect(
          RcScript.validate([
            const RcStep(RcStepKind.vibrate, {
              'mode': 'continuous',
              'durationSecMin': 600,
              'durationSecMax': 600,
            }),
            const RcStep(RcStepKind.delay, {'seconds': 5}),
          ]),
          isNull);
    });

    test('RV-09 取区间上界（取下界会漏掉"最久能占多久"）', () {
      // 单段 [1, 1800] 秒：上界 30 分钟，正好在限内 → 通过；
      // 两段就超了。若误取下界（1 秒），两段会被放行。
      const s = RcStep(RcStepKind.vibrate, {
        'mode': 'continuous',
        'durationSecMin': 1,
        'durationSecMax': 1800,
      });
      expect(RcScript.validate([s]), isNull);
      expect(RcScript.validate([s, s]), isNotNull);
    });

    test('RV-10 结构性错误仍然拒绝', () {
      expect(RcScript.validate(const []), isNotNull);
      expect(
          RcScript.validate(
              List.generate(51, (_) => const RcStep(RcStepKind.vibrate, {}))),
          isNotNull);
      expect(
          RcScript.validate(
              const [RcStep(RcStepKind.delay, {'seconds': 601})]),
          isNotNull);
      expect(
          RcScript.validate(const [RcStep(RcStepKind.delay, {'seconds': 0})]),
          isNotNull);
    });
  });

  group('RV 振动步骤路由（不得静默降级）', () {
    test('RV-15 随机/持续振动**绝不**退回固定节奏', () {
      for (final mode in [RcVibrateMode.random, RcVibrateMode.continuous]) {
        for (final legacy in [true, false]) {
          for (final action in [true, false]) {
            final r = routeRcVibrateStep(mode,
                hasLegacyHandler: legacy, hasActionHandler: action);
            expect(r, isNot(RcVibrateRoute.legacyFixed),
                reason: 'mode=$mode legacy=$legacy action=$action 退回了固定节奏 —— '
                    '对端要的是随机/持续振动，震两下就结束属于静默降级');
            expect(r, action ? RcVibrateRoute.actionHandler : RcVibrateRoute.skip,
                reason: 'mode=$mode legacy=$legacy action=$action');
          }
        }
      }
    });

    test('RV-16 固定节奏仍走老路径（协议向后兼容）', () {
      expect(
          routeRcVibrateStep(RcVibrateMode.fixed,
              hasLegacyHandler: true, hasActionHandler: false),
          RcVibrateRoute.legacyFixed);
      expect(
          routeRcVibrateStep(RcVibrateMode.fixed,
              hasLegacyHandler: true, hasActionHandler: true),
          RcVibrateRoute.legacyFixed,
          reason: '两者都在时，固定节奏必须走老路径 —— 老路径才是它语义上的实现');
      expect(
          routeRcVibrateStep(RcVibrateMode.fixed,
              hasLegacyHandler: false, hasActionHandler: true),
          RcVibrateRoute.skip,
          reason: '没有老处理器时也不能拿参数化处理器顶替：'
              '`resolveVibratePlan(VibrateAction)` 返回 null，会以 durationMs=0 下发');
    });
  });

  group('RV 参数规格不得腐烂（表单 ↔ 执行器唯一真源）', () {
    test('RV-11 随机振动的规格键 == 模型 toJson 键（去掉 kind/respectDnd）', () {
      final modelKeys = (const RandomVibrateAction().toJson().keys.toSet())
        ..remove('kind')
        // respectDnd 刻意不由远程暴露（RV-06 强制 true）。
        ..remove('respectDnd');
      final specKeys = {for (final f in rcVibrateRandomFields) f.key};
      expect(specKeys, modelKeys,
          reason: '规格与模型分叉 —— 表单能填的键与执行器认识的键不一致时，'
              '不报错、只会静默取默认值');
    });

    test('RV-12 持续振动的规格键 == 模型 toJson 键（去掉 kind/respectDnd）', () {
      final modelKeys = (const ContinuousVibrateAction().toJson().keys.toSet())
        ..remove('kind')
        ..remove('respectDnd');
      final specKeys = {for (final f in rcVibrateContinuousFields) f.key};
      expect(specKeys, modelKeys);
    });

    test('RV-13 防空转哨兵：规格非空且每个字段范围合法', () {
      expect(rcVibrateRandomFields.length, greaterThanOrEqualTo(8));
      expect(rcVibrateContinuousFields.length, greaterThanOrEqualTo(8));
      for (final f in [...rcVibrateRandomFields, ...rcVibrateContinuousFields]) {
        expect(f.min, lessThan(f.max), reason: '${f.key} 的范围无效');
        expect(f.label.trim(), isNotEmpty, reason: '${f.key} 缺标签');
      }
      // 键名不得重复（重复会让 putIfAbsent 静默复用同一个 controller）。
      for (final fields in [rcVibrateRandomFields, rcVibrateContinuousFields]) {
        final keys = [for (final f in fields) f.key];
        expect(keys.toSet().length, keys.length, reason: '规格里有重复键');
      }
    });

    test('RV-14 规格覆盖了三种 mode；默认参数与规格同源', () {
      for (final m in RcVibrateMode.values) {
        expect(rcVibrateFields.containsKey(m), isTrue, reason: '$m 没有规格');
      }
      for (final m in [RcVibrateMode.random, RcVibrateMode.continuous]) {
        final d = rcVibrateDefaultParams(m);
        final specKeys = {for (final f in rcVibrateFieldsFor(m)) f.key};
        expect(d.keys.toSet(), specKeys,
            reason: '$m 的默认参数键与规格不一致 —— 新建步骤会缺字段');
      }
      expect(rcVibrateDefaultParams(RcVibrateMode.fixed), isEmpty,
          reason: '固定节奏必须保持空参数（协议向后兼容）');
    });
  });

  // ══════════════════ VS 远程发送振动（`vibrate.start`，v2.x） ══════════════════
  //
  // 用户要的两种形态：**固定强度+固定时长** 与 **随机强度+随机时长**，且强度/时长
  // 可调。`fixed` 在**远程命令**语境下刻意不同于指令组的"固定节奏"（那里没有强度），
  // 这里是"震 N 秒、强度 X%"的恒定振动 —— 用 ContinuousVibrateAction 的退化区间表达，
  // 从而与 random/continuous 共用同一条 VibrateSession 通路（引擎零改动）。
  group('VS 远程发送振动', () {
    test('VS-01 fixed 缺省 → 恒定振动（强度/时长退化为点），且强制遵循勿扰', () {
      final a = rcVibrateStartConfig(const <String, dynamic>{})
          as ContinuousVibrateAction;
      expect(a.durationSecMin, 5);
      expect(a.durationSecMax, 5);
      expect(a.amplitudeMin, 0.6);
      expect(a.amplitudeMax, 0.6);
      expect(a.jitterMs, 0, reason: '恒定振动不得有强度波动');
      expect(a.respectDnd, isTrue, reason: '远程路径不得绕过系统勿扰');
    });

    test('VS-02 fixed 越界先夹紧再构造（release 下 assert 被剥离）', () {
      final tooBig = rcVibrateStartConfig(const {
        'mode': 'fixed',
        'durationSec': 999999999,
        'intensity': 9,
      }) as ContinuousVibrateAction;
      expect(tooBig.durationSecMin, VibrateLimits.maxDurationSec);
      expect(tooBig.amplitudeMax, 1.0);

      final tooSmall = rcVibrateStartConfig(const {
        'mode': 'fixed',
        'durationSec': -5,
        'intensity': -2,
      }) as ContinuousVibrateAction;
      expect(tooSmall.durationSecMin, 1);
      expect(tooSmall.amplitudeMin, 0.0);
    });

    test('VS-03 random 与指令组同口径（复用 vibrateConfig 的夹紧）', () {
      final a = rcVibrateStartConfig(const {
        'mode': 'random',
        'durationSecMin': 3,
        'durationSecMax': 10,
        'amplitudeMin': 0.4,
        'amplitudeMax': 1.0,
      }) as RandomVibrateAction;
      expect(a.durationSecMin, 3);
      expect(a.durationSecMax, 10);
      expect(a.amplitudeMin, 0.4);
      expect(a.amplitudeMax, 1.0);
      expect(a.respectDnd, isTrue);
    });

    test('VS-04 continuous 区间浮动（时长/强度/波动周期都生效）', () {
      final a = rcVibrateStartConfig(const {
        'mode': 'continuous',
        'durationSecMin': 10,
        'durationSecMax': 30,
        'amplitudeMin': 0.5,
        'amplitudeMax': 1.0,
        'jitterMs': 800,
      }) as ContinuousVibrateAction;
      expect(a.durationSecMin, 10);
      expect(a.durationSecMax, 30);
      expect(a.jitterMs, 800);
      expect(a.respectDnd, isTrue);
    });

    test('VS-05 未知/缺失 mode 归到 fixed（与 rcVibrateModeOf 一致，不抛）', () {
      for (final bad in <Object?>[null, 'RANDOM', 'x', 42, <String>[]]) {
        final a = rcVibrateStartConfig({'mode': bad});
        expect(a, isA<ContinuousVibrateAction>(), reason: 'mode=$bad');
        expect((a as ContinuousVibrateAction).durationSecMin, 5,
            reason: 'mode=$bad 应落到 fixed 的缺省时长');
      }
    });

    test('VS-06 label 给出台数与强度（审计/按钮文案用）', () {
      final f = rcVibrateStartLabel(
          const {'mode': 'fixed', 'durationSec': 5, 'intensity': 0.6});
      expect(f, contains('固定振动 5 秒'));
      expect(f, contains('60%'));

      final r = rcVibrateStartLabel(const {
        'mode': 'random',
        'durationSecMin': 3,
        'durationSecMax': 10,
        'amplitudeMin': 0.4,
        'amplitudeMax': 1.0,
      });
      expect(r, contains('随机振动 3–10 秒'));
      expect(r, contains('40%'));
      expect(r, contains('100%'));
    });

    test('VS-07 规格覆盖三种 mode；非 fixed 与指令组同源（同一份声明）', () {
      for (final m in RcVibrateMode.values) {
        expect(rcVibrateStartFields.containsKey(m), isTrue, reason: '$m 缺规格');
      }
      expect(
          {for (final f in rcVibrateStartFieldsFor(RcVibrateMode.fixed)) f.key},
          {'durationSec', 'intensity'},
          reason: 'fixed = 固定强度 + 固定时长，字段必须恰好是这两个');
      expect(
          identical(rcVibrateStartFieldsFor(RcVibrateMode.random),
              rcVibrateRandomFields),
          isTrue,
          reason: 'random 规格必须与指令组共用同一份声明，否则会分叉');
      expect(
          identical(rcVibrateStartFieldsFor(RcVibrateMode.continuous),
              rcVibrateContinuousFields),
          isTrue);
    });
  });
}
