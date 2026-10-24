import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart' show Mac, SecretBox, SecretKeyData;
import 'package:cryptography/dart.dart';

import '../services/native_bridge.dart';

/// 长期凭据的**落盘加密**（R94 / REM-10）。
///
/// ## 为什么需要它
///
/// `SharedPreferences` 在 Android 上就是应用私有目录里的一个 XML。配对码
/// 是**本机主密钥**（任何拿到它的人都能冒充已配对控制端），broker 密码与
/// TURN 凭据则能导致中间人/流量分析 —— 它们与"上次选的标签页"同一信任级别，
/// 明显不对等。设备被 root / 备份被导出 / `run-as` 调试时全部明文可取。
///
/// ## 方案（本轮**不引入新依赖**）
///
/// 调 F4 已提供的 `NativeBridge.getOrCreateDeviceSecret()`（Android 侧由
/// Keystore 保护）拿一个设备级秘密，再以它为密钥做 AES-256-GCM 落盘。
/// 封装形式 `enc1:<base64({n,c,m})>`：
/// - 前缀是**版本标记**，将来换算法时可识别旧值；
/// - 没有前缀的值视为**旧明文**，原样返回（升级不丢配置）；
/// - 任何失败（无秘密 / 解密失败 / 格式坏）一律**降级为"读不到"**，
///   绝不抛异常：凭据读取遍布启动路径，抛一次就是远程模块整体起不来。
///
/// ## 为什么是同步 API
///
/// `RemoteStore.pairingCode` / `brokerPassword` 都是 **getter**（UI 与
/// `_connect` 直接读）。改成异步会波及十几个调用点与全部页面。因此：
/// 设备秘密**只异步取一次**并缓存在内存，加解密走 `DartAesGcm.encryptSync`
/// （同包内的纯 Dart 实现，无新依赖）。
///
/// ## 边界（务必如实告知）
///
/// 这是**降低明文面**，不是"等价于 Keystore 加密存储"：
/// - 设备秘密本身由原生层保管，Dart 侧只能拿到它的字节；
/// - 有 root 权限的攻击者仍可 dump 进程内存拿到秘密。
/// 真正的终点是把凭据搬进 Keystore/EncryptedSharedPreferences（见 REM-10）。
class CredentialSealer {
  CredentialSealer._();

  /// 密文前缀（版本标记）。
  static const prefix = 'enc1:';

  /// 版本化 KDF 标签：换算法时改它，旧密文自然解不开（而不是解出错值）。
  static const _kdfLabel = 'sonicshield-cred-v1';

  /// 设备秘密（Base64 原文）→ 派生出的 32 字节密钥（缓存）。
  static List<int>? _key;

  /// 是否已经尝试过装载（失败也置位，避免每次读凭据都去撞一次平台通道）。
  static bool _loaded = false;

  /// 测试缝：替换设备秘密来源（宿主测试没有原生通道）。
  static Future<String?> Function()? deviceSecretLoader;

  /// 设备秘密是否可用（不可用时 [seal] 退化为明文、[open] 退化为"读不到"）。
  static bool get ready => _key != null;

  /// 装载设备秘密（幂等；失败不抛）。
  static Future<void> ensure() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await (deviceSecretLoader?.call() ??
          NativeBridge.getOrCreateDeviceSecret());
      if (raw == null || raw.isEmpty) return;
      final secret = base64Decode(raw);
      if (secret.isEmpty) return;
      // 单块 HMAC-SHA256 作 KDF：设备秘密本身是 256 bit CSPRNG 输出，
      // 不需要慢哈希（这里没有"人类可猜"的成分）。
      final mac = DartHmac.sha256().calculateMacSync(
        utf8.encode(_kdfLabel),
        secretKeyData: SecretKeyData(secret),
        nonce: const <int>[],
      );
      _key = mac.bytes;
    } on Object {
      // 平台通道不可用（宿主测试 / 旧系统）：保持明文兼容路径。
      _key = null;
    }
  }

  /// 重置（仅测试用）。
  static void resetForTest() {
    _key = null;
    _loaded = false;
    deviceSecretLoader = null;
  }

  /// 加密一个凭据值；未就绪时**原样返回**（降级为明文，保持可用性）。
  ///
  /// 空串直接返回空串：不要为"未配置"造一条密文，否则 UI 会把它当成
  /// "已配置了一个看不见的值"。
  static String seal(String plain) {
    final key = _key;
    if (plain.isEmpty || key == null) return plain;
    try {
      final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
      final box = DartAesGcm().encryptSync(
        utf8.encode(plain),
        secretKeyData: SecretKeyData(key),
        nonce: nonce,
      );
      return '$prefix${base64Encode(utf8.encode(jsonEncode({
            'n': base64Encode(box.nonce),
            'c': base64Encode(box.cipherText),
            'm': base64Encode(box.mac.bytes),
          })))}';
    } on Object {
      return plain; // 加密失败 ⇒ 明文（宁可明文可用，也不要写坏值）
    }
  }

  /// 解密一个凭据值。
  ///
  /// - 无前缀 ⇒ 旧明文，原样返回（升级兼容）；
  /// - 有前缀但密钥未就绪 / 解密失败 ⇒ **空串**（当作未配置）。
  ///   返回密文原文会更糟：它会被当作配对码/密码使用，表现为"怎么填都不对"。
  static String open(String stored) {
    if (stored.isEmpty) return '';
    if (!stored.startsWith(prefix)) return stored;
    final key = _key;
    if (key == null) return '';
    try {
      final raw = jsonDecode(
              utf8.decode(base64Decode(stored.substring(prefix.length))))
          as Map;
      final box = SecretBox(
        base64Decode(raw['c'] as String),
        nonce: base64Decode(raw['n'] as String),
        mac: Mac(base64Decode(raw['m'] as String)),
      );
      final clear = DartAesGcm().decryptSync(
        box,
        secretKeyData: SecretKeyData(key),
      );
      return utf8.decode(clear);
    } on Object {
      return '';
    }
  }
}
