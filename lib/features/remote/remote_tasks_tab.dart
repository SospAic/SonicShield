import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/tasks/task_editor_screen.dart';
import '../../remote/command_channel.dart';
import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';
import '../../remote/task_wire.dart';

/// 远程「任务」子页：管理**端点设备上**的自动化任务。
///
/// 定位（新 IA）：本机任务在「自动化」分组里管理；端点任务在这里管理。
/// 两者**共用同一个编辑器**（[TaskEditorScreen] 的远程目标模式），
/// 因此能力与本机完全对齐：新建 / 编辑 / 启停 / 跳过下一次 / 立即执行 / 删除。
///
/// 协议 v1.7（docs/14 §2.1）：`task.list(full)` / `task.get` / `task.upsert` /
/// `task.delete` / `task.runNow` / `asset.list` / `preset.list`。
class RemoteTasksTab extends ConsumerStatefulWidget {
  const RemoteTasksTab({super.key, this.channel});

  /// 命令通道注入缝 —— 与 [RemoteConsoleTab.channel] / [RemoteScriptsTab.channel]
  /// 同一形状：传 null 走 `RcEndpointService.instance`（生产默认），
  /// 传入即可在**宿主机单测**里驱动本页，无需 broker 与真机。
  ///
  /// ⚠️ **已知缺口（未闭环）**：`assist_join_screen` 给控制台与指令组都传了
  /// [AssistChannel]，**唯独没有给本页传** —— 因为本页的 `_load()` 建立在
  /// `RemoteStore.paired()`（已配对端点）之上，而协助会话里根本没有配对表。
  /// 要让"协助会话也能管理远端任务"，需要把 `_endpoint` 的来源也抽象出来
  /// （不只是命令通道），属于独立改动，不在本轮范围。
  final RcCommandChannel? channel;

  @override
  ConsumerState<RemoteTasksTab> createState() => _RemoteTasksTabState();
}

class _RemoteTasksTabState extends ConsumerState<RemoteTasksTab> {
  List<PairedEndpoint> _endpoints = const [];
  String _selectedId = '';
  bool _enabled = false;
  bool _loading = false;
  bool _awaiting = false;
  List<Map<String, dynamic>> _tasks = const [];
  Map<String, dynamic> _status = const {};
  StreamSubscription<Map<String, dynamic>>? _evtSub;

  /// 待决回执：cmdId → 结果（`_sendAwait` 用）。
  final _acks = <String, Completer<bool>>{};

  @override
  void initState() {
    super.initState();
    _load();
    _evtSub = (widget.channel?.events ?? RcEndpointService.instance.events)
        .listen(_onEvent);
  }

  @override
  void dispose() {
    unawaited(_evtSub?.cancel());
    for (final c in _acks.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _acks.clear();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (!mounted) return;
    setState(() {
      _endpoints = store.paired();
      _enabled = store.enabled;
      // ⚠️ **必须走共享选择**（BUG-063）。
      //
      // 原先这里是 `_selectedId.isEmpty ? _endpoints.first.deviceId : _selectedId`
      // —— 完全忽略 `store.selectedEndpointId`。而设备列表 / 控制台 / 对讲 /
      // 指令组四处都走 [initialSelectedId]，于是出现**跨页不一致**：
      // 用户在「我的设备」里选中 B 并快速连接，再切到本页，
      // 本页仍指向 **A**，且界面上没有任何提示 —— 启停/编辑/删除会
      // **静默落在错误的设备上**。
      //
      // 这不是"显示不对"，是**操作对象错**：删除会把 A 上的任务删掉。
      _selectedId = initialSelectedId(_endpoints, store.selectedEndpointId);
    });
    if (_selectedId.isNotEmpty) await refresh();
  }

  PairedEndpoint? get _endpoint {
    for (final e in _endpoints) {
      if (e.deviceId == _selectedId) return e;
    }
    return null;
  }

  void _onEvent(Map<String, dynamic> m) {
    if (!mounted) return;
    final type = m['type'] as String? ?? '';
    final payload = rcPayloadOf(m);
    switch (type) {
      case RcEvt.tasks:
        setState(() {
          _tasks = ((payload['tasks'] as List?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          _loading = false;
          _awaiting = false;
        });
      case RcEvt.task:
        // task.get / task.upsert 的单条回执：刷新列表即可（列表才是数据源）。
        setState(() => _awaiting = false);
      case RcEvt.status:
        setState(() {
          _status = payload;
          _awaiting = false;
        });
      case RcEvt.exec:
        final ok = payload['ok'] == true;
        _snack(ok
            ? '✓ 端点已执行「${payload['taskName'] ?? ''}」'
            : '✗ 端点执行失败：${payload['message'] ?? ''}');
        unawaited(refresh());
      case RcEvt.ack:
        final forId = payload['for'] as String? ?? '';
        final pending = forId.isEmpty ? null : _acks.remove(forId);
        final ok = payload['ok'] == true;
        if (pending != null) {
          if (!pending.isCompleted) pending.complete(ok);
        } else {
          // 未被 await 的回执（启停/跳过等即时操作）才弹提示，避免刷屏。
          setState(() => _awaiting = false);
          _snack(ok ? '✓ 端点已执行' : '✗ 端点拒绝或未执行');
        }
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<RemoteStore> _store() async =>
      RemoteStore(await SharedPreferences.getInstance());

  /// 发送命令，不等待回执（启停/跳过这类幂等即时操作）。
  Future<void> _send(String type, Map<String, dynamic> payload) async {
    final ep = _endpoint;
    if (ep == null) return;
    final ch = widget.channel;
    final store = ch == null ? await _store() : null;
    setState(() => _awaiting = true);
    final ok = ch != null
        ? await ch.send(RcMessage.now(type, payload))
        : await RcEndpointService.instance
            .sendTo(ep, RcMessage.now(type, payload), store!);
    if (!mounted) return;
    if (!ok) {
      setState(() => _awaiting = false);
      _snack('端点离线：命令已入队，上线后自动执行');
    }
  }

  /// 发送命令并等待端点回执；超时或离线返回 false。
  ///
  /// 远程写操作（upsert/delete）必须拿到 `rc.ack` 才能告知用户"确实生效"，
  /// 否则离线入队会被误报为成功（docs/14 §2.1）。
  Future<bool> _sendAwait(String type, Map<String, dynamic> payload,
      {Duration timeout = const Duration(seconds: 8)}) async {
    final ep = _endpoint;
    if (ep == null) return false;
    final ch = widget.channel;
    final store = ch == null ? await _store() : null;
    final msg = RcMessage.now(type, payload);
    final completer = Completer<bool>();
    _acks[msg.id] = completer;
    final published = ch != null
        ? await ch.send(msg)
        : await RcEndpointService.instance.sendTo(ep, msg, store!);
    if (!published) {
      _acks.remove(msg.id);
      return false;
    }
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _acks.remove(msg.id);
      return false;
    }
  }

  /// 拉取端点任务全貌（**完整定义** + 待执行统计）。
  Future<void> refresh() async {
    if (_selectedId.isEmpty) return;
    setState(() => _loading = true);
    await _send(RcCmd.taskList, const {'full': true});
    await _send(RcCmd.statusGet, const {});
    // 兜底：2 秒后解除 loading（端点离线时不会回执）
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted && _loading) setState(() => _loading = false);
  }

  // ---------------- 写操作 ----------------

  /// 新建 / 编辑：直接复用本机任务编辑器（远程目标模式）。
  Future<void> _openEditor({Map<String, dynamic>? wire}) async {
    final ep = _endpoint;
    if (ep == null) return;
    final initial = wire == null ? null : TaskWire.fromWire(wire);
    if (wire != null && initial == null) {
      _snack('端点返回的任务定义无法解析（协议版本可能不一致）');
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TaskEditorScreen(
          initialTask: initial,
          remoteTarget: RemoteTaskTarget(
            endpointName: ep.name,
            save: (task) async {
              // 复用同一份线格式编码：端点侧用 TaskWire.fromWire 反向校验。
              final ok = await _sendAwait(
                  RcCmd.taskUpsert, {'task': TaskWire.toWire(task)},
                  timeout: const Duration(seconds: 10));
              return ok;
            },
          ),
        ),
      ),
    );
    if (saved == true) {
      await refresh();
      _snack('已写入端点');
    }
  }

  Future<void> _delete(Map<String, dynamic> t) async {
    final id = t['id'] as String? ?? '';
    if (id.isEmpty) return;
    final name = t['name'] as String? ?? '该任务';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除端点任务'),
        content: Text('将在端点设备上删除「$name」及其全部计划与审计记录。\n'
            '此操作不可撤销，且端点用户不可见——请确认已获授权。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await _sendAwait(RcCmd.taskDelete, {'taskId': id});
    if (!mounted) return;
    _snack(done ? '已在端点删除「$name」' : '端点未确认（离线或任务不存在）');
    if (done) await refresh();
  }

  Future<void> _runNow(Map<String, dynamic> t) async {
    final id = t['id'] as String? ?? '';
    if (id.isEmpty) return;
    final name = t['name'] as String? ?? '该任务';
    final done = await _sendAwait(RcCmd.taskRunNow, {'taskId': id},
        timeout: const Duration(seconds: 50));
    if (!mounted) return;
    if (!done) _snack('端点未执行「$name」（离线、引擎未运行或动作失败）');
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    if (_endpoints.isEmpty) return _noEndpoint();
    if (!_enabled) return _disabled();

    final pending = _status['pendingCount'];
    return Scaffold(
      // 子页内嵌于「远程」分组，避免与外层 Scaffold 叠加出双层 AppBar。
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('新建端点任务'),
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            _endpointSelector(),
            const SizedBox(height: 10),
            _summaryCard(pending),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('端点任务（${_tasks.length}）',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_loading || _awaiting)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新',
                    onPressed: refresh,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (_tasks.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('端点暂无自动化任务。\n'
                      '点右下角「新建端点任务」即可在端点设备上创建 —— '
                      '与本机任务使用同一个编辑器。'),
                ),
              )
            else
              for (final t in _tasks) _taskTile(t),
            const SizedBox(height: 12),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '说明：远程任务与端点本地任务共用同一份调度数据；'
                  '新建/编辑会立即在端点重新物化计划，启停与跳过即时生效，'
                  '全部操作写入端点审计日志（source=remote）。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskTile(Map<String, dynamic> t) {
    final enabled = t['enabled'] == true;
    final id = t['id'] as String? ?? '';
    final assets = (t['assetIds'] as List?)?.length ?? 0;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        leading: Icon(
          enabled ? Icons.play_circle_outline : Icons.pause_circle_outline,
          color: enabled
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).disabledColor,
        ),
        title: Text(t['name'] as String? ?? '（未命名）',
            style: const TextStyle(fontSize: 14)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(_triggerDetail(t), style: const TextStyle(fontSize: 12)),
            Text(
              '${_actionDetail(t)}'
              '${assets > 0 ? ' · 音源池 $assets 条' : ''}'
              ' · 冷却 ${_cooldown(t)}',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (enabled)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_next_outlined),
                tooltip: '跳过下一次',
                onPressed: id.isEmpty
                    ? null
                    : () => _send(RcCmd.taskSkipNext, {'taskId': id}),
              ),
            Switch(
              value: enabled,
              onChanged: id.isEmpty
                  ? null
                  : (v) =>
                      _send(RcCmd.taskToggle, {'taskId': id, 'enabled': v}),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (v) => switch (v) {
                'run' => unawaited(_runNow(t)),
                'edit' => unawaited(_openEditor(wire: t)),
                'delete' => unawaited(_delete(t)),
                _ => null,
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'run',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.play_arrow),
                    title: Text('立即执行'),
                  ),
                ),
                PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.edit_outlined),
                    title: Text('编辑'),
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(Object? pending) {
    final ep = _endpoint;
    final online = _status.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: online
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              child: Icon(online ? Icons.phone_android : Icons.phonelink_off,
                  color: online
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ep?.name ?? '端点',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    online
                        ? '待执行 ${pending ?? '—'} 条 · 版本 ${_status['version'] ?? '?'}'
                        : '等待端点响应…',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _endpointSelector() => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: DropdownButtonFormField<String>(
            initialValue: _selectedId.isEmpty ? null : _selectedId,
            decoration: const InputDecoration(
                labelText: '目标端点', border: InputBorder.none),
            items: [
              for (final e in _endpoints)
                DropdownMenuItem(value: e.deviceId, child: Text(e.name)),
            ],
            onChanged: (v) {
              setState(() {
                _selectedId = v ?? '';
                _tasks = const [];
                _status = const {};
              });
              refresh();
            },
          ),
        ),
      );

  Widget _noEndpoint() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phonelink_off,
                  size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              const Text('尚未配对端点设备'),
              const SizedBox(height: 8),
              const Text('先完成配对，才能查看并操作对端任务。', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('去配对'),
                onPressed: () => context.push('/remote/pair-qr'),
              ),
            ],
          ),
        ),
      );

  Widget _disabled() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_tethering_off,
                  size: 64, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              const Text('远程模块未开启'),
              const SizedBox(height: 8),
              const Text('端点服务未运行：收不到命令，也收不到对端回执。',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.push('/remote/settings'),
                child: const Text('去开启'),
              ),
            ],
          ),
        ),
      );

  // ---------------- 摘要渲染 ----------------

  static String _triggerDetail(Map<String, dynamic> t) {
    final tr = t['trigger'];
    final base = _triggerLabel(t['triggerType']);
    if (tr is! Map) return base;
    final m = tr.cast<String, dynamic>();
    switch (t['triggerType']) {
      case 'fixedOnce':
        return '固定一次 · ${_fmtIso(m['at'])}';
      case 'dailyAt':
        return '每天 ${_hhmm(m['time'])}';
      case 'weeklyAt':
        final wd = ((m['weekdays'] as List?) ?? const [])
            .whereType<num>()
            .map((e) => e.toInt())
            .toList()
          ..sort();
        final days = wd.isEmpty ? '—' : wd.map(_weekdayName).join('/');
        return '每周 $days ${_hhmm(m['time'])}';
      case 'randomWindow':
        return '随机窗口 ${_hhmm(m['windowStart'])}–${_hhmm(m['windowEnd'])}'
            ' · 每天 ${m['timesPerDay'] ?? '?'} 次';
      case 'randomInterval':
        return '随机间隔 ${_gap(m['minGapSec'])}–${_gap(m['maxGapSec'])}'
            ' · 每天≤${m['maxPerDay'] ?? '?'} 次';
      case 'soundTriggered':
        return '声音触发 · ≥${m['thresholdDb'] ?? '?'} dB';
    }
    return base;
  }

  static String _actionDetail(Map<String, dynamic> t) {
    final a = t['action'];
    final base = _actionLabel(t['actionType']);
    if (a is! Map) return base;
    final m = a.cast<String, dynamic>();
    switch (m['kind']) {
      case 'play':
        return '$base · 音量 ${_pct(m['volumeMin'])}–${_pct(m['volumeMax'])}'
            ' · ${m['durationSecMin'] ?? '?'}–${m['durationSecMax'] ?? '?'}s';
      case 'tts':
        return '$base · ${m['text'] ?? ''}';
      case 'notify':
        return '$base · ${m['title'] ?? ''}';
      case 'record':
        return '$base · ${m['seconds'] ?? '?'}s';
      case 'soundscape':
        return '$base · ${((m['tracks'] as List?) ?? const []).length} 轨'
            ' · ${m['durationSec'] ?? '?'}s';
      case 'composite':
        final p = (m['primary'] as Map?)?.cast<String, dynamic>();
        return '$base · 通知 + ${_actionLabel(_kindToType(p?['kind']))}';
      // v1.9 振动族：把关键可调项摊在摘要里（远程与本机功能对齐 ——
      // 控制端看到的必须是"这任务会怎么震"，而不是一句"随机振动"）。
      case 'randomVibrate':
        return '$base · 强度 ${_pct(m['amplitudeMin'])}–${_pct(m['amplitudeMax'])}'
            ' · ${m['durationSecMin'] ?? '?'}–${m['durationSecMax'] ?? '?'}s'
            ' · ≤${m['maxPulses'] ?? '?'} 脉冲';
      case 'continuousVibrate':
        return '$base · 强度 ${_pct(m['amplitudeMin'])}–${_pct(m['amplitudeMax'])}'
            ' · ${m['durationSecMin'] ?? '?'}–${m['durationSecMax'] ?? '?'}s'
            '${(m['jitterMs'] as num?) != null && (m['jitterMs'] as num) > 0 ? ' · 波动 ${m['jitterMs']}ms' : ''}';
      case 'vibrate':
        return '$base · ${((m['patternMs'] as List?) ?? const []).length} 步';
    }
    return base;
  }

  static String _cooldown(Map<String, dynamic> t) {
    final s = (t['cooldownSec'] as num?)?.toInt() ?? 0;
    if (s <= 0) return '无';
    if (s % 3600 == 0) return '${s ~/ 3600}h';
    if (s % 60 == 0) return '${s ~/ 60}min';
    return '${s}s';
  }

  static String _hhmm(Object? spec) {
    if (spec is! Map) return '--:--';
    final h = (spec['hour'] as num?)?.toInt();
    final mi = (spec['minute'] as num?)?.toInt() ?? 0;
    if (h == null) return '--:--';
    return '${h.toString().padLeft(2, '0')}:${mi.toString().padLeft(2, '0')}';
  }

  static String _gap(Object? sec) {
    final s = (sec as num?)?.toInt() ?? 0;
    return s >= 3600 ? '${(s / 3600).toStringAsFixed(1)}h' : '${s ~/ 60}min';
  }

  static String _pct(Object? v) =>
      '${(((v as num?)?.toDouble() ?? 0) * 100).round()}%';

  static String _fmtIso(Object? iso) {
    if (iso is! String) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  static String _weekdayName(int d) =>
      const ['一', '二', '三', '四', '五', '六', '日'][(d - 1).clamp(0, 6)];

  /// 动作 kind → 展示用的 type 名。
  ///
  /// ⚠️ 必须覆盖 [ActionConfig.fromJson] 认识的**全部** kind（由
  /// `test/remote_label_perm_coverage_test.dart` LBL-01 强制）。
  /// 漏一个的后果（本轮实测）：组合动作的主动作是"随机指令集/嵌套组合"时，
  /// 摘要显示成「通知 + 」（**空标签**），用户看不出这任务到底要干什么。
  static String _kindToType(Object? kind) => switch (kind) {
        'play' => 'playAudio',
        'soundscape' => 'soundscape',
        'tts' => 'tts',
        'notify' => 'notify',
        'record' => 'recordEvidence',
        'vibrate' => 'vibrate',
        // v1.9：随机/持续振动（docs/20 §4）。漏登记的后果与 composite 那次一样 ——
        // 摘要里出现空标签（LBL-01 会红）。
        'randomVibrate' => 'randomVibrate',
        'continuousVibrate' => 'continuousVibrate',
        'composite' => 'composite',
        'randomFrom' => 'randomFrom',
        _ => '',
      };

  static String _triggerLabel(Object? raw) => switch (raw) {
        'fixedOnce' => '固定一次',
        'dailyAt' => '每天定时',
        'weeklyAt' => '每周定时',
        'randomWindow' => '随机窗口',
        'randomInterval' => '随机间隔',
        'soundTriggered' => '声音触发',
        // ⚠️ 空串也要给得出名字：`''` 不是 null，`'${raw ?? …}'` 会渲染成空白。
        _ => (raw == null || '$raw'.isEmpty) ? '未知触发' : '$raw',
      };

  static String _actionLabel(Object? raw) => switch (raw) {
        'playAudio' => '播放音频',
        'soundscape' => '声景混音',
        'tts' => '语音喊话',
        'notify' => '发送通知',
        'recordEvidence' => '录音取证',
        // 与 `ActionType.label` 保持一致（v1.9 起 `vibrate` 明确为"固定节奏"）。
        'vibrate' => '震动（固定节奏）',
        'randomVibrate' => '随机振动',
        'continuousVibrate' => '持续振动',
        'composite' => '组合动作',
        'randomFrom' => '随机指令集',
        _ => (raw == null || '$raw'.isEmpty) ? '未知动作' : '$raw',
      };
}
