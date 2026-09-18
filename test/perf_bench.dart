/// 性能测量的公共工具。
///
/// 文件名**不以 `_test.dart` 结尾**，因此不会被 `flutter test` 的用例发现机制
/// 当成测试文件执行 —— 它只是被两个性能套件 import 的辅助库。
///
/// ## 为什么需要它（本项目踩过的坑）
///
/// 本项目的性能用例跑在 `flutter test` 里，而 `flutter test` 用的是 **JIT**
/// （不是 release AOT）。这带来两个让"墙钟阈值"失真的因素：
///
/// 1. **JIT 编译成本被算进测量值**：首次执行一段代码要现编译，实测同一个
///    用例两次运行能差近 2 倍（100 任务物化：723ms vs 1294ms）。
///    不预热时，阈值衡量的是"JIT 冷启动"而不是算法成本。
/// 2. **单次采样被噪声支配**：GC、调度、页错误都会让单次测量偏大。
///    例如 `dailyCounts` 首次调用 333ms、稳态则远低于 50ms ——
///    单次测量测的是"第一次调用的 SQL 准备成本"，与用例意图
///    （稳态查询延迟）根本不是一回事。
///
/// 因此统一用 [benchMs] / [benchMsAsync]：
/// **先预热若干次，再取 N 次测量的最小值**。
///
/// 取最小值而不是平均值：墙钟噪声只会让测量值**变大**，所以最小值是对
/// "真实计算成本"最稳健的估计（基准测试的常规做法）。取平均值会把噪声
/// 算进结论，取最大值则完全测的是运气。
///
/// **注意**：这些工具只是让测量对准意图，**不负责放宽阈值**。
/// 阈值该取多少，取决于该套件承担的是"绝对验收"还是"回归护栏"：
/// - **绝对验收**（NFR 原值，如 100 任务 ≤500ms）只能在 **AOT** 下做，
///   见 `integration_test/perf_nfr_test.dart`（`flutter drive --profile`）；
/// - **JIT 回归护栏**（`test/performance_test.dart` 等）按"实测 JIT 基线 × 3"
///   定阈值 —— JIT 与 AOT 可差 30 倍以上，套用绝对预算会得到不可满足的断言
///   （BUG-036）。
library;

import 'dart:async';

/// 同步基准：预热 [warmUpRuns] 次，再测 [runs] 次，返回**最小值**（毫秒）。
int benchMs(
  void Function() body, {
  int runs = 5,
  int warmUpRuns = 3,
}) {
  for (var i = 0; i < warmUpRuns; i++) {
    body();
  }
  var best = 1 << 62;
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    if (sw.elapsedMilliseconds < best) best = sw.elapsedMilliseconds;
  }
  return best;
}

/// 异步基准：语义同 [benchMs]，用于含 `await` 的用例（DB 等）。
Future<int> benchMsAsync(
  Future<void> Function() body, {
  int runs = 5,
  int warmUpRuns = 3,
}) async {
  for (var i = 0; i < warmUpRuns; i++) {
    await body();
  }
  var best = 1 << 62;
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    await body();
    sw.stop();
    if (sw.elapsedMilliseconds < best) best = sw.elapsedMilliseconds;
  }
  return best;
}
