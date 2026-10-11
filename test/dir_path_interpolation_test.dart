import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 目录路径拼接锁（BUG-065）。
///
/// ## 为什么需要它
///
/// 任务导出在真机上**从来没有成功过**，而根因只是一行字符串插值：
///
/// ```dart
/// final dir = await getTemporaryDirectory();
/// final path = '$dir/sonic_shield_tasks_$stamp.json';   // ❌
/// ```
///
/// `Directory.toString()` **不是路径**，实测返回 `Directory: 'C:\Temp\xxx'`
/// （带 `Directory: ` 前缀与单引号）。插值后得到
/// `Directory: 'C:\Temp\xxx'/sonic_shield_tasks_123.json` —— 一个不存在的
/// 路径，`writeAsString` 必抛 `FileSystemException`，被 `_exportTasks` 的
/// `catch` 吞成一句「导出失败：…」。
///
/// 危害不在"写错了"，而在**它只影响一条路径**：全仓 7 处目录拼接里，
/// 另外 6 处都写的是 `${dir.path}/…`（正确）。所以它既不会被代码评审注意到，
/// 也不会被别的功能连累 —— 只有真去点一次「导出任务」才会发现，
/// 而用户看到的只是一句没有信息量的失败提示。
///
/// 这类"单点偏离既有惯例"的缺陷**只能靠机器扫**：人眼扫 7 处不会发现
/// 第 7 处少了个 `.path`。
void main() {
  /// 会返回 `Directory` 的插件 API（宿主/设备通用）。
  const dirApis = <String>[
    'getTemporaryDirectory',
    'getApplicationDocumentsDirectory',
    'getApplicationSupportDirectory',
    'getApplicationCacheDirectory',
    'getDownloadsDirectory',
    'getLibraryDirectory',
    'getExternalStorageDirectory',
  ];

  /// 一行里出现了任意一个目录 API 调用。
  final apiCallRe = RegExp(r'\b(get\w*Directory)\s*\(\s*\)');

  /// 把 `Directory` 赋给一个局部变量：`final dir = await getTemporaryDirectory()`
  /// 或 `final dir = Directory(...)`。
  final assignFromApiRe =
      RegExp(r'\b(?:final|var|Directory)\s+(\w+)\s*=\s*(?:await\s+)?(get\w*Directory)\s*\(');
  final assignFromCtorRe =
      RegExp(r'\b(?:final|var)\s+(\w+)\s*=\s*Directory\s*\(');
  /// 箭头体赋值：`Future<Directory> f() => getXxxDirectory();`
  /// （无 `=`，只有 `=>` —— 上面的 `\s*=\s*` 匹配不到，需单独识别，
  ///  否则 DIP-03 会把「有调用点却零识别」的文件误判为锁空转）。
  final arrowFromApiRe =
      RegExp(r'=>\s*(?:await\s+)?(get\w*Directory)\s*\(\)');

  /// 变量被插值**但没有接 `.path`** —— 就是 BUG-065 的形态。
  RegExp bareInterp(String name) =>
      RegExp(r'\$' + RegExp.escape(name) + r'(?!\.path)');
  RegExp braceInterp(String name) =>
      RegExp(r'\$\{' + RegExp.escape(name) + r'\}');

  /// 逐行扫一个文件，返回 (坏插值行号, 该行内容)。
  List<(int, String)> scan(String src) {
    final lines = src.split('\n');
    final dirVars = <String>{};
    final apiFilesFound = <String>{};
    for (final line in lines) {
      final code = line.trimLeft();
      if (code.startsWith('//') || code.startsWith('*')) continue;
      final m = assignFromApiRe.firstMatch(line) ??
          assignFromCtorRe.firstMatch(line);
      if (m != null) {
        dirVars.add(m.group(1)!);
        // ⚠️ `assignFromCtorRe` 只有 1 个捕获组 ⇒ `group(2)` 会抛 RangeError。
        // 用 `groupCount` 判定，而不是无脑取 group(2)。
        apiFilesFound
            .add(m.groupCount >= 2 ? (m.group(2) ?? 'Directory') : 'Directory');
      }
    }
    final bad = <(int, String)>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final code = line.trimLeft();
      if (code.startsWith('//') || code.startsWith('*')) continue;
      for (final name in dirVars) {
        if (bareInterp(name).hasMatch(line) ||
            braceInterp(name).hasMatch(line)) {
          bad.add((i + 1, line.trim()));
        }
      }
    }
    return bad;
  }

  List<File> libDartFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  group('DIP 目录路径拼接锁（BUG-065）', () {
    test('DIP-01 lib/ 下所有 Directory 变量插值时都必须接 .path', () {
      final offenders = <String>[];
      for (final f in libDartFiles()) {
        for (final (lineNo, text) in scan(f.readAsStringSync())) {
          offenders.add('${f.path}:$lineNo  $text');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '`Directory.toString()` 返回的是 "Directory: \'…\'"，不是路径。\n'
            '插值必须写 `\${dir.path}/…`。以下位置漏了 `.path`：\n'
            '${offenders.join('\n')}',
      );
    });

    test('DIP-02 检测器本身**能失败**（自检：否则这是恒真的假锁）', () {
      // 反面样本：正是 BUG-065 那一行。
      const broken = '''
      final dir = await getTemporaryDirectory();
      final path = '\$dir/sonic_shield_tasks_\$stamp.json';
      ''';
      expect(scan(broken), hasLength(1),
          reason: '反面样本必须被检出，否则本锁恒真');

      // 另一形态：`${dir}` 裸插值。
      const brokenBrace = '''
      final dir = await getApplicationDocumentsDirectory();
      final p = '\${dir}/x.json';
      ''';
      expect(scan(brokenBrace), hasLength(1));

      // 正面样本：正确写法必须**不**被误报。
      const ok = '''
      final dir = await getTemporaryDirectory();
      final path = '\${dir.path}/sonic_shield_tasks_\$stamp.json';
      await Share.shareXFiles([XFile('\${dir.path}/a.enc')]);
      ''';
      expect(scan(ok), isEmpty, reason: '正确写法不能误报');
    });

    test('DIP-03 每个目录 API 调用点都被识别（防 API 改名后锁空转）', () {
      final files = libDartFiles();
      final apiCallFiles = <String>{};
      final recognisedFiles = <String>{};
      for (final f in files) {
        final src = f.readAsStringSync();
        var calls = 0;
        var recognised = 0;
        for (final line in src.split('\n')) {
          final code = line.trimLeft();
          if (code.startsWith('//') || code.startsWith('*')) continue;
          if (apiCallRe.hasMatch(line)) calls++;
          if (assignFromApiRe.hasMatch(line) ||
              arrowFromApiRe.hasMatch(line)) {
            recognised++;
          }
        }
        if (calls > 0) apiCallFiles.add(f.path);
        if (recognised > 0) recognisedFiles.add(f.path);
      }
      // 有调用点却一个变量都没提取到 → 赋值写法变了（或 API 改名），
      // 本锁会静默空转 → 必须红。
      final missed = apiCallFiles.difference(recognisedFiles);
      expect(missed, isEmpty,
          reason: '这些文件调用了目录 API 但没被识别出赋值变量，锁会空转：$missed');
      // 反向哨兵：如果全仓一个调用点都扫不到，说明扫的目录/后缀写错了。
      expect(apiCallFiles, isNotEmpty,
          reason: '一个目录 API 调用点都没扫到 —— 扫描范围（lib/**/*.dart）可能错了');
      expect(dirApis.length, 7);
    });
  });
}
