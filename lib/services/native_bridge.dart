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

  // ---------------- 环境状态（v1.7 条件层扩展） ----------------

  /// 是否正在通话（含 VoIP/视频通话）。
  ///
  /// 由 `AudioManager.getMode()` 判定（MODE_IN_CALL / MODE_IN_COMMUNICATION），
  /// **不需要任何权限** —— 这是刻意选择：用 `TelephonyManager` 读通话状态要
  /// READ_PHONE_STATE，会给使用者增加授权负担，也与最小权限原则冲突。
  ///
  /// 返回 null 表示**本平台无法判定**（如 iOS 无对应桥接）。调用方按
  /// "未通话"处理（与电池条件的既有约定一致），详见 `TaskCondition` 类文档。
  static Future<bool?> isInCall() => _invoke<bool>('callState');

  /// 当前网络类型。
  ///
  /// 取值：`wifi` / `cellular` / `ethernet` / `vpn` / `none` / `other` / `unknown`。
  ///
  /// **`unknown` 的语义是"无法判定"，不是"某种确定的网络"**：原生侧在
  /// `ConnectivityManager` 取不到、或拿到了活跃网络却读不出 capabilities 时返回它，
  /// 桥不可用时 Dart 侧也回落到它。`none` 才是"确实没有活跃网络"这个确定状态。
  ///
  /// 判定顺序（原生侧）为 wifi → cellular → ethernet → vpn，即**物理承载优先**：
  /// 只有当前网络的 capabilities 里连物理承载都读不到时才会落到 `vpn`。
  /// 因此 `vpn` 的语义是"活跃网络是 VPN 且未能读出底层承载"，而不是
  /// "一定不在 Wi-Fi 下"。**在真实 VPN 场景下的取值尚未在设备上验证**
  /// （见 docs/12 §18.6 观察项）。
  static Future<String> networkType() async {
    final r = await _invoke<String>('networkType');
    return r ?? 'unknown';
  }

  /// 是否在 Wi-Fi 下；**无法判定时返回 null**（调用方按"满足"处理）。
  ///
  /// `unknown` 与桥不可用一样属于"无法判定"，必须返回 `null` 而不是 `false`：
  /// 两者对条件层是完全相反的后果 —— `false` 会**拦下**任务并在审计里写
  /// "不在 Wi-Fi 下"（一个我们其实不知道的原因），`null` 才按既有约定放行。
  /// 把"读不到"误报成"不满足"正是 `TaskCondition` 类文档要避免的
  /// "某平台读不到状态就把全部自动化静默停掉"（BUG-041）。
  static Future<bool?> isOnWifi() async {
    final t = await _invoke<String>('networkType');
    if (t == null || t == 'unknown') return null;
    return t == 'wifi';
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
