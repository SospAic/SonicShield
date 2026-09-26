import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../domain/models/task.dart';
import '../../services/background_service_manager.dart';

/// 任务列表：启停开关 / 下一触发时间 / 长按删除。
///
/// [embedded] = true 时作为「自动化」分组页的子 TAB 使用，不再自带 AppBar。
class TaskListScreen extends ConsumerWidget {
  const TaskListScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(taskListProvider);
    return Scaffold(
      appBar: embedded ? null : AppBar(title: const Text('自动化任务')),
      floatingActionButton: FloatingActionButton.extended(
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
          if (list.isEmpty) {
            return const _EmptyHint();
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(taskListProvider),
            child: ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, i) {
                final m = list[i];
                return _TaskTile(model: m);
              },
            ),
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
  const _TaskTile({required this.model});

  final TaskWithMeta model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = model.task;
    final next = model.nextFireAt;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (t.enabled)
              IconButton(
                icon: const Icon(Icons.skip_next_outlined),
                tooltip: '跳过下一次',
                onPressed: () async {
                  final occ = await ref.read(occurrenceRepoProvider.future);
                  final n = await occ.skipNextForTask(t.id);
                  ref.invalidate(taskListProvider);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                            n > 0 ? '已跳过「${t.name}」的下一次触发' : '没有待执行的下一次触发')));
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
        onTap: () async {
          await context.push('/tasks/${t.id}/edit');
          ref.invalidate(taskListProvider);
        },
        onLongPress: () async {
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
              priority: t.priority,
              createdAt: now,
              updatedAt: now,
            ));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('已创建副本（默认停用）')));
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
