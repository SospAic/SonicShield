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
import '../domain/models/condition.dart';
import '../domain/models/task.dart';
import '../domain/models/trigger.dart';
import '../domain/scheduling/schedule_engine.dart';
import 'condition_env.dart';
import 'notification_service.dart';
import 'native_bridge.dart';
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

  /// 读取一次平台环境（电量 / 充电 / 通话 / 网络），供一轮内**复用**。
  ///
  /// v1.7 扩展：新增通话状态与网络类型两个输入。
  /// 读不到时留 `null` 并按"满足"处理（与电池条件的既有约定一致，
  /// 避免某个平台读不到状态就把全部自动化静默停掉）；
  /// Android 侧始终可判定，故实际防护不受影响。
  ///
  /// 这 4 次读取都是**平台通道往返**（设备上 ≈1.5–2ms/次）。
  /// 改造前是**逐任务**读（一轮 N 个到期任务 = 4N 次往返），
  /// 现在改为每轮读一次（固定 4 次，与 N 解耦）——
  /// 同一轮内所有任务面对的是同一个物理环境。
  Future<ConditionEnv> readConditionEnv() async {
    var level = 100;
    var charging = false;
    try {
      level = await battery.batteryLevel;
      final st = await battery.batteryState;
      charging = st == BatteryState.charging || st == BatteryState.full;
    } on Object {
      // 无电池平台视为满足电量条件
    }
    bool? inCall;
    bool? onWifi;
    try {
      inCall = await NativeBridge.isInCall();
      onWifi = await NativeBridge.isOnWifi();
    } on Object {
      // 桥不可用（如 iOS）→ 保持 null，按"满足"处理
    }
    return ConditionEnv(
      charging: charging,
      batteryLevel: level,
      inCall: inCall,
      onWifi: onWifi,
    );
  }

  /// 任务条件层评估：不满足 → 返回**具体原因**（写审计），满足 → null。
  ///
  /// 消费**已读好的**环境快照（[ConditionEnv]），因此本函数不再触碰平台通道；
  /// `now` 实时取值 —— 本地时钟无平台开销，且时段窗口按真实时刻判定更准。
  String? conditionFailedIn(Task task, ConditionEnv env) {
    // 未配置条件的老任务用**默认条件**兜底，而不是直接放行：
    // `TaskCondition()` 的 skipInCall 默认为 true，因此"通话中不执行"这条
    // 安全护栏对**所有**任务生效（含历史任务），不存在"没配过条件就漏掉"的洞。
    // 使用者在编辑器里显式关掉该开关时，会落库一个 skipInCall=false 的条件对象，
    // 从而正确覆盖默认值。
    final c = task.condition ?? const TaskCondition();
    if (!c.hasAny) return null;
    // 返回**首个未满足条件**而不是整份条件描述：排障时要的是"为什么没执行"。
    return c.firstUnmetIn(env, now: DateTime.now());
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
    // 本轮环境快照：**首次需要时**读一次，轮内所有到期任务复用。
    // 惰性 → 若所有计划都在下面的"过期丢弃"分支被跳过，则一次平台读取都不会发生。
    final env = RoundConditionEnv(read: readConditionEnv);
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
      final condFail = conditionFailedIn(task, await env.value);
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
    // 本轮环境快照：本次声音事件会遍历**所有**声音触发任务，
    // 同样只读一次平台状态（与 executeDue 同理）。
    final env = RoundConditionEnv(read: readConditionEnv);
    for (final t
        in all.where((t) => t.triggerType == TriggerType.soundTriggered)) {
      final cfg = t.trigger as SoundTrigger;
      final last = await occs.lastDoneFor(t.id);
      final cooldown =
          Duration(seconds: math.max(cfg.cooldownSec, t.cooldownSec));
      if (last != null && at.difference(last) < cooldown) continue;
      // 条件层（v1.3）：声音触发同样受前置条件约束。
      final condFail = conditionFailedIn(t, await env.value);
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

  /// 远程「立即执行」（协议 v1.7，docs/14 §2.1）。
  ///
  /// 端点服务运行在**主 isolate**，无法直接调用本引擎的 `runAction`
  /// （播放器/TTS/原生桥的插件实例都注册在引擎隔离内）。因此远程
  /// `task.runNow` 走本通道转交执行，并把结果以 `rcRunResult` 回投，
  /// 端点据此回 `rc.ack`——避免"回执成功但实际没出声"的假阳性。
  service.on('runNow').listen((m) async {
    final taskId = m?['taskId'] as String?;
    final reqId = m?['reqId'] as String? ?? '';
    if (taskId == null || taskId.isEmpty) return;
    var ok = false;
    var message = '';
    try {
      final task = await tasksRepo.get(taskId);
      if (task == null) {
        message = '任务不存在';
      } else {
        // 单任务路径：只评估一个任务，读一次即可（无需 RoundConditionEnv）。
        final condFail = conditionFailedIn(task, await readConditionEnv());
        if (condFail != null) {
          message = '条件不满足：$condFail';
          await logs.append(
              source: 'remote',
              action: 'runNow',
              status: 'skipped',
              taskId: task.id,
              message: condFail);
        } else {
          // 物化期的音量/时长由调度器确定；远程立即执行取动作区间中点，
          // 保持"计划即审计"语义（volume/duration 落库到 occurrence）。
          final (vol, dur) = _nominalParams(task);
          ok = await runAction(task, vol, dur, 'remote');
          message = ok ? '已执行' : '执行失败';
          await occs.commitAll([
            PlannedOccurrence(
              id: '${task.id}@remote@${DateTime.now().millisecondsSinceEpoch}',
              taskId: task.id,
              fireAt: DateTime.now(),
              status: ok ? OccurrenceStatus.done : OccurrenceStatus.failed,
              volume: vol,
              durationMs: dur,
            ),
          ]);
          lastAction = '${task.name} · 远程立即执行';
        }
      }
    } on Object catch (e) {
      message = e.toString();
    }
    service.invoke('rcRunResult', {
      'reqId': reqId,
      'taskId': taskId,
      'ok': ok,
      'message': message,
    });
    await broadcast();
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

/// 远程「立即执行」的标称执行参数（音量/时长）。
///
/// 计划触发时这两个值由 [ScheduleEngine] 在物化期用 DPRNG 确定并落库；
/// 而立即执行没有计划条目，取动作区间中值作为标称值，并同样落库，
/// 保持"计划即审计"的一致性。合规上限同样生效。
(double, int) _nominalParams(Task task) {
  final play = switch (task.action) {
    final PlayAudioAction p => p,
    final CompositeAction c => switch (c.primary) {
        final PlayAudioAction p => p,
        _ => null,
      },
    _ => null,
  };
  if (play == null) return (0.8, 0);
  const cap = ComplianceGuardrails.maxMediaVolumePercent / 100;
  final hi = math.min(play.volumeMax, cap);
  final vol = ((play.volumeMin + hi) / 2).clamp(0.0, 1.0).toDouble();
  final dur =
      (((play.durationSecMin + play.durationSecMax) / 2) * 1000).round();
  return (vol, dur);
}
