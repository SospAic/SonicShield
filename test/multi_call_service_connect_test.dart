/// `MultiCallService`（多路视频同连）的**行为**驱动 —— 第 45 轮新建。
///
/// ## 为什么这是一个"有测试文件却从没被执行过"的整块
///
/// `multi_video_screen_test.dart`（第三十八轮）用 `debugSeed` 注入**假会话**
/// 把界面的窗口栅格/指令条驱动了起来，但它**绕过了 [MultiCallService.connect]
/// 本身** —— 会话是塞进去的，不是连出来的。于是服务层 179 行里 **100 行**
/// （`connect` 主链、`_applyAnswer`、`_applyCandidate`、`_onRemoteEvent`、
/// `onConnectionState` 全部分支）**从未被执行过**。
///
/// 这正是 `docs/17 §74` **判据第五代**的形状：**"界面有专属测试"、"纯函数被锁死"
/// 都不等于"这条服务路径被执行过"**。
///
/// ## 驱动方式
///
/// 与 `call_service_webrtc_test.dart` 同一套：`test/support/webrtc_stub.dart`
/// 复刻 `flutter_webrtc` 的**真实通道名与返回形状**，被驱动的仍是真实服务代码；
/// 出站信令走 `RcEndpointService.debugSendTo` 替身（`sendTo` 的成功分支要求
/// 一个 connected 的 MQTT 客户端，宿主机结构性不可达）。
///
/// ## 明确不测什么
///
/// - **不测**真实媒体协商与纹理渲染（同 `multi_video_screen_test.dart` 的边界）。
/// - **不测** 45s 真实超时到点：`_startWaitTimer` 的回调要等 45 秒；超时**判定**
///   已由 `call_lifecycle_test.dart` 的纯函数锁死。
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/multi_call_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/webrtc_stub.dart';

/// 出站替身记下的一条"已发出的信令"。
class _Sent {
  _Sent(this.msg, this.enqueueOnFail);

  final RcMessage msg;
  final bool enqueueOnFail;

  String get type => msg.type;
  Map<String, dynamic> get payload => msg.payload;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rtc = FakeWebrtc();
  final svc = MultiCallService.instance;
  final endpointSvc = RcEndpointService.instance;

  late RemoteStore store;
  late List<_Sent> sent;
  late bool sendOk;

  PairedEndpoint peer(String id) => PairedEndpoint(
        deviceId: id,
        name: '设备-$id',
        secret: 'SECRET01',
        pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  Future<void> settle([int rounds = 10]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    rtc.failUserMedia = false;
    rtc.failCreateOffer = false;
    rtc.withAudioTrack = true;
    rtc.withVideoTrack = true;
    rtc.localSdp = 'v=0\r\no=- 4611 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n';
    rtc.resetObservations();
    rtc.install();

    await svc.hangUpAll();
    svc.debugClear();

    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = RemoteStore(await SharedPreferences.getInstance());
    sent = <_Sent>[];
    sendOk = true;
    endpointSvc.debugSendTo = (ep, msg, st, enqueueOnFail) async {
      sent.add(_Sent(msg, enqueueOnFail));
      return sendOk;
    };
  });

  tearDown(() async {
    await svc.hangUpAll();
    svc.debugClear();
    // ⚠️ 顺序要紧：`hangUp` 里的 `unawaited(t.stop())` 会在**微任务**里
    // 才把 `trackDispose` 发到通道上（`WebRTC.invokeMethod` 是 async）。
    // 若紧接着就 `uninstall()`，那次发送会撞上"没有桩"⇒
    // `MissingPluginException` 记在**下一个**用例头上（第 45 轮实测）。
    await settle(3);
    endpointSvc.debugSendTo = null;
    rtc.uninstall();
  });

  // ══════════════════════════ connect 主链 ══════════════════════════

  group('MC-A connect：发起一路 outbound 会话', () {
    test('MC-01 成功 → invite 载荷齐全、相位 connecting、第一路成为焦点', () async {
      final ok = await svc.connect(peer('EP01'), store, video: true);
      expect(ok, isTrue);
      expect(svc.sessions, hasLength(1));
      expect(svc.activeId, 'EP01', reason: '第一路自动成为指令目标');
      final s = svc.sessionOf('EP01')!;
      expect(s.phase, MultiCallPhase.connecting);
      expect(s.pc, isNotNull);
      final m = sent.single.msg;
      expect(m.type, RcCmd.callInvite);
      expect(m.payload['callId'], s.callId);
      expect(m.payload['sdp'], rtc.localSdp);
      expect(m.payload['type'], 'offer');
      expect(m.payload['video'], isTrue);
      expect(m.payload['fromName'], store.deviceName);
      expect(sent.single.enqueueOnFail, isFalse,
          reason: '实时通话信令不得靠 outbox 补发');
      expect(rtc.called('createPeerConnection'), isTrue);
      expect(rtc.called('setLocalDescription'), isTrue);
    });

    test('MC-02 取流失败 → 不建会话（返回 false）', () async {
      rtc.failUserMedia = true;
      final ok = await svc.connect(peer('EP02'), store);
      expect(ok, isFalse);
      expect(svc.sessions, isEmpty);
      expect(rtc.called('createPeerConnection'), isFalse);
    });

    test('MC-03 同一设备已有会话 → 直接 false，不重复取流', () async {
      await svc.connect(peer('EP03'), store);
      rtc.resetObservations();
      sent.clear();
      expect(await svc.connect(peer('EP03'), store), isFalse);
      expect(rtc.called('getUserMedia'), isFalse);
      expect(sent, isEmpty);
    });

    test('MC-04 端点离线（sendTo=false）→ 该路判失败并从列表移除', () async {
      sendOk = false;
      final ok = await svc.connect(peer('EP04'), store);
      expect(ok, isFalse);
      expect(svc.sessions, isEmpty);
      expect(svc.activeId, isNull);
    });

    test('MC-05 createOffer 抛错 → 该路失败且不留半开会话', () async {
      rtc.failCreateOffer = true;
      final ok = await svc.connect(peer('EP05'), store);
      expect(ok, isFalse);
      expect(svc.sessions, isEmpty, reason: '半开会话会一直显示"连接中…"');
      expect(rtc.called('createPeerConnection'), isTrue);
    });

    test('MC-06 多路复用同一条本地流（相机只开一次）', () async {
      expect(await svc.connect(peer('EP06'), store), isTrue);
      expect(await svc.connect(peer('EP07'), store), isTrue);
      expect(svc.sessions, hasLength(2));
      expect(rtc.countOf('getUserMedia'), 1,
          reason: '为 N 路各开一次相机会在部分机型上直接失败（相机被占用）');
      expect(rtc.countOf('createPeerConnection'), 2);
      expect(svc.activeId, 'EP06', reason: '焦点仍在第一路（不因新增而跳走）');
    });

    test('MC-07 语音模式：video 约束为 false 且 invite 如实标注', () async {
      await svc.connect(peer('EP08'), store, video: false);
      final constraints = rtc.constraintsOf('getUserMedia');
      expect(constraints['video'], isFalse);
      expect(sent.single.payload['video'], isFalse);
    });

    test('MC-07b ★ addTrack 必须带本地流（BUG-077：多路同连一发即崩同源）',
        () async {
      // 与 CS-07b 同一条链：flutter_webrtc Dart 层 `'streamIds': [stream?.id]`
      // 省略 stream ⇒ `[null]` ⇒ native `nativeAddTrack` 的
      // `JniHelper.getStringBytes(null)` NPE ⇒ WebRTC `RTC_CHECK(false)` ⇒ SIGABRT。
      // 多路视频同连走的就是 `MultiCallService.connect` 这条建立路径。
      final ok = await svc.connect(peer('EP09'), store, video: true);
      expect(ok, isTrue);
      final args = rtc.lastArgs('addTrack');
      expect(args, isNotNull, reason: '必须真的调了 addTrack（否则本地轨没挂上）');
      final ids = args!['streamIds'] as List;
      expect(ids.length, 1);
      expect(ids.first, isNotNull,
          reason: 'streamIds[0] 为 null ⇒ native addTrack 必崩（BUG-077）');
      expect(ids.first, 'stream-1');
    });
  });

  // ══════════════════════════ 事件路由 ══════════════════════════

  group('MC-B 事件路由：只处理自己的 callId', () {
    test('MC-08 answer → 设远端描述并标记已回答', () async {
      await svc.connect(peer('EP10'), store);
      final s = svc.sessionOf('EP10')!;
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      ctrl.add(<String, dynamic>{
        'type': RcCmd.callAnswer,
        'payload': <String, dynamic>{
          'callId': s.callId,
          'sdp': 'answer-sdp',
          'sdpType': 'answer',
        },
      });
      await settle();
      expect(rtc.called('setRemoteDescription'), isTrue);
      expect(s.answered, isTrue,
          reason: '已应答后残留计时器不得再把这一路报成"对方无应答"');
      await ctrl.close();
      await settle(2);
    });

    test('MC-09 answer 的空 SDP 不得设远端描述（远端数据不可信）', () async {
      await svc.connect(peer('EP11'), store);
      final s = svc.sessionOf('EP11')!;
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      ctrl.add(<String, dynamic>{
        'type': RcCmd.callAnswer,
        'payload': <String, dynamic>{'callId': s.callId, 'sdp': ''},
      });
      await settle();
      expect(rtc.called('setRemoteDescription'), isFalse);
      await ctrl.close();
      await settle(2);
    });

    test('MC-10 candidate → 喂给该路的 PeerConnection', () async {
      await svc.connect(peer('EP12'), store);
      final s = svc.sessionOf('EP12')!;
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      ctrl.add(<String, dynamic>{
        'type': RcCmd.callCandidate,
        'payload': <String, dynamic>{
          'callId': s.callId,
          'candidate': <String, dynamic>{
            'candidate': 'cand-1',
            'sdpMid': '0',
            'sdpMLineIndex': 0,
          },
        },
      });
      await settle();
      expect(rtc.addedCandidates, <String>['cand-1']);
      // 形状不对的候选必须被忽略（不抛、不喂）
      ctrl.add(<String, dynamic>{
        'type': RcCmd.callCandidate,
        'payload': <String, dynamic>{'callId': s.callId, 'candidate': 42},
      });
      await settle();
      expect(rtc.addedCandidates, hasLength(1));
      await ctrl.close();
      await settle(2);
    });

    test('MC-11 别人的 callId（含来电）一律不碰', () async {
      await svc.connect(peer('EP13'), store);
      final s = svc.sessionOf('EP13')!;
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      ctrl.add(<String, dynamic>{
        'type': RcCmd.callAnswer,
        'payload': <String, dynamic>{'callId': 'SOMEONE-ELSE', 'sdp': 'x'},
      });
      ctrl.add(<String, dynamic>{
        'type': RcCmd.callEnd,
        'payload': <String, dynamic>{'callId': 'SOMEONE-ELSE'},
      });
      await settle();
      expect(s.answered, isFalse);
      expect(svc.sessionOf('EP13'), isNotNull,
          reason: '误把别人的 call.end 当成自己的会把这一路无故挂断');
      expect(rtc.called('setRemoteDescription'), isFalse);
      await ctrl.close();
      await settle(2);
    });

    test('MC-12 callId 非字符串不得让整条事件流崩溃', () async {
      await svc.connect(peer('EP14'), store);
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      ctrl.add(<String, dynamic>{
        'type': RcCmd.callAnswer,
        'payload': <String, dynamic>{'callId': 12345, 'sdp': 'x'},
      });
      await settle();
      expect(rtc.called('setRemoteDescription'), isFalse);
      expect(svc.sessionOf('EP14'), isNotNull);
      await ctrl.close();
      await settle(2);
    });

    test('MC-13 对端 call.end → 只挂断对应那一路', () async {
      await svc.connect(peer('EP15'), store);
      await svc.connect(peer('EP16'), store);
      final s = svc.sessionOf('EP15')!;
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      ctrl.add(<String, dynamic>{
        'type': RcCmd.callEnd,
        'payload': <String, dynamic>{'callId': s.callId},
      });
      await settle();
      expect(svc.sessionOf('EP15'), isNull);
      expect(svc.sessionOf('EP16'), isNotNull, reason: '保持其它视频链接');
      await ctrl.close();
      await settle(2);
    });
  });

  // ══════════════════════════ 连接状态 ══════════════════════════

  group('MC-C 连接状态：成功 / 失败 / 关闭', () {
    test('MC-14 connected → 该路已连接且标记已回答', () async {
      await svc.connect(peer('EP20'), store);
      await rtc.pushConnectionState('connected');
      await settle();
      final s = svc.sessionOf('EP20')!;
      expect(s.phase, MultiCallPhase.connected);
      expect(s.answered, isTrue);
      expect(svc.isConnected('EP20'), isTrue);
    });

    test('MC-15 failed → 该路失败且给出可诊断的原因', () async {
      await svc.connect(peer('EP21'), store);
      await rtc.pushConnectionState('failed');
      await settle();
      final s = svc.sessionOf('EP21')!;
      expect(s.phase, MultiCallPhase.failed);
      expect(s.failure, isNotNull);
      expect(s.failure, contains('TURN'),
          reason: '不可诊断的"连接失败"会让人反复重试（S5 无 TURN 降级路径）');
    });

    test('MC-16 closed → 该路标记已挂断', () async {
      await svc.connect(peer('EP22'), store);
      await rtc.pushConnectionState('connected');
      await settle();
      await rtc.pushConnectionState('closed');
      await settle();
      expect(svc.sessionOf('EP22')!.phase, MultiCallPhase.closed);
    });

    test('MC-17 已失败的一路不得被 closed 覆盖成"已挂断"', () async {
      await svc.connect(peer('EP23'), store);
      await rtc.pushConnectionState('failed');
      await settle();
      await rtc.pushConnectionState('closed');
      await settle();
      final s = svc.sessionOf('EP23')!;
      expect(s.phase, MultiCallPhase.failed);
      expect(s.failure, isNotNull, reason: '原因被冲掉 = 用户再也看不到为什么失败');
    });

    test('MC-18 本端候选经信令发给对端（载荷带 callId 与候选三元组）', () async {
      await svc.connect(peer('EP24'), store);
      final s = svc.sessionOf('EP24')!;
      sent.clear();
      await rtc.pushIceCandidate('local-cand', sdpMid: '0', sdpMLineIndex: 2);
      await settle();
      expect(sent.single.type, RcCmd.callCandidate);
      expect(sent.single.payload['callId'], s.callId);
      final cand = sent.single.payload['candidate'] as Map<String, dynamic>;
      expect(cand['candidate'], 'local-cand');
      expect(cand['sdpMid'], '0');
      expect(cand['sdpMLineIndex'], 2);
    });

    test('MC-19 远端流到达 → 该路拿到 remoteStream 并通知界面', () async {
      await svc.connect(peer('EP25'), store);
      final s = svc.sessionOf('EP25')!;
      var notified = 0;
      final sub = svc.updates.listen((_) => notified++);
      await settle(1);
      await rtc.pushTrack('remote-stream-9');
      await settle();
      expect(s.remoteStream, isNotNull);
      expect(s.remoteStream!.id, 'remote-stream-9');
      expect(notified, greaterThan(0));
      await sub.cancel();
    });
  });

  // ══════════════════════════ 挂断与焦点 ══════════════════════════

  group('MC-D 挂断、焦点与本地流归位', () {
    test('MC-20 挂断一路不影响其它路，焦点按规则回落', () async {
      await svc.connect(peer('EP30'), store);
      await svc.connect(peer('EP31'), store);
      svc.setActive('EP31');
      expect(svc.activeId, 'EP31');

      await svc.hangUp('EP31');
      expect(svc.sessionOf('EP31'), isNull);
      expect(svc.sessionOf('EP30'), isNotNull);
      expect(svc.activeId, 'EP30', reason: '焦点窗口被挂断时要回落到仍在列表里的那路');
    });

    test('MC-21 挂断不存在的设备是 no-op', () async {
      await svc.connect(peer('EP32'), store);
      await svc.hangUp('NO-SUCH-DEVICE');
      expect(svc.sessions, hasLength(1));
      expect(svc.activeId, 'EP32');
    });

    test('MC-22 全部挂断 → 本地流停止并置空（相机不得常亮）', () async {
      await svc.connect(peer('EP33'), store);
      rtc.resetObservations();
      await svc.hangUpAll();
      // `hangUp` 里 `unawaited(t.stop())` 是**微任务**才发到通道上 ⇒ 先让事件循环跑完。
      await settle(3);
      expect(svc.sessions, isEmpty);
      expect(svc.activeId, isNull);
      expect(rtc.called('trackDispose'), isTrue);
      expect(rtc.called('peerConnectionClose'), isTrue);
    });

    test('MC-23 setActive 只对已在列表里的设备生效', () async {
      await svc.connect(peer('EP34'), store);
      svc.setActive('NOT-IN-LIST');
      expect(svc.activeId, 'EP34');
      await svc.connect(peer('EP35'), store);
      svc.setActive('EP35');
      expect(svc.activeId, 'EP35');
      expect(svc.sessions, hasLength(2));
    });
  });

  // ══════════════════ MC-D 覆盖率冲刺（第六十一轮） ══════════════════
  //
  // 只补**既有未覆盖分支**，不新增任何生产代码；断言的是"用户看到的后果"。

  group('MC-D 收尾路径：信令异常与"断线未关"', () {
    test('BK-MC-01 answer 信令处理抛错 → 该路判失败并给出理由（不停在"连接中"）',
        () async {
      await svc.connect(peer('EP40'), store);
      final s = svc.sessionOf('EP40')!;
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      // SDP 不合法的常见形态：平台侧抛 PlatformException。
      rtc.failSetRemoteDescription = true;
      addTearDown(() => rtc.failSetRemoteDescription = false);

      ctrl.add(<String, dynamic>{
        'type': RcCmd.callAnswer,
        'payload': <String, dynamic>{
          'callId': s.callId,
          'sdp': 'answer-sdp',
          'sdpType': 'answer',
        },
      });
      await settle();

      expect(s.phase, MultiCallPhase.failed,
          reason: '信令处理失败却停在 connecting ⇒ 用户永远只看到转圈，不知道这路已经废了');
      expect(s.failure, '应答信令处理失败',
          reason: '失败必须带可诊断的原因，否则只能显示一句无信息量的"连接失败"');
      expect(s.answered, isFalse,
          reason: '远端描述没设成功就不能算"已应答"——否则 45s 超时会把真未接放过');
      await ctrl.close();
      await settle(2);
    });

    test('BK-MC-02 连接状态 = 断开（非关闭）→ 同样按"已挂断"收尾', () async {
      await svc.connect(peer('EP41'), store);
      // `disconnected` 是**独立**于 `closed` 的一个枚举值：只处理 closed
      // 会让"网络抖一下"的一路永远留在列表里显示"连接中"。
      await rtc.pushConnectionState('disconnected');
      await settle();
      expect(svc.sessionOf('EP41')!.phase, MultiCallPhase.closed,
          reason: 'disconnected 分支漏掉 ⇒ 该路再也回不到终态，用户无法重连');
    });
  });

  // ══════════════════ MC-E 覆盖率冲刺（第六十四轮） ══════════════════
  //
  // 只补**既有未覆盖分支**，不新增任何生产代码；断言的是"用户看到的后果"。

  group('MC-E 等待应答超时（真实计时器）', () {
    test('MC-24 发出 invite 后一直无应答 → 满 45 秒判该路失败「对方无应答」', () async {
      final ok = await svc.connect(peer('EP50'), store);
      expect(ok, isTrue, reason: '前置：invite 已发出，该路进入 connecting');
      final s = svc.sessionOf('EP50')!;
      expect(s.phase, MultiCallPhase.connecting);

      // 记录相位迁移：`hangUp` 随后会把该路收成 closed，故必须看**迁移过程**，
      // 不能只看终态 —— 否则 failed 这一段被 closed 覆盖后就观测不到了。
      final phases = <MultiCallPhase>[];
      final sub = svc.updates.listen((_) => phases.add(s.phase));
      addTearDown(sub.cancel);

      // 真实计时器：等待上限 = call_lifecycle.waitLimitMs(isCaller: true) = 45s。
      // 这是宿主上唯一一条"真超时到点"的路径（判定逻辑由纯函数锁死，但回调体
      // 只有真等到点才执行）—— 发出 invite 后对方一直不接，不能永远停在"连接中"。
      await Future<void>.delayed(const Duration(milliseconds: 46500));

      expect(phases, contains(MultiCallPhase.failed),
          reason: '一直无应答必须判失败，否则该路永远显示"连接中"，用户无从判断对端是否收到');
      expect(s.failure, '对方无应答',
          reason: '失败原因必须可诊断，且与单路 waitLimitMs 同源（两处超时值不得漂移）');
      expect(s.answered, isFalse,
          reason: '从未收到 answer ⇒ 不得被标成已回答，否则后续会误判已接通');
    });
  });

  // ══════════════════ MC-F 应答后建连超时（第七十五轮） ══════════════════
  //
  // BUG-081：单路侧新增了"应答后建连超时"（`call_lifecycle.connectTimeout`），
  // 多路必须**同源同结论** —— 否则同一台设备上"单路来电"会收尾、而"多路同连"
  // 永远停在"连接中"（两处超时值/判定漂移，正是本项目反复出现的形状）。

  group('MC-F 应答后建连超时（真实计时器）', () {
    test('MC-25 answer 到位但 ICE 始终不连通 → 满 15 秒判该路失败并挂断', () async {
      await svc.connect(peer('EP51'), store);
      final s = svc.sessionOf('EP51')!;
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      addTearDown(() => ctrl.close());

      // 记录相位迁移：`hangUp` 随后会把该路收成 closed，故必须看**迁移过程**。
      final phases = <MultiCallPhase>[];
      final sub = svc.updates.listen((_) => phases.add(s.phase));
      addTearDown(sub.cancel);

      // 前置：answer 到位 ⇒ 取消 45s 等待计时，启动 15s 建连计时。
      ctrl.add(<String, dynamic>{
        'type': RcCmd.callAnswer,
        'payload': <String, dynamic>{
          'callId': s.callId,
          'sdp': 'answer-sdp',
          'sdpType': 'answer',
        },
      });
      await settle();
      expect(s.answered, isTrue, reason: '前置：answer 已被受理');

      // 真实计时器：ICE 状态不推进 ⇒ 15s 到点必须收尾，不能无限"连接中"。
      await Future<void>.delayed(const Duration(milliseconds: 15500));
      await settle();

      expect(phases, contains(MultiCallPhase.failed),
          reason: '应答后连不上必须判失败，否则"多路同连"永远停在连接中（BUG-081 多路同源）');
      expect(phases.last, MultiCallPhase.closed,
          reason: '失败后必须挂断收尾，不能把死路留在列表里占着焦点');
      expect(s.failure, contains('TURN'),
          reason: '失败原因必须可诊断（指向对称 NAT + 配置 TURN），不能只显示"连接失败"');
      expect(svc.sessionOf('EP51'), isNull, reason: '挂断后该路必须从列表移除');
    });
  });
}
