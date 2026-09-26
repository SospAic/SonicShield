import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/multi_call_service.dart';
import 'package:sonic_shield/remote/protocol.dart';

/// P0 全链路断链锁：多路视频的事件取值必须走 `payload`。
///
/// ## 缺陷本体
///
/// `RcEndpointService._broadcast` 广播的是
/// `{...msg.toJson(), peerId, peerName}`，即
/// `{v, id, ts, type, payload, from, peerId, peerName}` ——
/// **业务字段全部在 `payload` 之内**（见 `protocol.dart` 的 `rcPayloadOf`）。
///
/// 修之前 `ownedCallIdOf` 与 `_onRemoteEvent` 在**顶层**取
/// `m['callId'] / m['sdp'] / m['candidate']` → 恒为 null
/// ⇒ `_onRemoteEvent` 第一行就 `return`
/// ⇒ answer/candidate/end **全部被丢弃**
/// ⇒ 多路视频永远接不通（UI 永久停在"连接中…"）。
///
/// 这类错误**不抛异常、不报错**，只是"什么都没发生"，所以只能靠锁。
void main() {
  group('P0 信封取值：必须走 payload', () {
    const owned = {'c1', 'c2'};

    test('MCO-01 真实信封形状命中（answer 的业务字段在 payload 内）', () {
      // 与 `_broadcast` 实际产出的形状逐字段一致。
      final envelope = <String, dynamic>{
        'v': 1,
        'id': 'abcdefghijkl',
        'ts': 1700000000000,
        'type': 'call.answer',
        'payload': {
          'callId': 'c1',
          'sdp': 'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n',
        },
        'from': 'peer',
        'peerId': 'peer',
        'peerName': '客厅',
      };
      expect(ownedCallIdOf(envelope, owned), 'c1');
    });

    test("MCO-02 顶层字段形状**不命中**（防回退到 m['callId']）", () {
      // 这就是"修之前"的取值位置。它必须**取不到** ——
      // 一旦有人把实现改回顶层，MCO-01 立刻变红；这条保证"顶层确实没有"。
      expect(
        ownedCallIdOf({'type': 'call.answer', 'callId': 'c1'}, owned),
        isNull,
      );
    });

    test('MCO-03 payload 里的 callId 不属于本服务 -> null（隔离边界不退化）', () {
      expect(
        ownedCallIdOf(
          {
            'type': 'call.answer',
            'payload': {'callId': 'other'},
          },
          owned,
        ),
        isNull,
      );
    });

    test('MCO-04 payload 缺失/类型异常都不崩（远端数据不可信）', () {
      expect(ownedCallIdOf({'type': 'call.answer'}, owned), isNull);
      expect(
          ownedCallIdOf({'type': 'call.answer', 'payload': null}, owned), isNull);
      expect(
          ownedCallIdOf({'type': 'call.answer', 'payload': 'x'}, owned), isNull);
      expect(
        ownedCallIdOf(
            {'type': 'call.answer', 'payload': {'callId': 123}}, owned),
        isNull,
      );
      expect(
        ownedCallIdOf({'type': 'call.answer', 'payload': {'callId': ''}}, owned),
        isNull,
      );
    });

    test('MCO-05 rcPayloadOf 对真实信封给出 payload 本身（answer/candidate 同源）', () {
      final p = rcPayloadOf({
        'type': 'call.candidate',
        'payload': {
          'callId': 'c2',
          'candidate': {'candidate': 'candidate:1 1 udp', 'sdpMid': '0'},
        },
      });
      expect(p['callId'], 'c2');
      expect(p['candidate'], isA<Map<String, dynamic>>());
    });
  });

  group('P0 源码锁：不得再出现顶层取值 / 不得自造超时', () {
    final src = File('lib/remote/multi_call_service.dart').readAsStringSync();
    // 只看**代码**行：注释里为解释缺陷而引用的 `m['callId']` 不是取值。
    final code = src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('MCO-06 取值必须经过 rcPayloadOf', () {
      expect(code.contains('rcPayloadOf(m)'), isTrue);
    });

    test('MCO-07 不得再出现顶层取值（callId/sdp/sdpType/candidate）', () {
      for (final f in ["m['callId']", "m['sdp']", "m['sdpType']", "m['candidate']"]) {
        expect(code.contains(f), isFalse,
            reason: '$f 是顶层取值 —— 恒为 null，会再次把多路视频打成断链');
      }
    });

    test('MCO-08 反向自检：锁本身有效（能读到文件且含已知锚点）', () {
      expect(code.contains('ownedCallIdOf'), isTrue);
      expect(code.contains("m['type']"), isTrue, reason: 'type 确实在信封顶层');
    });

    test('MCO-09 未接超时必须复用 call_lifecycle 的纯函数，不得自造时限', () {
      expect(code.contains('waitLimitMs(isCaller: true)'), isTrue,
          reason: '必须复用 callerAnswerTimeout，不能新造一套');
      expect(code.contains('timedOutMeansMissed('), isTrue,
          reason: '必须复用"已应答就不算未接"的判定');
      expect(RegExp(r'Duration\(seconds:\s*45\)').hasMatch(code), isFalse,
          reason: '自造 45s 会与 call_lifecycle.callerAnswerTimeout 漂移');
    });

    test('MCO-10 覆盖层必须覆盖 connecting（不得只在 ringing/connected 显示）', () {
      final ov =
          File('lib/features/remote/call_incoming_overlay.dart').readAsStringSync();
      final idx = ov.indexOf('final showCall');
      expect(idx, greaterThan(0), reason: '找不到 showCall 判定');
      final line = ov.substring(idx, ov.indexOf(';', idx));
      expect(line.contains('CallPhase.idle') && line.contains('CallPhase.ended'),
          isTrue,
          reason: '应以"非 idle/ended"为准，否则点接听后整段"协商中"没有界面');
      expect(line.contains('CallPhase.ringing'), isFalse,
          reason: '只认 ringing/connected 会让 connecting 期间覆盖层消失');
    });

    test('MCO-11 多路发起前必须做权限前置且给出具体文案（不得静默）', () {
      final s =
          File('lib/features/remote/multi_video_screen.dart').readAsStringSync();
      // 与本 group 里 MCO-06~09 同一规则：只看**代码**行 ——
      // 注释里解释「为什么要有 callStartBlockFor」不是调用；
      // 不剥注释的话，一句注释就能把这条锁永久喂绿（W5 P1）。
      final code = s
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('callStartBlockFor('), isTrue,
          reason: '发起前必须问相机/麦克风权限（参照单路 call_screen._call）');
      expect(code.contains('callStartBlockText('), isTrue,
          reason: '被拦下必须给具体原因，不能静默 return');
    });
  });
}
