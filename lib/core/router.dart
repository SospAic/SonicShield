import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/dashboard/dashboard_screen.dart';
import '../features/guard/guard_screen.dart';
import '../features/logs/log_screen.dart';
import '../features/remote/remote_screen.dart';
import '../features/remote/script_builder_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/sounds/sound_library_screen.dart';
import '../features/tasks/task_editor_screen.dart';
import '../features/tasks/task_list_screen.dart';

/// 声明式路由（go_router）。底部导航 + 三级编辑页。
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) => _Shell(child: child),
        routes: [
          GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
          GoRoute(path: '/tasks', builder: (_, __) => const TaskListScreen()),
          GoRoute(
              path: '/sounds', builder: (_, __) => const SoundLibraryScreen()),
          GoRoute(path: '/guard', builder: (_, __) => const GuardScreen()),
          GoRoute(path: '/logs', builder: (_, __) => const LogScreen()),
          GoRoute(
              path: '/settings', builder: (_, __) => const SettingsScreen()),
        ],
      ),
      GoRoute(
        path: '/tasks/new',
        builder: (_, __) => const TaskEditorScreen(),
      ),
      GoRoute(
        path: '/tasks/:id/edit',
        builder: (_, s) => TaskEditorScreen(taskId: s.pathParameters['id']),
      ),
      GoRoute(path: '/remote', builder: (_, __) => const RemoteScreen()),
      GoRoute(
        path: '/remote/script-builder/:endpointId',
        builder: (_, s) =>
            ScriptBuilderScreen(endpointId: s.pathParameters['endpointId']!),
      ),
    ],
  );
});

class _Shell extends StatelessWidget {
  const _Shell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        destinations: const [
          NavigationDestination(icon: Icon(Icons.shield_outlined), label: '守护'),
          NavigationDestination(icon: Icon(Icons.schedule), label: '任务'),
          NavigationDestination(icon: Icon(Icons.library_music), label: '音源'),
          NavigationDestination(icon: Icon(Icons.mic), label: '守卫'),
          NavigationDestination(icon: Icon(Icons.receipt_long), label: '日志'),
          NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
        ],
        selectedIndex: _selectedIndex(context),
        onDestinationSelected: (i) => _go(context, i),
      ),
    );
  }

  int _selectedIndex(BuildContext context) {
    final loc = GoRouterState.of(context).uri.path;
    switch (loc) {
      case '/tasks':
        return 1;
      case '/sounds':
        return 2;
      case '/guard':
        return 3;
      case '/logs':
        return 4;
      case '/settings':
        return 5;
      default:
        return 0;
    }
  }

  void _go(BuildContext context, int i) {
    const routes = ['/', '/tasks', '/sounds', '/guard', '/logs', '/settings'];
    context.go(routes[i]);
  }
}
