import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/core/utils/random.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';

Task _task(TriggerConfig trigger,
    {String id = 'task-1', QuietPolicy quiet = QuietPolicy.skip}) {
  final now = DateTime.now();
  return Task(
    id: id,
    name: '测试任务',
    enabled: true,
    triggerType: TriggerType.randomWindow,
    trigger: trigger,
    actionType: ActionType.playAudio,
    action: const PlayAudioAction(),
    assetIds: const [],
    cooldownSec: 300,
    quietPolicy: quiet,
    priority: 0,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('随机工具', () {
    test('planSeed 稳定：同任务同日相同，跨日/跨任务不同', () {
      final d1 = DateTime(2026, 9, 12);
      final d2 = DateTime(2026, 9, 13);
      expect(planSeed('a', d1), planSeed('a', d1));
      expect(planSeed('a', d1), isNot(planSeed('a', d2)));
      expect(planSeed('a', d1), isNot(planSeed('b', d1)));
    });

    test('sampleInWindow 满足最小间隔与窗口约束', () {
      final rng = Random(42);
      final r = sampleInWindow(
        n: 5,
        window: const Duration(hours: 8),
        minGap: const Duration(minutes: 30),
        rng: rng,
      );
      expect(r.length, 5);
      for (var i = 1; i < r.length; i++) {
        expect(r[i] - r[i - 1] >= const Duration(minutes: 30), isTrue,
            reason: '相邻间隔必须 >= 30min: $r');
      }
      expect(r.last <= const Duration(hours: 8), isTrue);
    });

    test('pickWeighted 分布合理性（大样本）', () {
      final rng = Random(7);
      var a = 0;
      for (var i = 0; i < 10000; i++) {
        if (pickWeighted(['a', 'b'], [3.0, 1.0], rng) == 'a') a++;
      }
      expect(a / 10000, inInclusiveRange(0.72, 0.78)); // 期望 0.75
    });
  });

  group('调度引擎', () {
    const engine = ScheduleEngine();

    test('每日触发：正确生成多条目并有序', () {
      final now = DateTime(2026, 9, 12, 8);
      final t = _task(const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)));
      final list = engine.materialize(t, now);
      // 视界 48h = 9/12 08:00 ~ 9/14 08:00：含 9/12、9/13 的 10:00 两条
      // （9/14 10:00 已超出视界右端）。
      expect(list.length, 2);
      for (var i = 1; i < list.length; i++) {
        expect(list[i].fireAt.isAfter(list[i - 1].fireAt), isTrue);
      }
      expect(list.first.fireAt.hour, 10);
      expect(list.first.fireAt.day, 12);
      expect(list.last.fireAt.day, 13);
    });

    test('随机窗口：确定性（幂等）且落在窗口内', () {
      final now = DateTime(2026, 9, 12, 0);
      final t = _task(RandomWindowTrigger(
        dateRange:
            DateRange(start: DateTime(2026, 9, 12), end: DateTime(2026, 9, 14)),
        windowStart: const TimeSpec(hour: 9),
        windowEnd: const TimeSpec(hour: 21),
        timesPerDay: 4,
        minGap: const Duration(minutes: 60),
      ));
      final a = engine.materialize(t, now);
      final b = engine.materialize(t, now);
      expect(a.map((e) => e.fireAt), b.map((e) => e.fireAt), reason: '重算必须幂等');
      // 视界 48h = 9/12 00:00 ~ 9/14 00:00：9/12、9/13 各 4 条，
      // 9/14 全天被视界右端裁剪（续算滚动补齐）。
      expect(a.length, 8);
      for (final e in a) {
        expect(e.fireAt.hour, inInclusiveRange(9, 20));
        expect(e.volume, inInclusiveRange(0.6, 1.0));
      }
      // 每天内最小间隔
      final byDay = <String, List<DateTime>>{};
      for (final e in a) {
        byDay
            .putIfAbsent(
                '${e.fireAt.year}${e.fireAt.month}${e.fireAt.day}', () => [])
            .add(e.fireAt);
      }
      for (final day in byDay.values) {
        for (var i = 1; i < day.length; i++) {
          expect(day[i].difference(day[i - 1]) >= const Duration(minutes: 60),
              isTrue,
              reason: '$day');
        }
      }
    });

    test('免打扰 skip：22:00-07:00 内的计划被丢弃', () {
      final now = DateTime(2026, 9, 12, 0);
      final t = _task(const DailyTrigger(time: TimeSpec(hour: 23, minute: 0)),
          quiet: QuietPolicy.skip);
      final list = engine.materialize(t, now);
      expect(list, isEmpty);
    });

    test('免打扰 shift：平移到次日免打扰结束点', () {
      final now = DateTime(2026, 9, 12, 0);
      final t = _task(const DailyTrigger(time: TimeSpec(hour: 23, minute: 0)),
          quiet: QuietPolicy.shift);
      final list = engine.materialize(t, now);
      expect(list, isNotEmpty);
      expect(list.first.fireAt.day, 13);
      expect(list.first.fireAt.hour, ComplianceGuardrails.defaultQuietEndHour);
    });

    test('固定一次：过期不生成', () {
      final now = DateTime(2026, 9, 12, 12);
      final t = _task(FixedOnceTrigger(at: DateTime(2026, 9, 12, 8)));
      expect(engine.materialize(t, now), isEmpty);
    });

    test('冷却：相邻条目间隔不足者被移除', () {
      final now = DateTime(2026, 9, 12, 0);
      final t = _task(RandomWindowTrigger(
        dateRange:
            DateRange(start: DateTime(2026, 9, 12), end: DateTime(2026, 9, 12)),
        windowStart: const TimeSpec(hour: 9),
        windowEnd: const TimeSpec(hour: 11),
        timesPerDay: 6,
        minGap: const Duration(minutes: 5),
      ));
      final list = engine.materialize(t, now);
      for (var i = 1; i < list.length; i++) {
        expect(list[i].fireAt.difference(list[i - 1].fireAt).inMinutes,
            greaterThanOrEqualTo(5),
            reason: '冷却必须生效');
      }
    });

    test('声音触发不进入时间计划', () {
      final t = _task(const SoundTrigger());
      expect(engine.materialize(t, DateTime(2026, 9, 12)), isEmpty);
    });

    test('禁用任务不生成', () {
      final now = DateTime.now();
      final t = _task(const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)))
          .copyWith(enabled: false);
      expect(engine.materialize(t, now), isEmpty);
    });
  });
}
