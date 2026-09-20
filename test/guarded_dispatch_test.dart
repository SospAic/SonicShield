import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/guarded_dispatch.dart';

/// 命令处理异常兜底的回归锁（BUG-051）。
///
/// ## 缺陷形状
///
/// 端点处理入站命令的链路 `updates.listen → _handleRaw → 解密 → _dispatch`
/// 修复前**全程无异常捕获**。于是任何处理器抛异常（数据库锁、字段缺失、
/// 枚举不匹配……）都会：**不回执、不写审计** —— 控制器只能看到 20 秒超时。
///
/// 这是**静默降级**的典型：故障被转译成"没反应"，把"哪里错了"变成
/// "什么都看不出来"。本项目对此类缺陷的判据一贯是：
/// **失败必须留下痕迹，且要让对端知道失败**。
///
/// 实测触发场景：`tool/rc_probe.dart` 经真实公网 broker 发 `ping` 有回执、
/// 发 `status.get` 超时 —— 因为 `ping` 不碰数据库而 `status.get` 要查
/// `occurrences` 表（见 docs/17 §24）。
void main() {
  // ---------------- describeFailure ----------------

  group('describeFailure（给控制端的可读原因）', () {
    test('多行异常压成一行（换行会破坏日志与回执）', () {
      final s = describeFailure(Exception('boom\nat line 2\r\nat line 3'));
      expect(s.contains('\n'), isFalse);
      expect(s.contains('\r'), isFalse);
      expect(s, contains('boom'));
      expect(s, contains('at line 2'));
    });

    test('超长异常被截断（栈与本地路径不该回执给对端）', () {
      final long = 'x' * 500;
      final s = describeFailure(Exception(long), maxLen: 40);
      expect(s.length, lessThanOrEqualTo(41)); // 40 + 省略号
      expect(s.endsWith('…'), isTrue);
    });

    test('空消息兜底为运行时类型名（toString() 可能为空）', () {
      expect(describeFailure(_EmptyMessageError()), contains('_EmptyMessageError'));
    });

    test('默认上限 160：不截断则原样返回', () {
      final s = describeFailure(Exception('短消息'));
      expect(s, contains('短消息'));
      expect(s.endsWith('…'), isFalse);
    });
  });

  // ---------------- guardDispatch ----------------

  group('guardDispatch（永不外泄 + 失败必留痕）', () {
    test('成功：返回 ok，且不写审计', () async {
      var audits = 0;
      final r = await guardDispatch(
        () async {},
        audit: (_) async => audits++,
      );
      expect(r.ok, isTrue);
      expect(r.reason, isEmpty);
      expect(audits, 0, reason: '成功路径不该产生失败审计');
    });

    test('失败：返回 failed 且**一定**调用审计（核心：不静默）', () async {
      final audited = <String>[];
      final r = await guardDispatch(
        () async => throw StateError('occurrences 表不可用'),
        audit: (m) async => audited.add(m),
      );

      expect(r.ok, isFalse);
      expect(r.reason, contains('occurrences 表不可用'));
      expect(r.error, isA<StateError>());
      expect(audited, hasLength(1),
          reason: '处理器失败必须留下审计 —— 否则故障只表现为"控制器超时"');
      expect(audited.single, contains('occurrences 表不可用'));
    });

    test('失败异常**不外泄**（外泄会打断 MQTT 的 updates 监听）', () async {
      await expectLater(
        guardDispatch(
          () async => throw Exception('boom'),
          audit: (_) async {},
        ),
        completes,
        reason: 'guardDispatch 的契约是"永不抛"',
      );
    });

    test('审计自身失败：标记 auditOk=false 且仍不外泄', () async {
      final r = await guardDispatch(
        () async => throw Exception('业务失败'),
        audit: (_) async => throw Exception('数据库连审计都写不进去'),
      );

      expect(r.ok, isFalse);
      expect(r.auditOk, isFalse,
          reason: '"没写审计"与"审计失败"必须可区分 —— 后者是更严重的信号');
      expect(r.reason, contains('业务失败'));
    });

    test('成功路径 auditOk 恒为 true（不制造假警报）', () async {
      final r = await guardDispatch(() async {}, audit: (_) async {});
      expect(r.auditOk, isTrue);
    });

    test('reason 传给审计与传给控制端的完全一致（同一份真相）', () async {
      String? seen;
      final r = await guardDispatch(
        () async => throw ArgumentError('taskId 缺失'),
        audit: (m) async => seen = m,
      );
      expect(seen, isNotNull);
      expect(r.reason, seen,
          reason: '审计里记的原因与控制端收到的必须是同一条 —— 否则两边对不上账');
    });
  });

  // ---------------- 源码契约锁（接线不能被悄悄退回） ----------------

  group('接线锁（源码契约）', () {
    final endpoint = File('lib/remote/endpoint_service.dart').readAsStringSync();
    final assistHost = File('lib/remote/assist_host.dart').readAsStringSync();

    /// 去掉行注释后再断言。
    ///
    /// **为什么必须这么做**：`contains` 对"注释掉的代码"同样为真 ——
    /// 用 `// await _ack(...)` 把回执注释掉，锁会**照样通过**（本轮证伪时实测到）。
    /// 那是一种自欺的锁。已知局限：字符串字面量里的 `//`（如 URL）会被误当注释，
    /// 因此本函数只用于断言"某段代码是否存在"，不用于解析语义。
    String code(String src) => src
        .split('\n')
        .map((l) {
          final i = l.indexOf('//');
          return i < 0 ? l : l.substring(0, i);
        })
        .join('\n');

    test('配对遥控：_dispatch 被 guardDispatch 包住', () {
      expect(endpoint.contains('await guardDispatch('), isTrue,
          reason: 'endpoint_service 必须用 guardDispatch 包住 _dispatch —— '
              '退回裸调用即回到"处理器异常 = 静默超时"（BUG-051）');
      expect(code(endpoint).contains('() => _dispatch(msg, peer)'), isTrue,
          reason: '_dispatch 的调用必须作为 run 回调传入，而不是裸 await');
      expect(code(endpoint).contains('await _dispatch(msg, _peerOf(msg))'), isFalse,
          reason: '旧的裸调用形态不应残留');
    });

    test('配对遥控：失败路径必须同时"写审计 + 回执拒绝"', () {
      // 取 guardDispatch 调用点到 _broadcast 之间的片段
      final start = endpoint.indexOf('await guardDispatch(');
      expect(start, greaterThanOrEqualTo(0));
      final end = endpoint.indexOf('_broadcast(msg, peerId: msg.from', start);
      expect(end, greaterThan(start), reason: '找不到 guardDispatch 调用点之后的 _broadcast');
      final region = code(endpoint.substring(start, end));

      expect(region.contains("status: 'failed'"), isTrue,
          reason: '失败必须写审计（status=failed）');
      expect(region.contains('处理器异常'), isTrue,
          reason: '审计与回执都要带上可读原因');
      expect(region.contains('await _ack(msg, false'), isTrue,
          reason: '失败必须显式回执 —— 只写审计的话控制器仍然只能看到超时');
    });

    test('配对遥控：MQTT 入站回调有最后一道防线（try/catch）', () {
      final start = endpoint.indexOf('client.updates!.listen(');
      expect(start, greaterThanOrEqualTo(0), reason: '找不到 MQTT 入站监听');
      final end = endpoint.indexOf('await _handleRaw(topic, text);', start);
      expect(end, greaterThan(start), reason: '找不到 _handleRaw 调用点');
      final region = code(endpoint.substring(start, end));
      expect(region.contains('try {'), isTrue,
          reason: '入站回调必须捕获异常 —— 漏出去只会变成无人看见的异步错误');
    });

    test('协助会话：onCommand 调用同样被 guardDispatch 包住', () {
      final start = assistHost.indexOf('final handler = onCommand;');
      expect(start, greaterThanOrEqualTo(0), reason: '找不到 onCommand 调用点');
      final region = code(assistHost.substring(start));
      expect(region.contains('await guardDispatch('), isTrue,
          reason: '协助会话与配对遥控同源，必须同样兜底');
      expect(region.contains('runZoned(() => handler(msg)'), isTrue,
          reason: 'runZoned 不能丢 —— 丢了回执会走错主题（assistReplyZone）');
      expect(region.contains('assistReplyZone: true'), isTrue,
          reason: 'assistReplyZone 标记不能丢 —— 协助会话的回执必须原路返回会合主题');
      expect(region.contains('await _publish('), isTrue,
          reason: '协助会话失败时必须显式回执拒绝（与配对遥控同判据）');
    });
  });
}

/// 一个 `toString()` 返回空串的异常，用于验证兜底。
class _EmptyMessageError implements Exception {
  @override
  String toString() => '';
}
