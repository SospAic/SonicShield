import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/device_list_screen.dart';
import 'package:sonic_shield/remote/device_group.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
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
    List<DeviceGroup> groups = const [],
    // P2-13：允许注入自定义配对页（默认是只显示文案的桩页）。
    Widget Function(BuildContext ctx)? pairPage,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = RemoteStore(await SharedPreferences.getInstance());
    for (final e in endpoints) {
      await store.addPaired(e);
    }
    if (selected != null) await store.setSelectedEndpoint(selected);
    // 组走真实 `DeviceGroupStore`（不 mock）：本页读的就是这份存储，
    // 换一套假实现就测不出"页面读错了键"这类缺陷。
    final groupStore = DeviceGroupStore(await SharedPreferences.getInstance());
    for (final g in groups) {
      await groupStore.save(g);
    }

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
            builder: (ctx, __) =>
                pairPage?.call(ctx) ??
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
    // P1-01：撤销强度边界必须对用户可见（共享配对码 ⇒ 删除≠密码学撤销），
    // 并给出可执行的更强手段入口（重置配对码）。
    expect(find.textContaining('撤销强度说明'), findsOneWidget,
        reason: '把"删除列表"说成"已彻底撤权"是夸大承诺（P1-01）');
    expect(find.textContaining('重置配对码'), findsOneWidget,
        reason: '只说局限不给下一步，用户没有可执行的更强手段');

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

  // ---------------- 设备组（Q6.B：建组 / 删组 / 组内群发 Ping） ----------------
  //
  // 这一块此前**一行都没被 pump 过**。三个纯函数（`validateGroupName` /
  // `resolveGroupTargets` / `DeviceGroupStore`）在 `device_list_test.dart`
  // 里测得很扎实，但"页面上点得到底对不对"从没验证 —— 又一次印证
  // 「有测试、有断言、全绿，测的却只是纯函数」这类缺口只能靠覆盖率榜找出来。

  /// 有界等待。**不用 `pumpAndSettle` 当"等数据"用**：它默认超时 10 分钟，
  /// 失败形态是"整轮门禁挂死、不留产物"，而不是一条能读的红断言。
  Future<void> waitFor(WidgetTester tester, bool Function() cond,
      {String reason = '有界等待超时'}) async {
    for (var i = 0; i < 200; i++) {
      if (cond()) return;
      await tester.pump(const Duration(milliseconds: 25));
    }
    fail(reason);
  }

  /// 「建组」按钮：未勾选时禁用（含空态提示里的「建组」字样要排除掉，
  /// 它不在 TextButton 里）。
  Finder createGroupBtn() => find.ancestor(
        of: find.textContaining('建组'),
        matching: find.byType(TextButton),
      );

  DeviceGroup dg(String id, String name, List<String> members) =>
      DeviceGroup(id: id, name: name, memberIds: members);

  testWidgets('DLSW-12 建组入口：未勾选时禁用，勾选后启用并显示已选台数',
      (tester) async {
    await pump(tester, endpoints: [ep('ep-1', name: 'A'), ep('ep-2', name: 'B')]);

    expect(createGroupBtn(), findsOneWidget, reason: '未勾选时标签就是「建组」');
    expect(tester.widget<TextButton>(createGroupBtn()).onPressed, isNull,
        reason: '一台没勾也能点进建组对话框，用户会在里面白填一遍再被拒');

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    expect(find.text('建组（已选 1 台）'), findsOneWidget,
        reason: '必须显示"会选几台" —— 多勾一台就多控一台，不能靠用户自己记');
    expect(tester.widget<TextButton>(createGroupBtn()).onPressed, isNotNull);
  });

  testWidgets('DLSW-13 建组：勾选 → 命名 → 保存，组落盘、出现在列表、勾选被清空',
      (tester) async {
    await pump(tester, endpoints: [ep('ep-1', name: 'A'), ep('ep-2', name: 'B')]);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(createGroupBtn());
    await tester.pumpAndSettle();

    expect(find.text('建组（1 台设备）'), findsOneWidget,
        reason: '对话框标题要复述"这一组有几台"，避免勾错');
    await tester.enterText(find.byType(TextField), '一楼展厅');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final saved =
        DeviceGroupStore(await SharedPreferences.getInstance()).groups();
    expect(saved, hasLength(1), reason: '建了组却没落盘 = 纯装饰');
    expect(saved.first.name, '一楼展厅');
    expect(saved.first.memberIds, ['ep-1'],
        reason: '入组名单必须正好是勾选的那台 —— 串台就是"控错设备"');

    expect(find.text('已创建设备组「一楼展厅」'), findsOneWidget);
    expect(find.text('一楼展厅'), findsOneWidget, reason: '建完必须立刻出现在组列表里');
    expect(find.text('1 台设备'), findsOneWidget);
    expect(find.text('建组'), findsOneWidget,
        reason: '建完勾选要清空，否则下一次建组会莫名其妙多带几台');
  });

  testWidgets('DLSW-14 建组：组名空白被拒，且不落盘', (tester) async {
    await pump(tester, endpoints: [ep('ep-1', name: 'A')]);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(createGroupBtn());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('组名不能为空'), findsOneWidget,
        reason: '全空格的组名会建出一个看不见名字的组 —— 纯坑');
    expect(DeviceGroupStore(await SharedPreferences.getInstance()).groups(),
        isEmpty);
  });

  testWidgets('DLSW-15 建组：点「取消」什么都不做（勾选保留）', (tester) async {
    await pump(tester, endpoints: [ep('ep-1', name: 'A')]);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(createGroupBtn());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '不该被保存的组名');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(DeviceGroupStore(await SharedPreferences.getInstance()).groups(),
        isEmpty,
        reason: '取消却把组建出来了 —— 这类缺陷不报错，只能靠锁');
    expect(find.text('建组（已选 1 台）'), findsOneWidget,
        reason: '取消只是改主意，勾选不该被顺手清掉');
  });

  testWidgets('DLSW-16 删组：确认后真的删掉、告知用户、列表消失', (tester) async {
    await pump(tester,
        endpoints: [ep('ep-1', name: 'A'), ep('ep-2', name: 'B')],
        groups: [dg('g1', '一楼展厅', ['ep-1', 'ep-2'])]);

    expect(find.text('一楼展厅'), findsOneWidget);
    expect(find.text('2 台设备'), findsOneWidget);

    await tester.tap(find.byTooltip('删除组'));
    await tester.pumpAndSettle();

    expect(find.text('删除这个设备组？'), findsOneWidget);
    expect(find.textContaining('不影响设备本身的配对关系'), findsOneWidget,
        reason: '必须说清"删组≠解配对"，否则用户不敢点');

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(DeviceGroupStore(await SharedPreferences.getInstance()).groups(),
        isEmpty);
    expect(find.text('一楼展厅'), findsNothing);
    expect(find.text('已删除分组「一楼展厅」'), findsOneWidget);
    expect((await store()).paired(), hasLength(2),
        reason: '删组**绝不能**牵连配对表 —— 组的生命周期与授权无关');
  });

  testWidgets('DLSW-17 删组：点「取消」必须保留', (tester) async {
    await pump(tester,
        endpoints: [ep('ep-1', name: 'A')],
        groups: [dg('g1', '一楼展厅', ['ep-1'])]);

    await tester.tap(find.byTooltip('删除组'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(DeviceGroupStore(await SharedPreferences.getInstance()).groups(),
        hasLength(1));
    expect(find.text('一楼展厅'), findsOneWidget);
  });

  testWidgets('DLSW-18 组内群发 Ping：失败必须逐行点名（不许静默）', (tester) async {
    await pump(tester,
        endpoints: [
          ep('ep-1', name: 'MI_MAX_2', alias: '客厅手机'),
          ep('ep-2', name: '书房平板'),
        ],
        groups: [dg('g1', '一楼展厅', ['ep-1', 'ep-2'])]);

    await tester.tap(find.byTooltip('组内群发 Ping'));
    // 这条路径要真跑 `sendTo`（未连接 ⇒ 入 outbox 并返回 false），
    // 因此用有界 waitFor 等结果对话框，而不是赌 pumpAndSettle 的时序。
    await waitFor(tester,
        () => find.text('「一楼展厅」群发 Ping 汇总').evaluate().isNotEmpty,
        reason: '群发汇总对话框必须出现（失败不许静默）');

    // ⚠️ 断言必须**收窄到对话框内**：`find.textContaining('客厅手机')` 会同时
    // 命中设备卡片标题（假红）——"文字在页面某处出现过"不是这条锁要说的事。
    final dlg = find.byType(AlertDialog);
    expect(find.descendant(of: dlg, matching: find.textContaining('已发 0 台 / 失败 2 台')),
        findsOneWidget);
    expect(
        find.descendant(of: dlg, matching: find.textContaining('· 客厅手机')),
        findsOneWidget,
        reason: '失败必须点名到设备 —— "有 2 台失败"等于没说');
    expect(
        find.descendant(of: dlg, matching: find.textContaining('· 书房平板')),
        findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '知道了'));
    await tester.pumpAndSettle();
    expect(find.text('「一楼展厅」群发 Ping 汇总'), findsNothing);
  });

  testWidgets('DLSW-19 组内群发 Ping：成员全部已解配对 → 明确告知，不入队',
      (tester) async {
    await pump(tester,
        endpoints: [ep('ep-1', name: 'A')],
        groups: [dg('g1', '一楼展厅', ['gone-1', 'gone-2'])]);

    await tester.tap(find.byTooltip('组内群发 Ping'));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有可用设备'), findsOneWidget,
        reason: '组名单只是收藏，成员可能全被解配对 —— 必须说清楚而不是转圈');
    expect(find.text('「一楼展厅」群发 Ping 汇总'), findsNothing,
        reason: '一台目标都没有时不该弹"失败汇总"（那是另一件事）');
    expect((await store()).outboxFor('gone-1'), isEmpty,
        reason: '已解配对的设备绝不能被下发（授权真源是配对表，不是组名单）');
  });

  testWidgets('BK-DLSW-22 组内群发 Ping：全部发出 → 如实报"已发 N 台 / 失败 0 台"',
      (tester) async {
    // 第六十一轮补：DLSW-18 只驱动了"全部失败"那一支（未连接 ⇒ sendTo 返回 false），
    // 「一台都没失败」这条**成功汇总**从未被执行过 —— 而它才是用户日常看到的那一条。
    RcEndpointService.instance.debugSendTo =
        (endpoint, msg, store, enqueueOnFail) async => true;
    addTearDown(() => RcEndpointService.instance.debugSendTo = null);

    await pump(tester,
        endpoints: [ep('ep-1', name: 'MI_MAX_2'), ep('ep-2', name: '书房平板')],
        groups: [dg('g1', '一楼展厅', ['ep-1', 'ep-2'])]);

    await tester.tap(find.byTooltip('组内群发 Ping'));
    await waitFor(tester,
        () => find.textContaining('群发 Ping 完成').evaluate().isNotEmpty,
        reason: '全部成功也要有回执 —— 没有回执用户不知道到底发没发');

    expect(find.text('「一楼展厅」群发 Ping 完成：已发 2 台 / 失败 0 台'),
        findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing,
        reason: '零失败不该弹汇总对话框（弹了等于把成功说成异常）');
  });

  testWidgets('DLSW-20 勾选只为建组：不改「当前目标」、不写连接时间', (tester) async {
    await pump(tester,
        endpoints: [ep('ep-1', name: 'A'), ep('ep-2', name: 'B')],
        selected: 'ep-1');

    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();

    final s = await store();
    expect(s.selectedEndpointId, 'ep-1',
        reason: '勾选若顺手改了当前目标，用户会在不知情下把命令发给另一台设备');
    expect(s.paired().firstWhere((e) => e.deviceId == 'ep-2').lastConnectedAt,
        isNull,
        reason: '勾选不是"连接"：写了连接时间会让「最近连接」说谎');
    expect(find.text('当前'), findsOneWidget);
    expect(find.textContaining('从未连接'), findsNWidgets(2));
  });

  testWidgets('DLSW-21 取消勾选：回到禁用态，且该设备不会被顺手带进组', (tester) async {
    await pump(tester, endpoints: [ep('ep-1', name: 'A'), ep('ep-2', name: 'B')]);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('建组（已选 1 台）'), findsOneWidget);

    // 再点一次 = 取消勾选。
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    expect(find.text('建组'), findsOneWidget, reason: '取消勾选后按钮必须回到禁用态');
    expect(tester.widget<TextButton>(createGroupBtn()).onPressed, isNull,
        reason: '还有 0 台勾选却仍可建组 ⇒ 能建出一个空组');
  });

  // ---------------- 配对返回刷新（P2-13） ----------------

  testWidgets('DLSW-23 扫码配对返回后列表自动刷新，新设备立即可见（P2-13）',
      (tester) async {
    // 注入一个"配对成功就落盘并返回"的配对页，复刻真实扫码页的行为。
    await pump(
      tester,
      pairPage: (ctx) => Scaffold(
        body: Center(
          child: Builder(
            builder: (c) => FilledButton(
              onPressed: () async {
                final s = RemoteStore(await SharedPreferences.getInstance());
                await s.addPaired(ep('ep-new', name: '新配对设备'));
                if (c.mounted) Navigator.of(c).pop();
              },
              child: const Text('模拟配对成功'),
            ),
          ),
        ),
      ),
    );

    // 前置：配对前是空态。
    expect(find.text('还没有保存的设备'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '扫码配对'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('模拟配对成功'));
    await tester.pumpAndSettle();

    // 修 P2-13 之前：`IndexedStack` 保留本页、`initState` 只跑一次，
    // 返回后列表停在配对前的空态快照 —— 用户看不到刚配好的设备。
    expect(find.text('新配对设备'), findsOneWidget,
        reason: '配对写盘后返回必须 reload，否则列表停在旧快照（P2-13）');
    expect(find.text('还没有保存的设备'), findsNothing);
  });
}
