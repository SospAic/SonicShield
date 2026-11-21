// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// R104 / 第一百零四轮：**行级残差登记豁免**契约锁。
///
/// 起因：R99 把 42 行残差「逐行举证为结构不可达」，但结论只写在文档里，
/// 覆盖率工具仍按 99.72% 报 —— 于是「100%」既拿不到、也没法机器复核。
/// R104 把它变成可判定机制：`tool/coverage_report.dart` 增加
/// 「净可测面 = 可测面 − 逐行举证不可达行」，并加三道反向锁：
/// ① stale 自动失效；② 按文件对账（少举证一行就 exit 2）；③ 每条理由绑锚点。
///
/// ⚠️ 本锁盯的是**机制**（清单格式 / 工具真的扣减 / 文档真有举证表），
/// 不是盯某个覆盖率数字 —— 数字由覆盖率工具按 lcov 现场算，写死即过期。
void main() {
  const toolPath = 'tool/coverage_report.dart';

  /// 判定器：返回违规列表；真实仓库必须为空，篡改过的文本必须非空。
  List<String> lineExemptionViolations({
    required String toolSrc,
    required String doc12Src,
  }) {
    final out = <String>[];
    final m = RegExp(
            r'const Map<String, Map<int, String>> _lineExemptions[\s\S]*?\n\};')
        .firstMatch(toolSrc);
    if (m == null) {
      return ['找不到 `_lineExemptions` 声明 ⇒ 逐行举证机制整个消失'];
    }
    final block = m.group(0)!;
    final entries = RegExp(
            r"^\s*(\d+):\s*'([^']*)',?\s*$",
            multiLine: true)
        .allMatches(block)
        .toList();
    if (entries.length < 40) {
      out.add('行级豁免清单只有 ${entries.length} 条（终态残差应为数十行量级）'
          '⇒ 空清单/半清单都会让净口径自称 100% 变成橡皮章');
    }
    for (final e in entries) {
      final reason = e.group(2)!;
      if (!reason.contains('§135.7')) {
        out.add('${e.group(1)} 行缺 `§135.7` 举证锚点：$reason');
      }
      if (reason.length < 20) {
        out.add('${e.group(1)} 行理由过短（<20 字），不算逐行举证');
      }
    }
    // 工具必须真的实现三道反向锁 + 净口径，且不许偷改官方 ratchet 判据。
    for (final token in <String>[
      'staleExemptLines',
      'netGate',
      '净可测面',
      '按文件对账',
      "a.startsWith('--gate=')",
      'testablePct + 1e-9 < gate',
      'final netLf = tLf - exemptCount;',
    ]) {
      if (!toolSrc.contains(token)) {
        out.add('工具源码缺 `$token` ⇒ 机制被删或 ratchet 口径被偷改');
      }
    }
    if (!doc12Src.contains('### §135.7')) {
      out.add('`docs/12` 缺 §135.7 逐行举证表');
    }
    final tableRows = RegExp(r'^\|\s*`lib/', multiLine: true)
        .allMatches(doc12Src)
        .length;
    if (tableRows < 10) {
      out.add('§135.7 举证表只有 $tableRows 行文件级举证（应逐文件列出）');
    }
    return out;
  }

  final toolSrc = File(toolPath).readAsStringSync();
  final doc12Src = File('docs/12-测试报告.md').readAsStringSync();

  group('LNE · 行级残差登记豁免（R104）', () {
    test('LNE-01 ★ 真实仓库：清单、工具、举证表三者自洽', () {
      final v = lineExemptionViolations(
          toolSrc: toolSrc, doc12Src: doc12Src);
      for (final s in v) {
        print('[LNE] 违规：$s');
      }
      expect(v, isEmpty,
          reason: '行级豁免机制不完整 ⇒ 净可测面 100% 不可信');
    });

    test('LNE-02 清单不得含设备层整文件豁免对象（防双重扣减）', () {
      final m = RegExp(
              r'const Map<String, Map<int, String>> _lineExemptions[\s\S]*?\n\};')
          .firstMatch(toolSrc)!;
      for (final f in <String>[
        'lib/services/background_engine.dart',
        'lib/main.dart',
        'lib/services/neural_tts.dart',
      ]) {
        expect(m.group(0)!, isNot(contains("'$f':")),
            reason: '$f 已是设备层整文件豁免，再登记行级会双重扣减分母');
      }
    });

    test('LNE-03 官方 ratchet 判据未被本轮改动（可测面口径保持不变）', () {
      expect(toolSrc, contains('--gate='));
      expect(toolSrc, contains('--min-covered='));
      expect(toolSrc, contains('testablePct + 1e-9 < gate'),
          reason: '净口径只能走 --net-gate，不许替换官方 --gate 判据');
    });

    group('反面样本（篡改过的文本必须判红）', () {
      test('LNE-90 清单清空 → 判红', () {
        final bad = toolSrc.replaceFirst(
            RegExp(r'const Map<String, Map<int, String>> _lineExemptions[\s\S]*?\n\};'),
            'const Map<String, Map<int, String>> _lineExemptions = '
                '<String, Map<int, String>>{};');
        expect(bad, isNot(toolSrc), reason: '反面样本构造失败');
        expect(lineExemptionViolations(toolSrc: bad, doc12Src: doc12Src),
            isNotEmpty);
      });

      test('LNE-91 删掉 stale 自动失效 → 判红', () {
        final bad = toolSrc.replaceAll('staleExemptLines', 'ignoreMe');
        expect(bad, isNot(toolSrc));
        expect(lineExemptionViolations(toolSrc: bad, doc12Src: doc12Src),
            isNotEmpty);
      });

      test('LNE-92 删掉文档举证表 → 判红', () {
        final bad = doc12Src.replaceFirst('### §135.7', '### 已删除');
        expect(bad, isNot(doc12Src));
        expect(lineExemptionViolations(toolSrc: toolSrc, doc12Src: bad),
            isNotEmpty);
      });
    });
  });
}
