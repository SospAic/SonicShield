import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/call_lifecycle.dart';
import '../../remote/endpoint_service.dart';
import '../../remote/multi_call_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';
import '../../core/theme.dart';

/// 多视频同连：同时保持多路视频，点窗口切换当前目标并**在保持连接的情况下**
/// 向该终端发远程指令。
///
/// 为什么"切换"不重建连接：每路会话各自持有一条 `RTCPeerConnection`，
/// 切换只改变 [_activeId]（哪个窗口高亮、指令发给谁），**不挂断任何一路** ——
/// 这正是"保持视频链接的情况下发送远程指令"的关键。
class MultiVideoScreen extends StatefulWidget {
  const MultiVideoScreen({super.key});

  @override
  State<MultiVideoScreen> createState() => _MultiVideoScreenState();
}

class _MultiVideoScreenState extends State<MultiVideoScreen> {
  final _svc = MultiCallService.instance;
  List<PairedEndpoint> _endpoints = const [];
  RemoteStore? _store;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    // 多会话服务按 callId 归属处理信令；来电仍由 CallService 负责。
    _svc.attach(RcEndpointService.instance.events);
    if (!mounted) return;
    setState(() {
      _store = store;
      _endpoints = store.paired();
    });
  }

  Future<void> _addDevice() async {
    final store = _store;
    if (store == null) {
      // 初始化未完成时点了 + 不能"没反应"。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在加载设备列表，请稍后再试')),
      );
      return;
    }
    final candidates =
        _endpoints.where((e) => _svc.sessionOf(e.deviceId) == null).toList();
    if (candidates.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可添加的设备（都已连接或尚未配对）')),
      );
      return;
    }
    final picked = await showDialog<PairedEndpoint>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('添加一路视频'),
        children: [
          for (final e in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e),
              child: Text(e.displayName),
            ),
        ],
      ),
    );
    if (picked == null) return;
    // ⚠️ 权限必须在**发起之前**问（与单路 `call_screen._call` 同一做法）。
    // 等 `getUserMedia` 失败再报错，用户看到的只是一句"连接失败"，
    // 根本不知道是权限问题（BUG-062 同形状：失败必须可诊断、不得静默）。
    // 本页固定 `video: true`（多路**视频**），故相机与麦克风都要。
    final status = await [Permission.microphone, Permission.camera].request();
    final blocked = callStartBlockFor(
      micGranted: status[Permission.microphone]?.isGranted ?? false,
      cameraGranted: status[Permission.camera]?.isGranted ?? false,
      video: true,
    );
    if (blocked != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(callStartBlockText(blocked))),
      );
      return;
    }
    final ok = await _svc.connect(picked, store);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('「${picked.displayName}」连接失败（端点离线或无法获取麦克风/摄像头）')),
      );
    }
  }

  Future<void> _sendActive(String cmd, Map<String, dynamic> payload) async {
    final store = _store;
    final s = _svc.activeSession;
    if (store == null || s == null) return;
    final ok = await RcEndpointService.instance.sendTo(
      s.peer,
      RcMessage.now(cmd, payload),
      store,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              ok ? '已向「${s.peer.displayName}」发送 $cmd' : '发送失败（端点离线，已暂存待发）')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('多设备视频'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加一路视频',
            onPressed: _addDevice,
          ),
          IconButton(
            icon: const Icon(Icons.call_end),
            tooltip: '全部挂断',
            onPressed: () => _svc.hangUpAll(),
          ),
        ],
      ),
      body: StreamBuilder<void>(
        stream: _svc.updates,
        builder: (context, _) {
          final sessions = _svc.sessions;
          if (sessions.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.grid_view, size: 56, color: scheme.outline),
                    const SizedBox(height: 12),
                    const Text('还没有视频连接'),
                    const SizedBox(height: 6),
                    Text(
                      '点右上角 + 添加设备，可同时连多台；'
                      '点某个窗口即切换为当前目标，其余保持连接。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            );
          }
          return Column(
            children: [
              Expanded(
                child: GridView.count(
                  crossAxisCount: sessions.length == 1 ? 1 : 2,
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  children: [
                    for (final s in sessions)
                      _VideoTile(
                        key: ValueKey(s.callId),
                        session: s,
                        active: s.peer.deviceId == _svc.activeId,
                        onTap: () => _svc.setActive(s.peer.deviceId),
                        onHangUp: () => _svc.hangUp(s.peer.deviceId),
                      ),
                  ],
                ),
              ),
              _CommandBar(
                session: _svc.activeSession,
                onPing: () => _sendActive(RcCmd.ping, const {}),
                onStatus: () => _sendActive(RcCmd.deviceStatus, const {}),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 单个视频窗口。
class _VideoTile extends StatefulWidget {
  const _VideoTile({
    super.key,
    required this.session,
    required this.active,
    required this.onTap,
    required this.onHangUp,
  });

  final MultiCallSession session;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onHangUp;

  @override
  State<_VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<_VideoTile> {
  final _renderer = RTCVideoRenderer();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _renderer.initialize();
    if (!mounted) return;
    setState(() {
      _renderer.srcObject = widget.session.remoteStream;
      _ready = true;
    });
  }

  @override
  void didUpdateWidget(covariant _VideoTile old) {
    super.didUpdateWidget(old);
    // 远端流是异步到达的（onTrack），到达后要贴到渲染器上。
    if (old.session.remoteStream != widget.session.remoteStream) {
      _renderer.srcObject = widget.session.remoteStream;
    }
  }

  @override
  void dispose() {
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.session;
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.active ? scheme.primary : scheme.outlineVariant,
            width: widget.active ? 3 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: _ready && s.remoteStream != null
                  ? RTCVideoView(_renderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                  : Center(
                      child: Text(
                        s.phase == MultiCallPhase.connected
                            ? '已连接（等待画面）'
                            : multiCallStatusText(s.phase, failure: s.failure),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
            ),
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
                color: Colors.black54,
                child: Text(
                  '${s.peer.displayName}${widget.active ? ' · 当前' : ''}',
                  style: AppText.bodySmall.copyWith(color: Colors.white),
                ),
              ),
            ),
            Positioned(
              right: 2,
              top: 2,
              child: IconButton(
                icon: const Icon(Icons.call_end, size: 18),
                color: Colors.white,
                tooltip: '挂断这一路',
                onPressed: widget.onHangUp,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部指令条：对**当前窗口**那台设备发指令（视频保持连接）。
class _CommandBar extends StatelessWidget {
  const _CommandBar({required this.session, this.onPing, this.onStatus});

  final MultiCallSession? session;
  final VoidCallback? onPing;
  final VoidCallback? onStatus;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: Text(
              s == null ? '未选择设备' : '当前目标：${s.peer.displayName}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: s == null ? null : onPing,
            icon: const Icon(Icons.network_ping),
            label: const Text('ping'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: s == null ? null : onStatus,
            icon: const Icon(Icons.info_outline),
            label: const Text('取状态'),
          ),
        ],
      ),
    );
  }
}
