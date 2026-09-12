import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../services/background_service_manager.dart';
import '../../services/native_bridge.dart';
import '../../services/permission_flow.dart';

/// 守护仪表盘：引擎开关 / 下一触发倒计时 / 今日执行统计 / 权限体检。
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _onFirstLaunch());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _onFirstLaunch() async {
    if (!mounted) return;
    await showComplianceGateOnce(context, ref);
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(engineStateProvider);
    final state = BackgroundServiceManager.instance.last;
    final theme = Theme.of(context);
    final next = state?.nextFireAt;

    return Scaffold(
      appBar: AppBar(title: const Text('声盾 SonicShield')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _EngineCard(
            running: state?.running ?? false,
            guardActive: state?.guardActive ?? false,
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('下一触发', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (state?.running != true)
                    Text('引擎未启动，请先开启守护', style: theme.textTheme.bodyMedium),
                  if (state?.running == true && next == null)
                    Text('暂无待执行计划（添加任务后将自动生成）',
                        style: theme.textTheme.bodyMedium),
                  if (next != null)
                    Text(
                      _countdown(next, DateTime.now()),
                      style: theme.textTheme.displaySmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  if (next != null) ...[
                    const SizedBox(height: 4),
                    Text('时间：${_fmt(next)}', style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          engine.when(
            data: (s) => Card(
              child: ListTile(
                leading: const Icon(Icons.assessment_outlined),
                title: Text('待执行计划：${s.pendingCount} 条'),
                subtitle: Text(
                    s.lastAction == null ? '等待任务' : '最近动作：${s.lastAction}'),
              ),
            ),
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text('引擎状态获取失败：$e'),
            ),
          ),
          const SizedBox(height: 12),
          const _PermissionChecklist(),
        ],
      ),
    );
  }

  static String _countdown(DateTime target, DateTime now) {
    final d = target.difference(now);
    if (d.isNegative) return '即将执行';
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static String _fmt(DateTime t) =>
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

class _EngineCard extends ConsumerWidget {
  const _EngineCard({required this.running, required this.guardActive});

  final bool running;
  final bool guardActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      color: running ? Theme.of(context).colorScheme.primaryContainer : null,
      child: SwitchListTile(
        secondary:
            Icon(running ? Icons.shield : Icons.shield_outlined, size: 32),
        title: Text(running ? '守护已开启' : '守护已关闭',
            style: Theme.of(context).textTheme.titleLarge),
        subtitle: const Text('启动后台引擎：调度、随机化、声音守卫'),
        value: running,
        onChanged: (v) async {
          final mgr = BackgroundServiceManager.instance;
          if (v) {
            await requestAllPermissions(ref);
            await NativeBridge.setServiceShouldRun(true);
            await mgr.start();
          } else {
            await NativeBridge.setServiceShouldRun(false);
            await mgr.stop();
          }
          ref.invalidate(engineStateProvider);
        },
      ),
    );
  }
}

class _PermissionChecklist extends ConsumerStatefulWidget {
  const _PermissionChecklist();

  @override
  ConsumerState<_PermissionChecklist> createState() =>
      _PermissionChecklistState();
}

class _PermissionChecklistState extends ConsumerState<_PermissionChecklist> {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.battery_saver),
            title: const Text('电源白名单与厂商保活引导'),
            subtitle: const Text('后台不被杀的关键一步（各品牌机型适配）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showKeepAliveGuide(context),
          ),
        ],
      ),
    );
  }
}
