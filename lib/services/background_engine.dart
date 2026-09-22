import 'dart:async';
import 'dart:convert';
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
import '../domain/scheduling/vibrate_resolve.dart';
import 'condition_env.dart';
import 'notification_service.dart';
import 'native_bridge.dart';
import 'playback_service.dart';
import 'sound_guard_service.dart';
import 'vibrate_session.dart';

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

/// 一条声景轨道要播哪条音源（**纯决策，便于断言**）。
///
/// 顺序：`assetId`（点名具体音源）→ `presetCategory`（点名分类，分类内随机）
/// → **就此为止，不再兜底**。
///
/// ⚠️ **BUG-059**：修之前这里还有第三级 `pickAnyAssetPath()`（"库里任意一条"）。
/// 但 [SoundscapeTrack] 断言 `assetId` / `presetCategory` **必居其一**，
/// 所以那一级**只可能在"点名了却没找到"时触发** —— 效果是：
/// 用户挑的某条音源被删了，任务却**静默改播一条完全不相干的声音**。
/// 这正是 BUG-048 判据「**点名了就必须满足，满足不了要失败，绝不 `??=`**」的形状。
///
/// 为什么不保留兜底：声景的每一轨都是用户**显式挑的**，缺一轨的正确后果是
/// "这轨不响 + 审计留痕"，而不是"拿别的声音凑数"（用户听不出来，也没法发现配置坏了）。
///
/// 抽成纯函数而不是留在调用处：`lib/services/background_engine.dart` 依赖真实
/// DB / 播放器 / 日志，宿主机上实例化不了；**签名里根本没有"任意一条"这个入参**
/// → 想退回兜底就必须先改签名，"不兜底"因此是**结构性**的，比源码锁更强。
String? soundscapeTrackPath({
  required String? byId,
  required String? byCategory,
}) =>
    byId ?? byCategory;

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
  final playback = PlaybackService();
  final guard = SoundGuardService();
  const native = MethodChannel(Channels.method);
  final battery = Battery();
  final prefs = await SharedPreferences.getInstance();

  // 振动会话（v1.9，docs/20 §7）：分片续发 + S1–S4 失效安全。
  final vibrate = VibrateSession.standard(
    logs,
    battery: () async {
      try {
        final level = await battery.batteryLevel;
        final st = await battery.batteryState;
        return (
          level: level,
          charging: st == BatteryState.charging || st == BatteryState.full,
        );
      } on Object {
        // 无电池平台：视为"电量充足且充电中"。**不因读不到而停掉振动** ——
        // 与条件层"无法判定按满足处理"同一约定（BUG-041 的教训）。
        return (level: 100, charging: true);
      }
    },
    kvGet: db.kvGet,
    kvSet: db.kvSet,
  );
  // S2（docs/20 §7.2）：每次服务启动**一律停止**残留振动，绝不续发。
  // 宁可少震一次，也不可失控 —— 与补执行限流 catchUpLimit 同一哲学。
  await vibrate.recoverAfterRestart();

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

  /// **概率门**（v1.8）：确定性条件通过后，按任务配置的百分比随机决定执行与否。
  ///
  /// 与条件层分离的原因：条件判定是纯函数（可测、幂等），随机门是**每次调用
  /// 必然不同**的输入（同 [now] 不进快照的先例）。审计可回溯："概率 30% 未命中"。
  /// 返回 null = 通过（或未配置）；返回文案 = 未命中原因（写审计）。
  String? probabilityGateMissed(Task task, {math.Random? rng}) {
    final c = task.condition;
    final pct = c?.probabilityPct;
    if (pct == null || pct >= 100) return null;
    final roll = (rng ?? math.Random()).nextInt(100);
    if (roll < pct) return null;
    return '概率 $pct% 未命中（掷出 $roll）';
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

  /// 声景混音：逐轨解析路径（assetId 优先，其次预置分类随机），多轨叠加。
  ///
  /// ⚠️ 解析不到的轨道**直接跳过**，绝不拿别的音源顶上（见 [soundscapeTrackPath]）。
  Future<void> soundscapeAndLog(
      Task task, SoundscapeAction sc, String source) async {
    final tracks = <SoundscapeTrackInput>[];
    var unresolved = 0;
    for (final t in sc.tracks) {
      final path = soundscapeTrackPath(
        byId: t.assetId != null ? await assetPathById(t.assetId!) : null,
        byCategory: t.presetCategory != null
            ? await presetPathByCategory(t.presetCategory!)
            : null,
      );
      if (path == null) {
        unresolved++;
        continue;
      }
      tracks.add(
          SoundscapeTrackInput(path: path, volume: t.volume, loop: t.loop));
    }
    if (tracks.isEmpty) {
      await logs.append(
          source: source,
          action: 'soundscape',
          status: 'failed',
          taskId: task.id,
          message: sc.tracks.isEmpty
              ? '无可解析的音轨'
              : '${sc.tracks.length} 轨全部无法解析'
                  '（点名的音源已不存在），已跳过而非改播其它音源');
      return;
    }
    // 部分轨解析不到也要留痕：否则用户听的是"少了轨的声景"却以为配置没生效。
    if (unresolved > 0) {
      await logs.append(
          source: source,
          action: 'soundscape',
          status: 'failed',
          taskId: task.id,
          message: '$unresolved/${sc.tracks.length} 轨无法解析（点名的音源已不存在）'
              '，已跳过这些轨');
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
      int durationMs, String source, {String? occurrenceId}) async {
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
        // FR-34 口径修正（v1.9，docs/20 §2.3）：无振动能力时**不再静默**。
        // 旧实现 `on Object { /* 静默 */ }` 会让"到点了但没震"完全无迹可寻，
        // 与本项目通则（承诺了就必须做到，做不到必须留痕）冲突。
        final caps = await vibrate.capabilities();
        if (!caps.hasVibrator) {
          await logs.append(
              source: source,
              action: 'vibrate',
              status: 'skipped',
              taskId: task.id,
              occurrenceId: occurrenceId,
              message: '无振动能力：${vibrateDegradations(caps, v).join('；')}');
          return true;
        }
        try {
          await native.invokeMethod('vibrate', {'pattern': v.patternMs});
          await logs.append(
              source: source,
              action: 'vibrate',
              status: 'success',
              taskId: task.id,
              occurrenceId: occurrenceId);
        } on Object {
          await logs.append(
              source: source,
              action: 'vibrate',
              status: 'failed',
              taskId: task.id,
              occurrenceId: occurrenceId,
              message: '原生调用失败（桥不可用或被拒绝）');
        }
        return true;
      case final RecordEvidenceAction rec:
        await recordAndLog(task, rec.seconds, source);
        return true;
      // ---- v1.9 振动（docs/20 §4/§7）----
      // 两类都交给 VibrateSession：它负责能力探测、降级明示、分片续发与
      // S1–S4 失效安全。`volume` 在振动语义下是**强度**，`durationMs` 是总时长，
      // 两者都由物化期敲定（"计划即审计"）。
      case final RandomVibrateAction _:
      case final ContinuousVibrateAction _:
        return vibrate.start(
          occurrenceId: occurrenceId ?? '${task.id}@runtime',
          taskId: task.id,
          action: cfg,
          durationMs: durationMs > 0 ? durationMs : 5000,
          amplitude: volume.clamp(0.0, 1.0),
          source: source,
        );
      case final CompositeAction c:
        return runSingle(task, c.primary, volume, durationMs, source,
            occurrenceId: occurrenceId);
      case final ActionSetAction set:
        // 动作集（v1.8）：按权重随机选一执行，审计记录"为什么选了这个"。
        final chosen = set.pick(math.Random());
        await logs.append(
            source: source,
            action: 'randomFrom',
            status: 'success',
            taskId: task.id,
            message: '权重 ${chosen.weight} → 选中 ${chosen.action.runtimeType}');
        return runSingle(task, chosen.action, volume, durationMs, source,
            occurrenceId: occurrenceId);
    }
  }

  /// 动作执行器（顶层分派，全部写审计日志）。
  Future<bool> runAction(
      Task task, double volume, int durationMs, String source,
      {String? occurrenceId}) async {
    lastAction = '${task.name} · ${task.actionType.label}';
    try {
      final cfg = task.action;
      if (cfg is CompositeAction) {
        final pre = cfg.prefixNotify;
        if (pre != null) {
          await NotificationService.instance
              .showEvent(title: pre.title, body: pre.body);
        }
        return await runSingle(task, cfg.primary, volume, durationMs, source,
            occurrenceId: occurrenceId);
      }
      return await runSingle(task, cfg, volume, durationMs, source,
          occurrenceId: occurrenceId);
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
    // 免打扰窗口（v1.9，修复 BUG-070）：**必须读用户设置**。
    // 此前这里恒用 `ScheduleEngine()` 的默认 22:00–07:00 —— 用户把窗口调窄后
    // 界面回显变了、落库也变了，**执行行为一点没变**（一条断掉的链路）。
    final window = normalizeQuietWindow(
      prefs.getInt(PrefsKeys.quietStartHour),
      prefs.getInt(PrefsKeys.quietEndHour),
    );
    // 夜间独立豁免主开关（v1.9，docs/20 §8.1）：**每轮重读**，不用服务启动时的快照。
    // 用户在引擎运行期间改设置后，下一轮物化即生效（无需重启服务）。
    // 读的是 `SharedPreferences`（与本项目其它用户级设置同一存储）。
    final allowExempt = prefs.getBool(PrefsKeys.quietExemptMaster) ?? false;
    if (!allowExempt) {
      // 授权被撤销 ⇒ **立刻清除**已落库的豁免计划。
      // 不能只靠重算：`commitAll` 是 `ignore` 语义（计划不漂移），
      // 已提交的豁免计划不会被新计划覆盖，会继续在夜间触发 ——
      // 那样"关掉开关"在最长一个 planHorizon 内等于没关（护栏被静默绕过）。
      final purged = await occs.deletePendingQuietExempt();
      if (purged > 0) {
        await logs.append(
            source: 'schedule',
            action: 'quietExempt',
            status: 'skipped',
            message: '夜间豁免主开关已关闭，清除 $purged 条待执行的豁免计划');
      }
    }
    final engine = ScheduleEngine(
      quietStartHour: window.start,
      quietEndHour: window.end,
      allowQuietExempt: allowExempt,
    );
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
          quietExempt: e.quietExempted,
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
      // 概率门（v1.8）：确定性条件通过后再掷随机门。
      final gateFail = probabilityGateMissed(task);
      if (gateFail != null) {
        await occs.markStatus(o.id, OccurrenceStatus.skipped);
        await logs.append(
            source: 'schedule',
            action: 'probability',
            status: 'skipped',
            taskId: task.id,
            occurrenceId: o.id,
            message: gateFail);
        continue;
      }
      final ok = await runAction(
          task, o.volume ?? 0.8, o.durationMs ?? 0, 'schedule',
          occurrenceId: o.id);
      await occs.markStatus(
          o.id, ok ? OccurrenceStatus.done : OccurrenceStatus.failed);
      // 夜间独立豁免审计（v1.9，docs/20 §8.2 约束 2）：**不得静默生效**。
      // 读的是**计划条目上持久化的标记**（而非任务当前配置）——
      // 任务配置可能在计划生成后被改掉，标记才代表"这条计划当时为何被放行"。
      if (o.quietExempt) {
        await logs.append(
            source: 'schedule',
            action: 'quietExempt',
            status: ok ? 'success' : 'failed',
            taskId: task.id,
            occurrenceId: o.id,
            message: '用户豁免免打扰（任务级）');
      }
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

  /// 远程 `vibrate.stop`（v1.9，docs/20 §10.2）：停止**全部**进行中的振动。
  ///
  /// ⚠️ 必须落在**引擎隔离**里，只调用原生 `vibrateStop()` 是不够的：
  /// 持续振动是「20 秒一片 + 3 秒 keep-alive」分片续发的（docs/20 §6），
  /// 光 cancel 掉当前这一片，下一片到期又会自己震起来。
  /// 因此走 `VibrateSession.stopAll()` —— 它同时清活跃表（停掉续发）
  /// 并调原生 cancel。
  service.on('vibrateStop').listen((m) async {
    final reason = m?['reason'] as String? ?? '远程停止';
    final before = vibrate.activeCount;
    await vibrate.stopAll(reason: reason);
    await logs.append(
      source: 'remote',
      action: 'vibrate.stop',
      status: before > 0 ? 'success' : 'skipped',
      message: before > 0
          ? '由远程停止 $before 项进行中的振动'
          : '远程请求停止，但当前没有进行中的振动',
    );
    await broadcast();
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

  /// 远程指令组里的**振动步骤**（v1.9，docs/20 §10.1）。
  ///
  /// ⚠️ 为什么必须转交引擎、而不是在主 isolate 直接调 `NativeBridge`：
  /// `VibrateSession` 是**唯一**持有「活跃振动表 + 分片续发 + S1–S4 失效安全」
  /// 的对象，而它只存在于本隔离内。主 isolate 单次下发一个长命令会有两个洞：
  /// ① 包络路径的 `maxEnvelopePointsPerChunk` 会截断，实际振动**短于**请求值
  ///   （静默缩短，正是 FR-34 禁止的那类降级）；
  /// ② `vibrate.stop` 与低电量降级都够不着它。
  /// 转交引擎后，指令组的振动与定时任务走**同一条**执行路径。
  service.on('vibrateStep').listen((m) async {
    final reqId = m?['reqId'] as String? ?? '';
    final occurrenceId = m?['occurrenceId'] as String? ?? '';
    var ok = false;
    var message = '';
    try {
      final raw = m?['action'];
      final decoded = raw is String
          ? jsonDecode(raw)
          : raw is Map
              ? raw
              : null;
      if (decoded is! Map<String, dynamic>) {
        message = '动作定义非法';
      } else {
        final action = ActionConfig.fromJson(decoded);
        final plan = resolveVibratePlan(
            action, math.Random(stringSeedOf(occurrenceId, action)), occurrenceId);
        ok = await vibrate.start(
          occurrenceId: occurrenceId,
          taskId: 'remote-script',
          action: action,
          durationMs: plan?.durationMs ?? 0,
          amplitude: plan?.baseAmplitude ?? 0,
          source: 'remote-script',
        );
        message = ok ? '已执行' : '被跳过或原生拒绝（见审计）';
      }
    } on Object catch (e) {
      message = e.toString();
    }
    if (reqId.isNotEmpty) {
      service.invoke('rcRunResult', {
        'reqId': reqId,
        'ok': ok,
        'message': message,
      });
    }
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
