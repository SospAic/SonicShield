import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/ptt_tab.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/permission_stub.dart';
import 'support/record_stub.dart';

/// 对讲机整页（`/remote/ptt`）的宿主测试 —— 第三十二轮新建。
///
/// ## 覆盖边界（刻意回避的只有一条）
///
/// `pttStart()` 拿到权限之后会 `Directory.systemTemp.createTemp('ptt')`，
/// 这是**真实 dart:io**，在 `testWidgets` 的 `FakeAsync` 里不会完成。
/// 因此**录音真正开始的后续**（`Timer.periodic` 计时 / 松开发送 / 分包加密）
/// 不在宿主层测；本文件覆盖的是**它之前与之后的全部判断**：
/// 未选端点、权限被拒、录音启动失败、端点选择落库、松手时未录音的早退。
/// 剩下的由设备层/集成测试补。
///
/// `rc.pttAck` 回执渲染（BUG-046）**不在本文件**：
/// `RcEndpointService` 的事件 `StreamController` 是库内私有字段，
/// 宿主测试无法注入事件；**不为覆盖率在生产代码里开测试专用后门**。
PairedEndpoint _ep(String id, String name) => PairedEndpoint(
    deviceId: id, name: name, secret: 'AB2CD5EF', pairedAt: DateTime.now());

Future<RemoteStore> _pump(
  WidgetTester tester, {
  List<PairedEndpoint> endpoints = const [],
  String selectedEndpointId = '',
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = RemoteStore(prefs);
  for (final e in endpoints) {
    await store.addPaired(e);
  }
  if (selectedEndpointId.isNotEmpty) {
    await store.setSelectedEndpoint(selectedEndpointId);
  }

  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PttTab())));
  await tester.pumpAndSettle();
  return store;
}

/// 按住说话按钮（`GestureDetector` + `CircleAvatar`）。
Finder get _micButton => find.ancestor(
    of: find.byIcon(Icons.mic), matching: find.byType(GestureDetector));

void main() {
  group('PTT 对讲机整页', () {
    testWidgets('PTT-01 未配对 → 明确引导"先完成扫码配对"（不是空白页）', (tester) async {
      await _pump(tester);

      expect(find.textContaining('尚未配对端点'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    });

    testWidgets('PTT-02 无端点时按住 → 提示"请先选择目标端点"', (tester) async {
      // ⚠️ 这条**只能**在没有已配对端点时触发：`initialSelectedId()` 会在
      // 有端点且无持久化选择时**自动选第一个**（remote_store.dart:99），
      // 所以"有端点但没选"这个组合在真实运行中不存在。
      await _pump(tester);

      await tester.tap(_micButton);
      await tester.pumpAndSettle();

      expect(find.text('请先选择目标端点'), findsOneWidget,
          reason: '没目标就按住必须说清楚为什么没反应');
    });

    testWidgets('PTT-03 麦克风被拒 → 提示"需要麦克风权限"且不开始录音', (tester) async {
      final asked = stubPermissions(
          {Permission.microphone: PermissionStatus.denied});
      addTearDown(clearPermissionStub);

      await _pump(tester,
          endpoints: [_ep('0123456789abcdef', '客厅平板')],
          selectedEndpointId: '0123456789abcdef');

      await tester.tap(_micButton);
      await tester.pumpAndSettle();

      expect(asked.single, [Permission.microphone]);
      expect(find.text('需要麦克风权限'), findsOneWidget);
      expect(find.textContaining('录音中'), findsNothing,
          reason: '没权限还进入录音态 ⇒ 用户说完发现没录上');
    });

    testWidgets('PTT-04 麦克风已授权但录音启动失败 → 明确提示（不是静默）', (tester) async {
      final asked = stubPermissions(
          {Permission.microphone: PermissionStatus.granted});
      addTearDown(clearPermissionStub);
      // 平台侧拒绝录音（见 record_stub 头注：避开真实 dart:io 建目录）。
      final recCalls = stubRecord(hasPermission: false);
      addTearDown(clearRecordStub);

      await _pump(tester,
          endpoints: [_ep('0123456789abcdef', '客厅平板')],
          selectedEndpointId: '0123456789abcdef');

      // 选中态要显示在下拉框上，而不是"我以为选了其实没选"。
      expect(find.text('客厅平板'), findsWidgets);

      await tester.tap(_micButton);
      await tester.pumpAndSettle();

      expect(asked.single, [Permission.microphone]);
      expect(recCalls, contains('hasPermission'),
          reason: '必须真的问过录音权限，而不是直接说"失败"');
      expect(find.text('录音启动失败'), findsOneWidget);
      expect(find.text('按住麦克风开始对讲'), findsOneWidget,
          reason: '启动失败必须留在待机态');
      expect(find.text('请先选择目标端点'), findsNothing,
          reason: '已选端点不该再报"未选"');
    });

    testWidgets('PTT-05 有多个端点时渲染对讲目标下拉框（不是让用户盲按）', (tester) async {
      // ⚠️ 本用例**刻意不按住麦克风**：`RcControllerService` 是进程内单例，
      // 其 `AudioRecorder` 只初始化一次 —— 同一进程里第二个用例再走
      // `pttStart()` 会停在插件的 `_safeCall`（`await _createFuture` 之后的
      // 信号量/已完成 Future 组合在宿主里不再推进）。
      // 驱动录音的断言集中在 PTT-04，不重复驱动。
      await _pump(tester, endpoints: [
        _ep('0123456789abcdef', '客厅平板'),
        _ep('fedcba9876543210', '书房音箱'),
      ]);

      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      expect(find.text('客厅平板'), findsWidgets,
          reason: '默认选中第一个，得让用户看见对谁说话');
      expect(find.text('按住麦克风开始对讲'), findsOneWidget);
    });

    testWidgets('PTT-06 切换对讲目标 → 落库 selectedEndpointId（与「我的设备」共享）',
        (tester) async {
      final store = await _pump(tester, endpoints: [
        _ep('0123456789abcdef', '客厅平板'),
        _ep('fedcba9876543210', '书房音箱'),
      ]);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('书房音箱').last);
      await tester.pumpAndSettle();

      expect(store.selectedEndpointId, 'fedcba9876543210',
          reason: '选了不落库 ⇒ 下次进来又回到旧目标（BUG-063 同形态）');
    });

    testWidgets('PTT-07 松手时并未在录音 → 直接早退（不报错、不发空包）', (tester) async {
      stubPermissions({Permission.microphone: PermissionStatus.denied});
      addTearDown(clearPermissionStub);

      await _pump(tester,
          endpoints: [_ep('0123456789abcdef', '客厅平板')],
          selectedEndpointId: '0123456789abcdef');

      // 一次 tap = onTapDown + onTapUp：down 因权限被拒而中止，
      // up 会进 `_send()`，此时 `_recording == false` 必须早退。
      await tester.tap(_micButton);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: '松手时没在录音是正常路径，绝不能抛异常');
      expect(find.textContaining('录音中'), findsNothing);
    });
  });
}
