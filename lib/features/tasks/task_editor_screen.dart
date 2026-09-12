import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../domain/models/action.dart';
import '../../domain/models/task.dart';
import '../../domain/models/trigger.dart';
import '../../services/background_service_manager.dart';

/// 任务编辑器：触发方式 -> 时间参数 -> 动作 -> 音源 -> 保存。
/// 编辑器刻意保持“单页分组 + 底部保存”，降低复杂度。
class TaskEditorScreen extends ConsumerStatefulWidget {
  const TaskEditorScreen({super.key, this.taskId});

  final String? taskId;

  @override
  ConsumerState<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends ConsumerState<TaskEditorScreen> {
  final _nameCtrl = TextEditingController();
  TriggerType _type = TriggerType.randomWindow;
  ActionKindChoice _actionKind = ActionKindChoice.play;

  // 固定/每日/每周
  TimeOfDay _time = const TimeOfDay(hour: 10, minute: 0);
  final Set<int> _weekdays = {1, 2, 3, 4, 5};

  // 随机窗口 / 随机间隔
  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now().add(const Duration(days: 7));
  TimeOfDay _winStart = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _winEnd = const TimeOfDay(hour: 21, minute: 0);
  int _timesPerDay = 3;
  int _minGapMin = 30;
  int _maxGapMin = 120;

  // 动作参数（随机时长/音量）
  double _volMin = 0.5, _volMax = 1.0;
  int _durMin = 3, _durMax = 15;
  bool _alarmChannel = false;
  bool _loopFill = false;
  int _rampUpSec = 0;

  String get _rampUpLabel => _rampUpSec == 0 ? '关闭' : '$_rampUpSec 秒渐强';
  String _ttsText = '请注意，已开启录音取证';
  int _recordSec = 60;

  Task? _editing;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.taskId == null) {
      _loaded = true;
      return;
    }
    final repo = await ref.read(taskRepoProvider.future);
    final t = await repo.get(widget.taskId!);
    if (t == null) return;
    setState(() {
      _editing = t;
      _nameCtrl.text = t.name;
      _type = t.triggerType;
      _loaded = true;
      final tr = t.trigger;
      if (tr is FixedOnceTrigger) {
        _time = TimeOfDay.fromDateTime(tr.at);
      } else if (tr is DailyTrigger) {
        _time = TimeOfDay(hour: tr.time.hour, minute: tr.time.minute);
      } else if (tr is WeeklyTrigger) {
        _time = TimeOfDay(hour: tr.time.hour, minute: tr.time.minute);
        _weekdays
          ..clear()
          ..addAll(tr.weekdays);
      } else if (tr is RandomWindowTrigger) {
        _winStart =
            TimeOfDay(hour: tr.windowStart.hour, minute: tr.windowStart.minute);
        _winEnd =
            TimeOfDay(hour: tr.windowEnd.hour, minute: tr.windowEnd.minute);
        _timesPerDay = tr.timesPerDay;
        _minGapMin = tr.minGap.inMinutes;
        _startDate = tr.dateRange.start;
        _endDate = tr.dateRange.end;
      } else if (tr is RandomIntervalTrigger) {
        _minGapMin = tr.minGap.inMinutes;
        _maxGapMin = tr.maxGap.inMinutes;
        _startDate = tr.dateRange.start;
        _endDate = tr.dateRange.end;
      } else if (tr is SoundTrigger) {
        _recordSec = tr.cooldownSec;
      }
      final a = t.action;
      if (a is PlayAudioAction) {
        _volMin = a.volumeMin;
        _volMax = a.volumeMax;
        _durMin = a.durationSecMin;
        _durMax = a.durationSecMax;
        _alarmChannel = a.channel == AudioChannel.alarm;
        _rampUpSec = a.rampUpSec;
        _loopFill = a.loopFill;
        _actionKind = ActionKindChoice.play;
      } else if (a is TtsAction) {
        _ttsText = a.text;
        _actionKind = ActionKindChoice.tts;
      } else if (a is RecordEvidenceAction) {
        _recordSec = a.seconds;
        _actionKind = ActionKindChoice.record;
      } else if (a is NotifyAction) {
        _actionKind = ActionKindChoice.notify;
      } else if (a is CompositeAction) {
        _actionKind = ActionKindChoice.composite;
        if (a.primary is PlayAudioAction) {
          final p = a.primary as PlayAudioAction;
          _volMin = p.volumeMin;
          _volMax = p.volumeMax;
          _durMin = p.durationSecMin;
          _durMax = p.durationSecMax;
          _alarmChannel = p.channel == AudioChannel.alarm;
          _rampUpSec = p.rampUpSec;
          _loopFill = p.loopFill;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('编辑任务')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.taskId == null ? '新建任务' : '编辑任务'),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('保存任务'),
            onPressed: _save,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '任务名称',
              hintText: '例如：工作时段随机提醒音 / 夜间取证',
            ),
          ),
          const SizedBox(height: 16),
          _section(context, '触发方式'),
          Wrap(
            spacing: 8,
            children: [
              for (final t in TriggerType.values)
                ChoiceChip(
                  label: Text(t.label),
                  selected: _type == t,
                  onSelected: (_) => setState(() => _type = t),
                ),
            ],
          ),
          ..._triggerInputs(context),
          const SizedBox(height: 16),
          _section(context, '动作'),
          Wrap(
            spacing: 8,
            children: [
              for (final k in ActionKindChoice.values)
                ChoiceChip(
                  label: Text(k.label),
                  selected: _actionKind == k,
                  onSelected: (_) => setState(() => _actionKind = k),
                ),
            ],
          ),
          ..._actionInputs(context),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _section(BuildContext ctx, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(title,
            style: Theme.of(ctx)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
      );

  List<Widget> _triggerInputs(BuildContext ctx) {
    switch (_type) {
      case TriggerType.fixedOnce:
      case TriggerType.dailyAt:
      case TriggerType.weeklyAt:
        return [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.access_time),
            title: Text('时刻：${_time.format(ctx)}'),
            onTap: () async {
              final t = await showTimePicker(context: ctx, initialTime: _time);
              if (t != null) setState(() => _time = t);
            },
          ),
          if (_type == TriggerType.weeklyAt)
            Wrap(
              children: [
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    label: Text(_weekdayName(d)),
                    selected: _weekdays.contains(d),
                    onSelected: (v) => setState(
                        () => v ? _weekdays.add(d) : _weekdays.remove(d)),
                  ),
              ],
            ),
        ];
      case TriggerType.randomWindow:
      case TriggerType.randomInterval:
        return [
          const SizedBox(height: 8),
          _DateRangeTile(
            start: _startDate,
            end: _endDate,
            onChanged: (s, e) => setState(() {
              _startDate = s;
              _endDate = e;
            }),
          ),
          if (_type == TriggerType.randomWindow) ...[
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: Text('窗口开始：${_winStart.format(ctx)}'),
              onTap: () async {
                final t =
                    await showTimePicker(context: ctx, initialTime: _winStart);
                if (t != null) setState(() => _winStart = t);
              },
            ),
            ListTile(
              leading: const Icon(Icons.stop),
              title: Text('窗口结束：${_winEnd.format(ctx)}'),
              onTap: () async {
                final t =
                    await showTimePicker(context: ctx, initialTime: _winEnd);
                if (t != null) setState(() => _winEnd = t);
              },
            ),
            _IntStepper(
              label: '每日随机次数',
              value: _timesPerDay,
              min: 1,
              max: 24,
              onChanged: (v) => setState(() => _timesPerDay = v),
            ),
            _IntStepper(
              label: '最短间隔（分钟）',
              value: _minGapMin,
              min: 1,
              max: 720,
              onChanged: (v) => setState(() => _minGapMin = v),
            ),
          ],
          if (_type == TriggerType.randomInterval) ...[
            _IntStepper(
              label: '最短间隔（分钟）',
              value: _minGapMin,
              min: 1,
              max: 720,
              onChanged: (v) => setState(() => _minGapMin = v),
            ),
            _IntStepper(
              label: '最长间隔（分钟）',
              value: _maxGapMin,
              min: 2,
              max: 1440,
              onChanged: (v) => setState(() => _maxGapMin = v),
            ),
          ],
        ];
      case TriggerType.soundTriggered:
        return [
          const SizedBox(height: 8),
          const Text('声音触发由「守卫」页统一配置灵敏度与冷却，任务保存后即刻生效。'),
        ];
    }
  }

  List<Widget> _actionInputs(BuildContext ctx) {
    final playInputs = [
      _RangeSliderTile(
        label: '随机音量',
        min: 0,
        max: 1,
        start: _volMin,
        end: _volMax,
        format: (v) => '${(v * 100).round()}%',
        onChanged: (a, b) => setState(() {
          _volMin = a;
          _volMax = b;
        }),
      ),
      _RangeSliderTile(
        label: '随机时长（秒）',
        min: 1,
        max: 120,
        start: _durMin.toDouble(),
        end: _durMax.toDouble(),
        format: (v) => '${v.round()}s',
        onChanged: (a, b) => setState(() {
          _durMin = a.round();
          _durMax = b.round();
        }),
      ),
      SwitchListTile(
        title: const Text('闹钟通道（穿透勿扰/静音）'),
        subtitle: const Text('请确保用途合法合规，谨慎开启'),
        value: _alarmChannel,
        onChanged: (v) => setState(() => _alarmChannel = v),
      ),
      SwitchListTile(
        title: const Text('循环填充（声景模式）'),
        subtitle: const Text('短音效循环播放，填满随机时长'),
        value: _loopFill,
        onChanged: (v) => setState(() => _loopFill = v),
      ),
      if (!_loopFill)
        ListTile(
          title: Text('渐强唤醒：$_rampUpLabel'),
          subtitle: Slider(
            value: _rampUpSec.toDouble(),
            min: 0,
            max: 300,
            divisions: 20,
            label: _rampUpLabel,
            onChanged: (v) => setState(() => _rampUpSec = v.round()),
          ),
        ),
    ];
    switch (_actionKind) {
      case ActionKindChoice.play:
        return [const SizedBox(height: 8), ...playInputs];
      case ActionKindChoice.tts:
        return [
          const SizedBox(height: 8),
          TextFormField(
            initialValue: _ttsText,
            decoration: const InputDecoration(labelText: '播报文本'),
            onChanged: (v) => _ttsText = v,
          ),
        ];
      case ActionKindChoice.record:
        return [
          const SizedBox(height: 8),
          _IntStepper(
            label: '录音取证时长（秒）',
            value: _recordSec,
            min: 10,
            max: 300,
            onChanged: (v) => setState(() => _recordSec = v),
          ),
        ];
      case ActionKindChoice.notify:
        return const [SizedBox(height: 8), Text('将发送系统通知（可在组合模式中叠加）。')];
      case ActionKindChoice.composite:
        return [
          const SizedBox(height: 8),
          const Text('组合 = 先发通知提示，再随机播放音频。'),
          ...playInputs,
        ];
    }
  }

  Future<void> _save() async {
    final repo = await ref.read(taskRepoProvider.future);
    final now = DateTime.now();

    TriggerConfig trigger;
    switch (_type) {
      case TriggerType.fixedOnce:
        final base = now.add(const Duration(minutes: 5));
        trigger = FixedOnceTrigger(
            at: DateTime(
                base.year, base.month, base.day, _time.hour, _time.minute));
      case TriggerType.dailyAt:
        trigger = DailyTrigger(
            time: TimeSpec(hour: _time.hour, minute: _time.minute));
      case TriggerType.weeklyAt:
        if (_weekdays.isEmpty) {
          if (!mounted) return;
          _toast(context, '请至少选择一个星期');
          return;
        }
        trigger = WeeklyTrigger(
            weekdays: _weekdays,
            time: TimeSpec(hour: _time.hour, minute: _time.minute));
      case TriggerType.randomWindow:
        trigger = RandomWindowTrigger(
          dateRange: DateRange(start: _startDate, end: _endDate),
          windowStart: TimeSpec(hour: _winStart.hour, minute: _winStart.minute),
          windowEnd: TimeSpec(hour: _winEnd.hour, minute: _winEnd.minute),
          timesPerDay: _timesPerDay,
          minGap: Duration(minutes: _minGapMin),
        );
      case TriggerType.randomInterval:
        trigger = RandomIntervalTrigger(
          dateRange: DateRange(start: _startDate, end: _endDate),
          minGap: Duration(minutes: _minGapMin),
          maxGap: Duration(minutes: _maxGapMin.clamp(_minGapMin + 1, 1440)),
        );
      case TriggerType.soundTriggered:
        trigger = const SoundTrigger();
    }

    ActionConfig action;
    switch (_actionKind) {
      case ActionKindChoice.play:
        action = PlayAudioAction(
          volumeMin: _volMin,
          volumeMax: _volMax,
          durationSecMin: _durMin,
          durationSecMax: _durMax.clamp(_durMin, 120),
          channel: _alarmChannel ? AudioChannel.alarm : AudioChannel.media,
          rampUpSec: _rampUpSec,
          loopFill: _loopFill,
        );
      case ActionKindChoice.tts:
        action = TtsAction(text: _ttsText);
      case ActionKindChoice.record:
        action = RecordEvidenceAction(seconds: _recordSec);
      case ActionKindChoice.notify:
        action = NotifyAction(title: '声盾 · 触发', body: _nameCtrl.text);
      case ActionKindChoice.composite:
        action = CompositeAction(
          primary: PlayAudioAction(
            volumeMin: _volMin,
            volumeMax: _volMax,
            durationSecMin: _durMin,
            durationSecMax: _durMax.clamp(_durMin, 120),
            channel: _alarmChannel ? AudioChannel.alarm : AudioChannel.media,
            rampUpSec: _rampUpSec,
            loopFill: _loopFill,
          ),
          prefixNotify: NotifyAction(title: '声盾 · 触发', body: _nameCtrl.text),
        );
    }

    final id = _editing?.id ?? const Uuid().v4();
    final task = Task(
      id: id,
      name: _nameCtrl.text.trim().isEmpty ? '未命名任务' : _nameCtrl.text.trim(),
      enabled: _editing?.enabled ?? true,
      triggerType: _type,
      trigger: trigger,
      actionType: switch (_actionKind) {
        ActionKindChoice.play => ActionType.playAudio,
        ActionKindChoice.tts => ActionType.tts,
        ActionKindChoice.record => ActionType.recordEvidence,
        ActionKindChoice.notify => ActionType.notify,
        ActionKindChoice.composite => ActionType.composite,
      },
      action: action,
      assetIds: _editing?.assetIds ?? const [],
      cooldownSec: 300,
      quietPolicy: QuietPolicy.skip,
      priority: 0,
      createdAt: _editing?.createdAt ?? now,
      updatedAt: now,
    );
    await repo.upsert(task);
    await BackgroundServiceManager.instance.replan();
    if (mounted) Navigator.of(context).pop();
  }

  void _toast(BuildContext ctx, String msg) =>
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));

  static String _weekdayName(int d) =>
      const ['一', '二', '三', '四', '五', '六', '日'][d - 1];
}

enum ActionKindChoice {
  play,
  tts,
  record,
  notify,
  composite,
  ;

  String get label => switch (this) {
        ActionKindChoice.play => '随机播放',
        ActionKindChoice.tts => '语音播报',
        ActionKindChoice.record => '录音取证',
        ActionKindChoice.notify => '通知',
        ActionKindChoice.composite => '通知+播放',
      };
}

// ---------------- 复用控件 ----------------

class _DateRangeTile extends StatelessWidget {
  const _DateRangeTile(
      {required this.start, required this.end, required this.onChanged});

  final DateTime start;
  final DateTime end;
  final void Function(DateTime, DateTime) onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.date_range),
      title: const Text('生效日期范围'),
      subtitle: Text('${start.year}-${start.month}-${start.day} ~ '
          '${end.year}-${end.month}-${end.day}'),
      onTap: () async {
        final r = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
          initialDateRange: DateTimeRange(start: start, end: end),
        );
        if (r != null) onChanged(r.start, r.end);
      },
    );
  }
}

class _IntStepper extends StatelessWidget {
  const _IntStepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text('$label：$value'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: value > min ? () => onChanged(value - 1) : null,
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: value < max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }
}

class _RangeSliderTile extends StatelessWidget {
  const _RangeSliderTile({
    required this.label,
    required this.min,
    required this.max,
    required this.start,
    required this.end,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double min;
  final double max;
  final double start;
  final double end;
  final String Function(double) format;
  final void Function(double, double) onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('$label：${format(start)} ~ ${format(end)}'),
        ),
        RangeSlider(
          values: RangeValues(start, end),
          min: min,
          max: max,
          divisions: 100,
          labels: RangeLabels(format(start), format(end)),
          onChanged: (v) => onChanged(v.start, v.end),
        ),
      ],
    );
  }
}
