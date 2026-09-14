import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show DartPluginRegistrant;

import 'package:battery_plus/battery_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../data/db/app_database.dart';
import '../data/repositories/log_repository.dart';
import '../data/repositories/occurrence_repository.dart';
import '../data/repositories/task_repository.dart';
import '../domain/models/action.dart';
import '../domain/models/task.dart';
import '../domain/models/trigger.dart';
import '../domain/scheduling/schedule_engine.dart';
import 'notification_service.dart';
import 'playback_service.dart';
import 'sound_guard_service.dart';

/// 后台引擎状态快照（服务 -> UI 广播）。
class EngineState {
  const EngineState({
    required this.running,
    required this.pendingCount,
    this.nextFireAt,
    this.lastAction,
    this.guardActive = false,
  });

  final bool running;
  final int pendingCount;
  final DateTime? nextFireAt;
  final String? lastAction;
  final bool guardActive;

  Map<String, Object?> toMap() => {
        'running': running,
        'pendingCount': pendingCount,
        'nextFireAt': nextFireAt?.millisecondsSinceEpoch,
        'lastAction': lastAction,
        'guardActive': guardActive,
      };
}

/// 后台调度引擎：运行于 flutter_background_service 的前台服务隔离。
///
/// 双通道触发（详见 docs/05）：
/// - 通道A（应用存活）：Dart Timer 周期 tick，亚秒级精度；
/// - 通道B（Doze/进程被杀）：原生 AlarmManager 精确闹钟唤醒前台服务，
///   服务启动即 executeDue() 补执行。
/// 两通道汇合到同一状态机（occurrences 表），天然幂等。
///
/// runZonedGuarded：引擎隔离内任何未捕获异步异常（如插件注册告警、
/// 单次 DB 抖动）只记录不致命——此前 isolate 会静默死亡，导致
/// Timer 通道A 停摆（BUG-011 根因，docs/12 §5）。
@pragma('vm:entry-point')
Future<void> engineEntryPoint(ServiceInstance service) async {
  await runZonedGuarded(() => _engineBody(service), (e, stack) {
    // 引擎自愈日志：异常不终止 isolate，下一轮 tick 自动恢复。
    // ignore: avoid_print
    print('[sonic_shield][engine] unhandled: $e');
  });
}

Future<void> _engineBody(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final db = await AppDatabase.open();
  final tasksRepo = TaskRepository(db);
  final occs = OccurrenceRepository(db);
  final logs = LogRepository(db);
  const engine = ScheduleEngine();
  final playback = PlaybackService();
  final guard = SoundGuardService();
  const native = MethodChannel(Channels.method);
  final battery = Battery();
  final prefs = await SharedPreferences.getInstance();

  var guardEnabled = prefs.getBool('guard_enabled') ?? false;
  StreamSubscription<SoundEvent>? guardSub;
  String? lastAction;

  /// 任务条件层评估（v1.3）：不满足 → 返回原因（写审计），满足 → null。
  Future<String?> conditionFailed(Task task) async {
    final c = task.condition;
    if (c == null || !c.hasAny) return null;
    var level = 100;
    var charging = false;
    try {
      level = await battery.batteryLevel;
      final st = await battery.batteryState;
      charging = st == BatteryState.charging || st == BatteryState.full;
    } on Object {
      // 无电池平台视为满足电量条件
    }
    final ok = c.evaluate(
        charging: charging, batteryLevel: level, now: DateTime.now());
    if (ok) return null;
    return c.describe();
  }

  // ==================== 依赖底座（先声明后引用） ====================

  Future<String?> assetPathById(String id) async {
    final rows = await db.db
        .query('audio_assets', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first['path'] as String;
  }

  /// 按预置分类随机取一条（导入预置库时标签为 预置/<分类>）。
  Future<String?> presetPathByCategory(String category) async {
    final rows = await db.db.query('audio_assets',
        where: 'tags LIKE ? AND tags LIKE ?',
        whereArgs: ['%预置%', '%$category%'],
        orderBy: 'RANDOM()',
        limit: 1);
    return rows.isEmpty ? null : rows.first['path'] as String;
  }

  /// 任意一条音源路径（按最近导入优先）。
  Future<String?> pickAnyAssetPath() async {
    final rows =
        await db.db.query('audio_assets', orderBy: 'created_at DESC', limit: 1);
    return rows.isEmpty ? null : rows.first['path'] as String;
  }

  /// 声景混音：逐轨解析路径（assetId 优先，其次预置分类随机），多轨叠加。
  Future<void> soundscapeAndLog(
      Task task, SoundscapeAction sc, String source) async {
    final tracks = <SoundscapeTrackInput>[];
    for (final t in sc.tracks) {
      var path = t.assetId != null ? await assetPathById(t.assetId!) : null;
      path ??= t.presetCategory != null
          ? await presetPathByCategory(t.presetCategory!)
          : null;
      path ??= await pickAnyAssetPath();
      if (path != null) {
        tracks.add(
            SoundscapeTrackInput(path: path, volume: t.volume, loop: t.loop));
      }
    }
    if (tracks.isEmpty) {
      await logs.append(
          source: source,
          action: 'soundscape',
          status: 'failed',
          taskId: task.id,
          message: '无可解析的音轨');
      return;
    }
    final r = await playback.playSoundscape(
      tracks: tracks,
      durationMs: sc.durationSec * 1000,
      channel: AudioChannel.media,
      fadeOutMs: sc.fadeOutSec * 1000,
    );
    await logs.append(
        source: source,
        action: 'soundscape',
        status: r.ok ? 'success' : 'failed',
        taskId: task.id,
        durationMs: r.playedMs,
        message: '${tracks.length} 轨 · ${r.message ?? ''}');
  }

  Future<String?> pickAssetFor(Task task) async {
    if (task.assetIds.isEmpty) return null;
    final rows = await db.db.query('audio_assets',
        where: 'id IN (${List.filled(task.assetIds.length, '?').join(',')})',
        whereArgs: task.assetIds);
    if (rows.isEmpty) return null;
    final paths = rows.map((r) => r['path'] as String).toList();
    final rng =
        math.Random(task.id.hashCode ^ DateTime.now().millisecondsSinceEpoch);
    return paths[rng.nextInt(paths.length)];
  }

  Future<void> playAndLog(Task task, PlayAudioAction p, double volume,
      int durationMs, String source) async {
    final path = await pickAssetFor(task);
    if (path == null) {
      await logs.append(
          source: source,
          action: 'play',
          status: 'failed',
          taskId: task.id,
          message: '无可用音源');
      return;
    }
    final r = await playback.play(
      path: path,
      channel: p.channel,
      volume: volume,
      maxDurationMs: durationMs > 0 ? durationMs : p.durationSecMin * 1000,
      fadeInMs: p.fadeInSec * 1000,
      fadeOutMs: p.fadeOutSec * 1000,
      rampUpMs: p.rampUpSec * 1000,
      loopFill: p.loopFill,
    );
    await logs.append(
        source: source,
        action: 'play',
        status: r.ok ? 'success' : 'failed',
        taskId: task.id,
        volume: volume,
        durationMs: r.playedMs,
        message: r.message);
  }

  Future<void> ttsAndLog(Task task, TtsAction t, String source) async {
    final tts = FlutterTts();
    try {
      // 整体超时保护：无 TTS 引擎的平台（如 AOSP 镜像）speak/setLanguage
      // 可能永远不回调，此前会导致审计日志永远写不进去（BUG-011 关联）。
      await tts.setVolume(t.volume).timeout(const Duration(seconds: 8));
      await tts.setLanguage('zh-CN').timeout(const Duration(seconds: 8));
      await tts.speak(t.text).timeout(const Duration(seconds: 15));
      await logs.append(
          source: source,
          action: 'tts',
          status: 'success',
          taskId: task.id,
          volume: t.volume);
    } catch (e) {
      await logs.append(
          source: source,
          action: 'tts',
          status: 'failed',
          taskId: task.id,
          message: e.toString());
    } finally {
      try {
        await tts.stop().timeout(const Duration(seconds: 3));
      } on Object {
        // 清理失败不影响审计
      }
    }
  }

  Future<void> recordAndLog(Task task, int seconds, String source) async {
    final rec = AudioRecorder();
    try {
      if (!await rec.hasPermission()) {
        await logs.append(
            source: source,
            action: 'record',
            status: 'failed',
            taskId: task.id,
            message: '无麦克风权限');
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      final path =
          '${dir.path}/evidence_${DateTime.now().millisecondsSinceEpoch}.evidence.m4a';
      await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path);
      await Future<void>.delayed(Duration(seconds: seconds));
      await rec.stop();
      // 取证哈希链（v1.3）：文件 SHA-256 入审计，供导出时校验完整性。
      var sha256Hex = '';
      try {
        final bytes = await File(path).readAsBytes();
        sha256Hex = sha256.convert(bytes).toString();
      } on Object {
        // 文件不可读时保留空哈希（审计仍记录路径与时间）
      }
      await logs.append(
          source: source,
          action: 'record',
          status: 'success',
          taskId: task.id,
          durationMs: seconds * 1000,
          message: 'sha256=$sha256Hex path=$path');
      await NotificationService.instance
          .showEvent(title: '声盾 · 取证完成', body: '已保存到应用私有目录（含完整性哈希）');
    } catch (e) {
      await logs.append(
          source: source,
          action: 'record',
          status: 'failed',
          taskId: task.id,
          message: e.toString());
    }
  }

  /// 动作执行统一串行 await：保证 occurrence 状态与审计日志严格一致
  /// （此前 fire-and-forget 在 TTS 挂起时导致日志永远缺失——BUG-011 关联）。
  Future<bool> runSingle(Task task, ActionConfig cfg, double volume,
      int durationMs, String source) async {
    switch (cfg) {
      case final PlayAudioAction p:
        await playAndLog(task, p, volume, durationMs, source);
        return true;
      case final SoundscapeAction sc:
        await soundscapeAndLog(task, sc, source);
        return true;
      case final TtsAction t:
        await ttsAndLog(task, t, source);
        return true;
      case final NotifyAction n:
        await NotificationService.instance
            .showEvent(title: n.title, body: n.body);
        await logs.append(
            source: source,
            action: 'notify',
            status: 'success',
            taskId: task.id);
        return true;
      case final VibrateAction v:
        try {
          await native.invokeMethod('vibrate', {'pattern': v.patternMs});
          await logs.append(
              source: source,
              action: 'vibrate',
              status: 'success',
              taskId: task.id);
        } on Object {
          // 无震动能力平台静默
        }
        return true;
      case final RecordEvidenceAction rec:
        await recordAndLog(task, rec.seconds, source);
        return true;
      case final CompositeAction c:
        return runSingle(task, c.primary, volume, durationMs, source);
    }
  }

  /// 动作执行器（顶层分派，全部写审计日志）。
  Future<bool> runAction(
      Task task, double volume, int durationMs, String source) async {
    lastAction = '${task.name} · ${task.actionType.label}';
    try {
      final cfg = task.action;
      if (cfg is CompositeAction) {
        final pre = cfg.prefixNotify;
        if (pre != null) {
          await NotificationService.instance
              .showEvent(title: pre.title, body: pre.body);
        }
        return await runSingle(task, cfg.primary, volume, durationMs, source);
      }
      return await runSingle(task, cfg, volume, durationMs, source);
    } catch (e) {
      await logs.append(
          source: source,
          action: task.actionType.name,
          status: 'failed',
          taskId: task.id,
          message: e.toString());
      return false;
    }
  }

  Future<void> broadcast() async {
    final now = DateTime.now();
    final pending = await occs.pendingCountAfter(now);
    final next = await occs.pendingWithin(now, now.add(const Duration(days: 7)),
        limit: 1);
    service.invoke(
        'state',
        EngineState(
          running: true,
          pendingCount: pending,
          nextFireAt: next.isEmpty ? null : next.first.fireAt,
          lastAction: lastAction,
          guardActive: guard.isRunning,
        ).toMap());
  }

  Future<void> pushExactAlarms(List<int> times) async {
    try {
      await native.invokeMethod('setExactAlarms', {'times': times});
    } on Object {
      // 桌面/测试降级：仅通道A生效
    }
  }

  Future<void> clearAllAlarms() async {
    try {
      await native.invokeMethod('clearAlarms');
    } on Object {
      // 同上
    }
  }

  /// 计划续算：物化未来 horizon，幂等提交，并排布原生精确闹钟（通道B）。
  Future<void> replan() async {
    final now = DateTime.now();
    final all = await tasksRepo.listAll(enabledOnly: true);
    final newEntries = <PlannedEntry>[];
    for (final t in all) {
      if (t.triggerType == TriggerType.soundTriggered) continue;
      newEntries.addAll(engine.materialize(t, now));
    }
    if (newEntries.isEmpty) {
      await clearAllAlarms();
      await broadcast();
      return;
    }
    await occs.commitAll([
      for (final e in newEntries)
        PlannedOccurrence(
          id: e.occurrenceId,
          taskId: e.taskId,
          fireAt: e.fireAt,
          status: OccurrenceStatus.pending,
          volume: e.volume,
          durationMs: e.durationMs,
        ),
    ]);
    final alarmTimes = newEntries
        .take(SchedulerConfig.maxNativeAlarmsPerTask)
        .map((e) => e.fireAt.millisecondsSinceEpoch)
        .toList();
    await pushExactAlarms(alarmTimes);
    lastAction = 'replan(${newEntries.length} 条计划)';
    await broadcast();
  }

  /// 执行所有到期计划（幂等；带补执行上限与陈旧丢弃）。
  Future<void> executeDue() async {
    final now = DateTime.now();
    final due = await occs.due(now, limit: SchedulerConfig.catchUpLimit);
    for (final o in due) {
      if (now.difference(o.fireAt) > const Duration(minutes: 10)) {
        await occs.markStatus(o.id, OccurrenceStatus.skipped);
        await logs.append(
            source: 'schedule',
            action: 'skip-stale',
            status: 'skipped',
            taskId: o.taskId,
            occurrenceId: o.id);
        continue;
      }
      final task = await tasksRepo.get(o.taskId);
      if (task == null || !task.enabled) {
        await occs.markStatus(o.id, OccurrenceStatus.skipped);
        continue;
      }
      // 条件层（v1.3）：不满足则跳过并审计。
      final condFail = await conditionFailed(task);
      if (condFail != null) {
        await occs.markStatus(o.id, OccurrenceStatus.skipped);
        await logs.append(
            source: 'schedule',
            action: 'condition',
            status: 'skipped',
            taskId: task.id,
            occurrenceId: o.id,
            message: condFail);
        continue;
      }
      final ok =
          await runAction(task, o.volume ?? 0.8, o.durationMs ?? 0, 'schedule');
      await occs.markStatus(
          o.id, ok ? OccurrenceStatus.done : OccurrenceStatus.failed);
    }
    if (due.isNotEmpty) await broadcast();
  }

  /// 声音事件 -> 执行所有启用的声音触发任务。
  Future<void> onSoundEvent(DateTime at, double peakDb) async {
    final all = await tasksRepo.listAll(enabledOnly: true);
    for (final t
        in all.where((t) => t.triggerType == TriggerType.soundTriggered)) {
      final cfg = t.trigger as SoundTrigger;
      final last = await occs.lastDoneFor(t.id);
      final cooldown =
          Duration(seconds: math.max(cfg.cooldownSec, t.cooldownSec));
      if (last != null && at.difference(last) < cooldown) continue;
      // 条件层（v1.3）：声音触发同样受前置条件约束。
      final condFail = await conditionFailed(t);
      if (condFail != null) {
        await logs.append(
            source: 'sound',
            action: 'condition',
            status: 'skipped',
            taskId: t.id,
            message: condFail);
        continue;
      }
      await runAction(t, 0.8, 0, 'sound');
      await occs.commitAll([
        PlannedOccurrence(
          id: '${t.id}@sound@${at.millisecondsSinceEpoch}',
          taskId: t.id,
          fireAt: at,
          status: OccurrenceStatus.done,
        ),
      ]);
    }
    await broadcast();
  }

  // ==================== UI -> 服务 消息 ====================

  service.on('replan').listen((_) => unawaited(replan()));
  service.on('tick').listen((_) => unawaited(executeDue()));
  service.on('guard').listen((m) async {
    guardEnabled = (m?['enabled'] as bool?) ?? false;
    await prefs.setBool('guard_enabled', guardEnabled);
    if (guardEnabled) {
      final profiles =
          await db.db.query('sound_profiles', where: 'enabled = 1', limit: 1);
      final cfg = profiles.isEmpty
          ? const SoundTrigger()
          : SoundTrigger(
              thresholdDb:
                  (profiles.first['threshold_db'] as num?)?.toDouble() ?? -35,
              minDurationMs:
                  (profiles.first['min_duration_ms'] as num?)?.toInt() ?? 800,
              cooldownSec:
                  (profiles.first['cooldown_sec'] as num?)?.toInt() ?? 120,
              onlyWhileCharging:
                  ((profiles.first['only_while_charging'] as int?) ?? 0) == 1,
            );
      final started = await guard.start(cfg);
      if (started) {
        await guardSub?.cancel();
        guardSub = guard.events
            .listen((e) => unawaited(onSoundEvent(e.detectedAt, e.peakDb)));
      }
      await logs.append(
          source: 'guard',
          action: 'start',
          status: started ? 'success' : 'failed',
          message: started ? null : '麦克风权限被拒');
    } else {
      await guardSub?.cancel();
      await guard.stop();
    }
    await broadcast();
  });
  service.on('stop').listen((_) async {
    await guardSub?.cancel();
    await guard.stop();
    await playback.stop();
    await service.stopSelf();
  });

  // ==================== 通道A：引擎主循环 ====================

  Timer.periodic(SchedulerConfig.engineTick, (_) {
    unawaited(executeDue());
    unawaited(() async {
      final pending = await occs.pendingCountAfter(DateTime.now());
      if (pending < SchedulerConfig.planExtendThreshold.inHours) {
        await replan();
      }
    }());
  });

  // 启动即补执行 + 续算（通道B 唤醒后同样走这里）。
  await executeDue();
  await replan();
  if (guardEnabled) {
    service.invoke('guard', {'enabled': true}); // 守卫自恢复
  }
  await broadcast();
}
