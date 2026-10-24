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

  /// 该组里所有 `_expectGuarded(<caseId>, <bench>, <budget>)` 调用的**条数**。
  ///
  /// R94 / QUA-02 起，三条用例不再各写一遍 `expect(bestMs,
  /// lessThanOrEqualTo(budget))`，而是统一走共用助手 `_expectGuarded`
  /// （预热 + min-of-N + 负载定性 + reason 带实测值，全部收敛在一处）。
  /// 锁随之改成按**新形状**扫描 —— 判据一条都没放松，反而更严：
  /// 组内出现绕过助手的内联 `lessThanOrEqualTo` 会被 PB-03 抓到。
  int guardedCalls(String body) =>
      RegExp(r'_expectGuarded\s*\(').allMatches(body).length;

  /// 该组里所有 `_expectGuarded(...)` 的**预算实参**（第三个位置参数）。
  List<String> budgetsIn(String body) => RegExp(r'_expectGuarded\s*\(\s*'
            r'[^,]+,\s*' // caseId
            r'[^,]+,\s*' // GuardedBench
            r'([^,)]+)') // budgetMs
        .allMatches(body)
        .map((m) => m.group(1)!.trim())
        .toList();

  test('PB-01 同组内"同一份工作量"的用例必须共用**同一个**预算', () {
    final budgets = budgetsIn(kdfGroup);
    expect(guardedCalls(kdfGroup), 3,
        reason: 'PBKDF2 组应有 3 条走 `_expectGuarded` 的耗时断言'
            '（加密 / 解密 / 错密码解密），实得 ${guardedCalls(kdfGroup)} 条 —— '
            '用例被改名或删除后本锁会失去覆盖');
    expect(budgets.length, 3,
        reason: '预算实参应能解析出 3 个，实得 ${budgets.length} 个');
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

  /// `_expectGuarded` 助手自身的函数体（从定义处取到 `void main()` 之前）。
  ///
  /// 为什么要单独取它：PB-03 的判据已经从"每条用例的 reason 里手插值实测值"
  /// 变成"共用助手必须插值实测值"。取不到助手体 ⇒ 锁失去锚点 ⇒ 判红，
  /// 不许"没找到就放行"。
  final helperBody = code(() {
    final i = src.indexOf('void _expectGuarded(');
    if (i < 0) return '';
    final j = src.indexOf('void main()', i);
    return src.substring(i, j < 0 ? src.length : j);
  }());

  test('PB-03 红灯必须自带实测值（否则又要靠"阈值置 0"取证）', () {
    // 早期做法是在**每条** reason 里手插值 `实测 ${sw.elapsedMilliseconds}ms`；
    // R94 / QUA-02 收敛到共用助手后，改判三件事（合起来等价且更严）：
    //   ① 三条用例**都走了** `_expectGuarded`（PB-01 已锁 3 条）；
    //   ② 助手自己的 reason 里**插值了实测最优值与预算**；
    //   ③ 组内**没有**绕过助手的内联 `lessThanOrEqualTo` —— 否则那条用例
    //      就既拿不到 min-of-N 也拿不到实测值，正是本条要防的形状。
    expect(helperBody.contains('void _expectGuarded('), isTrue,
        reason: '在 performance_v2_test.dart 里找不到 `_expectGuarded` 的定义 '
            '—— PB-03 失去锚点，必须判红');
    expect(helperBody.contains(r'${b.bestMs'), isTrue,
        reason: '`_expectGuarded` 的 reason 必须插值实测最优值'
            '（形如 `\${\$b.bestMs}` 的插值）—— 否则性能红灯读不到数字，'
            '只能再把阈值临时置 0 去逼 Actual');
    expect(helperBody.contains(r'${budgetMs}'), isTrue,
        reason: '`_expectGuarded` 的 reason 必须同时给出预算'
            '（形如 `\${\$budgetMs}` 的插值）—— '
            '否则看到实测值也不知道余量还有多少');
    final inline = RegExp(r'lessThanOrEqualTo\s*\(').allMatches(kdfGroup).length;
    expect(inline, 0,
        reason: '组内还有 $inline 处内联 `lessThanOrEqualTo` —— '
            '绕过共用助手就拿不到 min-of-N 与实测值（PB-03 的原始形状）');
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
