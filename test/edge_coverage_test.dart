import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/core/utils/random.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';

/// 边缘分支覆盖（第 4 项覆盖率工程）：补齐上述各文件的未覆盖分支。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('ActionType/AudioChannel label 全枚举', () {
    test('ActionType.label 全部（v1.9：十种）', () {
      expect(ActionType.playAudio.label, '播放音频');
      expect(ActionType.soundscape.label, '声景混音');
      expect(ActionType.tts.label, '语音喊话');
      expect(ActionType.notify.label, '发送通知');
      expect(ActionType.recordEvidence.label, '录音取证');
      // v1.9 起 `vibrate` 明确为"固定节奏"，与新增的随机/持续振动区分开。
      expect(ActionType.vibrate.label, '震动（固定节奏）');
      expect(ActionType.randomVibrate.label, '随机振动');
      expect(ActionType.continuousVibrate.label, '持续振动');
      expect(ActionType.composite.label, '组合动作');
      expect(ActionType.randomFrom.label, '随机指令集');
      // 枚举增长时这里会红：提醒同步 label 断言（而不是让新值悄悄没测）。
      expect(ActionType.values.length, 10);
    });

    test('AudioChannel.label 两种', () {
      expect(AudioChannel.media.label, '媒体通道');
      expect(AudioChannel.alarm.label, contains('穿透勿扰'));
    });
  });

  group('random.dart 边缘', () {
    test('shuffled 返回同元素集合且不修改原表', () {
      final src = [1, 2, 3, 4, 5, 6, 7, 8];
      final out = shuffled(src, Random(1));
      expect(out.toSet(), src.toSet());
      expect(src, [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('nextIntBetween 单点区间', () {
      expect(nextIntBetween(Random(1), 7, 8), 7);
    });
  });

  group('condition.dart 边缘', () {
    test('概率门字段进 hasAny/describe/toJson', () {
      const c = TaskCondition(probabilityPct: 30);
      expect(c.hasAny, isTrue);
      expect(c.describe(), contains('概率 30%'));
      expect(c.toJson()['probabilityPct'], 30);
    });

  });

  group('schedule_engine 边缘分支', () {
    Task mkTask(TriggerConfig trigger) {
      final now = DateTime(2026, 9, 20, 8);
      return Task(
        id: 'edge',
        name: '边缘',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: trigger,
        actionType: ActionType.notify,
        action: const NotifyAction(title: 'T', body: 'B'),
        assetIds: const [],
        cooldownSec: 300,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: now,
        updatedAt: now,
      );
    }

    test('dailyAt 带 dateRange 的物化', () {
      const engine = ScheduleEngine();
      final t = mkTask(DailyTrigger(
        time: const TimeSpec(hour: 10),
        dateRange:
            DateRange(start: DateTime(2026, 9, 20), end: DateTime(2026, 9, 22)),
      ));
      final list = engine.materialize(t, DateTime(2026, 9, 20, 8));
      // 48h 视界：9/20 10:00 与 9/21 10:00（9/22 10:00 超 48h 被裁）
      expect(list.length, 2);
    });

    test('weeklyAt 带 dateRange 过滤', () {
      const engine = ScheduleEngine();
      final t = mkTask(WeeklyTrigger(
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        time: const TimeSpec(hour: 10),
        dateRange:
            DateRange(start: DateTime(2026, 9, 20), end: DateTime(2026, 9, 25)),
      ));
      final list = engine.materialize(t, DateTime(2026, 9, 20, 8));
      expect(list, isNotEmpty);
      for (final e in list) {
        expect(e.fireAt.weekday, inInclusiveRange(1, 7));
      }
    });

    test('[P2-29] DateRange.days() 逐日历日、含端点、不重复', () {
      // ⚠️ 本机时区为 Asia/Shanghai（无夏令时），无法在宿主上复现 DST 回拨
      //    那一天"25 小时"的情形 —— DST 专项验证 **BLOCKED**（需 DST 时区设备）。
      //    这里锁住的是**日历语义**这一可断言性质：days() 必须恰好逐日前进、
      //    含首尾端点、严格递增；旧实现 `add(Duration(days:1))` 的固定 24h
      //    步进在回拨日会原地停留在同一天（本机测不到，但判据本身正确）。
      final r = DateRange(
          start: DateTime(2026, 11, 1), end: DateTime(2026, 11, 3));
      final days = r.days().toList();
      expect(days, <DateTime>[
        DateTime(2026, 11, 1),
        DateTime(2026, 11, 2),
        DateTime(2026, 11, 3),
      ], reason: '含端点、每天一次、日历日不漂移');
      for (var i = 1; i < days.length; i++) {
        expect(days[i].isAfter(days[i - 1]), isTrue, reason: '必须严格递增');
      }
      // 单日范围也必须产出 1 天（旧实现若在回拨日重复，计数会变成 0 或 2）。
      expect(DateRange(start: DateTime(2026, 11, 1), end: DateTime(2026, 11, 1))
          .days()
          .length, 1);
    });

    test('免打扰非跨午夜窗口（quietStart < quietEnd）', () {
      const engine = ScheduleEngine(quietStartHour: 2, quietEndHour: 5);
      final t = Task(
        id: 'q',
        name: 'q',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 3)),
        actionType: ActionType.notify,
        action: const NotifyAction(title: 'T', body: 'B'),
        assetIds: const [],
        cooldownSec: 300,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      final list = engine.materialize(t, DateTime(2026, 9, 20, 0));
      // 03:00 在 02:00-05:00 免打扰窗内 → 全部被 skip
      expect(list.where((e) => e.fireAt.hour == 3), isEmpty);
    });
  });

  group('occurrence_repository 补分支', () {
    late AppDatabase db;
    setUp(() async {
      db = await AppDatabase.open(inMemoryDatabasePath);
    });
    tearDown(() async {
      await db.close();
    });

    test('pendingCountAfter 在空表返回 0', () async {
      final occ = OccurrenceRepository(db);
      expect(await occ.pendingCountAfter(DateTime(2026)), 0);
    });

    test('purgeOlderThan 在空表返回 0', () async {
      final occ = OccurrenceRepository(db);
      expect(await occ.purgeOlderThan(DateTime(2026)), 0);
    });
  });
}
