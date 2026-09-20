import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';
import 'package:sonic_shield/remote/rc_script.dart';

/// BUG-058 回归锁：「随机指令集」子动作回填**不得猜**。
///
/// 修之前 `stepKindOfAction` 是 `_ => RcStepKind.play`：复合 / 声景 /
/// 嵌套动作组都会被**静默当成"播放音频"**回填 —— 用户打开编辑器再保存
/// （哪怕什么都没改）就把原配置悄悄改掉了，而且**没有任何提示**。
/// 更糟的是 `ActionConfig` 是 **sealed**，写 `_` 会关掉编译器的穷尽性检查
/// → 以后新增动作类型也照样静默掉进兜底。
const _src = 'lib/features/tasks/task_editor_screen.dart';

/// 取 `stepKindOfAction` 的 switch 体（从 `=> switch` 到第一个 `\n};`）。
///
/// 为什么不取"签名后第一个 `{`"：`=>` 后面紧跟的是 `switch (a) {`，
/// 而 Dart 具名参数也用大括号 —— 那个取法会取到别的东西（项目既有教训）。
String _stepKindBody() {
  final src = File(_src).readAsStringSync();
  const marker = 'RcStepKind? stepKindOfAction(ActionConfig a) => switch (a) {';
  final i = src.indexOf(marker);
  if (i < 0) {
    throw StateError('找不到 stepKindOfAction —— 是不是改名或挪走了？');
  }
  // 闭合是 `};`（顶层缩进 0 或 4 空格都可能）→ 用正则而不是写死缩进。
  final m = RegExp(r'\n\s*\};')
      .allMatches(src)
      .where((mm) => mm.start > i)
      .firstOrNull;
  if (m == null) throw StateError('stepKindOfAction 的 switch 体没有闭合');
  return src.substring(i, m.start);
}

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
    final src = File('lib/domain/models/action.dart').readAsStringSync();
    final declared = RegExp(r'class (\w+Action) extends ActionConfig')
        .allMatches(src)
        .map((m) => m.group(1)!)
        .toSet();
    final body = _stepKindBody();
    for (final t in declared) {
      expect(body.contains('$t()'), isTrue,
          reason: 'action.dart 里声明了 $t，stepKindOfAction 却没登记');
    }
  });

  test('ASE-05 保存路径必须把不可编辑的子动作原样带回来', () {
    final src = File(_src).readAsStringSync();
    // 只锁"有这一步"不够 —— 必须落在 randomFrom 的 candidates 里。
    final i = src.indexOf('ActionSetAction(candidates: [');
    expect(i >= 0, isTrue, reason: '找不到 randomFrom 的保存分支');
    final j = src.indexOf('\n        ]);', i);
    final branch = src.substring(i, j < 0 ? src.length : j);
    expect(branch.contains('..._setPreserved'), isTrue,
        reason: 'randomFrom 保存时必须 append `_setPreserved` —— 否则打开编辑器'
            '再保存就会静默丢掉复合/声景/嵌套子动作');
  });
}
