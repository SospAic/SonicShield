import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'endpoint_service.dart';
import 'call_lifecycle.dart';
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
/// ICE：默认 Google 公共 STUN；对称 NAT 场景需自建 TURN
/// （v1.7 S5 起支持在「远程 → 设置」配置，见 [CallService.iceServers]）。
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  static const _stunServers = <Map<String, dynamic>>[
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  /// 组装 ICE 服务器列表：STUN 必备 + **可选** TURN 中继。
  ///
  /// 未配置 TURN 时只返回 STUN —— 打洞成功与否取决于双方 NAT 类型，
  /// 这是 WebRTC 的固有属性，不是缺陷。真正的问题在于"失败后不给原因"，
  /// 所以失败路径统一由 [failureHint] 给出可操作提示。
  static Future<List<Map<String, dynamic>>> iceServers() async {
    final store = RemoteStore(await SharedPreferences.getInstance());
    return [
      ..._stunServers,
      if (store.turnConfigured)
        {
          'urls': store.turnUrl,
          if (store.turnUser.isNotEmpty) 'username': store.turnUser,
          if (store.turnCred.isNotEmpty) 'credential': store.turnCred,
        },
    ];
  }

  /// ICE 失败时给使用者的可操作提示（**无 TURN 降级路径**）。
  ///
  /// 未配置 TURN 时不能只说"连接失败"：使用者会反复重试却无从下手。
  /// 明确指向"对称 NAT + 配 TURN"，把不可诊断的失败变成可执行的下一步。
  static String failureHint({required bool turnConfigured}) => turnConfigured
      ? '直连与中继均失败：请检查 TURN 地址/账号是否有效，以及双方网络是否放行 UDP。'
      : '直连失败：双方很可能都处于对称 NAT（常见于 4G/5G 或企业网）。'
          '请在「远程 → 设置 → TURN 中继」填入自建 TURN 服务器后重试。';

  /// 最近一次连接失败的可读原因；无失败时为 null。
  String? get failureReason => _failureReason;
  String? _failureReason;

  final _failureCtrl = StreamController<String>.broadcast();
  Stream<String> get failures => _failureCtrl.stream;

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

  /// 本次通话是否为本机发起。
  ///
  /// UI 用它区分「来电」与「去电」—— 振铃阶段只有**被叫**才该出现
  /// 「接听」按钮；主叫在振铃阶段要做的是继续等（或挂断）。
  bool get isCaller => _isCaller;

  /// 远端媒体流（UI 渲染用）。
  MediaStream? get remoteStream => _remoteStream;
  MediaStream? _remoteStream;
  final _remoteCtrl = StreamController<MediaStream?>.broadcast();
  Stream<MediaStream?> get remoteStreamChanges => _remoteCtrl.stream;

  MediaStream? get localStream => _localStream;

  // ---------------- 接听超时与通话状态镜像（BUG-050） ----------------
  //
  // 修 BUG-050 之前：主叫发出 invite 后**没有超时** —— 被叫未开自动接通、
  // 或压根没收到 invite 时，主叫会**无限停在"连接中…"**，且没有任何
  // "未接"反馈。判定逻辑全部抽到 `call_lifecycle.dart`（纯函数、宿主机可断言），
  // 这里只负责把它接到 Timer / 信令 / UI 上。

  Timer? _waitTimer;

  /// 手动振铃期间暂存的 invite（SDP 在里面），供用户稍后点「接听」时使用。
  ///
  /// ⚠️ 为什么必须存：手动模式下"接听"是**用户稍后**在界面上点的，
  /// 那一刻拿不到原始 invite。不存的话，UI 就只能回头去调那个
  /// "收到 invite 就立刻接通"的老回调 —— 而那正是 BUG-056
  /// （「自动接通」开关关掉也照样接通）。
  Map<String, dynamic>? _pendingInvite;

  /// 是否正处于"振铃、等用户接/拒"的状态。
  bool get awaitingAnswer =>
      _phase == CallPhase.ringing && _pendingInvite != null;

  /// 是否已收到应答（SDP answer 或 `rc.call state=connected`）。
  /// 超时判定要用它来区分"没人接"与"已接通但计时器残留"。
  bool _answered = false;

  /// 最近一次通话的结束原因（UI 直接取用；无通话时为 null）。
  CallEndReason? get lastEndReason => _endReason;
  CallEndReason? _endReason;

  final _endedCtrl = StreamController<CallEndReason>.broadcast();

  /// 通话结束（含"未接"）时广播原因 —— 让 UI 能把结果说出来，
  /// 而不是无声无息地退回上一页。
  Stream<CallEndReason> get callEnded => _endedCtrl.stream;

  /// 对端 `rc.call` 的状态镜像（ringing / connected / ended）。
  /// 主叫据此显示"对方振铃中…"，不必等媒体真正建立。
  RemoteCallState get remoteState => _remoteState;
  RemoteCallState _remoteState = RemoteCallState.unknown;
  final _remoteStateCtrl = StreamController<RemoteCallState>.broadcast();
  Stream<RemoteCallState> get remoteStateChanges => _remoteStateCtrl.stream;

  /// 被叫振铃超时时的上报钩子（由端点侧装配，负责发出 `RcEvt.callMissed`）。
  ///
  /// 为什么用回调而不是在这里直接发：`rc.call.missed` 是**端点（被叫）**发出的
  /// 事件，发送通道（`_send` / MQTT 客户端）在 `endpoint_service` 手上；
  /// 由它装配既省掉一条反向依赖，也让"端点确实会发这个事件"变成可断言的接线
  /// （见 `call_lifecycle_test.dart` CL-14）。
  ///
  /// 只传 `callId`：对端与 store 端点自己知道，不必来回倒手。
  Future<void> Function(String callId)? onRingTimeout;

  /// 接上控制器的入站事件流，消费通话相关事件。
  ///
  /// 修 BUG-050 前：`rc.call` 与 `rc.call.missed` **在 App 内无人消费**
  /// （只有 `tool/` 的桌面 E2E 工具看得到）→ 用户在控制台既看不到
  /// "对方振铃中"，也收不到"未接"。
  void attach(Stream<Map<String, dynamic>> events) {
    _evtSub?.cancel();
    _evtSub = events.listen(_onRemoteEvent);
  }

  StreamSubscription<Map<String, dynamic>>? _evtSub;

  void _onRemoteEvent(Map<String, dynamic> m) {
    final type = m['type'] as String? ?? '';
    if (type == RcEvt.callState) {
      final payload = rcPayloadOf(m);
      final s = parseRemoteCallState(payload['state']);
      if (s == RemoteCallState.unknown) return; // 未知状态：什么都不做
      if (payload['callId'] != null && payload['callId'] != _callId) {
        return; // 不是本次通话的状态
      }
      _remoteState = s;
      if (!_remoteStateCtrl.isClosed) _remoteStateCtrl.add(s);
      if (remoteStateStopsWaiting(s)) _cancelWaitTimer();
      if (remoteStateEndsCall(s)) {
        unawaited(_teardown(reason: CallEndReason.remoteEnded));
      }
      return;
    }
    if (type == RcEvt.callMissed) {
      // 对端（被叫）判定本次未接 —— 主叫立刻结束等待并给出原因。
      if (!inCall) return;
      final payload = rcPayloadOf(m);
      if (payload['callId'] != null && payload['callId'] != _callId) return;
      unawaited(_teardown(reason: CallEndReason.missed));
    }
  }

  /// 启动"等待应答"计时（主叫等 answer / 被叫等用户接听）。
  void _startWaitTimer({required bool isCaller}) {
    _cancelWaitTimer();
    _answered = false;
    final limit = Duration(milliseconds: waitLimitMs(isCaller: isCaller));
    final sw = Stopwatch()..start();
    _waitTimer = Timer(limit, () {
      // 到点时再复核一次：Timer 可能在 teardown 之后才被调度到，
      // 也可能期间已经接通（answered）。
      if (!timedOutMeansMissed(
          answered: _answered, elapsedMs: sw.elapsedMilliseconds, limit: limit)) {
        return;
      }
      unawaited(_onWaitTimeout(isCaller: isCaller));
    });
  }

  void _cancelWaitTimer() {
    _waitTimer?.cancel();
    _waitTimer = null;
  }

  Future<void> _onWaitTimeout({required bool isCaller}) async {
    if (isCaller) {
      // 主叫侧判定：被叫没应答（可能没上线、也可能被叫侧静默丢弃）。
      await _teardown(reason: CallEndReason.missed);
      return;
    }
    // 被叫侧判定：振铃期间无人接听 → **由端点发出 rc.call.missed**，
    // 让主叫不必单方面等到自己的超时。
    final callId = _callId;
    if (callId != null) {
      try {
        await onRingTimeout?.call(callId);
      } on Object {
        // 上报失败不影响本地收尾（主叫仍有自己的超时兜底）。
      }
    }
    await _teardown(reason: CallEndReason.missed);
  }

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
    // invite 已发出 → 开始"等待应答"计时。
    // 修 BUG-050 前这里什么都没有：被叫未开自动接通、或 invite 被静默丢弃时，
    // 主叫会**无限停在"连接中…"**且没有任何"未接"反馈。
    _startWaitTimer(isCaller: true);
    return _callId;
  }

  // ---------------- 被叫（含自动接通） ----------------

  /// 收到 invite：按 [calleeActionFor] 决定自动接通 / 振铃等用户 / 回占线。
  /// 返回 true 表示已开始接通流程或已进入振铃等待。
  ///
  /// ⚠️ **没有 `onManualRing` 回调了**（BUG-056）。原先它存在的唯一用途是让
  /// 调用方"代为接通"—— 于是「自动接通」开关关掉也照样接通。
  /// 现在振铃只是把状态置为 [CallPhase.ringing]，接听界面由
  /// `CallOverlayHost` 常驻监听 phase 自动弹出，用户点「接听」时走
  /// [acceptPending]。**去掉这个参数是为了让那条错误接线不再可能**。
  Future<bool> onIncomingCall(
      Map<String, dynamic> payload, PairedEndpoint peer, RemoteStore store) async {
    // 决策走纯函数（宿主机可断言）。⚠️ 它保证「开关关闭 ⇒ 绝不自动接通」。
    final action = calleeActionFor(
      autoAnswer: await autoAnswerEnabled(),
      inCall: inCall,
    );
    if (action == CalleeAction.rejectBusy) {
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

    // ⚠️ 用**穷尽 switch 表达式**：将来给 [CalleeAction] 加一个值会**编译报错**，
    // 强迫作者显式决定它走哪条路。若写成 `if (autoAccept) {...} else {振铃}`，
    // 新值会**静默落进振铃分支** —— 那正是本项目反复出现的"静默降级"。
    return switch (action) {
      CalleeAction.autoAccept => await acceptIncoming(payload, peer, store),
      CalleeAction.ringUser => _ringUser(payload),
      // 上面已提前 return；保留此臂只为让 switch **穷尽**。
      CalleeAction.rejectBusy => false,
    };
  }

  /// 进入"振铃、等用户接/拒"状态。返回 true 表示已受理这通来电。
  bool _ringUser(Map<String, dynamic> payload) {
    // 手动路径：**只振铃，绝不自动接通**（BUG-056）。
    // 把 invite 存下来 —— 用户是**稍后**才点「接听」的，那一刻拿不到 SDP；
    // 不存就只能退回"收到 invite 就立刻接通"的老路，而那正是本 BUG。
    _pendingInvite = Map<String, dynamic>.from(payload);
    // 振铃超时：到点由**端点侧**发出 `RcEvt.callMissed`，主叫据此结束等待 ——
    // "没人接"这件事不该由主叫单方面猜（BUG-050）。
    _startWaitTimer(isCaller: false);
    return true;
  }

  /// 接通来电（自动或手动）。
  Future<bool> acceptIncoming(
      Map<String, dynamic> payload, PairedEndpoint peer, RemoteStore store,
      {bool video = true}) async {
    if (_phase != CallPhase.ringing) return false;
    _setPhase(CallPhase.connecting);
    // invite 已被消费 —— 之后再点「接听」应当无效（phase 守卫也拦一道）。
    _pendingInvite = null;
    // 用户（或自动接通策略）已经接下这通电话 → 振铃等待到此结束。
    _answered = true;
    _cancelWaitTimer();

    final ok = await _ensureMedia(video: _video);
    if (!ok) {
      await _sendCallMsg(
          RcCmd.callEnd, {'callId': _callId, 'reason': 'media'}, peer, store);
      await _teardown(reason: CallEndReason.failed);
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
      await _teardown(reason: CallEndReason.failed);
      return false;
    }
  }

  /// 拒接（仅手动流程）。
  Future<void> rejectCall(RemoteStore store) async {
    if (_phase != CallPhase.ringing || _peer == null) return;
    await _sendCallMsg(RcCmd.callEnd, {'callId': _callId, 'reason': 'rejected'},
        _peer!, store);
    // 本端拒接 → `declined`（'已拒接'）。
    // ⚠️ 不能复用 `rejected`：那个文案是给**被拒的一方**看的（'对方已拒接'），
    // 拒接的人自己看到"对方已拒接"会以为被拒的是自己。
    await _teardown(reason: CallEndReason.declined);
  }

  /// 接听当前振铃中的来电（UI「接听」按钮调用）。
  ///
  /// 没有待接 invite、或已经不在振铃状态时返回 `false`（**不抛异常**）——
  /// 按钮可能被连点，也可能在超时收尾之后才被点到。
  Future<bool> acceptPending() async {
    final invite = _pendingInvite;
    final peer = _peer;
    if (invite == null || peer == null) return false;
    if (_phase != CallPhase.ringing) return false;
    final store = await _storeRef?.call();
    if (store == null) return false;
    return acceptIncoming(invite, peer, store);
  }

  /// 拒接当前振铃中的来电（UI「拒接」按钮调用）。
  Future<void> declinePending() async {
    final store = await _storeRef?.call();
    if (store == null) return;
    await rejectCall(store);
  }

  // ---------------- 信令处理（由 endpoint_service 分派调用） ----------------

  /// 主叫收到 answer。
  Future<void> onAnswer(Map<String, dynamic> payload) async {
    if (!_isCaller ||
        _phase != CallPhase.connecting ||
        payload['callId'] != _callId) {
      return;
    }
    // 应答到达 → 等待结束（否则 45s 后会把一通已接通的电话报成"未接"）。
    _answered = true;
    _cancelWaitTimer();
    try {
      await _pc?.setRemoteDescription(RTCSessionDescription(
        payload['sdp'] as String,
        payload['type'] as String? ?? 'answer',
      ));
    } on Object {
      await _teardown(reason: CallEndReason.failed);
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
  ///
  /// [payload] 是 `call.end` 的业务字段；`reason` 决定给用户看哪句话
  /// （`busy` → '对方正在通话中'、`rejected` → '对方已拒接'，其余中性）。
  /// 未知/缺失 reason 一律中性，**不猜**（见 [endReasonFromSignal]）。
  Future<void> onRemoteEnd([Map<String, dynamic>? payload]) async {
    await _teardown(
        reason: endReasonFromSignal(payload?['reason'] as Object?));
  }

  // ---------------- 挂断 ----------------

  Future<void> hangUp(RemoteStore store) async {
    final wasConnected = _phase == CallPhase.connected;
    if (_peer != null && _phase != CallPhase.idle) {
      await _sendCallMsg(RcCmd.callEnd, {'callId': _callId, 'reason': 'hangup'},
          _peer!, store);
    }
    // 已接通后主动挂断 → '通话结束'；还没接通就取消 → '已挂断'。
    await _teardown(
        reason:
            wasConnected ? CallEndReason.answered : CallEndReason.hangup);
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
      'iceServers': await iceServers(),
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
        _failureReason = null;
        // 媒体已连通 ⇒ 必然已应答。这里再确认一次，防止"answer 信令丢了
        // 但媒体通了"的极端情形下 45s 后把通话报成"未接"。
        _answered = true;
        _cancelWaitTimer();
        _setPhase(CallPhase.connected);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        // 无 TURN 降级：把"失败"变成"可诊断的失败"（S5）。
        unawaited(_reportIceFailure());
        unawaited(_teardown());
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        // ⚠️ 不传 reason：这里是 `_pc.close()` 的**副作用**，
        // 传了会把真正的原因（未接/拒接）覆盖掉（BUG-050）。
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

  /// ICE 失败：记录可读原因并广播（S5 无 TURN 降级路径）。
  Future<void> _reportIceFailure() async {
    final store = RemoteStore(await SharedPreferences.getInstance());
    final hint = failureHint(turnConfigured: store.turnConfigured);
    _failureReason = hint;
    if (!_failureCtrl.isClosed) _failureCtrl.add(hint);
  }

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

  /// 收尾。
  ///
  /// ⚠️ [reason] 只在**本次结束真的有一个原因**的那一次传入。
  /// 由收尾**副作用**触发的二次调用（典型：`_pc.close()` 会让
  /// `onConnectionState` 变成 `closed`，那里再调一次 `_teardown()`）
  /// 必须传 `null`，否则会用"没有语义的结束"覆盖掉真正的原因 ——
  /// 用户会看到"对方无应答"被冲成空白（BUG-050）。
  Future<void> _teardown({CallEndReason? reason}) async {
    _cancelWaitTimer();
    _answered = false;
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
    // 镜像归位：**不广播**（"通话已结束"由 callEnded / phase 负责），
    // 否则 UI 会先收到 ended 再收到 unknown，白闪一下。
    _remoteState = RemoteCallState.unknown;
    _setPhase(CallPhase.ended);
    _callId = null;
    _peer = null;
    // 待接 invite 必须一起清掉：否则下一通来电的「接听」按钮
    // 可能拿到**上一通**的 SDP（连错人）。
    _pendingInvite = null;
    if (reason != null) {
      _endReason = reason;
      if (!_endedCtrl.isClosed) _endedCtrl.add(reason);
    }
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
