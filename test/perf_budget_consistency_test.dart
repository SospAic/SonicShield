import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 压测层**预算形状**的一致性锁：**同一组里做同一份工作量的用例，必须共用同一个预算**。
///
/// ## 为什么要有这个文件（BUG-057）
///
/// `performance_v2_test.dart` 的 GT 组里，GT-01（加密）/ GT-02（解密）的预算是
/// 4000ms，而 GT-03（错密码解密）**单独写死 1500ms** —— 可 `ExportCrypto.decrypt`
/// 对错密码**照样跑满 120k 次 PBKDF2**，三条用例的工作量完全相同。
///
/// 干净机器实测（第十七轮续五，用"阈值临时置 0"逼出实测值）：
/// GT-01 = 1128ms、GT-02 = 1049ms、GT-03 = 1127ms。
/// 于是 GT-03 只剩 **1.33×** 余量，兄弟用例却有 3.5×+。
/// 机器一有 CPU 争用（本轮实测：一个残留的扫描进程）GT-03 就先红（3229ms），
/// 表现为"同一份代码时红时绿"—— 与 BUG-043 / 053 / 054 / 055 同族。
///
/// 这类缺陷的共同点是**预算的形状不对**，而形状是**可以静态检查**的：
/// 同一份工作量给不同的预算，就一定有人是拍脑袋定的。
void main() {
  final src = File('test/performance_v2_test.dart').readAsStringSync();

  /// 剥掉行注释 —— 源码契约锁必须防止被"注释掉的代码"骗过。
  String code(String s) => s.split('\n').map((l) {
        final i = l.indexOf('//');
        return i < 0 ? l : l.substring(0, i);
      }).join('\n');

  /// 取 `group('<前缀>', () { ... })` 的**组体**（大括号配对）。
  ///
  /// 注意在 `test()` 之外执行，**不能用 `expect`**（会抛 `OutsideTestException`）。
  String groupBody(String source, String prefix) {
    final i = source.indexOf("group('$prefix");
    if (i < 0) throw StateError('找不到 group `$prefix…`');
    final open = source.indexOf('{', i);
    if (open < 0) throw StateError('group `$prefix…` 没有函数体');
    var depth = 0;
    for (var j = open; j < source.length; j++) {
      final c = source[j];
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return source.substring(open, j + 1);
      }
    }
    throw StateError('group `$prefix…` 的函数体未闭合');
  }

  /// PBKDF2 组（三条用例做同一份 KDF 工作量）。
  final kdfGroup = code(groupBody(src, 'GT-灰盒 · 加密备份'));

  /// 该组里所有 `lessThanOrEqualTo(<arg>)` 的实参。
  List<String> budgetsIn(String body) => RegExp(r'lessThanOrEqualTo\(([^)]*)\)')
      .allMatches(body)
      .map((m) => m.group(1)!.trim())
      .toList();

  test('PB-01 同组内"同一份工作量"的用例必须共用**同一个**预算', () {
    final budgets = budgetsIn(kdfGroup);
    expect(budgets.length, 3,
        reason: 'PBKDF2 组应有 3 条耗时断言（加密 / 解密 / 错密码解密），'
            '实得 ${budgets.length} 条 —— 用例被改名或删除后本锁会失去覆盖');
    expect(budgets.toSet().length, 1,
        reason: '三条用例做的是**同一份 KDF 工作量**（120k 次 PBKDF2），'
            '预算却出现了 ${budgets.toSet()} —— 预算不一致必然有人是拍脑袋定的，'
            '余量最小的那条会成为假红源头（BUG-057）');
  });

  test('PB-02 该预算必须是**命名常量**，不得是散落的字面量', () {
    final budgets = budgetsIn(kdfGroup);
    for (final b in budgets) {
      expect(b, 'kdfBudgetMs',
          reason: '预算写成字面量 `$b` 就会各写各的（BUG-057 正是这么来的）；'
              '必须引用同一个命名常量，让"改预算"成为一次显式动作');
    }
    expect(kdfGroup.contains('const kdfBudgetMs'), isTrue,
        reason: '找不到 `const kdfBudgetMs` 的声明');
  });

  test('PB-03 红灯必须自带实测值（否则又要靠"阈值置 0"取证）', () {
    // 本轮为了拿到真实耗时，不得不把三个阈值临时改成 0 逼出 Actual ——
    // 那是有效但昂贵的手法。断言里直接插值实测值，红灯时一眼就能看到数字。
    final withActual = RegExp(r'实测 \$\{sw\.elapsedMilliseconds\}ms')
        .allMatches(kdfGroup)
        .length;
    expect(withActual, 3,
        reason: '只有 $withActual 条断言在 reason 里带上了实测耗时；'
            '应为 3 —— 性能红灯必须先能读到数字，再谈怀疑阈值还是怀疑代码');
  });

  test('PB-04 预算不得低于实测基线 × 3（本组基线 ≈1.1s）', () {
    final m = RegExp(r'const kdfBudgetMs = (\d+)').firstMatch(kdfGroup);
    expect(m, isNotNull, reason: '`kdfBudgetMs` 必须是可解析的整数字面量');
    final budget = int.parse(m!.group(1)!);
    // 基线来自"阈值置 0"实测：三条用例 1049–1128ms，取上限 1128ms 作基线。
    const measuredBaselineMs = 1128;
    expect(budget, greaterThanOrEqualTo(measuredBaselineMs * 3),
        reason: '预算 ${budget}ms 不足实测基线 ${measuredBaselineMs}ms 的 3 倍 —— '
            'JIT 层余量必须显著大于噪声幅度（本轮 CPU 争用把耗时抬到 2.9×），'
            '否则机器一忙就假红');
  });
}
