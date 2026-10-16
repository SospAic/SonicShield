import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../data/repositories/task_repository.dart';

/// 导入 **assets 内置预置音效库**（`assets/audio/presets_manifest.json`）。
///
/// 幂等（按名字跳过已导入者）。原先只存在于「音源库」页（UI 私有方法），
/// 抽到这里有两个调用方：
/// - 「音源库」页的「导入预置库」按钮（行为不变）；
/// - **后台引擎**（2026-10）：守护反击改为只播随机噪音后，素材库为空
///   = 反击彻底空转。引擎在装配反击动作池前调用本函数自愈 —— 用户不必
///   记得先去音源库点导入。
///
/// 失败**原样抛出**：调用方（UI 提示 / 引擎记 failed 日志）各自处置，
/// 本函数不回 partial 成功（importer 已保证失败零残留）。
Future<AssetImportOutcome> importBundledPresets({
  required Future<Set<String>> Function() existingNames,
  required Future<void> Function(Iterable<AudioAsset>) saveAll,
  required Future<void> Function(String path) removeFile,
}) async {
  final raw = await rootBundle.loadString('assets/audio/presets_manifest.json');
  final manifest = jsonDecode(raw) as Map<String, dynamic>;
  final items = (manifest['items'] as List).cast<Map<String, dynamic>>();
  final docs = await getApplicationDocumentsDirectory();
  final entries = <AssetImportEntry>[
    for (final it in items)
      AssetImportEntry(
        name: '[预置]${it['name']}',
        // 第三个 tag 是 manifest 里的**稳定 id**（如 `annoy_spit`）：
        // 反击计划（v2.0）按它回查"本机装了哪些计划点名的音效"。
        // 资产行 id 是导入时生成的 UUID，无法反推 manifest id，故必须落 tag。
        tags: ['预置', '${it['category']}', '${it['id']}'],
        durationMs: (it['durationMs'] as num?)?.toInt() ?? 0,
        materialize: (id) async {
          final data = await rootBundle.load('assets/audio/${it['file']}');
          // P2-23：预置库落盘走原子写入（失败不留半截文件）。
          final dest = '${docs.path}/audio_$id.wav';
          await atomicWrite(dest,
              (tmp) => File(tmp).writeAsBytes(data.buffer.asUint8List(),
                  flush: true));
          return AssetBlob(path: dest, sizeBytes: data.lengthInBytes);
        },
      ),
  ];
  final importer = AssetLibraryImporter(
    saveAll: saveAll,
    removeFile: removeFile,
    existingNames: existingNames,
  );
  return importer.importAll(entries);
}

/// 原子落盘（P2-23）：先写 `<finalPath>.part`，全部写完再 `rename` 到最终路径。
///
/// ## 为什么
///
/// 批量导入的回滚只能删**已登记**的最终路径；而 `materialize` 若"边写边抛"
/// （磁盘满、源文件读一半失败、`length()` 取字节数时失败），最终路径要么留下
/// **半截可见文件**、要么根本没走到登记那一步 —— 回滚会漏掉它。
///
/// 写 `.part` 临时件再原子 rename 后：**失败时最终路径永不出现**，全部残留
/// 都集中在 `.part` 上并由本函数删除；成功则是一次同文件系统内的 rename，
/// 不会出现"被看见的半截文件"。原子 rename 也保证下游（DB 记录）读到的
/// 永远是完整文件。
///
/// 失败时**原样抛出原异常**：清理是尽力而为，不得掩盖真实原因（与
/// [AssetLibraryImporter] 的回滚语义一致）。
Future<void> atomicWrite(
  String finalPath,
  Future<void> Function(String tmpPath) write,
) async {
  final tmpPath = '$finalPath.part';
  try {
    await write(tmpPath);
    await File(tmpPath).rename(finalPath);
  } catch (_) {
    try {
      final tmp = File(tmpPath);
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {
      // 尽力而为：清理失败不得掩盖原始异常。
    }
    rethrow;
  }
}

/// 一条待导入音源的「来源描述」。
///
/// 「从哪读」与「怎么落盘」留给调用方（预置库读 asset bundle、
/// 本地导入复制用户文件）；本导入器只负责三件事：
/// **幂等跳过 / 失败回滚 / 单批写库**。
///
/// 之所以把这段逻辑从界面里抽出来：界面依赖 `FilePicker` / `rootBundle` /
/// `path_provider`，在宿主机上跑不起来 —— 而"导入失败会不会留下半套库"
/// 恰恰是**唯一值得写回归锁**的性质，抽出来之后它就能被断言。
class AssetImportEntry {
  const AssetImportEntry({
    required this.name,
    required this.materialize,
    this.tags = const [],
    this.durationMs = 0,
  });

  /// 库内显示名（预置库带 `[预置]` 前缀；重名即视为"已导入过"）。
  final String name;

  final List<String> tags;
  final int durationMs;

  /// 落盘并返回最终路径与字节数。抛错 = 本条导入失败。
  final Future<AssetBlob> Function(String id) materialize;
}

/// 单条落盘结果。
class AssetBlob {
  const AssetBlob({required this.path, required this.sizeBytes});

  final String path;
  final int sizeBytes;
}

/// 导入结果（供界面文案使用）。
class AssetImportOutcome {
  const AssetImportOutcome({required this.added, required this.skipped});

  /// 真正落库的条数。
  final int added;

  /// 因重名被跳过的条数。
  final int skipped;
}

/// 批量音源导入器：幂等跳过 → 全部落盘 → **一次**写库 → 失败回滚。
///
/// 失败语义（两种失败都**不留半套库**）：
/// - 落盘阶段失败 → 回滚本次已落盘的文件，**不调用** [saveAll]（库内零新增）；
/// - 写库阶段失败 → 事务回滚（库内零新增），并回滚本次已落盘的文件（无孤儿文件）。
///
/// 回滚自身失败**不掩盖**原始错误（清理是尽力而为，孤儿文件无害，
/// 而把真实原因吞掉会让界面显示一个无关的异常）。
class AssetLibraryImporter {
  AssetLibraryImporter({
    required this.saveAll,
    required this.removeFile,
    Future<Set<String>> Function()? existingNames,
    String Function()? newId,
    DateTime Function()? now,
  })  : existingNames = existingNames ?? _noExisting,
        newId = newId ?? _defaultId,
        now = now ?? _defaultNow;

  /// 单批写库（传 `AssetRepository.upsertMany`）—— **必须一次调用写完一整批**。
  final Future<void> Function(Iterable<AudioAsset>) saveAll;

  /// 回滚已落盘的文件。
  final Future<void> Function(String path) removeFile;

  /// 库内已有名字集合。默认空集 = **不做**幂等跳过
  /// （本地导入允许同名多份，与改造前行为一致）。
  final Future<Set<String>> Function() existingNames;

  final String Function() newId;
  final DateTime Function() now;

  static Future<Set<String>> _noExisting() async => const <String>{};

  static String _defaultId() => const Uuid().v4();

  static DateTime _defaultNow() => DateTime.now();

  Future<AssetImportOutcome> importAll(List<AssetImportEntry> entries) async {
    final existing = await existingNames();
    final written = <String>[];
    final assets = <AudioAsset>[];
    var skipped = 0;

    try {
      for (final e in entries) {
        if (existing.contains(e.name)) {
          skipped++;
          continue;
        }
        final id = newId();
        final blob = await e.materialize(id);
        written.add(blob.path);
        assets.add(AudioAsset(
          id: id,
          name: e.name,
          path: blob.path,
          durationMs: e.durationMs,
          sizeBytes: blob.sizeBytes,
          tags: e.tags,
          createdAt: now(),
        ));
      }
      // 全部条目都重名 → 不产生任何数据库操作（连空事务都不开）。
      if (assets.isEmpty) {
        return AssetImportOutcome(added: 0, skipped: skipped);
      }
      await saveAll(assets);
      return AssetImportOutcome(added: assets.length, skipped: skipped);
    } catch (_) {
      for (final p in written) {
        try {
          await removeFile(p);
        } catch (_) {
          // 尽力而为：清理失败不得掩盖原始异常。
        }
      }
      rethrow;
    }
  }
}
