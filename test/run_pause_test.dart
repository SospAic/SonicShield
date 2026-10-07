import 'package:flutter_test/flutter_test.dart';

import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/scheduling/china_holidays.dart';
import 'package:sonic_shield/domain/scheduling/run_pause.dart';

/// 「全局执行总开关（节假日自动暂停）」的**纯函数**测试（v79，docs/20 §9）。
///
/// ## 为什么必须钉死窗口边界
///
/// 这个开关会让**全部任务整体停摆** —— 判错一天就是"该停时没停 / 该跑时没跑"。
/// 语义描述（"法定休息日前一天晚上 8 点到休息日最后一天晚上 9 点"）是给人读的，
/// 落到代码上是**半开区间** `[起点当天 20:00, 终点当天 21:00)`。半开区间靠文字
/// 最容易记错（是"含 20:00 不含 21:00"还是反过来？），因此这里把 20:00/20:59/
/// 21:00/21:01 四个临界点逐一刻死。
///
/// ## 构造方式：全量覆盖的合成日历
///
/// 判据真源 `ChinaHolidays.dayKind` 的优先级是
/// 手动覆盖 > 自动表 > 内置表 > 按星期几。为了让用例**不依赖内置表年份**、
/// 也不被真实周末干扰，这里用 [cal] 造一张"除点名休息日外全为工作日"的覆盖表
/// （覆盖 2030–2031 两年，足够 `nextStart` 的 400 天扫描），
/// 于是每个场景的"连续休息日块"完全由本文件决定。
void main() {
  /// 合成日历：`2030-01-01` 起两年，**默认全部工作日**，只有 [rest] 里的日子是休息日。
  Map<String, DayKind> cal({Set<String> rest = const {}}) {
    final out = <String, DayKind>{};
    var d = DateTime(2030, 1, 1);
    final end = DateTime(2032, 1, 1);
    while (d.isBefore(end)) {
      final iso = ChinaHolidays.isoDate(d);
      out[iso] = rest.contains(iso) ? DayKind.restday : DayKind.workday;
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return out;
  }

  // 常用块：2030-03-23(六) + 03-24(日)，前后都是工作日。
  final weekend = cal(rest: {'2030-03-23', '2030-03-24'});
  final longBreak = cal(rest: {
    '2030-03-23',
    '2030-03-24',
    '2030-03-25',
    '2030-03-26',
    '2030-03-27',
  });
  final singleDay = cal(rest: {'2030-03-23'});
  // 调休补班：周六(03-23)是工作日，周日(03-24)休息。
  final makeupSat = cal(rest: {'2030-03-24'});

  group('RP 窗口判定（inWindow）', () {
    test('RP-01 普通周末：周五 20:00 开始 → 周日 21:00 结束（半开区间）', () {
      bool w(int day, int hour, [int minute = 0]) => RunPause.inWindow(
          DateTime(2030, 3, day, hour, minute),
          overrides: weekend);

      expect(w(22, 19, 59), isFalse, reason: '前夜 20:00 之前不暂停');
      expect(w(22, 20, 0), isTrue, reason: '20:00 整点必须进入暂停');
      expect(w(22, 23, 0), isTrue);
      expect(w(23, 12, 0), isTrue, reason: '块中间全天暂停');
      expect(w(24, 20, 59), isTrue, reason: '终点前 1 分钟仍在窗口');
      expect(w(24, 21, 0), isFalse, reason: '21:00 整点必须恢复执行');
      expect(w(25, 12, 0), isFalse, reason: '块结束次日不暂停');
    });

    test('RP-02 连续长假：起点前一天 20:00 → 末天 21:00（整块连续）', () {
      bool w(int day, int hour, [int minute = 0]) => RunPause.inWindow(
          DateTime(2030, 3, day, hour, minute),
          overrides: longBreak);

      expect(w(22, 20, 0), isTrue);
      expect(w(25, 3, 0), isTrue, reason: '块中间任意时刻都暂停');
      expect(w(27, 20, 59), isTrue);
      expect(w(27, 21, 0), isFalse);
      expect(w(28, 10, 0), isFalse);
    });

    test('RP-03 单日休息：前一天 20:00 → 当天 21:00', () {
      bool w(int day, int hour, [int minute = 0]) => RunPause.inWindow(
          DateTime(2030, 3, day, hour, minute),
          overrides: singleDay);

      expect(w(22, 19, 59), isFalse);
      expect(w(22, 20, 0), isTrue);
      expect(w(23, 20, 59), isTrue);
      expect(w(23, 21, 0), isFalse);
    });

    test('RP-04 调休补班周六（工作日）打断块：窗口从周日前夜起', () {
      bool w(int day, int hour, [int minute = 0]) => RunPause.inWindow(
          DateTime(2030, 3, day, hour, minute),
          overrides: makeupSat);

      expect(w(23, 12, 0), isFalse, reason: '补班周六是工作日，白天不暂停');
      expect(w(23, 20, 0), isTrue, reason: '周日前夜 20:00 起暂停');
      expect(w(24, 20, 59), isTrue);
      expect(w(24, 21, 0), isFalse);
    });

    test('RP-05 整张工作日表 ⇒ 任何时候都不暂停', () {
      final allWork = cal();
      expect(RunPause.inWindow(DateTime(2030, 6, 1, 12), overrides: allWork),
          isFalse);
      expect(RunPause.inWindow(DateTime(2030, 6, 1, 20, 30), overrides: allWork),
          isFalse);
    });
  });

  group('RP 模式（paused）', () {
    final inWindowAt = DateTime(2030, 3, 23, 12); // 块中间
    final outWindowAt = DateTime(2030, 3, 20, 12); // 工作日白天

    test('RP-10 auto 跟随窗口', () {
      expect(RunPause.paused(RunMasterMode.auto, inWindowAt, overrides: weekend),
          isTrue);
      expect(
          RunPause.paused(RunMasterMode.auto, outWindowAt, overrides: weekend),
          isFalse);
    });

    test('RP-11 on 恒运行（即使正在窗口内）', () {
      expect(RunPause.paused(RunMasterMode.on, inWindowAt, overrides: weekend),
          isFalse);
    });

    test('RP-12 off 恒暂停（即使窗口外）', () {
      expect(RunPause.paused(RunMasterMode.off, outWindowAt, overrides: weekend),
          isTrue);
    });
  });

  group('RP 解析（RunMasterMode.parse 容错）', () {
    test('RP-20 合法值与大小写/空白', () {
      expect(RunMasterMode.parse('auto'), RunMasterMode.auto);
      expect(RunMasterMode.parse('on'), RunMasterMode.on);
      expect(RunMasterMode.parse(' OFF '), RunMasterMode.off);
      expect(RunMasterMode.parse(RunMasterMode.off), RunMasterMode.off);
    });

    test('RP-21 读不懂一律回落 auto（不抛）', () {
      for (final bad in [null, 3, '', 'garbage', <String>['on'], true]) {
        expect(RunMasterMode.parse(bad), RunMasterMode.auto, reason: '$bad');
      }
    });

    test('RP-22 label 非空（UI 展示依赖）', () {
      for (final m in RunMasterMode.values) {
        expect(m.label.trim(), isNotEmpty);
      }
    });
  });

  group('RP 边界时刻（windowEnd / nextStart / nextTransition）', () {
    test('RP-30 暂停中：下次切换 = 当前窗口终点', () {
      expect(RunPause.windowEnd(DateTime(2030, 3, 23, 12), overrides: weekend),
          DateTime(2030, 3, 24, 21));
      expect(
          RunPause.nextTransition(RunMasterMode.auto, DateTime(2030, 3, 23, 12),
              overrides: weekend),
          DateTime(2030, 3, 24, 21));
    });

    test('RP-31 运行中：下次切换 = 下一个窗口起点', () {
      expect(RunPause.windowEnd(DateTime(2030, 3, 20, 12), overrides: weekend),
          isNull, reason: '窗口外没有"当前窗口终点"');
      expect(
          RunPause.nextTransition(RunMasterMode.auto, DateTime(2030, 3, 20, 12),
              overrides: weekend),
          DateTime(2030, 3, 22, 20));
    });

    test('RP-32 on/off 无自动切换 ⇒ null', () {
      expect(
          RunPause.nextTransition(RunMasterMode.on, DateTime(2030, 3, 23, 12),
              overrides: weekend),
          isNull);
      expect(
          RunPause.nextTransition(RunMasterMode.off, DateTime(2030, 3, 20, 12),
              overrides: weekend),
          isNull);
    });

    test('RP-33 扫描范围内无休息日 ⇒ 无下次切换', () {
      final allWork = cal();
      expect(
          RunPause.nextTransition(RunMasterMode.auto, DateTime(2030, 3, 20, 12),
              overrides: allWork),
          isNull);
    });

    test('RP-34 刚过窗口起点：跳过"当天已过去"的起点，取其后的块', () {
      // 两个块：03-23/24 与 03-30/31。at = 03-22 21:00 已在第一个块的窗口内
      //（起点 03-22 20:00 已过去）；nextStart 必须跳过它、给出 03-29 20:00，
      // 而不是把已过去的 03-22 20:00 当成"下次"。
      final twoBlocks = cal(rest: {
        '2030-03-23',
        '2030-03-24',
        '2030-03-30',
        '2030-03-31',
      });
      expect(RunPause.nextStart(DateTime(2030, 3, 22, 21), overrides: twoBlocks),
          DateTime(2030, 3, 29, 20));
    });
  });

  group('RP 常量', () {
    test('RP-40 窗口钟点与文档一致', () {
      expect(RunPause.windowStartHour, 20);
      expect(RunPause.windowEndHour, 21);
    });
  });
}
