import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'services/background_service_manager.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // 创建通知渠道（必须在启动前台服务之前——flutter_background_service
  // 指定自定义 channel id 时不会自动创建，缺失会导致 FGS 崩溃）。
  await NotificationService.instance.createServiceChannel();
  // 后台服务引擎先注册（不自动启动，由用户显式开启 —— 见 docs/05）。
  await BackgroundServiceManager.instance.init();
  await NotificationService.instance.ensure();
  runApp(const ProviderScope(child: SonicShieldApp()));
}
