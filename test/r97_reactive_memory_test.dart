import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/services/playback_service.dart';
import 'package:sonic_shield/services/reactive_counter_service.dart';
import 'package:sonic_shield/services/sound_guard_service.dart';

/// R88-AUD-06 回归锁：`ReactiveCounterService._records` 必须有界。
///
/// **零平台依赖 / 零真实等待**：时钟、定时器、播放、随机、审计全部注入替身，
/// 用 `_records.length`（确定性指标）与 `prunedCount` 断言，不测 RSS。
///
/// 锁住三件事：
/// 1. **有界**：时间窗 + 条数双约束，任何写入序列后长度都不超过 `maxRecords`；
/// 2. **不改变语义**：淘汰只作用于内存诊断（冷却 / 升级 / sink 落盘照旧）；
/// 3. **可观测**：淘汰必有 `prunedCount` 增量 + 一行 `debugPrint`，不静默。
void main() {
  final originalDebugPrint = debugPrint;
  late List<String> logs;
  late _Clock clock;
  late List<({String action, String status, String? message})> audits;
  late ReactiveCounterService svc;

  setUp(() {
    logs = <String>[];
    audits = <({String action, String status, String? message})>[];
    // 捕获淘汰日志：既验证"不静默"，也避免刷屏。
    debugPrint = (String? message, {int? wrapWidth}) {
      logs.add(message ?? '');
    };
    clock = _Clock(DateTime(2026, 1, 1, 12));
    svc = ReactiveCounterService(
      pool: const <CounterAction>[CounterAction.audio('preset.wav')],
      audit: ({
        required String action,
        required String status,
        String? message,
      }) async {
        audits.add((action: action, status: status, message: message));
      },
      playAudio: ({
        required String path,
        required double volume,
        required int durationMs,
      }) async =>
          PlayResult(ok: true, playedMs: durationMs),
      isBusy: () => false,
      timerFactory: (Duration delay, void Function() onFire) => _FakeTimer(),
      rng: math.Random(7),
      clock: clock.call,
    )..start();
  });

  tearDown(() {
    svc.stop();
    debugPrint = originalDebugPrint;
  });

  // 轻声音 = 每次 2 条记录（observed + ignored），最适合把 `_records` 灌满。
  SoundEvent light() =>
      SoundEvent(detectedAt: clock.now, peakDb: -45, durationMs: 300);
  SoundEvent heavy() =>
      SoundEvent(detectedAt: clock.now, peakDb: -6, durationMs: 500);

  Future<void> pumpLight(int n) async {
    for (var i = 0; i < n; i++) {
      await svc.onSound(light());
    }
  }

  Iterable<String> pruneLogs() =>
      logs.where((l) => l.contains('审计记录淘汰'));

  test('R97-RC-01 条数硬上限：1200 条写入后内存只留 maxRecords 条', () async {
    await pumpLight(600); // 600 × 2 = 1200 条
    expect(
      svc.records,
      hasLength(ReactiveCounterService.maxRecords),
      reason: 'R88-AUD-06：_records 必须有硬顶，否则 7×24 守卫下进程内存无上限增长',
    );
    expect(
      svc.prunedCount,
      1200 - ReactiveCounterService.maxRecords,
      reason: '淘汰条数必须精确可数（不留静默丢弃）',
    );
    expect(
      audits,
      hasLength(1200),
      reason: '淘汰只作用于内存诊断；注入的 sink 是持久历史，一条都不能少',
    );
    expect(
      svc.records.last.status,
      'ignored',
      reason: '裁掉的必须是最旧的一端，最新一条要留住',
    );
  });

  test('R97-RC-02 时间窗：超窗记录被淘汰，窗内的保留', () async {
    await pumpLight(5); // 10 条 @T0
    expect(svc.records, hasLength(10));
    clock.advance(
        ReactiveCounterService.recordRetention + const Duration(hours: 1));
    await pumpLight(1); // 2 条 @T1
    expect(
      svc.records,
      hasLength(2),
      reason: '只限条数会让"每天几条"的慢速场景永远留着一周前的旧记录',
    );
    expect(svc.prunedCount, 10);
    expect(
      svc.records.every((r) => r.at == clock.now),
      isTrue,
      reason: '超窗的旧记录必须真的被移除，而不是靠条数上限碰巧挤掉',
    );
  });

  test('R97-RC-03 预算内不淘汰、不刷日志（避免每写一条就丢）', () async {
    await pumpLight(10); // 20 条，远低于上限且全在窗口内
    expect(svc.records, hasLength(20));
    expect(svc.prunedCount, 0, reason: '没超预算就不能有任何淘汰');
    expect(
      pruneLogs(),
      isEmpty,
      reason: '无淘汰时不得产生"淘汰"日志（否则日志本身成为噪音/静默失败的反面）',
    );
  });

  test('R97-RC-04 双约束叠加：时间窗先清旧、条数再裁溢出', () async {
    await pumpLight(100); // 200 条 @T0
    clock.advance(
        ReactiveCounterService.recordRetention + const Duration(minutes: 1));
    await pumpLight(300); // 600 条 @T1
    expect(svc.records, hasLength(ReactiveCounterService.maxRecords));
    expect(
      svc.prunedCount,
      300,
      reason: '200 条因超窗淘汰 + 100 条因溢出淘汰，两个约束都必须真的生效',
    );
    expect(
      svc.records.every((r) => r.at == clock.now),
      isTrue,
      reason: '双约束叠加后不得残留窗口外记录',
    );
    expect(
      pruneLogs().join('\n'),
      contains('累计淘汰'),
      reason: '淘汰必须留下可见痕迹（本项目的铁律：静默失败必须收敛为可见失败）',
    );
  });

  test('R97-RC-05 淘汰不改既有语义：冷却照旧，sink 历史仍在', () async {
    final first = await svc.onSound(heavy());
    expect(first.acted, isTrue);
    await pumpLight(600); // 把那条 success 记录挤出内存
    expect(
      svc.records.any((r) => r.status == 'success'),
      isFalse,
      reason: '前提：内存里确实已淘汰掉最早的反击记录',
    );
    expect(
      audits.any((a) => a.status == 'success'),
      isTrue,
      reason: '持久历史由 sink 承担，淘汰内存记录不得影响落盘',
    );
    final second = await svc.onSound(heavy());
    expect(second.acted, isFalse);
    expect(
      second.reason,
      'cooldown',
      reason: '记录淘汰不得影响冷却门控（_records 不参与任何决策）',
    );
    expect(svc.escalationStep, 0, reason: '渐进升级计数与 _records 无关，不得被淘汰影响');
  });

  test('R97-RC-06 墙钟回跳不清空记录（按 at 逐条判定，不假设有序）', () async {
    await pumpLight(5); // 10 条
    clock.advance(
        ReactiveCounterService.recordRetention + const Duration(hours: 2));
    await pumpLight(1); // 超窗淘汰 10 条，剩 2 条
    expect(svc.prunedCount, 10);
    final kept = svc.records.length;
    clock.rewind(const Duration(hours: 48)); // NTP 大幅回拨
    await pumpLight(1);
    expect(
      svc.records,
      hasLength(kept + 2),
      reason: '回跳后 cutoff 更早，不得把仍在内存里的记录误删（否则审计留痕凭空消失）',
    );
    expect(svc.prunedCount, 10, reason: '回跳不产生新的淘汰');
  });
}

// ───────────────────────── 替身 ─────────────────────────

class _Clock {
  _Clock(this._t);

  DateTime _t;

  DateTime get now => _t;

  DateTime call() => _t;

  void advance(Duration d) => _t = _t.add(d);

  void rewind(Duration d) => _t = _t.subtract(d);
}

class _FakeTimer implements CounterTimer {
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}
