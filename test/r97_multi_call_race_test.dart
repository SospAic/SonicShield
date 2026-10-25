/// R88-AUD-04 回归锁：多路通话 `connect()` / `hangUp()` 竞态。
///
/// ## 缺陷形状（审计原文摘要）
/// `connect()` 在**所有 await 之前**就把会话塞进 `_sessions[deviceId]`，随后
/// `createPeerConnection` → `addTrack` → `createOffer` → `setLocalDescription`
/// → `_send(callInvite)` 全是异步，且**全程不复核**该会话是否还在表里。
/// 若 `hangUp()` 落在这串 await 中间，三条后果同时发生：
/// 1. 对端**仍会收到 invite 并振铃**（invite 在窗口之后才发）；
/// 2. 原生 `RTCPeerConnection` **泄漏**（`hangUp` 摘表时 `s.pc` 还是 null，
///    没人关它）；
/// 3. 本端**无路可挂**（表里已没有这条，`hangUp` 再调也找不到），且孤儿会话
///    上还会起 45s "等待应答"计时器。
///
/// ## 这份锁怎么锁（两条腿）
/// * **行为锁**（MC-02/03/04）：用 `test/support/webrtc_stub.dart` 的通道桩
///   驱动**真实**的 `connect()`，再用两个可注入点把 `connect()` **确定性**
///   停在窗口内（不是靠 sleep 撞时序）：
///   - `MultiCallService.debugPeerConnectionConfig`：停在"已入表、`s.pc`
///     仍为 null"（审计点名的场景）；
///   - `RcEndpointService.debugSendTo`：停在 `call.invite` 的发送 await 内。
/// * **源码锁**（MC-05）：`createOffer` / `setLocalDescription` 两个窗口在宿主
///   上没有可注入的延迟点（真实插件通道），只能用文本锁保证"每个 await 之后
///   都站着一条复核"，并强制 invite 之前必须有一条。
///
/// ## 明确不测什么
/// * 不测真实媒体协商、真实 45s 到点（超时**判定**由 `call_lifecycle_test.dart`
///   的纯函数锁死）。
/// * 不测"入表之前"（`_ensureLocalStream` 期间）的挂断：那时表里还没有这条，
///   `hangUp()` 按既有契约是 no-op，不属于 R88-AUD-04 的窗口。
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/multi_call_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/source_text.dart';
import 'support/webrtc_stub.dart';

/// 出站替身记下的一条"已发出的信令"。
class _Sent {
  _Sent(this.type, this.payload);

  final String type;
  final Map<String, dynamic> payload;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rtc = FakeWebrtc();
  final svc = MultiCallService.instance;
  final endpointSvc = RcEndpointService.instance;

  late RemoteStore store;
  late List<_Sent> sent;

  /// 审计里点名的"最小配置"：`createPeerConnection` 只关心有 `iceServers`。
  Map<String, dynamic> minimalCfg() => <String, dynamic>{
        'iceServers': <Map<String, dynamic>>[],
        'iceTransportPolicy': 'all',
      };

  PairedEndpoint peer(String id) => PairedEndpoint(
        deviceId: id,
        name: '设备-$id',
        secret: 'SECRET01',
        pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  /// 排空微任务/零延时定时器（与 `multi_call_service_connect_test.dart` 同款）。
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
    rtc.resetObservations();
    rtc.install();

    await svc.hangUpAll();
    svc.debugClear();
    MultiCallService.debugPeerConnectionConfig = null;

    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = RemoteStore(await SharedPreferences.getInstance());
    sent = <_Sent>[];
    endpointSvc.debugSendTo = (ep, msg, st, enqueueOnFail) async {
      sent.add(_Sent(msg.type, msg.payload));
      return true;
    };
  });

  tearDown(() async {
    MultiCallService.debugPeerConnectionConfig = null;
    await svc.hangUpAll();
    svc.debugClear();
    // ⚠️ 顺序要紧：`hangUp` 里的 `unawaited(t.stop())` 要到**微任务**里才把
    // 通道消息发出去，紧接着 `uninstall()` 会撞上"没有桩"⇒
    // `MissingPluginException` 记在**下一个**用例头上（第 45 轮实测）。
    await settle(3);
    endpointSvc.debugSendTo = null;
    rtc.uninstall();
  });

  group('R97 · 多路 connect/hangUp 竞态（R88-AUD-04）', () {
    test('R97-MC-01 存活复核判据：对象身份 + 未被关闭', () {
      final s1 = MultiCallSession(callId: 'c-1', peer: peer('EP01'));

      expect(stillCurrent(<String, MultiCallSession>{}, 'EP01', s1), isFalse,
          reason: '还没入表 / 已被摘表 ⇒ 不成立（否则 connect 会在孤儿上继续发 invite）');

      expect(
          stillCurrent(<String, MultiCallSession>{'EP01': s1}, 'EP01', s1),
          isTrue,
          reason: '表里那一条就是它本身 ⇒ 唯一成立的情形');

      final other = MultiCallSession(callId: 'c-2', peer: peer('EP01'));
      expect(
          stillCurrent(<String, MultiCallSession>{'EP01': other}, 'EP01', s1),
          isFalse,
          reason: '同设备已被**新一路**顶替 ⇒ 代次变了，老 connect 必须收场');

      s1.phase = MultiCallPhase.closed;
      expect(
          stillCurrent(<String, MultiCallSession>{'EP01': s1}, 'EP01', s1),
          isFalse,
          reason: '仍在表里但已被关闭（onConnectionState=closed 不摘表）⇒ 不得再发 invite');
    });

    test('R97-MC-02 hangUp 落在「已入表、PC 未建」窗口 ⇒ 不发 invite、补关 PC、返回 false',
        () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      MultiCallService.debugPeerConnectionConfig = () async {
        // 入表之后的**第一个** await：此刻 `_sessions[deviceId] == s` 且
        // `s.pc == null` —— 正是审计说"hangUp 摘表时关不掉 PC"的那个窗口。
        if (!entered.isCompleted) entered.complete();
        await gate.future;
        return minimalCfg();
      };

      final f = svc.connect(peer('EP01'), store, video: true);
      // 防"未处理异步错误"：用例中途断言失败时 `f` 可能带错误完成而无人 await。
      unawaited(f.catchError((Object _) => false));

      await entered.future;
      expect(svc.sessionOf('EP01'), isNotNull,
          reason: '入表必须发生在所有 await 之前（本缺陷的前提）');
      final s = svc.sessionOf('EP01')!;
      expect(s.pc, isNull, reason: '窗口判据：hangUp 此刻看到的 s.pc 还是 null');

      await svc.hangUp('EP01'); // ← 窗口内挂断（用户点了"挂断"/退出页面）
      expect(svc.sessionOf('EP01'), isNull, reason: '挂断同步摘表');
      expect(rtc.called('peerConnectionClose'), isFalse,
          reason: 'hangUp 关不掉还不存在的 PC —— 这正是原生对象泄漏的入口');

      gate.complete(); // 放行 connect
      expect(await f, isFalse,
          reason: '被挂断的一路必须如实返回 false（false = 没连上，契约不变）');

      expect(sent.where((x) => x.type == RcCmd.callInvite), isEmpty,
          reason: '★ 挂断之后绝不能再发 invite —— 否则对端开始振铃，而本端已无这一路');
      expect(rtc.called('peerConnectionClose'), isTrue,
          reason: '★ 刚建好的 PC 必须被 _abortConnect 补关（审计后果第 2 条：泄漏）');
      expect(rtc.called('peerConnectionDispose'), isTrue,
          reason: '只 close 不 dispose 仍会漏原生对象（BUG-134 同源）');
      expect(s.pc, isNull, reason: '收尾后不得留悬挂的 PC 引用');
      expect(s.waitTimer, isNull,
          reason: '★ 不得在孤儿会话上起 45s "等待应答"计时器（审计后果第 3 条）');
      expect(s.phase, MultiCallPhase.closed);
      expect(svc.sessions, isEmpty, reason: '已挂断的一路不得被 connect 复活');
      expect(svc.activeId, isNull, reason: '焦点不得指向已不存在的会话');
    });

    test('R97-MC-03 hangUp 落在 invite 发送的 await 内 ⇒ 不起等待计时器、返回 false',
        () async {
      final inviteEntered = Completer<void>();
      final inviteGate = Completer<void>();
      endpointSvc.debugSendTo = (ep, msg, st, enqueueOnFail) async {
        sent.add(_Sent(msg.type, msg.payload));
        if (msg.type == RcCmd.callInvite) {
          if (!inviteEntered.isCompleted) inviteEntered.complete();
          await inviteGate.future; // 把 connect 停在 invite 这个 await 上
        }
        return true;
      };

      final f = svc.connect(peer('EP02'), store);
      unawaited(f.catchError((Object _) => false));
      await inviteEntered.future;

      expect(svc.sessionOf('EP02'), isNotNull, reason: '此刻会话已入表、PC 已建好');
      final s = svc.sessionOf('EP02')!;
      expect(s.pc, isNotNull);

      await svc.hangUp('EP02'); // ← invite 的 await 内挂断（会自己 close/dispose）
      expect(s.pc, isNull, reason: 'hangUp 关掉了当时的 PC');

      inviteGate.complete();
      expect(await f, isFalse,
          reason: '★ 本路已被挂断 ⇒ 不得返回 true（否则 UI 显示"已连接"却无路可挂）');
      expect(s.waitTimer, isNull,
          reason: '★ invite 之后必须复核再起计时器；否则孤儿会话跑满 45s 才报"未接"');
      expect(s.phase, MultiCallPhase.closed);
      expect(svc.sessionOf('EP02'), isNull);
      expect(sent.where((x) => x.type == RcCmd.callInvite), hasLength(1),
          reason: 'invite 只发一次：复核失败不得重发、也不得补发 call.end 风暴');
    });

    test('R97-MC-04 复核按「设备 + 对象身份」，挂断别路不得误杀本路', () async {
      // 先完整建好 EP01（走真实配置链）。
      expect(await svc.connect(peer('EP01'), store), isTrue);
      expect(svc.sessionOf('EP01'), isNotNull);

      final entered = Completer<void>();
      final gate = Completer<void>();
      MultiCallService.debugPeerConnectionConfig = () async {
        if (!entered.isCompleted) entered.complete();
        await gate.future;
        return minimalCfg();
      };

      final f = svc.connect(peer('EP02'), store);
      unawaited(f.catchError((Object _) => false));
      await entered.future;

      await svc.hangUp('EP01'); // ← 挂断的是**别路**
      gate.complete();

      expect(await f, isTrue,
          reason: '★ 复核必须按 deviceId + 对象身份；用"全局代次/表非空"之类的判据会把别路的挂断误当成自己被杀');
      expect(svc.sessionOf('EP02'), isNotNull, reason: 'EP02 不得被误清');
      final s2 = svc.sessionOf('EP02')!;
      expect(s2.waitTimer, isNotNull, reason: '正常发出的 invite 必须照常起计时器');
      expect(svc.sessionOf('EP01'), isNull);
      expect(
          sent
              .where((x) => x.type == RcCmd.callInvite)
              .map((x) => x.payload['callId']),
          contains(s2.callId),
          reason: 'EP02 的 invite 必须真的发出');
    });

    test('R97-MC-05 源码锁：connect 的每个 await 之后都站着一条复核，且 invite 之前必须有',
        () {
      final raw = File('lib/remote/multi_call_service.dart').readAsStringSync();
      final src = stripComments(raw.replaceAll('\r\n', '\n'));
      final body = methodBody(src, 'Future<bool> connect(');
      const probe = 'stillCurrent(_sessions, deviceId, s)';

      expect(probe.allMatches(body).length, greaterThanOrEqualTo(4),
          reason: '入表之后有 5 段 await（配置/建 PC+addTrack / createOffer / '
              'setLocalDescription+档位+getLocalDescription / invite 发送）；'
              '少于 4 条复核就说明有窗口没人管（本缺陷的原形）');

      final invite = body.indexOf('RcCmd.callInvite');
      final wait = body.indexOf('_startWaitTimer(s)');
      expect(invite, greaterThan(0), reason: '找不到 invite 发送点 ⇒ 锁本身失效');
      expect(wait, greaterThan(invite), reason: '找不到计时器起点 ⇒ 锁本身失效');

      expect(body.lastIndexOf(probe, invite),
          greaterThan(body.indexOf('getLocalDescription')),
          reason: '★ invite 之前必须复核：少了它，用户点了挂断对端照样振铃');
      expect(body.lastIndexOf(probe, wait), greaterThan(invite),
          reason: '★ invite 之后、起计时器之前必须复核：否则孤儿会话跑满 45s');
    });
  });
}
