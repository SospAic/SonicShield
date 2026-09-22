import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/device_list_screen.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 「我的设备」页的 **widget 层**回归锁。
///
/// ## 为什么单独补这一块
///
/// `device_list_test.dart` 只测了两个**纯函数**（`initialSelectedId` /
/// `formatLastConnected`）—— 那是对的，但整页 **114 行可执行行里 75 行
/// 从没被 pump 过**：快速连接、改备注名、删除、空态、扫码入口，
/// 一条都没被执行。这类"有测试、有断言、全绿，但测的只是两个纯函数"
/// 的缺口，只能靠覆盖率榜找出来。
///
/// ## 锁的是什么（不是"界面长什么样"）
///
/// - **快速连接 = 写入共享选择**：点卡片必须落到 `selectedEndpointId`
///   （控制台 / 对讲 / 指令组读的是同一份），否则"快速连接"名存实亡；
/// - **备注名优先于对端自报名**（`displayName`），改完备注**立即**反映到列表；
/// - **删除要真的删掉并告知**，而不是只关个对话框（BUG-064 的同族教训：
///   `showDialog` 返回 ≠ 已执行）；
/// - **取消必须什么都不做**（取消却改了数据是最难发现的一类缺陷）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PairedEndpoint ep(
    String id, {
    String name = '端点',
    String? alias,
    DateTime? lastConnectedAt,
  }) =>
      PairedEndpoint(
        deviceId: id,
        name: name,
        secret: 's-$id',
        // 固定时间，避免时区/时钟影响断言（页面会格式化成 yyyy-MM-dd）。
        pairedAt: DateTime(2024, 3, 5),
        alias: alias,
        lastConnectedAt: lastConnectedAt,
      );

  /// 挂载整页。`embedded` 还原生产形状（分组页子 TAB 不带 AppBar）。
  ///
  /// 需要真 GoRouter：空态与 AppBar 上的扫码入口都会 `context.push`。
  Future<void> pump(
    WidgetTester tester, {
    List<PairedEndpoint> endpoints = const [],
    String? selected,
    bool embedded = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = RemoteStore(await SharedPreferences.getInstance());
    for (final e in endpoints) {
      await store.addPaired(e);
    }
    if (selected != null) await store.setSelectedEndpoint(selected);

    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
            path: '/',
            builder: (_, __) => DeviceListScreen(embedded: embedded)),
        GoRoute(
            path: '/remote/pair-qr',
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('PAIR-QR-PAGE')))),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
  }

  Future<RemoteStore> store() async =>
      RemoteStore(await SharedPreferences.getInstance());

  // ---------------- 空态与入口 ----------------

  testWidgets('DLSW-01 空态：明确说明"为什么是空的"与下一步，且扫码入口可跳转',
      (tester) async {
    await pump(tester);
    expect(find.text('还没有保存的设备'), findsOneWidget);
    expect(find.textContaining('扫码配对后'), findsOneWidget,
        reason: '空态必须告诉用户下一步做什么，不能只留一片空白');

    await tester.tap(find.widgetWithText(FilledButton, '扫码配对'));
    await tester.pumpAndSettle();
    expect(find.text('PAIR-QR-PAGE'), findsOneWidget);
  });

  testWidgets('DLSW-02 非 embedded：自带 AppBar，标题与扫码按钮都在', (tester) async {
    await pump(tester, endpoints: [ep('a', name: '客厅手机')]);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('我的设备'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.qr_code_scanner));
    await tester.pumpAndSettle();
    expect(find.text('PAIR-QR-PAGE'), findsOneWidget);
  });

  testWidgets('DLSW-03 embedded：不带 AppBar（作为分组页子 TAB 使用）', (tester) async {
    await pump(tester, endpoints: [ep('a', name: '客厅手机')], embedded: true);
    expect(find.byType(AppBar), findsNothing,
        reason: 'embedded 时宿主分组页已经有 AppBar，这里再来一个就是双层标题');
    expect(find.text('客厅手机'), findsOneWidget);
  });

  // ---------------- 卡片渲染 ----------------

  testWidgets('DLSW-04 卡片：备注名优先于对端自报名，并显示配对日期与"从未连接"',
      (tester) async {
    await pump(tester, endpoints: [
      ep('ep-1', name: 'MI_MAX_2', alias: '客厅手机'),
      ep('ep-2', name: '书房平板'),
    ]);

    expect(find.text('客厅手机'), findsOneWidget, reason: '备注名应覆盖对端自报名');
    expect(find.text('MI_MAX_2'), findsNothing,
        reason: '起了备注名还显示自报名，用户就分不清哪台是哪台');
    expect(find.text('书房平板'), findsOneWidget, reason: '没备注名则回落自报名');

    expect(find.textContaining('ep-1'), findsOneWidget, reason: '设备 ID 要能看到');
    // 两张卡片的 pairedAt 都是 2024-03-05 → 各出现一次。
    expect(find.textContaining('配对于 2024-03-05'), findsNWidgets(2));
    expect(find.textContaining('从未连接'), findsNWidgets(2));
  });

  testWidgets('DLSW-05 当前目标带「当前」标记，且只有一张卡片有', (tester) async {
    await pump(tester,
        endpoints: [ep('ep-1', name: 'A'), ep('ep-2', name: 'B')],
        selected: 'ep-2');
    expect(find.text('当前'), findsOneWidget);
    // 链接图标：选中的是 link，其余是 link_off。
    expect(find.byIcon(Icons.link), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
  });

  // ---------------- 快速连接 ----------------

  testWidgets('DLSW-06 点卡片 = 快速连接：写入共享选择 + 明确告知 + 标记跟着走',
      (tester) async {
    await pump(tester,
        endpoints: [ep('ep-1', name: 'A'), ep('ep-2', name: 'B')],
        selected: 'ep-1');

    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();

    // ① 落到**共享**选择（控制台/对讲/指令组读的是同一份）。
    expect((await store()).selectedEndpointId, 'ep-2',
        reason: '没写进共享选择，"快速连接"就只在当前页有效 —— 名存实亡');
    // ② 用户知道发生了什么。
    expect(find.text('已连接到「B」'), findsOneWidget);
    // ③ 「当前」标记跟着走，且只有一个。
    expect(find.text('当前'), findsOneWidget);
  });

  testWidgets('DLSW-07 快速连接会更新"最近连接"时间（不再显示"从未连接"）', (tester) async {
    await pump(tester, endpoints: [ep('ep-1', name: 'A')]);
    expect(find.textContaining('从未连接'), findsOneWidget);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();

    expect(find.textContaining('从未连接'), findsNothing,
        reason: '连接过之后还显示"从未连接"是自相矛盾的展示');
    expect(find.textContaining('刚刚'), findsOneWidget);
  });

  // ---------------- 改备注名 ----------------

  testWidgets('DLSW-08 改备注名：对话框预填当前名，保存后列表立即更新', (tester) async {
    await pump(tester, endpoints: [ep('ep-1', name: 'MI_MAX_2')]);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('改备注名'));
    await tester.pumpAndSettle();

    expect(find.text('备注名'), findsOneWidget);
    // 预填的是**当前展示名**，不是空 —— 否则用户改一个错字要重打全名。
    expect(find.widgetWithText(TextField, 'MI_MAX_2'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '客厅手机');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('客厅手机'), findsOneWidget);
    expect((await store()).paired().first.alias, '客厅手机');
  });

  testWidgets('DLSW-09 改备注名：点「取消」必须什么都不改', (tester) async {
    await pump(tester, endpoints: [ep('ep-1', name: 'MI_MAX_2')]);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('改备注名'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '不该被保存的名字');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.text('不该被保存的名字'), findsNothing);
    expect((await store()).paired().first.alias, isNull,
        reason: '取消却把数据改了 —— 这类缺陷不报错，只能靠锁');
    expect(find.text('MI_MAX_2'), findsOneWidget);
  });

  // ---------------- 删除 ----------------

  testWidgets('DLSW-10 删除：确认后真的删掉、告知用户、卡片消失', (tester) async {
    await pump(tester, endpoints: [
      ep('ep-1', name: 'A', alias: '客厅手机'),
      ep('ep-2', name: 'B'),
    ]);

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 对话框必须说清"重新连接要再扫码" —— 这是不可逆操作。
    expect(find.text('删除这台设备？'), findsOneWidget);
    expect(find.textContaining('重新连接需要再次扫码配对'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect((await store()).paired().length, 1);
    expect((await store()).paired().first.deviceId, 'ep-2');
    expect(find.text('已删除「客厅手机」'), findsOneWidget,
        reason: '删了却不告知，用户会以为没生效而重复操作');
    expect(find.text('客厅手机'), findsNothing);
  });

  testWidgets('DLSW-11 删除：点「取消」必须保留设备', (tester) async {
    await pump(tester, endpoints: [ep('ep-1', name: 'A')]);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect((await store()).paired().length, 1, reason: '取消不该删掉任何东西');
    expect(find.text('A'), findsOneWidget);
  });
}
