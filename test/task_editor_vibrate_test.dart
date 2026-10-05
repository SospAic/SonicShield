import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

/// 任务编辑器 · **振动三模式**（固定节奏 / 随机脉冲 / 持续）的表单面。
///
/// 背景：`task_editor_screen.dart` 是全仓**未覆盖行数最多**的文件（202 行），
/// 而 v1.9.0-alpha 新加的振动表单分支**整块**都落在里面 —— 也就是说，
/// 本轮新增的功能在宿主层几乎没被点过。本文件把那 202 行里的
/// **可达部分（195 行）**全部走一遍。
///
/// ## 为什么单开一个文件而不是塞进 `task_editor_deep_test.dart`
///
/// 1. 那份文件的 harness 是**局部函数**（不能 import），复制一份比抽公共
///    helper 更省事，且不会动到已绿的 38 条用例；
/// 2. 振动能力提示条需要**打桩 `sonic_shield/native` 通道** —— 打桩是全局的，
///    混在同一个文件里会让"桥不可用"那条分支再也测不到（顺序依赖）。
///
/// ## 宿主硬约束（技能 `flutter-widget-test-harness`）
///
/// * DB 往返包 `tester.runAsync`；每例 `timeout: 90s`；
/// * 加载态是无限动画 → 不用 `pumpAndSettle` 等它，用 `waitFor` 有界轮询；
/// * 按"关系"定位控件，不按全局下标（下标只在**同一列表内顺序确定**时用，
///   且要写清顺序依据）；
/// * 视口要够高：编辑器是很长的 `ListView`，视口外的子项**不会被构建**，
///   `find` 直接找不到（不是"控件不存在"）。
///
/// ## ⚠️ 本文件**没有**覆盖的 5 行（并且不该假装覆盖）
///
/// 三个振动分支里各有一段"区间起点 > 终点"的前置校验
/// （`_buildTask` 的 `1431-1432` / `1449-1450`），以及
/// `_setIcon`/`_setLabel`/`_buildTask` 里的 `RcStepKind.delay` 分支
/// （`1275` / `1284` / `1412`）。它们**在 debug 下不可达**，原因是：
///
/// * 区间校验：`RandomVibrateAction` / `ContinuousVibrateAction` 的构造期
///   `assert` 已经保证 `min <= max`，而编辑器的两个写入点
///   （`_applyTask` 回填、`_RangeSliderTile.onChanged`）要么由模型保证、
///   要么在 `clamp` 时**先写 min 再拿 min 夹 max** → 永远有序。
///   ⇒ 这条校验的真实保护对象是 **release 构建**（assert 被剥离）里
///   从 DB / 远端拿到的畸形配置。功能上测不到，因此改用 TEV-16 的
///   **源码锁**保证"校验必须在构造之前"，而不是写一条恒绿的假用例。
/// * `RcStepKind.delay`：`stepKindOfAction()` 对任何动作都**不返回** delay
///   （编辑器也没有"＋时延"按钮）→ 那两个 `switch` 分支是穷尽性兜底。
///
/// 这两类都会留在覆盖率缺口里 —— **这是诚实的缺口，不是遗漏**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const perTest = Timeout(Duration(seconds: 90));
  const nativeChannel = MethodChannel('sonic_shield/native');

  late AppDatabase db;

  // ── harness ────────────────────────────────────────────────────────────

  void bigViewport(WidgetTester tester, [Size size = const Size(1080, 8000)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

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

  /// 打桩振动能力探测。传 `null` = 桥不可用（`_probeEnv` 会吞掉异常）。
  void stubCaps(Map<String, Object?>? caps) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'vibrateCapabilities') return caps;
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, null);
    });
  }

  Future<void> pumpEditor(
    WidgetTester tester, {
    Task? initialTask,
    Future<bool> Function(Task)? remoteSave,
    String? taskId,
    Size viewport = const Size(1080, 8000),
  }) async {
    bigViewport(tester, viewport);
    RemoteTaskTarget? remote;
    if (remoteSave != null) {
      remote = RemoteTaskTarget(endpointName: '端点', save: remoteSave);
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await waitFor(
        tester,
        () => find.text('任务名称').evaluate().isNotEmpty,
        reason: '按 id 读库后编辑器应渲染完成（不再是加载态）',
      );
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.text('保存任务'));
    await tester.pump();
    await tester.pump();
  }

  // ── 定位辅助 ───────────────────────────────────────────────────────────

  Finder chip(String label) => find.widgetWithText(ChoiceChip, label);

  String textOf(WidgetTester tester, Finder f) =>
      tester.widget<Text>(f).data ?? '';

  bool switchValue(WidgetTester tester, String title) =>
      tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title))
          .value;

  String switchSubtitle(WidgetTester tester, String title) {
    final tile = tester
        .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title));
    return (tile.subtitle! as Text).data!;
  }

  /// 拖一条 `RangeSlider`。`drag` 的起点会被离散成该处数值再按 dx 移动 →
  /// `onChanged` 必被调用。用 ± 大位移保证跨过多个 division。
  Future<void> dragIt(WidgetTester tester, Finder f, double dx) async {
    await tester.drag(f, Offset(dx, 0));
    await tester.pump();
  }

  /// `_IntStepper` 的加减按钮 —— 限定在"含该 label 的那个 ListTile"里，
  /// 避免跨行错配（同一个 builder 里好几个步进器长得一模一样）。
  Finder stepperBtn(String label, IconData icon) => find.descendant(
        of: find.ancestor(
            of: find.textContaining(label), matching: find.byType(ListTile)),
        matching: find.byIcon(icon),
      );

  /// 选中一个振动 chip 并把表单渲染出来。
  Future<void> pickVibrate(WidgetTester tester, String label) async {
    await tester.tap(chip(label));
    await tester.pump();
  }

  // ── 夹具 ───────────────────────────────────────────────────────────────

  setUp(() async {
    db = await AppDatabase.open(inMemoryDatabasePath);
    BackgroundServiceManager.replanHook = () async {};
  });
  tearDown(() async {
    BackgroundServiceManager.replanHook = null;
    await db.close();
  });

  Task taskWith({
    required ActionType actionType,
    required ActionConfig action,
    String name = '振动任务',
  }) =>
      Task(
        id: 'v1',
        name: name,
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 7)),
        actionType: actionType,
        action: action,
        assetIds: const [],
        cooldownSec: 300,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  /// 回填 + 保存的通用夹具：返回 `_buildTask` 真正交出去的那个 Task。
  Future<Task?> pumpAndCapture(
    WidgetTester tester, {
    required ActionType actionType,
    required ActionConfig action,
    Future<void> Function(WidgetTester)? beforeSave,
  }) async {
    Task? sent;
    await pumpEditor(
      tester,
      initialTask: taskWith(actionType: actionType, action: action),
      remoteSave: (t) async {
        sent = t;
        return true;
      },
    );
    if (beforeSave != null) await beforeSave(tester);
    await tapSave(tester);
    await tester.pump();
    return sent;
  }

  // ══════════════════════════════════════════════════════════════════════
  // TEV-A · 回填：`_applyTask` 的三个振动分支（此前 0 覆盖）
  //
  // 这三个分支缺失时的后果最严重：`_actionKind` 会停在默认的 `play`，
  // 用户打开一个振动任务再保存 → **静默变成播放任务**（连 action_json
  // 都被覆盖）。所以回填不只是"显示对不对"，是数据完整性问题。
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEV-01 回填 · 固定节奏：模式串回到 InputChip，步数写对',
      (tester) async {
    await pumpEditor(
      tester,
      initialTask: taskWith(
        actionType: ActionType.vibrate,
        action: const VibrateAction(patternMs: [0, 500, 250]),
      ),
      remoteSave: (t) async => true,
    );
    expect(tester.widget<ChoiceChip>(chip('震动·固定节奏')).selected, isTrue,
        reason: 'actionKind 必须回到 vibrateFixed，不能停在默认 play');
    expect(tester.widget<ChoiceChip>(chip('随机播放')).selected, isFalse);
    for (final ms in ['0ms', '500ms', '250ms']) {
      expect(find.widgetWithText(InputChip, ms), findsOneWidget,
          reason: '模式串第 $ms 步应回到可点击的格子');
    }
    expect(find.textContaining('共 3 步'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEV-02 回填 · 随机脉冲：八项参数逐项回到控件', (tester) async {
    await pumpEditor(
      tester,
      initialTask: taskWith(
        actionType: ActionType.randomVibrate,
        action: const RandomVibrateAction(
          durationSecMin: 4,
          durationSecMax: 20,
          pulseOnMsMin: 100,
          pulseOnMsMax: 300,
          pulseOffMsMin: 50,
          pulseOffMsMax: 900,
          amplitudeMin: 0.2,
          amplitudeMax: 0.8,
          maxPulses: 55,
          rampUpSec: 7,
          respectDnd: false,
        ),
      ),
      remoteSave: (t) async => true,
    );
    expect(tester.widget<ChoiceChip>(chip('震动·随机脉冲')).selected, isTrue);
    expect(find.text('总时长（秒）：4s ~ 20s'), findsOneWidget);
    expect(find.text('单次振动时长（毫秒）：100ms ~ 300ms'), findsOneWidget);
    expect(find.text('脉冲间隔（毫秒）：50ms ~ 900ms'), findsOneWidget);
    expect(find.text('强度：20% ~ 80%'), findsOneWidget);
    expect(find.text('脉冲数上限（防爆护栏）：55'), findsOneWidget);
    expect(find.text('渐强（秒，0=关闭）：7'), findsOneWidget);
    // ⚠️ 勿扰开关是**安全项**：回填必须还原真实值，不能被默认 true 顶掉。
    expect(switchValue(tester, '遵循系统勿扰'), isFalse);
    expect(switchSubtitle(tester, '遵循系统勿扰'), contains('穿透系统勿扰'));
  }, timeout: perTest);

  testWidgets('TEV-03 回填 · 持续振动：十项参数逐项回到控件', (tester) async {
    await pumpEditor(
      tester,
      initialTask: taskWith(
        actionType: ActionType.continuousVibrate,
        action: const ContinuousVibrateAction(
          durationSecMin: 12,
          durationSecMax: 45,
          amplitudeMin: 0.3,
          amplitudeMax: 0.9,
          jitterMs: 250,
          sharpnessMin: 0.1,
          sharpnessMax: 0.6,
          dutyCyclePct: 80,
          rampUpSec: 5,
          rampDownSec: 6,
          respectDnd: false,
        ),
      ),
      remoteSave: (t) async => true,
    );
    expect(tester.widget<ChoiceChip>(chip('震动·持续')).selected, isTrue);
    expect(find.text('总时长（秒）：12s ~ 45s'), findsOneWidget);
    expect(find.text('随机振幅：30% ~ 90%'), findsOneWidget);
    expect(find.text('强度波动周期（毫秒，0=恒定）：250'), findsOneWidget);
    expect(find.text('锐度（仅 Android 16 生效）：0.10 ~ 0.60'), findsOneWidget);
    expect(find.text('占空比（%，100=不停顿）：80'), findsOneWidget);
    expect(find.text('渐强（秒）：5'), findsOneWidget);
    expect(find.text('渐弱（秒）：6'), findsOneWidget);
    expect(switchValue(tester, '遵循系统勿扰'), isFalse);
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════════
  // TEV-B · 三种表单的控件回调
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEV-04 固定节奏：点格 +50ms，超过 1000ms 回卷到 50ms',
      (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await pickVibrate(tester, '震动·固定节奏');
    // 默认 [0, 300, 200, 300]。
    expect(find.widgetWithText(InputChip, '0ms'), findsOneWidget);
    await tester.tap(find.widgetWithText(InputChip, '0ms'));
    await tester.pump();
    expect(find.widgetWithText(InputChip, '50ms'), findsOneWidget,
        reason: '点一下应 +50ms');
    expect(find.widgetWithText(InputChip, '0ms'), findsNothing);
  }, timeout: perTest);

  testWidgets('TEV-05 固定节奏：≥1000ms 的格子点一下回到 50ms（回卷分支）',
      (tester) async {
    await pumpEditor(
      tester,
      initialTask: taskWith(
        actionType: ActionType.vibrate,
        // 只放两格：1000ms 触发回卷，300 保持不动作对照。
        action: const VibrateAction(patternMs: [1000, 300]),
      ),
      remoteSave: (t) async => true,
    );
    await tester.tap(find.widgetWithText(InputChip, '1000ms'));
    await tester.pump();
    expect(find.widgetWithText(InputChip, '50ms'), findsOneWidget,
        reason: '超过 1000ms 应回卷到 50ms，而不是变成 1050ms');
    expect(find.widgetWithText(InputChip, '1050ms'), findsNothing);
  }, timeout: perTest);

  testWidgets('TEV-06 随机脉冲：四条区间滑条 + 两个步进器 + 勿扰开关',
      (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await pickVibrate(tester, '震动·随机脉冲');
    // 顺序依据：`_vibrateRandomInputs()` 里的**书写顺序** ——
    // 0=总时长、1=单次振动时长、2=脉冲间隔、3=强度。
    expect(find.byType(RangeSlider), findsNWidgets(4),
        reason: '随机脉冲正好四条区间滑条');

    const labels = ['总时长（秒）：', '单次振动时长（毫秒）：', '脉冲间隔（毫秒）：', '强度：'];
    for (var i = 0; i < labels.length; i++) {
      final before = textOf(tester, find.textContaining(labels[i]));
      await dragIt(tester, find.byType(RangeSlider).at(i), -200);
      expect(textOf(tester, find.textContaining(labels[i])), isNot(before),
          reason: '拖第 $i 条滑条应改变「${labels[i]}」的显示值');
    }

    // 步进器：脉冲数上限（1..1000）与渐强（0..600）。
    await tester.tap(stepperBtn('脉冲数上限（防爆护栏）', Icons.add_circle_outline));
    await tester.pump();
    expect(find.text('脉冲数上限（防爆护栏）：201'), findsOneWidget);
    await tester.tap(stepperBtn('脉冲数上限（防爆护栏）', Icons.remove_circle_outline));
    await tester.pump();
    expect(find.text('脉冲数上限（防爆护栏）：200'), findsOneWidget);
    await tester.tap(stepperBtn('渐强（秒，0=关闭）', Icons.add_circle_outline));
    await tester.pump();
    expect(find.text('渐强（秒，0=关闭）：1'), findsOneWidget);

    // 勿扰开关：默认开 → 关掉后文案必须**明说会穿透勿扰**。
    expect(switchValue(tester, '遵循系统勿扰'), isTrue);
    await tester.tap(find.widgetWithText(SwitchListTile, '遵循系统勿扰'));
    await tester.pump();
    expect(switchValue(tester, '遵循系统勿扰'), isFalse);
    expect(switchSubtitle(tester, '遵循系统勿扰'), contains('穿透系统勿扰'),
        reason: '关掉安全开关必须写明后果，不能只是状态变了');
  }, timeout: perTest);

  testWidgets('TEV-07 持续振动：三条区间滑条 + 四个步进器 + 勿扰开关',
      (tester) async {
    await pumpEditor(tester, remoteSave: (t) async => true);
    await pickVibrate(tester, '震动·持续');
    // 顺序依据：`_vibrateContinuousInputs()` 的书写顺序 ——
    // 0=总时长、1=随机振幅、2=锐度。
    expect(find.byType(RangeSlider), findsNWidgets(3));

    const labels = ['总时长（秒）：', '随机振幅：', '锐度（仅 Android 16 生效）：'];
    for (var i = 0; i < labels.length; i++) {
      final before = textOf(tester, find.textContaining(labels[i]));
      await dragIt(tester, find.byType(RangeSlider).at(i), 200);
      expect(textOf(tester, find.textContaining(labels[i])), isNot(before),
          reason: '拖第 $i 条滑条应改变「${labels[i]}」的显示值');
    }

    await tester.tap(stepperBtn('强度波动周期（毫秒，0=恒定）', Icons.add_circle_outline));
    await tester.pump();
    expect(find.text('强度波动周期（毫秒，0=恒定）：1'), findsOneWidget);
    // 占空比下限是 10%（不能减到 0 —— 0% 占空比 = 不振动，是无效配置）。
    await tester.tap(stepperBtn('占空比（%，100=不停顿）', Icons.remove_circle_outline));
    await tester.pump();
    expect(find.text('占空比（%，100=不停顿）：99'), findsOneWidget);
    await tester.tap(stepperBtn('渐强（秒）：', Icons.add_circle_outline));
    await tester.pump();
    expect(find.text('渐强（秒）：1'), findsOneWidget);
    await tester.tap(stepperBtn('渐弱（秒）：', Icons.add_circle_outline));
    await tester.pump();
    expect(find.text('渐弱（秒）：1'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, '遵循系统勿扰'));
    await tester.pump();
    expect(switchValue(tester, '遵循系统勿扰'), isFalse);
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════════
  // TEV-C · 能力提示条：**不得静默降级**
  //
  // 承诺了振幅/锐度却做不到时必须说出来。四条分支：桥不可用 / 无振动器 /
  // 能力齐全（不该有提示）/ 能力不足（逐条列出）。
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEV-08 能力提示 · 桥不可用 → 明说"读不到"，不假装支持',
      (tester) async {
    // 不打桩：`NativeBridge` 抛 MissingPluginException → `_probeEnv` 吞掉 →
    // `_caps` 保持 null。**注意区分**：这与"设备真的没有振动器"不是一回事。
    await pumpEditor(tester, remoteSave: (t) async => true);
    await pickVibrate(tester, '震动·随机脉冲');
    expect(find.textContaining('无法读取本机振动能力（桥不可用）'), findsOneWidget);
    expect(find.text('本机能力提示'), findsNothing);
  }, timeout: perTest);

  testWidgets('TEV-09 能力提示 · 无振动器 → 明说"振动不会发生"', (tester) async {
    stubCaps(const {
      'hasVibrator': false,
      'hasAmplitudeControl': false,
      'hasEnvelope': false,
      'minControlPointMs': 20,
      'platform': 'none',
      'backgroundSupported': true,
    });
    await pumpEditor(tester, remoteSave: (t) async => true);
    await pickVibrate(tester, '震动·固定节奏');
    await waitFor(
      tester,
      () => find.text('本机能力提示').evaluate().isNotEmpty,
      reason: '能力探测回执到了之后应出现提示卡片',
    );
    expect(find.textContaining('本机无振动器，振动不会发生'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('TEV-10 能力提示 · 能力齐全 → 不显示任何提示（不制造噪声）',
      (tester) async {
    stubCaps(const {
      'hasVibrator': true,
      'hasAmplitudeControl': true,
      'hasEnvelope': true,
      'minControlPointMs': 20,
      'platform': 'android',
      'backgroundSupported': true,
    });
    await pumpEditor(tester, remoteSave: (t) async => true);
    await pickVibrate(tester, '震动·随机脉冲');
    // 先等探测落地（否则"没有提示"可能只是"还没探测到"——恒真的假绿）。
    await waitFor(
      tester,
      () => find.textContaining('无法读取本机振动能力').evaluate().isEmpty,
      reason: '打桩后不该再显示"读不到能力"',
    );
    expect(find.text('本机能力提示'), findsNothing,
        reason: '能力齐全时提示条应完全消失（notes 为空）');
  }, timeout: perTest);

  testWidgets('TEV-11 能力提示 · 能力不足 → 逐条列出降级，且随输入实时更新',
      (tester) async {
    stubCaps(const {
      'hasVibrator': true,
      'hasAmplitudeControl': false, // 强度设置会失效
      'hasEnvelope': false, // 锐度会被忽略
      'minControlPointMs': 20,
      'platform': 'android',
      'backgroundSupported': false, // 后台振动做不到
    });
    await pumpEditor(tester, remoteSave: (t) async => true);
    await pickVibrate(tester, '震动·持续');
    await waitFor(
      tester,
      () => find.text('本机能力提示').evaluate().isNotEmpty,
      reason: '能力不足时应出现提示卡片',
    );
    expect(find.textContaining('本机不支持振幅控制'), findsOneWidget);
    expect(find.textContaining('本平台在后台无法振动'), findsOneWidget);
    // 默认锐度区间是 0~0 ⇒ 用户没要锐度，就不该拿锐度提示打扰他。
    expect(find.textContaining('本机不支持振动锐度'), findsNothing,
        reason: '没设锐度时不该提示锐度不可用');

    // 把锐度拖上去 → 提示必须**当场**出现（而不是等保存才说）。
    final sharpBefore = textOf(tester, find.textContaining('锐度（仅 Android 16 生效）：'));
    await dragIt(tester, find.byType(RangeSlider).at(2), 200);
    expect(textOf(tester, find.textContaining('锐度（仅 Android 16 生效）：')),
        isNot(sharpBefore));
    expect(find.textContaining('本机不支持振动锐度'), findsOneWidget,
        reason: '用户一设锐度，就应立刻知道这台机器做不到');
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════════
  // TEV-D · 保存：`_buildTask` 的三个振动分支（参数不丢）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEV-12 保存 · 固定节奏 → vibrate + patternMs 逐位一致',
      (tester) async {
    const pattern = [0, 500, 250, 900];
    final sent = await pumpAndCapture(
      tester,
      actionType: ActionType.vibrate,
      action: const VibrateAction(patternMs: pattern),
    );
    if (sent == null) fail('固定节奏保存未捕获到 Task');
    expect(sent.actionType, ActionType.vibrate);
    expect(sent.action, isA<VibrateAction>());
    expect((sent.action as VibrateAction).patternMs, pattern,
        reason: '打开再保存不得改动模式串');
  }, timeout: perTest);

  testWidgets('TEV-13 保存 · 随机脉冲 → randomVibrate + 十项参数往返一致',
      (tester) async {
    const src = RandomVibrateAction(
      durationSecMin: 4,
      durationSecMax: 20,
      pulseOnMsMin: 100,
      pulseOnMsMax: 300,
      pulseOffMsMin: 50,
      pulseOffMsMax: 900,
      amplitudeMin: 0.2,
      amplitudeMax: 0.8,
      maxPulses: 55,
      rampUpSec: 7,
      respectDnd: false,
    );
    final sent = await pumpAndCapture(
      tester,
      actionType: ActionType.randomVibrate,
      action: src,
    );
    if (sent == null) fail('随机脉冲保存未捕获到 Task');
    expect(sent.actionType, ActionType.randomVibrate);
    final a = sent.action as RandomVibrateAction;
    // 逐字段比 —— 不比对整个对象（`ActionConfig` 没实现 `==`，
    // `expect(a, src)` 会退化成同一性比较而恒假）。
    expect(a.durationSecMin, 4);
    expect(a.durationSecMax, 20);
    expect(a.pulseOnMsMin, 100);
    expect(a.pulseOnMsMax, 300);
    expect(a.pulseOffMsMin, 50);
    expect(a.pulseOffMsMax, 900);
    expect(a.amplitudeMin, 0.2);
    expect(a.amplitudeMax, 0.8);
    expect(a.maxPulses, 55);
    expect(a.rampUpSec, 7);
    // ⚠️ 安全项：关掉的勿扰开关必须**显式落 false**，不能被默认值顶回 true。
    expect(a.respectDnd, isFalse);
  }, timeout: perTest);

  testWidgets('TEV-14 保存 · 持续振动 → continuousVibrate + 十一项参数往返一致',
      (tester) async {
    const src = ContinuousVibrateAction(
      durationSecMin: 12,
      durationSecMax: 45,
      amplitudeMin: 0.3,
      amplitudeMax: 0.9,
      jitterMs: 250,
      sharpnessMin: 0.1,
      sharpnessMax: 0.6,
      dutyCyclePct: 80,
      rampUpSec: 5,
      rampDownSec: 6,
      respectDnd: false,
    );
    final sent = await pumpAndCapture(
      tester,
      actionType: ActionType.continuousVibrate,
      action: src,
    );
    if (sent == null) fail('持续振动保存未捕获到 Task');
    expect(sent.actionType, ActionType.continuousVibrate);
    final a = sent.action as ContinuousVibrateAction;
    expect(a.durationSecMin, 12);
    expect(a.durationSecMax, 45);
    expect(a.amplitudeMin, 0.3);
    expect(a.amplitudeMax, 0.9);
    expect(a.jitterMs, 250);
    expect(a.sharpnessMin, 0.1);
    expect(a.sharpnessMax, 0.6);
    expect(a.dutyCyclePct, 80);
    expect(a.rampUpSec, 5);
    expect(a.rampDownSec, 6);
    expect(a.respectDnd, isFalse);
  }, timeout: perTest);

  testWidgets('TEV-15 校验 · 固定节奏不足 2 个数值 → 提示且不保存（不崩）',
      (tester) async {
    Task? sent;
    await pumpEditor(
      tester,
      initialTask: taskWith(
        actionType: ActionType.vibrate,
        // `VibrateAction` 对 patternMs **没有** assert，所以这种畸形配置
        // 在 debug 下也能造出来（旧数据 / 手改 json）。
        action: const VibrateAction(patternMs: [0]),
      ),
      remoteSave: (t) async {
        sent = t;
        return true;
      },
    );
    await tapSave(tester);
    expect(find.text('固定节奏至少需要 2 个数值（延迟 + 振动时长）'), findsOneWidget);
    expect(sent, isNull, reason: '前置条件不足不得保存');
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════════
  // TEV-E · 夜间独立豁免：第二把钥匙（编辑器侧）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEV-16 夜间豁免 · 主开关已开时第二把钥匙可用且能双向切换',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {PrefsKeys.quietExemptMaster: true});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    // ⚠️ 必须走**本机模式**：`_quietExemptTile()` 只在 `remoteTarget == null`
    // 时渲染（远程任务属于端点设备，豁免权在本机设置里，不归端点）。
    await pumpEditor(tester);
    // `_probeEnv` 读 prefs 是异步的 → 等开关变成可用。
    await waitFor(
      tester,
      () => tester
          .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, '本任务豁免免打扰'))
          .onChanged !=
          null,
      reason: '主开关已开时，任务级开关应解除置灰',
    );
    expect(switchValue(tester, '本任务豁免免打扰'), isFalse,
        reason: '任务级默认关闭 —— 缺一把钥匙就回受约束的一侧');
    expect(find.textContaining('主开关关闭时'), findsNothing);

    await tester.tap(find.widgetWithText(SwitchListTile, '本任务豁免免打扰'));
    await tester.pump();
    expect(switchValue(tester, '本任务豁免免打扰'), isTrue);
    expect(switchSubtitle(tester, '本任务豁免免打扰'), contains('已开启'),
        reason: '开启后要写明"照常执行且每次写日志"');
  }, timeout: perTest);

  testWidgets('TEV-17 夜间豁免 · 主开关未开时置灰，且写明为什么', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    await pumpEditor(tester);
    final tile =
        tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '本任务豁免免打扰'));
    expect(tile.onChanged, isNull, reason: '主开关未开时第二把钥匙必须不可用');
    expect(tile.value, isFalse);
    expect(find.textContaining('主开关关闭时，本开关不生效'), findsOneWidget);
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════════
  // TEV-F · 源码锁：release 构建下的前置校验
  // ══════════════════════════════════════════════════════════════════════

  test('TEV-18 源码锁 · 三个振动分支都必须"先校验、再构造"', () {
    // 为什么需要这条锁：
    // 区间约束的**唯一 debug 保障**是模型 assert，而 assert 在 release
    // 被剥离 —— 从 DB / 远端拿到 `min > max` 的畸形配置时，`_save()` 是
    // `async`，构造期抛出会变成**未处理的 Future 错误**（BUG-067 同形：
    // debug 红屏 / release 静默存下无效配置）。因此编辑器必须在构造**之前**
    // 自己校验并给出可读提示。
    //
    // 那两条 `if` 在 debug 下**不可达**（模型 assert 与滑块 clamp 共同保证
    // 有序），功能用例写不出来 → 只能锁"它还在、而且在构造之前"。
    final src =
        File('lib/features/tasks/task_editor_screen.dart').readAsStringSync();

    String branchOf(String kind) {
      // ⚠️ `indexOf` 会命中 `_actionInputs` 里的那个 `case`（它在前），
      // 而前置校验在 `_buildTask` 里 —— 必须取**最后**一个。
      final start = src.lastIndexOf('case ActionKindChoice.$kind:');
      expect(start, greaterThan(0), reason: '找不到 $kind 分支（改名了？）');
      final rest = src.substring(start);
      // 取到下一个 `case ActionKindChoice.` 为止 —— **不写死缩进**
      // （原 `indexOf('\n      case ')` 依赖 6 空格缩进，缩进一变就静默切错
      // 区间；见 test/support/source_text.dart / A12）。
      final next = RegExp(r'\n[ \t]*case ActionKindChoice\.').firstMatch(rest);
      return next == null ? rest : rest.substring(0, next.start);
    }

    const guards = <String, String>{
      'vibrateFixed': '固定节奏至少需要 2 个数值',
      'vibrateRandom': '随机振动的区间起点不能大于终点',
      'vibrateContinuous': '持续振动的区间起点不能大于终点',
    };

    for (final e in guards.entries) {
      final body = branchOf(e.key);
      final guardAt = body.indexOf(e.value);
      final ctorAt = body.indexOf('action = ');
      expect(guardAt, greaterThan(-1),
          reason: '${e.key} 分支缺少前置校验提示：「${e.value}」');
      expect(ctorAt, greaterThan(-1), reason: '${e.key} 分支应构造 action');
      expect(guardAt, lessThan(ctorAt),
          reason: '${e.key}：校验必须发生在构造之前，否则等于没校验');
      expect(body.contains('return null;'), isTrue,
          reason: '${e.key}：校验失败必须直接返回，不能继续构造');
    }
  });

  test('TEV-19 源码锁 · 振动表单与执行器共用同一张规格表（唯一真源）', () {
    // 编辑器的手写控件集 与 `rcVibrateFields` 规格表**必须**逐字段对齐：
    // 漏一个字段的后果是"界面上改不了"（用户看不到）而不是抛异常，
    // 因此只能靠锁（与 LBL-01..05 同一判据）。
    final src =
        File('lib/features/tasks/task_editor_screen.dart').readAsStringSync();
    // 随机脉冲的构造参数：模型字段名 → 编辑器是否真的读了对应状态变量。
    const randomFields = <String, String>{
      'durationSecMin': '_rvDurMin',
      'durationSecMax': '_rvDurMax',
      'pulseOnMsMin': '_rvOnMin',
      'pulseOnMsMax': '_rvOnMax',
      'pulseOffMsMin': '_rvOffMin',
      'pulseOffMsMax': '_rvOffMax',
      'amplitudeMin': '_rvAmpMin',
      'amplitudeMax': '_rvAmpMax',
      'maxPulses': '_rvMaxPulses',
      'rampUpSec': '_rvRampUp',
      'respectDnd': '_rvRespectDnd',
    };
    const continuousFields = <String, String>{
      'durationSecMin': '_cvDurMin',
      'durationSecMax': '_cvDurMax',
      'amplitudeMin': '_cvAmpMin',
      'amplitudeMax': '_cvAmpMax',
      'jitterMs': '_cvJitterMs',
      'sharpnessMin': '_cvSharpMin',
      'sharpnessMax': '_cvSharpMax',
      'dutyCyclePct': '_cvDutyPct',
      'rampUpSec': '_cvRampUp',
      'rampDownSec': '_cvRampDown',
      'respectDnd': '_cvRespectDnd',
    };
    // `_buildTask` 是唯一把表单状态交给领域模型的出口 → 就在它里面查。
    //
    // ⚠️ 切片必须从 `_buildTask` 的**声明**开始：三个振动 chip 的 `case`
    // 在 `_actionInputs` 里也各出现一次，从那儿切会把 `_vibrateXxxInputs()`
    // 的构造参数一并框进来 → 锁会**恒真**（`_buildTask` 真丢字段也扫不出来）。
    final buildStart = src.indexOf('Task? _buildTask()');
    expect(buildStart, greaterThan(0), reason: '找不到 `_buildTask` 声明');
    final buildEnd = src.indexOf('case ActionKindChoice.record:', buildStart);
    expect(buildEnd, greaterThan(buildStart), reason: '`_buildTask` 切片右界没找到');
    final build = src.substring(buildStart, buildEnd);

    for (final e in {...randomFields, ...continuousFields}.entries) {
      expect(build.contains('${e.key}: ${e.value}'),
          isTrue,
          reason: '`_buildTask` 里缺少 `${e.key}: ${e.value}` —— '
              '模型字段与表单状态脱节，该字段在界面上将永远改不了');
    }
  });

  test('TEV-20 源码锁 · 自检：以上两条锁的扫描器本身能失败', () {
    // 防空转哨兵：如果 `branchOf` / 字段表因为改名而扫到空串，
    // 上面两条锁会**恒真**（扫不到东西自然"不缺"）。这里正面验证
    // "拿一个不存在的名字去扫，必然扫不到"。
    final src =
        File('lib/features/tasks/task_editor_screen.dart').readAsStringSync();
    expect(src.contains('case ActionKindChoice.vibrateFixed:'), isTrue,
        reason: '文件里应真的有振动分支（否则两条锁在空文件上恒真）');
    expect(src.contains('case ActionKindChoice.nopeNotAThing:'), isFalse,
        reason: '扫描器对不存在的分支必须给出 false —— 证明它真的在读内容');
    expect(src.contains('durationSecMin: _rvDurMin'), isTrue,
        reason: '规格表断言依赖这段文本真实存在（否则锁是空转的）');
    expect(src.contains('durationSecMin: _rvNotAThing'), isFalse);
  });

  // ══════════════════════════════════════════════════════════════════════
  // TEV-G · 端到端：本机保存真的落库（振动任务的完整往返）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('TEV-21 本机落库 · 振动任务写库后按 id 重新打开，参数一字不差',
      (tester) async {
    await dbRead(
      tester,
      () => TaskRepository(db).upsert(taskWith(
            actionType: ActionType.continuousVibrate,
            action: const ContinuousVibrateAction(
              durationSecMin: 15,
              durationSecMax: 25,
              amplitudeMin: 0.25,
              amplitudeMax: 0.75,
              jitterMs: 400,
              dutyCyclePct: 70,
              rampUpSec: 3,
              rampDownSec: 4,
              respectDnd: false,
            ),
          )),
    );
    await pumpEditor(tester, taskId: 'v1');
    expect(find.text('编辑任务'), findsOneWidget);
    await waitFor(
      tester,
      () => find.text('总时长（秒）：15s ~ 25s').evaluate().isNotEmpty,
      reason: '按 id 读库后振动参数应回填',
    );
    expect(find.text('随机振幅：25% ~ 75%'), findsOneWidget);
    expect(find.text('强度波动周期（毫秒，0=恒定）：400'), findsOneWidget);
    expect(find.text('占空比（%，100=不停顿）：70'), findsOneWidget);
    expect(find.text('渐强（秒）：3'), findsOneWidget);
    expect(find.text('渐弱（秒）：4'), findsOneWidget);
    expect(switchValue(tester, '遵循系统勿扰'), isFalse);
  }, timeout: perTest);
}
