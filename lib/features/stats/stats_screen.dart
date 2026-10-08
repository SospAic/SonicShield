import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/repositories/log_repository.dart';
import '../../core/theme.dart';

/// 统计看板（v2.0）：7 天执行趋势（柱状图）+ 动作分布 + 状态占比。
/// 数据全部来自本地 exec_logs 聚合（SQL），无任何外传。
///
/// [embedded] = true 时作为「日志」分组页的子 TAB 使用，不再自带 AppBar。
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  Future<StatsSnapshot>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = _snapshot();
  }

  Future<StatsSnapshot> _snapshot() async {
    final repo = await ref.read(logRepoProvider.future);
    final daily = await repo.dailyCounts(days: 7);
    final actions = await repo.actionBreakdown();
    final status = await repo.statusBreakdown();
    return StatsSnapshot(daily: daily, actions: actions, status: status);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('统计看板')),
      body: FutureBuilder<StatsSnapshot>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('加载失败：${snap.error}'));
          }
          final s = snap.data!;
          if (s.daily.isEmpty) {
            return const Center(child: Text('暂无数据。开启守护并添加任务后，看板将呈现执行趋势。'));
          }
          return RefreshIndicator(
            onRefresh: () async => setState(_reload),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                Text('近 7 天执行趋势',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _DailyBarChart(daily: s.daily),
                const SizedBox(height: 20),
                Text('动作分布', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final a in s.actions.take(8))
                  _BreakdownRow(
                    label: a.action,
                    value: a.count,
                    max: s.actions.first.count,
                  ),
                const SizedBox(height: 20),
                Text('状态占比', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final e in s.status.entries)
                      Chip(
                        avatar: Icon(
                          e.key == 'success'
                              ? Icons.check_circle
                              : e.key == 'failed'
                                  ? Icons.error
                                  : Icons.remove_circle_outline,
                        ),
                        label: Text('${e.key} ${e.value}'),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class StatsSnapshot {
  const StatsSnapshot({
    required this.daily,
    required this.actions,
    required this.status,
  });

  final List<({String day, int total, int failed})> daily;
  final List<({String action, int count})> actions;
  final Map<String, int> status;
}

/// 7 天柱状图（自绘，无第三方图表依赖）。
class _DailyBarChart extends StatelessWidget {
  const _DailyBarChart({required this.daily});

  final List<({String day, int total, int failed})> daily;

  @override
  Widget build(BuildContext context) {
    final max = daily.fold<int>(1, (m, d) => d.total > m ? d.total : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final d in daily)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text('${d.total}',
                            style: Theme.of(context).textTheme.labelSmall),
                        const SizedBox(height: 4),
                        FractionallySizedBox(
                          widthFactor: 0.6,
                          child: Container(
                            height: 90 * (d.total / max),
                            decoration: BoxDecoration(
                              color: d.failed > 0
                                  ? Theme.of(context)
                                      .colorScheme
                                      .error
                                      .withValues(alpha: 0.75)
                                  : Theme.of(context).colorScheme.primary,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(4)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(d.day.substring(5),
                            style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow(
      {required this.label, required this.value, required this.max});

  final String label;
  final int value;
  final int max;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
              width: 110,
              child: Text(label, style: AppText.bodySmall)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: max == 0 ? 0 : value / max,
                minHeight: 8,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
              width: 40,
              child: Text('$value',
                  textAlign: TextAlign.right,
                  style: AppText.bodySmall)),
        ],
      ),
    );
  }
}
