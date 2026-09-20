import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/call_lifecycle.dart';

/// BUG-050 的宿主机回归锁。
///
/// ## 为什么要有这个文件
///
/// BUG-050：主叫侧没有接听超时 → 被叫未开自动接通时**主叫无限等待且无"未接"反馈**。
/// 这条逻辑原先埋在 `CallService` 里（依赖 flutter_webrtc + 真实信令），
/// **宿主机无法实例化 → 整整一个版本没被测过**。
///
/// 本文件锁两层：
/// 1. **判定逻辑本身**（`call_lifecycle.dart` 的纯函数）；
/// 2. **接线**（`CallService` 真的用了它、`endpoint_service` 真的会发 `callMissed`）
///    —— 否则纯逻辑可以"全绿但没人调用"，那是本项目最熟悉的那类假绿。
void main() {
  /// 剥掉行注释后再断言。
  ///
  /// ⚠️ 直接 `contains` 会被**注释掉的代码**骗过（本项目已踩过）：
  /// 把 `callerAnswerTimeout` 写进注释也能让契约锁通过。
  String code(String src) => src
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i < 0 ? l : l.substring(0, i);
      })
      .join('\n');

  group('CL 超时判定（主叫接听超时 / 被叫振铃超时）', () {
    test('CL-01 到点即超时，差 1ms 不算', () {
      expect(waitTimedOut(elapsedMs: 44999, limit: callerAnswerTimeout), isFalse);
      expect(waitTimedOut(elapsedMs: 45000, limit: callerAnswerTimeout), isTrue);
      expect(waitTimedOut(elapsedMs: 45001, limit: callerAnswerTimeout), isTrue);
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
        expect(shouldNotifyEnd(r), isFalse,
            reason: '$r 是本端自己刚点的动作，再弹一次就是噪音');
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

  group('CL 接线锁（纯逻辑必须真的被用上，否则本文件全是恒真）', () {
    late String callService;
    late String endpointService;
    late String overlay;

    setUpAll(() {
      final candidates = [
        'lib/remote/call_service.dart',
        '../lib/remote/call_service.dart',
      ];
      final f = candidates.map(File.new).where((e) => e.existsSync()).toList();
      if (f.isEmpty) {
        throw StateError('找不到 lib/remote/call_service.dart（cwd=${Directory.current.path}）');
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
  });
}
