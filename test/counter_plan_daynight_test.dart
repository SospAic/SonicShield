import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';

/// 昼夜导向（DN 系列）：白天（06:00–21:00）**尽量不喊话** —— 以大量大音量噪音
/// 为主、少量**高强度**震动为辅；夜间**以 TTS 说烦人的话为主** + 震动配合 +
/// **轻幅度**噪音。覆盖三处：窗口配比、出厂默认、物化选路。
void main() {
  group('DN 窗口动作配比', () {
    test('DN-01 clamped 归一化：tts+vib>1 按比例缩到 1，音效概率非负', () {
      const w = CounterWindow(ttsWeight: 0.9, vibrateWeight: 0.9);
      final c = w.clamped();
      expect(c.ttsWeight + c.vibrateWeight, closeTo(1.0, 1e-9));
      expect(c.ttsWeight, closeTo(0.5, 1e-9));
      expect(c.audioWeight, 0.0);
    });

    test('DN-02 震动强度区间夹紧与交换', () {
      const w = CounterWindow(vibrateAmplitudeMin: 1.5, vibrateAmplitudeMax: -2);
      final c = w.clamped();
      expect(c.vibrateAmplitudeMin, 0.0);
      expect(c.vibrateAmplitudeMax, 1.0);
    });

    test('DN-03 fromJson/toJson 往返含配比字段', () {
      const w = CounterWindow(
          ttsWeight: 0.2,
          vibrateWeight: 0.3,
          vibrateAmplitudeMin: 0.1,
          vibrateAmplitudeMax: 0.9);
      final back = CounterWindow.fromJson(w.toJson(), const CounterWindow());
      expect(back.ttsWeight, 0.2);
      expect(back.vibrateWeight, 0.3);
      expect(back.vibrateAmplitudeMin, 0.1);
      expect(back.vibrateAmplitudeMax, 0.9);
    });

    test('DN-04 audioWeight = 1 - tts - vib', () {
      const w = CounterWindow(ttsWeight: 0.6, vibrateWeight: 0.3);
      expect(w.audioWeight, closeTo(0.1, 1e-9));
    });

    test('DN-05 validate 抓出配比和>1 与震动强度倒挂', () {
      final bad = CounterPlan.defaults().copyWith(
          workdayDay: const CounterWindow(ttsWeight: 0.7, vibrateWeight: 0.7));
      expect(bad.validate().any((e) => e.contains('权重之和不能超过 1')), isTrue);
      final badAmp = CounterPlan.defaults().copyWith(
          workdayDay: const CounterWindow(
              vibrateAmplitudeMin: 0.9, vibrateAmplitudeMax: 0.2));
      expect(
          badAmp.validate().any((e) => e.contains('震动强度下限不能大于上限')), isTrue);
    });
  });

  group('DN 出厂导向', () {
    test('DN-06 白天窗口 ttsWeight=0（不喊话）、大音量、高强度震动', () {
      final d = CounterPlan.defaults().workdayDay;
      expect(d.ttsWeight, 0.0);
      expect(d.volumeMin, greaterThanOrEqualTo(0.7));
      expect(d.vibrateAmplitudeMin, greaterThanOrEqualTo(0.8));
      expect(d.vibrateWeight, greaterThan(0));
    });

    test('DN-07 夜间窗口以喊话为主 + 轻幅度 + 震动配合', () {
      final n = CounterPlan.defaults().workdayNight;
      expect(n.ttsWeight, greaterThan(0.5));
      expect(n.vibrateWeight, greaterThan(0));
      expect(n.volumeMax, lessThanOrEqualTo(0.3));
    });

    test('DN-08 白天 = 06:00–21:00', () {
      expect(CounterPlan.defaults().dayStartHour, 6);
      expect(CounterPlan.defaults().dayEndHour, 21);
    });
  });

  group('DN 物化选路（昼夜配比）', () {
    final plan = CounterPlan.defaults().copyWith(
      presetIds: const ['annoy_spit'],
      ttsTexts: const ['干啥呢？'],
      cooldownSec: 30,
    );

    List<Task> tasks(DateTime day) => CounterPlanMaterializer.materialize(plan,
        planId: 'dn',
        from: day,
        days: 1,
        assetIdPool: const {'annoy_spit'},
        now: null);

    test('DN-09 白天/夜间任务**永不**是 TTS（2026-10 弃 TTS）', () {
      var dayTts = 0;
      var nightTts = 0;
      var nightTotal = 0;
      for (var i = 0; i < 20; i++) {
        for (final t in tasks(DateTime(2026, 3, 9 + i))) {
          if (t.name.contains('白天')) {
            if (t.actionType == ActionType.tts) dayTts++;
          } else {
            nightTotal++;
            if (t.actionType == ActionType.tts) nightTts++;
          }
        }
      }
      expect(dayTts, 0, reason: '白天 ttsWeight=0 ⇒ 不得出现喊话');
      expect(nightTotal, greaterThan(0));
      expect(nightTts, 0, reason: '弃 TTS ⇒ 夜间同样不得出现喊话');
    });

    test('DN-10 白天可出现高强度震动（RandomVibrateAction）', () {
      var vib = 0;
      for (var i = 0; i < 20; i++) {
        for (final t in tasks(DateTime(2026, 3, 9 + i))) {
          if (t.name.contains('白天') &&
              t.actionType == ActionType.randomVibrate) {
            final v = t.action as RandomVibrateAction;
            expect(v.amplitudeMin, greaterThanOrEqualTo(0.8));
            vib++;
          }
        }
      }
      expect(vib, greaterThan(0), reason: '白天应有少量高强度震动');
    });

    test('DN-11 无音源池时白天退化为震动（不喊话）', () {
      final l = CounterPlanMaterializer.materialize(plan,
          planId: 'dn',
          from: DateTime(2026, 3, 9),
          days: 1,
          assetIdPool: const {},
          now: null);
      expect(l, isNotEmpty);
      for (final t in l.where((t) => t.name.contains('白天'))) {
        expect(t.actionType, isNot(ActionType.tts));
      }
    });
  });
}
