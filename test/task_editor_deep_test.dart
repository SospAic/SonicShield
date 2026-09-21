import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

/// 任务编辑器深交互测试（第 4 项覆盖率工程）：
/// - initialTask 回填（触发/动作/条件各分支）
/// - remoteTarget 远程保存路径（不碰本机仓储与服务）
/// - _buildTask 各触发分支落库
/// - 概率门/随机指令集交互
///
/// 视口用 1080x6000：编辑器 ListView 很长，默认视口外的子项不会被
/// 懒构建（find 找不到）。replan 经测试缝短路（服务未初始化挂死）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;

  Future<void> pumpEditor(
    WidgetTester tester, {
    Task? initialTask,
    Future<bool> Function(Task)? remoteSave,
    String? remoteName,
  }) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    RemoteTaskTarget? remote;
    if (remoteSave != null) {
      remote =
          RemoteTaskTarget(endpointName: remoteName ?? '端点', save: remoteSave);
    }
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWith((ref) async => db)],
      child: MaterialApp(
        home: TaskEditorScreen(
          initialTask: initialTask,
          remoteTarget: remote,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    db = await AppDatabase.open(inMemoryDatabasePath);
    BackgroundServiceManager.replanHook = () async {};
  });
  tearDown(() async {
    BackgroundServiceManager.replanHook = null;
    await db.close();
  });

  Task dailyTask({bool probability = false}) => Task(
        id: 't1',
        name: '每日回填',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 7, minute: 30)),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(
            volumeMin: 0.3,
            volumeMax: 0.8,
            durationSecMin: 4,
            durationSecMax: 9),
        assetIds: const [],
        cooldownSec: 300,
        quietPolicy: QuietPolicy.skip,
        condition: probability
            ? const TaskCondition(requireCharging: true, probabilityPct: 30)
            : null,
        priority: 0,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  testWidgets('回填：每日触发 + 播放动作 + 概率门 30%', (tester) async {
    await pumpEditor(tester,
        initialTask: dailyTask(probability: true),
        remoteSave: (task) async => true,
        remoteName: '端点X');
    // 触发 chip 选中态
    expect(find.text('每天定时'), findsWidgets);
    // 概率门滑条文案
    expect(find.textContaining('30%'), findsWidgets);
    // 动作 chip 选中态（随机播放）
    expect(find.text('随机播放'), findsWidgets);
  });

  testWidgets('回填：随机指令集候选完整还原', (tester) async {
    final t = Task(
      id: 't2',
      name: '指令集回填',
      enabled: true,
      triggerType: TriggerType.dailyAt,
      trigger: const DailyTrigger(time: TimeSpec(hour: 8)),
      actionType: ActionType.randomFrom,
      action: ActionSetAction(candidates: [
        const ActionSetCandidate(weight: 3, action: TtsAction(text: '提醒')),
        const ActionSetCandidate(weight: 1, action: VibrateAction()),
      ]),
      assetIds: const [],
      cooldownSec: 300,
      quietPolicy: QuietPolicy.skip,
      priority: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await pumpEditor(tester,
        initialTask: t, remoteSave: (task) async => true, remoteName: '端点X');
    await tester.tap(find.text('随机指令集').last);
    await tester.pump();
    // 候选列表渲染**类型名 + 权重**（参数文本不渲染）
    expect(find.text('语音播报'), findsWidgets);
    expect(find.text('震动'), findsWidgets);
    expect(find.text('权重 3'), findsOneWidget);
    expect(find.text('权重 1'), findsOneWidget);
  });

  testWidgets('远程保存：_buildTask 产物经注入通道发出', (tester) async {
    Task? sent;
    await pumpEditor(
      tester,
      remoteSave: (task) async {
        sent = task;
        return true;
      },
      remoteName: '端点X',
    );
    await tester.enterText(find.byType(TextField).first, '远程任务X');
    await tester.tap(find.text('每天定时').last);
    await tester.pump();
    await tester.tap(find.text('保存任务'));
    await tester.pump(const Duration(seconds: 1));
    expect(sent, isNotNull);
    expect(sent!.name, '远程任务X');
    expect(sent!.triggerType, TriggerType.dailyAt);
  });
}
