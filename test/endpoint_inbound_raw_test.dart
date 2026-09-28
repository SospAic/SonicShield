import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 第四十七轮：**入站原始报文链路**（`_handleRaw → _handlePeerEvent`）的宿主行为锁。
///
/// ## 为什么需要这一份
///
/// `_handleRaw` 的生产**唯一**入口是 `_connect()` 里真实 MQTT `client.updates`
/// 监听器。宿主机连不上 broker ⇒ 这条链路此前**一行都没被执行过**：主题命名空间
/// 路由、cmd 多盐候选试解、准入裁决、限流窗口与停类插队、`guardDispatch` 兜底、
/// 收尾广播、evt 明文离线哨兵 …… 全靠 `test/endpoint_decode_fail_test.dart`、
/// `test/unpair_revoke_test.dart`、`test/q10_endpoint_test.dart` 这类**源码文本锁**
/// 兜底。第四十四轮立的判据第五代说得直白：
/// **「源码锁是绿的」≠「那条业务路径被执行过」**。
///
/// 本文件用本轮新增的两个接缝（`debugSetOwnCode` + `debugHandleRaw`，
/// 见 `lib/remote/endpoint_service.dart` 顶部）把**真密文**喂进去，断言的是
/// **可观测副作用**（审计行 / 事件流 / 盐落盘），不是"没抛异常"。
///
/// ⚠️ 全部走**真** `RcCodec`（真 HKDF / AES-GCM）：密钥错了就必须解不开，
/// 不接受"打个桩让 decode 恒成功"的假绿。
///
/// ⚠️ 端点服务是**单例**，`_seen` / `_cmdTs` / `_decodeFail` / `_rejectFlood`
/// 在文件内跨用例存活 ⇒ 每个用例用**自己的**发送方 deviceId / 主题，
/// 避免互相污染（这也是"限流用例不会污染其它用例"的前提）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const ownId = 'EPX0001abcdef12';
  const ctrlId = 'CTRL0001abcdef';

  final svc = RcEndpointService.instance;

  late SharedPreferences prefs;
  late RemoteStore store;
  late KdfSaltStore salts;
  late AppDatabase db;
  late PairedEndpoint peer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    await store.setIdentity(ownId, '端点机');
    await store.ensurePairingCode();
    salts = KdfSaltStore(prefs);
    db = await AppDatabase.open(inMemoryDatabasePath);
    peer = PairedEndpoint(
      deviceId: ctrlId,
      name: '控制端A',
      secret: 'CODE0001',
      pairedAt: DateTime(2024, 1, 1),
    );
    await store.addPaired(peer);
    svc.debugBind(store: store, db: db, saltStore: salts);
    svc.debugSetOwnCode(store.pairingCode);
  });

  tearDown(() async {
    svc.debugSendTo = null;
    svc.debugSetOwnCode('');
    await db.close();
  });

  String cmdTopic() => 'sonicshield/v1/$ownId/cmd';
  String evtTopic(String peerId) => 'sonicshield/v1/$peerId/evt';

  /// 造一条"从 [from] 发来"的命令信封（`RcMessage.now` 是随机的 ⇒ 天然去重安全）。
  RcMessage inbound(String type,
      {Map<String, dynamic> payload = const {}, String from = ctrlId}) {
    final n = RcMessage.now(type, payload);
    return RcMessage(
        id: n.id, ts: n.ts, type: n.type, payload: n.payload, from: from);
  }

  /// cmd 方向：控制端用「端点配对码 + 端点ID|cmd」加密（密钥模型见 `_handleRaw` 文档）。
  Future<String> sealCmd(RcMessage msg, {List<int>? salt}) async {
    final key =
        await RcCodec.deriveKey(store.pairingCode, '$ownId|cmd', salt: salt);
    return RcCodec.encode(msg, key, cmdTopic());
  }

  /// evt 方向：对端把回执发到 `{端点ID}/evt` 时用的是同一个「端点ID|evt」上下文。
  Future<String> sealEvt(RcMessage msg, String peerId, {List<int>? salt}) async {
    final key =
        await RcCodec.deriveKey(store.pairingCode, '$ownId|evt', salt: salt);
    return RcCodec.encode(msg, key, evtTopic(peerId));
  }

  /// 包住一次入站驱动，收集它同步/异步广播出来的事件信封。
  Future<List<Map<String, dynamic>>> collect(
      Future<void> Function() body) async {
    final seen = <Map<String, dynamic>>[];
    final sub = svc.events.listen(seen.add);
    try {
      await body();
      await Future<void>.delayed(Duration.zero);
    } finally {
      await sub.cancel();
    }
    return seen;
  }

  Future<List<Map<String, Object?>>> logs() => LogRepository(db).recent(limit: 500);

  Future<int> countLogs(
      {String? action, String? status, String? contains}) async {
    final rows = await logs();
    return rows.where((r) {
      if (action != null && r['action'] != action) return false;
      if (status != null && r['status'] != status) return false;
      if (contains != null &&
          !(r['message'] as String? ?? '').contains(contains)) {
        return false;
      }
      return true;
    }).length;
  }

  // ═══════════════════════════════════════════════ A · cmd 主题（命令方向）

  group('IR-A cmd 主题：解密 → 准入 → 限流 → 执行 → 广播', () {
    test('IR-01 合法密文 ⇒ 处理器真的跑了，且收尾按发送方广播（含反查到的名字）',
        () async {
      final seen = await collect(() async {
        await svc.debugHandleRaw(cmdTopic(), await sealCmd(inbound(RcCmd.ping)));
      });
      // 兜底回执：宿主机没有 MQTT 客户端 ⇒ `_send` 必须**留痕**而不是静默丢。
      // ⚠️ 审计 Action 取的是**出站那条消息**的类型（`rc.pong`），不是入站命令的
      // 类型（`ping`）—— `_auditSendDrop` 描述的是"哪条回执没发出去"。
      expect(
          await countLogs(
              action: RcEvt.pong, status: 'skipped', contains: '出站消息未发出'),
          1,
          reason: '回执发不出去必须写审计 —— 静默丢就是"命令执行了但控制端毫无反应"');
      expect(seen, hasLength(1));
      expect(seen.single['type'], RcCmd.ping);
      expect(seen.single['peerId'], ctrlId);
      expect(seen.single['peerName'], '控制端A',
          reason: 'peerName 必须由配对表**反查**出来，不是把 deviceId 原样回填');
    });

    test('IR-02 配对码不符 ⇒ 不再静默：写 decode.fail，且同主题 10s 内只写一条',
        () async {
      final bad = await RcCodec.deriveKey('WRONGCODE', '$ownId|cmd');
      final wire = await RcCodec.encode(inbound(RcCmd.ping), bad, cmdTopic());
      final seen = await collect(() async {
        await svc.debugHandleRaw(cmdTopic(), wire);
        await svc.debugHandleRaw(cmdTopic(), wire);
      });
      expect(seen, isEmpty, reason: '解不开就绝不能进入执行/广播');
      expect(await countLogs(action: 'decode.fail', status: 'failed'), 1,
          reason: '第二次必须被限频器吃掉 —— 错码命令会被 outbox 反复补发，'
              '不限频会把真正需要被看见的那条淹掉');
    });

    test('IR-03 发送方不在配对表 ⇒ 拒绝执行 + 留痕（撤销的"另一半"）', () async {
      const ghost = 'GHOST001abcdef12';
      final seen = await collect(() async {
        await svc.debugHandleRaw(cmdTopic(),
            await sealCmd(inbound(RcCmd.ping, from: ghost)));
      });
      expect(seen, isEmpty, reason: '★ 拒绝必须发生在 _dispatch **之前**');
      expect(
          await countLogs(
              action: RcCmd.ping,
              status: 'rejected',
              contains: '授权已撤销'),
          1);
      // 反例对照：同一主题、同一密文形态，只是发送方在表里 ⇒ 必须放行。
      final ok = await collect(() async {
        await svc.debugHandleRaw(cmdTopic(), await sealCmd(inbound(RcCmd.ping)));
      });
      expect(ok, hasLength(1), reason: '差别只能在"发送方在不在配对表"，不可是别的');
    });

    test('IR-04 滑窗限流：第 31 条被拒（30/60s），审计与回执都指出"限流"', () async {
      const busy = 'CTRL0002abcdef';
      await store.addPaired(PairedEndpoint(
        deviceId: busy,
        name: '控制端B',
        secret: 'CODE0002',
        pairedAt: DateTime(2024, 1, 1),
      ));
      for (var i = 0; i < 30; i++) {
        await svc.debugHandleRaw(cmdTopic(),
            await sealCmd(inbound(RcCmd.ping, from: busy)));
      }
      final seen = await collect(() async {
        await svc.debugHandleRaw(cmdTopic(),
            await sealCmd(inbound(RcCmd.ping, from: busy)));
      });
      expect(seen, isEmpty, reason: '被限流的命令不得落到 _dispatch');
      expect(await countLogs(action: RcCmd.ping, status: 'skipped', contains: '限流'),
          1);
    });

    test('IR-05 停类命令插队：窗口已满，"叫停"仍然进得去', () async {
      const busy = 'CTRL0003abcdef';
      await store.addPaired(PairedEndpoint(
        deviceId: busy,
        name: '控制端C',
        secret: 'CODE0003',
        pairedAt: DateTime(2024, 1, 1),
      ));
      for (var i = 0; i < 30; i++) {
        await svc.debugHandleRaw(cmdTopic(),
            await sealCmd(inbound(RcCmd.ping, from: busy)));
      }
      await svc.debugHandleRaw(cmdTopic(),
          await sealCmd(inbound(RcCmd.scriptStop, from: busy)));
      expect(await countLogs(action: RcCmd.scriptStop, status: 'success'), 1,
          reason: '停类必须先于限流放行 —— 否则窗口被刷满时连"叫停"都发不进来');
      expect(
          await countLogs(action: RcCmd.scriptStop, contains: '限流'), 0,
          reason: '叫停不得被限流拦下');
    });

    test('IR-06 多盐候选：对端存过盐 ⇒ 用盐加密的命令解得开', () async {
      final salt = KdfSaltStore.newSalt();
      await salts.saveSalt(ctrlId, salt);
      final seen = await collect(() async {
        await svc.debugHandleRaw(
            cmdTopic(), await sealCmd(inbound(RcCmd.ping), salt: salt));
      });
      expect(seen, hasLength(1),
          reason: 'null 候选先试、失败后必须**继续**试该对端的存盐，'
              '否则升级到 v2 之后两端静默失联');
    });

    test('IR-07 本机 deviceId 或配对码为空 ⇒ 直接返回（不抛、不落任何痕迹）',
        () async {
      final wire = await sealCmd(inbound(RcCmd.ping));
      await store.setIdentity('', '端点机');
      await svc.debugHandleRaw(cmdTopic(), wire);
      await store.setIdentity(ownId, '端点机');
      svc.debugSetOwnCode('');
      await svc.debugHandleRaw(cmdTopic(), wire);
      expect(await countLogs(action: RcCmd.ping), 0);
    });
  });

  // ═══════════════════════════════════════════════ B · evt 主题（回执方向）

  group('IR-B evt 主题：只解密转发，不执行', () {
    test('IR-08 合法密文 ⇒ 事件流拿到 rc.ack，peerId/peerName 都对', () async {
      final ack = inbound(RcEvt.ack,
          payload: {'ok': true, 'for': 'cmd-1'}, from: ctrlId);
      final seen = await collect(() async {
        await svc.debugHandleRaw(evtTopic(ctrlId), await sealEvt(ack, ctrlId));
      });
      expect(seen, hasLength(1));
      expect(seen.single['type'], RcEvt.ack);
      expect(seen.single['peerId'], ctrlId);
      expect(seen.single['peerName'], '控制端A');
      expect(rcPayloadOf(seen.single)['for'], 'cmd-1');
    });

    test('IR-09 LWT 离线哨兵是**明文**，必须被单独识别出来（且不必能解密）',
        () async {
      final wire =
          jsonEncode({'type': RcEvt.offline, 'deviceId': ctrlId});
      final seen = await collect(() async {
        await svc.debugHandleRaw(evtTopic(ctrlId), wire);
      });
      expect(seen, hasLength(1));
      expect(seen.single['type'], RcEvt.offline);
      expect(seen.single['peerName'], '控制端A');
      expect(await countLogs(action: 'decode.fail'), 0,
          reason: '离线哨兵不是"解密失败"，不得记成错码噪声');
    });

    test('IR-10 解不开 ⇒ 静默返回（evt 主题**刻意不审计**）', () async {
      final bad = await RcCodec.deriveKey('WRONGCODE', '$ownId|evt');
      final wire = await RcCodec.encode(inbound(RcEvt.ack), bad, evtTopic(ctrlId));
      final seen = await collect(() async {
        await svc.debugHandleRaw(evtTopic(ctrlId), wire);
      });
      expect(seen, isEmpty);
      expect(await countLogs(action: 'decode.fail'), 0,
          reason: '广播型事件"每个已配对端点各一份密文"，解不开别人那份是正常现象；'
              '在这里记会变成每 60s 一条的噪声');
    });

    test('IR-11 协助会合主题走**独立命名空间**：既不解密也不广播', () async {
      final seen = await collect(() async {
        await svc.debugHandleRaw(
            '${RcAssist.topicPrefix}deadbeef00000000', 'whatever');
      });
      expect(seen, isEmpty);
      expect(await countLogs(action: 'decode.fail'), 0,
          reason: '协助主题不依赖本机配对码 —— 一律丢给 Host 会让 Host 拿自己的 '
              'ctlKey 去解别人会话的报文，误计握手失败几次就把自己的会话锁死');
    });
  });

  // ═══════════════════════════════════════════════ C · 出站等待与配对确认

  group('IR-C requestPairing / _awaitAck', () {
    test('IR-12 回执到达 ⇒ confirmed，且对端下发的盐**原样**落盘', () async {
      svc.debugSendTo = (ep, msg, st, enqueueOnFail) async => true;
      final req = inbound(RcCmd.pairRequest, payload: {'deviceId': ctrlId});
      final salt = KdfSaltStore.newSalt();
      final ack = inbound(RcEvt.ack, payload: {
        'ok': true,
        'for': req.id,
        'kdfsalt': base64Encode(salt),
      });
      final fut = svc.requestPairing(peer, store, req,
          timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await svc.debugHandleRaw(evtTopic(ctrlId), await sealEvt(ack, ctrlId));
      final out = await fut;
      expect(out.confirmed, isTrue);
      expect(out.message, contains('对端已确认配对'));
      expect(salts.saltFor(ctrlId), salt,
          reason: '盐必须**原样**落盘：本机此后发给该端点的全部消息都用它派生');
    });

    test('IR-13 对端拒绝 ⇒ confirmed=false，理由**原样**透传（不写死文案）',
        () async {
      svc.debugSendTo = (ep, msg, st, enqueueOnFail) async => true;
      final req = inbound(RcCmd.pairRequest, payload: {'deviceId': ctrlId});
      final ack = inbound(RcEvt.ack,
          payload: {'ok': false, 'for': req.id, 'data': '用户点了拒绝'});
      final fut = svc.requestPairing(peer, store, req,
          timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await svc.debugHandleRaw(evtTopic(ctrlId), await sealEvt(ack, ctrlId));
      final out = await fut;
      expect(out.confirmed, isFalse);
      expect(out.message, '用户点了拒绝');
      expect(salts.saltFor(ctrlId), isNull,
          reason: '只在配对**成功**时落盐 —— 失败也写会把旧盐覆盖坏');
    });

    test('IR-14 发出去了但没人回 ⇒ 超时是**明确结论**，不是"再等等"', () async {
      svc.debugSendTo = (ep, msg, st, enqueueOnFail) async => true;
      final out = await svc.requestPairing(
          peer, store, inbound(RcCmd.pairRequest, payload: {'deviceId': ctrlId}),
          timeout: const Duration(milliseconds: 60));
      expect(out.confirmed, isFalse);
      expect(out.message, contains('尚未确认配对'));
    });

    test('IR-15 压根没发出去 ⇒ 立刻给出可执行指引（不等满超时）', () async {
      svc.debugSendTo = (ep, msg, st, enqueueOnFail) async => false;
      final out = await svc.requestPairing(
          peer, store, inbound(RcCmd.pairRequest, payload: {'deviceId': ctrlId}),
          timeout: const Duration(seconds: 30));
      expect(out.confirmed, isFalse);
      expect(out.message, contains('未能通知对端'),
          reason: '配对请求是**一次性在线握手**：失败要当场说，'
              '暂存进 outbox 等对端上线再补发毫无意义');
    });
  });
}
