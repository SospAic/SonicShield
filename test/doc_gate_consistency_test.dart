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
///
/// ## 三组锁（第五十五 / 五十七轮起）
///
/// - `DGC-*`：**阈值**一致性（`COVERAGE_MIN` / `MIN_COVERED` = `gates.sh` ↔ `CHANGELOG`）。
/// - `BAS-*`：**绝对分数**一致性（`9299/9597`、`9301/10087` 这类数字逐位比对）——
///   补上第五十四轮实测漏网的那一类：**百分比相同、数字不同**，DGC 抓不到。
///   设计说明见下方 `BAS` 段。
/// - `BRL-*`：**「自称最近/当前」声明**一致性 —— 补上 `BAS`「整篇**含有**权威分数」抓不到的
///   第二类：**自述过期**（文件里某处确实写着权威分数 ⇒ `BAS-04` 判绿，但**自称『最近一次』
///   的那一段写的是旧值**）。设计说明见下方 `BRL` 段。

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

// ═══════════ 基线**绝对分数**一致锁（BAS，第五十五轮） ═══════════
//
// ## 为什么需要它（第五十四轮实测的漏网形状）
//
// 第 53 轮把宿主数字刷到 `1974 / 9299 / 9597 / 9301 / 10087`，但 `README.md`、
// `docs/00`、`docs/09`、`docs/21`、`docs/22`、`HANDOVER.md`、`CHANGELOG.md`
// 六类落点**仍停在 `1973 / 9298 / 9596 / 9300 / 10086`**。
//
// 两组数字的**百分比巧合相同**（`96.89%` / `92.21%`）：
//   - `9298/9596 = 96.8953…%` → 96.89
//   - `9299/9597 = 96.8948…%` → 96.89
// DGC-01…03 只校验**阈值与百分比**（`COVERAGE_MIN` / `MIN_COVERED` / `measuredPct`），
// 因此**判绿**；人工目视同样容易滑过。⇒ 只有**逐位比对绝对分数**才能发现。
//
// ## 判据（真源 = 「权威根节」）
//
// `docs/12` 与 `docs/17` 的**最新顶级章节**是每轮现场写就的权威基线（离门禁最近），
// 二者必须给出**同一对**绝对分数；其余「当前基线」落点必须**逐位含有**这对分数。
// 本锁**不需要**外部产物（`coverage/lcov.info` 被 `.gitignore` 排除 ⇒ 不能当判据），
// 全部输入都是**受版本控制的文本** —— 这是刻意的：锁必须能在干净克隆上跑。
//
// ## 诚实边界（本锁**不**判什么）
//
// - 不判「文档数字与真实门禁产物一致」：没有任何受版本控制的真值载体，
//   只能靠**互相一致**逼近 —— 若所有落点**同时**漂到同一个错值，本锁抓不到。
// - `docs/00` 是**逐行历史表**（doc30 行合法保留第四十九轮旧值），
//   故只做「含有」检查、不做「唯一性」检查。
// - `docs/21` 同理（保留报告周期历史值）。

/// 剥掉 markdown 装饰符（`*` 加粗、`` ` `` 行内代码）。
///
/// 目的：让「口径标签 → 数字」的**相邻关系**在 `可测面 **96.89%（…）**` 与
/// `可测面 96.89%（…）` 两种写法下**一致可匹配**（否则正则要写两套）。
String stripMdDecor(String s) => s.replaceAll('*', '').replaceAll('`', '');

/// 一条「口径 → 覆盖率（分子/分母）」断言。
class BaselineClaim {
  const BaselineClaim(this.label, this.pct, this.covered, this.total);

  final String label;
  final double pct;
  final int covered;
  final int total;

  /// 绝对分数的**规范写法**（落点必须逐位含有它）。
  String get fraction => '$covered/$total';

  @override
  String toString() => '$label $pct%（$fraction）';

  @override
  bool operator ==(Object other) =>
      other is BaselineClaim &&
      other.pct == pct &&
      other.covered == covered &&
      other.total == total;

  @override
  int get hashCode => Object.hash(pct, covered, total);
}

/// 可测面口径的标签词（门禁阈值用的那个口径）。
const String kTestableLabel = r'可测面|门禁口径';

/// 全局口径的标签词（对外诚实数字）。
const String kGlobalLabel = r'全局|对外诚实数字';

/// 设备层豁免**分母**（`background_engine.dart` 454 + `main.dart` 36）。
///
/// 与 `test/device_exemption_lock_test.dart`（DEX 系列）绑定同一组事实；
/// 一旦豁免面几何变化，本锁与 DEX 会**同时**判红。
const int kDeviceExemptLines = 454 + 36;

/// 设备层豁免面**已覆盖**行（`background_engine.dart` 452/454 ⇒ 2；`main.dart` 0/36）。
const int kDeviceExemptCovered = 2;

/// 抽「<标签> … X%（A/B）」形态的基线断言。
///
/// 标签词与数字之间最多 32 个非换行字符（容忍加粗、全角括号、连接词）。
List<BaselineClaim> extractBaselineClaims(String text, String labelPattern) {
  final re = RegExp('($labelPattern)[^\\n]{0,32}?([0-9]{1,3}\\.[0-9]{2})\\s*%'
      '\\s*[（(]\\s*([0-9]{3,5})\\s*/\\s*([0-9]{3,5})\\s*[)）]');
  return re
      .allMatches(stripMdDecor(text))
      .map((m) => BaselineClaim(m.group(1)!, double.parse(m.group(2)!),
          int.parse(m.group(3)!), int.parse(m.group(4)!)))
      .toList();
}

/// 取 markdown 的**最后一个**顶级章节（`## ` 起至文末）。
///
/// 「最新节」= 每轮现场写就的权威基线节；空串 ⇒ 调用方必须判红。
String lastTopSection(String md) {
  final idx = md.lastIndexOf('\n## ');
  return idx < 0 ? '' : md.substring(idx);
}

/// 从 `CHANGELOG.md` 抽出「### 已知限制」段（落点之一；该段含基线第一条 + 历史链）。
String changelogLimitsSection(String md) {
  final start = md.indexOf('### 已知限制');
  if (start < 0) return '';
  final next = md.indexOf('\n### ', start + 1);
  return md.substring(start, next < 0 ? md.length : next);
}

/// **一致性判定器**：`null` = 一致；非 `null` = 判红原因。
///
/// 所有「解析不到 / 落点缺数字」的情形都返回非 `null`（判红而不是跳过）——
/// 与 DGC 同一条纪律：锁必须响，不能因为"没找到东西"就默认通过。
String? baselineConsistencyViolation({
  required String doc12,
  required String doc17,
  required Map<String, String> landingPoints,
}) {
  final roots = <String, ({BaselineClaim testable, BaselineClaim global})>{};
  final inputs = <String, String>{
    'docs/12-测试报告.md': doc12,
    'docs/17-接管审计与续作清单.md': doc17,
  };
  for (final e in inputs.entries) {
    final sec = lastTopSection(e.value);
    if (sec.trim().isEmpty) {
      return '${e.key}：找不到 `## ` 顶级章节（判红，不跳过）';
    }
    final t = extractBaselineClaims(sec, kTestableLabel).toSet();
    final g = extractBaselineClaims(sec, kGlobalLabel).toSet();
    if (t.isEmpty) {
      return '${e.key} 最新节里没有「可测面 X%（A/B）」形态的权威基线（判红）——'
          '请在该节写一行：`**宿主基线（权威）**：可测面 X%（A/B） / 全局 Y%（C/D）`';
    }
    if (t.length > 1) {
      return '${e.key} 最新节里有 ${t.length} 个**互不相同**的可测面基线'
          '（${t.join(' / ')}）⇒ 锁不知道该信哪条（判红）';
    }
    if (g.isEmpty) {
      return '${e.key} 最新节里没有「全局 Y%（C/D）」形态的权威基线（判红）';
    }
    if (g.length > 1) {
      return '${e.key} 最新节里有 ${g.length} 个**互不相同**的全局基线'
          '（${g.join(' / ')}）⇒ 锁不知道该信哪条（判红）';
    }
    roots[e.key] = (testable: t.first, global: g.first);
  }

  final keys = roots.keys.toList();
  final a = roots[keys[0]]!, b = roots[keys[1]]!;
  if (a.testable != b.testable || a.global != b.global) {
    return '两个权威根节**互相漂移**：`${keys[0]}` = ${a.testable} / ${a.global}，'
        '`${keys[1]}` = ${b.testable} / ${b.global}';
  }

  final t = a.testable, g = a.global;
  if (g.total - t.total != kDeviceExemptLines) {
    return '豁免面几何漂移：全局分母 ${g.total} − 可测面分母 ${t.total} = '
        '${g.total - t.total} ≠ $kDeviceExemptLines（= 454 + 36，见 DEX 锁）';
  }
  if (g.covered - t.covered != kDeviceExemptCovered) {
    return '豁免面已覆盖行漂移：全局分子 ${g.covered} − 可测面分子 ${t.covered} = '
        '${g.covered - t.covered} ≠ $kDeviceExemptCovered';
  }
  for (final c in <BaselineClaim>[t, g]) {
    final computed = c.covered * 100 / c.total;
    if ((computed - c.pct).abs() > 0.05) {
      return '权威基线自相矛盾：写着 ${c.pct}%，但 ${c.fraction} = '
          '${computed.toStringAsFixed(2)}%';
    }
  }

  final need = <String>[t.fraction, g.fraction];
  final missing = <String>[];
  for (final e in landingPoints.entries) {
    final absent = need.where((n) => !e.value.contains(n)).toList();
    if (absent.isNotEmpty) missing.add('${e.key}（缺 ${absent.join('、')}）');
  }
  if (missing.isNotEmpty) {
    return '「当前基线」落点没有同步到根节声明的**绝对分数** '
        '${need.join(' / ')}：\n  ${missing.join('\n  ')}';
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

// ═══════════ 「自称最近/当前」声明锁（BRL，第五十七轮） ═══════════
//
// 第五十七轮的全库反漂移审计（`_pt/bg_drift_audit.py`，范围超出 BAS-04 的 7 个落点）
// 在**真实语料**上抓到两处 BAS 结构性抓不到的漂移：
//
//   1. `docs/22 §6` 的表头写着「最近一次全绿门禁，2026-10-01 **第五十六轮**」，
//      但紧邻其下的 ⚠️ 注却写「上表已回刷为**最近一次全绿门禁（2026-09-28 第四十六轮）**
//      的实测值」——**同一段落里两个互斥的「最近一次」**，且该注的阈值链停在 `94.8`
//      （漏了 95.9 → 96.8）。`BAS-04` 只做「整篇**含有** 9299/9597」，该文件第 297 行
//      正好含有 ⇒ **判绿**。
//   2. `docs/23 §1.1` 的门禁基线行自称「**最近一次**全绿门禁（2026-09-28 第四十七轮）」，
//      实际最近一次是 2026-10-01 第五十六轮 —— 该文件根本不在 7 落点里 ⇒ 无人盯。
//
// 教训与第五十四轮同源、但更细：**漂移不一定是「数字错」，可以是「自述过期」**。
// 所以本组锁只盯两件事：
//   - `BRL-02`：凡称「最近一次全绿门禁」的行，**必须指向最新轮次**（真源 =
//     `CHANGELOG.md` 最上面那条 `#### 第N轮` 标题），或在 ±5 行内有显式历史标记；
//   - `BRL-03`：凡写「阈值链」的行，**必须含 `scripts/gates.sh` 的 COVERAGE_MIN 默认值**。

/// 中文数字 → 整数（只支持到 99，轮次足够）。解析失败返回 `null`。
int? chineseNumeralToInt(String s) {
  const digits = {
    '零': 0, '一': 1, '二': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
  };
  if (s.isEmpty) return null;
  if (RegExp(r'^\d+$').hasMatch(s)) return int.tryParse(s);
  var tens = 0; // 十位（`十` 之前的部分 × 10）
  var ones = 0; // 个位
  var sawDigit = false;
  for (final ch in s.split('')) {
    if (ch == '百') return null; // 轮次不会到百位；解析不了返回 null，调用方判红
    if (ch == '十') {
      tens = (sawDigit ? ones : 1) * 10;
      ones = 0;
      sawDigit = false;
      continue;
    }
    final d = digits[ch];
    if (d == null) return null;
    ones = d;
    sawDigit = true;
  }
  final v = tens + ones;
  return v == 0 ? null : v;
}

/// 从 `CHANGELOG.md` 取**最新轮次号**：文件最上面第一条 `#### 第N轮` 标题。
///
/// 取不到 → `null`（本锁失去真源 ⇒ 调用方必须判红，不许跳过）。
int? latestRoundFromChangelog(String md) {
  final re = RegExp(r'^####\s*第([一二三四五六七八九十零百\d]+)轮', multiLine: true);
  final m = re.firstMatch(md);
  if (m == null) return null;
  return chineseNumeralToInt(m.group(1)!);
}

/// 称「最近一次全绿门禁」但仍指向**旧**轮次的违规行（`文件:行号 说明`）。
///
/// `docs` 的 key 是相对路径；`windowLines` 用于「±N 行内有历史标记即豁免」。
/// 判红条件：行内含该短语 **且** 行内出现的轮次号**没有一个**等于
/// [latestRound]，**且** ±window 行内没有历史标记。
List<String> recentGateStaleViolations({
  required int latestRound,
  required Map<String, String> docs,
  int windowLines = 5,
}) {
  const phrase = '最近一次全绿门禁';
  const historyMarkers = <String>[
    '已被超越',
    '已被后续',
    '非当前基线',
    '勿作当前基线',
    '勿照抄',
    '历史记录',
    '历史口径',
    '过期',
  ];
  final roundRe = RegExp(r'第([一二三四五六七八九十零百\d]+)轮');
  final out = <String>[];
  docs.forEach((rel, text) {
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.contains(phrase)) continue;
      final rounds = roundRe
          .allMatches(line)
          .map((m) => chineseNumeralToInt(m.group(1)!))
          .whereType<int>()
          .toList();
      if (rounds.contains(latestRound)) continue;
      final lo = (i - windowLines).clamp(0, lines.length - 1);
      final hi = (i + windowLines).clamp(0, lines.length - 1);
      final near = lines.sublist(lo, hi + 1).join('\n');
      if (historyMarkers.any(near.contains)) continue;
      if (!_hasUnquotedOccurrence(line, phrase)) continue;
      out.add('$rel:${i + 1} 称「$phrase」但轮次 $rounds ≠ 最新第 $latestRound 轮'
          '（且 ±$windowLines 行内无历史标记）｜${line.trim()}');
    }
  });
  return out;
}

/// 行内是否存在**未被引号包裹**的 [needle]。
///
/// 为什么必须区分：项目文档会**逐字引用**漂移原文（如 `「…自称『最近一次全绿门禁（第四十六轮）』…」`），
/// 那是**叙述**不是自称。第五十七轮首跑实测：不加这一层，`BRL-02` 会把
/// `docs/12 §90` / `docs/17 §87` / `CHANGELOG` 里对本漂移的**描述**判成新的漂移（自指假阳性）。
bool _hasUnquotedOccurrence(String line, String needle) {
  const openQ = ['「', '『', '“', '"'];
  const closeQ = ['」', '』', '”', '"'];
  var start = 0;
  while (true) {
    final i = line.indexOf(needle, start);
    if (i < 0) return false;
    start = i + 1;
    final before = i > 0 ? line[i - 1] : '';
    final after = i + needle.length < line.length ? line[i + needle.length] : '';
    if (openQ.contains(before) || closeQ.contains(after)) continue;
    return true;
  }
}

/// 写「阈值链」但**没有走到脚本当前阈值**的段落。
///
/// 判据按**段落**（连续非空行）而非单行：真实的阈值链会**跨行折行**
/// （`docs/22 §6` 的链就横跨 4 行）。只有当段落**整体像一条链**（箭头后跟数字 ≥ 4 处）
/// 才检查终点 —— 这样"解释 BRL-03 判据本身"的说明文字（没有箭头）不会被误伤。
List<String> thresholdChainStaleViolations({
  required double coverageMin,
  required Map<String, String> docs,
}) {
  const phrase = '阈值链';
  final need = coverageMin.toStringAsFixed(1);
  final arrowRe = RegExp(r'→\s*\d+(?:\.\d+)?');
  final out = <String>[];
  docs.forEach((rel, text) {
    final lines = text.split('\n');
    var i = 0;
    while (i < lines.length) {
      if (lines[i].trim().isEmpty) {
        i++;
        continue;
      }
      var j = i;
      while (j < lines.length && lines[j].trim().isNotEmpty) {
        j++;
      }
      final para = lines.sublist(i, j).join('\n');
      final arrows = arrowRe.allMatches(para).length;
      if (para.contains(phrase) && arrows >= 4 && !para.contains(need)) {
        out.add('$rel:${i + 1} 「$phrase」段落像一条阈值链（箭头 $arrows 处）'
            '却未含当前 `COVERAGE_MIN=$need`');
      }
      i = j;
    }
  });
  return out;
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

  // ═══════════ 基线绝对分数一致锁（BAS，第五十五轮新增） ═══════════
  //
  // 起因：第五十四轮实测「6 处当前基线落点仍停在第 49/51 轮数字」而百分比**巧合相同**
  // （`9298/9596` 与 `9299/9597` 都写 96.89%）⇒ DGC 只比阈值与百分比，**抓不到**。
  group('BAS 基线绝对分数一致锁（防「百分比相同、数字不同」的漂移）', () {
    final d12 = File('docs/12-测试报告.md').readAsStringSync();
    final d17 = File('docs/17-接管审计与续作清单.md').readAsStringSync();

    /// 「当前基线」落点。`docs/00` 与 `docs/21` 保留逐轮历史值 ⇒ 只做「含有」检查。
    final landing = <String, String>{
      'README.md': File('README.md').readAsStringSync(),
      'docs/00-文档索引.md': File('docs/00-文档索引.md').readAsStringSync(),
      'docs/09-测试计划与测试用例.md':
          File('docs/09-测试计划与测试用例.md').readAsStringSync(),
      'docs/21-全功能点测试与缺陷修复报告.md':
          File('docs/21-全功能点测试与缺陷修复报告.md').readAsStringSync(),
      'docs/22-远程命令全量清单.md': File('docs/22-远程命令全量清单.md').readAsStringSync(),
      'HANDOVER.md': File('HANDOVER.md').readAsStringSync(),
      'CHANGELOG.md（已知限制段）': changelogLimitsSection(changelogMd),
    };

    ({BaselineClaim testable, BaselineClaim global})? rootOf(String text) {
      final sec = lastTopSection(text);
      final t = extractBaselineClaims(sec, kTestableLabel).toSet();
      final g = extractBaselineClaims(sec, kGlobalLabel).toSet();
      if (t.length != 1 || g.length != 1) return null;
      return (testable: t.first, global: g.first);
    }

    /// 只改**最后一个**顶级章节（反面样本构造用）。
    String mutateLastSection(String md, Pattern from, String to) {
      final idx = md.lastIndexOf('\n## ');
      expect(idx, greaterThanOrEqualTo(0), reason: '样本构造失败：没有顶级章节');
      final mutated = md.substring(idx).replaceFirst(from, to);
      expect(mutated, isNot(md.substring(idx)),
          reason: '样本构造失败：段内没找到要替换的模式 $from');
      return md.substring(0, idx) + mutated;
    }

    test('BAS-01 两个权威根节各须给出唯一的可测面/全局基线（解析不到即红）', () {
      final r12 = rootOf(d12);
      final r17 = rootOf(d17);
      expect(r12, isNotNull,
          reason: '`docs/12` 最新节里没有唯一的「可测面 X%（A/B）」+「全局 Y%（C/D）」'
              '权威基线 ⇒ 本锁失去真源，必须红（不许跳过）');
      expect(r17, isNotNull,
          reason: '`docs/17` 最新节缺权威基线 ⇒ 判红。该节请写一行：'
              '`**宿主基线（权威）**：可测面 X%（A/B） / 全局 Y%（C/D）`');
      print('[BAS] docs/12 最新节 : ${r12?.testable} / ${r12?.global}');
      print('[BAS] docs/17 最新节 : ${r17?.testable} / ${r17?.global}');
    });

    test('BAS-02 ★ 两个权威根节必须逐位一致（防两节互相漂移）', () {
      final r12 = rootOf(d12), r17 = rootOf(d17);
      expect(r12, isNotNull);
      expect(r17, isNotNull);
      expect(r12!.testable.fraction, r17!.testable.fraction,
          reason: '可测面**绝对分数**在两个根节里不一致 ⇒ 至少有一节没回刷');
      expect(r12.global.fraction, r17.global.fraction,
          reason: '全局**绝对分数**在两个根节里不一致 ⇒ 至少有一节没回刷');
    });

    test('BAS-03 ★ 豁免面几何必须自洽（全局−可测面 = 490 行；已覆盖 +2 行）', () {
      final r12 = rootOf(d12);
      expect(r12, isNotNull);
      final t = r12!.testable, g = r12.global;
      expect(g.total - t.total, kDeviceExemptLines,
          reason: '全局分母 ${g.total} − 可测面分母 ${t.total} 应恒为 '
              '$kDeviceExemptLines（= 454 + 36，与 DEX 锁同源）');
      expect(g.covered - t.covered, kDeviceExemptCovered,
          reason: '豁免面已覆盖行应恒为 $kDeviceExemptCovered（background_engine 452/454）');
    });

    test('BAS-04 ★ 7 个「当前基线」落点必须逐位含有根节的绝对分数', () {
      final r12 = rootOf(d12);
      expect(r12, isNotNull);
      final need = <String>[r12!.testable.fraction, r12.global.fraction];
      for (final e in landing.entries) {
        for (final n in need) {
          expect(e.value.contains(n), isTrue,
              reason: '${e.key} 里找不到 `$n` —— 该落点没同步到当前权威基线'
                  '（第五十四轮实测过：`9298/9596` 与 `9299/9597` 百分比相同、'
                  '数字不同，机器锁与目视**都**漏过）');
        }
      }
    });

    test('BAS-05 权威基线的百分比与分数必须自洽（±0.05pt）', () {
      final r12 = rootOf(d12);
      expect(r12, isNotNull);
      for (final c in <BaselineClaim>[r12!.testable, r12.global]) {
        final computed = c.covered * 100 / c.total;
        expect((computed - c.pct).abs(), lessThanOrEqualTo(0.05),
            reason: '写着 ${c.pct}%，但 ${c.fraction} = '
                '${computed.toStringAsFixed(2)}%');
      }
    });

    test('BAS-06 端到端判定器在真实仓库文本上必须判绿', () {
      final v = baselineConsistencyViolation(
          doc12: d12, doc17: d17, landingPoints: landing);
      expect(v, isNull, reason: '基线绝对分数不一致：$v');
    });

    group('反面样本（篡改过的文本喂进去必须判红）', () {
      test('BAS-90a 根节里改掉一位数字 → 判红', () {
        final bad = mutateLastSection(d12, '9299/9597', '9298/9596');
        expect(
            baselineConsistencyViolation(
                doc12: bad, doc17: d17, landingPoints: landing),
            isNotNull,
            reason: '根节被改、落点没改 ⇒ 必须判红（这正是第五十四轮的形状）');
      });

      test('BAS-90b 某个落点改掉一位数字 → 判红', () {
        // 必须用 `replaceAll`：`README.md` 里这对分数出现**两次**（门禁基线块 + 覆盖率行），
        // 只改第一处的话第二处仍含真值 ⇒ 样本失效（本组首跑实测踩到，故留痕）。
        final bad = Map<String, String>.from(landing)
          ..['README.md'] =
              landing['README.md']!.replaceAll('9299/9597', '9298/9596');
        expect(bad['README.md'], isNot(landing['README.md']));
        expect(bad['README.md']!.contains('9299/9597'), isFalse,
            reason: '样本构造失败：改完仍含真值 ⇒ 这条反例就测不到东西');
        expect(
            baselineConsistencyViolation(
                doc12: d12, doc17: d17, landingPoints: bad),
            isNotNull,
            reason: '落点数字与根节不同 ⇒ 必须判红，不许因为"百分比一样"放过');
      });

      test('BAS-90c 落点里的绝对分数被删掉 → 判红（vacuity 守卫）', () {
        final bad = Map<String, String>.from(landing)
          ..['HANDOVER.md'] =
              landing['HANDOVER.md']!.replaceAll('9301/10087', '');
        expect(bad['HANDOVER.md'], isNot(landing['HANDOVER.md']));
        expect(
            baselineConsistencyViolation(
                doc12: d12, doc17: d17, landingPoints: bad),
            isNotNull,
            reason: '找不到数字必须判红，不能默认通过');
      });

      test('BAS-90d 豁免面几何被破坏（分母 +1）→ 判红', () {
        final bad = mutateLastSection(d12, '10087', '10088');
        expect(
            baselineConsistencyViolation(
                doc12: bad, doc17: d17, landingPoints: landing),
            isNotNull,
            reason: '全局分母 − 可测面分母 ≠ 490 ⇒ 豁免面几何漂移');
      });

      test('BAS-90e 根节塞进第二条不同的可测面基线 → 判红（防"只取第一条"的假绿）', () {
        final bad = '$d12\n> 可测面 99.99%（9999/9999）\n';
        expect(
            baselineConsistencyViolation(
                doc12: bad, doc17: d17, landingPoints: landing),
            isNotNull,
            reason: '同一节里两条互不相同的可测面基线 ⇒ 真源不唯一 ⇒ 必须判红');
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // BRL：「自称最近/当前」声明锁（第五十七轮新增，第三组）
  // ═══════════════════════════════════════════════════════════════════════════
  group('BRL 「自称最近/当前」声明锁（防「自述过期」——BAS 结构性抓不到）', () {
    final rawDocs = <String, String>{
      'README.md': File('README.md').readAsStringSync(),
      'HANDOVER.md': File('HANDOVER.md').readAsStringSync(),
      'CHANGELOG.md': changelogMd,
      for (final f in Directory('docs').listSync().whereType<File>())
        if (f.path.endsWith('.md'))
          f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
    };

    test('BRL-01 最新轮次号必须可从 CHANGELOG.md 解析出来（解析不到即红）', () {
      final n = latestRoundFromChangelog(changelogMd);
      expect(n, isNotNull,
          reason: '`CHANGELOG.md` 最上面那条 `#### 第N轮` 标题取不到 ⇒ 本锁失去真源，'
              '必须红，不许跳过');
      print('[BRL] CHANGELOG 最新轮次 = 第 $n 轮');
      // 中文数字解析器自检（判据非恒真）
      expect(chineseNumeralToInt('五十七'), 57);
      expect(chineseNumeralToInt('十'), 10);
      expect(chineseNumeralToInt('五十六'), 56);
      expect(chineseNumeralToInt('百'), isNull, reason: '百位不支持 ⇒ 必须显式判红');
    });

    test('BRL-02 ★ 凡称「最近一次全绿门禁」的行必须指向最新轮次（或有历史标记）', () {
      final n = latestRoundFromChangelog(changelogMd);
      expect(n, isNotNull);
      final v =
          recentGateStaleViolations(latestRound: n!, docs: rawDocs);
      for (final s in v) {
        print('[BRL] 违规：$s');
      }
      expect(v, isEmpty,
          reason: '自述「最近一次全绿门禁」却指向旧轮次 ⇒ 与第五十四轮的「当前基线」'
              '漂移同类（更隐蔽：整篇仍含权威分数 ⇒ BAS-04 抓不到）');
    });

    test('BRL-03 ★ 凡写「阈值链」的行必须走到脚本当前 COVERAGE_MIN', () {
      final t = parseGateThresholds(shellSrc);
      expect(t, isNotNull);
      final v = thresholdChainStaleViolations(
          coverageMin: t!.coverageMin, docs: rawDocs);
      for (final s in v) {
        print('[BRL] 违规：$s');
      }
      expect(v, isEmpty,
          reason: '阈值链是「只升不降」的凭据链，停在旧阈值 ⇒ 读者会以为阈值更低');
    });

    test('BRL-90a 反面样本：把某文件的自称最近改成旧轮次 → 判红', () {
      final n = latestRoundFromChangelog(changelogMd)!;
      final bad = <String, String>{
        'x.md': '> 最近一次全绿门禁（2026-09-28 第四十六轮）实测：功能层 1511\n',
      };
      final v = recentGateStaleViolations(latestRound: n, docs: bad);
      expect(v, isNotEmpty,
          reason: '旧轮次且无历史标记 ⇒ 必须判红（这正是 `docs/22 §6` 的真实形状）');
    });

    test('BRL-90b 反面样本：自述最近 = 最新轮次 → 判绿（判据非恒真）', () {
      final n = latestRoundFromChangelog(changelogMd)!;
      final good = <String, String>{
        'x.md': '> 最近一次全绿门禁（第五十七轮）实测：RC=0\n',
      };
      expect(recentGateStaleViolations(latestRound: n, docs: good), isEmpty);
    });

    test('BRL-90c 反面样本：±5 行内有历史标记 ⇒ 豁免（防误伤历史段）', () {
      final n = latestRoundFromChangelog(changelogMd)!;
      final ok = <String, String>{
        'x.md': '⚠️ 本段已被后续收口超越（勿作当前基线）\n'
            '\n> **最近一次全绿门禁 gateBB（2026-09-25）实测**：功能层 1511\n',
      };
      expect(recentGateStaleViolations(latestRound: n, docs: ok), isEmpty,
          reason: '历史段必须能豁免，否则锁会误伤 `docs/17 §5x` 的历史结论');
    });

    test('BRL-90d 反面样本：阈值链被截断在旧阈值 → 判红', () {
      final bad = <String, String>{
        'x.md': '> 历史阈值链：74.5 → 73.2 → 78.4 → 79.8 → 82.2 → 93.3 → **94.8**；\n',
      };
      final v =
          thresholdChainStaleViolations(coverageMin: 96.8, docs: bad);
      expect(v, isNotEmpty, reason: '链停在 94.8 却声称是阈值链 ⇒ 必须判红');
    });

    test('BRL-90e 反面样本：阈值链走到当前阈值 → 判绿', () {
      final ok = <String, String>{
        'x.md': '> 历史阈值链：73.2 → 78.4 → 82.2 → 93.3 → 94.8 → 95.9 → **96.8**。\n',
      };
      expect(thresholdChainStaleViolations(coverageMin: 96.8, docs: ok),
          isEmpty);
    });

    test('BRL-90f ★ 反面样本：**被引用**（引号内）的旧轮次不算自称 → 判绿', () {
      final n = latestRoundFromChangelog(changelogMd)!;
      final quoted = <String, String>{
        'x.md': '| 1 | `docs/22 §6` 的注 | 表头「最近一次全绿门禁（第五十六轮）」'
            'vs 其下的注「上表已回刷为『最近一次全绿门禁（第四十六轮）』的实测值」 | … |\n',
      };
      expect(recentGateStaleViolations(latestRound: n, docs: quoted), isEmpty,
          reason: '文档会**逐字引用**漂移原文 —— 本轮的 `docs/12 §90` / `docs/17 §87` / `CHANGELOG` '
              '正是这种形状；不排除引用 ⇒ 锁会自指假红（第五十七轮首跑实测踩到）');
    });

    test('BRL-90g ★ 反面样本：说明 BRL-03 判据本身的文字（无箭头）→ 判绿', () {
      final explain = <String, String>{
        'x.md': '- `BRL-03` ★：凡含「阈值链」的行必须含 `scripts/gates.sh` 的 '
            '`COVERAGE_MIN` 默认值。\n',
      };
      expect(thresholdChainStaleViolations(coverageMin: 96.8, docs: explain),
          isEmpty,
          reason: '解释性文字里出现「阈值链」三字不得被当成真正的阈值链');
    });
  });
}
