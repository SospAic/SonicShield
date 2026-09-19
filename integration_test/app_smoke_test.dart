import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sonic_shield/app.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:sonic_shield/features/sounds/sound_library_screen.dart';

/// 集成冒烟测试：真机/模拟器上运行（flutter test integration_test -d <device>）。
/// 验证：应用启动 -> 各页面可达 -> 调度端到端物化。
///
/// 注意：页面存在无限动画组件（加载进度条/倒计时刷新），因此使用固定
/// pump 序列而非 pumpAndSettle（后者会因动画永不静止而超时）。
Future<void> _settle(WidgetTester tester, {int ms = 1500}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

/// 关掉**合规承诺**对话框（全新安装时必现）。
///
/// 该对话框是 `barrierDismissible: false`，会**挡住底部导航的点击** ——
/// 不先确认，导航用例必然失败（且报错信息只显示"点了但命中不到"）。
///
/// 为什么"必现"而不是偶发：`flutter test integration_test/...` 每次运行都会
/// **卸载应用**，`SharedPreferences` 里的"已确认"标记随之清空，
/// 于是 `showComplianceGateOnce` 每次都会弹。
Future<void> _dismissComplianceIfPresent(WidgetTester tester) async {
  final accept = find.widgetWithText(FilledButton, '我已阅读并承诺合法使用');
  if (accept.evaluate().isEmpty) return;
  await tester.tap(accept);
  await _settle(tester, ms: 600);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('应用启动并渲染守护仪表盘', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SonicShieldApp()));
    await _settle(tester, ms: 2500);
    await _dismissComplianceIfPresent(tester);
    // 标题与守护开关卡片存在即认为渲染成功。
    expect(find.text('声盾 SonicShield'), findsWidgets);
    expect(
      find.textContaining('守护'),
      findsWidgets,
      reason: '仪表盘应包含守护卡片（开启或关闭态）',
    );
  });

  testWidgets('底部导航五页可达', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SonicShieldApp()));
    await _settle(tester, ms: 2500);
    // 必须先关掉合规承诺对话框，否则它（barrierDismissible=false）会挡住导航点击。
    await _dismissComplianceIfPresent(tester);

    // v1.7 信息架构定稿为 **5 个 TAB**：守护 / 自动化 / 远程 / 日志 / 设置
    // （见 `lib/core/router.dart` 的 `_Shell._destinations`）。
    //
    // ⚠️ 本用例此前用的是 **IA 重构前的旧标签**（任务 / 音源 / 守卫）——
    // 那三页已合并进「自动化」，于是 `find.text('任务').last` 命中零个控件，
    // 抛 `Bad state: No element`。该用例**自 v1.7 IA 重构起就一直是红的**，
    // 却长期没被发现：`integration_test/` 不在默认门禁
    // （`flutter test --exclude-tags perf` 只跑 `test/`）内，只有手动驱动才会执行。
    const tabs = ['守护', '自动化', '远程', '日志', '设置'];
    for (final label in tabs) {
      // 精确限定在 NavigationBar 内查找：仪表盘正文里也有「守护」等字样，
      // 用 `.last` 是碰运气，容易随布局变化而错位。
      final target = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      );
      expect(target, findsWidgets, reason: '底部导航应存在「$label」TAB');
      await tester.tap(target.first);
      await _settle(tester, ms: 800);
      expect(tester.takeException(), isNull, reason: '页面 $label 不应崩溃');
    }
  });

  testWidgets('音源库页面在真实运行时渲染（BUG-047 改动的设备端验证）', (tester) async {
    // 直接 pump 该页面：它现在是 `assetRepoProvider` 的**唯一**数据入口，
    // 仓储解析失败（provider 抛错 / 表结构不匹配）只会表现为一块错误红屏，
    // 而 `takeException()` 能把它变成可断言的失败。
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: SoundLibraryScreen()),
    ));
    await _settle(tester, ms: 2500);
    expect(tester.takeException(), isNull, reason: '音源库页面不应崩溃');

    final empty = find.textContaining('暂无音源');
    final list = find.byType(ListView);
    expect(
      empty.evaluate().isNotEmpty || list.evaluate().isNotEmpty,
      isTrue,
      reason: '仓储读取完成后必须落到"空库提示"或"音源列表"之一',
    );
    expect(find.text('音源库'), findsWidgets);
  });

  test('端到端：任务定义 -> 物化 -> 计划条目可执行语义', () {
    const engine = ScheduleEngine();
    // 使用「明天」作为日期范围：窗口不被 now 截断，且 8:00-21:00
    // 与默认免打扰（22:00-07:00）不重叠 → 断言确定（3 条）。
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final day = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
    final task = Task(
      id: 'e2e-1',
      name: 'E2E',
      enabled: true,
      triggerType: TriggerType.randomWindow,
      trigger: RandomWindowTrigger(
        dateRange: DateRange(start: day, end: day),
        windowStart: const TimeSpec(hour: 8),
        windowEnd: const TimeSpec(hour: 21),
        timesPerDay: 3,
        minGap: const Duration(minutes: 60),
      ),
      actionType: ActionType.playAudio,
      action: const PlayAudioAction(volumeMin: 0.4, volumeMax: 0.8),
      assetIds: const [],
      cooldownSec: 60,
      quietPolicy: QuietPolicy.skip,
      priority: 0,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final entries = engine.materialize(task, DateTime.now());
    expect(entries.length, 3, reason: '明日窗口应物化 3 条计划');
    for (final e in entries) {
      expect(e.occurrenceId, contains('e2e-1'));
      expect(e.volume, inInclusiveRange(0.4, 0.8));
      expect(e.durationMs, inInclusiveRange(3000, 15000));
      expect(e.fireAt.hour, inInclusiveRange(8, 20));
    }
    // 幂等：重算一致。
    final again = engine.materialize(task, DateTime.now());
    expect(again.map((e) => e.fireAt), entries.map((e) => e.fireAt));
  });
}
