import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/remote/task_wire.dart';

/// 远程任务线格式（v1.7，docs/14 §2.1）契约测试。
///
/// 核心不变量：**入站数据不可信**。
/// `task.upsert` 的定义来自对端，端点必须在落库前做白名单校验；
/// 本文件锁定「合法往返无损」与「畸形输入一律拒绝/夹紧」两侧行为，
/// 因为 release 构建会剥离 `assert`，领域模型的区间约束此时形同不存在。
void main() {
  Task sample({
    String id = 't1',
    bool enabled = true,
    ActionConfig? action,
    TriggerConfig? trigger,
    TriggerType triggerType = TriggerType.dailyAt,
    ActionType actionType = ActionType.playAudio,
    List<String> assetIds = const ['a1', 'a2'],
    int cooldownSec = 300,
    int priority = 0,
    TaskCondition? condition,
  }) =>
      Task(
        id: id,
        name: '示例任务',
        enabled: enabled,
        triggerType: triggerType,
        trigger: trigger ?? const DailyTrigger(time: TimeSpec(hour: 8, minute: 30)),
        actionType: actionType,
        action: action ?? const PlayAudioAction(),
        assetIds: assetIds,
        cooldownSec: cooldownSec,
        quietPolicy: QuietPolicy.skip,
        condition: condition,
        priority: priority,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  group('TW 线格式往返', () {
    test('TW-01 播放任务往返后字段一致', () {
      final t = sample(
        condition: const TaskCondition(
            requireCharging: true, minBatteryPct: 30, windowStartMin: 420),
      );
      final back = TaskWire.fromWire(TaskWire.toWire(t));
      expect(back, isNotNull);
      expect(back!.id, t.id);
      expect(back.name, t.name);
      expect(back.enabled, isTrue);
      expect(back.triggerType, TriggerType.dailyAt);
      expect(back.actionType, ActionType.playAudio);
      expect(back.assetIds, ['a1', 'a2']);
      expect(back.cooldownSec, 300);
      expect(back.condition!.requireCharging, isTrue);
      expect(back.condition!.minBatteryPct, 30);
      expect(back.condition!.windowStartMin, 420);
    });

    test('TW-02 线格式 trigger/action 为嵌套对象而非 JSON 字符串', () {
      final w = TaskWire.toWire(sample());
      expect(w['trigger'], isA<Map<String, dynamic>>());
      expect(w['action'], isA<Map<String, dynamic>>());
      expect(w['enabled'], isA<bool>());
      expect(w['assetIds'], isA<List<String>>());
      // 与 Task.toRow() 的存储形态区分：不应出现 *_json 字符串列
      expect(w.containsKey('trigger_json'), isFalse);
      expect(w.containsKey('action_json'), isFalse);
    });

    test('TW-03 六种触发器均能往返', () {
      final cases = <TriggerType, TriggerConfig>{
        TriggerType.fixedOnce:
            FixedOnceTrigger(at: DateTime(2030, 1, 1, 9, 0)),
        TriggerType.dailyAt: const DailyTrigger(time: TimeSpec(hour: 7)),
        TriggerType.weeklyAt: const WeeklyTrigger(
            weekdays: {1, 3, 5}, time: TimeSpec(hour: 7, minute: 15)),
        TriggerType.randomWindow: RandomWindowTrigger(
            windowStart: const TimeSpec(hour: 9),
            windowEnd: const TimeSpec(hour: 18),
            timesPerDay: 2,
            minGap: const Duration(minutes: 30),
            dateRange: DateRange(
                start: DateTime(2030, 1, 1), end: DateTime(2030, 1, 31))),
        TriggerType.randomInterval: RandomIntervalTrigger(
            activeStart: const TimeSpec(hour: 8),
            activeEnd: const TimeSpec(hour: 20),
            minGap: const Duration(minutes: 20),
            maxGap: const Duration(minutes: 90),
            maxPerDay: 5,
            dateRange: DateRange(
                start: DateTime(2030, 1, 1), end: DateTime(2030, 1, 31))),
        TriggerType.soundTriggered: const SoundTrigger(),
      };
      for (final e in cases.entries) {
        final t = sample(triggerType: e.key, trigger: e.value);
        final back = TaskWire.fromWire(TaskWire.toWire(t));
        expect(back, isNotNull, reason: '${e.key.name} 往返失败');
        expect(back!.triggerType, e.key);
      }
    });

    test('TW-04 七种动作均能往返', () {
      final cases = <ActionType, ActionConfig>{
        ActionType.playAudio: const PlayAudioAction(),
        ActionType.tts: const TtsAction(text: '注意'),
        ActionType.notify: const NotifyAction(title: '标题', body: '正文'),
        ActionType.recordEvidence: const RecordEvidenceAction(seconds: 30),
        ActionType.vibrate: const VibrateAction(),
        ActionType.composite: const CompositeAction(
            primary: TtsAction(text: '主'),
            prefixNotify: NotifyAction(title: '先', body: '通知')),
        ActionType.soundscape: SoundscapeAction(
            tracks: const [SoundscapeTrack(presetCategory: 'rain')]),
      };
      for (final e in cases.entries) {
        final t = sample(actionType: e.key, action: e.value);
        final back = TaskWire.fromWire(TaskWire.toWire(t));
        expect(back, isNotNull, reason: '${e.key.name} 往返失败');
        expect(back!.actionType, e.key);
      }
    });
  });

  group('TW 入站校验（不可信输入）', () {
    test('TW-10 缺 id / 空 name → 拒绝', () {
      expect(TaskWire.fromWire({}), isNull);
      final noId = TaskWire.toWire(sample())..remove('id');
      expect(TaskWire.fromWire(noId), isNull);
      final blankName = TaskWire.toWire(sample())..['name'] = '   ';
      expect(TaskWire.fromWire(blankName), isNull);
    });

    test('TW-11 未知枚举名 → 拒绝（不得回落默认值）', () {
      final badTrigger = TaskWire.toWire(sample())..['triggerType'] = 'evilType';
      expect(TaskWire.fromWire(badTrigger), isNull);
      final badAction = TaskWire.toWire(sample())..['actionType'] = 'rmRf';
      expect(TaskWire.fromWire(badAction), isNull);
    });

    test('TW-12 未知 trigger/action kind → 拒绝', () {
      final badTrigger = TaskWire.toWire(sample());
      (badTrigger['trigger'] as Map)['kind'] = 'shellExec';
      expect(TaskWire.fromWire(badTrigger), isNull);

      final badAction = TaskWire.toWire(sample());
      (badAction['action'] as Map)['kind'] = 'deleteAll';
      expect(TaskWire.fromWire(badAction), isNull);
    });

    test('TW-13 trigger/action 缺失或类型错误 → 拒绝', () {
      final noTrigger = TaskWire.toWire(sample())..remove('trigger');
      expect(TaskWire.fromWire(noTrigger), isNull);
      final strAction = TaskWire.toWire(sample())..['action'] = 42;
      expect(TaskWire.fromWire(strAction), isNull);
    });

    test('TW-14 超长 name 被截断而非拒绝', () {
      final long = 'x' * 500;
      final w = TaskWire.toWire(sample())..['name'] = long;
      final back = TaskWire.fromWire(w);
      expect(back, isNotNull);
      expect(back!.name.length, TaskWire.maxNameLen);
    });

    test('TW-15 cooldownSec / priority 越界被夹紧', () {
      final w = TaskWire.toWire(sample())
        ..['cooldownSec'] = 999999999
        ..['priority'] = -9999;
      final back = TaskWire.fromWire(w);
      expect(back!.cooldownSec, TaskWire.maxCooldownSec);
      expect(back.priority, -TaskWire.maxPriorityAbs);

      final w2 = TaskWire.toWire(sample())..['cooldownSec'] = -50;
      expect(TaskWire.fromWire(w2)!.cooldownSec, 0);
    });

    test('TW-16 assetIds 数量有上限，非字符串元素被丢弃', () {
      final many = List.generate(500, (i) => 'a$i');
      final w = TaskWire.toWire(sample())..['assetIds'] = many;
      expect(TaskWire.fromWire(w)!.assetIds.length, TaskWire.maxAssetIds);

      final mixed = TaskWire.toWire(sample())
        ..['assetIds'] = ['ok', 1, null, '', 'ok2'];
      expect(TaskWire.fromWire(mixed)!.assetIds, ['ok', 'ok2']);
    });

    test('TW-17 非法时间戳回落为当前时间，且 updatedAt 一律刷新', () {
      final w = TaskWire.toWire(sample())
        ..['createdAt'] = 1
        ..['updatedAt'] = 99999999999999;
      final back = TaskWire.fromWire(w)!;
      // 早于 2000 年 → 视为非法 → 回落 now
      expect(back.createdAt.year, greaterThanOrEqualTo(2020));
      // 入站更新不采信对端时间线
      final drift = DateTime.now().difference(back.updatedAt).abs();
      expect(drift.inSeconds, lessThan(5));
    });

    test('TW-18 condition 越界值被夹紧', () {
      final w = TaskWire.toWire(sample());
      w['condition'] = {
        'requireCharging': false,
        'minBatteryPct': 500,
        'windowStartMin': -100,
        'windowEndMin': 9999,
      };
      final c = TaskWire.fromWire(w)!.condition!;
      expect(c.minBatteryPct, 100);
      expect(c.windowStartMin, 0);
      expect(c.windowEndMin, 1439);
    });
    test('TW-19 非安全相关字段宽容解析（enabled 的 0/1、vibrate 缺省模式）', () {
      // enabled 线格式约定 bool，但 0/1/字符串也能接受：
      // 不该为一个布尔字段把整条任务拒掉。
      for (final v in <Object>[1, 'true', true]) {
        final w = TaskWire.toWire(sample())..['enabled'] = v;
        expect(TaskWire.fromWire(w)!.enabled, isTrue, reason: 'enabled=$v');
      }
      for (final v in <Object>[0, 'false', false]) {
        final w = TaskWire.toWire(sample())..['enabled'] = v;
        expect(TaskWire.fromWire(w)!.enabled, isFalse, reason: 'enabled=$v');
      }

      // 震动缺 patternMs 应落到领域模型默认值，而不是拒绝整条任务。
      final w = TaskWire.toWire(sample())
        ..['actionType'] = 'vibrate'
        ..['action'] = {'kind': 'vibrate'};
      final a = TaskWire.fromWire(w)!.action as VibrateAction;
      expect(a.patternMs, const [0, 300, 200, 300]);
    });
  });

  group('TW 动作参数夹紧（release 无 assert 防线）', () {
    test('TW-20 volumeMin > volumeMax 被交换而非产生非法动作', () {
      final w = TaskWire.toWire(sample());
      w['action'] = {
        'kind': 'play',
        'volumeMin': 0.9,
        'volumeMax': 0.2,
        'durationSecMin': 30,
        'durationSecMax': 5,
      };
      final a = TaskWire.fromWire(w)!.action as PlayAudioAction;
      expect(a.volumeMin, lessThanOrEqualTo(a.volumeMax));
      expect(a.durationSecMin, lessThanOrEqualTo(a.durationSecMax));
    });

    test('TW-21 播放音量/时长越界被夹紧到合法区间', () {
      final w = TaskWire.toWire(sample());
      w['action'] = {
        'kind': 'play',
        'volumeMin': -3.0,
        'volumeMax': 99.0,
        'durationSecMin': 0,
        'durationSecMax': 999999,
        'rampUpSec': -10,
      };
      final a = TaskWire.fromWire(w)!.action as PlayAudioAction;
      expect(a.volumeMin, 0.0);
      expect(a.volumeMax, 1.0);
      expect(a.durationSecMin, greaterThanOrEqualTo(1));
      expect(a.durationSecMax, TaskWire.maxDurationSec);
      expect(a.rampUpSec, 0);
    });

    test('TW-22 组合动作的主动作同样被夹紧', () {
      final w = TaskWire.toWire(sample());
      w['action'] = {
        'kind': 'composite',
        'primary': {
          'kind': 'play',
          'volumeMin': 0.8,
          'volumeMax': 0.1,
        },
        'prefixNotify': {'kind': 'notify', 'title': 't', 'body': 'b'},
      };
      final a = TaskWire.fromWire(w)!.action as CompositeAction;
      final p = a.primary as PlayAudioAction;
      expect(p.volumeMin, lessThanOrEqualTo(p.volumeMax));
      expect(a.prefixNotify!.title, 't');
    });

    test('TW-23 声景轨道数越界 → 拒绝（避免不可执行的声景）', () {
      final w = TaskWire.toWire(sample());
      w['action'] = {
        'kind': 'soundscape',
        'tracks': [
          for (var i = 0; i < 9; i++) {'presetCategory': 'c$i'},
        ],
      };
      expect(TaskWire.fromWire(w), isNull);
    });

    test('TW-24 文本与录音时长超限被收敛', () {
      final w = TaskWire.toWire(sample());
      w['action'] = {
        'kind': 'tts',
        'text': 'a' * 5000,
        'volume': 7.5,
      };
      final a = TaskWire.fromWire(w)!.action as TtsAction;
      expect(a.text.length, TaskWire.maxTextLen);
      expect(a.volume, 1.0);

      final w2 = TaskWire.toWire(sample());
      w2['action'] = {'kind': 'record', 'seconds': 999999};
      final r = TaskWire.fromWire(w2)!.action as RecordEvidenceAction;
      expect(r.seconds, TaskWire.maxRecordSec);
    });
  });
}
