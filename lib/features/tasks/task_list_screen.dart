import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../domain/models/counter_plan.dart';
import '../../domain/models/task.dart';
import '../../services/background_service_manager.dart';
import '../../core/theme.dart';

  /// 任务列表：启停开关 / 下一触发时间 / **立即执行** / 长按删除 / 批量操作。
  ///
  /// [embedded] = true 时作为「自动化」分组页的子 TAB 使用，不再自带 AppBar。
  ///
  /// ## 展示单位：单任务 / 任务包（2026-10 新 IA）
  /// 清单以**一次创建产生的单位**组织，不再把所有历史条目平铺：
  /// - 手动创建的任务（UUID id）= **单任务**卡片（原有形态，全部操作保留）；
  /// - 反击计划物化的任务（`counter:{planId}:…` id）= 按 planId 聚合成
  ///   **任务包**卡片：一次导入/下发/一键生成是一个包，组头显示条数与
  ///   下一次触发，支持整组启停 / 立即执行下一条 / 整组删除；组内条目可
  ///   折叠。批量选择态下平铺全部任务（语义不变）。
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

  /// 「立即执行」：转交引擎隔离执行并等回执（引擎未运行/失败都如实呈现，
  /// 绝不假装成功 —— 与远程 `task.runNow` 同一通道，见
  /// [BackgroundServiceManager.runNow] 与 background_engine 的 `runNow` 监听）。
  Future<void> _runNow(Task t) async {
    final r = await BackgroundServiceManager.instance.runNow(t.id);
    if (!mounted) return;
    _snack(r.ok ? '已执行「${t.name}」' : '「${t.name}」未执行：${r.message}');
  }

  // ---- 任务包（counter 计划）操作 ----

  /// 整组启停：逐条 setEnabled → 重排一次 → 如实回报（与 [_batchSetEnabled]
  /// 同口径，只是候选集来自同一个 planId）。
  Future<void> _packSetEnabled(_TaskPack pack, bool enabled) async {
    final what = enabled ? '启用' : '停用';
    try {
      final repo = await ref.read(taskRepoProvider.future);
      for (final m in pack.items) {
        await repo.setEnabled(m.task.id, enabled);
      }
      ref.invalidate(taskListProvider);
      await BackgroundServiceManager.instance.replan();
      _snack('已$what「${pack.title}」全部 ${pack.items.length} 条');
    } on Object catch (e) {
      ref.invalidate(taskListProvider);
      _snack('任务包$what失败：$e');
    }
  }

  /// 整组删除：二次确认 → 逐条删任务与计划 → 重排一次 → 如实回报。
  Future<void> _packDelete(_TaskPack pack) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${pack.title}」全部 ${pack.items.length} 条？'),
        content: const Text('整包任务及其待执行计划将一并删除，此操作不可撤销。'),
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
      for (final m in pack.items) {
        await repo.delete(m.task.id);
        await occ.deleteForTask(m.task.id);
      }
      ref.invalidate(taskListProvider);
      await BackgroundServiceManager.instance.replan();
      _snack('已删除「${pack.title}」全部 ${pack.items.length} 条');
    } on Object catch (e) {
      ref.invalidate(taskListProvider);
      _snack('任务包删除失败：$e');
    }
  }

  /// 立即执行包内**下一条**（enabled 中 nextFireAt 最早者；没有启用项则取首条）。
  Future<void> _packRunNext(_TaskPack pack) async {
    final enabled = pack.items.where((m) => m.task.enabled).toList();
    final candidates = enabled.isNotEmpty ? enabled : pack.items;
    if (candidates.isEmpty) return;
    candidates.sort((a, b) {
      final fa = a.nextFireAt, fb = b.nextFireAt;
      if (fa == null && fb == null) return 0;
      if (fa == null) return 1;
      if (fb == null) return -1;
      return fa.compareTo(fb);
    });
    await _runNow(candidates.first.task);
  }

  /// 把平铺任务整理成「单次创建单位」列表：counter 计划按 planId 聚合成
  /// **任务包**，其余（手动 UUID 任务）为**单任务**。任务包在前、单任务在后
  /// —— 计划任务是大户，优先可管理。包内按下一触发时间排序（null 沉底）。
  List<_ListItem> _buildItems(List<TaskWithMeta> list) {
    final packs = <String, List<TaskWithMeta>>{};
    final singles = <TaskWithMeta>[];
    for (final m in list) {
      final planId = counterPlanIdOf(m.task.id);
      if (planId == null) {
        singles.add(m);
      } else {
        packs.putIfAbsent(planId, () => <TaskWithMeta>[]).add(m);
      }
    }
    int byNext(TaskWithMeta a, TaskWithMeta b) {
      final fa = a.nextFireAt, fb = b.nextFireAt;
      if (fa == null && fb == null) return a.task.id.compareTo(b.task.id);
      if (fa == null) return 1;
      if (fb == null) return -1;
      return fa.compareTo(fb);
    }

    final items = <_ListItem>[];
    for (final entry in packs.entries) {
      final members = entry.value..sort(byNext);
      items.add(_PackItem(_TaskPack(planId: entry.key, items: members)));
    }
    // ⚠️ 单任务**保持 provider 给的顺序**（`listAll` 是 priority DESC），
    // 绝不在这里重排：重排会把高优先级任务挤出首屏，而 ListView.builder 是
    // 懒加载 —— 视口外的条目**根本不构建**，`find.text` 也就找不到它
    // （2026-10-16 实测：TLS-08 因此假红/真红）。
    for (final m in singles) {
      items.add(_SingleItem(m));
    }
    return items;
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
          padding: const EdgeInsets.only(right: AppSpacing.sm),
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
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
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
          // 选择态：平铺全部任务（含 counter），批量语义与旧版逐字一致。
          // 普通态：按「单次创建单位」分组 —— 手动任务=单卡片，
          // counter 计划=任务包卡片（见 [_buildItems]）。
          final items = list.isEmpty ? const <_ListItem>[] : _buildItems(list);
          final Widget content = list.isEmpty
              ? const _EmptyHint()
              : RefreshIndicator(
                  onRefresh: () async => ref.invalidate(taskListProvider),
                  child: _selectionMode
                      ? ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (_, i) {
                            final m = list[i];
                            return _TaskTile(
                              model: m,
                              selectionMode: true,
                              selected: _selected.contains(m.task.id),
                              onToggle: () => _toggle(m.task.id),
                            );
                          },
                        )
                      : ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (_, i) {
                            final item = items[i];
                            return switch (item) {
                              _PackItem(:final pack) => _TaskPackCard(
                                  pack: pack,
                                  onRunNext: () => _packRunNext(pack),
                                  onToggleAll: (v) => _packSetEnabled(pack, v),
                                  onDelete: () => _packDelete(pack),
                                ),
                              _SingleItem(:final model) => _TaskTile(
                                  model: model,
                                  selectionMode: false,
                                  selected: false,
                                  onToggle: null,
                                  onRunNow: () => _runNow(model.task),
                                ),
                            };
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
        padding: const EdgeInsets.all(AppSpacing.xxl),
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

// ---- 任务包（2026-10：清单按「单次创建单位」展示）----

/// 一个任务包 = 一次创建产出的全部 counter 任务（同一 planId）。
class _TaskPack {
  const _TaskPack({required this.planId, required this.items});

  final String planId;

  /// 组内任务（已按下一触发时间排序）。
  final List<TaskWithMeta> items;

  /// 包标题：计划名不可从 id 可靠还原（id 是归一化后的），用稳定可读形式。
  String get title => '反击计划 · $planId';

  int get enabledCount => items.where((m) => m.task.enabled).length;

  bool get allEnabled => enabledCount == items.length;

  /// 组内最近一次待触发（null = 组内无未来计划）。
  DateTime? get nextFireAt {
    DateTime? min;
    for (final m in items) {
      final f = m.nextFireAt;
      if (f == null) continue;
      if (min == null || f.isBefore(min)) min = f;
    }
    return min;
  }
}

/// 列表项两种形态：任务包 / 单任务。
sealed class _ListItem {
  const _ListItem();
}

final class _PackItem extends _ListItem {
  const _PackItem(this.pack);
  final _TaskPack pack;
}

final class _SingleItem extends _ListItem {
  const _SingleItem(this.model);
  final TaskWithMeta model;
}

/// 任务包卡片：组头（条数/下次触发/整组开关/操作菜单）+ 可折叠组内条目。
class _TaskPackCard extends StatefulWidget {
  const _TaskPackCard({
    required this.pack,
    required this.onRunNext,
    required this.onToggleAll,
    required this.onDelete,
  });

  final _TaskPack pack;
  final VoidCallback onRunNext;
  final ValueChanged<bool> onToggleAll;
  final VoidCallback onDelete;

  @override
  State<_TaskPackCard> createState() => _TaskPackCardState();
}

class _TaskPackCardState extends State<_TaskPackCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final pack = widget.pack;
    final theme = Theme.of(context);
    final next = pack.nextFireAt;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(_expanded ? Icons.expand_more : Icons.expand_less,
                color: theme.colorScheme.primary),
            title: Text(pack.title, style: theme.textTheme.titleMedium),
            subtitle: Text(
              '${pack.items.length} 条 · 启用 ${pack.enabledCount} 条'
              '${next == null ? '' : ' · 下次 ${_fmtNext(next)}'}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: pack.allEnabled,
                  // 部分启用也显示"开"会误导：未全启用 → 关位，点了即全启用。
                  onChanged: widget.onToggleAll,
                ),
                PopupMenuButton<String>(
                  tooltip: '任务包操作',
                  onSelected: (v) => switch (v) {
                        'run' => widget.onRunNext(),
                        'delete' => widget.onDelete(),
                        _ => null,
                      },
                  itemBuilder: (ctx) => const [
                    PopupMenuItem(value: 'run', child: Text('立即执行下一条')),
                    PopupMenuItem(value: 'delete', child: Text('删除整包')),
                  ],
                ),
              ],
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            for (final m in pack.items)
              _PackTaskRow(model: m),
        ],
      ),
    );
  }
}

/// `MM-DD HH:mm`（任务包/组内行共用的下次触发格式）。
String _fmtNext(DateTime t) =>
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}';

/// 任务包内的紧凑条目（组头已承载整组操作，这里只做单条启停与时间展示）。
class _PackTaskRow extends ConsumerWidget {
  const _PackTaskRow({required this.model});

  final TaskWithMeta model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = model.task;
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 56, right: 16),
      title: Text(t.name, style: theme.textTheme.bodyMedium),
      subtitle: Text(
        '${t.triggerType.label} · ${t.actionType.label}'
        '${model.nextFireAt == null ? '' : ' · 下次 ${_fmtNext(model.nextFireAt!)}'}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: Switch(
        value: t.enabled,
        onChanged: (v) async {
          try {
            final repo = await ref.read(taskRepoProvider.future);
            await repo.setEnabled(t.id, v);
            ref.invalidate(taskListProvider);
            await BackgroundServiceManager.instance.replan();
          } on Object catch (e) {
            ref.invalidate(taskListProvider);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('切换失败：$e')));
            }
          }
        },
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
    this.onRunNow,
  });

  final TaskWithMeta model;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggle;

  /// 「立即执行」回调（选择态/未注入时为 null，不渲染该按钮）。
  final VoidCallback? onRunNow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = model.task;
    final next = model.nextFireAt;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
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
                  // 立即执行（2026-10）：转交引擎隔离执行并等回执；
                  // 未注入回调（如批量态平铺）不渲染。
                  if (onRunNow != null)
                    IconButton(
                      icon: const Icon(Icons.play_circle_outline),
                      tooltip: '立即执行',
                      onPressed: onRunNow,
                    ),
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
                      if (onRunNow != null)
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, 'run'),
                            child: const Text('立即执行')),
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
                if (act == 'run') {
                  onRunNow?.call();
                  return;
                }
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
