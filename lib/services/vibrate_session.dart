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
///
/// ## 动态系统状态：**现读，不随能力缓存**（NAT-05）
///
/// 响铃模式/勿扰是实时状态（用户随时会切），而能力（振动器/振幅/包络）
/// 进程内不变。旧实现把两者塞进同一个 `_capsCache` 永久复用 ⇒ 引擎启动时
/// 是"正常"、用户后来开了勿扰，审计仍写"正常"（漏告警），或反向假告警。
/// 现在拆成两条路：
/// - [capabilities]：只缓存**静态能力**（[VibrateCaps.staticOnly] 投影）；
/// - [environment]：每次执行前现读动态状态，≤[environmentTtl] TTL 合并
///   "一次触发内的多次查询"，超时必须重查（状态可能已经变了）。
///
/// ## 按响铃状态选振动 USAGE_*（NAT-06）
///
/// 系统静音/勿扰会**整条吞掉** `USAGE_NOTIFICATION` 振动，而
/// `vibrator.vibrate()` 仍返回成功。所以用法选择与回执必须分开处理：
/// - 用法选择见 [vibrateUsageFor]（正常→NOTIFICATION/ALARM、振动→RINGTONE、
///   静音→ALARM 才可能震）；
/// - **回执如实**：静音/勿扰且动作跟随勿扰（NOTIFICATION 用法）时，系统
///   必然吞掉 ⇒ 不下发、不记 `success`，记 `failed` + 原因并返回 false
///   （"不能震"绝不伪装成"震过了"）。
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

/// 振动 `USAGE_*` 选择（NAT-06）。
///
/// 桥接层（Kotlin `vibrationAttributes`）只有 `USAGE_ALARM` /
/// `USAGE_NOTIFICATION` 两档，由 [vibrateAlarmUsageFor] 折叠；本枚举保留
/// 三档策略语义 —— 将来 F4 给 `vibrateCommand` 扩 usage 参数时，只需改
/// 那一处映射，策略判定不用动。
enum VibrateUsage {
  /// `USAGE_NOTIFICATION`：跟随勿扰；静音/勿扰下整条被系统吞掉。
  notification,

  /// `USAGE_RINGTONE`：来电/提醒级；设备处于"振动"响铃态时语义最贴合。
  ringtone,

  /// `USAGE_ALARM`：用户必须感知级；穿透静音与勿扰（合规口径同音频
  /// `AudioChannel.alarm`，UI 必须显式提示）。
  alarm,
}

/// 按响铃状态 + 动作意图选择振动 USAGE（NAT-06，纯函数便于单测锁定）。
///
/// | 响铃状态 | respectDnd=true | respectDnd=false |
/// |---|---|---|
/// | 正常(2) | NOTIFICATION | ALARM |
/// | 振动(1) | NOTIFICATION（该态下通知用法本就震，无需升档） | RINGTONE |
/// | 静音(0) | NOTIFICATION（会被吞 ⇒ 由回执层如实报未送达） | ALARM |
/// | 读不到(-1) | NOTIFICATION | ALARM |
///
/// ⚠️ `respectDnd=true` 时**永远不得**升档：远程入站强制 true（对端不得
/// 绕过本机勿扰，docs/08 合规红线），而 RINGTONE/ALARM 会穿透勿扰。
VibrateUsage vibrateUsageFor({
  required int ringerMode,
  required bool respectDnd,
}) {
  if (respectDnd) return VibrateUsage.notification;
  // 本机自排动作 = 用户自己设的"闹钟"：按响铃状态选最可能真震的用法。
  return switch (ringerMode) {
    RingerMode.silent => VibrateUsage.alarm,
    RingerMode.vibrate => VibrateUsage.ringtone,
    _ => VibrateUsage.alarm,
  };
}

/// [VibrateUsage] → 桥接层的 `useAlarmUsage` 布尔（NAT-06）。
///
/// RINGTONE 就近映射为 alarm：桥（Kotlin `vibrationAttributes`）只有两档，
/// 而 RINGTONE 与 ALARM 同属"用户必须感知"级别、在各响铃态下都不被吞。
/// 真正的三档用法要等 F4 扩 `vibrateCommand` 的 usage 参数 —— 映射与
/// 限制都写在明处，不静默降级。
bool vibrateAlarmUsageFor(VibrateUsage usage) => usage != VibrateUsage.notification;

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

  /// 动态环境状态（响铃模式/勿扰）的缓存 TTL（NAT-05）。
  ///
  /// 为什么必须有 TTL 而不是"每次都查"或"永远缓存"：
  /// - 永远缓存 = NAT-05 原缺陷（用户切了勿扰，审计长期看不到）；
  /// - 每次都查 = 一次 `start()` 里 capabilities/environment 两次通道
  ///   调用，且 `_pump` 的每个 tick 都会重查（3s 一次，纯浪费）。
  /// 2s 的取舍：远小于任何用户可感知的动作间隔（任务触发、远程指令），
  /// 又把"一次执行过程中的多次查询"合并成一次；超时后**必须**重查，
  /// 因为状态随时会变。
  static const Duration environmentTtl = Duration(seconds: 2);

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

  /// **停止代次闸门**（🔴 R97 / R88-AUD-01）。
  ///
  /// ## 缺陷形状（真机可复现，P1）
  /// [start] 在真正下发首片之前有**三处平台往返**（`capabilities()` /
  /// `environment()` / `battery()`）。若 [stopAll] 落在这段窗口里：
  /// `_active` 还是空的 ⇒ `stopAll` 认为「当前没有进行中的振动」、审计记
  /// `skipped`、原生 `cancel()` 先发完；随后 [start] 恢复执行**照常下发首片**
  /// ⇒ **用户点了「停止」，振动才刚刚开始**（S3「任何时刻都能停」被击穿）。
  ///
  /// ## 修法
  /// 所有"停止"入口（[stopAll] / [stopFor] / [dispose] / [recoverAfterRestart]）
  /// 在**同步段**里 `_stoppedGen++`；[start] 在入口同步取快照，每个 `await`
  /// 之后复核 —— 不等即说明"停止请求发生在本次启动途中"，记 `skipped` 并放弃。
  ///
  /// ## 为什么是**全局**代次而不是 per-id
  /// 与 [stopFor] 既有注释同一取舍：原生 `cancel()` 没有"按 id 停"的粒度，
  /// S3 优先级高于"精确停一个"。宁可多取消一次正在起头的会话（用户刚点了停，
  /// 少震一次无害），也不能出现"点了停还在震"。
  int _stoppedGen = 0;

  /// 静态能力缓存（NAT-05：只缓存 [VibrateCaps.staticOnly] 投影，
  /// 失败不缓存以便重试）。
  VibrateCaps? _capsCache;

  /// 动态环境状态缓存（NAT-05：TTL 见 [environmentTtl]）。
  ///
  /// 记录类型而不是 `VibrateCaps`：这里只放"从回执里摘出来的动态字段"，
  /// 与静态能力缓存彻底分离，从结构上杜绝再次混存。
  ({int ringerMode, bool? dndActive, DateTime at})? _envCache;

  int get activeCount => _active.length;
  bool get isActive => _active.isNotEmpty;

  /// 当前活跃振动的 occurrenceId 快照（UI「停止振动」按钮用）。
  List<String> get activeIds => _active.keys.toList(growable: false);

  /// 静态能力（可缓存）。返回值**不含**动态系统状态（NAT-05）：
  /// `ringerMode` 恒为 [RingerMode.unknown]、`dndActive` 恒为 null。
  ///
  /// 需要完整视图（能力 + 当前响铃/勿扰）的调用方应自行拼接
  /// [VibrateCaps.withEnvironment]（本类的 [start] 即这么做）。
  Future<VibrateCaps> capabilities() async {
    final c = _capsCache;
    if (c != null) return c;
    final fresh = await capsProbe();
    // 顺带记录动态状态：让同一次 start() 不必二次探测通道。
    _noteEnvironment(fresh);
    // ⚠️ 只在"桥确实答复了"时缓存：`unknown` 表示读不到，
    // 读不到就不缓存，下次再试（否则一次抖动会永久降级）。
    // 缓存的必须是 staticOnly 投影 —— 把 ringerMode/dndActive 带进缓存
    // 就是 NAT-05 的根因（动态状态被当成永久事实）。
    if (fresh.platform != 'unknown') _capsCache = fresh.staticOnly;
    return fresh.staticOnly;
  }

  /// 动态系统状态（响铃模式/勿扰）**现读**（NAT-05）。
  ///
  /// ≤[environmentTtl] 内复用上次结果；超时必须重新探测 —— 用户在这点
  /// 时间里完全可能切了静音/勿扰，而旧值会让审计写出相反结论。
  Future<({int ringerMode, bool? dndActive})> environment() async {
    final e = _envCache;
    final t = now();
    if (e != null && t.difference(e.at) < environmentTtl) {
      return (ringerMode: e.ringerMode, dndActive: e.dndActive);
    }
    final fresh = await capsProbe();
    return _noteEnvironment(fresh, at: t);
  }

  /// 把一次探测回执里的动态字段摘进环境缓存，返回摘出的值。
  ({int ringerMode, bool? dndActive}) _noteEnvironment(
    VibrateCaps fresh, {
    DateTime? at,
  }) {
    final env = (ringerMode: fresh.ringerMode, dndActive: fresh.dndActive);
    _envCache = (
      ringerMode: env.ringerMode,
      dndActive: env.dndActive,
      at: at ?? now(),
    );
    return env;
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
    // 🔴 R97（R88-AUD-01）：在**任何 await 之前**同步取停止代次快照。
    // Dart 单线程 ⇒ 这一句与下面所有 `await` 之间不可能被插队，快照就是
    // "本次启动的出生代次"；任何停止入口都会让 `_stoppedGen` 大于它。
    final gen = _stoppedGen;
    // NAT-05：静态能力走缓存，动态状态现读，两者拼成这一次执行的完整视图。
    final staticCaps = await capabilities();
    final env = await environment();
    final caps = staticCaps.withEnvironment(
      ringerMode: env.ringerMode,
      dndActive: env.dndActive,
    );
    final degradations = vibrateDegradations(caps, action);
    final followDnd = _respectDnd(action);
    // R93 + NAT-02：系统状态是"调用成功却没震"的唯一解释来源 —— 必须进
    // 同一条审计行。判据（NAT-02 修正后）：静音(0) 或 勿扰；振动(1)与
    // 正常(2)都不算被吞（旧判据把这两态当成被吞、放过了静音，整体反向）。
    final swallowed = caps.notificationsMuted && followDnd;
    if (swallowed) {
      degradations.add('系统${caps.dndActive == true ? '勿扰' : caps.ringerLabel}中，'
          '且本动作跟随勿扰（USAGE_NOTIFICATION）⇒ 振动极可能被系统静默吞掉'
          '（原生回执仍是 success，本层不采信）');
    }

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

    // 🔴 R97（R88-AUD-01）：**停止代次复核**（见 `_stoppedGen` 的说明）。
    //
    // 位置刻意放在最后一处平台往返（`battery()`）之后、任何下发之前 ——
    // 这里是「窗口已全部关闭、但首片还没发」的那个唯一确定时刻。
    if (gen != _stoppedGen) {
      await _log(
        source: source,
        action: action.kind,
        status: 'skipped',
        taskId: taskId,
        occurrenceId: occurrenceId,
        message: '启动过程中收到停止请求，已取消下发（未开始振动）',
      );
      return false;
    }

    // ---- NAT-06：不能震就不震，绝不再记 success ----
    //
    // 静音/勿扰 + 跟随勿扰（USAGE_NOTIFICATION）⇒ 系统**必然**吞掉整条
    // 振动，而原生 `vibrator.vibrate()` 照样回 true。旧实现照发照记
    // success，用户什么都没感觉到（R93 用户报障"手机震动不好使"的根因）。
    // 现在：识别出这个状态就**不下发**，审计记 failed + 原因，返回 false。
    if (swallowed) {
      await _log(
        source: source,
        action: action.kind,
        status: 'failed',
        taskId: taskId,
        occurrenceId: occurrenceId,
        volume: amplitude,
        durationMs: durationMs,
        message: [
          '设备${caps.dndActive == true ? '勿扰' : '静音'}，振动可能不触发：'
              '本动作跟随勿扰（USAGE_NOTIFICATION）会被系统吞掉，未下发、不记 success',
          ...degradations,
        ].join('；'),
      );
      return false;
    }

    // NAT-06：按响铃状态选 USAGE_*（策略与 wire 映射分离，见函数注释）。
    final usage = vibrateUsageFor(
      ringerMode: env.ringerMode,
      respectDnd: followDnd,
    );
    final useAlarm = vibrateAlarmUsageFor(usage);
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
        final prev = _active[occurrenceId];
        _active[occurrenceId] = session;
        if (prev != null) {
          // BUG-126：同 id 重入（重试 / 重新物化后再次触发 / 远程连按两次）此前是
          // **直接覆盖** —— 旧会话的起始时刻、已下发片数、审计归属全部丢失，
          // 而 `stopFor(id)` 从此只能停到新会话，旧会话的账目再也对不上。
          // 原生侧本来就会被新的 `vibrate()` 取消（Android 语义），
          // 所以这里只需**把旧会话的账结清**并如实记账。
          await _log(
            source: prev.source,
            action: 'continuousVibrate',
            status: 'skipped',
            taskId: prev.taskId,
            occurrenceId: prev.occurrenceId,
            volume: prev.amplitude,
            durationMs: prev.coveredMs,
            message: '被同 id 的新会话接管（已下发 ${prev.chunks} 片 / '
                '${prev.coveredMs}ms），旧会话按停止处理',
          );
        }
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

        // 🔴 R97（R88-AUD-01 第二条）：`battery()` 是平台往返，期间该 id 可能
        // 已被**新会话接管**（BUG-126 的同 id 重入）或被停止摘表。旧实现继续用
        // **快照里的旧会话** `s` 续发，或在收尾时按 id `_active.remove(id)` ——
        // 于是被删掉、并记成「振动完成」的会是**新会话**（账目与原生状态全错）。
        // 身份复核（`identical`）后跳过：新会话由它自己那一轮负责。
        if (!identical(_active[s.occurrenceId], s)) continue;

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
    // 🔴 R97（R88-AUD-01）：**第一条语句**同步推进停止代次（在任何 await 之前）。
    // 这一句就是"点了停"对**正在起头、还没进活跃表**的会话的唯一约束手段。
    _stoppedGen++;
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
  ///
  /// ⚠️ **原生 `cancel()` 没有"按 id 停"的粒度**：它停掉本应用发起的全部振动，
  /// 因此停 A 会顺带打断 B 的当前片。这是刻意的取舍 —— S3「任何时刻都能停」
  /// 优先级高于"精确停一个"；B 会在下一个 tick（≤`keepAliveTick`）按
  /// `coveredMs` 续发，空隙有界且可解释。反过来若为了不打扰 B 而不发 cancel，
  /// 就会出现"点了停，A 还在震到本片结束"，那才是真正违反 S3。
  Future<void> stopFor(
    String occurrenceId, {
    String reason = '任务停止',
    bool skipNative = false,
  }) async {
    // 🔴 R97（R88-AUD-01）：与 [stopAll] 同理 —— 同步推进代次，让"停"这件事
    // 对**正在起头**的会话也生效（全局代次的取舍见 `_stoppedGen` 注释）。
    _stoppedGen++;
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
    _stoppedGen++;
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

  /// 释放会话管理器：取消续发定时器 + 清状态 + **下发一次原生 cancel**。
  ///
  /// BUG-127：旧实现只取消定时器与清表 —— 原生侧当前片（最长
  /// `VibrateRuntime.chunkMs` = 20s）会**继续震到自然结束**。S3 的字面要求是
  /// 「任何时刻都能停」，而 `dispose()` 正是「引擎关停 / 远程遥控停用 / 页面
  /// 销毁」的落点：用户关掉开关后手机还在震 20 秒，是四条失效安全里唯一
  /// 没堵上的缺口。
  ///
  /// `dispose()` 是**同步**接口（调用点在引擎 teardown），因此 cancel 以
  /// fire-and-forget 下发；通道已销毁时异常吞掉，不制造未处理异步错误。
  void dispose() {
    _stoppedGen++;
    _ticker?.cancel();
    _ticker = null;
    _active.clear();
    unawaited(stopNative().catchError((Object _) {}));
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
