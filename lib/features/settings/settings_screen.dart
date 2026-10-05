import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
import '../../services/export_crypto.dart';
import '../../services/permission_flow.dart';

import 'evidence_screen.dart';

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

  /// 夜间独立豁免主开关（v1.9，docs/20 §8.1）。默认 **false = 未授权**。
  ///
  /// 存 `SharedPreferences`（与本页其它设置同一存储）。**不做 DB 读取** ——
  /// kv 表要走一次 sqflite 往返，会让整页 widget 测试留下未完成的锁超时 Timer。
  bool _quietExemptMaster = false;

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
      // ⚠️ BUG-065：必须用 `dir.path`，**不能**写 `'$dir/...'`。
      // `Directory.toString()` 返回的是 `Directory: 'C:\Temp\xxx'`
      // （带 `Directory: ` 前缀和引号，实测），插值后得到
      // `Directory: 'C:\Temp\xxx'/sonic_shield_tasks_123.json` ——
      // 一个根本不存在的路径，`writeAsString` 必抛 `FileSystemException`，
      // 被下面的 catch 吞成「导出失败：…」。也就是说：**加密与非加密两条导出
      // 路径在真机上都从来没成功过**，而用户只看到一个语焉不详的失败提示。
      final path = '${dir.path}/sonic_shield_tasks_$stamp.json';
      // 可选密码加密（v2.0）：输入密码 → PBKDF2+AES-GCM 加密备份。
      //
      // ⚠️ BUG-066：`_askPassword` 返回 `null` = **用户取消**或**两次密码不一致**
      // —— 两者都必须**整体中止**，绝不能落到下面的明文分支。旧写法
      // （`if (password != null && password.isNotEmpty)`）会把这两种情况
      // 静默降级成"明文导出"：用户明确要加密、只因两次输入不一致，就得到一份
      // 含全部任务与音源引用的明文备份并交给系统分享面板。这与
      // 「隐私开关不得静默失效」（BUG-056 同源）是同一条红线。
      final password = await _askPassword('加密备份（留空则明文导出）');
      if (password == null) return; // 取消 / 两次不一致 → 不导出
      final body = const JsonEncoder.withIndent('  ').convert(payload);
      if (password.isNotEmpty) {
        final enc = await ExportCrypto.encrypt(body, password);
        await File('$path.enc').writeAsString(enc, flush: true);
        if (mounted) {
          final messenger = ScaffoldMessenger.of(context);
          await Share.shareXFiles([XFile('$path.enc')], subject: '声盾任务备份（加密）');
          messenger.showSnackBar(
              const SnackBar(content: Text('已导出加密备份——密码丢失将无法恢复，请妥善保管')));
        }
        return;
      }
      await File(path).writeAsString(body, flush: true);
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

  /// 密码输入对话框；返回 null = 用户取消。
  Future<String?> _askPassword(String title, {bool confirm = true}) async {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: c1,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码')),
            if (confirm)
              TextField(
                  controller: c2,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '确认密码')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return null;
    if (c1.text.isEmpty) return '';
    if (confirm && c1.text != c2.text) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('两次密码不一致')));
      }
      return null;
    }
    return c1.text;
  }

  Future<void> _importTasks() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.single.path == null) return;
      var raw = await File(result.files.single.path!).readAsString();
      // 加密备份（.enc）：输入密码解密（v2.0）。
      if (result.files.single.name.endsWith('.enc')) {
        final password = await _askPassword('解密备份', confirm: false);
        if (password == null || password.isEmpty) return;
        final plain = await ExportCrypto.decrypt(raw, password);
        if (plain == null) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('解密失败：密码错误或文件损坏')));
          }
          return;
        }
        raw = plain;
      }
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      if (payload['app'] != 'sonic_shield' || payload['tasks'] is! List) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('文件格式不符')));
        }
        return;
      }
      final repo = await ref.read(taskRepoProvider.future);
      // 先整体解析、再**一次性批量写入**：
      //  · 批量路径只有一次平台通道往返（逐条 upsert 是 N 次，每次约 1.5ms）；
      //  · 整批在同一事务里提交 —— 中途某条解析失败**不会留下半批已导入的任务**
      //    （旧的逐条循环会留下"提示导入失败、但列表里已经多了一截"的中间态）。
      final parsed = <Task>[];
      for (final tj in (payload['tasks'] as List)) {
        final row = (tj as Map).cast<String, dynamic>();
        parsed.add(Task(
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
        ));
      }
      await repo.upsertMany(parsed);
      final imported = parsed.length;
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
    // 进入页面时让豁免计数重新算一次（provider 刻意不是 `autoDispose` ——
    // 靠这一句保证"每次进来都是新的"，同时避开 autoDispose 的零延时 Timer）。
    //
    // ⚠️ 必须放进 post-frame 回调：`ref.invalidate` 会去 `dependOnInheritedWidget`
    // 找 `UncontrolledProviderScope`，而在 `initState()` 返回之前做这件事会被
    // 框架直接断言拦下（实测：整页用例全红）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(quietExemptCountProvider);
    });
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _powerMode = p.getString('power_mode') ?? 'balanced';
      _quietStart = p.getInt(PrefsKeys.quietStartHour) ??
          ComplianceGuardrails.defaultQuietStartHour;
      _quietEnd = p.getInt(PrefsKeys.quietEndHour) ??
          ComplianceGuardrails.defaultQuietEndHour;
      _quietExemptMaster = p.getBool(PrefsKeys.quietExemptMaster) ?? false;
    });
  }

  /// 切换夜间独立豁免主开关（v1.9，docs/20 §8.1）。
  ///
  /// 开启前**必须**二次确认并写明后果：这是**削弱**合规护栏的操作
  /// （docs/08 §4 原本标注"不可绕过"），不能一键静默开启。
  Future<void> _toggleQuietExempt(bool next) async {
    if (next) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('开启夜间独立豁免？'),
          content: const SingleChildScrollView(
            child: Text(
              '开启后，逐个任务还可以选择"豁免免打扰"。只有两处都开启时，'
              '该任务才会在免打扰时段（默认 22:00–07:00）照常执行。\n\n'
              '这意味着：\n'
              '· 夜间可能响起你为这些任务配置的声音/震动；\n'
              '· 本应用定位为个人自动化工具，请勿用它干扰他人；\n'
              '· 每次豁免执行都会写入日志，本页可查看本月次数。\n\n'
              '随时可在此关闭；关闭后已排入的豁免计划会被立即清除。',
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('我了解后果，开启')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setBool(PrefsKeys.quietExemptMaster, next);
    if (mounted) setState(() => _quietExemptMaster = next);
    // 立刻重算：开启后豁免计划才会被物化；关闭后引擎会清除已落库的豁免计划。
    await BackgroundServiceManager.instance.replan();
    if (mounted) {
      ref.invalidate(quietExemptCountProvider);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(next
              ? '已开启夜间豁免主开关（仍需逐任务开启"豁免免打扰"）'
              : '已关闭夜间豁免主开关，待执行的豁免计划已清除')));
    }
  }

  Future<void> _savePower(String mode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('power_mode', mode);
    await BackgroundServiceManager.instance.setPowerMode(mode);
    if (mounted) setState(() => _powerMode = mode);
  }

  Future<void> _saveQuiet() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(PrefsKeys.quietStartHour, _quietStart);
    await p.setInt(PrefsKeys.quietEndHour, _quietEnd);
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
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
                '合规护栏：默认 22:00–07:00 强制免打扰。此处只能把窗口**调窄**，不能调宽。',
                style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(height: 4),
          const Divider(height: 32),
          Text('夜间独立豁免', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          // ---- 夜间独立豁免（v1.9，docs/20 §8）：跨功能的 Two-Key Safety 主开关 ----
          Builder(builder: (context) {
            final enabled = _quietExemptMaster;
            // 计数走 provider：设置页只消费，且 widget 测试能把它换掉
            // （真实 sqflite 往返在 FakeAsync 里会留下未完成的 Timer）。
            final count = ref.watch(quietExemptCountProvider);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.nightlight_round),
                  title: const Text('夜间独立豁免（主开关）'),
                  subtitle: Text(enabled
                      ? '已开启：仍需在任务编辑器中逐任务开启"豁免免打扰"'
                      : '关闭中：所有任务在免打扰时段一律跳过或平移'),
                  value: enabled,
                  onChanged: _toggleQuietExempt,
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 56, bottom: 4),
                  child: Text(
                    // 读不到时显示"—"而不是 0：把"读失败"显示成"没豁免过"
                    // 会让用户以为护栏完好，属于误导。
                    '本月豁免次数：${count.valueOrNull?.toString() ?? '—'}'
                    '（每次豁免执行都会写入日志）',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 56, bottom: 8),
                  child: Text(
                    '⚠️ 开启豁免即削弱合规护栏，仅限个人场景（夜间静默提醒/闹钟）。'
                    '远程对端无法开启本开关，也无法为任务开启豁免。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            );
          }),
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
          // 说明（v1.7）：此处曾列出「远程遥控 / 视频通话 / 统计看板」三项，
          // 但它们只是 `context.go(...)` 导航快捷方式，**不含任何保活设置** ——
          // 放在「后台保活」分区语义不成立，且新 IA 已把「远程」「日志」提升为
          // 底部一级 TAB，快捷入口纯属冗余。故移除，保持本分区只放真正的
          // 保活相关项（电池白名单 / 精确闹钟）。
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
          Text('录音取证', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            leading: const Icon(Icons.folder_special),
            title: const Text('取证文件管理'),
            subtitle: const Text('浏览 / 导出 / 手动清理；取证文件永不自动删除'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const EvidenceScreen()),
            ),
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
