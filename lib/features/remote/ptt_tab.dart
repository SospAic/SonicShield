import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/controller_service.dart';
import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';

/// 对讲机整页（v1.6，v1 整段模式）：
/// 选择端点 → 按住说话（≤60s，AAC）→ 松开自动加密发送 →
/// 端点自动播放并回执（BUG-046：`rc.pttAck` 现已消费渲染）。
/// v2 路线：Opus 流式分片（Zello 式实时）。
class PttTab extends StatefulWidget {
  const PttTab({super.key});

  @override
  State<PttTab> createState() => _PttTabState();
}

class _PttTabState extends State<PttTab> {
  List<PairedEndpoint> _endpoints = const [];
  String _selectedId = '';
  bool _recording = false;
  int _recSec = 0;
  Timer? _ticker;
  String? _lastResult;
  StreamSubscription<Map<String, dynamic>>? _ackSub;

  @override
  void initState() {
    super.initState();
    _load();
    // BUG-046：消费端点的 `rc.pttAck` 回执（此前广播无人消费）。
    _ackSub = RcEndpointService.instance.events.listen((m) {
      if (!mounted) return;
      if (m['type'] == RcEvt.pttAck) {
        final payload = rcPayloadOf(m);
        final ok = payload['ok'] as bool? ?? false;
        setState(() => _lastResult = ok ? '对端已播放 ✓' : '对端播放失败');
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_ackSub?.cancel());
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

  Future<void> _start() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_selectedId.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('请先选择目标端点')));
      return;
    }
    final granted = await Permission.microphone.request().isGranted;
    if (!granted) {
      messenger.showSnackBar(const SnackBar(content: Text('需要麦克风权限')));
      return;
    }
    final controller = RcControllerService.instance;
    final ok = await controller.pttStart();
    if (!ok) {
      messenger.showSnackBar(const SnackBar(content: Text('录音启动失败')));
      return;
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _recSec = t.tick);
      if (_recSec >= 60) {
        t.cancel();
        _send();
      }
    });
    if (mounted) setState(() => _recording = true);
  }

  Future<void> _send() async {
    _ticker?.cancel();
    if (!_recording) return;
    setState(() => _recording = false);
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    final ep = endpointById(_endpoints, _selectedId);
    if (ep == null) {
      // 端点在别处被解配对 —— 明确告知，不要崩（BUG-060）。
      if (mounted) setState(() => _lastResult = '端点已不存在（可能已解配对）');
      return;
    }
    final r = await RcControllerService.instance.pttStopAndSend(ep, store);
    if (mounted) setState(() => _lastResult = r.message);
  }

  Future<void> _cancel() async {
    _ticker?.cancel();
    final controller = RcControllerService.instance;
    await controller.pttCancel();
    if (mounted) {
      setState(() {
        _recording = false;
        _recSec = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_endpoints.isEmpty)
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(14), child: Text('尚未配对端点。请先完成扫码配对。')))
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: DropdownButtonFormField<String>(
                initialValue: _selectedId.isEmpty ? null : _selectedId,
                decoration: const InputDecoration(
                    labelText: '对讲目标', border: InputBorder.none),
                items: [
                  for (final e in _endpoints)
                    DropdownMenuItem(value: e.deviceId, child: Text(e.name)),
                ],
                onChanged: (v) => setState(() => _selectedId = v ?? ''),
              ),
            ),
          ),
        const SizedBox(height: 24),
        Center(
          child: Column(
            children: [
              GestureDetector(
                onTapDown: (_) => _start(),
                onTapUp: (_) => _send(),
                onTapCancel: () => _cancel(),
                child: CircleAvatar(
                  radius: 52,
                  backgroundColor:
                      _recording ? Colors.red : Colors.deepOrange.shade400,
                  child: Icon(
                      _recording ? Icons.radio_button_checked : Icons.mic,
                      size: 48,
                      color: Colors.white),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _recording ? '录音中 $_recSec s / 60s —— 松开发送' : '按住麦克风开始对讲',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              if (_lastResult != null) ...[
                const SizedBox(height: 8),
                Text(_lastResult!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 13)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '对讲语音与遥控命令走同一端到端加密通道（AES-256-GCM），'
              'broker 不可见内容；音频仅由接收端在本地播放并审计留痕。'
              'v2 将升级 Opus 流式分片（250ms 实时对讲）。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}
