// ignore_for_file: avoid_print
/// 未覆盖行定位器 —— 回答"我该补哪一行的测试"，而不是"我差百分之几"。
///
/// ## 为什么需要它
///
/// `coverage_report.dart` 只给**每个文件差多少行**。但"差 68 行"这个数字
/// 对补测试毫无指导性 —— 你不知道这 68 行是
/// ① 真漏了的分支、② 设备依赖、还是 ③ 死代码。
///
/// 本工具直接把**未覆盖行的源码原文**打出来，让分类变成"看一眼"而不是"猜"。
///
/// ## 用法
///
/// ```bash
/// dart run tool/uncovered_lines.dart remote_screen
/// dart run tool/uncovered_lines.dart features/remote/remote_screen.dart ptt_tab
/// dart run tool/uncovered_lines.dart --context=2 remote_screen   # 带上下文
/// ```
///
/// 参数是**子串**：只要文件路径包含它就会被选中（用 `/` 或 `\` 都行，
/// 内部统一归一化）。不给参数时列出"缺口最大的 10 个文件"作为提示。
///
/// ## 分类约定（看到行后的判断口诀）
///
/// | 看到的形态 | 分类 | 动作 |
/// |---|---|---|
/// | `if` / `??` / `catch` / `switch` 的**另一半分支** | 真漏了 | 补用例 |
/// | `MethodChannel.invokeMethod` / `await` 真实插件 | 设备依赖 | **别写假用例**，用源码锁 |
/// | `main()` / `runApp` / `WidgetsFlutterBinding` | 入口不可达 | 登记 |
/// | `Color` / `EdgeInsets` / `const` | 无行为 | 忽略 |
library;

import 'dart:io';

void main(List<String> args) {
  final context = int.tryParse(
          (args
                      .firstWhere((a) => a.startsWith('--context='),
                          orElse: () => '--context=0')
                      .split('=')
                      .last)) ??
      0;
  final needles = args
      .where((a) => !a.startsWith('--'))
      .map((a) => a.replaceAll('\\', '/').toLowerCase())
      .toList();

  final lcov = File('coverage/lcov.info');
  if (!lcov.existsSync()) {
    stderr.writeln('找不到 coverage/lcov.info —— 先跑：');
    stderr.writeln('  flutter test --exclude-tags perf --coverage --concurrency=2');
    exit(2);
  }

  // ---- 解析 lcov ----
  final Map<String, Map<int, int>> hits = <String, Map<int, int>>{};
  String? cur;
  for (final raw in lcov.readAsLinesSync()) {
    final line = raw.trim();
    if (line.startsWith('SF:')) {
      cur = line.substring(3).replaceAll('\\', '/');
      hits.putIfAbsent(cur, () => <int, int>{});
    } else if (line.startsWith('DA:') && cur != null) {
      final parts = line.substring(3).split(',');
      if (parts.length >= 2) {
        hits[cur]![int.tryParse(parts[0]) ?? -1] = int.tryParse(parts[1]) ?? 0;
      }
    }
  }

  // ---- 选文件 ----
  var selected = hits.keys.toList()..sort();
  if (needles.isNotEmpty) {
    selected = selected
        .where((f) =>
            needles.any((n) => f.toLowerCase().contains(n)))
        .toList();
    if (selected.isEmpty) {
      stderr.writeln('没有文件匹配：${needles.join(', ')}');
      stderr.writeln('提示：用 `/` 路径片段，例如 features/remote/remote_screen.dart');
      exit(1);
    }
  } else {
    final ranked = selected.toList()
      ..sort((a, b) => _uncovered(hits[b]!).length.compareTo(_uncovered(hits[a]!).length));
    print('未给参数 —— 缺口最大的 10 个文件（用它们的路径片段再跑一次）：\n');
    for (final f in ranked.take(10)) {
      final u = _uncovered(hits[f]!);
      print('  ${u.length.toString().padLeft(4)} 行  $f');
    }
    return;
  }

  // ---- 输出 ----
  for (final f in selected) {
    final un = _uncovered(hits[f]!).toSet();
    final total = hits[f]!.length;
    final srcFile = File(f.replaceAll('/', Platform.pathSeparator));
    if (!srcFile.existsSync()) {
      print('\n### $f\n  (源文件不存在，跳过)');
      continue;
    }
    final src = srcFile.readAsLinesSync();
    print('\n${'═' * 74}');
    print('### $f');
    print('    未覆盖 ${un.length} / 可执行 $total  '
        '（已覆盖 ${((total - un.length) / total * 100).toStringAsFixed(1)}%）');
    print('═' * 74);
    for (var i = 0; i < src.length; i++) {
      final lineNo = i + 1;
      if (!un.contains(lineNo)) continue;
      print('${lineNo.toString().padLeft(4)}▶ ${src[i]}');
      for (var c = 1; c <= context; c++) {
        if (i - c >= 0) print('     ${src[i - c]}');
      }
    }
  }
}

List<int> _uncovered(Map<int, int> m) =>
    m.entries.where((e) => e.value == 0).map((e) => e.key).toList()..sort();
