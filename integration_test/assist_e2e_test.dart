import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/assist_join.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 协助会话「真实 broker」端到端测试 —— S3 验收（真机↔模拟器）的可行替代。
///
/// ## 为什么这样设计
///
/// S3 的验收标准是「真机 ↔ 模拟器端到端握手」。当前环境**没有真机接入**，
/// 而双模拟器 UI 自动化在本机不可行（宿主持续重载 → 模拟器 `System UI ANR`，
/// 且 Manifest 无 VIEW intent-filter、无深链，只能盲点坐标，结果不可信）。
///
/// 但该验收真正要证明的是**跨进程/跨网络的真实链路**是否成立，而不是
/// "两台不同型号的手机"。因此这里用一个**独立的第二个 MQTT 连接**扮演控制端：
///
/// | 角色 | 实现 |
/// |---|---|
/// | 端点 | 应用**真实的** `RcEndpointService`（真实 broker、真实订阅、真实按主题路由、真实审计落库） |
/// | 控制端 | 测试进程内**另开一条 MQTT 连接**，绑到**真实的** `AssistJoinClient` |
///
/// 两条连接在 broker 上彼此独立，投递由 broker 完成。因此真实覆盖了：
/// 会合主题的订阅与发布、`assist.hello` **重试**（真实 RTT）、
/// AES-256-GCM 端到端加密、端点服务的**按主题精确路由**、
/// 业务命令与回执经**会合主题**（`assistReplyZone`）。
///
/// **唯一未覆盖**的维度：两个不同 Android 进程/机型。
/// 该维度留待有真机时按 docs/17 §12.5 的步骤补测。
///
/// ## 运行
/// ```
/// flutter test integration_test/assist_e2e_test.dart -d emulator-5554
/// ```
/// 依赖公网 broker（默认 `broker.emqx.io`），需设备可访问互联网。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('协助会话真实 broker 端到端：握手 → 业务命令 → 回执', (tester) async {
    // 唯一化标识：公网 broker 上不能与其它客户端撞名。
    final rnd = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final epId = 'e2e-ep-$rnd';
    final ctrlId = 'e2e-ctl-$rnd';

    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    await store.setIdentity(epId, 'E2E端点');
    await store.setBroker(RemoteStore.defaultBroker);
    await store.setEnabled(true);

    final db = await AppDatabase.open();
    final host = RcAssistHost.instance;
    final join = AssistJoinClient();
    MqttServerClient? ctrlClient;
    _PeerTransport? transport;
    StreamSubscription<Map<String, dynamic>>? evtSub;

    try {
      // ---------- 端点侧：真实端点服务 + 真实会话托管 ----------
      await RcEndpointService.instance.start(store, db);
      expect(RcEndpointService.instance.isRunning, isTrue);

      final session = await host.start();
      expect(session.phase, AssistPhase.waiting);
      expect(host.session?.topic, session.topic);
      // 端点已在 broker 上订阅会合主题（start() 内 await subscribe）。

      // ---------- 控制端侧：第二条真实 MQTT 连接 ----------
      final broker = store.broker;
      ctrlClient = MqttServerClient.withPort(broker, ctrlId, 1883)
        ..port = 1883
        ..keepAlivePeriod = 30
        ..logging(on: false);
      ctrlClient.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(ctrlId)
          .startClean();
      await ctrlClient.connect();
      expect(
        ctrlClient.connectionStatus?.state,
        MqttConnectionState.connected,
        reason: '控制端第二条 MQTT 连接应建立成功（broker=$broker）',
      );

      transport = _PeerTransport(ctrlClient);
      join.bind(transport);
      join.ctrlName = 'E2E控制端';
      // 真实网络下 MQTT 的 SUBSCRIBE 生效有往返延迟，hello 需重试；
      // 这里保留生产的 1.5s 间隔（不注入毫秒级），以真实检验重试逻辑。
      join.helloRetryInterval = const Duration(milliseconds: 500);

      final events = <Map<String, dynamic>>[];
      evtSub = join.events.listen(events.add);
      transport.incoming.listen((wire) => unawaited(join.onWire(wire)));

      // ---------- 握手 ----------
      final ok = await join.join(session.code, session.password,
          timeout: const Duration(seconds: 30));

      expect(ok, isTrue, reason: '接入失败：${join.info.error ?? '未知原因'}');
      expect(join.active, isTrue);
      expect(join.phase, AssistPhase.active);
      expect(join.sessionId, session.sessionId,
          reason: '两端会话 ID 必须一致（证明是同一个会话）');
      expect(join.epName, 'E2E端点', reason: '端点显示名应经 accept 回传');
      expect(host.active, isTrue);
      expect(host.session?.ctrlName, 'E2E控制端',
          reason: '端点侧应记录控制端显示名（C2 可见性）');
      expect(join.perms.toJson().values.any((v) => v == true), isFalse,
          reason: 'C5：会话建立时端点默认全拒');

      // ---------- 业务命令：ping（只读，无需放行）经会合主题往返 ----------
      final sent = await join.send(RcMessage.now(RcCmd.ping));
      expect(sent, isTrue);

      await _waitFor(
        () => events.any((e) => e['type'] == RcEvt.pong),
        timeout: const Duration(seconds: 20),
      );

      final pong = events.firstWhere((e) => e['type'] == RcEvt.pong);
      expect(pong['assist'], isTrue, reason: '回执应标记来源为协助通道');
      expect(pong['peerName'], 'E2E端点');
      // BUG-023：回执业务字段在 payload 内，不在信封顶层。
      expect(rcPayloadOf(pong), isA<Map<String, dynamic>>());

      // ---------- 未授权命令：端点拒绝且不执行 ----------
      final deniedBefore = events.length;
      await join.send(RcMessage.now(RcCmd.soundPlay, {'category': 'alarms'}));
      await _waitFor(
        () => events
            .skip(deniedBefore)
            .any((e) => e['type'] == RcEvt.ack && rcPayloadOf(e)['ok'] == false),
        timeout: const Duration(seconds: 20),
      );
      expect(
        events
            .skip(deniedBefore)
            .any((e) => e['type'] == RcEvt.ack && rcPayloadOf(e)['ok'] == false),
        isTrue,
        reason: '默认全拒下 sound.play 应被端点显式拒绝',
      );

      // ---------- 审计：两端都要留痕 ----------
      expect(join.auditLog.any((e) => !e.outbound && e.type == RcEvt.ack),
          isTrue, reason: '控制端审计应记录端点的拒绝回执');
      expect(join.auditLog.any((e) => e.outbound && e.type == RcCmd.ping), isTrue);

      // ---------- 端点放行后同一命令即可执行 ----------
      expect(await host.grant(const AssistPerms(media: true)), isTrue);
      await _waitFor(() => join.perms.media, timeout: const Duration(seconds: 15));
      expect(join.perms.media, isTrue, reason: '权限变更应经 perm 报文同步到控制端');
      expect(join.allows(RcCmd.soundPlay), isTrue);

      // ---------- 控制端挂断 → 端点会话终止 ----------
      await join.leave();
      await _waitFor(() => host.session == null,
          timeout: const Duration(seconds: 15));
      expect(host.session, isNull, reason: '控制端挂断应通知端点终止会话');
      expect(join.phase, AssistPhase.closed);
    } finally {
      await evtSub?.cancel();
      await join.leave(silent: true);
      await host.close(silent: true);
      await RcEndpointService.instance.stop();
      await transport?.dispose();
      ctrlClient?.disconnect();
      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// 轮询等待条件成立（真实时钟；避免固定 sleep 在重载下变脆）。
Future<void> _waitFor(
  bool Function() cond, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// 控制端侧的 [AssistTransport]：把抽象接口落到**第二条真实 MQTT 连接**上。
class _PeerTransport implements AssistTransport {
  _PeerTransport(this._client) {
    _client.updates!.listen((list) {
      for (final m in list) {
        final pub = m.payload as MqttPublishMessage;
        final text =
            utf8.decode(pub.payload.message, allowMalformed: true);
        if (!_incoming.isClosed) _incoming.add(text);
      }
    });
  }

  final MqttServerClient _client;
  final _incoming = StreamController<String>.broadcast();

  /// 会合主题上收到的原始密文（交给 `AssistJoinClient.onWire` 解密）。
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<void> subscribe(String topic) async {
    _client.subscribe(topic, MqttQos.atLeastOnce);
  }

  @override
  Future<void> unsubscribe(String topic) async {
    _client.unsubscribe(topic);
  }

  @override
  Future<void> publishWire(String topic, String wire) async {
    final b = MqttClientPayloadBuilder()..addString(wire);
    _client.publishMessage(topic, MqttQos.atLeastOnce, b.payload!,
        retain: false);
  }

  Future<void> dispose() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}
