// QR4 扫描（sweep-data）：合规护栏回归测试。
//
// 覆盖 docs/08 三条红线在 domain 层的落实：
//   1. 免打扰窗口归一化：损坏/缺失配置必须回落默认 22:00–07:00（BUG-070 兜底）；
//   2. 最小冷却 60s：即使任务配 cooldownSec < 60，物化间隔仍 >= 60s；
//   3. 夜间豁免 Two-Key：任务级 quietExempt=true 但引擎主开关关闭时，
//      免打扰时段计划不得放行（单钥匙不生效，fail-safe）。
//
// 纯 Dart 测试：不触碰 sqflite / 平台通道，可在宿主直接运行。
import 'package:flutter_test/flutter_test.dart';

import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';

Task _task({
  required TriggerConfig trigger,
  TriggerType triggerType = TriggerType.fixedOnce,
  int cooldownSec = 300,
  QuietPolicy quietPolicy = QuietPolicy.skip,
  bool quietExempt = false,
}) {
  final now = DateTime(2026, 9, 25, 12);
  return Task(
    id: 't1',
    name: '护栏测试任务',
    enabled: true,
    triggerType: triggerType,
    trigger: trigger,
    actionType: ActionType.notify,
    action: const NotifyAction(title: '声盾', body: 'test'),
    assetIds: const [],
    cooldownSec: cooldownSec,
    quietPolicy: quietPolicy,
    quietExempt: quietExempt,
    priority: 0,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('合规护栏：免打扰窗口归一化（docs/08 红线 1）', () {
    test('缺失/越界/空窗口 一律回落默认 22:00–07:00', () {
      expect(normalizeQuietWindow(null, null),
          (start: ComplianceGuardrails.defaultQuietStartHour, end: ComplianceGuardrails.defaultQuietEndHour));
      // 越界值（而不是夹到边界）也回落默认
      expect(normalizeQuietWindow(-1, 30).start, 22);
      expect(normalizeQuietWindow(-1, 30).end, 7);
      // start == end 会让引擎判成零长度窗口 → 免打扰整体失效，必须回落
      expect(normalizeQuietWindow(8, 8).start, 22);
      expect(normalizeQuietWindow(8, 8).end, 7);
    });

    test('合法的调窄配置被保留（设置页只能 20–23 / 5–9）', () {
      expect(normalizeQuietWindow(23, 5), (start: 23, end: 5));
    });
  });

  group('合规护栏：最小冷却 60s（docs/08 红线 2）', () {
    test('cooldownSec=5 的任务物化后相邻间隔仍 >= 60s', () {
      final now = DateTime(2026, 9, 25, 10);
      final task = _task(
        triggerType: TriggerType.randomWindow,
        trigger: RandomWindowTrigger(
          dateRange: DateRange(
              start: DateTime(2026, 9, 25), end: DateTime(2026, 9, 26)),
          windowStart: const TimeSpec(hour: 10),
          windowEnd: const TimeSpec(hour: 12),
          timesPerDay: 8,
          minGap: const Duration(seconds: 5), // 放任原始时刻贴近
        ),
        cooldownSec: 5, // 低于合规下限
      );
      final entries =
          const ScheduleEngine().materialize(task, now, horizon: const Duration(days: 1));
      expect(entries, isNotEmpty);
      for (var i = 1; i < entries.length; i++) {
        final gap = entries[i].fireAt.difference(entries[i - 1].fireAt);
        expect(gap.inSeconds,
            greaterThanOrEqualTo(ComplianceGuardrails.minCooldownSeconds),
            reason: '第 $i 条与前一 条间隔 ${gap.inSeconds}s，低于 60s 下限');
      }
    });
  });

  group('合规护栏：夜间豁免 Two-Key（docs/08 红线 3）', () {
    final fire = DateTime(2026, 9, 25, 23, 30); // 命中默认免打扰 22:00–07:00

    test('skip 策略：免打扰时段计划被丢弃（即使任务级豁免已开、主开关未开）', () {
      final task = _task(
        trigger: FixedOnceTrigger(at: fire),
        quietPolicy: QuietPolicy.skip,
        quietExempt: true, // 只有任务级这一把钥匙
      );
      final entries =
          const ScheduleEngine().materialize(task, DateTime(2026, 9, 25, 12));
      expect(entries, isEmpty,
          reason: '引擎主开关默认 false，单钥匙不得放行夜间执行');
    });

    test('shift 策略：计划平移到免打扰结束点之后，不落在 22:00–07:00 内', () {
      final task = _task(
        trigger: FixedOnceTrigger(at: fire),
        quietPolicy: QuietPolicy.shift,
      );
      final entries =
          const ScheduleEngine().materialize(task, DateTime(2026, 9, 25, 12));
      expect(entries, isNotEmpty);
      final at = entries.first.fireAt;
      final inQuiet = at.hour >= 22 || at.hour < 7;
      expect(inQuiet, isFalse, reason: '平移后时刻 $at 仍落在免打扰时段内');
    });
  });
}
