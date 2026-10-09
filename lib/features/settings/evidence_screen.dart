import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/evidence_files.dart';
import '../../core/theme.dart';

/// 取证文件管理页（P2-11）：浏览 / 导出 / 手动清理。
///
/// 设计约束（`docs/07` §4/§5）：
/// - 取证文件是**用户资产**，永不自动删除；本页只做**显式**的手动清理；
/// - 导出 = 原样分享（`share_plus`），不改动源文件；
/// - 页面顶部给出**容量提示**，让用户能判断是否需要清理。
class EvidenceScreen extends StatefulWidget {
  const EvidenceScreen({super.key, this.store});

  /// 注入缝：生产为 null（自建基于应用文档目录的 [EvidenceStore]）；
  /// 测试注入替身以避开真实平台目录与文件 I/O（与 `SoundLibraryScreen`
  /// 的 `previewPlayer` 同一形状）。
  final EvidenceStore? store;

  @override
  State<EvidenceScreen> createState() => _EvidenceScreenState();
}

class _EvidenceScreenState extends State<EvidenceScreen> {
  late Future<List<EvidenceFile>> _future;
  EvidenceStore? _resolved;

  Future<EvidenceStore> _store() async {
    final cached = _resolved;
    if (cached != null) return cached;
    final injected = widget.store;
    if (injected != null) return _resolved = injected;
    final docs = await getApplicationDocumentsDirectory();
    return _resolved = EvidenceStore(directory: docs);
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<EvidenceFile>> _load() async => (await _store()).list();

  void _reload() {
    if (!mounted) return;
    setState(() {
      _future = _load();
    });
  }

  Future<void> _share(EvidenceFile f) async {
    try {
      await Share.shareXFiles([XFile(f.path)], subject: '声盾录音取证');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  Future<void> _delete(EvidenceFile f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${f.name}」？'),
        content: const Text('取证文件是用户资产，删除后不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await (await _store()).delete(f.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
      return;
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('录音取证文件')),
      body: FutureBuilder<List<EvidenceFile>>(
        future: _future,
        builder: (context, snap) {
          final items = snap.data ?? const <EvidenceFile>[];
          final total = items.fold<int>(0, (sum, e) => sum + e.sizeBytes);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
                child: Text(
                  '共 ${items.length} 个文件 · ${_fmtSize(total)}\n'
                  '取证文件为本机用户资产，永不自动删除；仅在下方手动清理。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: items.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(AppSpacing.xl),
                          child: Text(
                            '暂无录音取证文件。\n'
                            '当带「录音取证」动作的任务被触发时，录音会保存到这里。',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final f = items[i];
                          return ListTile(
                            leading: const Icon(Icons.mic),
                            title: Text(f.name),
                            subtitle: Text(
                                '${_fmtSize(f.sizeBytes)} · ${_fmtTime(f.modifiedAt)}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.share),
                                  tooltip: '导出',
                                  onPressed: () => _share(f),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: '删除',
                                  onPressed: () => _delete(f),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).round()} KB';
  }

  static String _fmtTime(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

  static String _two(int v) => v < 10 ? '0$v' : '$v';
}