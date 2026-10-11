import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/models/counter_plan_params.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/china_holidays.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_random.dart';
import 'package:sonic_shield/services/counter_plan_service.dart';

void main() {
  group('CP schema 与校验', () {
    test('CP-01 出厂默认计划通过校验且区间符合约定', () {
      final p = CounterPlan.defaults();
      expect(p.validate(), isEmpty);
      // 白天（06–21）：**大音量噪音**为主、**不喊话**、少量**高强度**震动。
      expect(p.workdayDay.volumeMin, 0.7);
      expect(p.workdayDay.volumeMax, 1.0);
      expect(p.workdayDay.durationSecMin, 3);
      expect(p.workdayDay.durationSecMax, 8);
      expect(p.workdayDay.ttsWeight, 0.0, reason: '白天整体导向是"尽量不包含 TTS"');
      expect(p.workdayDay.vibrateWeight, 0.2);
      expect(p.workdayDay.vibrateAmplitudeMin, 0.8, reason: '白天震动是"高强度"');
      expect(p.workdayDay.vibrateAmplitudeMax, 1.0);
      // 夜间：**以 TTS 说烦人的话为主** + 震动配合 + **轻幅度噪音**。
      expect(p.workdayNight.volumeMin, 0.1);
      expect(p.workdayNight.volumeMax, 0.3);
      expect(p.workdayNight.durationSecMax, 5);
      expect(p.workdayNight.ttsWeight, 0.6);
      expect(p.workdayNight.vibrateWeight, 0.3);
      expect(p.workdayNight.vibrateAmplitudeMin, 0.4, reason: '夜间震动幅度要更轻');
      // 休息日两段默认关闭（可选）
      expect(p.restdayDay.enabled, isFalse);
      expect(p.restdayNight.enabled, isFalse);
      // 休息日夜间 10–30% / 3–5s
      expect(p.restdayNight.volumeMin, 0.1);
      expect(p.restdayNight.volumeMax, 0.3);
      // 白天窗口 06:00–21:00
      expect(p.dayStartHour, 6);
      expect(p.dayEndHour, 21);
    });

    test('CP-02 toJson/fromJson 往返一致', () {
      final p = CounterPlan.defaults().copyWith(
        name: '测试计划',
        presetIds: const ['annoy_spit'],
        ttsTexts: const ['干啥呢？'],
        voiceId: 'az_db_female_xiaobei',
      );
      final back = CounterPlan.fromJson(jsonDecode(p.toPrettyJson()));
      expect(back.name, '测试计划');
      expect(back.presetIds, const ['annoy_spit']);
      expect(back.ttsTexts, const ['干啥呢？']);
      expect(back.voiceId, 'az_db_female_xiaobei');
      expect(back.toJson(), p.toJson());
      expect(back.validate(), isEmpty);
    });

    test('CP-03 fromJson 容错：脏类型回到默认、越界值被夹紧', () {
      final p = CounterPlan.fromJson(<String, dynamic>{
        'schema': CounterPlan.schemaId,
        'version': '2',
        'name': 123,
        'dayStartHour': 99,
        'cooldownSec': -5,
        'workday': {
          'day': {'volumeMin': 1.8, 'volumeMax': -3, 'durationSecMax': 9999},
        },
        'presetIds': <dynamic>['a', '', 5, 'b'],
      });
      // 名称类型不符 → 回落默认
      expect(p.name, CounterPlan.defaults().name);
      // 小时夹到 0..23
      expect(p.dayStartHour, 23);
      expect(p.cooldownSec, 0);
      // 音量夹到 0..1 且 min<=max
      expect(p.workdayDay.volumeMin, 0.0);
      expect(p.workdayDay.volumeMax, 1.0);
      // 时长上限被夹
      expect(p.workdayDay.durationSecMax, CounterWindow.maxDurationSec);
      // 非法数组项被丢弃
      expect(p.presetIds, const ['a', 'b']);
    });

    test('CP-04 validate 抓出各类问题', () {
      // schema 不符
      final bad = CounterPlan.fromJson(<String, dynamic>{'schema': 'x/9'});
      expect(bad.validate().any((e) => e.contains('schema')), isTrue);

      // 四个时段全关
      final off = CounterPlan.defaults().copyWith(
        workdayDay: const CounterWindow(enabled: false),
        workdayNight: const CounterWindow(enabled: false),
        restdayDay: const CounterWindow(enabled: false),
        restdayNight: const CounterWindow(enabled: false),
      );
      expect(off.validate().any((e) => e.contains('至少需要启用')), isTrue);

      // 动作池为空
      final empty = CounterPlan.defaults()
          .copyWith(presetIds: const [], ttsTexts: const []);
      expect(empty.validate().any((e) => e.contains('动作池为空')), isTrue);

      // 音量下限大于上限（直接构造，绕过 clamped）
      final badVol = CounterPlan.defaults().copyWith(
        workdayDay: const CounterWindow(volumeMin: 0.9, volumeMax: 0.2),
      );
      expect(badVol.validate().any((e) => e.contains('下限不能大于上限')), isTrue);

      // 白天起止相同
      final same = CounterPlan.defaults().copyWith(dayStartHour: 8, dayEndHour: 8);
      expect(same.validate().any((e) => e.contains('不能相同')), isTrue);
    });

    test('CP-05 tryParse：非法文本返回 null，合法返回计划', () {
      expect(CounterPlan.tryParse(''), isNull);
      expect(CounterPlan.tryParse('{不是 json'), isNull);
      final ok = CounterPlan.tryParse(
          '{"schema":"${CounterPlan.schemaId}","presetIds":["annoy_tsk"]}');
      expect(ok, isNotNull);
      expect(ok!.validate(), isEmpty);
    });

    test('CP-06 validate 逐条抓出窗口/冷却/TTS 的问题', () {
      CounterPlan withWindow(CounterWindow w) =>
          CounterPlan.defaults().copyWith(workdayDay: w);

      // 音量越界（直接构造，绕过 clamped）。
      expect(
          withWindow(const CounterWindow(volumeMin: -0.5))
              .validate()
              .any((e) => e.contains('音量必须在 0–1')),
          isTrue);
      // 时长越界（下限 < 1）。
      expect(
          withWindow(const CounterWindow(durationSecMin: 0))
              .validate()
              .any((e) => e.contains('时长必须在 1–600 秒')),
          isTrue);
      // 时长下限 > 上限。
      expect(
          withWindow(const CounterWindow(durationSecMin: 10, durationSecMax: 2))
              .validate()
              .any((e) => e.contains('时长下限不能大于上限')),
          isTrue);
      // 每小时次数越界。
      expect(
          withWindow(const CounterWindow(actionsPerHour: 99))
              .validate()
              .any((e) => e.contains('每小时次数必须在 0–12')),
          isTrue);
      // 冷却间隔越界。
      expect(
          CounterPlan.defaults()
              .copyWith(cooldownSec: -1)
              .validate()
              .any((e) => e.contains('冷却间隔')),
          isTrue);
      // TTS 空文案（trim 后为空）。
      expect(
          CounterPlan.defaults()
              .copyWith(ttsTexts: const ['   '])
              .validate()
              .any((e) => e.contains('TTS 文案不能为空')),
          isTrue);
      // TTS 文案超长。
      expect(
          CounterPlan.defaults()
              .copyWith(ttsTexts: ['x' * 201])
              .validate()
              .any((e) => e.contains('TTS 文案过长')),
          isTrue);
    });

    test('CP-07 isValid 等价于 validate().isEmpty', () {
      expect(CounterPlan.defaults().isValid, isTrue);
      expect(CounterPlan.fromJson(<String, dynamic>{'schema': 'x/9'}).isValid,
          isFalse);
    });

    test('CP-08 describeWindow 输出音量/时长/次数/动作配比（不区分 enabled）', () {
      const w = CounterWindow(
          volumeMin: 0.5,
          volumeMax: 0.8,
          durationSecMin: 3,
          durationSecMax: 8,
          actionsPerHour: 2);
      // 默认配比 tts=0.5 / vib=0 ⇒ 音效 50%。
      expect(describeWindow(w),
          '50%–80% · 3–8 秒 · 每小时 2 次 · 音效50%/TTS50%/震动0%');
      // 该函数本身不区分 enabled —— "未启用（该时段不反击）"的文案由设置页承担
      // （见 settings_screen.dart 的 `w.enabled ? describeWindow(w) : ...`）。
      const off = CounterWindow(enabled: false);
      expect(describeWindow(off), describeWindow(const CounterWindow()));
    });
  });

  group('CN 节假日判定', () {
    DayKind kind(int y, int m, int d,
            {Map<String, DayKind>? ov}) =>
        ChinaHolidays.dayKind(DateTime(y, m, d), overrides: ov);

    test('CN-01 法定放假 → 休息日（含工作日中的假）', () {
      expect(kind(2026, 10, 6), DayKind.restday); // 国庆假期中的周二
      expect(kind(2026, 2, 17), DayKind.restday); // 春节假期中的周二
      expect(kind(2025, 10, 6), DayKind.restday); // 2025 国庆假期中的周一
    });

    test('CN-02 调休补班 → 工作日（含周末上班）', () {
      expect(kind(2026, 2, 14), DayKind.workday); // 周六上班
      expect(kind(2026, 2, 28), DayKind.workday); // 周六上班
      expect(kind(2026, 10, 10), DayKind.workday); // 周六上班
      expect(kind(2025, 4, 27), DayKind.workday); // 周日上班
    });

    test('CN-03 普通日按星期几', () {
      expect(kind(2026, 3, 10), DayKind.workday); // 周二
      expect(kind(2026, 3, 14), DayKind.restday); // 周六
      expect(kind(2026, 3, 15), DayKind.restday); // 周日
    });

    test('CN-05 表外年份：周六周日为休息日、周一至周五为工作日', () {
      // 2031-01-04 是周六（2031-01-01 为周三）
      expect(ChinaHolidays.hasTableFor(2031), isFalse);
      expect(DateTime(2031, 1, 4).weekday, DateTime.saturday);
      expect(kind(2031, 1, 4), DayKind.restday);
      expect(kind(2031, 1, 6), DayKind.workday);
    });

    test('CN-06 overrides 优先于内置表', () {
      expect(
          kind(2026, 3, 10, ov: {'2026-03-10': DayKind.restday}),
          DayKind.restday);
      expect(
          kind(2026, 2, 17, ov: {'2026-02-17': DayKind.workday}),
          DayKind.workday);
    });

    test('CN-07 parseOverrides 容错解析', () {
      final m = ChinaHolidays.parseOverrides(<String, dynamic>{
        '2026-01-04': 'workday',
        '2026-02-17': '休息日',
        'bad': 5,
        '2026-03-01': 'unknown',
      });
      expect(m['2026-01-04'], DayKind.workday);
      expect(m['2026-02-17'], DayKind.restday);
      expect(m.containsKey('bad'), isFalse);
      expect(m.containsKey('2026-03-01'), isFalse);
    });
  });

  group('MT 物化', () {
    final plan = CounterPlan.defaults().copyWith(
      presetIds: const ['annoy_spit'],
      ttsTexts: const ['干啥呢？'],
      cooldownSec: 60,
    );

    List<Task> tasksFor(DateTime day, {int days = 1}) =>
        CounterPlanMaterializer.materialize(plan,
            planId: 'p1',
            from: day,
            days: days,
            assetIdPool: const {'annoy_spit', 'annoy_jeek'},
            now: null);

    test('MT-01 工作日：白天/夜间任务落在新约定内，且白天**不喊话**', () {
      final list = tasksFor(DateTime(2026, 3, 10)); // 周二
      expect(list, isNotEmpty);
      final dayTasks = list.where((t) => t.name.contains('白天')).toList();
      final nightTasks = list.where((t) => t.name.contains('夜间')).toList();
      expect(dayTasks, isNotEmpty);
      expect(nightTasks, isNotEmpty);
      for (final t in dayTasks) {
        expect(t.trigger, isA<FixedOnceTrigger>());
        final at = (t.trigger as FixedOnceTrigger).at;
        expect(at.hour >= 6 && at.hour < 21, isTrue);
        // 昼夜导向核心：白天窗口 ttsWeight=0 ⇒ **永不喊话**（只音效/震动）。
        expect(t.actionType, isNot(ActionType.tts));
        if (t.action is PlayAudioAction) {
          final a = t.action as PlayAudioAction;
          expect(a.volumeMin, greaterThanOrEqualTo(0.7));
          expect(a.volumeMax, lessThanOrEqualTo(1.0));
          expect(a.durationSecMin, greaterThanOrEqualTo(3));
          expect(a.durationSecMax, lessThanOrEqualTo(8));
        } else {
          final v = t.action as RandomVibrateAction;
          expect(v.amplitudeMin, greaterThanOrEqualTo(0.8));
          expect(v.amplitudeMax, lessThanOrEqualTo(1.0));
        }
      }
      for (final t in nightTasks) {
        final at = (t.trigger as FixedOnceTrigger).at;
        expect(at.hour >= 21 || at.hour < 6, isTrue);
        if (t.action is PlayAudioAction) {
          final a = t.action as PlayAudioAction;
          expect(a.volumeMin, greaterThanOrEqualTo(0.1));
          expect(a.volumeMax, lessThanOrEqualTo(0.3));
          expect(a.durationSecMax, lessThanOrEqualTo(5));
        }
      }
    });

    test('MT-02 休息日默认关闭 → 无任务；开启后按休息日夜间区间', () {
      expect(tasksFor(DateTime(2026, 3, 14)), isEmpty); // 周六，休息日段未开

      final on = plan.copyWith(
        restdayNight: const CounterWindow(
            enabled: true, volumeMin: 0.1, volumeMax: 0.3, durationSecMax: 5),
      );
      final list = CounterPlanMaterializer.materialize(on,
          planId: 'p1',
          from: DateTime(2026, 3, 14),
          days: 1,
          assetIdPool: const {'annoy_spit'},
          now: null);
      final night = list.where((t) => t.name.contains('夜间')).toList();
      expect(night, isNotEmpty);
      for (final t in night) {
        if (t.action is PlayAudioAction) {
          final a = t.action as PlayAudioAction;
          expect(a.volumeMin, greaterThanOrEqualTo(0.1));
          expect(a.volumeMax, lessThanOrEqualTo(0.3));
        } else {
          expect((t.action as TtsAction).volume, lessThanOrEqualTo(0.3));
        }
      }
    });

    test('MT-03 命名空间前缀与可复现性', () {
      final a = tasksFor(DateTime(2026, 3, 10), days: 2);
      final b = tasksFor(DateTime(2026, 3, 10), days: 2);
      expect(a.map((t) => t.id).toList(), b.map((t) => t.id).toList());
      expect(
          a.map((t) => (t.trigger as FixedOnceTrigger).at.millisecondsSinceEpoch)
              .toList(),
          b.map((t) => (t.trigger as FixedOnceTrigger).at.millisecondsSinceEpoch)
              .toList());
      for (final t in a) {
        expect(isCounterTaskId(t.id), isTrue);
        expect(counterPlanIdOf(t.id), 'p1');
      }
    });

    test('MT-04 now 过滤：已过时刻不生成', () {
      final day = DateTime(2026, 3, 10);
      final noon = DateTime(2026, 3, 10, 12);
      final list = tasksFor(day).where((t) =>
          (t.trigger as FixedOnceTrigger).at.isAfter(noon)).toList();
      final filtered = CounterPlanMaterializer.materialize(plan,
          planId: 'p1',
          from: day,
          days: 1,
          assetIdPool: const {'annoy_spit'},
          now: noon);
      expect(filtered.length, list.length);
      for (final t in filtered) {
        expect((t.trigger as FixedOnceTrigger).at.isAfter(noon), isTrue);
      }
    });

    test('MT-05 无音源池且无 TTS → 不生成（避免到点必失败）', () {
      final bare = plan.copyWith(presetIds: const [], ttsTexts: const []);
      expect(
          CounterPlanMaterializer.materialize(bare,
              planId: 'p1',
              from: DateTime(2026, 3, 10),
              days: 1,
              assetIdPool: const {},
              now: null),
          isEmpty);
    });

    test('MT-06 无音源池但有 TTS → 绝不排音效；白天只震动、夜间以喊话为主', () {
      final list = CounterPlanMaterializer.materialize(plan,
          planId: 'p1',
          from: DateTime(2026, 3, 10),
          days: 1,
          assetIdPool: const {},
          now: null);
      expect(list, isNotEmpty);
      // 没有音源池 ⇒ 排音效动作等于"到点必失败"，必须一条都没有。
      expect(list.every((t) => t.actionType != ActionType.playAudio), isTrue,
          reason: '无音源池时绝不能排音效动作');
      // 只剩 TTS / 震动两类。
      expect(
          list.every((t) =>
              t.actionType == ActionType.tts ||
              t.actionType == ActionType.randomVibrate),
          isTrue,
          reason: '无音源池时只可能是喊话或震动');
      // 白天窗口 ttsWeight=0 ⇒ **白天绝不喊话**（只能震动）—— 这是昼夜导向的核心。
      final dayTasks = list.where((t) => t.name.contains('白天')).toList();
      expect(dayTasks, isNotEmpty);
      expect(
          dayTasks.every((t) => t.actionType == ActionType.randomVibrate), isTrue,
          reason: '白天 ttsWeight=0 ⇒ 永不喊话');
      // 夜间 ttsWeight 占主导 ⇒ 至少排出一条喊话。
      final nightTasks = list.where((t) => t.name.contains('夜间')).toList();
      expect(nightTasks, isNotEmpty);
      expect(nightTasks.any((t) => t.actionType == ActionType.tts), isTrue,
          reason: '夜间应以喊话为主');
    });
  });

  group('RD 本机随机生成', () {
    test('RD-01 可复现且合规', () {
      final a = CounterPlanRandom.generate(seed: 20261006);
      final b = CounterPlanRandom.generate(seed: 20261006);
      expect(a.toJson(), b.toJson());
      expect(a.validate(), isEmpty);
    });

    test('RD-02 区间落在用户约定内', () {
      for (var seed = 0; seed < 40; seed++) {
        final p = CounterPlanRandom.generate(seed: seed, restdayDay: true, restdayNight: true);
        expect(p.validate(), isEmpty, reason: 'seed=$seed');
        // 白天：大音量噪音 + 不喊话（ttsWeight=0）+ 少量高强度震动。
        expect(p.workdayDay.volumeMin, greaterThanOrEqualTo(0.7));
        expect(p.workdayDay.volumeMax, lessThanOrEqualTo(1.0));
        expect(p.workdayDay.durationSecMin, greaterThanOrEqualTo(3));
        expect(p.workdayDay.durationSecMax, lessThanOrEqualTo(8));
        expect(p.workdayDay.ttsWeight, 0.0);
        expect(p.workdayDay.vibrateAmplitudeMin, greaterThanOrEqualTo(0.8));
        // 夜间：轻幅度噪音 + 以喊话为主 + 震动配合。
        expect(p.workdayNight.volumeMin, greaterThanOrEqualTo(0.1));
        expect(p.workdayNight.volumeMax, lessThanOrEqualTo(0.3));
        expect(p.workdayNight.durationSecMax, lessThanOrEqualTo(5));
        expect(p.workdayNight.ttsWeight, greaterThan(0));
        expect(p.workdayNight.vibrateWeight, greaterThan(0));
        expect(p.restdayNight.volumeMin, greaterThanOrEqualTo(0.1));
        expect(p.restdayNight.volumeMax, lessThanOrEqualTo(0.3));
        expect(p.ttsTexts, isNotEmpty);
        expect(p.presetIds, isNotEmpty);
      }
    });

    test('RD-03 休息日默认关闭', () {
      final p = CounterPlanRandom.generate(seed: 7);
      expect(p.restdayDay.enabled, isFalse);
      expect(p.restdayNight.enabled, isFalse);
    });

    test('RD-04 不同种子给出不同计划', () {
      final a = CounterPlanRandom.generate(seed: 1);
      final b = CounterPlanRandom.generate(seed: 2);
      expect(a.toJson(), isNot(equals(b.toJson())));
    });
  });

  group('PP 生成参数（参数化选择）', () {
    test('PP-01 出厂参数=昼夜导向且通过校验', () {
      final p = CounterPlanParams.defaults();
      expect(p.validate(), isEmpty);
      // 白天（06:00–21:00）：大音量噪音 + **不喊话**（ttsWeight=0）+ 少量高强度震动。
      expect(p.workdayDay.volumeMin, 0.7);
      expect(p.workdayDay.volumeMax, 1.0);
      expect(p.workdayDay.durationSecMin, 3);
      expect(p.workdayDay.durationSecMax, 8);
      expect(p.workdayDay.ttsWeight, 0.0);
      expect(p.workdayDay.vibrateWeight, greaterThan(0));
      // 夜间：轻幅度噪音 + 以喊话为主 + 震动配合。
      expect(p.workdayNight.volumeMin, 0.1);
      expect(p.workdayNight.volumeMax, 0.3);
      expect(p.workdayNight.ttsWeight, greaterThan(0));
      expect(p.restdayDay.enabled, isFalse);
      expect(p.restdayNight.enabled, isFalse);
      expect(p.cooldownSecMin, 600);
      expect(p.cooldownSecMax, 2400);
      expect(p.dayStartHour, 6);
      expect(p.dayEndHour, 21);
    });

    test('PP-02 toJson/fromJson 往返一致（含各区间与开关）', () {
      final p = CounterPlanParams.defaults().copyWith(
        dayStartHour: 7,
        dayEndHour: 22,
        cooldownSecMin: 300,
        cooldownSecMax: 900,
        workdayDay: const PlanWindowParams(
            volumeMin: 0.4,
            volumeMax: 0.9,
            durationSecMin: 2,
            durationSecMax: 10,
            actionsPerHourMin: 2,
            actionsPerHourMax: 5),
        restdayDay: const PlanWindowParams(
            enabled: true, volumeMin: 0.2, volumeMax: 0.6),
      );
      final back =
          CounterPlanParams.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(back.toJson(), p.toJson());
      expect(back.validate(), isEmpty);
    });

    test('PP-03 fromJson 容错：脏类型回默认、越界夹紧、min>max 交换', () {
      final p = CounterPlanParams.fromJson(<String, dynamic>{
        'schema': CounterPlanParams.schemaId,
        'dayStartHour': 99,
        'cooldownSecMin': -5,
        'workday': {
          'day': {
            'volumeMin': 1.8,
            'volumeMax': -3,
            'durationSecMax': 9999,
            'actionsPerHourMin': 9,
            'actionsPerHourMax': 2,
          },
        },
        'presetIds': <dynamic>['a', '', 5, 'b'],
      });
      expect(p.dayStartHour, 23);
      expect(p.cooldownSecMin, 0);
      expect(p.workdayDay.volumeMin, 0.0);
      expect(p.workdayDay.volumeMax, 1.0);
      expect(p.workdayDay.durationSecMax, PlanWindowParams.maxDurationSec);
      // 9 > 2 → 交换
      expect(p.workdayDay.actionsPerHourMin, 2);
      expect(p.workdayDay.actionsPerHourMax, 9);
      expect(p.presetIds, const ['a', 'b']);
    });

    test('PP-04 validate 抓出各类问题', () {
      final off = CounterPlanParams.defaults().copyWith(
        workdayDay: const PlanWindowParams(enabled: false),
        workdayNight: const PlanWindowParams(enabled: false),
      );
      expect(off.validate().any((e) => e.contains('至少需要启用')), isTrue);

      final badVol = CounterPlanParams.defaults().copyWith(
        workdayDay: const PlanWindowParams(volumeMin: 0.9, volumeMax: 0.2),
      );
      expect(badVol.validate().any((e) => e.contains('下限不能大于上限')), isTrue);

      final badGap = CounterPlanParams.defaults()
          .copyWith(cooldownSecMin: 900, cooldownSecMax: 300);
      expect(
          badGap.validate().any((e) => e.contains('动作间隔区间下限不能大于上限')),
          isTrue);

      final same =
          CounterPlanParams.defaults().copyWith(dayStartHour: 8, dayEndHour: 8);
      expect(same.validate().any((e) => e.contains('不能相同')), isTrue);

      final empty = CounterPlanParams.defaults()
          .copyWith(presetIds: const [], ttsTexts: const []);
      expect(empty.validate().any((e) => e.contains('动作池为空')), isTrue);
    });

    test('PP-05 toPromptHint 含用户调整后的区间（AI 与本机同源）', () {
      final p = CounterPlanParams.defaults().copyWith(
        cooldownSecMin: 120,
        cooldownSecMax: 480,
        workdayDay: const PlanWindowParams(
            volumeMin: 0.6, volumeMax: 0.9, durationSecMin: 4, durationSecMax: 6),
      );
      final hint = p.toPromptHint();
      expect(hint, contains('0.60-0.90'));
      expect(hint, contains('4-6'));
      expect(hint, contains('120-480'));
    });

    test('PP-06 summary 列出四时段开关与区间', () {
      final s = CounterPlanParams.defaults().summary();
      expect(s, contains('工作日·白天'));
      expect(s, contains('休息日·夜间：不反击'));
    });
  });

  group('PP2 生成参数：精确校验分支与取值', () {
    test('PP-07 validate 精确分支（schema / 间隔越界 / 文案过长 / 区间越界）', () {
      const badSchema = CounterPlanParams(schema: 'other/9');
      expect(badSchema.validate().any((e) => e.contains('schema 不匹配')), isTrue);

      const badCdMin = CounterPlanParams(cooldownSecMin: -1);
      expect(badCdMin.validate().any((e) => e.contains('动作间隔区间下限')), isTrue);

      const badCdMax = CounterPlanParams(
          cooldownSecMax: CounterPlanParams.maxCooldownSec + 1);
      expect(badCdMax.validate().any((e) => e.contains('动作间隔区间上限')), isTrue);

      const badVol =
          CounterPlanParams(workdayDay: PlanWindowParams(volumeMin: -0.5));
      expect(badVol.validate().any((e) => e.contains('音量区间必须在')), isTrue);

      const badDur = CounterPlanParams(
          workdayDay: PlanWindowParams(durationSecMin: 700, durationSecMax: 5));
      expect(badDur.validate().any((e) => e.contains('时长区间必须在')), isTrue);

      const swapDur = CounterPlanParams(
          workdayDay: PlanWindowParams(durationSecMin: 8, durationSecMax: 3));
      expect(
          swapDur.validate().any((e) => e.contains('时长区间下限不能大于上限')), isTrue);

      const badAct =
          CounterPlanParams(workdayDay: PlanWindowParams(actionsPerHourMin: 99));
      expect(
          badAct.validate().any((e) => e.contains('每小时次数区间必须在')), isTrue);

      const swapAct = CounterPlanParams(
          workdayDay:
              PlanWindowParams(actionsPerHourMin: 5, actionsPerHourMax: 2));
      expect(
          swapAct.validate().any((e) => e.contains('每小时次数区间下限不能大于上限')),
          isTrue);

      final longTts = CounterPlanParams(
          ttsTexts: <String>['x' * (CounterPlan.maxTtsTextLen + 1)]);
      expect(longTts.validate().any((e) => e.contains('TTS 文案过长')), isTrue);

      expect(CounterPlanParams.defaults().isValid, isTrue);
      expect(badSchema.isValid, isFalse);
    });

    test('PP-08 windowFor 取四组合对应时段', () {
      final p = CounterPlanParams.defaults();
      expect(p.windowFor(DayKind.workday, isNight: false), same(p.workdayDay));
      expect(p.windowFor(DayKind.workday, isNight: true), same(p.workdayNight));
      expect(p.windowFor(DayKind.restday, isNight: false), same(p.restdayDay));
      expect(p.windowFor(DayKind.restday, isNight: true), same(p.restdayNight));
    });

    test('PP-09 PlanWindowParams.copyWith 生效且 clamped 兜底', () {
      const w = PlanWindowParams();
      expect(w.copyWith(enabled: false).enabled, isFalse);
      // copyWith 内部已 clamped：volumeMin=9 被夹到 1.0 后超过原 volumeMax(0.8)，
      // 于是 min/max 交换 → min 落到 0.8、max 落到 1.0。
      expect(w.copyWith(volumeMin: 9).volumeMin, 0.8);
      expect(w.copyWith(volumeMin: 9).volumeMax, 1.0);
      expect(w.copyWith(durationSecMin: 0).clamped().durationSecMin, 1);
      expect(w.copyWith(actionsPerHourMax: 99).clamped().actionsPerHourMax,
          PlanWindowParams.maxActionsPerHour);
    });
  });

  group('RD2 参数化随机', () {
    test('RD-05 自定义参数：结果严格落在用户区间内', () {
      const params = CounterPlanParams(
        cooldownSecMin: 120,
        cooldownSecMax: 200,
        dayStartHour: 9,
        dayEndHour: 18,
        workdayDay: PlanWindowParams(
            volumeMin: 0.6,
            volumeMax: 0.9,
            durationSecMin: 4,
            durationSecMax: 6,
            actionsPerHourMin: 2,
            actionsPerHourMax: 4),
      );
      for (var seed = 0; seed < 30; seed++) {
        final p = CounterPlanRandom.generate(seed: seed, params: params);
        expect(p.validate(), isEmpty, reason: 'seed=$seed');
        expect(p.dayStartHour, 9);
        expect(p.dayEndHour, 18);
        expect(p.cooldownSec, inInclusiveRange(120, 200));
        expect(p.workdayDay.volumeMin, inInclusiveRange(0.6, 0.9));
        expect(p.workdayDay.volumeMax,
            inInclusiveRange(p.workdayDay.volumeMin, 0.9));
        expect(p.workdayDay.durationSecMin, inInclusiveRange(4, 6));
        expect(p.workdayDay.durationSecMax,
            inInclusiveRange(p.workdayDay.durationSecMin, 6));
        expect(p.workdayDay.actionsPerHour, inInclusiveRange(2, 4));
      }
    });

    test('RD-06 参数开启休息日两段 → 生成结果含休息日反击', () {
      final params = CounterPlanParams.defaults().copyWith(
        restdayDay:
            const PlanWindowParams(enabled: true, volumeMin: 0.2, volumeMax: 0.6),
        restdayNight: const PlanWindowParams(
            enabled: true, volumeMin: 0.05, volumeMax: 0.2),
      );
      final p = CounterPlanRandom.generate(seed: 11, params: params);
      expect(p.restdayDay.enabled, isTrue);
      expect(p.restdayNight.enabled, isTrue);
      expect(p.restdayDay.volumeMin, inInclusiveRange(0.2, 0.6));
      expect(p.restdayNight.volumeMax, inInclusiveRange(0.05, 0.2));
      expect(p.validate(), isEmpty);
    });

    test('RD-07 同种子同参数 → 完全可复现', () {
      const params = CounterPlanParams(cooldownSecMin: 300, cooldownSecMax: 600);
      final a = CounterPlanRandom.generate(seed: 3, params: params);
      final b = CounterPlanRandom.generate(seed: 3, params: params);
      expect(a.toJson(), b.toJson());
    });
  });

  group('SCH 排期模式（生成范围 / 条数）', () {
    final base = CounterPlan.defaults().copyWith(
      presetIds: const ['annoy_spit'],
      ttsTexts: const ['干啥呢？'],
      cooldownSec: 60,
    );
    const pool = <String>{'annoy_spit'};

    List<Task> mat(CounterPlan p, DateTime from, {int days = 7}) =>
        CounterPlanMaterializer.materialize(p,
            planId: 'sched',
            from: from,
            days: days,
            assetIdPool: pool,
            now: null);

    // 用任务 id 里编码的**日历日**（夜间时段会跨到次日凌晨，不能看 at）。
    Set<String> dayKeys(List<Task> l) => l
        .map((t) => ChinaHolidays.isoDate(dayOfCounterTaskId(t.id)!))
        .toSet();

    test('SCH-01 默认排期 = 循环随机，覆盖 horizon 内的所有工作日', () {
      expect(base.scheduleMode, PlanScheduleMode.recurringRandom);
      expect(base.weekdays, const <int>[1, 2, 3, 4, 5, 6, 7]);
      final l = mat(base, DateTime(2026, 3, 9)); // 周一
      // 3/14、3/15 为休息日，默认休息日两段关闭 → 无任务。
      expect(dayKeys(l), {
        '2026-03-09',
        '2026-03-10',
        '2026-03-11',
        '2026-03-12',
        '2026-03-13',
      });
    });

    test('SCH-02 循环随机 + 指定星期：只在所选星期生成', () {
      final p = base.copyWith(weekdays: const <int>[1, 3, 5]); // 一/三/五
      final l = mat(p, DateTime(2026, 3, 9));
      expect(dayKeys(l), {'2026-03-09', '2026-03-11', '2026-03-13'});
    });

    test('SCH-03 单次：整份计划恰好 1 条', () {
      final p = base.copyWith(scheduleMode: PlanScheduleMode.single);
      expect(mat(p, DateTime(2026, 3, 9)).length, 1);
    });

    test('SCH-04 几次：恰好 N 条', () {
      final p = base.copyWith(
          scheduleMode: PlanScheduleMode.several, occurrenceCount: 5);
      expect(mat(p, DateTime(2026, 3, 9)).length, 5);
    });

    test('SCH-05 几日：只覆盖前 N 个日历日', () {
      final p = base.copyWith(
          scheduleMode: PlanScheduleMode.severalDays, spanDays: 2);
      expect(dayKeys(mat(p, DateTime(2026, 3, 9))), {'2026-03-09', '2026-03-10'});
    });

    test('SCH-06 指定日期：只在指定日生成', () {
      final p = base.copyWith(
          scheduleMode: PlanScheduleMode.specificDate,
          specificDate: '2026-03-12');
      expect(dayKeys(mat(p, DateTime(2026, 3, 9))), {'2026-03-12'});
    });

    test('SCH-07 日期区间：只在区间内生成', () {
      final p = base.copyWith(
          scheduleMode: PlanScheduleMode.dateRange,
          rangeStart: '2026-03-12',
          rangeEnd: '2026-03-13');
      expect(dayKeys(mat(p, DateTime(2026, 3, 9))), {'2026-03-12', '2026-03-13'});
    });

    test('SCH-08 有界/循环判定', () {
      expect(base.isRecurring, isTrue);
      expect(base.copyWith(scheduleMode: PlanScheduleMode.single).isRecurring,
          isFalse);
      expect(base.copyWith(scheduleMode: PlanScheduleMode.dateRange).isRecurring,
          isFalse);
    });

    test('SCH-09 生成参数 ↔ JSON 往返（含排期字段）', () {
      final p = CounterPlanParams.defaults().copyWith(
        scheduleMode: PlanScheduleMode.dateRange,
        rangeStart: '2026-03-12',
        rangeEnd: '2026-03-20',
        occurrenceCount: 7,
        spanDays: 5,
        weekdays: const <int>[1, 2, 3],
      );
      final back = CounterPlanParams.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(back.scheduleMode, PlanScheduleMode.dateRange);
      expect(back.rangeStart, '2026-03-12');
      expect(back.rangeEnd, '2026-03-20');
      expect(back.occurrenceCount, 7);
      expect(back.spanDays, 5);
      expect(back.weekdays, const <int>[1, 2, 3]);
      expect(back.validate(), isEmpty);
    });

    test('SCH-10 计划 ↔ JSON 往返（排期字段随计划落库）', () {
      final p = base.copyWith(
        scheduleMode: PlanScheduleMode.specificDate,
        specificDate: '2026-03-12',
        occurrenceCount: 9,
        spanDays: 4,
        weekdays: const <int>[6, 7],
      );
      final back = CounterPlan.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(back.scheduleMode, PlanScheduleMode.specificDate);
      expect(back.specificDate, '2026-03-12');
      expect(back.occurrenceCount, 9);
      expect(back.spanDays, 4);
      expect(back.weekdays, const <int>[6, 7]);
    });

    test('SCH-11 validate 抓出排期问题', () {
      expect(
          base
              .copyWith(scheduleMode: PlanScheduleMode.specificDate)
              .validate()
              .any((e) => e.contains('指定日期')),
          isTrue);
      expect(
          base
              .copyWith(
                  scheduleMode: PlanScheduleMode.dateRange,
                  rangeStart: '2026-03-20',
                  rangeEnd: '2026-03-12')
              .validate()
              .any((e) => e.contains('起始日期不能晚于')),
          isTrue);
      expect(
          CounterPlanParams.defaults()
              .copyWith(
                  scheduleMode: PlanScheduleMode.several,
                  occurrenceCount: 999)
              .validate()
              .any((e) => e.contains('「几次」的条数')),
          isTrue);
      // 循环随机把星期清空 → 报错（渲染层保证至少留一天，这里是兜底校验）。
      expect(
          const CounterPlanParams(
                  scheduleMode: PlanScheduleMode.recurringRandom,
                  weekdays: <int>[])
              .validate()
              .any((e) => e.contains('「循环随机」')),
          isTrue);
    });

    test('SCH-12 本机随机生成带上排期字段并按其物化', () {
      final p = CounterPlanRandom.generate(
          seed: 7,
          params: CounterPlanParams.defaults().copyWith(
              scheduleMode: PlanScheduleMode.several, occurrenceCount: 4));
      expect(p.scheduleMode, PlanScheduleMode.several);
      expect(p.occurrenceCount, 4);
      final l = mat(p, DateTime(2026, 3, 9));
      expect(l.length, 4);
    });
  });

  group('COV67 排期校验/摘要的剩余分支', () {
    CounterPlan base() => CounterPlan.defaults().copyWith(
          presetIds: const ['annoy_spit'],
          ttsTexts: const ['干啥呢？'],
        );

    test('COV67-01 CounterPlan.validate：几次/几日越界、区间缺失、有界模式 break', () {
      // occurrenceCount 越界（counter_plan.dart:401）
      expect(
          base()
              .copyWith(occurrenceCount: 999)
              .validate()
              .any((e) => e.contains('「几次」的条数')),
          isTrue);
      // spanDays 越界（404）
      expect(
          base()
              .copyWith(spanDays: 999)
              .validate()
              .any((e) => e.contains('「几日」的天数')),
          isTrue);
      // dateRange 缺起止日期（415）：默认 rangeStart/rangeEnd 为 null
      expect(
          base()
              .copyWith(scheduleMode: PlanScheduleMode.dateRange)
              .validate()
              .any((e) => e.contains('日期区间')),
          isTrue);
      // recurringRandom 星期集合为空（422）
      expect(
          base()
              .copyWith(
                  scheduleMode: PlanScheduleMode.recurringRandom,
                  weekdays: const <int>[])
              .validate()
              .any((e) => e.contains('循环随机')),
          isTrue);
      // 有界模式单次/几次/几日走 break 分支（424–426）
      for (final m in const [
        PlanScheduleMode.single,
        PlanScheduleMode.several,
        PlanScheduleMode.severalDays,
      ]) {
        expect(base().copyWith(scheduleMode: m).validate(), isEmpty,
            reason: '$m 是合法有界排期，不应报错');
      }
    });

    test('COV67-02 CounterPlanParams.validate：几日越界、指定日期/区间非法、severalDays',
        () {
      final d = CounterPlanParams.defaults();
      // spanDays 越界（counter_plan_params.dart:410）
      expect(
          d.copyWith(spanDays: 999).validate().any((e) => e.contains('「几日」的天数')),
          isTrue);
      // specificDate 非法（414–415）
      expect(
          d
              .copyWith(
                  scheduleMode: PlanScheduleMode.specificDate, specificDate: 'bad')
              .validate()
              .any((e) => e.contains('指定日期')),
          isTrue);
      // dateRange 缺起止（421）
      expect(
          d
              .copyWith(scheduleMode: PlanScheduleMode.dateRange)
              .validate()
              .any((e) => e.contains('日期区间')),
          isTrue);
      // dateRange 起晚于止（423）
      expect(
          d
              .copyWith(
                  scheduleMode: PlanScheduleMode.dateRange,
                  rangeStart: '2026-03-20',
                  rangeEnd: '2026-03-12')
              .validate()
              .any((e) => e.contains('起始日期不能晚于')),
          isTrue);
      // severalDays 走 break 分支（431）
      expect(
          d.copyWith(scheduleMode: PlanScheduleMode.severalDays).validate(),
          isEmpty);
    });

    test('COV67-03 scheduleSummary / toPromptHint 的指定日期与区间分支', () {
      final d = CounterPlanParams.defaults();
      // scheduleSummary: specificDate（446）与 dateRange（448）
      expect(
          d
              .copyWith(
                  scheduleMode: PlanScheduleMode.specificDate,
                  specificDate: '2026-03-12')
              .scheduleSummary(),
          contains('2026-03-12'));
      expect(
          d
              .copyWith(
                  scheduleMode: PlanScheduleMode.dateRange,
                  rangeStart: '2026-03-12',
                  rangeEnd: '2026-03-13')
              .scheduleSummary(),
          contains('2026-03-12'));
      // toPromptHint: dateRange（483）
      expect(
          d
              .copyWith(
                  scheduleMode: PlanScheduleMode.dateRange,
                  rangeStart: '2026-03-12',
                  rangeEnd: '2026-03-13')
              .toPromptHint(),
          contains('日期区间'));
    });
  });
}