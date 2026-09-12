/// 确定性随机（DPRNG）工具。
///
/// 核心思想：随机计划必须可复现。进程被杀、设备重启、计划重算，
/// 只要「任务 ID + 计划日」不变，生成的随机时间序列就完全一致，
/// 从而避免"重启后计划漂移/提前泄漏"等问题。
/// 真正的随机性来自 taskId（UUID v4），对使用者而言仍是不可预测的。
library;

import 'dart:math';

/// 计划种子：hash(taskId, yyyy-MM-dd)。
int planSeed(String taskId, DateTime localDate) {
  final dayKey = '${localDate.year.toString().padLeft(4, '0')}-'
      '${localDate.month.toString().padLeft(2, '0')}-'
      '${localDate.day.toString().padLeft(2, '0')}';
  var h = 0x811c9dc5; // FNV-1a 32bit
  for (final cu in ('$taskId|$dayKey').codeUnits) {
    h ^= cu;
    h = (h * 0x01000193) & 0x7fffffff;
  }
  return h;
}

/// [min, max) 均匀分布（毫秒级精度）。
int nextIntBetween(Random rng, int min, int max) {
  assert(min <= max);
  if (max == min) return min;
  return min + rng.nextInt(max - min);
}

/// [min, max] 闭区间双精度。
double nextDoubleBetween(Random rng, double min, double max) =>
    min + rng.nextDouble() * (max - min);

/// 按权重随机挑选（权重和无需为 1）。
T pickWeighted<T>(List<T> items, List<double> weights, Random rng) {
  assert(items.length == weights.length && items.isNotEmpty);
  final total = weights.fold<double>(0, (a, b) => a + b);
  var r = rng.nextDouble() * total;
  for (var i = 0; i < items.length; i++) {
    r -= weights[i];
    if (r <= 0) return items[i];
  }
  return items.last;
}

/// 打乱副本（Fisher–Yates）。
List<T> shuffled<T>(List<T> list, Random rng) {
  final copy = [...list]..shuffle(rng);
  return copy;
}

/// 生成分层抖动序列：在 [start,end] 内取 n 个时刻，彼此间隔 >= minGap。
/// 采用"拒绝采样 + 保底收缩"策略，窗口过小则自动均分。
List<Duration> sampleInWindow({
  required int n,
  required Duration window,
  required Duration minGap,
  required Random rng,
}) {
  if (n <= 0) return const [];
  final windowMs = window.inMilliseconds;
  final gapMs = minGap.inMilliseconds;
  // 窗口装不下 n 个带最小间隔的点：退化为等分 + 微抖动。
  if ((n - 1) * gapMs >= windowMs) {
    final step = windowMs ~/ (n + 1);
    return [
      for (var i = 1; i <= n; i++)
        Duration(
            milliseconds:
                i * step + nextIntBetween(rng, -(step ~/ 4), (step ~/ 4) + 1)),
    ];
  }
  final out = <Duration>[];
  var attempts = 0;
  while (out.length < n && attempts < n * 200) {
    attempts++;
    final cand = rng.nextInt(windowMs + 1);
    final ok = out.every((d) => (d.inMilliseconds - cand).abs() >= gapMs);
    if (ok) out.add(Duration(milliseconds: cand));
  }
  if (out.length < n) {
    // 拒绝采样失败兜底：等分。
    final step = windowMs ~/ (n + 1);
    out
      ..clear()
      ..addAll([for (var i = 1; i <= n; i++) Duration(milliseconds: i * step)]);
  }
  out.sort();
  return out;
}
