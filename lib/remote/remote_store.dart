import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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

  /// 展示名：备注优先，回落对端自报名。
  String get displayName {
    final a = alias?.trim() ?? '';
    return a.isEmpty ? name : a;
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
  static const _kSelected = 'rc_selected_endpoint';

  // ---- v1.7 S5：可选 TURN 中继（docs/18 §S5） ----
  static const _kTurnUrl = 'rc_turn_url';
  static const _kTurnUser = 'rc_turn_user';
  static const _kTurnCred = 'rc_turn_cred';

  /// 默认公共演示 broker（生产建议自建 EMQX/Mosquitto，docs/14 §6）。
  static const defaultBroker = 'broker.emqx.io';

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
  String get broker => _prefs.getString(_kBroker) ?? defaultBroker;

  Future<void> setIdentity(String id, String name) async {
    await _prefs.setString(_kDeviceId, id);
    await _prefs.setString(_kDeviceName, name);
  }

  Future<void> setBroker(String v) => _prefs.setString(_kBroker, v);

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

  Future<void> removePaired(String deviceId) async {
    final list = [
      ...paired().where((p) => p.deviceId != deviceId),
    ];
    await _prefs.setString(
        _kPaired, jsonEncode(list.map((p) => p.toJson()).toList()));
    // 删掉的若正是当前目标，清空选择（否则列表里会出现"选中了一个不存在的端点"）。
    if (selectedEndpointId == deviceId) await selectEndpoint('');
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
    if (raw == null || raw.isEmpty) return const [];
    try {
      return ((jsonDecode(raw) as List).cast<Map<String, dynamic>>())
          .map(SavedScript.fromJson)
          .toList();
    } on Object {
      return const [];
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

  Future<void> enqueue(String wire, String endpointId) async {
    final list = outbox()
      ..add({
        'endpointId': endpointId,
        'wire': wire,
        'at': DateTime.now().millisecondsSinceEpoch
      });
    if (list.length > 200) list.removeRange(0, list.length - 200);
    await _prefs.setString(RemoteStore._kOutbox, jsonEncode(list));
  }

  List<Map<String, dynamic>> drainOutbox(String endpointId) {
    final all = outbox();
    final mine = all.where((m) => m['endpointId'] == endpointId).toList();
    if (mine.isEmpty) return const [];
    _prefs.setString(RemoteStore._kOutbox,
        jsonEncode(all.where((m) => m['endpointId'] != endpointId).toList()));
    return mine;
  }
}
