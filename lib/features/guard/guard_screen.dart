import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/providers.dart';
import '../../data/repositories/task_repository.dart';
import '../../domain/models/task.dart';
import '../../domain/models/trigger.dart';
import '../../services/background_service_manager.dart';
import 'guard_orchestration.dart';
import 'guard_toggle.dart';
import '../../services/native_bridge.dart';
import '../../services/permission_flow.dart';

/// 声音守卫页：灵敏度/冷却配置、开关守卫、实时电平表。
/// 说明：实时电平在引擎隔离内产生，v1 UI 以开关与状态展示为主；
/// 电平表通过引擎广播事件实现（见 docs/06 协议）。
///
/// [embedded] = true 时作为「自动化」分组页的子 TAB 使用，不再自带 AppBar。
class GuardScreen extends ConsumerStatefulWidget {
  const GuardScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<GuardScreen> createState() => _GuardScreenState();
}

class _GuardScreenState extends ConsumerState<GuardScreen> {
  double _threshold = -35;
  int _minMs = 800;
  int _cooldownSec = 120;
  Timer? _saveDebounce;

  /// 守卫编排（v1.10）：候选任务 / 挑选方式 / 延时。
  GuardOrchestration _orch = const GuardOrchestration();

  /// 可作为候选的「声音触发」任务（用于多选）。
  List<Task> _soundTasks = const [];

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final appDb = await ref.read(databaseProvider.future);
    final db = appDb.db;
    final rows =
        await db.query('sound_profiles', where: 'enabled = 1', limit: 1);
    final orch = GuardOrchestration.decode(await appDb.kvGet(guardOrchestrationKey));
    final tasks = await TaskRepository(appDb).listAll(enabledOnly: true);
    if (!mounted) return;
    setState(() {
      if (rows.isNotEmpty) {
        _threshold = (rows.first['threshold_db'] as num?)?.toDouble() ?? -35;
        _minMs = (rows.first['min_duration_ms'] as num?)?.toInt() ?? 800;
        _cooldownSec = (rows.first['cooldown_sec'] as num?)?.toInt() ?? 120;
      }
      _orch = orch;
      _soundTasks = [
        for (final t in tasks)
          if (t.triggerType == TriggerType.soundTriggered) t,
      ];
    });
  }

  Future<void> _persist() async {
    final db = (await ref.read(databaseProvider.future)).db;
    await db.insert(
      'sound_profiles',
      {
        'id': 'default',
        'name': '默认守卫',
        'threshold_db': _threshold,
        'min_duration_ms': _minMs,
        'cooldown_sec': _cooldownSec,
        'only_while_charging': 0,
        'enabled': 1,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // 守卫开着时热更新参数：重启守卫。
    final active = BackgroundServiceManager.instance.guardActive;
    if (active) {
      await BackgroundServiceManager.instance.setGuard(false);
      await BackgroundServiceManager.instance.setGuard(true, micGranted: true);
    }
  }

  /// 编排配置落 kv（**不动 schema**：见 `guard_orchestration.dart` 的说明）。
  Future<void> _persistOrchestration() async {
    final appDb = await ref.read(databaseProvider.future);
    await appDb.kvSet(guardOrchestrationKey, _orch.encode());
  }

  /// 守卫开关。
  ///
  /// ⚠️ BUG-061：此前三条失败路径（引擎没跑 / 麦克风权限被拒 / 引擎无响应）
  /// **全都静默表现为"开关弹回"**，用户既不知道失败也不知道该做什么。
  /// 现在统一经 `toggleGuard()` 归类，并把原因**明确告知**。
  Future<void> _onToggleGuard(bool v) async {
    final scaffold = ScaffoldMessenger.of(context);
    final mgr = BackgroundServiceManager.instance;
    // P2-16：捕获一站式权限申请的结果，以便在通知被拒时给出降级提示。
    PermissionRequestOutcome? perms;
    final outcome = await toggleGuard(
      wanted: v,
      engineRunning: mgr.isRunning,
      requestMic: () async => Permission.microphone.request().isGranted,
      persist: _persist,
      startMicService: () async {
        // 前台启动麦克风类型 FGS（Android 11+ while-in-use 通行证，
        // 使守卫在后台合法使用麦克风；docs/05 §1.4）。
        await NativeBridge.startMicService();
        perms = await requestAllPermissions(ref);
      },
      stopMicService: NativeBridge.stopMicService,
      setGuard: (enabled) => mgr.setGuard(enabled, micGranted: enabled),
      waitForGuardActive: mgr.waitForGuardActive,
      // 引擎自报的原因（如"麦克风启动失败：…"）—— 有它就别说"引擎无响应"。
      lastGuardError: () => mgr.guardError,
    );
    if (!mounted) return;
    ref.invalidate(engineStateProvider);
    setState(() {});
    if (!outcome.ok) {
      scaffold.showSnackBar(SnackBar(content: Text(outcome.text)));
    } else if (perms?.notificationDenied ?? false) {
      // P2-16：守卫已开启，但通知被拒 ⇒ 后台提醒/告警通知不会出现，明确告知。
      scaffold.showSnackBar(const SnackBar(
          content: Text('通知权限未授予：后台提醒与告警通知将不会出现。'
              '可在「系统设置 → 应用 → 声盾 → 通知」中重新开启')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(engineStateProvider);
    final guardOn = BackgroundServiceManager.instance.guardActive;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('声音守卫')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: SwitchListTile(
              secondary: Icon(guardOn ? Icons.mic : Icons.mic_off, size: 30),
              title: Text(guardOn ? '守卫运行中' : '守卫已停止'),
              subtitle: const Text('检测到超过阈值的声音事件后自动执行声音触发类任务'),
              value: guardOn,
              onChanged: _onToggleGuard,
            ),
          ),
          const SizedBox(height: 16),
          Text('触发灵敏度', style: Theme.of(context).textTheme.titleMedium),
          Text('阈值 ${_threshold.round()} dBFS（越大越不敏感）',
              style: Theme.of(context).textTheme.bodySmall),
          Slider(
            value: _threshold,
            min: -70,
            max: -10,
            divisions: 60,
            label: '${_threshold.round()} dB',
            onChanged: (v) => setState(() => _threshold = v),
            onChangeEnd: (_) {
              _saveDebounce?.cancel();
              _saveDebounce =
                  Timer(const Duration(milliseconds: 600), _persist);
            },
          ),
          ListTile(
            title: Text('最小持续时间：${_minMs}ms'),
          ),
          Slider(
            value: _minMs.toDouble(),
            min: 200,
            max: 3000,
            divisions: 14,
            label: '${_minMs}ms',
            onChanged: (v) => setState(() => _minMs = v.round()),
            onChangeEnd: (_) {
              _saveDebounce?.cancel();
              _saveDebounce =
                  Timer(const Duration(milliseconds: 600), _persist);
            },
          ),
          Text('触发冷却：${_cooldownSec}s（防连环执行）',
              style: Theme.of(context).textTheme.bodySmall),
          Slider(
            value: _cooldownSec.toDouble(),
            min: 30,
            max: 1800,
            divisions: 59,
            label: '${_cooldownSec}s',
            onChanged: (v) => setState(() => _cooldownSec = v.round()),
            onChangeEnd: (_) {
              _saveDebounce?.cancel();
              _saveDebounce =
                  Timer(const Duration(milliseconds: 600), _persist);
            },
          ),
          const Divider(height: 32),
          _buildOrchestration(context),
          const SizedBox(height: 12),
          engine.when(
            data: (s) => Card(
              child: ListTile(
                leading: Icon(
                    s.guardActive ? Icons.graphic_eq : Icons.pause_circle,
                    color: s.guardActive
                        ? Theme.of(context).colorScheme.primary
                        : null),
                title: Text(s.guardActive ? '正在监听声音事件' : '监听未激活'),
                // 失败原因直接显示在状态卡里：用户不必去日志页翻。
                subtitle: (s.guardError != null && s.guardError!.isNotEmpty)
                    ? Text(s.guardError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))
                    : null,
              ),
            ),
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text('状态获取失败：$e'),
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '隐私说明：音频数据仅在设备内存中计算能量电平，不存储、不上传；'
                '触发「录音取证」动作时才会写入本机私有目录。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 编排区（v1.10）。
  ///
  /// 这里**只配置"用哪几个任务 / 挑几个 / 等多久"** —— 音频与动作的多选、
  /// 随机、概率都在任务自己的动作层里（`assetIds` / `ActionSetAction` /
  /// `probabilityPct`），不在此重复实现（见 `guard_orchestration.dart` 的对照表）。
  Widget _buildOrchestration(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('触发后动作编排', style: theme.textTheme.titleMedium),
        Text(
          '音频与动作的多选/随机在任务里配置（任务的「随机指令集」与音源多选）；'
          '此处决定用哪几个声音触发任务、挑几个、等多久。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text('延时执行：${_orch.delaySec}s'
            '${_orch.delaySec == 0 ? '（立即）' : ''}'),
        Slider(
          value: _orch.delaySec.toDouble(),
          min: 0,
          max: GuardOrchestration.maxDelaySec.toDouble(),
          divisions: GuardOrchestration.maxDelaySec ~/ 5,
          label: '${_orch.delaySec}s',
          onChanged: (v) =>
              setState(() => _orch = _copyOrch(delaySec: v.round())),
          onChangeEnd: (_) => _persistOrchestration(),
        ),
        const SizedBox(height: 4),
        SegmentedButton<GuardPickMode>(
          segments: const [
            ButtonSegment(
                value: GuardPickMode.all,
                label: Text('全部执行'),
                icon: Icon(Icons.playlist_play)),
            ButtonSegment(
                value: GuardPickMode.randomOne,
                label: Text('随机一个'),
                icon: Icon(Icons.shuffle)),
          ],
          selected: {_orch.pick},
          onSelectionChanged: (s) {
            setState(() => _orch = _copyOrch(pick: s.first));
            _persistOrchestration();
          },
        ),
        const SizedBox(height: 8),
        Text('候选任务（不选 = 全部声音触发任务）', style: theme.textTheme.bodySmall),
        if (_soundTasks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('还没有「声音触发」类型的任务：请先在「自动化 · 任务」里新建。',
                style: TextStyle(fontSize: 12)),
          )
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final t in _soundTasks)
                  CheckboxListTile(
                    dense: true,
                    value: _orch.taskIds.contains(t.id),
                    title: Text(t.name),
                    onChanged: (v) {
                      final next = [..._orch.taskIds];
                      if (v == true) {
                        if (!next.contains(t.id)) next.add(t.id);
                      } else {
                        next.remove(t.id);
                      }
                      setState(() => _orch = _copyOrch(taskIds: next));
                      _persistOrchestration();
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }

  GuardOrchestration _copyOrch({
    List<String>? taskIds,
    GuardPickMode? pick,
    int? delaySec,
  }) =>
      GuardOrchestration(
        taskIds: taskIds ?? _orch.taskIds,
        pick: pick ?? _orch.pick,
        delaySec: delaySec ?? _orch.delaySec,
      );

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}
