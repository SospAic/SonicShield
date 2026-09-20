import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_background_service/flutter_background_service.dart';

import '../core/constants.dart';
import 'background_engine.dart';

/// UI 侧对后台服务的封装：启动/停止、开关守卫、订阅引擎状态。
class BackgroundServiceManager {
  BackgroundServiceManager._();

  static final BackgroundServiceManager instance = BackgroundServiceManager._();

  final FlutterBackgroundService _svc = FlutterBackgroundService();

  final _stateCtrl = StreamController<EngineState>.broadcast();
  Stream<EngineState> get state => _stateCtrl.stream;
  EngineState? _last;
  EngineState? get last => _last;

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
        foregroundServiceTypes: const [
          AndroidForegroundType.mediaPlayback,
          AndroidForegroundType.dataSync,
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
    final ok = await _svc.startService();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return ok;
  }

  Future<void> stop() async => _svc.invoke('stop');

  /// 测试缝（v1.8）：widget 测试中后台服务未初始化，`invoke('replan')`
  /// 会返回**永不完成**的 Future（已实测挂死测试）。测试注入本钩子短路。
  /// 生产代码不设置此值，走真实服务调用。
  @visibleForTesting
  static Future<void> Function()? replanHook;

  Future<void> replan() async {
    final hook = replanHook;
    if (hook != null) {
      await hook();
      return;
    }
    _svc.invoke('replan'); // 返回 void（fire-and-forget）
  }

  Future<void> setGuard(bool enabled) async =>
      _svc.invoke('guard', {'enabled': enabled});
  Future<void> setPowerMode(String mode) async =>
      _svc.invoke('powerMode', {'mode': mode});

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
    final completer = Completer<RunNowResult>();
    _pendingRun[reqId] = completer;
    // invoke 返回 void（fire-and-forget）：结果由 rcRunResult 回投。
    _svc.invoke('runNow', {'taskId': taskId, 'reqId': reqId});
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pendingRun.remove(reqId);
      return const RunNowResult(ok: false, message: '引擎执行超时');
    }
  }

  bool get isRunning => _last?.running ?? false;
  bool get guardActive => _last?.guardActive ?? false;

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
      if (s.guardActive == expected && !c.isCompleted) c.complete(true);
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
