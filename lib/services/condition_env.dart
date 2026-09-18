import '../../domain/models/condition.dart';

/// 一轮内的环境快照缓存：**首次需要时才读**，之后复用。
///
/// ## 为什么需要"每轮复用"
///
/// 一次条件评估原本要读 4 次平台状态（电量 / 充电 / 通话 / 网络），
/// 每次都是一次**平台通道往返**（设备上 ≈1.5–2ms，见 BUG-035 / BUG-042 的实测）。
/// 调度引擎的一轮 `executeDue()` 会遍历**所有**到期计划，于是 N 个到期任务
/// 就是 **4N 次往返** —— 单任务看只有 ≈4ms（可忽略），量大时却随 N 线性增长。
///
/// 同一轮内所有任务面对的是**同一个物理环境**，所以读一次即可：
/// 一轮固定 4 次往返，**与 N 解耦**。
///
/// ## 快照的时效性（诚实的取舍）
///
/// 快照在一轮内**首次需要时**读取，之后不再刷新。若该轮中正在播放
/// （`runAction` 可能持续数秒），轮末任务看到的通话/网络状态可能已过期数秒。
/// 这是有意取舍：`skipInCall` 是**尽力而为**的护栏（即便逐任务读取，
/// 通话也可能恰好在读完之后才开始），而"一轮评估一次"是行业惯例
/// （Tasker / MacroDroid 的条件段同样按轮评估）。
///
/// 因此 `now` **不**进快照 —— 它是本地时钟（无平台通道开销），
/// 保持实时取值让时段窗口的判定更准，且不增加任何成本。
class RoundConditionEnv {
  RoundConditionEnv({required Future<ConditionEnv> Function() read})
      : _read = read;

  final Future<ConditionEnv> Function() _read;

  /// 缓存的是 **Future** 而不是结果值。
  ///
  /// 差别在并发在途时体现：若只缓存结果值，`_cached` 要到 `await` **之后**
  /// 才被赋值，于是同一轮里两个并发取值会**各读一次**（"每轮一次"被击穿）。
  /// 缓存 Future 则让所有并发调用者共享同一次读取。
  Future<ConditionEnv>? _inflight;

  /// 实际执行平台读取的次数。
  ///
  /// 这是"每轮只读一次"这一性质的**可断言出口** —— 没有它，
  /// 这个优化只能靠读代码相信，无法写回归锁。
  int readCount = 0;

  /// 取得本轮的环境快照（首次调用触发读取，其后返回同一实例）。
  Future<ConditionEnv> get value {
    final existing = _inflight;
    if (existing != null) return existing;
    readCount++;
    return _inflight = _read();
  }
}
