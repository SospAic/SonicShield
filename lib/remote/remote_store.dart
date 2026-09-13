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
      return ((jsonDecode(raw) as List) as List<Map<String, dynamic>>)
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
