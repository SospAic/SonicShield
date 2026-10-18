import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 第八十七轮覆盖率回补（2026-10-18）。
///
/// ## 为什么需要这一份
///
/// 本轮把 `lib/**` 改了一大片（59 个缺陷），可测面分母 13956 → 14187（+231 行），
/// 已覆盖 13763 → 13928（+165）⇒ 未覆盖 193 → 259，可测面 **98.62% → 98.17%**，
/// 跌破 `COVERAGE_MIN=98.6`。新增代码里最集中的一块是
/// `TaskRepository.removeAssetRef`（BUG-148，19 行全裸）—— 它是"删音源时
/// 把任务里的引用一并摘干净"的唯一实现，却**从未被执行过**。
///
/// ## 为什么必须用**真库**
///
/// `removeAssetRef` 的全部风险都在 SQL 与 JSON 列上：
/// - `asset_ids` 是 TEXT，库里可能躺着**三种**形状（正常 JSON 数组 /
///   空串 / 坏 JSON），必须逐个走一遍反解分支；
/// - 改写走的是 `batch`，`n == 0` 时**不得** commit（否则每次删无关音源都写一次盘）；
/// - 改写必须只动**引用了它的那几条**，不能把别人的 `asset_ids` 一起冲掉。
///
/// 这三条在替身上都验不出来（替身没有 SQL 与列类型），所以走
/// `sqflite_common_ffi` 的真内存库。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase appDb;
  late TaskRepository repo;

  setUp(() async {
    appDb = await AppDatabase.open(inMemoryDatabasePath);
    repo = TaskRepository(appDb);
  });

  tearDown(() async {
    await appDb.close();
  });

  /// 直接写行（不经过 `upsert`）：本组要**精确控制** `asset_ids` 列的原始文本，
  /// 包括"坏 JSON"这种 `upsert` 永远写不出来的形状。
  Future<void> seed(String id, String assetIdsJson) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await appDb.db.insert('tasks', {
      'id': id,
      'name': id,
      'enabled': 1,
      'trigger_type': 'dailyAt',
      'trigger_json': '{}',
      'action_type': 'playAudio',
      'action_json': '{}',
      'asset_ids': assetIdsJson,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<String> assetIdsOf(String id) async {
    final rows = await appDb.db
        .query('tasks', columns: ['asset_ids'], where: 'id = ?', whereArgs: [id]);
    return rows.single['asset_ids'] as String;
  }

  group('RAR · removeAssetRef（BUG-148）', () {
    test('RAR-01 只摘被删的那个 id，其余引用与无关任务一字不动', () async {
      await seed('t1', '["a1","a2"]');
      await seed('t2', '["a2","a3"]');
      await seed('t3', '["a9"]');

      final n = await repo.removeAssetRef('a2');

      expect(n, 2, reason: '返回值是**被改写的任务数**，调用方据此判断要不要刷新');
      expect(await assetIdsOf('t1'), '["a1"]');
      expect(await assetIdsOf('t2'), '["a3"]');
      expect(await assetIdsOf('t3'), '["a9"]',
          reason: '没引用它的任务不得被顺手重写（那是无谓的写盘 + 时间戳漂移）');
    });

    test('RAR-02 摘成空数组：任务退化成"库内全部音源随机"，不是坏数据', () async {
      await seed('t1', '["a1"]');
      expect(await repo.removeAssetRef('a1'), 1);
      expect(await assetIdsOf('t1'), '[]',
          reason: '空数组是合法状态（引擎按"库内全部音源"挑），不能删任务也不能留 null');
    });

    test('RAR-03 空 id / 无人引用 → 返回 0，且不写盘', () async {
      await seed('t1', '["a1"]');
      expect(await repo.removeAssetRef(''), 0, reason: '空 id 必须早退，否则会匹配到空串元素');
      expect(await repo.removeAssetRef('not-used'), 0);
      expect(await assetIdsOf('t1'), '["a1"]');
    });

    test('RAR-04 坏 JSON / 空串 / 缺列 → 当成"没有引用"，不影响其它任务', () async {
      // 历史脏数据：手工改库、旧版本写坏、导入中断都可能留下这三种形状。
      await seed('bad1', 'not-json');
      await seed('bad2', '');
      await seed('bad3', '{"not":"a list"}');
      await seed('good', '["a1"]');

      final n = await repo.removeAssetRef('a1');

      expect(n, 1, reason: '只有 good 真的引用了它；坏数据既不能崩，也不能被算进 n');
      expect(await assetIdsOf('good'), '[]');
      // 坏行必须**原样保留** —— 清理脏数据不是本方法的职责，改了反而更难追。
      expect(await assetIdsOf('bad1'), 'not-json');
      expect(await assetIdsOf('bad2'), '');
      expect(await assetIdsOf('bad3'), '{"not":"a list"}');
    });

    test('RAR-05 数组里混入非字符串元素 → 只保留字符串（不崩、不丢正常项）',
        () async {
      await seed('t1', '["a1", 42, null, "a2"]');
      final n = await repo.removeAssetRef('a1');
      expect(n, 1);
      expect(await assetIdsOf('t1'), '["a2"]',
          reason: '非字符串元素必须被过滤掉 —— 留着它会让引擎的 byId 查询拿到 int');
    });

    test('RAR-06 空库 → 返回 0（无任务可改，不得 commit 空 batch）', () async {
      expect(await repo.removeAssetRef('a1'), 0);
    });
  });
}
