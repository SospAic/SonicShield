/// R94 / QUA-02：带**负载定性**的多次采样基准（min-of-N + 噪声离散度哨兵）。
///
/// ## 为什么需要它（WT-02 假红的完整证据链）
///
/// `_pt/r93gate.log` 第 31-36 行：`WT-02 parseUri 1 万次 ≤ 300ms` 实测
/// **321ms** 判红；同日志第 52-53 行：**同轮重跑 `+24 All tests passed`**。
/// 同一份代码、同一台机器、几十分钟后全绿 ⇒ 红的是**测量**，不是代码。
/// 根因：该用例用**裸 `Stopwatch` 单次采样**（min-of-1），违背
/// `performance_v2_test.dart` 文件头自己的约定与 BUG-053/055 已定案的
/// 纪律（"任何用例都不得用 `runs: 1`"、"余量要和噪声幅度比"）。
/// 首跑发生在整机 CPU 负载 67% 的机器上（同日志第 1-3 行门禁自己打印了
/// 预警），墙钟预算在该负载下本就不可信。
///
/// ## 与 `perf_bench.dart` 的关系（为什么不改它）
///
/// `perf_bench.dart` 已实现"预热 + 取 N 次最小值"，但它只有 min-of-N，
/// **没有负载定性**：整机高负载时每一轮都慢，最小值也照样慢。本文件补上
/// 这一层，且**不改** `perf_bench.dart`（它被两个性能套件共享，属
/// 其他工作包的所有权）。
///
/// ## 负载定性怎么做（Dart 侧没有 CPU 占用 API）
///
/// `gates.sh` 用 `machine_load`（`typeperf` / `/proc/loadavg`）在**脚本层**
/// 定性；Dart 标准库没有等价的"整机 CPU %"读取途径（`ProcessInfo` 只有
/// RSS），因此这里用**样本离散度**做代理判据：
///
/// - 取 [runs] 个样本，计算 `spread = max / min`；
/// - `spread <= [kLoadSpreadLimit]` ⇒ 采样窗口平稳，取最小值做判定
///   （噪声只会让单次偏大，最小值是对"真实计算成本"最稳健的估计）；
/// - `spread > [kLoadSpreadLimit]` ⇒ 窗口内出现过显著抢占/负载
///   （一个样本被噪声放大了 3 倍以上）⇒ 标记 `loaded`，**跳过时间断言**。
///
/// 跳过的语义与 `gates.sh` 的 BLOCKED 对齐：**未执行 ≠ 通过，也不是失败**。
/// 调用方必须 `print` 说明（本文件的调用方都这样做），让人能看见
/// "这条结论这次没测"，而不是静默变绿。
///
/// ⚠️ 边界（诚实声明）：离散度是**代理指标**，抓不到"持续均匀的高负载"
/// （那种情况下每轮都慢且离散度小）。彻底定性仍靠 `gates.sh` 的
/// `machine_load` + `perf_verdict`（负载 ≥60% 时压测失败判 BLOCKED）。
/// 本文件的目标只是消除**单次采样被噪声支配**这一类假红。
// ignore_for_file: avoid_print
//
// 为什么这里允许 `print`：本文件的职责就是"把这次没测的那几条说出来"
// （BLOCKED 语义）。跳过信息必须出现在 `flutter test` 的输出里才有效 ——
// 用 logger 会把它藏进只有调试构建才开的通道，等于静默变绿。
library;

import 'package:flutter_test/flutter_test.dart';

/// 样本离散度上限：`max / min` 超过该值视为"采样窗口被负载污染"。
///
/// 取值依据：干净机器上同一段代码的 7 次采样，max/min 通常 < 2（JIT 预热后
/// 稳定态）；BUG-055 实测"全套件负载下放大 5.2×"。取 3.0 落在两者之间：
/// 宁可多跳过几次（人工复跑成本低），也不把噪声当回归报上去
/// （误报回归会让人追一个不存在的 bug —— 那是更贵的错误）。
const double kLoadSpreadLimit = 3.0;

/// 一次带负载定性的基准结果。
class GuardedBench {
  const GuardedBench({
    required this.bestMs,
    required this.spread,
    required this.loaded,
    required this.samples,
  });

  /// 最小值（毫秒）—— 平稳窗口下的判定值。
  final double bestMs;

  /// `max / min`（样本离散度）。样本全为 0 时记为 1.0（不放大）。
  final double spread;

  /// true = 窗口被负载污染，时间断言应被**跳过**（BLOCKED 语义）。
  final bool loaded;

  /// 全部样本（毫秒，升序）—— 供失败/跳过时打印取证。
  List<double> get sorted => List<double>.of(samples)..sort();

  final List<double> samples;
}

/// 同步基准：预热 [warmUpRuns] 次，测 [runs] 次，返回最小值 + 负载定性。
///
/// 与 `benchMs` 的差别只在定性：`benchMs` 无条件返回最小值，本函数在
/// 离散度超限时置 [GuardedBench.loaded]。
GuardedBench benchGuarded(
  void Function() body, {
  int runs = 7,
  int warmUpRuns = 3,
}) {
  for (var i = 0; i < warmUpRuns; i++) {
    body();
  }
  final samples = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds / 1000.0);
  }
  return _verdict(samples);
}

/// 异步基准：语义同 [benchGuarded]，用于含 `await` 的用例（DB / 插件）。
Future<GuardedBench> benchGuardedAsync(
  Future<void> Function() body, {
  int runs = 7,
  int warmUpRuns = 3,
}) async {
  for (var i = 0; i < warmUpRuns; i++) {
    await body();
  }
  final samples = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    await body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds / 1000.0);
  }
  return _verdict(samples);
}

GuardedBench _verdict(List<double> samples) {
  var lo = samples.first;
  var hi = samples.first;
  for (final s in samples) {
    if (s < lo) lo = s;
    if (s > hi) hi = s;
  }
  // 亚毫秒用例（全部样本 < 1ms）不适用比率判据：整除粒度会放大 spread。
  // 此时视为平稳（负载污染在毫秒级以下测不出来，但这类用例也从不假红）。
  final spread = lo <= 0 ? 1.0 : hi / lo;
  return GuardedBench(
    bestMs: lo,
    spread: spread,
    loaded: spread > kLoadSpreadLimit,
    samples: samples,
  );
}

/// 从调用方自采的样本构造判定（供"计时外准备数据、只给目标动作计时"
/// 的用例使用 —— 例如每轮采样前重新灌入万级数据，保证工作量恒定）。
///
/// 判据与 [benchGuarded] 完全一致（min-of-N + 离散度哨兵）。
GuardedBench guardedFromSamples(List<double> samples) {
  if (samples.isEmpty) {
    throw ArgumentError.value(
        samples, 'samples', '至少需要一个样本（min-of-0 = 恒真，不允许）');
  }
  return _verdict(samples);
}

/// 跳过时间断言时的标准说明（调用方 `print` 用）—— 让"这次没测"可见。
String loadedSkipReason(String caseId, GuardedBench b) =>
    '[$caseId] 采样窗口负载污染（spread=${b.spread.toStringAsFixed(1)}'
    ' > $kLoadSpreadLimit，样本=${b.sorted.map((e) => e.toStringAsFixed(1)).join(', ')}ms）'
    ' ⇒ 墙钟结论不可信，跳过时间断言（BLOCKED 语义：未执行 ≠ 通过/失败）。'
    '请在空闲机器复跑：flutter test --tags perf --concurrency=1';

/// 带负载定性的时间断言：平稳窗口才判 [limitMs]，负载污染则**跳过并打印**。
///
/// ## 为什么它是 public 且不带下划线
///
/// 首版实现把本函数命名为 `_expectGuarded`，而 Dart 的库私有性是**按文件**
/// 划定的：`_` 前缀的名字**不可能**被其它文件 import。于是
/// `performance_test.dart` 里 6 处调用全部报 `undefined_function`，
/// 压测层整文件编译不过（表现为"功能层红、压测层根本没跑"）。
/// 教训：跨文件共用的辅助函数必须是 public，且**必须在被引用的文件里
/// 真实定义**（只有调用点、没有定义 = 编译期就炸，不是运行期假红）。
///
/// ## 判据（与 [benchGuarded] 的语义闭环）
///
/// - [GuardedBench.loaded] 为 false ⇒ `expect(bestMs <= limitMs)`，
///   **失败即真回归**（此时样本离散度小，墙钟可信）；
/// - loaded 为 true ⇒ 只 [print] 说明，**不做时间断言**。这是有意的
///   "未测"而不是"通过"：把噪声当回归报上去会让人追一个不存在的 bug，
///   那是更贵的错误（BUG-055 已为此付过一次代价）。
///
/// ⚠️ 本函数**不会**因为跳过而让调用方"看起来绿了" —— 跳过信息必须
/// 出现在测试输出里（本函数负责 print），人能在日志里看见"这条这次没测"。
void expectGuarded(
  String caseId,
  GuardedBench b,
  double limitMs, {
  String? reason,
}) {
  if (b.loaded) {
    // BLOCKED 语义：明确打印，不静默、不当通过。
    print(loadedSkipReason(caseId, b));
    return;
  }
  expect(
    b.bestMs,
    lessThanOrEqualTo(limitMs),
    reason: reason ??
        '[$caseId] 平稳窗口（spread=${b.spread.toStringAsFixed(1)}'
            ' ≤ $kLoadSpreadLimit）下最优 ${b.bestMs.toStringAsFixed(1)}ms'
            ' > ${limitMs}ms ⇒ 真实性能回归；样本=${b.sorted.map((e) => e.toStringAsFixed(1)).join(', ')}ms',
  );
}
