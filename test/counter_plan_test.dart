import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/china_holidays.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_random.dart';

void main() {
  group('CP schema 与校验', () {
    test('CP-01 出厂默认计划通过校验且区间符合约定', () {
      final p = CounterPlan.defaults();
      expect(p.validate(), isEmpty);
      // 工作日白天 50–80% / 3–8s
      expect(p.workdayDay.volumeMin, 0.5);
      expect(p.workdayDay.volumeMax, 0.8);
      expect(p.workdayDay.durationSecMin, 3);
      expect(p.workdayDay.durationSecMax, 8);
      // 工作日夜间 30–50% / 3–5s
      expect(p.workdayNight.volumeMin, 0.3);
      expect(p.workdayNight.volumeMax, 0.5);
      expect(p.workdayNight.durationSecMax, 5);
      // 休息日两段默认关闭（可选）
      expect(p.restdayDay.enabled, isFalse);
      expect(p.restdayNight.enabled, isFalse);
      // 休息日夜间 10–30% / 3–5s
      expect(p.restdayNight.volumeMin, 0.1);
      expect(p.restdayNight.volumeMax, 0.3);
      expect(p.dayStartHour, 8);
      expect(p.dayEndHour, 20);
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

    test('CP-08 describeWindow 输出音量/时长/次数（不区分 enabled）', () {
      const w = CounterWindow(
          volumeMin: 0.5,
          volumeMax: 0.8,
          durationSecMin: 3,
          durationSecMax: 8,
          actionsPerHour: 2);
      expect(describeWindow(w), '50%–80% · 3–8 秒 · 每小时 2 次');
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

    test('MT-01 工作日：白天/夜间任务的区间严格落在约定值内', () {
      final list = tasksFor(DateTime(2026, 3, 10)); // 周二
      expect(list, isNotEmpty);
      final dayTasks = list.where((t) => t.name.contains('白天')).toList();
      final nightTasks = list.where((t) => t.name.contains('夜间')).toList();
      expect(dayTasks, isNotEmpty);
      expect(nightTasks, isNotEmpty);
      for (final t in dayTasks) {
        expect(t.trigger, isA<FixedOnceTrigger>());
        final at = (t.trigger as FixedOnceTrigger).at;
        expect(at.hour >= 8 && at.hour < 20, isTrue);
        if (t.action is PlayAudioAction) {
          final a = t.action as PlayAudioAction;
          expect(a.volumeMin, greaterThanOrEqualTo(0.5));
          expect(a.volumeMax, lessThanOrEqualTo(0.8));
          expect(a.durationSecMin, greaterThanOrEqualTo(3));
          expect(a.durationSecMax, lessThanOrEqualTo(8));
        }
      }
      for (final t in nightTasks) {
        final at = (t.trigger as FixedOnceTrigger).at;
        expect(at.hour >= 20 || at.hour < 8, isTrue);
        if (t.action is PlayAudioAction) {
          final a = t.action as PlayAudioAction;
          expect(a.volumeMin, greaterThanOrEqualTo(0.3));
          expect(a.volumeMax, lessThanOrEqualTo(0.5));
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

    test('MT-06 无音源池但有 TTS → 全部走 TTS', () {
      final list = CounterPlanMaterializer.materialize(plan,
          planId: 'p1',
          from: DateTime(2026, 3, 10),
          days: 1,
          assetIdPool: const {},
          now: null);
      expect(list, isNotEmpty);
      expect(list.every((t) => t.actionType == ActionType.tts), isTrue);
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
        expect(p.workdayDay.volumeMin, greaterThanOrEqualTo(0.5));
        expect(p.workdayDay.volumeMax, lessThanOrEqualTo(0.8));
        expect(p.workdayDay.durationSecMin, greaterThanOrEqualTo(3));
        expect(p.workdayDay.durationSecMax, lessThanOrEqualTo(8));
        expect(p.workdayNight.volumeMin, greaterThanOrEqualTo(0.3));
        expect(p.workdayNight.volumeMax, lessThanOrEqualTo(0.5));
        expect(p.workdayNight.durationSecMax, lessThanOrEqualTo(5));
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
}