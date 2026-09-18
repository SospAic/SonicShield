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
  });

  final String deviceId;
  final String name;
  final String secret; // 配对秘密（本地保存；派生消息密钥用）
  final DateTime pairedAt;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'secret': secret,
        'pairedAt': pairedAt.millisecondsSinceEpoch,
      };

  static PairedEndpoint fromJson(Map<String, dynamic> j) => PairedEndpoint(
        deviceId: j['deviceId'] as String,
        name: j['name'] as String? ?? '未命名设备',
        secret: j['secret'] as String,
        pairedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['pairedAt'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch),
      );
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
