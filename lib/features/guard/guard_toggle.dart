import 'dart:async';

/// 守卫开关的失败分类与文案。
///
/// 起因：BUG-061 —— 守卫开关**失败时完全静默**：开关弹回、页面没有任何提示。
/// 实测（真机探针 v2）：点了开关后 `value` 保持 false、`mgr.last == null`
/// （引擎 isolate 从未回投 state），而页面文案里**没有任何解释**。
///
/// 判据（与 BUG-048/059/060 同源）：**要失败，但不要静默失败** ——
/// 失败必须让用户知道原因。守卫有三条互不相同的失败路径，
/// 却都表现为"开关弹回"，用户无从判断该去开引擎还是去开权限。
enum GuardToggleFailure {
  none,

  /// 后台引擎未运行 —— `setGuard()` 会发向不存在的服务，是彻底的 no-op。
  engineNotRunning,

  /// 麦克风权限未授予（`record` 插件 `hasPermission()` 会返回 false）。
  micDenied,

  /// 已下发但引擎未在超时内回投期望状态（引擎卡住 / 被杀 / 权限被系统拦截）。
  engineNoResponse,
}

/// 失败文案。
///
/// ⚠️ 用** switch 表达式**而不是 switch 语句 + `default`：
/// switch 表达式**必须穷尽**枚举值，将来新增一个 `GuardToggleFailure`
/// 而忘了补文案会**编译报错**（switch 语句配 default 则会静默给出兜底文案，
/// 用户看到一句说不清的话 —— 这正是 BUG-058 教训的同一形状）。
String guardFailureText(GuardToggleFailure f) => switch (f) {
      GuardToggleFailure.none => '',
      GuardToggleFailure.engineNotRunning => '守卫需要后台引擎：请先在「守护」页开启守护，再来打开守卫',
      GuardToggleFailure.micDenied => '需要麦克风权限：请在系统设置中允许后重试',
      GuardToggleFailure.engineNoResponse => '引擎无响应：请确认后台引擎正在运行（若刚开启请稍候几秒）',
    };

/// 守卫开关的完整流程（**可注入依赖**，便于回归锁真实证伪）。
///
/// 返回值：失败原因；`none` 表示成功。
///
/// 为什么抽成单独函数而不是写在 `onChanged` 里：
/// 三条失败路径都在异步链上，写在 State 里**无法在 host 单测中触发**
/// （依赖真机引擎）。抽出来后可以注入假依赖，逐条断言"能失败"。
Future<GuardToggleFailure> toggleGuard({
  required bool wanted,
  required bool engineRunning,
  required Future<bool> Function() requestMic,
  required Future<void> Function() persist,
  required Future<void> Function() startMicService,
  required Future<void> Function() stopMicService,
  required Future<void> Function(bool enabled) setGuard,
  required Future<bool> Function(bool expected) waitForGuardActive,
}) async {
  if (wanted) {
    // ① 引擎必须在跑：否则 setGuard 发向不存在的服务，静默 no-op。
    if (!engineRunning) return GuardToggleFailure.engineNotRunning;

    // ② 麦克风权限：record 插件 hasPermission() 为 false 时 start() 直接失败。
    final granted = await requestMic();
    if (!granted) return GuardToggleFailure.micDenied;

    await persist();
    await startMicService();
  } else {
    await stopMicService();
  }

  await setGuard(wanted);

  // ③ 等引擎回投状态确认真的生效；等不到就明确说"引擎无响应"。
  final ok = await waitForGuardActive(wanted);
  if (!ok) return GuardToggleFailure.engineNoResponse;

  return GuardToggleFailure.none;
}
