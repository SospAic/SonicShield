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
  ///
  /// 🔴 第八十四轮用户基线：**禁止** `alpha+N` 之类预发布后缀表述；
  /// 版本号一律为纯 `x.y.z`，且**每轮迭代至少 +0.0.1**（不得同号复用）。
  /// 迭代日期改由 [buildDate] 承载（见 [displayVersion]）。
  static const String version = '1.9.11';

  /// 与 pubspec.yaml 的 `+N` **构建号**同步（第七十七轮基线新增）。
  ///
  /// 为什么单独立一个常量：[version] 只到 `x.y.z[-pre]`，而**每次迭代抬的是
  /// 构建号**（`+17` → `+18`）。若界面只显示 [version]，用户**看不出本轮
  /// 迭代已经更新**——与「每次迭代 APP 中显示的版本必须同步更新」这条基线
  /// 相悖（历史上设置页底部还长期写死 `v1.0.0`，属同类漂移）。
  ///
  /// 因此约定：**界面一律显示 [displayVersion]**（含构建号）；
  /// `test/version_consistency_test.dart` 强制 [buildNumber] 与 pubspec 一致、
  /// 并锁死界面不得再出现写死的版本号。
  static const String buildNumber = '34';

  /// 迭代日期（年月日），每次迭代随版本信息一起更新。
  ///
  /// 项目基线（第七十七轮新增）：**每次迭代除了抬版本信息，还必须在版本信息后
  /// 追加年月日**——让用户/远程回执能直接看到本轮构建日期，而不必靠 `+N`
  /// 反推。`test/version_consistency_test.dart` 强制其格式为 `YYYY-MM-DD`、
  /// 且 [displayVersion] 必须携带该日期。
  static const String buildDate = '2026-10-25';

  /// 面向用户的完整版本串，设置页「关于」区块显示的就是它。
  ///
  /// 🔴 第八十四轮用户基线：格式固定为 **`版本号(当前日期)`**，
  /// 例：`1.9.1(20261011)` —— 日期为**紧凑 8 位** `YYYYMMDD`（不带连字符），
  /// 直接跟在版本号后的圆括号里。**禁止** `alpha+N` 之类预发布后缀。
  static String get displayVersion {
    final d = buildDate.replaceAll('-', '');
    return '$version($d)';
  }

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

  /// 来电（BUG-145）。
  ///
  /// 为什么必须**单独一个渠道**：`events` 是"任务执行结果"的低价值流，
  /// 用户完全可能把它静音或降级；来电却必须能打断一切。两者共用渠道的后果
  /// 就是"来电通知被当成执行日志静音掉"—— 即"来电丢失"。
  /// 独立渠道还让用户能在系统设置里单独给来电放行全屏意图与响铃。
  static const String calls = 'sonicshield_calls';
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

  /// 开始小时的可调范围（**只能调窄，不能调宽**，docs/08 §51 / FR-62）。
  ///
  /// BUG-107：设置页下拉此前是 `20..23`，用户能把窗口从 22:00 提前到 20:00
  /// —— 比默认**更宽**，直接违反护栏语义（而页面文案还写着"只能调窄"）。
  /// 区间收窄到这里，`_load()` 也会把历史脏值（20/21）归一到 22。
  static const int minQuietStartHour = 22;
  static const int maxQuietStartHour = 23;

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
  /// **v79 语义改造**：本开关是"批量默认值"，不再是**双钥匙**。任务级
  /// `Task.quietExempt`（`bool?` 三态）= `null` 跟随本开关 / `true` 强制豁免 /
  /// `false` 强制不豁免，**双向覆盖**（`exempt = taskExemptOverride ?? allowQuietExempt`）。
  ///
  /// 读取方：`background_engine.replan()`（关主开关时清除已落库的豁免计划，
  /// 但**保留** `quietExempt == true` 的强制豁免例外）、
  /// `endpoint_service._rematerialize()`、设置页与任务编辑器（三态回填与例外清单）。
  ///
  /// ⚠️ 为什么放 `SharedPreferences` 而不是 DB 的 kv 表：
  /// 本仓库把**全部用户级设置**（电源策略 / 免打扰时段 / 守卫开关）都放在
  /// prefs —— 主开关是同类东西，走同一个存储才有"设置都在一处"的可预期性；
  /// 而且 prefs 是**进程内同步可读**的，UI 读它不产生平台往返
  /// （kv 表要走一次 sqflite 查询，会让整页 widget 测试留下未完成的 Timer）。
  static const String quietExemptMaster = 'quiet_exempt_master';

  /// 声音守卫（麦克风常开检测）开关。默认 false。
  ///
  /// 读取方：引擎装配 `SoundGuardService` 时决定是否起采流
  /// （`background_engine` 的 `guardEnabled`）；
  /// 写入方：引擎 `setGuardEnabled` 与守卫页开关；**撤销麦克风通行证时
  /// 必须一并置 false**（通行证已被撤，若仍持久化为 true，下次启动会
  /// 在无通行证的情况下尝试起麦克风 —— 系统会直接拒，用户看到的是
  /// "守卫开关是开的但没反应"）。
  ///
  /// ⚠️ 抽成常量而不是散落的裸字符串：这是**跨进程共享的持久化键**
  /// （引擎 isolate 与 UI isolate 都读它），拼错一个字母不会报错，
  /// 只会表现为"守卫开关记不住"。
  static const String guardEnabled = 'guard_enabled';

  /// 「实时随机动态反击」开关（v2.0 阶段 D）。默认 false。
  ///
  /// 读取方：引擎装配 `ReactiveCounterService` 时决定是否喂入声音事件；
  /// 写入方：守卫页的「动态反击」开关。默认关闭 —— 这是会**主动出声**的
  /// 行为，必须由用户显式开启（与其它"会自动执行"的能力同一口径）。
  static const String reactiveCounterEnabled = 'reactive_counter_enabled';

  /// 「闹钟特权通道」开关（2026-10，docs/59 缺口1）。默认 **true**。
  ///
  /// 读取方：引擎 `pushExactAlarms` 排布通道B 时决定用
  /// `AlarmManager.setAlarmClock`（Doze 中唯一保证准时的公开通道）还是
  /// `setExactAndAllowWhileIdle`（9 分钟最小间隔、深度 Doze 可被推迟）；
  /// 写入方：设置页「后台保活」分区。关掉它的理由：状态栏常驻闹钟图标
  /// （用户可见性契约）。**关掉 = 准时性降级**，UI 有同字说明。
  static const String alarmClockChannel = 'alarm_clock_channel';

  /// **全局执行总开关**（v1.9，docs/20 §9）。取值：`auto` / `on` / `off`。
  ///
  /// - `auto`（默认）= 自动按法定休息日暂停：窗口为
  ///   `[休息日前一天 20:00, 连续休息日最后一天 21:00)`，窗口内所有任务默认
  ///   跳过，出窗自动恢复；
  /// - `on`  = 强制开启（忽略自动窗口，永不暂停）；
  /// - `off` = 强制关闭（始终暂停，只放行任务级例外 `Task.forceRun`）。
  ///
  /// 读取方：`background_engine.pausedAt()`（执行层裁决）、设置页与远程
  /// `rc.status` 回执。判定真源在纯函数 `RunPause.paused`（`run_pause.dart`）。
  ///
  /// ⚠️ 与 [quietExemptMaster] 是**两个独立开关**：夜间豁免管"免打扰时段能否
  /// 出声"，本开关管"整体是否停摆"，语义正交，互不覆盖。
  /// ⚠️ 远程**可以**写本键（`RcCmd.runMasterSet`，须 `script` 权限位）——
  /// 与「远程不得写 [quietExemptMaster]」的合规红线不同：那是单机护栏授权，
  /// 这是用户自己的整体刹车，允许持权对端代为切换。
  static const String runMasterMode = 'run_master_mode';

  /// 电源模式（`performance` / `balanced` / `saver`）。默认 `balanced`。
  ///
  /// 写入方：设置页「执行与护栏」TAB 的电源策略分段控件。
  /// 读取方：`background_engine`（启动时 + `powerMode` 热切换）。
  ///
  /// 🔴 语义（v1.9.1 补）：**仅 `performance`** 档由引擎持有**常驻
  /// `PARTIAL_WAKE_LOCK`** —— 锁屏 / Doze 下不让 CPU 休眠，使通道 A（应用内
  /// Dart Timer）也能持续运行，而不只依赖通道 B（精确闹钟）。代价 = 持续耗电。
  ///
  /// ⚠️ BUG-070「写在一处、用在另一处」同族：本键此前**只写不读** ——
  /// 设置页写入、`setPowerMode` 发 `powerMode` invoke，但引擎里**没有接收方**、
  /// 全仓也无人读取 ⇒ 电源模式对运行时**零影响**。现补上引擎侧读取 + 唯一副作用，
  /// 并集中到本类作为唯一真源。
  static const String powerMode = 'power_mode';
}
