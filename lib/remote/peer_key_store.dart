import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 每控制端密钥（`peerKey`）的**端点侧**存储（REM-01 根治，v3）。
///
/// ## 为什么需要它
///
/// 旧模型的"钥匙"是**本机 8 位配对码**：全体控制端共享、撤销时不改变 ⇒
/// 用户点「删除设备」只从列表里少了一行，对方手里的钥匙完好无损。
/// 现在配对成功时由**端点**为每个控制端生成 32 字节随机 `peerKey`，
/// 随 ack 下发；此后该控制端的命令用它加密。
///
/// `removePaired(id)` 删掉这里的这一把 ⇒ 旧密文**永久解不开** ——
/// 这才是"撤销 = 凭据级失效"，而不是"列表里少一行"。
///
/// ## 存储
///
/// SharedPreferences 单键 `rc_peer_keys`，值是 `{deviceId: base64(32B)}` 的
/// JSON。与 `rc_paired` / `rc:kdfsalt:` 同一信任级别（应用私有目录）。
/// 不引入 `flutter_secure_storage`：那会改 `pubspec.lock`，本轮明确禁止。
/// 落盘加密的替代路径见 `NativeBridge.getOrCreateDeviceSecret()`（F4 已提供），
/// 本轮先把"撤销真的生效"做对，静态加密留作后续（见 REM-10 处置）。
///
/// ## 为什么不复用 `PairedEndpoint.secret`
///
/// `secret` 是**控制端的全局配对码**（REM-03 的横向泄露面）。peerKey 是
/// 点对点材料，两者生命周期完全不同：轮换配对码应当让 peerKey 一起作废
/// （"全部重置"），而重新配对同一台设备应当**复用**已有 peerKey
/// （否则 ack 丢失一次就永久失联 —— 与盐复用同一条纪律）。
class PeerKeyStore {
  PeerKeyStore(this._prefs);

  final SharedPreferences _prefs;

  /// 存储键（单键 JSON 映射，避免 per-device 键在 prefs 里散落）。
  static const storageKey = 'rc_peer_keys';

  Map<String, String> _read() {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final out = <String, String>{};
      decoded.forEach((k, v) {
        if (k is String && v is String) out[k] = v;
      });
      return out;
    } on Object {
      // 存储被写坏：按空表处理（下次配对重建），**不**放行也不崩。
      return <String, String>{};
    }
  }

  /// 读取某控制端的 peerKey；未生成（旧配对）返回 null → 走 v2/v1 旧路径。
  List<int>? keyFor(String deviceId) {
    if (deviceId.isEmpty) return null;
    final b64 = _read()[deviceId];
    if (b64 == null || b64.isEmpty) return null;
    try {
      final bytes = base64Decode(b64);
      // 32 字节是契约：长度不符视为坏值（宁可回落旧路径，也不用半截密钥）。
      return bytes.length == 32 ? bytes : null;
    } on Object {
      return null;
    }
  }

  /// 保存某控制端的 peerKey（配对成功时调用）。
  Future<void> save(String deviceId, List<int> peerKey) async {
    if (deviceId.isEmpty || peerKey.length != 32) return;
    final map = _read()..[deviceId] = base64Encode(peerKey);
    await _prefs.setString(storageKey, jsonEncode(map));
  }

  /// 删除某控制端的 peerKey（**撤销的关键一步**：删了即永久解不开）。
  Future<void> remove(String deviceId) async {
    if (deviceId.isEmpty) return;
    final map = _read();
    if (map.remove(deviceId) == null) return;
    if (map.isEmpty) {
      await _prefs.remove(storageKey);
      return;
    }
    await _prefs.setString(storageKey, jsonEncode(map));
  }

  /// 清空全部（`rotatePairingCode` 的"全部重置"兜底）。
  Future<void> clearAll() async {
    await _prefs.remove(storageKey);
  }

  /// 当前已持有 peerKey 的控制端 id 集合（审计/诊断用）。
  Set<String> ids() => _read().keys.toSet();
}
