import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sonic_shield/data/db/app_database.dart';
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
}
