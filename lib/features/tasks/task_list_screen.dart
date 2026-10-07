import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../domain/models/task.dart';
import '../../services/background_service_manager.dart';

/// 任务列表：启停开关 / 下一触发时间 / 长按删除 / **批量操作**。
///
/// [embedded] = true 时作为「自动化」分组页的子 TAB 使用，不再自带 AppBar。
///
/// ## 批量操作（v2.x）
///
/// 支持**多选 / 全选 / 一键启用 / 一键停用 / 一键删除**。选择态与单条操作
/// 互斥：进入选择态后，点条目=勾选、长按菜单与「跳过下一次」等单条动作隐藏，
/// 避免"以为在勾选却改了某一条"的误操作。
///
/// ⚠️ 两条与单条操作**同款**的硬要求（见 `task_list_screen_test` 的口径）：
/// 1. 批量动作必须**真的落库**，不能只改界面；
/// 2. 落库后失败（重排原生闹钟炸了）必须**如实报错**，不许静默成功。
class TaskListScreen extends ConsumerStatefulWidget {
  const TaskListScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends ConsumerState<TaskListScreen> {
  /// 是否处于批量选择态。
  bool _selectionMode = false;

  /// 已勾选的任务 id 集合。
  final Set<String> _selected = <String>{};

  void _enterSelection() => setState(() {
        _selectionMode = true;
        _selected.clear();
      });

  void _exitSelection() => setState(() {
        _selectionMode = false;
        _selected.clear();
      });

  void _toggle(String id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 批量启用/停用：逐条 `setEnabled` → 重排一次 → 如实回报结果。
  Future<void> _batchSetEnabled(bool enabled, List<TaskWithMeta> list) async {
    final ids = _selected.toList(growable: false);
    if (ids.isEmpty) return;
    final what = enabled ? '启用' : '停用';
    try {
      final repo = await ref.read(taskRepoProvider.future);
      for (final id in ids) {
        await repo.setEnabled(id, enabled);
      }
      ref.invalidate(taskListProvider);
      await BackgroundServiceManager.instance.replan();
      _exitSelection();
      _snack('已$what ${ids.length} 个任务');
    } on Object catch (e) {
      // 失败必须可见：库可能只改了一半，重排也可能没跟上 —— 回读库让界面
      // 与服务真实状态一致，并把原因如实告诉用户（不许静默）。
      ref.invalidate(taskListProvider);
      _snack('批量$what失败：$e');
    }
  }

  /// 批量删除：二次确认 → 逐条删任务与其计划 → 重排一次 → 如实回报结果。
  Future<void> _batchDelete(List<TaskWithMeta> list) async {
    final ids = _selected.toList(growable: false);
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${ids.length} 个任务？'),
        content: const Text('任务及其待执行计划将一并删除，此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final repo = await ref.read(taskRepoProvider.future);
      final occ = await ref.read(occurrenceRepoProvider.future);
      for (final id in ids) {
        await repo.delete(id);
        // 任务没了、计划还在 = 引擎仍会"替不存在的人响"（孤儿 occurrence）。
        await occ.deleteForTask(id);
      }
      ref.invalidate(taskListProvider);
      await BackgroundServiceManager.instance.replan();
      _exitSelection();
      _snack('已删除 ${ids.length} 个任务');
    } on Object catch (e) {
      ref.invalidate(taskListProvider);
      _snack('批量删除失败：$e');
    }
  }

  /// 顶部工具条：普通态给「批量管理」入口；选择态给全选/启用/停用/删除/退出。
  Widget _toolbar(List<TaskWithMeta> list) {
    if (!_selectionMode) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextButton.icon(
            key: const Key('task_batch_enter'),
            icon: const Icon(Icons.checklist),
            label: const Text('批量管理'),
            onPressed: _enterSelection,
          ),
        ),
      );
    }
    final all = {for (final m in list) m.task.id};
    final allSelected = all.isNotEmpty && _selected.length == all.length;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              key: const Key('task_batch_exit'),
              icon: const Icon(Icons.close),
              tooltip: '退出批量',
              onPressed: _exitSelection,
            ),
            Text('已选 ${_selected.length} 项'),
            TextButton.icon(
              key: const Key('task_batch_select_all'),
              icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
              label: Text(allSelected ? '取消全选' : '全选'),
              onPressed: all.isEmpty
                  ? null
                  : () => setState(() {
                        if (allSelected) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(all);
                        }
                      }),
            ),
            TextButton.icon(
              key: const Key('task_batch_enable'),
              icon: const Icon(Icons.play_arrow_outlined),
              label: const Text('启用'),
              onPressed:
                  _selected.isEmpty ? null : () => _batchSetEnabled(true, list),
            ),
            TextButton.icon(
              key: const Key('task_batch_disable'),
              icon: const Icon(Icons.pause_outlined),
              label: const Text('停用'),
              onPressed:
                  _selected.isEmpty ? null : () => _batchSetEnabled(false, list),
            ),
            TextButton.icon(
              key: const Key('task_batch_delete'),
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除'),
              onPressed: _selected.isEmpty ? null : () => _batchDelete(list),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(taskListProvider);
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(_selectionMode ? '已选 ${_selected.length} 项' : '自动化任务'),
            ),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('新建任务'),
              onPressed: () async {
                await context.push('/tasks/new');
                ref.invalidate(taskListProvider);
              },
            ),
      body: tasks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (list) {
          if (list.isEmpty && !_selectionMode) {
            return const _EmptyHint();
          }
          final content = list.isEmpty
              ? const _EmptyHint()
              : RefreshIndicator(
                  onRefresh: () async => ref.invalidate(taskListProvider),
                  child: ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final m = list[i];
                      return _TaskTile(
                        model: m,
                        selectionMode: _selectionMode,
                        selected: _selected.contains(m.task.id),
                        onToggle: () => _toggle(m.task.id),
                      );
                    },
                  ),
                );
          return Column(
            children: [
              _toolbar(list),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule_send_outlined,
                size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text('还没有任务', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '支持：固定定时 / 每日 / 每周 / 随机窗口 / 随机间隔 / 声音触发；\n'
              '可随机时长与随机音量，并可搭配取证录音。',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({
    required this.model,
    this.selectionMode = false,
    this.selected = false,
    this.onToggle,
  });

  final TaskWithMeta model;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = model.task;
    final next = model.nextFireAt;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: selectionMode
            ? Checkbox(value: selected, onChanged: (_) => onToggle?.call())
            : null,
        title: Text(t.name, style: theme.textTheme.titleMedium),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text('${t.triggerType.label} · ${t.actionType.label}'),
            if (next != null)
              Text(
                '下次：${next.month.toString().padLeft(2, '0')}-'
                '${next.day.toString().padLeft(2, '0')} '
                '${next.hour.toString().padLeft(2, '0')}:'
                '${next.minute.toString().padLeft(2, '0')}',
                style: TextStyle(color: theme.colorScheme.primary),
              ),
          ],
        ),
        // 选择态隐藏单条动作（跳过/开关），避免"以为在勾选却改了某一条"。
        trailing: selectionMode
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (t.enabled)
                    IconButton(
                      icon: const Icon(Icons.skip_next_outlined),
                      tooltip: '跳过下一次',
                      onPressed: () async {
                        final occ =
                            await ref.read(occurrenceRepoProvider.future);
                        final n = await occ.skipNextForTask(t.id);
                        ref.invalidate(taskListProvider);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(n > 0
                                  ? '已跳过「${t.name}」的下一次触发'
                                  : '没有待执行的下一次触发')));
                        }
                      },
                    ),
                  Switch(
                    value: t.enabled,
                    onChanged: (v) async {
                      try {
                        final repo = await ref.read(taskRepoProvider.future);
                        await repo.setEnabled(t.id, v);
                        ref.invalidate(taskListProvider);
                        await BackgroundServiceManager.instance.replan();
                      } on Object catch (e) {
                        // 开关失败必须可见（历史 BUG-A 同形：失败时开关弹回 +
                        // 零提示，用户以为"开关关不掉"）。失败后同样 invalidate，
                        // 让开关回到与服务真实状态一致的回执值。
                        ref.invalidate(taskListProvider);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('切换失败：$e')));
                        }
                      }
                    },
                  ),
                ],
              ),
        onTap: selectionMode
            ? () => onToggle?.call()
            : () async {
                await context.push('/tasks/${t.id}/edit');
                ref.invalidate(taskListProvider);
              },
        onLongPress: selectionMode
            ? null
            : () async {
                final act = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('「${t.name}」'),
                    content: const Text('复制将创建一个默认停用的副本，可再编辑后启用。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, 'copy'),
                          child: const Text('复制任务')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, 'delete'),
                          child: const Text('删除')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, null),
                          child: const Text('取消')),
                    ],
                  ),
                );
                if (act == null) return;
                final repo = await ref.read(taskRepoProvider.future);
                final occ = await ref.read(occurrenceRepoProvider.future);
                if (act == 'copy') {
                  final now = DateTime.now();
                  await repo.upsert(Task(
                    id: const Uuid().v4(),
                    name: '${t.name}（副本）',
                    enabled: false, // 副本默认停用，防止意外触发
                    triggerType: t.triggerType,
                    trigger: t.trigger,
                    actionType: t.actionType,
                    action: t.action,
                    assetIds: t.assetIds,
                    cooldownSec: t.cooldownSec,
                    quietPolicy: t.quietPolicy,
                    // ⚠️ 必须带回：条件层（充电/电量/时段/Wi-Fi/通话保护/概率门）
                    // 与夜间豁免若丢失，副本启用后行为与原任务**静默不一致**
                    // （如原任务"仅充电时执行"，副本却无条件执行）。
                    condition: t.condition,
                    quietExempt: t.quietExempt,
                    forceRun: t.forceRun,
                    priority: t.priority,
                    createdAt: now,
                    updatedAt: now,
                  ));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('已创建副本（默认停用）')));
                  }
                }
                if (act == 'delete') {
                  await repo.delete(t.id);
                  await occ.deleteForTask(t.id);
                }
                ref.invalidate(taskListProvider);
                await BackgroundServiceManager.instance.replan();
              },
      ),
    );
  }
}
