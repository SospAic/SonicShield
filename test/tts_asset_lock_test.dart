import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 离线神经 TTS 资产**打包锁**。
///
/// ## 为什么需要它
///
/// Flutter 的 `flutter.assets` 目录条目是**非递归**的：写 `assets/tts/` 只会把
/// 该目录**直属**的文件打进包，**不会**下钻到 `assets/tts/<模型目录>/`。
/// 于是 pubspec 只写一层时，64 MB 的 onnx 与 tokens/lexicon/fst 全部缺席 ——
/// 而 `NeuralTtsEngine` 走的是 `rootBundle.load`，运行期只会失败一次然后
/// **静默回落系统音色**：包能装、能跑、能出人声，只是"神经音色"永远不生效。
///
/// 这种缺陷**构建不会红、测试不会红、真机也不报错** —— 2026-10-10 在 release
/// APK 里实测 `unzip -l | grep tts` 一条都没有，才发现模型根本没进包。
///
/// 所以把它变成可断言的性质：**`assets/tts/` 下的每个文件都必须被某条
/// assets 条目覆盖**（覆盖关系按 Flutter 的"非递归"语义解释）。
///
/// ## 解析上的坑（本文件踩过）
///
/// 本仓库工作区文件是 **CRLF**（`core.autocrlf=true`）。若先 `split('\n')`
/// 再用带 `$` 的正则，行尾残留的 `\r` 会让 `$` **匹配不上**
/// （`.*` 到 `\r` 前就停了，而 `$` 只能匹配真正的串尾）——
/// 表现是"带注释的那一行解析不出来"，且只在**行内有 `#`** 时暴露。
/// 故这里先归一化换行、且注释剥离用不带 `$` 的 `#.*`。
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();

  /// 取出 pubspec 里 `assets:` 列表的条目（去行尾注释、去引号）。
  List<String> assetEntries(String text) {
    final entries = <String>[];
    var inAssets = false;
    for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
      // 不带 `$`：CRLF 下 `$` 锚点会失配（见文件头注释）。
      final line = raw.replaceAll(RegExp(r'#.*'), '').trim();
      if (line == 'assets:') {
        inAssets = true;
        continue;
      }
      if (!inAssets) continue;
      final m = RegExp(r'^-\s*(\S+)$').firstMatch(line);
      if (m != null) {
        entries.add(m.group(1)!.replaceAll('"', '').replaceAll("'", ''));
        continue;
      }
      if (line.isEmpty) continue; // 列表内的整行注释
      break; // 离开 assets 段
    }
    return entries;
  }

  /// Flutter 的覆盖语义：目录条目（以 `/` 结尾）只覆盖**直属**文件。
  bool covered(String relPath, List<String> entries) {
    for (final e in entries) {
      if (e.endsWith('/')) {
        if (relPath.startsWith(e) &&
            !relPath.substring(e.length).contains('/')) {
          return true;
        }
      } else if (relPath == e) {
        return true;
      }
    }
    return false;
  }

  const modelDir = 'assets/tts/vits-piper-zh_CN-xiao_ya-medium';

  test('TTS-ASSET-00 解析器自检：能读出 assets 条目（否则后两条恒真）', () {
    final entries = assetEntries(pubspec);
    expect(entries, contains('assets/audio/'),
        reason: '解析器没读出已知存在的条目 ⇒ 解析逻辑坏了，后面的断言没有意义');
    expect(entries, contains('$modelDir/'),
        reason: '模型目录条目没被读出 —— 要么 pubspec 少了它，要么解析器漏行');
  });

  test('TTS-ASSET-01 模型目录存在且含引擎所需全部文件', () {
    expect(Directory(modelDir).existsSync(), isTrue,
        reason: '模型目录不存在：$modelDir');
    for (final f in const <String>[
      'zh_CN-xiao_ya-medium.onnx',
      'tokens.txt',
      'lexicon.txt',
      'phone.fst',
      'date.fst',
      'number.fst',
    ]) {
      expect(File('$modelDir/$f').existsSync(), isTrue, reason: '缺模型文件：$f');
    }
  });

  test('TTS-ASSET-02 ★ 模型目录下每个文件都被 pubspec 的 assets 条目覆盖', () {
    final entries = assetEntries(pubspec);
    final files = Directory(modelDir)
        .listSync()
        .whereType<File>()
        .map((f) => f.path.replaceAll('\\', '/'))
        .toList();
    expect(files, isNotEmpty, reason: '模型目录里一个文件都没有 ⇒ 本锁恒真');
    for (final rel in files) {
      expect(
        covered(rel, entries),
        isTrue,
        reason: '`$rel` 没有被 pubspec 的 assets 条目覆盖 ⇒ 不会被打进包。'
            'Flutter 的目录条目**非递归**，必须在 flutter.assets 里显式再列一层：'
            '`- $modelDir/`。',
      );
    }
  });

  test('TTS-ASSET-02r 反例：只写 `assets/tts/` 时子目录文件判为未覆盖', () {
    const buggy = <String>['assets/audio/', 'assets/tts/'];
    expect(covered('$modelDir/tokens.txt', buggy), isFalse,
        reason: '反例必须判否，否则 TTS-ASSET-02 的判据是恒真的');
    // 同一判据对"直属文件"仍判真 —— 证明它不是一律判否。
    expect(covered('assets/tts/some_direct_file.bin', buggy), isTrue);
  });
}
