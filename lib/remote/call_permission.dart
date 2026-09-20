/// 通话相关开关的**权限前置判定**与失败文案。
///
/// 起因：BUG-062 —— 「自动接通」开关在麦克风/相机权限被拒时**照样打开**，
/// 用户看到的是"已开启"，实际来电根本接不起来（且没有任何提示）。
/// 这与 BUG-061（守卫开关静默失败）是同一形状：
/// **失败必须让用户知道，不能静默假装成功。**
enum AutoAnswerBlock {
  none,

  /// 麦克风未授予：通话接起来也没有声音，等于假成功。
  micDenied,

  /// 相机未授予：视频来电无法出画面。
  cameraDenied,
}

/// 失败文案。
///
/// ⚠️ 用 **switch 表达式**（必须穷尽）：将来新增一个 `AutoAnswerBlock`
/// 而忘了补文案会**编译报错**；switch 语句配 `default` 则会静默给出兜底文案。
String autoAnswerBlockText(AutoAnswerBlock b) => switch (b) {
      AutoAnswerBlock.none => '',
      AutoAnswerBlock.micDenied => '需要麦克风权限才能自动接通（否则接起来也没有声音）',
      AutoAnswerBlock.cameraDenied => '需要相机权限才能自动接通视频来电',
    };

/// 判定是否可以打开「自动接通」。
///
/// 麦克风优先判定：没有麦克风的话视频再好也没意义，先报最根本的那个。
AutoAnswerBlock autoAnswerBlockFor({
  required bool micGranted,
  required bool cameraGranted,
}) {
  if (!micGranted) return AutoAnswerBlock.micDenied;
  if (!cameraGranted) return AutoAnswerBlock.cameraDenied;
  return AutoAnswerBlock.none;
}
