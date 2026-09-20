// =====================================================================
// AOT 预算归一化回归锁（BUG-054）
// =====================================================================
//
// ## 这个文件锁的是什么
//
// `integration_test/perf_nfr_test.dart`（AOT 绝对验收，`flutter drive --profile`）
// 里有一条**往返受限**的用例：
//
//     exec_logs 5000 条**逐条**写入 + recent   // 5000 次 append = 5000 次平台往返
//
// 它的耗时**完全由「本次运行的每次平台通道往返成本」决定**，而后者随机器状态
// 在 **1963µs ↔ 4839µs（2.5×）** 之间漂移。任何**硬编码的绝对 ms 护栏**
// 都会因此红绿翻转 —— 这正是 BUG-054：
//
//   · 护栏 20000ms（= 4ms/条，按"冷启 2.475ms/次"标定）
//   · 实测往返 1963µs → 9813ms → PASS（2.04×）
//   · 实测往返 4839µs → 24195ms → **FAIL**
//
// 本仓库对此已有明确约定（见 `perf_nfr_test.dart` 头注释）：
// **往返受限路径的预算必须自归一化**（`本次往返成本 × 调用次数 × 3`）。
// 其余往返受限用例（CRUD、任务逐条写入）都遵守了，**唯独这条没有**。
//
// ## 为什么它没遵守：基准自己给自己当基准
//
// 修前：`perCallUs = singleMs / 5000`，而 `singleMs` 正是这条 5000 次 append
// 的测量值 —— 用它来给**它自己**算预算会得到 `budgetFor(5000) ≡ 3 × singleMs`，
// **恒真、等于没测**。所以当时只能用绝对护栏。
//
// 修法：**基准改用一个独立的、小规模的同类探针**（`logs.append` × 200 次，
// 与那条 5000 次的用例解耦）→ 这条用例也能走 `budgetFor()`。
//
// ⚠️ **探针必须与被护栏的用例"同类"**（这是修的过程中踩到的第二个坑）：
// 曾改用 `tasks.get(<缺失 id>)`（纯 1 次 SELECT）当探针，结果它**低估**了
// 写入路径的单位成本（写入要 2~3 次往返）→ `任务 500 条逐条写入` 实测
// 3534ms / 预算 3728ms，**只剩 1.05× 余量** —— 等于把 BUG-054 搬到了
// 另一条用例上。**归一化的单位必须与被护栏的工作量同量级。**
//
// ## 本文件断言的性质（全部是"能失败"的）
//
// | # | 性质 | 违反后果 |
// |---|---|---|
// | A | 每条**往返受限**用例的预算必须是 `budgetFor(...)`，不得是字面量 | 该用例随机器状态假红（BUG-054 原状） |
// | B | 三条已知往返受限用例仍在（防改名后静默失去覆盖） | 锁"以为在守"其实没守 |
// | C | `perCallUs` 必须来自**独立探针**，不得由 `singleMs` 反推 | 恒真断言（3× 自己） |
// | D | 独立探针必须真的存在（`kProbeCalls` 常量 + 真实 Stopwatch 测量） | 性质 C 被空实现骗过 |
// | E | 那条 5000 用例的断言不得回退到绝对 `20000` | BUG-054 复活 |
// | F | 探针必须是**同类写入**，不得用廉价读代替 | 余量被结构差异吃掉（1.05× 的坑） |
// | G | 探针必须**预热** | 冷启抬高预算 → 护栏变松 |
//
// 判据来自 docs/12 §30.8 与 docs/17 §26⑦′ 的实测数据。
// =====================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉行注释与块注释 —— 否则"注释里写着修前的写法"会骗过 `isNot(contains(...))`。
String code(String src) => src
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .split('\n')
    .map((l) => l.replaceAll(RegExp(r'//.*$'), ''))
    .join('\n');

/// 取出 `src` 中 `start` 处 `(` 起、括号配对到 `)` 为止的内容（不含最外层括号）。
String _balanced(String src, int openIdx) {
  var depth = 0;
  for (var i = openIdx; i < src.length; i++) {
    final c = src[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return src.substring(openIdx + 1, i);
    }
  }
  throw StateError('括号未闭合（起点 $openIdx）');
}

/// 按**顶层**逗号切分实参（忽略嵌套括号/花括号/方括号里的逗号）。
List<String> _topLevelArgs(String s) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    } else if (c == ',' && depth == 0) {
      out.add(s.substring(start, i).trim());
      start = i + 1;
    }
  }
  out.add(s.substring(start).trim());
  return out;
}

/// 该用例名是否**往返受限**（每次调用 = 一次平台通道往返）。
///
/// 判据：名字含 `逐条`（逐条写入 = 每条一次往返）或 `CRUD`
/// （`任务 CRUD 500 次` = 500 upsert + 500 get = 1000 次往返）。
/// `批量` 路径是**单次**往返，与往返次数解耦，故不受此约束。
bool isRoundTripBound(String caseName) =>
    caseName.contains('逐条') || caseName.contains('CRUD');

void main() {
  // 解析阶段（test() 之外）**不能用 expect** —— 会抛 OutsideTestException，
  // 表现为"整个文件加载失败"（+0 -1），连用例名都看不到。用 StateError。
  final raw = File('integration_test/perf_nfr_test.dart').readAsStringSync();
  final src = code(raw);
  if (src.trim().isEmpty) throw StateError('AOT 用例文件解析为空');

  /// 所有 `report('<名>', <实测>, <预算>)` 调用 → (用例名, 预算表达式)。
  final reportCalls = <String, String>{};
  for (var i = src.indexOf('report('); i >= 0; i = src.indexOf('report(', i + 1)) {
    final args = _topLevelArgs(_balanced(src, i + 'report'.length));
    if (args.length < 3) continue;
    final name = args[0].replaceAll("'", '').trim();
    reportCalls[name] = args[2];
  }
  if (reportCalls.isEmpty) throw StateError('一个 report(...) 都没解析到');

  final roundTripCases =
      reportCalls.keys.where(isRoundTripBound).toList()..sort();

  group('AOT 预算归一化（BUG-054）', () {
    test('AN-01 必须解析到往返受限用例（否则本文件全是恒真）', () {
      expect(roundTripCases, isNotEmpty,
          reason: '判据是"名字含 逐条 或 CRUD"；一个都没匹配到 → 本文件的'
              '其余断言都在空集上成立，等于没测。'
              '若用例被改名，请同步更新 isRoundTripBound 的判据。');
    });

    test('AN-02 【BUG-054 回归锁】往返受限用例的预算必须是 budgetFor()，不得是字面量', () {
      final bad = <String>[];
      for (final name in roundTripCases) {
        if (!reportCalls[name]!.startsWith('budgetFor(')) {
          bad.add('「$name」→ ${reportCalls[name]}');
        }
      }
      expect(bad, isEmpty,
          reason: '往返受限路径的预算**必须自归一化**（本次往返成本 × 调用次数 × 3）。'
              '用字面量 ms 的后果：往返成本在 1963↔4839µs（2.5×）之间漂移时，'
              '该用例会随机器状态红绿翻转 —— 这就是 BUG-054。\n'
              '违规项：$bad');
    });

    test('AN-03 三条已知往返受限用例仍在（防改名后静默失去覆盖）', () {
      const known = [
        'exec_logs 5000 条**逐条**写入 + recent',
        '任务 CRUD 500 次',
        '任务 500 条**逐条**写入',
      ];
      for (final k in known) {
        expect(reportCalls.containsKey(k), isTrue,
            reason: '找不到用例「$k」。若它被改名，AN-02 的覆盖面会静默缩小'
                '（改名后可能不再含 逐条/CRUD）→ 请同步更新 isRoundTripBound 与'
                '本清单，而不是直接删掉这一条。');
      }
    });

    test('AN-04 基准必须来自**独立探针**，不得由被护栏的 singleMs 反推', () {
      final defLines = src
          .split('\n')
          .where((l) => l.contains('perCallUs ='))
          .toList();
      expect(defLines, hasLength(1),
          reason: 'perCallUs 应当恰好定义一次，实际 ${defLines.length} 处：$defLines');
      final def = defLines.single;
      expect(def, contains('probeMs'),
          reason: 'perCallUs 必须由独立探针（probeMs）测得，实际：$def');
      expect(def, isNot(contains('singleMs')),
          reason: 'perCallUs 不得由被护栏的 singleMs 反推 —— 那会让 '
              'budgetFor(5000) ≡ 3 × singleMs，**恒真、等于没测**（BUG-054 的成因）。'
              '实际：$def');
    });

    test('AN-05 独立探针必须真的存在（否则 AN-04 会被空实现骗过）', () {
      expect(src, contains('const kProbeCalls'),
          reason: '探针次数必须是具名常量（便于人工核对量级）');
      expect(src, contains('probeMs = sw.elapsedMilliseconds'),
          reason: '探针必须真的用 Stopwatch 测量，而不是写死的值');
    });

    test('AN-05b 【归一化单位必须与被护栏的工作量同量级】探针必须是同类写入，不得用廉价读代替', () {
      // 第一次修 BUG-054 时曾用 `tasks.get(<缺失 id>)`（纯 1 次 SELECT）当探针，
      // 结果它**低估**了写入路径的单位成本（写入要 2~3 次往返）→
      // `任务 500 条逐条写入` 实测 3534ms / 预算 3728ms，只剩 **1.05× 余量**
      // —— 等于把 BUG-054 搬到另一条用例上。
      final probeLoop = src.contains("source: 'probe'");
      expect(probeLoop, isTrue,
          reason: '探针必须是与被护栏用例**同类的写入路径**（`logs.append` 且带 '
              '`source: \'probe\'` 标记），否则它测出的单位成本与被护栏的工作量'
              '不同量级，3× 安全系数会被结构差异吃掉。');
      expect(src, isNot(contains("tasks.get('__perf_probe_missing__')")),
          reason: '不得用"读一行不存在的记录"（纯 1 次往返）当探针 —— '
              '它是本仓库已踩过的坑，见上方 reason。');
    });

    test('AN-05c 探针必须预热（避免用冷启成本抬高全部预算）', () {
      expect(src, contains("action: 'warmup'"),
          reason: '探针跑在一切之前，冷启会显著抬高单次成本 → 预算被抬高、'
              '护栏变松。必须先跑一小段预热。');
    });

    test('AN-06 【BUG-054 回归锁】5000 条逐条用例不得回退到绝对 20000ms', () {
      expect(src, isNot(contains('lessThanOrEqualTo(20000)')),
          reason: '20000ms 是按"冷启 2.475ms/次"标定的绝对护栏，'
              '实测往返可到 4839µs/次 → 余量在 2.0×↔0.83× 摆动、跨 1.0 就红。'
              '必须改用 budgetFor(5000)。');
      expect(reportCalls['exec_logs 5000 条**逐条**写入 + recent'],
          'budgetFor(5000)',
          reason: '该用例的预算必须显式绑定到 5000 次往返的自归一化预算');
    });
  });
}
