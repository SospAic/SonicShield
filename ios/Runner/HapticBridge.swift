import CoreHaptics
import Flutter
import UIKit

/// iOS 振动桥（docs/20 §6 / FR-36 / FR-37）。
///
/// ## 为什么必须自己写
///
/// Flutter 自带的 `HapticFeedback` 只有 light/medium/heavy 三档固定触感 ——
/// **没有时长、没有振幅**。而本需求的"持续振动 + 可设定随机振幅"在 iOS 上
/// 只有 CoreHaptics 能表达（`hapticContinuous` 事件的 `hapticIntensity`
/// 参数即振幅，`hapticSharpness` 即锐度）。
///
/// ## 能力边界（必须如实上报，不得假装支持）
///
/// - **后台振动不可用**：App 退到后台后 CoreHaptics 会被系统暂停。
///   `vibrateCapabilities` 因此返回 `backgroundSupported = false`，
///   Dart 侧的 `vibrateDegradations()` 会据此产出"后台无法振动"的说明并让
///   UI 明示。这正是 FR-34 口径修正（静默降级 → **明示**降级）的落地。
/// - 无 Taptic Engine 的设备（旧 iPad 等）`supportsHaptics == false`。
///
/// ## 通道
///
/// 与 Android 侧同名 `sonic_shield/native`，方法名逐一对齐
/// （`vibrateCapabilities` / `vibrateWaveform` / `vibrateEnvelope` /
/// `vibrateStop` / `vibrate` / `exactAlarmSupported`）。
///
/// ## NAT-12（R94）：未实现的方法必须**可区分**，不得静默 no-op 成功
/// 其余约 20 个 Android 专属方法（精确闹钟 / 电池白名单 / 投屏抓帧 / 输入注入 /
/// 麦克风 FGS …）在 iOS 上返回 `FlutterMethodNotImplemented` —— Dart 侧
/// `NativeBridge._invoke` 收到的是 `MissingPluginException`，与"原生明确
/// 报错"（`PlatformException`）**可区分**（NAT-13 的错误分类），据此判
/// "平台不支持"而不是"调用失败"。**不要**改成返回 true/false 之类的
/// 假成功回执 —— 那会让 Dart 侧把"没实现"当成"做到了"。
///
/// `exactAlarmSupported` 是唯一的例外：iOS **没有** Android 的「闹钟和提醒」
/// 特殊权限概念（`SCHEDULE_EXACT_ALARM` 是 Android 12+ 的东西），该检查在
/// iOS 上**不适用**。恒返回 false 会让 Dashboard 永久渲染一条"精确闹钟权限
/// 未开启"的告警 —— 一个 iOS 上不存在也修不了的提示（NAT-12 的误报根因）。
/// 故这里返回 **true**（语义："本平台不适用该检查"），由 Dart 侧保持
/// `Future<bool>` 不变；消费侧（Dashboard）归 F6。
///
/// ## 未验证项（UNVERIFIED，无 macOS/Xcode 环境）
/// - CoreHaptics 在后台引擎回调中的实际触感表现；
/// - `flutter_background_service_ios` 的 `BGAppRefreshTask` 调度时机
///   （系统可完全跳过，iOS 上定时任务**没有可承诺的准时性**）；
/// - TTS / 播放由 `flutter_tts` / `just_audio` 插件原生支持，不在本桥范围。
final class HapticBridge {

  private var engine: CHHapticEngine?
  private var player: CHHapticAdvancedPatternPlayer?

  /// 在隐式引擎的 binaryMessenger 上注册通道。
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "sonic_shield/native",
      binaryMessenger: messenger
    )
    let impl = HapticBridge()
    channel.setMethodCallHandler { call, result in
      impl.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "vibrateCapabilities":
      result(capabilities())
    case "vibrateWaveform":
      result(vibrateWaveform(args: call.arguments as? [String: Any] ?? [:]))
    case "vibrateEnvelope":
      result(vibrateEnvelope(args: call.arguments as? [String: Any] ?? [:]))
    case "vibrateStop":
      stop()
      result(true)
    case "vibrate":
      // v1.x 固定节奏入口：与 waveform 同一形状（timings 交替 静止/振动）。
      let pattern = (call.arguments as? [String: Any])?["pattern"] as? [Int] ?? []
      result(vibrateWaveform(args: [
        "timings": pattern,
        "repeat": -1,
        "useAlarmUsage": false,
      ]))
    case "exactAlarmSupported":
      // NAT-12：iOS 无 Android 精确闹钟权限概念 ⇒ 返回 true（"不适用该检查"），
      // 见类文档：恒 false 会造成永久误报。
      result(true)
    default:
      // NAT-12：未实现的方法返回**可区分**的 notImplemented（Dart 侧得到
      // MissingPluginException ⇒ "平台不支持"），绝不静默假成功。
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 能力

  private func capabilities() -> [String: Any] {
    let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    return [
      "hasVibrator": supported,
      // CoreHaptics 的 hapticIntensity 就是振幅 → 支持
      "hasAmplitudeControl": supported,
      // 连续事件 + 动态参数可表达包络 → 支持
      "hasEnvelope": supported,
      "minControlPointMs": 20,
      "platform": "ios",
      // ⚠️ 后台被系统暂停，如实上报
      "backgroundSupported": false,
    ]
  }

  // MARK: - 引擎

  private func ensureEngine() throws -> CHHapticEngine {
    if let e = engine, e.playsHapticsOnly { return e }
    let e = try CHHapticEngine()
    e.playsHapticsOnly = true
    e.isAutoShutdownEnabled = true
    e.stoppedHandler = { [weak self] _ in
      self?.engine = nil
      self?.player = nil
    }
    e.resetHandler = { [weak self] in
      try? self?.engine?.start()
    }
    try e.start()
    engine = e
    return e
  }

  private func stop() {
    try? player?.stop(atTime: CHHapticTimeImmediate)
    player = nil
    engine?.stop()
    engine = nil
  }

  // MARK: - 波形（脉冲串）

  /// `timings` 交替「静止/振动」，首元素为起始静止 —— 与 Android 语义一致。
  /// `amplitudes` 为 0..255（静止段为 0）；缺失时按满幅处理。
  private func vibrateWaveform(args: [String: Any]) -> Bool {
    guard let timings = args["timings"] as? [Int], !timings.isEmpty else {
      return false
    }
    let amps = args["amplitudes"] as? [Int]

    var events: [CHHapticEvent] = []
    var t = 0.0
    var i = 0
    while i < timings.count {
      let offMs = timings[i]
      let onMs = (i + 1 < timings.count) ? timings[i + 1] : 0
      t += Double(max(0, offMs)) / 1000.0
      if onMs > 0 {
        let raw = (amps != nil && i + 1 < (amps?.count ?? 0)) ? amps![i + 1] : 255
        // ⚠️ 与 Android 侧同一口径：强度 0 保留给"静止"，
        // 开启段最低取 0.05，否则"低强度"会静默变成"不振动"。
        let intensity = max(0.05, min(1.0, Float(raw) / 255.0))
        events.append(
          CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
              CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
              CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
            ],
            relativeTime: t
          )
        )
        t += Double(onMs) / 1000.0
      }
      i += 2
    }
    if events.isEmpty { return false }
    return play(events: events, advanced: false)
  }

  // MARK: - 包络（持续 + 随机振幅）

  /// `points` 为 `[{intensity, sharpness, durationMs}]`，与 Android 16 包络语义一致。
  /// 最后一点 intensity 为 0 表示收尾（与 Android 侧硬约束对齐）。
  private func vibrateEnvelope(args: [String: Any]) -> Bool {
    guard let raw = args["points"] as? [[String: Any]], raw.count >= 1 else {
      return false
    }
    var events: [CHHapticEvent] = []
    var t = 0.0
    for p in raw {
      let intensity = Float((p["intensity"] as? NSNumber)?.floatValue ?? 0)
      let sharpness = Float((p["sharpness"] as? NSNumber)?.floatValue ?? 0)
      let durMs = (p["durationMs"] as? NSNumber)?.doubleValue ?? 20
      let dur = max(0.02, durMs / 1000.0)
      events.append(
        CHHapticEvent(
          eventType: .hapticContinuous,
          parameters: [
            CHHapticEventParameter(
              parameterID: .hapticIntensity,
              value: max(0.0, min(1.0, intensity))
            ),
            CHHapticEventParameter(
              parameterID: .hapticSharpness,
              value: max(0.0, min(1.0, sharpness))
            ),
          ],
          relativeTime: t,
          duration: dur
        )
      )
      t += dur
    }
    if events.isEmpty { return false }
    return play(events: events, advanced: true)
  }

  private func play(events: [CHHapticEvent], advanced: Bool) -> Bool {
    do {
      let engine = try ensureEngine()
      let pattern = try CHHapticPattern(events: events, parameters: [])
      if advanced {
        let p = try engine.makeAdvancedPlayer(with: pattern)
        player = p
        try p.start(atTime: CHHapticTimeImmediate)
      } else {
        let p = try engine.makePlayer(with: pattern)
        try p.start(atTime: CHHapticTimeImmediate)
      }
      return true
    } catch {
      // 不静默：返回 false，由 Dart 侧留痕并走降级链。
      return false
    }
  }
}
