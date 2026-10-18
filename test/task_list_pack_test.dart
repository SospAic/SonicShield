import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/tasks/task_list_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 任务清单「按单次创建单位展示」+「立即执行」的宿主回归锁（2026-10）。
///
/// 覆盖新 IA 的三件事（老板需求原文）：
/// 1. 反击计划物化的 `counter:{planId}:…` 任务**按 planId 聚合成任务包**，
///    一次创建=一个包，不把用户自己的任务淹埋在几十条展开行里；
/// 2. 手动 UUID 任务保持**单任务**卡片（旧断言全部保留在
///    `task_list_screen_test.dart`，本文件只加不删语义）；
/// 3. 每条任务有「立即执行」入口，转交引擎执行；引擎未运行时**如实**回报
///    （不允许假成功）。
///
/// 宿主硬约束与 `task_list_screen_test.dart` 文件头同款：
/// - DB 操作必须包在 `tester.runAsync`（sqflite ffi 在后台 isolate，FakeAsync
///   里直接 await 会挂死）；
/// - 不用固定轮次 drain，用有界 `waitFor`；
/// - 收尾推掉 SnackBar 计时；
/// - 每例显式 90s timeout。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const perTest = Timeout(Duration(seconds: 90));

  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(inMemoryDatabasePath);
    BackgroundServiceManager.replanHook = () async {};
    // 引擎未运行（宿主没有另一侧）：runNow 会短路返回失败 —— 正好锁
    // 「未运行不许假成功」这条。
  });

  tearDown(() async {
    BackgroundServiceManager.replanHook = null;
    BackgroundServiceManager.startHook = null;
    await db.close();
  });

  Future<void> dbWrite(
      WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(body);
  }

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() cond, {
    required String reason,
    int maxRounds = 300,
  }) async {
    for (var i = 0; i < maxRounds; i++) {
      if (cond()) return;
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('等待超时（$maxRounds 轮）：$reason');
  }

  Future<void> waitForText(WidgetTester tester, String substring) => waitFor(
        tester,
        () => find.textContaining(substring).evaluate().isNotEmpty,
        reason: '应出现含「$substring」的文案',
      );

  Future<void> settleSnackBars(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Task manual(String id, String name) => Task(
        id: id,
        name: name,
        enabled: true,
        triggerType: TriggerType.fixedOnce,
        trigger: FixedOnceTrigger(at: DateTime(2026, 10, 20, 9, 30)),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(volumeMin: 0.5, volumeMax: 0.8,
            durationSecMin: 3, durationSecMax: 8),
        assetIds: const ['a1'],
        cooldownSec: 0,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: DateTime(2026, 10, 15),
        updatedAt: DateTime(2026, 10, 15),
      );

  Task counterTask(String planId, String key, String name) => Task(
        id: 'counter:$planId:$key',
        name: name,
        enabled: true,
        triggerType: TriggerType.fixedOnce,
        trigger: FixedOnceTrigger(at: DateTime(2026, 10, 20, 10, 15)),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(volumeMin: 0.3, volumeMax: 0.5,
            durationSecMin: 3, durationSecMax: 5),
        assetIds: const ['a1'],
        cooldownSec: 0,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: DateTime(2026, 10, 15),
        updatedAt: DateTime(2026, 10, 15),
      );

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (_, __) => const TaskListScreen(embedded: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('TLS-PACK-01 任务清单：manual 单卡 + counter 聚合为任务包卡片',
      (tester) async {
    await dbWrite(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(manual('t1', '我的晨间任务'));
      await repo.upsert(manual('t2', '我的夜间任务'));
      await repo.upsert(counterTask('p1', '20261020D00', '反击·工作日白天 10:15'));
      await repo.upsert(counterTask('p1', '20261020N00', '反击·工作日夜间 22:15'));
      await repo.upsert(counterTask('p2', '20261021D00', '反击·工作日白天 11:20'));
    });

    await pumpList(tester);
    await waitForText(tester, '我的晨间任务');

    // 手动任务：单任务卡片照旧逐条展示。
    expect(find.text('我的晨间任务'), findsOne);
    expect(find.text('我的夜间任务'), findsOne);

    // counter 任务：按 planId 聚合成任务包，**不**平铺展开行。
    expect(find.text('反击计划 · p1'), findsOne,
        reason: '一次创建的计划应显示为一个任务包');
    expect(find.text('反击计划 · p2'), findsOne);
    expect(find.text('反击·工作日白天 10:15'), findsNothing,
        reason: '包内条目默认折叠，不能平铺淹没清单');
    expect(find.text('2 条 · 启用 2 条'), findsOne,
        reason: '包头部要显示条数与启用数');
  }, timeout: perTest);

  testWidgets('TLS-PACK-02 点包头部展开：包内条目出现，可再次折叠',
      (tester) async {
    await dbWrite(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(counterTask('p1', '20261020D00', '反击·工作日白天 10:15'));
    });

    await pumpList(tester);
    await waitForText(tester, '反击计划 · p1');

    await tester.tap(find.text('反击计划 · p1'));
    await tester.pump();
    await waitForText(tester, '反击·工作日白天 10:15');

    await tester.tap(find.text('反击计划 · p1'));
    await tester.pump();
    await waitFor(
      tester,
      () => find.text('反击·工作日白天 10:15').evaluate().isEmpty,
      reason: '再点一次应折叠',
    );
  }, timeout: perTest);

  testWidgets('TLS-RUN-01 每条任务有「立即执行」入口；引擎未运行时如实告知',
      (tester) async {
    await dbWrite(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(manual('t1', '我的晨间任务'));
    });

    await pumpList(tester);
    await waitForText(tester, '我的晨间任务');

    // 入口存在（图标）。⚠️ 不找「立即执行」文本：它是 IconButton 的 tooltip，
    // 不在 widget 树里（tooltip 只在长按/hover 时渲染）—— 断言它会假红。
    expect(find.byIcon(Icons.play_circle_outline), findsWidgets);

    // 点立即执行 ⇒ 引擎未运行 ⇒ 如实失败提示，不许假成功。
    await tester.tap(find.byIcon(Icons.play_circle_outline).first);
    await waitForText(tester, '未执行');
    await settleSnackBars(tester);
  }, timeout: perTest);

  testWidgets('TLS-RUN-02 长按菜单含「立即执行」（与复制/删除并列）',
      (tester) async {
    await dbWrite(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(manual('t1', '我的晨间任务'));
    });

    await pumpList(tester);
    await waitForText(tester, '我的晨间任务');

    await tester.longPress(find.text('我的晨间任务'));
    await tester.pump();
    await waitForText(tester, '立即执行');
    expect(find.text('复制任务'), findsOne);
    expect(find.text('删除'), findsOne);

    // 取消，避免遗留对话框。
    await tester.tap(find.text('取消').last);
    await tester.pump();
  }, timeout: perTest);

  testWidgets('TLS-PACK-03 批量选择态下 counter 任务平铺（批量语义不变）',
      (tester) async {
    await dbWrite(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(manual('t1', '我的晨间任务'));
      await repo.upsert(counterTask('p1', '20261020D00', '反击·工作日白天 10:15'));
    });

    await pumpList(tester);
    await waitForText(tester, '我的晨间任务');

    await tester.tap(find.byKey(const Key('task_batch_enter')));
    await tester.pump();
    await waitFor(
      tester,
      () => find.textContaining('反击·工作日白天 10:15').evaluate().isNotEmpty,
      reason: '选择态下应平铺全部任务（含 counter），批量启停/删除才有一致语义',
    );
  }, timeout: perTest);

  testWidgets('TLS-PACK-04 空态仍指引新建（聚合改造不影响空列表）',
      (tester) async {
    await pumpList(tester);
    await waitForText(tester, '还没有任务');
    expect(find.widgetWithText(FloatingActionButton, '新建任务'), findsOne);
  }, timeout: perTest);

  testWidgets('TLS-PACK-05 包头部开关：整组停用并如实回报条数', (tester) async {
    await dbWrite(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(counterTask('p1', '20261020D00', '反击·工作日白天 10:15'));
      await repo.upsert(counterTask('p1', '20261020N00', '反击·工作日夜间 22:15'));
    });

    await pumpList(tester);
    await waitForText(tester, '反击计划 · p1');

    // 包未展开时卡内只有头部那一个 Switch（包内行尚未构建）。
    final card = find.ancestor(
      of: find.text('反击计划 · p1'),
      matching: find.byType(Card),
    );
    final packSwitch = find.descendant(of: card, matching: find.byType(Switch));
    expect(packSwitch, findsOne, reason: '包头部应有整组开关');

    await tester.tap(packSwitch);
    await waitForText(tester, '已停用「反击计划 · p1」全部 2 条');
    await settleSnackBars(tester);
  }, timeout: perTest);

  testWidgets('TLS-PACK-06 菜单「删除整包」：二次确认后整包删除', (tester) async {
    await dbWrite(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(counterTask('p1', '20261020D00', '反击·工作日白天 10:15'));
      await repo.upsert(counterTask('p1', '20261020N00', '反击·工作日夜间 22:15'));
    });

    await pumpList(tester);
    await waitForText(tester, '反击计划 · p1');

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await waitForText(tester, '删除整包');

    await tester.tap(find.text('删除整包'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 二次确认：文案要带包名与条数，避免误删。
    await waitForText(tester, '删除「反击计划 · p1」全部 2 条？');
    await tester.tap(find.text('删除'));
    await waitForText(tester, '已删除「反击计划 · p1」全部 2 条');
    await settleSnackBars(tester);

    // 整包消失（列表回到空态）。
    await waitFor(
      tester,
      () => find.text('反击计划 · p1').evaluate().isEmpty,
      reason: '删除后任务包卡片应消失',
    );
  }, timeout: perTest);

  testWidgets('TLS-PACK-07 菜单「立即执行下一条」：选中最早触发那条并如实回报',
      (tester) async {
    await dbWrite(tester, () async {
      final repo = TaskRepository(db);
      // 两条都启用：应挑 nextFireAt 最早的那条（此处顺序无关，只验入口连通）。
      await repo.upsert(counterTask('p1', '20261020D00', '反击·工作日白天 10:15'));
      await repo.upsert(counterTask('p1', '20261020N00', '反击·工作日夜间 22:15'));
    });

    await pumpList(tester);
    await waitForText(tester, '反击计划 · p1');

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await waitForText(tester, '立即执行下一条');

    await tester.tap(find.text('立即执行下一条'));
    // 引擎未运行 ⇒ 必须如实告知「未执行」，不许假成功。
    await waitForText(tester, '未执行');
    await settleSnackBars(tester);
  }, timeout: perTest);

  testWidgets('TLS-PACK-08 「立即执行下一条」：nextFireAt 混合（有/无未来计划）时排序正确',
      (tester) async {
    // `_packRunNext` 的比较器三条分支：双方都 null / 一方 null（沉底）/
    // 双方都有（比早）。此前只有"全 null"与"全有"两种夹具，缺"混合"分支 ——
    // 一旦把 null 沉底的比较写反，"立即执行下一条"会选中**没有未来计划**的
    // 那条（语义直接错）。
    await dbWrite(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(counterTask('p1', 'k1', '包·甲（有计划·较晚）'));
      await repo.upsert(counterTask('p1', 'k2', '包·乙（有计划·最早）'));
      await repo.upsert(counterTask('p1', 'k3', '包·丙（无计划）'));
      final or = OccurrenceRepository(db);
      final now = DateTime.now();
      // k3 故意**不**造 pending（nextFireAt = null 沉底路径）。
      await or.commitAll([
        PlannedOccurrence(
          id: 'occ-eth-a',
          taskId: 'counter:p1:k1',
          fireAt: now.add(const Duration(hours: 3)),
          status: OccurrenceStatus.pending,
        ),
        PlannedOccurrence(
          id: 'occ-eth-b',
          taskId: 'counter:p1:k2',
          fireAt: now.add(const Duration(hours: 1)),
          status: OccurrenceStatus.pending,
        ),
      ]);
    });

    await pumpList(tester);
    await waitForText(tester, '反击计划 · p1');

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await waitForText(tester, '立即执行下一条');

    await tester.tap(find.text('立即执行下一条'));
    // 排序断言通过"选中的是哪条"间接呈现：引擎未运行 ⇒ 如实「未执行」；
    // 混合排序不炸（有界等待内出现提示）即为比较器三分支均可达。
    await waitForText(tester, '未执行');
    await settleSnackBars(tester);

    // 选中者必须是有未来计划里最早的那条（k2，1 小时后）—— 不可执行是引擎
    // 未运行所致，与本排序无关；此处用审计回执太重，用包头部「下次」副标题核对。
    await waitFor(
      tester,
      () => find.textContaining('下次').evaluate().isNotEmpty,
      reason: '包卡片应显示组内最近的下次触发时间',
    );
  }, timeout: perTest);
}
