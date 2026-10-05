import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sonic_shield/app.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

/// 守卫开关真机探针 v3（验证 BUG-061 修复**真的可见**）。
///
/// 修复前（真机实测）：点开关 -> value 保持 false -> 页面文案里**零解释**。
///
/// 修复后应当：引擎未运行时**立刻**给出 SnackBar 说明，而且**连权限对话框
/// 都不弹**（引擎没跑就没必要问麦克风）—— 后者让这条失败路径在自动化里
/// 变得可观测：不需要 pm grant、不需要真人点系统弹窗。
Future<void> _settle(WidgetTester tester, {int ms = 1500}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

Future<void> _dismissComplianceIfPresent(WidgetTester tester) async {
  final accept = find.widgetWithText(FilledButton, '我已阅读并承诺合法使用');
  if (accept.evaluate().isEmpty) return;
  await tester.tap(accept);
  await _settle(tester, ms: 600);
}

List<String> _visibleTexts(WidgetTester tester) {
  final out = <String>[];
  for (final e in find.byType(Text).evaluate()) {
    final d = (e.widget as Text).data;
    if (d != null && d.isNotEmpty) out.add(d);
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('守卫开关失败必须可见（BUG-061 修复验证）', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SonicShieldApp()));
    await _settle(tester, ms: 2500);
    await _dismissComplianceIfPresent(tester);
    await _settle(tester, ms: 800);

    final mgr = BackgroundServiceManager.instance;
    // ignore: avoid_print
    print('PROBE engine.isRunning=${mgr.isRunning}');

    await tester.tap(find.text('自动化'));
    await _settle(tester, ms: 1200);
    await tester.tap(find.text('守卫'));
    await _settle(tester, ms: 1200);

    final sw = find.byType(Switch);
    if (sw.evaluate().isEmpty) {
      // ignore: avoid_print
      print('PROBE RESULT = 守卫页未找到 Switch');
      // P2-28：这里是**假绿路径** —— 找不到控件直接 return 会让用例"通过"，
      // 守卫开关回归（页面崩 / 路由改名 / 按钮消失）永远无人察觉。
      // 找不到就意味着这条验证根本没跑，必须硬失败。
      fail('守卫页未找到 Switch —— 无法验证 BUG-061 的可见性修复，用例不得以"跳过"名义变绿');
    }
    await tester.tap(sw.first);

    var sawHint = false;
    for (final ms in <int>[300, 500, 1000, 1500]) {
      await _settle(tester, ms: ms);
      final texts = _visibleTexts(tester);
      final hints = texts.where((t) => t.contains('守卫需要') ||
          t.contains('麦克风') ||
          t.contains('引擎无响应'));
      if (hints.isNotEmpty) {
        sawHint = true;
        // ignore: avoid_print
        print('PROBE HINT@${ms}ms = ${hints.toList()}');
        break;
      }
    }
    // ignore: avoid_print
    print('PROBE value=${(tester.widget(sw.first) as Switch).value} '
        'guardActive=${mgr.guardActive}');
    // ignore: avoid_print
    print('PROBE RESULT sawHint=$sawHint');

    expect(sawHint, isTrue,
        reason: 'BUG-061：守卫开关失败必须让用户看见原因，不能静默弹回');
  });
}
