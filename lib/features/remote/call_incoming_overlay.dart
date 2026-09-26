import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_keys.dart';
import '../../remote/call_lifecycle.dart';
import '../../remote/call_service.dart';
import '../../remote/remote_store.dart';

/// 通话 UI 宿主：挂在 `MaterialApp.builder` 上，**始终位于所有路由之上**。
///
/// ## 为什么不再用 `OverlayEntry`（v1.4 的做法）
///
/// `OverlayEntry` 需要先拿到 `Overlay`，而唯一能拿到它的地方是
/// "某个**已挂载页面**的 context"。原来的实现挂在通话页的 `initState`，
/// 于是 —— **没进过通话页就永远收不到来电界面**。
///
/// 被叫侧尤其致命：**人不在那个页面上，这通电话就接不了**
/// （只能看着它响到超时）。而这恰好和 BUG-056 纠缠在一起：
/// 之前"看起来能用"只是因为 `onManualRing` 会**立刻代为接通**，
/// 把"没有接听界面"这件事盖住了。一旦把自动接通关掉（BUG-056 的修复），
/// 缺失的接听界面就立刻暴露成"来电全部无人接听"。
///
/// 挂在 `builder` 上之后，来电界面与"当前在哪个路由"完全无关。
class CallOverlayHost extends ConsumerStatefulWidget {
  const CallOverlayHost({super.key, required this.child});

  final Widget? child;

  @override
  ConsumerState<CallOverlayHost> createState() => _CallOverlayHostState();
}

class _CallOverlayHostState extends ConsumerState<CallOverlayHost> {
  StreamSubscription<CallPhase>? _phaseSub;
  StreamSubscription<CallEndReason>? _endSub;
  CallPhase _phase = CallService.instance.currentPhase;

  @override
  void initState() {
    super.initState();
    _phaseSub = CallService.instance.phase.listen((p) {
      if (mounted) setState(() => _phase = p);
    });
    // 通话结束/未接时把原因说出来。宿主**常驻**，所以主叫就算中途
    // 退到别的页面也收得到"对方无应答"（BUG-050 的用户可见收益）。
    _endSub = CallService.instance.callEnded.listen(showEndNotice);
  }

  @override
  void dispose() {
    _phaseSub?.cancel();
    _endSub?.cancel();
    super.dispose();
  }

  /// 通话结束时把原因说出来（BUG-050）。
  ///
  /// 判断该不该弹的规则在 [shouldNotifyEnd]（纯函数、宿主机可断言）：
  /// 本端自己刚点的"挂断/拒接"不再弹（噪音），
  /// 未接/被拒/占线/对方挂断/失败**必须**弹 ——
  /// 否则又回到"无声无息退回上一页"。
  static void showEndNotice(CallEndReason r) {
    if (!shouldNotifyEnd(r)) return;
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(callEndText(r)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ 必须覆盖 `connecting`：被叫点「接听」后 phase 从 ringing → connecting，
    // 若这里只认 ringing/connected，覆盖层会在**整段"协商中"**消失、
    // 到 connected 才回来 —— 用户点完接听界面突然不见了，看起来像应用崩了。
    // 通话界面覆盖"除 idle/ended 之外"的全部阶段。
    final showCall = _phase != CallPhase.idle && _phase != CallPhase.ended;
    // ⚠️ 必须用 `Stack` 把 `child` **留在树里**，不能直接 return 通话界面 ——
    // 后者会把 Navigator 整个卸载掉，通话结束后导航栈被重置回初始路由。
    //
    // `alignment` 显式用非方向性的 `Alignment.topLeft`：默认的
    // `AlignmentDirectional` 需要 `Directionality`，而 `builder` 处在
    // 应用根部、不保证有这个祖先。
    return Stack(
      alignment: Alignment.topLeft,
      fit: StackFit.expand,
      children: [
        widget.child ?? const SizedBox.shrink(),
        if (showCall) const _CallView(),
      ],
    );
  }
}

/// 来电/通话中的全屏界面。
///
/// 手动模式下来电展示「接听/拒接」；通话中展示远端画面占位与挂断。
/// 只在通话期间构建 —— 两个 `RTCVideoRenderer` 的开销不落在应用启动路径上。
class _CallView extends ConsumerStatefulWidget {
  const _CallView();

  @override
  ConsumerState<_CallView> createState() => _CallViewState();
}

class _CallViewState extends ConsumerState<_CallView> {
  final _remoteView = RTCVideoRenderer();
  final _localView = RTCVideoRenderer();
  bool _renderersReady = false;
  StreamSubscription<MediaStream?>? _streamSub;
  StreamSubscription<RemoteCallState>? _remoteStateSub;

  @override
  void initState() {
    super.initState();
    _initRenderers();
    // 远端流到达时刷新渲染。
    _streamSub = CallService.instance.remoteStreamChanges.listen((_) {
      if (mounted) setState(() => _attachStreams());
    });
    // 对端 `rc.call` 状态变化（"对方振铃中…"）——BUG-050 前无人消费。
    _remoteStateSub = CallService.instance.remoteStateChanges.listen((_) {
      if (mounted) setState(() {});
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
    _streamSub?.cancel();
    _remoteStateSub?.cancel();
    try {
      _remoteView.dispose();
      _localView.dispose();
    } on Object {
      // ignore
    }
    super.dispose();
  }

  /// 挂断 / 拒接。
  ///
  /// 振铃中点"拒绝"走 [CallService.declinePending]（拒接，对端显示"对方已拒接"）；
  /// 已接通走 [CallService.hangUp]（挂断）。
  Future<void> _endCall() async {
    final svc = CallService.instance;
    if (svc.currentPhase == CallPhase.ringing) {
      await svc.declinePending();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await svc.hangUp(RemoteStore(prefs));
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
                                phase == CallPhase.ringing
                                    ? '来电…'
                                    : connectingText(svc.remoteState),
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
                      // 「接听」只在真正振铃时出现，且**只对来电方**有意义。
                      // 主叫侧振铃阶段没有"接听"这个动作。
                      if (phase == CallPhase.ringing && !svc.isCaller)
                        FloatingActionButton.large(
                          heroTag: 'accept',
                          backgroundColor: Colors.green,
                          child: const Icon(Icons.call, color: Colors.white),
                          // ⚠️ 这里**必须**走 acceptPending()（用暂存的 invite），
                          // 不能退回"收到 invite 就代为接通"的老回调 ——
                          // 那正是 BUG-056（开关关掉也照样接通）。
                          onPressed: () => CallService.instance.acceptPending(),
                        ),
                      FloatingActionButton.large(
                        heroTag: 'decline',
                        backgroundColor: Colors.red,
                        onPressed: _endCall,
                        child: const Icon(Icons.call_end, color: Colors.white),
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
