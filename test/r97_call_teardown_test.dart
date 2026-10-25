/// R97：`CallService._teardown` 的重入闸 + 会话代次 —— **R88-AUD-05（P2）** 的回归锁。
///
/// ## 缺陷本体（`_pt/audit/r88_bugscan_remote_services.md` · R88-AUD-05）
///
/// `_teardown` 会 `await _pc?.close()`；而 `close()` 会让
/// `onConnectionState` 变成 `closed`，那里又调一次 `_teardown()`。第一次收尾
/// **停在 await 上**时第二次就进来了：同一个 `RTCPeerConnection` 被
/// `close()` / `dispose()` 两次（flutter_webrtc 的原生 dispose **非幂等**）。
/// 更狠的一面：第二次收尾若跨越了 await 才恢复，此时用户已经发起**新通话**，
/// 它会把新会话的 `_pc` / `_callId` / `_phase` 一起清掉 —— 新通话被一条
/// 陈旧收尾打死。
///
/// ## 本文件怎么驱动（不碰真实 WebRTC / 真实网络 / 长等待）
///
/// 用**本文件内的平台通道替身**（`_FakeRtcPlatform`）把"手机那边"换掉，
/// 被驱动的仍是真实的 `call_service.dart`。替身提供两样宿主拿不到的东西：
///
/// 1. **可控延迟**：`closeGates` 让第 N 次 `peerConnectionClose` 挂在
///    `Completer` 上 —— 这正是复刻"第一次收尾停在 await 上"的唯一手段；
/// 2. **真实副作用**：`peerConnectionClose` 会像原生那样把连接状态推到
///    `closed`，于是"二次进入"是**真的由 close 的副作用触发**的，
///    不是测试手工再喊一次 `_teardown`（后者锁不住任何东西）。
///
/// ⚠️ 不用 `test/support/webrtc_stub.dart`：它是共享文件（本轮只允许新建本
/// 文件），且它不提供"挂起 close"与"close 触发 closed"这两个能力。
///
/// ## 明确不测什么
///
/// * **不测** `onIncomingCall` 里 `CalleeAction.rejectBusy => false` 那条 switch 臂
///   （任务单标的 `:632`，改前行号）：它**结构不可达** —— 同一取值在上面的
///   `if (action == CalleeAction.rejectBusy)` 处已经 `return false`，而 `action`
///   之后只可能被改成 `ringUser`，所以 `return switch (action)` 永远收不到
///   `rejectBusy`；保留该臂只为让 switch **穷尽**（将来加枚举值会编译报错）。
///   R97-CS-04 锁的是"它为什么不可达"，而不是硬凑一行覆盖。
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/remote/call_lifecycle.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// `flutter_webrtc 1.6.2+hotfix.3` 平台通道替身（**只**复刻通道名与返回形状）。
///
/// 与 `test/support/webrtc_stub.dart` 的差别只有两点，而这两点正是本缺陷
/// 需要的：`peerConnectionClose` **可挂起**、并且会**真的**推出 `closed` 状态。
class _FakeRtcPlatform {
  static const MethodChannel _method = MethodChannel('FlutterWebRTC.Method');
  static const MethodChannel _globalEvent = MethodChannel('FlutterWebRTC.Event');

  /// 按调用顺序记录的方法名。
  final List<String> methods = <String>[];

  /// `peerConnectionId` → `peerConnectionClose` 次数（**双关就是缺陷本体**）。
  final Map<String, int> closeById = <String, int>{};

  /// `peerConnectionId` → `peerConnectionDispose` 次数（原生 dispose 非幂等）。
  final Map<String, int> disposeById = <String, int>{};

  /// 依次消费的 `peerConnectionClose` 闸门（第 N 次 close 挂第 N 个）。
  final List<Completer<void>> closeGates = <Completer<void>>[];

  /// 建过的 pc id（`pc-1`、`pc-2`…）。
  final List<String> pcIds = <String>[];

  /// `enableSpeakerphone` 抛 `PlatformException`（复刻"平台不支持免提"）。
  bool failSpeakerphone = false;

  /// `peerConnectionClose` 是否像原生那样把状态推到 `closed`（**缺陷的引信**）。
  bool emitClosedOnClose = true;

  int _pcSeq = 0;
  int _senderSeq = 0;

  bool _installed = false;
  final List<String> _eventChannels = <String>[];

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  static const String _sdp =
      'v=0\r\no=- 4611 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n';

  void install() {
    if (_installed) return;
    _installed = true;
    _messenger.setMockMethodCallHandler(_method, _handle);
    // 插件懒建的全局事件通道：不打桩会以 MissingPluginException 上报成用例失败。
    _messenger.setMockMethodCallHandler(_globalEvent, (call) async => null);
  }

  /// 清空观测面与可编程开关（跨用例隔离；不动已安装的通道桩）。
  void reset() {
    methods.clear();
    closeById.clear();
    disposeById.clear();
    closeGates.clear();
    pcIds.clear();
    failSpeakerphone = false;
    emitClosedOnClose = true;
    _pcSeq = 0;
    _senderSeq = 0;
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    _messenger.setMockMethodCallHandler(_method, null);
    _messenger.setMockMethodCallHandler(_globalEvent, null);
    for (final name in _eventChannels) {
      _messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    _eventChannels.clear();
  }

  /// 往某个 pc 的事件通道推一条平台事件（**从平台到框架**方向）。
  Future<void> pushEvent(String pcId, Map<String, dynamic> event) async {
    await _messenger.handlePlatformMessage(
      'FlutterWebRTC/peerConnectionEvent$pcId',
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  /// 推一条连接状态事件（`connected` / `failed` / `closed` …）。
  Future<void> pushState(String pcId, String state) => pushEvent(pcId, {
        'event': 'peerConnectionState',
        'state': state,
      });

  static Map<String, dynamic> _track(String id, String kind) => {
        'id': id,
        'label': id,
        'kind': kind,
        'enabled': true,
        'settings': <String, dynamic>{},
      };

  /// `RTCRtpParameters.fromMap` 要求四个键都非 null，且 `rtcp` 的两个
  /// 位置参数不能为 null（`cname` / `reducedSize`）。
  static Map<String, dynamic> _rtpParameters() => {
        'transactionId': 'tx-1',
        'encodings': <dynamic>[],
        'headerExtensions': <dynamic>[],
        'codecs': <dynamic>[],
        'rtcp': {'cname': 'fake-cname', 'reducedSize': false},
        'degradationPreference': null,
      };

  Future<Object?> _handle(MethodCall call) async {
    methods.add(call.method);
    final rawArgs = call.arguments;
    final args = rawArgs is Map
        ? rawArgs.cast<String, dynamic>()
        : <String, dynamic>{};
    switch (call.method) {
      case 'getUserMedia':
        {
          final rawConstraints = args['constraints'];
          final constraints = rawConstraints is Map
              ? rawConstraints.cast<String, dynamic>()
              : <String, dynamic>{};
          final wantVideo =
              constraints['video'] != null && constraints['video'] != false;
          return <String, dynamic>{
            'streamId': 'stream-${_pcSeq + 1}',
            'audioTracks': <dynamic>[_track('local-audio', 'audio')],
            'videoTracks': <dynamic>[
              if (wantVideo) _track('local-video', 'video'),
            ],
          };
        }
      case 'createPeerConnection':
        {
          final id = 'pc-${++_pcSeq}';
          pcIds.add(id);
          final channel = 'FlutterWebRTC/peerConnectionEvent$id';
          _eventChannels.add(channel);
          _messenger.setMockMethodCallHandler(
              MethodChannel(channel), (c) async => null);
          return <String, dynamic>{'peerConnectionId': id};
        }
      case 'createOffer':
        return <String, dynamic>{'sdp': _sdp, 'type': 'offer'};
      case 'createAnswer':
        return <String, dynamic>{'sdp': _sdp, 'type': 'answer'};
      case 'getLocalDescription':
        return <String, dynamic>{'sdp': _sdp, 'type': 'offer'};
      case 'setRemoteDescription':
        return null;
      case 'addCandidate':
        return null;
      case 'addTrack':
        {
          final trackId = '${args['trackId']}';
          return <String, dynamic>{
            'senderId': 'sender-${_senderSeq++}',
            'track':
                _track(trackId, trackId.contains('video') ? 'video' : 'audio'),
            'rtpParameters': _rtpParameters(),
            'ownsTrack': false,
          };
        }
      case 'rtpSenderSetParameters':
        return <String, dynamic>{'result': true};
      case 'enableSpeakerphone':
        if (failSpeakerphone) {
          throw PlatformException(code: 'noSpeaker', message: '不支持免提');
        }
        return null;
      case 'peerConnectionClose':
        {
          final id = '${args['peerConnectionId']}';
          final n = (closeById[id] ?? 0) + 1;
          closeById[id] = n;
          // ⚠️ 缺陷的引信：真实原生在 close 时把状态推到 closed，
          // Dart 侧随即回调 `onConnectionState` ⇒ 二次进入 `_teardown`。
          // 只在**第一次** close 时推：已关闭的 pc 再 close 不会重放状态。
          if (emitClosedOnClose && n == 1) {
            unawaited(pushState(id, 'closed'));
          }
          // 可控延迟：让第一次收尾真的"停在 await 上"。
          if (closeGates.isNotEmpty) {
            await closeGates.removeAt(0).future;
          }
          return null;
        }
      case 'peerConnectionDispose':
        {
          final id = '${args['peerConnectionId']}';
          disposeById[id] = (disposeById[id] ?? 0) + 1;
          return null;
        }
      case 'trackDispose':
        return null;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rtc = _FakeRtcPlatform();
  final svc = CallService.instance;
  final endpointSvc = RcEndpointService.instance;

  late RemoteStore store;
  final sent = <RcMessage>[];

  PairedEndpoint peer(String id) => PairedEndpoint(
        deviceId: id,
        name: '客厅手机',
        secret: 'SECRET01',
        pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  /// 推进真实事件循环若干轮（服务层是真实异步，不用 fake-async）。
  Future<void> settle([int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = RemoteStore(await SharedPreferences.getInstance());
    CallService.bindStore(() async => store);
    sent.clear();
    rtc
      ..reset()
      ..install();
    endpointSvc.debugSendTo = (ep, msg, st, enqueueOnFail) async {
      sent.add(msg);
      return true;
    };
  });

  tearDown(() async {
    // 收尾：把单例推回 idle，否则下一例从脏相位开始（且 45s 计时器会跨例残留）。
    // 先放行所有还挂着的 close 闸门：本用例若在断言处提前失败，收尾可能还停在
    // `await pc.close()` 上 —— 不放行会让下一例看到 `_tearingDown == true`（假红）。
    for (final g in rtc.closeGates) {
      if (!g.isCompleted) g.complete();
    }
    rtc.closeGates.clear();
    await svc.onRemoteEnd();
    await settle(6);
    endpointSvc.debugSendTo = null;
    rtc.uninstall();
  });

  group('R97-A teardown 重入闸（R88-AUD-05）', () {
    test('R97-CS-01 closed 副作用在 close 期间二次进入 → 只 close 一次、只 dispose 一次',
        () async {
      final id = await svc.startCall(peer('EP9701'), store, video: false);
      expect(id, isNotNull, reason: '前置：必须真的建了 PeerConnection');
      final pcId = rtc.pcIds.single;

      // 第一次收尾挂在 close 上（模拟"从入口到 `_pc = null` 之间有多处 await"）。
      final gate = Completer<void>();
      rtc.closeGates.add(gate);

      final hanging = svc.hangUp(store);
      // 让 close 的 `closed` 副作用真的到达 —— 它会二次进入 `_teardown`。
      await settle(8);
      expect(rtc.closeById[pcId], 1,
          reason: '二次进入必须被同步闸挡在门外：同一个 pc 被 close 两次 ⇒ '
              '原生侧 double-free（dispose 非幂等，异常虽被 on Object 吞掉，'
              'native 已经 double-free）');

      // 第二条收尾路径也来一脚（`call.end` 与本地挂断同时到达是常态）。
      // 它必须被闸门直接返回，而不是把"已挂断"改写成"对方挂断"。
      await svc.onRemoteEnd();
      await settle(2);
      expect(rtc.closeById[pcId], 1, reason: '并发的第二条收尾不得再关一遍');
      expect(rtc.disposeById[pcId] ?? 0, 0, reason: '第一次收尾还挂在 close 上');

      gate.complete();
      await hanging;
      await settle(4);

      expect(rtc.closeById[pcId], 1, reason: '收尾结束后仍应只关过这一次');
      expect(rtc.disposeById[pcId], 1,
          reason: '同一 pc 被 dispose 两次是 R88-AUD-05 的直接症状');
      expect(svc.currentPhase, CallPhase.idle);
      expect(svc.callId, isNull);
      expect(svc.lastEndReason, CallEndReason.hangup,
          reason: '二次进入不得用"没有语义的结束"覆盖真正的原因（BUG-050）');
    });

    test('R97-CS-02 陈旧代次的收尾恢复后，不得清掉刚建立的新通话', () async {
      // ── 第一通：收尾挂在 close#1 上，closed 副作用引出**第二次**收尾 ──
      final first = await svc.startCall(peer('EP9702'), store, video: false);
      expect(first, isNotNull);
      final oldPc = rtc.pcIds.single;

      final gate1 = Completer<void>(); // 第一次收尾
      final gate2 = Completer<void>(); // 第二次（重入）收尾
      rtc.closeGates
        ..add(gate1)
        ..add(gate2);

      final hanging = svc.hangUp(store);
      await settle(8); // 第二次收尾已经进来并挂住（修复后：根本进不来）

      gate1.complete(); // 第一次收尾走完 ⇒ 相位经 microtask 回到 idle
      await hanging;
      await settle(4);
      expect(svc.currentPhase, CallPhase.idle, reason: '前置：第一通已收尾');

      // ── 用户立刻发起第二通（新 pc / 新 callId）──
      final second = await svc.startCall(peer('EP9703'), store, video: false);
      expect(second, isNotNull, reason: '前置：新通话必须真的建立');
      final newPc = rtc.pcIds.last;
      expect(newPc, isNot(oldPc));

      // ── 释放那条陈旧的第二次收尾：它此刻才恢复 ──
      gate2.complete();
      await settle(8);

      expect(svc.callId, second,
          reason: '陈旧收尾清掉 `_callId` ⇒ 新通话在 UI 与信令两侧都"不存在了"，'
              '而 pc 还连着 —— 这是 R88-AUD-05 最狠的一面');
      expect(svc.currentPhase, CallPhase.connecting,
          reason: '新通话被上一代的收尾打到 ended/idle ⇒ 界面直接退回，通话却还在跑');
      expect(svc.inCall, isTrue);
      expect(rtc.closeById[newPc], isNull,
          reason: '旧代次的手绝不能碰到新会话的 PeerConnection');
    });

    test('R97-CS-03 没有收尾在飞时，closed 副作用仍必须真的收尾（身份守卫不得误伤）',
        () async {
      final id = await svc.startCall(peer('EP9704'), store, video: false);
      expect(id, isNotNull);
      final pcId = rtc.pcIds.single;

      // 纯 `closed`（对端/原生侧关连接），没有任何本地收尾在飞。
      await rtc.pushState(pcId, 'closed');
      await settle(6);

      expect(svc.currentPhase, CallPhase.idle,
          reason: '身份守卫只该挡"不属于本代的 pc"，不能把合法的 closed 一起挡掉 —— '
              '否则底层已断而 UI 永远停在"通话中"');
      expect(svc.callId, isNull);
      expect(rtc.closeById[pcId], 1, reason: '收尾只关这一次');
      expect(rtc.disposeById[pcId], 1);

      // 幂等：再收一次不得重复 close（`_pc` 已摘空）。
      await svc.onRemoteEnd();
      await settle(2);
      expect(rtc.closeById[pcId], 1,
          reason: '收尾必须可重入调用而不重复关资源（多条路径都会调它）');
      expect(rtc.disposeById[pcId], 1);
    });
  });

  group('R97-B 覆盖率判定', () {
    test('R97-CS-04 rejectBusy 的 switch 臂结构不可达（提前 return 已覆盖该取值）',
        () async {
      // 判定链（改前行号）：`calleeActionFor` 在 `inCall` 时**只**返回 rejectBusy；
      // 而 `onIncomingCall` 在 `if (action == CalleeAction.rejectBusy)` 处
      // 已经 `return false`（:604），`action` 之后只可能被改成 `ringUser`（:602）
      // ⇒ `return switch (action)`（:628）永远收不到 rejectBusy ⇒ `:632` 不可达。
      expect(calleeActionFor(autoAnswer: true, inCall: true),
          CalleeAction.rejectBusy,
          reason: '占线判定在纯函数里只有这一个出口');

      final first = await svc.startCall(peer('EP9705'), store, video: false);
      expect(first, isNotNull, reason: '前置：必须先处于通话中');
      sent.clear();

      final ok = await svc.onIncomingCall(
          <String, dynamic>{'callId': 'C-97-04', 'sdp': 'x'},
          peer('EP9706'),
          store);

      expect(ok, isFalse, reason: '占线必须明确拒掉，而不是静默丢弃');
      expect(sent.single.type, RcCmd.callEnd);
      expect(sent.single.payload['reason'], 'busy',
          reason: '主叫要立刻拿到"对方占线"，不能白等到超时');
      expect(svc.callId, first,
          reason: '占线路径在提前 return 处就结束了 ⇒ 走不到那条 switch 臂，也不该动本通话');
      expect(svc.currentPhase, CallPhase.connecting);
    });
  });
}
