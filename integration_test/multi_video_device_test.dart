import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sonic_shield/app.dart';

/// 多设备视频页：真机可达性验证。
///
/// 本轮新增「多设备视频同连」入口（远程 → 通话 → 多设备视频同连）。
/// 真机上能否走到这一页、空态是否渲染正常，只有真机能给**真实执行数据** ——
/// 多路 WebRTC 的实际连通性需要 ≥2 台设备，不在本用例覆盖范围。
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('多设备视频页可达且空态正常', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SonicShieldApp()));
    await _settle(tester, ms: 2500);
    await _dismissComplianceIfPresent(tester);
    await _settle(tester, ms: 800);

    await tester.tap(find.text('远程'));
    await _settle(tester, ms: 1200);
    await tester.tap(find.text('通话'));
    await _settle(tester, ms: 1000);

    final entry = find.text('多设备视频同连');
    expect(entry, findsOneWidget, reason: '「远程 → 通话」里应有该入口');
    await tester.tap(entry);
    await _settle(tester, ms: 1500);

    // 进入页面：标题 + 空态提示。
    expect(find.text('多设备视频'), findsOneWidget);
    expect(find.text('还没有视频连接'), findsOneWidget);
    // ignore: avoid_print
    print('PROBE multi-video page OK');
  });
}
