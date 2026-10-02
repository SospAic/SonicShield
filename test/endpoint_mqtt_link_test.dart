import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/mqtt_client_stub.dart';

/// 第四十八轮：**MQTT 传输整层**（连接 / 订阅 / 发送 / 补发）的宿主行为锁。
///
/// ## 为什么需要这一份
///
/// 传输层的运行前提是「有一个 MQTT 客户端、且状态为 connected」。
/// 宿主机连不上 broker ⇒ 这一桶（约 128 行）此前**一行都没被执行过**：
/// `_connect` 的连接成功分支与订阅集合、`_send` 的成功分支、
/// `flushOutbox` 的补发分支、`sendTo` 的真实投递 ——
/// 全靠 `test/rc_transport_lock_test.dart`（TLS/端口）、
/// `test/q35_endpoint_wiring_test.dart`（端口来源/凭据门）、
/// `test/endpoint_dispatch_hardening_test.dart`（`_send` 的丢弃分支）
/// 这类**源码文本锁**兜底。判据第五代：**「源码锁是绿的」 ≠ 「那条业务路径被执行过」**。
///
/// ## 与第 45/46 轮两个替身的区别（判据第六代"换域"的第三站）
///
/// | 轮次 | 域 | 替身类型 | 还原义务 |
/// |---|---|---|---|
/// | 45 | `flutter_webrtc` | 平台通道桩 | 无（`MethodChannel` 桩天然隔离） |
/// | 46 | `just_audio` | **静态可写单例** `JustAudioPlatform.instance` | tearDown 必须还原 |
/// | **48** | `mqtt_client` | **实例注入** `debugClientFactory` | 生产恒为 null，无需全局还原 |
///
/// ⚠️ 全部走**真** `RcCodec`（真 HKDF / AES-GCM）：密钥错了就必须解不开，
/// 不接受"打个桩让 decode 恒成功"的假绿。替身只复刻**平台侧返回形状**，
/// 不做任何业务判断 —— 跑的是生产代码本身。
///
/// ⚠️ 端点服务是**单例**，`_seen` / `_cmdTs` / `_decodeFail` / `_rejectFlood`
/// 在文件内跨用例存活 ⇒ 每个用例用**自己的**主题/发送方，避免互相污染。
///
/// ⚠️ 本文件用**真异步**（`test()`，不是 `testWidgets`）：`AppDatabase` 走
/// `databaseFactoryFfi`，DB 操作在后台 isolate ⇒ 放进 fake-async 会**永久挂死**
/// （项目铁律，见 `.workbuddy-ai/memory/MEMORY.md`）。代价是
/// `_connect` 里那个 `Timer.periodic(60s)` 的心跳体**无法加速** ⇒ 如实留白
/// （见文件末的诚实边界）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const ownId = 'EP48own00000abc';
  const ctrlId = 'CTRL48peer00001';
  const brokerName = 'broker.round48.invalid';

  final svc = RcEndpointService.instance;

  late SharedPreferences prefs;
  late RemoteStore store;
  late KdfSaltStore salts;
  late AppDatabase db;
  late FakeMqttServerClient fake;
  late PairedEndpoint peer;

  /// 工厂被真正调用时收到的实参（`null` = 压根没调用）。
  String? seenBroker;
  String? seenClientId;
  int? seenPort;

  setUp(() async {
    seenBroker = null;
    seenClientId = null;
    seenPort = null;

    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    await store.setIdentity(ownId, '端点机48');
    await store.setBroker(brokerName);
    // ⚠️ 必须在 `debugSetOwnCode` **之前**：`store.pairingCode` 在
    // `ensurePairingCode()` 之前是空串，而空配对码会让 `_handleRaw` 直接返回
    // （真实缺陷的第一道闸门），于是"发出去的密文没人解"——
    // 症状是断言里"什么都没发生"，不是抛错。
    await store.ensurePairingCode();
    salts = KdfSaltStore(prefs);
    db = await AppDatabase.open(inMemoryDatabasePath);
    peer = PairedEndpoint(
      deviceId: ctrlId,
      name: '控制端48',
      secret: 'CODE4801',
      pairedAt: DateTime(2024, 1, 1),
    );
    await store.addPaired(peer);

    fake = FakeMqttServerClient(brokerName, ownId);
    svc.debugBind(store: store, db: db, saltStore: salts);
    svc.debugSetOwnCode(store.pairingCode);
    svc.debugClientFactory = (broker, clientId, port) {
      seenBroker = broker;
      seenClientId = clientId;
      seenPort = port;
      return fake;
    };
  });

  tearDown(() async {
    await svc.stop();
    svc.debugClientFactory = null;
    svc.debugSendTo = null;
    svc.debugSetOwnCode('');
    await fake.dispose();
    await db.close();
  });

  /// 把已排入微任务队列的异步收尾（`unawaited(refreshSubscriptions())` /
  /// `unawaited(flushAllOutbox(store))`）推完。
  ///
  /// ⚠️ 用有界轮次而不是 `pumpAndSettle` —— 本文件没有 widget 树，
  /// 且项目铁律禁止拿 `pumpAndSettle` 当"等数据"用。
  Future<void> settle([int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  String cmdTopicOf(String id) => 'sonicshield/v1/$id/cmd';
  String evtTopicOf(String id) => 'sonicshield/v1/$id/evt';

  RcMessage inbound(String type,
      {Map<String, dynamic> payload = const {}, String from = ctrlId}) {
    final n = RcMessage.now(type, payload);
    return RcMessage(
        id: n.id, ts: n.ts, type: n.type, payload: n.payload, from: from);
  }

  /// cmd 方向：控制端用「端点配对码 + 端点ID|cmd」加密。
  Future<String> sealCmd(RcMessage msg) async {
    final key = await RcCodec.deriveKey(store.pairingCode, '$ownId|cmd');
    return RcCodec.encode(msg, key, cmdTopicOf(ownId));
  }

  /// 与 `flushOutbox` **同参数**的一条合法暂存密文。
  Future<String> sealOutbox(String type) async {
    final key = await RcCodec.deriveKey(peer.secret, '${peer.deviceId}|cmd');
    return RcCodec.encode(
        inbound(type, from: store.deviceId), key, cmdTopicOf(peer.deviceId));
  }

  Future<int> countLogs(
      {String? action, String? status, String? contains}) async {
    final rows = await LogRepository(db).recent(limit: 500);
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

  // ═══════════════════════════════════════════ A · 连接与订阅集合

  group('MQ-A 连接：装配 → 构造客户端 → 订阅集合', () {
    test('MQ-01 start() 用 store 的 broker/deviceId/端口构造客户端，级联字段真的落到实例上',
        () async {
      await svc.start(store, db);

      expect(svc.isRunning, isTrue);
      expect(seenBroker, brokerName,
          reason: '构造实参必须来自 store.broker（自建 broker 才可能生效）');
      expect(seenClientId, ownId, reason: 'MQTT clientId 就是本机 deviceId');
      expect(seenPort, RemoteStore.defaultBrokerPort,
          reason: '未配置 rc_broker_port ⇒ 回落到共享常量（TL-03 的行为侧对照）');

      // 级联不是"写给人看的"：逐个字段断言它真落到了客户端实例上。
      expect(fake.port, RemoteStore.defaultBrokerPort);
      expect(fake.secure, isTrue, reason: 'C-13：secure=false 就退化成明文 TCP');
      expect(fake.keepAlivePeriod, 30);
      expect(fake.autoReconnect, isTrue);
      expect(fake.resubscribeOnAutoReconnect, isTrue);
      expect(fake.connectCalls, 1);
    });

    test('MQ-02 start() 幂等：第二次调用既不重连也不重建客户端', () async {
      await svc.start(store, db);
      final connects = fake.connectCalls;
      final subs = fake.subscribed.length;

      await svc.start(store, db);

      expect(fake.connectCalls, connects);
      expect(fake.subscribed.length, subs);
    });

    test('MQ-03 本机 deviceId 为空 ⇒ 根本不构造客户端（绝不空连 broker）', () async {
      await store.setIdentity('', '');
      await svc.start(store, db);

      expect(seenBroker, isNull, reason: '早返回必须发生在构造之前');
      expect(fake.connectCalls, 0);
      expect(svc.isRunning, isTrue,
          reason: '_running 已置真 —— 早返回在 _connect **内部**，不是 start 拒绝启动');
    });

    test('MQ-04 connect 抛错 ⇒ 走重连分支：不自毁 _running，且一条订阅都不发',
        () async {
      fake.failConnect = true;
      await svc.start(store, db);

      expect(fake.connectCalls, 1);
      expect(fake.subscribed, isEmpty,
          reason: '连不上就订阅 = 对着空气订阅，必须停在重连上');
      expect(svc.isRunning, isTrue,
          reason: '★ 服务仍然"在跑"（等着 10s 后重连）—— 这正是 autoReconnect 的语义');
      await settle();
    });

    test('MQ-05 连上了但状态不是 connected ⇒ 与"抛错"同一条重连分支', () async {
      fake.stayDisconnected = true;
      await svc.start(store, db);

      expect(fake.connectCalls, 1);
      expect(fake.subscribed, isEmpty);
      await settle();
    });

    test('MQ-06 连接成功 ⇒ 订阅本机 cmd + 每个已配对端点的 evt（BUG-013 的行为侧）',
        () async {
      await svc.start(store, db);

      // ⚠️ 本机 cmd 主题**刻意被订两次**：`_connect` 直连时订一次
      // （不依赖 `refreshSubscriptions` 的装配状态）＋ `refreshSubscriptions`
      // 再订一次（重连后的补订语义）。
      //
      // 为什么必须断言**次数**而不是"包含"：两处 subscribe 的主题字符串**逐字相同**，
      // 只断言 `contains` 的话，把其中任意一处删掉/改坏都不会判红 ——
      // 第 48 轮**变异测试实测**：把 `_connect` 那次改成 `cmdX`，MQ-06 仍绿
      // （靠 `refreshSubscriptions` 那一次兜住了）。那正是"断言没在约束它想约束的东西"。
      expect(fake.subscribed.where((t) => t == cmdTopicOf(ownId)).length, 2,
          reason: '★ 少一次就意味着 `_connect` 的直连订阅或补订被删掉了');
      expect(
          fake.subscribed, contains(evtTopicOf(peer.deviceId)),
          reason: '★ 不订对端 evt = 所有回执与通话信令永久不可达（BUG-013）');
    });

    test('MQ-07 refreshSubscriptions 在"未连接/未装配"时直接返回，不订阅任何主题',
        () async {
      // _client == null（没 start）
      await svc.refreshSubscriptions();
      expect(fake.subscribed, isEmpty);

      // 客户端在但没连上
      fake.failConnect = true;
      await svc.start(store, db);
      final afterStart = fake.subscribed.length;
      await svc.refreshSubscriptions();
      expect(fake.subscribed.length, afterStart,
          reason: '未连接时补订毫无意义 —— 必须早返回而不是攒一堆订阅');
    });

    test('MQ-08 onConnected（重连路径）⇒ 补订 + 冲刷暂存', () async {
      await svc.start(store, db);
      // 先把首连那次 `flushAllOutbox` 推完，避免它与本用例的 onConnected
      // 补发**并发读到同一条暂存**（实测会变成 2 次 publish 的假红）。
      await settle();
      await store.enqueue(await sealOutbox(RcCmd.ping), peer.deviceId);
      fake.subscribed.clear();

      // ⚠️ 生产代码把 `onConnected` 挂在客户端上，真实触发时机是**自动重连**。
      // 宿主机无法制造重连 ⇒ 直接取出宿主已装配好的那个闭包调用它。
      // 这不是"绕过生产代码"，而是**驱动生产代码注册的回调本身**。
      fake.onConnected!.call();
      await settle();

      expect(fake.subscribed, contains(cmdTopicOf(ownId)));
      expect(fake.subscribed, contains(evtTopicOf(peer.deviceId)));
      expect(fake.sentWires, hasLength(1),
          reason: '重连后必须补发暂存命令（UI 承诺"端点上线后自动执行"）');
      expect(store.outboxFor(peer.deviceId), isEmpty,
          reason: '补发成功后必须删条目，否则每次心跳都重发');
    });

    test('MQ-09 首连**不触发** onConnected ⇒ 仍必须补一次冲刷', () async {
      await store.enqueue(await sealOutbox(RcCmd.ping), peer.deviceId);

      await svc.start(store, db);
      await settle();

      expect(fake.onConnected, isNotNull, reason: '重连回调必须在连接前就装好');
      expect(fake.sentWires, hasLength(1),
          reason: '★ 首次连接走的是 connect() 而非 onConnected 回调 —— '
              '少了这一次，"启动时就有暂存命令"的场景永远不补发');
      expect(store.outboxFor(peer.deviceId), isEmpty);
    });

    test('MQ-10 stop() 断开客户端并清空引用；再 start() 会重新连一次', () async {
      await svc.start(store, db);
      expect(fake.disconnectCalls, 0);

      await svc.stop();
      expect(fake.disconnectCalls, 1);
      expect(svc.isRunning, isFalse);

      await svc.start(store, db);
      expect(fake.connectCalls, 2, reason: 'stop 之后必须能重新起一条连接');
    });
  });

  // ═══════════════════════════════════════════ B · 真实入站入口

  group('MQ-B updates 监听器：_handleRaw 的唯一生产入口', () {
    test('MQ-11 从 updates 流进来的报文真的驱动到入站链路（回执真的投出去）', () async {
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;

      // ★ 走的**不是** `debugHandleRaw` 这条测试缝，而是
      // `client.updates` 监听器 —— `_handleRaw` 的唯一生产调用点。
      await fake.emit(cmdTopicOf(ownId), await sealCmd(inbound(RcCmd.ping)));
      await settle();

      expect(fake.sentWires.length, sentBefore + 1,
          reason: '监听器闭包 → _handleRaw → 分发 → _send → 真投递，这条链路必须跑起来');
      // 反面对照：回执**发出去了**，就不该有"发不出去"的留痕。
      expect(await countLogs(action: RcEvt.pong, status: 'skipped'), 0,
          reason: '连接可用时还写"出站消息未发出"就是假留痕');
    });

    test('MQ-12 监听器把一次投递里的多条报文逐一处理', () async {
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;

      final w1 = await sealCmd(inbound(RcCmd.ping));
      final w2 = await sealCmd(inbound(RcCmd.ping));
      await fake.emitBatch([
        (cmdTopicOf(ownId), w1),
        (cmdTopicOf(ownId), w2),
      ]);
      await settle();

      expect(fake.sentWires.length - sentBefore, 2,
          reason: '监听器体内是一个 for 循环 —— 一次投递里的多条必须都被处理');
    });
  });

  // ═══════════════════════════════════════════ C · 出站与补发

  group('MQ-C 出站：_send / sendTo / flushOutbox', () {
    test('MQ-13 连接态下 _send 真的把密文投出去，且 from 被补成本机 deviceId',
        () async {
      await svc.start(store, db);

      await fake.emit(cmdTopicOf(ownId), await sealCmd(inbound(RcCmd.ping)));
      await settle();

      expect(fake.sentWires, hasLength(1),
          reason: '连接可用时 _send 必须走"真发"分支，而不是退化成审计留痕');
      final out = fake.sentWires.single;
      expect(out.topic, evtTopicOf(ownId),
          reason: '端点回执广播到**本机** evt 主题，由控制器订阅');
      expect(out.qos, MqttQos.atLeastOnce);

      // ★ 用对端的密钥把密文解回来 —— 证明发出去的是**真密文**且密钥正确。
      final key = await RcCodec.deriveKey(
          peer.secret, '${peer.deviceId}|evt');
      final back = await RcCodec.decode(out.wire, key, out.topic);
      expect(back, isNotNull, reason: '对端解不开 = 回执等于没发');
      expect(back!.from, ownId,
          reason: '★ 端点发出的消息必须自带发送方标识（否则控制器无法渲染来源）');
      expect(back.type, RcEvt.pong);
    });

    test('MQ-14 未连接时 _send 留痕且一条都不投（不静默、不假发）', () async {
      // 故意不 start() ⇒ _client == null
      await svc.debugHandleRaw(
          cmdTopicOf(ownId), await sealCmd(inbound(RcCmd.ping)));

      expect(fake.sentWires, isEmpty);
      expect(
          await countLogs(
              action: RcEvt.pong, status: 'skipped', contains: '出站消息未发出'),
          1,
          reason: '发不出去必须留痕 —— 否则"命令执行了但控制端毫无反应"');
    });

    test('MQ-15 连接态下 sendTo 走真实 publish，密文可被对端密钥解开', () async {
      await svc.start(store, db);
      final msg = RcMessage.now(RcCmd.ping, {'probe': 48});

      final ok = await svc.sendTo(peer, msg, store);

      expect(ok, isTrue, reason: '连接可用 ⇒ 在线路径必须成功');
      expect(fake.sentWires, hasLength(1));
      final out = fake.sentWires.single;
      expect(out.topic, cmdTopicOf(peer.deviceId));

      final key =
          await RcCodec.deriveKey(peer.secret, '${peer.deviceId}|cmd');
      final back = await RcCodec.decode(out.wire, key, out.topic);
      expect(back!.id, msg.id);
    });

    test('MQ-16 未连接 + enqueueOnFail ⇒ 暂存的是**密文**（补发路径解得开）',
        () async {
      final msg = RcMessage.now(RcCmd.ping, {'probe': 48});

      final ok = await svc.sendTo(peer, msg, store);

      expect(ok, isFalse);
      final queued = store.outboxFor(peer.deviceId);
      expect(queued, hasLength(1));
      final key =
          await RcCodec.deriveKey(peer.secret, '${peer.deviceId}|cmd');
      final back = await RcCodec.decode(
          queued.single['wire'] as String, key, cmdTopicOf(peer.deviceId),
          seenIds: const {}, maxSkewMs: const Duration(days: 3650).inMilliseconds);
      expect(back, isNotNull,
          reason: '★ 旧缺陷（BUG-053 同族）就是把明文 JSON 暂存起来，补发时一律解不开');
      expect(back!.id, msg.id);
    });

    test('MQ-17 flushOutbox 未连接 ⇒ 返回 0 且**不动**队列（只读+成功后才删）',
        () async {
      await store.enqueue(await sealOutbox(RcCmd.ping), peer.deviceId);

      expect(await svc.flushOutbox(store, peer), 0);
      expect(store.outboxFor(peer.deviceId), hasLength(1),
          reason: '★ 补发失败绝不能让命令消失 —— 那正是 drainOutbox 的错误用法');
      expect(fake.sentWires, isEmpty);
    });

    test('MQ-18 flushOutbox 解不开的坏条目被丢弃并**留痕**，不让它卡住队列',
        () async {
      await svc.start(store, db);
      // ⚠️ 必须**先** start 并把首连的那次 `flushAllOutbox` 推完，再入队 ——
      // 否则首连的补发与本用例的显式 flush 会**并发读到同一条**、
      // 各写一条审计（实测 audit 计数 1 → 2 的假红）。
      await settle();
      await store.enqueue('not-a-valid-wire', peer.deviceId);

      final n = await svc.flushOutbox(store, peer);

      expect(n, 0, reason: '坏条目不计入"实际交给客户端"的条数');
      expect(fake.sentWires, isEmpty);
      expect(store.outboxFor(peer.deviceId), isEmpty,
          reason: '★ 留着只会永久卡住后面每一条 —— 必须丢弃');
      expect(
          await countLogs(
              action: 'outbox.drop',
              status: 'failed',
              contains: '无法解密'),
          1,
          reason: '丢弃必须留痕（"命令没执行"才追得下去）');
    });

    test('MQ-19 flushAllOutbox 覆盖全部已配对端点，逐条重盖时间戳后投出',
        () async {
      const second = 'CTRL48peer00002';
      await store.addPaired(PairedEndpoint(
        deviceId: second,
        name: '控制端48B',
        secret: 'CODE4802',
        pairedAt: DateTime(2024, 1, 2),
      ));
      await svc.start(store, db);
      await settle(); // 首连那次补发推完（空队列），避免与下面的显式冲刷并发

      // 两条都指回同一个端点主题，便于断言"不是只补了一个端点"。
      await store.enqueue(await sealOutbox(RcCmd.ping), peer.deviceId);
      await store.enqueue('bad-wire-for-second', second);

      final n = await svc.flushAllOutbox(store);

      expect(n, 1, reason: '一条可重放、一条是坏条目');
      expect(fake.sentWires, hasLength(1));
      expect(store.outboxFor(peer.deviceId), isEmpty);
      expect(store.outboxFor(second), isEmpty,
          reason: '坏条目同样要被清掉，否则第二台设备的队列永远堵着');
    });

    test('MQ-22 flushOutbox 丢弃「缺 wire 字段」的畸形条目（不卡队列，也不计入投出条数）',
        () async {
      // 第 68 轮自查补：MQ-18/19 走的是 `wire` 非空但**解不开**（→ 2392 留痕丢弃）；
      // 这里是 `wire` **缺失**的畸形条目（升级残留 / 半写盘）—— 走的是不同的
      // `if (wire == null)` 分支，此前没有任何用例执行过。
      await svc.start(store, db);
      await settle(); // 首连那次补发推完（此时队列还空）
      await prefs.setString(
          'rc_outbox',
          jsonEncode([
            {'endpointId': peer.deviceId, 'at': 111}
          ]));

      expect(store.outboxFor(peer.deviceId), hasLength(1),
          reason: '前提：畸形条目确实进了队列（缺 wire 但 endpointId 命中）');

      final n = await svc.flushOutbox(store, peer);

      expect(n, 0, reason: '没法重放的条目不算"实际交给客户端"');
      expect(fake.sentWires, isEmpty, reason: '缺 wire 就不可能投得出去');
      expect(store.outboxFor(peer.deviceId), isEmpty,
          reason: '★ 畸形条目必须被丢弃 —— 留着会永久卡住它后面每一条命令');
    });
  });

  // ═══════════════════════════════════════════ D · 契约对照

  group('MQ-D 对照：源码文本锁的行为侧印证', () {
    test('MQ-20 端口来自 store.brokerPort（配置了就真的用）', () async {
      await store.setBrokerAdvanced(host: brokerName, port: 8899);
      await svc.start(store, db);

      expect(seenPort, 8899, reason: 'withPort 实参');
      expect(fake.port, 8899, reason: '`..port =` 那一处');
    });

    test('MQ-21 用户名 + 密码都非空才携带凭据（半套不携带）', () async {
      await store.setBrokerAdvanced(host: brokerName, username: 'u48');
      await svc.start(store, db);
      expect(fake.connectionMessage?.variableHeader?.connectFlags.usernameFlag,
          isFalse,
          reason: '只填用户名 ⇒ 半个凭据都不发（半套凭据会被 broker 直接拒连）');

      await svc.stop();
      await store.setBrokerAdvanced(
          host: brokerName, username: 'u48', password: 'p48');
      await svc.start(store, db);
      expect(fake.connectionMessage?.variableHeader?.connectFlags.usernameFlag,
          isTrue);
      expect(fake.connectionMessage?.variableHeader?.connectFlags.passwordFlag,
          isTrue);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────
// 诚实边界（本节不允许被读成别的意思）
//
// 1. **本替身证明不了真机行为**：QoS 1 的 ack/重投、`autoReconnect` 的真实
//    退避、TLS 证书链校验是否真的 fail-closed —— 这些只能在真机 + 抓包上取证
//    （`test/rc_transport_lock_test.dart` 的 TL 组已在文件头声明同一句）。
// 2. **`Timer.periodic(60s)` 的心跳体仍是未覆盖**：真实时钟无法加速，
//    而 fake-async 会让 `databaseFactoryFfi` 的 DB 调用永久挂死（项目铁律）。
//    该分支（补订 + 补发 + 心跳发送，约 13 行）本轮如实留白，未以任何方式凑数。
// 3. `_handleRaw` 抛错时的监听器兜底（try/catch → print，约 3 行）本轮也未覆盖：
//    需要构造一条"能被解码、但处理时会抛"的报文，未找到不依赖伪造的手段。
// ─────────────────────────────────────────────────────────────────────
