import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/providers.dart';
import '../../data/repositories/task_repository.dart';
import '../../domain/models/action.dart';
import '../../services/playback_service.dart';
import '../../services/preset_import.dart';
import '../../core/theme.dart';

/// 音源库：SAF 导入（免存储权限）+ 一键导入内置预置音效库
/// （60 条程序化合成，12 分类，见 tool/gen_sfx.dart）+ 单条试听。
///
/// [embedded] = true 时作为「自动化」分组页的子 TAB 使用：保留「导入预置库」
/// 操作（否则该能力在新 IA 下不可达），仅去掉标题与返回键。
class SoundLibraryScreen extends ConsumerStatefulWidget {
  const SoundLibraryScreen({
    super.key,
    this.embedded = false,
    this.previewPlayer,
    this.confirmDelete = true,
  });

  final bool embedded;

  /// 删除前是否弹确认对话框（QR3）。生产默认 `true`；
  /// 测试注入 `false` 以绕过对话框（对话框本身由 SLB-22 单独锁定）——
  /// 确认对话框与「真实文件 I/O 的 runAsync 分段驱动」在同一测试里无法共存
  /// （runAsync 重入被禁），注入缝是唯一让两者都成立的干净做法。
  final bool confirmDelete;

  /// 试听播放器的**注入缝**（与 [RemoteTasksTab.channel] 同一形状）。
  ///
  /// 生产路径传 `null` → 页面自建 [PlaybackService]，**行为一字未变**。
  ///
  /// 为什么必须有这个缝：宿主（`flutter test`）上音频插件不可用 ——
  /// `PlaybackService.play()` 要经 `AudioSession.instance` 与 `just_audio`
  /// 打平台通道，实测**直接挂死**（不是抛异常，是 Future 永不完成）。
  /// 没有缝，「试听按钮的停止/切换」这段逻辑就只能靠读代码，测不了 ——
  /// 而它恰恰是最容易写错的一处（`_previewingId == id` 时要点第二下停）。
  @visibleForTesting
  final PlaybackService? previewPlayer;

  @override
  ConsumerState<SoundLibraryScreen> createState() => _SoundLibraryScreenState();
}

class _SoundLibraryScreenState extends ConsumerState<SoundLibraryScreen> {
  bool _importingPresets = false;
  String? _previewingId;
  late final PlaybackService _previewPlayer =
      widget.previewPlayer ?? PlaybackService();

  /// 音源列表的**缓存 Future**（P2-24）。
  ///
  /// ## 为什么不能在 `build` 里现取
  /// 旧实现 `FutureBuilder(future: _listAssets())` 把查询建在 `build` 内：
  /// 试听（`setState(_previewingId=…)`）等**与列表无关**的状态变化也会重建
  /// build → 重新查一遍 DB 并解码 tags，音源多时每次试听都全量重查。
  /// 改为在 `initState` 建一次、只在**导入/删除/刷新**后显式换新 future，
  /// 其余 `setState` 复用同一个已完成 future（`FutureBuilder` 不再重复请求）。
  late Future<List<AudioAsset>> _assetsFuture;

  @override
  void initState() {
    super.initState();
    _assetsFuture = _listAssets();
  }

  /// 库内容变化后换新 future（导入完成后 / 删除后）。
  void _reloadAssets() {
    if (!mounted) return;
    // 用块体：箭头体会把赋值表达式的值（Future）返回给 setState，
    // Flutter 会判「setState 回调返回了 Future」而抛错。
    setState(() {
      _assetsFuture = _listAssets();
    });
  }

  Future<AssetRepository> _assets() => ref.read(assetRepoProvider.future);

  /// 失败即回滚的批量导入器（单批写库 + 已落盘文件清理）。
  AssetLibraryImporter _importer(
    AssetRepository repo, {
    Future<Set<String>> Function()? existingNames,
  }) =>
      AssetLibraryImporter(
        saveAll: repo.upsertMany,
        removeFile: (p) async {
          final f = File(p);
          if (await f.exists()) await f.delete();
        },
        existingNames: existingNames,
      );

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    final docs = await getApplicationDocumentsDirectory();
    final repo = await _assets();
    // 本地导入**不做**重名跳过（同一首歌允许留多份，与改造前行为一致）。
    final entries = <AssetImportEntry>[
      for (final f in result.files)
        if (f.path != null)
          AssetImportEntry(
            name: f.name,
            materialize: (id) async {
              // P2-23：写 .part 再原子 rename —— 边写边抛时不留下半截可见文件。
              final dest = '${docs.path}/audio_$id${_ext(f.path!)}';
              await atomicWrite(dest, (tmp) => File(f.path!).copy(tmp));
              return AssetBlob(
                  path: dest, sizeBytes: await File(dest).length());
            },
          ),
    ];
    try {
      final outcome = await _importer(repo).importAll(entries);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('导入完成：新增 ${outcome.added} 条'
                '${outcome.skipped > 0 ? '（跳过重名 ${outcome.skipped} 条）' : ''}')));
        _reloadAssets();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败（已回滚，库内无残留）：$e')));
      }
    }
  }

  /// 从 assets/audio/presets_manifest.json 批量导入预置音效（幂等）。
  ///
  /// 60 条**一次事务**写完（BUG-047）：逐条 `insert` 除了 60 次平台往返，
  /// 还会在第 k 条失败时留下 k-1 条"半套库"。
  ///
  /// 实现已下沉到 [importBundledPresets]（引擎的空库自愈与这里共用同一条
  /// 通路，避免两套导入逻辑漂移）。
  Future<void> _importPresets() async {
    if (_importingPresets) return;
    setState(() => _importingPresets = true);
    try {
      final repo = await _assets();
      final outcome = await importBundledPresets(
        existingNames: repo.nameSet,
        saveAll: repo.upsertMany,
        removeFile: (p) async {
          final f = File(p);
          if (await f.exists()) await f.delete();
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('预置音效导入完成：新增 ${outcome.added} 条，'
                '跳过已存在 ${outcome.skipped} 条')));
        _reloadAssets();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败（已回滚，库内无残留）：$e')));
      }
    } finally {
      if (mounted) setState(() => _importingPresets = false);
    }
  }

  /// 删除主体：先删记录再删文件（顺序不可换，理由见调用点注释）。
  Future<void> _deleteAsset(AudioAsset a) async {
    final repo = await _assets();
    await repo.delete(a.id);
    try {
      final f = File(a.path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 孤儿文件不影响使用，下次同路径写入会覆盖。
    }
    _reloadAssets();
  }

  Future<void> _preview(String path, String id) async {
    if (_previewingId != null) {
      await _previewPlayer.stop();
      if (_previewingId == id) {
        if (mounted) setState(() => _previewingId = null);
        return;
      }
    }
    if (mounted) setState(() => _previewingId = id);
    try {
      await _previewPlayer.play(
        path: path,
        channel: AudioChannel.media,
        volume: 0.9,
        maxDurationMs: 8000,
      );
    } on Object catch (e) {
      // 播放失败（文件被清理 / 编解码不支持）必须可见，且必须复位
      // `_previewingId`，否则图标永远停在"停止"态，再次点击行为错乱。
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('试听失败：$e')));
      }
    }
    if (mounted) setState(() => _previewingId = null);
  }

  Future<List<AudioAsset>> _listAssets() async => (await _assets()).listAll();

  static String _ext(String p) {
    final i = p.lastIndexOf('.');
    return i < 0 ? '.bin' : p.substring(i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: widget.embedded ? 52 : null,
        title: widget.embedded ? null : const Text('音源库'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: FilledButton.tonalIcon(
              icon: _importingPresets
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.library_music),
              label: const Text('导入预置库'),
              onPressed: _importingPresets ? null : _importPresets,
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.file_open),
        label: const Text('导入音频'),
        onPressed: _import,
      ),
      body: FutureBuilder<List<AudioAsset>>(
        future: _assetsFuture,
        builder: (context, snap) {
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('暂无音源。', textAlign: TextAlign.center),
                    SizedBox(height: 8),
                    Text(
                        '点击右上角「导入预置库」一键导入 70 条内置音效\n'
                        '（敲击/撞击/拖拽/门窗/玻璃/人声/动物/铃声/警示/自然/电子/助眠/招人烦），\n'
                        '或用右下角导入本地音频文件。',
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (_, i) {
              final a = items[i];
              final previewing = _previewingId == a.id;
              return ListTile(
                leading: Icon(previewing ? Icons.equalizer : Icons.music_note,
                    color: previewing
                        ? Theme.of(context).colorScheme.primary
                        : null),
                title: Text(a.name),
                subtitle: Text(
                  '${a.sizeBytes ~/ 1024} KB'
                  '${a.tags.isNotEmpty ? ' · ${a.tags.join('/')}' : ''}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(previewing ? Icons.stop : Icons.play_arrow),
                      tooltip: '试听',
                      onPressed: () => _preview(a.path, a.id),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '删除',
                      onPressed: () async {
                        // 删除前必须确认：音源可能被任务引用，误删后
                        // 任务到点播放会失败（文件缺失），不可一键撤销。
                        // （测试可经 `confirmDelete: false` 关闭，见字段注释。）
                        if (!widget.confirmDelete) {
                          await _deleteAsset(a);
                          return;
                        }
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text('删除「${a.name}」？'),
                            content:
                                const Text('将同时删除音频文件，引用它的任务将无法再播放该音源。'),
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
                        await _deleteAsset(a);
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _previewPlayer.dispose();
    super.dispose();
  }
}
