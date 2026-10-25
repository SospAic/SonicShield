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
import '../domain/scheduling/guard_orchestration.dart';
import '../domain/scheduling/run_pause.dart';
import '../domain/scheduling/schedule_engine.dart';
import '../domain/scheduling/vibrate_resolve.dart';
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
///
/// 引擎启动链步骤落盘（R89 遗迹，固化为常驻诊断）。
///
/// 为什么用文件而不是 `print` / `service.invoke`：
/// ① 后台 isolate 的 `print` 在部分设备上进不了 logcat（R89 真机实证：
///    模拟器上引擎侧 print 完全不可见），而"引擎静默死亡 → 开关零提示"
///    恰恰是最需要留痕的故障形态；
/// ② `service.invoke` 通道本身曾是待查嫌疑（v3–v7 探针的 dbg 标记从未
///    到达主 isolate），必须有一条**不经过它**的独立取证通道。
/// `Directory.systemTemp` 同步可写、无插件依赖；失败绝不阻断启动。
/// 最后落盘的那一行即死点定位。
void _diagStep(String step) {
  try {
    final f = File('${Directory.systemTemp.path}/r89_engine_diag.txt');
    // R90-24：**有界轮转**。引擎每次启动都会写几行，长期运行（每天启停数次）
    // 会让这个诊断文件无限增长。超过 256KB 就滚到 `.1`（只保留一代）——
    // 诊断只需要"最近一次启动/死亡"，历史没有保留价值。
    try {
      if (f.existsSync() && f.lengthSync() > 256 * 1024) {
        final bak = File('${f.path}.1');
        if (bak.existsSync()) bak.deleteSync();
        f.renameSync(bak.path);
      }
    } on Object {
      // 轮转失败不影响写入（继续追加即可）。
    }
    f.writeAsStringSync('${DateTime.now().toIso8601String()} $step\n',
        mode: FileMode.append, flush: true);
  } on Object {
    // 诊断写失败不影响主流程。
  }
}

@pragma('vm:entry-point')
Future<void> engineEntryPoint(ServiceInstance service) async {
  // 第一件事就是留痕（同步文件写、无插件依赖）：后续任何一步挂掉，
  // 最后落盘的那一行就是死点。
  _diagStep('m0-entry');
  await runZonedGuarded(() async {
    try {
      DartPluginRegistrant.ensureInitialized();
      _diagStep('m1-registrant');
    } on Object catch (e) {
      _diagStep('m1-ERR:$e');
      rethrow;
    }
    await _engineBody(service);
  }, (e, stack) {
    _diagStep('m-2-unhandled:$e');
    // 🔴 R89：**启动期失败绝不能静默**。
    //
    // 现场形态（1.9.6+29 用户报障「点守护总开关 → 开关不动、零提示」）：
    // `mgr.start()` 早已向调用方返回 **true**（原生 FGS 确实起来了），
    // 而引擎 Dart 侧在启动序列中途死亡 ⇒ 没有任何 state 回投 ⇒ 首页
    // 开关只认回投状态，永远停在"关"，用户感知就是"点了完全没反应"。
    //
    // 三层收口（仅启动期，`_engineBootstrapDone` 之前的失败才做）：
    // ① 回投 `running:false`：开关如实落"关"，不假装在跑；
    // ② `stopSelf()`：撤掉已空转的前台服务 —— 否则原生侧
    //    "Service already running" 会让用户下一次点击永远空转，
    //    永远等不到一次**全新的**启动；
    // ③ 真实原因进日志（logcat 可见），不吞。
    if (!_engineBootstrapDone) {
      try {
        service.invoke('state', <String, Object?>{'running': false});
      } on Object {
        // 回投失败不改变主判据。
      }
      try {
        unawaited(service.stopSelf());
      } on Object {
        // 停机失败不改变主判据。
      }
      // ignore: avoid_print
      print('[sonic_shield][engine] 启动失败（引擎已退出）：$e\n$stack');
    } else {
      // 运行期晚发错误：tick 各步骤已有 stepGuarded 逐层兜底，
      // 这里只留痕，不再推翻一个已经注册完毕的引擎。
      // ignore: avoid_print
      print('[sonic_shield][engine] unhandled: $e');
    }
  });
}

/// R89：引擎 bootstrap 是否已完成（handler 注册 + 首次广播结束）。
///
/// zone 处理器据此区分「启动期失败」（必须收口：广播停机 + 撤 FGS，见
/// [engineEntryPoint]）与「运行期晚发错误」（stepGuarded 已兜底，只留痕）。
bool _engineBootstrapDone = false;

Future<void> _engineBody(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  _diagStep('m1-registrant');

  /// 🔴 R90-06（2026-10-19）：**停机中**闸门。
  ///
  /// 现场形状：stop 清理链里有多段 `await`（守卫停止 2s 超时、写库、两次
  /// `broadcast`、末尾 150ms 延迟），期间 15s 的 `Timer.periodic` **仍在跑**：
  /// ① `clearAllAlarms()` 之后被并发 `replan → pushExactAlarms` 重排闹钟；
  /// ② `broadcast(running:false)` 之后被 tick 内的 `broadcast()` 覆盖 ⇒ UI
  ///    开关卡在"已开启"；③ `playback.stop()` 之后被并发 `executeDue` 重新起播
  ///    ⇒ 用户停了引擎仍在出声。
  ///
  /// 本闸门在 stop 处理器**第一条语句**同步置位（Dart 单线程，同步置位对
  /// 同 isolate 的一切重入原子），tick / executeDue / replan / pushExactAlarms
  /// 全部先查。**不在 `stopSelf` 前复位**：引擎即将退出，任何新工作都没有意义。
  ///
  /// R94 / SCH-15 补：`stopSelf()` **失败**时它会在 30 秒后复位
  /// （[armStoppingRecovery]）—— 否则引擎成为僵尸（FGS 通知还在、tick 全
  /// `return`、原生 `isRunning` 仍为 true ⇒ 用户再点开启只会得到
  /// "Service already running"，开关永久假死）。
  ///
  /// ⚠️ 声明必须提到 `AppDatabase.open()` **之前**：ARCH-05 的
  /// 「用户已关闭守护」闸门要在碰数据库/插件之前就生效（见下）。
  bool stopping = false;

  // 🔴 R94 / ARCH-05：**关机闸门**。
  //
  // 现场：原生 `AlarmWatchdogReceiver` 会在闹钟到点时拉起前台服务（它已校验
  // `should_run` 与代次），但**普通重启 / 系统回收后自启 / 用户先关后秒开**
  // 这几条路径仍可能拉起一个"用户已经关掉"的引擎 —— 一旦拉起，它会做完整套
  // 副作用（打开数据库、保留策略清理、排布精确闹钟、恢复守卫采音）。
  // 用户看到的却是"我明明关了"。
  //
  // 判据取原生持久化的 `should_run`（用户开关的权威真源，与看门狗同一份），
  // 且**在读数据库之前**判定：不该运行的引擎连库都不该碰。
  //
  // 失败方向：**只有明确读到 false 才停机**。
  // - 通道不可用（iOS / 桌面：`lastNativeError != null`）⇒ 视为"该运行"，
  //   否则会把整条非 Android 通路直接锁死；
  // - 抛异常同样视为"该运行"（fail-open）：宁可多跑一次，也不能让一次
  //   平台抖动把引擎永久关在门外。
  var shouldRun = true;
  try {
    final flag = await NativeBridge.serviceShouldRun();
    if (NativeBridge.lastNativeError == null) shouldRun = flag;
  } on Object {
    shouldRun = true;
  }
  if (!shouldRun) {
    // 同步置位：后面任何异步工作（若有）都进不去。
    stopping = true;
    _diagStep('m1b-should-run-false');
  }

  // 🔴 R89：数据库打开失败**不许杀死引擎**。
  //
  // 双引擎（主 UI + 后台服务）并发打开同一新库时，sqflite 的 onCreate
  // 只判 `user_version == 0`、不判表存在性 —— 败者连接会撞上胜者刚提交
  // 的 `CREATE TABLE` 抛 `DatabaseException(table tasks already exists)`
  // （R89 真机实证，详见 `AppDatabase._onCreate` 的注记）。幂等建表
  // （IF NOT EXISTS）已经消掉主因；这里再给**一次有界重试**兜底：
  // 败者重试时胜者的版本号已提交，第二次打开会直接跳过 onCreate。
  AppDatabase db;
  try {
    db = await AppDatabase.open();
  } on Object catch (e) {
    _diagStep('m2-db-open-ERR:$e');
    // ignore: avoid_print
    print('[sonic_shield][engine] 数据库打开失败，500ms 后重试一次：$e');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    db = await AppDatabase.open();
  }
  final tasksRepo = TaskRepository(db);
  final occs = OccurrenceRepository(db);
  final logs = LogRepository(db);
  _diagStep('m2-db-open');

  // ARCH-05 收口：用户已关闭守护 ⇒ 写一条审计后立即撤下前台服务。
  // 审计需要数据库（所以放在 open 之后），但**放在一切副作用之前**：
  // 保留策略清理、电源模式、守卫自恢复、闹钟排布都不得执行。
  if (!shouldRun) {
    try {
      await logs.append(
        source: 'engine',
        action: 'shouldRun',
        status: 'skipped',
        message: '用户已关闭守护（should_run=false）：本次唤醒不提供服务，'
            '不重排计划、不恢复守卫',
      );
    } on Object {
      // 审计写不进也要停机（安全侧是"别跑"，不是"别留痕"）。
    }
    try {
      await service.stopSelf();
    } on Object catch (e) {
      _diagStep('m2b-should-run-stopSelf-ERR:$e');
    }
    return;
  }

  // P2-10：保留策略维护（docs/07 §4「数据生命周期」）。两个 `purgeOlderThan`
  // 此前只有定义、无生产调用入口 —— 长期运行会让日志与历史计划只增不减。
  // 每次引擎启动跑一次即可：清理是**幂等**的（已删的再判一次为 0），且引擎
  // 只在守护开启/看门狗唤醒时启动，天然形成"低频维护"节奏。
  // 维护不是核心执行路径 —— 失败只留一条审计，**绝不阻断引擎启动**。
  try {
    final removed =
        await RetentionMaintenance(
          logs: logs,
          occurrences: occs,
          // R90-23：单步清理失败必须留痕（否则历史计划只增不减且无人知道）。
          onError: (e) => unawaited(logs.append(
            source: 'maintenance',
            action: 'retention',
            status: 'failed',
            message: '保留策略清理单步失败（另一步不受影响）：$e',
          )),
        ).run();
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

  _diagStep('m3-retention');

  // 🔴 R94 / SCH-04：**启动自愈**上一次进程中断留下的 `running` 占用行。
  //
  // `running` 是"某条连接已抢占、正在执行动作"的占用态（F3 新增）。执行者若在
  // `runAction` 期间被杀（系统回收后台服务 / 崩溃 / 用户强杀），那一行会**永久**
  // 停在 `running`：`due()` 只看 `pending` ⇒ 它永远不会再被执行，也不会有任何
  // 审计 —— 用户看到的是"那次没响，日志里什么都没有"。
  //
  // 放在 retention **之后**：清理先跑（它按 `status != 'pending'` 删历史，与本次
  // 自愈不冲突），避免刚改完状态又被 7 天阈值规则判定。条数 > 0 时必须留痕，
  // 否则"上次崩过"这件事只有数据库知道。
  try {
    final interrupted = await occs.recoverInterrupted();
    if (interrupted > 0) {
      await logs.append(
        source: 'schedule',
        action: 'interrupted',
        status: 'failed',
        message: '上次进程中断：$interrupted 条「执行中」计划已标记为失败'
            '（不自动补执行，避免重启后突然补响）',
      );
    }
  } on Object catch (e) {
    // 自愈失败不阻断启动，但必须留痕（否则下一次也会静默留在 running）。
    await logs.append(
      source: 'schedule',
      action: 'interrupted',
      status: 'failed',
      message: '启动自愈失败（残留「执行中」计划可能永远不再执行）：$e',
    );
  }

  final playback = PlaybackService();
  final guard = SoundGuardService();
  const native = MethodChannel(Channels.method);
  final battery = Battery();
  final prefs = await SharedPreferences.getInstance();
  _diagStep('m4-prefs');

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

  // 🔴 R94 / ARCH-11：**先同步，再读设置**。
  //
  // `SharedPreferences` 在 Dart 侧按 isolate 缓存（BUG-082）：本 isolate 的
  // 首次 `getInstance()` 就把整份 KV 读进内存，之后 UI isolate 的任何写入都
  // 看不到。旧实现在这里**先**读了 `powerMode` / `guardEnabled`，然后才在
  // 各个业务入口 `syncPrefs()` —— 于是"启动瞬间读到的两个设置"永远是
  // 上一次启动时的快照：用户在引擎运行期间改了电源策略/守卫开关，重启引擎后
  // 第一轮仍按旧值执行（守卫会被自动重新拉起，而用户明明关掉了它）。
  //
  // 现在把同步提前到**任何设置读取之前**，启动序列与运行期口径一致。
  await syncPrefs();

  /// 应用电源模式副作用（v1.9.1 新增）：**仅** `performance` 档持有常驻唤醒锁。
  ///
  /// 背景：此前 `power_mode` 是**死设置** —— 设置页写入、`setPowerMode` 发
  /// `powerMode` invoke，但引擎里**没有接收方**、全仓也无人读取 ⇒ 电源模式对运行时
  /// **零影响**（BUG-070「写在一处、用在另一处」同族）。本函数补上唯一副作用：
  /// 性能优先 = 持 `PARTIAL_WAKE_LOCK`（锁屏 / Doze 不冻结 CPU，通道 A 持续跑）；
  /// 平衡 / 省电 = 释放，退回"仅通道 B 精确闹钟"的默认保活。
  /// 当前生效的电源模式（NAT-07：决定任务结束后要不要显式释放唤醒锁）。
  ///
  /// `performance` 档的锁是**常驻**的（由用户显式选择、代价是耗电），
  /// `balanced` / `saver` 档只允许"按需持锁、用完即放" —— 这两档若把锁留到
  /// 下一次切档，等于把"平衡模式不持续耗电"的产品承诺悄悄破坏掉。
  var currentPowerMode = prefs.getString(PrefsKeys.powerMode) ?? 'balanced';

  Future<void> applyPowerMode(String mode) async {
    currentPowerMode = mode;
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
  _diagStep('m5-powerMode');

  /// NAT-07：任务结束 / 停机时释放**按需**持有的唤醒锁。
  ///
  /// 为什么必须显式释放：`balanced` / `saver` 两档允许引擎在动作执行期间
  /// 按需持锁（否则锁屏下长动作会被 Doze 掐断），但**不允许**把锁留到下一次
  /// 切档 —— 那等于"平衡模式也在持续耗电"，破坏用户选档时的承诺。
  /// `performance` 档的锁是常驻的，由 `applyPowerMode` 统一管理，此处跳过。
  ///
  /// 失败静默：下一次切档会由原生策略强制释放，不需要为一次释放失败打断执行。
  Future<void> releaseWakeLockIfNeeded() async {
    if (currentPowerMode == 'performance') return;
    try {
      await NativeBridge.releaseWakeLock();
    } on Object {
      // 见上注：切档点会强制释放。
    }
  }

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
  _diagStep('m6-vibrate');

  var guardEnabled = prefs.getBool(PrefsKeys.guardEnabled) ?? false;
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
  /// 为什么要它：通道A 的 15s `Timer.periodic` 与**原生闹钟唤醒的第二份服务**
  /// 会并发进入 `executeDue`，而 `executeDue` 内的 `runAction` 可长时间
  /// 阻塞（播放 / 录音 / TTS，最长 1800s）。没有守卫时，15s 的 tick 会在上一轮
  /// `runAction` 尚未返回时**再起一份** `executeDue`，而 `due()` 只筛
  /// `status='pending'` —— 那条计划尚未落终态，于是被**并发取出执行两次**
  /// （双响 / 重复录音 / 播放器互踩）。
  ///
  /// （R90-20：旧注释还声称 `service.on('tick')` 是第二个同源触发点 —— 那条
  /// 监听全仓无生产者，已删除；真正的第二触发点是原生闹钟唤醒的新服务实例。）
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

  /// **任务级**执行互斥表（R94 / SCH-03 + ARCH-08）。
  ///
  /// ## 为什么 [executing] 不够
  /// `executing` 的语义是"`executeDue` 这一轮别重入"（粒度 = 批次），而真实
  /// 需求是"**同一任务**在任一时刻至多一个执行实例"（粒度 = 任务）。两条粒度
  /// 不同：`runNow`（远程/本机立即执行）、`runGuardPlan`（声音触发）与
  /// `executeDue` 三者互不相识，同一条任务可以被其中任意两条**同时**执行 ——
  /// `PlaybackService.play()` 每次都新建 `AudioPlayer`（R90-07 有意为之），
  /// 于是不是"互相踩踏后只剩一路"，而是**两路同时出声**（双响）、
  /// 两个录音器抢麦克风（第二份必失败但污染审计）。
  ///
  /// ## 与数据库 CAS 的分工
  /// - 本表：**进程内**（同 isolate）互斥，零 I/O、同步判定 ⇒ 立刻返回 `busy`；
  /// - `OccurrenceRepository.markStatus(from: …)`：**跨进程/跨连接**防线
  ///   （UI isolate 与引擎 isolate 各持一条 SQLite 连接），抢不到就放弃。
  /// 两者互补：本表挡不住另一条连接，CAS 挡不住"不同 occurrence 但同一任务"。
  ///
  /// ⚠️ 必须是 `_engineBody` 内的**局部**状态（REENT-06 的形状要求）：
  /// 顶层可变全局会跨引擎重启残留，把已死的执行者当成"仍在跑"。
  final runLock = TaskRunLock();

  /// 已上报过解析失败的任务行 id（R90-09 去重）。
  ///
  /// 一行坏数据会被每一次 `listAll`（每 15s tick 至少一次）重新撞到；
  /// 每个 id 只落一条日志，避免把 exec_logs 刷爆。
  final Set<String> badTaskRowsReported = <String>{};

  /// 单行解析失败的上报口（R90-09）。
  void reportBadTaskRow(String id, Object error) {
    if (id.isEmpty || !badTaskRowsReported.add(id)) return;
    // QUA-08：`unawaited` 的 Future 必须自带兜底 —— 写审计失败（库已关 /
    // 磁盘满）时异常会逃进 zone，变成一条与真实原因无关的
    // "unhandled exception"，反而盖掉这条坏行本身的线索。
    unawaited(logs
        .append(
          source: 'db',
          action: 'taskRow',
          status: 'failed',
          taskId: id,
          message: '任务行解析失败，已跳过该行（其余任务不受影响）：$error',
        )
        .catchError((Object _) {}));
  }

  /// `replan` 重入时的**补跑登记**（BUG-087 修复，2026-10-18）。
  ///
  /// 旧行为：`replanning` 为真时直接 `print` + `return`，把本次触发**静默
  /// 丢弃**。而 `replan` 的触发源有四个：tick 续算、引擎启动、设置页开关
  /// （`service.on('replan')`）、远程命令 —— 其中设置页那条是**用户动作
  /// 的直接后果**，丢掉它等于"用户拨了开关但引擎永远不执行"。
  /// 更糟的是兜底 tick 若同时被别的 bug 卡死，这次丢弃就是**永久**的。
  ///
  /// 现在改为登记 `replanQueued`：本轮 `finally` 释放锁之后合并补跑一次。
  /// 互斥语义不变（仍不会有两个 replan 并发），但**没有任何触发源会丢失**。
  bool replanQueued = false;

  /// 守卫启动失败原因（随每次 `state` 广播回投给 UI）。
  /// 成功启动 / 主动关闭时清空 —— 否则 UI 会一直拿着一条过期的错误。
  String? guardError;

  /// **守卫命令代次**（🔴 R97 / R88-AUD-03）。
  ///
  /// `service.on('guard')` 是独立的 async 监听器，**没有任何串行化**：
  /// 用户快速「开 → 关」时，开启那一支会停在 `guard.start()` 的取流 `await` 里，
  /// 关闭那一支完整跑完（`guard.stop()` 此时 `_sub == null` ⇒ 实际是空操作），
  /// 随后开启那一支恢复执行 ⇒ **`guardEnabled=false` 而 `guard.isRunning=true`**：
  /// 麦克风继续采流、`onSoundEvent` 继续被调用（可继续触发延时动作）。
  ///
  /// 修法：每个命令在**同步段**里 `guardGen++` 并取快照，`guard.start()` 返回后
  /// 复核代次与目标态；不成立就立刻 `guard.stop()` 并如实记审计。
  int guardGen = 0;

  /// 精确闹钟（通道B）降级原因（P1-04），随每次 `state` 广播回投给 UI。
  /// 排布正常时清空 —— 与 [guardError] 同为"失败必须可见"的载体。
  String? alarmDiag;

  /// 守卫"延时执行"的待发定时器（v1.10 编排增强；R94 / SCH-14 改**多槽**）。
  ///
  /// 持有它是为了**能被取消**：用户关了守卫 / 停了引擎之后，已排定的延时
  /// 声音绝不能再响 —— 否则"关掉守卫"在最长一个延时窗口内等于没关
  /// （与 `replan()` 里清除夜间豁免计划同一类护栏）。
  ///
  /// ## 为什么从单槽改成多槽（SCH-14 / ARCH-07）
  /// 旧实现是 `guardDelayTimer?.cancel(); guardDelayTimer = Timer(...)`：
  /// 第二个声音事件到来时，第一个延时计划被 `cancel()` 且**没有任何审计**。
  /// 若编排是"多个任务各延时各的"（`GuardPickMode.all` + `delayMs > 0`），
  /// 后一个事件会把前一个任务的执行**静默吞掉** —— 与 BUG-087（replan 触发源
  /// 静默消失）同族：**触发源不得静默消失**。现在按「计划指纹」分槽，
  /// 只有**同一计划**被同键覆盖时才取消旧的，并写一条 `guardDelay/skipped`
  /// 说明"被新的声音事件顶替"。
  final guardDelaySlots = GuardDelaySlots(
    onSuperseded: (key) {
      // 覆盖即丢一次执行：必须留痕（不 await，回调是同步的）。
      unawaited(logs
          .append(
            source: 'sound',
            action: 'guardDelay',
            status: 'skipped',
            message: '延时计划被新的声音事件顶替（key=$key）：旧计划取消，'
                '只保留最后一次（避免连续噪音触发多次反击）',
          )
          .catchError((Object _) {}));
    },
  );

  /// 守卫路径的**单调**冷却基准（R94 / SCH-08 + SCH-10）。
  ///
  /// 两件事：
  /// 1. SCH-08：冷却基准必须在**执行之前**落定。旧实现只读 `lastDoneFor`
  ///    （只认 `done`，而 `done` 在 `runAction` 返回后才写）⇒ 动作时长 >
  ///    冷却窗口时，同一任务会在执行期间被第二个声音事件再次触发；
  /// 2. SCH-10：这是"经过时长"判据，必须用**单调**时钟（`Stopwatch`），
  ///    墙钟跳变不得解除或延长冷却。
  final guardClock = Stopwatch()..start();
  final Map<String, Duration> guardLastStart = <String, Duration>{};

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
      // 🔴 R94 / SCH-07：录音等待必须**可中断**。
      //
      // 旧实现是 `await Future<void>.delayed(Duration(seconds: seconds))` ——
      // 没有任何取消点：用户停引擎 / 关守卫之后，录音会继续录到 `seconds`
      // 结束（默认 60s，上限 1800s），麦克风被本应用占着，用户以为"已经关了"。
      // 这在隐私上是红线（"承诺了停止就必须停止"），而 stopSelf 又未必成功。
      //
      // 现在拆成 ≤2s 的片段循环，每片前后复检 `stopping`：停机后最多 2 秒
      // 内落 `skipped('已停机')`，不再产出"用户以为不存在"的录音。
      final finished = await waitInterruptibly(
        Duration(seconds: seconds),
        isStopping: () => stopping,
      );
      await rec.stop();
      if (!finished) {
        await logs.append(
            source: source,
            action: 'record',
            status: 'skipped',
            taskId: task.id,
            durationMs: seconds * 1000,
            message: '已停机：录音提前中断（用户关闭引擎/守卫），未完成取证');
        return const ExecutionOutcome.skipped('已停机');
      }
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
            : const ExecutionOutcome.failed('振动未启动（原生拒绝或动作类型不支持）');
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

  /// 任务优先级表（`taskId -> priority`），供 [orderDueBatch] 做同刻二次排序。
  ///
  /// 只取两列：`listAll()` 会把每条任务的 JSON 全解一遍（触发器/动作/条件），
  /// 而排序只需要一个整数。每 tick 一次的单表查询，成本可忽略。
  Future<Map<String, int>> taskPriorities() async {
    final rows =
        await db.db.query('tasks', columns: ['id', 'priority']);
    return {
      for (final r in rows)
        if (r['id'] is String) r['id'] as String: (r['priority'] as int?) ?? 0,
    };
  }

  /// 未来 pending 的**覆盖末端**，且只统计**启用任务**（R94 / SCH-11）。
  ///
  /// ## 为什么不能直接复用 `occs.latestPendingFireAt`
  /// 它不 join `tasks.enabled`，而 `replan` 只处理 `enabledOnly: true` 的任务
  /// ⇒ 停用任务遗留的 pending **既不删除也不重算**，却继续支撑"覆盖末端"：
  /// 一条 40 小时后的停用计划会让 `planNeedsExtend` 恒为 false，
  /// tick **最长 36 小时不再续算**（期间新建/修改的任务只靠 UI 显式 replan 才生效）。
  ///
  /// 判据必须只统计"会真正触发"的计划。仓储签名不动（F3 所有权），
  /// 过滤放在调用侧：一次 `JOIN` 聚合查询即可。
  Future<DateTime?> latestPendingFireAt(DateTime after) async {
    final r = await db.db.rawQuery(
      'SELECT MAX(o.fire_at) AS m FROM occurrences o '
      'JOIN tasks t ON t.id = o.task_id '
      "WHERE t.enabled = 1 AND o.status = 'pending' AND o.fire_at > ?",
      [after.millisecondsSinceEpoch],
    );
    final m = r.first['m'];
    return m is int ? DateTime.fromMillisecondsSinceEpoch(m) : null;
  }

  /// 未来 pending **条数**，同样只统计启用任务（SCH-11；`broadcast` 用）。
  ///
  /// 旧口径把停用任务的残留 pending 也算进首页"待执行 N 条"里，用户看到
  /// "下次触发 22:00"，而那条永远不会执行。
  Future<int> pendingCountEnabled(DateTime after) async {
    final r = await db.db.rawQuery(
      'SELECT COUNT(*) AS c FROM occurrences o '
      'JOIN tasks t ON t.id = o.task_id '
      "WHERE t.enabled = 1 AND o.status = 'pending' AND o.fire_at > ?",
      [after.millisecondsSinceEpoch],
    );
    return (r.first['c'] as int?) ?? 0;
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
    // SCH-11：只统计**启用任务**的 pending（停用任务的残留计划永远不会执行，
    // 计入会让首页显示一个不存在的倒计时与虚高的待执行条数）。
    final pending = await pendingCountEnabled(now);
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
    // R90-06：停机清理链已经 `clearAllAlarms()` 之后，并发 tick 的 replan
    // 不得再把闹钟排回去（否则"已关闭"的引擎到点又被看门狗拉起）。
    if (stopping) return;
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
    // R90-06：停机中不再接受任何新的续算（见 [stopping]）。
    if (stopping) return;
    // 与 executeDue 的守卫同形；同样在任何 await 之前同步置位。
    if (replanning) {
      // BUG-087 修复（2026-10-18）：不再丢弃本次触发，登记为"待补跑"，
      // 由本轮 finally 之后合并执行一次。互斥语义不变，但设置页开关 /
      // 远程命令 / tick 这些触发源再也不会静默消失。
      replanQueued = true;
      return;
    }
    replanning = true;
    // 双层 try/finally：内层「跑完就复位」，外层「锁外补跑被登记的续算」。
    // 拆两层的理由见外层 finally 处的长注释（REENT-05 的形状要求）。
    try {
      try {
        // 设置同步（BUG-082）：本函数是**唯一**读取免打扰窗口 + 夜间豁免主开关
        // 的地方，必须先 `reload()` —— 否则用户在引擎运行期间改的这两项在
        // 本 isolate 里全是旧值（详见 [syncPrefs]）。
        await syncPrefs();
        final now = DateTime.now();
        final all = await tasksRepo.listAll(
            enabledOnly: true, onRowError: reportBadTaskRow);
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
            // BUG-090 修复（2026-10-18）：治理事件必须**另起一个 action 名**。
            // 旧写法沿用 `action: 'quietExempt'`，而设置页「本月豁免次数」按
            // `action='quietExempt'` 计数且**不区分 status** ⇒ 一次夜间执行
            // 都没有也能虚高（撤销开关本身被记成"豁免了一次"）。
            // 换成独立 action 后，计数查询一字不动即恢复正确，且不存在
            // "少算真豁免"的风险（真豁免仍写 `quietExempt`）。
            await logs.append(
                source: 'schedule',
                action: 'quietExemptPurge',
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
          // BUG-089 修复（2026-10-18）：**所有**启用任务都必须进对账删除面。
          // 旧写法在 `taskIds.add` **之前** `continue` 掉声音触发任务 ⇒ 用户
          // 把某个任务从"固定定时"改成"声音触发"后，它的旧时间计划不会被
          // `reconcile` 清掉；而 `executeDue` 只按 `task.enabled` 过滤、
          // **不看 triggerType** ⇒ 幽灵计划照常取出执行。
          // 现在只跳过"物化"，不跳过"对账"（新计划为空 ⇒ 旧计划被删）。
          taskIds.add(t.id);
          if (t.triggerType == TriggerType.soundTriggered) continue;
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
        // 原生精确闹钟（通道B）排布（BUG-088 修复，2026-10-18）：
        // 旧写法是 `newEntries.take(maxNativeAlarmsPerTask)` —— `newEntries`
        // 是**按任务拼接**出来的（`ScheduleEngine.materialize` 只在每个任务
        // 内部排序），64 条额度会被列表头部的任务吃光，尾部任务一条精确闹钟
        // 都排不上；而夜间通道A（Dart Timer）在深度 Doze 下不可靠 ⇒ 那些任务
        // **永不被唤醒**。改为**全局按 fireAt 升序**取最早 N 条，并把被截断
        // 的数量写进审计（静默丢弃 = 没人知道谁掉了）。
        final ordered = List<PlannedEntry>.of(newEntries)
          ..sort((a, b) => a.fireAt.compareTo(b.fireAt));
        final keep = ordered.length <= SchedulerConfig.maxNativeAlarmsPerTask
            ? ordered
            : ordered.sublist(0, SchedulerConfig.maxNativeAlarmsPerTask);
        final dropped = ordered.length - keep.length;
        final alarmTimes =
            keep.map((e) => e.fireAt.millisecondsSinceEpoch).toList();
        if (dropped > 0) {
          await logs.append(
              source: 'schedule',
              action: 'alarms',
              status: 'skipped',
              message: '原生精确闹钟额度用尽：本轮 $ordered.length 条计划中最早的'
                  ' ${keep.length} 条已排布，另有 $dropped 条依赖通道A兜底'
                  '（深度 Doze 下可能失效）');
        }
        await pushExactAlarms(alarmTimes);
        lastAction = 'replan(${newEntries.length} 条计划)';
        await broadcast();
      } finally {
        replanning = false;
      }
    } finally {
      // BUG-087：锁已在此释放 ⇒ 登记过的续算在**锁外**补跑，不会自锁重入。
      // 互斥语义不变（仍是串行追加，不会两个 replan 并发），但设置页开关 /
      // 远程命令 / tick 这些触发源再也不会静默消失。
      //
      // ⚠️ 为什么必须套两层 try/finally：`REENT-05` 的源码契约锁要求
      // `} finally { replanning = false; } 紧邻收口`（复位语句后不得再有别的
      // 语句）—— 那是为了「把守卫注释掉 / 复位漏改」能被判红。补跑逻辑放进
      // 内层 finally 会破坏该形状，所以放外层：内层只管复位，外层只管补跑。
      //
      // ⚠️ 补跑也必须走 `stepGuarded`：`GTX-08` 禁字面 `await replan();`
      // （老库缺列时裸调会抛 SQLITE_ERROR 且没人接），而这里本来就是
      // 「不能因补跑失败影响上一轮结论」，兜底更严谨。
      if (replanQueued) {
        replanQueued = false;
        try {
          await stepGuarded('replan(queued)', replan);
        } on Object {
          // 补跑失败最坏就是下一轮 tick 再来；绝不在 finally 里向上抛
          // （那会覆盖上一轮的返回/异常）。
        }
      }
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
  /// 上一条已落盘的反击计划续算失败原因（R90-14 去重）。
  ///
  /// `refreshIfNeeded` 每 tick 都会被调用；同一条失败原因只落一次日志，
  /// 避免 15s 一条把 exec_logs 刷爆（那等于用噪声淹掉真正的失败）。
  String? lastCounterFailMsg;

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
      lastCounterFailMsg = null; // 恢复正常：下一次失败重新可见
      await logs.append(
        source: 'schedule',
        action: 'counterExtend',
        status: 'success',
        message: '反击计划自动续算：${r.message}',
      );
    } else if (!r.ok && r.message != lastCounterFailMsg) {
      // 🔴 R90-14（2026-10-19）：**失败**不得静默。
      //
      // 旧写法只在 `taskCount > 0` 时写日志 ⇒ 计划已启用但点名音效本机没有、
      // 导入失败等情形下，`refreshIfNeeded` 每 tick 都返回 `fail(...)`，而
      // 日志里**一条原因都没有** —— 用户看到"反击计划已启用"却永远不排期。
      //
      // ⚠️ 只记 `!r.ok`：`ok + taskCount==0` 是**正常**的"无需续算"（有界计划 /
      // 已排到 horizon 之外），每 15s 记一条会把 exec_logs 刷爆 —— 那反而是
      // 用另一种方式淹掉真正需要被看见的失败。
      lastCounterFailMsg = r.message;
      await logs.append(
        source: 'schedule',
        action: 'counterExtend',
        status: 'failed',
        message: '反击计划未续算：${r.message}',
      );
    }
  }

  /// 执行所有到期计划（幂等；带补执行上限、批次陈旧判定与执行预算）。
  ///
  /// 重入守卫（A2-P0-2）：见 [executing] 的说明。
  ///
  /// ## R94 起的结构（SCH-01 / 03 / 04 / 07 / 13）
  /// 本函数只负责**策略**：取批次、算一次 `pausedNow`、提供门禁与落库回调。
  /// 真正的批次循环搬到了顶层纯函数 [executeBatch]（可注入、可单测）——
  /// 它负责「停机复检 → 批次陈旧判定 → 任务级互斥 → CAS 抢占 → 预算内执行
  /// → 终态 CAS」。这样"判定与执行解耦"是**结构性**的，不是靠注释维持。
  Future<void> executeDue() async {
    // R90-06：停机中不再取新计划（已在执行中的那一条会自然收尾）。
    if (stopping) return;
    // 必须在**任何 await 之前**同步置位 —— Dart 单线程，同步置位对同 isolate
    // 的一切重入是原子的（这是守卫成立的前提，不是风格）。
    if (executing) {
      // 不静默吞掉：留 logcat 痕迹（与 `runZonedGuarded` 的自愈日志同渠道）。
      // 刻意**不写审计**：长动作期间每 15s 会被拒一次，写审计会把
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
      // 惰性 → 若所有计划都在"过期丢弃"分支被跳过，则一次平台读取都不会发生。
      final env = RoundConditionEnv(read: readConditionEnv);
      // SCH-13：同刻到期时按 `Task.priority` 降序（契约写的是"数值大者先执行"，
      // 而 `due()` 只有 `fire_at ASC` ⇒ 顺序此前退化成 rowid，不可预期）。
      final ordered = orderDueBatch(due, await taskPriorities());
      await executeBatch(
        due: ordered,
        // SCH-01 核心：整批用**批次开始时刻**做一次陈旧判定。
        // 批次内排队时间不计入迟到；跨批次的迟到仍按 10 分钟丢。
        batchStart: now,
        isStopping: () => stopping,
        runAction: (task, o) => runAction(
            task, o.volume ?? 0.8, o.durationMs ?? 0, 'schedule',
            occurrenceId: o.id),
        loadTask: tasksRepo.get,
        // 门禁顺序与既有三入口一致：暂停（最粗的刹车）→ 条件 → 概率。
        admit: (task, o) async {
          if (pausedNow && !task.forceRun) {
            return (
              action: 'runPause',
              message: '节假日自动暂停中（全局执行总开关），跳过',
            );
          }
          final condFail = conditionFailedIn(task, await env.value);
          if (condFail != null) {
            return (action: 'condition', message: condFail);
          }
          final gateFail = probabilityGateMissed(task);
          if (gateFail != null) {
            return (action: 'probability', message: gateFail);
          }
          return null;
        },
        // SCH-04：**CAS 抢占**。`due()` 只筛 pending，两条连接（UI 引擎 +
        // 后台引擎，`singleInstance:false`）会拿到同一批行；只有"从 pending
        // 抢到 running"的那一方才有资格执行。
        claim: (o) => occs.markStatus(o.id, OccurrenceStatus.running,
            from: {OccurrenceStatus.pending}),
        // 丢弃也是 CAS：别人已经抢走/用户刚跳过时返回 0，不得覆盖。
        discard: (o) => occs.markStatus(o.id, OccurrenceStatus.skipped,
            from: {OccurrenceStatus.pending}),
        finish: (o, outcome, task) async {
          // P1-07：终态由**真实执行结果**决定（缺失音源/TTS 超时/录音失败
          // 现在会如实落 failed，不再因 helper 返回 void 而被记成成功）。
          //
          // BUG-093：`skipped` 必须落 **skipped**，不能并进 done ——
          // 否则 `lastDoneFor` 会把"根本没发生"的执行算成 done，冷却被凭空激活。
          final ok = outcome.ok;
          final terminal = outcome.isSkipped
              ? OccurrenceStatus.skipped
              : (ok ? OccurrenceStatus.done : OccurrenceStatus.failed);
          // 只从 `running` 写终态：用户在执行期间点「跳过下一次」时该行已被
          // 改成 skipped，这里 CAS 返回 0、**不覆盖用户意图**（SCH-04）。
          await occs.markStatus(o.id, terminal,
              from: {OccurrenceStatus.running});
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
          // NAT-07：balanced / saver 档按需持锁、**用完即放**（performance
          // 档的锁是常驻的，由用户显式选择并承担耗电）。
          await releaseWakeLockIfNeeded();
        },
        audit: (action, status, message, o) => logs.append(
          source: 'schedule',
          action: action,
          status: status,
          taskId: o.taskId,
          occurrenceId: o.id,
          message: message,
        ),
        tryClaim: runLock.tryClaim,
        release: runLock.release,
      );
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
    final all = await tasksRepo.listAll(
            enabledOnly: true, onRowError: reportBadTaskRow);
    // 计划里的 id 可能已被删除/停用：**跳过并留痕**，不拿别的任务顶上
    // （与 BUG-059「点名了就必须满足」同一判据）。
    final byId = {for (final t in all) t.id: t};
    for (final id in plan.taskIds) {
      // SCH-07 同族：停机清理链期间不得再起新的动作。
      if (stopping) break;
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
      // SCH-03：任务级互斥。声音路径与定时/远程路径此前**互不相识** ——
      // 同一条任务可以同时被 `executeDue` 与本次声音事件各跑一份
      // （`PlaybackService.play` 每路新建播放器 ⇒ 双响，不是互相踩踏）。
      final occId = '${t.id}@sound@${at.millisecondsSinceEpoch}';
      if (!runLock.tryClaim(t.id, occId)) {
        await logs.append(
            source: 'sound',
            action: 'guardPlan',
            status: 'skipped',
            taskId: t.id,
            message: '同一任务正在执行（任务级互斥）：本次声音触发跳过，'
                '不叠加第二份动作');
        continue;
      }
      try {
        // 🔴 SCH-08：冷却基准必须在**执行之前**落定。
        //
        // 旧实现只靠 `lastDoneFor`（只认 `done`），而 `done` 是 `runAction`
        // **返回后**才写的 ⇒ 动作时长 > 冷却窗口时（用户/远程可把
        // `cooldownSec` 调到 10s，动作却是 60s 录音），执行期间的第二个声音
        // 事件查到的仍是 null/更早时间 ⇒ 同一任务被重复触发。
        // 现在两条基准取**更近的那条**：内存里的单调开始时刻（本进程内有效）
        // + 持久化的 `running` 占用行（跨进程可读，重启后由
        // `recoverInterrupted` 收口）。
        guardLastStart[t.id] = guardClock.elapsed;
        await occs.commitAll([
          PlannedOccurrence(
            id: occId,
            taskId: t.id,
            fireAt: at,
            status: OccurrenceStatus.running,
          ),
        ]);
        // 概率门已在 onSoundEvent 的候选裁决（admitExecution）中生效；
        // 此处只执行并如实落终态（P1-07）。
        final outcome = await runAction(t, 0.8, 0, 'sound', occurrenceId: occId);
        await occs.markStatus(
          occId,
          // 🔴 R90-04（2026-10-19）：三态映射必须与 `executeDue` 对齐。
          //
          // 旧写法 `outcome.isFailure ? failed : done` 把 **skipped 并进 done**：
          // 固定节奏振动在"无振动器 / 原生未确认"时返回
          // `ExecutionOutcome.skipped(...)`（见 runSingle 的振动分支），落库却
          // 成了 done ⇒ `lastDoneFor` 非空 ⇒ 后续**真实**声音事件在冷却期内被
          // 压掉。`executeDue` 早已按 BUG-093 修成三态，这里是漏改的孪生路径。
          outcome.isSkipped
              ? OccurrenceStatus.skipped
              : (outcome.ok
                  ? OccurrenceStatus.done
                  : OccurrenceStatus.failed),
          // SCH-04：只从 `running` 写终态 —— 用户在执行期间点了「跳过下一次」
          // 时该行已被改成 `skipped`，这里 CAS 返回 0、不覆盖用户意图。
          from: {OccurrenceStatus.running},
        );
      } finally {
        runLock.release(t.id);
      }
    }
    await broadcast();
  }

  /// 声音事件 -> 执行守卫计划。
  ///
  /// v1.10 编排增强（`GuardOrchestration`）只补三件事：
  /// **候选子集 / N 选一随机 / 延时执行**；动作内容仍完全由任务自己的动作层
  /// （`assetIds` 多音频随机、`ActionSetAction` 多动作加权随机、概率门）决定。
  Future<void> onSoundEvent(DateTime at, double peakDb) async {
    final all = await tasksRepo.listAll(
            enabledOnly: true, onRowError: reportBadTaskRow);
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
      // 🔴 SCH-08：冷却基准取**更近**的那条。
      //
      // `lastDoneFor` 只认 `done`（执行结束才写），单靠它会让"动作时长 >
      // 冷却窗口"的任务在执行期间被重复触发。这里再叠一条**单调**的
      // 「本次开始时刻」（`guardLastStart`，SCH-10：经过时长必须用单调时钟，
      // 墙钟跳变不得解除/延长冷却）。
      final startedAt = guardLastStart[t.id];
      final sinceStart =
          startedAt == null ? null : guardClock.elapsed - startedAt;
      final sinceDone = last == null ? null : at.difference(last);
      final sinceLast = switch ((sinceDone, sinceStart)) {
        (null, null) => null,
        (final d?, null) => d,
        (null, final s?) => s,
        (final d?, final s?) => d < s ? d : s,
      };
      if (sinceLast != null && sinceLast < cooldown) continue;
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
      // SCH-14：按**计划指纹**分槽（不是单槽覆盖）。同一计划被新事件顶替时
      // `onSuperseded` 会写一条 skipped 审计；不同计划各占一槽、互不吞并。
      guardDelaySlots.schedule(
        key: plan.taskIds.join(','),
        delay: Duration(milliseconds: plan.delayMs),
        onFire: () {
          // 延时窗口内守卫可能已被关闭（`service.on('guard')` 会 cancelAll）；
          // 这里再查一次 `guardEnabled` 与 `stopping` 做双保险，
          // 绝不在用户说"关"之后出声，也绝不在停机清理链期间起播。
          if (!guardEnabled || stopping) return;
          unawaited(runGuardPlan(plan, DateTime.now()));
        },
      );
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
    // 🔴 R94 / SCH-09：**先停旧实例**，再装配新的。
    //
    // 旧实现直接 `reactive = ReactiveCounterService(...)..start()` —— 旧实例被
    // 覆盖引用后**仍然活着**：`_running=true`、`_silenceTimer` 仍在计时。
    // 它的静默反制到期后会直接 `playback.play()`，**即使 UI 上"动态反击"已关闭**
    // （`stopReactiveCounter` 只能停到新实例）—— 用户听到一次无来源的噪音，
    // 且没有任何引用能停它。Dart 不会因为对象不可达就取消 Timer。
    //
    // 触发面很宽：开→开（重复点）、守卫开+反击开两条指令先后到达、守卫自恢复
    // 与 `reactive` 热切换叠加。`ReactiveCounterService.start()` 的幂等只对
    // **同一实例**生效，跨实例无效。
    reactive?.stop();
    reactive = null;
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
  // 🔴 R90-20（2026-10-19）：删除 `service.on('tick')` 死登记。
  //
  // 全仓（`lib/**` + `android/**`）**没有任何 `invoke('tick')` 生产者** ——
  // 通道A 的唯一触发点是下方 15s 的 `Timer.periodic`。旧代码同时注册了这条
  // 监听并在 [executing] 的注释里声称"两个同源可叠加的触发点"，会让后续维护者
  // 误判触发源数量（并误以为原生侧还会推 tick）。真正需要防的是 tick 与
  // 原生闹钟唤醒的第二份服务并发，那一层由 [executing] + 数据库乐观置状态兜住。
  // 电源模式热切换（v1.9.1）：设置页改档 → 引擎即时应用副作用（常驻唤醒锁）。
  // 与 `reactive` 同为"UI 改设置 → 引擎即时响应"，无需重启引擎。
  service.on('powerMode').listen((m) async {
    final mode = (m?['mode'] as String?) ?? 'balanced';
    await applyPowerMode(mode);
    await broadcast();
  });
  /// 守卫开关的**唯一漏斗**（本机开关 / 远程 `guard.set` / 启动自恢复共用）。
  ///
  /// ## 为什么要收成一个函数（R94 / ARCH-01 + NAT-03）
  /// 旧实现的启动自恢复是一句 `service.invoke('guard', {'enabled': true})` ——
  /// 把指令**投回 UI isolate**，可 UI isolate 里根本没有任何 `service.on('guard')`
  /// 消费者（消费者只在本引擎里）。于是"引擎重启后自动恢复守卫"是一条**死路径**：
  /// 回投成功（`invoke` 不抛）、无人接收、守卫永远不恢复，而界面显示"守卫开着"。
  ///
  /// 现在自恢复直接调用本函数（同一进程内，无需跨 isolate 中转）。并且
  /// [requireMicPassport] 为真时先确认 **microphone 型前台服务通行证**是否存活：
  /// Android 11+ while-in-use 语义下，没有通行证的后台 `AudioRecord`
  /// **不抛异常、只回全静音** —— 直接恢复会得到一个"在跑但采不到声"的守卫，
  /// 界面却报"守卫运行中"（核心安全能力静默失效，本项目最忌讳的形态）。
  /// 拿不到通行证 ⇒ **不启动采音**，如实回投 `guardActive:false` + 原因。
  Future<void> applyGuardEnabled(bool enabled,
      {bool requireMicPassport = false}) async {
    // 🔴 R97（R88-AUD-03）：**第一条语句**同步推进守卫代次并取快照。
    // 之后每一处 `await` 都可能被"反方向的命令"插队（开↔关），
    // 只有代次能告诉本支"我是不是已经过期了"。
    final gen = ++guardGen;
    guardEnabled = enabled;
    // 🔴 R97（R88-AUD-07）：**先清旧错误，再进 await 链**。
    //
    // 旧实现只在 `await guard.start()` **之后**才写 `guardError`，于是启动窗口
    // 内的每一次 `broadcast()` 都还带着**上一轮的失败文案** ⇒ UI 一收到状态
    // 就判「启动失败」，用户看到开关弹回。错误必须在"开始尝试"这一刻就清掉，
    // 失败时再由 `started.message` 写回。
    guardError = null;
    await prefs.setBool(PrefsKeys.guardEnabled, enabled);
    if (enabled) {
      if (requireMicPassport) {
        final alive = await NativeBridge.isMicServiceRunning();
        // ⚠️ 只有"确实读到了"才拦：iOS / 桌面没有这条通道
        // （`lastNativeError` 非空）时不能因为"读不到"就拒绝启动守卫 ——
        // 那会把整条非 Android 通路锁死（fail-open，与条件层同一约定）。
        if (NativeBridge.lastNativeError == null && !alive) {
          guardEnabled = false;
          await prefs.setBool(PrefsKeys.guardEnabled, false);
          guardError = '后台麦克风通行证已失效：请打开应用重新开启守卫';
          await logs.append(
              source: 'guard',
              action: 'start',
              status: 'skipped',
              // 文案必须可操作：用户唯一的修复动作是"回前台重新开一次守卫"。
              message: '后台麦克风通行证已失效：请打开应用重新开启守卫'
                  '（不启动采音，避免采到全静音却报「守卫运行中」）');
          await broadcast();
          return;
        }
      }
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
      // 🔴 R97（R88-AUD-03）：取流窗口内可能已到达「关闭」命令（或又一次「开启」）。
      // 代次不等 ⇒ 本次启动**已经过期**：立刻停掉刚起来的守卫并如实留痕，
      // 绝不把 `guardActive:true` 投给 UI —— 那会把"关了还在采"粉饰成"看起来正常"，
      // 而这正是本缺陷最危险的一面（核心安全能力静默失效）。
      if (gen != guardGen) {
        if (guard.isRunning) await guard.stop();
        guardError = '守卫启动完成时已被后续命令取消（未开始采音）';
        await logs.append(
          source: 'guard',
          action: 'start',
          status: 'skipped',
          message: '启动完成时已被后续命令取消：本次不采音'
              '（当前目标态 guardEnabled=$guardEnabled）',
        );
        await broadcast();
        return;
      }
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
      // 先撤延时计划：用户说"关"，就不能再有任何已排定的声音（多槽全撤）。
      guardDelaySlots.cancelAll();
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
  }

  service.on('guard').listen((m) async {
    await applyGuardEnabled((m?['enabled'] as bool?) ?? false);
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
    // SCH-15：**幂等闸门**。旧实现没有它 —— 用户在清理链未完成时重复点"关闭"
    // 会并发跑两遍清理链（两次 `CounterPlanService.disable()` 删任务 + 两次
    // `stopSelf`），第二遍还可能把第一遍刚回投的 `running:false` 覆盖成
    // 中间态。停止是幂等语义，第二条指令必须直接返回。
    if (stopping) return;
    // R90-06：**第一条语句**同步置位停机闸门（在任何 await 之前）。
    stopping = true;
    // 🔴 R89：停机清理链必须整体收口在 try/finally 里。
    //
    // 现场（1.9.6+29 真机实证，R89 探针 v9）：清理链中任意一步抛错
    // （如库瞬时不可用 → `broadcast(running:false)` 抛
    // `DatabaseException(database_closed 2)`）⇒ **`stopSelf()` 永远执行
    // 不到** ⇒ 原生 `BackgroundService.isRunning` 保持 true ⇒ 用户下一次
    // 点开关时原生 `runService()` 早退「Service already running」：
    // `startService()` 照样返回 true，但**不会有任何新引擎被拉起**，也再
    // 没有状态回投 ⇒ 开关永久假死（"点了完全没反应"），直到进程被杀。
    //
    // 纪律：停止方向走安全侧 —— FGS **必须**撤下来，清理尽力而为。
    try {
      // SCH-07：多槽延时计划全撤（单槽 `cancel()` 只撤得掉一个）。
      guardDelaySlots.cancelAll();
      await stopReactiveCounter();
      await guardSub?.cancel();
      guardSub = null;
      await guardErrSub?.cancel();
      guardErrSub = null;
      await guard.stop();
      await playback.stop();
      // SCH-07：**振动也必须在停机时停**。持续振动是 20s 分片 + 3s keep-alive
      // 续发的（docs/20 §6），只 `playback.stop()` 管不到它 —— 用户停了引擎，
      // 手机还会继续震到本片自然结束（最长 20s，且下一片已排定）。
      // `stopAll` 会同时清活跃表（停续发）并调原生 cancel（S3 契约）。
      await vibrate.stopAll(reason: '引擎停止');
      // 🔴 R97（R88-AUD-02）：`stopAll` 之后**再 dispose 一次**。
      //
      // `VibrateSession.dispose()` 是 BUG-127 为"引擎关停"补的出口，但全仓
      // **零调用点** —— 那次修复是空转的。这里显式接上：`stopAll` 已 await 过
      // 原生 cancel，`dispose` 再补一刀（fire-and-forget）专治「表丢了但原生
      // 还在震」的残留（例如上一次进程被杀后系统振动器仍在执行 20s 分片），
      // 同时取消续发定时器 —— 这是 isolate 即将被杀前最后一个能"停"的时刻。
      vibrate.dispose();
      // R90-19：停机时释放引擎独占的播放器句柄。
      //
      // 旧实现只 `stop()` 不 `dispose()` —— `AudioPlayer`（ExoPlayer）原生句柄
      // 要等 isolate 销毁才释放，反复启停会累积。`PlaybackService` 是
      // **本引擎闭包内**的实例（不是全局单例），此处释放安全。
      //
      // 神经 TTS（`_neuralTts`）是**进程级单例**、跨引擎重启复用，故**不在此
      // dispose** —— 释放它会强制下一次引擎启动重新加载模型（数百毫秒且可能
      // 失败），得不偿失；它的生命周期跟随进程，由系统回收。
      await playback.dispose();
      // P2-15：**对称撤下**麦克风前台服务通行证。`MicGuardService` 是独立
      // sticky service，而 Dashboard 关闭引擎走的是 `mgr.stop()` —— 若只停
      // Dart 层守卫，原生 FGS 与常驻通知会残留（dumpsys 可见），与"引擎已关"
      // 的界面语义不一致。同时清掉 `guard_enabled`：通行证已被撤，若还持久化
      // "下次自启守卫"，下次引擎启动会在**没有前台通行证**的情况下尝试采音
      //（违反 Android 11+ while-in-use），必然失败并报错 —— 停止方向走安全侧，
      // 守卫须由用户在前台显式重新开启（届时会重新申请通行证）。
      guardEnabled = false;
      await prefs.setBool(PrefsKeys.guardEnabled, false);
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
      // NAT-07：balanced/saver 档"按需持锁、用完即放" —— 停机是最后的使用者，
      // 必须显式释放（`applyPowerMode('balanced')` 只切策略，不保证释放
      // 本档按需 acquire 的那把锁）。失败静默：下一次切档会强制释放。
      try {
        await NativeBridge.releaseWakeLock();
      } on Object {
        // 释放失败由切档策略兜底，不阻断停机。
      }
      // ⚠️ **必须在 `stopSelf()` 之前回投 `running:false`**。
      // 旧实现从不回投停止状态，且 `broadcast()` 把 `running` 写死成 `true` ⇒
      // UI 的 `isRunning` 永远停在 true（引擎已经死了，再没人能广播），
      // 表现为"引擎开关**开了关不掉**"（真机 MI MAX 2 / API 25，BUG-B）。
      await broadcast(running: false);
      // `invoke` 只是把消息交给平台通道：给它一次事件循环的机会送出去，
      // 再杀自己。不加这一句，最后一条状态可能随 isolate 一起消失。
      await Future<void>.delayed(const Duration(milliseconds: 150));
    } on Object catch (e) {
      // 清理/回投失败：如实留痕 + 兜底回投一次停机状态，但**不阻断
      // finally 里的 stopSelf()**（那才是真正的安全侧动作）。
      _diagStep('stop-cleanup-ERR:$e');
      // ignore: avoid_print
      print('[sonic_shield][engine] 停机清理失败（仍会撤下前台服务）：$e');
      try {
        service.invoke('state', <String, Object?>{'running': false});
      } on Object {
        // 回投失败不改变主判据（UI 侧 mgr.stop() 已有乐观置假兜底）。
      }
    } finally {
      // 无论如何都要撤掉前台服务：原生 isRunning 不复位 ⇒ 引擎永远无法
      // 二次启动（见上注）。stopSelf 幂等，已停时无害。
      try {
        await service.stopSelf();
      } on Object catch (e) {
        _diagStep('stop-self-ERR:$e');
        // ignore: avoid_print
        print('[sonic_shield][engine] stopSelf 失败：$e');
        // 🔴 R94 / SCH-15：**僵尸引擎自愈**。
        //
        // `stopping` 一旦置位是单向的（tick / executeDue / replan 全部早退），
        // 其正确性完全依赖"随后一定 stopSelf 成功"这个**未被保证**的前提。
        // stopSelf 失败时：FGS 通知还在、原生 `isRunning` 仍是 true
        // （用户再点"开启"只会得到 "Service already running"）、而引擎自己
        // 已经不做任何工作 —— 用户只能杀进程/重启手机。
        //
        // 30 秒后复位闸门，让这个**还活着**的 isolate 重新可服务：
        // 清理链已完整跑过（闹钟已清、守卫/播放已停），此时恢复 tick 不会
        // 重排闹钟（replan 只在 planNeedsExtend 时跑，且会重新排布），
        // 也不会把"已关闭"的界面状态覆盖成开启（每次 broadcast 都会如实带
        // `running`）。同时写一条审计 —— 这是用户唯一能看到的线索。
        try {
          await logs.append(
            source: 'engine',
            action: 'stopSelf',
            status: 'failed',
            message: '引擎未能退出（stopSelf 失败：$e）：30 秒后自动恢复调度，'
                '如开关异常请重启应用',
          );
        } on Object {
          // 审计失败不改变自愈动作。
        }
        armStoppingRecovery(onReset: () {
          stopping = false;
          _diagStep('stop-self-recovered');
        });
      }
    }
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
        // R90-21：与相邻失败分支一致 —— 本机必须留痕。`rcRunResult` 只回给
        // 发送端一次，本机日志没痕迹的话，"远程点了一下没反应"事后无法排查。
        await logs.append(
            source: 'remote',
            action: 'runNow',
            status: 'skipped',
            taskId: taskId,
            message: '远程立即执行：任务不存在（$taskId）');
      } else {
        // 🔴 R90-03（2026-10-19）：**必须复用 [admitExecution]**。
        //
        // 旧实现在这里内联了"条件 → 概率"两道门，漏掉了 `admitExecution` 的
        // 第一道闸 —— `pausedAt(now)`（节假日自动暂停 / 全局执行总开关）。
        // 后果：`runMasterMode=off` 或法定休息日暂停窗口内，远程 `task.runNow`
        // 仍会播放/播报/振动，全局刹车对远程路径静默失效；而 `admitExecution`
        // 的文档明写"供声音与远程立即执行两个入口复用"—— 注释与实现直接矛盾。
        final denied =
            await admitExecution(task, await readConditionEnv(), 'remote');
        if (denied != null) {
          // 原因已由 admitExecution 写入审计（runPause / condition /
          // probability，均 status=skipped）；这里补一条"未执行"的计划条目，
          // 保持"计划即审计"语义。
          message = denied;
          await occs.commitAll([
            PlannedOccurrence(
              id: '${task.id}@remote@${DateTime.now().millisecondsSinceEpoch}',
              taskId: task.id,
              fireAt: DateTime.now(),
              status: OccurrenceStatus.skipped,
            ),
          ]);
        } else if (!runLock.tryClaim(task.id, 'runNow')) {
          // 🔴 R94 / SCH-03：任务级互斥。
          //
          // 远程/本机"立即执行"此前**完全不受** `executing` 约束 —— 用户在同一条
          // 长动作执行期间再点一次，就会起第二份 `runAction`：`PlaybackService.play`
          // 每次都新建 `AudioPlayer`（R90-07 有意为之）⇒ 不是互相踩踏后只剩一路，
          // 而是**两路同时出声**；录音则两个 `AudioRecorder` 抢麦克风。
          // 回执必须如实（`ok:false` + 原因），控制端才能提示"正在执行"。
          message = '同一任务正在执行（任务级互斥），请稍后再试';
          await logs.append(
              source: 'remote',
              action: 'runNow',
              status: 'skipped',
              taskId: task.id,
              message: '远程立即执行被拒：$message');
        } else {
          try {
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
                // R90-04 同族：三态如实落库（skipped 不得并进 done）。
                status: outcome.isSkipped
                    ? OccurrenceStatus.skipped
                    : (outcome.ok
                        ? OccurrenceStatus.done
                        : OccurrenceStatus.failed),
                volume: vol,
                durationMs: dur,
              ),
            ]);
            lastAction = '${task.name} · 远程立即执行';
            // NAT-07：balanced / saver 档用完即放（见 releaseWakeLockIfNeeded）。
            await releaseWakeLockIfNeeded();
          } finally {
            runLock.release(task.id);
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
      } else if (!runLock.tryClaim(
          // ⚠️ 互斥键用 **occurrenceId**，不是 `taskId`。
          // 远程指令组的振动步骤共用合成 taskId `remote-script`，按任务 id 加锁
          // 会让两条**互不相关**的振动指令互相拒绝；而同一 occurrenceId 被重复
          // 下发本来就是"接管同一路振动"的语义，拦下它才是对的。
          occurrenceId.isEmpty ? 'remote-script' : occurrenceId,
          occurrenceId)) {
        message = '同一振动步骤正在执行（任务级互斥），请稍后再试';
        await logs.append(
          source: 'remote',
          action: 'vibrate.step',
          status: 'skipped',
          taskId: 'remote-script',
          message: '振动步骤被拒：$message（occurrenceId=$occurrenceId）',
        );
      } else {
        try {
          final action = ActionConfig.fromJson(decoded);
          final plan = resolveVibratePlan(action,
              math.Random(stringSeedOf(occurrenceId, action)), occurrenceId);
          ok = await vibrate.start(
            occurrenceId: occurrenceId,
            taskId: 'remote-script',
            action: action,
            durationMs: plan?.durationMs ?? 0,
            amplitude: plan?.baseAmplitude ?? 0,
            source: 'remote-script',
          );
          if (ok) {
            message = '已执行';
          } else {
            // R90-22：回执承诺了"见审计"，就必须真的有一条。
            // `vibrate.start` 的 default 分支（非 v1.9 振动动作）不写任何审计，
            // 旧文案会让排障者按图索骥落空。
            await logs.append(
              source: 'remote',
              action: 'vibrate.step',
              status: 'skipped',
              taskId: 'remote-script',
              message: '振动步骤未执行（动作类型不支持或原生拒绝，'
                  'occurrenceId=$occurrenceId）',
            );
            message = '被跳过或原生拒绝（已记入执行日志）';
          }
        } finally {
          runLock.release(
              occurrenceId.isEmpty ? 'remote-script' : occurrenceId);
        }
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

  _diagStep('m7-handlers-registered');
  Timer.periodic(SchedulerConfig.engineTick, (_) {
    // R90-06：停机中整轮跳过（executeDue / 续算 / 重排闹钟都不得再起）。
    if (stopping) return;
    unawaited(stepGuarded('executeDue(tick)', executeDue));
    unawaited(() async {
      // 🔴 R89：整条续算链统一兜底。旧写法只有 extendCounterPlan / replan
      // 被 stepGuarded 包住，中间的 `latestPendingFireAt`（聚合查询）是裸
      // `await` —— 它一抛（库瞬时不可用等），异常直接逃进 zone handler，
      // 且**同 tick 的 replan 被静默跳过**：未来计划视界只耗不补，
      // 表现是"任务到点不出声"且界面无任何解释。
      try {
        // 先**续算反击计划**（幂等；未启用时只读一次 prefs 即返回），再重算任务级计划。
        // 顺序不可颠倒：续排只写 `tasks`，计划条目由下面的 `replan` 的
        // `occs.reconcile` 生成（`extendCounterPlan` 内部已带一次 `replan`，
        // 故续排成功后 `pending` 变大、下面这次 `replan` 会被阈值自然跳过 —— 不重复劳动）。
        await stepGuarded('extendCounterPlan(tick)', extendCounterPlan);
        // 计划续算判据（BUG-086 修复，2026-10-18）：
        // 旧写法是 `pendingCountAfter(now) < planExtendThreshold.inHours` ——
        // 拿**条数**和**小时**比大小，任务一多条数恒 ≥ 12 ⇒ 续算永不触发
        // ⇒ 未来计划视界只耗不补，夜间时段没有任何 plan entry ⇒ 用户开不开
        // 「夜间豁免主开关」表现完全一样（真机实证：pending alarm 0 条）。
        // 改判「覆盖末端」：最晚 pending 的触发时间已缩进阈值之内（或一条
        // 都没有）才续算。稳态约 36h 一次全量重算，其余 tick 只付一次
        // MAX(fire_at) 聚合查询。
        final nowTick = DateTime.now();
        // SCH-11：只统计**启用任务**的覆盖末端。停用任务的残留 pending
        // 此前会撑住"覆盖末端"⇒ 续算被抑制最长 36h（新任务迟迟排不上）。
        final coverEnd = await latestPendingFireAt(nowTick);
        if (planNeedsExtend(coverEnd,
            now: nowTick, threshold: SchedulerConfig.planExtendThreshold)) {
          await stepGuarded('replan(tick)', replan);
        }
      } on Object catch (e) {
        // 兜底：留痕 + 审计，绝不放异常逃出本闭包（zone handler 只记录，
        // 且本 tick 的续算已注定不完整，下个 tick 会自然补上）。
        await stepGuarded('extendChain(tick)', () async {
          await logs.append(
              source: 'schedule',
              action: 'extendChain(tick)',
              status: 'failed',
              message: '$e');
        });
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
    // 🔴 R94 / ARCH-01 + NAT-03：**守卫自恢复**。
    //
    // 旧实现是 `service.invoke('guard', {'enabled': true})` —— 把指令投回
    // **UI isolate**，可那边根本没有 `service.on('guard')` 消费者（消费者只在
    // 本引擎里）。于是"引擎重启后自动恢复守卫"是一条**死路径**：
    // `invoke` 不抛 ⇒ 看起来成功；无人接收 ⇒ 守卫永远不恢复；而界面显示
    // "守卫开着"（prefs 里 guard_enabled 仍是 true）。
    //
    // 现在直接调用本进程内的唯一漏斗 [applyGuardEnabled]，并先核对
    // **麦克风前台服务通行证**是否存活：Android 11+ 没有通行证的后台采音
    // 不抛异常、只回全静音 —— 那会得到一个"在跑但听不见"的守卫，
    // 界面却报运行中（核心安全能力静默失效）。拿不到通行证 ⇒ 不启动采音，
    // 如实回投 `guardActive:false` + 可操作的原因。
    await stepGuarded('guard(boot)',
        () => applyGuardEnabled(true, requireMicPassport: true));
  }
  await broadcast();
  // bootstrap 完成：此后 zone 里的晚发错误只留痕，不再走「启动失败收口」
  // （广播停机 + 撤 FGS）—— 那会误杀一个已注册完毕的引擎。
  _engineBootstrapDone = true;
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

// ═══════════════════════════════════════════════════════════════════════
// R94 · 批次执行骨架（顶层纯逻辑，可注入 ⇒ 可在宿主单测里穷举）
//
// 为什么把这些从 `_engineBody` 闭包里搬出来：
// `_engineBody` 只在 `flutter_background_service` 的隔离里运行（真实 DB /
// 播放器 / 原生桥），宿主上实例化不了 ⇒ 闭包内的逻辑**永远无法被行为测试
// 覆盖**。SCH-01（长动作吞掉同批计划）之所以能存活这么久，一半原因就是
// "判定与执行耦合在一个不可测的闭包里"。搬出来后：
// - `executeBatch` 用注入的 `runAction` / `claim` / `audit` 就能完整跑通一批；
// - `TaskRunLock` / `GuardDelaySlots` / `waitInterruptibly` /
//   `armStoppingRecovery` 都是独立的小对象，行为可被直接断言。
// ═══════════════════════════════════════════════════════════════════════

/// **任务级**执行互斥（SCH-03 / ARCH-08）。
///
/// 语义：同一 `taskId` 在任一时刻至多一个执行实例。`tryClaim` 是**同步**的
/// （无 `await`）—— Dart 单线程下这就是原子操作，不需要锁原语。
///
/// 为什么键是 `taskId` 而不是 `occurrenceId`：需求是"同一条任务别并发跑两份"，
/// 而 `executeDue`（计划条目）、`runNow`（临时条目）、`runGuardPlan`
/// （`@sound@` 条目）用的是**三套不同的 occurrenceId** —— 按 occurrenceId 加锁
/// 等于没加锁。
class TaskRunLock {
  final Map<String, String> _running = <String, String>{};

  /// 抢占成功返回 true；已有执行者返回 false（调用方应回 `busy`）。
  bool tryClaim(String taskId, String occurrenceId) {
    if (_running.containsKey(taskId)) return false;
    _running[taskId] = occurrenceId;
    return true;
  }

  /// 释放（`finally` 里调用；未持有时是 no-op）。
  void release(String taskId) => _running.remove(taskId);

  /// 当前持锁的 occurrenceId（null = 该任务空闲）。
  String? holder(String taskId) => _running[taskId];

  /// 正在执行的任务数（诊断/测试用）。
  int get activeCount => _running.length;
}

/// 门禁拒绝结果：`action` 决定审计行的 action 名（runPause / condition /
/// probability），`message` 是给用户看的原因。
typedef BatchDeny = ({String action, String message});

/// 单条动作的**执行预算**上限（SCH-01）。
///
/// 为什么必须有硬上限：`catchUpLimit` 与 15s tick 的组合从未按"最长动作时长"
/// 校验过（3 × 1800s ≫ 10min）。一条 30 分钟录音会把整批后面所有计划都推到
/// 10 分钟陈旧阈值之外 —— 它们**必然**被判 stale、永不执行。
/// 预算把"单条独占执行槽"的时间钉死在上限内，配合"批次开始时刻判定"，
/// 排队不再被算作迟到。
const Duration maxActionBudget = Duration(minutes: 10);

/// 预算余量：动作声明的时长 + 30s（起播/收尾/写盘的开销）。
const Duration actionBudgetGrace = Duration(seconds: 30);

/// 动作**声明的**时长（预算的基数）。
///
/// 取不到就返回 0（预算 = 余量 30s）：宁可早一点判超时并留痕，也不要让一条
/// 动作无上限地占着执行槽。组合动作看 `primary`；动作集取**最长候选**
/// （否则随机到长动作时预算会误杀）。
Duration declaredActionDuration(Task task, PlannedOccurrence o) {
  final ms = o.durationMs ?? 0;
  Duration of(ActionConfig a) => switch (a) {
        final RecordEvidenceAction r => Duration(seconds: r.seconds),
        final PlayAudioAction p =>
          Duration(milliseconds: ms > 0 ? ms : p.durationSecMax * 1000),
        final SoundscapeAction s => Duration(seconds: s.durationSec),
        final TtsAction t =>
          Duration(seconds: (8 + t.text.length ~/ 4).clamp(15, 120)),
        RandomVibrateAction _ ||
        ContinuousVibrateAction _ ||
        VibrateAction _ =>
          Duration(milliseconds: ms > 0 ? ms : 5000),
        final CompositeAction c => switch (c.primary) {
            final RecordEvidenceAction r => Duration(seconds: r.seconds),
            final PlayAudioAction p => Duration(
                milliseconds: ms > 0 ? ms : p.durationSecMax * 1000),
            final SoundscapeAction s => Duration(seconds: s.durationSec),
            final TtsAction t =>
              Duration(seconds: (8 + t.text.length ~/ 4).clamp(15, 120)),
            _ => Duration.zero,
          },
        final ActionSetAction set => set.candidates.isEmpty
            ? Duration.zero
            : set.candidates
                .map((c) => of(c.action))
                .reduce((a, b) => a > b ? a : b),
        _ => Duration.zero,
      };
  return of(task.action);
}

/// 单条计划的执行预算 = `min(声明时长 + 30s, 10min)`。
Duration actionBudgetFor(Task task, PlannedOccurrence o) {
  final want = declaredActionDuration(task, o) + actionBudgetGrace;
  return want > maxActionBudget ? maxActionBudget : want;
}

/// 一批到期计划的执行骨架（R94 / SCH-01 + 03 + 04 + 07 + ARCH-06）。
///
/// ## 判定与执行解耦（SCH-01）
/// 陈旧判定只用 [batchStart]（批次开始时刻）对**整批**做一次，不用逐条实时
/// `now`。这样"批次内排队"不再被算作迟到：第 1 条是 11 分钟录音时，第 2/3 条
/// 仍然执行。**跨批次**的迟到（上一批就已过期）仍按 [staleAfter] 丢弃 ——
/// 那才是真的"错过"。
///
/// ⚠️ 这**推翻**了 BUG-094 的注释（"必须逐条实时时刻"）。原因：那条修复解决的是
/// "长动作之后补响一批早就该丢的计划"，但它把**排队时间**也算进了迟到 ——
/// 用户自己设的 30 分钟录音，会把同批的提醒全部判死。正确判据是"这一批开始时
/// 它是否已经过期"，而不是"轮到它时它是否已经过期"。
///
/// ## 其它不变量
/// - 每轮开头复检 [isStopping]（SCH-07：停机不得继续起动作）；
/// - [claim] 是 CAS（`markStatus(from: pending)`），返回 0 ⇒ **别人抢走了**，
///   立刻放弃、不写终态（SCH-04）；
/// - [runAction] 有预算，超时落 `failed('执行超时')` 并**写审计**（不得静默）；
/// - 任务不存在/停用 ⇒ 落 `skipped` 且**必有审计**（ARCH-06：旧实现连日志都没有）；
/// - 进程内同任务已在执行 ⇒ **保留 pending**（下一批再试），不丢弃、不刷日志。
Future<void> executeBatch({
  required List<PlannedOccurrence> due,
  required DateTime batchStart,
  required bool Function() isStopping,
  required Future<ExecutionOutcome> Function(Task, PlannedOccurrence) runAction,
  /// 任务解析（必须提供：没有 Task 就无法执行动作）。
  required Future<Task?> Function(String taskId) loadTask,
  Future<BatchDeny?> Function(Task task, PlannedOccurrence o)? admit,
  /// CAS：`pending → running`，返回受影响行数（0 = 已被别人抢走）。
  Future<int> Function(PlannedOccurrence o)? claim,
  /// CAS：`pending → skipped`（陈旧/停用/门禁拒绝时丢弃），返回受影响行数。
  Future<int> Function(PlannedOccurrence o)? discard,
  /// 执行结束后的终态写入（调用方负责 `from: {running}` 的 CAS）。
  Future<void> Function(PlannedOccurrence o, ExecutionOutcome outcome, Task task)?
      finish,
  Future<void> Function(
          String action, String status, String? message, PlannedOccurrence o)?
      audit,
  Duration Function(Task task, PlannedOccurrence o)? budget,
  bool Function(String taskId, String occId)? tryClaim,
  void Function(String taskId)? release,
  Duration staleAfter = const Duration(minutes: 10),
}) async {
  Future<bool> discardWithAudit(
      PlannedOccurrence o, String action, String message) async {
    final n = await discard?.call(o) ?? 1;
    // n == 0 ⇒ 这行已被别人改过（CAS 落空）：**不要**再写一条属于别人的审计。
    if (n == 0) return false;
    await audit?.call(action, 'skipped', message, o);
    return true;
  }

  for (final o in due) {
    // SCH-07：停机后不再起新动作（剩余条目保持 pending，下次启动会补）。
    if (isStopping()) break;

    // SCH-01：整批共用 `batchStart` 做陈旧判定。
    final late = batchStart.difference(o.fireAt);
    if (late > staleAfter) {
      await discardWithAudit(
        o,
        'skip-stale',
        '因排队/超预算丢弃：计划已过期 ${late.inMinutes} 分钟'
            '（>${staleAfter.inMinutes} 分钟阈值），本批开始时刻就已超出补执行窗口',
      );
      continue;
    }

    final task = await loadTask(o.taskId);
    if (task == null) {
      // ARCH-06：旧实现是**无声** `continue` —— 用户既听不到也看不到。
      await discardWithAudit(o, 'disabled',
          '任务已停用/不存在，跳过残留计划（taskId=${o.taskId}）');
      continue;
    }
    if (!task.enabled) {
      await discardWithAudit(o, 'disabled',
          '任务已停用/不存在，跳过残留计划（taskId=${o.taskId}）');
      continue;
    }

    final denied = await admit?.call(task, o);
    if (denied != null) {
      await discardWithAudit(o, denied.action, denied.message);
      continue;
    }

    if (tryClaim != null && !tryClaim(task.id, o.id)) {
      // 进程内已有同任务在执行（runNow / 声音路径）：**保留 pending**，
      // 下一批再试。这里不写审计 —— 每 15s 一条会把执行日志刷爆，
      // 而这条计划并未失败（首轮仍在跑，由它自己落终态）。
      continue;
    }
    try {
      final claimed = await claim?.call(o) ?? 1;
      if (claimed == 0) {
        // SCH-04：另一条连接先抢到了（或用户刚跳过）。放弃，不回写终态。
        continue;
      }
      final limit = budget?.call(task, o) ?? actionBudgetFor(task, o);
      ExecutionOutcome outcome;
      try {
        outcome = await runAction(task, o).timeout(limit);
      } on TimeoutException {
        // 预算用尽：Dart 无法真正取消底层动作，但**执行槽**必须立刻释放，
        // 否则后面所有计划又会被拖进 stale 判定（SCH-01 的原形）。
        outcome = const ExecutionOutcome.failed('执行超时');
        await audit?.call(
          'timeout',
          'failed',
          '执行超时：动作未在预算 ${limit.inSeconds}s 内结束，已放弃等待'
              '（底层动作可能仍在收尾）',
          o,
        );
      } on Object catch (e) {
        outcome = ExecutionOutcome.failed(e.toString());
      }
      await finish?.call(o, outcome, task);
    } finally {
      release?.call(task.id);
    }
  }
}

/// **可中断等待**（SCH-07）：把长等待拆成 ≤[slice] 的片段，每片前后复检。
///
/// 返回 false = 被 [isStopping] 中断（调用方据此落 `skipped('已停机')`）。
/// 为什么不用 `Future.any([delay, stopSignal])`：那需要一条跨模块的取消信号流，
/// 而这里只有一个布尔闸门 —— 2 秒粒度足够（用户感知"立刻停"），
/// 且不引入新的生命周期对象（多一个可能泄漏的 Completer）。
Future<bool> waitInterruptibly(
  Duration total, {
  required bool Function() isStopping,
  Duration slice = const Duration(seconds: 2),
}) async {
  var left = total;
  while (left > Duration.zero) {
    if (isStopping()) return false;
    final step = left < slice ? left : slice;
    await Future<void>.delayed(step);
    left -= step;
  }
  return !isStopping();
}

/// 停机闸门的**超时复位**（SCH-15）。
///
/// `stopping` 是单向闸门（tick / executeDue / replan 全部早退），其正确性
/// 完全依赖"随后一定 `stopSelf()` 成功"。`stopSelf` 失败时引擎会成为僵尸：
/// FGS 通知还在、原生 `isRunning` 仍为 true（用户再点开启只会得到
/// "Service already running"）、而自己不再做任何工作。
///
/// 这里在 [grace] 之后调用 [onReset] 复位闸门，让**还活着**的 isolate 重新可
/// 服务。返回 Timer 便于调用方在确认退出时取消（当前实现不取消：
/// 若 stopSelf 随后真的成功，isolate 会被销毁，Timer 自然消失）。
Timer armStoppingRecovery({
  required void Function() onReset,
  Duration grace = const Duration(seconds: 30),
  Timer Function(Duration, void Function())? timerFactory,
}) {
  final make = timerFactory ?? (Duration d, void Function() cb) => Timer(d, cb);
  return make(grace, onReset);
}

/// 守卫「延时执行」的**多槽**定时器表（SCH-14 / ARCH-07）。
///
/// 旧实现是单槽（`guardDelayTimer?.cancel(); guardDelayTimer = Timer(...)`）：
/// 第二个声音事件会把第一个延时计划**静默**取消 —— 若编排是"多个任务各延时
/// 各的"，后一个事件直接吞掉前一个任务的执行，且日志里只有一条"已排定"。
/// 与 BUG-087（replan 触发源静默消失）同族：**触发源不得静默消失**。
///
/// 语义：
/// - 不同 key ⇒ 各占一槽，互不干扰；
/// - 同 key 再次排定 ⇒ 取消旧的，并通过 [onSuperseded] 留痕（**必须可见**）；
/// - [cancelAll] 用于关守卫 / 停引擎（用户说"关"就不能再有已排定的声音）。
class GuardDelaySlots {
  GuardDelaySlots({
    this.onSuperseded,
    Timer Function(Duration, void Function())? timerFactory,
  }) : _timerFactory =
            timerFactory ?? ((Duration d, void Function() cb) => Timer(d, cb));

  final void Function(String key)? onSuperseded;
  final Timer Function(Duration, void Function()) _timerFactory;
  final Map<String, Timer> _slots = <String, Timer>{};

  /// 当前待发的槽数（诊断/测试用）。
  int get length => _slots.length;

  bool isPending(String key) => _slots.containsKey(key);

  void schedule({
    required String key,
    required Duration delay,
    required void Function() onFire,
  }) {
    final old = _slots.remove(key);
    if (old != null) {
      old.cancel();
      onSuperseded?.call(key);
    }
    _slots[key] = _timerFactory(delay, () {
      _slots.remove(key);
      onFire();
    });
  }

  /// 取消单个槽（返回是否真的取消了）。
  bool cancel(String key) {
    final t = _slots.remove(key);
    if (t == null) return false;
    t.cancel();
    return true;
  }

  /// 取消全部槽（关守卫 / 停机）。
  void cancelAll() {
    for (final t in _slots.values) {
      t.cancel();
    }
    _slots.clear();
  }
}
