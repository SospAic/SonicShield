import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'protocol.dart';
import 'rc_script.dart';

/// 临时协助会话（v1.7，docs/18）——「临时码 + 访问密码」。
///
/// 与二维码配对（docs/14 §7.5）的关系：两者共用同一套 MQTT E2EE 与命令集，
/// 差异仅在**密钥来源与生命周期**。本模块只负责凭据、会合主题与会话密钥，
/// 不含任何 UI 与网络逻辑，便于纯单测覆盖。
///
/// ## 安全核心：密码认证会合主题
///
/// `topic = "sonicshield/v1/assist/" + hex(SHA-256(code|pw))[0:16]`
///
/// 只窃听到 [code] 的攻击者**无法算出 topic**，因此无法订阅、拿不到握手密文，
/// 也就**不存在可供离线字典攻击的素材**；想算出 topic 必须先猜中密码，
/// 而猜中密码本就能正常接入 —— 天然具备 PAKE 式「不可离线攻击」性质。
/// 若改为直接用 code 做 topic（厂商常见做法），攻击者可枚举 30 bit 的 topic
/// 长期收集密文再离线爆破，本设计从根上消除该路径。
///
/// ## 合规（docs/08 红线，不可协商）
///
/// 临时码只能在**端点屏幕**生成、必须由端点使用者**主动告知**控制端，
/// 与「物理在场扫码」等价，属**明示同意**。因此本模块：
/// - 不提供任何「控制端唤醒端点建会话」的入口（会话只能端点侧发起，C1）；
/// - 会话 TTL 有限、一次性、不落盘明文（C4）；
/// - 权限默认全拒（C5）。
abstract final class RcAssist {
  RcAssist._();

  static const topicPrefix = 'sonicshield/v1/assist/';

  /// 会话默认有效期（C4：一次性 + 短 TTL）。
  static const defaultTtl = Duration(minutes: 10);

  /// 同一会话允许的握手失败次数，超过即作废（防在线猜测）。
  static const maxFailures = 5;

  /// 会话密钥 HKDF 的 salt 前缀（版本化，便于日后轮换）。
  static const _kdfSaltPrefix = 'sonicshield-assist-v1|';

  static const _codeDigits = 9;

  /// Crockford Base32（去 I/L/O/U 等易混字符），与配对码同族。
  static const _pwAlphabet = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';

  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final Sha256 _sha = Sha256();

  // ---------------- 凭据 ----------------

  /// 临时码：9 位数字（ToDesk 式，便于口述）。**公开**，不构成安全边界。
  static String generateCode() {
    final r = Random.secure();
    return List.generate(_codeDigits, (_) => r.nextInt(10).toString()).join();
  }

  /// 访问密码：8 位 Crockford Base32（≈40 bit），**真正的共享秘密**。
  static String generatePassword() {
    final r = Random.secure();
    return List.generate(8, (_) => _pwAlphabet[r.nextInt(_pwAlphabet.length)])
        .join();
  }

  /// 归一化用户输入：去除空格/连字符/分隔符。
  static String normalizeCode(String raw) =>
      raw.replaceAll(RegExp(r'[^0-9]'), '');

  /// 归一化密码：去分隔符 + 转大写 + 剔除字母表外字符。
  ///
  /// 本字母表（同 `RcCodec.generatePairingCode`）已排除 I/L/O/U/0/1 等易混字符，
  /// 因此**不做** Crockford 标准的 O→0 / I→1 字形纠正——那些目标字符本身
  /// 就不在字母表内，纠正反而会产出非法字符。误读风险由展示层承担：
  /// 等宽字体 + 加大字距 + 分组显示。
  static String normalizePassword(String raw) {
    final s = raw.replaceAll(RegExp(r'[\s\-_]'), '').toUpperCase();
    return s.split('').where(_pwAlphabet.contains).join();
  }

  /// 临时码是否合法（长度精确匹配且全数字）。
  static bool isValidCode(String code) =>
      code.length == _codeDigits && RegExp(r'^[0-9]+$').hasMatch(code);

  /// 密码是否合法（长度精确匹配且全在字母表内）。
  static bool isValidPassword(String pw) =>
      pw.length == 8 && pw.split('').every(_pwAlphabet.contains);

  // ---------------- 会合主题 ----------------

  /// 由 临时码 + 密码 派生会合主题（见类文档「安全核心」）。
  ///
  /// 返回 `sonicshield/v1/assist/<16 位十六进制>`。
  static Future<String> topicFor(String code, String password) async {
    final digest = await _sha.hash(utf8.encode('$code|$password'));
    final hex =
        digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$topicPrefix${hex.substring(0, 16)}';
  }

  // ---------------- 会话密钥 ----------------

  /// 会话主密钥：HKDF(ikm = 密码, salt = 版本|临时码, info = "assist")。
  static Future<List<int>> sessionSecret(String code, String password) async {
    final sk = await _hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: utf8.encode('$_kdfSaltPrefix$code'),
      info: utf8.encode('assist'),
    );
    return sk.extractBytes();
  }

  /// 控制端 → 端点 方向密钥。
  static Future<List<int>> ctlKey(String code, String password) =>
      _directionKey(code, password, 'ctl');

  /// 端点 → 控制端 方向密钥。
  static Future<List<int>> epKey(String code, String password) =>
      _directionKey(code, password, 'ep');

  static Future<List<int>> _directionKey(
      String code, String password, String direction) async {
    final secret = await sessionSecret(code, password);
    final sk = await _hkdf.deriveKey(
      secretKey: SecretKey(secret),
      nonce: utf8.encode('$_kdfSaltPrefix$direction'),
      info: utf8.encode('assist-$direction'),
    );
    return sk.extractBytes();
  }
}

/// 协助会话状态机。
enum AssistPhase {
  /// 端点已生成凭据，等待控制端接入。
  waiting,

  /// 控制端已发起 hello，端点校验中。
  opening,

  /// 会话已建立。
  active,

  /// 已结束（任一方终止 / TTL 到期 / 失败超限）。
  closed,
}

/// 会话权限位（对标 RustDesk 权限系统）。
///
/// **默认全 false**（C5）：会话建立时不放行任何能力，
/// 必须由端点使用者逐项显式开启。
class AssistPerms {
  const AssistPerms({
    this.media = false,
    this.tts = false,
    this.vibrate = false,
    this.volume = false,
    this.location = false,
    this.video = false,
    this.script = false,
    this.audit = false,
  });

  /// 音效播放（sound.play / 指令组 play 步骤）。
  final bool media;

  /// TTS 喊话。
  final bool tts;

  /// 震动。
  final bool vibrate;

  /// 音量调节。
  final bool volume;

  /// 定位回传。
  final bool location;

  /// 视频通话。
  final bool video;

  /// 指令组（宏）执行。
  final bool script;

  /// 读取本机审计日志（`logs.recent`）。
  ///
  /// 单独成位而非复用 `script`：审计日志会回传端点的操作轨迹（谁在何时做了什么），
  /// 是**敏感只读**数据。若把它留在"免授权"清单里，一个未放行任何权限的对端
  /// 就能读取端点审计历史 —— 与"默认全拒"的承诺矛盾。
  final bool audit;

  static const none = AssistPerms();

  AssistPerms copyWith({
    bool? media,
    bool? tts,
    bool? vibrate,
    bool? volume,
    bool? location,
    bool? video,
    bool? script,
    bool? audit,
  }) =>
      AssistPerms(
        media: media ?? this.media,
        tts: tts ?? this.tts,
        vibrate: vibrate ?? this.vibrate,
        volume: volume ?? this.volume,
        location: location ?? this.location,
        video: video ?? this.video,
        script: script ?? this.script,
        audit: audit ?? this.audit,
      );

  Map<String, dynamic> toJson() => {
        'media': media,
        'tts': tts,
        'vibrate': vibrate,
        'volume': volume,
        'location': location,
        'video': video,
        'script': script,
        'audit': audit,
      };

  static AssistPerms fromJson(Map<String, dynamic> j) => AssistPerms(
        media: j['media'] as bool? ?? false,
        tts: j['tts'] as bool? ?? false,
        vibrate: j['vibrate'] as bool? ?? false,
        volume: j['volume'] as bool? ?? false,
        location: j['location'] as bool? ?? false,
        video: j['video'] as bool? ?? false,
        script: j['script'] as bool? ?? false,
        audit: j['audit'] as bool? ?? false,
      );

  /// 人类可读（UI 展示）。
  static const labels = <String, String>{
    'media': '播放音效',
    'tts': '语音喊话',
    'vibrate': '震动',
    'volume': '调节音量',
    'location': '获取定位',
    'video': '视频通话',
    'script': '执行指令组',
    'audit': '查看审计日志',
  };

  /// 按位名读取（键名同 [labels]）。
  bool flag(String key) => (toJson()[key] as bool?) ?? false;

  /// 按位名写入；未登记的键名原样返回（不新增权限位，失败关闭）。
  AssistPerms withFlag(String key, bool value) => switch (key) {
        'media' => copyWith(media: value),
        'tts' => copyWith(tts: value),
        'vibrate' => copyWith(vibrate: value),
        'volume' => copyWith(volume: value),
        'location' => copyWith(location: value),
        'video' => copyWith(video: value),
        'script' => copyWith(script: value),
        'audit' => copyWith(audit: value),
        _ => this,
      };
}

/// 端点侧的一条活动协助会话（内存态，**不落盘**——C4）。
class AssistSession {
  AssistSession({
    required this.code,
    required this.password,
    required this.topic,
    required this.expiresAt,
    this.sessionId = '',
    this.ctrlName = '',
    this.phase = AssistPhase.waiting,
    this.perms = AssistPerms.none,
    this.failures = 0,
  });

  final String code;
  final String password;
  final String topic;
  final DateTime expiresAt;

  String sessionId;

  /// 控制端显示名（端点横幅展示「正在被 X 协助」——C2）。
  String ctrlName;
  AssistPhase phase;
  AssistPerms perms;

  /// 握手失败计数（防在线猜测）。
  int failures;

  bool get expired => DateTime.now().isAfter(expiresAt);
  bool get locked => failures >= RcAssist.maxFailures;
  bool get usable => !expired && !locked && phase != AssistPhase.closed;

  Duration get remaining {
    final d = expiresAt.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  /// 失败一次；返回是否已达上限。
  bool registerFailure() {
    failures++;
    if (locked) phase = AssistPhase.closed;
    return locked;
  }
}

/// 协助协议消息类型（docs/18 §7）。
abstract final class RcAssistCmd {
  static const hello = 'assist.hello'; // 控制端 → 端点
  static const accept = 'assist.accept'; // 端点 → 控制端
  static const reject = 'assist.reject'; // 端点 → 控制端
  static const perm = 'assist.perm'; // 端点 → 控制端（权限位变更）
  static const close = 'assist.close'; // 双向
  // 注：曾经这里有一个「会话状态镜像」常量（rc.assist）。全仓除定义外只有
  // 一条测试断言其字面量，**没有任何生产侧发出/消费** —— 一个从不发出的常量
  // 比没有更糟：它让人以为"状态镜像已实现"。已删除；若日后要真正做状态镜像，
  // 应连同控制端的消费方一起提交，而不是先放一个常量。

  /// 是否为**会话控制类**消息（`assist.*`）。
  ///
  /// 非控制类即**业务命令** —— 会话建立后复用 v1 命令集
  /// （`sound.play` / `task.upsert` / `call.invite`…），
  /// 它们必须逐条过权限门控后才允许执行。
  static bool isControl(String type) => type.startsWith('assist.');
}

/// 权限门控：命令/指令组步骤 → 所需权限位。
///
/// **放在协议层而非端点侧**：控制端需要同一张映射表来灰化未授权按钮，
/// 端点侧需要它来拒绝越权命令。两处各写一份必然漂移 ——
/// 漂移的后果是"按钮可点但命令被拒"或更糟的"按钮灰着但其实能发"。
abstract final class RcPermGate {
  RcPermGate._();

  /// 未登记命令的哨兵权限名：任何 [AssistPerms] 都不会为 true。
  static const denyAll = '__unmapped__';

  /// 命令 → 所需权限位。返回 null 表示**只读/无害**，无需授权。
  ///
  /// 判定原则：**只读取状态放行，任何会作用于端点设备或改写其持久状态的
  /// 命令都必须先拿到对应权限位**。未列出的命令一律拒绝（默认拒绝，
  /// 而非默认放行）—— 新增命令忘记登记时应当失败关闭。
  static String? requiredPerm(String cmd) => switch (cmd) {
        // 只读：会话存活与 UI 渲染所必需
        RcCmd.ping ||
        RcCmd.statusGet ||
        RcCmd.deviceStatus ||
        RcCmd.taskList ||
        RcCmd.taskGet ||
        RcCmd.assetList ||
        RcCmd.presetList ||
        RcCmd.planGet =>
          null,
        // 审计日志读取：会回传端点的操作轨迹（谁在何时做了什么），是敏感只读面。
        // 此前它与 ping/status 同列"免授权"，等于未放行任何权限的对端也能读审计 ——
        // 与"默认全拒"直接矛盾（P2-1）。现要求独立的 `audit` 位。
        RcCmd.logsRecent => 'audit',
        // 出声 / 改音量
        RcCmd.soundPlay || RcCmd.pttVoice => 'media',
        RcCmd.volumeSet => 'volume',
        // 找回告警（Q9-B）：会点亮屏幕 + 最大音量提示，与"出声"同级敏感，
        // 要求 media 位 —— 能让端点出声的对端才能点亮屏幕喊话。
        RcCmd.deviceAlert => 'media',
        // v1.9：停止振动只会**减弱**端点正在做的事，但仍要求 `vibrate` 位 ——
        // 本工具是自我保护用途，让没有振动权限的对端停掉用户自己的报警振动
        // 同样是不可接受的。能震的才能停。
        RcCmd.vibrateStop => 'vibrate',
        // v2.x：远程**发起**振动与停止同为 `vibrate` 位 —— "能震的才能停、
        // 能停的也就能震"，两条命令是同一件事的两端，权限不该劈成两半。
        RcCmd.vibrateStart => 'vibrate',
        // 隐私
        RcCmd.locationGet => 'location',
        RcCmd.cameraSnap => 'video',
        // 摄像头/麦克风通话
        RcCmd.callInvite ||
        RcCmd.callAnswer ||
        RcCmd.callCandidate ||
        RcCmd.callEnd =>
          'video',
        // 宏执行与持久自动化改写
        RcCmd.scriptRun ||
        RcCmd.scriptStop ||
        RcCmd.taskRunNow ||
        RcCmd.taskToggle ||
        RcCmd.taskSkipNext ||
        RcCmd.taskUpsert ||
        RcCmd.taskDelete ||
        RcCmd.guardSet ||
        RcCmd.planApply ||
        RcCmd.planStop ||
        RcCmd.runMasterSet =>
          'script',
        _ => denyAll,
      };

  /// 该权限位是否已放行。
  static bool hasPerm(AssistPerms p, String perm) => switch (perm) {
        'media' => p.media,
        'tts' => p.tts,
        'vibrate' => p.vibrate,
        'volume' => p.volume,
        'location' => p.location,
        'video' => p.video,
        'script' => p.script,
        'audit' => p.audit,
        _ => false, // 含 [denyAll]
      };

  /// 该命令在当前权限下是否可执行。
  static bool allows(AssistPerms p, String cmd) {
    final need = requiredPerm(cmd);
    return need == null || hasPerm(p, need);
  }

  /// 指令组步骤 → 所需权限位。
  ///
  /// `record`（录音取证）**在协助会话下一律拒绝**：权限位模型里没有对应位，
  /// 而录音是高度敏感的隐私操作 —— 按"未登记即拒绝"原则保守处理，
  /// 待引入独立 `record` 权限位后再评估放行（docs/18 §10）。
  static String? requiredStepPerm(RcStepKind kind) => switch (kind) {
        RcStepKind.play => 'media',
        RcStepKind.tts => 'tts',
        RcStepKind.vibrate => 'vibrate',
        RcStepKind.delay || RcStepKind.notify => null,
        RcStepKind.record => denyAll,
      };
}
