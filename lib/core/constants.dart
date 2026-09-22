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
  static const String version = '1.9.0-alpha';
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

/// `SharedPreferences` 键名（**唯一真源**）。
///
/// ## 为什么要集中（BUG-070，2026-09-22）
/// `quiet_start` / `quiet_end` 自 v1.0 起就由设置页**写入**，
/// 但全仓**没有任何执行路径读取它们** —— 键名字符串只出现在设置页与它的
/// widget 测试里，于是形成一条"看着接通、其实是断的"链路：
/// 用户把免打扰窗口调窄，界面回显也变了，**实际执行仍恒为 22:00–07:00**。
///
/// 教训与 BUG-065（`Directory.toString()` 不是路径）同族：
/// **凡是"写在一处、用在另一处"的字符串，都要有唯一真源 + 一条端到端锁**，
/// 否则静态检查全绿而功能是空的。
abstract final class PrefsKeys {
  /// 免打扰开始小时（0–23）。读取方：`background_engine.replan()`
  /// 与 `endpoint_service._rematerialize()`，经 `normalizeQuietWindow()` 归一化。
  static const String quietStartHour = 'quiet_start';

  /// 免打扰结束小时（0–23）。读取方同上。
  static const String quietEndHour = 'quiet_end';

  /// 夜间独立豁免**主开关**（v1.9，docs/20 §8.1）。默认 false。
  ///
  /// 读取方：`background_engine.replan()`、`endpoint_service._rematerialize()`、
  /// 设置页与任务编辑器（第二把钥匙的可见性）。
  ///
  /// ⚠️ 为什么放 `SharedPreferences` 而不是 DB 的 kv 表：
  /// 本仓库把**全部用户级设置**（电源策略 / 免打扰时段 / 守卫开关）都放在
  /// prefs —— 主开关是同类东西，走同一个存储才有"设置都在一处"的可预期性；
  /// 而且 prefs 是**进程内同步可读**的，UI 读它不产生平台往返
  /// （kv 表要走一次 sqflite 查询，会让整页 widget 测试留下未完成的 Timer）。
  static const String quietExemptMaster = 'quiet_exempt_master';
}
