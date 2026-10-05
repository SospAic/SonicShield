// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/feature_point_inventory.dart';

/// **全功能点用例库完整性锁**。
///
/// ## 它防的是什么
///
/// 追溯矩阵（[featurePoints]）只有在**与需求规格严格对齐**时才有意义。
/// 三种退化都必须是**机器可判**的红：
///
/// 1. **遗漏**：`docs/02` 新增了一个 FR，矩阵没跟上 ⇒ 覆盖率悄悄掉到 <100%；
/// 2. **死链**：用例文件被删/改名，或里面那个标识串被改掉 ⇒ 矩阵仍"看起来"覆盖，
///    实际证据已不存在；
/// 3. **注水**：把证据指到一个**不含任何用例**的文件（空壳），假装覆盖。
///
/// 判据全部收在一个纯函数 [audit] 里，反例组（FP-R*）在同一判据上制造退化，
/// 证明它**非恒真**。
void main() {
  final doc = File('docs/02-需求规格说明书.md');

  /// 从需求规格里解析出所有功能点编号（表格首列 `| FR-xx |` / `| NFR-xx |`）。
  Set<String> parseDocIds(String src) {
    final re = RegExp(r'^\|\s*((?:FR|NFR)-[0-9]+[a-z]?)\s*\|', multiLine: true);
    return re.allMatches(src).map((m) => m.group(1)!).toSet();
  }

  /// 证据文件相对路径 → 类别。`null` = 路径不在允许的三类前缀内（判红）。
  String? kindOf(FeaturePoint e) {
    if (e.superseded) return 'superseded';
    if (e.evidenceFile.startsWith('test/')) return 'host';
    if (e.evidenceFile.startsWith('integration_test/')) return 'device';
    if (e.evidenceFile.startsWith('docs/')) return 'manual';
    return null;
  }

  final testDeclRe = RegExp(r'\b(test|testWidgets|group)\s*\(');

  /// 单条证据是否成立（文件存在 + 含 token + host/device 必须有用例声明）。
  bool evidenceOk(FeaturePoint e) {
    final kind = kindOf(e);
    if (kind == null) return false;
    final f = File(e.evidenceFile);
    if (!f.existsSync()) return false;
    final src = f.readAsStringSync();
    if (!src.contains(e.token)) return false;
    if (kind == 'host' || kind == 'device') {
      if (!testDeclRe.hasMatch(src)) return false;
    }
    return true;
  }

  /// **唯一判据**：返回所有违例（空 = 全绿）。
  List<String> audit(List<FeaturePoint> fps, Set<String> docIds) {
    final problems = <String>[];
    final seen = <String>{};
    for (final e in fps) {
      if (!seen.add(e.id)) problems.add('${e.id} 矩阵内重复条目');
      if (kindOf(e) == null) {
        problems.add('${e.id} 证据路径不属于 test/ integration_test/ docs/：${e.evidenceFile}');
      }
    }
    for (final id in docIds) {
      if (!seen.contains(id)) problems.add('$id 遗漏：docs/02 有、矩阵没有');
    }
    for (final id in seen) {
      if (!docIds.contains(id)) problems.add('$id 多出：矩阵有、docs/02 没有');
    }
    for (final e in fps) {
      if (!evidenceOk(e)) {
        problems.add('${e.id} 证据不成立：文件缺失 / 不含 `"${e.token}"` / '
            '非用例文件（${e.evidenceFile}）');
      }
    }
    return problems;
  }

  int activeTotal(List<FeaturePoint> fps) =>
      fps.where((e) => !e.superseded).length;
  int coveredActive(List<FeaturePoint> fps) =>
      fps.where((e) => !e.superseded && evidenceOk(e)).length;

  final docIds = doc.existsSync()
      ? parseDocIds(doc.readAsStringSync())
      : <String>{};

  // =====================================================================
  group('全功能点用例库', () {
    test('FP-00 能从 docs/02 解析出全部 57 个功能点（解析不到即红）', () {
      expect(doc.existsSync(), isTrue, reason: 'docs/02-需求规格说明书.md 不存在 —— 本锁失去真源');
      expect(
        docIds.length,
        57,
        reason: 'docs/02 解析到的功能点数是 ${docIds.length}，期望 57。'
            '若需求规格确实增删了条目，必须同步改本测试与矩阵 —— 不许静默漂移。',
      );
    });

    test('FP-01 ★ 矩阵与 docs/02 功能点集合完全一致，且每条证据都成立', () {
      final problems = audit(featurePoints, docIds);
      expect(problems, isEmpty,
          reason: '功能点用例库存在 ${problems.length} 处违例：\n${problems.join('\n')}');
    });

    test('FP-02 ★ 非取代型功能点覆盖率 = 100%（无遗漏、无死链）', () {
      final total = activeTotal(featurePoints);
      final covered = coveredActive(featurePoints);
      final ratio = total == 0 ? 0.0 : covered / total;
      print('功能点覆盖：$covered/$total = ${(ratio * 100).toStringAsFixed(1)}% '
          '（另含 ${featurePoints.length - total} 条已取代项，不计入分母）');
      expect(ratio, 1.0, reason: '存在功能点没有可执行/文档证据 —— 覆盖率不足 100%');
    });

    test('FP-03 三个非零分组都不为空（避免"全归一类"掩盖口径）', () {
      final hosts = featurePoints.where((e) => kindOf(e) == 'host').length;
      final devices = featurePoints.where((e) => kindOf(e) == 'device').length;
      final manuals = featurePoints.where((e) => kindOf(e) == 'manual').length;
      print('分类：host=$hosts device=$devices manual=$manuals '
          'superseded=${featurePoints.length - hosts - devices - manuals}');
      expect(hosts, greaterThan(0));
      expect(devices, greaterThan(0));
      expect(manuals, greaterThan(0),
          reason: '观测/现场型 NFR 必须有 manual 分类，否则会把它们误混进自动化通过率');
    });
  });

  // =====================================================================
  group('反例：判据非恒真', () {
    test('FP-R1 从矩阵删掉一条 → 判据报"遗漏"', () {
      final bad = featurePoints.where((e) => e.id != 'FR-13').toList();
      final problems = audit(bad, docIds);
      expect(problems.any((p) => p.contains('FR-13 遗漏')), isTrue,
          reason: '★ 反例必须被抓 ⇒ 集合一致性判据非恒真');
    });

    test('FP-R2 把某条 token 改成不存在的串 → 判据报"证据不成立"', () {
      final bad = featurePoints
          .map((e) => e.id == 'FR-30'
              ? const FeaturePoint('FR-30', 'x',
                  evidenceFile: 'test/task_wire_test.dart',
                  token: '__no_such_token__')
              : e)
          .toList();
      final problems = audit(bad, docIds);
      expect(problems.any((p) => p.startsWith('FR-30 证据不成立')), isTrue,
          reason: '★ 反例必须被抓 ⇒ 证据存在性判据非恒真');
      expect(coveredActive(bad), lessThan(activeTotal(bad)),
          reason: '★ 覆盖率判据也必须随之下降 ⇒ 非恒真');
    });

    test('FP-R3 把证据指向不存在的文件 / 非法前缀 → 判据报错', () {
      final badMissing = featurePoints
          .map((e) => e.id == 'FR-01'
              ? const FeaturePoint('FR-01', 'x',
                  evidenceFile: 'test/__ghost_test.dart', token: 'x')
              : e)
          .toList();
      expect(audit(badMissing, docIds).any((p) => p.startsWith('FR-01 证据不成立')),
          isTrue);

      final badPrefix = featurePoints
          .map((e) => e.id == 'FR-01'
              ? const FeaturePoint('FR-01', 'x',
                  evidenceFile: 'lib/main.dart', token: 'main')
              : e)
          .toList();
      expect(
          audit(badPrefix, docIds)
              .any((p) => p.startsWith('FR-01 证据路径不属于')),
          isTrue,
          reason: '★ 把证据指到实现代码（非用例）必须被判红');
    });
  });
}