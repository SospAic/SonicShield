import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';
import 'package:sonic_shield/remote/rc_script.dart';

import 'support/source_text.dart';

/// BUG-058 回归锁：「随机指令集」子动作回填**不得猜**。
///
/// 修之前 `stepKindOfAction` 是 `_ => RcStepKind.play`：复合 / 声景 /
/// 嵌套动作组都会被**静默当成"播放音频"**回填 —— 用户打开编辑器再保存
/// （哪怕什么都没改）就把原配置悄悄改掉了，而且**没有任何提示**。
/// 更糟的是 `ActionConfig` 是 **sealed**，写 `_` 会关掉编译器的穷尽性检查
/// → 以后新增动作类型也照样静默掉进兜底。
///
/// ⚠️ 本文件的 ASE-03/ASE-04 是**源码契约锁**，此前直接在**未剥注释**的
/// 文本上做断言（第 35 轮审计 `_pt/audit/F1-testquality.md §1.1` 点名的开口）：
/// 在 switch 体里写一句注释 `// 例如 PlayAudioAction()` 就能喂绿存在性断言；
/// 写一句 `// 不要写 _ =>` 反而会假红。第 36 轮改用公共
/// `test/support/source_text.dart` 剥注释后收敛（A11 系统性项）。
const _src = 'lib/features/tasks/task_editor_screen.dart';

/// 取 `stepKindOfAction` 的 switch 体（从 `=> switch` 到第一个 `\n};`）。
///
/// 为什么不取"签名后第一个 `{`"：`=>` 后面紧跟的是 `switch (a) {`，
/// 而 Dart 具名参数也用大括号 —— 那个取法会取到别的东西（项目既有教训）。
///
/// **纯函数**（入参是源码文本）以便反面样本直接喂合成源码。
String stepKindBodyFrom(String src) {
  // 先剥注释：否则注释里的 `XxxAction()` / `_ =>` 会分别造成假绿 / 假红。
  final code = stripComments(src);
  const marker = 'RcStepKind? stepKindOfAction(ActionConfig a) => switch (a) {';
  final i = code.indexOf(marker);
  if (i < 0) {
    throw StateError('找不到 stepKindOfAction —— 是不是改名或挪走了？');
  }
  // 闭合是 `};`（顶层缩进 0 或 4 空格都可能）→ 用正则而不是写死缩进。
  final m = RegExp(r'\n\s*\};')
      .allMatches(code)
      .where((mm) => mm.start > i)
      .firstOrNull;
  if (m == null) throw StateError('stepKindOfAction 的 switch 体没有闭合');
  return code.substring(i, m.start);
}

String _stepKindBody() => stepKindBodyFrom(File(_src).readAsStringSync());

/// 从 `action.dart` 源码里取出「权威子类集」（**剥注释后**）。
///
/// 剥注释的理由：注释里写一句 `// class FooAction extends ActionConfig`
/// 会污染这个集合 → 逼人去登记一个不存在的类（假红方向）。
Set<String> declaredActionsFrom(String src) => RegExp(
      r'class (\w+Action) extends ActionConfig',
    )
        .allMatches(stripComments(src))
        .map((m) => m.group(1)!)
        .toSet();

void main() {
  test('ASE-01 可表示的类型映射正确', () {
    expect(stepKindOfAction(const PlayAudioAction()), RcStepKind.play);
    expect(stepKindOfAction(const TtsAction(text: 'a')), RcStepKind.tts);
    expect(stepKindOfAction(const NotifyAction(title: '声盾', body: '测试')),
        RcStepKind.notify);
    expect(stepKindOfAction(const VibrateAction()), RcStepKind.vibrate);
    expect(stepKindOfAction(const RecordEvidenceAction(seconds: 3)),
        RcStepKind.record);
  });

  test('ASE-02 不可表示的类型返回 null（不猜成 play）', () {
    // 这三种在"随机指令集"编辑器里没有对应控件。
    // 猜成 play 的后果：回填成"播放音频"，保存即**静默改掉原配置**。
    expect(stepKindOfAction(const CompositeAction(primary: PlayAudioAction())),
        isNull);
    expect(
        stepKindOfAction(SoundscapeAction(tracks: [
          const SoundscapeTrack(assetId: 'a1'),
        ])),
        isNull);
    expect(
        stepKindOfAction(ActionSetAction(candidates: [
          const ActionSetCandidate(weight: 1, action: VibrateAction()),
          const ActionSetCandidate(weight: 1, action: TtsAction(text: 'b')),
        ])),
        isNull);
  });

  test('ASE-03 switch 必须显式穷尽、不得有 `_` 兜底', () {
    final body = _stepKindBody();
    // `_ =>` 会关掉 sealed 的穷尽性检查：新增子类时不报错，静默掉进兜底。
    expect(body.contains('_ =>'), isFalse,
        reason: 'stepKindOfAction 不允许 `_ =>` 兜底 —— 它会关掉 sealed '
            '的穷尽性检查，新增 ActionConfig 子类会静默被当成别的类型');

    // 每个 sealed 子类都必须**显式登记**（漏一个就编译报错，这才是目的）。
    for (final t in const [
      'PlayAudioAction',
      'TtsAction',
      'NotifyAction',
      'VibrateAction',
      'RecordEvidenceAction',
      'CompositeAction',
      'SoundscapeAction',
      'ActionSetAction',
      'RandomVibrateAction',
      'ContinuousVibrateAction',
    ]) {
      expect(body.contains('$t()'), isTrue,
          reason: 'stepKindOfAction 必须显式登记 $t —— 漏登记就该编译报错，'
              '而不是悄悄走兜底');
    }
  });

  test('ASE-04 ActionConfig 新增子类时本锁必须跟着改', () {
    // 防"登记表腐烂"：如果以后有人新增 ActionConfig 子类却忘了在
    // stepKindOfAction 里登记，ASE-03 会红（因为穷尽 switch 编译不过），
    // 这里则保证"子类清单"本身与源码同步 —— 否则 ASE-03 会恒绿。
    final declared =
        declaredActionsFrom(File('lib/domain/models/action.dart')
            .readAsStringSync());
    final body = _stepKindBody();
    expect(declared, isNotEmpty, reason: '锁本身失效：没解析出任何子类');
    for (final t in declared) {
      expect(body.contains('$t()'), isTrue,
          reason: 'action.dart 里声明了 $t，stepKindOfAction 却没登记');
    }
  });

  test('ASE-05 保存路径必须把不可编辑的子动作原样带回来', () {
    // 剥注释：否则注释里写一句 `..._setPreserved` 就能把这条锁喂绿。
    final src = stripComments(File(_src).readAsStringSync());
    // 只锁"有这一步"不够 —— 必须落在 randomFrom 的 candidates 里。
    final i = src.indexOf('ActionSetAction(candidates: [');
    expect(i, greaterThanOrEqualTo(0),
        reason: '找不到 randomFrom 的保存分支');
    // 括号配对取整个 `ActionSetAction(...)` 调用表达式（W5 P1）：
    // 旧写法用 `\n        ]);` 当右边界，依赖 8 空格缩进，失配时
    // `j < 0` 会**静默回落**成「从 i 扫到文件末尾」—— 那样文件里
    // 任何位置的 `..._setPreserved` 都能满足断言 ⇒ 恒绿。配对法
    // 缩进无关，且失配时返回 null，被下面的哨兵抓住、显式红。
    final open = src.indexOf('(', i);
    final branch = balancedSlice(src, open);
    expect(branch, isNotNull,
        reason: '括号配对失败 —— 保存分支的结构变了，本锁需要跟着改；'
            '不许静默退化成"扫到文件末尾"（那会让断言恒绿）');
    expect(branch!.contains('..._setPreserved'), isTrue,
        reason: 'randomFrom 保存时必须 append `_setPreserved` —— 否则打开编辑器'
            '再保存就会静默丢掉复合/声景/嵌套子动作');
  });

  group('反面样本：证明 ASE-03/ASE-04 不是恒真装饰品', () {
    test('ASE-90a 登记只写在注释里 → 不算登记（剥注释前会假绿）', () {
      const fake = 'RcStepKind? stepKindOfAction(ActionConfig a) => switch (a) {\n'
          '  // 例如 PlayAudioAction()\n'
          '  _ => null,\n'
          '};\n';
      // 不剥：注释就能满足存在性断言（**这就是第 35 轮点名的假绿通道**）。
      expect(fake.contains('PlayAudioAction()'), isTrue,
          reason: '若不剥注释，注释文本就能喂绿 ASE-03');
      // 剥后：必须不命中。
      final body = stepKindBodyFrom(fake);
      expect(body.contains('PlayAudioAction()'), isFalse);
    });

    test('ASE-90b 说明注释里的 `_ =>` 不得造成假红（剥注释前会假红）', () {
      const fake =
          'RcStepKind? stepKindOfAction(ActionConfig a) => switch (a) {\n'
              '  PlayAudioAction() => RcStepKind.play,\n'
              '  // 不许写 _ => 兜底\n'
              '  TtsAction() => RcStepKind.tts,\n'
              '};\n';
      expect(fake.contains('_ =>'), isTrue,
          reason: '不剥注释时 ASE-03 会因这句说明注释判红');
      expect(stepKindBodyFrom(fake).contains('_ =>'), isFalse);
    });

    test('ASE-90c 注释里的 class 声明不算子类（剥注释前会逼人登记假类）', () {
      const fake = '// class FakeAction extends ActionConfig\n'
          'class RealAction extends ActionConfig {}\n';
      expect(declaredActionsFrom(fake), {'RealAction'},
          reason: '注释里的声明若被算进去，ASE-04 会要求登记一个不存在的类');
      expect(declaredActionsFrom(fake).contains('FakeAction'), isFalse);
    });

    test('ASE-90d 用真实 BUG-058 形态对照：「不剥」会放行存在性断言', () {
      // 这是 BUG-058 修之前的形状：登记全被搬进注释 + `_ =>` 兜底。
      // 它能编译（sealed 上有 `_` 就是穷尽的），所以**编译器抓不到** ——
      // 只能靠本文件的源码锁。若源码锁不剥注释，这条就会假绿。
      const bugShape =
          'RcStepKind? stepKindOfAction(ActionConfig a) => switch (a) {\n'
              '  // 例如 PlayAudioAction() TtsAction() NotifyAction()\n'
              '  // VibrateAction() RecordEvidenceAction() CompositeAction()\n'
              '  _ => RcStepKind.play,\n'
              '};\n';
      // ① 不剥注释时：存在性断言被注释满足（**假绿**）。
      expect(bugShape.contains('PlayAudioAction()'), isTrue);
      expect(bugShape.contains('TtsAction()'), isTrue);
      expect(bugShape.contains('VibrateAction()'), isTrue);
      // ② 剥注释后：一个都不满足，且 `_ =>` 被抓 —— 锁判红。
      final body = stepKindBodyFrom(bugShape);
      expect(body.contains('PlayAudioAction()'), isFalse);
      expect(body.contains('TtsAction()'), isFalse);
      expect(body.contains('VibrateAction()'), isFalse);
      expect(body.contains('_ =>'), isTrue, reason: '兜底必须被抓到');
    });
  });
}
