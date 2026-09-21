import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

/// 任务编辑器（最大单文件 UI，591 行）的**深交互**测试。
///
/// 覆盖目标：把"每个控件的回调真的走一遍" + "`_buildTask` 每个分支的产物"。
/// 第 4 项覆盖率工程里，编辑器是**纯宿主可测**的最大一块（211 行未覆盖，
/// 且 90% 是 `onChanged` / `onTap` 回调 —— 不点就永远不计）。
///
/// ## 本文件必须遵守的宿主硬约束（技能 `flutter-widget-test-harness`）
///
/// 1. **开库放 `setUp`**（`databaseFactoryFfi` 的 SQLite 在**后台 isolate**）；
/// 2. **用例体里所有 DB 读写包 `tester.runAsync`**（`dbRead`）——
///    否则不是"慢"，是**永久挂死**（实测 10 分钟超时 + 其余用例级联失败，
///    报的却是 `Guarded function conflict`，指不到真因）；
/// 3. **`taskId` 路径不能用 `pumpAndSettle`**：加载态是 `CircularProgressIndicator`
///    （无限动画）→ `pumpAndSettle` 必超时。用 `waitFor` 有界轮询；
/// 4. **不要用固定轮数 drain 等异步**（时红时绿）→ `waitFor` + 超时 `fail`；
/// 5. **按"关系"定位控件**（`find.ancestor`/`descendant`），
///    下标只在"同一列表内顺序确定"时才用，且要写清顺序依据；
/// 6. 每例 `timeout: 90s` 护栏（挂死时给一次干净的失败，而不是拖垮整份报告）。
///
/// 视口用 1080x6000：编辑器 ListView 很长，默认视口外的子项**不会被懒构建**，
/// `find` 直接找不到（这不是"控件不存在"，是"没被构建"）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const perTest = Timeout(Duration(seconds: 90));

  late AppDatabase db;

  // ── harness ────────────────────────────────────────────────────────────

  void bigViewport(WidgetTester tester, [Size size = const Size(1080, 6000)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 跳出 FakeAsync 跑真实异步（DB 往返必须这样）。
  Future<T> dbRead<T>(WidgetTester tester, Future<T> Function() body) async {
    final r = await tester.runAsync(body);
    return r as T;
  }

  /// 有界轮询等待。⚠️ 超时必须 `fail` —— 静默放行会让负向断言恒真。
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() cond, {
    required String reason,
    int maxRounds = 80,
  }) async {
    for (var i = 0; i < maxRounds; i++) {
      if (cond()) return;
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('等待超时（$maxRounds 轮）：$reason');
  }

  /// 把编辑器**压在一个宿主页上**再打开。
  ///
  /// 为什么不直接 `home: TaskEditorScreen(...)`：保存成功会
  /// `Navigator.of(context).pop()`，压在宿主页上才有"退路"，
  /// 也才能断言"确实返回了上一页"（而不是"页面被弹空了"）。
  Future<void> pumpEditor(
    WidgetTester tester, {
    Task? initialTask,
    Future<bool> Function(Task)? remoteSave,
    String? remoteName,
    String? taskId,
    Size viewport = const Size(1080, 6000),
  }) async {
    bigViewport(tester, viewport);
    RemoteTaskTarget? remote;
    if (remoteSave != null) {
      remote =
          RemoteTaskTarget(endpointName: remoteName ?? '端点', save: remoteSave);
    }
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWith((ref) async => db)],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
                    builder: (_) => TaskEditorScreen(
                          initialTask: initialTask,
                          remoteTarget: remote,
                          taskId: taskId,
                        ))),
                child: const Text('HOST-OPEN'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('HOST-OPEN'));
    if (taskId != null) {
      // 约束 3：加载态是无限动画，pumpAndSettle 会超时。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // 路由动画
      await waitFor(
        tester,
        () => find.text('任务名称').evaluate().isNotEmpty,
        reason: '按 id 读库后编辑器应渲染完成（不再是加载态）',
      );
    } else {
      await tester.pumpAndSettle();
    }
  }

  /// 点保存并等它真的走完（远程模式：回调已收到 / 本机模式：已 pop）。
  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.text('保存任务'));
    await tester.pump();
    await tester.pump();
  }

  // ── 定位辅助（一律按"关系"，不按全局下标） ─────────────────────────────

  Finder chip(String label) => find.widgetWithText(ChoiceChip, label);
  Finder fchip(String label) => find.widgetWithText(FilterChip, label);

  /// 某个 ListTile 里的 Slider —— 用"它和哪段文案在同一行"定位。
  Finder sliderIn(String titleContains) => find.descendant(
        of: find.ancestor(
          of: find.textContaining(titleContains),
          matching: find.byType(ListTile),
        ),
        matching: find.byType(Slider),
      );

  String textOf(WidgetTester tester, Finder f) =>
      tester.widget<Text>(f).data ?? '';

  /// 把 [TimeOfDay] 渲染成**界面实际会显示的那串字**。
  ///
  /// 不硬编码 '06:05' / '6:05 AM'：宿主 `MaterialApp` 没挂
  /// `localizationsDelegates`，`TimeOfDay.format` 走
  /// `DefaultMaterialLocalizations`（en_US、12 小时制）→ 是 `6:05 AM`。
  /// 硬编码任一种写法都会把测试绑死在 locale 上；这里直接问框架要。
  String fmtTime(WidgetTester tester, TimeOfDay t) =>
      t.format(tester.element(find.byType(TaskEditorScreen)));

  bool switchValue(WidgetTester tester, String title) =>
      tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title))
          .value;

  /// 拖一个 Slider（`drag` 的起点会先被离散成该处数值，再按 dx 移动 →
  /// `onChanged` 必被调用）。用 ± 大位移保证跨过多个 division。
  Future<void> dragIt(WidgetTester tester, Finder f, double dx) async {
    await tester.drag(f, Offset(dx, 0));
    await tester.pump();
  }

  /// 用**键盘输入模式**选时间 —— 拨盘拖拽要算角度，输入模式是确定性的。
  Future<void> pickTime(
    WidgetTester tester,
    Finder tile,
    int hour,
    int minute,
  ) async {
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined)); // 切到输入模式
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '$hour');
    await tester.enterText(fields.at(1), '$minute');
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  /// 打开某个 `DropdownButton<int?>` 并选一项。
  /// 下标顺序依据：条件区的三个下拉在 `_conditionInputs` 里的**书写顺序**
  /// （0=最低电量、1=时段开始、2=时段结束）。
  Future<void> pickDropdown(
    WidgetTester tester,
    int index,
    String itemText,
  ) async {
    await tester.tap(find.byType(DropdownButton<int?>).at(index));
    await tester.pumpAndSettle();
    await tester.tap(find.text(itemText).last);
    await tester.pumpAndSettle();
  }

  /// 「生效日期范围」那一行的日期文案。
  String dateRangeSubtitle(WidgetTester tester) {
    final tile = find.ancestor(
        of: find.text('生效日期范围'), matching: find.byType(ListTile));
    return find
        .descendant(of: tile, matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .firstWhere((s) => s.contains('~'));
  }

  // ── 夹具 ───────────────────────────────────────────────────────────────

  setUp(() async {
    db = await AppDatabase.open(inMemoryDatabasePath);
    // 服务未初始化时 invoke 会抛（非 Android/iOS 平台单例直接抛）。
    BackgroundServiceManager.replanHook = () async {};
  });
  tearDown(() async {
    BackgroundServiceManager.replanHook = null;
    await db.close();
  });

  Task task({
    required String id,
    String name = '任务',
    required TriggerType triggerType,
    required TriggerConfig trigger,
    required ActionType actionType,
    required ActionConfig action,
    TaskCondition? condition,
  }) =>
      Task(
        id: id,
        name: name,
        enabled: true,
        triggerType: triggerType,
        trigger: trigger,
        actionType: actionType,
        action: action,
        assetIds: const [],
        cooldownSec: 300,
        quietPolicy: QuietPolicy.skip,
        condition: condition,
        priority: 0,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  Task dailyTask({bool probability = false}) => task(
        id: 't1',
        name: '每日回填',
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 7, minute: 30)),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(
            volumeMin: 0.3,
            volumeMax: 0.8,
            durationSecMin: 4,
            durationSecMax: 9),
        condition: probability
            ? const TaskCondition(requireCharging: true, probabilityPct: 30)
            : null,
      );

  // ══════════════════════════════════════════════════════════════════════
  // TEI-A · 回填（_applyTask 的每个分支）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEI-A1 本机按 id 加载：读库回填（不是"新建"空表单）',
      (tester) async {
    // ⚠️ 入库必须在 pump 之前，且要跳出 FakeAsync。
    await dbRead(tester, () => TaskRepository(db).upsert(dailyTask()));
    await pumpEditor(tester, taskId: 't1');
    // 标题变"编辑任务"（而不是"新建任务"）—— 这是"真的读到了"的最强信号。
    expect(find.text('编辑任务'), findsOneWidget);
    expect(find.text('新建任务'), findsNothing);
    // 名字被回填到输入框。
    expect(find.widgetWithText(TextFormField, '每日回填'), findsOneWidget);
    expect(chip('每天定时'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-A2 回填：固定一次 → 时刻', (tester) async {
    await pumpEditor(
      tester,
      initialTask: task(
        id: 'x',
        triggerType: TriggerType.fixedOnce,
        trigger: FixedOnceTrigger(at: DateTime(2026, 3, 4, 6, 5)),
        actionType: ActionType.notify,
        action: const NotifyAction(title: 'a', body: 'b'),
      ),
      remoteSave: (t) async => true,
    );
    expect(chip('固定一次'), findsOneWidget);
    expect(find.textContaining(fmtTime(tester, const TimeOfDay(hour: 6, minute: 5))),
        findsWidgets);
  }, timeout: perTest);

  testWidgets('TEI-A3 回填：每周 → 星期勾选状态跟着回来', (tester) async {
    await pumpEditor(
      tester,
      initialTask: task(
        id: 'x',
        triggerType: TriggerType.weeklyAt,
        trigger: const WeeklyTrigger(
            weekdays: {2, 4, 6}, time: TimeSpec(hour: 8, minute: 15)),
        actionType: ActionType.notify,
        action: const NotifyAction(title: 'a', body: 'b'),
      ),
      remoteSave: (t) async => true,
    );
    // 选中态必须落在**正确的那些天**上，而不是"随便哪天都行"。
    for (final d in [2, 4, 6]) {
      final label = const ['一', '二', '三', '四', '五', '六', '日'][d - 1];
      expect(tester.widget<FilterChip>(fchip(label)).selected, isTrue,
          reason: '周$label 应被回填为选中');
    }
    for (final d in [1, 3, 5, 7]) {
      final label = const ['一', '二', '三', '四', '五', '六', '日'][d - 1];
      expect(tester.widget<FilterChip>(fchip(label)).selected, isFalse,
          reason: '周$label 不该被选中');
    }
  }, timeout: perTest);

  testWidgets('TEI-A4 回填：随机窗口 → 窗口时刻/次数/间隔/日期范围', (tester) async {
    await pumpEditor(
      tester,
      initialTask: task(
        id: 'x',
        triggerType: TriggerType.randomWindow,
        trigger: RandomWindowTrigger(
          dateRange: DateRange(
              start: DateTime(2026, 5, 1), end: DateTime(2026, 6, 1)),
          windowStart: const TimeSpec(hour: 6, minute: 30),
          windowEnd: const TimeSpec(hour: 23, minute: 0),
          timesPerDay: 7,
          minGap: const Duration(minutes: 45),
        ),
        actionType: ActionType.notify,
        action: const NotifyAction(title: 'a', body: 'b'),
      ),
      remoteSave: (t) async => true,
    );
    expect(
        find.textContaining(fmtTime(tester, const TimeOfDay(hour: 6, minute: 30))),
        findsWidgets);
    expect(
        find.textContaining(fmtTime(tester, const TimeOfDay(hour: 23, minute: 0))),
        findsWidgets);
    expect(find.text('每日随机次数：7'), findsOneWidget);
    expect(find.text('最短间隔（分钟）：45'), findsOneWidget);
    expect(find.textContaining('2026-5-1'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-A5 回填：随机间隔 → 最短/最长间隔与日期范围', (tester) async {
    await pumpEditor(
      tester,
      initialTask: task(
        id: 'x',
        triggerType: TriggerType.randomInterval,
        trigger: RandomIntervalTrigger(
          dateRange: DateRange(
              start: DateTime(2026, 7, 2), end: DateTime(2026, 8, 9)),
          minGap: const Duration(minutes: 11),
          maxGap: const Duration(minutes: 99),
        ),
        actionType: ActionType.notify,
        action: const NotifyAction(title: 'a', body: 'b'),
      ),
      remoteSave: (t) async => true,
    );
    expect(find.text('最短间隔（分钟）：11'), findsOneWidget);
    expect(find.text('最长间隔（分钟）：99'), findsOneWidget);
    expect(find.textContaining('2026-7-2'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-A6 回填：声音触发 → 冷却回填到录音时长', (tester) async {
    await pumpEditor(
      tester,
      initialTask: task(
        id: 'x',
        triggerType: TriggerType.soundTriggered,
        trigger: const SoundTrigger(cooldownSec: 42),
        actionType: ActionType.recordEvidence,
        action: const RecordEvidenceAction(seconds: 33),
      ),
      remoteSave: (t) async => true,
    );
    expect(chip('声音触发'), findsOneWidget);
    expect(find.textContaining('由「守卫」页统一配置'), findsOneWidget);
    expect(find.text('录音取证时长（秒）：33'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-A7 回填：声景 → 轨道/总时长/渐出全还原', (tester) async {
    await pumpEditor(
      tester,
      initialTask: task(
        id: 'x',
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 1)),
        actionType: ActionType.soundscape,
        // ⚠️ 不能写 `const`：`SoundscapeAction` 的 assert 要读 `tracks.length`，
        // 常量表达式里访问不了 List 的 length（编译期直接报错）。
        action: SoundscapeAction(
          tracks: const [
            SoundscapeTrack(presetCategory: 'nature', volume: 0.8),
            SoundscapeTrack(presetCategory: 'doors', volume: 0.2, loop: false),
          ],
          durationSec: 120,
          fadeOutSec: 9,
        ),
      ),
      remoteSave: (t) async => true,
    );
    expect(chip('声景混音'), findsOneWidget);
    // 分类要翻成人话（不是把 'nature' 直接甩给用户）。
    expect(find.textContaining('轨道 1：自然'), findsOneWidget);
    expect(find.textContaining('80%'), findsWidgets);
    expect(find.textContaining('循环'), findsWidgets);
    expect(find.textContaining('轨道 2：门窗'), findsOneWidget);
    expect(find.text('总时长：120 秒'), findsOneWidget);
    expect(find.text('渐出：9 秒'), findsOneWidget);
  }, timeout: perTest);

  // 三种"单动作"回填分支各一条用例。
  // ⚠️ 不能在一个用例里循环 `pumpEditor` 三次：`pumpWidget` 会**原地更新**同一棵树，
  // 上一次 push 出来的编辑器还压在路由栈顶 → 第二次 `find.text('HOST-OPEN')`
  // 直接找不到（实测）。要重来就换用例。
  Future<void> pumpWithAction(
    WidgetTester tester,
    ActionType aType,
    ActionConfig a,
  ) =>
      pumpEditor(
        tester,
        initialTask: task(
          id: 'x',
          triggerType: TriggerType.dailyAt,
          trigger: const DailyTrigger(time: TimeSpec(hour: 1)),
          actionType: aType,
          action: a,
        ),
        remoteSave: (t) async => true,
      );

  testWidgets('TEI-A8a 回填：语音播报 → 文案回到输入框', (tester) async {
    await pumpWithAction(tester, ActionType.tts, const TtsAction(text: '喂喂喂'));
    expect(chip('语音播报'), findsOneWidget);
    expect(find.text('喂喂喂'), findsWidgets);
  }, timeout: perTest);

  testWidgets('TEI-A8b 回填：录音取证 → 时长回到步进器', (tester) async {
    await pumpWithAction(
        tester, ActionType.recordEvidence, const RecordEvidenceAction(seconds: 88));
    expect(chip('录音取证'), findsOneWidget);
    expect(find.text('录音取证时长（秒）：88'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-A8c 回填：通知 → 只显示说明文案', (tester) async {
    await pumpWithAction(
        tester, ActionType.notify, const NotifyAction(title: 't', body: 'b'));
    expect(chip('通知'), findsOneWidget);
    expect(find.textContaining('将发送系统通知'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-A9 回填：组合动作 → primary 的音量/时长/闹钟/渐强全带回',
      (tester) async {
    await pumpEditor(
      tester,
      initialTask: task(
        id: 'x',
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 1)),
        actionType: ActionType.composite,
        action: const CompositeAction(
          primary: PlayAudioAction(
            volumeMin: 0.1,
            volumeMax: 0.4,
            durationSecMin: 6,
            durationSecMax: 30,
            channel: AudioChannel.alarm,
            rampUpSec: 40,
            loopFill: false,
          ),
          prefixNotify: NotifyAction(title: 't', body: 'b'),
        ),
      ),
      remoteSave: (t) async => true,
    );
    expect(chip('通知+播放'), findsOneWidget);
    expect(find.textContaining('随机音量：10% ~ 40%'), findsOneWidget);
    expect(find.textContaining('随机时长（秒）：6s ~ 30s'), findsOneWidget);
    expect(switchValue(tester, '闹钟通道（穿透勿扰/静音）'), isTrue);
    expect(find.text('渐强唤醒：40 秒渐强'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-A11 回填：条件层六个字段全部带回（含显式 false）',
      (tester) async {
    await pumpEditor(
      tester,
      initialTask: task(
        id: 'x',
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 1)),
        actionType: ActionType.notify,
        action: const NotifyAction(title: 't', body: 'b'),
        condition: const TaskCondition(
          requireCharging: true,
          minBatteryPct: 50,
          windowStartMin: 22 * 60,
          windowEndMin: 7 * 60,
          requireWifi: true,
          skipInCall: false, // 显式关闭：必须被带回，不能被默认值顶掉
          probabilityPct: 30,
        ),
      ),
      remoteSave: (t) async => true,
    );
    expect(switchValue(tester, '仅充电时执行'), isTrue);
    expect(find.text('最低电量：50%'), findsOneWidget);
    expect(find.text('时段窗口：22:00–07:00'), findsOneWidget);
    expect(switchValue(tester, '仅 Wi-Fi 下执行'), isTrue);
    expect(switchValue(tester, '通话中不执行'), isFalse);
    expect(find.text('执行概率：30%'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-A10 回填：随机指令集含"不可编辑"子动作 → 明示保留、不静默丢',
      (tester) async {
    await pumpEditor(
      tester,
      initialTask: task(
        id: 'x',
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 1)),
        actionType: ActionType.randomFrom,
        action: ActionSetAction(candidates: [
          // 可编辑：录音取证（→ record）
          const ActionSetCandidate(
              weight: 3, action: RecordEvidenceAction(seconds: 12)),
          // 不可编辑：复合动作（stepKindOfAction → null）
          const ActionSetCandidate(
              weight: 1,
              action: CompositeAction(
                  primary: PlayAudioAction(),
                  prefixNotify: NotifyAction(title: 't', body: 'b'))),
        ]),
      ),
      remoteSave: (t) async => true,
    );
    expect(chip('随机指令集'), findsOneWidget);
    // record 候选：图标 + 文案都渲染出来（这两个 switch 分支平时没人走）。
    final card = find.ancestor(
        of: find.text('权重 3'), matching: find.byType(Card));
    expect(find.descendant(of: card, matching: find.text('录音取证')),
        findsOneWidget);
    expect(
        find.descendant(
            of: card, matching: find.byIcon(Icons.fiber_manual_record)),
        findsOneWidget);
    // 不可编辑的那个必须**明说**，而不是悄悄消失。
    expect(find.textContaining('另有 1 个子动作'), findsOneWidget);
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════════
  // TEI-B · 声景编辑区交互
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEI-B1 声景：加轨道 → 拖音量 → 删轨道', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await tester.tap(chip('声景混音'));
    await tester.pump();
    expect(find.textContaining('轨道 1'), findsNothing);

    await tester.tap(find.widgetWithText(ActionChip, '＋助眠底噪'));
    await tester.pump();
    expect(find.textContaining('轨道 1：助眠底噪'), findsOneWidget);

    // 音量滑条：拖了必须真的改状态（默认 60%）。
    final before = textOf(tester, find.textContaining('轨道 1：'));
    await dragIt(tester, sliderIn('轨道 1：'), -120);
    expect(textOf(tester, find.textContaining('轨道 1：')), isNot(before),
        reason: '拖动轨道音量滑条应改变显示值');

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(find.textContaining('轨道 1'), findsNothing);
  }, timeout: perTest);

  testWidgets('TEI-B2 声景：拖总时长与渐出滑条', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await tester.tap(chip('声景混音'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ActionChip, '＋自然'));
    await tester.pump();

    final durBefore = textOf(tester, find.textContaining('总时长：'));
    await dragIt(tester, sliderIn('总时长：'), 200);
    expect(textOf(tester, find.textContaining('总时长：')), isNot(durBefore));

    final fadeBefore = textOf(tester, find.textContaining('渐出：'));
    await dragIt(tester, sliderIn('渐出：'), 200);
    expect(textOf(tester, find.textContaining('渐出：')), isNot(fadeBefore));
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════════
  // TEI-C · 条件区交互
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEI-C1 条件：三个开关双向切换', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    // 通话保护默认开启（安全默认）——先锁住这个前提。
    expect(switchValue(tester, '通话中不执行'), isTrue);
    expect(switchValue(tester, '仅 Wi-Fi 下执行'), isFalse);
    expect(switchValue(tester, '仅充电时执行'), isFalse);

    await tester.tap(find.widgetWithText(SwitchListTile, '通话中不执行'));
    await tester.pump();
    expect(switchValue(tester, '通话中不执行'), isFalse);

    await tester.tap(find.widgetWithText(SwitchListTile, '仅 Wi-Fi 下执行'));
    await tester.pump();
    expect(switchValue(tester, '仅 Wi-Fi 下执行'), isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, '仅充电时执行'));
    await tester.pump();
    expect(switchValue(tester, '仅充电时执行'), isTrue);
  }, timeout: perTest);

  testWidgets('TEI-C2 条件：概率门滑条（100% 显示"每次都执行"）',
      (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    expect(find.text('执行概率：每次都执行'), findsOneWidget);
    await dragIt(tester, sliderIn('执行概率：'), -200);
    expect(find.text('执行概率：每次都执行'), findsNothing,
        reason: '拖低后不该再显示"每次都执行"');
    expect(find.textContaining('执行概率：'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-C3 条件：最低电量下拉（含"不限"）', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    expect(find.text('最低电量：不限'), findsOneWidget);
    await pickDropdown(tester, 0, '30%');
    expect(find.text('最低电量：30%'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-C4 条件：时段窗口两端下拉 → 区间文案', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    expect(find.text('时段窗口：不限'), findsOneWidget);
    // 只设一端时仍应显示"不限"（半截窗口不是窗口）。
    await pickDropdown(tester, 1, '22:00');
    expect(find.text('时段窗口：不限'), findsOneWidget);
    await pickDropdown(tester, 2, '07:00');
    expect(find.text('时段窗口：22:00–07:00'), findsOneWidget);
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════════
  // TEI-D · 触发区交互
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEI-D1 触发：时刻选择器（键盘输入模式）', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await tester.tap(chip('每天定时'));
    await tester.pump();
    expect(find.textContaining(fmtTime(tester, const TimeOfDay(hour: 10, minute: 0))),
        findsWidgets);
    await pickTime(tester, find.textContaining('时刻：'), 11, 45);
    expect(
        find.textContaining(fmtTime(tester, const TimeOfDay(hour: 11, minute: 45))),
        findsWidgets,
        reason: '选完时间后应回显新时刻');
  }, timeout: perTest);

  testWidgets('TEI-D2 触发：每周的星期 FilterChip 可勾可取消', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await tester.tap(chip('每周定时'));
    await tester.pump();
    // 默认周一~周五已选。
    expect(tester.widget<FilterChip>(fchip('六')).selected, isFalse);
    await tester.tap(fchip('六'));
    await tester.pump();
    expect(tester.widget<FilterChip>(fchip('六')).selected, isTrue);
    await tester.tap(fchip('六'));
    await tester.pump();
    expect(tester.widget<FilterChip>(fchip('六')).selected, isFalse);
  }, timeout: perTest);

  testWidgets('TEI-D3 触发：日期范围选择器确认后回写（值真的变了）',
      (tester) async {
    // 视口调小：全屏选择器在 6000px 高的宿主里会把月份列表铺到视口之外，
    // 目标日期格点不到（实测派生 Offset y=6107 > 6000）。
    await pumpEditor(tester,
        remoteSave: (t) async => true, viewport: const Size(1080, 2400));
    final before = dateRangeSubtitle(tester);
    await tester.tap(find.text('生效日期范围'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget,
        reason: '点这一行应弹出日期范围选择器');

    // ⚠️ 只断言"对话框关了"是不够的 —— `onChanged` 没接上也能绿。
    // 必须真的选出一个**与初始不同**的区间。
    final dialog = find.byType(DateRangePickerDialog);
    Future<void> tapDay(String day) async {
      final f = find.descendant(of: dialog, matching: find.text(day)).first;
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    await tapDay('10'); // 第一下 = 起点
    await tapDay('20'); // 第二下 = 终点（两次都点完 Save 才可用）
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(DateRangePickerDialog), findsNothing);
    expect(dateRangeSubtitle(tester), isNot(before),
        reason: '确认后区间应回写到那一行');
  }, timeout: perTest);

  testWidgets('TEI-D4 触发：随机窗口的"窗口开始/结束"两个时刻',
      (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    // 默认 triggerType 就是 randomWindow，无需切 chip。
    await pickTime(tester, find.textContaining('窗口开始：'), 5, 30);
    expect(
        find.textContaining(fmtTime(tester, const TimeOfDay(hour: 5, minute: 30))),
        findsWidgets);
    await pickTime(tester, find.textContaining('窗口结束：'), 12, 0);
    expect(
        find.textContaining(fmtTime(tester, const TimeOfDay(hour: 12, minute: 0))),
        findsWidgets);
  }, timeout: perTest);

  testWidgets('TEI-D5 触发：随机窗口的"次数/最短间隔"步进器', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    expect(find.text('每日随机次数：3'), findsOneWidget);
    // 步进器 trailing 是两个 IconButton（先减后加）→ 按图标定位，
    // 用 ancestor 限定在"哪一行的 ListTile"里，避免跨行错配。
    Finder stepperBtn(String label, IconData icon) => find.descendant(
          of: find.ancestor(
              of: find.textContaining(label), matching: find.byType(ListTile)),
          matching: find.byIcon(icon),
        );
    await tester.tap(stepperBtn('每日随机次数', Icons.add_circle_outline));
    await tester.pump();
    expect(find.text('每日随机次数：4'), findsOneWidget);
    await tester.tap(stepperBtn('每日随机次数', Icons.remove_circle_outline));
    await tester.pump();
    expect(find.text('每日随机次数：3'), findsOneWidget);

    await tester.tap(stepperBtn('最短间隔（分钟）', Icons.add_circle_outline));
    await tester.pump();
    expect(find.text('最短间隔（分钟）：31'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-D6 触发：随机间隔的"最短/最长"步进器', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await tester.tap(chip('随机间隔'));
    await tester.pump();
    expect(find.text('最短间隔（分钟）：30'), findsOneWidget);
    expect(find.text('最长间隔（分钟）：120'), findsOneWidget);
    Finder stepperBtn(String label, IconData icon) => find.descendant(
          of: find.ancestor(
              of: find.textContaining(label), matching: find.byType(ListTile)),
          matching: find.byIcon(icon),
        );
    await tester.tap(stepperBtn('最长间隔（分钟）', Icons.add_circle_outline));
    await tester.pump();
    expect(find.text('最长间隔（分钟）：121'), findsOneWidget);
    // 随机间隔分支的"最短间隔"是**另一个** _IntStepper（和随机窗口分支同标签、
    // 不同代码位置）—— 两个都要走到，否则会漏掉一条 onChanged。
    await tester.tap(stepperBtn('最短间隔（分钟）', Icons.add_circle_outline));
    await tester.pump();
    expect(find.text('最短间隔（分钟）：31'), findsOneWidget);
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════════
  // TEI-E · 动作区交互
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEI-E1 动作：随机音量与随机时长两条 RangeSlider', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    // `_RangeSliderTile` 在 play/composite 输入里的书写顺序：音量 → 时长。
    expect(find.byType(RangeSlider), findsNWidgets(2));
    final volBefore = textOf(tester, find.textContaining('随机音量：'));
    await dragIt(tester, find.byType(RangeSlider).at(0), -200);
    expect(textOf(tester, find.textContaining('随机音量：')), isNot(volBefore));

    final durBefore = textOf(tester, find.textContaining('随机时长（秒）：'));
    await dragIt(tester, find.byType(RangeSlider).at(1), -200);
    expect(
        textOf(tester, find.textContaining('随机时长（秒）：')), isNot(durBefore));
  }, timeout: perTest);

  testWidgets('TEI-E2 动作：闹钟通道开关 + 循环填充开关（渐强随之隐藏）',
      (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    expect(find.textContaining('渐强唤醒：'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, '闹钟通道（穿透勿扰/静音）'));
    await tester.pump();
    expect(switchValue(tester, '闹钟通道（穿透勿扰/静音）'), isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, '循环填充（声景模式）'));
    await tester.pump();
    expect(switchValue(tester, '循环填充（声景模式）'), isTrue);
    // 循环填充与渐强互斥（短音效循环填满时长，谈不上"渐强"）。
    expect(find.textContaining('渐强唤醒：'), findsNothing);
  }, timeout: perTest);

  testWidgets('TEI-E3 动作：语音播报文本输入', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await tester.tap(chip('语音播报'));
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextFormField, '请注意，已开启录音取证'), '新文案ABC');
    await tester.pump();
    expect(find.text('新文案ABC'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-E4 动作：录音取证时长步进器', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await tester.tap(chip('录音取证'));
    await tester.pump();
    expect(find.text('录音取证时长（秒）：60'), findsOneWidget);
    final tile = find.ancestor(
        of: find.textContaining('录音取证时长（秒）'),
        matching: find.byType(ListTile));
    await tester.tap(find.descendant(
        of: tile, matching: find.byIcon(Icons.add_circle_outline)));
    await tester.pump();
    expect(find.text('录音取证时长（秒）：61'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-E5 动作：随机指令集的候选权重滑条', (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await tester.tap(chip('随机指令集'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ActionChip, '＋震动'));
    await tester.pump();
    expect(find.text('权重 3'), findsOneWidget);
    final card =
        find.ancestor(of: find.text('权重 3'), matching: find.byType(Card));
    await dragIt(
        tester, find.descendant(of: card, matching: find.byType(Slider)), -120);
    expect(find.text('权重 3'), findsNothing,
        reason: '拖权重滑条后显示值应改变');
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════════
  // TEI-F · 保存 → _buildTask 的每个分支
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEI-F1 本机保存：真的落库 + 返回上一页', (tester) async {
    await pumpEditor(tester); // 无 remoteTarget → 走本机仓储
    await tester.enterText(find.byType(TextField).first, '本机落库任务');
    await tester.pump();
    await tapSave(tester);
    await waitFor(tester, () => find.text('保存任务').evaluate().isEmpty,
        reason: '本机保存成功后应 pop 回宿主页');

    final all = await dbRead(tester, () => TaskRepository(db).listAll());
    expect(all.map((t) => t.name), contains('本机落库任务'));
    // 本机保存不能把"远程/本机"搞混：这是一条真任务，不是远程定义。
    expect(all.single.triggerType, TriggerType.randomWindow);
  }, timeout: perTest);

  testWidgets('TEI-F2 远程保存失败：必须提示，且不能假装成功关页',
      (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => false, remoteName: '端点X');
    await tapSave(tester);
    await waitFor(
      tester,
      () => find.textContaining('端点未确认').evaluate().isNotEmpty,
      reason: '端点拒绝时应给出可读提示',
    );
    // 关键：页面**不能**关掉 —— 关掉等于告诉用户"存上了"。
    expect(find.text('保存任务'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEI-F3 校验：每周一个都没选 → 拦下并提示（不静默保存）',
      (tester) async {
    Task? saved;
    await pumpEditor(tester, remoteSave: (t) async {
      saved = t;
      return true;
    });
    await tester.tap(chip('每周定时'));
    await tester.pump();
    for (final d in ['一', '二', '三', '四', '五']) {
      await tester.tap(fchip(d));
      await tester.pump();
    }
    await tapSave(tester);
    expect(find.text('请至少选择一个星期'), findsOneWidget);
    expect(saved, isNull, reason: '校验失败不得保存');
  }, timeout: perTest);

  testWidgets('TEI-F4 保存：六种触发类型产出的 trigger 类型都对',
      (tester) async {
    // 显式列出"期望的实例类型"而不是拿字符串猜 —— 猜法一旦和命名脱节就恒真。
    final cases = <(String, TriggerType, Type)>[
      ('固定一次', TriggerType.fixedOnce, FixedOnceTrigger),
      ('每天定时', TriggerType.dailyAt, DailyTrigger),
      ('每周定时', TriggerType.weeklyAt, WeeklyTrigger),
      ('随机窗口', TriggerType.randomWindow, RandomWindowTrigger),
      ('随机间隔', TriggerType.randomInterval, RandomIntervalTrigger),
      ('声音触发', TriggerType.soundTriggered, SoundTrigger),
    ];
    for (final (chipLabel, expected, expectedType) in cases) {
      Task? sent;
      await pumpEditor(tester, remoteSave: (t) async {
        sent = t;
        return true;
      });
      await tester.tap(chip(chipLabel));
      await tester.pump();
      await tapSave(tester);
      await tester.pump();
      expect(sent, isNotNull, reason: '$chipLabel 应能保存');
      expect(sent!.triggerType, expected);
      // 类型字段与 payload 实例必须一致 —— 否则会出现"类型写对了、
      // 载荷还是上一个"的静默错配（引擎按 triggerType 调度，会崩在运行时）。
      expect(sent!.trigger.runtimeType, expectedType,
          reason: '$chipLabel 的 trigger 实例应与 triggerType 匹配');
    }
  }, timeout: perTest);

  testWidgets('TEI-F5 保存：七种动作类型产出的 actionType 都对',
      (tester) async {
    final cases = <(String, ActionType, String)>[
      ('随机播放', ActionType.playAudio, '随机播放'),
      ('声景混音', ActionType.soundscape, '声景混音'),
      ('语音播报', ActionType.tts, '语音播报'),
      ('录音取证', ActionType.recordEvidence, '录音取证'),
      ('通知', ActionType.notify, '通知'),
      ('通知+播放', ActionType.composite, '通知+播放'),
      ('随机指令集', ActionType.randomFrom, '随机指令集'),
    ];
    for (final (chipLabel, expected, _) in cases) {
      Task? sent;
      await pumpEditor(tester, remoteSave: (t) async {
        sent = t;
        return true;
      });
      await tester.tap(chip(chipLabel));
      await tester.pump();
      // 声景至少 1 轨、随机指令集至少 2 个候选 —— 模型层有 assert 兜底，
      // 这里先满足前置条件（见 TEI-F7：不满足时的行为是**另一个**问题）。
      if (chipLabel == '声景混音') {
        await tester.tap(find.widgetWithText(ActionChip, '＋自然'));
        await tester.pump();
      }
      if (chipLabel == '随机指令集') {
        // 五种候选**全加一遍** —— 保存时每一种都对应 `_buildTask` 里一条
        // 独立分支，少加一种就少走一条（play/tts/notify/vibrate/record）。
        for (final k in ['＋播放音频', '＋语音播报', '＋通知', '＋震动', '＋录音取证']) {
          await tester.tap(find.widgetWithText(ActionChip, k));
          await tester.pump();
        }
      }
      await tapSave(tester);
      await tester.pump();
      expect(sent, isNotNull, reason: '$chipLabel 应能保存');
      expect(sent!.actionType, expected, reason: '$chipLabel 的 actionType');
    }
  }, timeout: perTest);

  testWidgets('TEI-F6 保存：关掉通话保护必须落**显式 false** 的条件对象',
      (tester) async {
    Task? sent;
    await pumpEditor(tester, remoteSave: (t) async {
      sent = t;
      return true;
    });
    await tester.tap(find.widgetWithText(SwitchListTile, '通话中不执行'));
    await tester.pump();
    await tapSave(tester);
    await tester.pump();
    expect(sent, isNotNull);
    // 这是 BUG-061 同源的语义：不落条件对象的话，引擎的默认条件
    // （skipInCall=true）会把它覆盖回去 → 用户"关了开关但没用"。
    expect(sent!.condition, isNotNull,
        reason: '关掉安全默认必须留一个显式条件，不能返回 null 让默认值顶回来');
    expect(sent!.condition!.skipInCall, isFalse);
  }, timeout: perTest);

  // ── BUG-067：前置条件不足时必须"提示"而不是"崩" ──────────────────────
  //
  // `SoundscapeAction`(1–4 轨) / `ActionSetAction`(2–12 候选) 的构造期 assert
  // 在编辑器里**没有前置校验**，而 `_save()` 是 `async` —— 断言抛出会变成
  // **未处理的 Future 错误**：debug 下红屏；**release 下 assert 被剥离 →
  // 静默存下一个 0 轨声景 / 0 候选动作集**（到点什么都不播）。
  //
  // ⚠️ 这种抛出**不能**用 `tester.takeException()` 观察 —— 它是 Future 错误，
  // 走 zone 的 onError 直接判测试失败（实测 `takeException()` 返回 null，
  // 失败信息挂在测试体外）。所以判据只能是"提示文案出现 + 没保存"。

  testWidgets('TEI-F7a 声景 0 轨就保存 → 提示，不崩、不落库', (tester) async {
    Task? sent;
    await pumpEditor(tester, remoteSave: (t) async {
      sent = t;
      return true;
    });
    await tester.tap(chip('声景混音'));
    await tester.pump();
    await tapSave(tester);
    expect(find.text('声景混音至少需要 1 条轨道'), findsOneWidget);
    expect(sent, isNull, reason: '前置条件不足不得保存');
  }, timeout: perTest);

  testWidgets('TEI-F7b 随机指令集候选不足 2 个就保存 → 提示，不崩、不落库',
      (tester) async {
    Task? sent;
    await pumpEditor(tester, remoteSave: (t) async {
      sent = t;
      return true;
    });
    await tester.tap(chip('随机指令集'));
    await tester.pump();
    // 0 个候选
    await tapSave(tester);
    expect(find.text('随机指令集至少需要 2 个候选动作'), findsOneWidget);
    expect(sent, isNull);

    // 1 个候选同样不满足（1 个候选谈不上"随机"）。
    await tester.tap(find.widgetWithText(ActionChip, '＋震动'));
    await tester.pump();
    await tapSave(tester);
    expect(sent, isNull, reason: '只有 1 个候选仍不满足"随机"语义');
  }, timeout: perTest);
}
