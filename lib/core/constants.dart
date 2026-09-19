/// 全局常量。
///
/// 命名空间约定：
/// - 方法通道：`sonic_shield/native`（Flutter -> 原生）
/// - 事件通道：`sonic_shield/events`（后台服务 -> UI）
/// - 通知渠道：serviceChannel / eventChannel / guardChannel
library;

class AppMeta {
  static const String appName = '声盾 SonicShield';

  /// 必须与 android/app/build.gradle.kts 的 applicationId 一致
  /// （远程 status/device 回执会上报该值）。
  static const String appPackage = 'com.sonicshield.sonic_shield';

  /// 与 pubspec.yaml 的 version 保持同步（远程回执上报，BUG-018）。
  ///
  /// ⚠️ 这是版本号的**第四处**（pubspec / CHANGELOG / HANDOVER / 本常量）。
  /// 它长期被漏改（BUG-049：pubspec 已 1.7.1 而这里仍 1.7.0-alpha.1，
  /// 于是远程 status/device 回执上报的是**过期的版本号**）——
  /// 现已由 `test/version_consistency_test.dart` 强制三者一致。
  static const String version = '1.7.3';
  static const String complianceUrl =
      'https://example.invalid/sonicshield/compliance'; // 占位：发布时替换
}

class Channels {
  static const String method = 'sonic_shield/native';
  static const String events = 'sonic_shield/events';
  static const String service = 'sonic_shield/background';
}

class NotificationChannels {
  static const String service = 'sonicshield_service'; // 前台服务常驻通知
  static const String events = 'sonicshield_events'; // 执行结果通知
  static const String guard = 'sonicshield_guard'; // 声音守卫告警
  static const String evidence = 'sonicshield_evidence'; // 取证完成
}

/// 调度引擎参数（调优入口，均可在设置页覆盖）。
class SchedulerConfig {
  /// 计划滚动视界：一次物化未来多长的触发计划。
  static const Duration planHorizon = Duration(hours: 48);

  /// 剩余计划少于该值时触发续算。
  static const Duration planExtendThreshold = Duration(hours: 12);

  /// 引擎自检周期（应用存活时的兜底 tick）。
  static const Duration engineTick = Duration(seconds: 15);

  /// 单任务原生精确闹钟数量上限（防止超长计划撑爆 AlarmManager）。
  static const int maxNativeAlarmsPerTask = 64;

  /// 一次 tick 内最多补执行多少条逾期计划（防止休眠唤醒后风暴式连响）。
  static const int catchUpLimit = 3;
}

/// 电源管理阈值。
class PowerConfig {
  static const int saverBatteryLevel = 15; // <15% 且未充电 => 省电模式
  static const int lowBatteryLevel = 30; // <30% 提示
}

/// 合规护栏（写死，防止被配置绕过；详见 docs/08 合规白皮书）。
class ComplianceGuardrails {
  /// 默认强制免打扰时段（本地时区）。
  static const int defaultQuietStartHour = 22;
  static const int defaultQuietEndHour = 7;

  /// 系统音量百分比硬上限（media 通道）。
  static const double maxMediaVolumePercent = 100;

  /// 同一任务最短冷却间隔（秒），避免变成连续轰炸。
  static const int minCooldownSeconds = 60;
}
