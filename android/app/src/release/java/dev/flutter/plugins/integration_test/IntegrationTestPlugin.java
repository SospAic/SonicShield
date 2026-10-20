package dev.flutter.plugins.integration_test;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

/// 🔴 release 变体的 `integration_test` 插件**桩类**（2026-10-20 增补）。
///
/// ## 为什么需要它
///
/// `integration_test` 在 `pubspec.yaml` 的 `dev_dependencies` 里，但 Flutter 工具
/// **在生成 `GeneratedPluginRegistrant.java` 时会一并写入**（`native_build: true`
/// 的 dev 插件同样进注册表）。`:app:compileReleaseJavaWithJavac` 于是在 release
/// 变体里找不到 `dev.flutter.plugins.integration_test.IntegrationTestPlugin`
/// （该 AAR 只进 debug / test 变体）⇒ **release 构建直接失败**：
///
/// ```
/// GeneratedPluginRegistrant.java:74: 错误: 找不到符号
///   flutterEngine.getPlugins().add(new ...IntegrationTestPlugin());
/// ```
///
/// ## 为什么用「release 源集放桩类」而不是删注册表
///
/// 注册表是**工具每次构建都会重建**的生成物 —— 手工删掉（或打完补丁）
/// 会被下一次 build 覆盖。而 Android 源集是**按变体叠加**的：
/// 本文件只在 release 参与编译，debug/test 变体用的是 AAR 里的真身，
/// 两者不会同时出现在同一变体 ⇒ 不存在 duplicate class。
///
/// ⚠️ 本类**故意什么都不做**：release 包的运行期根本不需要集成测试插件
/// （它只服务于 `flutter test integration_test` 的宿主桥）。
public class IntegrationTestPlugin implements FlutterPlugin {
  public IntegrationTestPlugin() {}

  @Override
  public void onAttachedToEngine(FlutterPluginBinding binding) {
    // no-op：release 变体不需要注册任何通道。
  }

  @Override
  public void onDetachedFromEngine(FlutterPluginBinding binding) {
    // no-op
  }
}
