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
/// `vibrateStop` / `vibrate`）。未实现的方法返回 `FlutterMethodNotImplemented`，
/// Dart 侧 `NativeBridge._invoke` 会把它降级成 null —— 与既有约定一致。
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
    default:
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
