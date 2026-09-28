/// `CallService`（视频/语音通话服务）的**行为**驱动 —— 第 45 轮新建。
///
/// ## 为什么这是一个"有测试文件却从没被执行过"的整块
///
/// 项目里针对通话的既有测试**全是源码文本锁**：`test/call_flow_test.dart`
/// 35 条（`methodBody` + `contains`）、`test/call_lifecycle_test.dart` 锁纯函数、
/// `test/call_screen_test.dart` / `call_incoming_overlay_test.dart` 锁界面映射。
/// 于是 `call_service.dart` 的 **293 行里 132 行从未被执行过** ——
/// 包括 `_createPc`、`onCandidate`、`_flushPendingCandidates`、`onAnswer`、
/// `_teardown` 的全部分支。
///
/// 这正是 `docs/17 §74` **判据第五代**的形状：
/// **"源码锁是绿的" ≠ "那条业务路径被执行过"**。
/// 锁里写着 `_bufferCandidate(` 与 `_flushPendingCandidates()` 只证明源码有那几行字。
///
/// ## 驱动方式（不伪造生产逻辑）
///
/// 障碍是"宿主机没有相机麦克风、也没有真实对端"。本文件用
/// `test/support/webrtc_stub.dart`（照 `flutter_webrtc 1.6.2` 的**真实通道名与
/// 返回形状**写的平台替身）把"手机那边"换成一个可编程的替身，被驱动的
/// **仍是真实的 `call_service.dart`**。
///
/// 出站信令用 `RcEndpointService.debugSendTo`（本轮新增的 `@visibleForTesting`
/// 接缝）：`sendTo` 的成功分支要求一个 `connected` 的 MQTT 客户端，宿主机上
/// **结构性不可达** —— 不注入就只能覆盖失败分支。
///
/// ## 明确不测什么
///
/// - **不测**真实媒体协商：SDP 是常量串，ICE 不真的打洞，`RTCVideoView` 的纹理
///   不存在（与 `multi_video_screen_test.dart` 同一处理）。
/// - **不测** `_onWaitTimeout` 的 45s 真实计时：`callerAnswerTimeout` 是 45 秒，
///   真实等待不可接受；该分支的**判定**已由 `call_lifecycle_test.dart` 的纯函数
///   测试锁死（`timedOutMeansMissed` / `waitLimitMs`）。
/// - **不测** `CalleeAction.rejectBusy => false`（`onIncomingCall` 里那一条
///   **故意的不可达臂**：上面已提前 return，留它只为让 switch 穷尽）。
///
/// 每例上限 120s：本文件**不用** fake-async（服务层是真实异步 + 真实计时器），
/// 正常 2s 内跑完；给上限是为了让"万一挂死"快速暴露而不是等默认的 10 分钟。
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/remote/call_lifecycle.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/webrtc_stub.dart';

/// 出站替身记下的一条"已发出的信令"。
class _Sent {
  _Sent(this.endpoint, this.msg, this.enqueueOnFail);

  final PairedEndpoint endpoint;
  final RcMessage msg;
  final bool enqueueOnFail;

  String get type => msg.type;
  Map<String, dynamic> get payload => msg.payload;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rtc = FakeWebrtc();
  final svc = CallService.instance;
  final endpointSvc = RcEndpointService.instance;

  late RemoteStore store;
  late List<_Sent> sent;
  late bool sendOk;
  late List<String> failures;
  StreamSubscription<String>? failSub;

  PairedEndpoint peer(String id) => PairedEndpoint(
        deviceId: id,
        name: '客厅手机',
        secret: 'SECRET01',
        pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  /// 真实异步推进若干轮（服务层不用 fake-async，故用真事件循环让
  /// `await` 的插件调用真的完成）。
  Future<void> settle([int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 重建偏好（`setMockInitialValues` 会重置缓存实例 ⇒ 必须重建 store 并重绑）。
  Future<void> freshPrefs([
    Map<String, Object> values = const <String, Object>{},
  ]) async {
    SharedPreferences.setMockInitialValues(values);
    store = RemoteStore(await SharedPreferences.getInstance());
    CallService.bindStore(() async => store);
  }

  setUp(() async {
    rtc.failUserMedia = false;
    rtc.failCreateOffer = false;
    rtc.failSetRemoteDescription = false;
    rtc.failAddCandidate = false;
    rtc.failSpeakerphone = false;
    rtc.failSwitchCamera = false;
    rtc.withAudioTrack = true;
    rtc.withVideoTrack = true;
    rtc.localSdp = 'v=0\r\no=- 4611 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n';
    rtc.resetObservations();
    rtc.install();

    sent = <_Sent>[];
    sendOk = true;
    failures = <String>[];
    await freshPrefs();
    endpointSvc.debugSendTo = (ep, msg, st, enqueueOnFail) async {
      sent.add(_Sent(ep, msg, enqueueOnFail));
      return sendOk;
    };
    failSub = svc.failures.listen(failures.add);
  });

  tearDown(() async {
    // 收尾：否则 `_startWaitTimer` 的 45s 计时器会跨用例残留。
    await svc.onRemoteEnd();
    await settle(2);
    await failSub?.cancel();
    failSub = null;
    endpointSvc.debugSendTo = null;
    rtc.uninstall();
  });

  // ══════════════════════════ 主叫：失败路径 ══════════════════════════

  group('CS-A 主叫 startCall：每条失败都必须可诊断', () {
    test('CS-01 取流失败 → mediaFailed，且不建 PeerConnection', () async {
      rtc.failUserMedia = true;
      final id = await svc.startCall(peer('EP0001'), store);
      await settle();
      expect(id, isNull);
      expect(svc.lastStartBlock, CallStartBlock.mediaFailed,
          reason: '不登记原因 = 调用方只能显示一句不可执行的兜底文案（BUG-D）');
      expect(rtc.called('createPeerConnection'), isFalse);
      expect(svc.currentPhase, CallPhase.idle, reason: '收尾后必须回到 idle');
    });

    test('CS-02 createOffer 抛错 → offerFailed，不再取本地描述', () async {
      rtc.failCreateOffer = true;
      final id = await svc.startCall(peer('EP0002'), store);
      expect(id, isNull);
      expect(svc.lastStartBlock, CallStartBlock.offerFailed);
      expect(rtc.called('getLocalDescription'), isFalse);
      expect(sent, isEmpty, reason: '没拿到 offer 就不该发 invite');
    });

    test('CS-03 空 SDP 不得当成"已发出"（否则主叫白等 45s）', () async {
      rtc.localSdp = '';
      final id = await svc.startCall(peer('EP0003'), store);
      expect(id, isNull);
      expect(svc.lastStartBlock, CallStartBlock.offerFailed);
      expect(sent, isEmpty,
          reason: '空 SDP 的 invite 必然协商失败 —— 宁可在本地当场判失败');
    });

    test('CS-04 端点离线（sendTo=false）→ endpointOffline，且信令不进 outbox', () async {
      sendOk = false;
      final id = await svc.startCall(peer('EP0004'), store);
      expect(id, isNull);
      expect(svc.lastStartBlock, CallStartBlock.endpointOffline);
      expect(sent.single.type, RcCmd.callInvite);
      expect(sent.single.enqueueOnFail, isFalse,
          reason: '实时通话信令不能靠 outbox 补发：补发的 invite 带的是上一通的 '
              'SDP，而本端已 teardown ⇒ 对端上线后收到过期 invite 会照常振铃，'
              '自动接通开着时更会静默建立一路无人管理的会话（BUG-076）');
      expect(svc.callId, isNull, reason: '收尾必须清掉 callId');
    });
  });

  // ══════════════════════════ 主叫：成功链 ══════════════════════════

  group('CS-B 主叫 startCall：成功链与媒体参数', () {
    test('CS-05 invite 载荷齐全 + 相位转 connecting', () async {
      final id = await svc.startCall(peer('EP0010'), store, video: true);
      expect(id, isNotNull);
      expect(svc.callId, id);
      expect(svc.currentPhase, CallPhase.connecting);
      expect(svc.lastStartBlock, isNull);
      expect(rtc.called('createPeerConnection'), isTrue);
      expect(rtc.called('setLocalDescription'), isTrue);
      final m = sent.single.msg;
      expect(m.type, RcCmd.callInvite);
      expect(m.payload['callId'], id);
      expect(m.payload['sdp'], rtc.localSdp);
      expect(m.payload['type'], 'offer');
      expect(m.payload['video'], isTrue);
      expect(m.payload['fromName'], store.deviceName);
    });

    test('CS-06 语音呼叫：video 约束为 false，但免提仍要开', () async {
      final id = await svc.startCall(peer('EP0011'), store, video: false);
      expect(id, isNotNull);
      final constraints = rtc.constraintsOf('getUserMedia');
      expect(constraints['audio'], isTrue);
      expect(constraints['video'], isFalse);
      expect(rtc.called('enableSpeakerphone'), isTrue,
          reason: '不切扬声器 → Android 走听筒 → 用户报"听不到对方"');
      expect(rtc.lastArgs('enableSpeakerphone')!['enable'], isTrue);
      expect(sent.single.payload['video'], isFalse);
    });

    test('CS-07 视频呼叫：video 约束带 facingMode 与分辨率', () async {
      await svc.startCall(peer('EP0012'), store, video: true);
      final video =
          rtc.constraintsOf('getUserMedia')['video'] as Map<String, Object?>;
      expect(video['facingMode'], 'user');
      expect(video['width'], 640);
      expect(video['height'], 480);
    });

    test('CS-08 已在通话中再呼 → alreadyInCall，且不重复取流', () async {
      await svc.startCall(peer('EP0013'), store);
      rtc.resetObservations();
      sent.clear();
      final second = await svc.startCall(peer('EP0014'), store);
      expect(second, isNull);
      expect(svc.lastStartBlock, CallStartBlock.alreadyInCall);
      expect(rtc.called('getUserMedia'), isFalse);
      expect(sent, isEmpty, reason: '第二通 invite 一个字都不该发');
    });

    test('CS-09 平台不支持免提 → 静默降级，不把通话挡掉', () async {
      rtc.failSpeakerphone = true;
      final id = await svc.startCall(peer('EP0015'), store);
      expect(id, isNotNull,
          reason: '失败的是音频路由偏好，不是用户要求的那件事');
      expect(svc.lastStartBlock, isNull);
    });
  });

  // ══════════════════════════ 被叫 ══════════════════════════

  group('CS-C 被叫：振铃 / 自动接通 / 占线 / 拒接', () {
    test('CS-10 手动模式只振铃，绝不自动接通（BUG-056 不回潮）', () async {
      final ok = await svc.onIncomingCall(
          <String, dynamic>{'callId': 'C-10', 'sdp': 'offer-sdp', 'video': true},
          peer('EP0020'),
          store);
      expect(ok, isTrue);
      expect(svc.currentPhase, CallPhase.ringing);
      expect(svc.awaitingAnswer, isTrue);
      expect(svc.isCaller, isFalse);
      expect(rtc.called('createAnswer'), isFalse,
          reason: '"自动接通"开关关着就绝不能接通 —— 这是隐私规则');
      expect(rtc.called('getUserMedia'), isFalse);
      expect(sent, isEmpty);
    });

    test('CS-11 自动接通：createAnswer → 发 callAnswer，相位转 connecting', () async {
      await freshPrefs(<String, Object>{'rc_call_auto_answer': true});
      final ok = await svc.onIncomingCall(
          <String, dynamic>{
            'callId': 'C-11',
            'sdp': 'offer-sdp',
            'type': 'offer',
            'video': true,
          },
          peer('EP0021'),
          store);
      expect(ok, isTrue);
      expect(svc.currentPhase, CallPhase.connecting);
      expect(rtc.called('createAnswer'), isTrue);
      expect(rtc.called('setRemoteDescription'), isTrue);
      final answer = sent.single.msg;
      expect(answer.type, RcCmd.callAnswer);
      expect(answer.payload['callId'], 'C-11');
      expect(answer.payload['sdp'], rtc.localSdp);
      expect(svc.awaitingAnswer, isFalse, reason: 'invite 已被消费');
    });

    test('CS-12 占线：通话中收到 invite → 回 callEnd(busy) 且不打断本通话', () async {
      await svc.startCall(peer('EP0022'), store);
      sent.clear();
      final ok = await svc.onIncomingCall(
          <String, dynamic>{'callId': 'C-12', 'sdp': 'x'},
          peer('EP0023'),
          store);
      expect(ok, isFalse);
      expect(sent.single.type, RcCmd.callEnd);
      expect(sent.single.payload['reason'], 'busy');
      expect(svc.currentPhase, CallPhase.connecting);
      expect(svc.callId, isNotNull);
    });

    test('CS-13 answer 发不出去 → 当场收场，不假装接通', () async {
      await freshPrefs(<String, Object>{'rc_call_auto_answer': true});
      sendOk = false;
      final ok = await svc.onIncomingCall(
          <String, dynamic>{'callId': 'C-13', 'sdp': 'offer-sdp', 'video': false},
          peer('EP0024'),
          store);
      await settle();
      expect(ok, isFalse);
      expect(svc.lastEndReason, CallEndReason.failed,
          reason: '假接通会让主叫一路等到 45s 后报"对方无应答"（把网络故障误报成没人接）');
      expect(svc.currentPhase, CallPhase.idle);
    });

    test('CS-14 被叫媒体失败 → 回 callEnd(reason=media) 并收尾', () async {
      await freshPrefs(<String, Object>{'rc_call_auto_answer': true});
      rtc.failUserMedia = true;
      final ok = await svc.onIncomingCall(
          <String, dynamic>{'callId': 'C-14', 'sdp': 'offer-sdp'},
          peer('EP0025'),
          store);
      expect(ok, isFalse);
      expect(sent.last.type, RcCmd.callEnd);
      expect(sent.last.payload['reason'], 'media');
      expect(svc.lastEndReason, CallEndReason.failed);
    });

    test('CS-15 acceptPending：无来电 false；接听后重复点 false', () async {
      expect(await svc.acceptPending(), isFalse, reason: '没有待接 invite');
      await svc.onIncomingCall(
          <String, dynamic>{'callId': 'C-15', 'sdp': 's'},
          peer('EP0026'),
          store);
      expect(await svc.acceptPending(), isTrue);
      expect(rtc.called('createAnswer'), isTrue);
      expect(await svc.acceptPending(), isFalse,
          reason: '已接通后连点不得再协商一遍');
    });

    test('CS-16 declinePending → 回 callEnd(rejected) + 本端原因 declined', () async {
      await svc.onIncomingCall(
          <String, dynamic>{'callId': 'C-16', 'sdp': 's'},
          peer('EP0027'),
          store);
      sent.clear();
      await svc.declinePending();
      expect(sent.single.type, RcCmd.callEnd);
      expect(sent.single.payload['reason'], 'rejected');
      expect(svc.lastEndReason, CallEndReason.declined,
          reason: '本端拒接看到的是"已拒接"；复用 rejected 会显示成"对方已拒接"');
    });

    test('CS-17 不在振铃时 rejectCall 不得发出任何信令', () async {
      await svc.rejectCall(store);
      expect(sent, isEmpty);
      expect(svc.lastEndReason, isNot(CallEndReason.declined));
    });
  });

  // ══════════════════════════ ICE 时序 ══════════════════════════

  group('CS-D 主叫收 answer 与 ICE 候选时序（BUG-D 不回潮）', () {
    test('CS-18 onAnswer：设远端描述 + 补喂振铃期缓存的候选', () async {
      await svc.startCall(peer('EP0030'), store);
      final callId = svc.callId!;
      await svc.onCandidate(<String, dynamic>{
        'callId': callId,
        'candidate': <String, dynamic>{
          'candidate': 'cand-A',
          'sdpMid': '0',
          'sdpMLineIndex': 0,
        },
      });
      expect(rtc.addedCandidates, isEmpty,
          reason: 'WebRTC 硬要求：远端描述就位前不得直接喂候选');
      rtc.resetObservations();
      await svc.onAnswer(
          <String, dynamic>{'callId': callId, 'sdp': 'answer-sdp', 'type': 'answer'});
      expect(rtc.called('setRemoteDescription'), isTrue);
      expect(rtc.addedCandidates, <String>['cand-A'],
          reason: 'answer 之后必须把缓存补喂 —— 不补喂则 ICE 永不完成（"接通了但没画面"）');
    });

    test('CS-19 onAnswer 守卫：callId 不符 → 什么都不做', () async {
      await svc.startCall(peer('EP0031'), store);
      rtc.resetObservations();
      await svc.onAnswer(<String, dynamic>{'callId': 'OTHER', 'sdp': 'x'});
      expect(rtc.called('setRemoteDescription'), isFalse);
    });

    test('CS-20 onAnswer 守卫：非主叫不受理 answer', () async {
      await svc.onIncomingCall(
          <String, dynamic>{'callId': 'C-20', 'sdp': 's'},
          peer('EP0032'),
          store);
      rtc.resetObservations();
      await svc.onAnswer(<String, dynamic>{'callId': 'C-20', 'sdp': 'x'});
      expect(rtc.called('setRemoteDescription'), isFalse);
    });

    test('CS-21 远端描述就位后候选直接投递（不再进缓存）', () async {
      await svc.startCall(peer('EP0033'), store);
      final callId = svc.callId!;
      await svc.onAnswer(
          <String, dynamic>{'callId': callId, 'sdp': 'a', 'type': 'answer'});
      rtc.addedCandidates.clear();
      await svc.onCandidate(<String, dynamic>{
        'callId': callId,
        'candidate': <String, dynamic>{
          'candidate': 'cand-B',
          'sdpMid': '1',
          'sdpMLineIndex': 2,
        },
      });
      expect(rtc.addedCandidates, <String>['cand-B']);
    });

    test('CS-22 形状不对的候选一律忽略（远端数据不可信）', () async {
      await svc.startCall(peer('EP0034'), store);
      final callId = svc.callId!;
      for (final bad in <Object?>[
        'not-a-map',
        <String, dynamic>{'candidate': ''},
        <String, dynamic>{'candidate': 42},
      ]) {
        await svc.onCandidate(<String, dynamic>{'callId': callId, 'candidate': bad});
      }
      await svc.onCandidate(<String, dynamic>{
        'callId': 'OTHER',
        'candidate': <String, dynamic>{'candidate': 'x'},
      });
      expect(rtc.addedCandidates, isEmpty);
    });

    test('CS-23 单条候选被平台拒绝不得结束整路', () async {
      await svc.startCall(peer('EP0035'), store);
      final callId = svc.callId!;
      await svc.onAnswer(
          <String, dynamic>{'callId': callId, 'sdp': 'a', 'type': 'answer'});
      rtc.failAddCandidate = true;
      await svc.onCandidate(<String, dynamic>{
        'callId': callId,
        'candidate': <String, dynamic>{'candidate': 'cand-C'},
      });
      expect(svc.currentPhase, CallPhase.connecting,
          reason: 'ICE 会继续尝试其它候选；会话级失败另由连接状态上报');
    });

    test('CS-24 候选缓存有上界，超出时丢最旧', () async {
      await svc.startCall(peer('EP0036'), store);
      final callId = svc.callId!;
      for (var i = 0; i < maxBufferedCandidates + 6; i++) {
        await svc.onCandidate(<String, dynamic>{
          'callId': callId,
          'candidate': <String, dynamic>{'candidate': 'c$i'},
        });
      }
      await svc.onAnswer(
          <String, dynamic>{'callId': callId, 'sdp': 'a', 'type': 'answer'});
      expect(rtc.addedCandidates.length, maxBufferedCandidates);
      expect(rtc.addedCandidates.first, 'c6', reason: '丢的是最旧的那条');
    });
  });

  // ══════════════════════════ 连接状态 ══════════════════════════

  group('CS-E 连接状态：成功 / 失败可诊断 / 副作用不覆盖真因', () {
    test('CS-25 connected → 相位 connected 且清掉失败原因', () async {
      await svc.startCall(peer('EP0040'), store);
      await rtc.pushConnectionState('connected');
      await settle();
      expect(svc.currentPhase, CallPhase.connected);
      expect(svc.failureReason, isNull);
      expect(svc.inCall, isTrue);
    });

    test('CS-26 failed → 广播可执行的失败提示并收尾', () async {
      await svc.startCall(peer('EP0041'), store);
      await rtc.pushConnectionState('failed');
      await settle();
      expect(svc.failureReason, CallService.failureHint(turnConfigured: false));
      expect(failures, <String>[CallService.failureHint(turnConfigured: false)]);
      expect(svc.currentPhase, CallPhase.idle);
      expect(svc.inCall, isFalse);
    });

    test('CS-27 closed 副作用不得覆盖真正的原因（BUG-050）', () async {
      await svc.startCall(peer('EP0042'), store);
      await svc.hangUp(store);
      expect(svc.lastEndReason, CallEndReason.hangup);
      await rtc.pushConnectionState('closed');
      await settle();
      expect(svc.lastEndReason, CallEndReason.hangup,
          reason: '`_pc.close()` 的副作用传 reason=null；传了会把"已挂断"冲成空白');
    });

    test('CS-28 本端收集到的候选必须经信令发给对端', () async {
      await svc.startCall(peer('EP0043'), store);
      final callId = svc.callId!;
      sent.clear();
      await rtc.pushIceCandidate('local-cand', sdpMid: '0', sdpMLineIndex: 3);
      await settle();
      expect(sent.single.type, RcCmd.callCandidate);
      expect(sent.single.payload['callId'], callId);
      final cand = sent.single.payload['candidate'] as Map<String, dynamic>;
      expect(cand['candidate'], 'local-cand');
      expect(cand['sdpMid'], '0');
      expect(cand['sdpMLineIndex'], 3);
    });

    test('CS-29 远端流到达 → remoteStream 与流广播都就位', () async {
      await svc.startCall(peer('EP0044'), store);
      final seen = <MediaStream?>[];
      final sub = svc.remoteStreamChanges.listen(seen.add);
      await settle(1);
      await rtc.pushTrack('remote-stream-1');
      await settle();
      expect(svc.remoteStream, isNotNull);
      expect(svc.remoteStream!.id, 'remote-stream-1');
      expect(seen.where((s) => s != null), hasLength(1),
          reason: '界面靠这条流渲染远端画面');
      await sub.cancel();
    });
  });

  // ══════════════════════════ 收尾 / 设备控制 ══════════════════════════

  group('CS-F 挂断、收尾归位与设备控制', () {
    test('CS-30 hangUp：未接通 → 已挂断；已接通 → 通话结束', () async {
      await svc.startCall(peer('EP0050'), store);
      await svc.hangUp(store);
      expect(svc.lastEndReason, CallEndReason.hangup);
      expect(sent.last.type, RcCmd.callEnd);
      expect(sent.last.payload['reason'], 'hangup');

      sent.clear();
      await svc.startCall(peer('EP0051'), store);
      await rtc.pushConnectionState('connected');
      await settle();
      await svc.hangUp(store);
      expect(svc.lastEndReason, CallEndReason.answered);
    });

    test('CS-31 收尾归位：免提关掉 + 本地轨 stop + 流与 id 清空', () async {
      await svc.startCall(peer('EP0052'), store);
      rtc.resetObservations();
      await svc.onRemoteEnd();
      await settle();
      expect(rtc.called('enableSpeakerphone'), isTrue);
      expect(rtc.lastArgs('enableSpeakerphone')!['enable'], isFalse,
          reason: '不归位 → 通话结束后整个应用的媒体播放仍走扬声器');
      expect(rtc.called('trackDispose'), isTrue, reason: '本地轨必须 stop（否则相机常亮）');
      expect(svc.localStream, isNull);
      expect(svc.remoteStream, isNull);
      expect(svc.callId, isNull);
      expect(svc.remoteState, RemoteCallState.unknown);
      expect(svc.currentPhase, CallPhase.idle);
    });

    test('CS-32 switchCamera：无视频轨不抛；有则调平台；平台不支持静默', () async {
      await svc.switchCamera();
      await svc.startCall(peer('EP0053'), store);
      rtc.resetObservations();
      await svc.switchCamera();
      expect(rtc.called('mediaStreamTrackSwitchCamera'), isTrue,
          reason: '不切摄像头 = 用户点了没反应（本用例同时锁桩用对了通道方法名）');
      rtc.failSwitchCamera = true;
      await svc.switchCamera();
      expect(svc.inCall, isTrue, reason: '摄像头切换失败不得影响通话');
    });

    test('CS-33 toggleMute：无音频轨 false；有则真的翻转并下发平台', () async {
      expect(await svc.toggleMute(), isFalse);
      await svc.startCall(peer('EP0054'), store);
      rtc.resetObservations();
      expect(await svc.toggleMute(), isTrue, reason: '返回"当前是否静音"');
      expect(rtc.lastArgs('mediaStreamTrackSetEnable')!['enabled'], isFalse);
      expect(await svc.toggleMute(), isFalse, reason: '再切一次即恢复');
    });

    test('CS-34 没有音频轨时不得假装静音成功', () async {
      rtc.withAudioTrack = false;
      await svc.startCall(peer('EP0055'), store);
      expect(await svc.toggleMute(), isFalse);
      expect(rtc.called('mediaStreamTrackSetEnable'), isFalse);
    });
  });

  // ══════════════════════════ 配置与远端信令 ══════════════════════════

  group('CS-G ICE 服务器配置与远端信令消费', () {
    test('CS-35 iceServers：无 TURN 只有 STUN；配了 TURN 才带上凭据', () async {
      final plain = await CallService.iceServers();
      expect(plain, hasLength(2));
      expect(plain.every((s) => '${s['urls']}'.startsWith('stun:')), isTrue);

      await freshPrefs(<String, Object>{
        'rc_turn_url': 'turn:example.com:3478',
        'rc_turn_user': 'u1',
        'rc_turn_cred': 'c1',
      });
      final withTurn = await CallService.iceServers();
      expect(withTurn, hasLength(3));
      expect(withTurn.last['urls'], 'turn:example.com:3478');
      expect(withTurn.last['username'], 'u1');
      expect(withTurn.last['credential'], 'c1');
    });

    test('CS-36 failureHint 必须指向可执行的下一步', () async {
      expect(CallService.failureHint(turnConfigured: true), contains('TURN'));
      expect(CallService.failureHint(turnConfigured: false), contains('TURN'),
          reason: '未配 TURN 时也必须给出"去配 TURN"这条可执行路径');
      expect(CallService.failureHint(turnConfigured: false),
          isNot(CallService.failureHint(turnConfigured: true)));
    });

    test('CS-37 远端信令：connected 更新镜像；ended 收尾', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      await svc.startCall(peer('EP0060'), store);
      final callId = svc.callId!;
      ctrl.add(<String, dynamic>{
        'type': RcEvt.callState,
        'payload': <String, dynamic>{'state': 'connected', 'callId': callId},
      });
      await settle();
      expect(svc.remoteState, RemoteCallState.connected);

      ctrl.add(<String, dynamic>{
        'type': RcEvt.callState,
        'payload': <String, dynamic>{'state': 'ended', 'callId': callId},
      });
      await settle();
      expect(svc.lastEndReason, CallEndReason.remoteEnded);
      await ctrl.close();
      await settle(2);
    });

    test('CS-38 远端信令：callMissed 让主叫立刻结束等待并记"未接"', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      await svc.startCall(peer('EP0061'), store);
      final callId = svc.callId!;
      ctrl.add(<String, dynamic>{
        'type': RcEvt.callMissed,
        'payload': <String, dynamic>{'callId': callId},
      });
      await settle();
      expect(svc.lastEndReason, CallEndReason.missed,
          reason: '"没人接"该由被叫发信令说出来，而不是主叫单方面等满 45s');
      await ctrl.close();
      await settle(2);
    });

    test('CS-39 远端信令：非本次通话的状态不得污染镜像', () async {
      final ctrl = StreamController<Map<String, dynamic>>.broadcast();
      svc.attach(ctrl.stream);
      await svc.startCall(peer('EP0062'), store);
      ctrl.add(<String, dynamic>{
        'type': RcEvt.callState,
        'payload': <String, dynamic>{'state': 'connected', 'callId': 'OTHER'},
      });
      await settle();
      expect(svc.remoteState, RemoteCallState.unknown);
      await ctrl.close();
      await settle(2);
    });
  });
}
