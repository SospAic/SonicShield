import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import 'call_lifecycle.dart';
import 'call_media_profile.dart';
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
  //
  // ⚠️ 必须从 `payload` 里取（BUG-023 同形状）：事件信封是
  // `{v, id, ts, type, payload, from, peerId, peerName}`（见 `rcPayloadOf`），
  // 业务字段**全部**在 `payload` 之内。曾直接读顶层 `m['callId']` → 恒为 null
  // ⇒ 本服务丢弃**所有** answer/candidate/end ⇒ 多路视频永远接不通
  // （UI 永久停在"连接中…"）。这是 P0 全链路断链。
  // 反向锁：`test/multi_call_ownership_test.dart` 断言**顶层形状不命中**。
  final raw = rcPayloadOf(m)['callId'];
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

/// 存活复核：`s` 是否**仍是** [deviceId] 当前的那一路会话（R88-AUD-04）。
///
/// ## 为什么需要它
/// [MultiCallService.connect] 在**所有 await 之前**就把会话写进表里
/// （入表 → `createPeerConnection` → `addTrack` → `createOffer` →
/// `setLocalDescription` → `_send(callInvite)` 全是异步）。若 `hangUp()`
/// 落在这串 await 中间，表里那条已被摘走，而 `connect()` 手上只有**快照** `s`：
/// 它会继续把 invite 发出去（对端开始振铃），并在孤儿会话上起 45s 计时器 ——
/// 本端 UI 没有这一路，`hangUp()` 也再找不到它。
///
/// ## 判据
/// * **对象身份**：表里此刻的那一条必须就是 `s` 本身。换成新的一路（同设备
///   重连）也算不成立 —— 代次已经变了。
/// * **未被关闭**：`pc.onConnectionState` 的 closed 分支会把 `phase` 置成
///   [MultiCallPhase.closed] 但**不摘表**；此时继续发 invite 同样是错的。
///
/// 抽成纯函数（与 [ownedCallIdOf] / [nextActiveId] 同一手法）：竞态判据写错
/// **不会抛异常**，只会静默地多关一个 PC 或少发一条 invite，只能靠锁。
bool stillCurrent(Map<String, MultiCallSession> sessions, String deviceId,
        MultiCallSession s) =>
    identical(sessions[deviceId], s) && s.phase != MultiCallPhase.closed;

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

  /// 是否已收到应答（SDP answer 或媒体连通）。
  ///
  /// 供 [timedOutMeansMissed] 判定用：**已应答后**残留的计时器
  /// 不得再把一路通话报成"对方无应答"。
  bool answered = false;

  /// "等待应答"计时器（未接超时）。
  Timer? waitTimer;

  /// 应答后"等媒体连通"计时器（BUG-081，与 `CallService._connectTimer` 同义）。
  ///
  /// 没有它：answer 一到就取消 `waitTimer`，之后 ICE 迟迟不通时本路
  /// **永久停在「连接中…」**（既不报未接、也不报失败）。
  Timer? connectTimer;

  /// 本路已 `addTrack` 出去的 sender（docs/16 §10）。
  ///
  /// 多路是 **P2P，没有 SFU** ⇒ 每一路各跑一个编码器，路数越多 CPU 越爆
  /// （低端机上"too many video streams simultaneously"是常见卡顿根因）。
  /// 因此需要在**路数变化**时对**所有路**重新下发档位
  /// （见 [MultiCallService._applyProfilesToAll]）。
  List<RTCRtpSender> senders = <RTCRtpSender>[];

  /// 发起这一路时用的 store（BUG-136：`hangUp` 要发 `call.end` 需要它）。
  ///
  /// 为什么不放进 `hangUp` 的参数：`hangUp` 有两个调用来源 —— UI 挂断（有
  /// store）与**收到对端 `call.end`**（没有 store）。把 store 挂在会话上，
  /// 两条路径都能发信令，而不用给 UI 传参。
  RemoteStore? store;
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
    // `type` 是信封**唯一**留在顶层的业务字段（见 `RcMessage.toJson`）；
    // 其余（callId/sdp/candidate…）都在 `payload` 内，必须走 `rcPayloadOf`。
    final type = m['type'] as String? ?? '';
    final payload = rcPayloadOf(m);
    if (type == RcCmd.callAnswer) {
      final sdp = payload['sdp'] as String? ?? '';
      final kind = payload['sdpType'] as String? ??
          payload['kind'] as String? ??
          'answer';
      unawaited(_applyAnswer(s, sdp, kind));
    } else if (type == RcCmd.callCandidate) {
      final c = payload['candidate'];
      if (c is Map) unawaited(_applyCandidate(s, c.cast<String, dynamic>()));
    } else if (type == RcCmd.callEnd) {
      // BUG-136：对端已经发了 `call.end`，**不能再回一条** —— 否则两端互相
      // 回 end，形成"挂断风暴"（每条 end 都触发对方再发一条）。
      unawaited(hangUp(deviceId, notifyPeer: false));
    }
  }

  Future<void> _applyAnswer(MultiCallSession s, String sdp, String kind) async {
    final pc = s.pc;
    if (pc == null || sdp.isEmpty) return;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, kind));
      // 应答到达 ⇒ "等待应答"到此结束（否则 45s 后会把一路**已经应答**的
      // 会话报成"对方无应答"）。
      s.answered = true;
      _cancelWaitTimer(s);
      // 应答已到 → 启动"等媒体连通"计时（BUG-081）：ICE 不通就判失败收场。
      _startConnectTimer(s);
    } on Object {
      // 信令异常：标记失败，让 UI 能显示"这路没连上"，而不是停在"连接中"。
      _cancelWaitTimer(s);
      _cancelConnectTimer(s);
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

  /// 启动"等待应答"计时（本服务只负责**本机发起**的 outbound，故 `isCaller: true`）。
  ///
  /// 上限与"超时是否算未接"的判定**全部复用** `call_lifecycle.dart` 的纯函数
  /// （[waitLimitMs] / [timedOutMeansMissed]），不另造一套 ——
  /// 两处超时值一旦漂移，同一台设备在"单路"与"多路"下会得到不同结论。
  void _startWaitTimer(MultiCallSession s) {
    _cancelWaitTimer(s);
    s.answered = false;
    final limit = Duration(milliseconds: waitLimitMs(isCaller: true));
    final sw = Stopwatch()..start();
    s.waitTimer = Timer(limit, () {
      // 到点时复核：期间可能已应答，也可能本路已被挂断移除。
      if (!timedOutMeansMissed(
          answered: s.answered,
          elapsedMs: sw.elapsedMilliseconds,
          limit: limit)) {
        return;
      }
      s.phase = MultiCallPhase.failed;
      s.failure = '对方无应答';
      _notify();
      unawaited(hangUp(s.peer.deviceId));
    });
  }

  void _cancelWaitTimer(MultiCallSession s) {
    s.waitTimer?.cancel();
    s.waitTimer = null;
  }

  /// 启动"等媒体连通"计时（BUG-081，answer 到位后调用）。
  ///
  /// 上限复用 `call_lifecycle.dart` 的 [connectTimeout] / [connectTimedOut]，
  /// 与 `CallService` 保持一致 —— 同一台设备在单路/多路下不该有不同结论。
  void _startConnectTimer(MultiCallSession s) {
    _cancelConnectTimer(s);
    final sw = Stopwatch()..start();
    s.connectTimer = Timer(connectTimeout, () {
      // 到点复核：可能已经连通，也可能本路已被挂断移除。
      if (!_sessions.containsKey(s.peer.deviceId)) return;
      if (!connectTimedOut(
          connected: s.phase == MultiCallPhase.connected,
          elapsedMs: sw.elapsedMilliseconds)) {
        return;
      }
      s.phase = MultiCallPhase.failed;
      s.failure = '连接失败（多处于对称 NAT 时需配置 TURN）';
      _notify();
      unawaited(hangUp(s.peer.deviceId));
    });
  }

  void _cancelConnectTimer(MultiCallSession s) {
    s.connectTimer?.cancel();
    s.connectTimer = null;
  }

  /// 连接一台设备（发起一路 outbound 会话）。
  ///
  /// 返回 false 表示**没能发出** invite（缺本地媒体 / 建 PC 失败 / 端点离线）。
  /// 注意：返回 true 只代表 invite 已发出，不代表已连通 —— 连通看
  /// [MultiCallSession.phase]。
  /// 多路并发的**全局上限**（R90-12）。
  ///
  /// 旧实现只有"同设备不重复"与"单路通话互斥"两个守卫，**没有路上限** ——
  /// 配对 10 台即可建 10 条 `RTCPeerConnection`（每路独立编解码）。低端机上
  /// "too many video streams simultaneously" 是常见卡顿/摄像头争用根因
  /// （本文件 :91 的注释早已承认风险，却从未落为上限）。
  /// 4 路 = 单屏 2×2 的可用上限，也是中端机的编解码预算。
  static const int maxConcurrentSessions = 4;

  /// 宿主测试接缝：替换 [CallService.peerConnectionConfig]（R97-MC-02 用）。
  ///
  /// 为什么需要它：入表之后的**第一个** await 就是取 PC 配置，而竞态锁必须
  /// 能把 [connect] 精确停在这个"会话已在表里、`s.pc` 仍为 null"的窗口内
  /// （正是审计点名的场景：`hangUp()` 此时摘表，`s.pc` 还是 null ⇒ 它关不掉
  /// 随后才建好的那个 PC）。宿主机上没有第二个可注入的延迟点。
  /// 生产代码**永不**赋值 ⇒ 行为与直接调用 `CallService.peerConnectionConfig` 完全一致。
  @visibleForTesting
  static Future<Map<String, dynamic>> Function()? debugPeerConnectionConfig;

  /// 当前是否已达并发上限（供 UI 给出可执行提示）。
  bool get atCapacity => _sessions.length >= maxConcurrentSessions;

  Future<bool> connect(PairedEndpoint peer, RemoteStore store,
      {bool video = true}) async {
    final deviceId = peer.deviceId;
    if (_sessions.containsKey(deviceId)) return false; // 已有一路
    // R90-12：全局路上限（先于取媒体判断 —— 达到上限时不应再申请摄像头）。
    if (atCapacity) return false;
    // BUG-137：单会话通话（含来电/屏幕共享）正在进行时**不得**再起多路。
    // 两个服务各自 `getUserMedia` 会争同一台摄像头：后到的那个直接失败，
    // 或者更糟 —— 抢走前一个的相机句柄，让**正在进行的通话黑屏**。
    // 两者共用同一套麦克风/扬声器路由，互斥是硬约束（见 CallService 类注释）。
    if (CallService.instance.inCall) return false;
    if (_localStream == null && !await _ensureLocalStream(video: video)) {
      return false;
    }
    final s = MultiCallSession(callId: const Uuid().v4(), peer: peer)
      ..store = store;
    _sessions[deviceId] = s;
    _byCallId[s.callId] = deviceId;
    _activeId ??= deviceId;
    _notify();

    // ⚠️ R88-AUD-04：从入表这一行起，**每一个 await 都可能被 `hangUp()` 插进来**
    // （用户点挂断 / 退出页面 `hangUpAll`）。因此每个 await 之后都必须用
    // [stillCurrent] 复核；不成立就走 [_abortConnect] 收场 —— 绝不发 invite。
    try {
      // ⚠️ 这个分支刻意保留 `CallService.peerConnectionConfig()` 的**字面形状**：
      // `call_ice_test.dart` 的 CS-21 用它断言"多路复用单路那份统一配置"。
      final cfg = debugPeerConnectionConfig != null
          ? await debugPeerConnectionConfig!()
          : await CallService.peerConnectionConfig();
      final pc = s.pc = await createPeerConnection(cfg);
      // 建 PC 之前被摘表时 `s.pc` 还是 null ⇒ `hangUp()` 没关掉这个 PC。
      // 这里必须自查并补关，否则原生 `RTCPeerConnection` 无人释放（泄漏）。
      if (!stillCurrent(_sessions, deviceId, s)) return await _abortConnect(s);
      // 复用同一条本地流：为 N 路各开一次摄像头既耗资源，
      // 也会在部分机型上直接失败（相机被占用）。
      //
      // ⚠️ BUG-077（与 call_service 同源）：addTrack 必须带上本地流。
      // flutter_webrtc 的 Dart 层发的是 `'streamIds': [stream?.id]`，
      // 省略 stream ⇒ 送出 `[null]` ⇒ native `nativeAddTrack` 拿 null 调
      // `JniHelper.getStringBytes` 抛 NPE ⇒ WebRTC `CheckException`
      // `RTC_CHECK(false)` ⇒ SIGABRT（多路视频同连一发即崩即此因）。
      final local = _localStream;
      s.senders = <RTCRtpSender>[];
      if (local != null) {
        for (final t in local.getTracks()) {
          s.senders.add(await pc.addTrack(t, local));
        }
      }
      pc.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          s.remoteStream = event.streams.first;
          _notify();
        }
      };
      pc.onConnectionState = (state) {
        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            // 媒体已连通 ⇒ 必然已应答。这里再确认一次，防止"answer 信令丢了
            // 但媒体通了"的极端情形下超时把一路通话报成"未接"。
            s.answered = true;
            _cancelWaitTimer(s);
            // 媒体通了 → "等建连"计时到此结束（BUG-081）。
            _cancelConnectTimer(s);
            s.phase = MultiCallPhase.connected;
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _cancelWaitTimer(s);
            _cancelConnectTimer(s);
            s.phase = MultiCallPhase.failed;
            s.failure = '连接失败（多处于对称 NAT 时需配置 TURN）';
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _cancelWaitTimer(s);
            _cancelConnectTimer(s);
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
        unawaited(_send(
            peer,
            RcCmd.callCandidate,
            {
              'callId': s.callId,
              'candidate': {
                'candidate': c.candidate,
                'sdpMid': c.sdpMid,
                'sdpMLineIndex': c.sdpMLineIndex,
              },
            },
            store));
      };

      final offer = await pc.createOffer();
      if (!stillCurrent(_sessions, deviceId, s)) return await _abortConnect(s);
      await pc.setLocalDescription(offer);
      // 本地描述就位 → 按**当前并发路数**对本路与既有各路统一下发档位
      // （docs/16 §10）：新加一路会让所有路一起降级，避免低端机编码器过载。
      await _applyProfilesToAll();
      final desc = await pc.getLocalDescription();
      // ⚠️ 这一处复核是**最关键**的一条：它挡在 `call.invite` 之前。
      // 少了它，用户点了挂断、对端照样开始振铃（审计后果第 1 条）。
      if (!stillCurrent(_sessions, deviceId, s)) return await _abortConnect(s);
      final sent = await _send(
          peer,
          RcCmd.callInvite,
          {
            'callId': s.callId,
            'video': video,
            'sdp': desc?.sdp ?? '',
            'type': desc?.type ?? 'offer',
            'fromName': store.deviceName,
          },
          store);
      // invite 的 await 内也可能被挂断：此时 invite 已出门（无法撤回），但本路
      // 已不在表里 —— 既不能起"等待应答"计时器，也不能再走 `hangUp()`（它摘表时
      // 已返回，会把刚建好的 PC 漏在那里）。
      if (!stillCurrent(_sessions, deviceId, s)) return await _abortConnect(s);
      if (!sent) {
        // 端点离线：实时通话不能用 outbox 暂存，直接判失败。
        s.phase = MultiCallPhase.failed;
        s.failure = '端点离线，无法发起通话';
        _notify();
        await hangUp(deviceId);
        return false;
      }
      // invite 已发出 → 开始"等待应答"计时（未接超时）。
      // 没有它，被叫没收到/没接通时本路会**无限停在"连接中…"**，
      // 且没有任何"未接"反馈（与 BUG-050 同形状）。
      _startWaitTimer(s);
      return true;
    } on Object {
      // 异常也可能是"await 期间被挂断"的副产品（例如 PC 已被 `hangUp` 关掉，
      // 随后的 `addTrack`/`createOffer` 必然抛）：此时不能走 `hangUp()`，
      // 它摘表已经返回，会把这一路刚建好的 PC 漏成孤儿。
      if (!stillCurrent(_sessions, deviceId, s)) return await _abortConnect(s);
      s.phase = MultiCallPhase.failed;
      s.failure = '建立连接失败';
      _notify();
      await hangUp(deviceId);
      return false;
    }
  }

  /// [connect] 在 await 期间被判"已不是当前会话"时的收尾（R88-AUD-04）。
  ///
  /// 只做**这一路**的事，且天然幂等：
  /// * 若 `s` 还在表里（`phase` 已被 closed 分支置为 closed），走标准
  ///   [hangUp]，但**不发** `call.end` —— 这一路从没发出过 invite，对端
  ///   根本不知道它的存在，回一条 end 只会制造"挂断风暴"（BUG-136 同源）。
  /// * 若已被 [hangUp] 摘表：它摘表那一刻 `s.pc` 可能还是 null（我们那时还没
  ///   建好 PC），所以由这里补关 —— 这是审计后果第 2 条（原生对象泄漏）的补丁。
  ///   `close()`/`dispose()` 各自吞异常，重复调用也安全。
  ///
  /// 恒返回 `false`（= 没连上），与 [connect] 既有契约一致。
  Future<bool> _abortConnect(MultiCallSession s) async {
    final deviceId = s.peer.deviceId;
    if (identical(_sessions[deviceId], s)) {
      await hangUp(deviceId, notifyPeer: false);
    }
    _cancelWaitTimer(s);
    _cancelConnectTimer(s);
    _byCallId.remove(s.callId);
    final pc = s.pc;
    s.pc = null;
    if (pc != null) {
      try {
        await pc.close();
      } on Object {
        // 关闭失败也要继续 dispose（与 [hangUp] 同处置）。
      }
      try {
        await pc.dispose();
      } on Object {
        // 已释放 / 平台不支持：忽略。
      }
    }
    s.senders = <RTCRtpSender>[];
    s.phase = MultiCallPhase.closed;
    _activeId = nextActiveId(_sessions.keys.toList(), _activeId);
    _notify();
    return false;
  }

  Future<bool> _ensureLocalStream({required bool video}) async {
    try {
      // 与单路同源（docs/16 §10）：走 [videoConstraintsFor] 才有帧率上限，
      // 否则多路 + 无上限帧率会让低端机直接"爆卡"。
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video ? videoConstraintsFor(callVideoCapture) : false,
      });
      // BUG-138：多路视频**必须开免提**。不开时 Android 把声音送到听筒，
      // 视频通话里表现为"能看到画面但听不清"—— 与单路 `_ensureMedia` 同一
      // 处置（那里早就开了，多路这一半漏了，属于两条路漂移）。
      await _setSpeakerphone(true);
      return true;
    } on Object {
      return false;
    }
  }

  /// 本端是否**主动**开过免提（收尾只归位自己开的那次）。
  bool _speakerOn = false;

  /// 切换免提扬声器（平台不支持时静默忽略：它不是通话能否建立的必要条件）。
  Future<void> _setSpeakerphone(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
      _speakerOn = on;
    } on Object {
      // 平台不支持 → 忽略（音频路由偏好失败，不该挡住通话本身）。
    }
  }

  /// 当前**并发视频路数**（有视频 sender 的会话数）。
  ///
  /// 音频路不占视频编码器，因此不能简单用 `_sessions.length` ——
  /// 会低估档位（把 1 路视频 + 2 路语音误判成 3 路视频而降得过狠）。
  int _concurrentVideoSessions() {
    var n = 0;
    for (final s in _sessions.values) {
      if (s.senders.any((x) => x.track?.kind == 'video')) n++;
    }
    return n;
  }

  /// 按当前路数把档位下发给**所有**路（docs/16 §10）。
  ///
  /// 调用时机：**增加一路**（`connect` 里 setLocalDescription 之后）与
  /// **减少一路**（`hangUp` 移除之后）。前者降级、后者恢复更高画质 ——
  /// 只在新路建立时下发、挂断时不恢复，会让剩下的通话一直停在低画质。
  ///
  /// ⚠️ 失败一律吞掉（[applySendProfileToSenders] 内已处理），不阻塞信令。
  Future<void> _applyProfilesToAll() async {
    final profile = sendProfileFor(_concurrentVideoSessions());
    for (final s in _sessions.values) {
      await applySendProfileToSenders(s.senders, profile);
    }
  }

  Future<bool> _send(PairedEndpoint peer, String type,
      Map<String, dynamic> payload, RemoteStore store) async {
    // BUG-135：信令发送**必须**自己兜异常。调用点之一是
    // `pc.onIceCandidate` 里的 `unawaited(_send(...))` —— 那里没有任何
    // try/catch，`sendTo` 抛出的编码/密钥/通道异常会变成**未处理的异步错误**
    // （Release 下没人看见，Debug 下打断整条 ICE 收集）。
    // 语义与 `CallService._sendCallMsg` 对齐：发不出去 = false，由调用方决定收场。
    try {
      return await RcEndpointService.instance.sendTo(
        peer,
        RcMessage.now(type, payload),
        store,
        enqueueOnFail: false,
      );
    } on Object {
      return false;
    }
  }

  /// 挂断一路（不影响其它路 —— 这是"保持视频链接"的关键）。
  ///
  /// [notifyPeer] 为 false 时**不发** `call.end`（对端先发的场景，见 BUG-136）。
  Future<void> hangUp(String deviceId, {bool notifyPeer = true}) async {
    final s = _sessions.remove(deviceId);
    if (s == null) return;
    _cancelWaitTimer(s);
    _cancelConnectTimer(s);
    _byCallId.remove(s.callId);
    // BUG-136：主动挂断必须**告诉对端**。旧实现只关本地 PC —— 对端仍以为
    // 通话在继续（摄像头/麦克风照开、UI 停在"已连接"），直到它自己的
    // 45s 超时才发现。这与单路 `CallService.hangUp` 的行为也不一致。
    final store = s.store;
    if (notifyPeer && store != null) {
      await _send(s.peer, RcCmd.callEnd,
          {'callId': s.callId, 'reason': 'hangup'}, store);
    }
    // BUG-134：`close()` 只断连接，**不释放**原生 PeerConnection 与它注册的
    // EventChannel。只 close 不 dispose ⇒ 每挂一路泄漏一个原生对象；
    // 反复连/挂若干次后原生侧句柄堆积（`getStats`/渲染回调继续投递到已废弃
    // 的 Dart 对象）。两步都要做，且各自吞异常（关不掉也要把状态清干净）。
    final pc = s.pc;
    s.pc = null;
    if (pc != null) {
      try {
        await pc.close();
      } on Object {
        // 关闭失败也要继续 dispose。
      }
      try {
        await pc.dispose();
      } on Object {
        // 已释放 / 平台不支持：忽略。
      }
    }
    s.phase = MultiCallPhase.closed;
    // sender 随 `s.pc` 一起失效，断开引用避免后续误用。
    s.senders = <RTCRtpSender>[];
    if (_sessions.isEmpty) {
      _localStream?.getTracks().forEach((t) => unawaited(t.stop()));
      _localStream = null;
      // 最后一路结束 → 归位免提（只关本端自己开过的那次）。
      if (_speakerOn) await _setSpeakerphone(false);
    }
    _activeId = nextActiveId(_sessions.keys.toList(), _activeId);
    // 路数下降 → 对**剩余各路恢复更高档位**（docs/16 §10）：只在新路建立时
    // 降级、挂断时不恢复，会让剩下的通话一直停在低画质。
    if (_sessions.isNotEmpty) await _applyProfilesToAll();
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

  /// 宿主测试接缝（第三十八轮新增；**不改任何既有方法的签名或行为**）。
  ///
  /// ## 为什么需要它
  /// [_sessions] / [_activeId] 全私有，而宿主上 [connect] **恒返回 false**
  /// —— `getUserMedia` 与 `createPeerConnection` 没有另一侧（相机、对端均不存在），
  /// 也就是说"会话"这件事在宿主机上**没有任何生产来源**。
  /// 后果：`multi_video_screen.dart` 的窗口栅格、`_VideoTile`（约 100 行）、
  /// 底部指令条**结构上一条都执行不到** —— 它们只在 `sessions` 非空时才构建。
  ///
  /// 这里只提供「注入会话 + 还原」的最小通道（与 `RcEndpointService.debugBind`、
  /// `CallService.setPhaseForTest` 同形），让**只能靠锁**的那几类分支可被断言：
  /// 焦点切换（切换不得挂断其它路）、逐路挂断、相位文案档位、指令条目标。
  ///
  /// ⚠️ 仅 `@visibleForTesting`：生产代码绝不调用 —— `analysis_options.yaml`
  /// 已把 `invalid_use_of_visible_for_testing_member` 设为 **error**。
  /// ⚠️ 注入的会话**不带 [MultiCallSession.pc] / [MultiCallSession.waitTimer]**
  /// （宿主上不可能有真的 PC），因此本方法不产生任何真实信令或计时器。
  @visibleForTesting
  void debugSeed(Iterable<MultiCallSession> sessions, {String? activeId}) {
    for (final s in sessions) {
      _sessions[s.peer.deviceId] = s;
      _byCallId[s.callId] = s.peer.deviceId;
    }
    // 显式传 [activeId] 时以它为准（测试要能从"非第一路"起步）。
    _activeId = activeId ?? _activeId;
    // 与 [connect] 的 `_activeId ??= deviceId` 同一语义：第一路自动成为焦点。
    _activeId ??= _sessions.isEmpty ? null : _sessions.keys.first;
    _notify();
  }

  /// 清空注入的会话并把焦点复位（宿主测试的 `tearDown` 用）。
  ///
  /// ⚠️ 与 [dispose] 的差别：**不关闭** [_updates] 控制器 ——
  /// 测试要在同一进程里反复「注入 → 断言 → 还原」，控制器一旦 close
  /// 就再也订不上，后续用例全部假绿。
  @visibleForTesting
  void debugClear() {
    for (final s in _sessions.values) {
      _cancelWaitTimer(s);
      _cancelConnectTimer(s);
    }
    _sessions.clear();
    _byCallId.clear();
    _activeId = null;
    _notify();
  }

  Future<void> dispose() async {
    await _evtSub?.cancel();
    _evtSub = null;
    await hangUpAll();
    await _updates.close();
  }
}
