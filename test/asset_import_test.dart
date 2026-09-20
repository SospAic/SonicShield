import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/services/preset_import.dart';

/// BUG-047 回归锁：音源库批量导入的**原子性**与**幂等**。
///
/// 改造前 `_importPresets()` 在界面里逐条 `db.insert`：
/// 60 次平台往返 + 第 k 条失败会留下 k-1 条"半套库"。
/// 本文件把「一次调用写完一整批」与「失败不留残留」变成可断言的性质。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase appDb;
  late AssetRepository repo;

  setUp(() async {
    appDb = await AppDatabase.open(inMemoryDatabasePath);
    repo = AssetRepository(appDb);
  });

  tearDown(() async {
    await appDb.close();
  });

  AudioAsset makeAsset(String id, {String? name}) => AudioAsset(
        id: id,
        name: name ?? '音源$id',
        path: '/docs/audio_$id.wav',
        durationMs: 500,
        sizeBytes: 4096,
        tags: const ['预置', 'knocks'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  group('AssetRepository.upsertMany', () {
    test('往返保留全部字段（含 tags JSON）', () async {
      await repo.upsertMany([makeAsset('a1')]);
      final got = (await repo.listAll()).single;
      expect(got.id, 'a1');
      expect(got.name, '音源a1');
      expect(got.path, '/docs/audio_a1.wav');
      expect(got.durationMs, 500);
      expect(got.sizeBytes, 4096);
      expect(got.tags, ['预置', 'knocks']);
      expect(got.weight, 1.0);
      expect(got.createdAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('同 id 幂等（replace 语义，不产生重复行）', () async {
      await repo.upsertMany([makeAsset('dup'), makeAsset('dup')]);
      expect(await repo.listAll(), hasLength(1));
      await repo.upsertMany([makeAsset('dup')]); // 整批重放
      expect(await repo.listAll(), hasLength(1));
    });

    test('空集合不产生任何写入（不抛、不开事务）', () async {
      await repo.upsertMany(const <AudioAsset>[]);
      expect(await repo.listAll(), isEmpty);
    });

    test('原子性：提交前失败不留下半批数据（BUG-047 回归锁）', () async {
      // 第 3 条在**行映射阶段**抛错 → 批次已组好但**尚未 commit**。
      await expectLater(
        repo.upsertMany([
          makeAsset('ok1'),
          makeAsset('ok2'),
          _ExplodingAsset(makeAsset('boom')),
          makeAsset('ok3'),
        ]),
        throwsA(isA<StateError>()),
      );
      expect(
        await repo.listAll(),
        isEmpty,
        reason: '整批在同一事务里提交，提交前抛错必须**一条都不落库**。'
            '旧的逐条 insert 循环会留下 ok1/ok2 —— 使用者看到"导入失败"，'
            '音源列表里却已经多了一截。',
      );
    });

    test('upsert 与 upsertMany 行映射一致（防两条路径漂移）', () async {
      // 同一份输入分别走两条路径，落库的行映射必须**逐列相同**。
      final a = makeAsset('same');
      await repo.upsert(a);
      final rowSingle = (await appDb.db.query('audio_assets')).single;
      await appDb.db.delete('audio_assets');
      await repo.upsertMany([a]);
      final rowBatch = (await appDb.db.query('audio_assets')).single;

      expect(rowSingle.keys.toSet(), rowBatch.keys.toSet());
      for (final k in rowSingle.keys) {
        expect(rowBatch[k], rowSingle[k], reason: '列 $k 在两条写入路径上不一致');
      }
    });

    test('nameSet 只取名字且与写入一致（幂等判据）', () async {
      await repo.upsertMany([makeAsset('a1'), makeAsset('a2')]);
      expect(await repo.nameSet(), {'音源a1', '音源a2'});
    });

    test('delete 后 nameSet 同步收缩', () async {
      await repo.upsertMany([makeAsset('a1'), makeAsset('a2')]);
      await repo.delete('a1');
      expect(await repo.nameSet(), {'音源a2'});
    });
  });

  group('AssetLibraryImporter', () {
    /// 每条落盘一个假路径 `/tmp/<id>.wav`，并记录调用轨迹。
    AssetImportEntry entry(String name, {List<Object>? log}) =>
        AssetImportEntry(
          name: name,
          tags: const ['预置'],
          durationMs: 100,
          materialize: (id) async {
            log?.add('materialize:$name');
            return AssetBlob(path: '/tmp/$id.wav', sizeBytes: 10);
          },
        );

    test('N 条只调用一次 saveAll（"单事务 / 单往返"的可断言出口）', () async {
      final saves = <List<AudioAsset>>[];
      var n = 0;
      final importer = AssetLibraryImporter(
        saveAll: (items) async => saves.add(items.toList()),
        removeFile: (_) async {},
        newId: () => 'id${++n}',
      );
      final out =
          await importer.importAll([entry('a'), entry('b'), entry('c')]);
      expect(saves, hasLength(1), reason: '逐条 upsert 会调用 3 次 —— 3 次平台往返');
      expect(saves.single, hasLength(3));
      expect(out.added, 3);
      expect(out.skipped, 0);
    });

    test('幂等：重名条目被跳过，且**不触发落盘**', () async {
      final log = <Object>[];
      final saves = <List<AudioAsset>>[];
      final importer = AssetLibraryImporter(
        saveAll: (items) async => saves.add(items.toList()),
        removeFile: (_) async {},
        existingNames: () async => {'[预置]已存在'},
      );
      final out = await importer.importAll([
        entry('[预置]已存在', log: log),
        entry('[预置]新的', log: log),
      ]);
      expect(log, ['materialize:[预置]新的'], reason: '已存在的条目不该白读一次 asset bundle');
      expect(out.added, 1);
      expect(out.skipped, 1);
      expect(saves.single, hasLength(1));
    });

    test('全部重名 → 完全不调用 saveAll（连空事务都不开）', () async {
      var saveCalls = 0;
      final importer = AssetLibraryImporter(
        saveAll: (_) async => saveCalls++,
        removeFile: (_) async {},
        existingNames: () async => {'x'},
      );
      final out = await importer.importAll([entry('x'), entry('x')]);
      expect(saveCalls, 0);
      expect(out.added, 0);
      expect(out.skipped, 2);
    });

    test('空清单 → 不调用 saveAll（不开空事务）、不落盘', () async {
      var saveCalls = 0;
      final importer = AssetLibraryImporter(
        saveAll: (_) async => saveCalls++,
        removeFile: (_) async {},
      );
      final out = await importer.importAll(const <AssetImportEntry>[]);
      expect(out.added, 0);
      expect(out.skipped, 0);
      expect(saveCalls, 0);
    });

    test('落盘失败 → 回滚已落盘文件 + 库内零新增', () async {
      final removed = <String>[];
      final saves = <List<AudioAsset>>[];
      var n = 0;
      final importer = AssetLibraryImporter(
        saveAll: (items) async => saves.add(items.toList()),
        removeFile: (p) async => removed.add(p),
        newId: () => 'id${++n}',
      );
      await expectLater(
        importer.importAll([
          entry('a'),
          entry('b'),
          AssetImportEntry(
            name: 'c',
            materialize: (_) async => throw StateError('disk full'),
          ),
          entry('d'),
        ]),
        throwsA(isA<StateError>()),
      );
      expect(saves, isEmpty, reason: '落盘都没做完，绝不该开事务');
      expect(removed, ['/tmp/id1.wav', '/tmp/id2.wav'],
          reason: '本次已落盘的两个文件必须清理，否则每次失败都攒一批孤儿音频');
    });

    test('写库失败 → 事务回滚（零新增）+ 清理全部已落盘文件', () async {
      final removed = <String>[];
      var n = 0;
      final importer = AssetLibraryImporter(
        saveAll: (_) async => throw StateError('database is locked'),
        removeFile: (p) async => removed.add(p),
        newId: () => 'id${++n}',
      );
      await expectLater(
        importer.importAll([entry('a'), entry('b')]),
        throwsA(isA<StateError>()),
      );
      expect(removed, hasLength(2), reason: '库内一条没进，文件也不能留');
    });

    test('清理自身失败不掩盖原始异常', () async {
      final importer = AssetLibraryImporter(
        saveAll: (_) async => throw StateError('原始错误'),
        removeFile: (_) async => throw StateError('清理也失败了'),
      );
      await expectLater(
        importer.importAll([entry('a')]),
        throwsA(isA<StateError>().having((e) => e.message, 'message', '原始错误')),
      );
    });

    test('成功路径字段正确（name/tags/durationMs/path/sizeBytes）', () async {
      var n = 0;
      final importer = AssetLibraryImporter(
        saveAll: repo.upsertMany,
        removeFile: (_) async {},
        newId: () => 'id${++n}',
        now: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      await importer.importAll([entry('[预置]敲门')]);
      final got = (await repo.listAll()).single;
      expect(got.name, '[预置]敲门');
      expect(got.tags, ['预置']);
      expect(got.durationMs, 100);
      expect(got.path, '/tmp/id1.wav');
      expect(got.sizeBytes, 10);
      expect(got.createdAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('端到端幂等：真实仓储下重复导入零新增（`[预置]` 前缀即判据）', () async {
      final importer = AssetLibraryImporter(
        saveAll: repo.upsertMany,
        removeFile: (_) async {},
        existingNames: repo.nameSet,
      );
      final first = await importer.importAll([entry('[预置]a'), entry('[预置]b')]);
      expect(first.added, 2);
      final second = await importer.importAll([entry('[预置]a'), entry('[预置]b')]);
      expect(second.added, 0);
      expect(second.skipped, 2);
      expect(await repo.listAll(), hasLength(2));
    });

    test('不传 existingNames 时同名可重复导入（本地导入语义未变）', () async {
      var n = 0;
      final importer = AssetLibraryImporter(
        saveAll: repo.upsertMany,
        removeFile: (_) async {},
        newId: () => 'id${++n}',
      );
      await importer.importAll([entry('同一首歌'), entry('同一首歌')]);
      final all = await repo.listAll();
      expect(all, hasLength(2), reason: '本地导入允许同名多份，与改造前一致');
      expect(all.map((a) => a.name).toSet(), {'同一首歌'});
    });
  });

  group('预置库清单与磁盘资源一致性', () {
    test('60 条 / 12 分类 / 每个 file 都存在 / 名字唯一', () {
      final raw = File('assets/audio/presets_manifest.json').readAsStringSync();
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final items = (m['items'] as List).cast<Map<String, dynamic>>();

      expect(items, hasLength(60));
      expect(items.map((i) => i['category']).toSet(), hasLength(12));

      final names = <String>[];
      for (final it in items) {
        final file = File('assets/audio/${it['file']}');
        expect(file.existsSync(), isTrue, reason: '缺失资源：${it['file']}');
        expect((it['name'] as String).isNotEmpty, isTrue);
        expect((it['durationMs'] as num).toInt(), greaterThan(0));
        names.add(it['name'] as String);
      }
      // 导入的幂等判据是**名字**：清单里出现重名 → 会有条目被静默漏导入。
      expect(names.toSet(), hasLength(names.length),
          reason: '清单内名字必须唯一，否则"按名幂等"会漏导入');
    });
  });
}

/// 在**行映射阶段**抛错的音源 —— 用来验证批量写入的原子性。
///
/// 注入点必须在 `batch.commit()` **之前**：若在提交之后才抛，
/// 事务已经落库，断言就变成恒真的了。
class _ExplodingAsset extends AudioAsset {
  _ExplodingAsset(AudioAsset a)
      : super(
          id: a.id,
          name: a.name,
          path: a.path,
          durationMs: a.durationMs,
          sizeBytes: a.sizeBytes,
          tags: a.tags,
          weight: a.weight,
          createdAt: a.createdAt,
        );

  @override
  Map<String, Object?> toRow() => throw StateError('boom');
}
