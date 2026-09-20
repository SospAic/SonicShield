/// 指令组执行进度（`RcEvt.scriptState` = `rc.script`）的**纯逻辑**。
///
/// 端点侧 `_runScript` 每进入一个步骤就发
/// `{scriptId, state: running, stepIndex}`（`stepIndex` 为 **0-based**），
/// 整个指令组结束时发 `{scriptId, state: done|stopped}`（终止态**不带** stepIndex）。
///
/// ## 为什么单独抽成纯函数
///
/// 主叫侧此前**没有任何消费者**：发送后只弹一句「已发送（通知栏可终止）」，
/// 之后就再也看不到执行到第几步。这与 BUG-048 / BUG-056 同族 ——
/// 值算得出来、也发得出去，但**没有人在用**（静默降级）。
/// 抽成纯函数后可在宿主机上直接断言，不必靠读 UI 代码来确认链路接通。
library;

/// 指令组在端点侧的运行状态。
///
/// ⚠️ 新增成员时 [describeScriptProgress] 会**编译报错**（穷尽 switch，
/// 不写 `default:`）—— 这是刻意的：漏处理一个新状态会静默显示错误进度。
enum ScriptState { running, done, stopped, unknown }

class ScriptProgress {
  const ScriptProgress({
    required this.scriptId,
    required this.state,
    this.stepIndex,
  });

  final String scriptId;
  final ScriptState state;

  /// **0-based** 步骤下标，仅 [ScriptState.running] 会携带。
  final int? stepIndex;

  /// 终止态（done / stopped）：之后不会再有同 `scriptId` 的进度。
  bool get isTerminal =>
      state == ScriptState.done || state == ScriptState.stopped;
}

/// 解析 `rc.script` 载荷。
///
/// **未知 `state` → [ScriptState.unknown]，绝不猜**（BUG-050 判据）。
/// 若把未知值当"结束"处理，端点将来新增一个状态就会让进度卡**假装完成**；
/// 若当"运行中"处理，则会**永远转圈**。两种猜法都比"什么都不做"更坏。
ScriptProgress parseScriptProgress(Map<String, dynamic> payload) {
  final state = switch (payload['state']) {
    'running' => ScriptState.running,
    'done' => ScriptState.done,
    'stopped' => ScriptState.stopped,
    _ => ScriptState.unknown,
  };
  return ScriptProgress(
    scriptId: (payload['scriptId'] as String?) ?? '',
    state: state,
    stepIndex: (payload['stepIndex'] as num?)?.toInt(),
  );
}

/// 该进度是否应当反映到界面上。
///
/// [ScriptState.unknown] **必须被忽略** —— 见 [parseScriptProgress] 的说明。
/// 单独抽成函数是为了让"什么都不做"本身**可断言**。
bool shouldApplyProgress(ScriptProgress p) => p.state != ScriptState.unknown;

/// 人类可读文案。[totalSteps] 未知（模板不在本机）时只显示"第 N 步"。
String describeScriptProgress(ScriptProgress p, {int? totalSteps}) {
  switch (p.state) {
    case ScriptState.running:
      final n = (p.stepIndex ?? 0) + 1;
      return totalSteps == null ? '执行中 · 第 $n 步' : '执行中 · 第 $n/$totalSteps 步';
    case ScriptState.done:
      return '已完成';
    case ScriptState.stopped:
      return '已终止';
    case ScriptState.unknown:
      return '状态未知'; // 正常不会显示：已被 shouldApplyProgress 拦下
  }
}
