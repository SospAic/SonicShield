import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

/// 覆盖率「设备层豁免」白名单的**机器锁**（DEX 系列）。
///
/// ## 为什么必须有这把锁
///
/// `tool/coverage_report.dart` 的 `_deviceOnly` 白名单是一个**危险的旋钮**：
/// 往里塞一个文件，就能把它的未覆盖行从**门禁口径（可测面）**里整体抹掉。
/// 一旦失去约束，它就会退化成"调口径、不补测试"的橡皮章 ——
/// 这正是工具文件头那句「别为了数字好看往里塞」想防、却**防不住**的事
/// （注释管不住手）。所以要用**机器判据**把旋钮钉死。
///
/// ## 钉死的三条
///
/// 1. **双向绑定**：`_deviceOnly` 的键集合 **必须恰好等于** 本文件的
///    [_requiredMarkers] 键集合。多一个（偷偷豁免）/ 少一个（幽灵条目）
///    都判红 ⇒ 想加豁免就必须**同时**在这里补证据；
/// 2. **结构证据**：每个被豁免的文件里**必须真实存在**一个能证明它
///    「宿主跑不了」的字面量标记（引擎 isolate 的 `@pragma('vm:entry-point')`、
///    装配入口的 `runApp(`）。哪天有人把它重构成纯逻辑，标记消失 ⇒
///    锁立刻判红，豁免无法继续赖在白名单里；
/// 3. **理由可审**：每条 reason 去掉空白后不得短于 40 字 —— 一句话糊弄
///    过不了。
///
/// ⚠️ 本锁读源码文本，因此**一律先 [stripComments]**（注释满足断言 =
/// 锁退化成装饰品，见 `test/support/source_text.dart` 文件头）。
void main() {
  /// 豁免白名单的**结构证据表**：`被豁免文件 → 必须真实存在于其中的标记`。
  ///
  /// 新增豁免时**必须**同时在这里补一行，且标记必须是该文件里
  /// **不可移除**的结构性代码（不是注释、不是随便一句文案）。
  const Map<String, String> requiredMarkers = <String, String>{
    'lib/services/background_engine.dart': "@pragma('vm:entry-point')",
    'lib/main.dart': 'runApp(',
  };

  final toolSrc = File('tool/coverage_report.dart').readAsStringSync();

  /// 白名单的 map 字面量块（含两端大括号）。定位失败 = 判红，不静默通过。
  const decl = 'const Map<String, String> _deviceOnly = <String, String>{';
  final open = toolSrc.indexOf(decl);
  final mapBody =
      open < 0 ? null : balancedSlice(toolSrc, open + decl.length - 1);

  /// 解析 `'key': 'value' ...` 形式的 map 字面量 → 键值映射。
  ///
  /// 值允许**相邻字符串拼接**（Dart 会把 `'a' 'b'` 当成一个字面量）。
  Map<String, String> parseMap(String body) {
    final out = <String, String>{};

    String unquote(String raw) => raw
        .substring(1, raw.length - 1)
        .replaceAll(r"\'", "'")
        .replaceAll(r'\"', '"');

    final matches = RegExp(r"'(?:[^'\\]|\\.)*'").allMatches(body).toList();
    String? key;
    final buf = StringBuffer();
    for (var i = 0; i < matches.length; i++) {
      final raw = matches[i].group(0)!;
      final after = body.substring(matches[i].end).trimLeft();
      if (after.startsWith(':')) {
        // 上一个键值对收尾（没有显式逗号分隔时也要收）。
        if (key != null) out[key] = buf.toString();
        key = unquote(raw);
        buf.clear();
      } else if (key != null) {
        buf.write(unquote(raw));
        if (after.startsWith(',')) {
          out[key] = buf.toString();
          key = null;
          buf.clear();
        }
      }
    }
    if (key != null) out[key] = buf.toString();
    return out;
  }

  /// 标记是否**作为代码**存在于 [src] 中（先剥注释，再逐字比对）。
  bool hasMarker(String src, String marker) =>
      stripComments(src).contains(marker);

  group('DEX-01 白名单可被定位与解析（否则后面全是恒真）', () {
    test('能在 tool 源码里定位到 _deviceOnly 的 map 字面量', () {
      expect(open, greaterThanOrEqualTo(0),
          reason: '找不到 _deviceOnly 声明 —— 锁自己失效了');
      expect(mapBody, isNotNull, reason: 'map 字面量括号不配对');
    });

    test('解析出的条目非空', () {
      final entries = parseMap(stripComments(mapBody!));
      expect(entries, isNotEmpty,
          reason: '白名单解析出 0 条 —— 要么是空表，要么是解析器坏了');
    });
  });

  group('DEX-02 双向绑定：白名单与证据表必须逐条对齐', () {
    test('键集合恰好相等（多一个/少一个都判红）', () {
      final entries = parseMap(stripComments(mapBody!));
      expect(entries.keys.toSet(), requiredMarkers.keys.toSet(),
          reason: '白名单与本锁的证据表不一致：'
              '只在白名单里=偷偷豁免；只在证据表里=幽灵条目');
    });

    test('每个被豁免的文件都真实存在（防"豁免一个已删除的文件"注水）', () {
      final entries = parseMap(stripComments(mapBody!));
      for (final f in entries.keys) {
        expect(File(f).existsSync(), isTrue, reason: '$f 不存在');
      }
    });

    test('每条豁免的理由长度达标（一句话糊弄过不了）', () {
      final entries = parseMap(stripComments(mapBody!));
      for (final e in entries.entries) {
        expect(e.value.replaceAll(RegExp(r'\s'), '').length,
            greaterThanOrEqualTo(40),
            reason: '${e.key} 的豁免理由过短：必须有可审查的说明');
      }
    });
  });

  group('DEX-03 结构证据：被豁免的文件里必须真有"宿主跑不了"的标记', () {
    for (final entry in requiredMarkers.entries) {
      test('${entry.key} 含标记 ${entry.value}', () {
        final src = File(entry.key).readAsStringSync();
        expect(hasMarker(src, entry.value), isTrue,
            reason: '标记 ${entry.value} 在该文件里已不存在 —— '
                '说明它不再是"宿主不可达"的代码，豁免必须撤销');
      });
    }
  });

  group('DEX-90 反面样本（证明上面的判据**能失败**）', () {
    test('90a 解析器：注释里的键不算数（剥注释后必须消失）', () {
      const body = '''
{
  // 'lib/only/in/comment.dart': 'nope',
  'lib/real.dart': 'real reason',
}
''';
      final entries = parseMap(stripComments(body));
      expect(entries.containsKey('lib/only/in/comment.dart'), isFalse,
          reason: '注释里的键被当成真条目 ⇒ 有人可以靠注释绕过本锁');
      expect(entries.containsKey('lib/real.dart'), isTrue);
    });

    test('90b 标记检查：不存在的标记必须判红', () {
      expect(hasMarker('const a = 1; // runApp(', 'runApp('), isFalse,
          reason: '标记只出现在注释里却判绿 ⇒ 结构证据形同虚设');
    });

    test('90c 标记检查：真实代码里的标记判绿（不是恒假）', () {
      expect(hasMarker('void main() { runApp(const A()); }', 'runApp('),
          isTrue);
    });

    test('90d 双向绑定：白名单多出一个未登记的文件时必须不等', () {
      const body = '''
{
  'lib/services/background_engine.dart': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'lib/main.dart': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'lib/sneaky.dart': 'cccccccccccccccccccccccccccccccccccccccc',
}
''';
      final entries = parseMap(stripComments(body));
      expect(entries.keys.toSet(), isNot(requiredMarkers.keys.toSet()),
          reason: '偷偷多塞一个文件却仍判定相等 ⇒ 双向绑定失效');
    });
  });
}
