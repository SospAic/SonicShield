import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

/// `test/support/source_text.dart` 的**自锁**（STX 系列）。
///
/// 这个文件存在的理由：公共 helper 本身也会被"写坏"，而它一旦写坏，
/// **所有**依赖它的源码契约锁会一起静默失效（比 16 份副本更糟 —— 副本至少
/// 是各自独立的）。所以它必须有和它服务的锁同等强度的自检：
///
/// 1. 正向：逐条覆盖 `//`、`/* */`、字符串字面量、转义、具名参数表；
/// 2. **反面样本**（STX-90a/b/c）：拿"退化版实现"当对照，证明本实现与
///    退化版在**具体输入上结论不同** —— 否则这些函数就是恒真装饰品
///    （本项目强制：恒真断言 = 没测）。
void main() {
  group('stripComments', () {
    test('STX-01 行注释被剥、同行代码保留', () {
      const src = 'final a = 1; // 这是注释\nfinal b = 2;\n';
      final out = stripComments(src);
      expect(out.contains('final a = 1;'), isTrue);
      expect(out.contains('final b = 2;'), isTrue);
      expect(out.contains('这是注释'), isFalse);
    });

    test('STX-02 块注释被剥（含跨行 / 含代码形状的文本）', () {
      const src = 'void f() {\n'
          '  /* 下面这句是说明，不是代码：\n'
          "     await stepGuarded('replan', replan);\n"
          '  */\n'
          "  await stepGuarded('x', y);\n"
          '}\n';
      final out = stripComments(src);
      expect(out.contains("await stepGuarded('x', y)"), isTrue);
      expect(out.contains("await stepGuarded('replan', replan)"), isFalse,
          reason: '块注释里的"代码形状文本"必须被剥掉 —— 否则存在性断言被喂绿');
    });

    test('STX-03 字符串里的 `//` 不是注释开始（退化版会从 // 起截断）', () {
      const src = "final url = 'https://example.com/a'; // 真注释\n";
      final out = stripComments(src);
      expect(out.contains('https://example.com/a'), isTrue,
          reason: 'URL 里的 // 被当成注释 ⇒ 该行后半段丢失（可能假绿/假红）');
      expect(out.contains('真注释'), isFalse);
    });

    test('STX-04 字符串里的 `/* */` 不被剥', () {
      const src = "final s = 'a/*b*/c'; // 真注释\n";
      final out = stripComments(src);
      expect(out.contains('a/*b*/c'), isTrue);
      expect(out.contains('真注释'), isFalse);
    });

    test('STX-05 转义引号不终止字符串', () {
      const src = r"final s = 'a\'b'; // c" '\n';
      final out = stripComments(src);
      expect(out.contains(r"a\'b"), isTrue);
      expect(out.contains(' // c'), isFalse);
    });

    test('STX-06 双引号字符串同样整段保留', () {
      const src = 'final s = "x//y"; // z\n';
      final out = stripComments(src);
      expect(out.contains('"x//y"'), isTrue);
      expect(out.contains('z'), isFalse);
    });

    test('STX-07 未闭合块注释不越界（截到文件末尾而非抛错）', () {
      const src = 'final a = 1;\n/* 未闭合\n';
      final out = stripComments(src);
      expect(out.contains('final a = 1;'), isTrue);
      expect(out.contains('未闭合'), isFalse);
    });

    test('STX-21 XML 注释被剥（清单里"为什么不加某权限"的决策注释不是声明）', () {
      // 真实形状：`packages/native_bridge/android/src/main/AndroidManifest.xml`
      // 的 NAT-14 注释逐字写着 `PACKAGE_USAGE_STATS`（说明它为何被移除）。
      // 不剥 `<!-- -->` ⇒ `contains()` 把说明文字当成"权限已声明" ⇒ 假红，
      // 而假红最坏的后果是逼下一个人删掉这段决策留痕（LG-13 的同一课）。
      const xml = '<manifest>\n'
          '  <!-- NAT-14：PACKAGE_USAGE_STATS 已裁决移除（无授权入口） -->\n'
          '  <uses-permission android:name="android.permission.CAMERA" />\n'
          '</manifest>';
      final out = stripComments(xml);
      expect(out.contains('PACKAGE_USAGE_STATS'), isFalse,
          reason: 'XML 注释里的权限名是说明文字，不是声明');
      expect(out.contains('android.permission.CAMERA'), isTrue,
          reason: '真声明必须保留（剥注释不能把代码也剥掉）');
      expect(out.contains('<manifest>'), isTrue, reason: '标签本身不是注释');
    });

    test('STX-21b 未闭合 XML 注释不越界（截到文件末尾而非抛错）', () {
      const xml = '<manifest>\n<!-- 未闭合\n';
      final out = stripComments(xml);
      expect(out.contains('<manifest>'), isTrue);
      expect(out.contains('未闭合'), isFalse);
    });
  });

  group('methodBody', () {
    const engine = 'class E {\n'
        '  Future<void> broadcast({bool running = true}) async {\n'
        '    if (running) {\n'
        "      send('x');\n"
        '    }\n'
        '  }\n'
        '}\n';

    test('STX-08 具名参数表被跳过（不抽到参数列表本身）', () {
      final body = methodBody(engine, 'Future<void> broadcast(');
      expect(body.startsWith('{'), isTrue);
      expect(body.endsWith('}'), isTrue);
      expect(body.contains('running = true'), isFalse,
          reason: '抽到参数表本身会静默失效：断言窗口里根本没有函数体');
      expect(body.contains("send('x')"), isTrue);
      expect(body.contains('class E'), isFalse,
          reason: '不许把整个类体当函数体（右边界错）');
    });

    test('STX-09 签名找不到 → 显式抛错（不许静默返回空串）', () {
      expect(
          () => methodBody(engine, 'Future<void> 不存在('), throwsStateError);
    });

    test('STX-10 表达式体 → 显式抛错（不许返回一个悄悄错掉的区间）', () {
      const src = 'int f() => 1;\nvoid g() {}\n';
      expect(() => methodBody(src, 'int f('), throwsStateError);
    });

    test('STX-11 函数体未闭合 → 显式抛错', () {
      expect(() => methodBody('void f() {\n  a();\n', 'void f('),
          throwsStateError);
    });

    // ── 四种调用约定（A/B1/B2/C/D）+ 多行片段。全部是本仓库实测在用的写法。──
    const engine2 = 'class E {\n'
        '  Future<void> _rec({required int seconds}) async {\n'
        '    log(seconds);\n'
        '  }\n'
        '  Future<void> dispose() async {\n'
        '    await stop();\n'
        '  }\n'
        '  Future<void> _dispatch(RcMessage msg, PairedEndpoint peer) {\n'
        '    ack();\n'
        '  }\n'
        '  Future<void> _connect() async {\n'
        '    mqtt();\n'
        '  }\n'
        '  Future<void> _frag(\n'
        '    int a, RcMessage request, {\n'
        '    Duration timeout = const Duration(seconds: 8),\n'
        '  }) async {\n'
        '    frag();\n'
        '  }\n'
        '}\n';

    test('STX-15 约定 B1：签名含具名参数表开括号 `({`', () {
      final b = methodBody(engine2, 'Future<void> _rec({');
      expect(b.contains('log(seconds)'), isTrue);
      expect(b.contains('required int seconds'), isFalse,
          reason: '抽到参数表 = 静默取错窗口（断言窗口里没有函数体）');
    });

    test('STX-16 约定 B2：签名含函数体开括号 `() async {`', () {
      final b = methodBody(engine2, 'Future<void> dispose() async {');
      expect(b.contains('await stop()'), isTrue);
      expect(b.contains('_rec'), isFalse, reason: '右边界错（抽到隔壁方法）');
    });

    test('STX-17 约定 C：完整签名（参数表已闭合）', () {
      final b = methodBody(
          engine2, 'Future<void> _dispatch(RcMessage msg, PairedEndpoint peer)');
      expect(b.contains('ack()'), isTrue);
      expect(b.contains('dispose'), isFalse);
    });

    test('STX-18 约定 D：完整签名 + `async` 后缀', () {
      final b = methodBody(engine2, 'Future<void> _connect() async');
      expect(b.contains('mqtt()'), isTrue);
      expect(b.contains('_frag'), isFalse);
    });

    test('STX-19 多行签名的**片段**：参数表的 `(` 不在签名里也不许下溢', () {
      final b = methodBody(engine2, 'RcMessage request, {');
      expect(b.contains('frag()'), isTrue);
      expect(b.contains('Duration timeout = const'), isFalse,
          reason: '抽到跨行参数表 = 静默取错窗口');
    });

    test('STX-20 反例：朴素 `indexOf(\'{\', start)` 在 B1 上取错窗口', () {
      // 退化实现：从**签名起点**起找第一个 `{` —— 会命中具名参数表的那个 `{`。
      String naiveFromStart(String src, String signature) {
        final start = src.indexOf(signature);
        if (start < 0) return '';
        final open = src.indexOf('{', start);
        if (open < 0) return '';
        var depth = 0;
        for (var i = open; i < src.length; i++) {
          final c = src[i];
          if (c == '{') {
            depth++;
          } else if (c == '}') {
            depth--;
            if (depth == 0) return src.substring(open, i + 1);
          }
        }
        return '';
      }

      final bad = naiveFromStart(engine2, 'Future<void> _rec({');
      final good = methodBody(engine2, 'Future<void> _rec({');
      expect(bad, contains('required int seconds'),
          reason: '前提：退化实现确实命中参数表（否则本反例无效）');
      expect(bad == good, isFalse,
          reason: '退化实现与真源必须给出**不同**结果，否则本锁测不到东西');
      expect(good, contains('log(seconds)'));
    });
  });

  group('balancedSlice', () {
    test('STX-12 嵌套括号配对到闭合', () {
      const src = 'call(a, [b, {c: 1}], d) tail';
      final i = src.indexOf('(');
      final s = balancedSlice(src, i);
      // 切片从**开括号**起（调用方已经知道被调者是谁）。
      expect(s, '(a, [b, {c: 1}], d)');
    });

    test('STX-13 未闭合 / 起点不是括号 → null（调用方必须加哨兵）', () {
      expect(balancedSlice('call(a, [b', 4), isNull);
      expect(balancedSlice('abc', 0), isNull);
      expect(balancedSlice('abc', 99), isNull);
    });

    test('STX-14 balancedSliceAfter 取签名后第一个括号切片', () {
      const src = 'x = ActionSetAction(candidates: [a, b]);';
      final s = balancedSliceAfter(src, 'ActionSetAction(');
      expect(s, '(candidates: [a, b])');
      expect(balancedSliceAfter(src, '不存在的签名('), isNull);
    });
  });

  group('反面样本：证明这些函数不是恒真装饰品', () {
    /// 退化版实现（第 36 轮之前在 6 个文件里真实存在的那种）：
    /// 只认 `//` 与 `/* */`，**不认字符串字面量**。
    String naiveStrip(String src) {
      final out = StringBuffer();
      var i = 0;
      while (i < src.length) {
        final c = src[i];
        if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
          while (i < src.length && src[i] != '\n') {
            i++;
          }
          continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
          i += 2;
          while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
            i++;
          }
          i += 2;
          continue;
        }
        out.write(c);
        i++;
      }
      return out.toString();
    }

    test('STX-90a 存在性断言：违规只写在注释里 —— 剥注释后必须不再命中', () {
      const src = 'void f() {\n'
          '  // 这里应该调用 playRemote(category) —— 说明文字\n'
          '}\n';
      // 不剥：注释就能满足断言（**这就是被关掉的那条假绿通道**）。
      expect(src.contains('playRemote(category)'), isTrue,
          reason: '若不剥注释，注释文本就能喂绿存在性断言');
      // 剥后：必须不命中。
      expect(stripComments(src).contains('playRemote(category)'), isFalse);
    });

    test('STX-90b 禁止性断言：说明注释里的 `_ =>` 不得造成假红', () {
      const src = 'RcStepKind? f(ActionConfig a) => switch (a) {\n'
          '  PlayAudioAction() => RcStepKind.play,\n'
          '  // ⚠️ 不许写 _ => 兜底：会关掉 sealed 的穷尽性检查\n'
          '  TtsAction() => RcStepKind.tts,\n'
          '};\n';
      expect(src.contains('_ =>'), isTrue,
          reason: '原文里确实有 `_ =>`（在注释里）—— 不剥就会假红');
      expect(stripComments(src).contains('_ =>'), isFalse,
          reason: '剥注释后必须不再命中，否则锁会逼人删掉说明注释');
    });

    test('STX-90c 与退化版对照：字符串里的 `//` 上结论不同（证明本实现有实效）', () {
      const src = "final url = 'https://example.com/a'; final b = 2;\n";
      expect(naiveStrip(src).contains('example.com'), isFalse,
          reason: '退化版把 URL 的 // 当注释 ⇒ 该行从 // 起整段丢失');
      expect(naiveStrip(src).contains('final b = 2;'), isFalse,
          reason: '退化版会丢掉同行后半段（真实存在过的缺陷面）');
      expect(stripComments(src).contains('final b = 2;'), isTrue,
          reason: '本实现必须保住这一行 —— 与退化版结论不同才说明它做了实事');
      expect(stripComments(src).contains('https://example.com/a'), isTrue);
    });
  });
}
