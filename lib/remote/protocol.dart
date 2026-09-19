import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// 声盾远程遥控协议 v1（docs/14）。
///
/// 传输：MQTT（TLS），主题命名空间 `sonicshield/v1/{deviceId}/cmd|evt`。
/// 安全：配对秘密 → HKDF-SHA256 → AES-256-GCM 端到端加密；
/// 代理（MQTT broker）只见密文。AAD 绑定主题与设备 ID 防跨主题重放。
///
/// 消息信封（明文结构，加密后传输）：
/// {v:1, id, ts, type, payload}
///  - ts 单调毫秒；接收端拒绝 |now-ts| > 90s（防重放窗口）
///  - id 每消息随机，接收端缓存去重（防窗口内重放）
class RcMessage {
  const RcMessage({
    required this.id,
    required this.ts,
    required this.type,
    this.payload = const {},
    this.from = '',
  });

  final String id;
  final int ts;
  final String type;
  final Map<String, dynamic> payload;
  final String from; // 发送方 deviceId（调试/展示用，不参与鉴权）

  Map<String, dynamic> toJson() => {
        'v': 1,
        'id': id,
        'ts': ts,
        'type': type,
        'payload': payload,
        'from': from
      };

  static RcMessage? tryParse(Map<String, dynamic> j) {
    if (j['v'] != 1 || j['type'] is! String) return null;
    return RcMessage(
      id: j['id'] as String? ?? '',
      ts: (j['ts'] as num?)?.toInt() ?? 0,
      type: j['type'] as String,
      payload: (j['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
      from: j['from'] as String? ?? '',
    );
  }

  static RcMessage now(String type,
          [Map<String, dynamic> payload = const {}]) =>
      RcMessage(
        id: _randomId(),
        ts: DateTime.now().millisecondsSinceEpoch,
        type: type,
        payload: payload,
      );

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(12, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

/// 从事件信封中取出 `payload`。
///
/// [RcEndpointService.events] 广播的是 `msg.toJson()` 展开后的信封
/// （`{v, id, ts, type, payload, from, peerId, peerName}`），端点回执的
/// 业务字段全部在 **`payload` 之内**。UI 侧曾直接读顶层字段
/// （如 `m['pendingCount']`）→ 恒为 null，回执面板永远显示空值（BUG-023）。
/// 统一走本函数取值。
Map<String, dynamic> rcPayloadOf(Map<String, dynamic> envelope) {
  final p = envelope['payload'];
  return p is Map ? p.cast<String, dynamic>() : const {};
}

// ---------------- 命令类型（控制器 → 端点） ----------------

abstract final class RcCmd {
  static const ping = 'ping'; // → pong {latencyHint}
  static const statusGet = 'status.get'; // → status {engine,battery,tasks,next}
  static const soundPlay =
      'sound.play'; // {preset|assetId|category, volume, durationSec, loop}
  static const taskList = 'task.list'; // → tasks [...]
  static const taskToggle = 'task.toggle'; // {taskId, enabled}
  static const taskSkipNext = 'task.skipNext'; // {taskId}
  static const guardSet = 'guard.set'; // {enabled}
  static const logsRecent = 'logs.recent'; // {limit}

  /// 指令组（宏）：端点收到后【立即执行】。
  /// payload: {scriptId, name, fromName, sentAt, steps: [...]}
  /// steps 元素：{kind: play|tts|notify|vibrate|record|delay, ...参数}
  static const scriptRun = 'script.run';

  /// 终止当前指令组执行（携带 scriptId；'*' 表示终止任意当前执行）。
  static const scriptStop = 'script.stop';

  /// 对讲机（v1 整段模式，参考微信语音；v2 升级流式）：
  /// ptt.voice {voiceId, durationMs, audioB64(aac, 端到端加密信封内)}
  static const pttVoice = 'ptt.voice';

  /// 视频通话（v1.4，WebRTC + MQTT 信令，docs/16）：
  /// call.invite {callId, video} → 被叫自动接通（可配置）
  /// call.answer {callId, sdp} / call.candidate {callId, candidate} / call.end {callId}
  static const callInvite = 'call.invite';
  static const callAnswer = 'call.answer';
  static const callCandidate = 'call.candidate';
  static const callEnd = 'call.end';

  /// 设备完全控制（v1.6，仅限已配对设备，docs/16 §9）：
  /// device.status → rc.device；camera.snap → rc.photo；
  /// location.get → rc.location；volume.set {media, alarm}
  static const deviceStatus = 'device.status';
  static const cameraSnap = 'camera.snap';
  static const locationGet = 'location.get';
  static const volumeSet = 'volume.set';

  // ---- v1.7：远程任务 CRUD（与本机「自动化 → 任务」完整对齐，docs/14 §2.1）----

  /// 取单条任务完整定义：{taskId} → rc.task {task}
  static const taskGet = 'task.get';

  /// 新建/更新任务（按 id 幂等）：{task} → rc.ack
  /// 成功后端点**重新物化 occurrence**（否则新任务永不到期）。
  static const taskUpsert = 'task.upsert';

  /// 删除任务及其待执行计划：{taskId} → rc.ack
  static const taskDelete = 'task.delete';

  /// 立即执行任务动作（不等待计划时刻）：{taskId} → rc.ack + rc.exec
  static const taskRunNow = 'task.runNow';

  /// 端点音源库：{limit?} → rc.assets {assets}
  static const assetList = 'asset.list';

  /// 端点预置音源分类：{} → rc.presets {categories}
  static const presetList = 'preset.list';
}

// ---------------- 事件类型（端点 → 控制器） ----------------

abstract final class RcEvt {
  static const pong = 'rc.pong';
  static const status = 'rc.status';
  static const tasks = 'rc.tasks';
  static const logs = 'rc.logs';
  static const ack = 'rc.ack'; // 通用回执 {ok, for: cmdId, data}
  static const heartbeat = 'rc.heartbeat'; // 周期 60s
  static const exec =
      'rc.exec'; // 动作执行通知 {for?, taskId, taskName, ok, message, fromName}
  static const offline = 'rc.offline'; // LWT 由 broker 代发（明文哨兵，无敏感内容）
  static const scriptState =
      'rc.script'; // {scriptId, state: running|done|stopped, stepIndex}
  static const pttAck = 'rc.ptt'; // {voiceId, ok, playedMs}
  static const callState =
      'rc.call'; // 通话状态镜像 {callId, state: ringing|connected|ended}
  static const device = 'rc.device'; // 设备状态快照
  static const photo = 'rc.photo'; // 拍照回传 {photoB64}
  static const location = 'rc.location'; // 定位回传 {lat,lng,acc}
  static const callMissed = 'rc.call.missed'; // 未接（被叫进程不在线时由控制器判定）

  // ---- v1.7：远程任务 CRUD 回执 ----
  static const task = 'rc.task'; // 单条任务完整定义 {for, task}
  static const assets =
      'rc.assets'; // 音源库 {for, assets:[{id,name,durationMs,tags}]}
  static const presets = 'rc.presets'; // 预置分类 {for, categories:[...]}
}

// ---------------- 加密编解码 ----------------

final class RcCodec {
  RcCodec._();

  static final Hkdf _alg = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final AesGcm _aes = AesGcm.with256bits();

  /// 由配对秘密派生消息密钥。
  /// [context]：`{endpointId}|cmd` 或 `{endpointId}|evt`——端点与控制器
  /// 双方都能派生同方向密钥（每个配对、每个方向独立密钥）。
  static Future<List<int>> deriveKey(String secret, String context) async {
    final sk = await _alg.deriveKey(
      secretKey: SecretKey(utf8.encode(secret)),
      nonce: utf8.encode('sonicshield-rc-v1|$context'),
      info: utf8.encode('sonicshield'),
    );
    return sk.extractBytes();
  }

  /// 加密：AES-256-GCM，AAD = topic（v1 简化：防跨主题移植密文）。
  static Future<String> encode(
    RcMessage msg,
    List<int> key,
    String topic,
  ) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(msg.toJson())),
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: utf8.encode(topic),
    );
    final blob = <String, String>{
      'n': base64Encode(nonce),
      'c': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    };
    return base64Encode(utf8.encode(jsonEncode(blob)));
  }

  /// 解密；时间窗与去重校验由 [seenIds]/[maxSkewMs] 承担。
  static Future<RcMessage?> decode(
    String wire,
    List<int> key,
    String topic, {
    Map<String, int> seenIds = const {},
    int maxSkewMs = 90000,
  }) async {
    try {
      final blob = (jsonDecode(utf8.decode(base64Decode(wire))) as Map)
          .cast<String, String>();
      final box = SecretBox(
        base64Decode(blob['c']!),
        nonce: base64Decode(blob['n']!),
        mac: Mac(base64Decode(blob['m']!)),
      );
      final clear = await _aes.decrypt(
        box,
        secretKey: SecretKey(key),
        aad: utf8.encode(topic),
      );
      final msg = RcMessage.tryParse(
          (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>());
      if (msg == null) return null;
      final skew = (DateTime.now().millisecondsSinceEpoch - msg.ts).abs();
      if (skew > maxSkewMs) return null; // 重放/时钟漂移保护
      if (msg.id.isNotEmpty && seenIds.containsKey(msg.id)) return null;
      return msg;
    } on Object {
      return null; // 解密失败（密钥不符/篡改）→ 静默丢弃
    }
  }

  /// 生成配对码：8 位 Base32（Crockford 风格去易混字符），≈40bit 熵。
  static String generatePairingCode() {
    const chars = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';
    final r = Random.secure();
    final raw = List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
    return '${raw.substring(0, 4)}-${raw.substring(4)}';
  }

  /// 设备 ID：16 位小写十六进制。
  static String generateDeviceId() =>
      List.generate(16, (_) => '0123456789abcdef'[Random.secure().nextInt(16)])
          .join();
}

/// 扫码配对 URI（v1.5）：
/// sonicshield://pair/{deviceId(16位)}/{name(urlencoded)}/{code(8位)}
abstract final class PairQrProtocol {
  static const prefix = 'sonicshield://pair/';

  /// 解析对端配对二维码；格式不符（ID/码长度、前缀）返回 null。
  static ({String deviceId, String name, String code})? parseUri(String uri) {
    if (!uri.startsWith(prefix)) return null;
    final parts = uri.substring(prefix.length).split('/');
    if (parts.length < 3) return null;
    final id = parts[0];
    final name = Uri.decodeComponent(parts[1]);
    final code = parts[2].replaceAll('-', '').toUpperCase();
    if (id.length != 16 || code.length != 8) return null;
    return (deviceId: id, name: name, code: code);
  }
}
