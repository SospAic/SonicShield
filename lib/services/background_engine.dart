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
import '../data/repositories/api_config_store.dart';
import '../data/repositories/counter_plan_store.dart';
import '../data/repositories/log_repository.dart';
import '../data/repositories/occurrence_repository.dart';
import '../data/repositories/task_repository.dart';
import '../domain/models/action.dart';
import '../domain/models/condition.dart';
import '../domain/models/counter_plan.dart';
import '../domain/models/task.dart';
import '../domain/models/trigger.dart';
import '../domain/models/tts_voice.dart';
import '../domain/scheduling/run_pause.dart';
import '../domain/scheduling/schedule_engine.dart';
import '../domain/scheduling/vibrate_resolve.dart';
import '../features/guard/guard_orchestration.dart';
import 'condition_env.dart';
import 'counter_plan_service.dart';
import 'notification_service.dart';
import 'native_bridge.dart';
import 'neural_tts.dart';
import 'online_tts_client.dart';
import 'playback_service.dart';
import 'preset_import.dart';
import 'reactive_counter_service.dart';
import 'retention_maintenance.dart';
import 'sound_guard_service.dart';
import 'tts_service.dart';
import 'vibrate_session.dart';

/// 引擎隔离内的神经 TTS 单例：与 UI 隔离共享同一份模型资产落盘目录，
/// 首次 speak 才构造原生句柄；失败返回 false，由 [TtsService] 回落系统音色。
final NeuralTtsEngine _neuralTts = NeuralTtsEngine();

/// 引擎隔离内神经 TTS 播报委托（签名匹配 [NeuralTtsSpeak]）。
Future<bool> _speakNeuralTts(String text, double volume) =>
    _neuralTts.speak(text, volume);

/// 后台引擎状态快照（服务 -> UI 广播）。
class EngineState {
  const EngineState({
    required this.running,
    required this.pendingCount,
    this.nextFireAt,
    this.lastAction,
    this.guardActive = false,
    this.guardError,
    this.alarmDiag,
  });

  final bool running;
  final int pendingCount;
  final DateTime? nextFireAt;
  final String? lastAction;
  final bool guardActive;

  /// 守卫启动失败原因（成功 / 未尝试时为 null）。
  ///
  /// 为什么要随状态一起回投：`guardActive:false` 只能说明"没跑起来"，
  /// 说不出"为什么"。UI 侧 `waitForGuardActive(true)` 超时后只能报
  /// "引擎无响应"，而真实原因（如麦克风被占用）就在引擎手里 —— 不回投
  /// 就等于把失败静默掉（BUG-061 判据）。
  final String? guardError;

  /// 精确闹钟（通道B）**降级原因**（P1-04）；正常或未尝试时为 null。
  ///
  /// 与 [guardError] 同形：排布数量不足/权限被拒时，若不上报，界面会继续
  /// 显示"运行中 + 计划数"，用户无从知道"进程被杀后不再准点"。回投后
  /// UI 在可操作位置解释并提供"精确闹钟权限"入口（可恢复）。
  final String? alarmDiag;

  Map<String, Object?> toMap() => {
        'running': running,
        'pendingCount': pendingCount,
        'nextFireAt': nextFireAt?.millisecondsSinceEpoch,
        'lastAction': lastAction,
        'guardActive': guardActive,
        'guardError': guardError,
        'alarmDiag': alarmDiag,
      };
}

/// 动作执行的**统一结果语义**（P1-07）。
///
/// 为什么需要它：此前动作 helper（`playAndLog` / `ttsAndLog` / `recordAndLog`
/// / `soundscapeAndLog`）返回 `void`，而 [runSingle] 对播放/TTS/录音/声景分支
/// **固定 `return true`** —— 于是"播放缺文件""TTS 超时""录音失败"这些
/// **真实失败**在 occurrence / 远程 ack 里全被记成成功（日志说失败、计划说成功）。
/// 现在三态（success/failed/skipped）从 helper 一路带上调用方、Occurrence 与
/// 远程回执，语义只有一处真源。
enum ExecutionStatus { success, failed, skipped }

class ExecutionOutcome {
  const ExecutionOutcome._(this.status, this.reason);

  /// 动作确实完成。
  const ExecutionOutcome.success() : this._(ExecutionStatus.success, null);

  /// 动作**做错了 / 没做到**（缺音源、TTS 超时、录音异常、原生拒绝…）。
  const ExecutionOutcome.failed(String reason)
      : this._(ExecutionStatus.failed, reason);

  /// 动作**没做**，但这不是错误（平台无该能力、概率/条件未命中）。
  /// 与 failed 的区别决定 occurrence 记 skipped 还是 failed。
  const ExecutionOutcome.skipped(String reason)
      : this._(ExecutionStatus.skipped, reason);

  final ExecutionStatus status;
  final String? reason;

  /// 正向语义：只有 **failed** 算失败；skipped 不算失败（与既有
  /// `runAction` 布尔语义下"平台无能力仍返回 true"保持一致）。
  bool get ok => status != ExecutionStatus.failed;
  bool get isFailure => status == ExecutionStatus.failed;
  bool get isSkipped => status == ExecutionStatus.skipped;

  @override
  String toString() => 'ExecutionOutcome($status${reason == null ? '' : ': $reason'})';
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

  // P2-10：保留策略维护（docs/07 §4「数据生命周期」）。两个 `purgeOlderThan`
  // 此前只有定义、无生产调用入口 —— 长期运行会让日志与历史计划只增不减。
  // 每次引擎启动跑一次即可：清理是**幂等**的（已删的再判一次为 0），且引擎
  // 只在守护开启/看门狗唤醒时启动，天然形成"低频维护"节奏。
  // 维护不是核心执行路径 —— 失败只留一条审计，**绝不阻断引擎启动**。
  try {
    final removed =
        await RetentionMaintenance(logs: logs, occurrences: occs).run();
    if (removed.total > 0) {
      await logs.append(
        source: 'maintenance',
        action: 'retention',
        status: 'success',
        message: '清理过期日志 ${removed.logsRemoved} 条、'
            '历史计划 ${removed.occurrencesRemoved} 条',
      );
    }
  } on Object catch (e) {
    try {
      await logs.append(
        source: 'maintenance',
        action: 'retention',
        status: 'failed',
        message: '$e',
      );
    } on Object {
      // 连审计都写不进：维护本就不阻断启动，此处不再上抛。
    }
  }

  final playback = PlaybackService();
  final guard = SoundGuardService();
  const native = MethodChannel(Channels.method);
  final battery = Battery();
  final prefs = await SharedPreferences.getInstance();

  /// 跨 isolate 的**设置同步**（BUG-082，2026-10-17）：读设置前把 prefs 重新拉一遍。
  ///
  /// ## 为什么必须有它（用户实测：「开启夜间豁免后，新建的任务到点不执行」）
  /// 本引擎跑在 `flutter_background_service` 的**独立 `FlutterEngine` isolate** 里
  /// （`flutter_background_service_android-6.3.1/.../BackgroundService.java:211,228`），
  /// 而 `SharedPreferences` 的 Dart 侧是**按 isolate 缓存**的：
  /// `shared_preferences-2.5.5/lib/src/shared_preferences_legacy.dart:28` 的
  /// `static Completer<SharedPreferences>? _completer` + `:107` 的
  /// `_preferenceCache` ⇒ `getInstance()` 只在**首次**把整份 KV 读进内存，
  /// 之后 `getXxx()` 全部命中这份**本 isolate 的**快照。
  /// Android legacy 通道也**没有**变更回推（`LegacySharedPreferencesPlugin.kt`
  /// 未注册 `OnSharedPreferenceChangeListener`）⇒ UI isolate 之后的任何写入，
  /// 本 isolate **永远看不到**。
  ///
  /// 后果（全部是"界面回显变了、落库也变了，行为一点没变"）：
  /// - `quietExemptMaster`：用户开启夜间豁免后，引擎仍按"未授权"物化 ⇒
  ///   新建的夜间任务被判跳过、**到点不执行**（本次用户报的现象）；
  /// - `quietStartHour/quietEndHour`：BUG-070 的修复只在"引擎重启后"才成立；
  /// - `runMasterMode`：全局执行总开关改档后，执行期暂停判据仍是旧模式；
  /// - `alarmClockChannel`：通道选择不生效；
  /// - `CounterPlanStore`（反击计划本体 / 节假日覆盖表）：引擎侧读到旧表 ⇒
  ///   反击计划续算与暂停窗口都用旧值。
  ///
  /// ⚠️ 这类缺陷**只有"引擎已在运行"时才复现**，重启引擎即自愈 ——
  /// 所以它躲过了所有"重启后跑一遍"的手工验证，必须靠本函数在**每个读设置
  /// 的入口**显式同步。
  ///
  /// ## 失败方向
  /// `reload()` 抛（平台通道异常）⇒ **沿用旧缓存**继续调度：宁可短暂用旧设置，
  /// 也不能让一次 KV 读取失败把整个 tick 打断（与 `stepGuarded` 同一条纪律）。
  Future<void> syncPrefs() async {
    try {
      await prefs.reload();
    } on Object {
      // 读不到就沿用旧缓存，不阻断调度。
    }
  }

  /// 应用电源模式副作用（v1.9.1 新增）：**仅** `performance` 档持有常驻唤醒锁。
  ///
  /// 背景：此前 `power_mode` 是**死设置** —— 设置页写入、`setPowerMode` 发
  /// `powerMode` invoke，但引擎里**没有接收方**、全仓也无人读取 ⇒ 电源模式对运行时
  /// **零影响**（BUG-070「写在一处、用在另一处」同族）。本函数补上唯一副作用：
  /// 性能优先 = 持 `PARTIAL_WAKE_LOCK`（锁屏 / Doze 不冻结 CPU，通道 A 持续跑）；
  /// 平衡 / 省电 = 释放，退回"仅通道 B 精确闹钟"的默认保活。
  Future<void> applyPowerMode(String mode) async {
    final wantLock = mode == 'performance';
    try {
      await native.invokeMethod<bool>(
          'setPersistentWakeLock', {'enabled': wantLock});
    } on Object catch (e) {
      // 持锁失败不致命（最坏退回"仅通道 B"），但必须留痕，不得静默。
      await logs.append(
        source: 'engine',
        action: 'powerMode',
        status: 'failed',
        message: '切换电源模式 $mode 时唤醒锁设置失败：$e',
      );
    }
  }

  // 启动即应用（与设置页持久化的 power_mode 一致；看门狗唤醒重启后同样生效）。
  await applyPowerMode(prefs.getString(PrefsKeys.powerMode) ?? 'balanced');

  /// 实时随机动态反击（v2.0 阶段 D）。
  ///
  /// **不采音**：本服务没有录音器，它消费 [SoundGuardService] 的 [SoundEvent]
  /// —— 与守卫复用同一条麦克风通路（计划第 21 条），结构上不可能出现"第二个
  /// 录音器"。因此它只在守卫运行时才有意义（无声音来源 = 无输入）。
  /// 由 `PrefsKeys.reactiveCounterEnabled` 决定是否装配；`reactive` 通道热切换。
  ReactiveCounterService? reactive;

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
  /// 守卫**采流异常**的订阅（见 [SoundGuardService.errors]）。
  ///
  /// 为什么必须订阅：`record` 的采流在中途出错（麦克风被其它应用抢占、
  /// 录音器崩溃）时，守卫端只把 `isRunning` 置 false —— 没有审计、没有原因，
  /// 用户只看到"守卫自己关了"。订阅后把原因写进审计并回投 `guardError`。
  StreamSubscription<Object>? guardErrSub;
  String? lastAction;

  /// `executeDue` 的重入守卫（A2-P0-2；与 `VibrateSession._pumping` 同形）。
  ///
  /// 为什么要它：通道A 有**两个同源可叠加**的触发点 ——
  /// `Timer.periodic(engineTick)`（`background_engine.dart:1136`）与
  /// `service.on('tick')`（`:941`），而 `executeDue` 内的 `runAction` 可长时间
  /// 阻塞（播放 / 录音 / TTS，最长 1800s）。没有守卫时，15s 的 tick 会在上一轮
  /// `runAction` 尚未返回时**再起一份** `executeDue`，而 `due()` 只筛
  /// `status='pending'` —— 那条计划尚未落终态，于是被**并发取出执行两次**
  /// （双响 / 重复录音 / 播放器互踩）。
  ///
  /// ⚠️ 只做「`if (flag) return; flag = true; try { … } finally { flag = false; }`」
  /// 这件事：不在本修复里改 tick 间隔、不改 `runAction` 超时、不动任何执行语义。
  bool executing = false;

  /// `replan` 的重入守卫（同形；`service.on('replan')` 与 tick 续算同源可叠加）。
  ///
  /// ⚠️ 刻意**不与 [executing] 共用一个标志**：共用会让「执行一个长动作」把
  /// 续算整段挡掉（`replan` 负责续算计划视界），可能出现计划迟迟不续算。
  /// 两条路径各自持锁即可消除各自的重入，且互不干扰（详见 F2 报告）。
  bool replanning = false;

  /// 守卫启动失败原因（随每次 `state` 广播回投给 UI）。
  /// 成功启动 / 主动关闭时清空 —— 否则 UI 会一直拿着一条过期的错误。
  String? guardError;

  /// 精确闹钟（通道B）降级原因（P1-04），随每次 `state` 广播回投给 UI。
  /// 排布正常时清空 —— 与 [guardError] 同为"失败必须可见"的载体。
  String? alarmDiag;

  /// 守卫"延时执行"的待发定时器（v1.10 编排增强）。
  ///
  /// 持有它是为了**能被取消**：用户关了守卫 / 停了引擎之后，已排定的延时
  /// 声音绝不能再响 —— 否则"关掉守卫"在最长一个延时窗口内等于没关
  /// （与 `replan()` 里清除夜间豁免计划同一类护栏）。
  Timer? guardDelayTimer;

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

  /// 单步兜底执行：失败**写审计 + 打日志**，但绝不中断调用方。
  ///
  /// 存在的理由（真机取证，BUG-A）：引擎启动序列是**串行**的
  /// （`executeDue` → `replan` → `broadcast`），任何一步抛出去，它下面的
  /// 代码就再也不会执行 —— 而 UI 的"引擎在跑"完全依赖末尾那次广播。
  /// Mi 14 Pro（Android 16）上老库缺列 `occurrences.quiet_exempt`，
  /// `replan()` 抛 `SQLITE_ERROR` ⇒ 引擎永远不广播 ⇒ 引擎/守卫开关都打不开。
  ///
  /// 两处都留痕是刻意的：
  /// - 审计（`exec_logs`）给用户看 —— 界面上能查到"这一轮为什么没算出计划"；
  /// - `print` 给 `logcat` 看 —— 连审计都写不进去时（DB 本身坏了）仍有痕迹。
  Future<void> stepGuarded(String name, Future<void> Function() step) async {
    try {
      await step();
    } on Object catch (e) {
      // ignore: avoid_print
      print('[sonic_shield][engine] $name 失败：$e');
      try {
        await logs.append(
            source: 'schedule', action: name, status: 'failed', message: '$e');
      } on Object {
        // 审计通道自身不可用时不再二次抛出：上面已经打过留痕日志。
      }
    }
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
  Future<ExecutionOutcome> soundscapeAndLog(
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
      final reason = sc.tracks.isEmpty
          ? '无可解析的音轨'
          : '${sc.tracks.length} 轨全部无法解析'
              '（点名的音源已不存在），已跳过而非改播其它音源';
      await logs.append(
          source: source,
          action: 'soundscape',
          status: 'failed',
          taskId: task.id,
          message: reason);
      return ExecutionOutcome.failed(reason);
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
    return r.ok
        ? const ExecutionOutcome.success()
        : ExecutionOutcome.failed(r.message ?? '声景播放失败');
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

  Future<ExecutionOutcome> playAndLog(Task task, PlayAudioAction p, double volume,
      int durationMs, String source) async {
    final path = await pickAssetFor(task);
    if (path == null) {
      await logs.append(
          source: source,
          action: 'play',
          status: 'failed',
          taskId: task.id,
          message: '无可用音源');
      return const ExecutionOutcome.failed('无可用音源');
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
    return r.ok
        ? const ExecutionOutcome.success()
        : ExecutionOutcome.failed(r.message ?? '播放失败');
  }

  /// 系统 TTS（引擎隔离内）：音量 + 语言 + 按关键词猜音色 + 喊话。
  ///
  /// 与 `main.dart` 的 `speakSystemTts` 是**同一套决策**（都调可测的
  /// `TtsVoices.pickSystemVoice`），只是一份 `FlutterTts` 平台胶水无法跨
  /// isolate 共享 —— 引擎 isolate 不能 import 应用装配入口（会把整个 UI 拖进来）。
  /// 音色匹配失败**不视为错误**（交给系统默认音色）。
  ///
  /// 超时保护：无 TTS 引擎的平台（如 AOSP 镜像）speak/setLanguage 可能永不回调，
  /// 此前会导致审计日志永远写不进去（BUG-011 关联）。
  Future<void> speakSystemTts(
      String text, double volume, List<String> match) async {
    final tts = FlutterTts();
    try {
      await tts.setVolume(volume).timeout(const Duration(seconds: 8));
      await tts.setLanguage('zh-CN').timeout(const Duration(seconds: 8));
      if (match.isNotEmpty) {
        try {
          final voices =
              await tts.getVoices.timeout(const Duration(seconds: 8));
          final picked = TtsVoices.pickSystemVoice(voices, match);
          if (picked != null) {
            await tts.setVoice(picked).timeout(const Duration(seconds: 8));
          }
        } on Object {
          // 音色匹配是增强：拿不到列表/设置失败都不该让播报失败。
        }
      }
      // ★ 离线播报「没声音」的根因修复：`speak` 在 Android/iOS 上**默认立即返回**
      //   （原生仅在 `awaitSpeakCompletion && QUEUE_FLUSH` 时才挂起 result），于是
      //   下面 finally 里的 `stop()` 会把刚排队的朗读**当场取消**。开启「等朗读
      //   完成」后 speak 真正等到 `onDone`，stop() 变成无害清理。
      await tts.awaitSpeakCompletion(true).timeout(const Duration(seconds: 3));
      // 朗读预算按字数估（中文约 4 字/秒）+ 8s 余量，夹在 15..120s。
      final secs = (8 + text.length ~/ 4).clamp(15, 120).toInt();
      await tts.speak(text).timeout(Duration(seconds: secs));
    } finally {
      try {
        await tts.stop().timeout(const Duration(seconds: 3));
      } on Object {
        // 清理失败不影响审计
      }
    }
  }

  /// 在线语音（引擎隔离内）：合成 → 临时 mp3 → 播放器出声。
  Future<bool> speakOnlineTts(
      String text, double volume, String voiceName, ApiConfigStore cfg) async {
    // 选通路（Edge 免 Key WebSocket / Azure REST）统一交给 buildOnlineTtsClient；
    // 返回 null = 未配置/端点不可用，直接判失败、不发请求。
    final client = buildOnlineTtsClient(
      endpoint: cfg.ttsEndpoint,
      apiKey: cfg.ttsApiKey,
    );
    if (client == null) return false;
    final speaker = OnlineTtsSpeaker(
      client: client,
      sink: TtsAudioSink(
        writeTemp: (bytes, ext) async {
          final dir = await getTemporaryDirectory();
          final f = File(
              '${dir.path}/tts_${DateTime.now().microsecondsSinceEpoch}.$ext');
          await f.writeAsBytes(bytes, flush: true);
          return f.path;
        },
        deleteTemp: (path) => File(path).delete(),
        play: (path, vol) async =>
            (await playback.play(
          path: path,
          channel: AudioChannel.media,
          volume: vol,
          maxDurationMs: 60000,
        ))
                .ok,
      ),
    );
    try {
      return await speaker.speak(text, voiceName, volume);
    } finally {
      client.close();
    }
  }

  Future<ExecutionOutcome> ttsAndLog(Task task, TtsAction t, String source) async {
    // v2.0：本地定时「语音喊话」也走统一 `TtsService` —— 按 `voiceId` 决定用
    // 系统 TTS（离线）还是在线语音（含东北话）。与远程端点同一套决策，
    // 所以"本机用的音色"和"远程发的音色"语义不会分叉。
    final tts = TtsService(
      speakSystem: speakSystemTts,
      speakNeural: _speakNeuralTts,
      speakOnline: (text, volume, voiceName) => speakOnlineTts(
        text,
        volume,
        voiceName,
        ApiConfigStore(prefs),
      ),
    );
    final r = await tts.say(t.text, voiceId: t.voiceId, volume: t.volume);
    await logs.append(
        source: source,
        action: 'tts',
        status: r.ok ? 'success' : 'failed',
        taskId: task.id,
        volume: t.volume,
        message: r.ok ? (r.online ? '在线语音（${t.voiceId}）' : null) : r.message);
    return r.ok
        ? const ExecutionOutcome.success()
        : ExecutionOutcome.failed(r.message ?? '语音播报失败');
  }

  Future<ExecutionOutcome> recordAndLog(
      Task task, int seconds, String source) async {
    final rec = AudioRecorder();
    try {
      // ⚠️ **不再用 `rec.hasPermission()` 做准入判定**（真机取证 + 与
      // `SoundGuardService.start` 同一条教训，N-1）：
      // `record_android` 的 `PermissionManager.hasPermission()` 第一句就是
      // `if (activity == null) { onResult(false); return }`，而本方法**只**
      // 运行在 `flutter_background_service` 的引擎隔离里 —— 那里没有 Activity，
      // 于是该判定**恒为 false**，与系统实际授权无关。
      //
      // 后果与 C-1 完全同形：**本地定时「录音取证」在这条路径上恒失败**
      // （永远写 `failed · 无麦克风权限`、永不产出文件），而使用者看到的只是
      // "到点了没录上"，UI 并不区分"权限真的没给"和"这个判定在不该用的上下文里"。
      //
      // 现在改为**直接尝试开始录制**：权限真的没给，`start` 会抛，
      // 异常文本就是真实原因（比一句编造的"无麦克风权限"有用得多）。
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
        // ⚠️ 走**流式**哈希（P2-09）：`readAsBytes()` 会把整段录音全量载入内存，
        // 长录音（分钟级）在低配机上足以触发 OOM —— 而取证文件恰恰可能很长。
        sha256Hex =
            (await sha256.bind(File(path).openRead()).first).toString();
      } on Object {
        // 文件不可读时保留空哈希（审计仍记录路径与时间）
      }
      await logs.append(
          source: source,
          action: 'record',
          status: 'success',
          taskId: task.id,
          durationMs: seconds * 1000,
          // ⚠️ 哈希为空必须**写进审计文本**：只留 `sha256= ` 会被读成
          // "哈希就算出来了，只是空" —— 完整性校验其实没做到。
          message: sha256Hex.isEmpty
              ? 'sha256=（文件不可读，未生成完整性哈希）path=$path'
              : 'sha256=$sha256Hex path=$path');
      await NotificationService.instance.showEvent(
        title: '声盾 · 取证完成',
        // 同理：**承诺了哈希才说含哈希** —— 没算出来就说没算出来。
        body: sha256Hex.isEmpty
            ? '已保存到应用私有目录（文件不可读，完整性哈希未生成）'
            : '已保存到应用私有目录（含完整性哈希）',
      );
      return const ExecutionOutcome.success();
    } catch (e) {
      await logs.append(
          source: source,
          action: 'record',
          status: 'failed',
          taskId: task.id,
          message: e.toString());
      return ExecutionOutcome.failed(e.toString());
    } finally {
      // ⚠️ P2-09：`AudioRecorder` 此前**从不 dispose**，异常路径也不保证 stop。
      // 录音器持有麦克风句柄，不释放会持续占用系统音频资源（守卫/通话被拒）。
      // 用 try/finally 尽力停录并释放，且**不覆盖**已有错误。
      try {
        await rec.stop();
      } on Object {
        // 已停止或未开始时忽略
      }
      try {
        await rec.dispose();
      } on Object {
        // 释放失败不影响审计
      }
    }
  }

  /// 当前是否处于「全局执行总开关」的**暂停关闭**状态（v79，docs/20 §9）。
  ///
  /// 判据真源在纯函数层 [RunPause.paused]：模式取自 `PrefsKeys.runMasterMode`
  /// （`auto` / `on` / `off`，读不懂 → `auto`），`auto` 下再由节假日判定窗口
  /// `[休息日前一天 20:00, 连续休息日最后一天 21:00)` 决定。
  ///
  /// **每轮重读**（不缓存）：用户在引擎运行期间改模式，下一轮 tick 即生效，
  /// 无需重启服务 —— 与夜间豁免主开关、免打扰窗口同一口径。
  ///
  /// 节假日覆盖表沿用反击计划的同一份（`CounterPlanStore`：手动覆盖 + 联网整年表），
  /// 不另立存储，保证"休息日认定"全局唯一。
  bool pausedAt(DateTime at) {
    final mode = RunMasterMode.parse(prefs.getString(PrefsKeys.runMasterMode));
    final store = CounterPlanStore(prefs);
    return RunPause.paused(
      mode,
      at,
      overrides: store.overrides(),
      autoOverrides: store.autoOverrides(),
    );
  }

  /// 统一的执行前裁决（条件 → 概率），供**声音**与**远程立即执行**两个入口复用。
  ///
  /// 定时入口 `executeDue` 因重入/乐观置状态的结构约束，把同样两条门**同序**
  /// 内联实现（见其函数体）。三处判据一致：先确定性条件、再随机概率门。
  /// 返回 null = 通过；否则写审计并返回未通过原因。
  Future<String?> admitExecution(Task task, ConditionEnv env, String source,
      {String? occurrenceId}) async {
    // 设置同步（BUG-082）：本入口（声音触发 / 远程立即执行）不走 `executeDue`，
    // 但同样要读全局执行总开关 + 节假日表 ⇒ 先 reload，否则改档在引擎运行期间
    // 对这两条通路完全无效。
    await syncPrefs();
    // 全局执行总开关（v79，docs/20 §9）：暂停期间除显式例外一律不放行。
    // 放在最前 —— 它是比条件/概率更粗的刹车，不该先做无谓的平台读取与随机掷骰。
    if (!task.forceRun && pausedAt(DateTime.now())) {
      const msg = '节假日自动暂停中（全局执行总开关），跳过';
      await logs.append(
          source: source,
          action: 'runPause',
          status: 'skipped',
          taskId: task.id,
          occurrenceId: occurrenceId,
          message: msg);
      return msg;
    }
    final condFail = conditionFailedIn(task, env);
    if (condFail != null) {
      await logs.append(
          source: source,
          action: 'condition',
          status: 'skipped',
          taskId: task.id,
          occurrenceId: occurrenceId,
          message: condFail);
      return condFail;
    }
    final gateFail = probabilityGateMissed(task);
    if (gateFail != null) {
      await logs.append(
          source: source,
          action: 'probability',
          status: 'skipped',
          taskId: task.id,
          occurrenceId: occurrenceId,
          message: gateFail);
      return gateFail;
    }
    return null;
  }

  /// 动作执行统一串行 await：保证 occurrence 状态与审计日志严格一致
  /// （此前 fire-and-forget 在 TTS 挂起时导致日志永远缺失——BUG-011 关联）。
  Future<ExecutionOutcome> runSingle(Task task, ActionConfig cfg, double volume,
      int durationMs, String source, {String? occurrenceId}) async {
    switch (cfg) {
      case final PlayAudioAction p:
        return playAndLog(task, p, volume, durationMs, source);
      case final SoundscapeAction sc:
        return soundscapeAndLog(task, sc, source);
      case final TtsAction t:
        return ttsAndLog(task, t, source);
      case final NotifyAction n:
        await NotificationService.instance
            .showEvent(title: n.title, body: n.body);
        await logs.append(
            source: source,
            action: 'notify',
            status: 'success',
            taskId: task.id);
        return const ExecutionOutcome.success();
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
          return const ExecutionOutcome.skipped('无振动能力');
        }
        try {
          // ⚠️ 必须**检查回执**，不能只看"有没有抛异常"。
          //
          // Android 侧 `result.success(true)`；而 iOS 侧既没有 `vibrate` 分支、
          // 也不会回复 —— `invokeMethod` 返回 **null 而不抛**。旧代码据此写下
          // `status: 'success'`：审计里躺着一条**成功的振动**，而机器抖都没抖。
          // 这正是项目红线"静默假成功"的又一形态（与 C-3 `volume.set`、
          // `playHandler` 空转同族）。
          final ack = await native.invokeMethod('vibrate', {'pattern': v.patternMs});
          if (ack == true) {
            await logs.append(
                source: source,
                action: 'vibrate',
                status: 'success',
                taskId: task.id,
                occurrenceId: occurrenceId);
            return const ExecutionOutcome.success();
          } else {
            // 不写成 failed：命令本身没错，是**这个平台没实现这条通道**。
            // 如实标注"平台未确认"，并保留原生回执值以便诊断。
            await logs.append(
                source: source,
                action: 'vibrate',
                status: 'skipped',
                taskId: task.id,
                occurrenceId: occurrenceId,
                message: '平台未确认振动（原生回执=$ack）：本平台可能未实现该通道');
            return ExecutionOutcome.skipped('平台未确认振动（原生回执=$ack）');
          }
        } on Object {
          await logs.append(
              source: source,
              action: 'vibrate',
              status: 'failed',
              taskId: task.id,
              occurrenceId: occurrenceId,
              message: '原生调用失败（桥不可用或被拒绝）');
          return const ExecutionOutcome.failed('原生调用失败（桥不可用或被拒绝）');
        }
      case final RecordEvidenceAction rec:
        return recordAndLog(task, rec.seconds, source);
      // ---- v1.9 振动（docs/20 §4/§7）----
      // 两类都交给 VibrateSession：它负责能力探测、降级明示、分片续发与
      // S1–S4 失效安全。`volume` 在振动语义下是**强度**，`durationMs` 是总时长，
      // 两者都由物化期敲定（"计划即审计"）。
      case final RandomVibrateAction _:
      case final ContinuousVibrateAction _:
        final vStarted = await vibrate.start(
          occurrenceId: occurrenceId ?? '${task.id}@runtime',
          taskId: task.id,
          action: cfg,
          durationMs: durationMs > 0 ? durationMs : 5000,
          amplitude: volume.clamp(0.0, 1.0),
          source: source,
        );
        return vStarted
            ? const ExecutionOutcome.success()
            : const ExecutionOutcome.failed('振动未启动（见审计）');
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
  Future<ExecutionOutcome> runAction(
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
      return ExecutionOutcome.failed(e.toString());
    }
  }

  /// 回投引擎状态。
  ///
  /// [running] 默认 true（从引擎内部广播时它当然在跑），但**停止路径必须
  /// 显式传 false** —— 见 `service.on('stop')`。
  Future<void> broadcast({bool running = true}) async {
    final now = DateTime.now();
    final pending = await occs.pendingCountAfter(now);
    final next = await occs.pendingWithin(now, now.add(const Duration(days: 7)),
        limit: 1);
    service.invoke(
        'state',
        EngineState(
          running: running,
          pendingCount: pending,
          nextFireAt: next.isEmpty ? null : next.first.fireAt,
          lastAction: lastAction,
          guardActive: guard.isRunning,
          guardError: guardError,
          alarmDiag: alarmDiag,
        ).toMap());
  }

  /// 排布通道B（原生精确闹钟）。
  ///
  /// ⚠️ 旧实现是空 `catch`：排布失败**零痕迹**。后果是
  /// "进程被杀之后定时任务不再触发"这件事用户永远发现不了 —— 界面上
  /// 计划照常列出、引擎照常显示运行中，只有真机长时间灭屏后才漏出洞。
  /// 现在区分两种不可排布：**原生明确抛错**（failed）与**平台未回执**
  /// （skipped，iOS/桌面没有这条通道），都写审计。
  ///
  /// ## useAlarmClock（docs/59 缺口1，2026-10）
  /// 默认走 `setAlarmClock` 特权通道（prefs `alarmClockChannel`，默认 true）：
  /// Doze 深度休眠中准时触发、无 9 分钟最小间隔；用户可在设置里关掉
  /// （状态栏闹钟图标观感），关闭即回退 `setExactAndAllowWhileIdle`。
  /// 原生排布失败时会**逐条回退**并在回执 error 中写明降级 ——
  /// 本方法把降级原因如实汇进 `alarmDiag`，不静默。
  Future<void> pushExactAlarms(List<int> times) async {
    final useAlarmClock =
        prefs.getBool(PrefsKeys.alarmClockChannel) ?? true;
    try {
      final res = await NativeBridge.setExactAlarms(times,
          useAlarmClock: useAlarmClock);
      if (res.unsupported && res.scheduled == 0 && res.expected > 0 &&
          res.error == null && !res.denied) {
        // 平台未回执（iOS/桌面/旧版原生无此通道）：与 null 回执同义。
        alarmDiag = '本平台未实现精确闹钟：进程被杀后不再补触发（仅通道A生效）';
        await logs.append(
            source: 'schedule',
            action: 'alarms',
            status: 'skipped',
            message: '原生未回执精确闹钟排布：本平台可能未实现该通道，'
                '进程被杀后不再补触发（仅通道A生效）');
        return;
      }
      // P1-04：解析**结构化结果**。旧实现只看 null/异常，把"权限被拒返回 0"
      // 当成普通成功 —— 界面照常显示运行中与计划数，系统级唤醒却没排上。
      if (res.degraded) {
        alarmDiag = res.reason;
        await logs.append(
            source: 'schedule',
            action: 'alarms',
            status: 'failed',
            message: '精确闹钟降级：${res.reason}'
                '（预期 ${res.expected}，实排 ${res.scheduled}）');
      } else {
        alarmDiag = null;
      }
    } on Object catch (e) {
      alarmDiag = '精确闹钟排布失败（仅通道A生效）：$e';
      await logs.append(
          source: 'schedule',
          action: 'alarms',
          status: 'failed',
          message: '精确闹钟排布失败（仅通道A生效）：$e');
    }
  }

  /// 清除全部原生精确闹钟。
  ///
  /// 与 [pushExactAlarms] 对称：清理失败会留下**过期闹钟**，
  /// 表现为"任务删了 / 引擎关了，到点还是会唤醒一次"。
  Future<void> clearAllAlarms() async {
    try {
      await native.invokeMethod('clearAlarms');
    } on Object catch (e) {
      await logs.append(
          source: 'schedule',
          action: 'alarms',
          status: 'failed',
          message: '清除精确闹钟失败（可能残留过期闹钟）：$e');
    }
  }

  /// 计划续算：物化未来 horizon，幂等提交，并排布原生精确闹钟（通道B）。
  ///
  /// 重入守卫（A2-P0-2）：见 [replanning] 的说明。
  Future<void> replan() async {
    // 与 executeDue 的守卫同形；同样在任何 await 之前同步置位。
    if (replanning) {
      // ignore: avoid_print
      print('[sonic_shield][engine] replan 重入被拒：上一轮续算尚未完成，跳过本次触发');
      return;
    }
    replanning = true;
    try {
      // 设置同步（BUG-082）：本函数是**唯一**读取免打扰窗口 + 夜间豁免主开关
      // 的地方，必须先 `reload()` —— 否则用户在引擎运行期间改的这两项在
      // 本 isolate 里全是旧值（详见 [syncPrefs]）。
      await syncPrefs();
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
        //
        // ⚠️ v79：任务级可**双向覆盖** —— `quietExempt == true`（强制豁免）的任务
        // 在主开关关闭时**仍然豁免**，其计划必须**保留**，不能一并清掉。
        final forceExemptIds =
            all.where((t) => t.quietExempt == true).map((t) => t.id);
        final purged =
            await occs.deletePendingQuietExempt(keepTaskIds: forceExemptIds);
        if (purged > 0) {
          await logs.append(
              source: 'schedule',
              action: 'quietExempt',
              status: 'skipped',
              message: '夜间豁免主开关已关闭，清除 $purged 条待执行的豁免计划（已保留强制豁免例外）');
        }
      }
      final engine = ScheduleEngine(
        quietStartHour: window.start,
        quietEndHour: window.end,
        allowQuietExempt: allowExempt,
      );
      final newEntries = <PlannedEntry>[];
      final taskIds = <String>[];
      for (final t in all) {
        if (t.triggerType == TriggerType.soundTriggered) continue;
        taskIds.add(t.id);
        newEntries.addAll(engine.materialize(t, now));
      }
      // 计划**对账**（P1-05 / P2-03）：把每个任务的**未来 pending** 整体替换为
      // 本轮重算结果。种子只由「任务 id + 定义版本 + 当地日期」决定 ⇒ 未变更的
      // 任务是幂等的；改过触发器/免打扰窗口的任务，其旧幽灵计划在此被撤销。
      // 紧随其后的 `pushExactAlarms` 按新计划重排原生闹钟（两通道不脱节）。
      await occs.reconcile(taskIds, [
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
      ], now);
      if (newEntries.isEmpty) {
        await clearAllAlarms();
        await broadcast();
        return;
      }
      final alarmTimes = newEntries
          .take(SchedulerConfig.maxNativeAlarmsPerTask)
          .map((e) => e.fireAt.millisecondsSinceEpoch)
          .toList();
      await pushExactAlarms(alarmTimes);
      lastAction = 'replan(${newEntries.length} 条计划)';
      await broadcast();
    } finally {
      replanning = false;
    }
  }

  /// **反击计划自动续算**（补线）。
  ///
  /// ## 为什么必须有这一步
  /// 反击任务由 `CounterPlanMaterializer` 物化**未来 7 天**的固定时刻（`days: 7`），
  /// 跑完即尽；而上面的 [replan] 只做**任务级**重算 —— 它用 `ScheduleEngine` 按
  /// **每个已存在任务自己的触发器**排期，**不认识**「反击计划」这个概念，
  /// 因此**无法**生成第 8 天起的新反击任务。
  ///
  /// 而 `CounterPlanService.refreshIfNeeded` 此前**全仓只有定义、无任何生产调用方**
  /// （其 doc 自称"可在 App 启动 / 页面进入 / 引擎 tick 时安全重复调用"，
  /// 但从未接线）⇒ 反击计划在 horizon 用尽后会**悄无声息地停掉**，
  /// 界面上计划仍是"已启用"，却再也不触发 —— 典型的静默失效。
  ///
  /// ## 为什么放在 `replan` 之前
  /// `refreshIfNeeded` 续排只 `upsertMany` **任务**，**计划条目**（occurrences）
  /// 仍要由 [replan] 的 `occs.reconcile` 生成。先续任务、再重算，同一轮即可生效；
  /// 反过来则新任务要等到下一轮 tick 才有条目（空窗 15s）。
  ///
  /// ## 幂等与安全
  /// - `refreshIfNeeded` 内部**先判 horizon**（`minDaysAhead`），够长就直接返回、
  ///   不写库；续排走 `apply(replace: false)` —— **只 upsert，绝不删除**，
  ///   已执行的历史任务原样保留（与 `replace: true` 的整族重建相反）；
  /// - 未启用 / 尚无计划本体 ⇒ 直接返回，不算失败；
  /// - 任何异常只写一条审计，**绝不阻断**引擎主流程（与 [replan] 同一条纪律）。
  Future<void> extendCounterPlan() async {
    // 设置同步（BUG-082）：`CounterPlanStore` 的键（计划本体 / 启用位 /
    // 节假日覆盖表）由 UI isolate 写入 ⇒ 不 reload 就永远读到旧表，
    // 表现为"UI 里启用了反击计划，引擎却不续算"（7 天 horizon 跑完即静默停摆）。
    await syncPrefs();
    final store = CounterPlanStore(prefs);
    if (!store.enabled) return; // 未启用：无事可做，且省掉一次 DB 查询
    final svc = CounterPlanService(
      tasks: tasksRepo,
      store: store,
      resolveAudioIds: (ids) async =>
          resolvePresetAudioIds(await AssetRepository(db).listAll(), ids),
      // 续排落库后立刻重算调度，让新任务的计划条目在同一轮内生成。
      replan: replan,
    );
    final r = await svc.refreshIfNeeded();
    if (r.taskCount > 0) {
      await logs.append(
        source: 'schedule',
        action: 'counterExtend',
        status: 'success',
        message: '反击计划自动续算：${r.message}',
      );
    }
  }

  /// 执行所有到期计划（幂等；带补执行上限与陈旧丢弃）。
  ///
  /// 重入守卫（A2-P0-2）：见 [executing] 的说明。
  Future<void> executeDue() async {
    // 必须在**任何 await 之前**同步置位 —— Dart 单线程，同步置位对同 isolate
    // 的一切重入是原子的（这是守卫成立的前提，不是风格）。
    if (executing) {
      // 不静默吞掉：留 logcat 痕迹（与 `runZonedGuarded` 的自愈日志同渠道）。
      // 刻意**不写审计**：长动作（最长 1800s）期间每 15s 会被拒一次，写审计会把
      // 用户的执行日志刷爆；而本条计划并未失败（首轮仍在跑，由它自己落终态审计），
      // 无任何用户可见降级。
      // ignore: avoid_print
      print('[sonic_shield][engine] executeDue 重入被拒：上一轮仍在执行，跳过本次触发');
      return;
    }
    executing = true;
    try {
      // 设置同步（BUG-082）：下面 `pausedAt()` 读的是全局执行总开关
      // （`runMasterMode`，UI isolate 写入）⇒ 先 reload，改档才能即时生效。
      await syncPrefs();
      final now = DateTime.now();
      final due = await occs.due(now, limit: SchedulerConfig.catchUpLimit);
      // 全局执行总开关（v79，docs/20 §9）：**轮首算一次**，轮内所有到期计划复用。
      // 暂停期间仍逐条落 `skipped`（而非在计划层过滤）—— 换取"窗口一结束下轮 tick
      // 立即恢复执行"与"远程改模式即时生效"，无需任何补算/重建机制。
      final pausedNow = pausedAt(now);
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
        // 全局执行总开关（v79，docs/20 §9）：暂停期间除**显式例外**外一律跳过。
        // 例外以**任务当前配置**为准（`forceRun`），并写审计如实告知"为何没响"。
        if (pausedNow && !task.forceRun) {
          await occs.markStatus(o.id, OccurrenceStatus.skipped);
          await logs.append(
              source: 'schedule',
              action: 'runPause',
              status: 'skipped',
              taskId: task.id,
              occurrenceId: o.id,
              message: '节假日自动暂停中（全局执行总开关），跳过');
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
        // 乐观置状态（A2-P0-2 第二道防线）：`due()` 只筛 `status='pending'`，
        // 而 `runAction` 可阻塞至 1800s。若等它返回再落状态，跨 isolate
        // （原生闹钟唤醒的第二份服务）或守卫失效后的第二次 `due()` 仍会把它
        // 再次取出。因此在执行**之前**先把它标成 `failed`（等价于"已被本次执行
        // 取走"），使并发取出必然落空；执行结束后再按真实结果覆盖为 done/failed。
        //
        // 不引入新状态值：`OccurrenceStatus` 仍是 pending/done/skipped/failed
        // （`task.dart:146`），`fromRow` 的 `values.byName` 与既有断言/持久化完全
        // 兼容；正向语义不变 —— 正常路径下这一行紧接着就被下面那行覆盖。
        await occs.markStatus(o.id, OccurrenceStatus.failed);
        final outcome = await runAction(
            task, o.volume ?? 0.8, o.durationMs ?? 0, 'schedule',
            occurrenceId: o.id);
        // P1-07：终态由**真实执行结果**决定（缺失音源/TTS 超时/录音失败
        // 现在会如实落 failed，不再因 helper 返回 void 而被记成成功）。
        final ok = outcome.ok;
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
              message: '用户豁免免打扰（主开关默认 / 任务级强制）');
        }
      }
      if (due.isNotEmpty) await broadcast();
    } finally {
      // 无论如何都要复位：否则一次异常就会把守卫永久卡死，引擎从此不再执行任何
      // 计划（比原缺陷更糟）。这是「反向断言」锁住的那一点。
      executing = false;
    }
  }

  /// 读取守卫编排配置（v1.10）。
  ///
  /// 存 `kv` 而**不是**给 `sound_profiles` 加列：加列要走 DB 迁移
  /// （`lib/data/db/app_database.dart`），而 kv 是既有的通用键值表 ——
  /// 不动 schema 就不会引入"老库缺列"那一类事故。
  /// 每轮重读（不缓存）：用户在引擎运行期间改配置，下一次事件即生效。
  Future<GuardOrchestration> loadGuardOrchestration() async =>
      GuardOrchestration.decode(await db.kvGet(guardOrchestrationKey));

  /// 执行一次守卫计划（立即路径与延时路径**共用**，避免两条实现漂移）。
  Future<void> runGuardPlan(GuardPlan plan, DateTime at) async {
    final all = await tasksRepo.listAll(enabledOnly: true);
    // 计划里的 id 可能已被删除/停用：**跳过并留痕**，不拿别的任务顶上
    // （与 BUG-059「点名了就必须满足」同一判据）。
    final byId = {for (final t in all) t.id: t};
    for (final id in plan.taskIds) {
      final t = byId[id];
      if (t == null) {
        await logs.append(
            source: 'sound',
            action: 'guardPlan',
            status: 'skipped',
            taskId: id,
            message: '计划中的任务已不存在或已停用，已跳过（不改播其它任务）');
        continue;
      }
      // 概率门已在 onSoundEvent 的候选裁决（admitExecution）中生效；
      // 此处只执行并如实落终态（P1-07）。
      final occId = '${t.id}@sound@${at.millisecondsSinceEpoch}';
      final outcome =
          await runAction(t, 0.8, 0, 'sound', occurrenceId: occId);
      await occs.commitAll([
        PlannedOccurrence(
          id: occId,
          taskId: t.id,
          fireAt: at,
          status: outcome.isFailure
              ? OccurrenceStatus.failed
              : OccurrenceStatus.done,
        ),
      ]);
    }
    await broadcast();
  }

  /// 声音事件 -> 执行守卫计划。
  ///
  /// v1.10 编排增强（`GuardOrchestration`）只补三件事：
  /// **候选子集 / N 选一随机 / 延时执行**；动作内容仍完全由任务自己的动作层
  /// （`assetIds` 多音频随机、`ActionSetAction` 多动作加权随机、概率门）决定。
  Future<void> onSoundEvent(DateTime at, double peakDb) async {
    final all = await tasksRepo.listAll(enabledOnly: true);
    // 本轮环境快照：本次声音事件会遍历**所有**声音触发任务，
    // 同样只读一次平台状态（与 executeDue 同理）。
    final env = RoundConditionEnv(read: readConditionEnv);

    // 第一步：先算出**真正够格**的候选（冷却 + 条件 + 概率都通过），
    // 再交给编排决策 —— 否则"随机挑一个"可能挑中一个本来会被跳过的任务。
    final ready = <String>[];
    for (final t
        in all.where((t) => t.triggerType == TriggerType.soundTriggered)) {
      final cfg = t.trigger as SoundTrigger;
      final last = await occs.lastDoneFor(t.id);
      final cooldown =
          Duration(seconds: math.max(cfg.cooldownSec, t.cooldownSec));
      if (last != null && at.difference(last) < cooldown) continue;
      // P1-07：声音入口此前**绕过概率门**（只有定时入口有）——改用统一裁决
      // 管线（条件 → 概率），与 executeDue / 远程立即执行同判据。
      final denied = await admitExecution(t, await env.value, 'sound');
      if (denied != null) continue;
      ready.add(t.id);
    }

    final config = await loadGuardOrchestration();
    final plan = resolveGuardPlan(
      candidateIds: ready,
      config: config,
      rng: math.Random(),
    );

    // 点名了却一个都不在候选里 ⇒ 明确留痕，不静默（BUG-059 判据）。
    if (plan.isEmpty && config.taskIds.isNotEmpty) {
      await logs.append(
          source: 'sound',
          action: 'guardPlan',
          status: 'skipped',
          message: '编排点名的 ${config.taskIds.length} 个任务都不在本次候选中'
              '（已删除/停用/冷却中/条件不满足），本次不执行任何动作');
      await broadcast();
      return;
    }
    if (plan.isEmpty) {
      await broadcast();
      return;
    }

    // 随机决策必须可回溯："为什么这次响的是它"。
    if (config.pick == GuardPickMode.randomOne) {
      await logs.append(
          source: 'sound',
          action: 'guardPlan',
          status: 'success',
          taskId: plan.taskIds.first,
          message: '候选 ${ready.length} 个 → 随机选中 ${plan.taskIds.first}');
    }

    // 延时执行：先留痕，再排定一个**可取消**的定时器。
    if (plan.delayMs > 0) {
      await logs.append(
          source: 'sound',
          action: 'guardDelay',
          status: 'success',
          message: '检测到声音事件（${peakDb.toStringAsFixed(1)} dBFS），'
              '${plan.delayMs ~/ 1000}s 后执行 ${plan.taskIds.length} 项');
      guardDelayTimer?.cancel();
      guardDelayTimer = Timer(Duration(milliseconds: plan.delayMs), () {
        guardDelayTimer = null;
        // 延时窗口内守卫可能已被关闭（`service.on('guard')` 会取消本定时器）；
        // 这里再查一次 `guardEnabled` 做双保险，绝不在用户说"关"之后出声。
        if (!guardEnabled) return;
        unawaited(runGuardPlan(plan, DateTime.now()));
      });
      await broadcast();
      return;
    }

    await runGuardPlan(plan, at);
  }

  // ==================== UI -> 服务 消息 ====================

  /// 守卫采流异常（麦克风被抢占 / 录音器崩溃）：**写审计 + 回投原因**。
  ///
  /// 守卫端已把 `isRunning` 置 false（停止方向走安全侧，没有"还在采"的风险），
  /// 缺的只是"为什么"。不在这里做任何自愈重试：重试一个刚失败的录音器
  /// 只会让用户在不知情的情况下反复经历"守卫开了又关"。
  Future<void> onGuardStreamError(Object e) async {
    guardError = '守卫已停止：采流异常（$e）';
    await logs.append(
        source: 'guard',
        action: 'stream',
        status: 'failed',
        message: '采流中断，守卫已停止：$e');
    await broadcast();
  }

  /// 装配动态反击的动作池（v2.0 阶段 D；2026-10 起**只含噪音音效**）。
  ///
  /// ## 为什么不再有 TTS（产品决策）
  /// 可识别语音会暴露反击意图、取证价值低，与「不可预测」目标相反；
  /// 一律随机音效（"尤其是噪音"）。`CounterAction.tts` 构造保留（远端协议
  /// 兼容），但本池不再放入任何 TTS 动作。
  ///
  /// ## 素材库为空怎么办（自愈，2026-10）
  /// 以前库空 ⇒ 退化纯 TTS 池；没有 TTS 后库空 = 反击彻底空转。改为：
  /// 库空时先**自动导入内置预置库**（`importBundledPresets`，幂等），
  /// 再 resolve —— 用户不必记得先去「音源库」点导入。导入失败（如磁盘满）
  /// 不抛：返回空池，由调用方给用户如实提示（守卫照常运行，只是没反击）。
  Future<List<CounterAction>> buildReactivePool() async {
    final repo = AssetRepository(db);
    var assets = await repo.listAll();
    if (assets.isEmpty) {
      try {
        await importBundledPresets(
          existingNames: repo.nameSet,
          saveAll: repo.upsertMany,
          removeFile: (p) async {
            final f = File(p);
            if (await f.exists()) await f.delete();
          },
        );
        assets = await repo.listAll();
      } on Object catch (e) {
        await logs.append(
          source: 'reactive',
          action: 'pool',
          status: 'failed',
          message: '预置噪音库自动导入失败（反击将无动作可用）：$e',
        );
      }
    }
    final pool = <CounterAction>[];
    try {
      final ids = resolvePresetAudioIds(assets, CounterPlan.defaultPresetIds);
      final byId = {for (final a in assets) a.id: a};
      for (final id in ids) {
        final a = byId[id];
        if (a != null && a.path.isNotEmpty) {
          pool.add(CounterAction.audio(a.path));
        }
      }
    } on Object {
      // 素材库读取失败不该让动态反击整条失效：留空池 + 下面的日志说明。
    }
    if (pool.isEmpty) {
      await logs.append(
        source: 'reactive',
        action: 'pool',
        status: 'failed',
        message: '反击动作池为空：音源库没有可用噪音（请到「音源库」导入预置库）',
      );
    }
    return pool;
  }

  /// 启动动态反击（复用守卫的麦克风通路；本服务自身不采音）。
  ///
  /// 守卫没跑 ⇒ **不启动**：没有声音事件来源，装了也只是空转。
  Future<void> startReactiveCounter() async {
    if (!guard.isRunning) return;
    final pool = await buildReactivePool();
    reactive = ReactiveCounterService(
      pool: pool,
      playAudio: ({
        required String path,
        required double volume,
        required int durationMs,
      }) =>
          playback.play(
              path: path,
              channel: AudioChannel.media,
              volume: volume,
              maxDurationMs: durationMs),
      speak: (text, {required String voiceId, required double volume}) =>
          TtsService(
        speakSystem: speakSystemTts,
        speakNeural: _speakNeuralTts,
        speakOnline: (t, v, name) =>
            speakOnlineTts(t, v, name, ApiConfigStore(prefs)),
      ).say(text, voiceId: voiceId, volume: volume),
      // 审计过滤：**只持久化反击决策**（counter/success|failed|skipped），
      // 原始的 "观察到一次声音"（observed/ignored）只留内存记录 —— 否则
      // 7×24 常驻下 exec_logs 会被每次环境声响淹没（内存记录仍在，满足"尽量记录"）。
      audit: ({required String action, required String status, String? message}) async {
        if (action != 'counter') return;
        await logs.append(
            source: 'reactive', action: action, status: status, message: message);
      },
    )..start();
  }

  /// 撤下动态反击：停 realtime counter **并整族清场物化的反击计划任务**。
  ///
  /// ## 为什么必须联动（2026-10-15 BUG：「关闭后依然有效」）
  /// 反击计划（CounterPlan）物化出的 `counter:{planId}:{…}` 任务是**独立的
  /// fixedOnce 任务**，与 `reactiveCounterEnabled` 开关无关 —— 只停 realtime
  /// counter，计划任务照常按时刻触发，用户看到的就是"关了还在响"。
  ///
  /// 清场 = [CounterPlanService.disable]：按前缀整族删除计划任务（外键
  /// CASCADE 带走未执行 occurrences）+ `store.enabled = false`。此后 tick 的
  /// `extendCounterPlan → refreshIfNeeded` 首行 `if (!_store.enabled) return`
  /// 即被挡死，不会再续算。计划本体保留在 prefs 里，用户重新开启时可恢复。
  ///
  /// ## 失败不可静默
  /// 撤下 realtime 与清场计划任务是两件事：前者已停、后者失败 ⇒ "关了一半"，
  /// 必须落审计（UI 的守卫页/日志页可见），不许假装全关。
  Future<void> stopReactiveCounter() async {
    reactive?.stop();
    reactive = null;
    try {
      final store = CounterPlanStore(prefs);
      final svc = CounterPlanService(
        tasks: tasksRepo,
        store: store,
        replan: replan,
      );
      final r = await svc.disable();
      await logs.append(
        source: 'guard',
        action: 'reactiveCounterOff',
        status: 'success',
        message: '动态反击已关闭：${r.message}',
      );
    } on Object catch (e) {
      await logs.append(
        source: 'guard',
        action: 'reactiveCounterOff',
        status: 'failed',
        message: '动态反击已停，但反击计划任务清场失败（可能仍在触发）：$e',
      );
    }
  }

  service.on('replan').listen((_) => unawaited(replan()));
  service.on('tick').listen((_) => unawaited(executeDue()));
  // 电源模式热切换（v1.9.1）：设置页改档 → 引擎即时应用副作用（常驻唤醒锁）。
  // 与 `reactive` 同为"UI 改设置 → 引擎即时响应"，无需重启引擎。
  service.on('powerMode').listen((m) async {
    final mode = (m?['mode'] as String?) ?? 'balanced';
    await applyPowerMode(mode);
    await broadcast();
  });
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
      guardError = started.message;
      if (started.ok) {
        await guardSub?.cancel();
        guardSub = guard.events.listen((e) {
          unawaited(onSoundEvent(e.detectedAt, e.peakDb));
          // 动态反击复用**同一条**声音事件流（不新建录音器）。
          final rc = reactive;
          if (rc != null) unawaited(rc.onSound(e));
        });
        await guardErrSub?.cancel();
        guardErrSub = guard.errors.listen((e) {
          unawaited(onGuardStreamError(e));
        });
        // 守卫拿到流后，若用户已开启动态反击则装配它。守卫是动态反击的
        // **唯一声音来源**，所以装配时机只能是"守卫确实启动成功"之后。
        if (prefs.getBool(PrefsKeys.reactiveCounterEnabled) ?? false) {
          await startReactiveCounter();
        }
      }
      await logs.append(
          source: 'guard',
          action: 'start',
          status: started.ok ? 'success' : 'failed',
          // ⚠️ 失败原因**原样**入库：UI 也要拿到同一条文本（经 `guardError`），
          // 两侧文案同源，避免"日志里写着权限、界面说引擎无响应"。
          message: started.message);
    } else {
      guardError = null;
      // 先撤延时计划：用户说"关"，就不能再有任何已排定的声音。
      guardDelayTimer?.cancel();
      guardDelayTimer = null;
      await guardSub?.cancel();
      guardSub = null;
      await guardErrSub?.cancel();
      guardErrSub = null;
      // 守卫停 ⇒ 声音来源停 ⇒ 动态反击必须一并停（否则静默反制定时器
      // 会在无输入的情况下继续自主出声）。连带清场物化的反击计划任务
      // （BUG：只停 realtime 的话计划任务照常触发）。
      await stopReactiveCounter();
      await guard.stop();
      // 关闭也要留痕（对称）：否则"关了但没关掉"在日志里完全无迹可寻。
      await logs.append(
          source: 'guard', action: 'stop', status: 'success');
    }
    await broadcast();
  });
  // 动态反击热切换（v2.0 阶段 D）：UI 开关 → 引擎即时装配/撤下，
  // 不必重启守卫。守卫没跑时只落 prefs（下次守卫启动自动装配）。
  //
  // ⚠️ 关闭 = [stopReactiveCounter]：除停 realtime counter 外，还整族删除
  // 物化的 `counter:*` 计划任务并禁用计划续算 —— 否则"关了还在响"
  // （2026-10-15 BUG，计划任务与 realtime 开关是两套东西）。
  service.on('reactive').listen((m) async {
    final on = (m?['enabled'] as bool?) ?? false;
    await prefs.setBool(PrefsKeys.reactiveCounterEnabled, on);
    if (on) {
      if (guard.isRunning) await startReactiveCounter();
    } else {
      await stopReactiveCounter();
    }
    await broadcast();
  });
  service.on('stop').listen((_) async {
    guardDelayTimer?.cancel();
    guardDelayTimer = null;
    await stopReactiveCounter();
    await guardSub?.cancel();
    guardSub = null;
    await guardErrSub?.cancel();
    guardErrSub = null;
    await guard.stop();
    await playback.stop();
    // P2-15：**对称撤下**麦克风前台服务通行证。`MicGuardService` 是独立
    // sticky service，而 Dashboard 关闭引擎走的是 `mgr.stop()` —— 若只停
    // Dart 层守卫，原生 FGS 与常驻通知会残留（dumpsys 可见），与"引擎已关"
    // 的界面语义不一致。同时清掉 `guard_enabled`：通行证已被撤，若还持久化
    // "下次自启守卫"，下次引擎启动会在**没有前台通行证**的情况下尝试采音
    //（违反 Android 11+ while-in-use），必然失败并报错 —— 停止方向走安全侧，
    // 守卫须由用户在前台显式重新开启（届时会重新申请通行证）。
    guardEnabled = false;
    await prefs.setBool('guard_enabled', false);
    try {
      await native.invokeMethod('stopMicService');
    } on Object catch (e) {
      await logs.append(
          source: 'guard',
          action: 'micService',
          status: 'failed',
          message: '停止麦克风前台服务失败（可能残留守卫通知）：$e');
    }
    // P1-03：**对称撤销**原生精确闹钟。旧实现只停 Dart 层守卫/播放器就
    // `stopSelf()`，AlarmManager 里排定的闹钟仍在 ⇒ 到点由
    // `AlarmWatchdogReceiver` 重新拉起前台服务并执行到期任务 ——
    // 用户以为"已关闭"，系统却再次运行。这里与 start/replan 的排布路径对称清理，
    // 并由看门狗接收器在拉起前再校验启用态/代次（双保险）。
    await clearAllAlarms();
    // v1.9.1：释放性能优先档的常驻唤醒锁 —— **对称**撤下，不把"持续耗电"这个
    // 副作用留给"已停止"状态（否则用户关了引擎，CPU 仍被本应用钉住不放）。
    await applyPowerMode('balanced');
    // ⚠️ **必须在 `stopSelf()` 之前回投 `running:false`**。
    // 旧实现从不回投停止状态，且 `broadcast()` 把 `running` 写死成 `true` ⇒
    // UI 的 `isRunning` 永远停在 true（引擎已经死了，再没人能广播），
    // 表现为"引擎开关**开了关不掉**"（真机 MI MAX 2 / API 25，BUG-B）。
    await broadcast(running: false);
    // `invoke` 只是把消息交给平台通道：给它一次事件循环的机会送出去，
    // 再杀自己。不加这一句，最后一条状态可能随 isolate 一起消失。
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await service.stopSelf();
  });

  /// 远程 `vibrate.stop`（v1.9，docs/20 §11.2）：停止**全部**进行中的振动。
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
    if (taskId == null || taskId.isEmpty) {
      // ⚠️ 缺参数也必须回执：直接 `return` 会让发送端一直等到超时，
      // 只得到一句"引擎执行超时"，而真实原因是"这条命令没带任务 id"。
      await logs.append(
          source: 'remote',
          action: 'runNow',
          status: 'failed',
          message: '远程立即执行缺少 taskId，已拒绝');
      service.invoke('rcRunResult', {
        'reqId': reqId,
        'taskId': taskId ?? '',
        'ok': false,
        'message': '缺少 taskId：引擎无法执行',
      });
      return;
    }
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
          // P1-07：远程立即执行也必须过**概率门**（此前只有定时入口有）——
          // 否则"设了 30% 概率"对远程点击毫无约束。
          final gateFail = probabilityGateMissed(task);
          if (gateFail != null) {
            message = '概率未命中：$gateFail';
            await logs.append(
                source: 'remote',
                action: 'probability',
                status: 'skipped',
                taskId: task.id,
                message: gateFail);
            await occs.commitAll([
              PlannedOccurrence(
                id: '${task.id}@remote@${DateTime.now().millisecondsSinceEpoch}',
                taskId: task.id,
                fireAt: DateTime.now(),
                status: OccurrenceStatus.skipped,
              ),
            ]);
          } else {
            // 物化期的音量/时长由调度器确定；远程立即执行取动作区间中点，
            // 保持"计划即审计"语义（volume/duration 落库到 occurrence）。
            final (vol, dur) = _nominalParams(task);
            final outcome = await runAction(task, vol, dur, 'remote');
            // P1-07：回执区分真实成败（缺音源/TTS 超时不再回"已执行"）。
            ok = outcome.ok;
            message = ok ? '已执行' : (outcome.reason ?? '执行失败');
            await occs.commitAll([
              PlannedOccurrence(
                id: '${task.id}@remote@${DateTime.now().millisecondsSinceEpoch}',
                taskId: task.id,
                fireAt: DateTime.now(),
                status: outcome.isFailure
                    ? OccurrenceStatus.failed
                    : OccurrenceStatus.done,
                volume: vol,
                durationMs: dur,
              ),
            ]);
            lastAction = '${task.name} · 远程立即执行';
          }
        }
      }
    } on Object catch (e) {
      message = e.toString();
      // 远程路径的异常也要落本机审计：`rcRunResult` 只回给发送端一次，
      // 本机日志里没痕迹的话，"远程点了一下没反应"事后完全无法排查。
      await logs.append(
          source: 'remote',
          action: 'runNow',
          status: 'failed',
          taskId: taskId,
          message: '远程立即执行异常：$e');
    }
    service.invoke('rcRunResult', {
      'reqId': reqId,
      'taskId': taskId,
      'ok': ok,
      'message': message,
    });
    await broadcast();
  });

  /// 远程指令组里的**振动步骤**（v1.9，docs/20 §11.1）。
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
    unawaited(stepGuarded('executeDue(tick)', executeDue));
    unawaited(() async {
      // 先**续算反击计划**（幂等；未启用时只读一次 prefs 即返回），再重算任务级计划。
      // 顺序不可颠倒：续排只写 `tasks`，计划条目由下面的 `replan` 的
      // `occs.reconcile` 生成（`extendCounterPlan` 内部已带一次 `replan`，
      // 故续排成功后 `pending` 变大、下面这次 `replan` 会被阈值自然跳过 —— 不重复劳动）。
      await stepGuarded('extendCounterPlan(tick)', extendCounterPlan);
      final pending = await occs.pendingCountAfter(DateTime.now());
      if (pending < SchedulerConfig.planExtendThreshold.inHours) {
        await stepGuarded('replan(tick)', replan);
      }
    }());
  });

  // 启动即补执行 + 续算（通道B 唤醒后同样走这里）。
  //
  // ⚠️ **每一步都必须独立兜底**，因为它们串在同一个 async 体里：
  // 任何一步抛出去，它**下面**的代码就再也不会执行 —— 而 UI 的"引擎在跑"
  // 完全依赖本函数末尾那一次 `broadcast()`。
  //
  // 真机实证（Mi 14 Pro / Android 16，logcat `[sonic_shield][engine] unhandled:`）：
  // 老库缺列 `occurrences.quiet_exempt` ⇒ `replan()` 抛
  // `DatabaseException(no such column: quiet_exempt)` ⇒ 整个 body 中断 ⇒
  // **引擎永远不广播状态** ⇒ UI 的 `isRunning` 恒为 false ⇒
  // 「守护」页引擎开关与「守卫」页守卫开关**都打不开**，且页面零解释（BUG-A）。
  await stepGuarded('executeDue', executeDue);
  // 「动态反击」开关是反击计划任务的**存在前提**：本机关着 ⇒ 开机即清场。
  // 自愈场景（2026-10 BUG）：引擎未运行时用户关开关 → invoke 无人受理 →
  // store 仍启用、库里残留物化任务 → 旧版本引擎重启后照常触发。
  // 开着时为 no-op；这一步还顺带把自己曾经的漏关现场补清。
  if (!(prefs.getBool(PrefsKeys.reactiveCounterEnabled) ?? false)) {
    await stepGuarded('stopReactiveCounter(boot)', stopReactiveCounter);
  }
  // 反击计划续算必须**排在 replan 之前**（同 tick 内的理由）：续排只写任务，
  // 计划条目由紧随其后的 `replan` 生成。
  await stepGuarded('extendCounterPlan', extendCounterPlan);
  await stepGuarded('replan', replan);
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
