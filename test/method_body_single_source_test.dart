import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

/// 「源码契约锁的抽取器只有一个真源」的机器锁（MBS 系列）。
///
/// ## 为什么要有这个文件（第 36 轮续三）
///
/// `test/` 下曾散落 **18 份** 本地 `methodBody` 副本。第 34、35 轮两次"加固"
/// 都只修了**被点名的那几处** —— 因为"同一件事写 N 遍"的代价不是冗余，
/// 而是**加固永远只覆盖被点名的那几处**。第 36 轮续二把它们收敛到
/// `test/support/source_text.dart`；本锁负责**不让副本长回来**。
///
/// 更具体的教训（第 36 轮续三实测）：上一会话用一个正则
/// `String \w+(String \w+, String \w+)` 去删副本，该正则**太松** ——
/// 它同时命中了 `functionBlock` / `_switchBody` / `_bodyOf` / `groupBody`
/// 这四个**语义不同**的抽取器，把定义删掉却**没改调用点**，
/// 留下 `Expected to find ';'` 与 `Undefined name`（门禁 36 条 analyze 问题）。
/// ⇒ 所以本锁的判据必须**按名字白名单**，不能按形状。
///
/// ## 判据为什么必须自证非恒真（MBS-02）
///
/// 只断言"没找到副本"是**恒真风险**：扫描目录写错、正则写错、目录为空，
/// MBS-01 都会照样绿。所以必须拿**合成的违规样本**证明检测器真的会判红
/// （本项目铁律：恒真断言 = 没测）。
///
/// ⚠️ MBS-02 的样本**全部用字符串插值拼出来**（`'String ${_mbNames.first}('`），
/// 不写成字面量：否则本文件自己的源码里就含有那个名字，
/// 会被 MBS-01 判成"自己违规"（假红）—— 本轮**实测发生过一次**。
void main() {
  test('MBS-01 test/ 下不得再定义本地 methodBody 家族副本'
      '（唯一真源 = support/source_text.dart）', () {
    final offenders = <String>[];
    var scanned = 0;
    for (final e in Directory('test').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.replaceAll('\\', '/').endsWith('support/source_text.dart')) {
        continue; // 唯一真源自己
      }
      scanned++;
      final hits = _localDefs(e.readAsStringSync());
      if (hits.isNotEmpty) offenders.add('${e.path} -> ${hits.join(", ")}');
    }
    expect(scanned, greaterThan(50),
        reason: '只扫到 $scanned 个文件 —— 扫描面太小，目录/路径写错了？'
            '（工作目录应是仓库根）');
    expect(offenders, isEmpty,
        reason: '以下文件又出现了本地 methodBody 副本 —— 请 `import '
            'support/source_text.dart` 用共享真源，不要复制实现：\n'
            '${offenders.join("\n")}');
  });

  test('MBS-02 检测器非恒真：合成违规样本必须被判红，且不得误报', () {
    // ① 明显违规：本地定义 ⇒ 必须命中。
    final offender = 'String ${_mbNames.first}(String src, String signature) {\n'
        '  return src;\n'
        '}\n';
    expect(_localDefs(offender), contains(_mbNames.first),
        reason: '检测器抓不到明显的本地定义 ⇒ MBS-01 是恒真装饰品');

    // ② 只写在**注释**里的定义不算副本（不剥注释 ⇒ 说明注释造成假红）。
    final commented = '// String ${_mbNames.first}'
        '(String src, String signature) {}\n'
        'void main() {}\n';
    expect(_localDefs(commented), isEmpty,
        reason: '注释里的定义不是副本 —— 必须先 stripComments');

    // ③ **调用点**不是定义（否则真源的使用者会被误判）。
    final caller = 'void main() {\n'
        "  final b = ${_mbNames.first}(src, 'Future<void> f()');\n"
        '}\n';
    expect(_localDefs(caller), isEmpty, reason: '调用点不得被误判为副本');

    // ④ **语义不同**的抽取器不在本锁范围内 —— 这正是上一会话脚本正则太松
    //    踩的坑（把 groupBody 当成 methodBody 副本删掉）。
    const other = 'String groupBody(String src, String prefix) {\n'
        '  return src;\n'
        '}\n';
    expect(_localDefs(other), isEmpty,
        reason: '不同语义的抽取器（如 groupBody）不在本锁范围内，不得误判');

    // ⑤ 反向哨兵：真源自己的定义**必须**被本检测器认得（否则判据形同虚设）。
    //
    // ⚠️ 这条 reason 里**不能**写出那个名字的字面量：reason 是**字符串字面量**，
    //    `stripComments` 会保留它 ⇒ 本文件会因这句"说明"被判成自己违规
    //    （第 36 轮续三实测：MBS-01 真的把自己抓了出来，`Actual:
    //    ['test\\method_body_single_source_test.dart -> methodBody']`）。
    //    用 `_mbNames.first` 插值即可绕开。
    final real = File('test/support/source_text.dart').readAsStringSync();
    expect(_localDefs(real), isNotEmpty,
        reason: '检测器连唯一真源里的 `${_mbNames.first}` 定义都认不出来 —— '
            '说明判据写错了，MBS-01 的绿毫无意义');
  });
}

/// 只允许出现在**唯一真源**里的名字。任何其它文件定义它们即视为"副本长回来了"。
const _mbNames = ['methodBody', '_methodBody', 'methodBodyOf'];

/// 检出 [src] 里所有"本地 methodBody 家族定义"。
///
/// 判据：`String <name>(` —— 只看**定义**（前面有返回类型），不看调用点。
/// 先 `stripComments`：否则一句写着那个名字的说明注释
/// 就能把本锁打成假红（第 35 轮 ASE-03/ASE-04 的同类缺陷）。
///
/// ⚠️ 只剥**注释**不够：**字符串字面量**会整段保留。所以本文件（以及任何
/// 未来改它的人）**不得在字符串里写出那个名字**，否则 MBS-01 会抓到自己。
/// 需要写出来时用 `_mbNames` 插值。
List<String> _localDefs(String src) {
  final code = stripComments(src);
  final hits = <String>[];
  for (final n in _mbNames) {
    final re = RegExp(r'\bString\s+' + n + r'\s*\(');
    if (re.hasMatch(code)) hits.add(n);
  }
  return hits;
}
