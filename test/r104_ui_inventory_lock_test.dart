// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/ui_interaction_inventory.dart';

/// **全功能点交互清单完整性锁（R104）**。
///
/// 它把「所有功能都点过」从一句口号变成**机器可判的红**：
/// 1. `lib/features/**` 里每个 UI 文件（含 `section_scaffold`）都必须在清单登记；
/// 2. 每条交互的证据文件必须存在、且是**真用例文件**（含 test 声明）；
/// 3. 每条都必须写明触发前 / 触发后状态，且两者不得相同
///    （没有状态变化的"功能点"多半是空壳按钮）；
/// 4. 反例组证明判据**能失败**，不是恒真。
void main() {
  final testDeclRe = RegExp(r'\b(test|testWidgets|group)\s*\(');

  /// 现场枚举所有 UI 文件（不写死清单，防止新增页面悄悄漏掉）。
  Set<String> scanUiFiles() {
    final out = <String>{};
    final dir = Directory('lib/features');
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        out.add(entity.path.replaceAll(r'\', '/'));
      }
    }
    // 二级 TAB 容器在 core/widgets 下，同样是用户可点的界面。
    const scaffold = 'lib/core/widgets/section_scaffold.dart';
    if (File(scaffold).existsSync()) out.add(scaffold);
    return out;
  }

  /// 唯一判据：返回所有违例（空 = 全绿）。
  List<String> audit(List<UiInteraction> items, Set<String> uiFiles) {
    final problems = <String>[];
    final ids = <String>{};
    final covered = <String>{};
    for (final e in items) {
      if (!ids.add(e.id)) problems.add('${e.id} 清单内重复 id');
      covered.add(e.uiFile);
      if (!File(e.uiFile).existsSync()) {
        problems.add('${e.id} UI 文件不存在：${e.uiFile}');
      }
      final ev = File(e.evidenceFile);
      if (!ev.existsSync()) {
        problems.add('${e.id} 证据文件不存在：${e.evidenceFile}');
      } else if (!testDeclRe.hasMatch(ev.readAsStringSync())) {
        problems.add('${e.id} 证据不是用例文件：${e.evidenceFile}');
      }
      if (e.before.trim().isEmpty || e.after.trim().isEmpty) {
        problems.add('${e.id} 缺触发前/触发后状态记录');
      }
      if (e.before == e.after) {
        problems.add('${e.id} 触发前后状态完全相同 —— 疑似空壳按钮');
      }
      if (e.action.trim().isEmpty) problems.add('${e.id} 缺动作');
    }
    for (final f in uiFiles) {
      if (!covered.contains(f)) problems.add('$f 含交互界面但未登记任何交互点');
    }
    return problems;
  }

  final uiFiles = scanUiFiles();

  group('R104 全功能点交互清单', () {
    test('UI-00 能现场枚举出全部 UI 文件（枚举不到即红）', () {
      expect(uiFiles.length, greaterThanOrEqualTo(30),
          reason: '实际枚举到 ${uiFiles.length} 个 UI 文件 —— 目录读取失败会让后面全部恒真');
    });

    test('UI-01 ★ 清单零违例（漏登记 / 死链 / 无状态变化都判红）', () {
      final problems = audit(uiInteractions, uiFiles);
      expect(problems, isEmpty,
          reason: '交互清单存在 ${problems.length} 处违例：\n${problems.join('\n')}');
    });

    test('UI-02 ★ 交互点覆盖率 100%（所有 UI 文件都有可点击证据）', () {
      final covered = uiInteractions.map((e) => e.uiFile).toSet();
      final missing = uiFiles.difference(covered);
      final ratio = uiFiles.isEmpty ? 0.0 : (uiFiles.length - missing.length) / uiFiles.length;
      print('UI 交互点覆盖：${uiFiles.length - missing.length}/${uiFiles.length} '
          '= ${(ratio * 100).toStringAsFixed(1)}%；交互点条目 ${uiInteractions.length} 条');
      expect(ratio, 1.0, reason: '仍有未登记的 UI 文件：$missing');
    });

    test('UI-03 本轮现场仿真条目非空，且都有对应证据文件', () {
      final sims = uiInteractions.where((e) => e.simulated).toList();
      expect(sims, isNotEmpty, reason: '本轮必须真的点击并采集前后状态，不能全是转述');
      for (final e in sims) {
        expect(File(e.evidenceFile).existsSync(), isTrue,
            reason: '${e.id} 的现场仿真用例文件不存在');
      }
      print('本轮现场仿真 ${sims.length} 条：${sims.map((e) => e.id).join(', ')}');
    });
  });

  group('UI-90 反面样本（证明判据非恒真）', () {
    test('90a 删掉某文件的全部条目 → 报「未登记」', () {
      const victim = 'lib/features/dashboard/dashboard_screen.dart';
      final bad = uiInteractions.where((e) => e.uiFile != victim).toList();
      expect(audit(bad, uiFiles).any((p) => p.contains('$victim 含交互界面')), isTrue);
    });

    test('90b 证据指向不存在的文件 → 报「证据文件不存在」', () {
      final bad = uiInteractions
          .map((e) => e.id == 'SIM-DBS-01'
              ? UiInteraction(e.id, e.uiFile, e.control, e.action, e.before,
                  e.after, 'test/__ghost__.dart')
              : e)
          .toList();
      expect(audit(bad, uiFiles).any((p) => p.startsWith('SIM-DBS-01 证据文件不存在')),
          isTrue);
    });

    test('90c 新增一个 UI 文件但不登记 → 覆盖率下降且报违例', () {
      final extended = <String>{...uiFiles, 'lib/features/__new_page.dart'};
      expect(audit(uiInteractions, extended).any((p) => p.contains('__new_page.dart')),
          isTrue);
    });
  });
}
