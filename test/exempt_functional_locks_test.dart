import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 夜间豁免**功能语义**回归锁（第八十六轮，BUG-086 ~ BUG-092 一揽子修复）。
///
/// ## 为什么需要这一组
///
/// 「夜间豁免开关还是没用」这个用户反馈，追下去发现**不止一个根因**，而是
/// 三个叠加：引擎续算判据量纲错（BUG-086，`plan_extend_lock_test.dart` 已锁）、
/// `replan` 重入静默丢弃触发源（BUG-087）、反击计划物化写死
/// `quietExempt: false`（BUG-091）。任何一个没修，用户都会看到同样的现象
/// ——「开关开了没用」。
///
/// 本文件用**源码契约锁**锁住后两个（它们在设备层豁免/私有类里，宿主跑不到），
/// 再用**真 DB 行为锁**锁 `reconcile` 的 skipped 残影处理（BUG-092）与
/// `latestPendingFireAt`（BUG-086 的判据输入）。
///
/// ## 解析坑
/// 工作区源码是 CRLF，做文本断言前一律先归一化换行（同
/// `tts_asset_lock_test.dart` / `plan_extend_lock_test.dart`）。
/// 另：`AppDatabase._onConfigure` 开了 `PRAGMA foreign_keys = ON`，
/// `occurrences.task_id` 外键指向 `tasks.id` ⇒ **必须先造父任务**
/// 再插 occurrence，否则抛 `FOREIGN KEY constraint failed (787)`
/// 且是异步异常，只表现为「断言时表是空的」，极易误判成实现有 bug。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  String src(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final materializerSrc = src('lib/domain/scheduling/counter_plan_materializer.dart');
  final engineSrc = src('lib/services/background_engine.dart');

  group('CPL · 反击计划物化：一律跟随本机主开关', () {
    test('CPL-01 物化任务的 quietExempt 必须是 null（不得写 false）', () {
      // docs/20 §8.1：「反击计划生成的任务**一律** null（跟随本机主开关）」。
      // 旧写法 `plan.respectQuietHours ? false : null` 在 respectQuietHours
      // 默认 true 时几乎总产出 `false` = 强制不豁免 ⇒ 用户打开主开关后，
      // 反击计划夜间任务照样不执行，直接感知为"豁免开关没用"。
      expect(
        RegExp(r'quietExempt:\s*plan\.respectQuietHours').hasMatch(materializerSrc),
        isFalse,
        reason: '又在用 respectQuietHours 决定 quietExempt（BUG-091 原型）',
      );
      expect(
        materializerSrc.contains('quietExempt: null'),
        isTrue,
        reason: '物化必须写 quietExempt: null（跟随本机主开关）',
      );
    });

    test('CPL-90 反面样本：旧映射写法必须被 CPL-01 抓到', () {
      const buggy = 'quietExempt: plan.respectQuietHours ? false : null,';
      expect(
        RegExp(r'quietExempt:\s*plan\.respectQuietHours').hasMatch(buggy),
        isTrue,
        reason: '反面样本没命中 ⇒ CPL-01 的正则形同虚设',
      );
    });
  });

  group('RPL · replan 重入：登记补跑而非静默丢弃', () {
    test('RPL-01 重入时不得直接 return（必须登记补跑）', () {
      expect(
        engineSrc.contains('replanQueued = true'),
        isTrue,
        reason: 'replan 重入又变回"print + return"了：设置页开关/远程命令/tick '
            '这些触发源会静默消失，而兜底 tick 一旦被别的 bug 卡死就是永久失效',
      );
      expect(
        engineSrc.contains('replanQueued = false'),
        isTrue,
        reason: '补跑标记必须被消费（登记了却没人重置 = 每轮都补跑一次）',
      );
    });

    test('RPL-90 反面样本：旧写法的特征串不得再出现', () {
      // 旧原型的 logger 文案是全仓唯一的（`replan 重入被拒：…跳过本次触发`）。
      // 用它做反向锚定最稳：不依赖正则猜结构，也不会误伤新写法
      // （新分支里是"登记补跑"，没有这句文案）。
      const buggy = "print('[sonic_shield][engine] replan 重入被拒：上一轮续算尚未完成，跳过本次触发');";
      expect(buggy.contains('replan 重入被拒'), isTrue,
          reason: '反面样本必须先命中特征串');
      expect(
        engineSrc.contains('replan 重入被拒'),
        isFalse,
        reason: '旧"重入即丢弃"的日志文案又回来了 ⇒ 触发源会静默消失',
      );
    });
  });

  group('RCL · reconcile 的 skipped 残影（真 DB 行为锁）', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(inMemoryDatabasePath);
    });

    tearDown(() async {
      await db.close();
    });

    /// sqflite ffi 把 SQLite 放到**后台 isolate**：在 `testWidgets` 的
    /// FakeAsync 里直接 `await` DB 往返会挂死（与
    /// `task_list_pack_test.dart` 文件头同款约束，2026-10 实测踩过）。
    /// 所以这里所有 DB 操作一律包进 `tester.runAsync`。
    Future<T> dbRun<T>(WidgetTester tester, Future<T> Function() body) async {
      final r = await tester.runAsync(body);
      return r as T;
    }

    PlannedOccurrence occ(
      String id,
      String taskId,
      DateTime fireAt, {
      OccurrenceStatus status = OccurrenceStatus.pending,
      bool quietExempt = false,
    }) =>
        PlannedOccurrence(
          id: id,
          taskId: taskId,
          fireAt: fireAt,
          status: status,
          quietExempt: quietExempt,
        );

    /// 先造父任务再插 occurrence。
    ///
    /// **解析坑（2026-10-18 实测）**：`AppDatabase._onConfigure` 开了
    /// `PRAGMA foreign_keys = ON`，`occurrences.task_id` 有指向 `tasks.id`
    /// 的外键 ⇒ 只插 occurrence 会直接抛
    /// `FOREIGN KEY constraint failed (code 787)`，而且是**异步异常**：
    /// 后面的断言会看到一张空表，报"误删/没插进去"，掩盖真实原因。
    Task taskRow(String id) => Task(
          id: id,
          name: '任务 $id',
          enabled: true,
          triggerType: TriggerType.fixedOnce,
          trigger: FixedOnceTrigger(at: DateTime(2026, 10, 20, 9, 30)),
          actionType: ActionType.playAudio,
          action: const PlayAudioAction(
              volumeMin: 0.5,
              volumeMax: 0.8,
              durationSecMin: 3,
              durationSecMax: 8),
          assetIds: const ['a1'],
          cooldownSec: 0,
          quietPolicy: QuietPolicy.skip,
          priority: 0,
          createdAt: DateTime(2026, 10, 15),
          updatedAt: DateTime(2026, 10, 15),
        );

    Future<void> seedTask(WidgetTester tester, String id) => dbRun(
        tester, () => TaskRepository(db).upsert(taskRow(id)));

    testWidgets('OCC-01 latestPendingFireAt：返回未来 pending 的 MAX(fire_at)',
        (tester) async {
      final now = DateTime(2026, 10, 18, 22, 0);
      await seedTask(tester, 't1');
      await seedTask(tester, 't2');
      await dbRun(tester, () async {
        final repo = OccurrenceRepository(db);
        await repo.commitAll(<PlannedOccurrence>[
          occ('a', 't1', now.add(const Duration(hours: 5))),
          occ('b', 't1', now.add(const Duration(hours: 40))),
          occ('c', 't2', now.add(const Duration(hours: 60))),
        ]);
      });

      final coverEnd = await dbRun(
          tester, () => OccurrenceRepository(db).latestPendingFireAt(now));
      expect(coverEnd, now.add(const Duration(hours: 60)),
          reason: '必须是全表 MAX，不是第一条');

      // 阈值 12h ⇒ 覆盖末端在阈值之外 ⇒ 不该续算（配合 planNeedsExtend）
      expect(coverEnd!.isAfter(now.add(const Duration(hours: 12))), isTrue);
    });

    testWidgets('OCC-02 latestPendingFireAt：空表返回 null（自愈信号）', (tester) async {
      final v = await dbRun(tester,
          () => OccurrenceRepository(db).latestPendingFireAt(DateTime(2026, 1, 1)));
      expect(v, isNull, reason: 'null 是"一条都没有"，调用方据此判定需要续算');
    });

    testWidgets('RCL-02 未来 skipped 且不在本轮投影内 ⇒ 删除（清残影）', (tester) async {
      final now = DateTime(2026, 10, 18, 22, 0);
      // 用户在旧定义上跳过了"下一次"
      await seedTask(tester, 't1');
      await dbRun(tester, () async {
        await OccurrenceRepository(db).commitAll(<PlannedOccurrence>[
          occ('t1@A', 't1', now.add(const Duration(hours: 10)),
              status: OccurrenceStatus.skipped),
        ]);
      });

      // 触发器改了 ⇒ 本轮投影里这条已不存在（投影为空）
      await dbRun(tester,
          () => OccurrenceRepository(db).reconcile(<String>['t1'], <PlannedOccurrence>[], now));

      final left = await dbRun(tester,
          () => OccurrenceRepository(db).allForTask('t1'));
      expect(left.where((o) => o.id == 't1@A'), isEmpty,
          reason: '不在投影内的未来 skipped 是残影，必须清（BUG-092）');
    });

    testWidgets('RCL-03 未来 skipped 且仍在本轮投影内 ⇒ 保留（这是用户的跳过意图）',
        (tester) async {
      final now = DateTime(2026, 10, 18, 22, 0);
      final at = now.add(const Duration(hours: 10));
      await seedTask(tester, 't1');
      await dbRun(tester, () async {
        await OccurrenceRepository(db).commitAll(<PlannedOccurrence>[
          occ('t1@A', 't1', at, status: OccurrenceStatus.skipped),
        ]);
      });

      // 本轮投影仍包含同一条 ⇒ 用户的"跳过下一次"必须被尊重，不许被复活。
      await dbRun(tester, () async {
        await OccurrenceRepository(db).reconcile(<String>['t1'], <PlannedOccurrence>[
          occ('t1@A', 't1', at, status: OccurrenceStatus.skipped),
        ], now);
      });

      final all = await dbRun(tester, () => OccurrenceRepository(db).allForTask('t1'));
      final kept = all.where((o) => o.id == 't1@A');
      expect(kept, hasLength(1),
          reason: '投影内的 skipped 被误删 ⇒ 用户刚点的"跳过下一次"失效');
      expect(kept.single.status, OccurrenceStatus.skipped,
          reason: '投影内 skipped 的状态也不许被改写');

      // 且它仍不应被当计划取出来执行
      final dueRows = await dbRun(
          tester, () => OccurrenceRepository(db).due(at.add(const Duration(seconds: 1))));
      expect(dueRows.where((o) => o.id == 't1@A'), isEmpty);
    });

    testWidgets('RCL-04 过去的 skipped 是审计，reconcile 不得动它', (tester) async {
      final now = DateTime(2026, 10, 18, 22, 0);
      final past = now.subtract(const Duration(hours: 30));
      await seedTask(tester, 't1');
      await dbRun(tester, () async {
        await OccurrenceRepository(db).commitAll(<PlannedOccurrence>[
          occ('t1@PAST', 't1', past, status: OccurrenceStatus.skipped),
        ]);
      });

      await dbRun(tester,
          () => OccurrenceRepository(db).reconcile(<String>['t1'], <PlannedOccurrence>[], now));

      final all = await dbRun(tester, () => OccurrenceRepository(db).allForTask('t1'));
      expect(all.where((o) => o.id == 't1@PAST'), isNotEmpty,
          reason: '过去的 skipped 是审计留痕，不许被清理');
    });

    testWidgets('PURGE-01 关主开关：定向清除豁免计划，强制豁免例外必须留下',
        (tester) async {
      final now = DateTime(2026, 10, 18, 22, 0);
      for (final id in const ['t1', 't2', 't3']) {
        await seedTask(tester, id);
      }
      await dbRun(tester, () async {
        await OccurrenceRepository(db).commitAll(<PlannedOccurrence>[
          // t1：普通任务（跟随主开关）⇒ 授权撤销后必须清
          occ('e1', 't1', now.add(const Duration(hours: 10)), quietExempt: true),
          // t2 / t3：任务级「强制豁免」⇒ 主开关关了**仍**豁免，必须留
          occ('e2', 't2', now.add(const Duration(hours: 11)), quietExempt: true),
          occ('e3', 't3', now.add(const Duration(hours: 12)), quietExempt: true),
          // 非豁免计划：与主开关无关，一律不许被动
          occ('n1', 't1', now.add(const Duration(hours: 13))),
          // 已执行完的豁免计划：是审计，不是计划，不许清
          occ('d1', 't1', now.add(const Duration(hours: 14)),
              status: OccurrenceStatus.done, quietExempt: true),
        ]);
      });

      // 引擎 replan 的调用形状：keepTaskIds = quietExempt == true 的任务。
      final purged = await dbRun(tester,
          () => OccurrenceRepository(db).deletePendingQuietExempt(keepTaskIds: const ['t2', 't3']));
      expect(purged, 1, reason: '只有 e1 这一条该被清');

      final ids = await dbRun(tester, () async {
        final repo = OccurrenceRepository(db);
        return <String>[
          for (final o in <PlannedOccurrence>[
            ...await repo.allForTask('t1'),
            ...await repo.allForTask('t2'),
            ...await repo.allForTask('t3'),
          ])
            o.id
        ];
      });
      expect(ids, containsAll(<String>['e2', 'e3']),
          reason: '任务级强制豁免是 v79 的双向覆盖：主开关关了也仍然豁免');
      expect(ids, containsAll(<String>['n1', 'd1']));
      expect(ids, isNot(contains('e1')),
          reason: '授权已撤销的普通豁免计划必须清（BUG-086 时代的护栏静默绕过）');
    });

    testWidgets('PURGE-02 keepTaskIds 为空 ⇒ 退化为全清（老行为不变）',
        (tester) async {
      final now = DateTime(2026, 10, 18, 22, 0);
      await seedTask(tester, 't1');
      await dbRun(tester, () async {
        await OccurrenceRepository(db).commitAll(<PlannedOccurrence>[
          occ('e1', 't1', now.add(const Duration(hours: 10)), quietExempt: true),
          occ('e2', 't1', now.add(const Duration(hours: 11)), quietExempt: true),
          occ('n1', 't1', now.add(const Duration(hours: 12))),
        ]);
      });

      final purged = await dbRun(
          tester, () => OccurrenceRepository(db).deletePendingQuietExempt());
      expect(purged, 2);

      final left = await dbRun(tester, () => OccurrenceRepository(db).allForTask('t1'));
      expect(left.map((o) => o.id), <String>['n1'],
          reason: '非豁免计划不该被清除动作波及');
    });
  });
}
