import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';

/// 模型 JSON 序列化往返测试（数据完整性契约）。
void main() {
  group('TriggerConfig 序列化往返', () {
    test('FixedOnceTrigger', () {
      final t = FixedOnceTrigger(at: DateTime(2026, 9, 12, 10, 30));
      final back = TriggerConfig.fromJson(
          jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      expect(back, isA<FixedOnceTrigger>());
      expect((back as FixedOnceTrigger).at, t.at);
    });

    test('DailyTrigger（含可选日期范围）', () {
      final t = DailyTrigger(
        time: const TimeSpec(hour: 8, minute: 5),
        dateRange:
            DateRange(start: DateTime(2026, 9, 1), end: DateTime(2026, 9, 30)),
      );
      final back = TriggerConfig.fromJson(
          jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      final d = back as DailyTrigger;
      expect(d.time.hour, 8);
      expect(d.time.minute, 5);
      expect(d.dateRange!.contains(DateTime(2026, 9, 15)), isTrue);
      expect(d.dateRange!.contains(DateTime(2026, 10, 1)), isFalse);
    });

    test('WeeklyTrigger', () {
      const t = WeeklyTrigger(
        weekdays: {1, 3, 5},
        time: TimeSpec(hour: 7, minute: 30),
      );
      final back = TriggerConfig.fromJson(
          jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      expect((back as WeeklyTrigger).weekdays, {1, 3, 5});
    });

    test('RandomWindowTrigger', () {
      final t = RandomWindowTrigger(
        dateRange:
            DateRange(start: DateTime(2026, 9, 12), end: DateTime(2026, 9, 20)),
        windowStart: const TimeSpec(hour: 20),
        windowEnd: const TimeSpec(hour: 2),
        timesPerDay: 5,
        minGap: const Duration(minutes: 45),
        windowEndNextDay: true,
      );
      final back = TriggerConfig.fromJson(
          jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      final r = back as RandomWindowTrigger;
      expect(r.timesPerDay, 5);
      expect(r.minGap, const Duration(minutes: 45));
      expect(r.windowEndNextDay, isTrue);
    });

    test('RandomIntervalTrigger', () {
      final t = RandomIntervalTrigger(
        dateRange:
            DateRange(start: DateTime(2026, 9, 12), end: DateTime(2026, 9, 12)),
        minGap: const Duration(minutes: 10),
        maxGap: const Duration(hours: 2),
      );
      final back = TriggerConfig.fromJson(
          jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      final r = back as RandomIntervalTrigger;
      expect(r.minGap, const Duration(minutes: 10));
      expect(r.maxGap, const Duration(hours: 2));
    });

    test('SoundTrigger', () {
      const t =
          SoundTrigger(thresholdDb: -28, minDurationMs: 1200, cooldownSec: 90);
      final back = TriggerConfig.fromJson(
          jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      final s = back as SoundTrigger;
      expect(s.thresholdDb, -28);
      expect(s.minDurationMs, 1200);
      expect(s.cooldownSec, 90);
    });

    test('未知 kind 抛 ArgumentError', () {
      expect(
        () => TriggerConfig.fromJson({'kind': 'nope'}),
        throwsArgumentError,
      );
    });
  });

  group('ActionConfig 序列化往返', () {
    test('PlayAudioAction', () {
      const t = PlayAudioAction(
        volumeMin: 0.2,
        volumeMax: 0.9,
        durationSecMin: 2,
        durationSecMax: 30,
        channel: AudioChannel.alarm,
        fadeInSec: 1,
        fadeOutSec: 2,
      );
      final back = ActionConfig.fromJson(
          jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      final p = back as PlayAudioAction;
      expect(p.volumeMin, 0.2);
      expect(p.channel, AudioChannel.alarm);
      expect(p.fadeOutSec, 2);
    });

    test('TtsAction / NotifyAction / RecordEvidenceAction / VibrateAction', () {
      const tts = TtsAction(text: '已开启取证');
      final b1 = ActionConfig.fromJson(
          jsonDecode(jsonEncode(tts.toJson())) as Map<String, dynamic>);
      expect((b1 as TtsAction).text, '已开启取证');

      const notify = NotifyAction(title: 'T', body: 'B', silent: true);
      final b2 = ActionConfig.fromJson(
          jsonDecode(jsonEncode(notify.toJson())) as Map<String, dynamic>);
      expect((b2 as NotifyAction).silent, isTrue);

      const rec = RecordEvidenceAction(seconds: 45);
      final b3 = ActionConfig.fromJson(
          jsonDecode(jsonEncode(rec.toJson())) as Map<String, dynamic>);
      expect((b3 as RecordEvidenceAction).seconds, 45);

      const vib = VibrateAction(patternMs: [0, 100, 50, 100]);
      final b4 = ActionConfig.fromJson(
          jsonDecode(jsonEncode(vib.toJson())) as Map<String, dynamic>);
      expect((b4 as VibrateAction).patternMs, [0, 100, 50, 100]);
    });

    test('CompositeAction 嵌套', () {
      const t = CompositeAction(
        primary: PlayAudioAction(),
        prefixNotify: NotifyAction(title: 'a', body: 'b'),
      );
      final back = ActionConfig.fromJson(
          jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      final c = back as CompositeAction;
      expect(c.primary, isA<PlayAudioAction>());
      expect(c.prefixNotify!.title, 'a');
    });
  });

  group('Task 行序列化', () {
    test('toRow/fromRow 往返', () {
      final now = DateTime(2026, 9, 12, 9);
      final task = Task(
        id: 'id-1',
        name: '夜间取证',
        enabled: false,
        triggerType: TriggerType.soundTriggered,
        trigger: const SoundTrigger(thresholdDb: -30),
        actionType: ActionType.recordEvidence,
        action: const RecordEvidenceAction(seconds: 30),
        assetIds: const ['x'],
        cooldownSec: 600,
        quietPolicy: QuietPolicy.skip,
        priority: 5,
        createdAt: now,
        updatedAt: now,
      );
      final back = Task.fromRow(task.toRow());
      expect(back.id, 'id-1');
      expect(back.enabled, isFalse);
      expect(back.triggerType, TriggerType.soundTriggered);
      expect(back.action, isA<RecordEvidenceAction>());
      expect(back.priority, 5);
    });
  });
}
