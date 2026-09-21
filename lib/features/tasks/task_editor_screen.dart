import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../domain/models/action.dart';
import '../../domain/models/condition.dart';
import '../../remote/rc_script.dart';
import '../../domain/models/task.dart';
import '../../domain/models/trigger.dart';
import '../../services/background_service_manager.dart';

/// 「随机指令集」子动作 → [RcStepKind] 的回填映射；**不可表示的类型返回 null**。
///
/// ⚠️ 故意**不写 `_ =>` 兜底**（BUG-058）：[ActionConfig] 是 **sealed**，
/// 一旦写 `_` 就**关掉了编译器的穷尽性检查** —— 以后新增动作类型会静默掉进兜底。
/// 修之前这里正是 `_ => RcStepKind.play`：复合 / 声景 / 嵌套动作组都会被当成
/// "播放音频"回填，用户**打开编辑器再保存**（哪怕什么都没改）就把原配置悄悄改掉了。
///
/// 现在改成**显式穷尽 + null**：新增 [ActionConfig] 子类时这里**编译报错**，
/// 逼人显式登记，而不是悄悄当 play 处理。返回 null 的子动作由编辑器
/// [TaskEditorScreen] **原样保留**（`_setPreserved`），保存时不丢。
RcStepKind? stepKindOfAction(ActionConfig a) => switch (a) {
      PlayAudioAction() => RcStepKind.play,
      TtsAction() => RcStepKind.tts,
      NotifyAction() => RcStepKind.notify,
      VibrateAction() => RcStepKind.vibrate,
      RecordEvidenceAction() => RcStepKind.record,
      // 这三种在"随机指令集"编辑器里没有对应控件 → 不可表示，交回原配置保留。
      CompositeAction() => null,
      SoundscapeAction() => null,
      ActionSetAction() => null,
    };

/// 任务编辑器：触发方式 -> 时间参数 -> 动作 -> 音源 -> 保存。
/// 编辑器刻意保持“单页分组 + 底部保存”，降低复杂度。
///
/// ## 远程目标模式（v1.7，docs/14 §2.1）
///
/// 传入 [remoteTarget] 时，编辑器不读也不写本机仓储，而是把构建好的
/// [Task] 交给调用方注入的 [RemoteTaskTarget.save]（由「远程 → 任务」页
/// 负责编码为线格式并发送 `task.upsert`）。
/// 这样**一套编辑 UI 同时服务本机任务与端点任务**，无需为远程另写一份
/// 表单 —— 这正是「远程与本机功能对齐」的落点：不是长得像，而是同一份实现。
class TaskEditorScreen extends ConsumerStatefulWidget {
  const TaskEditorScreen({
    super.key,
    this.taskId,
    this.initialTask,
    this.remoteTarget,
  });

  final String? taskId;

  /// 远程模式的初始定义（null = 远程新建）。
  final Task? initialTask;

  /// 非空即进入远程模式。
  final RemoteTaskTarget? remoteTarget;

  @override
  ConsumerState<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

/// 远程任务保存目标。
class RemoteTaskTarget {
  const RemoteTaskTarget({
    required this.endpointName,
    required this.save,
  });

  /// 端点名称（用于标题与保存失败提示）。
  final String endpointName;

  /// 发送任务定义；返回 false 表示端点拒绝或离线。
  final Future<bool> Function(Task task) save;
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

  // 声景混音（v1.3）
  final List<SoundscapeTrack> _scTracks = [];
  int _scDurationSec = 60;
  int _scFadeOutSec = 5;

  // 条件层（v1.3；v1.7 新增 Wi-Fi 与通话保护；v1.8 概率门）
  bool _condCharging = false;
  int? _condMinBattery;
  int? _condWinStart;
  int? _condWinEnd;
  bool _condWifi = false;
  int _condProbability = 100; // 概率门（100=必执行，v1.8）

  // 随机指令集（v1.8）：候选动作种类 + 对应权重（平行数组）。
  final List<RcStepKind> _setCandidates = [];
  final List<double> _setWeights = [];

  /// 不可在编辑器中表示、需**原样保留**的子动作（复合 / 声景 / 嵌套动作组）。
  ///
  /// 见 [stepKindOfAction]：这些类型返回 null，若不保留，用户打开编辑器
  /// 再保存就会**静默丢掉**它们（BUG-058）。
  final List<ActionSetCandidate> _setPreserved = [];

  /// 通话中不执行。**默认开启**（安全默认，见 TaskCondition 类文档）：
  /// 定时音频灌进通话里对双方都是干扰，且使用者无法预期。
  bool _condSkipCall = true;

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
    // 远程模式（v1.7）：定义由调用方（端点任务页）从 `rc.task` 回执解析后传入，
    // 不读本机仓储——远程任务属于端点设备，本机库里没有它。
    final remote = widget.remoteTarget;
    if (remote != null) {
      final t = widget.initialTask;
      if (t == null) {
        setState(() => _loaded = true);
        return;
      }
      setState(() {
        _editing = t;
        _nameCtrl.text = t.name;
        _type = t.triggerType;
        _loaded = true;
        _applyTask(t);
      });
      return;
    }
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
      _applyTask(t);
    });
  }

  /// 把已解析的任务回填到编辑器的各控件（本机与远程模式共用）。
  void _applyTask(Task t) {
    {
      // 条件层回填（v1.3；v1.7 新增字段）。
      final c = t.condition;
      if (c != null) {
        _condCharging = c.requireCharging;
        _condMinBattery = c.minBatteryPct;
        _condWinStart = c.windowStartMin;
        _condWinEnd = c.windowEndMin;
        _condWifi = c.requireWifi;
        _condSkipCall = c.skipInCall;
        _condProbability = c.probabilityPct ?? 100;
      }
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
      } else if (a is SoundscapeAction) {
        _scTracks.addAll(a.tracks);
        _scDurationSec = a.durationSec;
        _scFadeOutSec = a.fadeOutSec;
        _actionKind = ActionKindChoice.soundscape;
      } else if (a is ActionSetAction) {
        _setCandidates.clear();
        _setWeights.clear();
        _setPreserved.clear();
        for (final c in a.candidates) {
          final k = _kindOfCandidate(c.action);
          if (k == null) {
            _setPreserved.add(c); // 不可编辑：原样保留，保存时不丢
          } else {
            _setCandidates.add(k);
            _setWeights.add(c.weight);
          }
        }
        _actionKind = ActionKindChoice.randomFrom;
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
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: Text(_titleText)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_titleText),
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
          const SizedBox(height: 16),
          _section(context, '执行条件'),
          ..._conditionInputs(context),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 声景混音编辑区（v1.3）：1–4 轨（预置分类+音量+循环），总时长与渐出。
  List<Widget> _soundscapeInputs(BuildContext ctx) {
    const categories = <String, String>{
      'ambient': '助眠底噪',
      'nature': '自然',
      'knocks': '敲击',
      'impacts': '撞击',
      'drags': '拖拽',
      'doors': '门窗',
      'glass': '玻璃',
      'human': '人声',
      'animals': '动物',
      'bells': '铃声',
      'alarms': '警示',
      'tech': '电子',
    };
    return [
      const SizedBox(height: 8),
      for (var i = 0; i < _scTracks.length; i++)
        Card(
          child: ListTile(
            leading:
                Icon(Icons.layers, color: Theme.of(ctx).colorScheme.primary),
            title: Text('轨道 ${i + 1}：'
                '${categories[_scTracks[i].presetCategory] ?? _scTracks[i].presetCategory ?? '指定音源'}'
                ' · ${(_scTracks[i].volume * 100).round()}%'
                '${_scTracks[i].loop ? ' · 循环' : ''}'),
            subtitle: Slider(
              value: _scTracks[i].volume,
              onChanged: (v) => setState(() => _scTracks[i] = SoundscapeTrack(
                  presetCategory: _scTracks[i].presetCategory,
                  assetId: _scTracks[i].assetId,
                  volume: v,
                  loop: _scTracks[i].loop)),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(() => _scTracks.removeAt(i)),
            ),
          ),
        ),
      if (_scTracks.length < 4)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in categories.entries)
                ActionChip(
                  label:
                      Text('＋${e.value}', style: const TextStyle(fontSize: 12)),
                  onPressed: () => setState(() =>
                      _scTracks.add(SoundscapeTrack(presetCategory: e.key))),
                ),
            ],
          ),
        ),
      ListTile(
        title: Text('总时长：$_scDurationSec 秒'),
        subtitle: Slider(
          value: _scDurationSec.toDouble(),
          min: 15,
          max: 600,
          divisions: 39,
          label: '$_scDurationSec s',
          onChanged: (v) => setState(() => _scDurationSec = v.round()),
        ),
      ),
      ListTile(
        title: Text('渐出：$_scFadeOutSec 秒'),
        subtitle: Slider(
          value: _scFadeOutSec.toDouble(),
          min: 1,
          max: 15,
          divisions: 14,
          label: '$_scFadeOutSec s',
          onChanged: (v) => setState(() => _scFadeOutSec = v.round()),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Text(
            '声景混音将多轨音源同时叠加播放（如雨声+雷声+风扇），'
            '到点后自动渐出。需先在音源库导入预置音效。',
            style: TextStyle(fontSize: 12)),
      ),
    ];
  }

  /// 条件层编辑区（v1.3；v1.7 新增 Wi-Fi 与通话保护）。
  List<Widget> _conditionInputs(BuildContext ctx) {
    return [
      // 安全护栏置顶：默认开启，且这是唯一"关掉会打扰他人"的开关。
      SwitchListTile(
        title: const Text('通话中不执行'),
        subtitle: const Text('避免音频灌进通话（默认开启，建议保持）'),
        value: _condSkipCall,
        onChanged: (v) => setState(() => _condSkipCall = v),
      ),
      SwitchListTile(
        title: const Text('仅 Wi-Fi 下执行'),
        subtitle: const Text('移动网络下跳过，避免消耗流量'),
        value: _condWifi,
        onChanged: (v) => setState(() => _condWifi = v),
      ),
      // 概率门（v1.8）：确定性条件全部通过后再掷随机门。
      ListTile(
        title: Text(
            '执行概率：${_condProbability >= 100 ? "每次都执行" : "$_condProbability%"}'),
        subtitle: Slider(
          value: _condProbability.toDouble(),
          min: 5,
          max: 100,
          divisions: 19,
          label: _condProbability >= 100 ? '100%（必执行）' : '$_condProbability%',
          onChanged: (v) => setState(() => _condProbability = v.round()),
        ),
      ),
      SwitchListTile(
        title: const Text('仅充电时执行'),
        value: _condCharging,
        onChanged: (v) => setState(() => _condCharging = v),
      ),
      ListTile(
        title: Text(
            '最低电量：${_condMinBattery == null ? '不限' : '$_condMinBattery%'}'),
        trailing: DropdownButton<int?>(
          value: _condMinBattery,
          hint: const Text('不限'),
          items: [
            const DropdownMenuItem(value: null, child: Text('不限')),
            for (final v in [10, 20, 30, 50, 70])
              DropdownMenuItem(value: v, child: Text('$v%')),
          ],
          onChanged: (v) => setState(() => _condMinBattery = v),
        ),
      ),
      ListTile(
        title: Text('时段窗口：${_condWinText()}'),
        trailing: SizedBox(
          width: 180,
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<int?>(
                  value: _condWinStart,
                  hint: const Text('开始'),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('不限')),
                    for (var h = 0; h < 24; h++)
                      DropdownMenuItem(
                          value: h * 60,
                          child: Text('${h.toString().padLeft(2, '0')}:00')),
                  ],
                  onChanged: (v) => setState(() => _condWinStart = v),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: DropdownButton<int?>(
                  value: _condWinEnd,
                  hint: const Text('结束'),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('不限')),
                    for (var h = 1; h <= 24; h++)
                      DropdownMenuItem(
                          value: h * 60 % 1440,
                          child: Text(
                              '${h % 24 == 0 ? '24' : (h).toString().padLeft(2, '0')}:00')),
                  ],
                  onChanged: (v) => setState(() => _condWinEnd = v),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  String _condWinText() {
    if (_condWinStart == null || _condWinEnd == null) return '不限';
    String hm(int m) =>
        '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
    return '${hm(_condWinStart!)}–${hm(_condWinEnd!)}';
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
      case ActionKindChoice.soundscape:
        return [const SizedBox(height: 8), ..._soundscapeInputs(context)];
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
      case ActionKindChoice.randomFrom:
        return _randomSetInputs(ctx);
    }
  }

  /// 随机指令集编辑（v1.8）：候选动作列表 + 权重滑条。
  /// 触发命中后按权重随机选一执行——"随机播放声音中的某一个 / 随机执行某一指令"。
  List<Widget> _randomSetInputs(BuildContext ctx) {
    const kinds = <(RcStepKind, String, IconData)>[
      (RcStepKind.play, '播放音频', Icons.volume_up),
      (RcStepKind.tts, '语音播报', Icons.record_voice_over),
      (RcStepKind.notify, '通知', Icons.notifications),
      (RcStepKind.vibrate, '震动', Icons.vibration),
      (RcStepKind.record, '录音取证', Icons.fiber_manual_record),
    ];
    return [
      const SizedBox(height: 8),
      Text('候选动作（命中后按权重随机选一执行）', style: Theme.of(ctx).textTheme.bodySmall),
      const SizedBox(height: 4),
      if (_setCandidates.isEmpty)
        const Card(
            child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('从下方添加至少 2 个候选动作（每个可设权重）。'))),
      for (var i = 0; i < _setCandidates.length; i++)
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(_setIcon(_setCandidates[i]),
                        size: 18, color: Theme.of(ctx).colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(_setLabel(_setCandidates[i]),
                        style: const TextStyle(fontSize: 13)),
                    const Spacer(),
                    IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () =>
                            setState(() => _setCandidates.removeAt(i))),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 8),
                    Text('权重 ${_setWeights[i].round()}',
                        style: const TextStyle(fontSize: 11)),
                    Expanded(
                      child: Slider(
                        value: _setWeights[i],
                        min: 0,
                        max: 10,
                        divisions: 10,
                        label: _setWeights[i].round().toString(),
                        onChanged: (v) => setState(() => _setWeights[i] = v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      if (_setPreserved.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '另有 ${_setPreserved.length} 个子动作（复合 / 声景 / 嵌套动作组）'
              '在此编辑器中没有对应控件，已按原配置保留，保存时不会丢失。',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      if (_setCandidates.length < 8)
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (k, label, icon) in kinds)
              ActionChip(
                avatar: Icon(icon, size: 16),
                label: Text('＋$label', style: const TextStyle(fontSize: 12)),
                onPressed: () => setState(() {
                  _setCandidates.add(k);
                  _setWeights.add(3);
                }),
              ),
          ],
        ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Text(
            '权重 0 = 不选中。全部为 0 时按等概率兜底。执行会审计记录'
            '"权重 → 选中"以便回溯。',
            style: TextStyle(fontSize: 12)),
      ),
    ];
  }

  /// 从候选动作反推 RcStepKind（编辑回填用）—— 见顶层 [stepKindOfAction]。
  RcStepKind? _kindOfCandidate(ActionConfig a) => stepKindOfAction(a);

  IconData _setIcon(RcStepKind k) => switch (k) {
        RcStepKind.play => Icons.volume_up,
        RcStepKind.tts => Icons.record_voice_over,
        RcStepKind.notify => Icons.notifications,
        RcStepKind.vibrate => Icons.vibration,
        RcStepKind.record => Icons.fiber_manual_record,
        RcStepKind.delay => Icons.timer,
      };

  String _setLabel(RcStepKind k) => switch (k) {
        RcStepKind.play => '播放音频',
        RcStepKind.tts => '语音播报',
        RcStepKind.notify => '通知',
        RcStepKind.vibrate => '震动',
        RcStepKind.record => '录音取证',
        RcStepKind.delay => '时延',
      };

  String get _titleText {
    final remote = widget.remoteTarget;
    if (remote != null) {
      return widget.initialTask == null
          ? '新建端点任务 · ${remote.endpointName}'
          : '编辑端点任务 · ${remote.endpointName}';
    }
    return widget.taskId == null ? '新建任务' : '编辑任务';
  }

  /// 保存：远程模式走调用方注入的通道，本机模式写本地仓储并续算计划。
  Future<void> _save() async {
    final task = _buildTask();
    if (task == null) return;

    final remote = widget.remoteTarget;
    if (remote != null) {
      final ok = await remote.save(task);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop();
      } else {
        _toast(context, '端点未确认（离线或拒绝该定义），未写入端点');
      }
      return;
    }

    final repo = await ref.read(taskRepoProvider.future);
    await repo.upsert(task);
    await BackgroundServiceManager.instance.replan();
    if (mounted) Navigator.of(context).pop();
  }

  /// 依据当前表单构建任务定义；校验失败返回 null（已提示用户）。
  Task? _buildTask() {
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
          if (mounted) _toast(context, '请至少选择一个星期');
          return null;
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
      case ActionKindChoice.soundscape:
        // ⚠️ BUG-067：`SoundscapeAction` 的 assert 要求 1–4 轨，而 `_save()`
        // 是 **async** —— 断言在构造期抛出会变成**未处理的 Future 错误**：
        // debug 下红屏，release 下 assert 被剥离 → **静默保存一个 0 轨声景**，
        // 到点什么都不播，用户只会以为"任务没生效"。
        // 校验必须发生在构造**之前**，并给出可读提示（与"每周未选星期"同形）。
        if (_scTracks.isEmpty) {
          if (mounted) _toast(context, '声景混音至少需要 1 条轨道');
          return null;
        }
        action = SoundscapeAction(
          tracks: List<SoundscapeTrack>.from(_scTracks),
          durationSec: _scDurationSec,
          fadeOutSec: _scFadeOutSec,
        );
      case ActionKindChoice.randomFrom:
        // 同理：`ActionSetAction` 要求 2–12 个候选（1 个候选谈不上"随机"，
        // 0 个会在 `pick()` 里越界）。
        if (_setCandidates.length + _setPreserved.length < 2) {
          if (mounted) _toast(context, '随机指令集至少需要 2 个候选动作');
          return null;
        }
        action = ActionSetAction(candidates: [
          for (var i = 0; i < _setCandidates.length; i++)
            ActionSetCandidate(
              weight: _setWeights[i],
              action: switch (_setCandidates[i]) {
                RcStepKind.play => PlayAudioAction(
                    volumeMin: _volMin,
                    volumeMax: _volMax,
                    durationSecMin: _durMin,
                    durationSecMax: _durMax.clamp(_durMin, 120),
                    channel:
                        _alarmChannel ? AudioChannel.alarm : AudioChannel.media,
                  ),
                RcStepKind.tts => TtsAction(text: _ttsText),
                RcStepKind.notify =>
                  NotifyAction(title: '声盾 · 触发', body: _nameCtrl.text),
                RcStepKind.vibrate => const VibrateAction(),
                RcStepKind.record => RecordEvidenceAction(seconds: _recordSec),
                RcStepKind.delay => RecordEvidenceAction(seconds: _recordSec),
              },
            ),
          // 不可编辑的子动作原样带回来 —— 打开编辑器再保存也不丢配置。
          ..._setPreserved,
        ]);
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
        ActionKindChoice.soundscape => ActionType.soundscape,
        ActionKindChoice.tts => ActionType.tts,
        ActionKindChoice.record => ActionType.recordEvidence,
        ActionKindChoice.notify => ActionType.notify,
        ActionKindChoice.composite => ActionType.composite,
        ActionKindChoice.randomFrom => ActionType.randomFrom,
      },
      action: action,
      assetIds: _editing?.assetIds ?? const [],
      cooldownSec: 300,
      quietPolicy: QuietPolicy.skip,
      // 注意 `!_condSkipCall`：关掉通话保护时必须落库一个显式 false 的条件对象，
      // 否则引擎的默认条件（skipInCall=true）会把它覆盖回去，使用者的关闭动作
      // 表现为"开关按了没用"。
      condition: (_condCharging ||
              _condMinBattery != null ||
              (_condWinStart != null && _condWinEnd != null) ||
              _condWifi ||
              !_condSkipCall ||
              _condProbability < 100)
          ? TaskCondition(
              requireCharging: _condCharging,
              minBatteryPct: _condMinBattery,
              windowStartMin: _condWinStart,
              windowEndMin: _condWinEnd,
              windowEndNextDay: (_condWinEnd ?? 0) <= (_condWinStart ?? 0),
              requireWifi: _condWifi,
              skipInCall: _condSkipCall,
              probabilityPct: _condProbability >= 100 ? null : _condProbability,
            )
          : null,
      priority: 0,
      createdAt: _editing?.createdAt ?? now,
      updatedAt: now,
    );
    return task;
  }

  void _toast(BuildContext ctx, String msg) =>
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));

  static String _weekdayName(int d) =>
      const ['一', '二', '三', '四', '五', '六', '日'][d - 1];
}

enum ActionKindChoice {
  play,
  soundscape,
  tts,
  record,
  notify,
  composite,
  randomFrom,
  ;

  String get label => switch (this) {
        ActionKindChoice.play => '随机播放',
        ActionKindChoice.soundscape => '声景混音',
        ActionKindChoice.tts => '语音播报',
        ActionKindChoice.record => '录音取证',
        ActionKindChoice.notify => '通知',
        ActionKindChoice.composite => '通知+播放',
        ActionKindChoice.randomFrom => '随机指令集',
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
