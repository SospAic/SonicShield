import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/guard/guard_orchestration.dart';
import 'package:sonic_shield/features/guard/guard_screen.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

import 'support/permission_stub.dart';

/// 守卫页（`GuardScreen`）宿主测试 —— 第三十六轮续六新建，**第三十七轮修复**。
///
/// ## 为什么此前零专属覆盖
/// 本页 158 可执行行里 87 行未覆盖，且 `grep -rln "GuardScreen" test/` **零命中** ——
/// 全项目没有任何测试引用过它。未覆盖面集中在**交互回调**：三个灵敏度 Slider 的
/// `onChanged`/`onChangeEnd`、编排的延时 Slider 与 `SegmentedButton`、
/// 候选任务 `CheckboxListTile`、以及守卫开关 `_onToggleGuard`。
///
/// ## ⚠️ 第三十七轮修复的 P0：本文件首版**挂死整个功能层**
///
/// 首版（2026-09-26 23:17）在用例体里直接 `await db.query(...)` 并用
/// `pumpAndSettle()` 等数据 —— 踩了本项目**已被写进测试文档的**那条硬约束：
///
/// > `databaseFactoryFfi` 把 SQLite 放在**后台 isolate** 跑，往返是**真实异步**；
/// > 而 `testWidgets` 的用例体跑在 `FakeAsync` 里 ⇒ 直接 `await` 库操作
/// > **永久挂死**（`pumpAndSettle` 要等 10 分钟超时才吐错）。
/// > 出处：`test/task_list_screen_test.dart` / `settings_screen_test.dart` 的类注释。
///
/// 实测证据（`_pt/l7.txt`，有界单跑 + expanded reporter）：
/// ```
/// 00:00 +0: loading test/guard_screen_test.dart
/// 00:00 +0: GS-01 …改阈值 → 文案随真实状态变化，并防抖落库
/// TEST_RC=124        ← `--timeout 30s` 都没能打断，硬超时 240s 才终止
/// ```
/// 且 `--timeout 30s` **不生效**：用例体卡在 fake-async 区内，真实计时器没机会跑。
/// 因为该文件从未被验证过（上一轮的 L5 触发被计划任务单槽静默吞掉、无产物），
/// 它一直躺在树里 ⇒ **整个功能层再也跑不完**，门禁既不是绿也不是红，是**挂死**。
///
/// ## 本版遵守的六条宿主约束（与 task_list / settings 同源）
/// 1. **开库放 `setUp`**（FakeAsync 之外）；
/// 2. **用例体里任何 DB 操作都包 `tester.runAsync`**；
/// 3. **不用固定轮数当断言** —— 能观测就用 `waitFor(cond)`，超时**显式 fail**；
/// 4. **不用 `pumpAndSettle`**（本页的加载态与 SnackBar 计时都让它语义不可靠）；
/// 5. **收尾推掉 SnackBar 计时**（默认 4s 自动消失 Timer），否则判
///    "A Timer is still pending"；
/// 6. **每个用例 `timeout: 90s`** —— 默认 10 分钟挂死会吃掉整轮迭代。
///
/// ## 引擎状态的注入缝
/// `BackgroundServiceManager.lastForTest` / `stateForTest` —— 注入引擎状态，
/// 驱动 `engine.when(data:…)` 分支（含 `guardError` 展示）。
/// ⚠️ 用 `Stream.multi` 而不是 `Stream.value`：后者是**单订阅**流，而
/// `_onToggleGuard` 会 `ref.invalidate(engineStateProvider)` ⇒ 重新订阅会抛
/// `Bad state: Stream has already been listened to`。`Stream.multi` 每次订阅
/// 都跑一遍回调 ⇒ 每个新订阅都立刻拿到当前状态，且天然支持多订阅。
///
/// ## 断言准则
/// 断言"回调真的跑了 + 状态真的变了"（文案随之变化 / 库里真的落值 / 失败真的
/// 弹了 SnackBar），不写"控件存在"这类恒真断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const perTest = Timeout(Duration(seconds: 90));

  late AppDatabase db;

  const idle = EngineState(running: false, pendingCount: 0);
  const active = EngineState(
      running: true, pendingCount: 0, guardActive: true, guardError: '麦克风被占用');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await AppDatabase.open(inMemoryDatabasePath);
    // 引擎相关调用一律短路（否则非 Android/iOS 平台 getter 直接抛）。
    BackgroundServiceManager.invokeHook = (method, args) async {};
    BackgroundServiceManager.startHook = () async => true;
    stubPermissions({Permission.microphone: PermissionStatus.granted});
    addTearDown(() async {
      BackgroundServiceManager.invokeHook = null;
      BackgroundServiceManager.startHook = null;
      BackgroundServiceManager.lastForTest = null;
      BackgroundServiceManager.stateForTest = null;
      clearPermissionStub();
      // 真实异步的收尾也不许留在 fake-async 里：本行在 tearDown（真实 zone）执行。
      try {
        await db.close();
      } on Object {
        // 仍在飞的 `_persist` 可能已把库关掉，忽略。
      }
    });
  });

  // ───────────────────────── 夹具（宿主安全的等待原语） ─────────────────────────

  /// 把**真实异步**（后台 isolate 的 SQLite 往返）推完。
  ///
  /// 每轮都 `runAsync` 一次让真实事件循环转一圈，再 `pump` 一帧让 `setState`
  /// 的结果落到界面。**不要**用 `pumpAndSettle` 代替它：那会卡满 10 分钟。
  Future<void> drainAsync(WidgetTester tester, {int rounds = 40}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 5));
    }
  }

  /// 有界轮询：条件成立才返回，否则**显式 fail**（不是"多 pump 几次"）。
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() cond, {
    required String reason,
    int maxRounds = 200,
  }) async {
    for (var i = 0; i < maxRounds; i++) {
      if (cond()) return;
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 10));
    }
    fail('等待超时（$maxRounds 轮）：$reason');
  }

  Future<void> waitForText(WidgetTester tester, String substring) => waitFor(
        tester,
        () => find.textContaining(substring).evaluate().isNotEmpty,
        reason: '应出现含「$substring」的文案',
      );

  /// 用例体里读库：**必须**过 `runAsync`（否则挂死）。
  Future<List<Map<String, Object?>>> dbQuery(String table, {String? where}) =>
      db.db.query(table, where: where);

  Future<T> inAsync<T>(WidgetTester tester, Future<T> Function() body) async {
    final r = await tester.runAsync(body);
    return r as T;
  }

  /// SnackBar 的自动消失计时（默认 4s）必须推掉，否则收尾判 pending timer。
  Future<void> retireSnackBars(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// pump 出守卫页并注入引擎状态。
  ///
  /// ⚠️ 三处都是**实测踩出来的**，不是风格偏好：
  /// 1. `StreamController.broadcast()` 而非 `Stream.value`：后者是**单订阅**流，
  ///    而 `_onToggleGuard` 会 `ref.invalidate(engineStateProvider)` ⇒
  ///    重新订阅会抛 `Bad state: Stream has already been listened to`。
  /// 2. 事件必须在**订阅建立之后**再 `add`（broadcast 不重放历史事件）——
  ///    先 `add` 后 `pumpWidget` 时状态卡永远停在 `LinearProgressIndicator`，
  ///    两条 GS-03 断言会**假红**（本文件第一版就是这么错的，实测 +6 -4）。
  /// 3. 视口放大：本页是长 `ListView`，默认 800×600 下编排区落在折叠区，
  ///    `tester.tap` 会因"不在视口"落空（与 `dashboard_screen_test` 同源处置）。
  Future<void> pumpGuard(WidgetTester tester, {EngineState state = idle}) async {
    final ctrl = StreamController<EngineState>.broadcast();
    addTearDown(() async => ctrl.close());
    BackgroundServiceManager.lastForTest = state;
    BackgroundServiceManager.stateForTest = ctrl.stream;

    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWith((ref) async => db)],
      child: const MaterialApp(home: GuardScreen()),
    ));
    // 订阅已建立 → 现在投递引擎状态。
    ctrl.add(state);
    await tester.pump();
    // `initState` 的 `_loadProfile` 是真实异步（后台 isolate）⇒ 推完它再断言。
    await drainAsync(tester);
  }

  Future<void> seedSoundTask(String id) async {
    final now = DateTime(2026, 1, 1);
    await TaskRepository(db).upsert(Task(
      id: id,
      name: '声音任务$id',
      enabled: true,
      triggerType: TriggerType.soundTriggered,
      trigger: const SoundTrigger(),
      actionType: ActionType.notify,
      action: const NotifyAction(title: 'T', body: 'B'),
      assetIds: const [],
      cooldownSec: 300,
      quietPolicy: QuietPolicy.skip,
      priority: 0,
      createdAt: now,
      updatedAt: now,
    ));
  }

  /// 直接取到真实 Slider 回调并调用 —— ListView 里逐个 drag 会受滚动位置影响，
  /// 而本文件要断言的是**回调里的业务逻辑**（夹取、防抖落库），不是手势命中。
  Future<void> driveSliderAt(WidgetTester tester, int i, double v) async {
    final s = tester.widget<Slider>(find.byType(Slider).at(i));
    s.onChanged!(v);
    await tester.pump();
    s.onChangeEnd!(v);
    // 600ms 防抖 Timer 必须推过，否则 `_persist` 根本不执行。
    await tester.pump(const Duration(milliseconds: 700));
    // 真实异步落库 + setState 落到界面。
    await drainAsync(tester);
  }

  group('GS-01 三个灵敏度 Slider（阈值 / 最短时长 / 冷却）', () {
    testWidgets('改阈值 → 文案随真实状态变化，并防抖落库', (tester) async {
      await pumpGuard(tester);
      expect(find.textContaining('阈值 -35 dBFS'), findsOneWidget);

      await driveSliderAt(tester, 0, -30);

      // 文案来自 setState 后的真实字段值 ⇒ 证明 onChanged 真的跑了。
      expect(find.textContaining('阈值 -30 dBFS'), findsOneWidget);
      final rows = await inAsync(
          tester, () => dbQuery('sound_profiles', where: 'enabled = 1'));
      expect(rows, isNotEmpty, reason: '防抖 600ms 后必须真的落库');
      expect((rows.first['threshold_db'] as num).toDouble(), -30);
    }, timeout: perTest);

    testWidgets('改最短时长 → 文案变化且落库', (tester) async {
      await pumpGuard(tester);
      await driveSliderAt(tester, 1, 1500);
      expect(find.textContaining('最小持续时间：1500ms'), findsOneWidget);
      final rows = await inAsync(
          tester, () => dbQuery('sound_profiles', where: 'enabled = 1'));
      expect((rows.first['min_duration_ms'] as num).toInt(), 1500);
    }, timeout: perTest);

    testWidgets('改冷却 → 文案变化且落库（同一行被 replace 覆盖）', (tester) async {
      await pumpGuard(tester);
      await driveSliderAt(tester, 2, 600);
      expect(find.textContaining('触发冷却：600s'), findsOneWidget);
      final rows = await inAsync(
          tester, () => dbQuery('sound_profiles', where: 'enabled = 1'));
      // id 恒为 'default' + ConflictAlgorithm.replace ⇒ 永远只有一行。
      expect(rows.length, 1);
      expect((rows.first['cooldown_sec'] as num).toInt(), 600);
    }, timeout: perTest);
  });

  group('GS-02 编排区（延时 Slider + 选取模式 + 候选任务）', () {
    testWidgets('无声音触发任务 → 给出可操作空态文案，而不是空白', (tester) async {
      await pumpGuard(tester);
      await waitForText(tester, '还没有「声音触发」类型的任务');
      expect(find.byType(CheckboxListTile), findsNothing);
    }, timeout: perTest);

    testWidgets('有声音触发任务 → 渲染候选勾选框，勾选真的写进 kv', (tester) async {
      // ⚠️ 真实异步写库必须过 `runAsync` —— fake-async 里直接 `await` 要么挂死，
      // 要么在 `_loadProfile` 读完之后才落盘 ⇒ 候选列表恒为空（实测假红一次）。
      await tester.runAsync(() => seedSoundTask('st1'));
      await pumpGuard(tester);
      await waitFor(
        tester,
        () => find.byType(CheckboxListTile).evaluate().isNotEmpty,
        reason: 'seed 的声音触发任务应渲染成候选勾选框',
      );

      final kvBefore = await inAsync(tester, () => db.kvGet(guardOrchestrationKey));
      // 同 Slider / SegmentedButton：驱动**真实回调**（断言回调里的业务逻辑，
      // 而不是长 ListView 里的手势命中）。
      final box = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
      box.onChanged!(true);
      await tester.pump();
      await drainAsync(tester);

      final kvAfter = await inAsync(tester, () => db.kvGet(guardOrchestrationKey));
      expect(kvAfter, isNot(kvBefore), reason: '勾选必须真的落 kv');
      expect(kvAfter, isNotNull);
      expect(kvAfter, contains('st1'));
    }, timeout: perTest);

    testWidgets('切到「随机一个」→ 选取模式真的落 kv', (tester) async {
      await pumpGuard(tester);
      // 与 Slider 同一处置：直接驱动**真实回调**（断言的是回调里的业务逻辑，
      // 不是手势命中）。控件找不到时 `tester.widget` 仍会抛 ⇒ 不是假绿。
      final seg = tester.widget<SegmentedButton<GuardPickMode>>(
          find.byType(SegmentedButton<GuardPickMode>));
      seg.onSelectionChanged!({GuardPickMode.randomOne});
      await tester.pump();
      await drainAsync(tester);
      final kv = await inAsync(tester, () => db.kvGet(guardOrchestrationKey));
      expect(kv, isNotNull);
      expect(kv, contains('randomOne'));
    }, timeout: perTest);

    testWidgets('延时 Slider → 文案变化且落 kv', (tester) async {
      await pumpGuard(tester);
      // 编排区的延时 Slider 是第 4 个（前三个是灵敏度）。
      await driveSliderAt(tester, 3, 30);
      expect(find.textContaining('延时执行：30s'), findsOneWidget);
      final kv = await inAsync(tester, () => db.kvGet(guardOrchestrationKey));
      expect(kv, isNotNull);
    }, timeout: perTest);
    testWidgets('GS-07 候选任务**取消勾选** → 从配置里移除（不是只加不减）', (tester) async {
      await tester.runAsync(() => seedSoundTask('st1'));
      await pumpGuard(tester);
      await waitFor(
        tester,
        () => find.byType(CheckboxListTile).evaluate().isNotEmpty,
        reason: 'seed 的声音触发任务应渲染成候选勾选框',
      );

      // 先勾上（此前已覆盖的 `v == true` 分支）……
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged!(true);
      await tester.pump();
      await drainAsync(tester);
      expect(await inAsync(tester, () => db.kvGet(guardOrchestrationKey)),
          contains('st1'));

      // ……再取消勾选（此前从未被驱动：编排配置只会变多、不会变少）。
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile))
          .onChanged!(false);
      await tester.pump();
      await drainAsync(tester);

      final kv = await inAsync(tester, () => db.kvGet(guardOrchestrationKey));
      expect(kv, isNotNull);
      expect(kv, isNot(contains('st1')),
          reason: '取消勾选必须真的从 taskIds 里移除 —— 否则"不选 = 全部触发"的语义被破坏');
    }, timeout: perTest);
  });

  group('GS-03 守卫开关与引擎状态卡', () {
    testWidgets('引擎未运行时开守卫 → 必须显式告知（不许静默弹回）',
        (tester) async {
      await pumpGuard(tester);
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      // 失败原因文案（`guardFailureText.engineNotRunning`）必须真的出现。
      await waitFor(
        tester,
        () => find.byType(SnackBar).evaluate().isNotEmpty,
        reason: '引擎未运行时开守卫必须显式告知，不能只把开关弹回',
      );
      expect(find.textContaining('守卫需要后台引擎'), findsOneWidget);
      await retireSnackBars(tester);
    }, timeout: perTest);

    testWidgets('引擎在跑且守卫激活 → 状态卡显示"正在监听"', (tester) async {
      await pumpGuard(tester, state: active);
      await waitForText(tester, '正在监听声音事件');
    }, timeout: perTest);

    testWidgets('引擎自报失败原因 → 直接显示在状态卡里（不必翻日志）',
        (tester) async {
      await pumpGuard(tester, state: active);
      await waitForText(tester, '麦克风被占用');
    }, timeout: perTest);

    testWidgets('GS-08 引擎状态流报错 → 状态卡直说"状态获取失败"（不停留在加载态）',
        (tester) async {
      // 第三条状态：`data` / `loading` 都已有用例，`error` 从未被驱动 ——
      // 而它正是"引擎查询炸了却只看到转圈"的那条（用户无从判断该不该重启）。
      final ctrl = StreamController<EngineState>.broadcast();
      addTearDown(() async => ctrl.close());
      BackgroundServiceManager.lastForTest = idle;
      BackgroundServiceManager.stateForTest = ctrl.stream;

      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        overrides: [databaseProvider.overrideWith((ref) async => db)],
        child: const MaterialApp(home: GuardScreen()),
      ));
      await drainAsync(tester);
      expect(find.byType(LinearProgressIndicator), findsOneWidget,
          reason: '前置：错误事件到达前应处于加载态');

      ctrl.addError(StateError('engine 查询失败'));

      await waitForText(tester, '状态获取失败');
      expect(find.textContaining('engine 查询失败'), findsOneWidget,
          reason: '原始原因要带出来，否则用户只能看到一句笼统的失败');
      await drainAsync(tester);
    }, timeout: perTest);
  });

  // ---------------------------------------------------------------------------
  // 第四十三轮：三条「有测试文件但从没被执行过」的守卫页分支。
  // ---------------------------------------------------------------------------
  group('GS-04 库态恢复与守卫热更新（第四十三轮）', () {
    testWidgets('GS-04 库里已有生效的守卫配置 → 进页即恢复阈值/时长/冷却',
        (tester) async {
      // 关键：本页此前只被"空库"驱动过 ⇒ `rows.isNotEmpty` 那一段
      // （L60-62，把库里的三项参数写回 UI 状态）**从未执行**。
      // 后果是"用户改过的灵敏度下次进来又变回默认"这类缺陷查不出来。
      await tester.runAsync(() => db.db.insert(
            'sound_profiles',
            {
              'id': 'default',
              'name': '默认守卫',
              'threshold_db': -42.0,
              'min_duration_ms': 1500,
              'cooldown_sec': 300,
              'only_while_charging': 0,
              'enabled': 1,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          ));

      await pumpGuard(tester);
      await waitForText(tester, '阈值 -42 dBFS');

      expect(find.textContaining('阈值 -42 dBFS'), findsOneWidget,
          reason: '库里的阈值必须被恢复 —— 否则用户调过的灵敏度每次都白调');
      expect(find.textContaining('最小持续时间：1500ms'), findsOneWidget);
      expect(find.textContaining('触发冷却：300s'), findsOneWidget);
    }, timeout: perTest);

    testWidgets('GS-05 守卫**正在跑**时改参数 → 必须先停后起（热更新）',
        (tester) async {
      await pumpGuard(tester, state: active);
      await waitForText(tester, '正在监听声音事件');

      final invoked = <String, Object?>{};
      final guards = <Map<String, Object?>>[];
      BackgroundServiceManager.invokeHook = (m, a) async {
        if (m == 'guard') guards.add(a ?? const <String, Object?>{});
        invoked[m] = a;
      };

      await driveSliderAt(tester, 0, -30);

      expect(guards.length, greaterThanOrEqualTo(2),
          reason: '守卫开着时改阈值必须重启守卫 —— 只落库不重启 ⇒ '
              '界面显示新值、引擎仍按旧阈值判断（静默失效）');
      expect(guards.first['enabled'], false, reason: '必须先停');
      expect(guards.last['enabled'], true, reason: '再起');
      expect(guards.last['micGranted'], true,
          reason: '重启时要把权威授权结论一并下发，引擎不必再问一遍');
    }, timeout: perTest);

    testWidgets('GS-06 引擎在跑 + 麦克风已授权 → 开守卫真的走到'
        '「申请麦克风前台服务」这一段', (tester) async {
      // 本页此前只测了 **失败** 路径（引擎没跑）。成功路径的中段
      // ——`await NativeBridge.startMicService(); await requestAllPermissions(ref);`
      // —— 是"守卫能在后台合法用麦克风"的唯一保证，却从没执行过。
      const running = EngineState(running: true, pendingCount: 0);
      final asked = stubPermissions({
        Permission.microphone: PermissionStatus.granted,
        Permission.notification: PermissionStatus.granted,
      });
      addTearDown(clearPermissionStub);

      final invoked = <String>[];
      BackgroundServiceManager.invokeHook = (m, a) async => invoked.add(m);

      await pumpGuard(tester, state: running);
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await drainAsync(tester);
      // `waitForGuardActive(true)` 有 3s 超时（fake Timer）——推过它，
      // 让 `_onToggleGuard` 走完并把失败原因告诉用户。
      await tester.pump(const Duration(seconds: 4));
      await drainAsync(tester);

      // 判据落在**可观测的副作用**上：`requestAllPermissions` 会依次申请
      // 通知与麦克风 —— 只有 `startMicService` 那一段真的跑了才会发生。
      expect(asked.map((e) => e.single), containsAll(<Permission>[
        Permission.notification,
        Permission.microphone,
      ]), reason: 'startMicService 必须带上 requestAllPermissions（前台服务通行证）');
      expect(invoked, contains('guard'), reason: '必须真的把开启意图下发给引擎');
      // 引擎在本测试里永远不会确认 ⇒ 必须显式告知，不许把开关静默弹回。
      expect(find.byType(SnackBar), findsOneWidget,
          reason: '引擎无响应时必须说出来（BUG-061）');
      await retireSnackBars(tester);
    }, timeout: perTest);
  });

  // ---------------------------------------------------------------------------
  // 动态反击开关（v2.0 阶段 D）——本轮新增。它此前**完全没有被驱动过**：
  // `_onToggleReactive` 的"落 prefs + 下发引擎 + 守卫未开时必须提示"三件事，
  // 任何一件静默失效，用户都会面对一个"看着像开了、实际没反应"的开关。
  // ---------------------------------------------------------------------------
  group('GS-09 动态反击开关（v2.0）', () {
    /// 「动态反击」是 `ListTile + Switch`（刻意不是第二个 `SwitchListTile`，
    /// 见 `guard_screen.dart` 的说明）。按标题文案定位它的 Switch，
    /// 避免与守卫开关（`SwitchListTile` 内部也含一个 Switch）混淆。
    Finder reactiveSwitch() => find.descendant(
          of: find.ancestor(
              of: find.text('动态反击'), matching: find.byType(ListTile)),
          matching: find.byType(Switch),
        );

    testWidgets('GS-09a 守卫未开时打开动态反击 → 下发 true + 落 prefs + 提示需守卫运行',
        (tester) async {
      final reactiveCalls = <Object?>[];
      BackgroundServiceManager.invokeHook = (m, a) async {
        if (m == 'reactive') reactiveCalls.add(a);
      };

      await pumpGuard(tester);
      await tester.ensureVisible(reactiveSwitch());
      await tester.tap(reactiveSwitch());
      await drainAsync(tester);

      expect(reactiveCalls, isNotEmpty, reason: '必须把开关意图下发给引擎');
      expect((reactiveCalls.last as Map)['enabled'], true);
      expect(
          (await SharedPreferences.getInstance())
              .getBool(PrefsKeys.reactiveCounterEnabled),
          isTrue,
          reason: '开关必须落 prefs —— 引擎没跑时也要记住用户意愿');
      // 守卫没开 = 动态反击"开了也没反应"，必须讲清楚（失败不可静默）。
      await waitForText(tester, '动态反击需要守卫运行');
      await retireSnackBars(tester);
    }, timeout: perTest);

    testWidgets('GS-09b 关闭动态反击 → 下发 false + 落 prefs false（不弹"需守卫"提示）',
        (tester) async {
      // 先把开关置为已开启：进页时 `_loadProfile` 会从 prefs 回填。
      SharedPreferences.setMockInitialValues({
        PrefsKeys.reactiveCounterEnabled: true,
      });
      final reactiveCalls = <Object?>[];
      BackgroundServiceManager.invokeHook = (m, a) async {
        if (m == 'reactive') reactiveCalls.add(a);
      };

      await pumpGuard(tester);
      expect(tester.widget<Switch>(reactiveSwitch()).value, isTrue,
          reason: '前置：prefs 已开 → 开关应回填为开');

      await tester.ensureVisible(reactiveSwitch());
      await tester.tap(reactiveSwitch());
      await drainAsync(tester);

      expect((reactiveCalls.last as Map)['enabled'], false);
      expect(
          (await SharedPreferences.getInstance())
              .getBool(PrefsKeys.reactiveCounterEnabled),
          isFalse);
      // 关闭是"回到更安全的一侧"，不该弹"需要守卫运行"。
      expect(find.textContaining('动态反击需要守卫运行'), findsNothing);
    }, timeout: perTest);

    testWidgets('GS-09c 守卫已运行中打开动态反击 → 不误报"需要守卫运行"',
        (tester) async {
      final reactiveCalls = <Object?>[];
      BackgroundServiceManager.invokeHook = (m, a) async {
        if (m == 'reactive') reactiveCalls.add(a);
      };

      await pumpGuard(tester, state: active);
      await waitForText(tester, '正在监听声音事件');
      await tester.ensureVisible(reactiveSwitch());
      await tester.tap(reactiveSwitch());
      await drainAsync(tester);

      expect((reactiveCalls.last as Map)['enabled'], true);
      expect(find.textContaining('动态反击需要守卫运行'), findsNothing,
          reason: '守卫已在运行，不该误报"需要守卫"');
    }, timeout: perTest);
  });
}
