/// 振动会话管理：**分片续发** + 四条失效安全（docs/20 §7.2）。
///
/// ## 为什么是分片续发
///
/// 用户决策 D1 是「持续振动**不设时长硬上限**」。这条决策能成立的**前提**
/// 就是本文件的分片架构：
///
/// - 每次只向原生下发 [VibrateRuntime.chunkMs]（20s）的振动；
/// - 由本进程的定时器（[VibrateRuntime.keepAliveTick] = 3s）续发下一片。
///
/// 于是「进程一死就没人续发」——振动在 ≤20s 内自然停止（**S1**）。
/// 反过来说：**绝不能**用 `createWaveform(..., repeat = 0)` 那种无限循环 ——
/// 进程死亡后振动**可能还在**，那是不可接受的失效模式。
///
/// ## 续发时机：宁可早发，不可晚发
///
/// Android 上再次调用 `vibrate()` 会**取消当前振动**并开始新的。因此：
/// - **早发**（下一片在当前片结束前下发）⇒ 覆盖连续，只是当前片尾部被截短，
///   而下一片的内容正好接上（`elapsedMs` 传的是 `coveredMs`，时间轴正确）；
/// - **晚发** ⇒ 出现肉眼/体感可见的**空隙**。
///
/// 所以判据是 `coveredMs - elapsedMs <= tick`，即提前一个 tick 续发。
///
/// ## 四条失效安全（D1 的代价，**不可裁剪**）
///
/// | # | 约束 | 落点 |
/// |---|---|---|
/// | S1 | 进程死亡即停 | 分片续发（本文件的结构性保证） |
/// | S2 | 重启**绝不续发** | [recoverAfterRestart]：启动一律停止 + 审计 |
/// | S3 | 任何时刻都能停 | [stopAll] / [stopFor] + 远程 `vibrate.stop` |
/// | S4 | 低电量自动降级 | [start] 前的电量闸 + [_pump] 中的在跑检查 |
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/constants.dart';
import '../core/utils/random.dart';
import '../data/repositories/log_repository.dart';
import '../domain/models/action.dart';
import '../domain/models/vibrate_caps.dart';
import '../domain/scheduling/vibrate_resolve.dart';
import 'native_bridge.dart';

/// 能力探测缝（测试注入）。
typedef VibrateCapsProbe = Future<VibrateCaps> Function();

/// 命令下发缝（测试注入）。
typedef VibrateSender = Future<bool> Function(VibrateCommand cmd);

/// 停止缝（测试注入）。
typedef VibrateStopper = Future<void> Function();

/// 电量读取缝（测试注入）。
typedef VibrateBatteryProbe = Future<({int level, bool charging})> Function();

/// kv 读写缝（测试注入；null = 不持久化，宿主测试用）。
typedef KvReader = Future<String?> Function(String key);
typedef KvWriter = Future<void> Function(String key, String value);

/// 活跃振动会话（内部状态）。
class _ActiveVibrate {
  _ActiveVibrate({
    required this.occurrenceId,
    required this.taskId,
    required this.action,
    required this.caps,
    required this.totalMs,
    required this.rng,
    required this.source,
    required this.useAlarm,
    required this.amplitude,
    required this.startedAt,
  });

  final String occurrenceId;
  final String taskId;
  final ContinuousVibrateAction action;
  final VibrateCaps caps;
  final int totalMs;
  final Random rng;
  final String source;
  final bool useAlarm;
  final double amplitude;
  final DateTime startedAt;

  /// 已下发命令**覆盖到的**执行时长（毫秒，相对 [startedAt]）。
  int coveredMs = 0;

  /// 已下发的片数（审计用）。
  int chunks = 0;
}

/// 振动会话管理器（单例式使用，但构造函数公开以便测试注入）。
class VibrateSession {
  VibrateSession({
    required this.logs,
    required this.capsProbe,
    required this.send,
    required this.stopNative,
    required this.battery,
    this.kvGet,
    this.kvSet,
    this.now = DateTime.now,
    Duration? tick,
  }) : _tick = tick ?? VibrateRuntime.keepAliveTick;

  /// 生产环境装配（原生桥 + kv）。
  ///
  /// ⚠️ [battery] 由调用方注入而不是在这里直接 new `PowerService`：
  /// 电量读取要走 `battery_plus` 平台通道，把它挡在构造函数之外，
  /// 宿主测试才能完全脱离平台跑 S4 判定。
  factory VibrateSession.standard(
    LogRepository logs, {
    required VibrateBatteryProbe battery,
    KvReader? kvGet,
    KvWriter? kvSet,
  }) =>
      VibrateSession(
        logs: logs,
        capsProbe: NativeBridge.vibrateCapabilities,
        send: NativeBridge.vibrateCommand,
        stopNative: NativeBridge.vibrateStop,
        battery: battery,
        kvGet: kvGet,
        kvSet: kvSet,
      );

  /// 活跃振动表的持久化键（**只用于 S2 的"上次没停干净"检测**）。
  static const kvKeyActive = 'vibrate_active';

  final LogRepository logs;
  final VibrateCapsProbe capsProbe;
  final VibrateSender send;
  final VibrateStopper stopNative;
  final VibrateBatteryProbe battery;
  final KvReader? kvGet;
  final KvWriter? kvSet;
  final DateTime Function() now;

  final Duration _tick;
  final Map<String, _ActiveVibrate> _active = {};
  Timer? _ticker;
  bool _pumping = false;

  /// 能力缓存（一次探测，进程内复用；失败不缓存以便重试）。
  VibrateCaps? _capsCache;

  int get activeCount => _active.length;
  bool get isActive => _active.isNotEmpty;

  /// 当前活跃振动的 occurrenceId 快照（UI「停止振动」按钮用）。
  List<String> get activeIds => _active.keys.toList(growable: false);

  Future<VibrateCaps> capabilities() async {
    final c = _capsCache;
    if (c != null) return c;
    final fresh = await capsProbe();
    // ⚠️ 只在"桥确实答复了"时缓存：`unknown` 表示读不到，
    // 读不到就不缓存，下次再试（否则一次抖动会永久降级）。
    if (fresh.platform != 'unknown') _capsCache = fresh;
    return fresh;
  }

  // ------------------------------------------------------------ 启动

  /// 启动一次振动。返回是否**真的**下发了振动。
  ///
  /// [durationMs] / [amplitude] 来自物化期（"计划即审计"），
  /// 没有物化值时由调用方按默认值兜底。
  Future<bool> start({
    required String occurrenceId,
    required String taskId,
    required ActionConfig action,
    required int durationMs,
    required double amplitude,
    required String source,
  }) async {
    final caps = await capabilities();
    final degradations = vibrateDegradations(caps, action);

    if (!caps.hasVibrator) {
      await _log(
        source: source,
        action: action.kind,
        status: 'skipped',
        taskId: taskId,
        occurrenceId: occurrenceId,
        message: '无振动能力：${degradations.join('；')}',
      );
      return false;
    }

    // ---- S4：低电量闸（对齐 FR-44「省电模式暂停随机类任务」）----
    final b = await battery();
    if (b.level < PowerConfig.saverBatteryLevel && !b.charging) {
      await _log(
        source: source,
        action: action.kind,
        status: 'skipped',
        taskId: taskId,
        occurrenceId: occurrenceId,
        message: '电量 ${b.level}% 且未充电，已跳过振动（省电降级）',
      );
      return false;
    }

    final useAlarm = !_respectDnd(action);
    final rng = Random(stringSeedOf(occurrenceId, action));

    switch (action) {
      case final RandomVibrateAction a:
        // 脉冲串一次性下发（脉冲数已被 maxPulses 封顶，无需分片）。
        final cmd = buildRandomVibrateCommand(
          caps: caps,
          a: a,
          rng: rng,
          totalMs: durationMs,
          useAlarmUsage: useAlarm,
        );
        final ok = await send(cmd);
        await _log(
          source: source,
          action: 'randomVibrate',
          status: ok ? 'success' : 'failed',
          taskId: taskId,
          occurrenceId: occurrenceId,
          volume: amplitude,
          durationMs: durationMs,
          message: [
            if (!ok) '原生拒绝或桥不可用',
            '模式=${cmd.mode.name} 脉冲段=${cmd.timings.length ~/ 2}',
            if (randomVibrateTruncated(a, durationMs)) '脉冲数已达上限，已截断',
            ...degradations,
          ].join('；'),
        );
        return ok;

      case final ContinuousVibrateAction a:
        final session = _ActiveVibrate(
          occurrenceId: occurrenceId,
          taskId: taskId,
          action: a,
          caps: caps,
          totalMs: durationMs,
          rng: rng,
          source: source,
          useAlarm: useAlarm,
          amplitude: amplitude,
          startedAt: now(),
        );
        final ok = await _sendChunk(session);
        if (!ok) {
          await _log(
            source: source,
            action: 'continuousVibrate',
            status: 'failed',
            taskId: taskId,
            occurrenceId: occurrenceId,
            volume: amplitude,
            durationMs: durationMs,
            message: ['原生拒绝或桥不可用', ...degradations].join('；'),
          );
          return false;
        }
        _active[occurrenceId] = session;
        _startTicker();
        await _persistActive();
        await _log(
          source: source,
          action: 'continuousVibrate',
          status: 'success',
          taskId: taskId,
          occurrenceId: occurrenceId,
          volume: amplitude,
          durationMs: durationMs,
          message: [
            '分片续发 片长=${VibrateRuntime.chunkMs}ms 总时长=${durationMs}ms',
            '模式=${session.caps.hasEnvelope ? 'envelope' : 'waveform'}',
            ...degradations,
          ].join('；'),
        );
        return true;

      default:
        // 固定节奏（VibrateAction）走既有路径，不在这里处理。
        return false;
    }
  }

  // ------------------------------------------------------------ 续发（S1）

  Future<bool> _sendChunk(_ActiveVibrate s) async {
    final cmd = buildContinuousChunk(
      caps: s.caps,
      a: s.action,
      rng: s.rng,
      chunkMs: VibrateRuntime.chunkMs,
      elapsedMs: s.coveredMs,
      totalMs: s.totalMs,
      useAlarmUsage: s.useAlarm,
    );
    if (cmd.chunkMs <= 0) return false;
    final ok = await send(cmd);
    if (ok) {
      s.coveredMs += cmd.chunkMs;
      s.chunks += 1;
    }
    return ok;
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(_tick, (_) => unawaited(_pump()));
  }

  /// 续发一轮。对每个活跃会话：到期收尾、需续发则续发。
  ///
  /// 对外可见（测试直接驱动，不依赖真实时钟）。
  Future<void> pump() => _pump();

  Future<void> _pump() async {
    if (_pumping || _active.isEmpty) return;
    _pumping = true;
    try {
      final finished = <String>[];
      for (final s in _active.values.toList()) {
        final elapsed = now().difference(s.startedAt).inMilliseconds;

        // S4：在跑期间电量掉到阈值以下 → 立即停止（不能只挡启动）。
        final b = await battery();
        if (b.level < PowerConfig.saverBatteryLevel && !b.charging) {
          await stopFor(s.occurrenceId, reason: '电量 ${b.level}% 未充电，省电降级停止');
          continue;
        }

        if (elapsed >= s.totalMs) {
          finished.add(s.occurrenceId);
          continue;
        }
        // 早发不晚发：当前片剩余不足一个 tick 就续发下一片。
        if (s.coveredMs - elapsed <= _tick.inMilliseconds && s.coveredMs < s.totalMs) {
          final ok = await _sendChunk(s);
          if (!ok) {
            await stopFor(s.occurrenceId, reason: '续发失败（原生拒绝或桥不可用）');
          }
        }
      }
      for (final id in finished) {
        final s = _active.remove(id);
        if (s == null) continue;
        await _log(
          source: s.source,
          action: 'continuousVibrate',
          status: 'success',
          taskId: s.taskId,
          occurrenceId: s.occurrenceId,
          volume: s.amplitude,
          durationMs: s.totalMs,
          message: '振动完成（分片 ${s.chunks} 片）',
        );
      }
      if (_active.isEmpty) {
        _ticker?.cancel();
        _ticker = null;
        await _persistActive();
      }
    } finally {
      _pumping = false;
    }
  }

  // ------------------------------------------------------------ S3：停止

  /// 停止**全部**进行中的振动（本地按钮 / 远程 `vibrate.stop` / 引擎关停共用）。
  Future<void> stopAll({String reason = '用户停止'}) async {
    final ids = _active.keys.toList(growable: false);
    for (final id in ids) {
      await stopFor(id, reason: reason, skipNative: true);
    }
    // 即使活跃表为空也要下发一次 cancel：可能存在"表丢了但原生还在震"的残留
    // （例如上一次进程被杀）。这正是 S3「任何时刻都能停」的字面要求。
    await stopNative();
    await _persistActive();
  }

  /// 停止单个 occurrence 的振动。
  ///
  /// [skipNative] 为 true 时只清状态（由 [stopAll] 统一下发一次 cancel）。
  Future<void> stopFor(
    String occurrenceId, {
    String reason = '任务停止',
    bool skipNative = false,
  }) async {
    final s = _active.remove(occurrenceId);
    if (!skipNative) await stopNative();
    if (_active.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
      await _persistActive();
    }
    if (s == null) return;
    await _log(
      source: s.source,
      action: 'continuousVibrate',
      status: 'skipped',
      taskId: s.taskId,
      occurrenceId: s.occurrenceId,
      volume: s.amplitude,
      durationMs: s.coveredMs,
      message: '已停止：$reason（已下发 ${s.chunks} 片 / ${s.coveredMs}ms）',
    );
  }

  // ------------------------------------------------------------ S2：重启

  /// 启动时调用：**一律停止，绝不续发**。
  ///
  /// 宁可少震一次，也不可失控 —— 与调度引擎"补执行限流 `catchUpLimit`"
  /// 同一哲学。若 kv 里残留了上次的活跃标记，说明上次进程结束时振动没停干净
  /// （或恰好死在振动中），此时额外写一条审计，让用户能看见这件事发生过。
  Future<void> recoverAfterRestart() async {
    _active.clear();
    _ticker?.cancel();
    _ticker = null;
    final stale = await kvGet?.call(kvKeyActive);
    await stopNative();
    await _persistActive();
    if (stale != null && stale.isNotEmpty && stale != '[]') {
      await _log(
        source: 'engine',
        action: 'continuousVibrate',
        status: 'skipped',
        message: '检测到上次进程结束时仍有振动（$stale），已强制停止且**不续发**',
      );
    }
  }

  Future<void> _persistActive() async {
    final w = kvSet;
    if (w == null) return;
    await w(kvKeyActive, jsonEncode(_active.keys.toList()));
  }

  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    _active.clear();
  }

  // ------------------------------------------------------------ 内部

  bool _respectDnd(ActionConfig action) => switch (action) {
        final RandomVibrateAction a => a.respectDnd,
        final ContinuousVibrateAction a => a.respectDnd,
        _ => true,
      };

  Future<void> _log({
    required String source,
    required String action,
    required String status,
    String? taskId,
    String? occurrenceId,
    double? volume,
    int? durationMs,
    String? message,
  }) =>
      logs.append(
        source: source,
        action: action,
        status: status,
        taskId: taskId,
        occurrenceId: occurrenceId,
        volume: volume,
        durationMs: durationMs,
        message: message,
      );
}

/// 波动种子：`'{occurrenceId}#{kind}'`。
///
/// 与物化期的 `stringSeed('$occurrenceId#jitter')` 同一键空间但**不同后缀** ——
/// 执行期的强度波动曲线因此与物化期的基准值**相互独立**，避免两者相关。
int stringSeedOf(String occurrenceId, ActionConfig action) =>
    stringSeed('$occurrenceId#run#${action.runtimeType}');
