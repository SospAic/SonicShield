import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/dashboard/dashboard_screen.dart';
import '../features/local/local_section.dart';
import '../features/logs/logs_section.dart';
import '../features/remote/assist_host_screen.dart';
import '../features/remote/assist_join_screen.dart';
import '../features/remote/call_screen.dart';
import '../features/remote/pair_qr_screen.dart';
import '../features/remote/ptt_screen.dart';
import '../features/remote/remote_section.dart';
import '../features/remote/remote_screen.dart';
import '../features/remote/script_builder_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/tasks/task_editor_screen.dart';

/// 声明式路由（go_router，v1.7 信息架构）。
///
/// ## 底部导航 6 → 5
///
/// 原 6 项（守护/任务/音源/守卫/日志/设置）超出 Material 3 建议的 3–5 项，
/// 触达率与可辨识度都会下降。现按**语义聚合**为 5 项：
///
/// | TAB | 子 TAB | 聚合理由 |
/// |---|---|---|
/// | 守护 | — | 本机 + 远程状态总览 |
/// | 自动化 | 任务 · 音源 · 守卫 | 同一条流水线：守卫监听 → 任务命中 → 播放音源 |
/// | 远程 | 设备 · 任务 · 指令组 · 通话 | 共享配对表与在线状态；视频/对讲并入 |
/// | 日志 | 审计 · 统计 | 同一份 exec_logs 的明细视图与聚合视图 |
/// | 设置 | — | 含远程模块设置与配对管理 |
///
/// 子 TAB 用查询参数 `?t=` 表达（如 `/local?t=1` 直达音源），保持可深链。
///
/// 用 [StatefulShellRoute.indexedStack] 而非普通 ShellRoute：各分支保持
/// 独立导航栈与滚动位置，切 TAB 不重建（行业标准做法）。
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    // 旧路径兼容：v1.7 之前的外链/深链不失效。
    redirect: (context, state) {
      switch (state.uri.path) {
        case '/tasks':
          return '/local';
        case '/sounds':
          return '/local?t=1';
        case '/guard':
          return '/local?t=2';
        case '/stats':
          return '/logs?t=1';
      }
      return null;
    },
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _Shell(shell: shell),
        branches: [
          // 0 · 守护
          StatefulShellBranch(routes: [
            GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
          ]),
          // 1 · 自动化（任务 / 音源 / 守卫）
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/local',
              builder: (_, s) => LocalSection(initialIndex: _tabOf(s)),
            ),
          ]),
          // 2 · 远程（设备 / 任务 / 指令组 / 通话）
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/remote',
              builder: (_, s) => RemoteSection(initialIndex: _tabOf(s)),
            ),
          ]),
          // 3 · 日志（审计 / 统计）
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/logs',
              builder: (_, s) => LogsSection(initialIndex: _tabOf(s)),
            ),
          ]),
          // 4 · 设置
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/settings', builder: (_, __) => const SettingsScreen()),
          ]),
        ],
      ),

      // ---- 整页路由（不显示底部导航，符合「编辑/沉浸式任务用整页」惯例）----
      GoRoute(path: '/tasks/new', builder: (_, __) => const TaskEditorScreen()),
      GoRoute(
        path: '/tasks/:id/edit',
        builder: (_, s) => TaskEditorScreen(taskId: s.pathParameters['id']),
      ),
      GoRoute(
          path: '/remote/settings', builder: (_, __) => const RemoteScreen()),
      GoRoute(path: '/remote/call', builder: (_, __) => const CallScreen()),
      GoRoute(path: '/remote/ptt', builder: (_, __) => const PttScreen()),
      GoRoute(
          path: '/remote/pair-qr', builder: (_, __) => const PairQrScreen()),
      GoRoute(
          path: '/remote/assist',
          builder: (_, __) => const AssistHostScreen()),
      GoRoute(
          path: '/remote/assist/join',
          builder: (_, __) => const AssistJoinScreen()),
      GoRoute(
        path: '/remote/script-builder/:endpointId',
        builder: (_, s) =>
            ScriptBuilderScreen(endpointId: s.pathParameters['endpointId']!),
      ),
    ],
  );
});

/// 读取子 TAB 下标（`?t=1`）；缺省 0。
int _tabOf(GoRouterState s) =>
    int.tryParse(s.uri.queryParameters['t'] ?? '') ?? 0;

class _Shell extends StatelessWidget {
  const _Shell({required this.shell});

  final StatefulNavigationShell shell;

  static const _destinations = [
    (Icons.shield_outlined, Icons.shield, '守护'),
    (Icons.auto_awesome_outlined, Icons.auto_awesome, '自动化'),
    (Icons.phonelink_outlined, Icons.phonelink, '远程'),
    (Icons.receipt_long_outlined, Icons.receipt_long, '日志'),
    (Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: (i) => shell.goBranch(
          i,
          // 再次点击当前 TAB → 回到该分支根位置（Material 惯例）。
          initialLocation: i == shell.currentIndex,
        ),
        destinations: [
          for (final (outlined, filled, label) in _destinations)
            NavigationDestination(
              icon: Icon(outlined),
              selectedIcon: Icon(filled),
              label: label,
            ),
        ],
      ),
    );
  }
}
