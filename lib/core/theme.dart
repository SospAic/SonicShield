import 'package:flutter/material.dart';

/// Material 3 主题（动态色 + 深浅模式）。
///
/// 品牌色：深青（盾）。字号阶梯一律走 `AppText.<role>`、间距走 `AppSpacing.<role>`、
/// 语义色走 `AppColors.<name>`（三者均在本文件下方）——
/// 页面里**不得再硬编码 `fontSize:` / 裸数字间距 / `Colors.red|green|orange|deepOrange`**，
/// 由 `test/style_consistency_lock_test.dart`（STY 系列）钉死。
///
/// ⚠️ 两个 seed **不得删除**：
/// - `shieldDeep` 被 `test/deep_pure_logic_test.dart` 的 DL-01 断言引用；
/// - `shieldMid` 还被 `remote_screen.dart` 直接用作 UI 色（录音指示）。
class AppTheme {
  AppTheme._();

  /// 品牌深青 —— light 模式的 seed。
  static const Color shieldDeep = Color(0xFF0B3B3C);

  /// 品牌中青 —— dark 模式的 seed，兼作录音指示色。
  static const Color shieldMid = Color(0xFF14666B);

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
          // M3 规范：Filled 按钮 = 20dp 全圆角（原为 12，与 Card 的圆角混淆）。
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
      snackBarTheme:
          const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}

/// 间距标尺（4 的倍数）。页面里不得再写裸数值 —— 由
/// `test/style_consistency_lock_test.dart` 钉死允许集。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// 字号阶梯 —— 全站**唯一**的字号来源（字号取值对齐 M3 Type Scale）。
///
/// ## 为什么用常量而不是 `Theme.of(context).textTheme.*`
///
/// 1. **const 链**：本仓大量调用点形如 `const Text('…', style: TextStyle(fontSize: 12))`，
///    换成 `textTheme` 必须去掉 `const`，并顺着父级一路去掉 —— 改动面与出错面都大。
/// 2. **行高会变**：`textTheme` 的角色自带 M3 的 `height`（如 `bodySmall` = 16/12），
///    而现有 `TextStyle(fontSize: 12)` 的 `height` 是 `null`（跟随字体）
///    ⇒ 直接替换**会改变行高**，在**没有 golden 测试**的前提下就是布局回归风险
///    （固定高度容器可能溢出）。
///
/// 本阶梯**只固定 `fontSize`**，因此对现有调用点是**零视觉变化**的等价替换；
/// 需要颜色/字重/字距时用 `.copyWith(...)`。
///
/// 由 `test/style_consistency_lock_test.dart` 钉死：`lib/features/**` 不得再出现
/// 裸的 `fontSize:` 数值。
abstract final class AppText {
  /// 11 —— 角标 / 时间戳（M3 `labelSmall`）。
  static const TextStyle labelSmall = TextStyle(fontSize: 11);

  /// 12 —— 次要正文，全站主力（M3 `bodySmall`）。
  static const TextStyle bodySmall = TextStyle(fontSize: 12);

  /// 14 —— 强调正文（M3 `bodyMedium`）。
  static const TextStyle bodyMedium = TextStyle(fontSize: 14);

  /// 16 —— 小标题（M3 `titleMedium`）。
  static const TextStyle titleMedium = TextStyle(fontSize: 16);

  /// 22 —— 大标题（M3 `titleLarge`）。
  static const TextStyle titleLarge = TextStyle(fontSize: 22);

  /// 24 —— 页面级标题（M3 `headlineSmall`）。
  static const TextStyle headlineSmall = TextStyle(fontSize: 24);

  /// 32 —— 极大数字 / 英雄标题（M3 `headlineLarge`）。
  static const TextStyle headlineLarge = TextStyle(fontSize: 32);
}

/// 语义色（**不随明暗切换**，故仅用于小面积状态着色：日志级别、通话控制、合规提示底）。
///
/// 为什么不用 `colorScheme.error`：`error` 只有一种语义，而日志需要成功/警告/失败三态。
///
/// ⚠️ 每个常量都**精确等于**它替换掉的那个 `Colors.*`（见各行注释），
/// 目的是**零视觉回归** —— 本仓没有 golden 测试，颜色只能靠等值保真。
abstract final class AppColors {
  /// 成功 / 接听（== 原 `Colors.green`）。
  static const Color success = Color(0xFF4CAF50);

  /// 警告（== 原 `Colors.orange`）。
  static const Color warning = Color(0xFFFF9800);

  /// 危险 / 挂断 / 失败（== 原 `Colors.red`）。
  static const Color danger = Color(0xFFF44336);

  /// 深危险 —— 小面积文字/描边（== 原 `AppTheme.danger`）。
  static const Color dangerDeep = Color(0xFFC62828);

  /// 暖色待机（== 原 `Colors.deepOrange.shade400`，录音按钮非录制态）。
  static const Color warm = Color(0xFFFF7043);

  /// 合规 / 安全提示卡的底色（== 原 `Color(0x14C62828)`）。
  ///
  /// ⚠️ 必须保持 `const` —— 调用点是 `const Card(color: AppColors.dangerWash, …)`；
  /// 若改成 `AppColors.dangerDeep.withValues(alpha: .08)` 会破坏 const 链，
  /// 触发 `prefer_const_constructors`（门禁第 1 步红）。
  static const Color dangerWash = Color(0x14C62828);
}
