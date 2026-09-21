import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/core/router.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/features/dashboard/dashboard_screen.dart';
import 'package:sonic_shield/features/local/local_section.dart';
import 'package:sonic_shield/features/logs/logs_section.dart';
import 'package:sonic_shield/features/remote/assist_host_screen.dart';
import 'package:sonic_shield/features/remote/assist_join_screen.dart';
import 'package:sonic_shield/features/remote/call_screen.dart';
import 'package:sonic_shield/features/remote/multi_video_screen.dart';
import 'package:sonic_shield/features/remote/pair_qr_screen.dart';
import 'package:sonic_shield/features/remote/ptt_screen.dart';
import 'package:sonic_shield/features/remote/remote_screen.dart';
import 'package:sonic_shield/features/remote/remote_section.dart';
import 'package:sonic_shield/features/remote/script_builder_screen.dart';
import 'package:sonic_shield/features/settings/settings_screen.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';

/// `lib/core/router.dart` 的宿主测试（信息架构回归锁）。
///
/// ## 这个文件锁的是什么
///
/// 路由表是**唯一**把「URL / 深链 / 底部导航 / 二级 TAB」四者绑在一起的地方。
/// 它出错的形态全都是**静默**的：改了路径字符串 → 旧外链 404；改了
/// `_destinations` 顺序 → 点「日志」进「设置」；漏改 `_tabOf` → 深链
/// `/local?t=2` 打开的是「任务」而不是「守卫」。这些都不抛异常，
/// 只会让用户看到错的东西，所以必须逐条上锁。
///
/// ## 四条宿主测试的硬约束（都踩过）
///
/// 1. **开库放 `setUp`，不放用例体**。`sqflite_common_ffi` 的开库走真实
///    isolate 往返，而 `testWidgets` 的用例体跑在 `FakeAsync` 里 ——
///    直接 `await AppDatabase.open()` 会**永久挂死**（实测卡满 6 分钟不返回）。
///    `setUp`/`tearDown` 在 fake async 之外执行，放这里即可。
/// 2. **导航要放在 `pumpWidget` 之前**（`router.go(at)` 先于首帧）。
///    否则 `go()` 发生在首帧之后，虽然 `currentConfiguration.uri` 立刻变了，
///    但组件树要等下一次 frame + 微任务才重建 —— 整页路由会「uri 对了、
///    屏幕上还是底部导航壳」。
/// 3. **禁止 `pumpAndSettle`**。`DashboardScreen` 有 `Timer.periodic(1s)`，
///    永远「settle」不了；而且它挂在 shell 的 `IndexedStack` 里，切到别的
///    TAB 也不会被卸载 —— 一旦用了就是超时。
///
/// 4. **收尾必须 drain**。fake async 里 sqflite 的**锁超时 Timer（10s）不会
///    自己取消**，测试收尾时会被判「A Timer is still pending」。`drain()`
///    借 `runAsync` 让真实 isolate 往返跑完，锁一释放 Timer 就取消了；
///    卸载组件树后还要补一帧零时长（Riverpod 的 `autoDispose` 走
///    `Timer(Duration.zero)`，而 `pump()` 不传时长时不会 elapse）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;

  setUp(() async {
    // 合规门已同意：否则 DashboardScreen 首帧后会弹「使用前必读」对话框。
    SharedPreferences.setMockInitialValues({'compliance_accepted_v1': true});
    db = await AppDatabase.open(inMemoryDatabasePath);
  });

  tearDown(() async {
    await db.close();
  });

  /// 让宿主库的异步往返跑完（见文件头第 4 条）。
  Future<void> drain(WidgetTester tester, {int rounds = 3}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 收尾：卸载组件树并把 Riverpod 的零延时调度推掉。
  ///
  /// `autoDispose` 的 provider 在最后一个监听者离开时，走的是
  /// `Timer(Duration.zero)`（`ProviderScheduler._defaultVsync`）——
  /// 而 `pump()` 不传时长时**不会 elapse**，这个零延时 Timer 就一直
  /// pending，收尾被判「A Timer is still pending even after the widget
  /// tree was disposed」。必须显式推一帧零时长。
  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 起一个真实 `GoRouter` 的应用外壳，首帧即落在 `at`。
  ///
  /// `addTearDown` 是 LIFO：先注册 `container.dispose`、后注册「卸载组件树」，
  /// 保证**先卸载再销毁容器**（反了会让 `DashboardScreen.dispose` 里的
  /// `_ticker.cancel()` 撞上已销毁的 ref）。
  Future<GoRouter> boot(WidgetTester tester, {String at = '/'}) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWith((_) async => db)],
    );
    addTearDown(container.dispose);
    addTearDown(() => teardownTree(tester));

    final router = container.read(routerProvider);
    if (at != '/') router.go(at); // 必须在首帧之前（见文件头第 2 条）
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await drain(tester);
    return router;
  }

  String uriOf(GoRouter r) =>
      r.routerDelegate.currentConfiguration.uri.toString();

  /// 底部导航栏内的某个标签（避开 AppBar 标题里的同名文字）。
  Finder navLabel(String label) => find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      );

  // ───────────────────── 旧路径重定向（外链不失效） ─────────────────────

  group('RTR-01 旧路径重定向', () {
    // v1.7 之前的外链/深链必须继续可用 —— 这是「静默 404」的防线。
    const legacy = {
      '/tasks': '/local',
      '/sounds': '/local?t=1',
      '/guard': '/local?t=2',
      '/stats': '/logs?t=1',
    };

    for (final e in legacy.entries) {
      testWidgets('${e.key} → ${e.value}', (tester) async {
        final router = await boot(tester, at: e.key);
        expect(uriOf(router), e.value,
            reason: '旧路径 ${e.key} 必须重定向到 ${e.value}（改路由表时容易漏改这条）');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('RTR-01b 未登记路径不被改写（default 分支返回 null）',
        (tester) async {
      // 锁的是 `redirect` 末尾的 `return null`：没有它，任何未知路径都可能
      // 被「顺手」改写成首页，掩盖真实的坏链接。
      final router = await boot(tester, at: '/definitely-not-a-route');
      expect(uriOf(router), '/definitely-not-a-route',
          reason: 'redirect 只应改写 4 条历史路径，其余必须原样放行');
    });
  });

  // ───────────────────── 底部导航（5 项唯一真源） ─────────────────────

  group('RTR-02 底部导航', () {
    testWidgets('RTR-02 恰好 5 项且标签顺序与文案固定', (tester) async {
      await boot(tester);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      final labels = [
        for (final d in bar.destinations) (d as NavigationDestination).label,
      ];
      expect(labels, ['守护', '自动化', '远程', '日志', '设置'],
          reason: '顺序即分支下标：错位会让「点日志进设置」这种静默错配发生');
      expect(labels.toSet().length, 5, reason: '标签不得重复（重复即无法辨识）');
    });

    testWidgets('RTR-02b 初始落在分支 0「守护」', (tester) async {
      await boot(tester);
      expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          0);
      expect(find.byType(DashboardScreen), findsOneWidget);
    });

    testWidgets('RTR-02c 点击标签切换到对应分支', (tester) async {
      final router = await boot(tester);
      for (final (label, index, uri) in [
        ('自动化', 1, '/local'),
        ('远程', 2, '/remote'),
        ('日志', 3, '/logs'),
        ('设置', 4, '/settings'),
        ('守护', 0, '/'),
      ]) {
        await tester.tap(navLabel(label));
        await tester.pump(const Duration(milliseconds: 400));
        await drain(tester);
        expect(
            tester
                .widget<NavigationBar>(find.byType(NavigationBar))
                .selectedIndex,
            index,
            reason: '点「$label」应选中分支 $index');
        expect(uriOf(router), uri, reason: '点「$label」应导航到 $uri');
      }
    });

    testWidgets('RTR-02d 再次点击当前 TAB 回到该分支根位置', (tester) async {
      // Material 惯例：已在「自动化」的「守卫」子 TAB 时再点「自动化」，
      // 应回到该分支根（丢掉 ?t=2）。锁的是 `initialLocation: i == currentIndex`。
      final router = await boot(tester, at: '/local?t=2');
      expect(uriOf(router), '/local?t=2');

      await tester.tap(navLabel('自动化'));
      await tester.pump(const Duration(milliseconds: 400));
      await drain(tester);

      expect(uriOf(router), '/local',
          reason: '再点当前 TAB 必须回分支根，而不是原地不动');
    });

    testWidgets('RTR-02e 切走再切回，分支保留自己的深链位置', (tester) async {
      // 反向锁：`initialLocation` 只在 `i == currentIndex` 时为真。
      // 若被写成恒真，每次切 TAB 都会把分支重置到根 —— 深链子 TAB 被悄悄丢掉。
      // ⚠️ 这条必须「切走再切回」才敏感：只切走的话两个分支的根都是它本身。
      final router = await boot(tester, at: '/local?t=2');

      await tester.tap(navLabel('日志'));
      await tester.pump(const Duration(milliseconds: 400));
      await drain(tester);
      expect(uriOf(router), '/logs');

      await tester.tap(navLabel('自动化'));
      await tester.pump(const Duration(milliseconds: 400));
      await drain(tester);
      expect(uriOf(router), '/local?t=2',
          reason: '切回分支 1 应回到它自己记着的位置（/local?t=2），而不是被重置到 /local');
    });
  });

  // ───────────────────── 二级 TAB 深链（?t=） ─────────────────────

  group('RTR-03 二级 TAB 深链解析', () {
    testWidgets('RTR-03 /local?t=N 传给 LocalSection.initialIndex',
        (tester) async {
      for (final (q, expected) in [('', 0), ('?t=1', 1), ('?t=2', 2)]) {
        await boot(tester, at: '/local$q');
        expect(
            tester.widget<LocalSection>(find.byType(LocalSection)).initialIndex,
            expected,
            reason: '/local$q 的 initialIndex 应为 $expected');
      }
    });

    testWidgets('RTR-03b /logs?t=1 传给 LogsSection.initialIndex', (tester) async {
      await boot(tester, at: '/logs?t=1');
      expect(
          tester.widget<LogsSection>(find.byType(LogsSection)).initialIndex, 1);
    });

    testWidgets('RTR-03c /remote?t=3 传给 RemoteSection.initialIndex',
        (tester) async {
      await boot(tester, at: '/remote?t=3');
      expect(
          tester.widget<RemoteSection>(find.byType(RemoteSection)).initialIndex,
          3);
    });

    testWidgets('RTR-03d 非数字 ?t 回落 0 且不崩', (tester) async {
      // `int.tryParse(...) ?? 0`：解析不了必须回落 0，不能抛。
      // ⚠️ 一条用例只 boot 一次：同一用例内多次 boot 会在收尾留下
      // Riverpod autoDispose 的零延时 Timer（拆开比硬等更稳）。
      await boot(tester, at: '/local?t=abc');
      expect(
          tester.widget<LocalSection>(find.byType(LocalSection)).initialIndex, 0,
          reason: '非数字 ?t 必须回落 0');
    });

    testWidgets('RTR-03d2 空 ?t 回落 0 且不崩', (tester) async {
      await boot(tester, at: '/local?t=');
      expect(
          tester.widget<LocalSection>(find.byType(LocalSection)).initialIndex, 0,
          reason: '空 ?t 必须回落 0');
    });

    testWidgets('RTR-03e initialIndex 真的作用到 TabBar（端到端）',
        (tester) async {
      // 上一组锁的是「路由把下标传对了」，这条锁「下标真的被消费了」。
      // 只看 initialIndex 字段会漏掉 SectionScaffold 不再理会它的情况。
      await boot(tester, at: '/local?t=2');
      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.controller?.index, 2,
          reason: '深链 /local?t=2 应让 TabBar 停在「守卫」');
    });

    testWidgets('RTR-03f 越界 ?t 被 clamp 到最后一个 TAB', (tester) async {
      await boot(tester, at: '/local?t=99');
      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.controller?.index, 2,
          reason: '越界下标必须夹到最后一个 TAB，而不是抛越界异常');
    });
  });

  // ───────────────────── 整页路由（不显示底部导航） ─────────────────────

  group('RTR-04 整页路由', () {
    // 「编辑 / 沉浸式任务用整页」：这些路由必须**盖掉**底部导航，
    // 否则用户在通话/编辑中途还能误触 TAB 丢掉现场。
    final fullPage = <String, Type>{
      '/tasks/new': TaskEditorScreen,
      '/tasks/t1/edit': TaskEditorScreen,
      '/remote/settings': RemoteScreen,
      '/remote/call': CallScreen,
      '/remote/multi-video': MultiVideoScreen,
      '/remote/ptt': PttScreen,
      '/remote/pair-qr': PairQrScreen,
      '/remote/assist': AssistHostScreen,
      '/remote/assist/join': AssistJoinScreen,
      '/remote/script-builder/e1': ScriptBuilderScreen,
    };

    for (final e in fullPage.entries) {
      testWidgets('${e.key} 直达且无底部导航', (tester) async {
        final router = await boot(tester, at: e.key);
        expect(uriOf(router), e.key);
        expect(find.byType(e.value), findsOneWidget, reason: '${e.key} 应渲染 ${e.value}');
        expect(find.byType(NavigationBar), findsNothing,
            reason: '整页路由必须盖掉底部导航（沉浸式）');
        expect(tester.takeException(), isNull);
      });
    }
  });

  // ───────────────────── 路径参数传递 ─────────────────────

  group('RTR-05 路径参数', () {
    testWidgets('RTR-05 /tasks/:id/edit 把 id 交给 TaskEditorScreen',
        (tester) async {
      // ⚠️ 断言必须落在**参数值**上，不能只断言「页面出现了」：
      // 页面类型对、id 丢了，是完全静默的缺陷。
      await boot(tester, at: '/tasks/task-abc/edit');
      final editor =
          tester.widget<TaskEditorScreen>(find.byType(TaskEditorScreen));
      expect(editor.taskId, 'task-abc');
    });

    testWidgets('RTR-05b /tasks/new 的 taskId 为空（新建而非编辑）',
        (tester) async {
      await boot(tester, at: '/tasks/new');
      final editor =
          tester.widget<TaskEditorScreen>(find.byType(TaskEditorScreen));
      expect(editor.taskId, isNull,
          reason: '新建入口不能带上 id，否则会误改已有任务');
    });

    testWidgets('RTR-05c /remote/script-builder/:endpointId 把端点交给脚本编辑器',
        (tester) async {
      await boot(tester, at: '/remote/script-builder/ep-42');
      final builder =
          tester.widget<ScriptBuilderScreen>(find.byType(ScriptBuilderScreen));
      expect(builder.endpointId, 'ep-42');
    });
  });

  // ───────────────────── 分组页归属 ─────────────────────

  group('RTR-06 分组页归属', () {
    testWidgets('RTR-06 5 个分支各自渲染正确的分组页', (tester) async {
      final expected = <String, Type>{
        '/': DashboardScreen,
        '/local': LocalSection,
        '/remote': RemoteSection,
        '/logs': LogsSection,
        '/settings': SettingsScreen,
      };
      for (final e in expected.entries) {
        await boot(tester, at: e.key);
        expect(find.byType(e.value), findsOneWidget,
            reason: '${e.key} 应渲染 ${e.value}');
      }
    });

    testWidgets('RTR-06b 切 TAB 后仍在同一外壳内（底部导航常驻）', (tester) async {
      await boot(tester, at: '/local');
      expect(find.byType(NavigationBar), findsOneWidget,
          reason: '分组页属于 shell 分支，底部导航必须常驻');
      expect(find.byType(DashboardScreen), findsNothing,
          reason: '分支不得叠加渲染（IndexedStack 只应构建当前分支）');
    });
  });
}
