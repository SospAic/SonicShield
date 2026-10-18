import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';
import 'package:sonic_shield/features/tasks/task_list_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// R88 覆盖率长尾补齐：任务清单 + 任务编辑器的**失败路径**与**超限校验**。
///
/// 目标行（R87 lcov 中 `DA:<行>,0`）：
/// - `task_list_screen.dart`：96-97（整包启停 catch）、130-131（整包删除
///   catch）、248/251-252（批量删除 catch + BUG-151 退出选择态）、
///   608-611（包内单条开关 catch）、734/750（长按菜单「立即执行」）。
/// - `task_editor_screen.dart`：1737（随机指令集候选 > 12 的保存前拦截）。
///
/// ## 确认**结构性不可达**（debug 下无输入能进入，故只做标注、不硬凑）
/// - `task_editor_screen.dart:1527` / `1536` / `1759`：`RcStepKind.delay`
///   的三个分支。`_setItems` 只有两个来源：① `_applyTask` 里经
///   [stepKindOfAction] 反推（该函数**永不返回** delay，`ActionConfig`
///   没有时延动作）；② 编辑区的 5 个 `kinds` chip（同样不含 delay）。
///   因此 delay 永远进不了 `_setItems`。
/// - `task_editor_screen.dart:1779` / `1797`：振动区间的"起点 > 终点"拦截。
///   模型构造器有 assert、`fromJson` 的 `_rangeInt/_rangeDouble` 会交换
///   min/max、滑块回调又用 `clamp(_min, …)` 兜底 —— debug 下无法构造出
///   逆序状态（`test/task_editor_vibrate_test.dart` 的 TEV-18 已用源码锁
///   登记同一结论）。
///
/// ## 宿主硬约束（与 `task_list_pack_test.dart` / `task_editor_deep_test.dart` 同款）
/// - 用例体内的 DB 读写一律包 `tester.runAsync`；
/// - 等数据用有界 `waitFor`，禁止 `pumpAndSettle` 当"等数据"；
/// - 每例 90s 护栏。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const perTest = Timeout(Duration(seconds: 90));

  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(inMemoryDatabasePath);
    BackgroundServiceManager.replanHook = () async {};
  });

  tearDown(() async {
    BackgroundServiceManager.replanHook = null;
    BackgroundServiceManager.startHook = null;
    await db.close();
  });

  Future<T> dbRun<T>(WidgetTester tester, Future<T> Function() body) async {
    final r = await tester.runAsync(body);
    return r as T;
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
        trigger: FixedOnceTrigger(at: DateTime(2026, 12, 20, 9, 30)),
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

  Task counter(String planId, String key, String name) => Task(
        id: 'counter:$planId:$key',
        name: name,
        enabled: true,
        triggerType: TriggerType.fixedOnce,
        trigger: FixedOnceTrigger(at: DateTime(2026, 12, 20, 10, 15)),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(
            volumeMin: 0.3,
            volumeMax: 0.5,
            durationSecMin: 3,
            durationSecMax: 5),
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
        overrides: [
          databaseProvider.overrideWith((ref) async => db),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (_, __) => const TaskListScreen(embedded: true),
              ),
              GoRoute(
                path: '/tasks/:id/edit',
                builder: (_, s) =>
                    Scaffold(body: Text('STUB-EDIT:${s.pathParameters['id']}')),
              ),
            ],
          ),
        ),
      ),
    );
    await waitFor(
      tester,
      () =>
          find.byType(ListView).evaluate().isNotEmpty ||
          find.text('还没有任务').evaluate().isNotEmpty,
      reason: '首屏应进入 数据/空态 之一',
    );
  }

  // ══════════════════ 任务清单：失败路径 ══════════════════

  testWidgets('R88T-01 任务包整组停用：落库成功但 replan 抛错 → 如实报错、不谎报成功',
      (tester) async {
    // 覆盖 task_list_screen.dart:96-97（`_packSetEnabled` 的 catch）。
    // 现场：逐条 setEnabled 已写库，最后重排原生闹钟炸了 —— 旧实现会静默
    // 吞掉异常，用户以为"整包停用成功"，实际闹钟仍在。
    await dbRun(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(counter('p1', 'D00', '反击·白天'));
      await repo.upsert(counter('p1', 'N00', '反击·夜间'));
    });

    await pumpList(tester);
    await waitForText(tester, '反击计划 · p1');

    BackgroundServiceManager.replanHook =
        () async => throw StateError('replan-boom');

    final card = find.ancestor(
      of: find.text('反击计划 · p1'),
      matching: find.byType(Card),
    );
    await tester.tap(find.descendant(of: card, matching: find.byType(Switch)));
    await waitForText(tester, '任务包停用失败：');

    // 不许谎报成功。
    expect(find.textContaining('已停用'), findsNothing,
        reason: '失败路径不得再弹"已停用「…」全部 N 条"');

    // 但库是真的改了（失败发生在 replan，不在写库）—— 报错要与之相符。
    final all = await dbRun(tester, () => TaskRepository(db).listAll());
    expect(all.every((t) => !t.enabled), isTrue,
        reason: '逐条 setEnabled 在 replan 之前已完成，库里应全部停用');

    await settleSnackBars(tester);
  }, timeout: perTest);

  testWidgets('R88T-02 任务包整包删除：删完 replan 抛错 → 明说失败，且不掩盖已删事实',
      (tester) async {
    // 覆盖 task_list_screen.dart:130-131（`_packDelete` 的 catch）。
    await dbRun(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(counter('p1', 'D00', '反击·白天'));
      await repo.upsert(counter('p1', 'N00', '反击·夜间'));
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
    await waitForText(tester, '删除「反击计划 · p1」全部 2 条？');

    BackgroundServiceManager.replanHook =
        () async => throw StateError('replan-boom');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('删除')));
    await waitForText(tester, '任务包删除失败：');

    expect(find.textContaining('已删除「反击计划 · p1」'), findsNothing,
        reason: 'replan 失败时不得宣称整包已删成功');

    // 删除本身已落库 —— 报错文案是"重排失败"，界面必须回到真实状态（包消失）。
    final left = await dbRun(tester, () => TaskRepository(db).listAll());
    expect(left, isEmpty, reason: '逐条 delete 在 replan 之前已完成');
    await waitFor(
      tester,
      () => find.text('还没有任务').evaluate().isNotEmpty,
      reason: '失效缓存后任务包卡片应消失，页面回到空态（与服务真实状态一致）',
    );

    await settleSnackBars(tester);
  }, timeout: perTest);

  testWidgets('R88T-03 批量删除：删完 replan 抛错 → 报错并退出选择态（BUG-151）',
      (tester) async {
    // 覆盖 task_list_screen.dart:248 / 251-252（`_batchDelete` 的 catch）。
    await dbRun(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(manual('t1', '甲'));
      await repo.upsert(counter('p1', 'D00', '反击·白天'));
    });

    await pumpList(tester);
    await waitForText(tester, '甲');
    await tester.tap(find.byKey(const Key('task_batch_enter')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('task_batch_select_all')));
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.byKey(const Key('task_batch_delete')));
    await waitForText(tester, '删除 2 个任务？');

    BackgroundServiceManager.replanHook =
        () async => throw StateError('replan-boom');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('删除')));
    await waitForText(tester, '批量删除失败：');

    expect(find.textContaining('已删除 2 个任务'), findsNothing);

    // BUG-151：失败也必须退出选择态 —— 否则界面停在"已选 N 项"，而其中
    // 一部分可能已被删除，下一次操作会对着幽灵 id 反复失败。
    await waitFor(
      tester,
      () => find.textContaining('已选').evaluate().isEmpty,
      reason: '失败后应退出选择态',
    );
    await waitFor(
      tester,
      () => find.text('还没有任务').evaluate().isNotEmpty,
      reason: '退出选择态且库已空 ⇒ 回到空态（而不是继续平铺空列表）',
    );

    final left = await dbRun(tester, () => TaskRepository(db).listAll());
    expect(left, isEmpty);
    await settleSnackBars(tester);
  }, timeout: perTest);

  testWidgets('R88T-04 包内单条开关：replan 抛错 → 就地提示「切换失败」',
      (tester) async {
    // 覆盖 task_list_screen.dart:608-611（`_PackTaskRow` 的 catch）。
    await dbRun(tester, () async {
      final repo = TaskRepository(db);
      await repo.upsert(counter('p1', 'D00', '反击·白天'));
      await repo.upsert(counter('p1', 'N00', '反击·夜间'));
    });

    await pumpList(tester);
    await waitForText(tester, '反击计划 · p1');
    await tester.tap(find.text('反击计划 · p1'));
    await tester.pump();
    await waitForText(tester, '反击·白天');

    final row = find.ancestor(
      of: find.text('反击·白天'),
      matching: find.byType(ListTile),
    );
    final sw = find.descendant(of: row, matching: find.byType(Switch));
    expect(sw, findsOneWidget, reason: '包内行应有一个单条开关');

    BackgroundServiceManager.replanHook =
        () async => throw StateError('replan-boom');
    await tester.tap(sw);
    await waitForText(tester, '切换失败：');

    // 与单任务卡片同口径：落库成功、重排失败，库值仍应是新值（false）。
    final t =
        await dbRun(tester, () => TaskRepository(db).get('counter:p1:D00'));
    expect(t!.enabled, isFalse, reason: 'setEnabled 在 replan 之前已落库');

    await settleSnackBars(tester);
  }, timeout: perTest);

  testWidgets('R88T-05 长按菜单「立即执行」：走 onRunNow，引擎未运行如实回报',
      (tester) async {
    // 覆盖 task_list_screen.dart:734（对话框按钮）与 750（act == 'run' 分支）。
    await dbRun(
        tester, () => TaskRepository(db).upsert(manual('t1', '我的晨间任务')));

    await pumpList(tester);
    await waitForText(tester, '我的晨间任务');

    await tester.longPress(find.text('我的晨间任务'));
    await tester.pump();
    await waitForText(tester, '立即执行');

    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('立即执行')));
    // 引擎未运行 ⇒ 必须如实告知「未执行」，不许假成功。
    await waitForText(tester, '未执行');

    // 走的是"执行"，不是复制/删除：库不该多一条、也不该少一条。
    final all = await dbRun(tester, () => TaskRepository(db).listAll());
    expect(all.length, 1);
    expect(all.single.id, 't1');
    await settleSnackBars(tester);
  }, timeout: perTest);

  // ══════════════════ 编辑器：随机指令集超限 ══════════════════

  testWidgets('R88T-06 随机指令集：候选总数 > 12 → 保存前拦下并提示，不落库',
      (tester) async {
    // 覆盖 task_editor_screen.dart:1737。
    // 5 个不可编辑候选（复合动作 → `_setPreserved`）+ 手工再加 8 个
    // 「震动」（chip 在 `_setItems.length < 8` 时才渲染）⇒ 13 > 12。
    await dbRun(tester, () async {
      await TaskRepository(db).upsert(Task(
        id: 'r88-set',
        name: '随机集超限',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 7, minute: 30)),
        actionType: ActionType.randomFrom,
        action: ActionSetAction(candidates: [
          for (var i = 0; i < 5; i++)
            const ActionSetCandidate(
              weight: 3,
              action: CompositeAction(
                primary: PlayAudioAction(),
                prefixNotify: NotifyAction(title: 't', body: 'b'),
              ),
            ),
        ]),
        assetIds: const [],
        cooldownSec: 0,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ));
    });

    tester.view.physicalSize = const Size(1080, 12000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => db),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
                    builder: (_) => const TaskEditorScreen(taskId: 'r88-set'))),
                child: const Text('HOST-OPEN'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('HOST-OPEN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await waitFor(
      tester,
      () => find.text('任务名称').evaluate().isNotEmpty,
      reason: '按 id 读库后编辑器应渲染完成（不再是加载态）',
    );
    await waitForText(tester, '另有 5 个子动作');

    final addVibrate = find.widgetWithText(ActionChip, '＋震动');
    for (var i = 0; i < 8; i++) {
      await tester.ensureVisible(addVibrate);
      await tester.pump();
      await tester.tap(addVibrate);
      await tester.pump();
    }
    expect(addVibrate, findsNothing,
        reason: '达到 8 个后添加 chip 应收起（`_setItems.length < 8` 门）');
    expect(find.text('权重 3'), findsNWidgets(8),
        reason: '8 次添加应真的产生 8 个候选行（5 + 8 = 13 > 12）');

    await tester.tap(find.text('保存任务'));
    await tester.pump();
    await tester.pump();
    await waitForText(tester, '随机指令集最多 12 个候选动作');

    // 校验失败 ⇒ 不 pop、不落库（原 5 个候选原样保留）。
    expect(find.text('保存任务'), findsOneWidget);
    final saved = await dbRun(tester, () => TaskRepository(db).get('r88-set'));
    final action = saved!.action;
    expect(action, isA<ActionSetAction>());
    expect((action as ActionSetAction).candidates.length, 5,
        reason: '保存被拦下，库里的候选数不能变');

    await settleSnackBars(tester);
  }, timeout: perTest);
}
