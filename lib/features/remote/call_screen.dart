import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/call_service.dart';
import '../../remote/remote_store.dart';
import 'call_incoming_overlay.dart';

/// 视频通话页：选择配对端点发起呼叫（视频/语音）+ 自动接通开关。
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, this.preselectEndpointId});

  final String? preselectEndpointId;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  bool _autoAnswer = false;
  List<PairedEndpoint> _endpoints = const [];
  String? _selected;

  @override
  void initState() {
    super.initState();
    _load();
    // 来电覆盖层监听（手动接听场景）。
    CallIncomingOverlay.attach(context);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (!mounted) return;
    setState(() {
      _endpoints = store.paired();
      _autoAnswer = store.paired().isNotEmpty ? _autoAnswer : _autoAnswer;
      _selected = widget.preselectEndpointId ??
          (_endpoints.isEmpty ? null : _endpoints.first.deviceId);
    });
    _autoAnswer = await CallService.autoAnswerEnabled();
    if (mounted) setState(() {});
  }

  Future<void> _toggleAuto(bool v) async {
    await [
      Permission.camera,
      Permission.microphone,
    ].request();
    await CallService.setAutoAnswer(v);
    if (mounted) setState(() => _autoAnswer = v);
  }

  Future<void> _call(bool video) async {
    final ep = _endpoints.where((e) => e.deviceId == _selected).firstOrNull;
    if (ep == null) return;
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    CallService.bindStore(
        () async => RemoteStore((await SharedPreferences.getInstance())));
    final callId =
        await CallService.instance.startCall(ep, store, video: video);
    if (!mounted) return;
    if (callId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('呼叫失败：请检查摄像头/麦克风权限或端点离线')));
      return;
    }
    Navigator.of(context).pushNamed('/remote/call/in-call');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('视频通话')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: SwitchListTile(
              secondary: Icon(_autoAnswer ? Icons.videocam : Icons.videocam_off,
                  size: 30),
              title: Text(_autoAnswer ? '自动接通已开启' : '自动接通已关闭',
                  style: Theme.of(context).textTheme.titleMedium),
              subtitle: const Text('仅限已配对设备呼入时自动接通（家人守护场景）。'
                  '接通后屏幕可见、系统摄像头指示灯正常工作，不提供隐蔽模式。'),
              value: _autoAnswer,
              onChanged: _toggleAuto,
            ),
          ),
          const SizedBox(height: 12),
          Text('呼叫端点', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (_endpoints.isEmpty)
            const Card(
                child: Padding(
                    padding: EdgeInsets.all(14),
                    child: Text('尚未配对端点。请先在「远程遥控」页完成配对。'))),
          RadioGroup<String>(
            groupValue: _selected,
            onChanged: (v) => setState(() => _selected = v),
            child: Column(
              children: [
                for (final e in _endpoints)
                  RadioListTile<String>(
                    value: e.deviceId,
                    title: Text(e.name),
                    subtitle: Text(e.deviceId),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.videocam),
                  label: const Text('视频呼叫'),
                  onPressed: _selected == null ? null : () => _call(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.call),
                  label: const Text('语音呼叫'),
                  onPressed: _selected == null ? null : () => _call(false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Card(
            color: Color(0x14C62828),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '⚠️ 合规提示：自动接通用于家人守护（老人/儿童看护）与本人设备间协作。'
                '在他人不知情时开启其摄像头属于侵犯隐私的违法行为，本应用不提供'
                '任何隐蔽接通方式——接通即亮屏、系统指示灯正常工作。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
