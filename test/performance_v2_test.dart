@Tags(['perf'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:sonic_shield/services/export_crypto.dart';

/// 第二轮性能压测（v1.4–v2.0 新模块，docs/17）。
/// 覆盖：条件层 / 扫码配对解析 / 加密备份 / 统计聚合 / 指令组序列 / 内存基准。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('WT-白盒 · 条件层与扫码配对', () {
    const cond = TaskCondition(
      requireCharging: true,
      minBatteryPct: 20,
      windowStartMin: 8 * 60,
      windowEndMin: 21 * 60,
    );
    final now = DateTime(2026, 9, 15, 12); // 12:00，在窗口内

    test('WT-01 TaskCondition.evaluate 10 万次 ≤ 800ms', () {
      final sw = Stopwatch()..start();
      var pass = 0;
      for (var i = 0; i < 100000; i++) {
        if (cond.evaluate(charging: true, batteryLevel: 80, now: now)) {
          pass++;
        }
      }
      sw.stop();
      expect(pass, 100000);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(800),
          reason: '条件评估 10 万次耗时 ${sw.elapsedMilliseconds}ms');
    });

    test('WT-02 parseUri 1 万次（有效/无效混合）≤ 300ms', () {
      const valid =
          'sonicshield://pair/0123456789abcdef/%E5%A3%B0%E7%9B%BE-A1/AB2CD5EF';
      final sw = Stopwatch()..start();
      var ok = 0;
      for (var i = 0; i < 10000; i++) {
        if (PairQrProtocol.parseUri(valid) != null) ok++;
        if (PairQrProtocol.parseUri('sonicshield://pair/bad') == null) ok++;
      }
      sw.stop();
      expect(ok, 20000); // 每轮两断言均计入
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(300));
    });

    test('WT-03 配对码/设备 ID 生成各 1 万次 ≤ 800ms', () {
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10000; i++) {
        expect(RcCodec.generatePairingCode().replaceAll('-', '').length, 8);
        expect(RcCodec.generateDeviceId().length, 16);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(800));
    });
  });

  group('GT-灰盒 · 加密备份（PBKDF2 120k + AES-GCM）', () {
    // ~50KB 任务备份（100 任务全字段）。
    final bigPayload = const JsonEncoder().convert({
      'app': 'sonic_shield',
      'version': 1,
      'tasks': [
        for (var i = 0; i < 100; i++)
          {
            'id': 't$i',
            'name': '压测任务$i（含中文字段与较长描述内容以扩大体积）',
            'trigger_json':
                '{"kind":"randomWindow","timesPerDay":3,"minGapSec":1800}',
            'action_json': '{"kind":"play","volumeMin":0.3,"volumeMax":0.9}',
            'condition_json': '{"requireCharging":true,"minBatteryPct":20}',
          }
      ],
    });

    test('GT-01 加密 50KB 备份（含 KDF 12 万次，纯 Dart 实现）≤ 4s', () async {
      final sw = Stopwatch()..start();
      final enc = await ExportCrypto.encrypt(bigPayload, 'stress-pass');
      sw.stop();
      expect(enc.length, greaterThan(40000));
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(4000),
          reason: '加密耗时 ${sw.elapsedMilliseconds}ms');
    });

    test('GT-02 解密 50KB 备份（含 KDF 12 万次，纯 Dart 实现）≤ 4s', () async {
      final enc = await ExportCrypto.encrypt(bigPayload, 'stress-pass');
      final sw = Stopwatch()..start();
      final back = await ExportCrypto.decrypt(enc, 'stress-pass');
      sw.stop();
      expect(back, bigPayload);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(4000),
          reason: '解密耗时 ${sw.elapsedMilliseconds}ms');
    });

    test('GT-03 错误密码解密（含 KDF+失败）≤ 4s', () async {
      final enc = await ExportCrypto.encrypt(bigPayload, 'right');
      final sw = Stopwatch()..start();
      final back = await ExportCrypto.decrypt(enc, 'wrong');
      sw.stop();
      expect(back, isNull);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(1500));
    });
  });

  group('GT-灰盒 · 统计聚合（万级日志）', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(inMemoryDatabasePath);
      final base = DateTime.now().subtract(const Duration(days: 3));
      final batch = db.db.batch();
      for (var i = 0; i < 10000; i++) {
        batch.insert('exec_logs', {
          'source': 'schedule',
          'action': i % 3 == 0 ? 'play' : (i % 3 == 1 ? 'tts' : 'notify'),
          'status': i % 10 == 0 ? 'failed' : 'success',
          'created_at': base.add(Duration(minutes: i)).millisecondsSinceEpoch,
        });
      }
      await batch.commit(noResult: true);
    });
    tearDown(() async {
      await db.close();
    });

    test('GT-04 dailyCounts 万级 ≤ 50ms', () async {
      final logs = LogRepository(db);
      final sw = Stopwatch()..start();
      final daily = await logs.dailyCounts(days: 7);
      sw.stop();
      expect(daily, isNotEmpty);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(50),
          reason: 'dailyCounts ${sw.elapsedMilliseconds}ms');
    });

    test('GT-05 actionBreakdown 万级 ≤ 50ms', () async {
      final logs = LogRepository(db);
      final sw = Stopwatch()..start();
      final actions = await logs.actionBreakdown();
      sw.stop();
      expect(actions, isNotEmpty);
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(50));
    });
  });

  group('GT-灰盒 · 指令组序列与 outbox', () {
    test('GT-06 50 步指令组 toPayload × 100 ≤ 200ms', () {
      final steps = [
        for (var i = 0; i < 50; i++)
          i.isEven
              ? const RcStep(RcStepKind.play, {
                  'volume': 0.8,
                  'durationSec': 10,
                  'presetCategory': 'ambient'
                })
              : const RcStep(RcStepKind.delay, {'seconds': 30}),
      ];
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        final payload = RcScript(
          scriptId: 's$i',
          name: '压测',
          fromName: 'A',
          sentAt: DateTime.now().millisecondsSinceEpoch,
          steps: steps,
        ).toJson();
        expect(payload['steps'], isNotNull);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(200));
    });

    test('GT-07 outbox 200 条 + 二次 drain 幂等 ≤ 400ms', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = RemoteStore(prefs);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        await store.enqueue('w$i', 'dev');
      }
      final d1 = store.drainOutbox('dev');
      final d2 = store.drainOutbox('dev');
      sw.stop();
      expect(d1.length, 200);
      expect(d2, isEmpty); // 幂等：冲刷后不再重复
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(400));
    });
  });

  group('MT-内存基准', () {
    test('MT-01 1000 任务物化 1.2 万条 ≤ 4000ms（分配量代理）', () {
      const engine = ScheduleEngine();
      final now = DateTime(2026, 9, 14, 12);
      var count = 0;
      var footprint = 0; // 分配量代理：occurrenceId 字符总量
      final sw = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        final t = Task(
          id: 'mem-$i',
          name: '内存压测$i',
          enabled: true,
          triggerType: TriggerType.randomWindow,
          trigger: RandomWindowTrigger(
            dateRange: DateRange(
                start: DateTime(2026, 9, 14), end: DateTime(2026, 10, 14)),
            windowStart: const TimeSpec(hour: 8),
            windowEnd: const TimeSpec(hour: 21),
            timesPerDay: 3,
            minGap: const Duration(minutes: 30),
          ),
          actionType: ActionType.playAudio,
          action: const PlayAudioAction(),
          assetIds: const [],
          cooldownSec: 300,
          quietPolicy: QuietPolicy.skip,
          priority: 0,
          createdAt: now,
          updatedAt: now,
        );
        for (final e in engine.materialize(t, now)) {
          count++;
          footprint += e.occurrenceId.length;
        }
      }
      sw.stop();
      expect(count, greaterThanOrEqualTo(6000),
          reason: '48h 视界 × 3 次/天 ≈ 6 条/任务');
      // 分配量代理：1.2 万条 ID ≈ 300KB 字符量级，远低于泄漏阈值。
      expect(footprint, lessThan(500000));
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(4000),
          reason: '1000 任务物化 ${sw.elapsedMilliseconds}ms');
    });
  });
}
