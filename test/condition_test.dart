import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/condition.dart';

/// 任务条件层契约测试（v1.3 基础 + v1.7 新增「仅 Wi-Fi」「通话中不执行」）。
///
/// ## 本文件锁定的核心不变量
///
/// 1. **通话中不执行默认开启**（安全默认）：定时音频灌进通话对双方都是干扰，
///    且使用者无法预期。行业领先的自动化工具（MacroDroid 的 Call State 约束、
///    Tasker 的 Call 状态）都把通话状态作为一等条件。
/// 2. **无法判定时按"满足"处理**（`inCall`/`onWifi` 传 null）：
///    与既有代码对电池条件的约定一致（"无电池平台视为满足"），
///    避免某个平台读不到状态就把全部自动化静默停掉。
///    Android 侧始终能判定（走 `AudioManager.mode`，无需权限），故防护不受影响。
/// 3. **`firstUnmet` 给出的是"为什么没执行"**，而不是"配了哪些条件" ——
///    审计与排障要的是前者。
void main() {
  final now = DateTime(2026, 9, 18, 12, 0);

  /// 便捷调用：默认"未充电 / 电量 100 / 无通话 / 在 Wi-Fi"。
  String? unmet(
    TaskCondition c, {
    bool charging = false,
    int battery = 100,
    bool? inCall = false,
    bool? onWifi = true,
    DateTime? at,
  }) =>
      c.firstUnmet(
        charging: charging,
        batteryLevel: battery,
        now: at ?? now,
        inCall: inCall,
        onWifi: onWifi,
      );

  group('CC 通话保护（v1.7 安全默认）', () {
    test('CC-01 默认构造即开启通话保护', () {
      const c = TaskCondition();
      expect(c.skipInCall, isTrue);
      expect(c.hasAny, isTrue, reason: '默认条件本身就构成一条护栏');
    });

    test('CC-02 通话中 → 阻止执行，且原因可读', () {
      const c = TaskCondition();
      expect(unmet(c, inCall: true), contains('通话中'));
      expect(
          c.evaluate(
              charging: false, batteryLevel: 100, now: now, inCall: true),
          isFalse);
    });

    test('CC-03 未通话 → 放行', () {
      const c = TaskCondition();
      expect(unmet(c, inCall: false), isNull);
    });

    test('CC-04 通话状态无法判定（null）→ 按未通话处理（与电池条件约定一致）', () {
      const c = TaskCondition();
      expect(unmet(c, inCall: null), isNull);
    });

    test('CC-05 显式关闭后，通话中也不再阻止', () {
      const c = TaskCondition(skipInCall: false);
      expect(unmet(c, inCall: true), isNull);
    });

    test('CC-06 通话保护优先于其他条件报告（先报最要紧的原因）', () {
      const c = TaskCondition(skipInCall: true, requireCharging: true);
      // 同时"通话中"且"未充电" → 应报通话（对使用者的干扰更直接）
      expect(unmet(c, inCall: true, charging: false), contains('通话中'));
    });
  });

  group('CC Wi-Fi 条件（v1.7）', () {
    test('CC-10 默认不要求 Wi-Fi', () {
      const c = TaskCondition();
      expect(c.requireWifi, isFalse);
      expect(unmet(c, onWifi: false), isNull);
    });

    test('CC-11 要求 Wi-Fi 且当前是移动网络 → 阻止，原因指明不在 Wi-Fi', () {
      const c = TaskCondition(requireWifi: true);
      expect(unmet(c, onWifi: false), contains('Wi-Fi'));
    });

    test('CC-12 要求 Wi-Fi 且在 Wi-Fi 下 → 放行', () {
      const c = TaskCondition(requireWifi: true);
      expect(unmet(c, onWifi: true), isNull);
    });

    test('CC-13 网络状态无法判定（null）→ 按满足处理，不静默停掉自动化', () {
      const c = TaskCondition(requireWifi: true);
      expect(unmet(c, onWifi: null), isNull);
    });
  });

  group('CC 既有条件回归（v1.3 行为不得改变）', () {
    test('CC-20 仅充电：未充电阻止，充电放行', () {
      const c = TaskCondition(requireCharging: true, skipInCall: false);
      expect(unmet(c, charging: false), contains('未充电'));
      expect(unmet(c, charging: true), isNull);
    });

    test('CC-21 最低电量：低于阈值阻止，且原因含具体数值', () {
      const c = TaskCondition(minBatteryPct: 30, skipInCall: false);
      final r = unmet(c, battery: 12);
      expect(r, contains('12'));
      expect(r, contains('30'));
      expect(unmet(c, battery: 30), isNull, reason: '等于阈值应放行');
    });

    test('CC-22 时段窗口：窗口外阻止，窗口内放行', () {
      // 08:00–10:00，now = 12:00 → 窗口外
      const c = TaskCondition(
          windowStartMin: 8 * 60, windowEndMin: 10 * 60, skipInCall: false);
      expect(unmet(c), contains('时段窗口'));
      expect(unmet(c, at: DateTime(2026, 9, 18, 9, 0)), isNull);
    });

    test('CC-23 跨零点窗口：22:00–07:00 在 23:00 与 06:00 均放行，12:00 阻止', () {
      const c = TaskCondition(
          windowStartMin: 22 * 60, windowEndMin: 7 * 60, skipInCall: false);
      expect(unmet(c, at: DateTime(2026, 9, 18, 23, 0)), isNull);
      expect(unmet(c, at: DateTime(2026, 9, 18, 6, 0)), isNull);
      expect(unmet(c, at: DateTime(2026, 9, 18, 12, 0)), contains('时段窗口'));
    });

    test('CC-24 windowEndNextDay 标志不改变跨零点判定（两种写法等价）', () {
      const a = TaskCondition(
          windowStartMin: 22 * 60,
          windowEndMin: 7 * 60,
          windowEndNextDay: true,
          skipInCall: false);
      const b = TaskCondition(
          windowStartMin: 22 * 60,
          windowEndMin: 7 * 60,
          windowEndNextDay: false,
          skipInCall: false);
      for (final h in [0, 6, 12, 23]) {
        final t = DateTime(2026, 9, 18, h, 0);
        expect(unmet(a, at: t), unmet(b, at: t), reason: 'h=$h 应一致');
      }
    });
  });

  group('CC 序列化与升级兼容', () {
    test('CC-30 新字段可完整往返', () {
      const c = TaskCondition(requireWifi: true, skipInCall: false);
      final back = TaskCondition.fromJsonOrNull(
          '{"requireWifi":true,"skipInCall":false}')!;
      expect(back.requireWifi, isTrue);
      expect(back.skipInCall, isFalse);
      expect(c.toJson()['requireWifi'], isTrue);
      expect(c.toJson()['skipInCall'], isFalse);
    });

    test('CC-31 老数据缺新键 → skipInCall 取默认 true（老任务自动获得通话保护）', () {
      final back = TaskCondition.fromJsonOrNull(
          '{"requireCharging":true,"minBatteryPct":20}')!;
      expect(back.skipInCall, isTrue, reason: '缺键时必须取安全默认');
      expect(back.requireWifi, isFalse);
      expect(back.requireCharging, isTrue);
    });

    test('CC-32 损坏 JSON → 返回 null（视为无条件，不阻塞执行）', () {
      expect(TaskCondition.fromJsonOrNull('{not json'), isNull);
      expect(TaskCondition.fromJsonOrNull(''), isNull);
      expect(TaskCondition.fromJsonOrNull(null), isNull);
    });

    test('CC-33 describe() 汇总已启用条件，供 UI/审计展示', () {
      const c = TaskCondition(
          requireWifi: true, skipInCall: true, requireCharging: true);
      final d = c.describe();
      expect(d, contains('通话中不执行'));
      expect(d, contains('仅 Wi-Fi'));
      expect(d, contains('仅充电'));

      expect(const TaskCondition(skipInCall: false).describe(), '无条件');
    });
  });
}
