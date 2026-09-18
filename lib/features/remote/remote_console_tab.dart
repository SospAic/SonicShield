import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/assist.dart';
import '../../remote/command_channel.dart';
import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';

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

  /// 已知离线的对端（peerId → 显示名）。
  ///
  /// 来源：broker 代发的 **LWT 明文离线哨兵** `rc.offline`（docs/14 §4）。
  /// 端点服务（控制器侧）已识别该哨兵、并附上 `peerId`/`peerName` 转发到事件流，
  /// 但此前**没有任何 UI 消费它** —— 使用者在端点离线时毫无提示，
  /// 只有点下命令之后才会从"端点离线：已入队"的提示里**间接**得知（BUG-039）。
  /// 恢复信号：该对端的**任何其它事件**（心跳每 60s 一次，是最慢的一种）。
  final _offlinePeers = <String, String>{};
  StreamSubscription<Map<String, dynamic>>? _evtSub;
  StreamSubscription<void>? _updSub;
  final _pendingAcks = <String, String>{}; // cmdId -> 描述

  @override
  void initState() {
    super.initState();
    _load();
    final channel = widget.channel;
    _evtSub = (channel?.events ?? RcEndpointService.instance.events)
        .listen(_onEvent);
    // 权限/可用性变更 → 重建，刷新按钮灰化与横幅摘要。
    // 协助会话里端点可随时放行或收回权限，若不订阅就只在收到业务回执时才
    // 重建，灰化状态会停留在旧值（BUG-030）。
    _updSub = channel?.updates.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
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
      _selectedId = _endpoints.isEmpty
          ? ''
          : (_selectedId.isEmpty ? _endpoints.first.deviceId : _selectedId);
    });
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
      case RcEvt.photo:
        setState(() => _photoB64 = payload['photoB64'] as String?);
      case RcEvt.logs:
        setState(() => _lastLogs = (payload['logs'] as List?) ?? const []);
      case RcEvt.ack:
        final desc = _pendingAcks.remove(payload['for'] as String?);
        if (desc != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content:
                  Text('${payload['ok'] == true ? '✓' : '✗'} $desc')));
        }
    }
  }

  Future<void> _send(String type, Map<String, dynamic> payload, String desc,
      {bool trackAck = true}) async {
    final msg = RcMessage.now(type, payload);

    // 协助会话通道：对端不是已配对设备，经会合主题收发。
    final channel = widget.channel;
    if (channel != null) {
      if (!channel.canSend) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('协助会话未激活')));
        return;
      }
      if (trackAck) _pendingAcks[msg.id] = desc;
      final ok = await channel.send(msg);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败：「$desc」')));
      }
      return;
    }

    final ep = _endpoint;
    if (ep == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择端点')));
      return;
    }
    final store = await _store();
    if (trackAck) _pendingAcks[msg.id] = desc;
    final ok = await RcEndpointService.instance.sendTo(ep, msg, store);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('端点离线：「$desc」已入队，端点上线后自动执行')));
    }
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
    final perms = channel is AssistChannel
        ? channel.client.perms
        : AssistPerms.none;
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
      padding: const EdgeInsets.all(16),
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
                onPressed: _allowed(RcCmd.ping)
                    ? () => _send(RcCmd.ping, {}, 'Ping 测试', trackAck: false)
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.phone_android),
                label: const Text('状态快照'),
                // 该命令的响应是专用事件 rc.status，不是 rc.ack
                // （BUG-038：若按默认 trackAck，_pendingAcks 里的条目永不清理）。
                onPressed: _allowed(RcCmd.statusGet)
                    ? () => _send(RcCmd.statusGet, {}, '状态快照',
                        trackAck: false)
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.battery_charging_full),
                label: const Text('设备状态'),
                // BUG-037：端点早已实现 device.status（电量/充电/版本/待执行数），
                // 控制台也早就有「设备快照回执」卡片，但**没有任何入口发这条命令**
                // → 卡片永久为空。此按钮补上入口。
                onPressed: _allowed(RcCmd.deviceStatus)
                    ? () => _send(RcCmd.deviceStatus, {}, '设备状态',
                        trackAck: false)
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.photo_camera),
                label: const Text('拍照回传'),
                onPressed: _allowed(RcCmd.cameraSnap)
                    ? () => _send(RcCmd.cameraSnap, {}, '拍照回传')
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.location_on),
                label: const Text('定位回传'),
                onPressed: _allowed(RcCmd.locationGet)
                    ? () => _send(RcCmd.locationGet, {}, '定位回传',
                        trackAck: false)
                    : null),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.receipt_long),
                label: const Text('端点日志'),
                // BUG-037 同类：logs.recent → rc.logs 此前**收发两端皆无**
                // （端点在实现、事件无人消费、控制器无入口）。此处一并补齐。
                onPressed: _allowed(RcCmd.logsRecent)
                    ? () => _send(RcCmd.logsRecent, {'limit': 20}, '端点日志',
                        trackAck: false)
                    : null),
          ],
        ),
        const SizedBox(height: 12),
        _section('音效播放'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
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
              padding: const EdgeInsets.all(12),
              child: Text('往返 ${_lastPingAt!['rtt']} ms',
                  style: const TextStyle(fontSize: 12)),
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
            OutlinedButton(
                onPressed: _allowed(RcCmd.volumeSet)
                    ? () => _send(RcCmd.volumeSet, {'media': 0.8}, '媒体音量 80%')
                    : null,
                child: const Text('音量 80%')),
          ],
        ),
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
        const SizedBox(height: 16),
        if (_lastStatus != null &&
            (_lastStatus!['pendingCount'] as num?) != null) ...[
          _section('状态回执（status.get）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '端点待执行 ${_lastStatus!['pendingCount']} 条 · '
                '版本 ${_lastStatus!['version'] ?? '?'}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
        if (_lastDevice != null) ...[
          _section('设备快照回执'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '电量 ${_lastDevice!['batteryLevel']}%'
                '${(_lastDevice!['charging'] as bool?) == true ? '（充电中）' : ''}\n'
                '待执行 ${_lastDevice!['pendingCount']} 条 · 版本 ${_lastDevice!['version']}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
        if (_lastLocation != null && _lastLocation!['lat'] is num) ...[
          _section('定位回执'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'lat ${_lastLocation!['lat']}, lng ${_lastLocation!['lng']}'
                '（精度 ±${(_lastLocation!['acc'] as num?)?.round() ?? '?'} m）',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
        if (_lastLogs != null) ...[
          _section('端点日志回执（logs.recent）'),
          _logsCard(),
        ],
        if (_photoB64 != null) ...[
          _section('拍照回执'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: DropdownButtonFormField<String>(
          initialValue: _selectedId.isEmpty ? null : _selectedId,
          decoration: const InputDecoration(
              labelText: '目标端点', border: InputBorder.none),
          items: [
            for (final e in _endpoints)
              DropdownMenuItem(value: e.deviceId, child: Text(e.name)),
          ],
          onChanged: (v) => setState(() => _selectedId = v ?? ''),
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      );

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
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(Icons.cloud_off, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$name 已离线（broker 离线哨兵）：命令将入队，端点上线后自动执行',
              style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
            ),
          ),
        ]),
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
          padding: EdgeInsets.all(12),
          child: Text('端点暂无执行日志', style: TextStyle(fontSize: 12)),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// 毫秒时间戳 → `HH:mm:ss`（设备时钟可能缺失，缺失时显示占位符）。
  static String _fmtClock(Object? ms) {
    if (ms is! num) return '--:--:--';
    final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}

/// 回传照片解码视图。
class _PhotoView extends StatelessWidget {
  const _PhotoView({required this.b64});

  final String b64;

  @override
  Widget build(BuildContext context) {
    try {
      return Image.memory(
        base64Decode(b64),
        errorBuilder: (_, __, ___) =>
            const Text('图片解码失败', style: TextStyle(fontSize: 12)),
      );
    } on Object {
      return const Text('图片解码失败', style: TextStyle(fontSize: 12));
    }
  }
}
