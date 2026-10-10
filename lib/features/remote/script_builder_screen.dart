import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../remote/rc_script.dart';
import '../../remote/remote_store.dart';
import '../../remote/controller_service.dart';
import '../../remote/script_executor.dart';
import '../../domain/models/tts_voice.dart';
import '../../services/remote_tts_presets.dart';
import '../../core/theme.dart';

/// 远程指令组装器：把 play/tts/notify/vibrate/record/delay 组装为序列，
/// 一键发送至已配对端点（端点收到后立即执行，通知栏可随时终止）。
class ScriptBuilderScreen extends ConsumerStatefulWidget {
  const ScriptBuilderScreen({super.key, required this.endpointId});

  final String endpointId;

  @override
  ConsumerState<ScriptBuilderScreen> createState() =>
      _ScriptBuilderScreenState();
}

class _ScriptBuilderScreenState extends ConsumerState<ScriptBuilderScreen> {
  final _nameCtrl = TextEditingController(text: '远程指令组');
  final List<ScriptDraftStep> _steps = [];
  PairedEndpoint? _endpoint;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    setState(() {
      _endpoint = store
          .paired()
          .where((p) => p.deviceId == widget.endpointId)
          .cast<PairedEndpoint?>()
          .firstOrNull;
    });
  }

  void _addStep(RcStepKind kind) {
    setState(() {
      switch (kind) {
        case RcStepKind.play:
          _steps.add(ScriptDraftStep(kind,
              {'volume': 0.9, 'durationSec': 10, 'presetCategory': null}));
        case RcStepKind.tts:
          _steps.add(
              ScriptDraftStep(kind, {'text': '请注意，声盾远程指令', 'volume': 0.8}));
        case RcStepKind.notify:
          _steps.add(ScriptDraftStep(kind, {'title': '声盾', 'body': '远程通知内容'}));
        case RcStepKind.vibrate:
          // 默认仍是固定节奏（`{}`），与老控制器发的线格式完全一致。
          _steps.add(
              ScriptDraftStep(kind, rcVibrateDefaultParams(RcVibrateMode.fixed)));
        case RcStepKind.record:
          _steps.add(ScriptDraftStep(kind, {'seconds': 30}));
        case RcStepKind.delay:
          _steps.add(ScriptDraftStep(kind, {'seconds': 5}));
      }
    });
  }

  void _move(int index, int delta) {
    final j = index + delta;
    if (j < 0 || j >= _steps.length) return;
    setState(() {
      final s = _steps.removeAt(index);
      _steps.insert(j, s);
    });
  }

  /// 编辑框初始值：**按 kind 取当前值**，不能用 `??` 链猜。
  ///
  /// ⚠️ BUG-068：原写法是
  /// `params['text'] ?? params['title'] ?? params['seconds']?.toString() ?? ''`，
  /// 于是 ——
  /// - `play` 的当前时长存在 `durationSec` 里，三个键**一个都取不到** →
  ///   编辑框是**空的**。用户看不到自己在改什么，一确定就把 10 覆盖成他输入的值，
  ///   且无从对照；
  /// - `notify` 的当前内容存在 `body` 里，却**读的是 `title`** → 读写不是同一个字段：
  ///   标签写着「通知内容」，框里显示的却是标题。
  ///
  /// 两类都不抛异常，只会让用户改错东西（项目纪律：展示/编辑类写错**只能靠锁**）。
  /// 用 **switch 表达式**（必须穷尽）→ 将来新增 kind 忘补会编译报错。
  static String _initialEditText(ScriptDraftStep s) => switch (s.kind) {
        RcStepKind.tts => s.params['text']?.toString() ?? '',
        RcStepKind.notify => s.params['body']?.toString() ?? '',
        RcStepKind.delay => s.params['seconds']?.toString() ?? '',
        RcStepKind.record => s.params['seconds']?.toString() ?? '',
        RcStepKind.play => s.params['durationSec']?.toString() ?? '',
        RcStepKind.vibrate => '',
      };

  /// 编辑框标签：**按 kind 取**（switch 穷尽 → 新增 kind 忘补即编译报错）。
  static String _editLabelOf(RcStepKind k) => switch (k) {
        RcStepKind.tts => '播报文本',
        RcStepKind.notify => '通知内容',
        RcStepKind.delay => '时延（秒，0.5–600）',
        RcStepKind.record => '录音时长（秒）',
        RcStepKind.play => '播放时长（秒）',
        RcStepKind.vibrate => '（振动参数见下方选择器）',
      };

  Future<void> _editStep(int index) async {
    final s = _steps[index];

    // 振动步自 v1.9 起**有可编辑参数**（mode + 各区间），走专用对话框
    // （docs/20 §11.1）。固定节奏仍是"无可编辑参数"，但模式本身可切换。
    if (s.kind == RcStepKind.vibrate) {
      final out = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => _VibrateStepDialog(params: s.params),
      );
      if (out != null && mounted) setState(() => s.params = out);
      return;
    }

    // 语音播报步自 v2.0 起**可指定音色**（协议 `tts {text, volume, voiceId?}`，
    // `endpoint_service` 已消费 `voiceId`），走专用对话框（文本 + 音色下拉）。
    if (s.kind == RcStepKind.tts) {
      final out = await showDialog<_TtsStepResult>(
        context: context,
        builder: (ctx) => _TtsStepDialog(
          text: s.params['text']?.toString() ?? '',
          voiceId: s.params['voiceId']?.toString() ?? '',
        ),
      );
      if (out == null || !mounted) return;
      setState(() {
        s.params['text'] = out.text;
        // 选回「系统默认」时**必须删键**，否则旧的 voiceId 会留在 params 里
        // 被继续发出去（用户以为改回了默认，实际还是旧音色——静默失效）。
        if (out.voiceId.isEmpty) {
          s.params.remove('voiceId');
        } else {
          s.params['voiceId'] = out.voiceId;
        }
      });
      return;
    }

    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => _TextStepDialog(
        title: '编辑步骤 · ${s.describe()}',
        label: _editLabelOf(s.kind),
        initial: _initialEditText(s),
      ),
    );
    if (text == null || !mounted) return;
    setState(() {
      switch (s.kind) {
        case RcStepKind.tts:
          s.params['text'] = text;
        case RcStepKind.notify:
          s.params['body'] = text;
        case RcStepKind.delay:
          s.params['seconds'] = double.tryParse(text) ?? 5;
        case RcStepKind.record:
          s.params['seconds'] = int.tryParse(text) ?? 30;
        case RcStepKind.play:
          s.params['durationSec'] = int.tryParse(text) ?? 10;
        // 振动步已在上面 return，不会走到这里；留着是为了让 switch 穷尽。
        case RcStepKind.vibrate:
          break;
      }
    });
  }

  Future<void> _send({bool saveFirst = false}) async {
    final err = ScriptDraft(name: _nameCtrl.text, steps: _steps).validate();
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    if (_endpoint == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('端点不存在')));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    final script = RcScript(
      scriptId: const Uuid().v4(),
      name: _nameCtrl.text,
      fromName: store.deviceName,
      sentAt: DateTime.now().millisecondsSinceEpoch,
      steps: [for (final s in _steps) s.toStep()],
    );
    if (saveFirst) {
      await store.saveScript(SavedScript(
        id: script.scriptId,
        name: script.name,
        payload: script.toJson(),
        savedAt: DateTime.now(),
      ));
    }
    final controller = RcControllerService.instance;
    final ok = await controller.sendScript(_endpoint!, script, store);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok
              ? (saveFirst ? '已保存为模板并发送' : '指令组已发送，端点将立即执行')
              : (saveFirst ? '已保存为模板（端点离线，上线后自动冲刷）' : '发送失败（端点离线或未连接）'))));
      if (ok) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('指令组装器 → ${_endpoint?.name ?? '…'}'),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: FilledButton.icon(
            icon: const Icon(Icons.send),
            label: const Text('发送并立即执行'),
            onPressed: _send,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: '指令组名称'),
          ),
          const SizedBox(height: 12),
          Text('步骤（共 ${_steps.length}）',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (_steps.isEmpty)
            const Card(
                child: Padding(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    child: Text('从下方添加动作与时延元素。端点收到后会立即依次执行，'
                        '通知栏全程显示进度并可随时终止。'))),
          for (var i = 0; i < _steps.length; i++)
            Card(
              child: ListTile(
                leading: Icon(_iconOf(_steps[i].kind)),
                title: Text(_steps[i].describe()),
                onTap: () => _editStep(i),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                        onPressed: () => _move(i, -1),
                        icon: const Icon(Icons.arrow_upward, size: 20)),
                    IconButton(
                        onPressed: () => _move(i, 1),
                        icon: const Icon(Icons.arrow_downward, size: 20)),
                    IconButton(
                        onPressed: () => setState(() => _steps.removeAt(i)),
                        icon: const Icon(Icons.delete_outline, size: 20)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text('添加步骤', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final k in RcStepKind.values)
                ActionChip(
                  avatar: Icon(_iconOf(k), size: 18),
                  label: Text(_labelOf(k)),
                  onPressed: () => _addStep(k),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text(
                '合规提示：远程指令组仅可用于本人设备或已获明确授权的场景。'
                '接收端执行全程审计留痕，通知栏可见并可随时终止。',
                style: AppText.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconOf(RcStepKind k) => switch (k) {
        RcStepKind.play => Icons.volume_up,
        RcStepKind.tts => Icons.record_voice_over,
        RcStepKind.notify => Icons.notifications,
        RcStepKind.vibrate => Icons.vibration,
        RcStepKind.record => Icons.fiber_manual_record,
        RcStepKind.delay => Icons.timer,
      };

  static String _labelOf(RcStepKind k) => switch (k) {
        RcStepKind.play => '随机播放',
        RcStepKind.tts => '语音播报',
        RcStepKind.notify => '通知',
        RcStepKind.vibrate => '震动',
        RcStepKind.record => '录音取证',
        RcStepKind.delay => '时延',
      };
}

/// 单行文本编辑对话框。
///
/// ⚠️ 控制器由**对话框自己**持有并在 `dispose()` 释放（BUG-064 的形状）：
/// `await showDialog` 返回 ≠ 对话框已从树上移除 —— 退场动画期间 `TextField`
/// 仍在引用 controller。此前本文件在外层 `new` 了 controller 且**从不释放**，
/// 既是泄漏，也把 BUG-064 的坑原样留在那里（一旦有人"顺手"补一句
/// `ctrl.dispose()` 就会踩中它）。
class _TextStepDialog extends StatefulWidget {
  const _TextStepDialog({
    required this.title,
    required this.label,
    required this.initial,
  });

  final String title;
  final String label;
  final String initial;

  @override
  State<_TextStepDialog> createState() => _TextStepDialogState();
}

class _TextStepDialogState extends State<_TextStepDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _ctrl,
          decoration: InputDecoration(labelText: widget.label),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _ctrl.text),
              child: const Text('确定')),
        ],
      );
}

/// 语音播报步骤的编辑结果：文本 + 音色 id。
class _TtsStepResult {
  const _TtsStepResult(this.text, this.voiceId);

  final String text;

  /// 空串 = 系统默认（自动挑），对应协议里**不带** `voiceId` 字段。
  final String voiceId;
}

/// 「语音播报」步骤编辑对话框（v2.0）：播报文本 + 音色下拉。
///
/// ⚠️ 音色**必须**用 `DropdownButton`，不能加第二个 `TextField`：既有用例
/// （SBS-06/07）在 `AlertDialog` 里用 `find.byType(TextField)` **无作用域**地
/// 取「唯一的那个框」来 `enterText` 与读值；再多一个输入框会让
/// `tester.widget<TextField>` 抛 "Too many elements"。下拉不参与文本输入，
/// 天然不与之冲突。
///
/// 控制器由本对话框自己持有并释放（BUG-064；`await showDialog` 返回 ≠ 已下树）。
class _TtsStepDialog extends StatefulWidget {
  const _TtsStepDialog({required this.text, required this.voiceId});

  final String text;
  final String voiceId;

  @override
  State<_TtsStepDialog> createState() => _TtsStepDialogState();
}

class _TtsStepDialogState extends State<_TtsStepDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.text);

  /// 未知 id（外部导入的脏数据）回落到「系统默认」，避免 Dropdown 断言。
  late String _voiceId = TtsVoices.all.any((v) => v.id == widget.voiceId)
      ? widget.voiceId
      : '';

  /// 5 个可自定义预置位（异步载入；载入前先用出厂默认，避免闪空）。
  List<String> _presets = RemoteTtsPresets.defaults;

  @override
  void initState() {
    super.initState();
    _loadPresets();
  }

  Future<void> _loadPresets() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _presets = RemoteTtsPresets.read(prefs));
  }

  /// 打开「自定义预置位」对话框并持久化（**独立对话框**：本对话框必须只保留
  /// 1 个 `TextField`，否则 SBS-06/07 的 `find.byType(TextField)` 会报
  /// "Too many elements"）。
  Future<void> _editPresets() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return; // await 之后必须重新确认挂载，否则 context 跨异步间隙使用
    final out = await showDialog<List<String>>(
      context: context,
      builder: (_) => _TtsPresetsDialog(presets: _presets),
    );
    if (out == null || !mounted) return;
    await RemoteTtsPresets.write(prefs, out);
    if (!mounted) return;
    setState(() => _presets = RemoteTtsPresets.normalize(out));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('编辑步骤 · 语音播报'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _ctrl,
                decoration: const InputDecoration(labelText: '播报文本'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('预置位', style: AppText.bodySmall),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _editPresets,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('自定义'),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < _presets.length; i++)
                    ActionChip(
                      label: Text(
                        _presets[i].length > 10
                            ? '${_presets[i].substring(0, 10)}…'
                            : _presets[i],
                      ),
                      onPressed: () =>
                          setState(() => _ctrl.text = _presets[i]),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('音色', style: AppText.bodySmall),
              DropdownButton<String>(
                isExpanded: true,
                value: _voiceId,
                items: [
                  const DropdownMenuItem(value: '', child: Text('系统默认（自动）')),
                  for (final d in TtsDialect.values) ...[
                    DropdownMenuItem(
                      enabled: false,
                      value: '__header_${d.name}',
                      child: Text(d.label, style: AppText.bodySmall),
                    ),
                    for (final v in TtsVoices.all.where((v) => v.dialect == d))
                      DropdownMenuItem(
                        value: v.id,
                        child: Text(
                            '${v.name}（${v.gender.label}${v.isOnline ? '·在线' : ''}）'),
                      ),
                  ],
                ],
                onChanged: (v) => setState(() => _voiceId = v ?? ''),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(
                  context, _TtsStepResult(_ctrl.text, _voiceId)),
              child: const Text('确定')),
        ],
      );
}

/// 「自定义预置位」对话框：5 行输入，保存后持久化。
///
/// 独立于 [_TtsStepDialog]（后者必须只保留 1 个 `TextField`）。
class _TtsPresetsDialog extends StatefulWidget {
  const _TtsPresetsDialog({required this.presets});

  final List<String> presets;

  @override
  State<_TtsPresetsDialog> createState() => _TtsPresetsDialogState();
}

class _TtsPresetsDialogState extends State<_TtsPresetsDialog> {
  late final List<TextEditingController> _ctrls = [
    for (var i = 0; i < RemoteTtsPresets.slotCount; i++)
      TextEditingController(
          text: i < widget.presets.length ? widget.presets[i] : ''),
  ];

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('自定义预置位'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _ctrls.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _ctrls[i],
                    decoration: InputDecoration(labelText: '预置位 ${i + 1}'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, [for (final c in _ctrls) c.text]),
              child: const Text('保存')),
        ],
      );
}

/// 振动步骤编辑对话框（v1.9，docs/20 §11.1）。
///
/// 表单字段来自 [rcVibrateFieldsFor] —— 与端点执行器**共用同一份声明**，
/// 于是"表单能填的键"与"执行器认识的键"在结构上不可能分叉（否则会静默取默认值）。
/// 控制器同样由本对话框持有并释放（BUG-064）。
class _VibrateStepDialog extends StatefulWidget {
  const _VibrateStepDialog({required this.params});

  final Map<String, dynamic> params;

  @override
  State<_VibrateStepDialog> createState() => _VibrateStepDialogState();
}

class _VibrateStepDialogState extends State<_VibrateStepDialog> {
  late RcVibrateMode _mode = rcVibrateModeOf(widget.params['mode']);
  final _ctrls = <String, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  static String _modeLabel(RcVibrateMode m) => switch (m) {
        RcVibrateMode.fixed => '固定节奏',
        RcVibrateMode.random => '随机脉冲',
        RcVibrateMode.continuous => '持续振动',
      };

  static String _fmt(num v) =>
      v is double && v != v.roundToDouble() ? '$v' : '${v.toInt()}';

  /// 初始值：**先读当前参数，读不到才用该 mode 的默认值**。
  /// 不走 `??` 链在别的字段里瞎猜（BUG-068 的教训）。
  String _initial(RcVibrateField f) {
    final v = widget.params[f.key];
    if (v is num) return _fmt(v);
    final d = rcVibrateDefaultParams(_mode)[f.key];
    return d is num ? _fmt(d) : '';
  }

  TextEditingController _ctrl(RcVibrateField f) =>
      _ctrls.putIfAbsent(f.key, () => TextEditingController(text: _initial(f)));

  /// 收集结果。解析不了/留空的键**不写入** → 端点按默认值夹紧，
  /// 而列表标题会立刻显示夹紧后的实际生效值（不制造"填了却没生效"的错觉）。
  Map<String, dynamic> _collect() {
    if (_mode == RcVibrateMode.fixed) return <String, dynamic>{};
    final out = <String, dynamic>{'mode': _mode.name};
    for (final f in rcVibrateFieldsFor(_mode)) {
      final t = _ctrl(f).text.trim();
      final n = f.fraction ? double.tryParse(t) : int.tryParse(t);
      if (n != null) out[f.key] = n;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final fields = rcVibrateFieldsFor(_mode);
    return AlertDialog(
      title: const Text('编辑步骤 · 震动'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('振动模式'),
                  const SizedBox(width: 12),
                  DropdownButton<RcVibrateMode>(
                    value: _mode,
                    onChanged: (m) {
                      if (m != null) setState(() => _mode = m);
                    },
                    items: [
                      for (final m in RcVibrateMode.values)
                        DropdownMenuItem(value: m, child: Text(_modeLabel(m))),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (fields.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text('固定节奏无可编辑参数（协议向后兼容：`{}` 语义不变）',
                      style: AppText.bodySmall),
                ),
              for (final f in fields)
                TextField(
                  controller: _ctrl(f),
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: f.label,
                    helperText: '范围 ${_fmt(f.min)}–${_fmt(f.max)}',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _collect()),
            child: const Text('确定')),
      ],
    );
  }
}
