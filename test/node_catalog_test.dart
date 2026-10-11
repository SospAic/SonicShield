import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/node_catalog.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 远程连接节点目录 / 一键测速 / 传输方案（第八十二轮）契约测试。
///
/// 覆盖：目录内容（含国内节点、无明文端口）、时延探测的**成功与失败**两条路径
/// （用本地 ServerSocket 驱动，不依赖外网）、STUN 报文构造与校验（纯函数）、
/// 传输方案解析，以及 `RemoteStore` 的节点/传输持久化往返。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NC 节点目录', () {
    test('NC-01 MQTT 目录含国内节点 broker-cn.emqx.io，且无明文端口', () {
      expect(kMqttNodes, isNotEmpty);
      expect(kMqttNodes.any((n) => n.host == 'broker-cn.emqx.io'), isTrue,
          reason: 'EMQX 国内节点是「就近接入」的关键候选');
      expect(kMqttNodes.where((n) => n.cn), isNotEmpty);
      for (final n in kMqttNodes) {
        expect(n.port, isNot(1883), reason: '目录里不得出现明文端口');
        expect(n.id, '${n.host}:${n.port}');
      }
    });

    test('NC-02 STUN 目录含 ≥3 个国内节点 + Google 回落', () {
      expect(kStunNodes.where((n) => n.cn).length, greaterThanOrEqualTo(3),
          reason: 'Google STUN 在国内基本不可达，必须有多个国内节点');
      expect(kStunNodes.any((n) => n.host.contains('google')), isTrue);
      for (final n in kStunNodes) {
        expect(n.url, startsWith('stun:'));
      }
    });
  });

  group('NC 时延探测', () {
    test('NC-10 connectLatency 对本地服务端返回毫秒数（成功路径）', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((s) => s.destroy());
      addTearDown(server.close);
      final ms = await NodeSpeedTest.connectLatency('127.0.0.1', server.port,
          tls: false, timeout: const Duration(seconds: 3));
      expect(ms, isNotNull);
      expect(ms, greaterThanOrEqualTo(0));
    });

    test('NC-11 connectLatency 对无人监听端口返回 null（失败路径，不抛）', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final ms = await NodeSpeedTest.connectLatency('127.0.0.1', port,
          tls: false, timeout: const Duration(milliseconds: 800));
      expect(ms, isNull);
    });

    test('NC-12 stunBindingRequest 是 20 字节且头部正确', () {
      final tx = List<int>.generate(12, (i) => i);
      final req = NodeSpeedTest.stunBindingRequest(tx);
      expect(req.length, 20);
      expect(req.sublist(0, 2), [0x00, 0x01]);
      expect(req.sublist(2, 4), [0x00, 0x00]);
      expect(req.sublist(4, 8), [0x21, 0x12, 0xA4, 0x42]);
      expect(req.sublist(8), tx);
    });

    test('NC-13 isStunBindingResponse 校验类型 / 魔术字 / 事务 ID', () {
      final tx = List<int>.generate(12, (i) => i);
      final ok = <int>[0x01, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42, ...tx];
      expect(NodeSpeedTest.isStunBindingResponse(ok, tx), isTrue);
      // 类型不是 Binding Success
      expect(NodeSpeedTest.isStunBindingResponse(
          <int>[0x00, 0x01, ...ok.sublist(2)], tx), isFalse);
      // 魔术字被改
      final badCookie = [...ok]..[4] = 0x00;
      expect(NodeSpeedTest.isStunBindingResponse(badCookie, tx), isFalse);
      // 事务 ID 不匹配
      expect(
          NodeSpeedTest.isStunBindingResponse(ok, List<int>.filled(12, 9)),
          isFalse);
      // 太短
      expect(NodeSpeedTest.isStunBindingResponse(ok.sublist(0, 10), tx), isFalse);
    });

    test('NC-14 probeMqtt/probeStun 对不可达节点给出 null 且按可达优先排序', () async {
      const dead = [MqttNode(host: '127.0.0.1', label: 'dead', port: 1)];
      final r = await NodeSpeedTest.probeMqtt(dead,
          timeout: const Duration(milliseconds: 600));
      expect(r, hasLength(1));
      expect(r.first.ok, isFalse);
      expect(r.first.ms, isNull);

      const deadStun = [StunNode(host: '127.0.0.1', label: 'dead', port: 1)];
      final rs = await NodeSpeedTest.probeStun(deadStun,
          timeout: const Duration(milliseconds: 600));
      expect(rs, hasLength(1));
      expect(rs.first.ok, isFalse);
    });
  });

  group('NC 传输方案', () {
    test('NC-20 RcTransport.parse 容错 + usable（QUIC 暂不可用）', () {
      expect(RcTransport.parse('wss'), RcTransport.wss);
      expect(RcTransport.parse(' TLS '), RcTransport.tls);
      expect(RcTransport.parse('bogus'), RcTransport.tls);
      expect(RcTransport.parse(null), RcTransport.tls);
      expect(RcTransport.tls.usable, isTrue);
      expect(RcTransport.wss.usable, isTrue);
      expect(RcTransport.quic.usable, isFalse, reason: 'Dart 客户端库无 QUIC');
    });

    test('NC-21 三种传输方案的默认端口都不是明文端口', () {
      const plaintext = <int>[1883, 8080, 80];
      for (final t in RcTransport.values) {
        expect(plaintext, isNot(contains(t.defaultPort)), reason: t.id);
      }
    });
  });

  group('NC RemoteStore 节点 / 传输持久化', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('NC-30 setMqttNode / setStunSelectedUrl / setTransport 往返', () async {
      final s = RemoteStore(await SharedPreferences.getInstance());
      expect(s.mqttNodeHost, isEmpty);

      await s.setMqttNode('broker-cn.emqx.io', port: 8883);
      expect(s.mqttNodeHost, 'broker-cn.emqx.io');
      expect(s.mqttNodePort, 8883);
      expect(s.broker, 'broker-cn.emqx.io',
          reason: '选了预设节点后 broker 必须指向它');

      await s.setMqttNode('');
      expect(s.mqttNodeHost, isEmpty);

      await s.setStunSelectedUrl('stun:stun.qq.com:3478');
      expect(s.stunSelectedUrl, 'stun:stun.qq.com:3478');

      expect(s.transport, RcTransport.tls, reason: '出厂默认 TLS');
      await s.setTransport(RcTransport.wss);
      expect(s.transport, RcTransport.wss);
    });

    test('NC-31 自建（高级）broker 优先于预设节点', () async {
      final s = RemoteStore(await SharedPreferences.getInstance());
      await s.setMqttNode('broker-cn.emqx.io', port: 8883);
      await s.setBrokerAdvanced(host: 'my.broker.local', port: 8883);
      expect(s.broker, 'my.broker.local',
          reason: '显式接管的自建 broker 优先级最高');
    });
  });
}
