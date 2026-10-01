import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/dashboard/quick_scripts_card.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 首页「快捷指令组」卡的 **widget 层**回归锁。
///
/// ## 为什么单独补这一块
///
/// 这个卡是**唯一一个既没有专属测试文件、又能被首页直接渲染的写路径**：
/// `lib/features/dashboard/quick_scripts_card.dart` 46 行可执行行里
/// **30 行从没被 pump 过**（覆盖率 34.8%）。它只被 `coverage_sentinel_test.dart`
/// import 过（哨兵只查"文件存在"），没有任何断言碰过它 —— 也就是说
/// **"点一下执行"这条真会往别人设备发命令的路径，此前零验证**。
///
/// ## 锁的是什么（不是"界面长什么样"）
///
/// - **空态不留空壳**：没收藏指令组时整块 `SizedBox.shrink()`，
///   否则首页永远挂着一张空白卡片；
/// - **必须显示目标端点**：不写"打给谁"，"一键执行"就是盲发
///   （多端点场景下用户无从判断会不会打错设备）;
/// - **未配对时按钮禁用**，而不是点了没反应;
/// - **离线必须明确告知并入队**（`sendTo` 的 `enqueueOnFail` 契约），
///   而不是假装"已发送";
/// - **端点在别处被解配对**（BUG-060 同族形状）时必须明确提示，
///   不能静默失败、更不能崩;
/// - **最多 3 条**：首页是入口不是指令仓库。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PairedEndpoint ep(String id) => PairedEndpoint(
        deviceId: id,
        name: '端点-$id',
        secret: 'SECRET8C',
        pairedAt: DateTime(2026, 9, 27),
      );

  SavedScript ss(String id, String name) => SavedScript(
        id: id,
        name: name,
        // 真实 `RcScript.toJson()`，不手搓 dict —— 手搓的 dict 一旦与
        // 序列化口径漂移，`RcScript.fromJson` 抛异常而测试仍然"绿"。
        payload: RcScript(
          scriptId: 'sc-$id',
          name: name,
          fromName: '控制器',
          sentAt: 0,
          steps: const [RcStep(RcStepKind.delay, {'seconds': 1})],
        ).toJson(),
        savedAt: DateTime(2026, 9, 27),
      );

  /// 有界等待。**不用 `pumpAndSettle` 当"等数据"用** —— 它默认超时 10 分钟，
  /// 失败形态是"整轮门禁挂死且不留产物"，而不是一条能读的红断言。
  Future<void> waitFor(WidgetTester tester, bool Function() cond,
      {String reason = '有界等待超时'}) async {
    for (var i = 0; i < 200; i++) {
      if (cond()) return;
      await tester.pump(const Duration(milliseconds: 25));
    }
    fail(reason);
  }

  Future<void> pumpCard(
    WidgetTester tester, {
    List<PairedEndpoint> paired = const [],
    List<SavedScript> scripts = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = RemoteStore(await SharedPreferences.getInstance());
    for (final e in paired) {
      await store.addPaired(e);
    }
    for (final s in scripts) {
      await store.saveScript(s);
    }

    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: QuickScriptsCard())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('QSC-01 没有收藏指令组时整块不渲染（首页不留空壳卡片）',
      (tester) async {
    await pumpCard(tester, paired: [ep('ep-1')]);

    expect(find.text('快捷指令组'), findsNothing);
    expect(find.byType(Card), findsNothing,
        reason: '空态还挂一张空 Card，首页会永远多一块说不出用途的空白');
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('QSC-02 渲染收藏项，并写明"打给谁"', (tester) async {
    await pumpCard(tester,
        paired: [ep('ep-1')], scripts: [ss('s1', '欢迎光临')]);

    expect(find.text('快捷指令组'), findsOneWidget);
    expect(find.text('欢迎光临'), findsOneWidget);
    expect(find.text('目标：ep-1'), findsOneWidget,
        reason: '"一键执行"却不写目标设备，多端点时等于盲发');
    expect(find.widgetWithText(FilledButton, '执行'), findsOneWidget);
  });

  testWidgets('QSC-03 未配对任何端点：执行按钮禁用，并明说没有目标', (tester) async {
    await pumpCard(tester, scripts: [ss('s1', '欢迎光临')]);

    expect(find.text('目标：未配对端点'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '执行'))
          .onPressed,
      isNull,
      reason: '没有目标还能点，用户会以为发出去了',
    );
  });

  testWidgets('QSC-04 点「执行」：端点离线 ⇒ 入待发队列并明确告知（不假装已发送）',
      (tester) async {
    await pumpCard(tester,
        paired: [ep('ep-1')], scripts: [ss('s1', '欢迎光临')]);

    await tester.tap(find.widgetWithText(FilledButton, '执行'));
    await waitFor(
        tester, () => find.textContaining('端点离线').evaluate().isNotEmpty,
        reason: '执行结果必须可见 —— 静默失败会让用户反复点');

    final store = RemoteStore(await SharedPreferences.getInstance());
    expect(store.outboxFor('ep-1'), hasLength(1),
        reason: '离线时必须真的入 outbox，否则"上线后自动补发"是句空话');
    expect(find.textContaining('已加入待发队列'), findsOneWidget);
  });

  testWidgets('QSC-05 最多只展示 3 条收藏（首页是入口，不是指令仓库）',
      (tester) async {
    await pumpCard(tester, paired: [ep('ep-1')], scripts: [
      ss('s1', '第一条'),
      ss('s2', '第二条'),
      ss('s3', '第三条'),
      ss('s4', '第四条'),
    ]);

    // `saveScript` 头插 ⇒ 展示序 = 倒序保存序。
    expect(find.text('第四条'), findsOneWidget);
    expect(find.text('第三条'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget);
    expect(find.text('第一条'), findsNothing,
        reason: '第 4 条不该出现在首页 —— 否则收藏越多首页越长');
    expect(find.byType(ListTile), findsNWidgets(3));
  });

  testWidgets('QSC-06 ★ 端点已被解配对：明确告知，不崩也不静默（BUG-060 同族）',
      (tester) async {
    await pumpCard(tester,
        paired: [ep('ep-1')], scripts: [ss('s1', '欢迎光临')]);
    expect(find.text('目标：ep-1'), findsOneWidget);

    // 页面已加载完成之后，端点在别处被解配对（配对表被清空）。
    final store = RemoteStore(await SharedPreferences.getInstance());
    await store.removePaired('ep-1');

    await tester.tap(find.widgetWithText(FilledButton, '执行'));
    await waitFor(
        tester, () => find.textContaining('端点已不存在').evaluate().isNotEmpty,
        reason: '★ 目标端点消失时必须明确提示。早先这类路径是"点了一下什么都没发生"，'
            '用户只能反复点（BUG-060 的形状）');

    expect(find.textContaining('请重新选择'), findsOneWidget);
    expect(store.outboxFor('ep-1'), isEmpty,
        reason: '已解配对的端点绝不能被下发命令 —— 授权真源是配对表');
  });

  testWidgets('QSC-07 ★ 端点在线的成功一侧：如实说"已发送、立即执行"（不混同离线）',
      (tester) async {
    await pumpCard(tester,
        paired: [ep('ep-1')], scripts: [ss('s1', '欢迎光临')]);

    // 宿主连不上 broker ⇒ `sendTo` 恒 false（QSC-04 覆盖的就是那一侧）。
    // 用第 45 轮的 `debugSendTo` 缝驱动"broker 已受理"，走到成功文案 ——
    // 两条文案混同的话，用户分不清"已经打了"和"排队等着"。
    final svc = RcEndpointService.instance;
    var calls = 0;
    svc.debugSendTo = (endpoint, msg, store, enqueueOnFail) async {
      calls++;
      expect(endpoint.deviceId, 'ep-1');
      expect(msg.type, RcCmd.scriptRun);
      return true;
    };
    addTearDown(() => svc.debugSendTo = null);

    await tester.tap(find.widgetWithText(FilledButton, '执行'));
    await waitFor(tester,
        () => find.textContaining('已发送').evaluate().isNotEmpty,
        reason: '受理成功必须给出与"离线入队"不同的明确文案');

    expect(calls, 1, reason: '「执行」必须真的把指令组交出去一次');
    expect(find.textContaining('端点立即执行'), findsOneWidget);
    expect(find.textContaining('已加入待发队列'), findsNothing,
        reason: '已受理却报"已入队"会让用户以为没发出去、反复点');
  });
}
