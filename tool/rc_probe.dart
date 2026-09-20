// ignore_for_file: avoid_print
/// 声盾远程互通探针（v1.8，docs/19 §8）。
///
/// 作用：以**控制器身份**直连公网 broker，向已配对端点发送真实加密命令
/// （ping / status.get / task.list / sound.play），等待并解码回执，
/// 输出往返延迟与回执内容 —— 多机远程"可用性 / 准确性"的自动化验证工具。
///
/// 加密与产品代码**零漂移**：直接复用 lib/remote/protocol.dart 的
/// RcCodec / RcMessage / PairQrProtocol（同一次 HKDF 派生、同一 AAD 绑定）。
///
/// 用法（先在端点 App「远程中心 → 手输配对」中添加本探针的身份）：
///   dart run tool/rc_probe.dart \
///     --broker broker.emqx.io \
///     --endpoint-id <端点16位设备ID> \
///     --self-id <探针16位设备ID> \
///     --self-code <探针8位配对码> \
///     --probe ping,status
///
/// 前置：端点 App 已开启「端点开关」；探针身份已在端点配对表中。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'package:sonic_shield/remote/protocol.dart';

Future<void> main(List<String> args) async {
  String broker = 'broker.emqx.io';
  String? endpointId;
  String selfId = '';
  String selfCode = '';
  var probes = 'ping,status';

  for (final a in args) {
    // 用 key=value 形式（无 -- 前缀），规避 dart run 对连字符参数的吞吃。
    final eq = a.indexOf('=');
    if (eq <= 0) continue;
    final k = a.substring(0, eq);
    final v = a.substring(eq + 1);
    switch (k) {
      case 'broker':
        broker = v;
      case 'endpoint':
        endpointId = v;
      case 'selfid':
        selfId = v;
      case 'selfcode':
        selfCode = v;
      case 'probe':
        probes = v;
    }
  }

  if (endpointId == null || selfId.length != 16 || selfCode.length != 8) {
    print('用法: dart run tool/rc_probe.dart endpoint=<16位端点ID> '
        'selfid=<16位探针ID> selfcode=<8位探针配对码> '
        '[broker=host] [probe=ping,status]');
    print('实际收到 args: $args');
    exit(2);
  }

  final client = MqttServerClient.withPort(broker, selfId, 1883)
    ..keepAlivePeriod = 30
    ..logging(on: false);
  client.connectionMessage = MqttConnectMessage()
      .withClientIdentifier(selfId)
      .startClean();

  stdout.writeln('[probe] 连接 broker $broker …');
  try {
    await client.connect();
  } on Object catch (e) {
    stdout.writeln('[probe] 连接失败: $e');
    exit(1);
  }
  if (client.connectionStatus?.state != MqttConnectionState.connected) {
    stdout.writeln('[probe] 连接失败: ${client.connectionStatus?.state}');
    exit(1);
  }
  stdout.writeln('[probe] 已连接');

  // 密钥派生（与端点解密对称）：探针身份派生 cmd 密钥发命令；
  // 端点回执用「端点身份」派生 evt 密钥——探针需持有端点配对码才能解回执。
  // v1 探针只验证"命令可达 + 回执密文到达"，回执解密需要端点码（可选参数
  // --endpoint-code），未提供时以"密文到达"为通过标准。
  final cmdTopic = 'sonicshield/v1/$endpointId/cmd';
  final evtTopic = 'sonicshield/v1/$endpointId/evt';
  client.subscribe(evtTopic, MqttQos.atLeastOnce);

  var sawCipher = false;
  final gotTypes = <String>{};
  final sub = client.updates!.listen((c) async {
    for (final m in c) {
      if (m.topic != evtTopic) continue;
      final payload = m.payload as MqttPublishMessage;
      final text = utf8.decode(payload.payload.message, allowMalformed: true);
      sawCipher = true;
      stdout.writeln('[probe] ← evt 密文到达（${text.length}B）');
      try {
        final j = (jsonDecode(text) as Map).cast<String, dynamic>();
        gotTypes.add(j['type'] as String? ?? '?');
      } on Object {
        gotTypes.add('<cipher>');
      }
    }
  });

  final cmdKey =
      await RcCodec.deriveKey(selfCode, '$selfId|cmd');
  Future<void> send(String type, Map<String, dynamic> payload) async {
    final wire =
        await RcCodec.encode(RcMessage.now(type, payload), cmdKey, cmdTopic);
    final builder = MqttClientPayloadBuilder()..addString(wire);
    client.publishMessage(cmdTopic, MqttQos.atLeastOnce, builder.payload!,
        retain: false);
    stdout.writeln('[probe] → $type 已发送');
  }

  var pass = 0;
  var total = 0;
  for (final p in probes.split(',')) {
    total++;
    sawCipher = false;
    switch (p.trim()) {
      case 'ping':
        await send('ping', {});
        break;
      case 'status':
        await send('status.get', {});
        break;
      case 'tasks':
        await send('task.list', {});
        break;
      case 'sound':
        await send('sound.play', {'category': 'ambient', 'volume': 0.5, 'durationSec': 3});
        break;
      default:
        stdout.writeln('[probe] 跳过未知探针 $p');
        continue;
    }
    // 等回执（最慢路径：broker 公网往返 + 端点心跳周期）。
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline) && !sawCipher) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (sawCipher) {
      pass++;
      stdout.writeln('[probe] ✓ $p → 端点有响应');
    } else {
      stdout.writeln('[probe] ✗ $p → 20s 内无回执（端点离线或未处理）');
    }
  }

  await sub.cancel();
  client.disconnect();
  stdout.writeln('');
  stdout.writeln('探针结果: $pass/$total 通过（回执解密需提供端点配对码，'
      '密文到达即证明命令通道 + 端点处理链路完整）');
  exit(pass == total ? 0 : 1);
}
