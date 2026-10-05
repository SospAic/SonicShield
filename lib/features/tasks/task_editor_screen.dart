import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/providers.dart';
import '../../data/repositories/task_repository.dart' show AudioAsset;
import '../../domain/models/action.dart';
import '../../domain/models/condition.dart';
import '../../remote/rc_script.dart';
import '../../domain/models/task.dart';
import '../../domain/models/trigger.dart';
import '../../domain/models/vibrate_caps.dart';
import '../../domain/scheduling/vibrate_resolve.dart';
import '../../services/background_service_manager.dart';
import '../../services/native_bridge.dart';

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
      // 随机/持续振动（v1.9）同样**不可表示**：`RcStepKind.vibrate` 的编辑控件
      // 只会生成 `VibrateAction`（固定节奏），映射过去会在保存时把随机脉冲串
      // **静默降级**成固定节奏 —— 与 BUG-058 是同一类错误。
      // 因此返回 null，由 `_setPreserved` 原样保留。
      // ⚠️ 若将来把 `RcStepKind.vibrate` 参数化（docs/20 §10.1），
      // 需要同步放开这里，并补一条"参数不丢"的往返锁。
      RandomVibrateAction() => null,
      ContinuousVibrateAction() => null,
    };

/// 编辑器动作选项 → 领域动作类型（**唯一映射点**，提成顶层函数以便上锁）。
///
/// ⚠️ 为什么必须是可调用的函数而不是 `_save()` 里的一段内联 switch：
/// 曾经 [ActionKindChoice] 里**没有** `vibrate`，于是 `ActionType.vibrate`
/// 的任务打开编辑器后落回默认的 `play`，一按保存就被**静默改成播放任务**。
/// 这个缺陷靠人眼审查发现不了（枚举与选项集在两个地方）。
/// 提成纯函数后，`test/action_kind_coverage_test.dart` 可以断言
/// **每个 [ActionType] 都存在至少一个可产生它的编辑器选项**，
/// 将来新增动作类型时若忘了加选项，那条锁立刻变红。
ActionType actionTypeOfChoice(ActionKindChoice c) => switch (c) {
      ActionKindChoice.play => ActionType.playAudio,
      ActionKindChoice.soundscape => ActionType.soundscape,
      ActionKindChoice.tts => ActionType.tts,
      ActionKindChoice.record => ActionType.recordEvidence,
      ActionKindChoice.notify => ActionType.notify,
      ActionKindChoice.composite => ActionType.composite,
      ActionKindChoice.randomFrom => ActionType.randomFrom,
      ActionKindChoice.vibrateFixed => ActionType.vibrate,
      ActionKindChoice.vibrateRandom => ActionType.randomVibrate,
      ActionKindChoice.vibrateContinuous => ActionType.continuousVibrate,
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

  /// 随机窗口**跨午夜**（P2-05）：结束时刻落在次日（如 20:00–02:00）。
  /// 曾经不回填这个标志 → 编辑一个跨午夜任务再保存就退化成"空窗口"。
  bool _winEndNextDay = false;
  int _timesPerDay = 3;
  int _minGapMin = 30;
  int _maxGapMin = 120;

  /// 固定一次的**日期**（P2-04，只回填时刻会丢日期）。
  ///
  /// 新建时默认取「今天，但若默认时刻已过则顺延到明天」——保证默认值本身
  /// **不是过去时刻**（保存路径对过去的固定一次会显式拒绝）。
  late DateTime _fixedOnceDate = _defaultFixedOnceDate();

  DateTime _defaultFixedOnceDate() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final at = DateTime(today.year, today.month, today.day, _time.hour, _time.minute);
    return at.isAfter(now) ? today : today.add(const Duration(days: 1));
  }

  // 动作参数（随机时长/音量）
  double _volMin = 0.5, _volMax = 1.0;
  int _durMin = 3, _durMax = 15;
  bool _alarmChannel = false;
  bool _loopFill = false;
  int _rampUpSec = 0;

  // ---------------- 振动族（v1.9，docs/20 §4/§9） ----------------

  /// 固定节奏：`[起始延迟, 振, 停, 振, …]`（毫秒）。默认与 `VibrateAction` 一致。
  List<int> _vibPattern = const [0, 300, 200, 300];

  // 随机脉冲（RandomVibrateAction）
  int _rvDurMin = 3, _rvDurMax = 10;
  int _rvOnMin = 150, _rvOnMax = 400;
  int _rvOffMin = 100, _rvOffMax = 600;
  double _rvAmpMin = 0.4, _rvAmpMax = 1.0;
  int _rvMaxPulses = 200;
  int _rvRampUp = 0;
  bool _rvRespectDnd = true;

  // 持续振动（ContinuousVibrateAction）
  int _cvDurMin = 10, _cvDurMax = 30;
  double _cvAmpMin = 0.5, _cvAmpMax = 1.0;
  int _cvJitterMs = 0;
  double _cvSharpMin = 0.0, _cvSharpMax = 0.0;
  int _cvDutyPct = 100;
  int _cvRampUp = 0, _cvRampDown = 0;
  bool _cvRespectDnd = true;

  /// 本机振动能力（null = 尚未读到）。用于**明示降级**（FR-34 口径修正）：
  /// 承诺了振幅/锐度就必须说清"这台设备做不到"。
  VibrateCaps? _caps;

  /// 夜间独立豁免（任务级，v1.9，docs/20 §8）。默认 false。
  /// 主开关关闭时界面**置灰不可点**（Two-Key Safety）。
  bool _quietExempt = false;

  /// 主开关（设置页）当前状态。**只读** —— 编辑器不提供开启入口。
  /// 读 `SharedPreferences`（不做 DB 往返，避免 widget 测试里的假故障）。
  bool _quietExemptMaster = false;

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

  // 随机指令集（v1.8）：候选动作种类 + 权重。
  //
  // ⚠️ P2-06：曾经是 `_setCandidates` / `_setWeights` 两条**平行数组**，
  // 删除候选项时只删了种类这一条、没删权重 → 剩余候选的权重整体错位
  // （删掉第 2 项后，第 3 项的权重顶到第 2 项上）。改为**单一列表**，
  // 种类与权重天然绑定，删除/编辑都不可能错位。
  final List<({RcStepKind kind, double weight})> _setItems = [];

  /// 播放类动作**点名**的音源 id 集合（P1-06）。
  ///
  /// 空集合意味着"到点必然失败（无可用音源）"——保存时会给出明确提示，
  /// 不再像以前那样让用户毫无察觉地存下一个必然失败的播放任务。
  final Set<String> _assetIds = {};

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
    _probeEnv();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  /// 读取本机振动能力（v1.9，docs/20 §5.2 / FR-38）+ 夜间豁免主开关状态。
  ///
  /// ## ⚠️ 为什么这两件事**不能**放进 `_load()`
  ///
  /// `_load()` 在 `taskId == null`（新建）时是**同步**走到 `_loaded = true` 的 ——
  /// `async` 函数体在第一个 `await` 之前是同步执行的，而那句 `_loaded = true`
  /// **没有包在 `setState` 里**（依赖"首帧之前就已置位"这一事实）。
  ///
  /// 一旦在它前面插入任何 `await`（例如读 prefs / 探能力），`_loaded` 就会
  /// 晚于首帧才被置位，而它不会触发重建 → 界面**永远停在加载圈**，
  /// `pumpAndSettle` 直接超时。实测（2026-09-22）：编辑器 30+ 条用例连锁红。
  ///
  /// 所以：任何**环境探测**都必须走这里 —— 独立异步 + `setState` 回写，
  /// 读不到就保持"未授权/未知"（都是更安全的一侧），绝不阻塞页面可用性。
  Future<void> _probeEnv() async {
    try {
      final caps = await NativeBridge.vibrateCapabilities();
      if (mounted) setState(() => _caps = caps);
    } on Object {
      // 桥不可用（桌面 / 测试未打桩）→ 保持 null，不猜。
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final on = prefs.getBool(PrefsKeys.quietExemptMaster) ?? false;
      if (mounted) setState(() => _quietExemptMaster = on);
    } on Object {
      // 读不到就按"未授权"处理 —— 降级到**更安全**的一侧（开关置灰）。
      if (mounted) setState(() => _quietExemptMaster = false);
    }
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
    if (t == null) {
      // 任务已被删除（或 id 失效）：必须置 `_loaded`，否则页面**永远停在
      // 加载圈**，"点了没反应"（此处已在 await 之后，必须走 setState）。
      if (mounted) setState(() => _loaded = true);
      return;
    }
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
      // 夜间独立豁免（v1.9）：**必须回填**，否则"打开编辑器再保存"
      // 会把用户已开的豁免静默关掉（保存路径显式写 `_quietExempt`）。
      _quietExempt = t.quietExempt;
      // 音源池回填（P1-06）：不回填的话，"打开编辑器再保存"会把已点名的
      // 音源整体清空 —— 与"编辑即静默改配置"同类错误。
      _assetIds
        ..clear()
        ..addAll(t.assetIds);
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
        // P2-04：必须同时回填**日期**，只取时刻会把远期任务悄悄改成"今天"。
        _fixedOnceDate = DateTime(tr.at.year, tr.at.month, tr.at.day);
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
        // P2-05：跨午夜标志必须回填，否则 20:00–02:00 的窗口会被当成
        // "同日 20:00–02:00"（零长度），保存后计划为空。
        _winEndNextDay = tr.windowEndNextDay;
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
        _setItems.clear();
        _setPreserved.clear();
        for (final c in a.candidates) {
          final k = _kindOfCandidate(c.action);
          if (k == null) {
            _setPreserved.add(c); // 不可编辑：原样保留，保存时不丢
          } else {
            _setItems.add((kind: k, weight: c.weight));
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
      } else if (a is VibrateAction) {
        // v1.9 修复：此前没有这条分支 → 震动任务打开编辑器后 `_actionKind`
        // 停留在默认 `play`，保存即**静默变成播放任务**。
        _vibPattern = List<int>.from(a.patternMs);
        _actionKind = ActionKindChoice.vibrateFixed;
      } else if (a is RandomVibrateAction) {
        _rvDurMin = a.durationSecMin;
        _rvDurMax = a.durationSecMax;
        _rvOnMin = a.pulseOnMsMin;
        _rvOnMax = a.pulseOnMsMax;
        _rvOffMin = a.pulseOffMsMin;
        _rvOffMax = a.pulseOffMsMax;
        _rvAmpMin = a.amplitudeMin;
        _rvAmpMax = a.amplitudeMax;
        _rvMaxPulses = a.maxPulses;
        _rvRampUp = a.rampUpSec;
        _rvRespectDnd = a.respectDnd;
        _actionKind = ActionKindChoice.vibrateRandom;
      } else if (a is ContinuousVibrateAction) {
        _cvDurMin = a.durationSecMin;
        _cvDurMax = a.durationSecMax;
        _cvAmpMin = a.amplitudeMin;
        _cvAmpMax = a.amplitudeMax;
        _cvJitterMs = a.jitterMs;
        _cvSharpMin = a.sharpnessMin;
        _cvSharpMax = a.sharpnessMax;
        _cvDutyPct = a.dutyCyclePct;
        _cvRampUp = a.rampUpSec;
        _cvRampDown = a.rampDownSec;
        _cvRespectDnd = a.respectDnd;
        _actionKind = ActionKindChoice.vibrateContinuous;
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
          if (widget.remoteTarget == null) ...[
            _section(context, '夜间独立豁免'),
            _quietExemptTile(),
          ],
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

  /// 本地日期渲染（`yyyy-MM-dd`），供固定一次日期项显示。
  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
          // P2-04：固定一次必须能选**日期**（原先只有时刻，保存时日期被顶替）。
          if (_type == TriggerType.fixedOnce)
            ListTile(
              leading: const Icon(Icons.calendar_today),
              title: Text('日期：${_fmtDate(_fixedOnceDate)}'),
              subtitle: const Text('固定一次只在所选日期的该时刻触发'),
              onTap: () async {
                final d = await showDatePicker(
                  context: ctx,
                  initialDate: _fixedOnceDate,
                  firstDate: DateTime.now().subtract(const Duration(days: 1)),
                  lastDate: DateTime.now().add(const Duration(days: 3650)),
                );
                if (d != null) setState(() => _fixedOnceDate = d);
              },
            ),
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
            // P2-05：跨午夜窗口（如 20:00–02:00）必须显式声明并回填；
            // 否则"结束早于开始"会被当成零长度窗口，计划为空。
            SwitchListTile(
              title: const Text('窗口跨午夜（结束在次日）'),
              subtitle: const Text('例如 20:00–02:00：结束时刻落在第二天'),
              value: _winEndNextDay,
              onChanged: (v) => setState(() => _winEndNextDay = v),
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

  /// 音源选择入口（P1-06）。
  ///
  /// 播放类动作的效果完全取决于"点名了哪些音源"：空集合在引擎侧直接
  /// 判 `无可用音源` 失败（FR-02，**刻意不改成随机兜底**）。因此这里要么
  /// 让用户显式选，要么把"未选 = 必然失败"讲清楚。
  Widget _assetPickerTile(BuildContext ctx) {
    final empty = _assetIds.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(empty ? Icons.error_outline : Icons.library_music,
              color: empty ? Theme.of(ctx).colorScheme.error : null),
          title: Text(empty ? '音源：未选择' : '音源：已选 ${_assetIds.length} 条'),
          subtitle: Text(empty
              ? '未点名音源，到点将因「无可用音源」失败'
              : '命中后从已选音源中等概率随机一条'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickAssets(),
        ),
        if (empty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('请至少选择一条音源（或点击对话框里的“全库随机”全选当前音源库）。',
                style: TextStyle(
                    fontSize: 12, color: Theme.of(ctx).colorScheme.error)),
          ),
      ],
    );
  }

  /// 打开音源多选对话框（**按需读库**：只有点开时才触发一次查询，
  /// 避免给每个编辑器用例都塞一次异步 DB 往返）。
  Future<void> _pickAssets() async {
    List<AudioAsset> all;
    try {
      final repo = await ref.read(assetRepoProvider.future);
      all = await repo.listAll();
    } on Object catch (e) {
      if (mounted) _toast(context, '音源库读取失败：$e');
      return;
    }
    if (!mounted) return;
    if (all.isEmpty) {
      _toast(context, '音源库为空：请先在「声音」页导入音源，否则播放任务无法执行');
      return;
    }
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _AssetPickerDialog(assets: all, selected: _assetIds),
    );
    if (picked != null && mounted) {
      setState(() => _assetIds
        ..clear()
        ..addAll(picked));
    }
  }

  List<Widget> _actionInputs(BuildContext ctx) {
    final playInputs = [
      // P1-06：播放类动作必须能点名音源；未选时**显式**告知"到点必然失败"。
      _assetPickerTile(ctx),
      const Divider(height: 8),
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
      case ActionKindChoice.vibrateFixed:
        return _vibrateFixedInputs();
      case ActionKindChoice.vibrateRandom:
        return _vibrateRandomInputs();
      case ActionKindChoice.vibrateContinuous:
        return _vibrateContinuousInputs();
    }
  }

  /// 能力提示条（v1.9，FR-38 / docs/20 §5.2）。
  ///
  /// ⚠️ **不得静默降级**：承诺了振幅/锐度却做不到时，必须在这里说清楚。
  /// 与"无震动设备"是两回事 —— 后者是"这台机器没有硬件"，
  /// 前者是"设置保存了但系统会忽略它"。
  List<Widget> _vibrateCapHint(ActionConfig action) {
    final caps = _caps;
    if (caps == null) {
      return const [
        SizedBox(height: 8),
        Text('无法读取本机振动能力（桥不可用），实际效果以设备为准。',
            style: TextStyle(fontSize: 12)),
      ];
    }
    final notes = vibrateDegradations(caps, action);
    if (notes.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('本机能力提示',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              for (final n in notes)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('· $n', style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  /// 固定节奏（v1.x 既有能力）：模式串 + 时长/强度不受随机化影响。
  List<Widget> _vibrateFixedInputs() {
    final a = VibrateAction(patternMs: _vibPattern);
    return [
      const SizedBox(height: 8),
      const Text('按固定节奏振动（毫秒序列：起始延迟、振、停、振…）。',
          style: TextStyle(fontSize: 12)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          for (var i = 0; i < _vibPattern.length; i++)
            InputChip(
              label: Text('${_vibPattern[i]}ms'),
              onPressed: () => setState(() {
                final v = _vibPattern[i];
                _vibPattern = List<int>.from(_vibPattern)..[i] = v >= 1000 ? 50 : v + 50;
              }),
            ),
        ],
      ),
      const SizedBox(height: 4),
      Text('点击任一格 +50ms（超过 1000ms 回到 50ms）。共 ${_vibPattern.length} 步。',
          style: const TextStyle(fontSize: 11)),
      ..._vibrateCapHint(a),
    ];
  }

  /// 随机脉冲（FR-36）：脉冲时长 / 间隔 / 强度全部在区间内随机。
  List<Widget> _vibrateRandomInputs() {
    final a = RandomVibrateAction(
      durationSecMin: _rvDurMin,
      durationSecMax: _rvDurMax,
      pulseOnMsMin: _rvOnMin,
      pulseOnMsMax: _rvOnMax,
      pulseOffMsMin: _rvOffMin,
      pulseOffMsMax: _rvOffMax,
      amplitudeMin: _rvAmpMin,
      amplitudeMax: _rvAmpMax,
      maxPulses: _rvMaxPulses,
      rampUpSec: _rvRampUp,
      respectDnd: _rvRespectDnd,
    );
    return [
      const SizedBox(height: 8),
      const Text('每个脉冲的时长、间隔与强度都在区间内随机（"计划即审计"：'
          '实际取值在物化期敲定并落库，重启不漂移）。',
          style: TextStyle(fontSize: 12)),
      _RangeSliderTile(
        label: '总时长（秒）',
        min: 1,
        max: 120,
        start: _rvDurMin.toDouble(),
        end: _rvDurMax.toDouble(),
        format: (v) => '${v.round()}s',
        onChanged: (s, e) => setState(() {
          _rvDurMin = s.round().clamp(1, 120);
          _rvDurMax = e.round().clamp(_rvDurMin, 120);
        }),
      ),
      _RangeSliderTile(
        label: '单次振动时长（毫秒）',
        min: VibrateLimits.minPulseOnMs.toDouble(),
        max: VibrateLimits.maxPulseOnMs.toDouble(),
        start: _rvOnMin.toDouble(),
        end: _rvOnMax.toDouble(),
        format: (v) => '${v.round()}ms',
        onChanged: (s, e) => setState(() {
          _rvOnMin = s.round().clamp(VibrateLimits.minPulseOnMs, VibrateLimits.maxPulseOnMs);
          _rvOnMax = e.round().clamp(_rvOnMin, VibrateLimits.maxPulseOnMs);
        }),
      ),
      _RangeSliderTile(
        label: '脉冲间隔（毫秒）',
        min: 0,
        max: VibrateLimits.maxPulseOffMs.toDouble(),
        start: _rvOffMin.toDouble(),
        end: _rvOffMax.toDouble(),
        format: (v) => '${v.round()}ms',
        onChanged: (s, e) => setState(() {
          _rvOffMin = s.round().clamp(0, VibrateLimits.maxPulseOffMs);
          _rvOffMax = e.round().clamp(_rvOffMin, VibrateLimits.maxPulseOffMs);
        }),
      ),
      _RangeSliderTile(
        label: '强度',
        min: 0,
        max: 1,
        start: _rvAmpMin,
        end: _rvAmpMax,
        format: (v) => '${(v * 100).round()}%',
        onChanged: (s, e) => setState(() {
          _rvAmpMin = s.clamp(0.0, 1.0);
          _rvAmpMax = e.clamp(_rvAmpMin, 1.0);
        }),
      ),
      _IntStepper(
        label: '脉冲数上限（防爆护栏）',
        value: _rvMaxPulses,
        min: 1,
        max: VibrateLimits.maxPulses,
        onChanged: (v) => setState(() => _rvMaxPulses = v),
      ),
      _IntStepper(
        label: '渐强（秒，0=关闭）',
        value: _rvRampUp,
        min: 0,
        max: VibrateLimits.maxRampSec,
        onChanged: (v) => setState(() => _rvRampUp = v),
      ),
      _dndSwitch(
        value: _rvRespectDnd,
        onChanged: (v) => setState(() => _rvRespectDnd = v),
      ),
      ..._vibrateCapHint(a),
    ];
  }

  /// 持续振动（FR-37）：可设随机振幅区间 + 波动周期 + 锐度 + 占空比 + 渐强/渐弱。
  List<Widget> _vibrateContinuousInputs() {
    final a = ContinuousVibrateAction(
      durationSecMin: _cvDurMin,
      durationSecMax: _cvDurMax,
      amplitudeMin: _cvAmpMin,
      amplitudeMax: _cvAmpMax,
      jitterMs: _cvJitterMs,
      sharpnessMin: _cvSharpMin,
      sharpnessMax: _cvSharpMax,
      dutyCyclePct: _cvDutyPct,
      rampUpSec: _cvRampUp,
      rampDownSec: _cvRampDown,
      respectDnd: _cvRespectDnd,
    );
    return [
      const SizedBox(height: 8),
      const Text('持续振动：可在设定时长内保持振动，并让强度随机波动。',
          style: TextStyle(fontSize: 12)),
      _RangeSliderTile(
        label: '总时长（秒）',
        min: 1,
        max: 600,
        start: _cvDurMin.toDouble(),
        end: _cvDurMax.toDouble(),
        format: (v) => '${v.round()}s',
        onChanged: (s, e) => setState(() {
          _cvDurMin = s.round().clamp(1, 600);
          _cvDurMax = e.round().clamp(_cvDurMin, 600);
        }),
      ),
      _RangeSliderTile(
        label: '随机振幅',
        min: 0,
        max: 1,
        start: _cvAmpMin,
        end: _cvAmpMax,
        format: (v) => '${(v * 100).round()}%',
        onChanged: (s, e) => setState(() {
          _cvAmpMin = s.clamp(0.0, 1.0);
          _cvAmpMax = e.clamp(_cvAmpMin, 1.0);
        }),
      ),
      _IntStepper(
        label: '强度波动周期（毫秒，0=恒定）',
        value: _cvJitterMs,
        min: 0,
        max: VibrateLimits.maxJitterMs,
        onChanged: (v) => setState(() => _cvJitterMs = v),
      ),
      _RangeSliderTile(
        label: '锐度（仅 Android 16 生效）',
        min: 0,
        max: 1,
        start: _cvSharpMin,
        end: _cvSharpMax,
        format: (v) => v.toStringAsFixed(2),
        onChanged: (s, e) => setState(() {
          _cvSharpMin = s.clamp(0.0, 1.0);
          _cvSharpMax = e.clamp(_cvSharpMin, 1.0);
        }),
      ),
      _IntStepper(
        label: '占空比（%，100=不停顿）',
        value: _cvDutyPct,
        min: 10,
        max: 100,
        onChanged: (v) => setState(() => _cvDutyPct = v),
      ),
      _IntStepper(
        label: '渐强（秒）',
        value: _cvRampUp,
        min: 0,
        max: VibrateLimits.maxRampSec,
        onChanged: (v) => setState(() => _cvRampUp = v),
      ),
      _IntStepper(
        label: '渐弱（秒）',
        value: _cvRampDown,
        min: 0,
        max: VibrateLimits.maxRampSec,
        onChanged: (v) => setState(() => _cvRampDown = v),
      ),
      _dndSwitch(
        value: _cvRespectDnd,
        onChanged: (v) => setState(() => _cvRespectDnd = v),
      ),
      ..._vibrateCapHint(a),
    ];
  }

  /// 「勿扰」开关：关掉会**穿透系统勿扰**，必须写明后果（与音频 alarm 通道同口径）。
  Widget _dndSwitch({required bool value, required ValueChanged<bool> onChanged}) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('遵循系统勿扰'),
      subtitle: Text(value
          ? '开启：系统勿扰时段内不会振动（推荐）'
          : '⚠️ 已关闭：将使用闹钟级振动属性，**会穿透系统勿扰**'),
      value: value,
      onChanged: onChanged,
    );
  }

  /// 任务级夜间豁免开关（v1.9，docs/20 §8.1）。
  ///
  /// **主开关关闭时置灰不可点** —— Two-Key Safety 的第二把钥匙只有在
  /// 第一把（设置页主开关）已开启时才有意义。置灰而不是隐藏：
  /// 让用户看得见"这个能力存在、但需要先去设置页授权"，
  /// 否则他只会以为本应用不支持。
  Widget _quietExemptTile() {
    final master = _quietExemptMaster;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('本任务豁免免打扰'),
          subtitle: Text(master
              ? (_quietExempt
                  ? '已开启：本任务在免打扰时段（含夜间）照常执行，每次都会写日志'
                  : '关闭中：本任务在免打扰时段按策略跳过或平移')
              : '需要先在「设置 → 夜间独立豁免（主开关）」中开启，本开关才会生效'),
          value: _quietExempt && master,
          onChanged: master ? (v) => setState(() => _quietExempt = v) : null,
        ),
        if (!master)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text('主开关关闭时，本开关不生效（双重开关设计，防止误开）。',
                style: TextStyle(fontSize: 12)),
          ),
      ],
    );
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
      if (_setItems.isEmpty)
        const Card(
            child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('从下方添加至少 2 个候选动作（每个可设权重）。'))),
      for (var i = 0; i < _setItems.length; i++)
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(_setIcon(_setItems[i].kind),
                        size: 18, color: Theme.of(ctx).colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(_setLabel(_setItems[i].kind),
                        style: const TextStyle(fontSize: 13)),
                    const Spacer(),
                    IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        // P2-06：单一列表删除，种类与权重不可能错位。
                        onPressed: () => setState(() => _setItems.removeAt(i))),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 8),
                    Text('权重 ${_setItems[i].weight.round()}',
                        style: const TextStyle(fontSize: 11)),
                    Expanded(
                      child: Slider(
                        value: _setItems[i].weight,
                        min: 0,
                        max: 10,
                        divisions: 10,
                        label: _setItems[i].weight.round().toString(),
                        onChanged: (v) => setState(() => _setItems[i] =
                            (kind: _setItems[i].kind, weight: v)),
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
      if (_setItems.length < 8)
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (k, label, icon) in kinds)
              ActionChip(
                avatar: Icon(icon, size: 16),
                label: Text('＋$label', style: const TextStyle(fontSize: 12)),
                onPressed: () => setState(() {
                  _setItems.add((kind: k, weight: 3));
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
        // ⚠️ **必须带上 `true`**（BUG-073）：远程模式的唯一调用方
        // （`remote_tasks_tab._openEditor`）用的是 `push<bool>`，并在
        // `saved == true` 时才刷新列表 + 提示「已写入端点」。
        // 原先这里是无参 `pop()` → 结果恒为 `null` → 那个分支**永远不执行**：
        // 任务其实写进端点了，但列表不刷新、也没有任何确认，
        // 用户会以为"没保存成功"。
        // 与"离线入队被误报成功"相反 —— 这是**成功被误报成沉默**。
        Navigator.of(context).pop(true);
      } else {
        _toast(context, '端点未确认（离线或拒绝该定义），未写入端点');
      }
      return;
    }

    try {
      final repo = await ref.read(taskRepoProvider.future);
      await repo.upsert(task);
      await BackgroundServiceManager.instance.replan();
    } on Object catch (e) {
      // 失败必须可见：不能让异常穿透 onChanged 变成未处理错误，
      // 也不能不 pop 让用户误以为"没保存成功"却不知原因。
      if (mounted) _toast(context, '保存失败：$e');
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// 依据当前表单构建任务定义；校验失败返回 null（已提示用户）。
  Task? _buildTask() {
    final now = DateTime.now();

    TriggerConfig trigger;
    switch (_type) {
      case TriggerType.fixedOnce:
        // P2-04：用回填/选择的**日期** + 时刻拼成完整 DateTime，不再拿
        // "今天 +5 分钟所在的那一天"顶替 —— 编辑远期任务时日期会丢。
        final at = DateTime(_fixedOnceDate.year, _fixedOnceDate.month,
            _fixedOnceDate.day, _time.hour, _time.minute);
        if (!at.isAfter(now)) {
          if (mounted) _toast(context, '固定一次的时间必须晚于当前时间，请重新选择日期/时刻');
          return null;
        }
        trigger = FixedOnceTrigger(at: at);
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
          // P2-05：跨午夜标志必须随保存带出，否则 20:00–02:00 变空窗口。
          windowEndNextDay: _winEndNextDay,
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
        if (_setItems.length + _setPreserved.length < 2) {
          if (mounted) _toast(context, '随机指令集至少需要 2 个候选动作');
          return null;
        }
        action = ActionSetAction(candidates: [
          for (final it in _setItems)
            ActionSetCandidate(
              weight: it.weight,
              action: switch (it.kind) {
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
      case ActionKindChoice.vibrateFixed:
        // 固定节奏：模式串至少要有"延迟 + 一次振动"。
        if (_vibPattern.length < 2) {
          if (mounted) _toast(context, '固定节奏至少需要 2 个数值（延迟 + 振动时长）');
          return null;
        }
        action = VibrateAction(patternMs: List<int>.from(_vibPattern));
      case ActionKindChoice.vibrateRandom:
        // ⚠️ 区间约束由 `assert` 表达，而 `_save()` 是 async ——
        // 断言在构造期抛出会变成**未处理的 Future 错误**（BUG-067 同形）。
        // 因此必须在这里**先校验再构造**，并给可读提示。
        if (_rvDurMin > _rvDurMax || _rvOnMin > _rvOnMax || _rvOffMin > _rvOffMax) {
          if (mounted) _toast(context, '随机振动的区间起点不能大于终点');
          return null;
        }
        action = RandomVibrateAction(
          durationSecMin: _rvDurMin,
          durationSecMax: _rvDurMax,
          pulseOnMsMin: _rvOnMin,
          pulseOnMsMax: _rvOnMax,
          pulseOffMsMin: _rvOffMin,
          pulseOffMsMax: _rvOffMax,
          amplitudeMin: _rvAmpMin,
          amplitudeMax: _rvAmpMax,
          maxPulses: _rvMaxPulses,
          rampUpSec: _rvRampUp,
          respectDnd: _rvRespectDnd,
        );
      case ActionKindChoice.vibrateContinuous:
        if (_cvDurMin > _cvDurMax || _cvAmpMin > _cvAmpMax || _cvSharpMin > _cvSharpMax) {
          if (mounted) _toast(context, '持续振动的区间起点不能大于终点');
          return null;
        }
        action = ContinuousVibrateAction(
          durationSecMin: _cvDurMin,
          durationSecMax: _cvDurMax,
          amplitudeMin: _cvAmpMin,
          amplitudeMax: _cvAmpMax,
          jitterMs: _cvJitterMs,
          sharpnessMin: _cvSharpMin,
          sharpnessMax: _cvSharpMax,
          dutyCyclePct: _cvDutyPct,
          rampUpSec: _cvRampUp,
          rampDownSec: _cvRampDown,
          respectDnd: _cvRespectDnd,
        );
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
      actionType: actionTypeOfChoice(_actionKind),
      action: action,
      // P1-06：使用编辑器里点名的音源（回填自 `_editing.assetIds`，
      // 新建默认空 —— 保存前会就"空音源必然失败"给出明确提示）。
      assetIds: _assetIds.toList(),
      cooldownSec: _editing?.cooldownSec ?? 300,
      quietPolicy: _editing?.quietPolicy ?? QuietPolicy.skip,
      // 夜间独立豁免（v1.9）：
      // · 本机模式 → 用编辑器里的开关值；
      // · **远程模式恒 false**（docs/20 §8.2 约束 1）：端点侧 `TaskWire.fromWire`
      //   本来就会丢弃入站该字段，此处显式置 false 是为了让控制端**不产生**
      //   "我开了豁免"的错觉 —— 界面也不显示这个开关。
      quietExempt: widget.remoteTarget == null ? _quietExempt : false,
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
  // ---- 振动族（v1.9，docs/20 §9）----
  // ⚠️ 这三个必须存在：在它们出现之前，`ActionType.vibrate` 的任务
  // **在编辑器里根本没有对应选项** —— 打开就落回默认的 `play`，
  // 一按保存就把震动任务**静默改成播放任务**（连 `action_json` 都被覆盖）。
  // 这正是"动作类型枚举与编辑器选项集不同步"的后果，只能靠穷尽 switch +
  // 「每种 ActionType 都有可回填的编辑器选项」的锁来防。
  vibrateFixed,
  vibrateRandom,
  vibrateContinuous,
  ;

  String get label => switch (this) {
        ActionKindChoice.play => '随机播放',
        ActionKindChoice.soundscape => '声景混音',
        ActionKindChoice.tts => '语音播报',
        ActionKindChoice.record => '录音取证',
        ActionKindChoice.notify => '通知',
        ActionKindChoice.composite => '通知+播放',
        ActionKindChoice.randomFrom => '随机指令集',
        ActionKindChoice.vibrateFixed => '震动·固定节奏',
        ActionKindChoice.vibrateRandom => '震动·随机脉冲',
        ActionKindChoice.vibrateContinuous => '震动·持续',
      };

  /// 是否属于"震动"分组（用于在界面上加一条分组说明与能力提示条）。
  bool get isVibrate => switch (this) {
        ActionKindChoice.vibrateFixed ||
        ActionKindChoice.vibrateRandom ||
        ActionKindChoice.vibrateContinuous =>
          true,
        _ => false,
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

/// 音源多选对话框（P1-06）：可搜索名称/标签，可一键“全库随机”（全选）。
class _AssetPickerDialog extends StatefulWidget {
  const _AssetPickerDialog({required this.assets, required this.selected});

  final List<AudioAsset> assets;
  final Set<String> selected;

  @override
  State<_AssetPickerDialog> createState() => _AssetPickerDialogState();
}

class _AssetPickerDialogState extends State<_AssetPickerDialog> {
  late final Set<String> _picked = {...widget.selected};
  String _query = '';

  List<AudioAsset> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.assets;
    return widget.assets
        .where((a) =>
            a.name.toLowerCase().contains(q) ||
            a.tags.any((t) => t.toLowerCase().contains(q)))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return AlertDialog(
      title: const Text('选择音源'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search), hintText: '搜索名称 / 标签'),
              onChanged: (v) => setState(() => _query = v),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.select_all, size: 18),
                label: Text('全库随机（全选 ${widget.assets.length} 条）'),
                onPressed: () => setState(() => _picked
                  ..clear()
                  ..addAll(widget.assets.map((a) => a.id))),
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('没有匹配的音源'))
                  : ListView(
                      children: [
                        for (final a in items)
                          CheckboxListTile(
                            dense: true,
                            value: _picked.contains(a.id),
                            title: Text(a.name),
                            subtitle: a.tags.isEmpty
                                ? null
                                : Text(a.tags.join(' · '),
                                    style: const TextStyle(fontSize: 11)),
                            onChanged: (v) => setState(() => v == true
                                ? _picked.add(a.id)
                                : _picked.remove(a.id)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(_picked),
            child: Text('确定（${_picked.length}）')),
      ],
    );
  }
}
