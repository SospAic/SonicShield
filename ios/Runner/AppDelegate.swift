import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 振动桥（docs/20 §6）：CoreHaptics 需要自建通道 —— Flutter 内置的
    // HapticFeedback 只有三档固定触感，无时长无振幅，表达不了本需求。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HapticBridge") {
      HapticBridge.register(with: registrar.messenger())
    }
  }
}
