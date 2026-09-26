import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/protocol.dart';

import 'support/source_text.dart';

/// Q1.B 回归锁：慢 KDF + 每设备随机盐 + 配对码轮换。
///
/// 兼容铁证：同 secret+context 下，无盐派生结果必须等于旧算法
/// （纯 HKDF-SHA256，salt=`sonicshield-rc-v1|{context}`，info=`sonicshield`）
/// ——否则全量已配对端点掉线。
void main() {
  const secret = 'AB2CD5EF';
  const context = 'aaaaaaaaaaaaaaaa|cmd';

  group('deriveKey 兼容与加盐', () {
    test('无盐结果 == 旧算法结果（兼容铁证）', () async {
      // 旧算法独立复现（与本仓库升级前实现逐参数一致）。
      final oldAlg = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final oldSk = await oldAlg.deriveKey(
        secretKey: SecretKey(utf8.encode(secret)),
        nonce: utf8.encode('sonicshield-rc-v1|$context'),
        info: utf8.encode('sonicshield'),
      );
      final oldBytes = await oldSk.extractBytes();

      final noSalt = await RcCodec.deriveKey(secret, context);
      final nullSalt = await RcCodec.deriveKey(secret, context, salt: null);
      final emptySalt = await RcCodec.deriveKey(secret, context, salt: const []);

      expect(noSalt, oldBytes);
      expect(nullSalt, oldBytes);
      expect(emptySalt, oldBytes);
    });

    test('同 secret+context：有盐结果 != 无盐结果', () async {
      final salt = RcCodec.newSalt();
      final withSalt = await RcCodec.deriveKey(secret, context, salt: salt);
      final noSalt = await RcCodec.deriveKey(secret, context);
      expect(withSalt.length, 32);
      expect(withSalt, isNot(noSalt));
    });

    test('同盐结果稳定（确定性）', () async {
      final salt = RcCodec.newSalt();
      final a = await RcCodec.deriveKey(secret, context, salt: salt);
      final b = await RcCodec.deriveKey(secret, context, salt: salt);
      expect(a, b);
    });

    test('不同盐结果不同（每设备隔离）', () async {
      final s1 = RcCodec.newSalt();
      final s2 = RcCodec.newSalt();
      final a = await RcCodec.deriveKey(secret, context, salt: s1);
      final b = await RcCodec.deriveKey(secret, context, salt: s2);
      expect(a, isNot(b));
    });

    test('双方同盐同派生（端点/控制端互通前提）', () async {
      final salt = RcCodec.newSalt();
      final endpoint =
          await RcCodec.deriveKey(secret, 'aaaaaaaaaaaaaaaa|cmd', salt: salt);
      final controller =
          await RcCodec.deriveKey(secret, 'aaaaaaaaaaaaaaaa|cmd', salt: salt);
      expect(endpoint, controller);
    });

    test('newSalt：32 字节且随机', () {
      final a = RcCodec.newSalt();
      final b = RcCodec.newSalt();
      expect(a.length, 32);
      expect(b.length, 32);
      expect(a, isNot(b));
    });
  });

  group('KdfSaltStore 存取', () {
    late KdfSaltStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      store = KdfSaltStore(prefs);
    });

    test('盐存取往返', () async {
      expect(store.saltFor('device-1'), isNull); // 旧端点：无盐
      final salt = RcCodec.newSalt();
      await store.saveSalt('device-1', salt);
      expect(store.saltFor('device-1'), salt);
    });

    test('未存盐设备与其他设备互不干扰', () async {
      final salt = RcCodec.newSalt();
      await store.saveSalt('device-2', salt);
      expect(store.saltFor('device-2'), salt);
      expect(store.saltFor('device-3'), isNull);
    });

    test('saveSalt 覆盖旧盐（轮换场景）', () async {
      final s1 = RcCodec.newSalt();
      await store.saveSalt('device-1', s1);
      final s2 = RcCodec.newSalt();
      await store.saveSalt('device-1', s2);
      expect(store.saltFor('device-1'), s2);
    });
  });

  group('rotatedPairingCode', () {
    final pattern = RegExp(r'^[A-HJ-KM-NP-TV-Z2-9]{4}-[A-HJ-KM-NP-TV-Z2-9]{4}$');

    test('格式与 generatePairingCode 一致（8 位 Crockford Base32 + 连字符）', () {
      for (var i = 0; i < 50; i++) {
        expect(pattern.hasMatch(RcCodec.rotatedPairingCode('AB2C-D5EF')), isTrue);
      }
    });

    test('不与旧码相同（含仅分隔符位置不同的假轮换）', () {
      final samples = [
        'AB2C-D5EF',
        'ZZZZ-9999',
        'WXYZ-2345',
        'ABCD-EFGH',
        '', // 空旧码也要能轮换
      ];
      for (final cur in samples) {
        final next = RcCodec.rotatedPairingCode(cur);
        expect(next.replaceAll('-', ''), isNot(cur.replaceAll('-', '')));
      }
    });

    test('多次轮换形成链且不回环到自身', () {
      var code = 'AB2C-D5EF';
      for (var i = 0; i < 20; i++) {
        final next = RcCodec.rotatedPairingCode(code);
        expect(next.replaceAll('-', ''), isNot(code.replaceAll('-', '')));
        code = next;
      }
    });
  });

  group('源码锁', () {
    // 剥除行注释与块注释后拼接源码（`test/support/source_text.dart`，
    // 第 36 轮收敛到唯一真源）。
    // ⚠️ 此前本文件用的是**行级粗糙版**（`split('//').first`）—— 它会把
    // `'mqtt://...'` 这类字符串字面量从 `//` 起截断（可能假绿/假红）；
    // 收敛后字符串整段保留。

    /// 检查签名片段是否存在（兼容单行与多行、尾逗号等书写形式）。
    bool hasSignature(String src) => stripComments(src).contains(
        RegExp('deriveKey\\([^)]*\\{\\s*List<int>\\? salt[,}]'));

    const protocolPath = 'lib/remote/protocol.dart';

    test('$protocolPath：deriveKey 签名必须含 {List<int>? salt}', () {
      final src = File(protocolPath).readAsStringSync();
      expect(hasSignature(src), isTrue,
          reason: 'Q1.B 慢 KDF + 每设备随机盐：deriveKey 必须支持可选盐参数');
    });

    test('反例样本：无盐签名不应通过同一检查（防检查器恒真）', () {
      const negative = '''
Future<List<int>> deriveKey(String secret, String context) async {
  return <int>[];
}
''';
      expect(hasSignature(negative), isFalse);
    });
  });
}
