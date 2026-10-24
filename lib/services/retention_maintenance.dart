import '../data/repositories/log_repository.dart';
import '../data/repositories/occurrence_repository.dart';

/// 一次保留策略维护的结果（供审计文案使用）。
class RetentionOutcome {
  const RetentionOutcome({
    required this.logsRemoved,
    required this.occurrencesRemoved,
  });

  /// 被清理的执行日志条数（90 天前）。
  final int logsRemoved;

  /// 被清理的历史计划条数（7 天前的非 pending）。
  final int occurrencesRemoved;

  int get total => logsRemoved + occurrencesRemoved;
}

/// 保留策略维护任务（P2-10；docs/07 §4「数据生命周期」）。
///
/// ## 为什么需要它
///
/// `docs/07` 规定 `exec_logs` 保留 90 天、非 pending 的 `occurrences`
/// 保留 7 天，由维护任务周期清理。但两个 `purgeOlderThan` 此前**只有定义、
/// 没有生产调用入口** —— 长期运行的设备上表与统计只增不减。
///
/// ## 为什么抽成独立类
///
/// 与 [AssetLibraryImporter] 同一理由：引擎跑在 `flutter_background_service`
/// 的 isolate 里、依赖真实平台插件，宿主机**实例化不了**；把
/// 「按保留天数算截止时间 → 调两个 purge」抽出来，就能在内存库上断言
/// **真的删了该删的、留了不该留的**（尤其 `pending` 必须保留）。
///
/// ## 边界
///
/// 只清理**数据库里的过期记录**。录音取证文件属用户资产、**永不自动删除**
/// （`docs/07` §4），不在本任务职责内。
class RetentionMaintenance {
  RetentionMaintenance({
    required this.logs,
    required this.occurrences,
    DateTime Function()? now,
    this.logRetentionDays = 90,
    this.occurrenceRetentionDays = 7,
    this.batchLimit = 500,
    this.onError,
  }) : now = now ?? DateTime.now;

  final LogRepository logs;
  final OccurrenceRepository occurrences;

  /// 执行日志保留天数（`docs/07`：90 天；设置页可调整，故可注入）。
  final int logRetentionDays;

  /// 已终态计划保留天数（`docs/07`：7 天）。
  final int occurrenceRetentionDays;

  /// 单批删除行数（DAT-11）。
  ///
  /// 两个 `purgeOlderThan` 都改成了 `LIMIT` 循环：**一次大删除**会在
  /// `BEGIN IMMEDIATE` 里持写锁数秒，对端（UI 保存任务 / 远程 upsert /
  /// 引擎 tick）在 `busy_timeout=5000` 内拿不到锁就抛 `database is locked`。
  /// 500 行/批是"锁持有时间 ≪ 5s"与"往返次数可接受"之间的折中
  /// （5000 行 ≈ 10 批 ≈ 10 次平台往返）。
  final int batchLimit;

  final DateTime Function() now;

  /// 单步失败的上报口（R90-23）。默认 null = 只吞不报（宿主测试/无日志场景）。
  ///
  /// 旧实现两步 purge 裸串行：`exec_logs` 清理一抛，`occurrences` 清理就
  /// **永远不执行**（长期运行后历史计划只增不减）。现在两步互相隔离，
  /// 失败经本回调留痕（引擎侧注入写 `exec_logs` 的闭包）。
  final void Function(Object error)? onError;

  /// 执行一次维护。**幂等**：重复调用只会把已删的再判一次为 0。
  ///
  /// 两步**各自 try/catch**（R90-23）：任何一步失败都不得阻断另一步。
  Future<RetentionOutcome> run() async {
    final t = now();
    var logsRemoved = 0;
    var occurrencesRemoved = 0;
    try {
      logsRemoved = await logs.purgeOlderThan(
        t.subtract(Duration(days: logRetentionDays)),
        batchLimit: batchLimit,
      );
    } on Object catch (e) {
      onError?.call(e);
    }
    try {
      occurrencesRemoved = await occurrences.purgeOlderThan(
        t.subtract(Duration(days: occurrenceRetentionDays)),
        batchLimit: batchLimit,
      );
    } on Object catch (e) {
      onError?.call(e);
    }
    return RetentionOutcome(
      logsRemoved: logsRemoved,
      occurrencesRemoved: occurrencesRemoved,
    );
  }
}