/// 振动设备能力描述（docs/20 §5.1 / FR-38）。
///
/// 纯数据模型，**放在 domain 层**：`native_bridge`（services）负责把原生
/// 回执解析成它，`vibrate_resolve`（scheduling）与 UI 消费它。
/// 反向依赖（domain → services）会让纯函数单测必须拉起平台通道，故不这么做。
///
/// ⚠️ 本类存在的理由（docs/20 §2.2）：Android 上「设备不支持振幅控制」时
/// **所有非零振幅一律被当成 100%**（官方文档原文），同一份配置在不同设备上
/// 体感完全不同**且不报错**。这正是本项目最忌讳的**静默降级** ——
/// 所以能力必须显式探测、显式上报、显式告知用户。
///
/// ⚠️ NAT-05（R94）：一个对象里混着两种生命周期不同的数据 ——
/// **静态能力**（振动器/振幅/包络/后台支持，进程内不变，可缓存）与
/// **动态系统状态**（[VibrateCaps.ringerMode] / [VibrateCaps.dndActive]，
/// 用户随时会切，必须现读）。前者缓存用 [VibrateCaps.staticOnly] 投影，
/// 后者每次执行前用 [VibrateCaps.withEnvironment] 拼回（见
/// `VibrateSession.environment()` 的 ≤2s TTL）。原生回执仍是同一个 Map
/// （桥契约不动），拆分发生在**消费与缓存**层。
library;

/// `AudioManager.RINGER_MODE_*` 常量（NAT-02：值用本地 SDK
/// `javap -constants` 核对，自 API 1 未变）。
///
/// 为什么抽成常量而不是散落字面量：这三个值曾经被写反过
/// （代码里 0=正常 / 2=振动），而那种错误**没有任何编译期或运行期信号**，
/// 只会让"调用成功却没震"的归因链整体反向（正常被误报、静音被漏报）。
/// 命名 + 单一真源 + 单测锁，是这类错误唯一的防御。
abstract final class RingerMode {
  /// 读不到（原生哨兵；`vibrateCapabilities` 读异常时回它）。
  static const int unknown = -1;

  /// 静音（`RINGER_MODE_SILENT = 0`）：**通知类振动会被系统整条吞掉**。
  static const int silent = 0;

  /// 振动（`RINGER_MODE_VIBRATE = 1`）：通知以振动呈现（该态下通知用法本就震）。
  static const int vibrate = 1;

  /// 正常响铃（`RINGER_MODE_NORMAL = 2`）。
  static const int normal = 2;
}

class VibrateCaps {
  const VibrateCaps({
    required this.hasVibrator,
    required this.hasAmplitudeControl,
    required this.hasEnvelope,
    required this.minControlPointMs,
    this.platform = 'unknown',
    this.backgroundSupported = true,
    this.ringerMode = RingerMode.unknown,
    this.dndActive,
  });

  /// `AudioManager.ringerMode`：**0 = 静音 / 1 = 振动 / 2 = 正常**，
  /// [RingerMode.unknown]（-1）= 读不到。
  ///
  /// ⚠️ NAT-02（R94）：这三个值曾把 0 与 2 写反（0=正常、2=振动）——
  /// 后果是绝大多数处于正常(2)的手机被判"振动中/被吞"（假告警），
  /// 而真正静音(0)时反被判"正常"（漏告警）。常量值见 [RingerMode]。
  ///
  /// 为什么必须上报（R93，用户报障"手机震动不好使"的根因链）：
  /// 振动按 `USAGE_NOTIFICATION`（`respectDnd=true`）下发时，**系统静音 /
  /// 勿扰会把整条振动吞掉**，而 `vibrator.vibrate(...)` 依然返回成功 ——
  /// 我们的回执于是写着 success，用户却什么都没感觉到（最坏的静默失败）。
  /// 把响铃模式一起读回来，审计日志才能回答"调用了为什么没震"。
  ///
  /// ⚠️ 本字段是**动态系统状态**，不是静态能力（NAT-05）：消费方必须每次
  /// 执行前现读（`VibrateSession.environment()`，≤2s TTL），不得随能力
  /// 快照长期缓存；缓存里只许出现 [staticOnly] 投影（-1 / null）。
  final int ringerMode;

  /// 系统「勿扰」是否正在拦截通知
  /// （`currentInterruptionFilter != INTERRUPTION_FILTER_ALL`）。
  ///
  /// QUA-09（R94）：改为**可空**。`null` = 读不到（Kotlin 侧读不到时回
  /// 哨兵 `-1` 而不是 `false`）；`false` 必须是"确定没开"。
  /// 旧实现把"读不到"折叠成 `false`，审计于是写"系统未开勿扰"，而真相是
  /// "不知道开没开"——排障会被引向错误结论（与 `NativeBridge.isOnWifi()`
  /// 返回 null 而非 false 同一先例，BUG-041）。
  final bool? dndActive;

  /// 无振动器（桌面/测试/部分平板）。
  static const VibrateCaps none = VibrateCaps(
    hasVibrator: false,
    hasAmplitudeControl: false,
    hasEnvelope: false,
    minControlPointMs: 20,
    platform: 'none',
  );

  /// **桥不可用时的取值**：与 [none] 一样保守（不声称任何能力），
  /// 但 platform 标记为 `unknown` 以便审计区分"设备真的没有"与"读不到"。
  ///
  /// 为什么不复用 [none]：两者对用户是同一后果（降级），对**排查**是完全不同的
  /// 结论 —— 与 `NativeBridge.isOnWifi()` 返回 null 而非 false 同一先例
  /// （BUG-041：把"读不到"误报成"不满足"会静默停掉全部自动化）。
  static const VibrateCaps unknown = VibrateCaps(
    hasVibrator: false,
    hasAmplitudeControl: false,
    hasEnvelope: false,
    minControlPointMs: 20,
    platform: 'unknown',
  );

  final bool hasVibrator;

  /// 是否支持振幅控制（`Vibrator.hasAmplitudeControl()`）。
  /// false ⇒ 强度设置**无效**（一律满格），必须告知用户。
  final bool hasAmplitudeControl;

  /// 是否支持包络效果（Android 16 / API 36 的 `areEnvelopeEffectsSupported()`）。
  final bool hasEnvelope;

  /// 包络控制点的最小间隔（毫秒）。框架要求设备至少支持 20ms。
  final int minControlPointMs;

  /// `android` / `ios` / `none` / `unknown`（排查用）。
  final String platform;

  /// **后台是否还能振动**（iOS 上为 false）。
  ///
  /// 为什么做成**数据字段**而不是在 UI 里写 `if (platform == 'ios')`：
  /// 平台判断散落在 UI 里就再也测不到、也审计不到；做成能力字段后，
  /// [VibrateCaps] 的降级说明与 UI 提示条走同一条数据通路
  /// （docs/20 §6「不得假装支持」）。
  ///
  /// iOS：CoreHaptics 在 App 退到后台后被系统暂停 → 后台持续振动**做不到**。
  final bool backgroundSupported;

  /// 解析原生回执。缺失字段一律取保守值（**不猜能力**）。
  ///
  /// ⚠️ `dndActive` 必须容忍三种到达形态（QUA-09）：`bool`（确定状态）、
  /// `num`（Kotlin 哨兵 `-1` = 读不到 ⇒ `null`；`1` 保守按"确定开启"）、
  /// 缺失 ⇒ `null`。**不能**写 `m['dndActive'] as bool? ?? false` ——
  ///  Kotlin 侧（F4，QUA-09）已把读不到改成回 `-1`（Int），旧写法收到它
  /// 会抛 `TypeError`，把 `vibrateCapabilities()` 整条路变成运行时崩溃。
  factory VibrateCaps.fromMap(Map<String, dynamic> m) {
    final dnd = m['dndActive'];
    return VibrateCaps(
      hasVibrator: m['hasVibrator'] as bool? ?? false,
      hasAmplitudeControl: m['hasAmplitudeControl'] as bool? ?? false,
      hasEnvelope: m['hasEnvelope'] as bool? ?? false,
      minControlPointMs: (m['minControlPointMs'] as num?)?.toInt() ?? 20,
      platform: m['platform'] as String? ?? 'unknown',
      backgroundSupported: m['backgroundSupported'] as bool? ?? true,
      ringerMode: (m['ringerMode'] as num?)?.toInt() ?? RingerMode.unknown,
      dndActive: dnd is bool
          ? dnd
          : (dnd is num && dnd.toInt() == 1 ? true : null),
    );
  }

  Map<String, dynamic> toMap() => {
        'hasVibrator': hasVibrator,
        'hasAmplitudeControl': hasAmplitudeControl,
        'hasEnvelope': hasEnvelope,
        'minControlPointMs': minControlPointMs,
        'platform': platform,
        'backgroundSupported': backgroundSupported,
        'ringerMode': ringerMode,
        'dndActive': dndActive,
      };

  /// 能给出"完整强度"的设备（包络或振幅控制任一）。
  bool get canExpressAmplitude => hasVibrator && (hasEnvelope || hasAmplitudeControl);

  /// 只保留**静态能力**的副本：动态系统状态（响铃模式/勿扰）复位为
  /// "读不到"哨兵（NAT-05）。
  ///
  /// 为什么需要它：能力（有没有振动器/振幅/包络）在进程生命周期内不变，
  /// 可以缓存；响铃模式/勿扰是**实时状态**，用户随时会切。把两者塞进同一
  /// 个缓存对象，就会出现"引擎启动时正常 → 用户后来开了勿扰 → 审计仍写
  /// 正常"（漏告警）或反向的假告警（NAT-05 原缺陷）。缓存只许存这个投影，
  /// 动态状态另走 [withEnvironment] 现读拼装。
  VibrateCaps get staticOnly => VibrateCaps(
        hasVibrator: hasVibrator,
        hasAmplitudeControl: hasAmplitudeControl,
        hasEnvelope: hasEnvelope,
        minControlPointMs: minControlPointMs,
        platform: platform,
        backgroundSupported: backgroundSupported,
        ringerMode: RingerMode.unknown,
        dndActive: null,
      );

  /// 贴上**实时**环境状态（NAT-05）：静态能力 + 当前响铃模式/勿扰。
  ///
  /// 与 [staticOnly] 是一对：前者用于缓存投影，后者用于每次执行前把现读
  /// 到的动态状态拼回能力对象（审计/降级判定看到的是同一份完整视图）。
  VibrateCaps withEnvironment({
    required int ringerMode,
    required bool? dndActive,
  }) =>
      VibrateCaps(
        hasVibrator: hasVibrator,
        hasAmplitudeControl: hasAmplitudeControl,
        hasEnvelope: hasEnvelope,
        minControlPointMs: minControlPointMs,
        platform: platform,
        backgroundSupported: backgroundSupported,
        ringerMode: ringerMode,
        dndActive: dndActive,
      );

  /// 系统是否处于"通知类振动会被吞掉"的状态：**静音(0) 或 勿扰**。
  ///
  /// NAT-02：判据曾是 `ringerMode == 1 || ringerMode == 2`（把"振动/正常"
  /// 当成被吞、把"静音"放过）—— 完全反了。正确判据只有静音(0)与勿扰：
  /// 振动模式(1)下通知类振动本就该震，正常(2)更不在列。
  /// `dndActive == null`（读不到）时**不**计入：读不到 ≠ 被吞（BUG-041 口径）。
  bool get notificationsMuted =>
      ringerMode == RingerMode.silent || dndActive == true;

  /// 人话（审计日志直接可用）。映射见 [RingerMode]（NAT-02 修正）。
  String get ringerLabel => switch (ringerMode) {
        RingerMode.silent => '静音',
        RingerMode.vibrate => '振动',
        RingerMode.normal => '正常',
        _ => '读不到',
      };

  @override
  String toString() => 'VibrateCaps(platform=$platform, vibrator=$hasVibrator, '
      'amplitude=$hasAmplitudeControl, envelope=$hasEnvelope, '
      'minControlPoint=${minControlPointMs}ms, bg=$backgroundSupported, '
      'ringer=$ringerLabel($ringerMode), '
      'dnd=${dndActive ?? '未知'})';

  @override
  bool operator ==(Object other) =>
      other is VibrateCaps &&
      other.hasVibrator == hasVibrator &&
      other.hasAmplitudeControl == hasAmplitudeControl &&
      other.hasEnvelope == hasEnvelope &&
      other.minControlPointMs == minControlPointMs &&
      other.platform == platform &&
      other.backgroundSupported == backgroundSupported &&
      other.ringerMode == ringerMode &&
      other.dndActive == dndActive;

  @override
  int get hashCode => Object.hash(hasVibrator, hasAmplitudeControl, hasEnvelope,
      minControlPointMs, platform, backgroundSupported, ringerMode, dndActive);
}
