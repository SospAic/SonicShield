import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/protocol.dart';

/// 远程消息密钥契约（BUG-013 / BUG-021 回归）。
///
/// 密钥模型是**按接收方身份派生**的：
/// - 发送方用「接收方 deviceId + 接收方配对码」加密；
/// - 接收方用自己的配对码 + 自己的 deviceId 解密。
///
/// 这条契约此前没有测试覆盖，导致端点的收命令路径错误地遍历对端列表
/// 派生密钥（与发送方参数永不相等），命令从未被成功解密；
/// 控制器也从未订阅对端 evt 主题，回执与通话信令全部不可达。
void main() {
  // 两台设备各自的持久身份（配对码即共享秘密，扫码时交给对端）。
  const aId = 'aaaaaaaaaaaaaaaa';
  const aCode = 'AB2CD5EF';
  const bId = 'bbbbbbbbbbbbbbbb';
  const bCode = 'ZY9XW8VU';

  const cmdTopic = 'sonicshield/v1/$bId/cmd';
  const evtTopic = 'sonicshield/v1/$bId/evt';

  group('密钥派生契约（按接收方身份）', () {
    test('cmd：A 加密 → B 用自身身份解密成功', () async {
      // 控制器 A 侧：用目标端点 B 的配对码 + B 的 deviceId。
      final txKey = await RcCodec.deriveKey(bCode, '$bId|cmd');
      final wire = await RcCodec.encode(
          RcMessage.now(RcCmd.ping, const {'n': 1}), txKey, cmdTopic);

      // 端点 B 侧：用自己的配对码 + 自己的 deviceId（修复后的实现）。
      final rxKey = await RcCodec.deriveKey(bCode, '$bId|cmd');
      final msg = await RcCodec.decode(wire, rxKey, cmdTopic);

      expect(msg, isNotNull, reason: 'B 必须能解出自己的 cmd');
      expect(msg!.type, RcCmd.ping);
      expect(msg.payload['n'], 1);
    });

    test('cmd：旧实现（遍历对端密钥）必须解密失败', () async {
      final txKey = await RcCodec.deriveKey(bCode, '$bId|cmd');
      final wire =
          await RcCodec.encode(RcMessage.now(RcCmd.ping), txKey, cmdTopic);

      // B 侧曾用「对端 A 的配对码 + A 的 deviceId」尝试解密 → 永不匹配。
      final staleKey = await RcCodec.deriveKey(aCode, '$aId|cmd');
      expect(await RcCodec.decode(wire, staleKey, cmdTopic), isNull,
          reason: '这条断言锁定 BUG-021 不会回归');
    });

    test('evt：B 加密回执 → A 用自身身份解密成功', () async {
      // 端点 B 侧：用控制器 A 的配对码 + A 的 deviceId。
      final txKey = await RcCodec.deriveKey(aCode, '$aId|evt');
      final wire = await RcCodec.encode(
          RcMessage.now(RcEvt.pong, const {'at': 42}), txKey, evtTopic);

      // 控制器 A 侧：用自己的配对码 + 自己的 deviceId。
      final rxKey = await RcCodec.deriveKey(aCode, '$aId|evt');
      final msg = await RcCodec.decode(wire, rxKey, evtTopic);

      expect(msg, isNotNull, reason: 'A 必须能解出 B 广播给自己的回执');
      expect(msg!.type, RcEvt.pong);
    });

    test('通话信令 call.answer 走同一 evt 契约', () async {
      final txKey = await RcCodec.deriveKey(aCode, '$aId|evt');
      final wire = await RcCodec.encode(
          RcMessage.now(RcCmd.callAnswer,
              const {'callId': 'c1', 'sdp': 'v=0', 'type': 'answer'}),
          txKey,
          evtTopic);
      final rxKey = await RcCodec.deriveKey(aCode, '$aId|evt');
      final msg = await RcCodec.decode(wire, rxKey, evtTopic);
      expect(msg?.type, RcCmd.callAnswer);
      expect(msg?.payload['callId'], 'c1');
    });

    test('方向隔离：cmd 密钥无法解 evt 密文（密钥方向独立）', () async {
      final evtKey = await RcCodec.deriveKey(aCode, '$aId|evt');
      final wire =
          await RcCodec.encode(RcMessage.now(RcEvt.status), evtKey, evtTopic);
      final cmdKey = await RcCodec.deriveKey(aCode, '$aId|cmd');
      expect(await RcCodec.decode(wire, cmdKey, evtTopic), isNull);
    });

    test('配对码不符 → 解密失败（未配对设备无法注入命令）', () async {
      final txKey = await RcCodec.deriveKey(bCode, '$bId|cmd');
      final wire =
          await RcCodec.encode(RcMessage.now(RcCmd.scriptRun), txKey, cmdTopic);
      final attacker = await RcCodec.deriveKey('HACKER22', '$bId|cmd');
      expect(await RcCodec.decode(wire, attacker, cmdTopic), isNull);
    });
  });

  group('信封与重放防护', () {
    test('from 字段参与序列化（发送方标识用于回执渲染）', () {
      const msg = RcMessage(id: 'x1', ts: 1, type: RcCmd.ping, from: aId);
      final back = RcMessage.tryParse(msg.toJson());
      expect(back?.from, aId);
    });

    test('超出 ±90s 时间窗 → 拒绝', () async {
      final key = await RcCodec.deriveKey(bCode, '$bId|cmd');
      final stale = RcMessage(
        id: 'old',
        ts: DateTime.now().millisecondsSinceEpoch - 120000,
        type: RcCmd.ping,
      );
      final wire = await RcCodec.encode(stale, key, cmdTopic);
      expect(await RcCodec.decode(wire, key, cmdTopic), isNull);
    });

    test('重复消息 ID → 第二次被去重丢弃', () async {
      final key = await RcCodec.deriveKey(bCode, '$bId|cmd');
      final wire =
          await RcCodec.encode(RcMessage.now(RcCmd.ping), key, cmdTopic);
      final seen = <String, int>{};
      final first = await RcCodec.decode(wire, key, cmdTopic, seenIds: seen);
      expect(first, isNotNull);
      seen[first!.id] = DateTime.now().millisecondsSinceEpoch;
      final second = await RcCodec.decode(wire, key, cmdTopic, seenIds: seen);
      expect(second, isNull, reason: '窗口内重放必须被丢弃');
    });

    test('AAD 绑定主题：换主题解密失败', () async {
      final key = await RcCodec.deriveKey(bCode, '$bId|cmd');
      final wire =
          await RcCodec.encode(RcMessage.now(RcCmd.ping), key, cmdTopic);
      expect(
          await RcCodec.decode(wire, key, 'sonicshield/v1/$bId/evt'), isNull);
    });
  });

  group('P1-17 reserveInboundId：查重+预占的原子登记', () {
    test('首次 true / 重复 false，且首次留下预占时间戳', () {
      final seen = <String, int>{};
      expect(RcCodec.reserveInboundId(seen, 'id-1', 1000), isTrue);
      expect(RcCodec.reserveInboundId(seen, 'id-1', 1001), isFalse,
          reason: '★ 第二次必须 false —— 证明"查重"不是恒 true；'
              '若有人把它改回只读查重（不预占），并发重投会双通过');
      expect(seen['id-1'], 1000, reason: '首次必须预占时间戳，供后续窗口剪枝');
    });

    test('窗口外条目被剪枝，不无限增长', () {
      final seen = <String, int>{};
      expect(RcCodec.reserveInboundId(seen, 'old', 0, windowMs: 100), isTrue);
      expect(RcCodec.reserveInboundId(seen, 'new', 500, windowMs: 100), isTrue);
      expect(seen.containsKey('old'), isFalse,
          reason: '超窗条目必须被剪掉，否则长时间运行内存持续涨');
      expect(seen['new'], 500);
    });

    test('空 ID 恒放行且不污染去重表（协议入口另有 P2-26 拒绝）', () {
      final seen = <String, int>{};
      expect(RcCodec.reserveInboundId(seen, '', 1), isTrue);
      expect(RcCodec.reserveInboundId(seen, '', 2), isTrue);
      expect(seen, isEmpty, reason: '空串不得进入去重表，否则会把"无 ID 报文"当成同一条');
    });
  });

  group('P2-26 协议入口拒绝空 ID（fail closed）', () {
    test('tryParse 对缺失 ID / 空串 ID 都返回 null', () {
      expect(
          RcMessage.tryParse(
              const {'v': 1, 'ts': 1, 'type': RcCmd.ping, 'payload': <String, dynamic>{}}),
          isNull,
          reason: '缺失 ID 的报文不得被解析成 id="" 放进业务链路');
      expect(
          RcMessage.tryParse(const {
            'v': 1,
            'id': '',
            'ts': 1,
            'type': RcCmd.ping,
            'payload': <String, dynamic>{}
          }),
          isNull,
          reason: '空串 ID 同样 fail closed');
      // 反面对照：合法非空 ID 必须照常解析（证明上面不是"恒返回 null"）。
      final ok = RcMessage.tryParse(const {
        'v': 1,
        'id': 'abc123',
        'ts': 1,
        'type': RcCmd.ping,
        'payload': <String, dynamic>{}
      });
      expect(ok, isNotNull);
      expect(ok!.id, 'abc123');
    });

    test('encode 空 ID 后 decode 必失败；重复投递两次均 fail closed', () async {
      final key = await RcCodec.deriveKey(bCode, '$bId|cmd');
      final wire = await RcCodec.encode(
          RcMessage(
              id: '',
              ts: DateTime.now().millisecondsSinceEpoch,
              type: RcCmd.scriptRun),
          key,
          cmdTopic);

      expect(await RcCodec.decode(wire, key, cmdTopic), isNull,
          reason: '空 ID 报文必须被协议入口拒绝，绝不进入业务链路');
      expect(await RcCodec.decode(wire, key, cmdTopic), isNull,
          reason: '★ 重投同一条空 ID 报文仍 fail closed —— 不走"不查重"的旁路');
    });
  });
}
