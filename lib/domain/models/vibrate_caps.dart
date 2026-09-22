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
library;

class VibrateCaps {
  const VibrateCaps({
    required this.hasVibrator,
    required this.hasAmplitudeControl,
    required this.hasEnvelope,
    required this.minControlPointMs,
    this.platform = 'unknown',
    this.backgroundSupported = true,
  });

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
  factory VibrateCaps.fromMap(Map<String, dynamic> m) => VibrateCaps(
        hasVibrator: m['hasVibrator'] as bool? ?? false,
        hasAmplitudeControl: m['hasAmplitudeControl'] as bool? ?? false,
        hasEnvelope: m['hasEnvelope'] as bool? ?? false,
        minControlPointMs: (m['minControlPointMs'] as num?)?.toInt() ?? 20,
        platform: m['platform'] as String? ?? 'unknown',
        backgroundSupported: m['backgroundSupported'] as bool? ?? true,
      );

  Map<String, dynamic> toMap() => {
        'hasVibrator': hasVibrator,
        'hasAmplitudeControl': hasAmplitudeControl,
        'hasEnvelope': hasEnvelope,
        'minControlPointMs': minControlPointMs,
        'platform': platform,
        'backgroundSupported': backgroundSupported,
      };

  /// 能给出"完整强度"的设备（包络或振幅控制任一）。
  bool get canExpressAmplitude => hasVibrator && (hasEnvelope || hasAmplitudeControl);

  @override
  String toString() => 'VibrateCaps(platform=$platform, vibrator=$hasVibrator, '
      'amplitude=$hasAmplitudeControl, envelope=$hasEnvelope, '
      'minControlPoint=${minControlPointMs}ms, bg=$backgroundSupported)';

  @override
  bool operator ==(Object other) =>
      other is VibrateCaps &&
      other.hasVibrator == hasVibrator &&
      other.hasAmplitudeControl == hasAmplitudeControl &&
      other.hasEnvelope == hasEnvelope &&
      other.minControlPointMs == minControlPointMs &&
      other.platform == platform &&
      other.backgroundSupported == backgroundSupported;

  @override
  int get hashCode => Object.hash(hasVibrator, hasAmplitudeControl, hasEnvelope,
      minControlPointMs, platform, backgroundSupported);
}
