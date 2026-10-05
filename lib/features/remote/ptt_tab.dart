import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/controller_service.dart';
import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';

/// 对讲机整页（v1.6；v2 起为**流式**）：
/// 选择端点 → 按住说话（≤60s，AAC）→ **边录边分包加密发送** →
/// 端点**边收边放**（首片到达即出声）→ 末片收尾并回执
/// （BUG-046：`rc.pttAck` 现已消费渲染）。
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

  /// 手指是否仍按在麦克风上（P2-25）。
  ///
  /// `_start()` 要跨"请求麦克风权限 → `pttStart()`"两段 await；用户若在它们
  /// 完成前松手，`_send()` 因 `_recording == false` 直接返回，随后 `_start()`
  /// 仍会把录音拉起来 —— 一段**无人控制**的录音要到 60s 上限才自动发送。
  /// 用本标志在 await 之后复核"是否仍按住"，已松手则撤销启动。
  bool _pressing = false;

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
    // 录音中直接离开页面会把麦克风一直占着 —— 释放路径必须兜底。
    if (_recording) unawaited(RcControllerService.instance.pttCancelStream());
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (!mounted) return;
    setState(() {
      _endpoints = store.paired();
      // 与「我的设备」共享同一份选择（快速连接的落点）。
      _selectedId = initialSelectedId(_endpoints, store.selectedEndpointId);
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
    // P2-25：权限申请期间用户可能已松手 → 不再开始录音。
    if (!_pressing) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final store = RemoteStore(prefs);
    final ep = endpointById(_endpoints, _selectedId);
    if (ep == null) {
      messenger.showSnackBar(const SnackBar(content: Text('端点已不存在（可能已解配对）')));
      return;
    }
    final controller = RcControllerService.instance;
    final ok = await controller.pttStartStream(ep, store);
    if (!ok) {
      messenger.showSnackBar(const SnackBar(content: Text('录音启动失败')));
      return;
    }
    // P2-25：`pttStartStream()` 期间松手 → 录音流已拉起但无人控制，必须撤销，
    // 否则这段录音要等到 60s 上限才自动收尾。
    if (!_pressing || !mounted) {
      await controller.pttCancelStream();
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
    final r = await RcControllerService.instance.pttStopStream();
    if (mounted) setState(() => _lastResult = r.message);
  }

  Future<void> _cancel() async {
    _ticker?.cancel();
    final controller = RcControllerService.instance;
    await controller.pttCancelStream();
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
                onChanged: (v) async {
                  setState(() => _selectedId = v ?? '');
                  final prefs = await SharedPreferences.getInstance();
                  await RemoteStore(prefs).setSelectedEndpoint(v ?? '');
                },
              ),
            ),
          ),
        const SizedBox(height: 24),
        Center(
          child: Column(
            children: [
              GestureDetector(
                onTapDown: (_) {
                  _pressing = true;
                  _start();
                },
                onTapUp: (_) {
                  _pressing = false;
                  _send();
                },
                onTapCancel: () {
                  _pressing = false;
                  _cancel();
                },
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
              'v2 流式：边说边发、边收边放（约 0.5 秒一片）。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}
