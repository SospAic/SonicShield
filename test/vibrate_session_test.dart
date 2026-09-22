import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/domain/scheduling/vibrate_resolve.dart';
import 'package:sonic_shield/services/vibrate_session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 振动会话（`VibrateSession`）的**四条失效安全**回归锁（docs/20 §7.2）。
///
/// | # | 约束 | 为什么不可裁剪 |
/// |---|---|---|
/// | S1 | 进程死亡即停 | 分片续发是**结构性**保证：没人续发 → ≤20s 自然停 |
/// | S2 | 重启**绝不续发** | 宁可少震一次，也不可失控 |
/// | S3 | 任何时刻都能停 | D1「不设时长上限」的对价 |
/// | S4 | 低电量自动降级 | 启动闸 **与** 在跑检查（只挡启动是不够的） |
///
/// 全部依赖（能力探测 / 下发 / 停止 / 电量 / 时钟 / kv / tick）都由构造注入，
/// 所以本文件**完全不碰平台通道**，跑在宿主机上。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase appDb;
  late LogRepository logs;

  setUp(() async {
    appDb = await AppDatabase.open(inMemoryDatabasePath);
    logs = LogRepository(appDb);
  });

  tearDown(() async {
    await appDb.close();
  });

  /// 造一个可控的会话：时钟由测试推进，下发命令全部记账。
  ({
    VibrateSession session,
    List<VibrateCommand> sent,
    List<String> stops,
    List<int> batteryLevel,
    void Function(Duration) advance,
  }) build({
    VibrateCaps caps = const VibrateCaps(
      hasVibrator: true,
      hasAmplitudeControl: true,
      hasEnvelope: true,
      minControlPointMs: 20,
      platform: 'android',
    ),
    bool sendOk = true,
    /// 从第 N 片开始失败（0 基）；null = 一直成功。
    int? failFromChunk,
    int battery = 90,
    bool charging = false,
    String? staleKv,
  }) {
    final sent = <VibrateCommand>[];
    final stops = <String>[];
    final levels = <int>[battery];
    var clock = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    var kvValue = staleKv;

    final s = VibrateSession(
      logs: logs,
      capsProbe: () async => caps,
      send: (cmd) async {
        if (!sendOk) return false;
        if (failFromChunk != null && sent.length >= failFromChunk) return false;
        sent.add(cmd);
        return true;
      },
      stopNative: () async => stops.add('cancel'),
      battery: () async => (level: levels.last, charging: charging),
      kvGet: (k) async => k == VibrateSession.kvKeyActive ? kvValue : null,
      kvSet: (k, v) async {
        if (k == VibrateSession.kvKeyActive) kvValue = v;
      },
      now: () => clock,
      // 真实定时器故意设得远大于用例时长：续发由测试显式 `pump()` 驱动，
      // 不依赖墙钟（否则用例会随机器负载时红时绿）。
      tick: const Duration(hours: 1),
    );
    return (
      session: s,
      sent: sent,
      stops: stops,
      batteryLevel: levels,
      advance: (d) => clock = clock.add(d),
    );
  }

  const continuous = ContinuousVibrateAction(
    durationSecMin: 60,
    durationSecMax: 60,
    amplitudeMin: 0.5,
    amplitudeMax: 0.5,
  );

  group('VS 基本闸门', () {
    test('VS-01 无振动器 → skipped 审计 + 不下发 + 返回 false', () async {
      final h = build(caps: VibrateCaps.none);
      final ok = await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: continuous,
        durationMs: 60000,
        amplitude: 0.5,
        source: 'test',
      );

      expect(ok, isFalse);
      expect(h.sent, isEmpty);
      final rows = await logs.recent();
      expect(rows.first['status'], 'skipped');
      expect(rows.first['message'], contains('无振动能力'));
    });

    test('VS-02 S4 启动闸：低电量且未充电 → 跳过，不震', () async {
      final h = build(battery: PowerConfig.saverBatteryLevel - 5);
      final ok = await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: continuous,
        durationMs: 60000,
        amplitude: 0.5,
        source: 'test',
      );

      expect(ok, isFalse);
      expect(h.sent, isEmpty);
      final rows = await logs.recent();
      expect(rows.first['status'], 'skipped');
      expect(rows.first['message'], contains('省电降级'));
    });

    test('VS-03 S4 边界：低电量但**在充电** → 允许（充电时省电闸不生效）',
        () async {
      final h = build(
          battery: PowerConfig.saverBatteryLevel - 5, charging: true);
      final ok = await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: continuous,
        durationMs: 60000,
        amplitude: 0.5,
        source: 'test',
      );
      expect(ok, isTrue);
      expect(h.sent, hasLength(1));
      h.session.dispose();
    });

    test('VS-04 固定节奏（VibrateAction）不由本会话处理', () async {
      final h = build();
      final ok = await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: const VibrateAction(),
        durationMs: 800,
        amplitude: 1,
        source: 'test',
      );
      expect(ok, isFalse);
      expect(h.sent, isEmpty);
    });
  });

  group('VS S1：分片续发（进程死即停的结构性保证）', () {
    test('VS-05 单片不超过 chunkMs，且续发按时长累加', () async {
      final h = build();
      final ok = await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: continuous,
        durationMs: 60000, // 60s > 20s 片长 → 必须分 3 片
        amplitude: 0.5,
        source: 'test',
      );
      expect(ok, isTrue);
      expect(h.sent, hasLength(1));
      // ⚠️ 结构性判据：**任何一次下发都不超过 chunkMs**。
      // 这条一旦破了，"进程死亡即停"就不再成立（无限循环会一直在震）。
      for (final c in h.sent) {
        expect(c.chunkMs, lessThanOrEqualTo(VibrateRuntime.chunkMs));
      }
      expect(h.session.activeCount, 1);

      // 推进到当前片尾前一个 tick → 续发第二片。
      h.advance(const Duration(seconds: 19));
      await h.session.pump();
      expect(h.sent.length, greaterThanOrEqualTo(2));

      h.advance(const Duration(seconds: 19));
      await h.session.pump();
      expect(h.sent.length, greaterThanOrEqualTo(3));

      // 跑满总时长 → 收尾，活跃表清空。
      h.advance(const Duration(seconds: 25));
      await h.session.pump();
      expect(h.session.activeCount, 0);
      h.session.dispose();
    });

    test('VS-06 续发失败 → 立即停止并写审计（不假装还在震）', () async {
      final h = build(sendOk: false);
      final ok = await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: continuous,
        durationMs: 60000,
        amplitude: 0.5,
        source: 'test',
      );
      // 首片就失败 → 直接返回 false，不进活跃表。
      expect(ok, isFalse);
      expect(h.session.activeCount, 0);
      final rows = await logs.recent();
      expect(rows.first['status'], 'failed');
    });

    test('VS-07 首片成功后中途失败 → 停止 + 审计（不继续假装在震）', () async {
      final h = build(failFromChunk: 1); // 第 1 片成功，第 2 片起失败
      final ok = await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: continuous,
        durationMs: 60000,
        amplitude: 0.5,
        source: 'test',
      );
      expect(ok, isTrue);
      expect(h.session.activeCount, 1);

      h.advance(const Duration(seconds: 19));
      await h.session.pump();

      expect(h.session.activeCount, 0, reason: '续发失败必须退出活跃表，不能留个空壳');
      final rows = await logs.recent();
      expect(rows.any((r) => (r['message'] as String? ?? '').contains('续发失败')),
          isTrue);
      h.session.dispose();
    });
  });

  group('VS S3：任何时刻都能停', () {
    test('VS-08 stopAll 即使活跃表为空也要下发一次原生 cancel', () async {
      final h = build();
      // 从未 start 过 —— 模拟"上次进程被杀，表丢了但原生还在震"。
      await h.session.stopAll(reason: '远程停止');

      expect(h.stops, isNotEmpty,
          reason: 'S3 的字面要求：没有活跃记录也必须能停（残留振动）');
      h.session.dispose();
    });

    test('VS-09 stopFor 写审计并带上已下发片数', () async {
      final h = build();
      await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: continuous,
        durationMs: 60000,
        amplitude: 0.5,
        source: 'test',
      );
      await h.session.stopFor('o1', reason: '用户停止');

      expect(h.session.activeCount, 0);
      expect(h.stops, isNotEmpty);
      final rows = await logs.recent();
      final stopped = rows.firstWhere((r) => r['status'] == 'skipped');
      expect(stopped['message'], contains('已停止：用户停止'));
      expect(stopped['message'], contains('已下发'));
      h.session.dispose();
    });

    test('VS-10 stopFor 未知 id 不抛、也不误报', () async {
      final h = build();
      await h.session.stopFor('ghost');
      expect(h.stops, isNotEmpty, reason: '即使 id 未知也要下发 cancel');
      h.session.dispose();
    });
  });

  group('VS S2：重启绝不续发', () {
    test('VS-11 无残留：清空 + cancel，不写"检测到残留"审计', () async {
      final h = build();
      await h.session.recoverAfterRestart();
      expect(h.stops, isNotEmpty);
      final rows = await logs.recent();
      expect(rows.where((r) => (r['message'] as String? ?? '').contains('检测到上次')),
          isEmpty);
      h.session.dispose();
    });

    test('VS-12 有残留：强制停止 + 写审计 + **绝不续发**', () async {
      final h = build(staleKv: '["o-old"]');
      await h.session.recoverAfterRestart();

      expect(h.session.activeCount, 0);
      expect(h.stops, isNotEmpty);
      final rows = await logs.recent();
      final warn = rows.firstWhere(
          (r) => (r['message'] as String? ?? '').contains('检测到上次'));
      expect(warn['status'], 'skipped');
      expect(warn['message'], contains('不续发'));
      // 关键：恢复流程**没有**下发任何振动命令。
      expect(h.sent, isEmpty,
          reason: '重启后补震是失控失效模式（宁可少震一次）');
      h.session.dispose();
    });

    test('VS-13 恢复后再 start 才重新开始（旧残留不会复活）', () async {
      final h = build(staleKv: '["o-old"]');
      await h.session.recoverAfterRestart();
      expect(h.session.activeCount, 0);

      final ok = await h.session.start(
        occurrenceId: 'o-new',
        taskId: 't1',
        action: continuous,
        durationMs: 30000,
        amplitude: 0.5,
        source: 'test',
      );
      expect(ok, isTrue);
      expect(h.session.activeIds, ['o-new']);
      h.session.dispose();
    });
  });

  group('VS S4：在跑期间掉电', () {
    test('VS-14 跑着跑着电量掉到阈值以下 → 立即停止（不能只挡启动）', () async {
      final h = build(battery: 90);
      await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: continuous,
        durationMs: 600000,
        amplitude: 0.5,
        source: 'test',
      );
      expect(h.session.activeCount, 1);

      h.batteryLevel[0] = PowerConfig.saverBatteryLevel - 1;
      h.advance(const Duration(seconds: 5));
      await h.session.pump();

      expect(h.session.activeCount, 0);
      final rows = await logs.recent();
      expect(
          rows.any((r) => (r['message'] as String? ?? '').contains('省电降级停止')),
          isTrue);
      h.session.dispose();
    });
  });

  group('VS 随机振动与勿扰', () {
    test('VS-15 随机振动一次性下发（脉冲数已被 maxPulses 封顶，不分片）', () async {
      final h = build();
      final ok = await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: const RandomVibrateAction(),
        durationMs: 8000,
        amplitude: 0.6,
        source: 'test',
      );
      expect(ok, isTrue);
      expect(h.sent, hasLength(1));
      expect(h.session.activeCount, 0, reason: '随机振动不进活跃表（无续发）');
      h.session.dispose();
    });

    test('VS-16 respectDnd=false → 用 USAGE_ALARM（穿透勿扰，UI 必须提示）',
        () async {
      final h = build();
      await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: const RandomVibrateAction(respectDnd: false),
        durationMs: 8000,
        amplitude: 0.6,
        source: 'test',
      );
      expect(h.sent.single.useAlarmUsage, isTrue);

      final h2 = build();
      await h2.session.start(
        occurrenceId: 'o2',
        taskId: 't1',
        action: const RandomVibrateAction(respectDnd: true),
        durationMs: 8000,
        amplitude: 0.6,
        source: 'test',
      );
      expect(h2.sent.single.useAlarmUsage, isFalse);
      h.session.dispose();
      h2.session.dispose();
    });

    test('VS-17 能力不足时降级说明进审计（不得静默降级）', () async {
      final h = build(
        caps: const VibrateCaps(
          hasVibrator: true,
          hasAmplitudeControl: false, // 强度设置会失效
          hasEnvelope: false,
          minControlPointMs: 20,
          platform: 'android',
        ),
      );
      await h.session.start(
        occurrenceId: 'o1',
        taskId: 't1',
        action: const ContinuousVibrateAction(
            durationSecMin: 10, durationSecMax: 10, amplitudeMin: 0.2, amplitudeMax: 0.9),
        durationMs: 10000,
        amplitude: 0.5,
        source: 'test',
      );
      final rows = await logs.recent();
      expect(rows.first['message'], contains('不支持振幅控制'));
      h.session.dispose();
    });
  });
}
