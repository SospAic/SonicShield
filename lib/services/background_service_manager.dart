import 'dart:async';

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
  }

  Future<bool> start() async {
    final ok = await _svc.startService();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return ok;
  }

  Future<void> stop() async => _svc.invoke('stop');
  Future<void> replan() async => _svc.invoke('replan');

  Future<void> setGuard(bool enabled) async =>
      _svc.invoke('guard', {'enabled': enabled});
  Future<void> setPowerMode(String mode) async =>
      _svc.invoke('powerMode', {'mode': mode});

  bool get isRunning => _last?.running ?? false;
  bool get guardActive => _last?.guardActive ?? false;
}
