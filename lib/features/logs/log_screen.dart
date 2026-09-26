import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/providers.dart';

enum _LogFilter { all, success, failed, skipped }

/// 执行日志：审计视图 + 状态筛选 + CSV 导出。
///
/// [embedded] = true 时作为「日志」分组页的子 TAB 使用：保留导出操作，
/// 仅去掉标题与返回键。
class LogScreen extends ConsumerStatefulWidget {
  const LogScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends ConsumerState<LogScreen> {
  _LogFilter _filter = _LogFilter.all;

  List<Map<String, Object?>> _applyFilter(List<Map<String, Object?>> rows) {
    if (_filter == _LogFilter.all) return rows;
    final want = _filter.name;
    return rows.where((r) => r['status'] == want).toList();
  }

  Future<void> _exportCsv() async {
    try {
      final repo = await ref.read(logRepoProvider.future);
      final rows = await repo.recent(limit: 5000);
      if (rows.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('暂无日志可导出')));
        }
        return;
      }
      final df = DateFormat('yyyy-MM-dd HH:mm:ss');
      final buf = StringBuffer(
          'time,source,action,status,task_id,occurrence_id,volume,duration_ms,message\n');
      for (final r in rows) {
        final ts = DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int);
        String esc(Object? v) =>
            '"${(v ?? '').toString().replaceAll('"', '""')}"';
        buf.writeln([
          df.format(ts),
          esc(r['source']),
          esc(r['action']),
          esc(r['status']),
          esc(r['task_id']),
          esc(r['occurrence_id']),
          r['volume'] ?? '',
          r['duration_ms'] ?? '',
          esc(r['message']),
        ].join(','));
      }
      final dir = await getTemporaryDirectory();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final path = '${dir.path}/sonic_shield_logs_$stamp.csv';
      await File(path).writeAsString(buf.toString(), flush: true);
      if (mounted) {
        await Share.shareXFiles([XFile(path)], subject: '声盾执行日志（审计导出）');
      }
    } catch (e) {
      // 失败可见：写盘/分享失败（磁盘满、临时目录不可用等）不能静默吞掉，
      // 否则用户以为导出成功、审计链实际断了。
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(logListProvider);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: widget.embedded ? 52 : null,
        title: widget.embedded ? null : const Text('执行日志'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '导出 CSV',
            onPressed: _exportCsv,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SegmentedButton<_LogFilter>(
              segments: const [
                ButtonSegment(value: _LogFilter.all, label: Text('全部')),
                ButtonSegment(value: _LogFilter.success, label: Text('成功')),
                ButtonSegment(value: _LogFilter.failed, label: Text('失败')),
                ButtonSegment(value: _LogFilter.skipped, label: Text('跳过')),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ),
          Expanded(
            child: logs.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('加载失败：$e')),
              data: (rows) {
                final filtered = _applyFilter(rows);
                if (filtered.isEmpty) {
                  // 区分「真的没有日志」与「有日志但当前筛选无结果」：
                  // 两者共用一句"暂无日志"会让用户误以为执行记录丢了。
                  if (rows.isNotEmpty) {
                    return Center(
                        child: Text(
                            '当前筛选（${_filter.name}）无匹配日志，可切换到「全部」'));
                  }
                  return const Center(
                      child: Text('暂无日志。开启守护并添加任务后，这里会记录每一次执行。'));
                }
                final df = DateFormat('MM-dd HH:mm:ss');
                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(logListProvider),
                  child: ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = filtered[i];
                      final ts = DateTime.fromMillisecondsSinceEpoch(
                          r['created_at'] as int);
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
          ),
        ],
      ),
    );
  }
}
