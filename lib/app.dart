import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme.dart';

/// 合规确认开关（首次启动强制阅读使用条款）。
final complianceAcceptedProvider = StateProvider<bool>((ref) => true);

/// 全局 SnackBar 入口。
///
/// 通话结束（未接/被拒/占线…）的提示可能在**任意页面之上**弹出 ——
/// 主叫发起呼叫后即便退到别的页，也必须收得到"对方无应答"（BUG-050）。
/// 用 `ScaffoldMessenger.of(context)` 需要拿得到当时的页面 context，
/// 而通话结束是一个**全局异步事件**，没有"当时的页面"。
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class SonicShieldApp extends ConsumerWidget {
  const SonicShieldApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: '声盾 SonicShield',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: ref.watch(routerProvider),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
    );
  }
}
