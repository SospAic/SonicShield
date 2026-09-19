import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/providers.dart';
import '../../data/repositories/task_repository.dart';
import '../../domain/models/action.dart';
import '../../services/playback_service.dart';
import '../../services/preset_import.dart';

/// 音源库：SAF 导入（免存储权限）+ 一键导入内置预置音效库
/// （60 条程序化合成，12 分类，见 tool/gen_sfx.dart）+ 单条试听。
///
/// [embedded] = true 时作为「自动化」分组页的子 TAB 使用：保留「导入预置库」
/// 操作（否则该能力在新 IA 下不可达），仅去掉标题与返回键。
class SoundLibraryScreen extends ConsumerStatefulWidget {
  const SoundLibraryScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<SoundLibraryScreen> createState() => _SoundLibraryScreenState();
}

class _SoundLibraryScreenState extends ConsumerState<SoundLibraryScreen> {
  bool _importingPresets = false;
  String? _previewingId;
  final PlaybackService _previewPlayer = PlaybackService();

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
              final dest = File('${docs.path}/audio_$id${_ext(f.path!)}');
              await File(f.path!).copy(dest.path);
              return AssetBlob(path: dest.path, sizeBytes: await dest.length());
            },
          ),
    ];
    try {
      final outcome = await _importer(repo).importAll(entries);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('导入完成：新增 ${outcome.added} 条'
                '${outcome.skipped > 0 ? '（跳过重名 ${outcome.skipped} 条）' : ''}')));
        setState(() {});
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
  Future<void> _importPresets() async {
    if (_importingPresets) return;
    setState(() => _importingPresets = true);
    try {
      final raw =
          await rootBundle.loadString('assets/audio/presets_manifest.json');
      final manifest = jsonDecode(raw) as Map<String, dynamic>;
      final items = (manifest['items'] as List).cast<Map<String, dynamic>>();
      final docs = await getApplicationDocumentsDirectory();
      final repo = await _assets();
      final entries = <AssetImportEntry>[
        for (final it in items)
          AssetImportEntry(
            name: '[预置]${it['name']}',
            tags: ['预置', '${it['category']}'],
            durationMs: (it['durationMs'] as num?)?.toInt() ?? 0,
            materialize: (id) async {
              final data = await rootBundle.load('assets/audio/${it['file']}');
              final dest = File('${docs.path}/audio_$id.wav');
              await dest.writeAsBytes(data.buffer.asUint8List(), flush: true);
              return AssetBlob(
                  path: dest.path, sizeBytes: data.lengthInBytes);
            },
          ),
      ];
      final importer = _importer(repo, existingNames: repo.nameSet);
      final outcome = await importer.importAll(entries);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('预置音效导入完成：新增 ${outcome.added} 条，'
                '跳过已存在 ${outcome.skipped} 条（库内共 ${items.length} 条）')));
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

  Future<void> _preview(String path, String id) async {
    if (_previewingId != null) {
      await _previewPlayer.stop();
      if (_previewingId == id) {
        if (mounted) setState(() => _previewingId = null);
        return;
      }
    }
    if (mounted) setState(() => _previewingId = id);
    await _previewPlayer.play(
      path: path,
      channel: AudioChannel.media,
      volume: 0.9,
      maxDurationMs: 8000,
    );
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
            padding: const EdgeInsets.only(right: 8),
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
        future: _listAssets(),
        builder: (context, snap) {
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('暂无音源。', textAlign: TextAlign.center),
                    SizedBox(height: 8),
                    Text(
                        '点击右上角「导入预置库」一键导入 60 条内置音效\n'
                        '（敲击/撞击/拖拽/门窗/玻璃/人声/动物/铃声/警示/自然/电子/助眠），\n'
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
                        final repo = await _assets();
                        // 先删记录再删文件：反过来的话，删文件成功而删记录失败
                        // 会留下一条指向不存在文件的记录（点试听即报错）。
                        await repo.delete(a.id);
                        try {
                          final f = File(a.path);
                          if (await f.exists()) await f.delete();
                        } catch (_) {
                          // 孤儿文件不影响使用，下次同路径写入会覆盖。
                        }
                        if (mounted) setState(() {});
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
