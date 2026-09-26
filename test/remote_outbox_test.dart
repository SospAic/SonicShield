import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/source_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RemoteStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = RemoteStore(await SharedPreferences.getInstance());
  });

  group('outbox 存储：只读读取 + 成功后删', () {
    test('OB-01 outboxFor 只读：读完 outbox 一条不少（不许"取走即删"）', () async {
      await store.enqueue('w1', 'dev-a');
      await store.enqueue('w2', 'dev-a');

      final mine = store.outboxFor('dev-a');

      expect(mine.map((m) => m['wire']), ['w1', 'w2']);
      expect(store.outbox(), hasLength(2),
          reason: '只读读取绝不能改动存储 —— 否则补发失败即丢命令');
      expect(store.outboxFor('dev-a'), hasLength(2), reason: '可重复读');
    });

    test('OB-02 removeOutbox 只删"已成功"的那条，其余原样保留', () async {
      await store.enqueue('w1', 'dev-a');
      await store.enqueue('w2', 'dev-a');
      await store.enqueue('w3', 'dev-a');

      final sent = store.outboxFor('dev-a').take(2).toList();
      await store.removeOutbox('dev-a', sent);

      expect(store.outboxFor('dev-a').map((m) => m['wire']), ['w3'],
          reason: '没发出去的那条必须还在（否则 flush 中途失败就永久丢）');
    });

    test('OB-03 removeOutbox 不碰其它端点的条目', () async {
      await store.enqueue('a1', 'dev-a');
      await store.enqueue('b1', 'dev-b');

      await store.removeOutbox('dev-a', store.outboxFor('dev-a'));

      expect(store.outboxFor('dev-a'), isEmpty);
      expect(store.outboxFor('dev-b').map((m) => m['wire']), ['b1']);
    });

    test('OB-04 同 wire 同毫秒的两条命令仍是独立条目（删一条不能连带删另一条）', () async {
      // 连发同一条命令：`at` 很可能相同，只有 `id` 能区分。
      await store.enqueue('same', 'dev-a');
      await store.enqueue('same', 'dev-a');

      final list = store.outboxFor('dev-a');
      expect(list, hasLength(2));
      expect(outboxKeyOf(list[0]), isNot(outboxKeyOf(list[1])),
          reason: 'key 碰撞会让 removeOutbox 一次删两条 —— '
              '把"还没发出去的那条"也抹掉，正是要杜绝的丢命令');

      await store.removeOutbox('dev-a', [list.first]);
      expect(store.outboxFor('dev-a'), hasLength(1),
          reason: '只应删掉成功的那条');
    });

    test('OB-05 removeOutbox 传空列表 → 什么都不删', () async {
      await store.enqueue('w1', 'dev-a');
      await store.removeOutbox('dev-a', const []);
      expect(store.outboxFor('dev-a'), hasLength(1));
    });

    test('OB-06 老数据没有 id → 退回 at|wire，仍能定位到那一条', () async {
      // 模拟升级前落盘的条目（enqueue 当时还没写 id）。
      SharedPreferences.setMockInitialValues({
        'rc_outbox': '[{"endpointId":"dev-a","wire":"legacy","at":111}]',
      });
      final legacy = RemoteStore(await SharedPreferences.getInstance());

      expect(legacy.outboxFor('dev-a'), hasLength(1));
      expect(outboxKeyOf(legacy.outboxFor('dev-a').first), '111|legacy');

      await legacy.removeOutbox('dev-a', legacy.outboxFor('dev-a'));
      expect(legacy.outboxFor('dev-a'), isEmpty);
    });
  });

  group('prepareOutboxReplay：重放必须重盖时间戳与 ID', () {
    const topic = 'sonicshield/v1/dev-a/cmd';

    Future<List<int>> keyFor() =>
        RcCodec.deriveKey('sec-a', 'dev-a|cmd');

    test('RP-01 两小时前的暂存命令：原样重发会被接收端丢弃，重放后必须能收下', () async {
      final key = await keyFor();
      final stale = RcMessage(
        id: 'old-id',
        ts: DateTime.now()
            .subtract(const Duration(hours: 2))
            .millisecondsSinceEpoch,
        type: RcCmd.soundPlay,
        payload: const {'assetId': 'a-7'},
        from: 'ctrl',
      );
      final wire = await RcCodec.encode(stale, key, topic);

      // 前提：原样重发**确实**会被 ±90s 时间窗丢掉（这就是必须重盖的原因）。
      expect(await RcCodec.decode(wire, key, topic), isNull,
          reason: '若这里不是 null，说明时间窗没生效，本锁的前提需要重审');

      final replayed = await prepareOutboxReplay(wire, key, topic);
      expect(replayed, isNotNull, reason: '解密必须忽略时间窗（要的是"当年那条命令"）');

      final got = await RcCodec.decode(replayed!, key, topic);
      expect(got, isNotNull, reason: '重放后的信封必须能被当前时间窗接收');
      expect(got!.type, RcCmd.soundPlay);
      expect(got.payload['assetId'], 'a-7', reason: '业务内容必须原样保留');
      expect(got.id, isNot('old-id'),
          reason: 'ID 必须换新：沿用旧 ID 会被接收端按"重放"去重丢掉');
    });

    test('RP-02 密钥不符 → null（调用方据此丢弃，避免永久卡住队列）', () async {
      final key = await keyFor();
      final wire = await RcCodec.encode(
          RcMessage.now(RcCmd.ping), key, topic);

      final otherKey = await RcCodec.deriveKey('sec-other', 'dev-a|cmd');
      expect(await prepareOutboxReplay(wire, otherKey, topic), isNull);
    });

    test('RP-03 密文损坏 → null（不抛）', () async {
      final key = await keyFor();
      expect(await prepareOutboxReplay('not-a-wire', key, topic), isNull);
    });
  });

  group('补发接线锁（源码契约）', () {
    final src = File('lib/remote/endpoint_service.dart').readAsStringSync();

    test('OB-W1 flushOutbox 用只读读取 + 成功后删，且不再用 drainOutbox', () {
      final body = methodBody(src, 'Future<int> flushOutbox(');

      expect(body, contains('store.outboxFor('),
          reason: '必须只读读取；drainOutbox 取走即删，补发失败即丢命令');
      expect(body, contains('store.removeOutbox('),
          reason: '成功后才删');
      expect(body, contains('prepareOutboxReplay('),
          reason: '必须重盖时间戳/ID，否则超窗的命令补发也会被丢');
      expect(body, isNot(contains('drainOutbox')),
          reason: 'P0-3 的旧形状：取走即删');
    });

    test('OB-W2 存在 flushAllOutbox 并遍历 store.paired()', () {
      final body = methodBody(src, 'Future<int> flushAllOutbox(');
      expect(body, contains('store.paired()'));
      expect(body, contains('flushOutbox('));
    });

    test('OB-W3 连接建立 / 首连 / 心跳三处都接线了补发', () {
      final connect = methodBody(src, 'Future<void> _connect()');
      final hits = 'flushAllOutbox(store)'.allMatches(connect).length;
      expect(hits, greaterThanOrEqualTo(3),
          reason: 'onConnected（重连）+ connect 后（首连）+ 心跳（瞬时失败重试）'
              '缺任何一处，某些上线路径就不会补发');
      expect(connect, contains('onConnected'));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // OB-C · 暂存内容必须是**密文**（第三十四轮发现的真实缺陷）
  // ══════════════════════════════════════════════════════════════════
  //
  // 缺陷形状（"两半分别写、从未合拢"）：
  //   · 入队侧 `sendTo` 存的是 `jsonEncode(out.toJson())` —— **明文 JSON**；
  //   · 出队侧 `flushOutbox` 走 `prepareOutboxReplay` → `RcCodec.decode`
  //     —— 要的是**密文**。
  //
  // 后果两条：
  //   1. **离线补发整条死掉**：每条暂存命令都解不开，被当成"密钥已变更"丢弃；
  //      UI 上却还写着"端点上线后自动执行"，审计还把人引向错误结论。
  //   2. **机密性回退**：被操控端下发的全部命令明文躺在 SharedPreferences 里，
  //      拿得到设备的人**不需要任何密钥**就能读出来 —— 与"端到端加密"的
  //      承诺不符（E2E 保护的是传输与 broker，不保护这种自己写出来的明文副本）。
  //
  // 下面的断言是**行为测试**（不是源码文本锁）：`sendTo` 在未连接时只依赖
  // 传入的 store，不需要 `_client`/`_db`，因此宿主机可直跑；并且用真实
  // 密钥把暂存内容解回来 —— 旧实现在这里必然返回 null。
  group('OB-C 暂存内容必须是密文（可被补发路径解开）', () {
    final endpoint = PairedEndpoint(
      deviceId: 'e' * 16,
      name: '端点',
      secret: 'SECRET8C',
      pairedAt: DateTime(2026, 9, 24),
    );

    String topicOf() => 'sonicshield/v1/${endpoint.deviceId}/cmd';

    test('OB-C1 ★ 暂存的是密文（明文 JSON 会带 "type" 字样）', () async {
      await store.setIdentity('c' * 16, '控制器');
      final ok = await RcEndpointService.instance
          .sendTo(endpoint, RcMessage.now(RcCmd.ping, {}), store);
      expect(ok, isFalse, reason: '前提：未连接 ⇒ 走暂存分支并返回 false');

      final stored = store.outboxFor(endpoint.deviceId);
      expect(stored, hasLength(1), reason: '命令应在 outbox 里等着补发');
      final wire = stored.first['wire'] as String;

      expect(wire.contains('"type"'), isFalse,
          reason: '★ 明文 JSON 必然出现 "type" 键。出现即说明这条路又回退成明文暂存');
      expect(wire.contains(RcCmd.ping), isFalse,
          reason: '★ 命令类型都不该明文可见 —— 那等于把"被操控端下发了什么"摊开给人看');
    });

    test('OB-C2 ★ 暂存内容能被补发路径解开（旧实现在此返回 null）', () async {
      await store.setIdentity('c' * 16, '控制器');
      await RcEndpointService.instance
          .sendTo(endpoint, RcMessage.now(RcCmd.statusGet, {}), store);

      final wire = store.outboxFor(endpoint.deviceId).first['wire'] as String;
      final key =
          await RcCodec.deriveKey(endpoint.secret, '${endpoint.deviceId}|cmd');

      final reEnc = await prepareOutboxReplay(wire, key, topicOf());
      expect(reEnc, isNotNull,
          reason: '★ 这一条就是旧实现的红灯：入队存明文、出队要密文，'
              '`prepareOutboxReplay` 永远返回 null ⇒ 每条暂存命令都被当成'
              '"密钥已变更"丢弃（离线补发功能整条死掉）');

      final decoded = await RcCodec.decode(reEnc!, key, topicOf());
      expect(decoded, isNotNull, reason: '重放后必须仍是合法信封');
      expect(decoded!.type, RcCmd.statusGet,
          reason: '补发的必须是**原来那条**命令，而不是别的东西');
    });

    test('OB-C3 入队与在线发送用同一段 topic/key（不许各自算一份）', () {
      final src = File('lib/remote/endpoint_service.dart').readAsStringSync();
      // ⚠️ 不能直接用 `methodBody(src, 'Future<bool> sendTo(')`：
      // 该签名带具名参数表 `{bool enqueueOnFail = true}`，取「签名后第一个 `{`」
      // 会命中**参数表**那对括号 ⇒ 截取出来的是 `{bool enqueueOnFail = true}`，
      // 断言会在"前提"上假红。这里改以 `) async {` 为锚点再做大括号配对。
      final sigAt = src.indexOf('Future<bool> sendTo(');
      expect(sigAt, greaterThanOrEqualTo(0), reason: '前提：sendTo 必须存在');
      final anchor = src.indexOf(') async {', sigAt);
      expect(anchor, greaterThan(sigAt), reason: '前提：sendTo 必须是 async 方法');
      final open = src.indexOf('{', anchor);
      var depth = 0;
      var end = -1;
      for (var i = open; i < src.length; i++) {
        final c = src[i];
        if (c == '{') depth++;
        if (c == '}') {
          depth--;
          if (depth == 0) {
            end = i;
            break;
          }
        }
      }
      expect(end, greaterThan(open), reason: '前提：方法体大括号必须配对');
      final body = src.substring(open, end + 1);

      final topicAt = body.indexOf('sonicshield/v1/\${endpoint.deviceId}/cmd');
      final offlineAt = body.indexOf('MqttConnectionState.connected');
      expect(topicAt, greaterThanOrEqualTo(0));
      expect(offlineAt, greaterThanOrEqualTo(0));
      expect(topicAt, lessThan(offlineAt),
          reason: '★ topic/key 必须在未连接分支之前算好并被两条路共用；'
              '否则就是"两半各写一份"，正是本缺陷的成因');
      expect('RcCodec.encode('.allMatches(body).length, greaterThanOrEqualTo(2),
          reason: '在线路径与暂存路径都要走 encode');
      expect(body, isNot(contains('jsonEncode(out.toJson())')),
          reason: '★ 明文暂存的旧写法必须彻底消失');
    });
  });
}
