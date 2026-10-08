import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/command_channel.dart';
import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';
import '../../remote/script_progress.dart';
import '../../core/theme.dart';

/// 指令组 Tab（v1.6）：收藏模板列表（一键发往选中端点/编辑/删除）
/// + 新建组装器入口。数据来自 RemoteStore.savedScripts。
///
/// v1.8（第十七轮续五）：**消费 `RcEvt.scriptState`** —— 端点每进入一个步骤都会
/// 广播 `rc.script`，本页据此显示执行进度。此前该事件只有桌面 E2E 工具消费，
/// 主叫侧发完就只能去端点看通知栏（协议三向覆盖里的最后一个 App 内缺口）。
///
/// v1.8（第十七轮续八）：**发送改走 [RcCommandChannel]** —— 与远程控制台共用
/// **同一条命令路径**。本页原本直接 `RcEndpointService.instance.sendTo(ep, …)`，
/// 只能驱动"已配对端点"；而协助会话的对端**没有配对关系**（密钥按临时码派生、
/// 主题是会合主题），于是"协助会话里跑不了指令组"。
/// 传入 `AssistChannel` 后即可在协助会话中执行已收藏的模板。
class RemoteScriptsTab extends ConsumerStatefulWidget {
  const RemoteScriptsTab({super.key, this.channel, this.events});

  /// 命令通道。传 `AssistChannel` 即可在**协助会话**里执行指令组。
  ///
  /// 为什么不把"发命令"复制一份到协助页：协议约定**控制台只有一条命令路径**，
  /// 复制会让新增命令只加一边（必然漂移）。
  final RcCommandChannel? channel;

  /// 端点事件流；默认取通道事件流，其次 `RcEndpointService.instance.events`。
  ///
  /// 留出注入点是为了让部件测试能直接回灌 `rc.script` ——
  /// 否则"用户真的能在界面上看到进度"这件事只能靠读代码来断言。
  final Stream<Map<String, dynamic>>? events;

  @override
  ConsumerState<RemoteScriptsTab> createState() => _RemoteScriptsTabState();
}

class _RemoteScriptsTabState extends ConsumerState<RemoteScriptsTab> {
  List<PairedEndpoint> _endpoints = const [];
  String _selectedId = '';
  List<SavedScript> _saved = const [];

  /// scriptId → 最新进度（消费 `RcEvt.scriptState`）。
  final _progress = <String, ScriptProgress>{};

  /// scriptId → **未执行**的步骤说明（R-4②：`state:done` 随带 `skipped`）。
  ///
  /// 为什么必须单独存：`state:done` 只说明"跑完了"，不说明"每一步都做了"。
  /// 端点跳过 3 步与全部做完，在控制端**看起来完全一样** —— 这正是
  /// "成功被误报"的同一形状（端点在 `_runScript` 里把权限拒绝 / 无处理器 /
  /// 无音源等步骤累积进 `skipped`）。
  final _skipped = <String, List<String>>{};

  StreamSubscription<Map<String, dynamic>>? _evtSub;
  StreamSubscription<void>? _updSub;

  /// scriptRun 已发出但端点 8 秒内无 ack 也无进度的兜底（与配对回执同超时）。
  /// 收到 ack / scriptState 即取消；触发则明确告知"发出 ≠ 被执行"。
  Timer? _runWatchdog;

  RcCommandChannel? get _ch => widget.channel;

  /// 事件来源优先级：**注入（测试）> 通道 > 端点服务**。
  ///
  /// 与远程控制台同构 —— 协助会话的回执由通道（会合主题）给出，
  /// 若这里仍取 `RcEndpointService.events`，协助会话下进度永远不出现。
  Stream<Map<String, dynamic>> get _events =>
      widget.events ?? _ch?.events ?? RcEndpointService.instance.events;

  @override
  void initState() {
    super.initState();
    _load();
    _evtSub = _events.listen(_onEvent);
    // 协助会话里端点可随时放行/收回权限 → 通道可用性会变；
    // 不订阅就只在收到业务事件时才重建，横幅/按钮会停在旧值（与远程控制台同源）。
    _updSub = _ch?.updates.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _runWatchdog?.cancel();
    unawaited(_evtSub?.cancel());
    unawaited(_updSub?.cancel());
    super.dispose();
  }

  /// 端点侧指令组进度（`rc.script`）与**被拒回执**（`rc.ack`）。
  ///
  /// 未知状态一律不猜：`shouldApplyProgress` 为假时**什么都不做**，
  /// 进度保持上一次的已知状态（BUG-050 判据）。
  void _onEvent(Map<String, dynamic> m) {
    if (!mounted) return;
    final type = m['type'] as String? ?? '';
    final payload = rcPayloadOf(m);

    // ---- R-5 同类（同一缺陷，本页同样中招）----
    //
    // `rc.script` 是端点**广播**的事件（`_send` 不带 targetPeerId），控制器侧
    // 由 `_handlePeerEvent` 附上 `peerId`。多端点场景下，另一台端点正在跑的
    // 指令组进度会混进本页 —— 列表副标题会张冠李戴（A 的模板显示 B 的进度）。
    // 协助会话的事件不带 `peerId` ⇒ 天然放行。
    final pid = m['peerId'] as String? ?? '';
    if (pid.isNotEmpty && pid != _selectedId) return;

    // ---- R-4①：端点校验失败会回 `rc.ack{forType:'script.run', ok:false}` ----
    //
    // 此前本页**只**处理 `rc.script`，这条 ack 没有任何消费者 ⇒ 用户点完
    // 「执行」看到的是"已发送，进度见下方"，而端点**压根没开始跑**
    // （例如"已有指令组在执行"）—— 典型的静默失败：发出去 ≠ 被执行。
    if (type == RcEvt.ack) {
      if (payload['forType'] == RcCmd.scriptRun) {
        // 端点已回应 → 兜底计时器完成使命。
        _runWatchdog?.cancel();
        if (payload['ok'] == false) {
          final why = payload['data']?.toString() ?? '';
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content:
                  Text('端点未执行指令组：${why.isEmpty ? '被端点拒绝' : why}')));
        }
      }
      return;
    }

    if (type != RcEvt.scriptState) return;
    _runWatchdog?.cancel();
    final p = parseScriptProgress(payload);
    if (!shouldApplyProgress(p)) return;
    // ---- R-4②：终态恒带 `skipped`（未执行步骤说明）----
    // 终态有两个（done / stopped），端点**两者都会**带上 `skipped`，
    // 因此这里按 `isTerminal` 处理 —— 只认 done 会让"被终止时跳过的那几步"
    // 无声消失，与"成功被误报"是同一形状。
    if (p.isTerminal) {
      final sk = (payload['skipped'] as List?)
              ?.whereType<String>()
              .toList() ??
          const <String>[];
      if (sk.isEmpty) {
        _skipped.remove(p.scriptId);
      } else {
        _skipped[p.scriptId] = sk;
        // 必须**主动**说出来：进度卡在终止态后就不再显示（`_active` 为 null），
        // 只靠列表副标题的话，"模板已不在本机"的场景就完全看不到。
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('指令组'
                '${p.state == ScriptState.done ? '跑完' : '被终止'}，'
                '其中 ${sk.length} 步未执行：${sk.join('；')}')));
      }
    }
    setState(() => _progress[p.scriptId] = p);
  }

  /// 仍在执行的指令组 —— 进度卡只在"有在跑"时出现。
  ScriptProgress? get _active {
    for (final p in _progress.values) {
      if (!p.isTerminal) return p;
    }
    return null;
  }

  /// 与当前进度对应的收藏模板（用于取名字与总步数）。
  SavedScript? get _activeScript {
    final a = _active;
    if (a == null) return null;
    for (final s in _saved) {
      if (s.payload['scriptId'] == a.scriptId) return s;
    }
    return null;
  }

  /// 某条收藏模板的进度文案；从未跑过则返回 null。
  ///
  /// R-4②：终态若带 `skipped`，把"其中 N 步未执行 + 原因"接在后面 ——
  /// 否则「跑完了」与「跑完了但 3 步没做」在界面上完全无法区分。
  String? _progressText(SavedScript s) {
    final id = s.payload['scriptId'];
    final p = _progress[id];
    if (p == null) return null;
    final base = describeScriptProgress(p,
        totalSteps: (s.payload['steps'] as List?)?.length);
    final sk = _skipped[id];
    if (!p.isTerminal || sk == null || sk.isEmpty) return base;
    return '$base · 其中 ${sk.length} 步未执行：${sk.join('；')}';
  }

  /// 列表项的副标题：基础信息 + （若有）执行进度。
  String _subtitleFor(SavedScript s) {
    final base = '已收藏 · ${s.payload['fromName'] ?? ''}';
    final p = _progressText(s);
    return p == null ? base : '$base · $p';
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (!mounted) return;
    setState(() {
      _endpoints = store.paired();
      _saved = store.savedScripts();
      // 与「我的设备」共享同一份选择（快速连接的落点）。
      _selectedId = initialSelectedId(_endpoints, store.selectedEndpointId);
    });
  }

  Future<void> _send(SavedScript s) async {
    final ch = _ch;
    if (ch == null && _selectedId.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择目标端点')));
      return;
    }
    if (ch != null && !ch.canSend) {
      // 与远程控制台同判据：会话未激活就**不发**，并把原因说出来 ——
      // 静默拦截会让使用者以为"功能坏了"（BUG-029 的同类）。
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('协助会话未激活，无法发送')));
      return;
    }
    final msg = RcMessage.now(RcCmd.scriptRun, s.payload);
    final bool ok;
    if (ch != null) {
      ok = await ch.send(msg);
    } else {
      final prefs = await SharedPreferences.getInstance();
      final store = RemoteStore(prefs);
      final ep = endpointById(_endpoints, _selectedId);
      if (ep == null) {
        // 端点在别处被解配对 —— 明确告知，不要崩（BUG-060）。
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('端点已不存在（可能已解配对），请重新选择')));
        }
        return;
      }
      ok = await RcEndpointService.instance.sendTo(ep, msg, store);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok
              ? '「${s.name}」已发送，进度见下方（端点通知栏可终止）'
              : (ch != null ? '协助会话未激活：未发送' : '端点离线：已入队，上线后自动补发'))));
    }
    // 已发出 ≠ 已被执行：8 秒内没有 ack 也没有进度，就把这个事实说出来
    //（此前 UI 停在"进度见下方"，端点若从未回应就永远是"点了没反应"）。
    // 入队场景（ok == false）不计时 —— 那条路有自己的补发提示。
    if (ok) {
      _runWatchdog?.cancel();
      _runWatchdog = Timer(const Duration(seconds: 8), () {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '「${s.name}」发出 8 秒未收到端点回应（未确认也未开始执行），'
                '请检查端点是否在线')));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ch = _ch;
    final active = _active;
    final activeScript = _activeScript;
    return Scaffold(
      // 协助会话下没有"已配对端点 id"，组装器路由（`/remote/script-builder/<id>`）
      // 无法定位目标 → 不显示入口，改由顶部说明卡把边界讲清楚
      // （比留一个"点了就报错"的按钮好）。
      floatingActionButton: ch != null
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('新建指令组'),
              onPressed: () async {
                if (_selectedId.isEmpty) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('请先完成端点配对')));
                  return;
                }
                await context.push('/remote/script-builder/$_selectedId');
                await _load();
              },
            ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (ch != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.handshake_outlined),
                title: Text(ch.label),
                subtitle: const Text('协助会话：可直接执行下方已收藏的指令组；'
                    '组装新指令组需要已配对端点。'),
              ),
            ),
          if (ch == null && _endpoints.isNotEmpty)
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedId.isEmpty ? null : _selectedId,
                  decoration: const InputDecoration(
                      labelText: '发送目标端点', border: InputBorder.none),
                  items: [
                    for (final e in _endpoints)
                      DropdownMenuItem(value: e.deviceId, child: Text(e.name)),
                  ],
                  onChanged: (v) async {
                    setState(() => _selectedId = v ?? '');
                    final prefs = await SharedPreferences.getInstance();
                    await RemoteStore(prefs).setSelectedEndpoint(v ?? '');
                  },
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (active != null) ...[
            Card(
              child: ListTile(
                leading: const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: Text(activeScript?.name ?? '远程指令组'),
                subtitle: Text(describeScriptProgress(active,
                    totalSteps:
                        (activeScript?.payload['steps'] as List?)?.length)),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_saved.isEmpty)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text(ch == null
                        ? '暂无收藏的指令组。点击右下角「新建指令组」组装动作与时延序列，'
                            '发送前可勾选「存为模板」。'
                        : '暂无收藏的指令组。协助会话下只能执行**已收藏**的模板；'
                            '请先在已配对端点侧组装并勾选「存为模板」。'))),
          for (final s in _saved)
            Card(
              child: ListTile(
                leading: const Icon(Icons.bolt),
                title: Text(s.name),
                subtitle: Text(_subtitleFor(s)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.tonal(
                        onPressed: () => _send(s), child: const Text('执行')),
                    IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          try {
                            final prefs =
                                await SharedPreferences.getInstance();
                            await RemoteStore(prefs).deleteScript(s.id);
                            await _load();
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已删除')));
                          } on Object catch (e) {
                            // 删除失败不能无声无息 —— 列表还在会让人以为没点上。
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('删除失败：$e')));
                          }
                        }),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text(
                '指令组 = 动作 + 时延的有序序列（最多 50 步）。端点收到后立即执行，'
                '执行进度会实时回传本页（端点每进入一步广播一次），'
                '端点通知栏全程显示发送方与进度，可随时终止；全程审计留痕。',
                style: AppText.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
