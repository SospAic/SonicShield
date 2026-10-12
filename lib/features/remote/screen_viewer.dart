import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme.dart';
import '../../remote/call_service.dart';
import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';

/// 远程桌面级控制（docs/61 §5 P3）：控制端**观看 + 手势注入**。
///
/// 画面来自 WebRTC 远端流（`CallService.remoteStream`，屏幕共享会话）；
/// 手势按**归一化 0..1** 坐标经 `input.tap` / `input.swipe` 下发 ——
/// 端点按真实像素换算，故控制端**无需知道**端点分辨率，旋转/分辨率变化不失效
/// （docs/61 §4.1 坐标口径）。
///
/// ## 前提（任一不满足都会"看着像连上了却控制不了"）
/// - 会话是 `kind:'screen'`（P2）。⚠️ `getDisplayMedia` 的 MediaProjection token
///   交接**尚未真机验证**（docs/24 R12）—— 在 spike 通过前，本页的画面可能起不来；
/// - 端点须已开启**无障碍**，否则每条注入都会收到 `rc.inputAck{ok:false}`
///   （端点侧不静默降级，本页把 `_last` 如实显示）。
///
/// ## 红线（docs/61 §1）
/// 本页必须让控制端**明白**：这是**对方可见**的实时屏幕，不是隐蔽能力
/// （顶部状态条固定显示该文案）。
class ScreenViewerScreen extends ConsumerStatefulWidget {
  const ScreenViewerScreen({
    super.key,
    required this.endpoint,
    required this.castId,
  });

  final PairedEndpoint endpoint;
  final String castId;

  @override
  ConsumerState<ScreenViewerScreen> createState() => _ScreenViewerScreenState();
}

class _ScreenViewerScreenState extends ConsumerState<ScreenViewerScreen> {
  final RTCVideoRenderer _remote = RTCVideoRenderer();
  bool _ready = false;
  bool _hasMedia = false;
  String _last = '等待画面…';

  /// 手势起点 / 终点（归一化前的本地像素）。只在 `onPanEnd` 下发**一条** swipe。
  Offset? _panStart;
  Offset? _panLast;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _remote.initialize();
    if (!mounted) return;
    setState(() => _ready = true);
    final cur = CallService.instance.remoteStream;
    if (cur != null) {
      _remote.srcObject = cur;
      setState(() {
        _hasMedia = true;
        _last = '已收到画面';
      });
    }
    CallService.instance.remoteStreamChanges.listen((s) {
      if (!mounted) return;
      _remote.srcObject = s;
      setState(() {
        _hasMedia = s != null;
        _last = s != null ? '已收到画面' : '画面已中断';
      });
    });
  }

  @override
  void dispose() {
    _remote.dispose();
    super.dispose();
  }

  Future<void> _send(String type, Map<String, dynamic> payload) async {
    final store = RemoteStore(await SharedPreferences.getInstance());
    await RcEndpointService.instance
        .sendTo(widget.endpoint, RcMessage.now(type, payload), store);
  }

  double _nx(double dx, double w) => w <= 0 ? 0 : (dx / w).clamp(0.0, 1.0);

  void _tap(Offset p, Size box) {
    final x = _nx(p.dx, box.width);
    final y = _nx(p.dy, box.height);
    _send(RcCmd.inputTap, {'castId': widget.castId, 'x': x, 'y': y});
    if (mounted) {
      setState(() => _last =
          'tap ${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}（等待回执…）');
    }
  }

  void _swipe(Offset a, Offset b, Size box) {
    _send(RcCmd.inputSwipe, {
      'castId': widget.castId,
      'x1': _nx(a.dx, box.width),
      'y1': _nx(a.dy, box.height),
      'x2': _nx(b.dx, box.width),
      'y2': _nx(b.dy, box.height),
      'durationMs': 220,
    });
    if (mounted) setState(() => _last = 'swipe（等待回执…）');
  }

  Future<void> _stop() async {
    await _send(RcCmd.screenCastStop, {'castId': widget.castId});
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('远程控制 · ${widget.endpoint.name}'),
        actions: [
          TextButton.icon(
            onPressed: _stop,
            icon: const Icon(Icons.stop_screen_share_outlined),
            label: const Text('停止'),
          ),
        ],
      ),
      body: Column(
        children: [
          // 红线文案：控制端必须知道这是**对方可见**的实时屏幕。
          Container(
            width: double.infinity,
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              '对方设备可见本次操作指示，且可随时停止',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final box = Size(c.maxWidth, c.maxHeight);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _tap(d.localPosition, box),
                  // 只在**起点/终点**各记一次，`onPanEnd` 才下发 —— 避免每帧发命令。
                  onPanStart: (d) => _panStart = d.localPosition,
                  onPanUpdate: (d) => _panLast = d.localPosition,
                  onPanCancel: () {
                    _panStart = null;
                    _panLast = null;
                  },
                  onPanEnd: (_) {
                    final a = _panStart;
                    final b = _panLast;
                    if (a != null && b != null) _swipe(a, b, box);
                    _panStart = null;
                    _panLast = null;
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_ready && _hasMedia)
                        RTCVideoView(
                          _remote,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                        )
                      else
                        Center(
                          child: Text(
                            _last,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: Text(
                          _last,
                          style: AppText.bodySmall.copyWith(
                              color: Colors.white70),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
