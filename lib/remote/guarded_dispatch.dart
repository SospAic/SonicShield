/// 命令处理失败的兜底：把**静默超时**变成**显式失败**（BUG-051）。
///
/// ## 为什么需要它
///
/// 端点处理一条入站命令的链路是：
///
/// ```
/// client.updates.listen → _handleRaw → 解密 → _dispatch → 业务分支（查库/播放/…）
/// ```
///
/// 修复前，这条链上**任何一环抛异常都不会被捕获** —— 异常逃逸进流回调，
/// 后果是**不回执、不写审计**，控制器只能看到"20 秒超时"。
/// 真实原因（数据库锁、字段缺失、枚举不匹配……）被完全隐藏，
/// 排查成本极高：你只知道"没反应"，不知道"为什么没反应"。
///
/// 这正是 `tool/rc_probe.dart` 在真实公网实测中暴露的形状：
/// **`ping` 通、`status.get` 超时** —— 因为 `ping` 不碰数据库，
/// 而 `status.get` 要查 `occurrences` 表（见 docs/17 §24）。
///
/// ## 设计取舍
///
/// 抽成「纯逻辑 + 依赖注入」的形式，因此整条决策链**可在宿主机断言**：
///
/// | 参数 | 作用 |
/// |---|---|
/// | `run` | 真正的业务处理 |
/// | `audit` | 失败时**必须**被调用 —— "失败要如实记录"是本项目的硬约定 |
/// | 返回值 | 携带可回执的原因，由调用方决定是否 `ack(false, reason)` |
///
/// **审计本身失败也要被看见**：若 `audit` 抛异常（例如数据库正是故障源），
/// 不能再往上抛（那又会退回静默），而是通过 [GuardedOutcome.auditOk]
/// 如实标记 —— 否则"没写审计"与"审计失败"无法区分。
library;

/// 一次命令处理的受控结果。
final class GuardedOutcome {
  const GuardedOutcome._(this.ok, this.reason, this.error, this.auditOk);

  /// 处理成功。
  static const GuardedOutcome success = GuardedOutcome._(true, '', null, true);

  /// 处理失败。[reason] 给控制端看，[error] 是原始异常。
  factory GuardedOutcome.failed(
    String reason,
    Object error, {
    bool auditOk = true,
  }) =>
      GuardedOutcome._(false, reason, error, auditOk);

  /// 是否处理成功。
  final bool ok;

  /// 给控制端的可读原因（已脱敏截断）；成功时为空串。
  final String reason;

  /// 原始异常；成功时为 null。
  final Object? error;

  /// 失败审计是否成功落盘。**为 false 说明"连审计都失败了"**，
  /// 这是比处理失败更严重的信号（通常是数据库本身不可用）。
  final bool auditOk;

  @override
  String toString() => ok
      ? 'GuardedOutcome.success'
      : 'GuardedOutcome.failed($reason, auditOk=$auditOk)';
}

/// 把异常压成**给控制端看的**一行可读原因。
///
/// 三条硬约束：
/// 1. **压成一行**（换行会破坏日志与回执的可读性）；
/// 2. **截断**（栈与本地路径对使用者没有意义，且对端是不可信信道）；
/// 3. **空消息兜底**为运行时类型名（`Exception()` 的 `toString()` 可能为空）。
String describeFailure(Object error, {int maxLen = 160}) {
  var s = error.toString().replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
  if (s.isEmpty) s = error.runtimeType.toString();
  return s.length <= maxLen ? s : '${s.substring(0, maxLen)}…';
}

/// 把一次命令处理包成**永不抛**的形式。
///
/// 契约（三者都必须成立，否则静默缺陷会复发）：
/// 1. `run` 抛**任何**异常都不会外泄 —— 外泄会打断 MQTT 的 updates 监听；
/// 2. 失败时**一定尝试**调用 [audit]（它自己抛异常也不外泄）；
/// 3. 返回可回执的 [GuardedOutcome]，调用方据此 `ack(false, reason)`。
Future<GuardedOutcome> guardDispatch(
  Future<void> Function() run, {
  required Future<void> Function(String message) audit,
  int maxReasonLen = 160,
}) async {
  try {
    await run();
    return GuardedOutcome.success;
  } on Object catch (e) {
    final reason = describeFailure(e, maxLen: maxReasonLen);
    var auditOk = true;
    try {
      await audit(reason);
    } on Object {
      // 审计本身失败：如实标记，但**绝不再抛**（否则又回到静默）。
      auditOk = false;
    }
    return GuardedOutcome.failed(reason, e, auditOk: auditOk);
  }
}
