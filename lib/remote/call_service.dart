import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'endpoint_service.dart';
import 'call_lifecycle.dart';
import 'call_media_profile.dart';
import 'node_catalog.dart';
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

  /// 公共 STUN（**国内可达优先**）。
  ///
  /// ## 为什么要换掉清一色 Google（BUG-081：连接极慢/不可用）
  ///
  /// `stun.l.google.com` 在中国大陆基本**不可达**：STUN 请求打水漂 ⇒ 拿不到
  /// 任何 `srflx`（服务器反射）候选 ⇒ 跨网（一方 4G、一方 wifi）时只剩 host
  /// 候选，直连**必然失败**，还要白等满一轮 ICE 超时才报错 —— 用户看到的
  /// 就是「连接太慢，基本不可用」。
  ///
  /// 这里换成国内主流公共 STUN（小米/哔哩哔哩/腾讯），并**保留** Google 一条
  /// 作为海外网络回落（双方都在海外时它反而更快）。多候选并存不冲突：
  /// ICE 会并行采集、择优使用。
  /// 自动模式（未指定首选）时的 STUN 候选：**全部并行**（ICE 会择优采集）。
  ///
  /// 真源是 `node_catalog.dart` 的 [kStunNodes]（国内可达优先 + Google 回落），
  /// 与「远程 → 设置」的一键测速**共用同一份目录**，避免两处列表漂移。
  static List<Map<String, dynamic>> get _stunServers => [
        for (final n in kStunNodes) {'urls': n.url},
      ];

  /// 预采集的 ICE 候选数。
  ///
  /// 取 4：覆盖 host+srflx 的典型基数，又不至于让每通电话都多开一堆 socket
  /// （移动端耗电）。它在 `createPeerConnection` 时就并行开始收集候选，
  /// 与 `createOffer` 重叠 ⇒ 省掉一段 gather 等待（建连提速）。
  static const int iceCandidatePoolSize = 4;

  /// 组装 ICE 服务器列表：STUN 必备 + **可选** TURN 中继。
  ///
  /// 未配置 TURN 时只返回 STUN —— 打洞成功与否取决于双方 NAT 类型，
  /// 这是 WebRTC 的固有属性，不是缺陷。真正的问题在于"失败后不给原因"，
  /// 所以失败路径统一由 [failureHint] 给出可操作提示。
  ///
  /// ## TURN 的 UDP/TCP 双通道（行业实践）
  ///
  /// 使用者只填一条 `turn:host:port`，这里**自动补**一条
  /// `?transport=tcp`（见 [turnTcpFallbackUrl]）：封 UDP 的企业网/酒店 wifi
  /// 下 UDP 候选全灭，TCP 通道仍能打过去，否则整通电话直接连不上。
  /// 顺序为 UDP 优先、TCP 兜底 —— 与腾讯 TRTC / Stream 的推荐一致。
  static Future<List<Map<String, dynamic>>> iceServers() async {
    final store = RemoteStore(await SharedPreferences.getInstance());
    final turn = <Map<String, dynamic>>[];
    if (store.turnConfigured) {
      // 凭据两条通道共用；无账号密码时不塞空字段（部分服务器不接受空凭据）。
      final creds = <String, dynamic>{
        if (store.turnUser.isNotEmpty) 'username': store.turnUser,
        if (store.turnCred.isNotEmpty) 'credential': store.turnCred,
      };
      turn.add({'urls': store.turnUrl, ...creds});
      final tcp = turnTcpFallbackUrl(store.turnUrl);
      if (tcp != null) turn.add({'urls': tcp, ...creds});
    }
    // 指定了首选 STUN ⇒ 只用它（第八十二轮「下拉切换」）；否则全部并行（默认行为不变）。
    final sel = store.stunSelectedUrl.trim();
    final stun = sel.isEmpty
        ? _stunServers
        : <Map<String, dynamic>>[
            {'urls': sel},
          ];
    return [...stun, ...turn];
  }

  /// `createPeerConnection` 的**统一配置**（单路 [CallService] 与多路
  /// [MultiCallService] 共用，避免两处参数漂移）。
  ///
  /// 除 `iceServers` 外，这几个参数直接影响**建连速度与成功率**：
  /// - `bundlePolicy: max-bundle`：媒体/数据复用同一条传输，少一轮 ICE；
  /// - `rtcpMuxPolicy: require`：RTP/RTCP 同端口，候选数减半、打洞更快；
  /// - `iceCandidatePoolSize`：预采集候选，省掉 gather 等待；
  /// - `iceTransportPolicy: all`：**直连优先**，失败才走 relay
  ///   （中继耗带宽、绕远路，只在打洞失败时兜底）。
  ///
  /// 以上键名均已由 flutter_webrtc 原生层解析
  /// （`MethodCallHandlerImpl` 的 `iceTransportPolicy` / `bundlePolicy` /
  /// `rtcpMuxPolicy` / `iceCandidatePoolSize`）。
  static Future<Map<String, dynamic>> peerConnectionConfig() async => {
        'iceServers': await iceServers(),
        'iceTransportPolicy': 'all',
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
        'iceCandidatePoolSize': iceCandidatePoolSize,
        'sdpSemantics': 'unified-plan',
      };

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

  /// 本端已 `addTrack` 出去的 sender（docs/16 §10）。
  ///
  /// 用它在 `setLocalDescription` **之后**下发编码档位
  /// （[applySendProfileToSenders]）：WebRTC 硬要求在本地描述就位后才能
  /// `setParameters`。为什么需要下发：默认编码器**没有码率/帧率上限**，
  /// BWE 会把码率抬到编码器跑不动为止 —— 这正是低端机"爆卡"的主因。
  List<RTCRtpSender> _senders = const <RTCRtpSender>[];
  String? _callId;
  PairedEndpoint? _peer;
  bool _isCaller = false;
  bool _video = true;

  /// 本会话是否为**屏幕共享**（docs/61 §5 P2）。
  ///
  /// `false`（默认）= 普通音视频通话（`getUserMedia`，摄像头 + 麦克风）；
  /// `true` = 屏幕共享（`getDisplayMedia`，媒体是**屏幕画面**，默认不采麦克风）。
  /// 与通话**互斥**：`startCall` 的 `inCall` 守卫同时覆盖两者（单会话）。
  bool _screen = false;
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

  /// 应答后"等媒体真正连通"的计时器（BUG-081）。
  ///
  /// 与 [_waitTimer] 是**两段不同的风险**：`_waitTimer` 等的是"对方接不接"，
  /// 本计时器等的是"接起来后 ICE 能不能连上"。修之前只有前者 ⇒ 应答一到位
  /// 就没有任何上限，被叫自动接通后一旦 ICE 凑不齐就**永久停在「连接中…」**。
  Timer? _connectTimer;

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
      //
      // ⚠️ BUG-081：必须**先发信令**再收尾。修之前主叫超时只做本地收尾，
      // 被叫（尤其自动接通后卡在 connecting 的那种）收不到任何通知 ⇒
      // 主叫界面已退回、被叫却永久停在"连接中…"。这里补一条 `call.end`，
      // 让对端也用同一个原因（missed → '对方无应答'）收场。
      await _sendEndSignal(reason: 'missed');
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

  /// 启动"等媒体真正连通"计时（BUG-081，应答已交换后调用）。
  ///
  /// 到点仍未 `connected` → 判定媒体建连失败：通知对端 + 本地按
  /// [CallEndReason.failed]（文案「连接失败」）收场，**不再永久 connecting**。
  void _startConnectTimer() {
    _cancelConnectTimer();
    final sw = Stopwatch()..start();
    _connectTimer = Timer(connectTimeout, () {
      // 到点时复核：期间可能已经连通（connected），也可能已收尾（phase 变了）。
      if (_phase != CallPhase.connecting) return;
      if (!connectTimedOut(
          connected: _phase == CallPhase.connected,
          elapsedMs: sw.elapsedMilliseconds)) {
        return;
      }
      unawaited(_onConnectTimeout());
    });
  }

  void _cancelConnectTimer() {
    _connectTimer?.cancel();
    _connectTimer = null;
  }

  Future<void> _onConnectTimeout() async {
    // 让对端也按"媒体失败"收场，避免一边退出一边卡住。
    await _sendEndSignal(reason: 'media');
    await _teardown(reason: CallEndReason.failed);
  }

  /// 尽力把 `call.end` 发给对端（**失败不改变本地收尾**）。
  ///
  /// 超时/建连失败时对端可能已不可达，因此这里只"尽力而为"：
  /// 发不出去也不阻塞本地收尾（本地必须让用户看到结果，不能为了通知对端
  /// 而把本端也卡住）。
  Future<void> _sendEndSignal({required String reason}) async {
    final peer = _peer;
    final callId = _callId;
    if (peer == null || callId == null) return;
    final store = await _storeRef?.call();
    if (store == null) return;
    await _sendCallMsg(
        RcCmd.callEnd, {'callId': callId, 'reason': reason}, peer, store);
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
      {bool video = true, bool screen = false}) async {
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
    _screen = screen;
    _peer = endpoint;
    _callId = const Uuid().v4();
    _setPhase(CallPhase.connecting);

    final ok = await _ensureMedia(video: video, screen: screen);
    if (!ok) {
      _lastStartBlock = CallStartBlock.mediaFailed;
      await _teardown();
      return null;
    }
    await _createPc();

    try {
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      // 本地描述就位 → 立刻下发编码档位（docs/16 §10）。失败不阻塞发起。
      await _applySendProfile();
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
        // docs/61 §5 P2：会话类型。`'screen'` ⇒ 被叫用 `getDisplayMedia`
        // （共享**屏幕**）而非 `getUserMedia`（摄像头）。缺省 `'call'`
        // 保持向后兼容 —— 旧端不认此字段时按普通通话处理，不会解析失败。
        'kind': screen ? 'screen' : 'call',
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
    // docs/61 §5 P2：会话类型（缺省 `'call'` ⇒ 向后兼容旧端）。
    _screen = payload['kind'] == 'screen';
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

    final ok = await _ensureMedia(video: _video, screen: _screen);
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
      // 本地描述就位 → 立刻下发编码档位（docs/16 §10）。失败不阻塞接通。
      await _applySendProfile();
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
      // 应答已交换 → 启动"等媒体连通"计时（BUG-081）：ICE 迟迟不通就收场，
      // 绝不永久停在「连接中…」。
      _startConnectTimer();
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
      // 应答已交换 → 启动"等媒体连通"计时（BUG-081）：ICE 迟迟不通就收场。
      _startConnectTimer();
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

  Future<bool> _ensureMedia({required bool video, bool screen = false}) async {
    try {
      if (screen) {
        // docs/61 §5 P2：**屏幕共享** —— 用 `getDisplayMedia` 取屏幕画面，
        // **不采麦克风**（投屏默认只传屏幕视频；设备音频是独立开关、默认关，
        // 见 docs/24 §阶段2「不复用部分」）。
        //
        // ⚠️ 本分支是 P2 的**最大不确定点**（docs/24 R12）：flutter_webrtc 在
        // Android 上如何与我们在 P0 拿到的 MediaProjection token 交接，
        // **尚未真机验证**（本机 Dart 管道耗尽 ⇒ 无法构建/实测）。若该 API
        // 不可用、或会二次弹授权窗，降级方案是原生 libwebrtc AAR 直写
        // （信令仍复用 MQTT）。**在 spike 通过前，不得声称 P2 可用。**
        _localStream = await navigator.mediaDevices.getDisplayMedia({
          'video': true,
          'audio': false,
        });
        return true;
      }
      // ⚠️ 采集约束必须走 [videoConstraintsFor]（docs/16 §10）：旧写法只写死
      // 640x480、**完全不设帧率上限**，部分机型会以 30/60fps 采集，
      // 低端机编码线程直接吃满 CPU ⇒ 双方"爆卡"。`ideal` 而非精确值是为了
      // 避免"摄像头不支持该分辨率 ⇒ 整通电话起不来"。
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video ? videoConstraintsFor(callVideoCapture) : false,
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
    final pc = _pc = await createPeerConnection(
      await CallService.peerConnectionConfig(),
    );
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
    _senders = <RTCRtpSender>[];
    if (local != null) {
      // await：addTrack 是异步平台调用，结果被丢弃时异常会变成"无人接管的
      // 未来错误"（同 webrtc_stub 第 45 轮记录的那类静默失败）。
      for (final t in local.getTracks()) {
        _senders.add(await pc.addTrack(t, local));
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
        // 媒体通了 → "等建连"计时到此结束（BUG-081）。
        _cancelConnectTimer();
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

  /// 把编码档位下发给本端 sender（docs/16 §10）。
  ///
  /// 单路通话固定取 `sendProfileFor(1)`（600kbps / 24fps / 不缩放 /
  /// `maintain-framerate`）。多路通话由 `MultiCallService` 按并发路数取档，
  /// 两处共用同一张表。
  ///
  /// ⚠️ 只能在 `setLocalDescription` **之后**调用（WebRTC 硬要求），
  /// 且失败一律**吞掉**（[applySendProfileToSenders] 内已处理）——
  /// 它调的是"画质/负载"而不是"能否通话"，失败应退回默认自适应。
  Future<void> _applySendProfile() =>
      applySendProfileToSenders(_senders, sendProfileFor(1));

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
    _cancelConnectTimer();
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
    // sender 随 `_pc` 一起失效（它们只是 pc 的句柄）：不清会在下一通里
    // 对着一批已 dispose 的 sender 调 setParameters。
    _senders = const <RTCRtpSender>[];
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
