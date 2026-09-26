import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/call_lifecycle.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 覆盖率补强：`call_service.dart` 里**宿主机可达的行为**（状态机、守卫、
/// 信令事件消费、收尾路径），全部走真实代码路径，不写源码锁。
///
/// ## 为什么这样测
///
/// - `CallService` 是单例，宿主机拿不到相机/麦克风 ⇒ `startCall` /
///   `acceptIncoming` 的 `_ensureMedia` 必然失败（`getUserMedia` 抛
///   `MissingPluginException`，被 `_ensureMedia` 的 `on Object` 吃掉）——
///   这正是生产里"权限被拒"分支的**真实形状**，失败收场（teardown /
///   lastStartBlock / 相位序列）全部可断言。
/// - 信令事件（`rc.call` / `rc.call.missed`）通过 [CallService.attach]
///   喂进真实事件流，断言 `remoteState` 镜像与结束原因。
/// - 相位推进用官方测试缝 [CallService.setPhaseForTest]（仅改状态、
///   不发信令，`@visibleForTesting` 仅供测试）。
///
/// ## ⚠️ 与第 34 轮隔离版（`_pt/quarantine/cov_remote_ctrl2_test.dart`）的差异
///
/// 旧版有若干断言**依赖"上一条用例恰好把单例留成某个值"**，前序用例一变就
/// 整片假红（第 34 轮实测 7 处，登记于 `docs/17 §61.5-2`）。
/// `CallService` 是单例且**没有** `@visibleForTesting` 复位缝（本轮只被授权
/// 给 `PlaybackService` 加缝，`call_service.dart` 只读），所以本文件用两条纪律
/// 把"顺序依赖"从根上拿掉：
///
/// 1. `setUp` 里显式 `setPhaseForTest(idle)` —— 相位不再跨用例漂移；
/// 2. 凡是"这次动作**不得**产生某个副作用"的判据，一律写成**前后对比**
///    （`before` == `after`），而不是"等于某个绝对值"：
///    `lastEndReason` / `remoteState` 是**跨会话保留**的字段
///    （`_teardown` 只在 `reason != null` 时写 `_endReason`，
///    `call_service.dart:795-798`），断言 `isNull` 会随前序用例而假红。
///
/// ⚠️ 纪律：凡开过"振铃等待计时器"的用例，必须在用例内 teardown
/// （拒接 / 接听失败收场都会取消计时器），不让 45s 计时器泄漏到后续用例。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RemoteStore store;
  late PairedEndpoint endpoint;
  final svc = CallService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = RemoteStore(await SharedPreferences.getInstance());
    await store.setIdentity('ctrl-1', '控制端A');
    endpoint = PairedEndpoint(
      deviceId: 'dev-1',
      name: '端点一',
      secret: 'secret-dev-1',
      pairedAt: DateTime.now(),
    );
    // 单例相位跨用例存活：显式归位。缺这一句时，任何"上一条用例把相位留在
    // ringing/connecting"的漂移都会让后续用例的 `inCall` 判据整体错位
    // （旧隔离版正是这一类假红）。`setPhaseForTest` 只改状态、不发信令。
    svc.setPhaseForTest(CallPhase.idle);
  });

  Map<String, dynamic> invite({String callId = 'in-1', bool video = false}) =>
      {'callId': callId, 'video': video, 'sdp': 'v=0 fake', 'type': 'offer'};

  group('相位状态机与发起守卫', () {
    // ⚠️ 本用例断言**全新单例**的快照，必须保持为本文件第一条
    // （`CallService` 无复位缝，`lastEndReason`/`callId` 只能靠"没人动过"来保证）。
    test('CS-01 初始快照：idle / 非通话中 / 无原因 / 无拦截', () {
      expect(svc.currentPhase, CallPhase.idle);
      expect(svc.inCall, isFalse);
      expect(svc.isCaller, isFalse);
      expect(svc.callId, isNull);
      expect(svc.peerDeviceId, isNull);
      expect(svc.awaitingAnswer, isFalse);
      expect(svc.lastEndReason, isNull);
      expect(svc.lastStartBlock, isNull);
      expect(svc.failureReason, isNull);
      expect(svc.remoteState, RemoteCallState.unknown);
      expect(svc.remoteStream, isNull);
      expect(svc.localStream, isNull);
    });

    test('CS-02 setPhaseForTest 真广播相位；inCall 随相位翻转', () async {
      final seen = <CallPhase>[];
      final sub = svc.phase.listen(seen.add);
      addTearDown(sub.cancel);

      svc.setPhaseForTest(CallPhase.ringing);
      await pumpEventQueue();
      expect(seen, contains(CallPhase.ringing));
      expect(svc.currentPhase, CallPhase.ringing);
      expect(svc.inCall, isTrue);

      svc.setPhaseForTest(CallPhase.idle);
      await pumpEventQueue();
      expect(seen.last, CallPhase.idle);
      expect(svc.inCall, isFalse);
    });

    test('CS-03 通话中再发起 → 拦下（alreadyInCall），相位与 callId 不被污染',
        () async {
      final callIdBefore = svc.callId;
      svc.setPhaseForTest(CallPhase.ringing);
      final callId = await svc.startCall(endpoint, store);
      expect(callId, isNull);
      expect(svc.lastStartBlock, CallStartBlock.alreadyInCall,
          reason: '被拦必须给出可执行的下一步原因（BUG-D：返回 null 却不说为什么）');
      expect(svc.currentPhase, CallPhase.ringing, reason: '被拦不得动相位');
      // 锁：`startCall` 的拦截分支在 `_callId = const Uuid().v4()` **之前**返回
      // （call_service.dart:304-307），因此既不得生成新 callId，也不得清掉既有值。
      expect(svc.callId, callIdBefore, reason: '被拦不得生成/清掉 callId');
      svc.setPhaseForTest(CallPhase.idle);
    });

    test('CS-04 宿主机发起：媒体必失败 → connecting/ended/idle 相位序列 + '
        'mediaFailed 原因', () async {
      final endReasonBefore = svc.lastEndReason;
      final seen = <CallPhase>[];
      final sub = svc.phase.listen(seen.add);
      addTearDown(sub.cancel);

      final callId = await svc.startCall(endpoint, store, video: true);
      await pumpEventQueue();

      expect(callId, isNull);
      expect(svc.lastStartBlock, CallStartBlock.mediaFailed,
          reason: '失败必须区分"权限/媒体打不开"与"端点离线"（文案与下一步都不同）');
      // 锁：`startCall` 的媒体失败收尾是 `await _teardown()`（**不带 reason**，
      // call_service.dart:320），所以 `_endReason` 必须**保持原值** ——
      // 旧版写 `isNull` 是在赌"前面没人收过场"，前序用例一变就假红。
      expect(svc.lastEndReason, endReasonBefore,
          reason: '媒体失败的收尾不带语义原因（caller 另有文案），且不得覆盖上一通的收场原因');
      expect(seen, [CallPhase.connecting, CallPhase.ended, CallPhase.idle],
          reason: 'ended 只是瞬时相位，微任务后必须归位 idle');
      expect(svc.inCall, isFalse);
      expect(svc.peerDeviceId, isNull, reason: 'teardown 必须清掉对端');
    });
  });

  group('被叫：振铃 / 拒接 / 占线 / 接听收场', () {
    test('CS-05 手动振铃：默认不自动接通；拒接 → declined 收场且不发暂存',
        () async {
      final remoteStateBefore = svc.remoteState;
      expect(await svc.onIncomingCall(invite(), endpoint, store), isTrue);
      expect(svc.currentPhase, CallPhase.ringing);
      expect(svc.awaitingAnswer, isTrue, reason: 'pendingInvite + ringing');
      expect(svc.isCaller, isFalse);
      expect(svc.callId, 'in-1');
      expect(svc.peerDeviceId, 'dev-1');
      // 锁：`onIncomingCall` 只写本机会话状态，**不碰** `_remoteState` ——
      // 那个镜像专属于对端 `rc.call`（call_service.dart:188-191）。
      // 写成"必须等于 unknown"会把"本端振铃不得改动镜像"错锁成"镜像此刻恰好是 unknown"。
      expect(svc.remoteState, remoteStateBefore,
          reason: '本端振铃不得改动「对端状态」镜像');
      expect(store.outboxFor('dev-1'), isEmpty, reason: '振铃本身不发信令');

      await svc.rejectCall(store);
      await pumpEventQueue();
      expect(svc.lastEndReason, CallEndReason.declined,
          reason: '本端拒接必须用 declined（不是"对方已拒接"的 rejected）');
      expect(svc.callId, isNull);
      expect(svc.awaitingAnswer, isFalse);
      expect(svc.currentPhase, CallPhase.idle);
      expect(store.outboxFor('dev-1'), isEmpty,
          reason: '实时信令不走 outbox（enqueueOnFail=false）');
    });

    test('CS-06 通话中来电话 → 回 busy 拒掉，相位不变、无暂存、无收场', () async {
      final endReasonBefore = svc.lastEndReason;
      svc.setPhaseForTest(CallPhase.connecting);
      final accepted =
          await svc.onIncomingCall(invite(callId: 'in-2'), endpoint, store);
      expect(accepted, isFalse);
      expect(svc.currentPhase, CallPhase.connecting,
          reason: '占线路径不动本机相位');
      // 锁：占线分支只回一条 `call.end reason=busy` 就 return
      // （call_service.dart:384-389），**不进 `_teardown`** ——
      // 所以本机不得新增/覆盖收场原因（旧版写 `isNull`，被前一条用例的
      // declined 打成假红，正是第 34 轮隔离的 7 处之一）。
      expect(svc.lastEndReason, endReasonBefore,
          reason: '占线不 teardown 本机会话，不得制造/覆盖收场原因');
      expect(store.outboxFor('dev-1'), isEmpty);
      svc.setPhaseForTest(CallPhase.idle);
    });

    test('CS-07 接听守卫：无 pendingInvite / 非振铃相位 / 未绑 store 时都返回 false',
        () async {
      expect(await svc.acceptPending(), isFalse,
          reason: 'idle 下无可接 invite，且不得抛（按钮可能被连点/超时后才点到）');

      // 相位守卫（与用例顺序无关的那一条）：有 invite、有 peer，但相位不是
      // ringing ⇒ 必须原样 false（call_service.dart:498）。
      expect(await svc.onIncomingCall(invite(callId: 'in-3'), endpoint, store),
          isTrue);
      expect(svc.currentPhase, CallPhase.ringing);
      svc.setPhaseForTest(CallPhase.connecting);
      expect(await svc.acceptPending(), isFalse, reason: '非振铃相位不得接通');
      svc.setPhaseForTest(CallPhase.ringing);
      expect(svc.awaitingAnswer, isTrue, reason: '守卫路径不得消费 invite');

      // store 守卫：⚠️ 本用例必须排在 CS-08/CS-09 **之前** —— 它们会
      // `CallService.bindStore`，而 `_storeRef` 是静态、没有解绑缝，
      // 一旦排到后面这条分支就再也走不到（会被 acceptIncoming 的媒体失败
      // 收场，断言随之变成 idle 而非 ringing）。
      expect(await svc.acceptPending(), isFalse);
      expect(svc.currentPhase, CallPhase.ringing);
      expect(svc.awaitingAnswer, isTrue);

      await svc.rejectCall(store); // 收场并取消振铃计时器
      await pumpEventQueue();
      expect(svc.currentPhase, CallPhase.idle);
    });

    test('CS-08 绑定 store 后接听：宿主媒体失败 → failed 收场（不当假成功）',
        () async {
      CallService.bindStore(() async => store);
      expect(await svc.onIncomingCall(invite(callId: 'in-4'), endpoint, store),
          isTrue);

      final ok = await svc.acceptPending();
      await pumpEventQueue();
      expect(ok, isFalse);
      expect(svc.lastEndReason, CallEndReason.failed);
      expect(svc.currentPhase, CallPhase.idle);
      expect(svc.awaitingAnswer, isFalse, reason: 'invite 已被消费');
      expect(store.outboxFor('dev-1'), isEmpty,
          reason: 'media 失败要当场回 call.end 且不暂存');
    });

    test('CS-09 declinePending：拒接按钮路径同样 declined 收场', () async {
      CallService.bindStore(() async => store);
      expect(await svc.onIncomingCall(invite(callId: 'in-5'), endpoint, store),
          isTrue);

      await svc.declinePending();
      await pumpEventQueue();
      expect(svc.lastEndReason, CallEndReason.declined);
      expect(svc.currentPhase, CallPhase.idle);
    });
  });

  group('对端信令消费（attach 事件流）', () {
    test('CS-10 onRemoteEnd 的 reason 映射：busy/未知/缺失', () async {
      final ended = <CallEndReason>[];
      final sub = svc.callEnded.listen(ended.add);
      addTearDown(sub.cancel);

      svc.setPhaseForTest(CallPhase.connecting);
      await svc.onRemoteEnd({'reason': 'busy'});
      await pumpEventQueue();
      expect(svc.lastEndReason, CallEndReason.busy);
      expect(ended, contains(CallEndReason.busy));
      expect(svc.currentPhase, CallPhase.idle);

      svc.setPhaseForTest(CallPhase.connecting);
      await svc.onRemoteEnd({'reason': 'what-is-this'});
      await pumpEventQueue();
      expect(svc.lastEndReason, CallEndReason.remoteEnded,
          reason: '未知 reason 一律中性，不得冒充"已挂断"以外的话术');

      svc.setPhaseForTest(CallPhase.connecting);
      await svc.onRemoteEnd(null);
      await pumpEventQueue();
      expect(svc.lastEndReason, CallEndReason.remoteEnded);
    });

    test('CS-11 rc.call 状态镜像：ringing 生效 / 错 callId 忽略 / 未知状态忽略 / '
        'ended 收场', () async {
      final events = StreamController<Map<String, dynamic>>();
      addTearDown(events.close);
      svc.attach(events.stream);

      final changes = <RemoteCallState>[];
      final sub = svc.remoteStateChanges.listen(changes.add);
      addTearDown(sub.cancel);

      events.add({
        'type': RcEvt.callState,
        'payload': {'state': 'ringing'},
      });
      await pumpEventQueue();
      expect(svc.remoteState, RemoteCallState.ringing);
      expect(changes, contains(RemoteCallState.ringing));

      events.add({
        'type': RcEvt.callState,
        'payload': {'state': 'ringing', 'callId': 'other-call'},
      });
      await pumpEventQueue();
      expect(svc.remoteState, RemoteCallState.ringing,
          reason: '不是本次通话的状态不得覆盖镜像');

      events.add({
        'type': RcEvt.callState,
        'payload': {'state': 'weird-state'},
      });
      await pumpEventQueue();
      expect(svc.remoteState, RemoteCallState.ringing,
          reason: '解析不出已知状态必须忽略');

      events.add({
        'type': RcEvt.callState,
        'payload': {'state': 'ended'},
      });
      await pumpEventQueue();
      expect(svc.lastEndReason, CallEndReason.remoteEnded);
      expect(svc.currentPhase, CallPhase.idle);
      expect(svc.remoteState, RemoteCallState.unknown,
          reason: '收尾必须把镜像归位 unknown');
    });

    test('CS-12 rc.call.missed：idle 时忽略；通话中 → missed 收场', () async {
      final events = StreamController<Map<String, dynamic>>();
      addTearDown(events.close);
      svc.attach(events.stream);

      final endReasonBefore = svc.lastEndReason;
      events.add({
        'type': RcEvt.callMissed,
        'payload': {'callId': 'x'},
      });
      await pumpEventQueue();
      // 锁：`_onRemoteEvent` 的 callMissed 分支第一句就是 `if (!inCall) return;`
      // （call_service.dart:234）—— 空闲时不得 teardown，因此**不得新增收场原因**。
      // 旧版写死 `remoteEnded`（"沿用上一条收场原因"），把"不得制造收场"
      // 错锁成"上一条恰好是 remoteEnded"，前序用例一变即假红。
      expect(svc.lastEndReason, endReasonBefore,
          reason: '空闲时未接通知不得制造新收场（也不得覆盖上一条原因）');
      expect(svc.currentPhase, CallPhase.idle);

      svc.setPhaseForTest(CallPhase.connecting);
      events.add(<String, Object?>{
        'type': RcEvt.callMissed,
        'payload': <String, Object?>{},
      });
      await pumpEventQueue();
      expect(svc.lastEndReason, CallEndReason.missed);
      expect(svc.currentPhase, CallPhase.idle);
    });
  });

  group('自动接通开关（合规隐私开关）', () {
    test('CS-13 setAutoAnswer(true) 后读取为 true，可再关回', () async {
      await CallService.setAutoAnswer(true);
      expect(await CallService.autoAnswerEnabled(), isTrue,
          reason: '「自动接通」开关是使用者唯一能表达"别自动接我电话"的地方（BUG-056）');

      await CallService.setAutoAnswer(false);
      expect(await CallService.autoAnswerEnabled(), isFalse);
    });
  });
}
