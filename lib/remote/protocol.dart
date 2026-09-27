import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// 声盾远程遥控协议 v1（docs/14）。
///
/// 传输：MQTT over **TLS 8883**（证书链强校验，不提供忽略证书的回调；
/// 见 `RcEndpointService._connect` 与 `RemoteStore.defaultBrokerPort`）。
/// 主题命名空间 `sonicshield/v1/{deviceId}/cmd|evt`。
/// 安全：配对秘密 → HKDF-SHA256 → AES-256-GCM 端到端加密；
/// 代理（MQTT broker）只见密文。AAD 绑定主题与设备 ID 防跨主题重放。
///
/// 消息信封（明文结构，加密后传输）：
/// {v:1, id, ts, type, payload}
///  - ts 单调毫秒；接收端拒绝 |now-ts| > 90s（防重放窗口）
///  - id 每消息随机，接收端缓存去重（防窗口内重放）
/// 远程遥控 broker 端口：**TLS 8883**（C-13 P0）。
///
/// ## 为什么这个常量放在本文件，而不是 `remote_store.dart`
///
/// `protocol.dart` **不依赖 Flutter**（只 import `dart:*` 与 `cryptography`）；
/// 而 `tool/rc_probe.dart`、`tool/rc_e2e_controller.dart` 是**纯 Dart 命令行
/// 工具**（`dart run tool/...`）。它们若去 import `remote_store.dart`，就会把
/// `shared_preferences`（→ Flutter）拖进依赖树，在 `dart run` 下直接编译不过。
/// 端到端工具是"修完还能验证"的前提，因此真源必须落在无 Flutter 依赖的一侧。
///
/// ⚠️ **明文 1883 已被封禁**：`lib/` + `tool/` + `integration_test/` 全量扫描
/// （剥注释后）不得再出现该端口，且每个 MQTT 构造点都必须 `secure = true` ——
/// 见 `test/rc_transport_lock_test.dart`。
const int rcBrokerPort = 8883;

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
  /// 配对**双向化**（v2.0，R-2）：控制端扫码/手输成功后，主动把**自己**登记到
  /// 端点侧，使配对成为"双向"而非"单方落盘"。
  ///
  /// payload（**必须携带这三项**）：
  /// `{deviceId: 控制端 16 位 ID, name: 控制端显示名, code: 控制端 8 位配对码}`
  ///
  /// ⚠️ **`code` 不是可选装饰**：端点回执的密钥是
  /// `deriveKey(控制端配对码, '{控制端ID}|evt')`（见 `endpoint_service._send`）。
  /// 不携带它，端点就没有可用密钥 → 回执永远发不出去 → 控制端只能等到超时。
  /// 这正是"端点执行了却毫无回音"的根因。
  ///
  /// 安全边界（`msg.from` 不可信，一切以 payload 为准）：
  /// - **能解密即证明对方持有本机配对码**（密钥按接收方身份派生，见类文档），
  ///   因此本命令不需要额外的口令校验；
  /// - 但**绝不允许覆盖已配对控制端的 secret** —— 同 deviceId 且配对码不符
  ///   必须**拒绝**，否则任一已配对控制器都能顶掉另一台的配对记录，
  ///   从而**劫持**发给它的全部回执（提权面）；
  /// - 协助会话下**一律拒绝**：`RcPermGate.requiredPerm` 未登记 → `denyAll`
  ///   （协助对端**未配对**，不得借它把自己变成已配对设备）。
  ///
  /// 回执：`rc.ack {ok, for, data}`。
  static const pairRequest = 'pair.request';

  // ⚠️ 回执载荷以**端点实现**为准（`RcEndpointService` 的对应 case）；
  // 这里的注释曾长期与实现不符（C-9 文档漂移），已按实测改正。
  static const ping = 'ping'; // → rc.pong {device, at}
  static const statusGet =
      'status.get'; // → rc.status {engine, pendingCount, nextFireAt, version}
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
  /// device.status → rc.device {for, deviceName, batteryLevel, charging,
  ///                             version, pendingCount, nextFireAt}；
  /// camera.snap   → **恒** rc.ack{ok:false}（插件不兼容，v1.6 降级，
  ///                  **不产生** rc.photo，docs/16 §9 注记 / docs/22 §3 C-5）；
  /// location.get  → rc.location {for, lat, lng, acc}｜失败时
  ///                  {for, lat:null, lng:null, error:true}（C-1）；
  /// volume.set    → rc.ack
  static const deviceStatus = 'device.status';
  static const cameraSnap = 'camera.snap';
  static const locationGet = 'location.get';
  static const volumeSet = 'volume.set';

  /// `device.alert` → rc.ack。找回场景（Q9-B）：屏幕点亮 + 最大音量提示 + 通知横幅。
  /// payload：`message?`（锁屏提示文案，缺省用端点名）。需端点前台服务在跑；
  /// 原生未实现/被拒时如实 `ok=false`（不假成功）。
  static const deviceAlert = 'device.alert';

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

  // ---- v1.9：振动（docs/20 §10.2）----

  /// 停止端点**全部**进行中的振动：{} → rc.ack {stopped}
  ///
  /// 与 D1「持续振动不设时长硬上限」配套：上限换来的是**任何时刻都能停**，
  /// 本地有「停止振动」按钮，远程有本命令。它是让"不设上限"站得住的那半边。
  /// ⚠️ 不携带 taskId：停止是全局的，避免"停错了对象"这类静默失效。
  static const vibrateStop = 'vibrate.stop';
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
  static const device = 'rc.device'; // 设备状态快照（载荷见 deviceStatus）
  static const photo =
      'rc.photo'; // 拍照回传 {photoB64} —— **当前无发射方**（camera.snap 恒降级，C-5）
  static const location =
      'rc.location'; // 定位回传 {for, lat, lng, acc}｜失败 {for, error:true}
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

  /// v2 前置拉伸（Q1.B）：PBKDF2-HMAC-SHA256，`cryptography` 包默认实例
  /// 纯 Dart 实现（VM/移动端可用；Argon2id 虽在 `DartCryptography` 中存在，
  /// 但 PBKDF2 成本可预期且与本仓库 `ExportCrypto` 同族，选 PBKDF2）。
  static final Pbkdf2 _stretch = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 120000,
    bits: 256,
  );
  static final AesGcm _aes = AesGcm.with256bits();

  /// 由配对秘密派生消息密钥。
  /// [context]：`{endpointId}|cmd` 或 `{endpointId}|evt`——端点与控制器
  /// 双方都能派生同方向密钥（每个配对、每个方向独立密钥）。
  ///
  /// [salt]：每设备随机盐（Q1.B）。**兼容铁律**：
  /// - 无盐（null 或空）→ 原始 v1 路径（纯 HKDF），已配对端点继续可用；
  /// - 有盐 → 先 PBKDF2 前置拉伸，再把盐并入 HKDF salt 参数（v2）。
  /// 双方必须持有同一份盐：端点在配对登记时生成下发，控制端在配对成功
  /// 事件时落盘（见 `KdfSaltStore`）。
  static Future<List<int>> deriveKey(
    String secret,
    String context, {
    List<int>? salt,
  }) async {
    List<int> ikm = utf8.encode(secret);
    List<int> hkdfSalt = utf8.encode('sonicshield-rc-v1|$context');
    if (salt != null && salt.isNotEmpty) {
      final stretched = await _stretch.deriveKey(
        secretKey: SecretKey(utf8.encode(secret)),
        nonce: salt,
      );
      ikm = await stretched.extractBytes();
      // ⚠️ `utf8.encode` 返回**不可变** Uint8List，不能 `..addAll`（运行时炸
      // "Cannot add to a fixed-length list"）—— 必须新建可增长列表拼接。
      hkdfSalt = <int>[
        ...utf8.encode('sonicshield-rc-v2|$context'),
        ...salt,
      ];
    }
    final sk = await _alg.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: hkdfSalt,
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

  /// 配对码轮换（Q1.B）：生成与 [current] 同格式、**不与旧码相同**的新配对码。
  /// 纯函数：不做落盘/网络操作；持久化与 UI 入口由调用方负责。
  /// 比较时剥除 `-` 分隔符，杜绝新旧码仅分隔符位置不同的假轮换。
  static String rotatedPairingCode(String current) {
    const chars = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';
    final r = Random.secure();
    String gen() {
      final raw =
          List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
      return '${raw.substring(0, 4)}-${raw.substring(4)}';
    }

    final old = current.replaceAll('-', '');
    var next = gen();
    while (next.replaceAll('-', '') == old) {
      next = gen();
    }
    return next;
  }

  /// 生成 32 字节每设备随机盐（Q1.B）。Base64 落盘由 `KdfSaltStore` 负责。
  static List<int> newSalt() =>
      List.generate(32, (_) => Random.secure().nextInt(256));

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
  ///
  /// ⚠️ **BUG-075（第四十轮修）**：`deviceId` 与 `code` **都必须归一化到小写**。
  /// 此前只归一化了码（剥连字符 + 转大写），ID 原样保留 —— 而
  /// `_hex16` 明确接受大写、手输框的提示语又写"0-9 与 a-f"，
  /// 于是用户手抄成大写时：本机落盘成功、二维码/结果卡片都说"已配对"，
  /// 但 `deviceId` 是 **MQTT 主题段**（`sonicshield/v1/{deviceId}/cmd`，
  /// 大小写敏感）且是密钥派生的输入（`deriveKey(code, '{deviceId}|cmd')`）——
  /// 对端实际主题是小写（`generateDeviceId()` 恒小写，见上），
  /// 结果就是**命令永远发不出去、回执永远解不开**，且全程无任何报错。
  /// 归一化放在协议层（项目既定的"归一化只有协议层一处实现"），
  /// 使扫码与手输两条路径同时受益。
  static ({String deviceId, String name, String code})? parseUri(String uri) {
    if (!uri.startsWith(prefix)) return null;
    final parts = uri.substring(prefix.length).split('/');
    if (parts.length < 3) return null;
    final id = parts[0].toLowerCase();
    final name = Uri.decodeComponent(parts[1]);
    final code = parts[2].replaceAll('-', '').toUpperCase();
    if (id.length != 16 || code.length != 8) return null;
    return (deviceId: id, name: name, code: code);
  }
}
