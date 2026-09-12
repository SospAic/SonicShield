import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/providers.dart';

/// 音源库：从系统文件（SAF，免存储权限）导入音频到应用私有目录。
class SoundLibraryScreen extends ConsumerStatefulWidget {
  const SoundLibraryScreen({super.key});

  @override
  ConsumerState<SoundLibraryScreen> createState() => _SoundLibraryScreenState();
}

class _SoundLibraryScreenState extends ConsumerState<SoundLibraryScreen> {
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
      appBar: AppBar(title: const Text('音源库')),
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
            return const Center(child: Text('暂无音源，点击右下角导入音频文件'));
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (_, i) {
              final it = items[i];
              return ListTile(
                leading: const Icon(Icons.music_note),
                title: Text(it['name'] as String? ?? ''),
                subtitle: Text(
                    '${((it['size_bytes'] as int?) ?? 0) ~/ 1024} KB · ${it['path']}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final db = (await ref.read(databaseProvider.future)).db;
                    await db.delete('audio_assets',
                        where: 'id = ?', whereArgs: [it['id']]);
                    setState(() {});
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
