import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_screen.dart';
import 'package:sonic_shield/remote/controller_service.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/permission_stub.dart';
import 'support/record_stub.dart';

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

/// 带 **GoRouter** 的宿主：`RemoteScreen` 里有两个 `context.push(...)`
/// （扫码配对 / 指令组装器），用普通 `MaterialApp(home:)` 会直接抛
/// "No GoRouter found" ⇒ 这两条跳转路径必须靠路由壳才能真实执行。
///
/// [visited] 记录**实际被 push 的 location**，用于断言"跳到了正确的地址"
/// （只断言"有 IconButton"是恒真的，等于没测）。
Future<RemoteStore> _pumpRouted(
  WidgetTester tester, {
  List<PairedEndpoint> endpoints = const [],
  required List<String> visited,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = RemoteStore(await SharedPreferences.getInstance());
  for (final e in endpoints) {
    await store.addPaired(e);
  }

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const RemoteScreen()),
      GoRoute(
        path: '/remote/pair-qr',
        builder: (ctx, __) {
          visited.add('/remote/pair-qr');
          return Scaffold(
            appBar: AppBar(title: const Text('扫码配对页')),
            body: FilledButton(
              onPressed: () => Navigator.of(ctx).maybePop(),
              child: const Text('返回'),
            ),
          );
        },
      ),
      GoRoute(
        path: '/remote/script-builder/:id',
        builder: (_, s) {
          final id = s.pathParameters['id']!;
          visited.add('/remote/script-builder/$id');
          return Scaffold(
              appBar: AppBar(title: const Text('指令组装器页')),
              body: Text(id));
        },
      ),
    ],
  );

  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  // ⚠️ **必须用「平台层」桩，且必须在 setUp 里预热**（第四十一轮实测换来）：
  // `RcControllerService` 是**进程内单例**，`AudioRecorder` 只在首次构造时
  // 发起一次 `create()`，而 `_safeCall` 每次调用都先 `await _createFuture`。
  // 实测（`_pt/q5_probe_raw.txt`）：用 method channel 桩时，`create()` 的往返
  // **跨用例后不再推进** ⇒ `_createFuture` 永久不完成 ⇒ 之后同一进程内
  // **任何** `start()/stop()` 都**永久挂起**（不是抛错）。
  // 完整说明见 `support/record_stub.dart` 第二层。
  late FakeRecordPlatform rec;
  setUp(() async {
    rec = installFakeRecordPlatform();
    // ★ `setUp` 跑在**真实 zone** ⇒ 这一次调用把 `_createFuture` 真正推完成。
    await RcControllerService.instance.pttCancel();
    rec.calls.clear();
  });
  tearDown(restoreRecordPlatform);

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

    // ---------------- 以下为第三十二轮补齐：此前 68 行未覆盖中的"可补块" ----------------

    testWidgets('RRS-15 取消配对 → 真正落库移除（不是只把卡片藏起来）', (tester) async {
      final store = await _pump(tester, endpoints: [_ep('0123456789abcdef', '客厅平板')]);
      expect(find.text('已配对端点（1）'), findsOneWidget);

      await tester.tap(find.byTooltip('取消配对'));
      await tester.pumpAndSettle();

      expect(store.paired(), isEmpty,
          reason: '删了卡片但没删库 ⇒ 重启后又冒出来，这是"假删除"');
      expect(find.text('已配对端点（0）'), findsOneWidget);
      expect(find.textContaining('尚未配对端点'), findsOneWidget);
    });

    testWidgets('RRS-16 TURN 对话框"取消" → 不落库', (tester) async {
      final store = await _pump(tester, turnUrl: 'turn:keep.me:3478');

      await tester.tap(find.text('TURN 中继（可选）'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextField).at(0), 'turn:discard.me:3478');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(store.turnUrl, 'turn:keep.me:3478',
          reason: 'TURN 取消必须和 broker 取消一样真的不写');
    });

    testWidgets('RRS-17 扫码配对 → 跳 /remote/pair-qr，返回后刷新列表', (tester) async {
      final visited = <String>[];
      await _pumpRouted(tester, visited: visited);

      await tester.tap(find.byTooltip('扫码配对'));
      await tester.pumpAndSettle();

      expect(visited, ['/remote/pair-qr'],
          reason: '必须真的跳到扫码页，而不是原地弹个 toast');

      // 返回后 `_load()` 要被 await —— 扫码配对成功回来的端点必须立刻可见。
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();

      expect(find.text('已配对端点（0）'), findsOneWidget);
    });

    testWidgets('RRS-18 指令组装器 → 带上该端点的 deviceId 跳转', (tester) async {
      final visited = <String>[];
      await _pumpRouted(tester,
          endpoints: [_ep('0123456789abcdef', '客厅平板')], visited: visited);

      await tester.tap(find.byTooltip('指令组装器'));
      await tester.pumpAndSettle();

      expect(visited, ['/remote/script-builder/0123456789abcdef'],
          reason: '组装器必须知道对谁发 —— 传错 id 等于把指令发到别的设备');
    });

    testWidgets('RRS-19 对讲机：麦克风已授权 → 打开对讲面板', (tester) async {
      stubPermissions({Permission.microphone: PermissionStatus.granted});
      addTearDown(clearPermissionStub);

      await _pump(tester, endpoints: [_ep('0123456789abcdef', '客厅平板')]);

      await tester.tap(find.byTooltip('对讲机'));
      await tester.pumpAndSettle();

      // 面板必须**指明对谁说**，否则用户按下去不知道发给谁。
      expect(find.text('对讲机 → 客厅平板'), findsOneWidget);
      expect(find.text('按住下方按钮开始说话'), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsWidgets);
    });

    testWidgets('RRS-19b 对讲面板「关闭」真的关闭面板（不是一个摆设按钮）', (tester) async {
      // 第 68 轮自查补：`_PttSheet` 的「关闭」此前只有"面板打开"被验过，
      // 关闭按钮本身一次都没被点过 —— 一个点不动的关闭键会把用户困在面板里。
      stubPermissions({Permission.microphone: PermissionStatus.granted});
      addTearDown(clearPermissionStub);

      await _pump(tester, endpoints: [_ep('0123456789abcdef', '客厅平板')]);

      await tester.tap(find.byTooltip('对讲机'));
      await tester.pumpAndSettle();
      expect(find.text('对讲机 → 客厅平板'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();

      expect(find.text('对讲机 → 客厅平板'), findsNothing,
          reason: '关闭必须真的收起面板 —— 否则用户被困在无法退出的底部面板里');
    });

    testWidgets('RRS-20 对讲机：麦克风被拒 → 明确提示且不打开面板', (tester) async {
      final requested = stubPermissions(
          {Permission.microphone: PermissionStatus.denied});
      addTearDown(clearPermissionStub);

      await _pump(tester, endpoints: [_ep('0123456789abcdef', '客厅平板')]);

      await tester.tap(find.byTooltip('对讲机'));
      await tester.pumpAndSettle();

      expect(requested.single, [Permission.microphone],
          reason: '必须真的申请了麦克风权限');
      expect(find.text('需要麦克风权限才能对讲'), findsOneWidget);
      expect(find.text('对讲机 → 客厅平板'), findsNothing,
          reason: '没权限还弹出面板 ⇒ 用户说完才发现没录上（静默失败）');
    });

    testWidgets('RRS-21 手输配对"取消" → 对话框关闭且不入库', (tester) async {
      final store = await _pump(tester);

      await tester.tap(find.widgetWithText(FilledButton, '手输'));
      await tester.pumpAndSettle();
      expect(find.text('配对新端点'), findsOneWidget);

      // 填了合法内容再取消 —— 才验得出"取消"是真的拦住了写入，
      // 而不是"因为内容不合法所以没写"。
      await tester.enterText(find.byType(TextField).at(0), '0123456789abcdef');
      await tester.enterText(find.byType(TextField).at(1), '不该被保存');
      await tester.enterText(find.byType(TextField).at(2), 'AB2CD5EF');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(find.text('配对新端点'), findsNothing);
      expect(store.paired(), isEmpty);
      expect(find.text('已配对端点（0）'), findsOneWidget);
    });

    // ---------------- 以下为 R-9 配套：控制台「去开启」的落点必须可用 ----------------

    testWidgets('RRS-22 控制台「去开启」的落点就是本页：开关真的可交互（不是死入口）',
        (tester) async {
      // R-9：控制台在本机远程模块未开启时提示「命令不会补发」并给出「去开启」
      // 入口，落点即 `/remote/settings`（本页）。若这里的开关本身不可点，
      // 那个入口就是**死路** —— 用户知道原因却无处可去。
      await _pump(tester);

      final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(sw.value, isFalse, reason: '默认必须是关闭态（合规：远程遥控默认关）');
      expect(sw.onChanged, isNotNull,
          reason: '关闭态必须能点开，否则「去开启」入口指向一个不可交互的页面');
    });

    // ---------------- 以下为第四十一轮：两块「有测试但整块没被驱动」 ----------------

    /// 高级代理卡片与对话框标题**是同一串字** ⇒ 只断言 `findsOneWidget` 会恒假。
    Finder advCard() => find.text('MQTT 代理（高级，可选）');
    Finder advDialog() =>
        find.ancestor(of: find.text('保存'), matching: find.byType(AlertDialog));
    /// 按**序号**取对话框内的输入框（`find.byWidget` 是身份匹配，
    /// 重 build 后 Widget 实例会换 ⇒ 序号更稳）。
    Finder advField(int i) => find
        .descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField))
        .at(i);

    testWidgets('RRS-23 高级代理：填好保存 → 四项真落库 + 明确"重启后生效"',
        (tester) async {
      final store = await _pump(tester);

      await tester.tap(advCard());
      await tester.pumpAndSettle();
      expect(advDialog(), findsOneWidget, reason: '点卡片必须真的打开高级代理对话框');

      expect(find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          findsNWidgets(4),
          reason: 'host / port / user / pass 四个字段一个都不能少');
      await tester.enterText(advField(0), 'mqtt.example.com');
      await tester.enterText(advField(1), '8883');
      await tester.enterText(advField(2), 'admin');
      await tester.enterText(advField(3), 's3cret');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(store.brokerHost, 'mqtt.example.com');
      expect(store.brokerPort, 8883);
      expect(store.brokerUsername, 'admin');
      expect(store.brokerPassword, 's3cret');
      expect(find.text('已保存：重启远程模块后生效'), findsOneWidget,
          reason: '保存 ≠ 已切换：必须说清"重启才生效"，否则用户以为已经换过去了');
    });

    testWidgets('RRS-24 高级代理：取消 → 一个字段都不落库', (tester) async {
      final store = await _pump(tester);

      await tester.tap(advCard());
      await tester.pumpAndSettle();
      // 填了合法内容再取消 —— 才验得出"取消"真拦住了写入，
      // 而不是"因为内容没填所以没写"。
      await tester.enterText(advField(0), '不该被保存');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(advDialog(), findsNothing);
      expect(store.brokerHost, isEmpty, reason: '取消必须一个字段都不写');
      expect(find.text('已保存：重启远程模块后生效'), findsNothing);
    });

    testWidgets('RRS-25 高级代理：非数字被过滤；端口留空 = null（走默认 TLS）',
        (tester) async {
      final store = await _pump(tester);

      await tester.tap(advCard());
      await tester.pumpAndSettle();

      await tester.enterText(advField(1), '8a8');
      expect(tester.widget<TextField>(advField(1)).controller!.text, '88',
          reason: '端口字段必须只收数字（inputFormatters），否则 int.tryParse 静默变 null');

      await tester.enterText(advField(0), 'mqtt.example.com');
      await tester.enterText(advField(1), '');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(store.brokerHost, 'mqtt.example.com');
      expect(store.brokerPort, isNull,
          reason: '端口留空要落 null（调用方回落到默认 TLS 端口），不能写成 0');
    });

    testWidgets('RRS-26 对讲面板：按住录音不可用 → 松手给出"未录到音频"（不是静默）',
        (tester) async {
      stubPermissions({Permission.microphone: PermissionStatus.granted});
      addTearDown(clearPermissionStub);
      // record 桩由顶层 `setUp` 装好（见 main() 头注：单例构造时机决定成败）。

      await _pump(tester, endpoints: [_ep('0123456789abcdef', '客厅平板')]);
      await tester.tap(find.byTooltip('对讲机'));
      await tester.pumpAndSettle();

      // 本页没有别的 CircleAvatar ⇒ 这个 finder 唯一命中面板里的"按住说话"。
      expect(find.byType(CircleAvatar), findsOneWidget);
      // ★ **整条手势都必须跑在 `runAsync` 里**，三个理由缺一不可：
      // ① `_PttSheet` 的两个回调会 `await` 录音插件的 Future，而
      //    `AudioRecorder._createFuture` 是 `late final` 且**只在首次构造时
      //    创建一次**（`record-7.1.1/lib/src/record.dart:25,32-41`），本文件在
      //    顶层 `setUp`（真实 zone）里预热过它 ⇒ 它属于**真实 zone**；
      //    fake-async 只推进本 zone 的微任务，跨 zone 的那个**永远等不到**
      //    （症状是"断言找不到文本"，不是抛错；详见 `main()` 头注）。
      // ② `TapGestureRecognizer` 的 100ms `didExceedDeadline` 是 `Timer`
      //    （`tap.dart:308-311,370-376`）——在真实 zone 里下按才会得到**真实**
      //    计时器，`pump(150ms)` 推的是 fake 时钟，推不动它。
      // ③ 抬手要走 arena sweep → `acceptGesture`（`tap.dart:347-354`）才会
      //    补发 down+up，所以 down 与 up 必须在同一段真实时间里成对发生。
      await tester.runAsync(() async {
        final g = await tester.startGesture(
            tester.getCenter(find.byType(CircleAvatar)));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await g.up();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('按住下方按钮开始说话'), findsOneWidget,
          reason: '录音没起来就必须留在待机态，不能让用户以为正在录');
      expect(find.text('未录到音频'), findsOneWidget,
          reason: '松手必须给出结果 —— 静默什么都不显示等于"按了没反应"');
    }, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets('RRS-27 对讲面板：滑出手势取消 → 真的走到 onCancel（释放录音）',
        (tester) async {
      stubPermissions({Permission.microphone: PermissionStatus.granted});
      addTearDown(clearPermissionStub);
      // record 桩由顶层 `setUp` 装好（见 main() 头注）。

      await _pump(tester, endpoints: [_ep('0123456789abcdef', '客厅平板')]);
      await tester.tap(find.byTooltip('对讲机'));
      await tester.pumpAndSettle();

      // down 之后**取消**（不抬手）⇒ 触发 onTapCancel → onCancel → pttCancel。
      // ★ 同 RRS-26：整条手势 + 真实计时器都要在 `runAsync` 里。
      // ⚠️ 必须等过 `kPressTimeout`（100ms）：`TapGestureRecognizer` 只有在
      // `_sentTapDown` 为真时才会在 PointerCancel 上调 onTapCancel
      // （`packages/flutter/lib/src/gestures/tap.dart:315-319`），
      // 而 `_sentTapDown` 由 `didExceedDeadline()` 置位（`:308-311`）。
      // 取消时 arena 还没 sweep ⇒ `_wonArenaForPrimaryPointer` 仍是 false，
      // 没有任何"补发 down"的机会 ⇒ 那个 100ms 计时器是**唯一**通路，
      // 而它必须是**真实**计时器（在 runAsync 内下按才会得到）。
      // 只 `pump(150ms)` 推 fake 时钟 ⇒ onTapCancel **永不触发**，断言会以
      // "没有 stop 调用"的形式失败（看起来像生产代码没释放录音，其实是手势没被识别）。
      await tester.runAsync(() async {
        final g = await tester.startGesture(
            tester.getCenter(find.byType(CircleAvatar)));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await g.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();

      expect(rec.calls, contains('stop'),
          reason: '滑出取消必须真的释放录音通道（`pttCancel()` → `_rec.stop()`），'
              '否则麦克风被一直占着 —— 只有断言"面板还在"是恒真的');
      expect(tester.takeException(), isNull);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
