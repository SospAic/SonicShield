// ignore_for_file: avoid_print
/// 覆盖率**分母**生成器 —— 生成 `test/coverage_sentinel_test.dart`。
///
/// ## 为什么需要它（这不是"为了好看的数字"，是修一个测量缺陷）
///
/// Dart 的覆盖率只统计**测试运行期被加载过的库**：
/// 一个从未被任何 `import` 触及的 `lib/xxx.dart` **根本不会出现在
/// `coverage/lcov.info` 里** —— 它既不计分子也不计分母。
///
/// 实测（2026-09-21 第二十轮）：`lib/` 下 **74** 个 `.dart`，
/// lcov 里只有 **44** 个 `SF:` 记录。**30 个文件（含 `task_list_screen` /
/// `guard_screen` / `remote_screen` / `settings_screen` / `router` / `main`
/// 等全部主要 UI 页）从未被 import**，于是"全局覆盖率 57.5%"这个数字
/// **分母悄悄少算了约 40% 的代码**。
///
/// 后果：越是不写测试、越是不 import，覆盖率反而越"好看"。
/// 这类**可以靠不测来优化**的口径，比没有指标更危险。
///
/// ## 修法
///
/// 生成一个只做 `import` 的哨兵测试：它不调用任何东西，唯一作用是让每个库
/// 都被**加载**，从而在 lcov 里留下 `SF:` 记录 —— 未执行的函数自然记 `LH:0`。
/// 分母因此**完整且不可作弊**。
///
/// 哨兵里还带一条**自检锁**：用 `Directory('lib')` 现场枚举真实文件，
/// 与哨兵的 import 列表比对。**新增 lib 文件却忘了刷新哨兵 → 测试直接红**，
/// 并提示跑本脚本。分母完整性由机器保证，不靠人记。
///
/// ## 用法
///
/// ```bash
/// dart run tool/gen_coverage_sentinel.dart      # 重新生成哨兵
/// flutter test --coverage --exclude-tags perf   # 跑覆盖率（分母已完整）
/// dart run tool/coverage_report.dart            # 看报告
/// ```
///
/// ⚠️ 实现注记：模板一律用**原始字符串**（`r'''`）+ 占位符替换。
/// 早期版本用普通 `'''` 模板，`\\` 被当成转义吃掉 → 生成出 `r'\'`
/// 这种非法 Dart，且 `\${...}` 被原样输出。**转义地雷在生成器里是必然的**，
/// 用占位符绕开比小心翼翼地数反斜杠可靠得多。
library;

import 'dart:io';

const String _pkg = 'sonic_shield';
const String _sentinelPath = 'test/coverage_sentinel_test.dart';

/// 枚举 `lib/` 下所有 `.dart`，返回**正斜杠**相对路径（跨平台稳定）。
List<String> libDartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((f) => f.path.replaceAll(r'\', '/'))
    .where((p) => p.endsWith('.dart'))
    .toList()
  ..sort();

/// 哨兵模板：**原始字符串**，三处占位符由 [buildSentinel] 替换。
const String _template = r'''// GENERATED FILE —— 请勿手工编辑。改 lib/ 结构后跑：
//   dart run tool/gen_coverage_sentinel.dart
//
// 覆盖率哨兵：只 import、不调用。
//
// 作用：Dart 覆盖率只统计**运行期被加载过的库**，未被任何 import 触及的
// 文件在 lcov.info 里**完全不存在**（不计分子也不计分母）—— 于是"不测"
// 反而让覆盖率更好看。本文件让 `lib/` 下每个库都被加载，未执行的函数
// 自然记 `LH:0`，分母因此**完整且不可作弊**。
//
// 实测背景见 tool/gen_coverage_sentinel.dart 的文档注释。
// ignore_for_file: unused_import, depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

__IMPORTS__

void main() {
  // ① 分母自检：lib/ 现场枚举 vs 哨兵 import 列表，必须完全一致。
  //    ⚠️ 这条是**真锁**：新增 lib 文件却忘了刷新哨兵 → 直接红。
  test('COV-01 覆盖率哨兵覆盖 lib 下全部 .dart（分母完整性）', () {
    final src = File('__SENTINEL__').readAsStringSync();
    final imported = RegExp(r"import 'package:__PKG__/([^']+)';")
        .allMatches(src)
        .map((m) => 'lib/${m.group(1)}')
        .toSet();

    final onDisk = libDartFilesForTest().toSet();

    final missing = onDisk.difference(imported).toList()..sort();
    expect(
      missing,
      isEmpty,
      reason: 'lib 下这些文件没有被哨兵 import，覆盖率分母会漏算它们：\n'
          '  ${missing.join('\n  ')}\n'
          '修复：dart run tool/gen_coverage_sentinel.dart',
    );

    final stale = imported.difference(onDisk).toList()..sort();
    expect(
      stale,
      isEmpty,
      reason: '哨兵引用了已不存在的文件（重命名/删除后没刷新）：\n'
          '  ${stale.join('\n  ')}\n'
          '修复：dart run tool/gen_coverage_sentinel.dart',
    );

    // 反向自检：确认扫描本身确实读到了东西。
    // 防"正则写错 → 两边都空 → 断言恒绿"这种**假锁**。
    expect(imported.length, greaterThan(50),
        reason: '哨兵 import 数异常（${imported.length}）—— 正则或路径可能写错了');
    expect(onDisk.length, greaterThan(50),
        reason: 'lib 枚举数异常（${onDisk.length}）—— 工作目录可能不对');
  });
}

/// 与 tool/gen_coverage_sentinel.dart 的 [libDartFiles] 同逻辑。
///
/// 这里**故意复制一份**而不是 import tool/ 下的脚本：
/// 测试不应依赖 `tool/` 的实现细节。两份各自独立，若哪天分叉，
/// COV-01 会因为"枚举结果对不上"而红 —— 这正是我们要的。
List<String> libDartFilesForTest() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((f) => f.path.replaceAll(r'\', '/'))
    .where((p) => p.endsWith('.dart'))
    .toList();
''';

String buildSentinel(List<String> files) {
  final imports = files.map((p) {
    // lib/foo/bar.dart  →  package:sonic_shield/foo/bar.dart
    final rel = p.substring('lib/'.length);
    return "import 'package:$_pkg/$rel';";
  }).join('\n');

  return _template
      .replaceAll('__IMPORTS__', imports)
      .replaceAll('__SENTINEL__', _sentinelPath)
      .replaceAll('__PKG__', _pkg);
}

void main() {
  final files = libDartFiles();
  if (files.isEmpty) {
    stderr.writeln('未找到 lib/ 下的 .dart —— 请在项目根目录运行本脚本。');
    exit(1);
  }
  File(_sentinelPath).writeAsStringSync(buildSentinel(files));
  print('已生成 $_sentinelPath（$_pkg，${files.length} 个库）');
}
