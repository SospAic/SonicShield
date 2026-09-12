import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../domain/models/action.dart';
import '../../services/playback_service.dart';

/// 音源库：SAF 导入（免存储权限）+ 一键导入内置预置音效库
/// （60 条程序化合成，12 分类，见 tool/gen_sfx.dart）+ 单条试听。
class SoundLibraryScreen extends ConsumerStatefulWidget {
  const SoundLibraryScreen({super.key});

  @override
  ConsumerState<SoundLibraryScreen> createState() => _SoundLibraryScreenState();
}

class _SoundLibraryScreenState extends ConsumerState<SoundLibraryScreen> {
  bool _importingPresets = false;
  String? _previewingId;
  final PlaybackService _previewPlayer = PlaybackService();

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    final docs = await getApplicationDocumentsDirectory();
    final db = (await ref.read(databaseProvider.future)).db;
    for (final f in result.files) {
      if (f.path == null) continue;
      final id = const Uuid().v4();
      final dest = File('${docs.path}/audio_$id${_ext(f.path!)}');
      await File(f.path!).copy(dest.path);
      await db.insert(
          'audio_assets',
          {
            'id': id,
            'name': f.name,
            'path': dest.path,
            'size_bytes': await dest.length(),
            'tags': '[]',
            'weight': 1.0,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('导入完成')));
      setState(() {});
    }
  }

  /// 从 assets/audio/presets_manifest.json 批量导入预置音效（幂等）。
  Future<void> _importPresets() async {
    if (_importingPresets) return;
    setState(() => _importingPresets = true);
    try {
      final raw =
          await rootBundle.loadString('assets/audio/presets_manifest.json');
      final manifest = jsonDecode(raw) as Map<String, dynamic>;
      final items = (manifest['items'] as List).cast<Map<String, dynamic>>();
      final docs = await getApplicationDocumentsDirectory();
      final db = (await ref.read(databaseProvider.future)).db;
      final existing = await db.query('audio_assets', columns: ['name']);
      final existingNames = existing.map((r) => r['name'] as String).toSet();

      var added = 0;
      for (final it in items) {
        final name = '[预置]${it['name']}';
        if (existingNames.contains(name)) continue;
        final data = await rootBundle.load('assets/audio/${it['file']}');
        final id = const Uuid().v4();
        final dest = File('${docs.path}/audio_$id.wav');
        await dest.writeAsBytes(data.buffer.asUint8List(), flush: true);
        await db.insert(
            'audio_assets',
            {
              'id': id,
              'name': name,
              'path': dest.path,
              'duration_ms': it['durationMs'],
              'size_bytes': data.lengthInBytes,
              'tags': jsonEncode(['预置', it['category']]),
              'weight': 1.0,
              'created_at': DateTime.now().millisecondsSinceEpoch,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        added++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('预置音效导入完成：新增 $added 条（库内共 ${items.length} 条）')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
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

  Future<List<Map<String, Object?>>> _listAssets() async {
    final db = (await ref.read(databaseProvider.future)).db;
    return db.query('audio_assets', orderBy: 'created_at DESC');
  }

  static String _ext(String p) {
    final i = p.lastIndexOf('.');
    return i < 0 ? '.bin' : p.substring(i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('音源库'),
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
      body: FutureBuilder<List<Map<String, Object?>>>(
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
              final it = items[i];
              final id = it['id'] as String;
              final previewing = _previewingId == id;
              final tags = it['tags'] == null || (it['tags'] as String).isEmpty
                  ? const <String>[]
                  : (jsonDecode(it['tags'] as String) as List).cast<String>();
              return ListTile(
                leading: Icon(previewing ? Icons.equalizer : Icons.music_note,
                    color: previewing
                        ? Theme.of(context).colorScheme.primary
                        : null),
                title: Text(it['name'] as String? ?? ''),
                subtitle: Text(
                  '${((it['size_bytes'] as int?) ?? 0) ~/ 1024} KB'
                  '${tags.isNotEmpty ? ' · ${tags.join('/')}' : ''}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(previewing ? Icons.stop : Icons.play_arrow),
                      tooltip: '试听',
                      onPressed: () => _preview(it['path'] as String, id),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '删除',
                      onPressed: () async {
                        final db = (await ref.read(databaseProvider.future)).db;
                        await db.delete('audio_assets',
                            where: 'id = ?', whereArgs: [id]);
                        setState(() {});
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
