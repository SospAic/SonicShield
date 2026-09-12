import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/trigger.dart';

/// 免打扰时间窗边界测试（合规护栏的核心正确性）。
void main() {
  group('inDailyWindow', () {
    test('普通窗口（同日）', () {
      const s = TimeSpec(hour: 9);
      const e = TimeSpec(hour: 18);
      DateTime at(int h, int m) => DateTime(2026, 9, 12, h, m);
      expect(inDailyWindow(s, e, false, at(9, 0)), isTrue);
      expect(inDailyWindow(s, e, false, at(12, 30)), isTrue);
      expect(inDailyWindow(s, e, false, at(17, 59)), isTrue);
      expect(inDailyWindow(s, e, false, at(18, 0)), isFalse); // 右开
      expect(inDailyWindow(s, e, false, at(8, 59)), isFalse);
    });

    test('跨午夜窗口（endNextDay）', () {
      const s = TimeSpec(hour: 20);
      const e = TimeSpec(hour: 2);
      DateTime at(int h, int m) => DateTime(2026, 9, 12, h, m);
      expect(inDailyWindow(s, e, true, at(20, 0)), isTrue);
      expect(inDailyWindow(s, e, true, at(23, 59)), isTrue);
      expect(inDailyWindow(s, e, true, at(1, 59)), isTrue);
      expect(inDailyWindow(s, e, true, at(2, 0)), isFalse);
      expect(inDailyWindow(s, e, true, at(12, 0)), isFalse);
    });
  });

  group('resolveQuiet（免打扰处理）', () {
    // 免打扰 22:00 - 07:00（跨午夜）
    final qs = DateTime(2026, 9, 11, 22);
    final qe = DateTime(2026, 9, 12, 7);

    test('窗口外原样返回', () {
      final t = DateTime(2026, 9, 12, 12);
      expect(resolveQuiet(t, qs, qe, QuietPolicy.skip), t);
    });

    test('窗口内 + skip => null（丢弃）', () {
      final t = DateTime(2026, 9, 12, 3, 30);
      expect(resolveQuiet(t, qs, qe, QuietPolicy.skip), isNull);
    });

    test('窗口内 + shift => 平移到免打扰结束点', () {
      final t = DateTime(2026, 9, 12, 3, 30);
      final r = resolveQuiet(t, qs, qe, QuietPolicy.shift);
      expect(r, DateTime(2026, 9, 12, 7));
    });

    test('左闭右开：结束点本身不在免打扰内', () {
      final t = qe; // 07:00
      expect(resolveQuiet(t, qs, qe, QuietPolicy.skip), t);
    });

    test('shift 语义：窗口内任意时刻平移到免打扰结束点（过期判定由引擎层完成）', () {
      final t = DateTime(2026, 9, 10, 23); // 落在 9/10 22:00 ~ 9/11 07:00 窗口内
      final oldQs = DateTime(2026, 9, 10, 22);
      final oldQe = DateTime(2026, 9, 11, 7);
      final now = DateTime(2026, 9, 12, 12);
      expect(resolveQuiet(t, oldQs, oldQe, QuietPolicy.shift), oldQe);
      // now 已晚于平移目标：引擎层 materialize 会丢弃该过期条目（防补执行风暴）。
      expect(now.isAfter(oldQe), isTrue);
    });
  });
}
