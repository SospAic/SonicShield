import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「展示/说明类查表」的**覆盖锁**（与 BUG-058 同源：表漏登记 → 静默降级）。
///
/// 这类表有三个共同点：① 输入是 String 或 sealed 类型；② 漏登记**不编译报错**
/// （String switch 必须有兜底；sealed 上写 `_` 还会关掉穷尽性检查）；
/// ③ 后果都是**用户看不到正确信息**，而不是抛异常 —— 所以没人会发现。
///
/// 本轮实测抓到的：`_kindToType` 漏了 `composite` / `randomFrom`
/// → 组合动作的主动作是"随机指令集/嵌套组合"时，摘要显示成「通知 + 」（**空标签**）。
const _tasksTab = 'lib/features/remote/remote_tasks_tab.dart';
const _assist = 'lib/remote/assist.dart';
const _action = 'lib/domain/models/action.dart';
const _permHintSrc = 'lib/features/remote/assist_host_screen.dart';

/// 取 `marker` 之后到第一个 `\n…};` 的 switch 体。
///
/// ⚠️ 不能取"签名后第一个 `{`"：Dart 具名参数也用大括号（项目既有教训）。
String _bodyOf(String src, String marker) {
  final i = src.indexOf(marker);
  if (i < 0) throw StateError('找不到 $marker —— 是不是改名或挪走了？');
  final m = RegExp(r'\n\s*\};').allMatches(src, i).firstOrNull;
  if (m == null) throw StateError('$marker 的 switch 体没有闭合');
  return src.substring(i, m.start);
}

void main() {
  final tasks = File(_tasksTab).readAsStringSync();
  final assist = File(_assist).readAsStringSync();
  final action = File(_action).readAsStringSync();
  final hintSrc = File(_permHintSrc).readAsStringSync();

  test('LBL-01 `_kindToType` 必须覆盖全部动作 kind', () {
    // 权威集合 = ActionConfig.fromJson 认识的 kind（新增动作类型必改这里）。
    final fromJson = _bodyOf(action,
        "static ActionConfig fromJson(Map<String, dynamic> j) => switch (j['kind']) {");
    final kinds = RegExp(r"'(\w+)' => ")
        .allMatches(fromJson)
        .map((m) => m.group(1)!)
        .toSet();
    expect(kinds.length, greaterThanOrEqualTo(8),
        reason: 'ActionConfig 的 kind 集合变了，本锁要跟着看');

    final kindToType = _bodyOf(
        tasks, 'static String _kindToType(Object? kind) => switch (kind) {');
    for (final k in kinds) {
      expect(kindToType.contains("'$k' =>"), isTrue,
          reason: '`_kindToType` 没登记 kind `$k` —— 漏登记的后果是任务摘要'
              '显示成「通知 + 」（空标签），用户看不出这任务要干什么');
    }
  });

  test('LBL-02 组合/随机指令集必须有名字（本轮实测缺陷）', () {
    final kindToType = _bodyOf(
        tasks, 'static String _kindToType(Object? kind) => switch (kind) {');
    expect(kindToType.contains("'composite' =>"), isTrue);
    expect(kindToType.contains("'randomFrom' =>"), isTrue);
  });

  test('LBL-03 `_actionLabel` 必须覆盖 `_kindToType` 的全部产出', () {
    final kindToType = _bodyOf(
        tasks, 'static String _kindToType(Object? kind) => switch (kind) {');
    final outs = RegExp(r"=> '(\w+)'")
        .allMatches(kindToType)
        .map((m) => m.group(1)!)
        .toSet();
    final label = _bodyOf(
        tasks, 'static String _actionLabel(Object? raw) => switch (raw) {');
    for (final o in outs) {
      expect(label.contains("'$o' =>"), isTrue,
          reason: '`_kindToType` 会产出 `$o`，`_actionLabel` 却没有对应文案');
    }
  });

  test('LBL-04 空串也要给得出名字（`\'\'` 不是 null）', () {
    // 原写法 `'${raw ?? '未知动作'}'`：raw=null → "未知动作"，raw='' → **空白**。
    for (final (fn, fallback) in const [
      ('_actionLabel', '未知动作'),
      ('_triggerLabel', '未知触发'),
    ]) {
      final b =
          _bodyOf(tasks, 'static String $fn(Object? raw) => switch (raw) {');
      expect(b.contains('raw == null'), isTrue,
          reason: '`$fn` 的兜底必须显式判空串 —— 只判 `raw ?? …` 会让空串渲染成空白');
      expect(b.contains(fallback), isTrue);
    }
  });

  test('LBL-05 每个权限键都必须有 UI 说明文案', () {
    // 权威集合 = AssistPerms.withFlag 能设置的权限位。
    final withFlag = _bodyOf(assist,
        'AssistPerms withFlag(String key, bool value) => switch (key) {');
    final keys = RegExp(r"'(\w+)' => copyWith")
        .allMatches(withFlag)
        .map((m) => m.group(1)!)
        .toSet();
    expect(keys.isNotEmpty, isTrue);

    final hint = _bodyOf(
        hintSrc, 'static Widget? _permHint(String key) => switch (key) {');
    for (final k in keys) {
      expect(hint.contains("'$k' =>"), isTrue,
          reason: '权限 `$k` 没有说明文案 —— 用户会在**完全不知道要授权什么**'
              '的情况下被要求勾选（新增权限位时最容易漏）');
    }
  });
}
