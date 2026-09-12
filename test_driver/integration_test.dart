import 'package:integration_test/integration_test_driver.dart';

/// flutter drive 集成测试驱动桩。
/// 用法：
/// flutter drive --driver=test_driver/integration_test.dart \
///   --target=integration_test/app_smoke_test.dart \
///   --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk \
///   -d emulator-5554
Future<void> main() => integrationDriver();
