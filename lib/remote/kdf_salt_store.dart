import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';

/// 每设备 KDF 随机盐的本地存储（Q1.B：慢 KDF + 每设备随机盐）。
///
/// - 存储：SharedPreferences，键 `rc:kdfsalt:<deviceId>`，值为
///   Base64 编码的 32 字节安全随机盐（由 [RcCodec.newSalt] 生成）。
/// - 兼容：`saltFor` 返回 null（旧配对端点没有存盐）时，调用方**必须**
///   走 [RcCodec.deriveKey] 的无盐旧路径，已配对设备不受影响。
///
/// ## 接线点（本文件只交付 API，不负责接线）
///
/// ① 端点侧：`pair.request` 应答 / 配对登记时 `newSalt()` + `saveSalt()`，
///    并把盐随配对成功回执下发给控制端；
/// ② 控制端：收到配对成功事件时 `saveSalt()` 落盘对端下发的盐。
/// 双方此后用同一份盐走 `RcCodec.deriveKey(secret, context, salt: ...)`。
class KdfSaltStore {
  KdfSaltStore(this._prefs);

  final SharedPreferences _prefs;

  static const _prefix = 'rc:kdfsalt:';

  static String _key(String deviceId) => '$_prefix$deviceId';

  /// 生成 32 字节安全随机盐（委托 [RcCodec.newSalt]，单一真源）。
  static List<int> newSalt() => RcCodec.newSalt();

  /// 读取某设备的盐；未存盐（旧配对端点）返回 null → 走无盐旧派生路径。
  List<int>? saltFor(String deviceId) {
    final s = _prefs.getString(_key(deviceId));
    if (s == null || s.isEmpty) return null;
    return base64Decode(s);
  }

  /// 保存某设备的盐（配对登记 / 收到配对成功事件时调用）。
  Future<void> saveSalt(String deviceId, List<int> salt) =>
      _prefs.setString(_key(deviceId), base64Encode(salt));
}
