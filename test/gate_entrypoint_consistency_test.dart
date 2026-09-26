import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 门禁**两条入口**的阈值一致性锁（GEC）。
///
/// ## 为什么需要它
///
/// 本项目有两条等价入口：`scripts/gates.sh`（bash，权威）与 `scripts/gates.ps1`
/// （PowerShell）。二者必须给出**同一套判据** —— 否则"走哪条路跑门禁"就决定了
/// 回归能不能被放过，更松的那条会成为**静默通道**。
///
/// 历史上已漂移**两次**（均实测，不是推测）：
///
/// 1. `2026-09-25` 之前：`.ps1` 停在 **3 步** —— **整个覆盖率 ratchet 缺失**；
/// 2. `2026-09-26`（第 36 轮实测）：第 4 步已补，但阈值停在 **72.5**（第 33 轮的值），
///    且**完全没有 `MIN_COVERED`** —— 第 34 轮给 `gates.sh` 加的"分母稀释"防线
///    在 `.ps1` 上根本不存在（而 `.ps1` 的第 4 步注释还写着"与 gates.sh 同源同阈值"）。
///
/// 两次的形状完全相同：**人记得改一个、忘了改另一个**。所以把它变成机器判据。
///
/// ## 边界（刻意收窄）
///
/// 本锁只比**默认阈值**与"是否真的把 `MIN_COVERED` 传给了覆盖率工具"，
/// **不**比对两条脚本的完整语义（那需要真跑一遍 PowerShell，见 `GEC-05` 的反例说明）。
void main() {
  final sh = File('scripts/gates.sh').readAsStringSync();
  final ps = File('scripts/gates.ps1').readAsStringSync();

  /// gates.sh：`COVERAGE_MIN="${COVERAGE_MIN:-74.1}"` → `74.1`
  double? shCovMin() => double.tryParse(RegExp(
              r'^COVERAGE_MIN="\$\{COVERAGE_MIN:-([0-9.]+)\}"',
              multiLine: true)
          .firstMatch(sh)
          ?.group(1) ??
      '');

  /// gates.sh：`MIN_COVERED="${MIN_COVERED:-7443}"` → `7443`
  int? shMinCovered() => int.tryParse(RegExp(
              r'^MIN_COVERED="\$\{MIN_COVERED:-([0-9]+)\}"',
              multiLine: true)
          .firstMatch(sh)
          ?.group(1) ??
      '');

  /// 形如 `$covMin = if (...) { ... } else { '74.1' }` 的默认值。
  /// 用 `[^)]*` / `[^}]*` 而不是 `.*`：避免跨行贪婪匹配到别的地方。
  final psCovMinRe = RegExp(
      r"\$covMin\s*=\s*if\s*\([^)]*\)\s*\{[^}]*\}\s*else\s*\{\s*'([0-9.]+)'");
  final psMinCoveredRe = RegExp(
      r"\$minCov\s*=\s*if\s*\([^)]*\)\s*\{[^}]*\}\s*else\s*\{\s*'([0-9]+)'");

  double? psCovMin() =>
      double.tryParse(psCovMinRe.firstMatch(ps)?.group(1) ?? '');
  int? psMinCovered() =>
      int.tryParse(psMinCoveredRe.firstMatch(ps)?.group(1) ?? '');

  test('GEC-01 两个脚本的默认阈值都能解析出来（解析不到即红，不许跳过）', () {
    expect(shCovMin(), isNotNull, reason: 'gates.sh 里找不到 COVERAGE_MIN 默认值');
    expect(shMinCovered(), isNotNull, reason: 'gates.sh 里找不到 MIN_COVERED 默认值');
    expect(psCovMin(), isNotNull,
        reason: 'gates.ps1 里找不到 COVERAGE_MIN 默认值 —— 写法变了？本锁失效必须红');
    expect(psMinCovered(), isNotNull,
        reason: 'gates.ps1 里找不到 MIN_COVERED 默认值 —— 第 36 轮之前它**根本没有**这一项'
            '（已补）；写法再变本锁必须红，不许默认为"没有就是不用比"');
  });

  test('GEC-02 ★ 两条入口的 COVERAGE_MIN 必须一致', () {
    expect(psCovMin(), shCovMin(),
        reason: '两条入口阈值不一致 ⇒ 更松的那条成为静默通道'
            '（历史已漂移两次：缺第 4 步、阈值停在 72.5）');
  });

  test('GEC-03 ★ 两条入口的 MIN_COVERED 必须一致', () {
    expect(psMinCovered(), shMinCovered(),
        reason: 'MIN_COVERED 是"分母被安全必需代码稀释"的防线（第 34 轮加的）；'
            '只在一个入口上有 = 另一个入口的防线**不存在**');
  });

  test('GEC-04 gates.ps1 必须真的把 MIN_COVERED 传给覆盖率工具', () {
    expect(ps.contains('--min-covered='), isTrue,
        reason: '光有默认值不传参 = 装饰品；第 36 轮之前正是这个形状'
            '（第 4 步只传了 --gate=）');
  });

  test('GEC-05 反例：把 ps1 的阈值改回 72.5 必须与真源不同（证明判据非恒真）', () {
    // 只替换**数字那一段**，保留整行结构（否则正则再也匹配不上，反例就失去意义）。
    final bad = ps.replaceFirstMapped(psCovMinRe,
        (m) => m.group(0)!.replaceFirst(m.group(1)!, '72.5'));
    expect(bad, isNot(ps), reason: '反例样本没构造成功（替换没生效）—— 这条反例就没意义了');

    final badVal = double.tryParse(psCovMinRe.firstMatch(bad)?.group(1) ?? '');
    expect(badVal, 72.5, reason: '反例样本的解析结果应当正好是 72.5');
    expect(badVal, isNot(shCovMin()),
        reason: '★ 反例必须与真源不同 ⇒ GEC-02 在同一判据下会判红 ⇒ 判据非恒真');
  });
}
