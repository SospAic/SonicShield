import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/providers.dart';
import '../../services/background_service_manager.dart';
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

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final db = (await ref.read(databaseProvider.future)).db;
    final rows =
        await db.query('sound_profiles', where: 'enabled = 1', limit: 1);
    if (rows.isNotEmpty && mounted) {
      setState(() {
        _threshold = (rows.first['threshold_db'] as num?)?.toDouble() ?? -35;
        _minMs = (rows.first['min_duration_ms'] as num?)?.toInt() ?? 800;
        _cooldownSec = (rows.first['cooldown_sec'] as num?)?.toInt() ?? 120;
      });
    }
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
      await BackgroundServiceManager.instance.setGuard(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(engineStateProvider);
    final guardOn = BackgroundServiceManager.instance.guardActive;
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(title: const Text('声音守卫')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: SwitchListTile(
              secondary: Icon(guardOn ? Icons.mic : Icons.mic_off, size: 30),
              title: Text(guardOn ? '守卫运行中' : '守卫已停止'),
              subtitle: const Text('检测到超过阈值的声音事件后自动执行声音触发类任务'),
              value: guardOn,
              onChanged: (v) async {
                final scaffold = ScaffoldMessenger.of(context);
                if (v) {
                  final granted =
                      await Permission.microphone.request().isGranted;
                  if (!granted) {
                    scaffold
                        .showSnackBar(const SnackBar(content: Text('需要麦克风权限')));
                    return;
                  }
                  await _persist();
                  if (!mounted) return;
                  await requestAllPermissions(ref);
                  // 前台启动麦克风类型 FGS（Android 11+ while-in-use 通行证，
                  // 使守卫在后台合法使用麦克风；docs/05 §1.4）。
                  await NativeBridge.startMicService();
                } else {
                  await NativeBridge.stopMicService();
                }
                await BackgroundServiceManager.instance.setGuard(v);
                ref.invalidate(engineStateProvider);
                if (mounted) setState(() {});
              },
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

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}
