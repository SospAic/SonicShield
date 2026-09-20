import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/services/condition_env.dart';

/// 条件层"每轮复用"回归锁（BUG-044）。
///
/// ## 锁的是什么
///
/// 一次条件评估原本逐任务读 4 次平台状态（电量/充电/通话/网络），
/// 每读一次就是一次**平台通道往返**（设备上 ≈1.5–2ms）。
/// 调度引擎一轮遍历 N 个到期任务 → **4N 次往返**。
///
/// 改造后一轮只读一次（固定 4 次，与 N 解耦）。本文件把这条性质
/// **变成可断言的行为**：没有 `RoundConditionEnv.readCount`，
/// 这个优化只能靠读代码相信。
///
/// ## 边界（诚实说明）
///
/// 本文件锁的是**复用机制本身**与**判定逻辑的等价性**；
/// "引擎的 `executeDue()` 确实用了这个机制"属于接线，由代码审查 +
/// `flutter analyze` 保证（引擎的闭包运行在后台 isolate，无法直接单测）。
void main() {
  group('RoundConditionEnv：每轮只读一次', () {
    test('取 N 次只触发 1 次平台读取（核心性质）', () async {
      var calls = 0;
      final env = RoundConditionEnv(read: () async {
        calls++;
        return const ConditionEnv(batteryLevel: 42, inCall: true);
      });

      for (var i = 0; i < 7; i++) {
        await env.value;
      }

      expect(env.readCount, 1,
          reason: '一轮内 7 个任务应当只读 1 次平台状态；'
              '若这里是 7，说明"每轮复用"退回了逐任务读取（4N 次往返）');
      expect(calls, 1, reason: '注入的读取函数也必须只被调用 1 次');
    });

    test('多次取回的是**同一个**快照实例（不是重新读出来的等值对象）', () async {
      final env = RoundConditionEnv(
        read: () async => const ConditionEnv(batteryLevel: 7),
      );
      final a = await env.value;
      final b = await env.value;
      expect(identical(a, b), isTrue,
          reason: '必须复用同一实例；若返回新的等值对象，'
              '说明读取虽被缓存但调用方拿到的不是快照');
    });

    test('惰性：从不取值则一次平台读取都不发生', () async {
      var calls = 0;
      final env = RoundConditionEnv(read: () async {
        calls++;
        return const ConditionEnv();
      });

      expect(env.readCount, 0);
      expect(calls, 0,
          reason: '一轮里若没有任何任务需要评估条件（例如全部计划都被'
              '"过期丢弃"分支 continue 掉），不应产生任何平台开销');
      // 显式"用一下"以确保上面的 0 不是因为根本没走到读取路径
      await env.value;
      expect(calls, 1);
    });

    test('并发在途取值也只读一次（await 期间不会重复触发）', () async {
      var calls = 0;
      final env = RoundConditionEnv(read: () async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return const ConditionEnv(batteryLevel: 55);
      });

      final results = await Future.wait([env.value, env.value, env.value]);

      expect(calls, 1, reason: '并发首次取值必须只读一次');
      expect(identical(results[0], results[1]), isTrue);
      expect(identical(results[1], results[2]), isTrue);
    });
  });

  group('ConditionEnv：默认值等于改造前的引擎初值', () {
    // 改造前引擎的初值：level = 100 / charging = false / inCall = null / onWifi = null。
    // 默认构造必须逐字复刻这组值，否则"平台读不到"时的行为会悄悄改变。
    const env = ConditionEnv();

    test('默认值逐字复刻改造前的初值', () {
      expect(env.batteryLevel, 100);
      expect(env.charging, isFalse);
      expect(env.inCall, isNull);
      expect(env.onWifi, isNull);
    });

    test('电量读不到（默认 100）→ 电量条件视为满足', () {
      const c = TaskCondition(minBatteryPct: 50);
      expect(c.firstUnmetIn(env, now: DateTime(2026, 9, 18, 12)), isNull);
    });

    test('通话读不到（null）→ 通话保护不拦（无法判定按满足，BUG-041 约定）', () {
      const c = TaskCondition(skipInCall: true);
      expect(c.firstUnmetIn(env, now: DateTime(2026, 9, 18, 12)), isNull,
          reason: 'null 是"无法判定"而非"没在通话"；'
              '若这里返回原因，等于把读不到状态误报成不满足');
    });

    test('网络读不到（null）→ Wi-Fi 条件不拦（BUG-041 约定）', () {
      const c = TaskCondition(requireWifi: true);
      expect(c.firstUnmetIn(env, now: DateTime(2026, 9, 18, 12)), isNull);
    });

    test('充电条件在无电池平台上**仍会**拦下（保留原行为，未放宽）', () {
      const c = TaskCondition(requireCharging: true);
      expect(c.firstUnmetIn(env, now: DateTime(2026, 9, 18, 12)), '未充电',
          reason: 'charging 默认 false 是改造前就有的行为，'
              '本次重构不得顺手把它改成"视为满足"');
    });
  });

  group('firstUnmetIn 与 firstUnmet 等价（判定逻辑只有一份）', () {
    test('穷举一组条件 × 环境，两条路径结论完全一致', () {
      final now = DateTime(2026, 9, 18, 14, 30); // 14:30 → 870 分钟
      final conditions = <TaskCondition>[
        const TaskCondition(),
        const TaskCondition(skipInCall: false),
        const TaskCondition(requireCharging: true),
        const TaskCondition(minBatteryPct: 50),
        const TaskCondition(requireWifi: true),
        const TaskCondition(windowStartMin: 600, windowEndMin: 900),
        const TaskCondition(windowStartMin: 1200, windowEndMin: 300), // 跨零点
        const TaskCondition(
          requireCharging: true,
          minBatteryPct: 80,
          requireWifi: true,
          skipInCall: true,
          windowStartMin: 0,
          windowEndMin: 1439,
        ),
      ];
      final envs = <ConditionEnv>[
        const ConditionEnv(),
        const ConditionEnv(batteryLevel: 5, charging: false),
        const ConditionEnv(batteryLevel: 100, charging: true),
        const ConditionEnv(inCall: true),
        const ConditionEnv(inCall: false),
        const ConditionEnv(onWifi: true),
        const ConditionEnv(onWifi: false),
        const ConditionEnv(
            batteryLevel: 30, charging: true, inCall: true, onWifi: false),
      ];

      var checked = 0;
      for (final c in conditions) {
        for (final e in envs) {
          final viaEnv = c.firstUnmetIn(e, now: now);
          final viaRaw = c.firstUnmet(
            charging: e.charging,
            batteryLevel: e.batteryLevel,
            now: now,
            inCall: e.inCall,
            onWifi: e.onWifi,
          );
          expect(viaEnv, viaRaw,
              reason: '条件 ${c.describe()} × 环境 $e 两条路径结论不一致 '
                  '→ 说明判定逻辑被复制成了两份，必然漂移');
          checked++;
        }
      }
      expect(checked, conditions.length * envs.length);
    });
  });

  group('now 不进快照：时段窗口仍按真实时刻判定', () {
    test('同一快照配不同 now → 窗口内外结论正确翻转', () {
      // 窗口 10:00–11:00（600–660）
      const c = TaskCondition(windowStartMin: 600, windowEndMin: 660);
      const env = ConditionEnv();

      expect(c.firstUnmetIn(env, now: DateTime(2026, 9, 18, 10, 30)), isNull,
          reason: '10:30 在窗口内');
      expect(c.firstUnmetIn(env, now: DateTime(2026, 9, 18, 9, 30)), '不在时段窗口内');
      expect(c.firstUnmetIn(env, now: DateTime(2026, 9, 18, 12, 0)), '不在时段窗口内');
    });
  });

  group('firstUnmetIn 的判定优先级与 firstUnmet 一致', () {
    test('通话中优先于其它原因被报出（排障要的是最直接的那个）', () {
      const c = TaskCondition(
        requireCharging: true,
        minBatteryPct: 90,
        requireWifi: true,
        skipInCall: true,
      );
      const env = ConditionEnv(
          batteryLevel: 10, charging: false, inCall: true, onWifi: false);
      expect(c.firstUnmetIn(env, now: DateTime(2026, 9, 18, 12)), '通话中（不打扰通话）');
    });
  });
}
