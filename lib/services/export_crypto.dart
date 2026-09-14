import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 任务备份加密（v2.0）：PBKDF2 派生密钥 + AES-256-GCM。
/// 文件格式：{"v":1,"salt":b64,"nonce":b64,"mac":b64,"cipher":b64}（JSON）。
/// 密码丢失不可恢复（无后门）——文档与 UI 明示。
class ExportCrypto {
  ExportCrypto._();

  static final Pbkdf2 _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 120000,
    bits: 256,
  );
  static final AesGcm _aes = AesGcm.with256bits();

  static Future<Uint8List> _deriveKey(String password, List<int> salt) async {
    final sk = await _pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return Uint8List.fromList(await sk.extractBytes());
  }

  static String _b64(List<int> b) => base64Encode(b);

  /// 加密明文 JSON → 加密备份 JSON 字符串。
  static Future<String> encrypt(String plainJson, String password) async {
    final salt = _aes.newNonce(); // 12B 随机（借用 nonce 生成器）
    final key = await _deriveKey(password, salt);
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(utf8.encode(plainJson),
        secretKey: SecretKey(key),
        nonce: nonce,
        aad: utf8.encode('sonicshield-backup-v1'));
    return const JsonEncoder.withIndent('  ').convert({
      'v': 1,
      'kdf': 'PBKDF2-SHA256-120000',
      'salt': _b64(salt),
      'nonce': _b64(nonce),
      'mac': _b64(box.mac.bytes),
      'cipher': _b64(box.cipherText),
    });
  }

  /// 解密；密码错误/文件损坏返回 null。
  static Future<String?> decrypt(String encryptedJson, String password) async {
    try {
      final j = (jsonDecode(encryptedJson) as Map).cast<String, dynamic>();
      if (j['v'] != 1) return null;
      final salt = base64Decode(j['salt'] as String);
      final key = await _deriveKey(password, salt);
      final box = SecretBox(
        base64Decode(j['cipher'] as String),
        nonce: base64Decode(j['nonce'] as String),
        mac: Mac(base64Decode(j['mac'] as String)),
      );
      final clear = await _aes.decrypt(box,
          secretKey: SecretKey(key), aad: utf8.encode('sonicshield-backup-v1'));
      return utf8.decode(clear);
    } on Object {
      return null;
    }
  }
}
