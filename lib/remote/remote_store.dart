import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'node_catalog.dart';
import 'protocol.dart';

/// 已配对端点。
class PairedEndpoint {
  const PairedEndpoint({
    required this.deviceId,
    required this.name,
    required this.secret,
    required this.pairedAt,
    this.alias,
    this.lastConnectedAt,
  });

  final String deviceId;
  final String name;
  final String secret; // 配对秘密（本地保存；派生消息密钥用）
  final DateTime pairedAt;

  /// 备注名（「我的设备」列表用）。为空时展示 [name]。
  ///
  /// 为什么需要它：`name` 是**对端自报**的设备名，可能重复或不好认；
  /// 备注名是本机给这台设备起的别名，属于本机数据、不参与同步。
  final String? alias;

  /// 最近一次把该端点设为目标（"连接"）的时间。
  final DateTime? lastConnectedAt;

  /// 展示名（FR-77，第八十四轮用户明文）。
  ///
  /// 格式固定为 **`别名（远程机器真实名称）`** —— 用户明文：「本机更新远程机器
  /// 名称相当于为当机器取别名，显示为 `别名（远程机器真实名称）`，别名只在本机显示」。
  ///
  /// - 有别名：`别名（真名）`，便于本机辨认的同时**不丢失真名**（真名是对端上报的，
  ///   跨机一致，别才是本机的私有视角）；
  /// - 无别名：只显示 [name]（不加空括号，避免 `（设备）` 这种噪声）。
  String get displayName {
    final a = alias?.trim() ?? '';
    return a.isEmpty ? name : '$a（$name）';
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'secret': secret,
        'pairedAt': pairedAt.millisecondsSinceEpoch,
        if (alias != null) 'alias': alias,
        if (lastConnectedAt != null)
          'lastConnectedAt': lastConnectedAt!.millisecondsSinceEpoch,
      };

  static PairedEndpoint fromJson(Map<String, dynamic> j) => PairedEndpoint(
        deviceId: j['deviceId'] as String,
        name: j['name'] as String? ?? '未命名设备',
        secret: j['secret'] as String,
        pairedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['pairedAt'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch),
        alias: j['alias'] as String?,
        lastConnectedAt: (j['lastConnectedAt'] as num?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (j['lastConnectedAt'] as num).toInt()),
      );

  PairedEndpoint copyWith({
    String? deviceId,
    String? name,
    String? secret,
    DateTime? pairedAt,
    Object? alias = _sentinel,
    Object? lastConnectedAt = _sentinel,
  }) =>
      PairedEndpoint(
        deviceId: deviceId ?? this.deviceId,
        name: name ?? this.name,
        secret: secret ?? this.secret,
        pairedAt: pairedAt ?? this.pairedAt,
        // 用 sentinel 区分"不传"与"显式传 null"（清空备注）。
        alias: identical(alias, _sentinel) ? this.alias : alias as String?,
        lastConnectedAt: identical(lastConnectedAt, _sentinel)
            ? this.lastConnectedAt
            : lastConnectedAt as DateTime?,
      );
}

/// `copyWith` 的"未传值"哨兵：让 `copyWith(alias: null)` 能真正清空备注。
const Object _sentinel = Object();

/// 决定页面初始选中的端点：**优先全局已选**（且仍在配对表里），否则回落第一条。
///
/// 为什么抽成共享纯函数而不是各页各写一遍：写错了表现为
/// "在『我的设备』里选好的端点，切到控制台/对讲/指令组又变回第一条" ——
/// 这是**静默**错误（不报错、不崩溃），只能靠锁兜住。
///
/// 注意 `persisted` 可能指向**已被删除**的端点（用户在别处解配对），
/// 因此必须回配对表里核对，不能直接信任。
String initialSelectedId(List<PairedEndpoint> endpoints, String persisted) {
  if (endpoints.isEmpty) return '';
  if (persisted.isNotEmpty && endpointById(endpoints, persisted) != null) {
    return persisted;
  }
  return endpoints.first.deviceId;
}

/// 按 `deviceId` 找**已选中的端点**；找不到返回 **null**（不抛）。
///
/// ⚠️ 为什么不用 `firstWhere` 一行写完（BUG-060）：`firstWhere` 不带 `orElse`
/// 时找不到会抛 `Bad state: No element`。而"选中端点"是**跨页面共享的旧状态** ——
/// 用户在别处解配对、或配对表被清了，本页 `_selectedId` 仍是旧值，
/// 此时一点「发送 / 松开对讲 / 快捷指令」就**直接崩溃**，而且**没有任何提示**
/// （用户看到的是界面无响应或闪退，完全不知道是配对没了）。
///
/// 返回 null 让调用方有机会**明确告知**（"端点已不存在，可能已解配对"）——
/// 这既符合「点名了就必须满足，满足不了要失败」，也符合「失败必须留痕且让用户知道」：
/// **要失败，但不要崩。**
PairedEndpoint? endpointById(List<PairedEndpoint> endpoints, String deviceId) {
  if (deviceId.isEmpty) return null;
  for (final e in endpoints) {
    if (e.deviceId == deviceId) return e;
  }
  return null;
}

/// 远程遥控持久化状态（SharedPreferences，KV 简单可靠）。
class RemoteStore {
  RemoteStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kEnabled = 'rc_enabled';
  static const _kDeviceId = 'rc_device_id';
  static const _kDeviceName = 'rc_device_name';
  static const _kBroker = 'rc_broker';
  static const _kPaired = 'rc_paired';
  static const _kScripts = 'rc_scripts';
  static const _kOutbox = 'rc_outbox';
  static const _kPairCode = 'rc_pair_code';
  /// 已撤销授权的设备 id 列表（BUG-110）。
  ///
  /// 为什么需要它：配对码是**全体控制端共享**的，`removePaired` 只把设备移出
  /// 本机列表，拦不住它用旧码继续握手（`pair.request` 在准入里是**无条件放行**
  /// 的，见 `decideRcAdmission`）。这里记下"曾被本机撤销"的 id，
  /// 让**诚实自报身份**的被撤销方在配对握手这一步就被拒，
  /// 而不是靠"它自己不提 from"的运气。彻底吊销仍需轮换配对码
  /// （`rotatePairingCode` 会清空本表：新码 = 新的授权基线）。
  static const _kRevoked = 'rc_revoked';
  static const _kSelected = 'rc_selected_endpoint';

  // ---- v1.7 S5：可选 TURN 中继（docs/18 §S5） ----
  static const _kTurnUrl = 'rc_turn_url';
  static const _kTurnUser = 'rc_turn_user';
  static const _kTurnCred = 'rc_turn_cred';

  // ---- Q2.B：用户自带 broker（host/port/用户名/密码全配置化，默认仍公共） ----
  static const _kBrokerHost = 'rc_broker_host';
  static const _kBrokerPort = 'rc_broker_port';
  static const _kBrokerUser = 'rc_broker_user';
  static const _kBrokerPass = 'rc_broker_pass';

  // ---- 第八十二轮：预设节点下拉（MQTT 代理节点 / 通话 STUN 节点 / 传输方案） ----
  static const _kMqttNode = 'rc_mqtt_node';
  static const _kMqttNodePort = 'rc_mqtt_node_port';
  static const _kStunNode = 'rc_stun_node';
  static const _kTransport = 'rc_transport';

  /// 默认公共演示 broker（生产建议自建 EMQX/Mosquitto，docs/14 §6）。
  static const defaultBroker = 'broker.emqx.io';

  /// broker 端口：**TLS 8883**（C-13 P0，禁止回落明文 1883）。
  ///
  /// ## 为什么不给"明文开关"
  ///
  /// 业务载荷本身是 AES-256-GCM 端到端加密、broker 看不到内容 —— 但**明文端口
  /// 仍然泄露元数据**（谁与谁通信、消息长度与时序、`clientId`/主题里的设备 ID），
  /// 且信封可被链路上的中间人**篡改 / 丢弃 / 抑制**：重放有 90s 窗口 + 去重挡着，
  /// 而"把 `script.stop` 丢掉"这种攻击**没有任何防线**。
  ///
  /// 因此这里**刻意**不做成偏好项：没有"关闭 TLS"的运行时开关，
  /// 也就没有一条能在生产上悄悄回落到明文的路径（自建 broker 同样必须启用
  /// TLS，docs/14）。
  ///
  /// 真源是 [rcBrokerPort]（`protocol.dart`，无 Flutter 依赖）——
  /// 这样纯 Dart 的端到端工具能引用**同一个**常量，不会各写一个数字。
  /// 回归锁：`test/rc_transport_lock_test.dart`。
  static const defaultBrokerPort = rcBrokerPort;

  // ---------------- TURN 中继配置（S5） ----------------
  //
  // 为什么是"可选"：绝大多数家用网络靠 STUN 打洞即可直连；只有**双方都处于
  // 对称 NAT**（常见于 4G/5G 移动网络、企业网）时才必须走中继。
  // 内置公共 TURN 既不可靠也不合适（带宽/隐私），因此默认不配置，
  // 由使用者在自建服务器上填 —— 声盾不替使用者做中继选型。

  /// TURN 地址（如 `turn:example.com:3478`）；空串 = 未配置。
  String get turnUrl => _prefs.getString(_kTurnUrl) ?? '';

  String get turnUser => _prefs.getString(_kTurnUser) ?? '';

  String get turnCred => _prefs.getString(_kTurnCred) ?? '';

  /// 是否已配置可用的 TURN 中继。
  bool get turnConfigured => turnUrl.trim().isNotEmpty;

  /// 保存 TURN 配置（传空串即清除）。
  Future<void> setTurn({
    required String url,
    required String user,
    required String cred,
  }) async {
    await _prefs.setString(_kTurnUrl, url.trim());
    await _prefs.setString(_kTurnUser, user.trim());
    await _prefs.setString(_kTurnCred, cred);
  }

  bool get enabled => _prefs.getBool(_kEnabled) ?? false;
  Future<void> setEnabled(bool v) => _prefs.setBool(_kEnabled, v);

  String get deviceId => _prefs.getString(_kDeviceId) ?? '';
  String get deviceName => _prefs.getString(_kDeviceName) ?? '';

  /// MQTT 代理地址。
  ///
  /// 语义（Q2.B 后保持不变的部分）：未配置自定义 host 时返回**原公共地址**
  /// （`rc_broker` 或 [defaultBroker]）—— 默认行为与旧版一字不差。
  /// 配置了 [brokerHost] 时优先返回它（自建 broker 接管连接目标）。
  String get broker {
    final h = brokerHost.trim();
    if (h.isNotEmpty) return h; // 自建/高级优先（显式接管）
    final n = mqttNodeHost.trim();
    if (n.isNotEmpty) return n; // 预设节点下拉（第八十二轮）
    return _prefs.getString(_kBroker) ?? defaultBroker;
  }

  // ---------------- 用户自带 broker（Q2.B，全部可空） ----------------
  //
  // 为什么全部可空：四个字段都是「可选覆盖」—— 空/null 表示"用默认公共
  // broker（[defaultBroker]:[defaultBrokerPort]，无鉴权）"。不配置时行为
  // 与旧版完全一致，不产生任何迁移负担。
  //
  // 端口**不是**"关 TLS"的开关：无论连哪个 broker，传输都固定走 TLS
  // （C-13，回归锁 test/rc_transport_lock_test.dart TL-07）；自定义端口
  // 只是自建 broker 监听端口不同，没有明文回落路径。

  /// 自定义 broker 主机；空串 = 未配置（回落公共 broker）。
  String get brokerHost => _prefs.getString(_kBrokerHost) ?? '';

  /// 自定义 broker 端口；null = 未配置（回落 [defaultBrokerPort]，TLS 8883）。
  int? get brokerPort => _prefs.getInt(_kBrokerPort) ?? _prefs.getInt(_kMqttNodePort);

  /// broker 用户名（自建 broker 开启鉴权时填）；空串 = 未配置。
  String get brokerUsername => _prefs.getString(_kBrokerUser) ?? '';

  /// broker 密码；空串 = 未配置。明文落盘与 [turnCred] 同一信任级别
  /// （仅本机 SharedPreferences，不参与任何同步/上报）。
  String get brokerPassword => _prefs.getString(_kBrokerPass) ?? '';

  /// 保存自定义 broker 配置（`host` 传空串即整体清除、回到默认公共）。
  ///
  /// 端口传 null / 非正数即视为"未配置"，清除已存的端口（回落 TLS 8883）。
  /// 连接侧（读这四个字段并重连）由远程模块在下一次启动时完成 ——
  /// 因此 UI 上写明「保存后重启远程模块生效」。
  Future<void> setBrokerAdvanced({
    required String host,
    int? port,
    String username = '',
    String password = '',
  }) async {
    await _prefs.setString(_kBrokerHost, host.trim());
    if (port != null && port > 0) {
      await _prefs.setInt(_kBrokerPort, port);
    } else {
      await _prefs.remove(_kBrokerPort);
    }
    await _prefs.setString(_kBrokerUser, username.trim());
    await _prefs.setString(_kBrokerPass, password);
  }

  Future<void> setIdentity(String id, String name) async {
    await _prefs.setString(_kDeviceId, id);
    await _prefs.setString(_kDeviceName, name);
  }

  Future<void> setBroker(String v) => _prefs.setString(_kBroker, v);

  // ---------------- 预设节点（第八十二轮） ----------------

  /// 下拉选中的 MQTT 预设节点主机；空串 = 未选（回落 [defaultBroker]）。
  String get mqttNodeHost => _prefs.getString(_kMqttNode) ?? '';

  /// 下拉选中的 MQTT 预设节点端口；null = 未选（回落 [defaultBrokerPort]）。
  int? get mqttNodePort => _prefs.getInt(_kMqttNodePort);

  /// 选中一个 MQTT 预设节点（写 host + port）。传空 host 即清除、回落默认。
  Future<void> setMqttNode(String host, {int port = 8883}) async {
    final h = host.trim();
    if (h.isEmpty) {
      await _prefs.remove(_kMqttNode);
      await _prefs.remove(_kMqttNodePort);
      return;
    }
    await _prefs.setString(_kMqttNode, h);
    await _prefs.setInt(_kMqttNodePort, port);
  }

  /// 选中的 STUN 节点 URL（如 `stun:stun.qq.com:3478`）；空串 = 自动（全部并行）。
  String get stunSelectedUrl => _prefs.getString(_kStunNode) ?? '';

  /// 设置选中的 STUN 节点（传空串 = 回到「自动：全部并行」，默认行为不变）。
  Future<void> setStunSelectedUrl(String url) =>
      _prefs.setString(_kStunNode, url.trim());

  /// 选中的 MQTT **传输方案**（`tls` / `wss` / `quic`）；默认 `tls`。
  ///
  /// ⚠️ 这不是「关 TLS」开关：三种方案都要求加密（见 [RcTransport]）。
  RcTransport get transport =>
      RcTransport.parse(_prefs.getString(_kTransport));

  /// 设置传输方案（写 `rc_transport`）。
  Future<void> setTransport(RcTransport t) =>
      _prefs.setString(_kTransport, t.id);

  /// 本机配对码（共享秘密）：对端扫码后即持有该值，用于派生消息密钥。
  ///
  /// 密钥模型是**按接收方身份派生**的：发送方用「接收方 deviceId +
  /// 接收方配对码」加密，接收方用自己的配对码 + 自己的 deviceId 解密。
  /// 因此本机需要随时能取到自己的配对码（见 RcEndpointService._handleRaw）。
  String get pairingCode => _prefs.getString(_kPairCode) ?? '';

  /// 首次使用时生成并持久化（多台控制器可重复扫码配对本机）。
  Future<String> ensurePairingCode() async {
    var code = pairingCode;
    if (code.length != 8) {
      code = RcCodec.generatePairingCode().replaceAll('-', '');
      await _prefs.setString(_kPairCode, code);
    }
    return code;
  }

  /// 轮换本机配对码并持久化，返回新码（8 位、无连字符，与 [pairingCode] 同格式）。
  ///
  /// ⚠️ **密钥语义（docs/25 P1-10 要求先核对再动）**：入站命令由控制端用
  /// `deriveKey(本机配对码, '{本机ID}|cmd')` 加密（见 `endpoint_service` 入站解密），
  /// 因此本机配对码一变，**所有已配对控制器的旧密钥立即失效** —— 它们必须
  /// **重新扫码**才能再次遥控本机。这正是"重置"的意图（配对码疑似泄露时吊销），
  /// 所以 UI 必须二次确认并显式告知；出站事件反向派生（用**控制器**的配对码），
  /// 不受本机码轮换影响，故端点仍能收到旧控制器的回执请求。
  ///
  /// 只做落盘，不碰网络：刷新接收侧缓存由
  /// `RcEndpointService.rotateOwnPairingCode` 负责（否则"扫完即失联"）。
  Future<String> rotatePairingCode() async {
    final next = RcCodec.rotatedPairingCode(pairingCode).replaceAll('-', '');
    await _prefs.setString(_kPairCode, next);
    // BUG-110：新码 = 新的授权基线。旧码派生出的所有密钥已失效，
    // 撤销名单随之作废（否则被撤销的设备换了新码也永远配不上）。
    await clearRevoked();
    return next;
  }

  /// 读取配对表。
  ///
  /// **始终返回可变的新列表**（含空表）。历史上空表返回 `const []`，
  /// 而调用方习惯写 `paired()..removeWhere(...)` 的级联 —— 在不可变列表上
  /// 级联修改会抛 `Unsupported operation: Cannot remove from an unmodifiable
  /// list`，症状是**首次配对（空表）必然失败**，且因为没有 try/catch，
  /// 表现为"扫了码但界面毫无反应、也没有报错"（BUG-031）。
  List<PairedEndpoint> paired() {
    final raw = _prefs.getString(_kPaired);
    if (raw == null || raw.isEmpty) return <PairedEndpoint>[];
    try {
      return ((jsonDecode(raw) as List).cast<Map<String, dynamic>>())
          .map(PairedEndpoint.fromJson)
          .toList();
    } on Object {
      return <PairedEndpoint>[];
    }
  }

  Future<void> addPaired(PairedEndpoint e) async {
    final list = paired();
    final i = list.indexWhere((p) => p.deviceId == e.deviceId);
    if (i >= 0) {
      // 同 deviceId 视为重新配对：**原位覆盖**而非追加。
      // 追加会让该端点跑到列表末尾，而控制台默认选中 `paired().first` ——
      // 于是"重新扫一次码"会悄悄换掉控制台的默认目标设备。
      list[i] = e;
    } else {
      list.add(e);
    }
    await _prefs.setString(
        _kPaired, jsonEncode(list.map((p) => p.toJson()).toList()));
  }

  /// 解除配对：把该 deviceId 移出本机配对表（**授权撤销的唯一真源**）。
  ///
  /// ⚠️ 只删列表**不足以**撤销授权 —— 它必须同时让该 deviceId 的后续入站
  /// 命令被**拒绝**。这一半由端点侧的准入裁决承担（`RcEndpointService._handleRaw`
  /// → `decideRcAdmission`：发送方必须在**当前**配对表里，否则拒收并写审计）。
  /// 本方法落盘之后，端点侧收到的下一条来自该 deviceId 的命令就会被拒 ——
  /// 因此**不要在别处"只删列表"而不接准入**，那正是 P0「配对移出了列表、
  /// 对方仍能控制本机」的形状（A3 §2「撤销」）。
  Future<void> removePaired(String deviceId) async {
    final list = [
      ...paired().where((p) => p.deviceId != deviceId),
    ];
    await _prefs.setString(
        _kPaired, jsonEncode(list.map((p) => p.toJson()).toList()));
    // 删掉的若正是当前目标，清空选择（否则列表里会出现"选中了一个不存在的端点"）。
    if (selectedEndpointId == deviceId) await selectEndpoint('');
    // BUG-110：同时登记"已撤销"，让它的配对握手请求在准入层就被拒。
    if (deviceId.isNotEmpty) await revoke(deviceId);
  }

  // ---------------- 授权撤销（BUG-110） ----------------

  /// 已撤销授权的设备 id（**新列表**，调用方可安全修改）。
  List<String> revokedIds() {
    final raw = _prefs.getString(_kRevoked);
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      return (jsonDecode(raw) as List).map((e) => '$e').toList();
    } on Object {
      // 存储被写坏时**不放行**也不崩：按空表处理，等下一次撤销重建。
      return <String>[];
    }
  }

  bool isRevoked(String deviceId) =>
      deviceId.isNotEmpty && revokedIds().contains(deviceId);

  /// 登记撤销（幂等）。
  Future<void> revoke(String deviceId) async {
    if (deviceId.isEmpty) return;
    final list = revokedIds();
    if (list.contains(deviceId)) return;
    list.add(deviceId);
    await _prefs.setString(_kRevoked, jsonEncode(list));
  }

  /// 清空撤销表（轮换配对码后调用：新码即新的授权基线）。
  Future<void> clearRevoked() async {
    await _prefs.remove(_kRevoked);
  }

  // ---------------- 「我的设备」列表（向日葵式：保存连接 + 快速连接） ----------------

  /// 当前目标端点（**跨页面共享且持久化**）。
  ///
  /// 为什么必须落到存储而不是各页自己的 `State`：
  /// 此前 `_selectedId` 是**每个 TAB 各自的局部状态**，在「设备」页选好的端点
  /// 切到「对讲」「指令组」就丢了 —— 使用者每次都要重新选，也就谈不上
  /// "快速连接各个设备"。统一存这里，各页初始化时读取即可。
  String get selectedEndpointId => _prefs.getString(_kSelected) ?? '';

  /// 只改"当前选择"，**不**记连接时间（下拉框换目标属于这一类）。
  Future<void> setSelectedEndpoint(String deviceId) =>
      _prefs.setString(_kSelected, deviceId);

  /// 快速连接：设为当前目标**并**写入"最近连接时间"。
  ///
  /// 传入空串 = 取消选择。
  Future<void> selectEndpoint(String deviceId) async {
    await setSelectedEndpoint(deviceId);
    if (deviceId.isNotEmpty) await touchPaired(deviceId);
  }

  /// 写"最近连接时间"。端点不存在时**静默忽略**
  /// （这是记账信息，不该让它影响主流程）。
  Future<void> touchPaired(String deviceId) async {
    final list = paired();
    final i = list.indexWhere((p) => p.deviceId == deviceId);
    if (i < 0) return;
    list[i] = list[i].copyWith(lastConnectedAt: DateTime.now());
    await _prefs.setString(
        _kPaired, jsonEncode(list.map((p) => p.toJson()).toList()));
  }

  /// 改备注名。端点不存在时**静默忽略**。
  Future<void> renamePaired(String deviceId, String alias) async {
    final list = paired();
    final i = list.indexWhere((p) => p.deviceId == deviceId);
    if (i < 0) return;
    list[i] = list[i].copyWith(alias: alias.trim().isEmpty ? null : alias);
    await _prefs.setString(
        _kPaired, jsonEncode(list.map((p) => p.toJson()).toList()));
  }
}

/// 已保存的指令组模板（收藏）。
class SavedScript {
  const SavedScript({
    required this.id,
    required this.name,
    required this.payload,
    required this.savedAt,
  });

  final String id;
  final String name;
  final Map<String, dynamic> payload; // script.run payload
  final DateTime savedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'payload': payload,
        'savedAt': savedAt.millisecondsSinceEpoch,
      };

  static SavedScript fromJson(Map<String, dynamic> j) => SavedScript(
        id: j['id'] as String,
        name: j['name'] as String? ?? '指令组',
        payload: (j['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        savedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['savedAt'] as num?)?.toInt() ?? 0),
      );
}

extension RemoteStoreScripts on RemoteStore {
  List<SavedScript> savedScripts() {
    final raw = _prefs.getString(RemoteStore._kScripts);
    if (raw == null || raw.isEmpty) return [];
    try {
      return ((jsonDecode(raw) as List).cast<Map<String, dynamic>>())
          .map(SavedScript.fromJson)
          .toList();
    } on Object {
      return [];
    }
  }

  Future<void> saveScript(SavedScript s) async {
    final list = savedScripts()..removeWhere((p) => p.id == s.id);
    list.insert(0, s);
    await _prefs.setString(RemoteStore._kScripts,
        jsonEncode(list.map((p) => p.toJson()).toList()));
  }

  Future<void> deleteScript(String id) async {
    final list = savedScripts()..removeWhere((p) => p.id == id);
    await _prefs.setString(RemoteStore._kScripts,
        jsonEncode(list.map((p) => p.toJson()).toList()));
  }

  // ---------- 离线 outbox（v1.3：端点离线时命令暂存，上线冲刷） ----------

  List<Map<String, dynamic>> outbox() {
    final raw = _prefs.getString(RemoteStore._kOutbox);
    if (raw == null || raw.isEmpty) return [];
    try {
      // 必须返回可变列表：enqueue/drain 会就地增删（压测发现的 BUG-012）。
      return ((jsonDecode(raw) as List).cast<Map<String, dynamic>>()).toList();
    } on Object {
      return [];
    }
  }

  /// 队列硬上限（P2-21）：超过时丢弃**最旧**的条目。
  static const int maxOutboxEntries = 200;

  /// 入队一条待发密文。
  ///
  /// [ttlMs]（P1-15）：该条目的新鲜度窗口（毫秒）。> 0 时写入 `expiresAt`
  /// （`at + ttlMs`），补发路径据此判定"是否还值得补发"；`null`/`0` 表示
  /// 无 TTL（恒可补发，兼容旧调用与测试）。
  ///
  /// 返回**被超限丢弃的条目**（P2-21）：此前是**静默** `removeRange`，
  /// 于是"队列满了、最旧那条被挤掉"完全不留痕 —— 使用者只看到"命令没执行"。
  /// 调用方拿到非空列表后**必须**写审计，绝不静默丢命令。
  Future<List<Map<String, dynamic>>> enqueue(String wire, String endpointId,
      {int? ttlMs}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = outbox()
      ..add({
        'id': _newOutboxId(),
        'endpointId': endpointId,
        'wire': wire,
        'at': now,
        if (ttlMs != null && ttlMs > 0) 'expiresAt': now + ttlMs,
      });
    final dropped = <Map<String, dynamic>>[];
    if (list.length > maxOutboxEntries) {
      final n = list.length - maxOutboxEntries;
      dropped.addAll(list.take(n));
      list.removeRange(0, n);
    }
    await _prefs.setString(RemoteStore._kOutbox, jsonEncode(list));
    return dropped;
  }

  static String _newOutboxId() =>
      'o${DateTime.now().microsecondsSinceEpoch}'
      '_${Random.secure().nextInt(1 << 32)}';

  List<Map<String, dynamic>> drainOutbox(String endpointId) {
    final all = outbox();
    final mine = all.where((m) => m['endpointId'] == endpointId).toList();
    if (mine.isEmpty) return const [];
    _prefs.setString(RemoteStore._kOutbox,
        jsonEncode(all.where((m) => m['endpointId'] != endpointId).toList()));
    return mine;
  }

  /// 某端点的待发命令（**只读**，不删除任何条目）。
  ///
  /// ⚠️ 与 [drainOutbox] 的区别是本方法**不取走**。补发路径必须用它 ——
  /// [drainOutbox] 是"取走即删"，一旦补发中途失败（连接断了、密文损坏、
  /// 进程被杀），命令就**永久消失**，而 UI 上写着"端点上线后自动执行"。
  /// 只读读取 + 成功后才 [removeOutbox]，才能保证"没发出去就还在"。
  List<Map<String, dynamic>> outboxFor(String endpointId) =>
      outbox().where((m) => m['endpointId'] == endpointId).toList();

  /// 删除某端点的**指定**待发命令（补发成功后才调用）。
  ///
  /// 只删 [sent] 里列出的条目，**不碰**同端点的其它条目；`sent` 为空时不写盘。
  Future<void> removeOutbox(
      String endpointId, List<Map<String, dynamic>> sent) async {
    if (sent.isEmpty) return;
    final keys = {for (final m in sent) outboxKeyOf(m)};
    final rest = outbox()
        .where((m) =>
            m['endpointId'] != endpointId || !keys.contains(outboxKeyOf(m)))
        .toList();
    await _prefs.setString(RemoteStore._kOutbox, jsonEncode(rest));
  }
}

/// 一条待发命令的稳定标识（同一端点内唯一）。
///
/// 优先用 [enqueue] 写入的 `id`：`at`（毫秒）+ `wire` 在同毫秒内重复发送
/// 同一条命令时会**碰撞** —— 那时按 key 删会一次删掉两条，
/// 把"还没发出去的那条"也抹掉（正是本模块要杜绝的丢命令）。
/// 老数据没有 `id`，退回 `at|wire`（可接受：那只影响升级前残留的条目）。
///
/// 放在**顶层**而不是 extension 的静态成员：Dart 的扩展静态成员无法通过
/// `RemoteStore.xxx` 访问，调用点会变得别扭且容易写错。
String outboxKeyOf(Map<String, dynamic> m) {
  final id = m['id'];
  return id is String && id.isNotEmpty ? id : '${m['at']}|${m['wire']}';
}

/// 一条待发命令的新鲜度截止时刻（毫秒）；无 `expiresAt` 返回 null（P1-15）。
///
/// 老数据（升级前写入）没有该字段 ⇒ null ⇒ 视为"无 TTL"。这条兼容是刻意的：
/// 不能因为升级而把历史暂存命令一次性判为过期丢掉。
int? outboxExpiresAtOf(Map<String, dynamic> m) {
  final v = m['expiresAt'];
  return v is num ? v.toInt() : null;
}
