import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../services/background_service_manager.dart';

/// 任务列表：启停开关 / 下一触发时间 / 长按删除。
class TaskListScreen extends ConsumerWidget {
  const TaskListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(taskListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('自动化任务')),
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
        trailing: Switch(
          value: t.enabled,
          onChanged: (v) async {
            final repo = await ref.read(taskRepoProvider.future);
            await repo.setEnabled(t.id, v);
            ref.invalidate(taskListProvider);
            await BackgroundServiceManager.instance.replan();
          },
        ),
        onTap: () async {
          await context.push('/tasks/${t.id}/edit');
          ref.invalidate(taskListProvider);
        },
        onLongPress: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('删除任务'),
              content: Text('确定删除「${t.name}」？其计划与日志将一并清理。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除')),
              ],
            ),
          );
          if (ok == true) {
            final repo = await ref.read(taskRepoProvider.future);
            final occ = await ref.read(occurrenceRepoProvider.future);
            await repo.delete(t.id);
            await occ.deleteForTask(t.id);
            ref.invalidate(taskListProvider);
            await BackgroundServiceManager.instance.replan();
          }
        },
      ),
    );
  }
}
