import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/multi_call_service.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 多视频同连的核心逻辑锁。
///
/// 重点：多会话服务与既有单会话 `CallService` **共用同一条事件流**，
/// 隔离边界就是"callId 归属"。判错会让两个服务抢同一条信令 ——
/// 症状是随机掉线、两端状态打架，属于**静默**错误，只能靠锁。
void main() {
  group('MCS 事件路由（与 CallService 的隔离边界）', () {
    final owned = {'c1', 'c2'};

    test('MCS-01 自己的 callId -> 返回它', () {
      expect(ownedCallIdOf({'callId': 'c2'}, owned), 'c2');
    });

    test('MCS-02 别人的 callId -> null（不抢信令）', () {
      // 来电 / 单会话通话的 callId 不在本服务名下，必须放过。
      expect(ownedCallIdOf({'callId': 'other'}, owned), isNull);
    });

    test('MCS-03 没有 callId -> null', () {
      expect(ownedCallIdOf({'type': 'ping'}, owned), isNull);
      expect(ownedCallIdOf({}, owned), isNull);
      expect(ownedCallIdOf({'callId': null}, owned), isNull);
    });

    test('MCS-04 callId 类型异常不崩（远端数据不可信）', () {
      expect(ownedCallIdOf({'callId': 123}, owned), isNull);
      expect(ownedCallIdOf({'callId': ''}, owned), isNull);
    });
  });

  group('MCS 切换焦点（切换不断开其它路）', () {
    test('MCS-05 当前仍在列表 -> 保持不变', () {
      // 别人挂断时不该把焦点跳走（否则使用者正在操作的窗口会莫名切换）。
      expect(nextActiveId(['a', 'b'], 'b'), 'b');
    });

    test('MCS-06 当前已移除 -> 取第一条', () {
      expect(nextActiveId(['a', 'b'], 'gone'), 'a');
    });

    test('MCS-07 空列表 -> null（不聚焦任何窗口）', () {
      expect(nextActiveId(const [], 'a'), isNull);
      expect(nextActiveId(const [], null), isNull);
    });
  });

  group('MCS 展示文案', () {
    test('MCS-08 每个 phase 都有非空文案', () {
      for (final p in MultiCallPhase.values) {
        expect(multiCallStatusText(p).isNotEmpty, isTrue,
            reason: '$p 缺少状态文案');
      }
    });

    test('MCS-09 failed 优先显示具体原因', () {
      expect(
        multiCallStatusText(MultiCallPhase.failed,
            failure: '端点离线，无法发起通话'),
        '端点离线，无法发起通话',
      );
      // 没给原因时也要有兜底文案，而不是空白。
      expect(multiCallStatusText(MultiCallPhase.failed).isNotEmpty, isTrue);
    });

    test('MCS-10 源码锁：状态文案必须是穷尽 switch 表达式（不得有兜底分支）', () {
      final src = File('lib/remote/multi_call_service.dart').readAsStringSync();
      final fn = src.substring(src.indexOf('String multiCallStatusText'));
      final body = fn.substring(0, fn.indexOf(';'));
      expect(body.contains('_ =>'), isFalse,
          reason: '`_ =>` 兜底会静默吃掉新增 phase（BUG-058 同形状）');
      expect(body.contains('default:'), isFalse);
      // 反向自检：抓不到东西说明锁本身失效了。
      expect(body.contains('MultiCallPhase.connecting'), isTrue);
    });
  });

  group('MCS 会话模型', () {
    test('MCS-11 一路会话自带 callId 与 peer（一路一条 PC 的前提）', () {
      final peer = PairedEndpoint(
        deviceId: 'd1',
        name: '客厅',
        secret: 's',
        pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final s = MultiCallSession(callId: 'c1', peer: peer);
      expect(s.callId, 'c1');
      expect(s.peer.deviceId, 'd1');
      expect(s.pc, isNull); // 未建连时不应持有 PC
      expect(s.phase, MultiCallPhase.connecting);
    });
  });
}
