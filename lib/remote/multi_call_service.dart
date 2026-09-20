import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import 'call_service.dart' show CallService;
import 'endpoint_service.dart';
import 'protocol.dart';
import 'remote_store.dart';

/// 多路会话中单个连接的状态。
enum MultiCallPhase { connecting, connected, failed, closed }

/// 事件路由：只处理**自己拥有**的 callId，其余一律不碰。
///
/// 为什么单独抽成纯函数：多会话服务与既有的单会话 `CallService`
/// **共用同一条事件流**。判错（把别人的 callId 当成自己的）会让两个服务
/// 同时处理同一条信令 —— 症状是随机掉线、两端状态打架，属于**静默**错误，
/// 只能靠锁。抽成纯函数后这条边界可以在 host 单测里逐条断言。
String? ownedCallIdOf(Map<String, dynamic> m, Set<String> owned) {
  // ⚠️ 不能用 `m['callId'] as String?`：远端报文字段类型**不可信**，
  // 收到非 String（如数字）时 `as` 会**抛异常**，把"忽略一条无关信令"
  // 变成"整条事件流处理崩溃"。用 `is` 判定则天然不抛（MCS-04 锁住）。
  final raw = m['callId'];
  if (raw is! String || raw.isEmpty) return null;
  return owned.contains(raw) ? raw : null;
}

/// 当前会话结束后该聚焦谁。
///
/// 规则：当前仍在列表里 → 保持不变（不要因为别人挂断就跳窗口）；
/// 否则取第一条；空列表 → null（不聚焦任何窗口）。
String? nextActiveId(List<String> ids, String? current) {
  if (ids.isEmpty) return null;
  if (current != null && ids.contains(current)) return current;
  return ids.first;
}

/// 窗口状态文案。
///
/// 抽成纯函数：展示类逻辑**写错不会抛异常**，只会显示成空白/错误的话，
/// 因此必须逐档位可断言（项目纪律：展示类只能靠锁）。
/// 用 **switch 表达式**（必须穷尽）→ 将来新增 phase 忘补文案会编译报错。
String multiCallStatusText(MultiCallPhase phase, {String? failure}) =>
    switch (phase) {
      MultiCallPhase.connecting => '连接中…',
      MultiCallPhase.connected => '已连接',
      MultiCallPhase.failed => failure ?? '连接失败',
      MultiCallPhase.closed => '已挂断',
    };

/// 一路会话（一个端点一条 PeerConnection）。
class MultiCallSession {
  MultiCallSession({required this.callId, required this.peer});

  final String callId;
  final PairedEndpoint peer;
  RTCPeerConnection? pc;
  MediaStream? remoteStream;
  MultiCallPhase phase = MultiCallPhase.connecting;
  String? failure;
}

/// 多路视频同连（主控视角：同时连多台设备，点窗口切换目标）。
///
/// ⚠️ 与 `CallService` 的分工（刻意不合并）：
/// - `CallService`：**单会话**，继续负责**来电**（被叫、振铃、自动接通）；
/// - 本服务：**多会话**，只负责**本机发起**的若干路 outbound 连接。
///
/// 两者共用同一条事件流，靠 `ownedCallIdOf` 按 callId 归属隔离：
/// 本服务只处理自己的 callId，来电 invite 不带本服务的 callId，因此不会
/// 出现"两个服务抢同一条信令"。这样既不必重构 630 行的 `CallService`，
/// 也不会让来电路径承担并发风险。
class MultiCallService {
  MultiCallService._();

  static final MultiCallService instance = MultiCallService._();

  /// deviceId → 会话（一台设备一路）。
  final _sessions = <String, MultiCallSession>{};

  /// callId → deviceId（事件路由用）。
  final _byCallId = <String, String>{};

  final _updates = StreamController<void>.broadcast();

  MediaStream? _localStream;
  String? _activeId;
  StreamSubscription<Map<String, dynamic>>? _evtSub;

  /// 会话变化（增删改、状态迁移）通知。
  Stream<void> get updates => _updates.stream;

  List<MultiCallSession> get sessions =>
      _sessions.values.toList(growable: false);

  /// 当前聚焦的窗口（发指令的目标）。
  String? get activeId => _activeId;

  MultiCallSession? sessionOf(String deviceId) => _sessions[deviceId];

  MultiCallSession? get activeSession =>
      _activeId == null ? null : _sessions[_activeId];

  bool isConnected(String deviceId) =>
      _sessions[deviceId]?.phase == MultiCallPhase.connected;

  /// 订阅端点事件流。只处理属于本服务的 callId。
  void attach(Stream<Map<String, dynamic>> events) {
    _evtSub?.cancel();
    _evtSub = events.listen(_onRemoteEvent);
  }

  void _onRemoteEvent(Map<String, dynamic> m) {
    final callId = ownedCallIdOf(m, _byCallId.keys.toSet());
    if (callId == null) return; // 别人的（含来电）→ 不碰
    final deviceId = _byCallId[callId];
    if (deviceId == null) return;
    final s = _sessions[deviceId];
    if (s == null) return;
    final type = m['type'] as String? ?? '';
    if (type == RcCmd.callAnswer) {
      final sdp = m['sdp'] as String? ?? '';
      final kind = m['sdpType'] as String? ?? m['kind'] as String? ?? 'answer';
      unawaited(_applyAnswer(s, sdp, kind));
    } else if (type == RcCmd.callCandidate) {
      final c = m['candidate'];
      if (c is Map) unawaited(_applyCandidate(s, c.cast<String, dynamic>()));
    } else if (type == RcCmd.callEnd) {
      unawaited(hangUp(deviceId));
    }
  }

  Future<void> _applyAnswer(
      MultiCallSession s, String sdp, String kind) async {
    final pc = s.pc;
    if (pc == null || sdp.isEmpty) return;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, kind));
    } on Object {
      // 信令异常：标记失败，让 UI 能显示"这路没连上"，而不是停在"连接中"。
      s.phase = MultiCallPhase.failed;
      s.failure = '应答信令处理失败';
      _notify();
    }
  }

  Future<void> _applyCandidate(
      MultiCallSession s, Map<String, dynamic> c) async {
    final pc = s.pc;
    if (pc == null) return;
    try {
      await pc.addCandidate(RTCIceCandidate(
        c['candidate'] as String? ?? '',
        c['sdpMid'] as String?,
        (c['sdpMLineIndex'] as num?)?.toInt(),
      ));
    } on Object {
      // 单个候选失败不影响整路，忽略（ICE 会继续尝试其他候选）。
    }
  }

  /// 连接一台设备（发起一路 outbound 会话）。
  ///
  /// 返回 false 表示**没能发出** invite（缺本地媒体 / 建 PC 失败 / 端点离线）。
  /// 注意：返回 true 只代表 invite 已发出，不代表已连通 —— 连通看
  /// [MultiCallSession.phase]。
  Future<bool> connect(PairedEndpoint peer, RemoteStore store,
      {bool video = true}) async {
    final deviceId = peer.deviceId;
    if (_sessions.containsKey(deviceId)) return false; // 已有一路
    if (_localStream == null && !await _ensureLocalStream(video: video)) {
      return false;
    }
    final s = MultiCallSession(callId: const Uuid().v4(), peer: peer);
    _sessions[deviceId] = s;
    _byCallId[s.callId] = deviceId;
    _activeId ??= deviceId;
    _notify();

    try {
      final pc = s.pc = await createPeerConnection({
        'iceServers': await CallService.iceServers(),
        'sdpSemantics': 'unified-plan',
      });
      // 复用同一条本地流：为 N 路各开一次摄像头既耗资源，
      // 也会在部分机型上直接失败（相机被占用）。
      _localStream?.getTracks().forEach(pc.addTrack);
      pc.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          s.remoteStream = event.streams.first;
          _notify();
        }
      };
      pc.onConnectionState = (state) {
        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            s.phase = MultiCallPhase.connected;
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            s.phase = MultiCallPhase.failed;
            s.failure = '连接失败（多处于对称 NAT 时需配置 TURN）';
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            if (s.phase != MultiCallPhase.failed) {
              s.phase = MultiCallPhase.closed;
            }
          default:
            break;
        }
        _notify();
      };
      pc.onIceCandidate = (c) {
        if (c.candidate == null) return;
        unawaited(_send(peer, RcCmd.callCandidate, {
          'callId': s.callId,
          'candidate': {
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        }, store));
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      final desc = await pc.getLocalDescription();
      final sent = await _send(peer, RcCmd.callInvite, {
        'callId': s.callId,
        'video': video,
        'sdp': desc?.sdp ?? '',
        'type': desc?.type ?? 'offer',
        'fromName': store.deviceName,
      }, store);
      if (!sent) {
        // 端点离线：实时通话不能用 outbox 暂存，直接判失败。
        s.phase = MultiCallPhase.failed;
        s.failure = '端点离线，无法发起通话';
        _notify();
        await hangUp(deviceId);
        return false;
      }
      return true;
    } on Object {
      s.phase = MultiCallPhase.failed;
      s.failure = '建立连接失败';
      _notify();
      await hangUp(deviceId);
      return false;
    }
  }

  Future<bool> _ensureLocalStream({required bool video}) async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video':
            video ? {'facingMode': 'user', 'width': 640, 'height': 480} : false,
      });
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> _send(PairedEndpoint peer, String type,
      Map<String, dynamic> payload, RemoteStore store) async {
    return RcEndpointService.instance.sendTo(
      peer,
      RcMessage.now(type, payload),
      store,
      enqueueOnFail: false,
    );
  }

  /// 挂断一路（不影响其它路 —— 这是"保持视频链接"的关键）。
  Future<void> hangUp(String deviceId) async {
    final s = _sessions.remove(deviceId);
    if (s == null) return;
    _byCallId.remove(s.callId);
    try {
      await s.pc?.close();
    } on Object {
      // 关闭失败也要把状态清干净，不能留一路"僵尸会话"。
    }
    s.phase = MultiCallPhase.closed;
    if (_sessions.isEmpty) {
      _localStream?.getTracks().forEach((t) => unawaited(t.stop()));
      _localStream = null;
    }
    _activeId = nextActiveId(_sessions.keys.toList(), _activeId);
    _notify();
  }

  Future<void> hangUpAll() async {
    for (final id in _sessions.keys.toList()) {
      await hangUp(id);
    }
  }

  /// 切换当前聚焦的窗口（**不挂断任何一路**）。
  void setActive(String deviceId) {
    if (!_sessions.containsKey(deviceId)) return;
    _activeId = deviceId;
    _notify();
  }

  void _notify() {
    if (!_updates.isClosed) _updates.add(null);
  }

  Future<void> dispose() async {
    await _evtSub?.cancel();
    _evtSub = null;
    await hangUpAll();
    await _updates.close();
  }
}
