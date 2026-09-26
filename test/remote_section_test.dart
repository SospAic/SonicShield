import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_section.dart';

/// 「远程」分组页（`RemoteSection`）的宿主导航锁 —— 第三十二轮补。
///
/// ## 锁的是什么（不是"有几个图标"）
///
/// `RemoteSection` 里**九处** `context.push(...)`（`SectionScaffold` 的 4 个
/// AppBar 操作 + 「我的设备」Tab 的 2 个文字入口 + 「通话」子页的 3 个入口）
/// 决定用户从远程中心**实际能跳到哪**。只断言"有这个 IconButton"是恒真的，
/// 等于没测；本文件用 GoRouter 把每次点击**真的推一跳**，再断言
/// `router.uri.path` 与目标页确实 build 出来。
///
/// ## 为什么能主机测（无后门）
///
/// 这些跳转只是 `context.push`，依赖框架的 `GoRouter`，不触碰任何服务单例；
/// 目标路由在测试里指向 `Placeholder()`（不初始化真实子页，避免把
/// `CallService` / `RcEndpointService` 等 `static final` 单例的副作用带进来）。
/// 这与 `remote_screen_test.dart`、`ptt_tab_test.dart` 的"不生产开后门"原则一致。
///
/// 路径分两类：
/// - `assist` / `assist/join` / `pair-qr` / `settings` —— AppBar 与设备 Tab 共用；
/// - `call` / `multi-video` / `ptt` —— 只在「通话」子页（Tab 4）里。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoRouter router;
  // 路线真实 build 时才记录 —— 比读 `router.uri` 更可靠（go_router 的
  // `currentConfiguration.uri` 在 push 后未必即时反映），且与 remote_screen_test 同构。
  final visited = <String>[];

  Future<void> pump(WidgetTester tester, {Widget home = const RemoteSection()}) async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    visited.clear();

    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => home),
        for (final p in const [
          '/remote/assist',
          '/remote/assist/join',
          '/remote/pair-qr',
          '/remote/settings',
          '/remote/call',
          '/remote/multi-video',
          '/remote/ptt',
        ])
          GoRoute(
            path: p,
            builder: (_, __) {
              visited.add(p);
              return Scaffold(
                appBar: AppBar(title: const Text('目标页')),
                body: const Placeholder(),
              );
            },
          ),
      ],
    );

    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// 点击后必须真的跳到 [expected]，且目标页真的 build 出来（不是只渲染图标）。
  Future<void> expectPush(
    WidgetTester tester,
    Finder finder,
    String expected,
  ) async {
    await tester.tap(finder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(visited, contains(expected),
        reason: '点击必须真的跳转到 $expected（只渲染图标 = 恒真断言）');
    expect(find.byType(Placeholder), findsOneWidget,
        reason: '目标路由必须真正 build（uri 对但屏上没变 = 陷阱 2）');
  }

  group('RSN 远程分组页导航', () {
    testWidgets('RSN-01 AppBar 协助入口 → /remote/assist', (tester) async {
      await pump(tester);
      await expectPush(tester,
          find.widgetWithIcon(IconButton, Icons.support_agent), '/remote/assist');
    });

    testWidgets('RSN-02 AppBar 接入协助 → /remote/assist/join', (tester) async {
      await pump(tester);
      await expectPush(tester,
          find.widgetWithIcon(IconButton, Icons.login), '/remote/assist/join');
    });

    testWidgets('RSN-03 AppBar 扫码配对 → /remote/pair-qr', (tester) async {
      await pump(tester);
      await expectPush(tester,
          find.widgetWithIcon(IconButton, Icons.qr_code_scanner), '/remote/pair-qr');
    });

    testWidgets('RSN-04 AppBar 设置 → /remote/settings', (tester) async {
      await pump(tester);
      await expectPush(tester,
          find.widgetWithIcon(IconButton, Icons.tune), '/remote/settings');
    });

    testWidgets('RSN-05 「我的设备」文字入口：临时协助 → /remote/assist',
        (tester) async {
      await pump(tester);
      await expectPush(tester, find.text('临时协助会话（生成临时码）'),
          '/remote/assist');
    });

    testWidgets('RSN-06 「我的设备」文字入口：接入协助 → /remote/assist/join',
        (tester) async {
      await pump(tester);
      await expectPush(tester, find.text('接入协助会话'), '/remote/assist/join');
    });

    testWidgets('RSN-07 「通话」子页（直接挂路由壳）→ 三个入口均可达',
        (tester) async {
      // `RemoteCallEntry` 是公开 widget，直接渲染绕开 `TabBarView` 的 offstage，
      // 避免点不到。每次入口独立 `pump`（全新路由栈），免得出栈动画残留遮挡。
      await pump(tester, home: const RemoteCallEntry());
      expect(find.text('发起视频 / 语音通话'), findsOneWidget,
          reason: '通话子页必须真的渲染出来');
      await expectPush(tester, find.text('发起视频 / 语音通话'), '/remote/call');

      await pump(tester, home: const RemoteCallEntry());
      await expectPush(tester, find.text('多设备视频同连'), '/remote/multi-video');

      await pump(tester, home: const RemoteCallEntry());
      await expectPush(tester, find.text('对讲机'), '/remote/ptt');
    });
  });
}
