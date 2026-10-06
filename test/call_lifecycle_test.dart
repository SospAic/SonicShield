import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/call_lifecycle.dart';

import 'support/source_text.dart';

/// 通话生命周期的宿主机回归锁。
///
/// ## 为什么要有这个文件
///
/// **BUG-050**：主叫侧没有接听超时 → 被叫未开自动接通时**主叫无限等待且无"未接"反馈**。
/// **BUG-056**：「自动接通」开关**关掉也照样接通**（来电处理里 `onManualRing`
/// 会立刻代为接通）→ 使用者的隐私开关形同虚设。
///
/// 这两段逻辑原先都埋在 `CallService` 里（依赖 flutter_webrtc + 真实信令），
/// **宿主机无法实例化 → 整整一个版本没被测过**。
///
/// 本文件锁两层：
/// 1. **判定逻辑本身**（`call_lifecycle.dart` 的纯函数）；
/// 2. **接线**（`CallService` 真的用了它、`endpoint_service` 真的会发 `callMissed`、
///    来电处理**不得**代为接通、接听界面真的常驻）
///    —— 否则纯逻辑可以"全绿但没人调用"，那是本项目最熟悉的那类假绿。
void main() {
  /// 剥掉行注释后再断言。
  ///
  /// ⚠️ 直接 `contains` 会被**注释掉的代码**骗过（本项目已踩过）：
  /// 把 `callerAnswerTimeout` 写进注释也能让契约锁通过。
  String code(String src) => src.split('\n').map((l) {
        final i = l.indexOf('//');
        return i < 0 ? l : l.substring(0, i);
      }).join('\n');

  group('CL 超时判定（主叫接听超时 / 被叫振铃超时）', () {
    test('CL-01 到点即超时，差 1ms 不算', () {
      expect(
          waitTimedOut(elapsedMs: 44999, limit: callerAnswerTimeout), isFalse);
      expect(
          waitTimedOut(elapsedMs: 45000, limit: callerAnswerTimeout), isTrue);
      expect(
          waitTimedOut(elapsedMs: 45001, limit: callerAnswerTimeout), isTrue);
    });

    test('CL-02 已接通后超时不得判为"未接"（否则通话中会显示"对方无应答"）', () {
      expect(
        timedOutMeansMissed(
            answered: false, elapsedMs: 45000, limit: callerAnswerTimeout),
        isTrue,
        reason: '未接通且到点 → 未接',
      );
      expect(
        timedOutMeansMissed(
            answered: true, elapsedMs: 45000, limit: callerAnswerTimeout),
        isFalse,
        reason: '已接通 → 绝不能报未接',
      );
      expect(
        timedOutMeansMissed(
            answered: true, elapsedMs: 999999, limit: callerAnswerTimeout),
        isFalse,
        reason: '已接通且严重超时 → 仍不得报未接',
      );
    });

    test('CL-03 两个角色各有上限，且都不为 0（为 0 会让每次呼叫立刻"未接"）', () {
      expect(waitLimitMs(isCaller: true), callerAnswerTimeout.inMilliseconds);
      expect(waitLimitMs(isCaller: false), calleeRingTimeout.inMilliseconds);
      expect(waitLimitMs(isCaller: true), greaterThan(0));
      expect(waitLimitMs(isCaller: false), greaterThan(0));
    });
  });

  group('CL 应答后建连超时（BUG-081：永久「连接中」）', () {
    test('CL-21 未连通到点即超时，差 1ms 不算', () {
      expect(connectTimedOut(connected: false, elapsedMs: 14999), isFalse);
      expect(connectTimedOut(connected: false, elapsedMs: 15000), isTrue);
      expect(connectTimedOut(connected: false, elapsedMs: 15001), isTrue);
    });

    test('CL-22 已 connected 后任何时长都不得判超时（否则通话中会被强拆）', () {
      for (final ms in [15000, 60000, 999999]) {
        expect(connectTimedOut(connected: true, elapsedMs: ms), isFalse,
            reason: '媒体已通 → 残留计时器不得把进行中的通话判成失败');
      }
    });

    test('CL-23 建连上限不为 0，且短于等待应答上限', () {
      expect(connectTimeout.inMilliseconds, greaterThan(0),
          reason: '为 0 会让每通电话刚应答就判失败');
      expect(connectTimeout.inMilliseconds,
          lessThan(callerAnswerTimeout.inMilliseconds),
          reason: '"接起来好久连不上"不该比"没人接"还慢');
    });
  });

  group('CL TURN TCP 回落推导（封 UDP 网络）', () {
    test('CL-24 裸 turn: URL 推导出 ?transport=tcp', () {
      expect(turnTcpFallbackUrl('turn:relay.example.com:3478'),
          'turn:relay.example.com:3478?transport=tcp');
    });

    test('CL-25 已带 query 的 URL 不重复追加（尊重显式选择）', () {
      expect(turnTcpFallbackUrl('turn:relay.example.com:3478?transport=udp'),
          isNull);
      expect(turnTcpFallbackUrl('turn:relay.example.com:3478?transport=tcp'),
          isNull);
    });

    test('CL-26 非 turn: 或空串不推导（turns: 本就走 TCP）', () {
      for (final u in <String>[
        '',
        '   ',
        'turns:relay.example.com:5349',
        'stun:stun.miwifi.com:3478',
        'relay.example.com:3478',
      ]) {
        expect(turnTcpFallbackUrl(u), isNull, reason: '`$u` 不该被推导');
      }
    });
  });

  group('CL `rc.call` 状态镜像解析', () {
    test('CL-04 三个已知状态解析正确', () {
      expect(parseRemoteCallState('ringing'), RemoteCallState.ringing);
      expect(parseRemoteCallState('connected'), RemoteCallState.connected);
      expect(parseRemoteCallState('ended'), RemoteCallState.ended);
    });

    test('CL-05 未知状态一律 unknown，绝不猜（含大小写/空白/null/非字符串）', () {
      for (final raw in <Object?>[
        null,
        '',
        'RINGING',
        'Connected',
        'connected ',
        'in-call',
        'unknown',
        42,
        true,
        <String>[],
      ]) {
        expect(parseRemoteCallState(raw), RemoteCallState.unknown,
            reason: '`$raw` 必须归 unknown，不得猜测');
      }
    });

    test('CL-06 unknown 必须"什么都不做"（不得取消等待、不得结束通话）', () {
      expect(remoteStateStopsWaiting(RemoteCallState.unknown), isFalse,
          reason: '未知状态若取消等待，主叫会误以为对方已应答 → 永远等不到通话');
      expect(remoteStateEndsCall(RemoteCallState.unknown), isFalse,
          reason: '未知状态若结束通话，协议加一个新 state 就会挂断所有在途通话');
    });

    test('CL-07 connected/ended 停止等待，只有 ended 结束通话', () {
      expect(remoteStateStopsWaiting(RemoteCallState.connected), isTrue);
      expect(remoteStateStopsWaiting(RemoteCallState.ended), isTrue);
      expect(remoteStateStopsWaiting(RemoteCallState.ringing), isFalse,
          reason: 'ringing 只更新镜像，主叫仍需继续等待');

      expect(remoteStateEndsCall(RemoteCallState.ended), isTrue);
      expect(remoteStateEndsCall(RemoteCallState.connected), isFalse);
      expect(remoteStateEndsCall(RemoteCallState.ringing), isFalse);
    });
  });

  group('CL 结束原因与文案', () {
    test('CL-08 `busy` 必须映射成"占线"，不得退化成"对方已挂断"', () {
      expect(endReasonFromSignal('busy'), CallEndReason.busy);
      expect(callEndText(CallEndReason.busy), '对方正在通话中');
      expect(endReasonFromSignal('rejected'), CallEndReason.rejected);
      expect(callEndText(CallEndReason.rejected), '对方已拒接');
    });

    test('CL-09 未知 reason 归"对方已挂断"（中性），不得猜成具体原因', () {
      for (final raw in <Object?>[null, '', 'wat', 7, 'BUSY']) {
        expect(endReasonFromSignal(raw), CallEndReason.remoteEnded,
            reason: '`$raw` 是未知 reason，只能给中性文案');
      }
    });

    test('CL-10 每个结束原因都有非空且互不相同的文案（防复制粘贴漏改）', () {
      final texts = <String>[];
      for (final r in CallEndReason.values) {
        final t = callEndText(r);
        expect(t, isNotEmpty, reason: '$r 没有文案');
        texts.add(t);
      }
      expect(texts.toSet().length, CallEndReason.values.length,
          reason: '有两个结束原因显示了同一句话：$texts');
    });

    test('CL-11 "未接"文案必须能表达"对方无应答"', () {
      expect(callEndText(CallEndReason.missed), contains('无应答'));
    });

    test('CL-16 本端拒接不得复用"对方已拒接"（否则用户以为自己被拒了）', () {
      expect(callEndText(CallEndReason.declined), '已拒接');
      expect(callEndText(CallEndReason.declined),
          isNot(callEndText(CallEndReason.rejected)),
          reason: '`rejected` 是给被拒的一方看的，本端拒接必须另有文案');
      // 信令层 `rejected` 仍然映射到"对方已拒接"（对端视角正确）。
      expect(endReasonFromSignal('rejected'), CallEndReason.rejected);
    });

    test('CL-17 只有"对端振铃"才显示"对方振铃中"，其余仍是"连接中"', () {
      expect(connectingText(RemoteCallState.ringing), contains('振铃'),
          reason: '主叫看不到"对方振铃中"就无法区分"对方在响"与"信令没送到"');
      for (final s in [
        RemoteCallState.connected,
        RemoteCallState.ended,
        RemoteCallState.unknown,
      ]) {
        expect(connectingText(s), isNot(contains('振铃')),
            reason: '$s 不得显示"对方振铃中"（unknown 尤其不能猜）');
      }
      expect(connectingText(RemoteCallState.unknown), '连接中…');
    });

    test('CL-18 本端动作不弹提示；远端原因与失败必须弹', () {
      const notified = <CallEndReason>{
        CallEndReason.missed,
        CallEndReason.rejected,
        CallEndReason.busy,
        CallEndReason.remoteEnded,
        CallEndReason.failed,
      };
      const silent = <CallEndReason>{
        CallEndReason.answered,
        CallEndReason.hangup,
        CallEndReason.declined,
      };
      for (final r in silent) {
        expect(shouldNotifyEnd(r), isFalse, reason: '$r 是本端自己刚点的动作，再弹一次就是噪音');
      }
      for (final r in notified) {
        expect(shouldNotifyEnd(r), isTrue,
            reason: '$r 不告知用户 = 又回到"无声无息退回上一页"（BUG-050 的症状）');
      }
      // 防"新增原因没被归类"：两个清单必须**恰好**覆盖全部枚举值。
      // （不能写成恒真的 partition 断言 —— 那等于没测。）
      expect(notified.union(silent), CallEndReason.values.toSet(),
          reason: '新增了 CallEndReason 却没在本用例里归类；'
              '`shouldNotifyEnd` 的穷尽 switch 会编译报错，这里补一条可读的红灯');
    });
  });

  group('CA 被叫接听动作（BUG-056）', () {
    test('CA-01 开关关闭 ⇒ 必须振铃等用户，**绝不自动接通**', () {
      // 这是 BUG-056 的核心断言。
      // 修之前 `_handleCallInvite` 的 onManualRing 会**立刻 acceptIncoming**，
      // 于是"关掉自动接通"这个动作对行为**没有任何影响**。
      expect(
        calleeActionFor(autoAnswer: false, inCall: false),
        CalleeAction.ringUser,
        reason: '开关关闭时自动接通 = 使用者的隐私开关形同虚设',
      );
    });

    test('CA-02 开关开启 ⇒ 自动接通', () {
      expect(calleeActionFor(autoAnswer: true, inCall: false),
          CalleeAction.autoAccept);
    });

    test('CA-03 占线优先于开关（两种开关状态都必须回 busy）', () {
      for (final auto in [true, false]) {
        expect(calleeActionFor(autoAnswer: auto, inCall: true),
            CalleeAction.rejectBusy,
            reason: 'autoAnswer=$auto 时占线仍须回 busy，否则主叫要等到超时');
      }
    });

    test('CA-04 四个组合全覆盖，且默认值是 ringUser（不是 autoAccept）', () {
      final seen = <CalleeAction>{};
      for (final auto in [true, false]) {
        for (final busy in [true, false]) {
          seen.add(calleeActionFor(autoAnswer: auto, inCall: busy));
        }
      }
      expect(seen, {
        CalleeAction.autoAccept,
        CalleeAction.ringUser,
        CalleeAction.rejectBusy
      });
      // 只有"显式开启"那一个组合才会自动接通。
      var autoCount = 0;
      for (final auto in [true, false]) {
        for (final busy in [true, false]) {
          if (calleeActionFor(autoAnswer: auto, inCall: busy) ==
              CalleeAction.autoAccept) {
            autoCount++;
          }
        }
      }
      expect(autoCount, 1, reason: '自动接通只能由"开关开启且不在通话中"这一个组合触发');
    });

    test('CA-05 来电文案必须带上对方名字，并区分视频/语音', () {
      expect(
          incomingCallText(fromName: '妈妈的手机', video: true), contains('妈妈的手机'));
      expect(incomingCallText(fromName: '妈妈的手机', video: true), contains('视频'));
      expect(incomingCallText(fromName: '妈妈的手机', video: false), contains('语音'));
      expect(incomingCallText(fromName: '妈妈的手机', video: true),
          isNot(incomingCallText(fromName: '妈妈的手机', video: false)),
          reason: '视频/语音必须能区分，否则用户不知道要不要穿好衣服');
    });

    test('CA-06 只有振铃状态才能接听', () {
      expect(canAcceptNow(true), isTrue);
      expect(canAcceptNow(false), isFalse);
    });
  });

  group('CL 接线锁（纯逻辑必须真的被用上，否则本文件全是恒真）', () {
    late String callService;
    late String endpointService;
    late String overlay;
    late String appDart;


    setUpAll(() {
      final candidates = [
        'lib/remote/call_service.dart',
        '../lib/remote/call_service.dart',
      ];
      final f = candidates.map(File.new).where((e) => e.existsSync()).toList();
      if (f.isEmpty) {
        throw StateError(
            '找不到 lib/remote/call_service.dart（cwd=${Directory.current.path}）');
      }
      callService = code(f.first.readAsStringSync());

      final e2 = [
        'lib/remote/endpoint_service.dart',
        '../lib/remote/endpoint_service.dart',
      ].map(File.new).where((e) => e.existsSync()).toList();
      if (e2.isEmpty) {
        throw StateError('找不到 lib/remote/endpoint_service.dart');
      }
      endpointService = code(e2.first.readAsStringSync());

      final o = [
        'lib/features/remote/call_incoming_overlay.dart',
        '../lib/features/remote/call_incoming_overlay.dart',
      ].map(File.new).where((e) => e.existsSync()).toList();
      if (o.isEmpty) {
        throw StateError('找不到 lib/features/remote/call_incoming_overlay.dart');
      }
      overlay = code(o.first.readAsStringSync());

      final a = [
        'lib/app.dart',
        '../lib/app.dart',
      ].map(File.new).where((e) => e.existsSync()).toList();
      if (a.isEmpty) throw StateError('找不到 lib/app.dart');
      appDart = code(a.first.readAsStringSync());
    });

    test('CL-12 CallService 必须真的启动等待计时（主叫 + 被叫两条路径）', () {
      // ⚠️ 断言的是**两个调用点**而不是常量名：`_startWaitTimer` 内部统一走
      // `waitLimitMs(isCaller: isCaller)`，所以 `callerAnswerTimeout` 这个字面量
      // 在服务里根本不出现。只断言常量名会得到一个恒真的锁。
      expect(callService, contains('_startWaitTimer(isCaller: true)'),
          reason: '主叫路径没有启动接听超时 → 又回到 BUG-050');
      expect(callService, contains('_startWaitTimer(isCaller: false)'),
          reason: '被叫路径没有启动振铃超时 → 无人接听时两端都在空等');
      expect(callService, contains('waitLimitMs'),
          reason: '超时上限必须取自纯逻辑，不得在服务里另写一套');
      expect(callService, contains('timedOutMeansMissed'),
          reason: '超时判定必须走纯逻辑，不得在服务里另写一套');
    });

    test('CL-13 CallService 必须消费 rc.call 与 rc.call.missed（App 内消费方）', () {
      expect(callService, contains('RcEvt.callState'),
          reason: '不消费 rc.call → 控制台看不到对方是否振铃（BUG-050 的第二半）');
      expect(callService, contains('RcEvt.callMissed'),
          reason: '不消费 rc.call.missed → 对方判定的"未接"到达后无人处理');
      expect(callService, contains('parseRemoteCallState'),
          reason: '状态解析必须走纯逻辑');
    });

    test('CL-14 端点必须真的会发出 rc.call.missed（否则事件永远等不到）', () {
      expect(endpointService, contains('RcEvt.callMissed'),
          reason: '被叫振铃超时后必须由端点侧发出 rc.call.missed；'
              '只写注释不算');
    });

    test('CL-15 超时计时器必须在 teardown 里取消（不得泄漏 Timer）', () {
      expect(callService, contains('_cancelWaitTimer'),
          reason: 'teardown 不取消计时器 → 通话结束后仍会触发"未接"回调');
      expect(callService, contains('_waitTimer?.cancel()'),
          reason: '取消动作必须真的调用 Timer.cancel');
    });

    test('CL-19 通话 UI 必须真的消费 callEnded / connectingText（否则用户仍然看不到）', () {
      expect(overlay, contains('callEnded'),
          reason: 'UI 不听 callEnded → 纯逻辑算出来的"对方无应答"没人显示');
      expect(overlay, contains('callEndText'),
          reason: '文案必须取自纯逻辑（callEndText），不得在 UI 里另写一套');
      expect(overlay, contains('connectingText'),
          reason: '不消费 rc.call 状态 → 主叫永远只看到"连接中…"');
    });

    test('CL-20 main 必须把端点的已解密事件流接给 CallService（否则 attach 无人调用）', () {
      final m = [
        'lib/main.dart',
        '../lib/main.dart',
      ].map(File.new).where((e) => e.existsSync()).toList();
      if (m.isEmpty) throw StateError('找不到 lib/main.dart');
      final mainSrc = code(m.first.readAsStringSync());
      expect(mainSrc, contains('CallService.instance.attach'),
          reason: '`attach` 定义了却没人调用 = `rc.call` 仍然无人消费（恒真的接线锁）');
      expect(mainSrc, contains('RcEndpointService.instance.events'),
          reason: '必须接的是端点**已解密**的事件流');
    });

    test('CA-07 CallService 的被叫分支必须走 calleeActionFor（不得另写一套判断）', () {
      expect(callService, contains('calleeActionFor'),
          reason: '不接纯逻辑 → "开关关闭也要振铃"这条规则就没有任何锁');
      expect(callService, contains('CalleeAction.ringUser'),
          reason: '必须显式处理 ringUser 分支，否则手动路径等于没实现');
    });

    test('CA-08 【BUG-056 回归锁】来电处理里**不得**代为接通', () {
      final body =
          methodBody(endpointService, 'Future<void> _handleCallInvite(');
      expect(body, isNot(contains('acceptIncoming')),
          reason: '来电处理里出现 acceptIncoming = 又变成"收到 invite 就接通"，'
              '「自动接通」开关会再次形同虚设（BUG-056）');
      expect(body, contains('onIncomingCall'),
          reason: '来电处理必须把决策交给 CallService');
    });

    test('CA-09 `onManualRing` 这个回调必须彻底消失（让错误接线不可能复活）', () {
      // 该参数存在的**唯一**用途就是让调用方代为接通 —— 去掉它，
      // BUG-056 的那种写法就无从写起（而不是只靠注释提醒）。
      expect(callService, isNot(contains('onManualRing')),
          reason: '`onManualRing` 回来了 → 又会有人往里面塞 acceptIncoming');
      expect(endpointService, isNot(contains('onManualRing')),
          reason: '同上：调用方不得再有"代为接通"的入口');
    });

    test('CA-10 【BUG-056】接听界面必须挂在 builder 上（否则被叫接不到电话）', () {
      expect(appDart, contains('CallOverlayHost'),
          reason: '来电界面若不常驻，被叫不在通话页时就没有接听入口 —— '
              '关掉自动接通后，来电会全部变成"无人接听"');
      expect(appDart, contains('builder:'),
          reason: '必须挂在 MaterialApp.builder 上才在所有路由之上');
    });

    test('CA-11 【BUG-056】界面「接听」必须走 acceptPending，不得自己拼 invite', () {
      expect(overlay, contains('acceptPending'),
          reason: '接听必须用服务层暂存的 invite，否则界面拿不到 SDP');
      expect(overlay, contains('declinePending'),
          reason: '拒接同理，且要走"本端拒接"的语义（declined）');
      expect(overlay, isNot(contains('acceptIncoming')),
          reason: '界面不应直接调 acceptIncoming（它需要 invite/peer/store 三件套，'
              '界面不该持有这些）');
    });

    test('CL-27 【BUG-081 回归锁】应答后必须启动建连计时，并在收尾取消', () {
      expect(callService, contains('_startConnectTimer()'),
          reason: '应答后不启动建连计时 → 又回到"永久连接中"（BUG-081）');
      expect(callService, contains('_cancelConnectTimer()'),
          reason: '收尾/连通时必须取消建连计时，不得泄漏 Timer');
      expect(callService, contains('connectTimedOut'),
          reason: '建连超时判定必须走纯逻辑，不得在服务里另写一套');
    });

    test('CL-28 【BUG-081】超时必须发信令通知对端（不得只本地收尾）', () {
      expect(callService, contains("_sendEndSignal(reason: 'missed')"),
          reason: '主叫超时只做本地收尾 → 被叫永久停在"连接中"');
      expect(callService, contains("_sendEndSignal(reason: 'media')"),
          reason: '建连失败也必须通知对端，否则一边退出一边卡住');
    });
  });
}
