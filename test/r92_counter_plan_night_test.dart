import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/domain/models/counter_plan_params.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_random.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';

/// R92 反击计划「夜间不生成」根因定死 + 回归锁。
///
/// ## 用户报障（2026-10-20）
/// 「一键生成反击方案后，晚 10 点到早 7 点无论修改任何设置都不生成动作」。
///
/// ## 根因
/// 物化出来的反击任务**硬编码** `quietPolicy: QuietPolicy.skip`
/// （`counter_plan_materializer.dart:248`，fail-safe 方向）。`ScheduleEngine`
/// 的 `_applyQuiet` 判据是：
///
/// ```dart
/// final exempt = taskExemptOverride ?? allowQuietExempt;   // 任务级 null ⇒ 主开关
/// … 命中免打扰窗口后：exempt ? 照计划 : (skip ? null : 平移到窗口结束)
/// ```
///
/// 主开关（`quietExemptMaster`）默认 **false** ⇒ 命中 `[22:00, 07:00)` 的
/// **夜间条目整条被丢弃**（`continue`，连 occurrence 都不落库）。于是
/// 「工作日·夜间 / 休息日·夜间」两个开关**看起来有用、实际无用**：
/// 不授权夜间豁免时，夜间窗口永远零条目 —— 用户改任何参数都不生成。
///
/// ## 为什么不能反向修（直接改 skip）
/// `docs/08` 的合规护栏：22:00–07:00 强制免打扰，只能调窄不能调宽；
/// 夜间放行的唯一合法通路是用户**显式授权**的「夜间独立豁免」主开关
/// （`docs/20 §8.1`：主开关 = 全量默认值 + 任务级双向覆盖）。
/// 所以修法是**让依赖可见 + 一键授权**（见 `settings_screen.dart` 的横幅），
/// 而不是把 fail-safe 的 skip 放开。
void main() {
  /// 取一个「已物化 + 启用 + 免打扰时段内」的反击任务。
  ///
  /// [allowMaster] 经 CounterPlanRandom 生成（白天 06–21、夜间 21–06 默认都开），
  /// 因此一定能拿到夜间任务；返回它和它自己的 fireAt。
  ({Task task, DateTime fireAt}) nightCounterTask() {
    final plan = CounterPlanRandom.generate(seed: 20261020);
    final tasks = CounterPlanMaterializer.materialize(
      plan,
      planId: 'p1',
      from: DateTime(2026, 10, 20, 12),
      days: 7,
      assetIdPool: const <String>{'annoy_spit'},
      now: null,
    );
    // ⚠️ 计划夜间窗口是 [21:00, 06:00)，而合规免打扰窗口是 [22:00, 07:00)
    // —— 只有落在**交集**里的时刻才会被 `_applyQuiet` 拦下。这正是
    // "计划看起来有夜间、晚上却没有动作"的几何形状。
    final hit = tasks.where((t) {
      if (!t.name.contains('夜间')) return false;
      final h = (t.trigger as FixedOnceTrigger).at.hour;
      return h >= 22 || h < 7;
    }).toList();
    expect(hit, isNotEmpty,
        reason: '必须存在落在 22:00–07:00 免打扰窗口内的夜间任务');
    final t = hit.first;
    final at = (t.trigger as FixedOnceTrigger).at;
    expect(at.hour >= 22 || at.hour < 7, isTrue);
    return (task: t, fireAt: at);
  }

  group('R92 夜间不生成：根因与合法通路', () {
    test('CPN-01 主开关关闭（默认）= 夜间条目整条丢弃 —— 这就是报障根因', () {
      final c = nightCounterTask();
      final entries = const ScheduleEngine(
        quietStartHour: 22,
        quietEndHour: 7,
      ).materialize(c.task, c.fireAt.subtract(const Duration(minutes: 5)));
      expect(entries, isEmpty,
          reason: 'fail-safe：未授权夜间豁免时，免打扰时段内不得产生任何计划');
    });

    test('CPN-02 授权主开关 ⇒ 夜间按原计划生成，且标记为已豁免', () {
      final c = nightCounterTask();
      final entries = const ScheduleEngine(
        quietStartHour: 22,
        quietEndHour: 7,
        allowQuietExempt: true,
      ).materialize(c.task, c.fireAt.subtract(const Duration(minutes: 5)));
      expect(entries.length, 1,
          reason: '授权后夜间必须真生成 —— 这正是用户要的行为');
      expect(entries.single.fireAt, c.fireAt);
      expect(entries.single.quietExempted, isTrue,
          reason: '豁免是削弱护栏的行为，必须可计数（quietExempt 审计）');
    });

    test('CPN-03 任务级强制豁免可双向覆盖（主开关关也能放行）', () {
      final c = nightCounterTask();
      final forced = c.task.copyWith(quietExempt: true);
      final entries = const ScheduleEngine(quietStartHour: 22, quietEndHour: 7)
          .materialize(forced, c.fireAt.subtract(const Duration(minutes: 5)));
      expect(entries.length, 1);
      expect(entries.single.quietExempted, isTrue);
    });

    test('CPN-04 白天条目不受免打扰窗口影响（两种授权态都生成）', () {
      final plan = CounterPlanRandom.generate(seed: 20261020);
      final tasks = CounterPlanMaterializer.materialize(
        plan,
        planId: 'p1',
        from: DateTime(2026, 10, 20, 12),
        days: 1,
        assetIdPool: const <String>{'annoy_spit'},
        now: null,
      );
      // ⚠️ 白天窗口 [06:00, 21:00) 与免打扰窗口 [22:00, 07:00) 有
      // [06:00, 07:00) 的交集 —— 落在交集中的白天条目同样会被 `_applyQuiet`
      // 处理。这里只取 **07:00 以后** 的白天条目，才能干净地断言"白天不受影响"。
      final day = tasks.where((t) {
        if (!t.name.contains('白天')) return false;
        final h = (t.trigger as FixedOnceTrigger).at.hour;
        return h >= 7 && h < 22;
      }).toList();
      expect(day, isNotEmpty, reason: '应存在 07:00–22:00 之间的白天条目');
      final t = day.first;
      final at = (t.trigger as FixedOnceTrigger).at;
      for (final allow in const [false, true]) {
        final entries = ScheduleEngine(
                quietStartHour: 22, quietEndHour: 7, allowQuietExempt: allow)
            .materialize(t, at.subtract(const Duration(minutes: 5)));
        expect(entries.length, 1, reason: '白天不该被免打扰窗口吞掉（allow=$allow）');
        expect(entries.single.fireAt, at);
        expect(entries.single.quietExempted, isFalse);
      }
    });

    test('CPN-05 生成参数的两个「夜间」开关确实进产物（不是死字段）', () {
      final base = CounterPlanParams.defaults();
      final on = CounterPlanRandom.generate(
        seed: 7,
        params: base.copyWith(
          workdayNight: base.workdayNight.copyWith(enabled: false),
          restdayNight: base.restdayNight.copyWith(enabled: true),
        ),
      );
      expect(on.workdayNight.enabled, isFalse);
      expect(on.restdayNight.enabled, isTrue,
          reason: '「夜间」开关必须一路带到产物窗口');
      expect(on.dayStartHour, base.dayStartHour);
      expect(on.dayEndHour, base.dayEndHour);

      // 反向：两段夜间全关 ⇒ 物化结果里不该再出现夜间任务。
      final allOff = CounterPlanRandom.generate(
        seed: 7,
        params: base.copyWith(
          workdayNight: base.workdayNight.copyWith(enabled: false),
          restdayNight: base.restdayNight.copyWith(enabled: false),
        ),
      );
      final tasksOff = CounterPlanMaterializer.materialize(
        allOff,
        planId: 'p1',
        from: DateTime(2026, 10, 20, 12),
        days: 1,
        assetIdPool: const <String>{'annoy_spit'},
        now: null,
      );
      expect(tasksOff.where((t) => t.name.contains('夜间')), isEmpty,
          reason: '夜间开关全关就该真的没有夜间任务（否则还是死字段）');
    });

    test('CPN-06 合规默认窗口正是用户报障的 22:00–07:00', () {
      expect(ComplianceGuardrails.defaultQuietStartHour, 22);
      expect(ComplianceGuardrails.defaultQuietEndHour, 7,
          reason: '默认免打扰窗口 = 报障所说的"晚10点到早7点"');
    });
  });
}
