import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../remote/rc_script.dart';
import '../../remote/remote_store.dart';
import '../../remote/controller_service.dart';
import '../../remote/script_executor.dart';

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
          _steps.add(ScriptDraftStep(kind, {}));
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

  Future<void> _editStep(int index) async {
    final s = _steps[index];
    final ctrl = TextEditingController(text: _initialEditText(s));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑步骤 · ${s.describe()}'),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            labelText: switch (s.kind) {
              RcStepKind.tts => '播报文本',
              RcStepKind.notify => '通知内容',
              RcStepKind.delay => '时延（秒，0.5–600）',
              RcStepKind.record => '录音时长（秒）',
              RcStepKind.play => '播放时长（秒）',
              RcStepKind.vibrate => '（无可编辑参数）',
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        switch (s.kind) {
          case RcStepKind.tts:
            s.params['text'] = ctrl.text;
          case RcStepKind.notify:
            s.params['body'] = ctrl.text;
          case RcStepKind.delay:
            s.params['seconds'] = double.tryParse(ctrl.text) ?? 5;
          case RcStepKind.record:
            s.params['seconds'] = int.tryParse(ctrl.text) ?? 30;
          case RcStepKind.play:
            s.params['durationSec'] = int.tryParse(ctrl.text) ?? 10;
          case RcStepKind.vibrate:
            break;
        }
      });
    }
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
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            icon: const Icon(Icons.send),
            label: const Text('发送并立即执行'),
            onPressed: _send,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
                    padding: EdgeInsets.all(14),
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
              padding: EdgeInsets.all(12),
              child: Text(
                '合规提示：远程指令组仅可用于本人设备或已获明确授权的场景。'
                '接收端执行全程审计留痕，通知栏可见并可随时终止。',
                style: TextStyle(fontSize: 12),
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
