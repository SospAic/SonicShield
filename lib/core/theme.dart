import 'package:flutter/material.dart';

/// Material 3 主题（动态色 + 深浅模式）。
/// 品牌色：深青（盾）+ 琥珀（警报）。
class AppTheme {
  AppTheme._();

  static const Color shieldDeep = Color(0xFF0B3B3C);
  static const Color shieldMid = Color(0xFF14666B);
  static const Color alertAmber = Color(0xFFFFB300);
  static const Color danger = Color(0xFFC62828);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness b) {
    final scheme = ColorScheme.fromSeed(
      seedColor: b == Brightness.dark ? shieldMid : shieldDeep,
      brightness: b,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      snackBarTheme:
          const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
