import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/services/export_crypto.dart';

/// v2.0 新功能测试闭环：加密备份（ExportCrypto）与统计聚合（LogStats）。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('ExportCrypto（加密备份）', () {
    const plain =
        '{"app":"sonic_shield","version":1,"tasks":[{"id":"a","name":"测试"}]}';

    test('加解密往返：正确密码还原明文', () async {
      final enc = await ExportCrypto.encrypt(plain, 'pass-123');
      expect(enc, isNot(contains('测试'))); // 密文中不见明文
      final back = await ExportCrypto.decrypt(enc, 'pass-123');
      expect(back, plain);
    });

    test('错误密码 → null（不抛异常）', () async {
      final enc = await ExportCrypto.encrypt(plain, 'right');
      final back = await ExportCrypto.decrypt(enc, 'wrong');
      expect(back, isNull);
    });

    test('密文篡改 → null（GCM 完整性校验）', () async {
      final enc = await ExportCrypto.encrypt(plain, 'pass');
      // 精准篡改 cipher 字段：解码 JSON → 翻转密文尾字符 → 重编码。
      final j = (jsonDecode(enc) as Map).cast<String, dynamic>();
      final c = base64Decode(j['cipher'] as String);
      c[c.length - 1] ^= 0xFF;
      j['cipher'] = base64Encode(c);
      final tampered = const JsonEncoder.withIndent('  ').convert(j);
      final back = await ExportCrypto.decrypt(tampered, 'pass');
      expect(back, isNull, reason: 'GCM MAC 校验必须拦截篡改');
    });

    test('随机 salt：两次加密产生不同密文', () async {
      final a = await ExportCrypto.encrypt(plain, 'same-pass');
      final b = await ExportCrypto.encrypt(plain, 'same-pass');
      expect(a, isNot(b));
      expect(await ExportCrypto.decrypt(b, 'same-pass'), plain);
    });

    test('损坏文件 → null', () async {
      expect(await ExportCrypto.decrypt('not-json', 'pass'), isNull);
      expect(await ExportCrypto.decrypt('{"v":99}', 'pass'), isNull);
    });
  });

  group('LogStats（统计聚合）', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(inMemoryDatabasePath);
      await db.db.execute(
          "INSERT INTO tasks (id, name, enabled, trigger_type, trigger_json, action_type, action_json, asset_ids, cooldown_sec, quiet_policy, priority, created_at, updated_at) VALUES ('t', '父', 1, 'dailyAt', '{}', 'playAudio', '{}', '[]', 300, 'skip', 0, 0, 0)");
    });
    tearDown(() async {
      await db.close();
    });

    test('dailyCounts 7 天窗口与失败计数', () async {
      final logs = LogRepository(db);
      final today = _fmt(DateTime.now());
      await _seedDirect(db, today, 'success', 'play', 3);
      await _seedDirect(db, today, 'failed', 'play', 2);
      await _seedDirect(
          db,
          _fmt(DateTime.now().subtract(const Duration(days: 1))),
          'success',
          'tts',
          1);
      final daily = await logs.dailyCounts(days: 7);
      expect(daily.length, 2); // 两天有数据
      expect(daily.last.total, 5); // 今天 5 条
      expect(daily.last.failed, 2);
      expect(daily.first.total, 1); // 昨天 1 条
    });

    test('actionBreakdown 分布排序', () async {
      final logs = LogRepository(db);
      final today = _fmt(DateTime.now());
      await _seedDirect(db, today, 'success', 'play', 5);
      await _seedDirect(db, today, 'success', 'tts', 2);
      final actions = await logs.actionBreakdown();
      expect(actions.first.action, 'play');
      expect(actions.first.count, 5);
      expect(actions[1].action, 'tts');
    });

    test('statusBreakdown 占比', () async {
      final logs = LogRepository(db);
      final today = _fmt(DateTime.now());
      await _seedDirect(db, today, 'success', 'play', 4);
      await _seedDirect(db, today, 'failed', 'play', 1);
      final status = await logs.statusBreakdown();
      expect(status['success'], 4);
      expect(status['failed'], 1);
    });
  });
}

String _fmt(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 直接以参数化时间戳写入指定日期的日志（本地时区语义，
/// 避免 sqlite strftime 按 UTC 解析导致的日期错位）。
Future<void> _seedDirect(
    AppDatabase db, String day, String status, String action, int count) async {
  final dt = DateTime.parse('${day}T12:00:00');
  for (var i = 0; i < count; i++) {
    await db.db.execute(
      "INSERT INTO exec_logs (source, action, status, message, created_at) VALUES ('schedule', ?, ?, NULL, ?)",
      [action, status, dt.millisecondsSinceEpoch + i * 1000],
    );
  }
}
