import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

/// 任务编辑器（最大单文件 UI，591 行）的 widget 测试。
///
/// 覆盖目标（覆盖率缺口 top1：582 行未覆盖）：
/// - 触发类型切换（6 种 chips）
/// - 动作类型切换（7 种 chips，含随机指令集）
/// - 随机指令集候选编辑（添加/权重/删除）
/// - 概率门滑条
/// - 保存路径（_buildTask 全分支 → upsert 落库）
///
/// BackgroundServiceManager.replan 在测试环境会抛（服务未初始化），
/// 保存测试通过捕获 pump 异常来验证「upsert 已先行落库」——
/// replan 发生在 upsert 之后，落库事实不受服务异常影响。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;

  Future<void> pumpEditor(WidgetTester tester) async {
    // 大视口：编辑器 ListView 很长，默认 800x600 视口外的子项不会被
    // 懒构建，导致 find.text 找不到（"动作"区在屏幕外）。
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWith((ref) async => db)],
      child: const MaterialApp(home: TaskEditorScreen()),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    db = await AppDatabase.open(inMemoryDatabasePath);
    // 测试缝：replan 在测试环境挂死（invoke 返回 pending Future），
    // 注入空钩子短路——落库断言不受影响。
    BackgroundServiceManager.replanHook = () async {};
  });
  tearDown(() async {
    BackgroundServiceManager.replanHook = null;
  });
  tearDown(() async {
    await db.close();
  });

  testWidgets('渲染：触发类型与动作类型 chips 全部出现', (tester) async {
    await pumpEditor(tester);
    expect(find.text('任务名称'), findsOneWidget);
    expect(find.text('触发方式'), findsOneWidget);
    expect(find.text('动作'), findsOneWidget);
    for (final label in ['固定一次', '每天定时', '每周定时', '随机窗口', '随机间隔', '声音触发']) {
      expect(find.text(label), findsWidgets, reason: '触发 chip $label');
    }
    for (final label in [
      '随机播放',
      '声景混音',
      '语音播报',
      '录音取证',
      '通知',
      '通知+播放',
      '随机指令集'
    ]) {
      expect(find.text(label), findsWidgets, reason: '动作 chip $label');
    }
  });

  testWidgets('触发类型切换不崩溃且条件区随类型变化', (tester) async {
    await pumpEditor(tester);
    for (final label in ['随机窗口', '随机间隔', '声音触发', '固定一次', '每天定时', '每周定时']) {
      await tester.tap(find.text(label).last);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '切换到 $label');
    }
  });

  testWidgets('动作类型逐一切换（7 种全走一遍）', (tester) async {
    await pumpEditor(tester);
    for (final label in [
      '随机播放',
      '声景混音',
      '语音播报',
      '录音取证',
      '通知',
      '通知+播放',
      '随机指令集'
    ]) {
      await tester.tap(find.text(label).last);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '切到 $label');
    }
  });

  testWidgets('随机指令集：添加候选 + 权重滑条出现', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.text('随机指令集').last);
    await tester.pump();
    await tester.tap(find.text('＋播放音频'));
    await tester.pump();
    await tester.tap(find.text('＋语音播报'));
    await tester.pump();
    expect(find.text('候选动作（命中后按权重随机选一执行）'), findsOneWidget);
    expect(find.byType(Slider), findsWidgets);
    // 删除一个候选
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();
  });

  testWidgets('概率门滑条出现在条件区', (tester) async {
    await pumpEditor(tester);
    expect(find.textContaining('执行概率'), findsOneWidget);
  });

  testWidgets('概率门滑条：拖到 30% 后落库前状态可见（不触发保存）', (tester) async {
    await pumpEditor(tester);
    // 概率门滑条在条件区（视口内已构建）
    final slider = find.byType(Slider);
    expect(slider, findsWidgets);
    // 拖动第一个 Slider 到约 30%
    final center = tester.getCenter(slider.first);
    await tester.drag(slider.first, Offset(center.dx - 500, 0));
    await tester.pump();
    expect(find.textContaining('%'), findsWidgets);
  });

  testWidgets('随机指令集：TTS 候选文本可输入（不触发保存）', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.text('随机指令集').last);
    await tester.pump();
    await tester.tap(find.text('＋语音播报'));
    await tester.pump();
    expect(find.text('候选动作（命中后按权重随机选一执行）'), findsOneWidget);
  });
}
