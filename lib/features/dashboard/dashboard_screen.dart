import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../domain/scheduling/run_pause.dart';
import '../../services/background_service_manager.dart';
import '../../services/native_bridge.dart';
import '../../services/permission_flow.dart';
import '../../services/run_master_service.dart';
import 'quick_scripts_card.dart';

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
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _EngineCard(
            running: state?.running ?? false,
            guardActive: state?.guardActive ?? false,
          ),
          // ⚠️ 第八十二轮：FR-71「全局执行总开关放置到首页」。
          // 与设置页同源绑定 `PrefsKeys.runMasterMode`（v79，docs/20 §9），
          // 首页常驻，便于用户一键切换节假日自动暂停。
          const SizedBox(height: 12),
          const _RunMasterCard(),
          // P1-04：精确闹钟降级必须在**用户可操作的位置**解释并给恢复入口。
          // 否则界面继续显示运行中 + 计划数，用户无从知道"进程被杀后不再准点"。
          if (state?.alarmDiag != null) ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.alarm_off),
                title: const Text('精确闹钟未完全生效（降级运行）'),
                subtitle: Text(state!.alarmDiag!),
                trailing: TextButton(
                  onPressed: () => NativeBridge.openExactAlarmSettings(),
                  child: const Text('去授权'),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          const QuickScriptsCard(),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
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
            // P1-02：合规同意是引擎启动的**唯一准入闸**。此前开启分支从不读
            // `isComplianceAccepted()`，用户点"不同意"后仍能 `shouldRun=true`
            // 并 `mgr.start()` —— 合规门不是有效准入闸。未同意则弹出须知，
            // 拒签一律不启动。
            final accepted = await ensureComplianceAccepted(context);
            if (!accepted) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('需先阅读并同意《合规使用须知》才能开启守护')));
              }
              return;
            }
            final perms = await requestAllPermissions(ref);
            // P2-16：通知被拒**不再静默** —— 后台提醒/找回通知/执行结果提示会
            // 全部消失，必须让用户知道"哪儿坏了、怎么修"，否则只会当成功能故障。
            if (perms.notificationDenied && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content:
                      Text('通知权限未授予：后台提醒、设备找回通知与执行结果提示'
                          '将不会出现。可在「系统设置 → 应用 → 声盾 → 通知」中重新开启')));
            }
            await NativeBridge.setServiceShouldRun(true);
            // ⚠️ `start()` 的返回值**必须看**：后台服务启动失败时
            // `_svc.startService()` 返回 false 且不抛，旧实现直接忽略它 ——
            // 用户看到的是"开关弹回、零提示"（与守卫开关 BUG-061 同形）。
            final ok = await mgr.start();
            if (!ok && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('守护启动失败：后台服务未响应'
                      '（请检查电池优化白名单与厂商自启动设置）')));
            }
          } else {
            await NativeBridge.setServiceShouldRun(false);
            await mgr.stop();
          }
          if (context.mounted) ref.invalidate(engineStateProvider);
        },
      ),
    );
  }
}

/// 首页常驻「全局执行总开关（节假日自动暂停）」（FR-71，第八十二轮）。
///
/// 与设置页 / 远程 `run.master.set` 同源（[RunMasterService] → `PrefsKeys.runMasterMode`，
/// v79 docs/20 §9）：三态 `auto/on/off`，暂停窗口判定走纯函数 [RunPause]。
/// 首页只给**开关 + 当前状态**，例外清单仍在设置页展示，避免首页过长。
///
/// 🔴 监听 [RunMasterService.mode] ⇒ **远程改动即时刷新本卡片**（第八十二轮
/// 补的"最后一公里"：此前只在 `initState` 读一次，远程改了首页不刷新）。
class _RunMasterCard extends ConsumerStatefulWidget {
  const _RunMasterCard();

  @override
  ConsumerState<_RunMasterCard> createState() => _RunMasterCardState();
}

class _RunMasterCardState extends ConsumerState<_RunMasterCard> {
  @override
  void initState() {
    super.initState();
    // 从 prefs 播种（与设置页 / 远程 `run.master.set` 同一真源）。
    RunMasterService.instance.seed();
  }

  /// 写总开关：走 [RunMasterService]，于是**本机与远程改动互相可见**。
  Future<void> _set(RunMasterMode m) => RunMasterService.instance.set(m);

  static String _fmtMd(DateTime? t) {
    if (t == null) return '—';
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${p2(t.month)}-${p2(t.day)} ${p2(t.hour)}:${p2(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    // 监听 [RunMasterService]：远程 `run.master.set` 与本机改动都会即时刷新本卡片。
    return ValueListenableBuilder<RunMasterMode>(
      valueListenable: RunMasterService.instance.mode,
      builder: (context, mode, _) {
        final now = DateTime.now();
        final paused = RunPause.paused(mode, now);
        final nextAt = RunPause.nextTransition(mode, now);
        final status = switch (mode) {
          RunMasterMode.auto => paused
              ? '自动暂停中：到 ${_fmtMd(nextAt)} 自动恢复'
              : '自动运行中：到 ${_fmtMd(nextAt)} 自动暂停',
          RunMasterMode.on => '强制开启：忽略自动窗口，始终执行',
          RunMasterMode.off => '强制关闭：始终暂停，仅执行例外任务',
        };
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.pause_circle_outline),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('全局执行总开关',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SegmentedButton<RunMasterMode>(
                  segments: [
                    for (final m in RunMasterMode.values)
                      ButtonSegment(value: m, label: Text(m.label)),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) => _set(s.first),
                ),
                const SizedBox(height: 8),
                Text('当前状态：$status', style: AppText.bodySmall),
                const SizedBox(height: 4),
                const Text(
                  '自动模式：法定休息日前一天 20:00 → 休息日最后一天 21:00 暂停'
                  '（含普通周末）；窗口内任务默认跳过，出窗自动恢复。',
                  style: AppText.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
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
