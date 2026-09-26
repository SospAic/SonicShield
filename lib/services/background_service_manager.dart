import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_background_service/flutter_background_service.dart';

import '../core/constants.dart';
import '../domain/models/action.dart';
import 'background_engine.dart';
import 'native_bridge.dart';

/// UI 侧对后台服务的封装：启动/停止、开关守卫、订阅引擎状态。
class BackgroundServiceManager {
  BackgroundServiceManager._();

  static final BackgroundServiceManager instance = BackgroundServiceManager._();

  final FlutterBackgroundService _svc = FlutterBackgroundService();

  final _stateCtrl = StreamController<EngineState>.broadcast();
  // 测试缝：注入 state 流以驱动 `engineStateProvider` 的 data/error 分支；
  // 生产代码不设置，走真实 `_stateCtrl.stream`。
  static Stream<EngineState>? _stateOverride;
  @visibleForTesting
  static set stateForTest(Stream<EngineState>? s) => _stateOverride = s;
  Stream<EngineState> get state => _stateOverride ?? _stateCtrl.stream;
  EngineState? _last;
  EngineState? get last => _last;
  // 测试缝：注入 `last` 以驱动依赖它的 UI（下一触发倒计时 / 守卫态渲染）；
  // 生产代码不设置，走真实 `_last`。
  @visibleForTesting
  static set lastForTest(EngineState? s) => instance._last = s;

  /// 远程「立即执行」的待决请求（reqId → 完成器）。
  ///
  /// 引擎隔离内执行完毕后经 `rcRunResult` 回投；端点服务 await 该 Future
  /// 后才回 `rc.ack`，避免"回执成功但实际没出声"（docs/14 §2.1）。
  final _pendingRun = <String, Completer<RunNowResult>>{};
  var _runSeq = 0;

  Future<void> init() async {
    await _svc.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: engineEntryPoint,
        isForegroundMode: true,
        autoStart: false, // 由用户在首页显式开启（合规与功耗友好）
        notificationChannelId: NotificationChannels.service,
        initialNotificationTitle: '声盾 SonicShield',
        initialNotificationContent: '调度引擎运行中',
        foregroundServiceNotificationId: 0x521ED,
        // 不含 microphone：Android 14+ while-in-use 限制下，后台复活的
        // 服务携带 microphone 类型会被拒绝。麦克风访问由本地插件的
        // MicGuardService 在用户前台交互时独立持有（docs/05 §1.4）。
        //
        // 不含 dataSync（F-2，SEC1 第 35 轮）：Android 15+ 对 dataSync 型
        // 前台服务有「24 小时内累计 6 小时」上限，到点系统回调
        // Service.onTimeout；而插件 flutter_background_service_android 6.3.1
        // 的 BackgroundService.java **全文件 0 处 onTimeout**（Config.java:81
        // 只读本处写下的类型位，不与清单求并；BackgroundService.java:169-173
        // 把它算成 startForeground 的 type 位）⇒ 到点即抛
        // android.app.RemoteServiceException 杀进程（Fatal）。本引擎是
        // 7×24 常驻 ⇒ 必然命中。mediaPlayback **不在**该上限清单内，且本工程
        // 后台确为「本地调度 + 定时播放」，语义成立。
        foregroundServiceTypes: const [
          AndroidForegroundType.mediaPlayback,
        ],
      ),
      iosConfiguration: IosConfiguration(
        onForeground: engineEntryPoint,
        onBackground: (ServiceInstance s) async => true, // iOS 后台无 UI 隔离
        autoStart: false,
      ),
    );
    _svc.on('state').listen((m) {
      final data = m ?? <String, Object?>{};
      _last = EngineState(
        running: data['running'] as bool? ?? false,
        pendingCount: (data['pendingCount'] as num?)?.toInt() ?? 0,
        nextFireAt: data['nextFireAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(data['nextFireAt'] as int),
        lastAction: data['lastAction'] as String?,
        guardActive: data['guardActive'] as bool? ?? false,
        guardError: data['guardError'] as String?,
      );
      _stateCtrl.add(_last!);
    });
    _svc.on('rcRunResult').listen((m) {
      final reqId = (m ?? <String, Object?>{})['reqId'] as String? ?? '';
      final c = _pendingRun.remove(reqId);
      if (c == null || c.isCompleted) return;
      c.complete(RunNowResult(
        ok: (m!['ok'] as bool?) ?? false,
        message: (m['message'] as String?) ?? '',
      ));
    });
  }

  Future<bool> start() async {
    final hook = startHook;
    if (hook != null) return hook();
    final ok = await _svc.startService();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return ok;
  }

  /// 测试缝（与 [invokeHook] 同形）：widget 测试中 `_svc.startService()` 会
  /// 触碰 `FlutterBackgroundService` 平台实例，非 Android/iOS 直接抛
  /// `UnsupportedError`。测试注入本钩子短路；生产代码不设置，走真实启动。
  @visibleForTesting
  static Future<bool> Function()? startHook;

  Future<void> stop() => _invoke('stop');

  /// 测试缝（v1.8）：widget 测试中后台服务未初始化，`invoke(...)` 会**抛**。
  ///
  /// 具体机制：`FlutterBackgroundService.invoke` → `FlutterBackgroundService
  /// Platform.instance`，而该 getter 内部判平台，**非 Android/iOS 直接抛**
  /// `UnsupportedError('FlutterBackgroundService is currently supported for
  /// Android and iOS Platform only.')`（实测：宿主 widget 测试里点一下
  /// 「电源策略」就炸，且异常发生在 `setState` 之前 → 界面停在旧值）。
  ///
  /// 测试注入本钩子短路。生产代码不设置此值，走真实服务调用。
  @visibleForTesting
  static Future<void> Function(String method, Map<String, Object?>? args)?
      invokeHook;

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    final hook = invokeHook;
    if (hook != null) {
      await hook(method, args);
      return;
    }
    _svc.invoke(method, args); // 返回 void（fire-and-forget）
  }

  /// 测试缝（v1.8）：widget 测试中后台服务未初始化，`invoke('replan')`
  /// 会抛（见 `invokeHook`）。测试注入本钩子短路。
  /// 生产代码不设置此值，走真实服务调用。
  @visibleForTesting
  static Future<void> Function()? replanHook;

  Future<void> replan() async {
    final hook = replanHook;
    if (hook != null) {
      await hook();
      return;
    }
    await _invoke('replan');
  }

  /// 开关守卫。
  ///
  /// [micGranted]：**主 isolate 的权威授权结论**（UI 刚 `request()` 出来的）。
  ///
  /// ⚠️ 为什么必须由 UI 传下来、而不是让引擎自己查：引擎跑在
  /// `flutter_background_service` 的隔离里，**没有 Activity**，而
  /// `record` 插件的 `hasPermission()` 在 `activity == null` 时**直接返回 false**
  /// （`record_android-2.2.0/.../PermissionManager.kt:33-36`）——
  /// 与系统实际授权无关。真机实证：`RECORD_AUDIO: granted=true` 的设备上，
  /// 审计里仍然写着"麦克风权限被拒"（BUG-A）。所以授权与否**只能**由
  /// 有能力询问系统的那一侧（主 isolate）回答。
  Future<void> setGuard(bool enabled, {bool? micGranted}) => _invoke('guard', {
        'enabled': enabled,
        if (micGranted != null) 'micGranted': micGranted,
      });
  Future<void> setPowerMode(String mode) => _invoke('powerMode', {'mode': mode});

  /// 远程 `vibrate.stop`（v1.9）：停止全部进行中的振动。
  ///
  /// 两步都要做：
  /// 1. `vibrateStop` 转交引擎 → 清活跃表（**停掉分片续发**，否则下一片
  ///    到期会自己震起来）+ 原生 cancel；
  /// 2. 兜底直调原生 cancel —— 引擎没跑时第 1 步发向不存在的服务没有效果。
  ///    原生 cancel 幂等，引擎在跑时重复调一次无害。
  Future<void> stopVibrate({String reason = '远程停止'}) async {
    await _invoke('vibrateStop', {'reason': reason});
    await NativeBridge.vibrateStop();
  }

  /// 远程「立即执行任务动作」：转交引擎隔离执行并等待结果。
  ///
  /// 引擎未运行时直接返回失败（调用方据此回 `rc.ack ok=false` 并给出
  /// 可操作提示），不静默成功。
  Future<RunNowResult> runNow(String taskId,
      {Duration timeout = const Duration(seconds: 45)}) async {
    if (!isRunning) {
      return const RunNowResult(ok: false, message: '调度引擎未运行');
    }
    final reqId = 'run${_runSeq++}_${DateTime.now().microsecondsSinceEpoch}';
    return _awaitResult(
        reqId, 'runNow', {'taskId': taskId, 'reqId': reqId}, timeout);
  }

  /// 远程指令组里的振动步骤（v1.9，docs/20 §10.1）。
  ///
  /// 与 [runNow] 同构：转交引擎隔离执行并等回投。引擎没跑时直接返回失败 ——
  /// 不在主 isolate 私自下发，因为那样会绕过分片续发与 `vibrate.stop`（见
  /// `background_engine` 的 `vibrateStep` 监听处的注记）。
  Future<RunNowResult> runVibrateStep({
    required ActionConfig action,
    required String occurrenceId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isRunning) {
      return const RunNowResult(ok: false, message: '调度引擎未运行');
    }
    final reqId = 'vib${_runSeq++}_${DateTime.now().microsecondsSinceEpoch}';
    return _awaitResult(reqId, 'vibrateStep', {
      'reqId': reqId,
      'occurrenceId': occurrenceId,
      'action': jsonEncode(action.toJson()),
    }, timeout);
  }

  /// 发出命令并等 `rcRunResult` 回投（超时是**返回值**而非异常）。
  Future<RunNowResult> _awaitResult(String reqId, String method,
      Map<String, Object?> args, Duration timeout) async {
    final completer = Completer<RunNowResult>();
    _pendingRun[reqId] = completer;
    // invoke 返回 void（fire-and-forget）：结果由 rcRunResult 回投。
    _svc.invoke(method, args);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pendingRun.remove(reqId);
      return const RunNowResult(ok: false, message: '引擎执行超时');
    }
  }

  bool get isRunning => _last?.running ?? false;
  bool get guardActive => _last?.guardActive ?? false;

  /// 引擎自报的**守卫启动失败原因**（成功时为 null）。
  ///
  /// 存在的意义（BUG-061 判据的加强）：`waitForGuardActive(true)` 超时只能
  /// 说"没等到"，说不出"为什么没等到"。有了它，UI 就能把麦克风侧的真实
  /// 原因原样转达给用户，而不是一律归咎于"引擎无响应"。
  String? get guardError => _last?.guardError;

  /// 等待引擎回投状态，直到 `guardActive == expected` 或超时。
  ///
  /// 存在意义（BUG-061）：`setGuard()` 是 **fire-and-forget** 的 `invoke`，
  /// 调用返回**不代表生效**。引擎没跑时它发向不存在的服务、完全没反应，
  /// UI 若只看"调用完成"就会显示错误的成功。
  /// 有了这个等待，UI 才能区分"生效了"与"引擎无响应"。
  ///
  /// 返回 true = 观察到期望状态；false = 超时。
  ///
  /// ⚠️ 刻意**不用** `state.firstWhere(...)`：`firstWhere` 不带 `orElse`
  /// 会在流关闭时抛 `Bad state: No element`（全局锁 EBI-04 禁止该形态）。
  /// 这里用 Completer + `timeout(onTimeout:)`，超时是**返回值**而非异常。
  Future<bool> waitForGuardActive(bool expected,
      {Duration timeout = const Duration(seconds: 3)}) async {
    if (guardActive == expected) return true;
    final c = Completer<bool>();
    StreamSubscription<EngineState>? sub;
    sub = state.listen((s) {
      if (c.isCompleted) return;
      if (s.guardActive == expected) {
        c.complete(true);
      } else if (expected && s.guardError != null) {
        // 引擎已**明确**报出启动失败原因（如"麦克风启动失败：…"）：
        // 这时不可能再等到 `guardActive:true`，立刻结束等待把原因交给 UI，
        // 不必白等满 3 秒再报一句含糊的"引擎无响应"。
        c.complete(false);
      }
    });
    try {
      return await c.future.timeout(timeout, onTimeout: () => false);
    } finally {
      await sub.cancel();
    }
  }
}

/// 远程「立即执行」结果。
class RunNowResult {
  const RunNowResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}
