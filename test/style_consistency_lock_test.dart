// ignore_for_file: avoid_print
/// 样式一致性锁（STY 系列，第八十一轮新增）。
///
/// ## 为什么需要这一组锁
///
/// 第八十一轮把全站样式收敛到 `lib/core/theme.dart` 的三个阶梯：
/// `AppText`（字号）/ `AppSpacing`（间距）/ `AppColors`（语义色）。
/// 但**本仓没有 golden 测试**（`matchesGoldenFile` 全库 0 处）——
/// 也就是说，样式改错了**没有任何自动化手段会发现**。
///
/// 这一组锁就是那个缺失的安全网：它不看渲染结果，而是把**规范本身**
/// 钉成机器断言，让"下次再写一个裸 `fontSize: 13`"当场变红。
///
/// ## 六条不变量
///
/// | 锁 | 不变量 |
/// |---|---|
/// | STY-01 | `lib/features/**` 不得出现裸 `fontSize:` 数值（走 `AppText`） |
/// | STY-02 | `lib/features/**` 不得出现 `Colors.red/green/orange/deepOrange`（走 `AppColors`） |
/// | STY-03 | `lib/features/**` 不得出现 `Color(0x14C62828)` 字面量（走 `AppColors.dangerWash`） |
/// | STY-04 | `lib/features/**` 的 `EdgeInsets` 数值必须落在标尺 ∪ 已登记例外内 |
/// | STY-05 | `AppTheme` 的 `FilledButton` 圆角必须是 M3 规范的 20 |
/// | STY-06 | `AppTheme.alertAmber` 必须已被删除（真死代码） |
///
/// 每组都配**反面样本**（`STY-9x`）：把篡改过的源码喂进判据函数，必须判红。
/// 恒真的锁 = 没有锁（本仓既有纪律）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/core/theme.dart';

import 'support/source_text.dart';

/// `EdgeInsets` 允许出现的字面量：4 的倍数标尺 + 已登记的结构性例外。
///
/// - `0`：无内边距；
/// - `2`：发丝线（chip / badge 的纵向内边距，4 的一半）；
/// - `40`：`call_screen` 的 FAB 净空；
/// - `56`：对齐 `ListTile` leading 宽度（设置页左缩进）；
/// - `96`：`remote_tasks_tab` 的底部留白。
const kSpacingAllowed = <int>{0, 2, 4, 8, 12, 16, 24, 32, 40, 56, 96};

/// 全量读取 `lib/features/**` 的 Dart 源码（路径 → 内容）。
Map<String, String> readFeatureSources() {
  final out = <String, String>{};
  for (final e in Directory('lib/features').listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) {
      out[e.path.replaceAll(r'\', '/')] = e.readAsStringSync();
    }
  }
  return out;
}

// ───────────────────────── 判据（纯函数，可喂反面样本） ─────────────────────────

/// STY-01：裸 `fontSize:` 数值。
List<String> fontSizeViolations(Map<String, String> srcs) {
  final re = RegExp(r'fontSize:\s*[0-9]');
  final out = <String>[];
  srcs.forEach((p, s) {
    final lines = stripComments(s).split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (re.hasMatch(lines[i])) out.add('$p:${i + 1}  ${lines[i].trim()}');
    }
  });
  return out;
}

/// STY-02：`Colors.red/green/orange/deepOrange`。
List<String> semanticColorViolations(Map<String, String> srcs) {
  final re = RegExp(r'Colors\.(red|green|orange|deepOrange)\b');
  final out = <String>[];
  srcs.forEach((p, s) {
    final lines = stripComments(s).split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (re.hasMatch(lines[i])) out.add('$p:${i + 1}  ${lines[i].trim()}');
    }
  });
  return out;
}

/// STY-03：`Color(0x14C62828)` 字面量（合规提示卡底色）。
List<String> dangerWashLiteralViolations(Map<String, String> srcs) {
  final re = RegExp(r'0x14C62828', caseSensitive: false);
  final out = <String>[];
  srcs.forEach((p, s) {
    final lines = stripComments(s).split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (re.hasMatch(lines[i])) out.add('$p:${i + 1}  ${lines[i].trim()}');
    }
  });
  return out;
}

/// STY-04：`EdgeInsets` 里落在允许集之外的字面量。
List<String> offScaleSpacingViolations(Map<String, String> srcs) {
  final re = RegExp(r'EdgeInsets\.(?:all|symmetric|only|fromLTRB)\(([^)]*)\)');
  final numRe = RegExp(r'\d+');
  final out = <String>[];
  srcs.forEach((p, s) {
    final lines = stripComments(s).split('\n');
    for (var i = 0; i < lines.length; i++) {
      for (final m in re.allMatches(lines[i])) {
        for (final n in numRe.allMatches(m.group(1)!)) {
          final v = int.parse(n.group(0)!);
          if (!kSpacingAllowed.contains(v)) {
            out.add('$p:${i + 1}  ${lines[i].trim()}  → $v');
          }
        }
      }
    }
  });
  return out;
}

void main() {
  final srcs = readFeatureSources();

  group('STY 样式一致性锁（无 golden 测试下的替代安全网）', () {
    test('STY-00 KNOWN 自检：扫描器确实读到了文件（防「0 命中」与「我没看见」同形）', () {
      // 全库 features 有 29 个文件；给一个下界而不是等值，避免新增文件即红。
      expect(srcs.length, greaterThan(25),
          reason: '目录遍历失效 ⇒ 下面所有「0 命中」都不可信');
      // 已知事实：收敛后 features 里**应当**大量出现 AppText / AppSpacing。
      final all = srcs.values.join('\n');
      expect(all.contains('AppText.'), isTrue,
          reason: '收敛后 features 必须出现 AppText 引用；否则说明遍历错了目录');
      expect(all.contains('AppSpacing.'), isTrue);
      expect(all.contains('AppColors.'), isTrue);
    });

    test('STY-01 ★ 真实仓库：features/** 无裸 fontSize 数值', () {
      final v = fontSizeViolations(srcs);
      for (final s in v) {
        print('[STY-01] $s');
      }
      expect(v, isEmpty,
          reason: '字号必须走 AppText.*（lib/core/theme.dart）—— 裸 fontSize 会让'
              '字号阶梯重新散落，而本仓没有 golden 测试兜底');
    });

    test('STY-02 ★ 真实仓库：features/** 无语义 Colors.red/green/orange/deepOrange', () {
      final v = semanticColorViolations(srcs);
      for (final s in v) {
        print('[STY-02] $s');
      }
      expect(v, isEmpty,
          reason: '语义色必须走 AppColors.*（值已等值保真，见 theme.dart 注释）');
    });

    test('STY-03 ★ 真实仓库：features/** 无 Color(0x14C62828) 字面量', () {
      final v = dangerWashLiteralViolations(srcs);
      for (final s in v) {
        print('[STY-03] $s');
      }
      expect(v, isEmpty,
          reason: '合规提示卡底色必须走 AppColors.dangerWash（单一来源）');
    });

    test('STY-04 ★ 真实仓库：features/** 的 EdgeInsets 数值全在标尺内', () {
      final v = offScaleSpacingViolations(srcs);
      for (final s in v) {
        print('[STY-04] $s');
      }
      expect(v, isEmpty,
          reason: '间距必须落在 kSpacingAllowed（4 的倍数标尺 + 登记例外）；'
              '新增野值请先更新该常量并在注释里写明理由');
    });

    test('STY-05 ★ AppTheme 的 FilledButton 圆角 = M3 规范的 20', () {
      final theme = File('lib/core/theme.dart').readAsStringSync();
      final body = methodBody(stripComments(theme), 'static ThemeData _base(');
      expect(body.contains('BorderRadius.circular(20)'), isTrue,
          reason: 'M3 规范：Filled 按钮 = 20dp 全圆角（原为 12，与 Card 混淆）');
      expect(body.contains('BorderRadius.circular(12)'), isFalse,
          reason: '按钮圆角不得退回 12');
    });

    test('STY-06 ★ alertAmber 必须已被删除（真死代码，全库零引用）', () {
      final libs = <String, String>{};
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is File && e.path.endsWith('.dart')) {
          libs[e.path.replaceAll(r'\', '/')] = e.readAsStringSync();
        }
      }
      final hits = <String>[];
      libs.forEach((p, s) {
        if (stripComments(s).contains('alertAmber')) hits.add(p);
      });
      expect(hits, isEmpty,
          reason: 'alertAmber 全库零引用（仅定义行）⇒ 已删除；若重新引入，'
              '请同时接入 UI 或说明保留理由');
    });
  });

  group('STY 反面样本（篡改过的源码喂进判据必须判红）', () {
    test('STY-90a 裸 fontSize → 判红', () {
      expect(
          fontSizeViolations({'x.dart': 'style: TextStyle(fontSize: 13)'}),
          isNotEmpty);
    });

    test('STY-90b 注释里的 fontSize 不算违规（剥注释后为空）→ 判绿', () {
      expect(
          fontSizeViolations({'x.dart': '// 曾经是 TextStyle(fontSize: 13)'}),
          isEmpty);
    });

    test('STY-90c Colors.red → 判红', () {
      expect(semanticColorViolations({'x.dart': 'color: Colors.red,'}),
          isNotEmpty);
    });

    test('STY-90d 野值间距 14 → 判红；标尺值 16 → 判绿（判据非恒真）', () {
      expect(
          offScaleSpacingViolations(
              {'x.dart': 'padding: const EdgeInsets.all(14),'}),
          isNotEmpty);
      expect(
          offScaleSpacingViolations(
              {'x.dart': 'padding: const EdgeInsets.all(AppSpacing.lg),'}),
          isEmpty);
      expect(
          offScaleSpacingViolations(
              {'x.dart': 'padding: const EdgeInsets.only(left: 56, bottom: 2),'}),
          isEmpty,
          reason: '已登记的结构性例外不得误报');
    });

    test('STY-90e dangerWash 字面量 → 判红', () {
      expect(
          dangerWashLiteralViolations({'x.dart': 'color: Color(0x14C62828),'}),
          isNotEmpty);
    });
  });

  group('AppText / AppSpacing 阶梯自检（值即契约）', () {
    test('STY-07 阶梯取值必须与 M3 Type Scale 字号一致', () {
      expect(AppText.labelSmall.fontSize, 11);
      expect(AppText.bodySmall.fontSize, 12);
      expect(AppText.bodyMedium.fontSize, 14);
      expect(AppText.titleMedium.fontSize, 16);
      expect(AppText.headlineSmall.fontSize, 24);
      expect(AppText.headlineLarge.fontSize, 32);
    });

    test('STY-08 阶梯只固定 fontSize，不得夹带 height（否则改变行高 = 视觉回归）', () {
      for (final t in <Object?>[
        AppText.labelSmall,
        AppText.bodySmall,
        AppText.bodyMedium,
        AppText.titleMedium,
        AppText.titleLarge,
        AppText.headlineSmall,
        AppText.headlineLarge,
      ]) {
        expect((t! as dynamic).height, isNull,
            reason: 'AppText 若带上 height，会把现有调用点的行高改掉 —— '
                '本仓无 golden 测试，这类改动不可验证');
      }
    });

    test('STY-09 间距标尺必须是 4 的倍数且严格递增', () {
      const vals = <double>[
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xl,
        AppSpacing.xxl,
      ];
      for (var i = 0; i < vals.length; i++) {
        expect(vals[i] % 4, 0, reason: 'AppSpacing 必须是 4 的倍数');
        if (i > 0) expect(vals[i], greaterThan(vals[i - 1]));
      }
    });
  });
}
