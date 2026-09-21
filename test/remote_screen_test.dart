import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_screen.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 远程中心 · 设置页（`/remote/settings`）的宿主测试。
///
/// 覆盖范围刻意**避开**两条宿主不可达路径：
/// - 开关**打开**：`_toggleEnabled(true)` 要 `ref.read(databaseProvider.future)`
///   （sqflite，宿主无实现）并真正 `RcEndpointService.start()` 连 MQTT；
/// - 已开启时改 broker：同理会重启端点服务。
/// 这两条由设备层/集成测试覆盖。其余（渲染 / 开关关闭 / 三个对话框 /
/// 配对校验 / 剪贴板）全部可在宿主真实执行。
PairedEndpoint _ep(String id, String name) => PairedEndpoint(
    deviceId: id, name: name, secret: 'AB2CD5EF', pairedAt: DateTime.now());

Future<RemoteStore> _pump(
  WidgetTester tester, {
  bool enabled = false,
  List<PairedEndpoint> endpoints = const [],
  String deviceId = '',
  String broker = '',
  String turnUrl = '',
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = RemoteStore(await SharedPreferences.getInstance());
  if (enabled) await store.setEnabled(true);
  if (deviceId.isNotEmpty) {
    await store.setIdentity(deviceId, '声盾-${deviceId.substring(0, 4)}');
  }
  if (broker.isNotEmpty) await store.setBroker(broker);
  if (turnUrl.isNotEmpty) {
    await store.setTurn(url: turnUrl, user: '', cred: '');
  }
  for (final e in endpoints) {
    await store.addPaired(e);
  }

  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: RemoteScreen())));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  group('RRS 远程设置页', () {
    testWidgets('RRS-01 默认关闭：说明"关闭"而不是让用户猜', (tester) async {
      await _pump(tester);

      expect(find.text('远程中心 · 设置'), findsOneWidget);
      expect(find.text('端点已关闭'), findsOneWidget);
      expect(find.textContaining('允许已配对设备通过公网遥控本机'), findsOneWidget);
      // 未生成身份时必须给出来路，而不是留空。
      expect(find.text('开启后自动生成'), findsOneWidget);
      // 默认 broker 要显示出来（用户得知道流量走哪）。
      expect(find.textContaining(RemoteStore.defaultBroker), findsOneWidget);
    });

    testWidgets('RRS-02 未配对 → 明确引导"去另一台设备复制 ID 与配对码"', (tester) async {
      await _pump(tester);

      expect(find.text('已配对端点（0）'), findsOneWidget);
      expect(find.textContaining('尚未配对端点'), findsOneWidget);
    });

    testWidgets('RRS-03 已配对 → 列出全部端点与数量', (tester) async {
      await _pump(tester, endpoints: [_ep('dev-a', 'A 机'), _ep('dev-b', 'B 机')]);

      expect(find.text('已配对端点（2）'), findsOneWidget);
      expect(find.text('A 机'), findsOneWidget);
      expect(find.text('B 机'), findsOneWidget);
      expect(find.textContaining('尚未配对端点'), findsNothing);
    });

    testWidgets('RRS-04 已开启 → 显示"端点在线"，开关为开', (tester) async {
      await _pump(tester, enabled: true);

      expect(find.text('端点在线'), findsOneWidget);
      final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(sw.value, isTrue);
    });

    testWidgets('RRS-05 关闭开关 → 真正落库 enabled=false（不是只改界面）', (tester) async {
      final store = await _pump(tester, enabled: true);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(store.enabled, isFalse, reason: '开关必须落库，否则重启后又"自己开了"');
      expect(find.text('端点已关闭'), findsOneWidget);
    });

    testWidgets('RRS-06 有身份时可复制设备 ID 并提示', (tester) async {
      await _pump(tester, deviceId: '0123456789abcdef');

      expect(find.textContaining('0123456789abcdef'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.copy));
      await tester.pump();

      expect(find.text('设备 ID 已复制'), findsOneWidget);
    });

    testWidgets('RRS-07 无身份时不显示复制按钮（避免复制到空串）', (tester) async {
      await _pump(tester);

      expect(find.byIcon(Icons.copy), findsNothing);
    });

    testWidgets('RRS-08 改 MQTT 代理 → 保存后落库并刷新界面', (tester) async {
      final store = await _pump(tester);

      await tester.tap(find.text('MQTT 代理'));
      await tester.pumpAndSettle();
      expect(find.text('MQTT 代理地址'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'broker.example.com');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(store.broker, 'broker.example.com');
      expect(find.textContaining('broker.example.com'), findsOneWidget);
    });

    testWidgets('RRS-09 改 MQTT 代理 → 取消不落库', (tester) async {
      final store = await _pump(tester, broker: 'keep.me');

      await tester.tap(find.text('MQTT 代理'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'discard.me');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(store.broker, 'keep.me', reason: '取消必须真的不写 —— 否则对话框是装饰');
    });

    testWidgets('RRS-10 TURN 未配置 → 说明"对称 NAT 时会直连失败"（不是空白）', (tester) async {
      await _pump(tester);

      expect(find.textContaining('仅用 STUN 打洞'), findsOneWidget);
      expect(find.textContaining('对称 NAT'), findsOneWidget);
    });

    testWidgets('RRS-11 填 TURN → 保存后落库并显示"已启用中继"', (tester) async {
      final store = await _pump(tester);

      await tester.tap(find.text('TURN 中继（可选）'));
      await tester.pumpAndSettle();
      expect(find.text('TURN 中继'), findsWidgets);

      await tester.enterText(
          find.byType(TextField).at(0), 'turn:relay.example.com:3478');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(store.turnUrl, 'turn:relay.example.com:3478');
      expect(find.textContaining('已启用中继'), findsOneWidget);
    });

    testWidgets('RRS-12 手输配对：ID 位数不对 → 明确报错且**不写配对表**', (tester) async {
      final store = await _pump(tester);

      await tester.tap(find.widgetWithText(FilledButton, '手输'));
      await tester.pumpAndSettle();
      expect(find.text('配对新端点'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), 'short');
      await tester.enterText(find.byType(TextField).at(1), '某设备');
      await tester.enterText(find.byType(TextField).at(2), 'AB2CD5EF');
      await tester.tap(find.widgetWithText(FilledButton, '配对'));
      await tester.pumpAndSettle();

      expect(find.textContaining('设备 ID 须 16 位'), findsOneWidget);
      expect(store.paired(), isEmpty,
          reason: '校验失败绝不能留下半条配对记录');
    });

    testWidgets('RRS-13 手输配对：合法输入 → 入库 + 提示 + 列表出现', (tester) async {
      final store = await _pump(tester);

      await tester.tap(find.widgetWithText(FilledButton, '手输'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), '0123456789abcdef');
      await tester.enterText(find.byType(TextField).at(1), '客厅平板');
      // 配对码允许带连字符，实现里会去掉再校验（端点屏上就是 AB2C-D5EF 这个形状）。
      await tester.enterText(find.byType(TextField).at(2), 'ab2c-d5ef');
      await tester.tap(find.widgetWithText(FilledButton, '配对'));
      await tester.pumpAndSettle();

      final paired = store.paired();
      expect(paired.length, 1);
      expect(paired.first.deviceId, '0123456789abcdef');
      expect(paired.first.name, '客厅平板');
      expect(paired.first.secret, 'AB2CD5EF', reason: '必须归一化：去连字符 + 转大写');
      expect(find.textContaining('配对完成'), findsOneWidget);
      expect(find.text('已配对端点（1）'), findsOneWidget);
    });

    testWidgets('RRS-14 扫码配对入口存在（tooltip 可发现）', (tester) async {
      await _pump(tester);

      expect(find.byTooltip('扫码配对'), findsOneWidget);
    });
  });
}
