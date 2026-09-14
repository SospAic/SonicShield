import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../core/constants.dart';
import '../../domain/models/action.dart';
import '../../domain/models/condition.dart';
import '../../domain/models/task.dart';
import '../../domain/models/trigger.dart';
import '../../services/background_service_manager.dart';
import '../../services/native_bridge.dart';
import '../../services/permission_flow.dart';

/// 设置页：电源模式 / 免打扰时段 / 保活引导 / 合规信息。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _powerMode = 'balanced';
  int _quietStart = ComplianceGuardrails.defaultQuietStartHour;
  int _quietEnd = ComplianceGuardrails.defaultQuietEndHour;

  // ---------------- 任务备份（导出/导入，v1.3） ----------------

  Future<void> _exportTasks() async {
    try {
      final repo = await ref.read(taskRepoProvider.future);
      final tasks = await repo.listAll();
      if (tasks.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('没有可导出的任务')));
        }
        return;
      }
      final payload = {
        'app': 'sonic_shield',
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'tasks': [
          for (final t in tasks)
            {
              'id': t.id,
              'name': t.name,
              'trigger_type': t.triggerType.name,
              'trigger_json': jsonEncode(t.trigger.toJson()),
              'action_type': t.actionType.name,
              'action_json': jsonEncode(t.action.toJson()),
              'asset_ids': jsonEncode(t.assetIds),
              'cooldown_sec': t.cooldownSec,
              'quiet_policy': t.quietPolicy.name,
              'priority': t.priority,
              'condition_json': t.condition == null
                  ? null
                  : jsonEncode(t.condition!.toJson()),
              'created_at': t.createdAt.millisecondsSinceEpoch,
            },
        ],
      };
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final path = '$dir/sonic_shield_tasks_$stamp.json';
      await File(path).writeAsString(
          const JsonEncoder.withIndent('  ').convert(payload),
          flush: true);
      if (mounted) {
        await Share.shareXFiles([XFile(path)], subject: '声盾任务备份');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  Future<void> _importTasks() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.single.path == null) return;
      final raw = await File(result.files.single.path!).readAsString();
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      if (payload['app'] != 'sonic_shield' || payload['tasks'] is! List) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('文件格式不符')));
        }
        return;
      }
      final repo = await ref.read(taskRepoProvider.future);
      var imported = 0;
      for (final tj in (payload['tasks'] as List)) {
        final row = (tj as Map).cast<String, dynamic>();
        final task = Task(
          id: row['id'] as String? ?? const Uuid().v4(),
          name: row['name'] as String? ?? '导入任务',
          enabled: false, // 导入后默认停用，防意外触发
          triggerType: TriggerType.values.byName(row['trigger_type'] as String),
          trigger: TriggerConfig.fromJson(
              jsonDecode(row['trigger_json'] as String)
                  as Map<String, dynamic>),
          actionType: ActionType.values.byName(row['action_type'] as String),
          action: ActionConfig.fromJson(
              jsonDecode(row['action_json'] as String) as Map<String, dynamic>),
          assetIds: (jsonDecode(row['asset_ids'] as String? ?? '[]') as List)
              .cast<String>(),
          cooldownSec: row['cooldown_sec'] as int? ?? 300,
          quietPolicy: QuietPolicy.values
              .byName(row['quiet_policy'] as String? ?? 'skip'),
          condition:
              TaskCondition.fromJsonOrNull(row['condition_json'] as String?),
          priority: row['priority'] as int? ?? 0,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
              row['created_at'] as int? ?? 0),
          updatedAt: DateTime.now(),
        );
        await repo.upsert(task);
        imported++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入完成：$imported 条任务（默认停用）')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _powerMode = p.getString('power_mode') ?? 'balanced';
      _quietStart =
          p.getInt('quiet_start') ?? ComplianceGuardrails.defaultQuietStartHour;
      _quietEnd =
          p.getInt('quiet_end') ?? ComplianceGuardrails.defaultQuietEndHour;
    });
  }

  Future<void> _savePower(String mode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('power_mode', mode);
    await BackgroundServiceManager.instance.setPowerMode(mode);
    if (mounted) setState(() => _powerMode = mode);
  }

  Future<void> _saveQuiet() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('quiet_start', _quietStart);
    await p.setInt('quiet_end', _quietEnd);
    await BackgroundServiceManager.instance.replan();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('电源策略', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'performance', label: Text('性能优先')),
              ButtonSegment(value: 'balanced', label: Text('平衡')),
              ButtonSegment(value: 'saver', label: Text('省电')),
            ],
            selected: {_powerMode},
            onSelectionChanged: (s) => _savePower(s.first),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('省电模式下，电量 < 15% 且未充电时自动暂停随机类任务与守卫，仅保留固定定时。',
                style: TextStyle(fontSize: 12)),
          ),
          const Divider(height: 32),
          Text('强制免打扰时段（合规护栏）', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            title: Text('开始：$_quietStart:00'),
            trailing: DropdownButton<int>(
              value: _quietStart,
              items: [
                for (var h = 20; h <= 23; h++)
                  DropdownMenuItem(value: h, child: Text('$h:00')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _quietStart = v);
                _saveQuiet();
              },
            ),
          ),
          ListTile(
            title: Text('结束：$_quietEnd:00'),
            trailing: DropdownButton<int>(
              value: _quietEnd,
              items: [
                for (var h = 5; h <= 9; h++)
                  DropdownMenuItem(value: h, child: Text('$h:00')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _quietEnd = v);
                _saveQuiet();
              },
            ),
          ),
          const Divider(height: 32),
          Text('后台保活', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.battery_saver),
            title: const Text('电池优化白名单与厂商引导'),
            onTap: () => showKeepAliveGuide(context),
          ),
          ListTile(
            leading: const Icon(Icons.alarm),
            title: const Text('精确闹钟权限（Android 12+）'),
            onTap: () => NativeBridge.openExactAlarmSettings(),
          ),
          ListTile(
            leading: const Icon(Icons.settings_remote),
            title: const Text('远程遥控'),
            subtitle: const Text('多端点公网遥控 · 指令组 · 对讲机'),
            onTap: () => context.push('/remote'),
          ),
          const Divider(height: 32),
          Text('任务备份', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('导出任务（JSON）'),
            subtitle: const Text('含条件与音源引用；导入后默认停用'),
            onTap: _exportTasks,
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('导入任务（JSON）'),
            onTap: _importTasks,
          ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.gavel),
            title: const Text('合规使用须知'),
            subtitle: const Text('禁止用于骚扰他人；详见文档 docs/08'),
            onTap: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('合规使用须知'),
                content: const SingleChildScrollView(
                  child: Text(
                    '本应用定位为合法的个人自动化与自我保护工具：定时提醒、'
                    '助眠/专注音、录音取证、守护提示。\n\n'
                    '严禁利用随机播放/喊话功能骚扰、恐吓、报复他人——该行为'
                    '在多数地区违反治安管理与噪声污染防治相关法规，也可能构成'
                    '民事侵权。\n\n应用已内置免打扰时段、音量上限、冷却与完整'
                    '日志等自律机制。使用者对自身使用行为承担全部法律责任。',
                  ),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('我已知晓')),
                ],
              ),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('声盾 SonicShield'),
            subtitle: Text('v1.0.0 · Flutter 跨平台 · 仅限合法用途'),
          ),
        ],
      ),
    );
  }
}
