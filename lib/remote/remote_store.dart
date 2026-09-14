import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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

  /// 默认公共演示 broker（生产建议自建 EMQX/Mosquitto，docs/14 §6）。
  static const defaultBroker = 'broker.emqx.io';

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

  List<PairedEndpoint> paired() {
    final raw = _prefs.getString(_kPaired);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return ((jsonDecode(raw) as List).cast<Map<String, dynamic>>())
          .map(PairedEndpoint.fromJson)
          .toList();
    } on Object {
      return const [];
    }
  }

  Future<void> addPaired(PairedEndpoint e) async {
    final list = [...paired()..removeWhere((p) => p.deviceId == e.deviceId), e];
    await _prefs.setString(
        _kPaired, jsonEncode(list.map((p) => p.toJson()).toList()));
  }

  Future<void> removePaired(String deviceId) async {
    final list = paired()..removeWhere((p) => p.deviceId == deviceId);
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
