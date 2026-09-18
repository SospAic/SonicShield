import 'package:flutter/material.dart';

import '../../core/widgets/section_scaffold.dart';
import '../logs/log_screen.dart';
import '../stats/stats_screen.dart';

/// 「日志」分组页（新 IA）：审计明细 + 统计洞察。
///
/// 原「日志」与「统计」两个入口分散在底部 TAB 与设置页；两者本质是同一份
/// `exec_logs` 的**明细视图**与**聚合视图**，合并为一个分组更自然，
/// 也让「统计」从设置页二级入口提升为一等公民。
class LogsSection extends StatelessWidget {
  const LogsSection({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  Widget build(BuildContext context) {
    return SectionScaffold(
      title: '日志',
      initialIndex: initialIndex,
      tabs: [
        SectionTabSpec(
          label: '审计',
          icon: Icons.receipt_long,
          builder: (_) => const LogScreen(embedded: true),
        ),
        SectionTabSpec(
          label: '统计',
          icon: Icons.insights,
          builder: (_) => const StatsScreen(embedded: true),
        ),
      ],
    );
  }
}
