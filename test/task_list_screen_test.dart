import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/tasks/task_list_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

/// 任务列表页（`TaskListScreen`）的宿主回归锁。
///
/// ## 这个页面为什么值得上锁
///
/// 它是「任务」这件事对用户唯一可见的面：**开关写没写进库**、**"跳过下一次"
/// 到底跳没跳**、**长按删除是不是只删了界面**，全在这里发生。而且它的失败
/// 形态是静默的 —— 开关回弹、SnackBar 说"已跳过"但库里还是 pending、
/// 删除后 occurrence 残留（`ON DELETE CASCADE` 在 `foreign_keys` 未开时
/// 不会生效）。用户看不出，只有下一轮调度跑错才暴露。
///
/// ## 宿主硬约束（全部实测踩过）
///
/// 1. **开库放 `setUp`**（fake async 之外）。
/// 2. **⚠️ 用例体里的任何 DB 操作都必须包在 `tester.runAsync` 里**。
///    `databaseFactoryFfi` 把 SQLite 放在**后台 isolate** 跑，往返是真实异步；
///    而 `testWidgets` 的用例体跑在 `FakeAsync` 里 —— 直接
///    `await repo().upsert(...)` **会永久挂死**（本次实测：TLS-02 卡满
///    10 分钟超时，后续 18 个用例全部级联失败，整轮 10m21s）。
///    `dbRead`/`dbWrite` 两个包装器就是干这个的。
/// 3. **⚠️ 不要用"固定轮数 drain"去等一个异步重读**。
///    `ref.invalidate()` 之后的重读**不是同步的**：`AsyncValue` 会先带着
///    旧值，UI 要等新读完成才变。固定 `drain(rounds: 5)` 会**时快时慢**
///    （TLS-03b 就是这么假红的：库已经是 `false`，界面还是 `true`）。
///    统一用 `waitFor(cond)` —— 有界轮询、超时**显式 fail**，比"多 pump 几次"
///    既确定又不会把真缺陷拖成偶发。
/// 4. **禁止 `pumpAndSettle` 当"等数据"用**。本页加载态是
///    `CircularProgressIndicator`（无限动画）→ 数据没到就 `pumpAndSettle`
///    是**超时**，不是失败得清楚。
/// 5. **收尾必须推掉 SnackBar 计时**（默认 4s 自动消失 Timer），否则
///    收尾判 "A Timer is still pending"。
/// 6. **每个用例加 `timeout`**：宿主测试挂死时默认超时是 **10 分钟**，
///    一个用例挂住就吃掉整轮迭代时间。显式给 90 秒，让挂死快速暴露。
///
/// ## 刻意不覆盖（设备层）
///
/// 不断言 `BackgroundServiceManager.instance.replan()` 的真实效果 —— 它走
/// `flutter_background_service` 平台通道，宿主没有另一侧。这里只注入
/// `replanHook` 短路（测试缝），把"落库"这层锁死；"replan 真的重排了原生
/// 闹钟"由设备层负责。
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
    await db.close();
  });

  // ───────────────────────── 夹具 ─────────────────────────

  /// 用例体里的**读**（见文件头第 2 条）。
  Future<T> dbRead<T>(WidgetTester tester, Future<T> Function() body) async {
    final r = await tester.runAsync(body);
    return r as T;
  }

  /// 用例体里的**写**（见文件头第 2 条）。
  Future<void> dbWrite(
      WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(body);
  }

  /// 有界轮询等待（见文件头第 3 条）：每轮让**真实事件循环**跑一次再 pump。
  ///
  /// 超时**显式 fail**，而不是悄悄放行 —— 否则"等不到"会退化成"没测"。
  /// ⚠️ `maxRounds` 是**上限不是断言**：提高它只给真实 IO 更多轮次，不削弱检查
  /// （依据：2026-09-22 第二十九轮负载 100% 下的同类假红）。
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

  /// 等某段文案出现（SnackBar / 对话框 / 新页面）。
  Future<void> waitForText(WidgetTester tester, String substring) => waitFor(
        tester,
        () => find.textContaining(substring).evaluate().isNotEmpty,
        reason: '应出现含「$substring」的文案',
      );

  /// 把 SnackBar 的自动消失计时推过去，避免收尾留下 pending Timer。
  Future<void> settleSnackBars(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Task makeTask(
    String id, {
    bool enabled = true,
    String? name,
    TriggerType triggerType = TriggerType.dailyAt,
    ActionType actionType = ActionType.playAudio,
    int priority = 2,
  }) {
    final now = DateTime.now();
    return Task(
      id: id,
      name: name ?? '任务$id',
      enabled: enabled,
      triggerType: triggerType,
      trigger: const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)),
      actionType: actionType,
      action: const PlayAudioAction(volumeMin: 0.3, volumeMax: 0.7),
      assetIds: const ['a1'],
      cooldownSec: 300,
      quietPolicy: QuietPolicy.shift,
      priority: priority,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> addTask(WidgetTester tester, Task t) =>
      dbWrite(tester, () => TaskRepository(db).upsert(t));

  Future<void> addOcc(WidgetTester tester, PlannedOccurrence o) =>
      dbWrite(tester, () => OccurrenceRepository(db).commitAll([o]));

  /// 读某条任务**自己那一行**上的开关值。
  ///
  /// ⚠️ 刻意**不按索引**取 `widgetList<Switch>()[i]`：`listAll` 的排序是
  /// `priority DESC, created_at DESC`，同一毫秒创建、同优先级的任务之间是
  /// 平局，返回顺序**未定义**（实测 TLS-03 第一版就因此假红）。
  /// 按"名字所在 ListTile 内的 Switch"取值，顺带锁住一条真不变量：
  /// **开关必须挂在自己那条任务上** —— 挂错行 = 关掉别人的任务。
  bool switchOf(WidgetTester tester, String name) {
    final tile =
        find.ancestor(of: find.text(name), matching: find.byType(ListTile));
    return tester
        .widget<Switch>(find.descendant(of: tile, matching: find.byType(Switch)))
        .value;
  }

  /// 起一个带真实 `GoRouter` 的宿主（`context.push` 需要 `InheritedGoRouter`）。
  ///
  /// 二级路由用**桩页**而非真实编辑器：本文件测的是列表页发出的**导航意图**
  /// （去了哪个路径、带没带 id），真实编辑器由 `task_editor_*_test.dart` 负责。
  Future<GoRouter> pumpList(
    WidgetTester tester, {
    bool embedded = false,
    bool failDb = false,
    Size viewport = const Size(1200, 4000),
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => TaskListScreen(embedded: embedded),
        ),
        GoRoute(
          path: '/tasks/new',
          builder: (_, __) => const Scaffold(body: Text('STUB-NEW')),
        ),
        GoRoute(
          path: '/tasks/:id/edit',
          builder: (_, s) =>
              Scaffold(body: Text('STUB-EDIT:${s.pathParameters['id']}')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async {
            if (failDb) throw StateError('boom');
            return db;
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    // 首屏：等到"数据分支"真的渲染出来，而不是盲 pump 几次。
    await waitFor(
      tester,
      () =>
          find.byType(ListView).evaluate().isNotEmpty ||
          find.text('还没有任务').evaluate().isNotEmpty ||
          find.textContaining('加载失败：').evaluate().isNotEmpty,
      reason: '首屏应进入 数据/空态/失败 之一',
    );
    return router;
  }

  // ───────────────────── TLS-01 空态 ─────────────────────

  group('TLS-01 空态', () {
    testWidgets('TLS-01 无任务 → 给出空态与能力说明，而不是白屏', (tester) async {
      await pumpList(tester);

      expect(find.text('还没有任务'), findsOneWidget);
      // 空态必须告诉用户"支持什么"，否则用户不知道下一步能做什么。
      expect(find.textContaining('固定定时'), findsOneWidget);
      expect(find.textContaining('随机窗口'), findsOneWidget);
      expect(find.byType(ListView), findsNothing,
          reason: '空列表不应构建 ListView');
    }, timeout: perTest);

    testWidgets('TLS-01b 空态仍有「新建任务」入口（否则用户无路可走）',
        (tester) async {
      await pumpList(tester);

      expect(find.widgetWithText(FloatingActionButton, '新建任务'),
          findsOneWidget);
    }, timeout: perTest);
  });

  // ─────────────────── TLS-02 列表渲染 ───────────────────

  group('TLS-02 列表渲染', () {
    testWidgets('TLS-02 逐条渲染名称 + 「触发 · 动作」组合文案', (tester) async {
      await addTask(tester, makeTask('t1', name: '早安提醒'));
      await addTask(
          tester,
          makeTask('t2',
              name: '夜间取证',
              triggerType: TriggerType.soundTriggered,
              actionType: ActionType.recordEvidence));
      await pumpList(tester);

      expect(find.text('还没有任务'), findsNothing);
      expect(find.text('早安提醒'), findsOneWidget);
      expect(find.text('夜间取证'), findsOneWidget);
      // 组合文案要两个 label 都在，且用 ' · ' 连接（改了分隔符也要红）。
      expect(
          find.text(
              '${TriggerType.dailyAt.label} · ${ActionType.playAudio.label}'),
          findsOneWidget);
      expect(
          find.text('${TriggerType.soundTriggered.label} · '
              '${ActionType.recordEvidence.label}'),
          findsOneWidget);
    }, timeout: perTest);

    testWidgets('TLS-02b 有未来计划 → 显示「下次：MM-DD HH:MM」', (tester) async {
      await addTask(tester, makeTask('t1'));
      final fire = DateTime.now().add(const Duration(days: 2));
      await addOcc(
          tester,
          PlannedOccurrence(
              id: 'o1',
              taskId: 't1',
              fireAt: fire,
              status: OccurrenceStatus.pending));
      await pumpList(tester);

      final expected = '下次：${fire.month.toString().padLeft(2, '0')}-'
          '${fire.day.toString().padLeft(2, '0')} '
          '${fire.hour.toString().padLeft(2, '0')}:'
          '${fire.minute.toString().padLeft(2, '0')}';
      expect(find.text(expected), findsOneWidget);
    }, timeout: perTest);

    testWidgets('TLS-02c 无未来计划 → 不显示「下次」行（不写"未知"占位）',
        (tester) async {
      await addTask(tester, makeTask('t1'));
      await pumpList(tester);

      expect(find.textContaining('下次：'), findsNothing);
    }, timeout: perTest);
  });

  // ─────────────────── TLS-03 启停开关 ───────────────────

  group('TLS-03 启停开关', () {
    testWidgets('TLS-03 开关初始值反映落库的 enabled（且挂在自己那一行）',
        (tester) async {
      await addTask(tester, makeTask('on', name: '开着的'));
      await addTask(tester, makeTask('off', name: '关着的', enabled: false));
      await pumpList(tester);

      expect(find.byType(Switch), findsNWidgets(2));
      expect(switchOf(tester, '开着的'), isTrue);
      expect(switchOf(tester, '关着的'), isFalse);
    }, timeout: perTest);

    testWidgets('TLS-03b 关掉开关 → **真的落库**（不是只改界面）', (tester) async {
      await addTask(tester, makeTask('t1', name: '唯一的'));
      await pumpList(tester);

      await tester.tap(find.byType(Switch));
      // 先等界面回落（见文件头第 3 条），再断言库 —— 两件事都要成立。
      await waitFor(tester, () => !switchOf(tester, '唯一的'),
          reason: '关掉后开关应变为 false');

      final got = await dbRead(tester, () => TaskRepository(db).get('t1'));
      expect(got!.enabled, isFalse,
          reason: '开关必须写进库；只改内存会让重启后"自己又开了"');
    }, timeout: perTest);

    testWidgets('TLS-03c 打开开关 → 同样落库（双向都要锁）', (tester) async {
      await addTask(tester, makeTask('t1', name: '唯一的', enabled: false));
      await pumpList(tester);

      await tester.tap(find.byType(Switch));
      await waitFor(tester, () => switchOf(tester, '唯一的'),
          reason: '打开后开关应变为 true');

      final got = await dbRead(tester, () => TaskRepository(db).get('t1'));
      expect(got!.enabled, isTrue);
    }, timeout: perTest);
  });

  // ─────────────────── TLS-04 跳过下一次 ───────────────────

  group('TLS-04 跳过下一次', () {
    testWidgets('TLS-04 只有启用中的任务才显示「跳过下一次」按钮', (tester) async {
      await addTask(tester, makeTask('on', name: '开着的'));
      await addTask(tester, makeTask('off', name: '关着的', enabled: false));
      await pumpList(tester);

      // 关着的任务上没有跳过按钮 —— 它本来就不会触发，跳过是无意义操作。
      expect(find.byIcon(Icons.skip_next_outlined), findsOneWidget);
    }, timeout: perTest);

    testWidgets('TLS-04b 有 pending 计划 → 跳过把该条标记为 skipped（落库）',
        (tester) async {
      await addTask(tester, makeTask('t1'));
      await addOcc(
          tester,
          PlannedOccurrence(
              id: 'o1',
              taskId: 't1',
              fireAt: DateTime.now().add(const Duration(days: 1)),
              status: OccurrenceStatus.pending));
      await pumpList(tester);

      await tester.tap(find.byIcon(Icons.skip_next_outlined));
      await waitForText(tester, '已跳过「任务t1」的下一次触发');

      // 关键：必须验证**库里那条计划的 status 真的变了**，
      // 而不是只弹了个 SnackBar。跳过是"改审计事实"，不是 UI 状态。
      final rows = await dbRead(
          tester,
          () => db.db.query('occurrences', where: 'id = ?', whereArgs: ['o1']));
      expect(rows.first['status'], OccurrenceStatus.skipped.name);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('TLS-04c 无 pending 计划 → 如实说「没有待执行的下一次触发」',
        (tester) async {
      await addTask(tester, makeTask('t1'));
      await pumpList(tester);

      await tester.tap(find.byIcon(Icons.skip_next_outlined));
      await waitForText(tester, '没有待执行的下一次触发');

      // 不能静默成功、也不能谎报"已跳过"。
      expect(find.textContaining('已跳过'), findsNothing);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('TLS-04d 计划已过期（fire_at < now）→ 不算"下一次"，如实报无',
        (tester) async {
      await addTask(tester, makeTask('t1'));
      await addOcc(
          tester,
          PlannedOccurrence(
              id: 'past',
              taskId: 't1',
              fireAt: DateTime.now().subtract(const Duration(hours: 1)),
              status: OccurrenceStatus.pending));
      await pumpList(tester);

      await tester.tap(find.byIcon(Icons.skip_next_outlined));
      await waitForText(tester, '没有待执行的下一次触发');

      // 过期那条不能被误标成 skipped —— 它是"待补执行"的历史，不是"下一次"。
      final rows = await dbRead(
          tester,
          () =>
              db.db.query('occurrences', where: 'id = ?', whereArgs: ['past']));
      expect(rows.first['status'], OccurrenceStatus.pending.name);
      await settleSnackBars(tester);
    }, timeout: perTest);
  });

  // ─────────────────── TLS-05 导航意图 ───────────────────

  group('TLS-05 导航', () {
    testWidgets('TLS-05 点卡片 → 去 /tasks/:id/edit 且**带上 id**', (tester) async {
      await addTask(tester, makeTask('abc-1', name: '可点的'));
      await pumpList(tester);

      await tester.tap(find.text('可点的'));
      // 断言落在 id 上：只断言"跳到了编辑器"会漏掉"打开了别人的任务"。
      await waitForText(tester, 'STUB-EDIT:abc-1');
    }, timeout: perTest);

    testWidgets('TLS-05b 点「新建任务」→ 去 /tasks/new（不带 id）', (tester) async {
      await pumpList(tester);

      await tester.tap(find.widgetWithText(FloatingActionButton, '新建任务'));
      await waitForText(tester, 'STUB-NEW');
    }, timeout: perTest);

    testWidgets('TLS-05c 从编辑器返回 → 列表**重新读库**（显示最新数据）',
        (tester) async {
      await addTask(tester, makeTask('t1', name: '旧名字'));
      final router = await pumpList(tester);

      await tester.tap(find.text('旧名字'));
      await waitForText(tester, 'STUB-EDIT:t1');

      // 模拟"在编辑器里改了名字"（真机上是编辑器写的库）。
      await addTask(tester, makeTask('t1', name: '新名字'));
      router.pop();
      await waitFor(tester, () => find.text('新名字').evaluate().isNotEmpty,
          reason: '返回后必须重读库；否则用户改完名字回到列表还是旧的');
    }, timeout: perTest);

    testWidgets('TLS-05d 从「新建」返回 → 列表**重新读库**（新任务立刻出现）',
        (tester) async {
      final router = await pumpList(tester);
      expect(find.text('还没有任务'), findsOneWidget);

      await tester.tap(find.widgetWithText(FloatingActionButton, '新建任务'));
      await waitForText(tester, 'STUB-NEW');

      await addTask(tester, makeTask('t9', name: '刚建的'));
      router.pop();
      await waitFor(tester, () => find.text('刚建的').evaluate().isNotEmpty,
          reason: '返回后必须重读库；否则新建完回到列表看不到刚建的任务');
    }, timeout: perTest);
  });

  // ─────────────────── TLS-08 下拉刷新 ───────────────────

  group('TLS-08 下拉刷新', () {
    testWidgets('TLS-08 下拉刷新 → 重新读库（不是只播动画）', (tester) async {
      // ⚠️ 用**小视口**让列表可滚动：默认视口 4000px 高，要灌 80 条才撑满，
      // 而 `taskListProvider` 对每条任务都要单独查一次 pending 计划（N+1），
      // 80 条 = 80 次 isolate 往返 → 直接把 `waitFor` 的轮数预算耗尽（实测超时）。
      final many = <Task>[for (var i = 0; i < 20; i++) makeTask('t$i', name: '任务$i')];
      await dbWrite(tester, () => TaskRepository(db).upsertMany(many));
      await pumpList(tester, viewport: const Size(400, 800));

      // 刷新之后才写进库的那条，只有真的重读才会出现。
      // priority 给高值 → 排序确定性地排在最前（`listAll` 是 priority DESC），
      // 不依赖 created_at（同一毫秒创建会平局）。
      await addTask(tester, makeTask('t99', name: '刷新后才有', priority: 9));

      await tester.fling(find.byType(ListView), const Offset(0, 400), 1200);
      await waitFor(
          tester, () => find.text('刷新后才有').evaluate().isNotEmpty,
          reason: '下拉刷新必须真的重读库，而不是只播一个转圈动画');
    }, timeout: perTest);
  });

  // ─────────────────── TLS-06 长按菜单 ───────────────────

  group('TLS-06 长按菜单', () {
    testWidgets('TLS-06 长按 → 三个选项都出现（复制/删除/取消）', (tester) async {
      await addTask(tester, makeTask('t1', name: '长按我'));
      await pumpList(tester);

      await tester.longPress(find.text('长按我'));
      await waitForText(tester, '复制任务');

      expect(find.text('「长按我」'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      // 对话框必须说明"复制出来的是停用的"，否则用户以为副本会立刻开始响。
      expect(find.textContaining('默认停用'), findsOneWidget);
    }, timeout: perTest);

    testWidgets('TLS-06b 「取消」→ 库里不变（不多也不少）', (tester) async {
      await addTask(tester, makeTask('t1', name: '长按我'));
      await pumpList(tester);

      await tester.longPress(find.text('长按我'));
      await waitForText(tester, '复制任务');
      await tester.tap(find.text('取消'));
      await waitFor(tester, () => find.text('复制任务').evaluate().isEmpty,
          reason: '取消后对话框应关闭');

      final all = await dbRead(tester, () => TaskRepository(db).listAll());
      expect(all.length, 1);
      expect(all.single.id, 't1');
    }, timeout: perTest);

    testWidgets('TLS-06c 「复制任务」→ 新副本落库且**默认停用**', (tester) async {
      await addTask(tester, makeTask('t1', name: '原件'));
      await pumpList(tester);

      await tester.longPress(find.text('原件'));
      await waitForText(tester, '复制任务');
      await tester.tap(find.text('复制任务'));
      await waitForText(tester, '已创建副本');

      final all = await dbRead(tester, () => TaskRepository(db).listAll());
      expect(all.length, 2, reason: '应新增一条副本，原件保留');
      final copy = all.firstWhere((t) => t.id != 't1');
      expect(copy.name, '原件（副本）');
      expect(copy.enabled, isFalse,
          reason: '副本必须默认停用，否则复制即意外触发');
      // 配置要整份带走，不能只复制名字。
      expect(copy.triggerType, TriggerType.dailyAt);
      expect(copy.actionType, ActionType.playAudio);
      expect(copy.assetIds, ['a1']);
      expect(copy.quietPolicy, QuietPolicy.shift);
      expect(copy.priority, 2);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('TLS-06d 「删除」→ 任务与其计划**一并**清掉（不留孤儿 occurrence）',
        (tester) async {
      await addTask(tester, makeTask('t1', name: '要删的'));
      await addOcc(
          tester,
          PlannedOccurrence(
              id: 'o1',
              taskId: 't1',
              fireAt: DateTime.now().add(const Duration(days: 1)),
              status: OccurrenceStatus.pending));
      await pumpList(tester);

      await tester.longPress(find.text('要删的'));
      await waitForText(tester, '复制任务');
      await tester.tap(find.text('删除'));
      // 列表刷新后那条卡片应消失 —— 这本身就是"真的删了"的界面证据。
      await waitFor(tester, () => find.text('要删的').evaluate().isEmpty,
          reason: '删除后该任务卡片应从列表消失');

      final gone = await dbRead(tester, () => TaskRepository(db).get('t1'));
      expect(gone, isNull);
      // 孤儿计划是最阴的缺陷：任务没了，计划还在，引擎仍会"替不存在的人响"。
      final occ = await dbRead(
          tester,
          () => db.db.query('occurrences',
              where: 'task_id = ?', whereArgs: ['t1']));
      expect(occ, isEmpty, reason: '删除必须级联清计划，不能只删任务行');
    }, timeout: perTest);
  });

  // ─────────────────── TLS-07 外壳与失败 ───────────────────

  group('TLS-07 外壳与失败', () {
    testWidgets('TLS-07 embedded=false → 自带 AppBar「自动化任务」', (tester) async {
      await pumpList(tester);

      expect(find.widgetWithText(AppBar, '自动化任务'), findsOneWidget);
    }, timeout: perTest);

    testWidgets('TLS-07b embedded=true → 不重复 AppBar（分组页已有一层）',
        (tester) async {
      await pumpList(tester, embedded: true);

      expect(find.byType(AppBar), findsNothing,
          reason: '嵌在分组页里再带 AppBar 会出现双层标题');
    }, timeout: perTest);

    testWidgets('TLS-07c 加载失败 → 明说「加载失败：<原因>」，不留空白页',
        (tester) async {
      await pumpList(tester, failDb: true);

      expect(find.textContaining('加载失败：'), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
      expect(find.text('还没有任务'), findsNothing,
          reason: '失败不能伪装成"没有任务"——用户会以为数据丢了');
    }, timeout: perTest);
  });

  // ══════════════════ TLS-08 覆盖率冲刺（第六十一轮） ══════════════════
  //
  // TLS-03b/03c 覆盖的是开关的**成功**路径；失败路径（重排原生闹钟这一步炸了）
  // 此前一行都没被执行过 —— 而它正是"开关看起来关掉了，重启又自己开了"的现场。

  group('TLS-08 开关失败路径', () {
    testWidgets('BK-TLS-01 重排失败 → 开关必须回落并**明说原因**（不许静默）',
        (tester) async {
      await addTask(tester, makeTask('t1', name: '唯一的'));
      await pumpList(tester);

      // 落库成功、重排原生闹钟失败：这是真机上最常见的中间态
      // （后台服务被杀 / 精确闹钟权限被撤）。
      BackgroundServiceManager.replanHook =
          () async => throw StateError('replan-boom');

      await tester.tap(find.byType(Switch));
      await waitForText(tester, '切换失败：');

      // ⚠️ 断言必须落在**开关真的回落**这一点上：只弹提示、开关仍显示"已关闭"
      // 会让用户以为设置生效了，而库/服务其实没跟上。
      await waitFor(tester, () => switchOf(tester, '唯一的'),
          reason: '失败后开关必须回到与服务真实状态一致的取值（这里库仍是 enabled=true）');

      await settleSnackBars(tester);
    }, timeout: perTest);
  });

  // ══════════════════ TLS-09 批量操作（v2.x 新增） ══════════════════
  //
  // 批量动作是**一次改多条**的高危面：漏写一条 = "批量停用了 5 条，其实只停了 3 条"；
  // 只改界面不落库 = 重启后全部复活；失败静默 = 用户以为删干净了其实没有。
  // 所以这一组的铁律与单条一致：**真的落库 + 失败必须可见**。
  group('TLS-09 批量操作', () {
    Finder batchKey(String k) => find.byKey(Key(k));

    testWidgets('TLS-09 普通态有「批量管理」入口；进入后出现工具条且 FAB 让位',
        (tester) async {
      await addTask(tester, makeTask('t1', name: '甲'));
      await pumpList(tester, embedded: true);

      expect(batchKey('task_batch_enter'), findsOneWidget);
      expect(batchKey('task_batch_select_all'), findsNothing);

      await tester.tap(batchKey('task_batch_enter'));
      await tester.pump();

      expect(batchKey('task_batch_select_all'), findsOneWidget);
      expect(find.text('已选 0 项'), findsOneWidget);
      // 选择态不应还能新建 —— 避免"勾着任务却弹出新建页"。
      // ⚠️ FAB 的退场走 Scaffold 的缩放动画，单次 pump 还在树上，须等其真的消失。
      await waitFor(
          tester,
          () => find
              .widgetWithText(FloatingActionButton, '新建任务')
              .evaluate()
              .isEmpty,
          reason: '进入选择态后 FAB 应让位（退场动画结束后不在树上）');
    }, timeout: perTest);

    testWidgets('TLS-09b 多选：点条目勾选/取消，计数随之更新', (tester) async {
      await addTask(tester, makeTask('t1', name: '甲'));
      await addTask(tester, makeTask('t2', name: '乙'));
      await pumpList(tester, embedded: true);

      await tester.tap(batchKey('task_batch_enter'));
      await tester.pump();

      await tester.tap(find.text('甲'));
      await tester.pump();
      expect(find.text('已选 1 项'), findsOneWidget);

      await tester.tap(find.text('乙'));
      await tester.pump();
      expect(find.text('已选 2 项'), findsOneWidget);

      await tester.tap(find.text('乙')); // 再点一次 = 取消勾选
      await tester.pump();
      expect(find.text('已选 1 项'), findsOneWidget);
    }, timeout: perTest);

    testWidgets('TLS-09c 全选：一键勾满；再点变「取消全选」并清空', (tester) async {
      for (var i = 0; i < 3; i++) {
        await addTask(tester, makeTask('t$i', name: '任务$i'));
      }
      await pumpList(tester, embedded: true);
      await tester.tap(batchKey('task_batch_enter'));
      await tester.pump();

      await tester.tap(batchKey('task_batch_select_all'));
      await tester.pump();
      expect(find.text('已选 3 项'), findsOneWidget);
      expect(find.text('取消全选'), findsOneWidget);

      await tester.tap(batchKey('task_batch_select_all'));
      await tester.pump();
      expect(find.text('已选 0 项'), findsOneWidget);
    }, timeout: perTest);

    testWidgets('TLS-09d 批量停用 → **真的落库**（不是只改界面）', (tester) async {
      await addTask(tester, makeTask('t1', name: '甲'));
      await addTask(tester, makeTask('t2', name: '乙'));
      await pumpList(tester, embedded: true);
      await tester.tap(batchKey('task_batch_enter'));
      await tester.pump();
      await tester.tap(batchKey('task_batch_select_all'));
      await tester.pump();

      await tester.tap(batchKey('task_batch_disable'));
      await waitForText(tester, '已停用 2 个任务');

      final all = await dbRead(tester, () => TaskRepository(db).listAll());
      expect(all.every((t) => !t.enabled), isTrue,
          reason: '批量停用必须写进库；只改内存会让重启后"自己又开了"');
      // 操作完成应自动退出选择态。
      expect(batchKey('task_batch_select_all'), findsNothing);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('TLS-09e 批量启用 → 落库（双向都要锁）', (tester) async {
      await addTask(tester, makeTask('t1', name: '甲', enabled: false));
      await addTask(tester, makeTask('t2', name: '乙', enabled: false));
      await pumpList(tester, embedded: true);
      await tester.tap(batchKey('task_batch_enter'));
      await tester.pump();
      await tester.tap(batchKey('task_batch_select_all'));
      await tester.pump();

      await tester.tap(batchKey('task_batch_enable'));
      await waitForText(tester, '已启用 2 个任务');

      final all = await dbRead(tester, () => TaskRepository(db).listAll());
      expect(all.every((t) => t.enabled), isTrue);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('TLS-09f 批量删除 → 二次确认后任务与计划**一并**清掉',
        (tester) async {
      await addTask(tester, makeTask('t1', name: '甲'));
      await addTask(tester, makeTask('t2', name: '乙'));
      await addOcc(
          tester,
          PlannedOccurrence(
              id: 'o1',
              taskId: 't1',
              fireAt: DateTime.now().add(const Duration(days: 1)),
              status: OccurrenceStatus.pending));
      await addOcc(
          tester,
          PlannedOccurrence(
              id: 'o2',
              taskId: 't2',
              fireAt: DateTime.now().add(const Duration(days: 1)),
              status: OccurrenceStatus.pending));
      await pumpList(tester, embedded: true);
      await tester.tap(batchKey('task_batch_enter'));
      await tester.pump();
      await tester.tap(batchKey('task_batch_select_all'));
      await tester.pump();

      await tester.tap(batchKey('task_batch_delete'));
      await waitForText(tester, '删除 2 个任务？');
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('删除')));
      await waitForText(tester, '已删除 2 个任务');

      final left = await dbRead(tester, () => TaskRepository(db).listAll());
      expect(left, isEmpty);
      // 孤儿计划是最阴的缺陷：任务没了、计划还在，引擎仍会"替不存在的人响"。
      final occ = await dbRead(tester, () => db.db.query('occurrences'));
      expect(occ, isEmpty, reason: '删除必须级联清计划，不能留孤儿 occurrence');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('TLS-09g 取消删除 → 库不变，且仍留在选择态', (tester) async {
      await addTask(tester, makeTask('t1', name: '甲'));
      await pumpList(tester, embedded: true);
      await tester.tap(batchKey('task_batch_enter'));
      await tester.pump();
      await tester.tap(batchKey('task_batch_select_all'));
      await tester.pump();

      await tester.tap(batchKey('task_batch_delete'));
      await waitForText(tester, '删除 1 个任务？');
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('取消')));
      await tester.pump();
      await tester.pump();

      final all = await dbRead(tester, () => TaskRepository(db).listAll());
      expect(all.length, 1);
      expect(all.single.id, 't1');
      // 取消后仍留在选择态 —— 用户可能只是换了主意，不该被踢出去。
      expect(batchKey('task_batch_select_all'), findsOneWidget);
    }, timeout: perTest);

    testWidgets('TLS-09h 选择态隐藏单条动作（开关/跳过），避免误改某一条',
        (tester) async {
      await addTask(tester, makeTask('t1', name: '甲'));
      await pumpList(tester, embedded: true);
      expect(find.byType(Switch), findsOneWidget);

      await tester.tap(batchKey('task_batch_enter'));
      await tester.pump();

      expect(find.byType(Switch), findsNothing);
      expect(find.byIcon(Icons.skip_next_outlined), findsNothing);
    }, timeout: perTest);

    testWidgets('TLS-09i 批量动作失败（重排炸）→ 如实报错，不许静默成功',
        (tester) async {
      await addTask(tester, makeTask('t1', name: '甲'));
      await pumpList(tester, embedded: true);
      await tester.tap(batchKey('task_batch_enter'));
      await tester.pump();
      await tester.tap(batchKey('task_batch_select_all'));
      await tester.pump();

      BackgroundServiceManager.replanHook =
          () async => throw StateError('replan-boom');
      await tester.tap(batchKey('task_batch_disable'));
      await waitForText(tester, '批量停用失败：');

      // 不许谎报成功。
      expect(find.textContaining('已停用'), findsNothing);
      await settleSnackBars(tester);
    }, timeout: perTest);
  });
}
