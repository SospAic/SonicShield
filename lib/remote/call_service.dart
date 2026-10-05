import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// 最近一次**发起呼叫被拦下**的原因（null = 未被拦下）。
  ///
  /// BUG-D：原先 `startCall` 只返回 `null`，调用方拿不到"为什么"，
  /// 只能显示一句"权限或离线"的兜底 —— 用户无从下手。原因判定在
  /// [callStartBlockFor] / [CallStartBlock]（纯逻辑、宿主机可断言）。
  CallStartBlock? get lastStartBlock => _lastStartBlock;
  CallStartBlock? _lastStartBlock;

  final _failureCtrl = StreamController<String>.broadcast();
  Stream<String> get failures => _failureCtrl.stream;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _callId;
  PairedEndpoint? _peer;
  bool _isCaller = false;
  bool _video = true;
  CallPhase _phase = CallPhase.idle;

  /// 本端是否已成功 `setRemoteDescription`。
  ///
  /// ICE candidate **必须**在它之后才能喂给 PeerConnection（WebRTC 硬要求），
  /// 因此早到的候选要先缓存（见 [onCandidate] 与 `_pendingCandidates`）。
  bool _remoteDescSet = false;

  /// 早到的 ICE candidate 缓存（BUG-D）。
  ///
  /// 修之前这些候选被**静默丢弃**：被叫手动接听时 `_pc` 尚未创建，
  /// 振铃期间到达的候选全部丢掉；而主叫的 gathering 早已结束、不会补发
  /// ⇒ ICE 永不完成 ⇒ "接通了但没画面没声音"。
  /// 上限见 [maxBufferedCandidates]。
  final _pendingCandidates = <RTCIceCandidate>[];

  final _phaseCtrl = StreamController<CallPhase>.broadcast();
  Stream<CallPhase> get phase => _phaseCtrl.stream;
  CallPhase get currentPhase => _phase;
  String? get callId => _callId;

  /// 本次通话**对端**的 deviceId（未在通话中时为 null）。
  ///
  /// P1 撤销清场用：`RcEndpointService.onPeerRevoked` 靠它判断"这通电话是不是
  /// 那台已被解除配对的设备打来的/打给它的"。之所以不在这里另存一份状态：
  /// [_peer] 会在**唯一的**收尾路径（`_teardown` 一带，`_peer = null`）里被清掉，
  /// 天然不会漂移。
  String? get peerDeviceId => _peer?.deviceId;

  bool get inCall => _phase != CallPhase.idle && _phase != CallPhase.ended;

  /// 测试缝（与 `BackgroundServiceManager.stateForTest` / `lastForTest` 同形）：
  /// 把会话相位推到指定值，并像生产一样广播到 [phase]。
  ///
  /// ## 为什么需要它
  ///
  /// `CallOverlayHost` 的渲染**只由相位决定**（`showCall = 非 idle/ended`），
  /// 而真实相位只能由**真实媒体协商**推动：`connecting` 需要
  /// `getUserMedia` + `createOffer`（相机/麦克风），`connected` 需要
  /// `RTCPeerConnection` 真的连上（对端 + ICE）。宿主机两样都没有，
  /// 于是整块覆盖层（`call_incoming_overlay.dart`，93 行）长期 0 覆盖 ——
  /// 而它恰恰是被叫**唯一**的接听入口（BUG-056）。
  ///
  /// 这条缝只改**状态**：不发信令、不建媒体、不碰权限，
  /// 因此既不能让"通话跑起来"，也改变不了任何判定结果 —— 它驱动的是
  /// "相位 → 界面"这段映射，正是宿主可断言的那一段。
  ///
  /// ⚠️ 生产路径**从不**调用（`@visibleForTesting` 由分析器强制：
  /// 见 `analysis_options.yaml` 的 `invalid_use_of_visible_for_testing_member: error`）。
  /// 生产相位只由 [startCall] / [onIncomingCall] / [acceptIncoming] /
  /// [hangUp] / [onAnswer] / `_teardown` 驱动。
  @visibleForTesting
  void setPhaseForTest(CallPhase p) => _setPhase(p);

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
          answered: _answered,
          elapsedMs: sw.elapsedMilliseconds,
          limit: limit)) {
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
  ///
  /// ⚠️ 失败时**必须**同时设置 [lastStartBlock]：调用方（`CallScreen`）
  /// 依赖它给出可执行的失败原因。返回 null 却不说明原因，就是
  /// BUG-D 里"点了按钮什么都没发生"的一半。
  Future<String?> startCall(PairedEndpoint endpoint, RemoteStore store,
      {bool video = true}) async {
    _lastStartBlock = null;
    if (inCall) {
      _lastStartBlock = CallStartBlock.alreadyInCall;
      return null;
    }
    // 新会话起点：候选缓存必须是空的（上一通若有残留，`_teardown` 已清）。
    _pendingCandidates.clear();
    _remoteDescSet = false;
    _isCaller = true; // 主叫标记（onAnswer 守卫用）
    _video = video;
    _peer = endpoint;
    _callId = const Uuid().v4();
    _setPhase(CallPhase.connecting);

    final ok = await _ensureMedia(video: video);
    if (!ok) {
      _lastStartBlock = CallStartBlock.mediaFailed;
      await _teardown();
      return null;
    }
    await _createPc();

    try {
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
    } on Object {
      _lastStartBlock = CallStartBlock.offerFailed;
      await _teardown();
      return null;
    }

    final desc = await _pc!.getLocalDescription();
    final sdp = desc?.sdp ?? '';
    if (sdp.isEmpty) {
      // ⚠️ 空 SDP 的 invite 是"看起来发出去了"的**假成功**：对端一定协商失败，
      // 而且主叫会为此白等满 45s 才报"对方无应答"。宁可在本地当场判失败。
      _lastStartBlock = CallStartBlock.offerFailed;
      await _teardown();
      return null;
    }
    final sent = await RcEndpointService.instance.sendTo(
      endpoint,
      RcMessage.now(RcCmd.callInvite, {
        'callId': _callId,
        'video': video,
        'sdp': sdp,
        'type': desc?.type ?? 'offer',
        'fromName': store.deviceName,
      }),
      store,
      // ⚠️ BUG-076：**必须显式** `false`。`sendTo` 的默认值是 `true`，
      // 于是这条 invite 会被写进 outbox 补发队列 —— 与本节注释
      // （"outbox 不适用于实时通话"）以及 `_sendCallMsg`（answer/candidate/end
      // 一律 `false`）**正好相反**。补发的 invite 携带的是**上一通的 SDP**，
      // 而本端此刻已经 `_teardown`（`_pc` 已关、callId 已清）：对端上线后收到
      // 这条过期 invite 会照常振铃，自动接通开着时更会静默建立一路
      // **无人管理**的会话（麦克风/摄像头已开、且因为 `_answered=true`
      // 连 45s 振铃超时都不会启动）。
      enqueueOnFail: false,
    );
    if (!sent) {
      // 端点离线（outbox 不适用于实时通话）。
      _lastStartBlock = CallStartBlock.endpointOffline;
      await _teardown();
      return null;
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
  Future<bool> onIncomingCall(Map<String, dynamic> payload, PairedEndpoint peer,
      RemoteStore store) async {
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
    // 新会话起点：候选缓存必须是空的（`_createPc` 要等到用户点「接听」
    // 才会跑，而候选在振铃期间就会进缓存 —— 两者不能互相清）。
    _pendingCandidates.clear();
    _remoteDescSet = false;
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
      // 远端描述就位 → 之后到达的候选可以直接喂；此前缓存的在下面统一重放。
      _remoteDescSet = true;
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      final sent = await _sendCallMsg(
          RcCmd.callAnswer,
          {
            'callId': _callId,
            'sdp': answer.sdp,
            'type': answer.type,
          },
          peer,
          store);
      if (!sent) {
        // ⚠️ 应答**发不出去**时绝不能假装接通：主叫会一路等到 45s 后
        // 报"对方无应答"（把"网络坏了"误报成"没人接"）。这里当场收场，
        // 让本端使用者知道真实原因（`failed` → '连接失败'）。
        await _teardown(reason: CallEndReason.failed);
        return false;
      }
      // answer 已送出 → 把**振铃期间**缓存的候选补喂上（BUG-D）：
      // 不重放的话，主叫的 gathering 早已结束，ICE 永远凑不齐。
      await _flushPendingCandidates();
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
      _remoteDescSet = true;
      // 被叫的候选在 answer **之前**就发出了（`setLocalDescription(answer)`
      // 先于发信令）⇒ 它们会早于远端描述到达，必须在这里补喂（BUG-D）。
      await _flushPendingCandidates();
    } on Object {
      await _teardown(reason: CallEndReason.failed);
    }
  }

  /// 双向 ICE candidate。
  ///
  /// ⚠️ **早到的候选必须缓存、稍后重放，绝不丢弃**（BUG-D）。判定与理由见
  /// [candidateDeliverable]。旧实现是 `if (callId 不符 || _pc == null) return;`
  /// —— 被叫手动接听时 `_pc` 尚未创建，振铃期间到达的候选被**全部丢掉**，
  /// 等用户接听时主叫的 gathering 已经结束 ⇒ ICE 永不完成 ⇒ "接通了但
  /// 没画面没声音"。
  Future<void> onCandidate(Map<String, dynamic> payload) async {
    if (payload['callId'] != _callId) return; // 不是本次通话的候选
    final raw = payload['candidate'];
    if (raw is! Map) return; // 远端数据不可信：形状不对就忽略
    final c = raw.cast<String, dynamic>();
    final sdp = c['candidate'];
    if (sdp is! String || sdp.isEmpty) return;
    final candidate = RTCIceCandidate(
      sdp,
      c['sdpMid'] as String?,
      (c['sdpMLineIndex'] as num?)?.toInt() ?? 0,
    );
    if (!candidateDeliverable(
      pcReady: _pc != null,
      remoteDescriptionSet: _remoteDescSet,
    )) {
      _bufferCandidate(candidate);
      return;
    }
    await _addCandidate(candidate);
  }

  /// 缓存一条早到的候选（上限见 [maxBufferedCandidates]）。
  ///
  /// 超限时丢**最旧**的：host 候选最先产出、也最可能直连成功，要留下。
  /// 丢弃本身不改变"是否静默"的性质 —— 若最终所有候选都不可用，
  /// 会话级失败由 `onConnectionState=failed` → [failureHint] 报出。
  void _bufferCandidate(RTCIceCandidate c) {
    if (_pendingCandidates.length >= maxBufferedCandidates) {
      _pendingCandidates.removeAt(0);
    }
    _pendingCandidates.add(c);
  }

  Future<void> _addCandidate(RTCIceCandidate c) async {
    try {
      await _pc?.addCandidate(c);
    } on Object {
      // 单条候选失败不影响整路：ICE 会继续尝试其它候选；
      // 若全部失败，会话级失败由 onConnectionState 报出（不静默）。
    }
  }

  /// 把早到的候选一次性补喂给 PeerConnection。
  ///
  /// 只能在 `setRemoteDescription` **成功之后**调用（WebRTC 硬要求）。
  Future<void> _flushPendingCandidates() async {
    if (_pc == null || !_remoteDescSet) return;
    final pending = List.of(_pendingCandidates);
    _pendingCandidates.clear();
    for (final c in pending) {
      await _addCandidate(c);
    }
  }

  /// 对端挂断/占线/拒接。
  ///
  /// [payload] 是 `call.end` 的业务字段；`reason` 决定给用户看哪句话
  /// （`busy` → '对方正在通话中'、`rejected` → '对方已拒接'，其余中性）。
  /// 未知/缺失 reason 一律中性，**不猜**（见 [endReasonFromSignal]）。
  Future<void> onRemoteEnd([Map<String, dynamic>? payload]) async {
    await _teardown(reason: endReasonFromSignal(payload?['reason'] as Object?));
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
        reason: wasConnected ? CallEndReason.answered : CallEndReason.hangup);
  }

  // ---------------- 内部 ----------------

  Future<bool> _ensureMedia({required bool video}) async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video':
            video ? {'facingMode': 'user', 'width': 640, 'height': 480} : false,
      });
      // 免提（hands-free）：不切扬声器时 Android 会把通话声音送**听筒**，
      // 视频通话里表现为"能看到画面但听不清/听不到对方" —— 这是"无效果"
      // 最容易被误判成"功能坏了"的一种。本模块的产品形态就是免提通话，
      // 因此默认走扬声器（docs/16 §6 家人守护场景）。
      await _setSpeakerphone(true);
      return true;
    } on Object {
      return false;
    }
  }

  /// 切换免提扬声器。
  ///
  /// 平台不支持时**静默忽略**：它不是通话能否建立的必要条件，
  /// 报错反而会挡住通话本身（这与"失败必须可见"不矛盾 ——
  /// 这里失败的是音频路由偏好，不是用户要求的那件事）。
  Future<void> _setSpeakerphone(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
    } on Object {
      // 平台不支持 → 忽略。
    }
  }

  Future<void> _createPc() async {
    // ⚠️ 只复位"远端描述"标记，**绝不能**在这里清候选缓存：
    // 被叫的 `_pc` 是在用户点「接听」时才创建的，而候选早在**振铃期间**
    // 就已到达并进了缓存 —— 在这里清掉就等于把 BUG-D 原样复现。
    // 缓存的生命周期是**一次会话**，由 `_teardown` / 会话起点负责清空。
    _remoteDescSet = false;
    final pc = _pc = await createPeerConnection({
      'iceServers': await iceServers(),
      'sdpSemantics': 'unified-plan',
    });
    // ⚠️ BUG-077：addTrack **必须**把本地流一并传进去。
    //
    // flutter_webrtc 的 Dart 层写死了 `'streamIds': [stream?.id]`
    // （rtc_peerconnection_impl.dart:604）：不传 stream ⇒ 发过去的是 `[null]`，
    // Java 侧 `streamIds.toArray(new String[0])` 得到 `String[null]`，
    // native `nativeAddTrack` 拿这个 null 去调 `JniHelper.getStringBytes`
    // 直接抛 NPE；WebRTC 的 `CheckException` 见到 pending 异常即
    // `RTC_CHECK(false)`（jvm.cc:81）⇒ SIGABRT。
    //
    // 症状就是「发起视频/语音通话后程序崩溃」（P0）：getUserMedia 已成功、
    // 摄像头指示灯已亮，紧接着 addTrack 处整个进程 abort。旧写法
    // `forEach(pc.addTrack)` 正是"不传 stream"——而
    // `integration_test/camera_probe_test.dart` 传了 stream，所以探针能过、
    // 生产却崩（这也是"profile 通过、release 崩溃"假象的由来）。
    final local = _localStream;
    if (local != null) {
      // await：addTrack 是异步平台调用，结果被丢弃时异常会变成"无人接管的
      // 未来错误"（同 webrtc_stub 第 45 轮记录的那类静默失败）。
      for (final t in local.getTracks()) {
        await pc.addTrack(t, local);
      }
    }
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
      if (c.candidate == null) return;
      // ⚠️ 不能用 `.then(...).catchError((_) {})`：`_sendCallMsg` 现在返回
      // `Future<bool>`，`catchError` 的处理器必须返回 bool，否则**出错时**
      // 会再抛一个 TypeError（把"发候选失败"变成"崩在错误处理器里"）。
      unawaited(_sendLocalCandidate(c));
    };
  }

  /// 发出本端的一条 ICE candidate（尽力而为：失败由会话级状态兜底上报）。
  Future<void> _sendLocalCandidate(RTCIceCandidate c) async {
    final peer = _peer;
    final callId = _callId;
    if (peer == null || callId == null) return;
    final store = await _storeRef?.call();
    if (store == null) return;
    await _sendCallMsg(
      RcCmd.callCandidate,
      {
        'callId': callId,
        'candidate': {
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        },
      },
      peer,
      store,
    );
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

  /// 发出通话信令。
  ///
  /// ⚠️ 返回 **bool**：实时通话的信令**不能**走 outbox 补发，所以"发失败"
  /// 必须由调用方看见并决定怎么收场。修 BUG-D 之前这里把返回值丢掉 ——
  /// 于是 `call.answer` 发不出去时被叫照样"接通成功"，主叫却一路等到 45s
  /// 报"对方无应答"（把网络故障误报成没人接）。
  Future<bool> _sendCallMsg(String type, Map<String, dynamic> payload,
      PairedEndpoint peer, RemoteStore store) async {
    try {
      return await RcEndpointService.instance.sendTo(
          peer, RcMessage.now(type, payload), store,
          enqueueOnFail: false);
    } on Object {
      // 编码/密钥/通道异常 → 如实报失败，不吞掉。
      return false;
    }
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
    // 候选缓存与远端描述标记必须跟着本次会话一起清掉：留着会在下一通
    // 通话里被当成"本次的候选"重放给新的 PeerConnection（连错人）。
    _pendingCandidates.clear();
    _remoteDescSet = false;
    // 免提归位：不关掉的话，通话结束后整个应用的媒体播放仍走扬声器。
    await _setSpeakerphone(false);
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
