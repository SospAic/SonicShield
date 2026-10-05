// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **release 视频通话路径守护锁（WebRTC 原生类在 R8 下的存活）**。
///
/// ## 为什么需要它（与相机那次事故同源）
///
/// v1.9.0-alpha+17 的"相机无法调用"根因是：release 包必经 R8 压缩/混淆
/// （Flutter 插件写死 `isMinifyEnabled = true`），而 ML Kit 的实现类靠
/// **反射按类名加载** —— 被重命名后扫码原生通道抛 NPE。**视频通话走的是
/// 同一类风险**：`flutter_webrtc` 的 `org.webrtc.**` 由 native `.so` 通过
/// JNI `FindClass` 按名查找，一旦被 R8 重命名，`getUserMedia` /
/// `RTCPeerConnection` 会在真机 release 上失败（debug 不压缩，完全正常）。
///
/// 宿主测试**碰不到**这一段：`test/support/webrtc_stub.dart` 把平台通道桩掉，
/// `WebRTC.invokeMethod` 不会真的调到原生 —— 也就是说"通道名对不对"能被
/// 这两条覆盖，**"原生类在 release 里还在不在"完全没人管**。本锁补的正是这个洞。
///
/// ## 与相机修复的关系
///
/// 相机那次 `mobile_scanner` 自带的规则是**单星号** `com.google.mlkit.*`
/// （不跨包分隔符 ⇒ 子包照旧被重命名），**不足以**修复 ⇒ 必须由本工程
/// `android/app/proguard-rules.pro` 用双星号补充。
///
/// 视频这条不同：`flutter_webrtc` 自带 `consumerProguardFiles 'proguard-rules.pro'`，
/// 且规则本身就是**双星号** `org.webrtc.**` ⇒ 依赖侧已经足够，**不需要**本工程
/// 重复声明。本锁的作用是：把"依赖侧的这份足够性"钉住 —— 一旦升级
/// `flutter_webrtc` 换成**单星号**（退化）或**去掉 `consumerProguardFiles`**
/// （规则压根不合并进 release 构建），锁立刻判红，逼人重新评估，
/// 而不是等到真机上"能打通但没画面"才发现。
///
/// ## 边界（诚实声明）
///
/// 这是**依赖源文件文本分析**，不是 R8 的实际保留结果。它抓的是
/// 「规则退化 / 规则未接入」这些**文本可判**的形态；抓不住"规则在但被
/// 后面的规则覆盖"这类只有真跑 R8 才能判的问题 —— 那只能靠 release APK 真机取证。
void main() {
  // ---------------------------------------------------------------- 解析依赖

  /// 从 `.dart_tool/package_config.json` 解析包 [name] 的根目录。
  ///
  /// 用 package_config 而不是猜 pub cache 路径：这样 pub 源（pub.dev /
  /// pub.flutter-io.cn）与缓存位置变化都不影响本锁，CI 上同样成立。
  Directory? packageRoot(String name) {
    final cfg = File('.dart_tool/package_config.json');
    if (!cfg.existsSync()) return null;
    final data = jsonDecode(cfg.readAsStringSync()) as Map<String, dynamic>;
    for (final p in (data['packages'] as List)) {
      final m = p as Map<String, dynamic>;
      if (m['name'] != name) continue;
      final uri = Uri.parse(m['rootUri'] as String);
      // rootUri 可能是相对路径（本工程自身）—— 相对 package_config.json 所在目录。
      if (uri.scheme == 'file') {
        return Directory(uri.toFilePath());
      }
      return Directory.fromUri(cfg.parent.uri.resolveUri(uri));
    }
    return null;
  }

  final webrtcRoot = packageRoot('flutter_webrtc');

  // 依赖侧的规则文件（JNI 保活的真实来源）。
  final depGradle =
      webrtcRoot == null ? null : File('${webrtcRoot.path}/android/build.gradle');
  final depRules = webrtcRoot == null
      ? null
      : File('${webrtcRoot.path}/android/proguard-rules.pro');

  // 本工程的应用级规则（相机那次的双星号补充落在这里）。
  final appRules = File('android/app/proguard-rules.pro');

  // ---------------------------------------------------------------- 判据

  /// 依赖的 android/build.gradle 是否**真的把规则接进 release 构建**。
  ///
  /// 只认 `consumerProguardFiles`：写成 `proguardFiles` 是库自身构建的规则，
  /// **不会**随 consumer 合并进下游 app 的 release 混淆 —— 那是"看起来接入了、
  /// 实际没生效"的经典形态。
  bool wiresConsumerRules(String gradleSrc) =>
      RegExp("consumerProguardFiles\\s+['\"][^'\"]*proguard-rules\\.pro['\"]")
          .hasMatch(gradleSrc);

  /// 规则源里是否有 `-keep class <pkg>.** {`（**双星号** = 含所有子包）。
  ///
  /// 双星号是判据核心：单星号不跨包分隔符 ⇒ 子包会被重命名（相机的教训）。
  bool keepsWholeSubtree(String rulesSrc, String pkg) =>
      RegExp('-keep\\s+class\\s+${RegExp.escape(pkg)}\\.\\*\\*\\s*\\{')
          .hasMatch(rulesSrc);

  /// 规则源里是否只有**单星号**形式（退化写法，等于没保住子包）。
  bool onlySingleStar(String rulesSrc, String pkg) =>
      RegExp('${RegExp.escape(pkg)}\\.\\*(?!\\*)').hasMatch(rulesSrc);

  // =====================================================================
  group('WebRTC release 保留锁（依赖消费规则）', () {
    test('WK-01 能解析到 flutter_webrtc 包根与其 android 规则文件', () {
      expect(webrtcRoot, isNotNull,
          reason: '从 .dart_tool/package_config.json 里找不到 flutter_webrtc —— '
              '本锁会空转。若已改名/移除该依赖，必须显式更新本锁。');
      expect(depGradle!.existsSync(), isTrue,
          reason: 'flutter_webrtc 的 android/build.gradle 不存在（路径结构变了）');
      expect(depRules!.existsSync(), isTrue,
          reason: 'flutter_webrtc 的 android/proguard-rules.pro 不存在 —— '
              '依赖侧不再提供 R8 规则，视频原生类在 release 下将无人保活。');
    });

    test('WK-02 ★ 依赖必须用 consumerProguardFiles 把规则接入（否则不会合并进 release）', () {
      expect(wiresConsumerRules(depGradle!.readAsStringSync()), isTrue,
          reason: 'flutter_webrtc 没有声明 consumerProguardFiles \'proguard-rules.pro\' —— '
              '它的规则**不会**随 consumer 合并进本 app 的 release 混淆 ⇒ '
              'org.webrtc.** 被 R8 重命名 ⇒ 真机 release 上 getUserMedia/'
              'RTCPeerConnection 失败（"能打通但没画面"）。');
    });

    test('WK-03 ★ 依赖规则必须用双星号保留 org.webrtc.** 与 com.cloudwebrtc.webrtc.**', () {
      final rules = depRules!.readAsStringSync();
      for (final pkg in const [
        'org.webrtc',
        'com.cloudwebrtc.webrtc',
      ]) {
        expect(keepsWholeSubtree(rules, pkg), isTrue,
            reason: 'flutter_webrtc 的规则没有用**双星号**保留 `$pkg.**` —— '
                'native `.so` 通过 JNI FindClass 按类名查找这些类，'
                '单星号不跨包分隔符 ⇒ 子包被重命名 ⇒ release 视频路径静默失败。');
        expect(onlySingleStar(rules, pkg), isFalse,
            reason: '依赖规则里出现了单星号 `$pkg.*` —— 已退化，子包不再受保护。');
      }
    });

    test('WK-04 本工程规则不得重复且写错地声明 org.webrtc（依赖侧已足够）', () {
      final app = appRules.readAsStringSync();
      // 允许 totally 不提；不允许"提了但用单星号"（那会给人"已自保"的错觉，
      // 而单星号恰恰保不住子包）。
      expect(onlySingleStar(app, 'org.webrtc'), isFalse,
          reason: '应用级规则里出现单星号 `org.webrtc.*` —— 视频原生类的保活'
              '由依赖的 consumer 规则（双星号）负责，这里写单星号既多余又保不住子包。');
    });
  });

  // =====================================================================
  group('反例：判据非恒真', () {
    test('WKR-01 去掉 consumerProguardFiles → WK-02 判据判红', () {
      final raw = depGradle!.readAsStringSync();
      final bad =
          raw.replaceFirst(RegExp(r'consumerProguardFiles\s+[^\n]*'), '');
      expect(bad, isNot(raw), reason: '反例样本没构造成功（替换没生效）—— 反例失去意义');
      expect(wiresConsumerRules(bad), isFalse,
          reason: '★ 反例必须让 WK-02 判红 ⇒ 判据非恒真');
    });

    test('WKR-02 把双星号改回单星号 → WK-03 判据判红', () {
      final raw = depRules!.readAsStringSync();
      final bad = raw.replaceFirst('org.webrtc.**', 'org.webrtc.*');
      expect(bad, isNot(raw), reason: '反例样本没构造成功（替换没生效）—— 反例失去意义');
      expect(keepsWholeSubtree(bad, 'org.webrtc'), isFalse,
          reason: '★ 反例必须让 WK-03（双星号）判红 ⇒ 判据非恒真');
      expect(onlySingleStar(bad, 'org.webrtc'), isTrue,
          reason: '★ 反例必须让 WK-03（单星号否决）判红 ⇒ 判据非恒真');
    });
  });
}