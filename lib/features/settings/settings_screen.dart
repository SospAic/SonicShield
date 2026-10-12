import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../core/constants.dart';
import '../../data/repositories/api_config_store.dart';
import '../../data/repositories/counter_plan_store.dart';
import '../../domain/models/action.dart';
import '../../domain/models/condition.dart';
import '../../domain/models/counter_plan.dart';
import '../../domain/models/counter_plan_params.dart';
import '../../domain/models/task.dart';
import '../../domain/models/trigger.dart';
import '../../domain/models/tts_voice.dart';
import '../../domain/scheduling/counter_plan_random.dart';
import '../../services/background_service_manager.dart';
import '../../services/holiday_update_service.dart';
import '../../services/native_bridge.dart';
import '../../services/export_crypto.dart';
import '../../services/permission_flow.dart';

import 'evidence_screen.dart';
import '../../core/theme.dart';

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

  // ---------------- 语音与接口 / 反击计划（v2.0） ----------------
  //
  // ⚠️ 本区块**刻意不在页面里内联 `TextField`**：导入/导出的密码对话框用例用
  // `find.byType(TextField).at(0/1)` 无作用域地取框，页面上任何常驻输入框都会
  // 抢到 `at(0)`，让「导出/解密」用例把密码打进配置框（实测会假红）。因此：
  // · DeepSeek / 在线语音配置 → 各自的编辑对话框；
  // · 试听文本 → 试听对话框；
  // · 音色选择 → 无输入框的 ListTile 列表。
  String _dsBaseUrl = ApiConfigStore.defaultBaseUrl;
  String _dsModel = ApiConfigStore.defaultModel;
  String _dsApiKey = '';
  String _ttsEndpoint = '';
  String _ttsApiKey = '';
  bool _onlineTtsConfigured = false;

  /// 试听所选音色 id（`TtsVoices`）。
  String _previewVoiceId = TtsVoices.defaultId;

  CounterPlan? _plan;
  bool _planEnabled = false;

  /// 联网一键更新落库的节假日表（条数 / 上次更新时间），仅用于本页如实展示。
  int _holidayDayCount = 0;
  DateTime? _holidayUpdatedAt;

  /// 反击计划的**生成参数**（音量区间 / 时长区间 / 每小时次数区间 / 动作间隔
  /// 区间 / 休息日两段是否反击……）。本机随机与 AI 生成共用同一份，落库在
  /// `counter_plan_params_json`；未配置时用出厂约定区间。
  CounterPlanParams _planParams = CounterPlanParams.defaults();

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
    final cfg = ApiConfigStore(p);
    final planStore = CounterPlanStore(p);
    setState(() {
      _powerMode = p.getString(PrefsKeys.powerMode) ?? 'balanced';
      _quietStart = p.getInt(PrefsKeys.quietStartHour) ??
          ComplianceGuardrails.defaultQuietStartHour;
      _quietEnd = p.getInt(PrefsKeys.quietEndHour) ??
          ComplianceGuardrails.defaultQuietEndHour;
      _quietExemptMaster = p.getBool(PrefsKeys.quietExemptMaster) ?? false;
      _dsBaseUrl = cfg.baseUrl;
      _dsModel = cfg.model;
      _dsApiKey = cfg.apiKey;
      _ttsEndpoint = cfg.ttsEndpoint;
      _ttsApiKey = cfg.ttsApiKey;
      _onlineTtsConfigured = cfg.onlineTtsConfigured;
      _plan = planStore.loadPlan();
      _planEnabled = planStore.enabled;
      _planParams = planStore.loadParams() ?? CounterPlanParams.defaults();
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------- 语音与接口（v2.0） ----------------

  /// 编辑并保存 DeepSeek 配置（基址/模型/Key）。
  Future<void> _editDeepSeek() async {
    final out = await showDialog<List<String>>(
      context: context,
      builder: (_) => _FieldsDialog(
        title: 'DeepSeek 接口配置',
        fields: [
          _FieldSpec('API 基址', _dsBaseUrl, hint: ApiConfigStore.defaultBaseUrl),
          _FieldSpec('模型', _dsModel, hint: ApiConfigStore.defaultModel),
          _FieldSpec('API Key', _dsApiKey, obscure: true, hint: '留空即清除'),
        ],
      ),
    );
    if (out == null) return;
    final cfg = ApiConfigStore(await SharedPreferences.getInstance());
    await cfg.setBaseUrl(out[0]);
    await cfg.setModel(out[1]);
    await cfg.setApiKey(out[2]);
    if (!mounted) return;
    setState(() {
      _dsBaseUrl = cfg.baseUrl;
      _dsModel = cfg.model;
      _dsApiKey = cfg.apiKey;
    });
    _snack('DeepSeek 配置已保存');
  }

  /// 编辑并保存在线语音配置（endpoint + Key）。
  Future<void> _editOnlineTts() async {
    final out = await showDialog<List<String>>(
      context: context,
      builder: (_) => _FieldsDialog(
        title: '在线语音配置',
        fields: [
          _FieldSpec('在线语音 Endpoint', _ttsEndpoint,
              hint: '默认内置免 Key 端点（Edge 大声朗读）；留空即关闭在线语音'),
          _FieldSpec('在线语音 Key', _ttsApiKey,
              obscure: true, hint: '内置端点免 Key；改用 Azure 等 REST 端点时才需填写'),
        ],
      ),
    );
    if (out == null) return;
    final cfg = ApiConfigStore(await SharedPreferences.getInstance());
    await cfg.setOnlineTts(endpoint: out[0], apiKey: out[1]);
    if (!mounted) return;
    setState(() {
      _ttsEndpoint = cfg.ttsEndpoint;
      _ttsApiKey = cfg.ttsApiKey;
      _onlineTtsConfigured = cfg.onlineTtsConfigured;
    });
    _snack(_onlineTtsConfigured
        ? '在线语音已配置（东北话音色可用）'
        : '在线语音已关闭：仅系统音色可用');
  }

  /// 打开试听对话框（输入文字 → 走 `TtsService.say`）。
  Future<void> _openPreview() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TtsPreviewDialog(
        voiceName: TtsVoices.byId(_previewVoiceId).name,
        onPreview: _previewVoice,
      ),
    );
  }

  Future<void> _previewVoice(String text) async {
    final svc = await ref.read(ttsServiceProvider.future);
    final r = await svc.say(text, voiceId: _previewVoiceId);
    if (!mounted) return;
    _snack(r.ok
        ? '已试听：${TtsVoices.byId(_previewVoiceId).name}'
        : '试听失败：${r.message ?? '未知原因'}');
  }

  // ---------------- 反击计划（v2.0） ----------------

  Future<void> _reloadPlan() async {
    final p = await SharedPreferences.getInstance();
    final store = CounterPlanStore(p);
    if (!mounted) return;
    setState(() {
      _plan = store.loadPlan();
      _planEnabled = store.enabled;
      _planParams = store.loadParams() ?? CounterPlanParams.defaults();
      _holidayDayCount = store.autoOverrides().length;
      _holidayUpdatedAt = store.autoOverridesUpdatedAt();
    });
  }

  /// 本机按同一份生成参数随机并启用（离线可用）。
  Future<void> _genLocalPlan() async {
    final svc = await ref.read(counterPlanServiceProvider.future);
    final r = await svc.apply(CounterPlanRandom.generate(params: _planParams));
    await _reloadPlan();
    _snack(r.message);
  }

  /// 一键 AI 生成：把当前生成参数拼进提示词；校验通过才落库。
  Future<void> _genAiPlan() async {
    final ds = await ref.read(deepseekServiceProvider.future);
    final gen = await ds.generatePlan(params: _planParams);
    if (!gen.ok || gen.plan == null) {
      _snack('AI 生成失败：${gen.message}');
      return;
    }
    final svc = await ref.read(counterPlanServiceProvider.future);
    final r = await svc.apply(gen.plan!);
    await _reloadPlan();
    _snack(r.ok ? '${gen.message}；${r.message}' : r.message);
  }

  /// 导入 JSON 计划文件：解析失败/校验失败都如实提示，不落库。
  Future<void> _importPlanJson() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.single.path == null) return;
      final raw = await File(result.files.single.path!).readAsString();
      final plan = CounterPlan.tryParse(raw);
      if (plan == null) {
        _snack('导入失败：文件不是合法 JSON');
        return;
      }
      final errs = plan.validate();
      if (errs.isNotEmpty) {
        _snack('计划校验未通过：${errs.join('；')}');
        return;
      }
      final svc = await ref.read(counterPlanServiceProvider.future);
      final r = await svc.apply(plan);
      await _reloadPlan();
      _snack(r.message);
    } catch (e) {
      _snack('导入失败：$e');
    }
  }

  /// 下载 JSON 模版（默认计划 → 分享分发）。
  Future<void> _downloadPlanTemplate() async {
    try {
      final json = CounterPlan.defaults().toPrettyJson();
      final dir = await getTemporaryDirectory();
      // ⚠️ 必须用 `dir.path`（BUG-065）：`Directory.toString()` 带回
      // `Directory: '...'` 前缀，插值出的路径不存在，写盘必抛。
      final path = '${dir.path}/sonicshield_counter_plan_template.json';
      await File(path).writeAsString(json, flush: true);
      if (!mounted) return;
      await Share.shareXFiles([XFile(path)], subject: '声盾反击计划模版');
    } catch (e) {
      _snack('导出模版失败：$e');
    }
  }

  Future<void> _disablePlan() async {
    final svc = await ref.read(counterPlanServiceProvider.future);
    final r = await svc.disable();
    await _reloadPlan();
    _snack(r.message);
  }

  /// 一键更新中国节假日（联网）：拉取公开数据源 → 落库自动覆盖表 → 按需重排。
  ///
  /// **失败不静默、不写空表**：全部年份都失败时如实报错，内置表与旧表原样保留
  /// （`HolidayUpdateService` 只在有成功结果时才返回非空 overrides）。
  Future<void> _updateHolidays() async {
    _snack('正在联网更新节假日…');
    try {
      final svc = await ref.read(holidayUpdateServiceProvider.future);
      final res = await svc.update();
      if (!res.anyOk) {
        _snack('节假日更新失败（已保留内置表）：\n${res.describe()}');
        return;
      }
      final plan = await ref.read(counterPlanServiceProvider.future);
      final r = await plan.refreshHolidays(res.overrides);
      await _reloadPlan();
      _snack('${res.describe()}\n${r.message}');
    } catch (e) {
      _snack('节假日更新失败（已保留内置表）：$e');
    }
  }

  String _fmtDay(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 编辑并保存**生成参数**（音量区间 / 时长区间 / 每小时次数 / 动作间隔 /
  /// 时段开关 / 白天起止小时）。
  ///
  /// 用对话框承载（本页**禁止常驻 `TextField`**，见文件顶部注释）；滑块与开关
  /// 即改即显。保存后本机随机与 AI 生成**同时**读到新参数（同一份 `_planParams`）。
  Future<void> _editPlanParams() async {
    final out = await showDialog<CounterPlanParams>(
      context: context,
      builder: (_) => _PlanParamsDialog(initial: _planParams),
    );
    if (out == null) return;
    final errs = out.validate();
    if (errs.isNotEmpty) {
      _snack('参数未通过校验：${errs.join('；')}');
      return;
    }
    final p = await SharedPreferences.getInstance();
    await CounterPlanStore(p).saveParams(out);
    if (!mounted) return;
    setState(() => _planParams = out);
    _snack('生成参数已保存（本机随机与 AI 生成同时生效）');
  }

  /// 音色列表：按「普通话 / 东北话」分组，标注男/女，可选中（无输入框）。
  List<Widget> _voiceWidgets(BuildContext context) {
    final out = <Widget>[];
    for (final d in TtsDialect.values) {
      out.add(Padding(
        padding: const EdgeInsets.only(left: AppSpacing.lg, top: AppSpacing.sm),
        child: Text(d.label, style: Theme.of(context).textTheme.labelLarge),
      ));
      for (final v in TtsVoices.all.where((v) => v.dialect == d)) {
        out.add(ListTile(
          key: ValueKey<String>('voice_${v.id}'),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          title: Text('${v.name}（${v.gender.label}）'),
          subtitle: Text(v.summary),
          trailing: Icon(_previewVoiceId == v.id
              ? Icons.radio_button_checked
              : Icons.radio_button_off),
          onTap: () => setState(() => _previewVoiceId = v.id),
        ));
      }
    }
    return out;
  }

  /// 反击计划区块：状态 + 四时段区间 + 五个操作。
  List<Widget> _planWidgets(BuildContext context) {
    final p = _plan;
    final out = <Widget>[
      Text('反击计划', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      ListTile(
        leading: const Icon(Icons.security),
        title: Text(p == null ? '当前计划：未配置' : '当前计划：${p.name}'),
        subtitle: Text(p == null
            ? '用下方按钮生成或导入一份计划'
            : (_planEnabled
                ? '已启用（任务命名空间 counter:，与手动任务隔离）'
                : '未启用（已下线，保留计划本体）')),
      ),
    ];
    if (p != null) {
      for (final e in <(String, CounterWindow)>[
        ('工作日·白天', p.windowFor(DayKind.workday, isNight: false)),
        ('工作日·夜间', p.windowFor(DayKind.workday, isNight: true)),
        ('休息日·白天', p.windowFor(DayKind.restday, isNight: false)),
        ('休息日·夜间', p.windowFor(DayKind.restday, isNight: true)),
      ]) {
        out.add(ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          title: Text(e.$1),
          subtitle:
              Text(e.$2.enabled ? describeWindow(e.$2) : '未启用（该时段不反击）'),
        ));
      }
    }
    out.add(ListTile(
      key: const ValueKey<String>('plan_params_edit'),
      leading: const Icon(Icons.tune),
      title: const Text('编辑生成参数'),
      subtitle: Text(_planParams.summary()),
      isThreeLine: true,
      onTap: _editPlanParams,
    ));
    out.addAll(<Widget>[
      ListTile(
        leading: const Icon(Icons.casino_outlined),
        title: const Text('本机随机生成并启用'),
        subtitle: const Text('离线按当前参数区间随机（与 AI 同一份参数）'),
        onTap: _genLocalPlan,
      ),
      ListTile(
        leading: const Icon(Icons.auto_awesome),
        title: const Text('一键 AI 生成并导入'),
        subtitle: const Text('需先配置 DeepSeek Key'),
        onTap: _genAiPlan,
      ),
      ListTile(
        leading: const Icon(Icons.file_open_outlined),
        title: const Text('导入 JSON'),
        onTap: _importPlanJson,
      ),
      ListTile(
        key: const ValueKey<String>('holiday_update'),
        leading: const Icon(Icons.event_available_outlined),
        title: const Text('一键更新节假日（联网）'),
        subtitle: Text(_holidayDayCount > 0
            ? '已更新 $_holidayDayCount 天'
                '${_holidayUpdatedAt == null ? '' : ' · ${_fmtDay(_holidayUpdatedAt!)}'}'
            : '拉取公开数据源（覆盖 '
                '${HolidayUpdateService.defaultYears().join('、')} 年）；失败保留内置表'),
        onTap: _updateHolidays,
      ),
      ListTile(
        leading: const Icon(Icons.download_outlined),
        title: const Text('下载 JSON 模版'),
        subtitle: const Text('sonicshield_counter_plan_template.json'),
        onTap: _downloadPlanTemplate,
      ),
      ListTile(
        leading: const Icon(Icons.stop_circle_outlined),
        title: const Text('下线'),
        subtitle: const Text('清除计划任务并停用（保留计划本体）'),
        onTap: _disablePlan,
      ),
    ]);
    return out;
  }

  /// 切换夜间独立豁免主开关（v79，docs/20 §8.1）。
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
              '本开关是任务的**默认值**：开启后，所有任务默认在免打扰时段'
              '（默认 22:00–07:00）照常执行；关闭后默认全部跳过或平移。\n\n'
              '个别任务可在任务编辑器里单独反向设置（强制豁免 / 强制不豁免），'
              '这些偏离默认值的任务会在下方「例外清单」中列出。\n\n'
              '这意味着：\n'
              '· 夜间可能响起你为这些任务配置的声音/震动；\n'
              '· 本应用定位为个人自动化工具，请勿用它干扰他人；\n'
              '· 每次豁免执行都会写入日志，本页可查看本月次数。\n\n'
              '随时可在此关闭；关闭后已排入的豁免计划会被立即清除'
              '（个别"强制豁免"的例外仍会保留）。',
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
    // 立刻重算：开启后豁免计划才会被物化；关闭后引擎会清除已落库的豁免计划
    // （仅保留 `quietExempt == true` 的强制豁免例外）。
    await BackgroundServiceManager.instance.replan();
    if (mounted) {
      ref.invalidate(quietExemptCountProvider);
      ref.invalidate(quietExemptOverrideTasksProvider);
      // ⚠️ 必须一并失效**任务列表**：本页在 `StatefulShellRoute.indexedStack` 下
      // 与任务列表**同时常驻**，`taskListProvider`（autoDispose）被列表页持续
      // watch ⇒ 缓存不会因切页而失效。豁免开关改变了「下一触发」的物化结果，
      // 不失效这里，列表会一直显示旧时间（用户实测："豁免后下一任务时间没变"）。
      ref.invalidate(taskListProvider);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(next
              ? '已开启夜间豁免主开关：所有任务默认豁免（个别可强制不豁免）'
              : '已关闭夜间豁免主开关：所有任务默认不豁免（个别可强制豁免）')));
    }
  }

  Future<void> _savePower(String mode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(PrefsKeys.powerMode, mode);
    await BackgroundServiceManager.instance.setPowerMode(mode);
    if (mounted) setState(() => _powerMode = mode);
  }

  Future<void> _saveQuiet() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(PrefsKeys.quietStartHour, _quietStart);
    await p.setInt(PrefsKeys.quietEndHour, _quietEnd);
    await BackgroundServiceManager.instance.replan();
    // 同上：免打扰窗口变更也会改变物化结果（平移点变了）⇒ 一并失效任务列表。
    ref.invalidate(taskListProvider);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: DefaultTabController(
        // FR-80（第八十四轮用户明文）：反击计划独立成一个 TAB ⇒ 4 → 5。
        length: 5,
        child: Column(
          children: [
            const TabBar(
              isScrollable: true,
              tabs: [
                Tab(text: '执行与护栏'),
                Tab(text: '保活与备份'),
                // ⚠️ 刻意不叫「语音与接口」—— 那会与下方同名分区标题撞成两处
                // 同文案，`find.text('语音与接口')` 的 findsOneWidget 会判红。
                Tab(text: '语音与音色'),
                // FR-80：反击计划独占一个 TAB（此前内嵌在「语音与音色」里）。
                Tab(text: '反击计划'),
                Tab(text: '数据与合规'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _tabBody(_secExecution(context)),
                  _tabBody(_secKeepAlive(context)),
                  _tabBody(_secVoice(context)),
                  _tabBody(_secCounterPlan(context)),
                  _tabBody(_secData(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 单个 TAB 的滚动容器（各 TAB 各自滚动、互不干扰）。
  ///
  /// ⚠️ 第八十二轮：设置页原先是一个**超长单页 ListView**（用户反馈太长），
  /// 现按功能分成 TAB。⚠️ 第八十四轮 FR-80：4 → **5** 个 TAB（反击计划独立）。
  /// 注意 `TabBarView` 是**惰性**的 —— 非活动 TAB 的
  /// 子树不在 widget 树里，`find.text(...)` 默认找不到它们（测试需先切 TAB）。
  Widget _tabBody(List<Widget> children) => ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: children,
      );

  /// TAB 1「执行与护栏」：电源策略 / 强制免打扰时段 / 夜间独立豁免。
  List<Widget> _secExecution(BuildContext context) => [
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
            padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text(
                '性能优先：额外持有唤醒锁，锁屏后 CPU 不休眠、定时最准（更耗电）；'
                '省电模式：电量 < 15% 且未充电时自动暂停随机类任务与守卫，仅保留固定定时。',
                style: AppText.bodySmall),
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
            padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text(
                '合规护栏：默认 22:00–07:00 强制免打扰。此处只能把窗口**调窄**，不能调宽。',
                style: AppText.bodySmall),
          ),
          const SizedBox(height: 4),
          const Divider(height: 32),
          Text('夜间独立豁免', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          // ---- 夜间独立豁免（v79，docs/20 §8）：主开关即"默认值" + 任务级双向覆盖 ----
          Builder(builder: (context) {
            final enabled = _quietExemptMaster;
            // 计数走 provider：设置页只消费，且 widget 测试能把它换掉
            // （真实 sqflite 往返在 FakeAsync 里会留下未完成的 Timer）。
            final count = ref.watch(quietExemptCountProvider);
            final overrides = ref.watch(quietExemptOverrideTasksProvider);
            // 例外清单 = **显式反向设置**（偏离主开关默认值）的任务。
            // `null`（跟随主开关）永不入列；主开关一变动，这里按当时的 [enabled]
            // 重算，无需重查库。
            final exceptions = (overrides.valueOrNull ?? const <Task>[])
                .where((t) => t.quietExempt != enabled)
                .toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.nightlight_round),
                  title: const Text('夜间独立豁免（主开关）'),
                  subtitle: Text(enabled
                      ? '已开启：所有任务默认豁免（在免打扰时段照常执行）'
                      : '关闭中：所有任务默认不豁免（免打扰时段跳过或平移）'),
                  value: enabled,
                  onChanged: _toggleQuietExempt,
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 56, bottom: AppSpacing.xs),
                  child: Text(
                    // 读不到时显示"—"而不是 0：把"读失败"显示成"没豁免过"
                    // 会让用户以为护栏完好，属于误导。
                    '本月豁免次数：${count.valueOrNull?.toString() ?? '—'}'
                    '（每次豁免执行都会写入日志）',
                    style: AppText.bodySmall,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 56, bottom: AppSpacing.sm),
                  child: Text(
                    '⚠️ 开启豁免即削弱合规护栏，仅限个人场景（夜间静默提醒/闹钟）。'
                    '远程对端无法开启本开关，也无法为任务开启豁免。',
                    style: AppText.bodySmall,
                  ),
                ),
                // ---- 例外清单（偏离主开关默认值的任务）----
                Padding(
                  padding: const EdgeInsets.only(left: 56, bottom: AppSpacing.xs),
                  child: Text(
                    '例外清单（${exceptions.length} 条偏离默认值）',
                    style: AppText.bodyMedium.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (exceptions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(left: 56, bottom: AppSpacing.sm),
                    child: Text('无：所有任务都跟随主开关默认值',
                        style: AppText.bodySmall),
                  )
                else
                  for (final t in exceptions)
                    Padding(
                      padding: const EdgeInsets.only(left: 56, bottom: 2),
                      child: Text(
                        '· ${t.name}'
                        '（${t.quietExempt == true ? '强制豁免' : '强制不豁免'}）',
                        style: AppText.bodySmall,
                      ),
                    ),
              ],
            );
          }),
        ];

  /// TAB 2「保活与备份」：后台保活 / 任务备份。
  ///
  /// ⚠️ 第八十二轮：「全局执行总开关（节假日自动暂停）」已**移植到守护首页**
  /// （`features/guard/guard_screen.dart` 的 `_buildRunMasterCard`）—— 它是
  /// "到底执不执行"的总闸，与守卫/动态反击同属执行控制，放守护页更该被看见。
  List<Widget> _secKeepAlive(BuildContext context) => [
          Text('后台保活', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const _KeepAliveSelfCheck(),
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
        ];

  /// TAB 3「语音与接口」：TTS/DeepSeek 接口、音色与试听。
  ///
  /// ⚠️ 第八十四轮 FR-80：原属本 TAB 的「反击计划」已**独立成第 4 个 TAB**。
  List<Widget> _secVoice(BuildContext context) => [
          Text('语音与接口', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: const Text('DeepSeek 接口配置'),
            subtitle: Text('基址 $_dsBaseUrl · 模型 $_dsModel · '
                'Key ${_dsApiKey.isEmpty ? '未配置' : '已配置'}'),
            onTap: _editDeepSeek,
          ),
          ListTile(
            leading: const Icon(Icons.translate),
            title: const Text('在线语音配置'),
            subtitle: Text(_onlineTtsConfigured
                ? (_ttsEndpoint == ApiConfigStore.defaultTtsEndpoint
                    ? '内置免费在线语音（开箱可用）：Microsoft Edge 大声朗读'
                    : '已配置：$_ttsEndpoint')
                : '在线语音已关闭：仅系统音色可用（东北话需在线语音）'),
            onTap: _editOnlineTts,
          ),
          const Padding(
            padding: EdgeInsets.only(left: AppSpacing.lg, top: AppSpacing.sm, bottom: 2),
            child: Text('音色（离线优先，可选中后试听）',
                style: AppText.bodySmall),
          ),
          ..._voiceWidgets(context),
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('试听所选音色'),
            subtitle: Text(TtsVoices.byId(_previewVoiceId).name),
            onTap: _openPreview,
          ),
        ];

  /// TAB 4「反击计划」（FR-80，第八十四轮用户明文：反击计划**独立成一个 TAB**）。
  ///
  /// 此前它内嵌在「语音与音色」TAB 末尾；现独占一页 ——
  /// 反击计划是**执行策略**，与语音/音色不是一类东西（用户诉求即"别混在一起"）。
  ///
  /// ⚠️ 分区标题 `Text('反击计划')` 由 [\_planWidgets] 提供（单一真源）——
  /// 此处**不再重复**加标题，否则 TAB 标签 + 两处标题 = 3 个同文案 widget，
  /// `find.text('反击计划')` 的断言会判红（实测 `SET-07c`）。
  List<Widget> _secCounterPlan(BuildContext context) => [
        const Padding(
          padding: EdgeInsets.only(bottom: AppSpacing.sm),
          child: Text(
            '随机反击计划：按当前参数区间离线随机生成，或由 AI 生成后导入；'
            '启用后任务落在 counter: 命名空间，与手动任务隔离。',
            style: AppText.bodySmall,
          ),
        ),
        ..._planWidgets(context),
      ];

  /// TAB 4「数据与合规」：录音取证 / 合规须知 / 关于。
  List<Widget> _secData(BuildContext context) => [
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
          const Divider(height: 32),
          Text('关于', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            key: const ValueKey<String>('about_version'),
            leading: const Icon(Icons.info_outline),
            title: const Text(AppMeta.appName),
            // 版本串**只从常量取**（`AppMeta.displayVersion` = version+buildNumber）。
            // 历史上这里写死过 `v1.0.0`，此后漂了多个版本没人发现 —— 与「每次迭代
            // APP 中显示的版本必须同步更新」这条基线相悖。现由
            // `test/version_consistency_test.dart` 机器锁死：既锁常量与 pubspec 一致，
            // 也锁本文件不得再出现写死的版本号。
            subtitle: Text('v${AppMeta.displayVersion} · Flutter 跨平台 · 仅限合法用途'),
          ),
        ];
}

/// 一个可编辑字段的规格（供 [_FieldsDialog] 声明式渲染）。
class _FieldSpec {
  const _FieldSpec(this.label, this.initial, {this.obscure = false, this.hint});

  final String label;
  final String initial;
  final bool obscure;
  final String? hint;
}

/// 通用多字段编辑对话框：控制器由自身持有并在 `dispose()` 释放（BUG-064 形状）。
///
/// 点「保存」返回各字段文本（[List<String>]）；「取消」返回 null。
class _FieldsDialog extends StatefulWidget {
  const _FieldsDialog({required this.title, required this.fields});

  final String title;
  final List<_FieldSpec> fields;

  @override
  State<_FieldsDialog> createState() => _FieldsDialogState();
}

class _FieldsDialogState extends State<_FieldsDialog> {
  late final List<TextEditingController> _ctrls = [
    for (final f in widget.fields) TextEditingController(text: f.initial),
  ];

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.fields.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: TextField(
                      controller: _ctrls[i],
                      obscureText: widget.fields[i].obscure,
                      decoration: InputDecoration(
                        labelText: widget.fields[i].label,
                        hintText: widget.fields[i].hint,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, [for (final c in _ctrls) c.text]),
            child: const Text('保存'),
          ),
        ],
      );
}

/// 试听对话框：输入文字 → [onPreview] 走 `TtsService.say`（结果由上层提示）。
class _TtsPreviewDialog extends StatefulWidget {
  const _TtsPreviewDialog({required this.voiceName, required this.onPreview});

  final String voiceName;
  final Future<void> Function(String text) onPreview;

  @override
  State<_TtsPreviewDialog> createState() => _TtsPreviewDialogState();
}

class _TtsPreviewDialogState extends State<_TtsPreviewDialog> {
  final _ctrl = TextEditingController(text: '你好');
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onPreview(_ctrl.text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('试听 · ${widget.voiceName}'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: _ctrl,
            decoration: const InputDecoration(labelText: '试听文本'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭')),
          FilledButton.icon(
            onPressed: _busy ? null : _run,
            icon: const Icon(Icons.play_arrow),
            label: const Text('试听'),
          ),
        ],
      );
}

/// 反击计划「生成参数」编辑对话框（参数化选择：音量区间 / 时长区间 /
/// 每小时次数区间 / 动作间隔区间 / 四个时段开关 / 白天起止小时）。
///
/// ## 为什么只用滑块与开关，**不用 `TextField`**
/// 设置页靠"页面上没有常驻输入框"来保证导出/加密用例里
/// `find.byType(TextField).at(0)` 取到的就是密码框（见文件顶部注释）。
/// 对话框虽在叠加层，但仍统一不用输入框 —— 参数天然是数值区间，滑块更直观。
///
/// 「保存」返回 [CounterPlanParams]；「取消」返回 null；「恢复默认」回到出厂区间。
class _PlanParamsDialog extends StatefulWidget {
  const _PlanParamsDialog({required this.initial});

  final CounterPlanParams initial;

  @override
  State<_PlanParamsDialog> createState() => _PlanParamsDialogState();
}

class _PlanParamsDialogState extends State<_PlanParamsDialog> {
  late CounterPlanParams _p = widget.initial.clamped();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('反击计划生成参数'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('调好的参数同时作用于「本机随机生成」与「一键 AI 生成」。',
                  style: AppText.bodySmall),
              _section('排期模式'),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  for (final m in PlanScheduleMode.values)
                    ChoiceChip(
                      key: ValueKey<String>('pp_mode_${m.name}'),
                      label: Text(m.label),
                      selected: _p.scheduleMode == m,
                      onSelected: (_) =>
                          setState(() => _p = _p.copyWith(scheduleMode: m)),
                    ),
                ],
              ),
              ..._scheduleFields(),
              _section('时段与间隔'),
              _range(
                '白天时段',
                0,
                23,
                23,
                _p.dayStartHour.toDouble(),
                _p.dayEndHour.toDouble(),
                (v) => setState(() => _p = _p.copyWith(
                      dayStartHour: v.start.round(),
                      dayEndHour: v.end.round(),
                    )),
                fmt: (v) => '${v.round()}:00',
              ),
              _range(
                '动作间隔（秒）',
                0,
                CounterPlanParams.maxCooldownSec.toDouble(),
                96,
                _p.cooldownSecMin.toDouble(),
                _p.cooldownSecMax.toDouble(),
                (v) => setState(() => _p = _p.copyWith(
                      cooldownSecMin: v.start.round(),
                      cooldownSecMax: v.end.round(),
                    )),
                fmt: (v) => '${v.round()}s',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('遵循免打扰时段'),
                value: _p.respectQuietHours,
                onChanged: (v) =>
                    setState(() => _p = _p.copyWith(respectQuietHours: v)),
              ),
              _section('工作日'),
              _window('工作日·白天', _p.workdayDay,
                  (w) => _p.copyWith(workdayDay: w)),
              _window('工作日·夜间', _p.workdayNight,
                  (w) => _p.copyWith(workdayNight: w)),
              _section('休息日（可选）'),
              _window('休息日·白天', _p.restdayDay,
                  (w) => _p.copyWith(restdayDay: w)),
              _window('休息日·夜间', _p.restdayNight,
                  (w) => _p.copyWith(restdayNight: w)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () =>
                setState(() => _p = CounterPlanParams.defaults()),
            child: const Text('恢复默认')),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _p),
            child: const Text('保存')),
      ],
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 2),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );

  /// 按当前排期模式渲染**仅该模式需要**的字段（其余模式不显示，避免误配）。
  List<Widget> _scheduleFields() {
    switch (_p.scheduleMode) {
      case PlanScheduleMode.single:
        return const <Widget>[
          Padding(
            padding: EdgeInsets.only(top: AppSpacing.xs),
            child: Text('在接下来的一周内随机反击 1 次。', style: AppText.bodySmall),
          ),
        ];
      case PlanScheduleMode.several:
        return <Widget>[
          _intDropdown('次数', 'pp_occ', _p.occurrenceCount, 1, 12,
              (v) => setState(() => _p = _p.copyWith(occurrenceCount: v))),
        ];
      case PlanScheduleMode.severalDays:
        return <Widget>[
          _intDropdown('天数', 'pp_span', _p.spanDays, 1, 30,
              (v) => setState(() => _p = _p.copyWith(spanDays: v))),
        ];
      case PlanScheduleMode.specificDate:
        return <Widget>[
          _dateTile('指定日期', 'pp_specific_date', _p.specificDate,
              (iso) => setState(() => _p = _p.copyWith(specificDate: iso))),
        ];
      case PlanScheduleMode.dateRange:
        return <Widget>[
          _dateTile('起始日期', 'pp_range_start', _p.rangeStart,
              (iso) => setState(() => _p = _p.copyWith(rangeStart: iso))),
          _dateTile('结束日期', 'pp_range_end', _p.rangeEnd,
              (iso) => setState(() => _p = _p.copyWith(rangeEnd: iso))),
        ];
      case PlanScheduleMode.recurringRandom:
        const names = <String>['一', '二', '三', '四', '五', '六', '日'];
        return <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Wrap(
              spacing: 6,
              children: [
                for (var i = 1; i <= 7; i++)
                  FilterChip(
                    key: ValueKey<String>('pp_wd_$i'),
                    label: Text('周${names[i - 1]}'),
                    selected: _p.weekdays.contains(i),
                    onSelected: (sel) => setState(() {
                      final set = <int>{..._p.weekdays};
                      if (sel) {
                        set.add(i);
                      } else if (set.length > 1) {
                        set.remove(i); // 至少保留一天，避免生成空计划
                      }
                      _p = _p.copyWith(weekdays: set.toList()..sort());
                    }),
                  ),
              ],
            ),
          ),
        ];
    }
  }

  Widget _intDropdown(String label, String key, int value, int lo, int hi,
      ValueChanged<int> onChanged) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        DropdownButton<int>(
          key: ValueKey<String>(key),
          value: value.clamp(lo, hi),
          items: [
            for (var i = lo; i <= hi; i++)
              DropdownMenuItem<int>(value: i, child: Text('$i')),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }

  /// 日期选择行：未设置显示「未设置」，选择后回填 ISO `yyyy-MM-dd`。
  Widget _dateTile(String label, String key, String? iso,
      ValueChanged<String> onChanged) {
    final d = CounterPlan.parseIsoDate(iso);
    return Row(
      children: [
        Expanded(child: Text(label)),
        TextButton(
          key: ValueKey<String>(key),
          onPressed: () async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: d ?? now,
              firstDate: DateTime(now.year - 1),
              lastDate: DateTime(now.year + 3),
            );
            if (picked != null) {
              onChanged('${picked.year.toString().padLeft(4, '0')}-'
                  '${picked.month.toString().padLeft(2, '0')}-'
                  '${picked.day.toString().padLeft(2, '0')}');
            }
          },
          child: Text(iso ?? '未设置'),
        ),
      ],
    );
  }

  /// 单个时段的开关 + 三条区间滑块（关闭时只留开关，避免误调）。
  Widget _window(
    String label,
    PlanWindowParams w,
    CounterPlanParams Function(PlanWindowParams) update,
  ) {
    final c = w.clamped();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: ValueKey<String>('pp_enabled_$label'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(label),
          value: c.enabled,
          onChanged: (v) =>
              setState(() => _p = update(w.copyWith(enabled: v))),
        ),
        if (c.enabled) ...[
          _range(
            '$label 音量',
            0,
            1,
            20,
            c.volumeMin,
            c.volumeMax,
            (v) => setState(() => _p = update(
                w.copyWith(volumeMin: v.start, volumeMax: v.end))),
            fmt: (v) => '${(v * 100).round()}%',
          ),
          _range(
            '$label 时长（秒）',
            1,
            CounterWindow.maxDurationSec.toDouble(),
            CounterWindow.maxDurationSec - 1,
            c.durationSecMin.toDouble(),
            c.durationSecMax.toDouble(),
            (v) => setState(() => _p = update(w.copyWith(
                durationSecMin: v.start.round(),
                durationSecMax: v.end.round()))),
            fmt: (v) => '${v.round()}s',
          ),
          _range(
            '$label 每小时次数',
            0,
            CounterWindow.maxActionsPerHour.toDouble(),
            CounterWindow.maxActionsPerHour,
            c.actionsPerHourMin.toDouble(),
            c.actionsPerHourMax.toDouble(),
            (v) => setState(() => _p = update(w.copyWith(
                actionsPerHourMin: v.start.round(),
                actionsPerHourMax: v.end.round()))),
            fmt: (v) => '${v.round()}',
          ),
        ],
      ],
    );
  }

  Widget _range(
    String label,
    double min,
    double max,
    int divisions,
    double lo,
    double hi,
    ValueChanged<RangeValues> onChanged, {
    required String Function(double) fmt,
  }) {
    final a = lo.clamp(min, max);
    final b = hi.clamp(min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          child: Text('$label：${fmt(a)} – ${fmt(b)}',
              style: AppText.bodySmall),
        ),
        RangeSlider(
          min: min,
          max: max,
          divisions: divisions,
          values: RangeValues(a <= b ? a : b, a <= b ? b : a),
          labels: RangeLabels(fmt(a), fmt(b)),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// 保活自检面板（v1.9.1）：一眼看清"锁屏后能否继续工作"所依赖的四项是否就绪。
///
/// 为什么需要它：用户反馈"锁屏后功能全部失效"，而根因往往是**不在普通权限
/// 列表里**的两项（精确闹钟特殊权限 / 厂商省电策略）没设置 —— 用户"以为给了
/// 所有权限"。本面板把四项状态显式列出并给出**一键修复入口**，消灭这一盲区。
///
/// 四项（任一 ✗ 都可能导致锁屏后失效）：
///   ① 精确闹钟特殊权限（通道 B 前提；Android 14+ 对 targetSdk≥34 默认拒绝）
///   ② 电池优化白名单（Doze 豁免）
///   ③ 通知权限（前台服务常驻通知的前提）
///   ④ 调度引擎运行中（前台服务在跑）
///
/// 全部状态读取都 **try/catch 容错**：桥不可用（桌面/测试）时按"未就绪"显示，
/// 绝不抛异常；且**不创建任何 Timer**，避免污染 widget 测试（同「kv 表会留
/// 未完成 Timer」的既有教训）。
class _KeepAliveSelfCheck extends StatefulWidget {
  const _KeepAliveSelfCheck();

  @override
  State<_KeepAliveSelfCheck> createState() => _KeepAliveSelfCheckState();
}

class _KeepAliveSelfCheckState extends State<_KeepAliveSelfCheck> {
  // null = 正在检测（显示沙漏）。
  bool? _exactAlarm;
  bool? _batteryWhitelist;
  bool? _notification;
  bool _engineRunning = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var exact = false;
    var battery = false;
    var notif = false;
    try {
      exact = await NativeBridge.exactAlarmSupported();
    } on Object {
      exact = false;
    }
    try {
      battery = await NativeBridge.isIgnoringBatteryOptimizations();
    } on Object {
      battery = false;
    }
    try {
      notif = (await Permission.notification.status).isGranted;
    } on Object {
      notif = false;
    }
    if (!mounted) return;
    setState(() {
      _exactAlarm = exact;
      _batteryWhitelist = battery;
      _notification = notif;
      _engineRunning = BackgroundServiceManager.instance.isRunning;
    });
  }

  Widget _statusIcon(bool? ok) {
    if (ok == null) {
      return const Icon(Icons.hourglass_empty, color: AppColors.warning);
    }
    return Icon(
      ok ? Icons.check_circle : Icons.cancel,
      color: ok ? AppColors.success : AppColors.danger,
    );
  }

  void _recheck() {
    setState(() {
      _exactAlarm = null;
      _batteryWhitelist = null;
      _notification = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('保活自检'),
            subtitle: const Text('锁屏后能否继续工作的四项前提'),
            trailing: IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '重新检测',
              onPressed: _recheck,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: _statusIcon(_exactAlarm),
            title: const Text('精确闹钟权限'),
            subtitle: const Text('锁屏/Doze 下唯一可靠通道；「闹钟和提醒」特殊权限'),
            trailing: TextButton(
              onPressed: () async {
                await NativeBridge.openExactAlarmSettings();
                await _load();
              },
              child: const Text('去开启'),
            ),
          ),
          ListTile(
            leading: _statusIcon(_batteryWhitelist),
            title: const Text('电池优化白名单'),
            subtitle: const Text('未加入则 Doze 更激进，后台更易被冻结'),
            trailing: TextButton(
              onPressed: () async {
                await NativeBridge.requestIgnoreBatteryOptimizations();
                await _load();
              },
              child: const Text('去加入'),
            ),
          ),
          ListTile(
            leading: _statusIcon(_notification),
            title: const Text('通知权限'),
            subtitle: const Text('前台服务常驻通知的前提'),
            trailing: const TextButton(
              onPressed: openAppSettings,
              child: Text('去开启'),
            ),
          ),
          ListTile(
            leading: _statusIcon(_engineRunning),
            title: const Text('调度引擎运行中'),
            subtitle: const Text('前台服务在跑 = 后台执行的基础'),
            trailing: TextButton(
              onPressed: () => setState(() =>
                  _engineRunning = BackgroundServiceManager.instance.isRunning),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
    );
  }
}
