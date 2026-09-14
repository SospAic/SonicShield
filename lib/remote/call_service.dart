import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'endpoint_service.dart';
import 'protocol.dart';
import 'remote_store.dart';

/// 通话会话状态。
enum CallPhase { idle, ringing, connecting, connected, ended }

/// 视频通话服务（v1.4，方案 A：WebRTC P2P + MQTT E2EE 信令，docs/16）。
///
/// 角色：
/// - 主叫（caller）：createOffer → call.invite(SDP) → 收 answer → ICE 互通
/// - 被叫（callee）：收 invite →（自动接通开启时）createAnswer → 回 answer
///
/// 媒体：getUserMedia（video+audio），DTLS-SRTP 传输加密（WebRTC 内建），
/// 信令走声盾 MQTT 端到端加密通道（复用 RcCodec）。
/// ICE：Google 公共 STUN；对称 NAT 场景需自建 TURN（文档说明，v1 不内置）。
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  static const _iceServers = <Map<String, dynamic>>[
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _callId;
  PairedEndpoint? _peer;
  bool _isCaller = false;
  bool _video = true;
  CallPhase _phase = CallPhase.idle;

  final _phaseCtrl = StreamController<CallPhase>.broadcast();
  Stream<CallPhase> get phase => _phaseCtrl.stream;
  CallPhase get currentPhase => _phase;
  String? get callId => _callId;
  bool get inCall => _phase != CallPhase.idle && _phase != CallPhase.ended;

  /// 远端媒体流（UI 渲染用）。
  MediaStream? get remoteStream => _remoteStream;
  MediaStream? _remoteStream;
  final _remoteCtrl = StreamController<MediaStream?>.broadcast();
  Stream<MediaStream?> get remoteStreamChanges => _remoteCtrl.stream;

  MediaStream? get localStream => _localStream;

  // ---------------- 自动接通配置（合规：家人守护定位，见 docs/16 §6） ----------------

  static const _kAutoAnswer = 'rc_call_auto_answer';

  static Future<bool> autoAnswerEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kAutoAnswer) ?? false;

  static Future<void> setAutoAnswer(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kAutoAnswer, v);

  // ---------------- 主叫 ----------------

  /// 发起呼叫。返回 callId；连接失败返回 null。
  Future<String?> startCall(PairedEndpoint endpoint, RemoteStore store,
      {bool video = true}) async {
    if (inCall) return null;
    _isCaller = true; // 主叫标记（onAnswer 守卫用）
    _video = video;
    _peer = endpoint;
    _callId = const Uuid().v4();
    _setPhase(CallPhase.connecting);

    final ok = await _ensureMedia(video: video);
    if (!ok) {
      await _teardown();
      return null;
    }
    await _createPc();

    try {
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
    } on Object {
      await _teardown();
      return null;
    }

    final desc = await _pc!.getLocalDescription();
    final sent = await RcEndpointService.instance.sendTo(
      endpoint,
      RcMessage.now(RcCmd.callInvite, {
        'callId': _callId,
        'video': video,
        'sdp': desc?.sdp ?? '',
        'type': desc?.type ?? 'offer',
        'fromName': store.deviceName,
      }),
      store,
    );
    if (!sent) {
      await _teardown();
      return null; // 端点离线（outbox 不适用于实时通话）
    }
    return _callId;
  }

  // ---------------- 被叫（含自动接通） ----------------

  /// 收到 invite：自动接通开启则直接 answer，否则交由 UI 手动接听。
  /// 返回 true 表示已开始接通流程。
  Future<bool> onIncomingCall(
      Map<String, dynamic> payload, PairedEndpoint peer, RemoteStore store,
      {void Function(String callId, String fromName, bool video)?
          onManualRing}) async {
    if (inCall) {
      // 占线：直接回 end，主叫立刻得到反馈。
      await _sendCallMsg(RcCmd.callEnd,
          {'callId': payload['callId'], 'reason': 'busy'}, peer, store);
      return false;
    }
    _isCaller = false;
    _peer = peer;
    _callId = payload['callId'] as String;
    _video = payload['video'] as bool? ?? true;
    _setPhase(CallPhase.ringing);

    final auto = await autoAnswerEnabled();
    if (!auto) {
      onManualRing?.call(
          _callId!, payload['fromName'] as String? ?? peer.name, _video);
      return true; // UI 弹来电界面，等待用户操作
    }
    return await acceptIncoming(payload, peer, store);
  }

  /// 接通来电（自动或手动）。
  Future<bool> acceptIncoming(
      Map<String, dynamic> payload, PairedEndpoint peer, RemoteStore store,
      {bool video = true}) async {
    if (_phase != CallPhase.ringing) return false;
    _setPhase(CallPhase.connecting);

    final ok = await _ensureMedia(video: _video);
    if (!ok) {
      await _sendCallMsg(
          RcCmd.callEnd, {'callId': _callId, 'reason': 'media'}, peer, store);
      await _teardown();
      return false;
    }
    await _createPc();

    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(
        payload['sdp'] as String,
        payload['type'] as String? ?? 'offer',
      ));
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _sendCallMsg(
          RcCmd.callAnswer,
          {
            'callId': _callId,
            'sdp': answer.sdp,
            'type': answer.type,
          },
          peer,
          store);
      return true;
    } on Object {
      await _teardown();
      return false;
    }
  }

  /// 拒接（仅手动流程）。
  Future<void> rejectCall(RemoteStore store) async {
    if (_phase != CallPhase.ringing || _peer == null) return;
    await _sendCallMsg(RcCmd.callEnd, {'callId': _callId, 'reason': 'rejected'},
        _peer!, store);
    await _teardown();
  }

  // ---------------- 信令处理（由 endpoint_service 分派调用） ----------------

  /// 主叫收到 answer。
  Future<void> onAnswer(Map<String, dynamic> payload) async {
    if (!_isCaller ||
        _phase != CallPhase.connecting ||
        payload['callId'] != _callId) {
      return;
    }
    try {
      await _pc?.setRemoteDescription(RTCSessionDescription(
        payload['sdp'] as String,
        payload['type'] as String? ?? 'answer',
      ));
    } on Object {
      await _teardown();
    }
  }

  /// 双向 ICE candidate。
  Future<void> onCandidate(Map<String, dynamic> payload) async {
    if (payload['callId'] != _callId || _pc == null) return;
    try {
      final c = (payload['candidate'] as Map).cast<String, dynamic>();
      await _pc!.addCandidate(RTCIceCandidate(
        c['candidate'] as String?,
        c['sdpMid'] as String?,
        (c['sdpMLineIndex'] as num?)?.toInt() ?? 0,
      ));
    } on Object {
      // 忽略无效 candidate
    }
  }

  /// 对端挂断/占线/拒接。
  Future<void> onRemoteEnd() async {
    await _teardown();
  }

  // ---------------- 挂断 ----------------

  Future<void> hangUp(RemoteStore store) async {
    if (_peer != null && _phase != CallPhase.idle) {
      await _sendCallMsg(RcCmd.callEnd, {'callId': _callId, 'reason': 'hangup'},
          _peer!, store);
    }
    await _teardown();
  }

  // ---------------- 内部 ----------------

  Future<bool> _ensureMedia({required bool video}) async {
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

  Future<void> _createPc() async {
    final pc = _pc = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _localStream?.getTracks().forEach(pc.addTrack);
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        _remoteCtrl.add(_remoteStream);
      }
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setPhase(CallPhase.connected);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(_teardown());
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        unawaited(_teardown());
      }
    };
    pc.onIceCandidate = (c) {
      if (c.candidate != null && _peer != null && _callId != null) {
        _storeRef
            ?.call()
            .then((store) => _sendCallMsg(
                  RcCmd.callCandidate,
                  {
                    'callId': _callId,
                    'candidate': {
                      'candidate': c.candidate,
                      'sdpMid': c.sdpMid,
                      'sdpMLineIndex': c.sdpMLineIndex,
                    },
                  },
                  _peer!,
                  store,
                ))
            .catchError((Object _) {});
      }
    };
  }

  /// store 提供者（由 UI/引擎注入，避免服务层直接依赖插件初始化时序）。
  static Future<RemoteStore> Function()? _storeRef;
  static void bindStore(Future<RemoteStore> Function() ref) => _storeRef = ref;

  Future<void> _sendCallMsg(String type, Map<String, dynamic> payload,
      PairedEndpoint peer, RemoteStore store) async {
    await RcEndpointService.instance.sendTo(
        peer, RcMessage.now(type, payload), store,
        enqueueOnFail: false);
  }

  void _setPhase(CallPhase p) {
    _phase = p;
    if (!_phaseCtrl.isClosed) _phaseCtrl.add(p);
  }

  Future<void> _teardown() async {
    try {
      await _pc?.close();
      await _pc?.dispose();
    } on Object {
      // ignore
    }
    _pc = null;
    try {
      _localStream?.getTracks().forEach((t) => t.stop());
    } on Object {
      // ignore
    }
    _localStream = null;
    _remoteStream = null;
    _remoteCtrl.add(null);
    _setPhase(CallPhase.ended);
    _callId = null;
    _peer = null;
    // 归位（下一次呼叫从 idle 开始）。
    scheduleMicrotask(() {
      if (_phase == CallPhase.ended) _setPhase(CallPhase.idle);
    });
  }

  /// 切换摄像头（通话中，Android 有效）。
  Future<void> switchCamera() async {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    try {
      await (track as dynamic).switchCamera();
    } on Object {
      // 平台不支持则忽略
    }
  }

  /// 静音切换（返回当前是否已静音）。
  Future<bool> toggleMute() async {
    final audio = _localStream?.getAudioTracks();
    if (audio == null || audio.isEmpty) return false;
    final enabled = !audio.first.enabled;
    audio.first.enabled = enabled;
    return !enabled;
  }
}
