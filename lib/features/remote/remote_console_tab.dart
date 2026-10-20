import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/assist.dart';
import '../../remote/command_channel.dart';
import '../../remote/controller_service.dart';
import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/rc_script.dart';
import '../../remote/remote_store.dart';
import '../../core/theme.dart';
import '../../domain/scheduling/run_pause.dart';
import 'screen_viewer.dart';

/// 远程控制台（v1.6）：对已配对端点的完全控制——
/// ping/状态快照/任务查看与开关/音效播放/守卫开关/音量调节/拍照/定位。
/// 每个命令的响应经 [RcEndpointService.events] 流实时渲染。
///
/// v1.7：改为面向 [RcCommandChannel] —— 传入 [channel] 即可驱动**协助会话**
/// 端点（S3），不传则维持原有的"已配对端点"行为。两种目标共用同一套命令面板，
/// 避免出现第二份会漂移的实现。
class RemoteConsoleTab extends ConsumerStatefulWidget {
  const RemoteConsoleTab({super.key, this.channel});

  /// 命令通道；null = 使用已配对端点（默认行为）。
  final RcCommandChannel? channel;

  @override
  ConsumerState<RemoteConsoleTab> createState() => _RemoteConsoleTabState();
}

class _RemoteConsoleTabState extends ConsumerState<RemoteConsoleTab> {
  List<PairedEndpoint> _endpoints = const [];
  String _selectedId = '';
  bool _enabled = false;
  Map<String, dynamic>? _lastStatus;
  Map<String, dynamic>? _lastDevice;
  Map<String, dynamic>? _lastPingAt;
  Map<String, dynamic>? _lastLocation;
  List<dynamic>? _lastLogs;
  String? _photoB64;

  /// 端点音源库（`asset.list` → `rc.assets`）。
  ///
  /// BUG-048 配套：端点早已实现 `asset.list` / `preset.list`，但控制台
  /// **既无入口也无消费方**（HANDOVER §6.12 的 P2 项）—— 于是远程播放只能
  /// 按固定分类"盲播"。有了列表才能点选**指定音源**（`sound.play {assetId}`）。
  List<dynamic>? _lastAssets;
  int _assetsTotal = 0;

  /// 音量面板（Y1）：滑杆当前值（0–100）。
  double _volumePct = 80;

  /// 音量持久化键前缀（SharedPreferences 直用，键 `rc:volume:<deviceId>`）。
  ///
  /// 为什么不走 [RemoteStore]：它是本轮的**只读**文件且没有通用 KV 能力
  /// （每个键都是具名常量 + 专用 getter），为加一个音量值去动配对/信封
  /// 逻辑得不偿失。SharedPreferences 与 RemoteStore 底层是同一份实例，
  /// 读写一致性没有问题。
  static const _volumeKeyPrefix = 'rc:volume:';

  /// 已发出、等待回执的音量命令：cmdId → (存储键, 百分比)。
  ///
  /// 为什么不是"发送即记忆"：端点可能拒绝（iOS 恒失败 / 协助会话端点侧
  /// 拒绝）。把被拒的值记成"最后成功设置"就是**假成功** —— 只有回执
  /// `ok == true` 才落盘。协助会话的事件不带 peerId，故存储键在**发送时**
  /// 就随命令记下，避免回执时错记到别的端点名下。
  final _volumeInFlight = <String, ({String key, int pct})>{};

  /// 端点预置分类（`preset.list` → `rc.presets`）。
  List<dynamic>? _lastPresets;

  /// 已知离线的对端（peerId → 显示名）。
  ///
  /// 来源：broker 代发的 **LWT 明文离线哨兵** `rc.offline`（docs/14 §4）。
  /// 端点服务（控制器侧）已识别该哨兵、并附上 `peerId`/`peerName` 转发到事件流，
  /// 但此前**没有任何 UI 消费它** —— 使用者在端点离线时毫无提示，
  /// 只有点下命令之后才会从"端点离线：已入队"的提示里**间接**得知（BUG-039）。
  /// 恢复信号：该对端的**任何其它事件**（心跳每 60s 一次，是最慢的一种）。
  final _offlinePeers = <String, String>{};

  /// 已发出、**等待响应**的命令：cmdId → 期望（R-3）。
  ///
  /// 为什么不只用 `Map<String, String>`（cmdId → 描述）：
  /// 1. 需要知道**在等什么** —— 一半命令的响应是专用事件（`rc.status` /
  ///    `rc.location` …）而不是 `rc.ack`，只有记下期望类型，收到事件时才清得掉；
  /// 2. 需要知道**等了多久** —— 否则超时无法判定（旧实现只写不删：端点离线时
  ///    永远等不到 `rc.ack`，条目随点击次数无界增长，是真实的内存泄漏）。
  final _pendingAcks = <String, _PendingAck>{};

  /// 超时扫描器：每 1s 检查一次有没有超过 [_ackTimeoutSec] 还没回响的命令。
  Timer? _ackWatch;

  /// 未响应判定的门槛（秒）。超过即提示并清除条目。
  static const _ackTimeoutSec = 8;

  StreamSubscription<Map<String, dynamic>>? _evtSub;
  StreamSubscription<void>? _updSub;

  /// 远程动作回执行（FR-79，第八十四轮用户明文）。
  ///
  /// 用户要求：「在『目标端点和设备快照』与『动作』两个模块中间新增两行高的
  /// 命令行组件，显示为一个**两行高的文本框**，里面显示**所有远程动作的回执**，
  /// 超过两行时自动换行，**同时去除原来的各动作的反馈信息显示点**」。
  ///
  /// 故原「逐动作 SnackBar（✓/✗ desc）」全部改为**追加进本列表**，
  /// 由 [_ReceiptConsole] 统一渲染（固定两行高、自动换行、可滚动看全部）。
  /// 保留上限 [_kReceiptMax] 防无界增长（旧的 SnackBar 一闪即走，无此问题）。
  final List<String> _receipts = <String>[];

  /// 回执行保留条数上限（超出丢最旧的；避免长时间使用后无界增长）。
  static const int _kReceiptMax = 200;

  /// 追加一条回执（FR-79）。
  ///
  /// 不弹 SnackBar —— 用户要的是「积在一处、可回看」，而不是「一闪而过」。
  void _pushReceipt(String line) {
    if (!mounted) return;
    setState(() {
      _receipts.add(line);
      if (_receipts.length > _kReceiptMax) {
        _receipts.removeRange(0, _receipts.length - _kReceiptMax);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
    final channel = widget.channel;
    _evtSub =
        (channel?.events ?? RcEndpointService.instance.events).listen(_onEvent);
    // 权限/可用性变更 → 重建，刷新按钮灰化与横幅摘要。
    // 协助会话里端点可随时放行或收回权限，若不订阅就只在收到业务回执时才
    // 重建，灰化状态会停留在旧值（BUG-030）。
    _updSub = channel?.updates.listen((_) {
      if (mounted) setState(() {});
    });
    // R-3：命令发出去之后**必须有人负责判定"它到底回没回"**。
    // 这些响应事件永不重发、也无超时 —— 端点离线 / 配对码不一致 / 引擎卡住时，
    // 用户点了按钮界面毫无变化（无 loading、无错误、无提示），是纯粹的静默失败。
    _ackWatch = Timer.periodic(const Duration(seconds: 1), (_) => _expirePending());
  }

  @override
  void dispose() {
    _ackWatch?.cancel();
    unawaited(_evtSub?.cancel());
    unawaited(_updSub?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (!mounted) return;
    setState(() {
      _endpoints = store.paired();
      _enabled = store.enabled;
      // 与「我的设备」共享同一份选择：在那里点过"连接"，这里就应是同一台。
      _selectedId = initialSelectedId(_endpoints, store.selectedEndpointId);
    });
    // 音量滑杆回填：进页面即恢复该端点最后一次成功设置的值（Y1）。
    await _restoreVolume();
  }

  PairedEndpoint? get _endpoint {
    final id = _selectedId;
    if (id.isEmpty) return null;
    for (final e in _endpoints) {
      if (e.deviceId == id) return e;
    }
    return null;
  }

  /// 当前选中的端点是否**已知离线**。
  ///
  /// 协助会话的事件不带 `peerId`，且其存活由会话 TTL 与 close 信令表达，
  /// 因此这里对协助通道恒为 false（不会误报）。
  bool get _targetOffline =>
      _selectedId.isNotEmpty && _offlinePeers.containsKey(_selectedId);

  Future<RemoteStore> _store() async =>
      RemoteStore(await SharedPreferences.getInstance());

  // ---------------- 音量面板（Y1） ----------------

  /// 音量持久化的存储键：按端点各记一份。
  /// 协助会话没有配对 deviceId，统一落在 `assist` 键下。
  String _volumeStoreKey() =>
      '$_volumeKeyPrefix${_selectedId.isEmpty ? 'assist' : _selectedId}';

  /// 进页面/换端点时回填滑杆：读该端点最后一次**成功**设置的音量
  /// （没记录时回落 80%，与旧写死按钮的值一致）。
  Future<void> _restoreVolume() async {
    final key = _volumeStoreKey();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      final v = prefs.getInt(key) ?? 80;
      _volumePct = v.clamp(0, 100).toDouble();
    });
  }

  /// 发送音量命令（松手 / 点档位时调用；拖动过程不发，防刷屏）。
  ///
  /// 发出后把 (存储键, 百分比) 挂进 [_volumeInFlight]，回执 `ok == true`
  /// 才落盘（见该字段说明）。
  Future<void> _sendVolume(int pct) async {
    final cmdId = await _send(RcCmd.volumeSet, volumePayloadForPercent(pct),
        volumeLabelForPercent(pct));
    if (cmdId == null || !mounted) return;
    _volumeInFlight[cmdId] = (key: _volumeStoreKey(), pct: pct);
  }

  /// 回执成功 → 记「该端点最后一次成功设置的音量」。
  Future<void> _rememberVolume(String key, int pct) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, pct);
  }

  void _onEvent(Map<String, dynamic> m) {
    if (!mounted) return;
    final type = m['type'] as String? ?? '';
    // 端点在线状态：`rc.offline` 是 broker 代发的 LWT 明文哨兵；
    // 其余任何来自同一 peerId 的事件都说明它活着（心跳是最慢的恢复信号）。
    // 协助会话的事件不带 peerId，故不会误判。
    final peerId = m['peerId'] as String? ?? '';
    if (peerId.isNotEmpty) {
      setState(() {
        if (type == RcEvt.offline) {
          _offlinePeers[peerId] = m['peerName'] as String? ?? peerId;
        } else {
          _offlinePeers.remove(peerId);
        }
      });
    }
    // 端点回执的业务字段全部在 payload 内（BUG-023：此前读顶层字段恒为 null，
    // 导致状态/设备/定位/回执面板永远显示空值）。
    final payload = rcPayloadOf(m);

    // ---- R-5：业务事件必须按 `peerId` 过滤 ----
    //
    // 多端点场景下，**另一台**端点的 `rc.status` / `rc.location` / `rc.assets`
    // 会直接覆盖本页状态 —— 用户看着 A 的名字，看到的却是 B 的数据，
    // 甚至可能在错误的对象上做操作。协助会话的事件不带 `peerId` ⇒ 天然放行。
    //
    // ⚠️ 放在上面的"在线状态记账"**之后**：离线哨兵是**按 peerId 记账**的，
    // 在这里把它丢掉会让"切到那台设备时看不到离线提示"（静默降级）。
    if (peerId.isNotEmpty && peerId != _selectedId) return;

    switch (type) {
      case RcEvt.pong:
        final at = (payload['at'] as num?)?.toInt() ?? 0;
        setState(() => _lastPingAt = {
              'at': at,
              'rtt': DateTime.now().millisecondsSinceEpoch - at
            });
      case RcEvt.status:
        setState(() => _lastStatus = payload);
      case RcEvt.device:
        setState(() => _lastDevice = payload);
      case RcEvt.location:
        setState(() => _lastLocation = payload);
      // `rc.photo` 的**单帧截屏**路径（FR-85 P1）：端点 `screen.cast.request
      // {once:true}` 抓一帧后回本事件。camera.snap 仍按设计降级（见 docs/16 §9），
      // 故这里的消费端同时服务单帧截屏与将来可能的拍照回传。
      case RcEvt.photo:
        setState(() => _photoB64 = payload['photoB64'] as String?);
      case RcEvt.logs:
        setState(() => _lastLogs = (payload['logs'] as List?) ?? const []);
      case RcEvt.assets:
        setState(() {
          _lastAssets = (payload['assets'] as List?) ?? const [];
          _assetsTotal =
              (payload['total'] as num?)?.toInt() ?? _lastAssets!.length;
        });
      case RcEvt.presets:
        setState(
            () => _lastPresets = (payload['categories'] as List?) ?? const []);
      // ---- docs/61：远程桌面级控制（看 + 控）的回执 ----
      // 会话状态机镜像：端点授权/拒绝/开流/停止都会推一条，落进回执行
      // （控制端据此知道"等画面 / 被拒 / 已中断"，而不是静默无反应）。
      case RcEvt.screen:
        final st = payload['state'] as String? ?? '';
        _pushReceipt('屏幕会话：$st');
      // 逐条输入注入回执（刻意不并入 rc.ack，见 protocol.dart 的说明）：
      // 失败必须带原因，否则用户只看到"✗"却不知道端点为何拒。
      case RcEvt.inputAck:
        final ok = payload['ok'] == true;
        final why = payload['message']?.toString() ?? '';
        _pushReceipt(
            '${ok ? '✓' : '✗'} 输入注入${ok || why.isEmpty ? '' : '（$why）'}');
      case RcEvt.ack:
        final cmdId = payload['for'] as String? ?? '';
        final p = cmdId.isEmpty ? null : _pendingAcks[cmdId];
        // ⚠️ 只对「响应就是 rc.ack」的命令弹提示：专用事件类命令（status.get /
        // location.get …）的响应**不是** rc.ack，收到它的 ack 属协议异常，
        // 不能当成正常回执（BUG-038 判据；这也正是 R-3 要区分两种期望的原因）。
        if (p != null && p.expectType == RcEvt.ack) {
          _pendingAcks.remove(cmdId);
          // Y1 音量：只有回执 ok 才记「最后成功设置」——端点拒绝的值
          // 不能被当成已生效（发送即记忆 = 假成功）。
          final shot = _volumeInFlight.remove(cmdId);
          if (payload['ok'] == true && shot != null) {
            unawaited(_rememberVolume(shot.key, shot.pct));
          }
          // 失败原因（`data`）必须一并显示：只说"✗"等于让用户自己去猜
          // 端点为什么拒绝（R-4 同族判据）。
          final data = payload['data']?.toString() ?? '';
          // FR-79：不再弹 SnackBar（原「逐动作反馈点」），改写进两行高回执行。
          _pushReceipt('${payload['ok'] == true ? '✓' : '✗'} ${p.desc}'
              '${data.isEmpty ? '' : '（$data）'}');
        }
    }
    // R-3：收到期望的响应即清除条目 —— 否则 8s 后会误报"端点未响应"。
    // ack 已在上面按 cmdId 精确清理（只清"等 ack"的那类），故跳过。
    if (type != RcEvt.ack) _clearExpectation(type, payload['for']);
  }

  /// 登记一条「期望响应」（R-3）：命令已发出，等待 [expectType] 类型的事件。
  void _armExpectation(String cmdId, String desc, String? expectType) {
    if (expectType == null) return;
    _pendingAcks[cmdId] = _PendingAck(desc: desc, expectType: expectType);
  }

  /// 收到响应 → 清除对应条目。
  ///
  /// - 带 `for` 的事件（rc.device / location / logs / assets / presets）：
  ///   只清 `for == cmdId` 的那一条；
  /// - 不带 `for` 的事件（rc.pong / rc.status）：清掉**同类型**的全部 ——
  ///   它们没有可对账的 id（端点侧也没带），只能按类型认领。
  void _clearExpectation(String type, Object? forId) {
    if (_pendingAcks.isEmpty) return;
    final id = forId is String ? forId : '';
    _pendingAcks.removeWhere((cmdId, p) =>
        p.expectType == type && (id.isEmpty || cmdId == id));
  }

  /// 1s 扫描：超过 [_ackTimeoutSec] 仍未收到响应的条目 → **提示 + 清除**。
  ///
  /// 文案要覆盖三种"点了没反应"的常见原因，否则用户无法决定下一步：
  /// 端点离线、配对码不一致（能发出去但对方解不开）、引擎未运行。
  void _expirePending() {
    if (!mounted || _pendingAcks.isEmpty) return;
    final expired = <String>[];
    _pendingAcks.removeWhere((cmdId, p) {
      if (++p.waitedSec < _ackTimeoutSec) return false;
      expired.add(p.desc);
      // 音量命令超时同样不算成功（在途记录一并清除）。
      _volumeInFlight.remove(cmdId);
      return true;
    });
    if (expired.isEmpty) return;
    final head = expired.first;
    final more = expired.length - 1;
    // FR-79：超时同样写入回执行（不再弹 SnackBar）。
    _pushReceipt('⚠ 「$head」端点未响应：可能离线、配对码不一致或引擎未运行'
        '${more > 0 ? '（另有 $more 条同类）' : ''}');
  }

  /// 发送命令。
  ///
  /// [trackAck]：响应是通用回执 `rc.ack`（默认）；
  /// [expectEvt]：响应是**专用事件**（`rc.status` / `rc.location` …）。
  ///
  /// 两者都会登记一条「期望响应」（R-3）：8 秒内没等到就如实告诉用户
  /// 「端点未响应」，而不是让界面毫无变化。
  ///
  /// 返回该命令的 `cmdId`（发出并记账时）；**没有发出去**（未激活/未选中
  /// 端点/发送失败）返回 null —— 调用方据此把"发出去的命令"与后续回执
  /// 对上账（音量模块靠它判定"最后成功设置的值"）。
  Future<String?> _send(String type, Map<String, dynamic> payload, String desc,
      {bool trackAck = true, String? expectEvt}) async {
    final msg = RcMessage.now(type, payload);
    final expect = trackAck ? RcEvt.ack : expectEvt;

    // 协助会话通道：对端不是已配对设备，经会合主题收发。
    final channel = widget.channel;
    if (channel != null) {
      if (!channel.canSend) {
        _pushReceipt('⚠ $desc：协助会话未激活');
        return null;
      }
      final ok = await channel.send(msg);
      if (!mounted) return null;
      if (ok) {
        _armExpectation(msg.id, desc, expect);
        _pushReceipt('→ $desc  已发出（等待回执…）');
        return msg.id;
      }
      _pushReceipt('✗ $desc：发送失败');
      return null;
    }

    final ep = _endpoint;
    if (ep == null) {
      _pushReceipt('⚠ $desc：请先选择端点');
      return null;
    }
    final store = await _store();
    final ok = await RcEndpointService.instance.sendTo(ep, msg, store);
    if (!mounted) return null;
    if (ok) {
      // 只有**真的发出去了**才记账：没发出去的情况下面会立刻给出原因，
      // 再叠一条"8 秒后未响应"只会互相矛盾。
      _armExpectation(msg.id, desc, expect);
      _pushReceipt('→ $desc  已发出（等待回执…）');
      return msg.id;
    }
    // R-9：`sendTo` 返回 false 的原因**不止一种**，提示必须跟着原因走。
    // 一律说"已入队，端点上线后自动执行"会让"本机远程模块根本没开"的用户
    // 一直等一个永远等不到的补发（那是**误导**，不是提示）。
    if (!_enabled) {
      _pushReceipt('⚠ $desc：本机远程模块未开启，命令不会补发');
    } else {
      _pushReceipt('⚠ $desc：端点离线，已入队（端点上线后自动执行）');
    }
    return null;
  }

  /// 该命令在当前通道下是否预计可执行（协助会话下按端点放行的权限位灰化）。
  bool _allowed(String cmd) {
    final channel = widget.channel;
    if (channel == null) return true;
    return channelAllows(channel, cmd);
  }

  /// 协助会话头部：端点名 + 权限摘要（让使用者随时知道"对方允许了什么"）。
  Widget _sessionBanner() {
    final channel = widget.channel!;
    final scheme = Theme.of(context).colorScheme;
    final perms =
        channel is AssistChannel ? channel.client.perms : AssistPerms.none;
    final on = <String>[];
    for (final e in AssistPerms.labels.entries) {
      if (perms.flag(e.key)) on.add(e.value);
    }
    return Card(
      color: scheme.primaryContainer,
      child: ListTile(
        leading: Icon(Icons.support_agent, color: scheme.onPrimaryContainer),
        title: Text(channel.label,
            style: TextStyle(
                color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600)),
        subtitle: Text(
          on.isEmpty ? '端点尚未放行任何能力（默认全拒）' : '已放行：${on.join('、')}',
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (widget.channel == null && !_enabled) _enableHint(),
        if (widget.channel != null) _sessionBanner() else _endpointSelector(),
        if (_targetOffline) ...[
          const SizedBox(height: 8),
          _offlineBanner(),
        ],
        const SizedBox(height: 12),
        _section('设备快照与动作'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Ping'),
                // 响应是专用事件 rc.pong（不是 rc.ack）→ 记「期望 rc.pong」，
                // 收到即清、超 8s 未收到即提示（R-3）。
                onPressed: _allowed(RcCmd.ping)
                    ? () => _send(RcCmd.ping, {}, 'Ping 测试',
                        trackAck: false, expectEvt: RcEvt.pong)
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.phone_android),
                label: const Text('状态快照'),
                // 该命令的响应是专用事件 rc.status，不是 rc.ack
                // （BUG-038：若按默认 trackAck，_pendingAcks 里的条目永不清理）。
                onPressed: _allowed(RcCmd.statusGet)
                    ? () => _send(RcCmd.statusGet, {}, '状态快照',
                        trackAck: false, expectEvt: RcEvt.status)
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.battery_charging_full),
                label: const Text('设备状态'),
                // BUG-037：端点早已实现 device.status（电量/充电/版本/待执行数），
                // 控制台也早就有「设备快照回执」卡片，但**没有任何入口发这条命令**
                // → 卡片永久为空。此按钮补上入口。
                onPressed: _allowed(RcCmd.deviceStatus)
                    ? () => _send(RcCmd.deviceStatus, {}, '设备状态',
                        trackAck: false, expectEvt: RcEvt.device)
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.photo_camera),
                // R-7：端点 `camera.snap` **恒降级**回 `rc.ack(false)`
                // （camera 插件与 AGP9 不兼容，见 docs/16 §9 注记），
                // `rc.photo` 没有发出方 ⇒「拍照回执」卡片是死分支。
                // 文案必须让用户知道"现在点了没用"，否则只会看到一句
                // 「✗ 拍照回传」，像是坏了。
                //
                // ⚠️ 拆成两个 `Text`（而不是一整串）是刻意的：既有回归用例
                // （`remote_console_tab_test.dart` RCT-09/RCT-10）用
                // `find.widgetWithText(FilledButton, '拍照回传')` 定位本按钮，
                // 合成一串会让那个精确匹配失效。视觉上仍是完整一句。
                label: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text('拍照回传'), Text('（暂未启用）')],
                ),
                onPressed: _allowed(RcCmd.cameraSnap)
                    ? () =>
                        _send(RcCmd.cameraSnap, {}, '拍照回传（暂未启用）')
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.location_on),
                label: const Text('定位回传'),
                onPressed: _allowed(RcCmd.locationGet)
                    ? () => _send(RcCmd.locationGet, {}, '定位回传',
                        trackAck: false, expectEvt: RcEvt.location)
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.receipt_long),
                label: const Text('端点日志'),
                // BUG-037 同类：logs.recent → rc.logs 此前**收发两端皆无**
                // （端点在实现、事件无人消费、控制器无入口）。此处一并补齐。
                onPressed: _allowed(RcCmd.logsRecent)
                    ? () => _send(RcCmd.logsRecent, {'limit': 20}, '端点日志',
                        trackAck: false, expectEvt: RcEvt.logs)
                    : null),
            // ---- docs/61：远程桌面级控制（看 + 控）----
            // 请求后**端点**会弹 MediaProjection 系统授权窗；且 `kind:'control'`
            // 还需端点已开启无障碍。任一不满足 ⇒ 端点如实回 `ok:false`（不静默）。
            FilledButton.tonalIcon(
                icon: const Icon(Icons.desktop_windows_outlined),
                label: const Text('请求远程控制'),
                onPressed: _allowed(RcCmd.screenCastRequest)
                    ? () async {
                        final castId =
                            'cast_${DateTime.now().millisecondsSinceEpoch}';
                        // 跨 await 前先取 Navigator（避免用 BuildContext 跨异步间隙）。
                        final navigator = Navigator.of(context);
                        await _send(
                            RcCmd.screenCastRequest,
                            {'castId': castId, 'kind': 'control'},
                            '请求远程控制（需对方授权 + 已开无障碍）');
                        // 授权是**异步**的（端点弹系统窗）⇒ 先进观看页等画面；
                        // 端点拒绝时 `rc.screen{state:denied}` + `rc.ack{ok:false}`
                        // 会落在回执框里，页面显示"等待画面…"不会假装成功。
                        final ep = _endpoint;
                        if (ep != null && mounted) {
                          await navigator.push<void>(MaterialPageRoute<void>(
                            builder: (_) => ScreenViewerScreen(
                                endpoint: ep, castId: castId),
                          ));
                        }
                      }
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.stop_screen_share_outlined),
                label: const Text('停止远程控制'),
                onPressed: _allowed(RcCmd.screenCastStop)
                    ? () => _send(RcCmd.screenCastStop, {}, '停止远程控制')
                    : null),
          ],
        ),
        // FR-79（第八十四轮用户明文）：在「设备快照与动作」与「动作」两模块
        // **中间**插入一个**两行高**的命令行回执组件，显示**所有远程动作的回执**。
        const SizedBox(height: 12),
        _ReceiptConsole(lines: _receipts),
        const SizedBox(height: 12),
        _section('音效播放'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // BUG-048 配套：端点早已实现 asset.list / preset.list → rc.assets /
            // rc.presets，但控制台既无入口也无消费方（HANDOVER §6.12 的 P2 项）。
            // 没有列表就只能按下面那排**固定猜测**的分类盲播；有列表才能点选
            // 指定音源（`sound.play {assetId}`）。
            FilledButton.tonalIcon(
                icon: const Icon(Icons.library_music_outlined),
                label: const Text('端点音源库'),
                // 响应是专用事件 rc.assets（不是 rc.ack）→ 记「期望 rc.assets」。
                onPressed: _allowed(RcCmd.assetList)
                    ? () => _send(RcCmd.assetList, {'limit': 50}, '端点音源库',
                        trackAck: false, expectEvt: RcEvt.assets)
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.category_outlined),
                label: const Text('预置分类'),
                onPressed: _allowed(RcCmd.presetList)
                    ? () => _send(RcCmd.presetList, {}, '预置分类',
                        trackAck: false, expectEvt: RcEvt.presets)
                    : null),
            for (final c in const ['knocks', 'nature', 'ambient', 'alarms'])
              OutlinedButton(
                  onPressed: _allowed(RcCmd.soundPlay)
                      ? () => _send(
                          RcCmd.soundPlay,
                          {'category': c, 'volume': 0.9, 'durationSec': 8},
                          '播放 $c 音效')
                      : null,
                  child: Text(c)),
          ],
        ),
        if (_lastPingAt != null) ...[
          const SizedBox(height: 12),
          _section('Ping'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text('往返 ${_lastPingAt!['rtt']} ms',
                  style: AppText.bodySmall),
            ),
          ),
        ],
        const SizedBox(height: 12),
        _section('守卫与音量'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
                onPressed: _allowed(RcCmd.guardSet)
                    ? () => _send(RcCmd.guardSet, {'enabled': true}, '开启端点守卫')
                    : null,
                child: const Text('守卫 开')),
            OutlinedButton(
                onPressed: _allowed(RcCmd.guardSet)
                    ? () => _send(RcCmd.guardSet, {'enabled': false}, '关闭端点守卫')
                    : null,
                child: const Text('守卫 关')),
          ],
        ),
        _volumePanel(),
        const SizedBox(height: 12),
        _section('全局执行总开关（v1.9 · 节假日自动暂停）'),
        // v82 回显 + 高亮：把端点最近一次 `rc.status` 的 `runMasterMode/paused`
        // 如实展示，并高亮当前档 —— 否则"远程到底改没改"只能靠记忆
        // （按钮此前不回显状态）。数据源与端点 `RcEvt.status` 同源。
        Builder(builder: (context) {
          final raw = _lastStatus?['runMasterMode'] as String?;
          final paused = _lastStatus?['paused'] as bool?;
          final label = raw == null ? null : RunMasterMode.parse(raw).label;
          final text = label == null
              ? '端点当前：未知（尚未取到状态）'
              : '端点当前：$label${paused == true ? ' · 暂停中' : (paused == false ? ' · 运行中' : '')}';
          // v79：远程控制端点的整体刹车。三态与端点设置页一致
          // （`auto` 法定休息日自动暂停 / `on` 强制开启 / `off` 强制关闭）。
          // 门控位为 `script`（见 RcPermGate），协助会话未放行即灰化。
          // v82：当前档用 [FilledButton] 高亮，其余用 [OutlinedButton]。
          Widget btn(RunMasterMode m) {
            final active = raw == m.name;
            final onPressed = _allowed(RcCmd.runMasterSet)
                ? () => _send(RcCmd.runMasterSet, {'mode': m.name}, '总开关=${m.label}')
                : null;
            final child = Text(active ? '● ${m.label}' : m.label);
            return active
                ? FilledButton(onPressed: onPressed, child: child)
                : OutlinedButton(onPressed: onPressed, child: child);
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(text, style: AppText.bodySmall),
              ),
              Wrap(spacing: 8, runSpacing: 8, children: [
                btn(RunMasterMode.auto),
                btn(RunMasterMode.on),
                btn(RunMasterMode.off),
              ]),
            ],
          );
        }),
        const SizedBox(height: 12),
        _section('指令组（宏）'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // BUG-020 剩余项：端点早已实现 script.stop，但控制器无入口。
            // 门控位为 `script`（见 RcPermGate），协助会话下未放行即灰化。
            OutlinedButton(
                onPressed: _allowed(RcCmd.scriptStop)
                    ? () => _send(RcCmd.scriptStop, {}, '停止端点指令组')
                    : null,
                child: const Text('停止指令组')),
          ],
        ),
        const SizedBox(height: 12),
        _section('振动（v1.9 停止 / v2.x 发送）'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // v2.x：主动"震"端点 —— 固定强度+固定时长 或 随机强度+随机时长。
            // 与下面「停止端点振动」是一对（能震才谈得上停）。
            OutlinedButton.icon(
                icon: const Icon(Icons.touch_app, size: 18),
                onPressed: _allowed(RcCmd.vibrateStart)
                    ? () async {
                        final v = await showDialog<Map<String, dynamic>>(
                            context: context,
                            builder: (_) => const _VibrateStartDialog());
                        if (v == null || !mounted) return;
                        await _send(RcCmd.vibrateStart, v, '发送端点振动');
                      }
                    : null,
                label: const Text('发送振动')),
            // D1 配套：持续振动**不设时长硬上限**，换来的是"任何时刻都能停"。
            // 这个按钮就是那半边 —— 没有它，"不设上限"就是一句空话。
            OutlinedButton.icon(
                icon: const Icon(Icons.vibration, size: 18),
                onPressed: _allowed(RcCmd.vibrateStop)
                    ? () => _send(RcCmd.vibrateStop, {}, '停止端点振动')
                    : null,
                label: const Text('停止端点振动')),
          ],
        ),
        const SizedBox(height: 16),
        if (_lastStatus != null &&
            (_lastStatus!['pendingCount'] as num?) != null) ...[
          _section('状态回执（status.get）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                '端点待执行 ${_lastStatus!['pendingCount']} 条 · '
                '版本 ${_lastStatus!['version'] ?? '?'}',
                style: AppText.bodySmall,
              ),
            ),
          ),
        ],
        if (_lastDevice != null) ...[
          _section('设备快照回执'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                '电量 ${_lastDevice!['batteryLevel']}%'
                '${(_lastDevice!['charging'] as bool?) == true ? '（充电中）' : ''}\n'
                '待执行 ${_lastDevice!['pendingCount']} 条 · 版本 ${_lastDevice!['version']}',
                style: AppText.bodySmall,
              ),
            ),
          ),
        ],
        // R-3③：端点定位失败时回 `rc.location {lat:null, error:true}` ——
        // 旧条件只认 `lat is num`，于是**失败被整个隐藏**：用户点了「定位回传」
        // 看到的是一片空白，分不清"没回"还是"回了但拿不到"。
        if (_lastLocation != null &&
            (_lastLocation!['lat'] is num || _lastLocation!['error'] == true)) ...[
          _section('定位回执'),
          _locationCard(),
        ],
        if (_lastLogs != null) ...[
          _section('端点日志回执（logs.recent）'),
          _logsCard(),
        ],
        if (_lastAssets != null) ...[
          _section('端点音源库回执（asset.list）'),
          _assetsCard(),
        ],
        if (_lastPresets != null) ...[
          _section('端点预置分类回执（preset.list）'),
          _presetsCard(),
        ],
        // ⚠️ R-7 死分支（同上，显式标注保留）：只有端点将来恢复 `rc.photo`
        // 才会出现。当前 `camera.snap` 恒回 `rc.ack(false)`，永远走不到这里。
        if (_photoB64 != null) ...[
          _section('拍照回执'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: _PhotoView(b64: _photoB64!),
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  /// 远程模块未启用时的引导（端点服务未运行则所有命令都不会被接收）。
  Widget _enableHint() => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: ListTile(
          leading: const Icon(Icons.wifi_tethering_off),
          title: const Text('远程模块未开启'),
          subtitle: const Text('端点服务未运行：本机收不到命令，也收不到对端回执'),
          trailing: TextButton(
            onPressed: () => context.push('/remote/settings'),
            child: const Text('去开启'),
          ),
        ),
      );

  Widget _endpointSelector() {
    if (_endpoints.isEmpty) {
      return Card(
          child: ListTile(
              leading: const Icon(Icons.phonelink_off),
              title: const Text('尚未配对端点'),
              subtitle: const Text('在「扫码配对」完成两台设备的互信'),
              onTap: () => context.push('/remote/pair-qr')));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        child: DropdownButtonFormField<String>(
          initialValue: _selectedId.isEmpty ? null : _selectedId,
          decoration: const InputDecoration(
              labelText: '目标端点', border: InputBorder.none),
          items: [
            for (final e in _endpoints)
              DropdownMenuItem(value: e.deviceId, child: Text(e.name)),
          ],
          onChanged: (v) async {
            // R90 体验项：**换端点必须清空上一台的回执**。
            // 旧实现只改 `_selectedId`，`_lastStatus/_lastDevice/...` 仍是上一台
            // 的数据 —— 切换瞬间会出现"看着 A 的名字、看着 B 的待执行条数"，
            // 与 R-5 想消除的形态同源。
            setState(() {
              _selectedId = v ?? '';
              _lastStatus = null;
              _lastDevice = null;
              _lastPingAt = null;
              _lastLocation = null;
              _lastLogs = null;
              _lastAssets = null;
              _lastPresets = null;
            });
            // 持久化到全局选择：换页/重启后仍是这台（"快速连接"的另一端）。
            final prefs = await SharedPreferences.getInstance();
            await RemoteStore(prefs).setSelectedEndpoint(v ?? '');
            // 换端点 → 滑杆回填为新目标自己的音量（Y1）。
            await _restoreVolume();
          },
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      );

  /// 音量面板（Y1）：滑杆 + 快捷档位，替换旧的写死 80% 按钮。
  ///
  /// - **松手才发送**：拖动过程只改本地状态（onChanged），松手
  ///   （onChangeEnd）才发命令 —— 拖动途中每次回调都发会把端点刷成
  ///   命令洪水（8s 超时队列被塞满，真正的命令被淹没）。
  /// - `_allowed` 为 false 时整体置灰并给出原因（协助会话未放行 volume 位），
  ///   不另造一套门禁。
  /// - 底部小字如实说明平台边界（I-4：仅 Android 生效，iOS 恒失败）。
  Widget _volumePanel() {
    final allowed = _allowed(RcCmd.volumeSet);
    final pct = _volumePct.round();
    final note = allowed
        ? '仅 Android 生效，iOS 当前不支持（I-4）'
        : '协助会话未放行「调节音量」权限（volume 位），面板已置灰；'
            '仅 Android 生效，iOS 当前不支持（I-4）';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.volume_up, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(volumeLabelForPercent(pct))),
              Text('$pct%', style: AppText.bodySmall),
            ]),
            Slider(
              value: _volumePct,
              min: 0,
              max: 100,
              divisions: 100,
              label: '$pct%',
              onChanged: allowed
                  ? (v) => setState(() => _volumePct = v)
                  : null,
              onChangeEnd: allowed ? (v) => _sendVolume(v.round()) : null,
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in volumeQuickSteps())
                  OutlinedButton(
                    onPressed: allowed
                        ? () {
                            setState(() => _volumePct = s.toDouble());
                            _sendVolume(s);
                          }
                        : null,
                    child: Text(s == 0 ? '静音' : '$s%'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(note, style: AppText.labelSmall),
          ],
        ),
      ),
    );
  }

  /// 端点离线横幅（LWT 离线哨兵，BUG-039）。
  ///
  /// 明确告诉使用者两件事：①**现在发的命令不会立刻执行**；
  /// ②它们**没有丢**（进 outbox，端点上线后自动冲刷）——
  /// 后者是这套设计里最容易让人误以为"坏了"的地方。
  Widget _offlineBanner() {
    final scheme = Theme.of(context).colorScheme;
    final name = _offlinePeers[_selectedId] ?? '端点';
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(children: [
          Icon(Icons.cloud_off, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$name 已离线（broker 离线哨兵）：命令将入队，端点上线后自动执行',
              style: AppText.bodySmall.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ]),
      ),
    );
  }

  /// 定位回执卡片（R-3③：成功与失败**都要渲染**）。
  ///
  /// 端点失败时回的载荷是 `{lat:null, lng:null, error:true}`（见
  /// `endpoint_service._sendLocation` 的 catch 分支），必须给出**可行动**的
  /// 原因（未授权定位 / 定位服务未开启），而不是一块空白。
  Widget _locationCard() {
    final loc = _lastLocation ?? const <String, dynamic>{};
    if (loc['error'] == true) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Text('定位失败（端点未授权定位或定位服务未开启）',
              style: AppText.bodySmall),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Text(
          'lat ${loc['lat']}, lng ${loc['lng']}'
          '（精度 ±${(loc['acc'] as num?)?.round() ?? '?'} m）',
          style: AppText.bodySmall,
        ),
      ),
    );
  }

  /// 端点审计日志回执卡片（`logs.recent` → `rc.logs`）。
  ///
  /// 行格式由端点决定（`t/source/action/status`，见 `endpoint_service`），
  /// 这里只做展示，最多列 20 条（与请求的 `limit` 一致，防长列表撑爆页面）。
  Widget _logsCard() {
    final rows = _lastLogs ?? const [];
    if (rows.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Text('端点暂无执行日志', style: AppText.bodySmall),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final raw in rows.take(20))
              if (raw is Map)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${_fmtClock(raw['t'])} · ${raw['source']}/${raw['action']}'
                    ' · ${raw['status']}',
                    style: AppText.bodySmall,
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// 端点音源库回执卡片（`asset.list` → `rc.assets`）。
  ///
  /// 每行**可点**：点一下即以 `sound.play {assetId}` 播放**那一条**。
  /// 列表与"指定播放"必须成对出现 —— BUG-048 之前端点忽略 `assetId`，
  /// 即使有了列表，点选也只会播库里最新的一条（点"闹钟"响起"敲击声"）。
  Widget _assetsCard() {
    final rows = _lastAssets ?? const [];
    if (rows.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Text('端点音源库为空（可先在端点导入音源或预置库）', style: AppText.bodySmall),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
              child: Text('共 $_assetsTotal 条（点选即指定播放）',
                  style: AppText.bodySmall),
            ),
            for (final raw in rows.take(50))
              if (raw is Map)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.play_arrow, size: 18),
                  title: Text(raw['name'] as String? ?? '（未命名）',
                      style: AppText.bodyMedium),
                  subtitle: Text(
                    '${_fmtDuration(raw['durationMs'])}'
                    '${_tagSuffix(raw['tags'])}',
                    style: AppText.labelSmall,
                  ),
                  onTap: () => _playAsset(raw['id'] as String?),
                ),
          ],
        ),
      ),
    );
  }

  /// 端点预置分类回执卡片（`preset.list` → `rc.presets`）。
  ///
  /// 与上面那排固定猜测的分类不同，这里是端点**真实存在**的分类，
  /// 因此点了必然有音源（否则端点会如实回 `ok=false` 说明原因）。
  Widget _presetsCard() {
    final cats = (_lastPresets ?? const []).whereType<String>().toList();
    if (cats.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Text('端点无预置音源分类（尚未导入预置库）', style: AppText.bodySmall),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in cats)
              ActionChip(
                label: Text(c),
                onPressed: () => _send(RcCmd.soundPlay,
                    {'preset': c, 'volume': 0.9, 'durationSec': 8}, '播放 $c 分类'),
              ),
          ],
        ),
      ),
    );
  }

  /// 点选端点音源库中的一条 → **指定 assetId** 播放。
  void _playAsset(String? id) {
    if (id == null || id.isEmpty) return;
    _send(RcCmd.soundPlay, {'assetId': id, 'volume': 0.9, 'durationSec': 8},
        '播放指定音源');
  }

  /// 标签列 → ` · a/b`（空标签不产生尾巴）。
  static String _tagSuffix(Object? tags) {
    if (tags is! List) return '';
    final list = tags.whereType<String>().toList();
    return list.isEmpty ? '' : ' · ${list.join('/')}';
  }

  /// 毫秒时长 → `1:05` / `12s`。
  static String _fmtDuration(Object? ms) {
    if (ms is! num) return '时长未知';
    final total = ms.toInt() ~/ 1000;
    if (total < 60) return '${total}s';
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  /// 毫秒时间戳 → `HH:mm:ss`（设备时钟可能缺失，缺失时显示占位符）。
  static String _fmtClock(Object? ms) {
    if (ms is! num) return '--:--:--';
    final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}

/// 两行高的远程动作回执命令行组件（FR-79，第八十四轮用户明文）。
///
/// 用户原话：「远程控制台页面『目标端点和设备快照』与『动作』两个模块中间
/// 新增两行高的命令行组件，显示为一个**两行高的文本框**，里面显示**所有远程
/// 动作的回执**，超过两行时**自动换行**，同时**去除原来的各动作的反馈信息显示点**。」
///
/// 呈现选择：
/// - **固定两行高**（按等宽字体行高 × 2 定高），不因内容多少而跳动；
/// - 内容**自动换行**，超出两行时内部**可滚动**（不然第 3 行起会被裁掉，
///   而"所有回执"是硬需求 ⇒ 必须能回看全部）；
/// - 等宽字体 + 深色底 + 亮字，视觉上就是"命令行/终端回执"；
/// - 空态给一行灰字占位，避免用户以为"组件没渲染"。
class _ReceiptConsole extends StatelessWidget {
  const _ReceiptConsole({required this.lines});

  /// 全部回执行（按时间先后追加；渲染时最新的在最下面）。
  final List<String> lines;

  /// 命令行字号（等宽）。
  static const double _fontSize = 12;

  /// 行高倍数（两行高的定高基准）。
  static const double _lineHeight = 1.4;

  /// 组件的**固定高度 = 两行**（用户明文"两行高"）。
  static double get _height => _fontSize * _lineHeight * 2 + 16; // + 内边距

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: _height,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        // 深色"终端"底：与周围 Card 区分，一眼知道是回执区。
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: lines.isEmpty
          ? const Text(
              '> 远程动作回执将显示在这里',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: _fontSize,
                height: _lineHeight,
                color: Colors.grey,
              ),
            )
          : SingleChildScrollView(
              // 超出两行 ⇒ 可滚动回看全部回执（"显示所有回执"的硬需求）。
              child: Text(
                lines.join('\n'),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: _fontSize,
                  height: _lineHeight,
                  color: scheme.onSurface,
                ),
              ),
            ),
    );
  }
}

/// 一条「已发出、等待响应」的命令（R-3）。
///
/// 与旧实现（`Map<String, String>` 只存描述）的区别：多存了**期望的响应类型**
/// 与**已等待时长**，前者决定收到什么事件才能销账，后者决定何时判超时。
class _PendingAck {
  _PendingAck({required this.desc, required this.expectType});

  /// 展示用描述（提示文案里回显，让用户知道是**哪一条**没回）。
  final String desc;

  /// 期望的响应类型：`rc.ack`，或专用事件（`rc.status` / `rc.location` …）。
  final String expectType;

  /// 已等待的秒数（由 1s 扫描累加）。
  ///
  /// ⚠️ 用**计数**而不是 `DateTime.now()` 差值：部件测试跑在 `FakeAsync` 假时钟
  /// 里，`tester.pump(9s)` 推得动定时器、推不动墙上时钟 —— 用墙上时钟的话
  /// "8 秒未响应"这条分支在宿主上**永远测不到**（也就永远锁不住）。
  int waitedSec = 0;
}

/// 回传照片解码视图。
///
/// ⚠️ R-7：当前**不可达**（端点不产 `rc.photo`），保留是为了端点恢复拍照
/// 回传时不必重写消费端；见 [RcEvt.photo] 处的说明。
class _PhotoView extends StatelessWidget {  const _PhotoView({required this.b64});

  final String b64;

  @override
  Widget build(BuildContext context) {
    try {
      return Image.memory(
        base64Decode(b64),
        errorBuilder: (_, __, ___) =>
            const Text('图片解码失败', style: AppText.bodySmall),
      );
    } on Object {
      return const Text('图片解码失败', style: AppText.bodySmall);
    }
  }
}

/// 「发送振动」参数对话框：选模式 → 调强度/时长 → 返回 `vibrate.start` payload。
///
/// 与指令组的振动步**共用** [rcVibrateStartFieldsFor] 的参数表 —— 表单字段与
/// 端点解析口径同源，不会出现"UI 能填、端点读不懂"的隐性契约。
/// 三种模式对应：固定强度+固定时长（fixed）/ 随机强度+随机时长（random）/
/// 区间浮动（continuous）。
class _VibrateStartDialog extends StatefulWidget {
  const _VibrateStartDialog();

  @override
  State<_VibrateStartDialog> createState() => _VibrateStartDialogState();
}

class _VibrateStartDialogState extends State<_VibrateStartDialog> {
  RcVibrateMode _mode = RcVibrateMode.fixed;

  /// 当前各字段取值（key → num）；模式切换时按 [rcVibrateDefaultParams] 重置。
  final Map<String, num> _v = <String, num>{};

  @override
  void initState() {
    super.initState();
    _seed();
  }

  void _seed() {
    _v.clear();
    if (_mode == RcVibrateMode.fixed) {
      // 固定强度 + 固定时长：默认 5 秒 / 60%。
      _v['durationSec'] = 5;
      _v['intensity'] = 0.6;
      return;
    }
    final defaults = rcVibrateDefaultParams(_mode);
    for (final f in rcVibrateStartFieldsFor(_mode)) {
      final d = defaults[f.key];
      _v[f.key] = d is num ? d : f.min;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('发送振动'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<RcVibrateMode>(
                segments: const [
                  ButtonSegment(
                      value: RcVibrateMode.fixed, label: Text('固定')),
                  ButtonSegment(
                      value: RcVibrateMode.random, label: Text('随机')),
                  ButtonSegment(
                      value: RcVibrateMode.continuous, label: Text('持续')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() {
                  _mode = s.first;
                  _seed();
                }),
              ),
              const SizedBox(height: 8),
              for (final f in rcVibrateStartFieldsFor(_mode)) _field(f),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(
              context, <String, dynamic>{'mode': _mode.name, ..._v}),
          child: const Text('发送'),
        ),
      ],
    );
  }

  Widget _field(RcVibrateField f) {
    final lo = f.min.toDouble();
    final hi = f.max.toDouble();
    final cur = (_v[f.key] ?? f.min).toDouble().clamp(lo, hi);
    final divisions = f.fraction ? 20 : (hi - lo).round().clamp(1, 120);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${f.label}：${f.fraction ? cur.toStringAsFixed(2) : cur.round()}',
          style: AppText.bodySmall,
        ),
        Slider(
          min: lo,
          max: hi,
          divisions: divisions,
          value: cur,
          onChanged: (v) => setState(() => _v[f.key] = v),
        ),
      ],
    );
  }
}
