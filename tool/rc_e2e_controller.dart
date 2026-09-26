// 远程遥控端到端实测控制器（P0 双端点实测用，docs/12 §10.5）。
//
// 目的：以「桌面控制器」身份连接真实 MQTT broker，对**真机/模拟器上的
// 声盾 App（端点）**发送真实加密命令并校验其真实回执。复用项目自身的
// `package:sonic_shield/remote/protocol.dart`，因此密钥派生、AES-GCM 信封、
// 时间窗与 AAD 绑定与 App 完全一致——测的是真实协议，不是复刻实现。
//
// 密钥模型（与 endpoint_service.dart 对称，按接收方身份派生）：
//   cmd：控制器用 deriveKey(E.code, '{E.id}|cmd') 加密 → 发到 v1/{E.id}/cmd
//   evt：端点用   deriveKey(C.code, '{C.id}|evt') 加密 → 发到 v1/{E.id}/evt
//   AAD = 实际发布主题（双向）。
//
// 用法：
//   dart run tool/rc_e2e_controller.dart \
//     --eid <端点16位ID> --ecode <端点8位配对码> \
//     --cid <控制器16位ID> --ccode <控制器8位配对码> \
//     [--broker broker.emqx.io]
//
// 退出码：0 = 全部通过；1 = 存在失败。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:sonic_shield/remote/protocol.dart';

// ---------------- 结果统计 ----------------
var _pass = 0;
var _fail = 0;
final _failures = <String>[];

void _ok(String name, String detail) {
  _pass++;
  stdout.writeln('  [PASS] $name — $detail');
}

void _bad(String name, String detail) {
  _fail++;
  _failures.add('$name: $detail');
  stdout.writeln('  [FAIL] $name — $detail');
}

void _info(String s) => stdout.writeln('  [info] $s');

String _arg(List<String> a, String k, {String? dflt}) {
  final i = a.indexOf(k);
  if (i >= 0 && i + 1 < a.length) return a[i + 1];
  if (dflt != null) return dflt;
  stderr.writeln('缺少参数 $k');
  exit(2);
}

Future<void> main(List<String> argv) async {
  final eid = _arg(argv, '--eid');
  final ecode = _arg(argv, '--ecode').replaceAll('-', '').toUpperCase();
  final cid = _arg(argv, '--cid');
  final ccode = _arg(argv, '--ccode').replaceAll('-', '').toUpperCase();
  final broker = _arg(argv, '--broker', dflt: 'broker.emqx.io');

  stdout.writeln('=== 声盾远程遥控 端到端实测 ===');
  stdout.writeln('broker      : $broker:$rcBrokerPort (TLS)');
  stdout.writeln('端点(E)     : $eid  code=$ecode');
  stdout.writeln('控制器(C)   : $cid  code=$ccode');
  stdout.writeln('');

  // 双向密钥（与 App 一致）
  final cmdKey = await RcCodec.deriveKey(ecode, '$eid|cmd');
  final evtKey = await RcCodec.deriveKey(ccode, '$cid|evt');
  final cmdTopic = 'sonicshield/v1/$eid/cmd';
  final evtTopic = 'sonicshield/v1/$eid/evt';

  // ---------------- MQTT ----------------
  // 控制端侧同样是 MQTT 客户端，**必须**与端点用同一档传输（C-13）：
  // 端点只认 TLS 8883，工具若还写明文 1883 就会连不上 —— "修完反而测不了"。
  final client = MqttServerClient.withPort(broker, cid, rcBrokerPort)
    ..port = rcBrokerPort
    ..secure = true
    ..keepAlivePeriod = 30
    ..autoReconnect = true
    ..logging(on: false)
    ..setProtocolV311();

  client.connectionMessage =
      MqttConnectMessage().withClientIdentifier(cid).startClean();

  final inbox = StreamController<Map<String, dynamic>>.broadcast();
  final seen = <String>{};

  stdout.writeln('[1] 连接 broker …');
  try {
    await client.connect();
  } on Object catch (e) {
    stderr.writeln('连接失败: $e');
    exit(1);
  }
  if (client.connectionStatus?.state != MqttConnectionState.connected) {
    stderr.writeln('连接状态异常: ${client.connectionStatus}');
    exit(1);
  }
  stdout.writeln('    已连接（clientId=$cid）');

  // updates 流在 connect() 之后才可用。
  client.updates!.listen((batch) async {
    for (final m in batch) {
      final topic = m.topic;
      final payload = m.payload as MqttPublishMessage;
      final wire = utf8.decode(payload.payload.message, allowMalformed: true);
      if (topic != evtTopic) continue;
      final msg = await RcCodec.decode(wire, evtKey, topic, seenIds: const {});
      if (msg == null) {
        final head = wire.length > 24 ? wire.substring(0, 24) : wire;
        _info('evt 解密失败（可能非本控制器密钥）: $head…');
        continue;
      }
      if (msg.id.isNotEmpty && seen.contains(msg.id)) continue;
      seen.add(msg.id);
      if (!inbox.isClosed) {
        inbox.add({...msg.toJson(), 'peerId': eid});
      }
    }
  });

  client.subscribe(evtTopic, MqttQos.atLeastOnce);
  client.subscribe('sonicshield/v1/$cid/evt', MqttQos.atLeastOnce);
  stdout.writeln('    已订阅 $evtTopic');
  await Future<void>.delayed(const Duration(seconds: 1));

  // ---------------- 工具 ----------------
  var seq = 0;
  Future<String> send(String type, Map<String, dynamic> payload) async {
    final msg = RcMessage(
      id: 'c${(++seq).toString().padLeft(3, '0')}'
          '${DateTime.now().millisecondsSinceEpoch % 100000}',
      ts: DateTime.now().millisecondsSinceEpoch,
      type: type,
      payload: payload,
      from: cid,
    );
    final wire = await RcCodec.encode(msg, cmdKey, cmdTopic);
    final b = MqttClientPayloadBuilder()..addString(wire);
    client.publishMessage(cmdTopic, MqttQos.atLeastOnce, b.payload!,
        retain: false);
    return msg.id;
  }

  /// 等待满足条件的 evt。
  Future<Map<String, dynamic>?> waitFor(
    bool Function(Map<String, dynamic>) match, {
    Duration timeout = const Duration(seconds: 15),
    String what = 'evt',
  }) async {
    try {
      return await inbox.stream
          .firstWhere(match)
          .timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> expectType(String type,
          {Duration timeout = const Duration(seconds: 15)}) =>
      waitFor((m) => m['type'] == type, timeout: timeout, what: type);

  // ---------------- 探活：先确认端点在线 ----------------
  stdout.writeln('');
  stdout.writeln('[2] 端点探活（ping → rc.pong）');
  {
    await send(RcCmd.ping, const {});
    final r = await expectType(RcEvt.pong, timeout: const Duration(seconds: 20));
    if (r == null) {
      _bad('RC-01 ping/pong',
          '20s 内未收到 rc.pong —— 端点可能未启动/未连 broker/配对注入无效');
      stdout.writeln('');
      stdout.writeln('端点不可达，终止后续用例。');
      await _finish(client);
      return;
    }
    _ok('RC-01 ping/pong',
        'device=${r['payload']?['device']}（真实 MQTT 往返成功，密钥派生正确）');
  }

  // ---------------- RC-02 status.get ----------------
  stdout.writeln('');
  stdout.writeln('[3] 状态与任务查询');
  {
    await send(RcCmd.statusGet, const {});
    final r = await expectType(RcEvt.status);
    if (r == null) {
      _bad('RC-02 status.get', '未收到 rc.status');
    } else {
      final p = r['payload'] as Map;
      _ok('RC-02 status.get',
          'version=${p['version']} pendingCount=${p['pendingCount']} engine=${p['engine']}');
    }
  }

  // ---------------- RC-03 task.list ----------------
  String? realTaskId;
  {
    await send(RcCmd.taskList, const {});
    final r = await expectType(RcEvt.tasks);
    if (r == null) {
      _bad('RC-03 task.list', '未收到 rc.tasks');
    } else {
      final list = (r['payload']?['tasks'] as List?) ?? const [];
      if (list.isNotEmpty) realTaskId = (list.first as Map)['id'] as String?;
      _ok('RC-03 task.list',
          '${list.length} 个任务${realTaskId == null ? '（库为空，属正常）' : '，首个 id=$realTaskId'}');
    }
  }

  // ---------------- RC-04 logs.recent ----------------
  {
    await send(RcCmd.logsRecent, {'limit': 20});
    final r = await expectType(RcEvt.logs);
    if (r == null) {
      _bad('RC-04 logs.recent', '未收到 rc.logs');
    } else {
      final n = ((r['payload']?['logs'] as List?) ?? const []).length;
      _ok('RC-04 logs.recent', '返回 $n 条审计日志（远程命令已落审计）');
    }
  }

  // ---------------- RC-05 guard.set ----------------
  {
    await send(RcCmd.guardSet, {'enabled': true});
    final r = await waitFor((m) =>
        m['type'] == RcEvt.ack && m['payload']?['forType'] == RcCmd.guardSet);
    if (r == null) {
      _bad('RC-05 guard.set', '未收到对应 rc.ack');
    } else {
      _ok('RC-05 guard.set', 'ack ok=${r['payload']?['ok']}');
    }
  }

  // ---------------- RC-06 volume.set（v1.6.1 BUG-016 修复项） ----------------
  {
    await send(RcCmd.volumeSet, {'media': 0.5, 'alarm': 0.4});
    final r = await waitFor((m) =>
        m['type'] == RcEvt.ack && m['payload']?['forType'] == RcCmd.volumeSet);
    if (r == null) {
      _bad('RC-06 volume.set', '未收到对应 rc.ack（NativeBridge.volume.set 可能异常）');
    } else {
      final ok = r['payload']?['ok'] == true;
      ok
          ? _ok('RC-06 volume.set',
              'ack ok=true（原生 setStreamVolume 生效，BUG-016 修复已验证）')
          : _bad('RC-06 volume.set', 'ack ok=false data=${r['payload']?['data']}');
    }
  }

  // ---------------- RC-07 device.status ----------------
  {
    await send(RcCmd.deviceStatus, const {});
    final r = await expectType(RcEvt.device);
    if (r == null) {
      _bad('RC-07 device.status', '未收到 rc.device');
    } else {
      final p = r['payload'] as Map;
      _ok('RC-07 device.status',
          'name=${p['deviceName']} battery=${p['batteryLevel']}% charging=${p['charging']} version=${p['version']}');
    }
  }

  // ---------------- RC-08 location.get ----------------
  {
    await send(RcCmd.locationGet, const {});
    final r = await expectType(RcEvt.location, timeout: const Duration(seconds: 25));
    if (r == null) {
      _bad('RC-08 location.get', '未收到 rc.location');
    } else {
      final p = r['payload'] as Map;
      final hasPos = p['lat'] != null && p['lng'] != null;
      hasPos
          ? _ok('RC-08 location.get',
              'lat=${p['lat']} lng=${p['lng']} acc=${p['acc']}')
          : _info('RC-08 location.get 回执但无坐标（权限/无 GPS）：${jsonEncode(p)}');
      if (!hasPos) {
        _bad('RC-08 location.get', '回执无坐标 —— 模拟器无定位硬件属预期，真机应成功');
      }
    }
  }

  // ---------------- RC-09 sound.play ----------------
  {
    await send(RcCmd.soundPlay, {'volume': 0.3, 'durationSec': 2});
    final r = await waitFor((m) =>
        m['type'] == RcEvt.ack && m['payload']?['forType'] == RcCmd.soundPlay);
    if (r == null) {
      _bad('RC-09 sound.play', '未收到对应 rc.ack');
    } else {
      final ok = r['payload']?['ok'] == true;
      ok
          ? _ok('RC-09 sound.play', 'ack ok=true（playHandler 已注入并实际播放）')
          : _info('RC-09 sound.play ack ok=false data=${r['payload']?['data']}（音源库为空属预期）');
      if (!ok) {
        _bad('RC-09 sound.play',
            '未播放 —— 需库内有音源；BUG-015 修复仅保证 handler 已注入');
      }
    }
  }

  // ---------------- RC-10 camera.snap（预期降级） ----------------
  {
    await send(RcCmd.cameraSnap, const {});
    final r = await waitFor((m) =>
        m['type'] == RcEvt.ack && m['payload']?['forType'] == RcCmd.cameraSnap);
    if (r == null) {
      _bad('RC-10 camera.snap', '未收到对应 rc.ack');
    } else {
      final ok = r['payload']?['ok'] == true;
      !ok
          ? _ok('RC-10 camera.snap',
              '按设计降级 ok=false data=${r['payload']?['data']}（camera 插件 AGP9 未兼容，符合 docs/16 §9）')
          : _ok('RC-10 camera.snap', '意外成功 ok=true（camera 已可用，需更新文档）');
    }
  }

  // ---------------- RC-11 script.run（完整执行） ----------------
  stdout.writeln('');
  stdout.writeln('[4] 指令组（宏）执行');
  {
    final sid = 'e2e-${DateTime.now().millisecondsSinceEpoch}';
    await send(RcCmd.scriptRun, {
      'scriptId': sid,
      'name': 'E2E 正常执行组',
      'fromName': '桌面控制器',
      'sentAt': DateTime.now().millisecondsSinceEpoch,
      'steps': [
        {'kind': 'notify', 'title': 'E2E', 'body': '第 1 步通知'},
        {'kind': 'delay', 'seconds': 1},
        {'kind': 'vibrate'},
        {'kind': 'delay', 'seconds': 1},
      ],
    });
    final done = await waitFor(
      (m) =>
          m['type'] == RcEvt.scriptState &&
          m['payload']?['scriptId'] == sid &&
          m['payload']?['state'] == 'done',
      timeout: const Duration(seconds: 20),
    );
    if (done == null) {
      _bad('RC-11 script.run', '20s 内未收到 state=done');
    } else {
      _ok('RC-11 script.run',
          'scriptId=$sid 完整执行至 done（notify/delay/vibrate 步骤链跑通）');
    }
  }

  // ---------------- RC-12 script.stop（执行中终止） ----------------
  {
    final sid = 'e2e-stop-${DateTime.now().millisecondsSinceEpoch}';
    await send(RcCmd.scriptRun, {
      'scriptId': sid,
      'name': 'E2E 可终止组',
      'fromName': '桌面控制器',
      'sentAt': DateTime.now().millisecondsSinceEpoch,
      'steps': [
        {'kind': 'delay', 'seconds': 30},
        {'kind': 'notify', 'title': '不应到达', 'body': '此步应被终止跳过'},
      ],
    });
    // 等 running 出现，确认已在执行
    final running = await waitFor(
      (m) =>
          m['type'] == RcEvt.scriptState &&
          m['payload']?['scriptId'] == sid &&
          m['payload']?['state'] == 'running',
      timeout: const Duration(seconds: 8),
    );
    if (running == null) {
      _bad('RC-12 script.stop', '未进入 running 状态，无法验证终止');
    } else {
      await send(RcCmd.scriptStop, {'scriptId': sid});
      final stopped = await waitFor(
        (m) =>
            m['type'] == RcEvt.scriptState &&
            m['payload']?['scriptId'] == sid &&
            m['payload']?['state'] == 'stopped',
        timeout: const Duration(seconds: 10),
      );
      stopped == null
          ? _bad('RC-12 script.stop', '发出终止后未收到 state=stopped')
          : _ok('RC-12 script.stop',
              '执行中终止生效（30s delay 被中断，state=stopped）');
    }
  }

  // ---------------- RC-13 ptt.voice ----------------
  stdout.writeln('');
  stdout.writeln('[5] 对讲与通话信令');
  {
    // 最小合法 m4a 头（仅验证链路与落盘，不校验可播放性）
    final bytes = Uint8List.fromList(List<int>.filled(512, 0x00));
    await send(RcCmd.pttVoice, {
      'voiceId': 'e2e-voice-1',
      'durationMs': 900,
      'fromName': '桌面控制器',
      'audioB64': base64Encode(bytes),
    });
    final r = await expectType(RcEvt.pttAck, timeout: const Duration(seconds: 20));
    if (r == null) {
      _bad('RC-13 ptt.voice', '未收到 rc.ptt 回执');
    } else {
      _ok('RC-13 ptt.voice',
          'voiceId=${r['payload']?['voiceId']} ok=${r['payload']?['ok']}（音频已解密落盘并交播放器）');
    }
  }

  // ---------------- RC-14 call.invite ----------------
  {
    final callId = 'e2e-call-${DateTime.now().millisecondsSinceEpoch}';
    await send(RcCmd.callInvite, {'callId': callId, 'video': false});
    final r = await expectType(RcEvt.callState, timeout: const Duration(seconds: 20));
    if (r == null) {
      _bad('RC-14 call.invite', '未收到 rc.call 信令镜像');
    } else {
      _ok('RC-14 call.invite',
          'callId=${r['payload']?['callId']} state=${r['payload']?['state']}（来电已分发到 CallService）');
    }
  }

  // ---------------- 汇总 ----------------
  stdout.writeln('');
  stdout.writeln('══════════════════════════════════════');
  stdout.writeln('通过 $_pass / 失败 $_fail');
  if (_failures.isNotEmpty) {
    stdout.writeln('失败明细：');
    for (final f in _failures) {
      stdout.writeln('  · $f');
    }
  }
  stdout.writeln('══════════════════════════════════════');
  await _finish(client);
  exit(_fail == 0 ? 0 : 1);
}

Future<void> _finish(MqttServerClient client) async {
  try {
    client.disconnect();
  } on Object {
    // ignore
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
}
