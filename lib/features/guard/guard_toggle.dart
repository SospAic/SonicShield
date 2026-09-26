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

  /// 麦克风权限未授予（`Permission.microphone.request()` 返回非 granted）。
  micDenied,

  /// 已下发但引擎未在超时内回投期望状态（引擎卡住 / 被杀）。
  engineNoResponse,

  /// 引擎**明确**报出了守卫启动失败（原因随 `EngineState.guardError` 回投）。
  ///
  /// 与 [engineNoResponse] 的区别：那个是"等不到回音"，这个是"对方说清了
  /// 为什么不行"（如麦克风被别的应用占用）。两者的用户指引完全不同，
  /// 不能合并成一句话 —— 合并就是新的静默失败。
  guardStartFailed,

  /// 链路里抛了未预期异常（原生桥不可用 / 前台服务被系统拒绝 / 权限弹窗被
  /// 打断等）。
  ///
  /// ⚠️ 这一条是 BUG-061 的**残留形状**：旧实现让 `startMicService()` 的异常
  /// 直接穿透 `onChanged`，于是开关弹回、**零提示** —— 用户看到的与"没点"一样。
  /// 现在任何异常都必须变成一个看得见的原因。
  unexpected,
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
      GuardToggleFailure.guardStartFailed => '守卫未能启动（详见下方原因）',
      GuardToggleFailure.unexpected => '操作失败（详见下方原因）',
    };

/// 开关结果：**分类 + 引擎自报的原因**。
///
/// 为什么不是裸枚举：枚举带不了 payload，而"引擎说麦克风被占用"这种
/// **具体原因**正是用户唯一能据以行动的信息。丢掉它就只能退回一句
/// 万金油式的"引擎无响应" —— 那就是把已经拿到的信息又静默掉了。
class GuardToggleOutcome {
  const GuardToggleOutcome(this.failure, {this.detail});

  final GuardToggleFailure failure;

  /// 直接可展示的具体原因；null 时退回 [guardFailureText]。
  final String? detail;

  bool get ok => failure == GuardToggleFailure.none;

  /// 给用户看的最终文案。
  String get text {
    final d = detail;
    if (d != null && d.isNotEmpty) return d;
    return guardFailureText(failure);
  }
}

/// 守卫开关的完整流程（**可注入依赖**，便于回归锁真实证伪）。
///
/// 返回值：[GuardToggleOutcome]；`failure == none` 表示成功。
///
/// 为什么抽成单独函数而不是写在 `onChanged` 里：
/// 三条失败路径都在异步链上，写在 State 里**无法在 host 单测中触发**
/// （依赖真机引擎）。抽出来后可以注入假依赖，逐条断言"能失败"。
///
/// ## 开 / 关两条路径的对称性（v1.10）
///
/// 旧实现的关闭分支只有 `stopMicService()` + `setGuard(false)` + 等回投，
/// **既没有引擎检查，顺序也反了**（先撤麦克风通行证、再让引擎停）。结果是
/// 两个方向的失效方式不对称：开不了会报错，关不掉却只报一句含糊的话。
///
/// 现在的约定：
/// - **两个方向都确认引擎侧**（`waitForGuardActive`）；
/// - 关闭方向先让引擎停，再撤麦克风通行证 —— 撤通行证是"停止"的最后一步，
///   顺序反了会出现"通行证没了、引擎还在收流"的中间态；
/// - 关闭时若引擎本来就没跑，则没有"引擎侧"可确认，直接成功
///   （否则用户会被一个已经关掉的守卫卡住，永远清不掉开关）。
Future<GuardToggleOutcome> toggleGuard({
  required bool wanted,
  required bool engineRunning,
  required Future<bool> Function() requestMic,
  required Future<void> Function() persist,
  required Future<void> Function() startMicService,
  required Future<void> Function() stopMicService,
  required Future<void> Function(bool enabled) setGuard,
  required Future<bool> Function(bool expected) waitForGuardActive,
  String? Function()? lastGuardError,
}) async {
  try {
    if (wanted) {
      // ① 引擎必须在跑：否则 setGuard 发向不存在的服务，静默 no-op。
      if (!engineRunning) {
        return const GuardToggleOutcome(GuardToggleFailure.engineNotRunning);
      }

      // ② 麦克风权限：由**主 isolate** 询问系统（引擎隔离问不出结果，
      //    见 `SoundGuardService.start` 的注记）。
      final granted = await requestMic();
      if (!granted) {
        return const GuardToggleOutcome(GuardToggleFailure.micDenied);
      }

      await persist();
      await startMicService();
      // ③ 把**权威授权结论**一并下发，引擎不必再自己问一遍。
      await setGuard(true);

      final ok = await waitForGuardActive(true);
      if (!ok) {
        // 引擎若明确说了原因，就原样转达；否则才是真的"没回音"。
        final e = lastGuardError?.call();
        if (e != null && e.isNotEmpty) {
          return GuardToggleOutcome(GuardToggleFailure.guardStartFailed,
              detail: e);
        }
        return const GuardToggleOutcome(GuardToggleFailure.engineNoResponse);
      }
      return const GuardToggleOutcome(GuardToggleFailure.none);
    }

    // ---- 关闭路径（与开启对称）----
    // 先让引擎停：引擎侧的 `guard.stop()` 会取消采流订阅。
    await setGuard(false);
    // 再撤麦克风前台服务通行证。**停止方向一律走安全侧**：
    // 无论引擎是否确认，都不能留下一个还在采音的守卫。
    await stopMicService();
    // 引擎本来没跑 ⇒ 没有"引擎侧"可确认，直接成功。
    if (!engineRunning) {
      return const GuardToggleOutcome(GuardToggleFailure.none);
    }
    if (!await waitForGuardActive(false)) {
      return const GuardToggleOutcome(GuardToggleFailure.engineNoResponse);
    }
    return const GuardToggleOutcome(GuardToggleFailure.none);
  } on Object catch (e) {
    // 任何未预期异常都必须变成一个用户看得见的原因 —— 绝不允许它穿透
    // `onChanged` 造成"开关弹回 + 零提示"（BUG-061 残留形状）。
    return GuardToggleOutcome(GuardToggleFailure.unexpected, detail: '操作失败：$e');
  }
}
