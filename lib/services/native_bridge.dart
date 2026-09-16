import 'package:flutter/services.dart';

/// 与原生层（Android MainActivity / Kotlin）通信的唯一入口。
///
/// 原生端能力：
/// - setExactAlarms / clearAlarms：把已提交计划的触发时刻写入
///   AlarmManager（setExactAndAllowWhileIdle），Doze 下也能唤醒
///   前台服务执行 —— 双通道触发的“原生子通道”。
/// - exactAlarmSupported / openExactAlarmSettings：Android 12+ 特殊权限。
/// - isIgnoringBatteryOptimizations / requestIgnoreBatteryOptimizations。
/// - openOemAutostart：跳转主流厂商的自启动/电池白名单页。
/// - setServiceShouldRun：开机自启标志（BootReceiver 读取）。
class NativeBridge {
  NativeBridge._();

  static const MethodChannel _ch = MethodChannel(ChannelsMethod.channel);

  static Future<T?> _invoke<T>(String method,
      [Map<String, dynamic>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on PlatformException {
      // 桌面/测试/未实现平台上静默降级；日志由调用方记录。
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 提交精确闹钟（毫秒时间戳列表）。返回成功排布的数量。
  static Future<int> setExactAlarms(List<int> epochMs) async {
    final r = await _invoke<int>('setExactAlarms', {'times': epochMs});
    return r ?? 0;
  }

  static Future<void> clearAlarms() => _invoke<Object?>('clearAlarms');

  static Future<bool> exactAlarmSupported() async {
    final r = await _invoke<bool>('exactAlarmSupported');
    return r ?? false;
  }

  static Future<void> openExactAlarmSettings() =>
      _invoke<Object?>('openExactAlarmSettings');

  static Future<bool> isIgnoringBatteryOptimizations() async {
    final r = await _invoke<bool>('isIgnoringBatteryOptimizations');
    return r ?? true; // 桌面/iOS 视为无需处理
  }

  static Future<void> requestIgnoreBatteryOptimizations() =>
      _invoke<Object?>('requestIgnoreBatteryOptimizations');

  /// vendor: xiaomi|huawei|oppo|vivo|samsung|meizu|oneplus|generic
  static Future<void> openOemAutostart(String vendor) =>
      _invoke<Object?>('openOemAutostart', {'vendor': vendor});

  static Future<void> setServiceShouldRun(bool v) =>
      _invoke<Object?>('setServiceShouldRun', {'value': v});

  static Future<bool> serviceShouldRun() async {
    final r = await _invoke<bool>('getShouldRun');
    return r ?? false;
  }

  /// 守卫模式：前台启动麦克风类型 FGS（while-in-use 通行证）。
  /// 必须在用户前台交互（点击守卫开关）时调用（docs/05 §1.4）。
  static Future<void> startMicService() => _invoke<Object?>('startMicService');

  static Future<void> stopMicService() => _invoke<Object?>('stopMicService');

  /// 震动（毫秒节奏数组，遵循 Android Vibrator 语义：交替的
  /// 静止/震动时长，首元素为起始静止时长）。无震动能力平台静默降级。
  static Future<void> vibrate(List<int> patternMs) =>
      _invoke<Object?>('vibrate', {'pattern': patternMs});

  /// 设置媒体/闹钟音量（0..1 归一化，原生按流最大音量换算）。
  /// 用于远程 volume.set（docs/16 §9），不影响铃声音量。
  static Future<bool> setVolume({double? media, double? alarm}) async {
    final r = await _invoke<bool>('volume.set', {
      if (media != null) 'media': media,
      if (alarm != null) 'alarm': alarm,
    });
    return r ?? false;
  }
}

/// 避免与 services 包内其它 Channels 常量冲突的私有命名空间。
abstract final class ChannelsMethod {
  static const channel = 'sonic_shield/native';
}
