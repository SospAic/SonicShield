import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';

/// 执行日志：全部动作的审计视图（时间/来源/动作/状态/音量/时长）。
class LogScreen extends ConsumerWidget {
  const LogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(logListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('执行日志')),
      body: logs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(child: Text('暂无日志。开启守护并添加任务后，这里会记录每一次执行。'));
          }
          final df = DateFormat('MM-dd HH:mm:ss');
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(logListProvider),
            child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = rows[i];
                final ts =
                    DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int);
                final status = r['status'] as String? ?? '';
                final color = switch (status) {
                  'success' => Colors.green,
                  'failed' => Colors.red,
                  _ => Colors.orange,
                };
                return ListTile(
                  dense: true,
                  leading: Icon(
                    switch (r['action']) {
                      'play' => Icons.volume_up,
                      'tts' => Icons.record_voice_over,
                      'record' => Icons.fiber_manual_record,
                      'notify' => Icons.notifications,
                      'vibrate' => Icons.vibration,
                      _ => Icons.bolt,
                    },
                    color: color,
                  ),
                  title: Text(
                    '${df.format(ts)} · ${r['source']} · ${r['action']} · $status',
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    [
                      if (r['volume'] != null)
                        '音量${((r['volume'] as num).toDouble() * 100).round()}%',
                      if (r['duration_ms'] != null)
                        '${((r['duration_ms'] as num).toInt() / 1000).toStringAsFixed(1)}s',
                      if (r['message'] != null &&
                          (r['message'] as String).isNotEmpty)
                        r['message'] as String,
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
