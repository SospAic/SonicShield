// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **Android 向下兼容守卫锁**（第三十一轮，docs/03 §1 / docs/05 §1.4 / docs/20 §5.1）。
///
/// ## 为什么必须有这个文件
///
/// 本项目有 3 个 Kotlin 文件在做「按 SDK 版本分级」的事（振动、精确闹钟、
/// 前台服务类型）。而 **`flutter test` 不编译 Kotlin、`flutter analyze` 也不看
/// Kotlin**（BUG-074 的血泪）—— 也就是说 Dart 侧的任何测试都**碰不到**这些分级。
/// 分级写错的后果又恰恰是**静默**的：低版本上悄悄降级，不报错、不崩溃，
/// 只在真机上表现为"到点了没震 / 没响"。
///
/// 这不是假想 —— 第三十一轮就是靠逐条核对发现的（见 GUARD 组）。
///
/// ## 这个文件锁什么
///
/// | 组 | 不变量 |
/// |---|---|
/// | FLOOR | `minSdk` 恰好是**已裁决的地板**，且不再有人往 `build.gradle.kts` 里加无效的 `abiFilters` |
/// | GUARD | 每个高版本 API 的 `Build.VERSION.SDK_INT` 守卫等级 **精确等于**该 API 的真实起始版本 |
/// | ATTR  | 「后台振动必须带 attributes」（BUG-069）在 **API 21+ 全档**都成立，且属性只有**一个**构造出口 |
/// | FGS   | 麦克风前台服务的类型位守卫等级正确，且清单声明齐全 |
/// | SDK   | 上表用到的 API 等级**不是凭记忆写的** —— 每个都配一条权威证据，运行时重新求值比对 |
///
/// ## 关键设计：**单一等级表 + 权威证据**（不是两张表）
///
/// 初版把"GUARD 组用的等级表"和"SDK 交叉核对用的探针表"写成了**两张互不相干的表**，
/// 于是出现一个假绿：把 `apiLevels['Build.VERSION_CODES.M']` 从 23 改成 24，
/// GUARD-01 会红，但 SDK 交叉核对**照样绿** —— 因为它核的是另一张表。
/// 等于"文档声称交叉核对过，实际没有"。
///
/// 现在只有一个 [guardApi] 表，每项自带 `where`/`regex` 证据；
/// SDK 组遍历**同一张表**求值比对。改错数字必然被抓。
///
/// ## 为什么是"源码文本锁"而不是编译期检查
///
/// Kotlin 不在 Dart 的分析范围内，且本项目**没有** Kotlin 单测基础设施
/// （引入需要给 `packages/native_bridge` 加 test sourceSet + JUnit，
/// 那是一次独立的技术选型，不该顺手做）。所以这里用文本锁。
///
/// ⚠️ **诚实声明本锁的能力边界**：它是**源码文本分析**，不是编译器。
/// 它能抓住「**守卫等级写错**」（本轮的真实缺陷形态），
/// 抓不住「**守卫结构写错**」（例如把符号挪进一个语义上到不了的 `if`）。
/// 后者只能靠真机取证。**不要把本锁当成"Kotlin 已被验证"**。
///
/// 另外：分析器对 `else` 分支**没有否定语义感知** —— 它只能看到"上面最近的守卫"。
/// 凡涉及 else 的判定（如 GUARD-02）都必须用"守卫 + 紧邻上一行"的**结构组合**来判，
/// 不能单看守卫等级。
void main() {
  // ---------------------------------------------------------------- 常量

  const pluginDir =
      'packages/native_bridge/android/src/main/kotlin/com/sonicshield/native_bridge';
  const appKotlinDir =
      'android/app/src/main/kotlin/com/sonicshield/sonic_shield';

  final pluginKt = File('$pluginDir/NativeBridgePlugin.kt');
  final micGuardKt = File('$pluginDir/MicGuardService.kt');
  final watchdogKt = File('$pluginDir/AlarmWatchdogReceiver.kt');
  final bootKt = File('$appKotlinDir/BootReceiver.kt');
  final appGradle = File('android/app/build.gradle.kts');
  final pluginGradle = File('packages/native_bridge/android/build.gradle');
  final appManifest = File('android/app/src/main/AndroidManifest.xml');
  final pluginManifest =
      File('packages/native_bridge/android/src/main/AndroidManifest.xml');

  /// **唯一**的守卫等级表：`Build.VERSION_CODES.*` / 本地常量 → 真实 API 等级 + 权威证据。
  ///
  /// `where` 取值：
  /// - `sdk`    → 证据在 Android SDK 的 `api-versions.xml`（`regex` 捕获组 1 = 等级）
  /// - `kotlin` → 证据在**本仓库的 Kotlin 源码**（本地常量自己定义了自己的值）
  const guardApi =
      <String, ({int level, String where, String regex, String what})>{
    'Build.VERSION_CODES.M': (
      level: 23,
      where: 'sdk',
      regex: r'<method name="setExactAndAllowWhileIdle\([^"]*"[^>]*?since="(\d+)"',
      what: 'AlarmManager.setExactAndAllowWhileIdle',
    ),
    'Build.VERSION_CODES.O': (
      level: 26,
      where: 'sdk',
      regex: r'<method name="hasAmplitudeControl\([^"]*"[^>]*?since="(\d+)"',
      what: 'Vibrator.hasAmplitudeControl',
    ),
    'Build.VERSION_CODES.Q': (
      level: 29,
      where: 'sdk',
      regex: r'<field name="FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK"[^>]*?since="(\d+)"',
      what: 'ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK',
    ),
    'Build.VERSION_CODES.R': (
      level: 30,
      where: 'sdk',
      regex: r'<field name="FOREGROUND_SERVICE_TYPE_MICROPHONE"[^>]*?since="(\d+)"',
      what: 'ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE',
    ),
    'Build.VERSION_CODES.S': (
      level: 31,
      where: 'sdk',
      regex: r'<field name="ACTION_REQUEST_SCHEDULE_EXACT_ALARM"[^>]*?since="(\d+)"',
      what: 'Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM',
    ),
    'Build.VERSION_CODES.TIRAMISU': (
      level: 33,
      where: 'sdk',
      regex: r'<method name="vibrate\(Landroid/os/VibrationEffect;'
          r'Landroid/os/VibrationAttributes;\)V"[^>]*?since="(\d+)"',
      what: 'Vibrator.vibrate(VibrationEffect, VibrationAttributes)',
    ),
    'API_BAKLAVA': (
      level: 36,
      where: 'kotlin',
      regex: r'private const val API_BAKLAVA = (\d+)',
      what: '插件内本地常量 API_BAKLAVA（刻意不用 Build.VERSION_CODES.BAKLAVA）',
    ),
  };

  /// 只做等级查表的便捷视图。
  final apiLevels = guardApi.map((k, v) => MapEntry(k, v.level));

  /// **已裁决的地板：API 24（Android 7.0 Nougat）**。
  ///
  /// 不是随手取的数 —— 它是**多方共同锁死**的，取最大值：
  ///
  /// | 约束来源 | 下限 |
  /// |---|---|
  /// | Flutter 3.47.3 SDK（`FlutterExtension.kt:26`） | **24** |
  /// | `flutter_plugin_android_lifecycle` 2.0.35 | **24** |
  /// | `flutter_tts` 4.2.5 | **24** |
  /// | `record_android` 2.2.0 | **24** |
  /// | `shared_preferences_android` 2.4.28 | **24** |
  /// | `geolocator_android`（用 `flutter.minSdkVersion`） | 24 |
  /// | 其余 14 个含 android/ 的包 | 16–21 |
  ///
  /// ⇒ **不可能再低**：AGP 清单合并会在「app 的 minSdk 低于某个库声明的 minSdk」
  /// 时直接报错。所以"向下兼容"的落点**不是**继续降 minSdk，
  /// 而是**让 API 24/25 上的运行时行为真正正确** —— 这正是 GUARD/ATTR 组在管的事。
  const floor = 24;

  String read(File f) => f.readAsStringSync();

  // ---------------------------------------------------------------- 分析器

  /// 去掉注释与字符串字面量内容（保留换行以维持行号）。
  ///
  /// ⚠️ **必须去注释**：本轮的修复注释里**就写着**
  /// `Build.VERSION.SDK_INT >= Build.VERSION_CODES.M` 这样的字面量，
  /// 不去掉的话分析器会把注释当成真守卫 —— 锁就变成了自我实现的空转。
  ///
  /// ⚠️ **必须抹字符串**：`"hasAmplitudeControl" to amp` 这样的**映射键**是协议名，
  /// 不是 API 调用。若算作"出现"，锁会把 map 字面量误判成
  /// 「无守卫地使用了 API 26 的方法」（GUARD-05 初版就是这么假红的）。
  String sanitize(String src) {
    final out = StringBuffer();
    var i = 0;
    while (i < src.length) {
      final c = src[i];
      if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
        while (i < src.length && src[i] != '\n') {
          i++;
        }
      } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
        i += 2;
        while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
          if (src[i] == '\n') out.write('\n');
          i++;
        }
        i += 2;
      } else if (c == '"') {
        out.write(' ');
        i++;
        while (i < src.length && src[i] != '"') {
          if (src[i] == '\\') {
            out.write(' ');
            i++;
          }
          if (i < src.length) {
            out.write(src[i] == '\n' ? '\n' : ' ');
            i++;
          }
        }
        if (i < src.length) {
          out.write(' ');
          i++;
        }
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  final guardRe = RegExp(r'SDK_INT\s*(>=|<)\s*([A-Za-z0-9_.]+)');
  final funBoundaryRe = RegExp(r'^\s*(?:@\w+\s*)?(?:private\s+|internal\s+'
      r'|public\s+|protected\s+)?(?:override\s+)?(?:fun|class|object)\s');

  /// 找 [line] 所在**函数体内**、向上最近的一条 `SDK_INT <op> LEVEL`。
  ///
  /// 返回 `(level, op, line)`；未找到返回 null（= 该符号处于无守卫位置）。
  /// 语义：`op == '>='` ⇒ 该符号在「API ≥ level」的块内；
  /// `op == '<'`  ⇒ 该符号在「API < level 就提前返回」之后，等价于「API ≥ level」。
  /// 两种写法都表示**该符号只在 API ≥ level 时才可达**。
  ({int level, String op, int line})? nearestGuard(
      List<String> lines, int line) {
    for (var i = line; i >= 0; i--) {
      if (i != line && funBoundaryRe.hasMatch(lines[i])) return null;
      final m = guardRe.firstMatch(lines[i]);
      if (m == null) continue;
      // BootReceiver 用的是**全限定名** `android.os.Build.VERSION_CODES.O`，
      // 这里统一剥掉包前缀再查表 —— 否则会漏判成"未登记常量"。
      var name = m.group(2)!;
      if (name.startsWith('android.os.')) {
        name = name.substring('android.os.'.length);
      }
      final lv = apiLevels[name];
      if (lv == null) {
        // 未登记的守卫常量 —— 属于新增分级却没登记，必须让人看见
        return (level: -1, op: m.group(1)!, line: i);
      }
      return (level: lv, op: m.group(1)!, line: i);
    }
    return null;
  }

  /// 收集 [symbol] 在 [src] 中所有出现位置及其守卫等级。
  List<({int line, int? level})> occurrences(String src, String symbol) {
    final lines = sanitize(src).split('\n');
    final res = <({int line, int? level})>[];
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i];
      if (t.trimLeft().startsWith('import ')) continue; // import 不在守卫范围
      if (!t.contains(symbol)) continue;
      final g = nearestGuard(lines, i);
      res.add((line: i + 1, level: g?.level));
    }
    return res;
  }

  // =====================================================================
  // FLOOR：地板与构建配置
  // =====================================================================
  group('FLOOR 地板与构建配置', () {
    test('FLOOR-01 app minSdk 恰好等于已裁决地板（写死，不跟 flutter.minSdkVersion 漂）', () {
      final src = read(appGradle);
      expect(
        RegExp(r'^\s*minSdk\s*=\s*(\d+)\s*$', multiLine: true)
            .firstMatch(src)
            ?.group(1),
        '$floor',
        reason: 'app 的 minSdk 变了 —— 要么是有人"顺手降"（但 AGP 清单合并会失败），'
            '要么是地板裁决变了。两种情况都必须显式改这个测试，不能悄悄漂。',
      );
    });

    test('FLOOR-02 插件的 minSdk 不低于 app 的（否则清单合并必失败）', () {
      final src = read(pluginGradle);
      final v = RegExp(r'minSdk\s*=\s*(\d+)').firstMatch(src)?.group(1);
      expect(v, isNotNull, reason: '插件 build.gradle 里读不到 minSdk');
      expect(
        int.parse(v!) >= floor,
        isTrue,
        reason: '插件的 minSdk 低于 app 的 minSdk 时 AGP 会直接报错；'
            '这里显式钉住，避免有人只改一边。',
      );
    });

    test('FLOOR-03 打开 core library desugaring（低版本上 java.time 等才可用）', () {
      final src = read(appGradle);
      expect(src, contains('isCoreLibraryDesugaringEnabled = true'));
      expect(src, contains('desugar_jdk_libs'));
    });

    test('FLOOR-04 不得在 build.gradle.kts 里写 abiFilters（防误伤 32 位老设备）', () {
      final code = sanitize(read(appGradle));
      expect(
        code.contains('abiFilters'),
        isFalse,
        reason: 'Flutter 的 Gradle 插件在本文件顶部 plugins{} apply 时就执行了 '
            'abiFilters.clear() + addAll(PLATFORM_ABI_LIST)（FlutterPlugin.kt:591-600），'
            '而 android{} 在其后求值 ⇒ 这里写 abiFilters **完全无效**（只会追加重复项）。'
            '更糟的是：若有人把它挪到"生效"的位置，就会排除 armeabi-v7a，'
            '而 API 24/25 时代的低端机大量是 32 位 ⇒ INSTALL_FAILED_NO_MATCHING_ABIS 装不上。'
            '要减体积请用 `flutter build apk --split-per-abi`。',
      );
    });
  });

  // =====================================================================
  // GUARD：高版本 API 的守卫等级必须精确等于其真实起始版本
  // =====================================================================
  group('GUARD 守卫等级表', () {
    // 允许「无守卫出现」的豁免 —— 必须逐条给出理由，且是**窄匹配**（整行子串）。
    // ⚠️ 豁免也必须是"可失效"的：条件写窄，一旦前提被破坏，豁免自动失效、锁变红。
    const unguardedExemptions =
        <({String symbol, String lineContains, String reason})>[
      (
        symbol: 'VibrationEffect',
        lineContains: 'effect: VibrationEffect,',
        reason: 'applyEffect 的**形参类型**（声明处，非调用处）。该函数已标 '
            '@RequiresApi(O)，且只被 `>= O` 与 `>= API_BAKLAVA` 两条分支调用；'
            'ART 按调用点解析方法，API<26 走不到它。注解本身由 ATTR-03 单独锁。',
      ),
      (
        symbol: 'startForegroundService',
        lineContains: 'ContextCompat.startForegroundService(',
        reason: '这是 **AndroidX 兼容壳** `ContextCompat.startForegroundService`，'
            '它内部对 API<26 自动降级为 `startService` —— 正因如此它**不需要**守卫。'
            '豁免条件是整行子串 `ContextCompat.startForegroundService(`：'
            '若有人把 `ContextCompat.` 去掉换成裸 `context.startForegroundService`，'
            '本豁免立刻失效、锁变红（那条路才真的需要 >= O 守卫）。',
      ),
    ];

    void checkGuard({
      required File file,
      required String symbol,
      required int level,
      required String reason,
    }) {
      final src = read(file);
      final lines = sanitize(src).split('\n');
      final occ = occurrences(src, symbol);
      expect(
        occ,
        isNotEmpty,
        reason: '在 ${file.path} 里找不到 `$symbol` —— '
            '符号被删/改名了？锁会因此空转，必须让人看见。',
      );
      for (final o in occ) {
        final exempted = unguardedExemptions.any((e) =>
            e.symbol == symbol && lines[o.line - 1].contains(e.lineContains));
        if (exempted) continue;
        expect(
          o.level,
          isNotNull,
          reason: '${file.path}:${o.line} 的 `$symbol` 处于**无守卫**位置。'
              '该 API 的起始版本是 API $level，低于它的设备上会走到这里。',
        );
        expect(
          o.level,
          level,
          reason: '${file.path}:${o.line} 的 `$symbol` 守卫等级是 ${o.level}，'
              '但该 API 的真实起始版本是 **$level**。'
              '$reason\n'
              '守卫**高于**真实版本 ⇒ 高版本白白降级（本轮修的就是这个：'
              'setExactAndAllowWhileIdle 明明 API 23 就有，却锁在 31）；\n'
              '守卫**低于**真实版本 ⇒ 低版本调用不存在的 API，崩溃或静默失效。',
        );
      }
    }

    test('GUARD-01 setExactAndAllowWhileIdle 守卫必须是 M(23)，不是 S(31)', () {
      checkGuard(
        file: pluginKt,
        symbol: 'setExactAndAllowWhileIdle',
        level: 23,
        reason: 'docs/03 §1 与 docs/05 §1.2 都宣称通道B 用 AllowWhileIdle；'
            '而 setExact 在 Doze 下会被推迟到下一个维护窗口（可能数小时）。'
            '锁在 31 ⇒ API 24–30（Android 7.0–11）的"Doze 下可靠唤醒"只是文档里的说法。',
      );
    });

    test('GUARD-02 setExact 只能是 `>= M` 那个 if 的 else 兜底', () {
      // `setExact` 本身 API 19 起可用，不是"高版本 API"；这里锁的是**位置**：
      // 它必须落在 `if (SDK_INT >= M) { AllowWhileIdle } else { setExact }`
      // 的 **else 分支**里。
      //
      // ⚠️ 分析器**无法识别 else 的否定语义** —— 它只能看到"上面最近的守卫是 >= M"。
      // 所以这里用**结构组合**判定：`>= M` 的守卫 + 紧邻上一行是 `} else {`，
      // 两条同时成立才等价于"这是 >= M 的 else 分支"。少任何一条都说明结构被改了。
      //
      // ⚠️ 第八十五轮（2026-10-17）**判据从「计数 == 1」改为「逐处结构检查」**：
      // 第八十三轮（`d3dba8d`）给 `setAlarmClock` 特权通道加了**失败回退**，
      // 回退里同样需要 `>= M ? AllowWhileIdle : setExact` ⇒ 合法地出现第 2 处。
      // 旧的 `expect(idx.length, 1)` 因此判红，但它抓的其实**不是**真正的不变量 ——
      // 真正的不变量是「**每一处** `setExact` 都落在 `>= M` 的 else 兜底里」。
      // 改为逐处检查后判据**更强**（原来只查唯一那一处），且不再因合法新增假红。
      final lines = sanitize(read(pluginKt)).split('\n');
      final idx = <int>[];
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('am.setExact(')) idx.add(i);
      }
      expect(
        idx,
        isNotEmpty,
        reason: '找不到 `am.setExact(` —— 兜底分支被删除或改名，本锁失去判据（不许跳过）。',
      );
      for (final i in idx) {
        final g = nearestGuard(lines, i);
        expect(g?.level, 23,
            reason: '第 ${i + 1} 行的 `am.setExact(` 上面最近的守卫不是 M(23)，'
                '是 ${g?.level}。');
        expect(g?.op, '>=',
            reason: '第 ${i + 1} 行的 `am.setExact(` 上面最近的守卫不是 `>=` 形式，'
                '是 `${g?.op}`。');
        String? prev;
        for (var j = i - 1; j >= 0; j--) {
          if (lines[j].trim().isEmpty) continue;
          prev = lines[j].trim();
          break;
        }
        expect(
          prev,
          '} else {',
          reason: '第 ${i + 1} 行的 `am.setExact(` 的上一行是 `$prev`，不是 `} else {`。\n'
              '⇒ 它不再是 `>= M` 的兜底分支。若它落在 `>= M` 的主分支里，'
              '就等于把 AllowWhileIdle 换回了 setExact —— '
              'API 24–30 在 Doze 下会被推迟到下一个维护窗口。',
        );
      }
    });

    test('GUARD-03 精确闹钟权限引导与查询守卫必须是 S(31)', () {
      checkGuard(
        file: pluginKt,
        symbol: 'ACTION_REQUEST_SCHEDULE_EXACT_ALARM',
        level: 31,
        reason: 'SCHEDULE_EXACT_ALARM 特殊权限与引导页是 Android 12 / API 31 引入。',
      );
      checkGuard(
        file: pluginKt,
        symbol: 'canScheduleExactAlarms',
        level: 31,
        reason: '同上。这里是 `SDK_INT < S ||` 的短路写法，'
            '分析器把 `<` 也折算成"该符号只在 API ≥ level 才可达"。',
      );
    });

    test('GUARD-04 振动器获取守卫必须是 S(31)', () {
      checkGuard(
        file: pluginKt,
        symbol: 'VIBRATOR_MANAGER_SERVICE',
        level: 31,
        reason: 'VibratorManager 是 Android 12 / API 31 引入；'
            '更低版本必须走已废弃的 VIBRATOR_SERVICE。',
      );
    });

    test('GUARD-05 VibrationEffect 与 hasAmplitudeControl 守卫必须是 O(26)', () {
      checkGuard(
        file: pluginKt,
        symbol: 'VibrationEffect.createWaveform(',
        level: 26,
        reason: 'VibrationEffect 类与 createWaveform 都是 API 26 起。',
      );
      checkGuard(
        file: pluginKt,
        symbol: 'hasAmplitudeControl',
        level: 26,
        reason: 'hasAmplitudeControl 是 API 26 起（api-versions.xml: method@26）。'
            'SDK < O 时它恒为 false —— 这正是"振幅设置静默失效"的判据来源。'
            '⚠️ 注意 `"hasAmplitudeControl" to amp` 是**映射键**，分析器已抹掉字符串，'
            '不会把它误算成一次 API 使用。',
      );
    });

    test('GUARD-06 VibrationAttributes 守卫必须是 TIRAMISU(33) —— 不能按类等级 30 放宽', () {
      checkGuard(
        file: pluginKt,
        symbol: 'VibrationAttributes.createForUsage(',
        level: 33,
        reason: '`VibrationAttributes` **类**是 API 30，但 '
            '`vibrate(VibrationEffect, VibrationAttributes)` 这个**重载**是 API 33'
            '（api-versions.xml 核对）。按 30 放宽会在 API 30–32 上抛 NoSuchMethodError。',
      );
    });

    test('GUARD-07 包络振动相关 API 守卫必须是 36', () {
      checkGuard(
        file: pluginKt,
        symbol: 'areEnvelopeEffectsSupported',
        level: 36,
        reason: '包络振动是 Android 16 / API 36 引入。',
      );
      checkGuard(
        file: pluginKt,
        symbol: 'envelopeEffectInfo',
        level: 36,
        reason: '同上。注意本机（Redmi K70 至尊版 / Android 16）实测 '
            'hasEnvelope=false、mMaxEnvelopeEffectSize=0 ⇒ 这条路走不到，但守卫仍必须正确。',
      );
    });

    test('GUARD-08 前台服务启动与通知渠道守卫必须是 O(26)', () {
      checkGuard(
        file: watchdogKt,
        symbol: 'startForegroundService',
        level: 26,
        reason: 'startForegroundService 是 API 26 起；更低版本必须用 startService'
            '（API 26 起才有"5 秒内必须 startForeground"的后台限制）。',
      );
      checkGuard(
        file: pluginKt,
        symbol: 'startForegroundService',
        level: 26,
        reason: '同上（插件里这一处是 ContextCompat 兼容壳，走豁免）。',
      );
      checkGuard(
        file: micGuardKt,
        symbol: 'NotificationChannel(',
        level: 26,
        reason: 'NotificationChannel 是 API 26 起；更低版本渠道 ID 会被忽略。',
      );
    });

    test('GUARD-09 BootReceiver 的开机踢醒：精确闹钟守卫 M(23)，授权探测 S(31)', () {
      // F-3 方案①（第 70 轮）：开机自启**不再**直接 startForegroundService
      // （Android 12+ 后台启动 FGS 受限、Android 15+ 禁止 BOOT_COMPLETED 启动
      // mediaPlayback 型 FGS ⇒ 旧写法必被拒且曾经静默），改为排一次性精确闹钟
      // 复用既有 AlarmWatchdogReceiver 拉起引擎。故本锁的符号从
      // `startForegroundService` 换成 `setExactAndAllowWhileIdle`。
      checkGuard(
        file: bootKt,
        symbol: 'setExactAndAllowWhileIdle',
        level: 23,
        reason: 'F-3 方案① 的踢醒路径：setExactAndAllowWhileIdle 自 API 23 起可用'
            '（SDK api-versions.xml: method@23）。锁成 31 会让 API 24–30 静默退到'
            'setExact（Doze 下被推迟数小时），"开机即恢复"在低版本上就不成立。'
            '该文件用**全限定名** android.os.Build.VERSION_CODES.M，分析器会剥前缀。',
      );
      checkGuard(
        file: bootKt,
        symbol: 'canScheduleExactAlarms',
        level: 31,
        reason: 'canScheduleExactAlarms 是 API 31(S) 起。未授予 SCHEDULE_EXACT_ALARM '
            '时排精确闹钟会抛 SecurityException —— 本文件用 '
            '`SDK_INT < S || am.canScheduleExactAlarms()` 短路，'
            '未授权时降级为非精确闹钟（不享有 FGS 启动豁免）。'
            '守卫等级写错会让低版本调用不存在的 API。',
      );
    });
  });

  // =====================================================================
  // ATTR：BUG-069「后台振动必须带 attributes」必须在 API 21+ 全档成立
  // =====================================================================
  group('ATTR 振动属性（BUG-069 的下限延伸）', () {
    test('ATTR-01 API<26 的旧重载也必须带 AudioAttributes', () {
      final code = sanitize(read(pluginKt));
      expect(
        code,
        contains(
            'v.vibrate(timings.toLongArray(), repeat, vibrationAttributes(useAlarm))'),
        reason: 'API 24/25 走的是 `vibrate(long[], int, AudioAttributes)` 旧重载。'
            '该重载**自 API 21 就存在**（api-versions.xml: method@21）——'
            '所以"低版本带不了属性"是错的。曾用两参重载（无属性），'
            '等于把 BUG-069「后台振动必须带属性」在低版本上又留了一遍。',
      );
      expect(
        RegExp(r'v\.vibrate\(timings\.toLongArray\(\), repeat\)\s*$', multiLine: true)
            .hasMatch(code),
        isFalse,
        reason: '又出现了**不带属性**的两参旧重载调用 —— BUG-069 在低版本上复发。',
      );
    });

    test('ATTR-02 AudioAttributes 的构造只有一个出口（两条路不可能漂移）', () {
      final code = sanitize(read(pluginKt));
      final n = RegExp(r'AudioAttributes\.Builder\(\)').allMatches(code).length;
      expect(
        n,
        1,
        reason: '插件里有 $n 处 AudioAttributes.Builder()。'
            '属性构造必须是**唯一出口**（vibrationAttributes()）：'
            '否则 API 24/25 的旧重载与 API 26+ 的 VibrationEffect 重载会各自演化，'
            '又漂回"某一条路没属性"的老问题。',
      );
    });

    test('ATTR-03 只在 26+/36+ 可达的函数必须标 @RequiresApi（形参无守卫的正当性）', () {
      final src = read(pluginKt);
      expect(
        RegExp(r'@RequiresApi\(Build\.VERSION_CODES\.O\)\s*\n\s*private fun applyEffect')
            .hasMatch(src),
        isTrue,
        reason: 'applyEffect 的形参是 VibrationEffect（API 26 起），签名处没有守卫。'
            '必须用 @RequiresApi(O) 声明契约，否则"谁可以调它"完全靠口头约定。',
      );
      expect(
        RegExp(r'@RequiresApi\(API_BAKLAVA\)\s*\n\s*private fun vibrateEnvelope')
            .hasMatch(src),
        isTrue,
        reason: 'vibrateEnvelope 全用 API 36 的包络 API，必须标 @RequiresApi(API_BAKLAVA)。',
      );
    });

    test('ATTR-04 振动唯一出口仍是 applyEffect（v1.x 入口不得绕过）', () {
      final code = sanitize(read(pluginKt));
      // BUG-133 起 `vibrate()` 返回 `Boolean`（真实回执，不再无条件 success(true)），
      // 因此签名与 `{` 之间多了一段返回类型 —— 锁的**意图**是"必须转调
      // vibrateWaveform"，故放宽为"可选返回类型"。
      expect(
        RegExp(r'private fun vibrate\(ctx: Context, pattern: List<Long>\)'
                r'(?::\s*\w+)?\s*\{[^}]*vibrateWaveform\(')
            .hasMatch(code),
        isTrue,
        reason: 'v1.x 的 vibrate() 入口必须转调 vibrateWaveform（带属性），'
            '不能自己裸调 Vibrator.vibrate —— 否则又开了一条无属性的旁路。',
      );
    });
  });

  // =====================================================================
  // FGS：麦克风前台服务的类型位
  // =====================================================================
  group('FGS 前台服务类型', () {
    test('FGS-01 三参 startForeground 守卫必须是 R(30)，不是 Q(29)', () {
      final lines = sanitize(read(micGuardKt)).split('\n');
      var found = false;
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE')) {
          continue;
        }
        found = true;
        final g = nearestGuard(lines, i);
        expect(
          g?.level,
          30,
          reason: '`ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE` 的官方起始版本是 '
              '**API 30**（api-versions.xml: field@30；同批的 LOCATION / DATA_SYNC / '
              'MEDIA_PLAYBACK 才是 @29）。曾按 Q(29) 分支 ⇒ 在 Android 10 上'
              '向 startForeground 传了一个该版本尚不存在的类型位。'
              'API 29 本来就没有"麦克风前台服务类型"语义（麦克风 while-in-use '
              '约束是 Android 11 才引入），所以低版本走两参重载是正确行为。',
        );
      }
      expect(found, isTrue, reason: '找不到 FOREGROUND_SERVICE_TYPE_MICROPHONE —— 锁空转。');
    });

    test('FGS-02 清单声明齐全（类型 + 权限）', () {
      final m = read(pluginManifest);
      expect(m, contains('android:foregroundServiceType="microphone"'));
      expect(m, contains('android.permission.FOREGROUND_SERVICE_MICROPHONE'));
      expect(m, contains('android.permission.ACCESS_NETWORK_STATE'));
      final app = read(appManifest);
      expect(app, contains('android.permission.SCHEDULE_EXACT_ALARM'));
      expect(app, contains('android.permission.FOREGROUND_SERVICE'));
    });

    test('SEC-01 关闭系统备份（E2EE 根密钥不得随备份离机）', () {
      final app = read(appManifest);
      // 空转自检：读不到清单内容时下面两条都会"看起来通过"（isNot contains 恒真）。
      expect(app, contains('<application'),
          reason: '清单没读到内容 ⇒ 本锁是空转假绿，必须先修读取路径。');
      expect(
        app,
        contains('android:allowBackup="false"'),
        reason: '根密钥（RemoteStore.pairingCode / PairedEndpoint.secret）明文存于 '
            'SharedPreferences；allowBackup 默认 true 时它会随 ①系统/云备份恢复 '
            '②adb backup(API<=30) ③root/取证 三条路径离机 —— 拿到即等于拿到端点控制权。'
            '这是 A3/A4 审计的 P0-4，不要删。',
      );
      expect(
        app,
        isNot(contains('android:allowBackup="true"')),
        reason: '不得存在显式开启备份的声明（防止变体清单或第二段 <application> 回退）。',
      );
    });
  });

  // =====================================================================
  // SDK：等级表本身必须与权威来源一致（遍历同一张表）
  // =====================================================================
  group('SDK 交叉核对（等级不是凭记忆写的）', () {
    /// 依次尝试的 api-versions.xml 位置（可用环境变量覆盖）。
    List<String> candidateXmlPaths() => [
          if (Platform.environment['ANDROID_API_VERSIONS_XML'] != null)
            Platform.environment['ANDROID_API_VERSIONS_XML']!,
          'E:/dev/android-sdk/platforms/android-36/data/api-versions.xml',
          if (Platform.environment['ANDROID_HOME'] != null)
            '${Platform.environment['ANDROID_HOME']}/platforms/android-36/data/api-versions.xml',
        ];

    test('SDK-01 api-versions.xml 可读（否则本组锁等于没做，必须显式失败）', () {
      final hit = candidateXmlPaths().where((p) => File(p).existsSync()).toList();
      expect(
        hit,
        isNotEmpty,
        reason: '找不到 Android SDK 的 api-versions.xml，试过：\n'
            '${candidateXmlPaths().map((p) => '  - $p').join('\n')}\n'
            '本组锁的意义就是"API 等级不是凭记忆写的"。'
            '如果只是换机器，请设 ANDROID_API_VERSIONS_XML 指向它；'
            '**不要**为了让测试变绿而删掉本组。',
      );
    });

    test('SDK-02 guardApi 里每个等级都与其权威证据一致（遍历同一张表）', () {
      final hit = candidateXmlPaths().where((p) => File(p).existsSync()).toList();
      final xml = hit.isEmpty ? null : File(hit.first).readAsStringSync();
      final pluginSrc = read(pluginKt);

      final mismatches = <String>[];
      for (final e in guardApi.entries) {
        final v = e.value;
        final String? haystack = switch (v.where) {
          'sdk' => xml,
          'kotlin' => pluginSrc,
          _ => null,
        };
        if (haystack == null) {
          mismatches.add('${e.key}: 证据来源 `${v.where}` 不可用'
              '（SDK-01 已报；若为 kotlin 来源则说明插件源码读不到）');
          continue;
        }
        final m = RegExp(v.regex).firstMatch(haystack);
        if (m == null) {
          mismatches
              .add('${e.key}（${v.what}）: 在 `${v.where}` 来源里匹配不到，正则需更新？');
          continue;
        }
        final actual = int.parse(m.group(1)!);
        if (actual != v.level) {
          mismatches.add('${e.key}（${v.what}）: 表里写 ${v.level}，权威来源是 $actual');
        }
      }
      expect(
        mismatches,
        isEmpty,
        reason: '守卫等级表与权威来源不一致：\n  ${mismatches.join('\n  ')}\n'
            '⇒ 表里的等级可能来自记忆而非权威来源。以权威来源为准修正。\n'
            '（本组刻意遍历 guardApi **同一张表** —— 若只核另一张平行表，'
            '改错 guardApi 也不会被发现，等于"声称交叉核对过、实际没有"。）',
      );
    });
  });
}
