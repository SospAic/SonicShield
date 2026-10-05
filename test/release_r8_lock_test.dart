// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **release 构建守护锁**（R8 / ProGuard）。
///
/// ## 为什么必须有这个文件
///
/// 本项目的"扫码 → 相机"整条链路依赖 `mobile_scanner`，而它靠 **ML Kit 的组件
/// 发现机制**（清单 `<meta-data>` + 运行时 `Class.forName`/反射按类名加载）
/// 拿实现类。Flutter 的 Gradle 插件在 `FlutterPlugin.kt:218` 里**写死**了
/// `releaseBuildType.isMinifyEnabled = true` —— 也就是说，**只要是 release 包，
/// R8 压缩/混淆一定打开**，与本工程 `build.gradle.kts` 怎么写无关。
///
/// 一旦 R8 把按名加载的类重命名/裁剪，扫码时原生方法通道直接抛
/// `NullPointerException`，表现为「相机启动失败」—— 而 debug 包（不压缩）
/// 同一机型同一路径完全正常。这是 v1.9.0-alpha+17 实测复现过的**真实事故**，
/// 不是假想。
///
/// 更隐蔽的是：`mobile_scanner` 自带的 consumer 规则只写了
/// `-keep class com.google.mlkit.* { *; }` —— ProGuard 里**单个 `*` 不跨越包
/// 分隔符**，所以子包（`com.google.mlkit.vision.barcode.**` 等）**照旧被重命名**。
/// 自带的规则**不足以**修好，必须有本工程级的**双星号**补充规则。
///
/// ## 这个文件锁什么
///
/// | 组 | 不变量 |
/// |---|---|
/// | R8   | `android/app/proguard-rules.pro` 存在，ML Kit 用**双星号**保整棵子树，且各反射入口齐全 |
/// | WIRE | `build.gradle.kts` 的 **release 块真的接入** `proguardFiles(..., "proguard-rules.pro")` |
/// | 反例 | 把双星号改回单星号 / 删掉 `proguardFiles` 调用，**同一判据必须判红**（证明非恒真） |
///
/// ## ⚠️ 诚实声明本锁的能力边界
///
/// 这是**源码文本分析**，不是 Gradle 求值、更不是 R8 的实际保留结果。
/// 它能抓住「规则缺失 / 规则退化成单星号 / 接入被删掉」这些**文本可判**的形态；
/// 抓不住「规则在，但被后面的规则覆盖」这类需要真正跑一遍 R8 才能判的问题。
/// 那只能靠**真机 release 取证**（安装 release APK 后驱动扫码/视频路径）。
/// **不要把本锁当成"release 包已验证"**。
void main() {
  final appGradle = File('android/app/build.gradle.kts');
  final proguard = File('android/app/proguard-rules.pro');

  // ---------------------------------------------------------------- 工具

  /// 去掉 ProGuard 的 `#` 行内注释（注释里**就写着** `com.google.mlkit.*`
  /// 这类反例字面量；不去掉的话锁会被注释自我满足 —— 判据变成空转）。
  String stripHashComments(String src) {
    final out = StringBuffer();
    for (final line in const LineSplitter().convert(src)) {
      final i = line.indexOf('#');
      out.writeln(i < 0 ? line : line.substring(0, i));
    }
    return out.toString();
  }

  /// 去掉 `//` 行注释（保留字符串字面量，因为要判 `"proguard-rules.pro"`）。
  ///
  /// ⚠️ **必须去注释**：`build.gradle.kts` 的注释里**就写着**
  /// `proguard-rules.pro` 字样（说明文字），不去掉的话"接入"判据会假绿。
  String stripSlashComments(String src) {
    final out = StringBuffer();
    for (final line in const LineSplitter().convert(src)) {
      final i = line.indexOf('//');
      out.writeln(i < 0 ? line : line.substring(0, i));
    }
    return out.toString();
  }

  /// 在 [src] 里找 [keyword] 之后**第一个** `{...}` 配平块，返回块内内容。
  ///
  /// 找不到返回 null（结构变了 → 调用方必须判红，不许跳过）。
  String? bracedAfter(String src, String keyword) {
    final k = src.indexOf(keyword);
    if (k < 0) return null;
    final open = src.indexOf('{', k);
    if (open < 0) return null;
    var depth = 0;
    for (var i = open; i < src.length; i++) {
      final c = src[i];
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return src.substring(open + 1, i);
      }
    }
    return null;
  }

  /// 从完整 gradle 源码里取出 `buildTypes { release { ... } }` 的 **release 块**。
  String? releaseBlockOf(String gradleSrc) {
    final clean = stripSlashComments(gradleSrc);
    final buildTypes = bracedAfter(clean, 'buildTypes');
    if (buildTypes == null) return null;
    return bracedAfter(buildTypes, 'release');
  }

  /// release 块是否**真的接入**了本工程的 ProGuard 规则。
  ///
  /// 三个条件缺一不可：调用了 `proguardFiles(`、带了我们的 `proguard-rules.pro`、
  /// 且保留了 Android 默认优化规则（`proguard-android-optimize.txt`）。
  bool wiresProguard(String? releaseBlock) {
    if (releaseBlock == null) return false;
    return RegExp(r'proguardFiles\s*\(').hasMatch(releaseBlock) &&
        releaseBlock.contains('"proguard-rules.pro"') &&
        releaseBlock.contains('proguard-android-optimize.txt');
  }

  // ML Kit 必须**双星号**保整棵子树（`\*\*` = 含所有子包）。
  final mlkitDoubleStar = RegExp(r'-keep\s+class\s+com\.google\.mlkit\.\*\*\s*\{');
  // 单星号形式 `com.google.mlkit.*`（后面**不是** `*`）—— 这是"只保住一层"的
  // 退化写法。（双星号里 `mlkit.**` 的首个 `*` 后面跟着 `*`，负向前瞻使其不匹配。）
  final mlkitSingleStar = RegExp(r'com\.google\.mlkit\.\*(?!\*)');

  // =====================================================================
  // R8：规则文件本身
  // =====================================================================
  group('R8 规则文件（android/app/proguard-rules.pro）', () {
    test('R8-01 规则文件必须存在（无真 keystore 也照样压缩，缺它扫码必崩）', () {
      expect(
        proguard.existsSync(),
        isTrue,
        reason: '缺少 android/app/proguard-rules.pro —— Flutter 插件写死 release '
            '`isMinifyEnabled = true`，没有应用级规则时 ML Kit 会被重命名/裁剪，'
            '扫码时原生方法通道抛 NullPointerException（相机起不来）。',
      );
    });

    test('R8-02 ★ ML Kit 必须用双星号保整棵子树（单星号不跨包分隔符）', () {
      final code = stripHashComments(proguard.readAsStringSync());
      expect(
        mlkitDoubleStar.hasMatch(code),
        isTrue,
        reason: '没有 `-keep class com.google.mlkit.** { *; }` —— ML Kit 的组件发现'
            '按类名反射加载实现类，子包被重命名即失效。注意 `mobile_scanner` 自带的'
            '规则是**单星号**，只保住 `com.google.mlkit` 这一层，**不足以**修复，'
            '必须由本工程的双星号规则补充。',
      );
    });

    test('R8-03 不得只留单星号形式 com.google.mlkit.*（子包照样被重命名）', () {
      final code = stripHashComments(proguard.readAsStringSync());
      expect(
        mlkitSingleStar.hasMatch(code),
        isFalse,
        reason: '出现了单星号 `com.google.mlkit.*` —— ProGuard 里单个 `*` **不跨越'
            '包分隔符**，`com.google.mlkit.vision.barcode.**` 等子包照旧被重命名，'
            '等于规则退化回"修不好"的状态。',
      );
    });

    test('R8-04 其余按名加载的反射入口必须齐全', () {
      final code = stripHashComments(proguard.readAsStringSync());
      const required = <String>[
        '-keep class com.google.android.gms.internal.mlkit_**',
        '-keep class com.google.android.libraries.barhopper.**',
        '-keep class com.google.photos.**',
        '-keepclassmembers class * extends java.lang.Enum',
      ];
      for (final keep in required) {
        expect(
          code.contains(keep),
          isTrue,
          reason: '缺少规则 `$keep` —— 这些类/成员同样按名（`Class.forName` / '
              '`valueOf(String)`）加载，被 R8 重命名后会在真机 release 上静默失效。',
        );
      }
    });
  });

  // =====================================================================
  // WIRE：规则必须在 release 块真正生效
  // =====================================================================
  group('GRADLE release 块接入（android/app/build.gradle.kts）', () {
    test('WIRE-01 ★ release 块必须真的接入 proguardFiles(..., "proguard-rules.pro")', () {
      final block = releaseBlockOf(appGradle.readAsStringSync());
      expect(
        block,
        isNotNull,
        reason: 'build.gradle.kts 里找不到 `buildTypes { release { ... } }` —— '
            '结构变了，本锁会空转，必须让人看见。',
      );
      expect(
        wiresProguard(block),
        isTrue,
        reason: '规则文件存在，但 release 块没有真的接入 —— 光有文件 = 装饰品。'
            '必须同时满足：调用 `proguardFiles(`、带上 `"proguard-rules.pro"`、'
            '并保留 `proguard-android-optimize.txt` 默认规则。',
      );
    });

    test('WIRE-02 不得用 isMinifyEnabled = false 绕过（压缩被写死为 true）', () {
      final block = releaseBlockOf(appGradle.readAsStringSync()) ?? '';
      expect(
        RegExp(r'isMinifyEnabled\s*=\s*false').hasMatch(block),
        isFalse,
        reason: '显式写 `isMinifyEnabled = false` 是想"关掉压缩来绕开 R8 问题"——'
            '但 Flutter 插件（FlutterPlugin.kt:218）已写死为 true，两种写法并存时'
            '行为取决于求值顺序（在不同 AGP/插件版本上不确定）。正确做法是'
            '**接规则**，不是关压缩；这里锁死该绕过写法。',
      );
    });
  });

  // =====================================================================
  // 反例：证明上述判据**非恒真**（把判据指向真源会判红）
  // =====================================================================
  group('反例：判据非恒真', () {
    test('R8R-01 把双星号改回单星号 → R8-02 / R8-03 判据判红', () {
      final raw = proguard.readAsStringSync();
      final bad = raw.replaceFirst('com.google.mlkit.**', 'com.google.mlkit.*');
      expect(bad, isNot(raw), reason: '反例样本没构造成功（替换没生效）—— 反例就失去意义');

      final code = stripHashComments(bad);
      expect(
        mlkitDoubleStar.hasMatch(code),
        isFalse,
        reason: '★ 反例必须让 R8-02 判红 ⇒ 判据非恒真',
      );
      expect(
        mlkitSingleStar.hasMatch(code),
        isTrue,
        reason: '★ 反例必须让 R8-03 判红 ⇒ 判据非恒真',
      );
    });

    test('R8R-02 从 release 块删掉 proguardFiles 调用 → WIRE-01 判据判红', () {
      final raw = appGradle.readAsStringSync();
      final bad = raw.replaceFirst(RegExp(r'proguardFiles\s*\('), '');
      expect(bad, isNot(raw), reason: '反例样本没构造成功（替换没生效）—— 反例就失去意义');
      expect(
        wiresProguard(releaseBlockOf(bad)),
        isFalse,
        reason: '★ 反例必须让 WIRE-01 判红 ⇒ 判据非恒真',
      );
    });
  });
}