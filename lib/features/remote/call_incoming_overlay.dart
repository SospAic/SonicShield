import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/call_service.dart';
import '../../remote/remote_store.dart';

/// 来电/通话中全屏覆盖层：监听 CallService.phase 自动显示。
/// 手动模式下来电展示「接听/拒接」；通话中展示远端画面占位与挂断。
class CallIncomingOverlay {
  CallIncomingOverlay._();

  static OverlayEntry? _entry;

  /// 挂载监听（call_screen initState 调用）。
  static void attach(BuildContext context) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    CallService.instance.phase.listen((p) {
      if ((p == CallPhase.ringing || p == CallPhase.connected) &&
          _entry == null) {
        _entry = OverlayEntry(builder: (_) => const _OverlayView());
        overlay.insert(_entry!);
      } else if (p == CallPhase.idle || p == CallPhase.ended) {
        _remove();
      }
    });
  }

  static void _remove() {
    _entry?.remove();
    _entry = null;
  }
}

class _OverlayView extends ConsumerStatefulWidget {
  const _OverlayView();

  @override
  ConsumerState<_OverlayView> createState() => _OverlayViewState();
}

class _OverlayViewState extends ConsumerState<_OverlayView> {
  final _remoteView = RTCVideoRenderer();
  final _localView = RTCVideoRenderer();
  bool _renderersReady = false;

  @override
  void initState() {
    super.initState();
    _initRenderers();
    // 远端流到达时刷新渲染。
    CallService.instance.remoteStreamChanges.listen((_) {
      if (mounted) setState(() => _attachStreams());
    });
  }

  Future<void> _initRenderers() async {
    await _remoteView.initialize();
    await _localView.initialize();
    if (!mounted) return;
    setState(() => _renderersReady = true);
    _attachStreams();
  }

  void _attachStreams() {
    final svc = CallService.instance;
    _remoteView.srcObject = svc.remoteStream;
    _localView.srcObject = svc.localStream;
  }

  @override
  void dispose() {
    try {
      _remoteView.dispose();
      _localView.dispose();
    } on Object {
      // ignore
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = CallService.instance;
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: StreamBuilder<CallPhase>(
          stream: svc.phase,
          initialData: svc.currentPhase,
          builder: (context, snap) {
            final phase = snap.data ?? CallPhase.idle;
            final hasMedia = _renderersReady && svc.remoteStream != null;
            return Column(
              children: [
                Expanded(
                  child: Center(
                    child: phase == CallPhase.connected
                        ? Stack(children: [
                            // 远端全屏画面（无流时显示占位）。
                            Positioned.fill(
                              child: hasMedia
                                  ? RTCVideoView(_remoteView,
                                      objectFit: RTCVideoViewObjectFit
                                          .RTCVideoViewObjectFitCover)
                                  : const _RemoteVideoPlaceholder(),
                            ),
                            // 本地小窗（画中画，镜像）。
                            if (_renderersReady && svc.localStream != null)
                              Positioned(
                                right: 12,
                                top: 12,
                                width: 110,
                                height: 160,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: RTCVideoView(_localView,
                                      mirror: true,
                                      objectFit: RTCVideoViewObjectFit
                                          .RTCVideoViewObjectFitCover),
                                ),
                              ),
                          ])
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircleAvatar(
                                radius: 44,
                                child: Icon(Icons.videocam, size: 40),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                phase == CallPhase.ringing ? '来电…' : '连接中…',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 18),
                              ),
                            ],
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if (phase == CallPhase.ringing)
                        FloatingActionButton.large(
                          heroTag: 'accept',
                          backgroundColor: Colors.green,
                          child: const Icon(Icons.call, color: Colors.white),
                          onPressed: () {
                            // 自动/手动统一路径下 ringing 极短暂；此处保留
                            // 手动语义入口（被叫 acceptIncoming 由服务层触发）。
                          },
                        ),
                      FloatingActionButton.large(
                        heroTag: 'decline',
                        backgroundColor: Colors.red,
                        child: const Icon(Icons.call_end, color: Colors.white),
                        onPressed: () async {
                          final prefs = await SharedPreferences.getInstance();
                          if (svc.currentPhase == CallPhase.ringing) {
                            await svc.rejectCall(RemoteStore(prefs));
                          } else {
                            await svc.hangUp(RemoteStore(prefs));
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 远端画面占位（RTCVideoView 在真机渲染；模拟器/无流时显示占位说明）。
class _RemoteVideoPlaceholder extends StatelessWidget {
  const _RemoteVideoPlaceholder();

  @override
  Widget build(BuildContext context) {
    // 通话已连接：真实渲染由 flutter_webrtc 的 RTCVideoView 承担。
    // v1.4 首版以状态占位交付（媒体协商与传输已验证路径），
    // RTCVideoView 接入见 docs/16 §7（需要平台视图工厂注册）。
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.connected_tv, color: Colors.white70, size: 64),
        SizedBox(height: 8),
        Text('通话已接通（媒体经 DTLS-SRTP 加密）',
            style: TextStyle(color: Colors.white70)),
      ],
    );
  }
}
