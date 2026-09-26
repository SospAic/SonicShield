// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **文档-门禁阈值一致性锁**（第 35 轮；把 `_pt/audit/DOC1-drift.md` 的漂移机器化）。
///
/// ## 为什么需要这个文件
///
/// 本项目反复出现"**文档写的阈值/数字与 `scripts/gates.sh` 的实际值漂移**"：
/// DOC1 审计又抓到三处不一致（`docs/17` 写 74.5/7010、`gates.sh` 是 73.2/7248、
/// `docs/12` 写 72.2/6771）。这类漂移不抛异常、不报错，只会让人**基于错误的数字
/// 做决策**（"文档说阈值 74.5，实际 73.2，于是以为掉到 73.5 是回归"）。
///
/// ## 真值方向（唯一真源）
///
/// **`scripts/gates.sh` 是唯一真源，文档必须服从它** —— 不是反过来。
/// 所以本锁的判据是：`CHANGELOG.md`「已知限制」段里的阈值 == 脚本里的默认值。
///
/// ## 反面样本（恒真断言 = 没测）
///
/// 文件末尾 `DGC-90a..90j` 用**故意篡改过的文本**（73.2→99.9、注释行伪装成真值、
/// 删掉整段、实测值低于门槛…）喂给同一个判定器，断言它**会判红**。
/// 任何一条反面样本判绿，就说明对应的正向断言是恒真的、没在检查东西。
///
/// ## 诚实边界
///
/// 本锁只锁「**文本里的数字**是否与脚本一致」，不锁「跑出来的覆盖率真的达标」——
/// 后者只能由门禁第 4 步（`tool/coverage_report.dart`）在真实 `coverage/lcov.info`
/// 上判定。两者是互补的：本锁防"文档骗人"，门禁防"代码退步"。

// ═══════════════════════ 纯函数（可被反面样本直接喂） ═══════════════════════

/// 剥掉 shell 注释：整行注释（trim 后 `#` 开头）整行丢弃；行内注释从 ` #` 起截断。
///
/// ⚠️ 必须先剥：`scripts/gates.sh` 的注释里**确实**留着历史数字
/// （`:13` 的 `COVERAGE_MIN=70`、`:186` 的 74.5、`:164` 的 72.6…），
/// 不剥就会把注释里的历史值当成"当前真值"。
String stripShellComments(String shellSrc) {
  final out = StringBuffer();
  for (final line in shellSrc.split('\n')) {
    if (line.trimLeft().startsWith('#')) continue; // 整行注释
    // 行内注释：shell 里 `#` 只有在"词首"（行首或前面是空白）才算注释起点。
    var cut = line.length;
    for (var i = 0; i < line.length; i++) {
      if (line[i] == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t')) {
        cut = i;
        break;
      }
    }
    out.writeln(line.substring(0, cut));
  }
  return out.toString();
}

/// 取 shell 赋值右值里的**默认值**：兼容 `73.2` / `"73.2"` / `"${VAR:-73.2}"`。
///
/// 这是本锁最容易被写错的一处：`COVERAGE_MIN="${COVERAGE_MIN:-73.2}"` 的
/// 真值嵌在 `${VAR:-default}` 里（也是"允许被环境变量覆盖"的写法），
/// 直接拿右值当数字会解析失败。
String? _shellDefaultValue(String rhs) {
  var s = rhs.trim();
  if (s.length >= 2) {
    final a = s[0];
    final b = s[s.length - 1];
    if ((a == '"' && b == '"') || (a == "'" && b == "'")) {
      s = s.substring(1, s.length - 1).trim();
    }
  }
  final m = RegExp(r'^\$\{[A-Za-z_][A-Za-z0-9_]*(?::-|-)([^}]*)\}$').firstMatch(s);
  if (m != null) s = m.group(1)!.trim();
  return s.isEmpty ? null : s;
}

/// 从 shell 源码解析门禁阈值的**默认值**。
///
/// 找不到 / 畸形 → 返回 `null`（调用方**必须判红**，不许跳过）。
/// 多个赋值时按 shell 语义**后者覆盖前者**（`export` 前缀同样识别）。
({double coverageMin, int minCovered})? parseGateThresholds(String shellSrc) {
  final code = stripShellComments(shellSrc);
  double? coverageMin;
  int? minCovered;
  for (final raw in code.split('\n')) {
    final line = raw.trim();
    final c = RegExp(r'^(?:export\s+)?COVERAGE_MIN\s*=\s*(.+)$').firstMatch(line);
    if (c != null) {
      final v = _shellDefaultValue(c.group(1)!);
      if (v != null) coverageMin = double.tryParse(v);
    }
    final m = RegExp(r'^(?:export\s+)?MIN_COVERED\s*=\s*(.+)$').firstMatch(line);
    if (m != null) {
      final v = _shellDefaultValue(m.group(1)!);
      if (v != null) minCovered = int.tryParse(v);
    }
  }
  if (coverageMin == null || minCovered == null) return null;
  return (coverageMin: coverageMin, minCovered: minCovered);
}

/// `CHANGELOG.md`「已知限制」段里抽出来的阈值与实测数字（任一缺失即为 `null` 字段）。
class DocGateLimits {
  const DocGateLimits({
    this.coverageMin,
    this.minCovered,
    this.measuredPct,
    this.measuredCovered,
    this.measuredTotal,
  });

  final double? coverageMin;
  final int? minCovered;
  final double? measuredPct;
  final int? measuredCovered;
  final int? measuredTotal;
}

/// 从 `CHANGELOG.md` 的「### 已知限制」段解析阈值与**当前**实测覆盖率。
///
/// 段不存在 → `null`（判红）。段内**第一条** `覆盖率 X%（A/B）` 视为当前实测值 ——
/// 段里还留着一条被作废的旧数（`72.30%（6781/9379）`），取第一条正是为了
/// 不把"已作废的历史值"当成现状。
DocGateLimits? parseChangelogLimits(String md) {
  final lines = md.split('\n');
  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim().startsWith('### 已知限制')) {
      start = i;
      break;
    }
  }
  if (start < 0) return null;
  var end = lines.length;
  for (var i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith('### ')) {
      end = i;
      break;
    }
  }
  final section = lines.sublist(start, end).join('\n');

  final covM = RegExp(r'COVERAGE_MIN\s*=\s*([0-9]+(?:\.[0-9]+)?)').firstMatch(section);
  final minM = RegExp(r'MIN_COVERED\s*=\s*([0-9]+)').firstMatch(section);
  // 允许 markdown 加粗包裹数字（`**覆盖率 73.34%（7264/9905）**`）。
  final measM = RegExp(
          r'覆盖率\s*\**\s*([0-9]+(?:\.[0-9]+)?)\s*%\**\s*[（(]\s*([0-9]+)\s*/\s*([0-9]+)\s*[)）]')
      .firstMatch(section);
  return DocGateLimits(
    coverageMin: covM == null ? null : double.tryParse(covM.group(1)!),
    minCovered: minM == null ? null : int.tryParse(minM.group(1)!),
    measuredPct: measM == null ? null : double.tryParse(measM.group(1)!),
    measuredCovered: measM == null ? null : int.tryParse(measM.group(2)!),
    measuredTotal: measM == null ? null : int.tryParse(measM.group(3)!),
  );
}

/// **一致性判定器**：`null` = 一致；非 `null` = 不一致的原因（即判红）。
///
/// 所有"解析不到"的情形都返回非 `null`（**判红而不是跳过**）——
/// 解析器失效时锁必须响，不能因为"没找到东西"就默认为通过。
String? gateConsistencyViolation(String shellSrc, String changelogMd) {
  final t = parseGateThresholds(shellSrc);
  if (t == null) {
    return '无法从 scripts/gates.sh 解析出 COVERAGE_MIN / MIN_COVERED 的默认值 '
        '（真源缺失 ⇒ 拒绝判定，判红）';
  }
  final c = parseChangelogLimits(changelogMd);
  if (c == null) return 'CHANGELOG.md 里找不到「### 已知限制」段（判红）';
  if (c.coverageMin == null) {
    return 'CHANGELOG「已知限制」段里找不到 `COVERAGE_MIN=` 阈值（判红）';
  }
  if (c.minCovered == null) {
    return 'CHANGELOG「已知限制」段里找不到 `MIN_COVERED=` 阈值（判红）';
  }
  if (c.coverageMin != t.coverageMin) {
    return 'COVERAGE_MIN 漂移：文档 ${c.coverageMin} ≠ 脚本 ${t.coverageMin}';
  }
  if (c.minCovered != t.minCovered) {
    return 'MIN_COVERED 漂移：文档 ${c.minCovered} ≠ 脚本 ${t.minCovered}';
  }
  if (c.measuredPct == null || c.measuredCovered == null || c.measuredTotal == null) {
    return 'CHANGELOG「已知限制」段里找不到当前实测覆盖率'
        '（应形如 `覆盖率 73.34%（7264/9905）`）（判红）';
  }
  if (c.measuredTotal == 0) return 'CHANGELOG 实测覆盖率的行数分母为 0（判红）';
  if (c.measuredCovered! < t.minCovered) {
    return 'CHANGELOG 声称的实测覆盖行 ${c.measuredCovered} < MIN_COVERED ${t.minCovered}'
        '（文档说了一个连自己门禁都过不了的值）';
  }
  if (c.measuredPct! < t.coverageMin) {
    return 'CHANGELOG 声称的实测覆盖率 ${c.measuredPct}% < COVERAGE_MIN ${t.coverageMin}%';
  }
  final computed = c.measuredCovered! / c.measuredTotal! * 100;
  if ((computed - c.measuredPct!).abs() > 0.05) {
    return 'CHANGELOG 实测覆盖率自相矛盾：写着 ${c.measuredPct}%，'
        '但 ${c.measuredCovered}/${c.measuredTotal} = ${computed.toStringAsFixed(2)}%';
  }
  return null;
}

/// 在 `CHANGELOG.md` 的「已知限制」段**内**做一次替换（反面样本构造用）。
///
/// 不在整篇替换：`COVERAGE_MIN` 在历史版本段里也出现过，全局 `replaceFirst`
/// 会改错地方，让反面样本"看起来判红了"但其实是别的原因。
String _mutateChangelogSection(String md, Pattern from, String to) {
  final start = md.indexOf('### 已知限制');
  if (start < 0) throw StateError('样本构造失败：CHANGELOG 里没有「已知限制」段');
  final next = md.indexOf('\n### ', start + 1);
  final end = next < 0 ? md.length : next;
  final section = md.substring(start, end);
  final mutated = section.replaceFirst(from, to);
  if (mutated == section) {
    throw StateError('样本构造失败：段内没找到要替换的模式 $from');
  }
  return md.substring(0, start) + mutated + md.substring(end);
}

void main() {
  final shellSrc = File('scripts/gates.sh').readAsStringSync();
  final changelogMd = File('CHANGELOG.md').readAsStringSync();

  // ───────────────────────── 正向断言 ─────────────────────────

  test('DGC-01 scripts/gates.sh 的两个阈值默认值必须可解析（解析不到即红）', () {
    final t = parseGateThresholds(shellSrc);
    expect(t, isNotNull,
        reason: '脚本是唯一真源，连它都解析不出来说明 `COVERAGE_MIN=` / '
            '`MIN_COVERED=` 的写法变了 —— 本锁失效，必须红，不许跳过');
    final tt = t!;
    expect(tt.coverageMin, greaterThan(0));
    expect(tt.minCovered, greaterThan(0));
  });

  test('DGC-02 CHANGELOG「已知限制」段必须同时给出阈值与当前实测覆盖率（缺一即红）', () {
    final c = parseChangelogLimits(changelogMd);
    expect(c, isNotNull, reason: 'CHANGELOG 的「### 已知限制」段没了 —— 阈值与实测值失去落脚点');
    final cc = c!;
    expect(cc.coverageMin, isNotNull, reason: '段里没有 `COVERAGE_MIN=`');
    expect(cc.minCovered, isNotNull, reason: '段里没有 `MIN_COVERED=`');
    expect(cc.measuredPct, isNotNull,
        reason: '段里没有 `覆盖率 X%（A/B）` 形态的当前实测值');
    expect(cc.measuredCovered, isNotNull);
    expect(cc.measuredTotal, isNotNull);
  });

  test('DGC-03 文档与脚本一致（真值来源是脚本，不是文档）', () {
    final violation = gateConsistencyViolation(shellSrc, changelogMd);
    final t = parseGateThresholds(shellSrc);
    final c = parseChangelogLimits(changelogMd);
    print('[DGC] scripts/gates.sh : COVERAGE_MIN=${t?.coverageMin}  '
        'MIN_COVERED=${t?.minCovered}');
    print('[DGC] CHANGELOG.md     : COVERAGE_MIN=${c?.coverageMin}  '
        'MIN_COVERED=${c?.minCovered}  实测 ${c?.measuredPct}%'
        '（${c?.measuredCovered}/${c?.measuredTotal}）');
    expect(violation, isNull, reason: '文档-门禁阈值漂移：$violation');
  });

  // ───────────── 反面样本：判定器必须判红（恒真断言 = 没测） ─────────────

  group('反面样本（篡改过的文本喂进去必须判红）', () {
    test('DGC-90a 脚本阈值 73.2 被篡改成 99.9 → 判红', () {
      final real = parseGateThresholds(shellSrc)!;
      final bad = shellSrc.replaceFirst(
          RegExp(r'COVERAGE_MIN\s*=\s*"\$\{COVERAGE_MIN:-[0-9.]+\}"'),
          'COVERAGE_MIN="\${COVERAGE_MIN:-99.9}"');
      expect(bad, isNot(shellSrc), reason: '样本构造失败：没改到脚本');
      final parsed = parseGateThresholds(bad);
      expect(parsed, isNotNull, reason: '篡改后仍应能解析（否则测的是另一件事）');
      expect(parsed!.coverageMin, isNot(real.coverageMin));
      expect(gateConsistencyViolation(bad, changelogMd), isNotNull,
          reason: '脚本被改成 99.9、文档仍是 ${real.coverageMin} —— 必须判红');
    });

    test('DGC-90b 注释行伪装成真值（唯一赋值在注释里）→ 解析不到 → 判红', () {
      const onlyComment = '#!/usr/bin/env bash\n'
          '# COVERAGE_MIN="\${COVERAGE_MIN:-99.9}"\n'
          '# MIN_COVERED="\${MIN_COVERED:-1}"\n'
          'echo "hi"\n';
      expect(parseGateThresholds(onlyComment), isNull,
          reason: '注释里的"赋值"不是真值 —— 不剥注释的实现会读成 99.9/1（假绿）');
      expect(gateConsistencyViolation(onlyComment, changelogMd), isNotNull,
          reason: '真源解析不到 ⇒ 判红（不是跳过）');
    });

    test('DGC-90c 真值之后追加一条注释诱饵 → 仍取真值（诱饵不生效）', () {
      final real = parseGateThresholds(shellSrc)!;
      final withDecoy = '$shellSrc\n'
          '# COVERAGE_MIN="\${COVERAGE_MIN:-99.9}"\n'
          '# MIN_COVERED="\${MIN_COVERED:-1}"\n';
      final parsed = parseGateThresholds(withDecoy);
      expect(parsed, isNotNull);
      final p = parsed!;
      expect(p.coverageMin, real.coverageMin,
          reason: '注释诱饵写在真值之后，若解析器不剥注释、取"最后一个匹配"，'
              '就会读成 99.9 —— 这正是 DOC1 类漂移的温床');
      expect(p.minCovered, real.minCovered);
      expect(gateConsistencyViolation(withDecoy, changelogMd), isNull,
          reason: '诱饵只是注释，不应造成假红');
    });

    test('DGC-90d 删掉脚本里的阈值赋值 → 判红', () {
      // 逐行删除（不用 `(?m)` 内联标志 —— Dart 的 RegExp 是 ECMAScript 语法，
      // 不支持 `(?m)`，写了会在运行期抛 FormatException）。
      final assign = RegExp(r'^(?:export\s+)?(?:COVERAGE_MIN|MIN_COVERED)\s*=');
      final deleted = shellSrc
          .split('\n')
          .where((l) => !assign.hasMatch(l.trim()))
          .join('\n');
      expect(deleted, isNot(shellSrc));
      expect(parseGateThresholds(deleted), isNull, reason: '两个真源都被删了');
      expect(gateConsistencyViolation(deleted, changelogMd), isNotNull);
    });

    test('DGC-90e export 形态（环境变量覆盖语法）仍解析出默认值', () {
      final real = parseGateThresholds(shellSrc)!;
      final exported = shellSrc.replaceFirst('COVERAGE_MIN="', 'export COVERAGE_MIN="');
      expect(exported, isNot(shellSrc));
      final parsed = parseGateThresholds(exported);
      expect(parsed, isNotNull,
          reason: r'`export COVERAGE_MIN="${COVERAGE_MIN:-<default>}"` 也要认');
      expect(parsed!.coverageMin, real.coverageMin);
    });

    test('DGC-90f 删掉 CHANGELOG 的「已知限制」段 → 判红', () {
      final noSection = changelogMd.replaceFirst('### 已知限制', '### 别的标题');
      expect(noSection, isNot(changelogMd));
      expect(parseChangelogLimits(noSection), isNull);
      expect(gateConsistencyViolation(shellSrc, noSection), isNotNull,
          reason: 'CHANGELOG 里找不到阈值 ⇒ 判红（不是跳过）');
    });

    test('DGC-90g CHANGELOG 的 COVERAGE_MIN 改成 99.9 → 判红', () {
      final bad = _mutateChangelogSection(
          changelogMd, RegExp(r'COVERAGE_MIN\s*=\s*[0-9.]+'), 'COVERAGE_MIN=99.9');
      expect(parseChangelogLimits(bad)!.coverageMin, 99.9);
      expect(gateConsistencyViolation(shellSrc, bad), isNotNull);
    });

    test('DGC-90h CHANGELOG 的 MIN_COVERED 改成 1 → 判红', () {
      final bad = _mutateChangelogSection(
          changelogMd, RegExp(r'MIN_COVERED\s*=\s*[0-9]+'), 'MIN_COVERED=1');
      expect(parseChangelogLimits(bad)!.minCovered, 1);
      expect(gateConsistencyViolation(shellSrc, bad), isNotNull);
    });

    test('DGC-90i CHANGELOG 实测值降到门槛以下 → 判红', () {
      final bad = _mutateChangelogSection(
          changelogMd,
          RegExp(r'覆盖率\s*\**\s*[0-9.]+\s*%\**\s*[（(]\s*[0-9]+\s*/\s*[0-9]+\s*[)）]'),
          '覆盖率 0.00%（0/99999）');
      final c = parseChangelogLimits(bad)!;
      expect(c.measuredPct, 0.0);
      expect(gateConsistencyViolation(shellSrc, bad), isNotNull,
          reason: '文档声称的实测值过不了自己的门禁 ⇒ 判红');
    });

    test('DGC-90j CHANGELOG 实测百分比与其分数自相矛盾 → 判红', () {
      final bad = _mutateChangelogSection(
          changelogMd, RegExp(r'覆盖率\s*\**\s*[0-9.]+\s*%'), '覆盖率 99.99%');
      final c = parseChangelogLimits(bad)!;
      expect(c.measuredPct, 99.99);
      expect(c.measuredCovered, isNotNull);
      expect(gateConsistencyViolation(shellSrc, bad), isNotNull,
          reason: '只改了百分比、没改分数 ⇒ 自相矛盾 ⇒ 判红');
    });
  });
}
