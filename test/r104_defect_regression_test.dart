// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/core/constants.dart';

/// R104 / BUG-154,156 回归锁。
///
/// BUG-154：设置页文案承诺「只能把免打扰窗口调窄，不能调宽」，
/// BUG-107 当年只把**开始**从 20..23 收到 22..23，**结束**却仍停在
/// 5..9 —— 选 8/9 会把默认 22:00–07:00 拉成 22:00–09:00（更宽）。
/// 修法是把结束上界钉在默认 7，并从 `ComplianceGuardrails` 派生。
///
/// BUG-156：既有「固定一次」任务的日期一旦过期，点日期选择器会把
/// `_fixedOnceDate` 直接当 `initialDate` 传给 `showDatePicker`，
/// 而 firstDate 是昨天 ⇒ Flutter 断言崩，用户连改日期的机会都没有。
/// 修法是把 initialDate 夹进 [firstDate, lastDate]。
void main() {
  const uiSettings = 'lib/features/settings/settings_screen.dart';
  const uiTaskEditor = 'lib/features/tasks/task_editor_screen.dart';

  /// 跨午夜窗口宽度（小时）。22:00–07:00 ⇒ 9。
  int width(int start, int end) => (end + 24 - start) % 24;

  group('QW · 免打扰窗口「只能调窄」护栏（BUG-154）', () {
    test('QW-01 结束上界必须等于默认结束小时，下界必须更小', () {
      expect(ComplianceGuardrails.maxQuietEndHour,
          ComplianceGuardrails.defaultQuietEndHour,
          reason: '结束上界一旦超过 7，用户就能把窗口调宽');
      expect(ComplianceGuardrails.minQuietEndHour,
          lessThan(ComplianceGuardrails.defaultQuietEndHour));
      expect(ComplianceGuardrails.minQuietStartHour,
          ComplianceGuardrails.defaultQuietStartHour,
          reason: 'BUG-107 的开始端护栏不得回退');
    });

    test('QW-02 ★ 遍历全部可选项：窗口宽度一律不超过默认', () {
      final defaultWidth = width(ComplianceGuardrails.defaultQuietStartHour,
          ComplianceGuardrails.defaultQuietEndHour);
      var checked = 0;
      for (var s = ComplianceGuardrails.minQuietStartHour;
          s <= ComplianceGuardrails.maxQuietStartHour;
          s++) {
        for (var e = ComplianceGuardrails.minQuietEndHour;
            e <= ComplianceGuardrails.maxQuietEndHour;
            e++) {
          expect(width(s, e), lessThanOrEqualTo(defaultWidth),
              reason: '$s:00–$e:00 比默认 22:00–07:00 更宽 ⇒ 违反页面承诺');
          checked++;
        }
      }
      expect(checked, greaterThan(0), reason: '空转自检：必须真的遍历过组合');
    });

    test('QW-90 反面样本：旧区间 5..9 里的 8/9 确实会调宽', () {
      final defaultWidth = width(22, 7);
      var violations = 0;
      for (var e = 5; e <= 9; e++) {
        if (width(22, e) > defaultWidth) violations++;
      }
      expect(violations, 2,
          reason: '若一条都不违规，说明 QW-02 是恒真锁，没有意义');
    });

    test('QW-03 源码契约：设置页结束下拉不硬编码 5..9', () {
      final f = File(uiSettings);
      expect(f.existsSync(), isTrue, reason: '找不到设置页');
      final src = f.readAsStringSync();
      expect(src, isNot(contains('for (var h = 5; h <= 9; h++)')),
          reason: 'BUG-154 复发：结束下拉又写死了 5..9');
      expect(src, isNot(contains('if (_quietEnd < 5 || _quietEnd > 9)')));
      expect(src, contains('ComplianceGuardrails.minQuietEndHour'));
      expect(src, contains('ComplianceGuardrails.maxQuietEndHour'));
    });
  });

  group('DP · 固定一次日期选择器（BUG-156）', () {
    test('DP-01 源码契约：initialDate 必须是夹取后的值', () {
      final f = File(uiTaskEditor);
      expect(f.existsSync(), isTrue, reason: '找不到任务编辑器');
      final src = f.readAsStringSync();
      expect(src, contains('final initial = _fixedOnceDate.isBefore(first)'),
          reason: '少了夹取 ⇒ 过期任务一点日历就抛断言');
      expect(src, contains('initialDate: initial,'));
      expect(src, isNot(contains('initialDate: _fixedOnceDate,')));
      expect(src, contains('firstDate: first,'));
      expect(src, contains('lastDate: last,'));
    });

    test('DP-90 反面样本：还原旧写法能被判红', () {
      final src = File(uiTaskEditor).readAsStringSync();
      final reverted = src.replaceFirst('initialDate: initial,',
          'initialDate: _fixedOnceDate,');
      expect(reverted, isNot(src), reason: '反面样本构造失败 ⇒ 锁失去意义');
      expect(reverted, contains('initialDate: _fixedOnceDate,'),
          reason: '还原成 BUG-156 后 DP-01 必须能抓到');
    });
  });
}