import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';

/// 远程控制台（v1.6）：对已配对端点的完全控制——
/// ping/状态快照/任务查看与开关/音效播放/守卫开关/音量调节/拍照/定位。
/// 每个命令的响应经 [RcEndpointService.events] 流实时渲染。
class RemoteConsoleTab extends ConsumerStatefulWidget {
  const RemoteConsoleTab({super.key});

  @override
  ConsumerState<RemoteConsoleTab> createState() => _RemoteConsoleTabState();
}

class _RemoteConsoleTabState extends ConsumerState<RemoteConsoleTab> {
  List<PairedEndpoint> _endpoints = const [];
  String _selectedId = '';
  List<Map<String, dynamic>> _remoteTasks = [];
  Map<String, dynamic>? _lastStatus;
  Map<String, dynamic>? _lastDevice;
  Map<String, dynamic>? _lastPingAt;
  Map<String, dynamic>? _lastLocation;
  String? _photoB64;
  StreamSubscription<Map<String, dynamic>>? _evtSub;
  final _pendingAcks = <String, String>{}; // cmdId -> 描述

  @override
  void initState() {
    super.initState();
    _load();
    _evtSub = RcEndpointService.instance.events.listen(_onEvent);
  }

  @override
  void dispose() {
    unawaited(_evtSub?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (!mounted) return;
    setState(() {
      _endpoints = store.paired();
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

  Future<RemoteStore> _store() async =>
      RemoteStore(await SharedPreferences.getInstance());

  void _onEvent(Map<String, dynamic> m) {
    if (!mounted) return;
    final type = m['type'] as String? ?? '';
    final forId = m['for'] as String?;
    switch (type) {
      case 'rc.pong':
        final at = (m['at'] as num?)?.toInt() ?? 0;
        setState(() => _lastPingAt = {
              'at': at,
              'rtt': DateTime.now().millisecondsSinceEpoch - at
            });
      case 'rc.status':
        setState(() => _lastStatus = m);
      case 'rc.device':
        setState(() => _lastDevice = m);
      case 'rc.location':
        setState(() => _lastLocation = m);
      case 'rc.photo':
        setState(() => _photoB64 = m['photoB64'] as String?);
      case 'rc.tasks':
        final list = (m['tasks'] as List?) ?? const [];
        setState(() {
          _remoteTasks = list.cast<Map<String, dynamic>>();
        });
      case 'rc.ack':
        final desc = _pendingAcks.remove(forId);
        if (desc != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content:
                  Text('${(m['ok'] as bool?) == true ? '✓' : '✗'} $desc')));
        }
    }
  }

  Future<void> _send(String type, Map<String, dynamic> payload, String desc,
      {bool trackAck = true}) async {
    final ep = _endpoint;
    if (ep == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择端点')));
      return;
    }
    final store = await _store();
    final msg = RcMessage.now(type, payload);
    if (trackAck) _pendingAcks[msg.id] = desc;
    final ok = await RcEndpointService.instance.sendTo(ep, msg, store);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('端点离线：「$desc」已入队，端点上线后自动执行')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _endpointSelector(),
        const SizedBox(height: 12),
        _section('设备快照与动作'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Ping'),
                onPressed: () =>
                    _send(RcCmd.ping, {}, 'Ping 测试', trackAck: false)),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.phone_android),
                label: const Text('状态快照'),
                onPressed: () => _send(RcCmd.statusGet, {}, '状态快照')),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.list),
                label: const Text('任务列表'),
                onPressed: () => _send(RcCmd.taskList, {}, '任务列表')),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.photo_camera),
                label: const Text('拍照回传'),
                onPressed: () => _send(RcCmd.cameraSnap, {}, '拍照回传')),
            FilledButton.tonalIcon(
                icon: const Icon(Icons.location_on),
                label: const Text('定位回传'),
                onPressed: () => _send(RcCmd.locationGet, {}, '定位回传')),
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
                  onPressed: () => _send(
                      RcCmd.soundPlay,
                      {'category': c, 'volume': 0.9, 'durationSec': 8},
                      '播放 $c 音效'),
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
                onPressed: () =>
                    _send(RcCmd.guardSet, {'enabled': true}, '开启端点守卫'),
                child: const Text('守卫 开')),
            OutlinedButton(
                onPressed: () =>
                    _send(RcCmd.guardSet, {'enabled': false}, '关闭端点守卫'),
                child: const Text('守卫 关')),
            OutlinedButton(
                onPressed: () =>
                    _send(RcCmd.volumeSet, {'media': 0.8}, '媒体音量 80%'),
                child: const Text('音量 80%')),
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
        if (_photoB64 != null) ...[
          _section('拍照回执'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _PhotoView(b64: _photoB64!),
            ),
          ),
        ],
        if (_remoteTasks.isNotEmpty) ...[
          _section('端点任务列表'),
          Card(
            child: Column(
              children: [
                for (final t in _remoteTasks)
                  SwitchListTile(
                    dense: true,
                    title: Text(t['name'] as String? ?? '',
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text('${t['triggerType']} · ${t['actionType']}',
                        style: const TextStyle(fontSize: 11)),
                    value: (t['enabled'] as bool?) ?? false,
                    onChanged: (v) => _send(
                        RcCmd.taskToggle,
                        {'taskId': t['id'], 'enabled': v},
                        '切换任务「${t['name']}」'),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

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
