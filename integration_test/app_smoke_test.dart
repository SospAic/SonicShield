import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sonic_shield/app.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';

/// 集成冒烟测试：真机/模拟器上运行（flutter test integration_test）。
/// 验证：应用启动 -> 各页面可达 -> 调度端到端物化。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('应用启动并渲染守护仪表盘', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SonicShieldApp()));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.text('声盾 SonicShield'), findsWidgets);
  });

  testWidgets('底部导航六页可达', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SonicShieldApp()));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    for (final label in ['任务', '音源', '守卫', '日志', '设置']) {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(tester.takeException(), isNull, reason: '页面 $label 不应崩溃');
    }
  });

  test('端到端：任务定义 -> 物化 -> 计划条目可执行语义', () {
    const engine = ScheduleEngine();
    final task = Task(
      id: 'e2e-1',
      name: 'E2E',
      enabled: true,
      triggerType: TriggerType.randomWindow,
      trigger: RandomWindowTrigger(
        dateRange: DateRange(start: DateTime.now(), end: DateTime.now()),
        windowStart: const TimeSpec(hour: 0),
        windowEnd: const TimeSpec(hour: 23, minute: 59),
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
    expect(entries.length, 3);
    for (final e in entries) {
      expect(e.occurrenceId, contains('e2e-1'));
      expect(e.volume, inInclusiveRange(0.4, 0.8));
      expect(e.durationMs, inInclusiveRange(3000, 15000));
    }
  });
}
