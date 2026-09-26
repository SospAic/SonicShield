// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

/// **前台服务类型位锁**（F-2，SEC1 第 35 轮）。
///
/// ## 为什么必须有这个文件
///
/// `flutter_background_service` 的前台服务类型位在**两处**各写一份：
///
/// | # | 位置 | 作用 |
/// |---|---|---|
/// | ① | `lib/services/background_service_manager.dart` 的 `AndroidConfiguration.foregroundServiceTypes` | **运行时真正生效的那份** |
/// | ② | `android/app/src/main/AndroidManifest.xml` 的 `<service android:foregroundServiceType="...">` | Android 14+ 的「类型位必须在清单声明 + 对应 type-specific 权限」校验依据 |
///
/// 插件源码事实（`flutter_background_service_android-6.3.1`，pub 缓存静态读取）：
///
/// - `Config.java:81-83` `getForegroundServiceTypes()` 只读 Dart 写下的
///   SharedPreferences 值，**不与清单求并**；
/// - `BackgroundService.java:168-173` 把该值 split 后 OR 成 `startForeground`
///   的 type 位（`:173` `ServiceCompat.startForeground(...)`）；
/// - `ForegroundTypeMapper.java:28-37`：值非空 ⇒ 只按它算位；为空 ⇒
///   `FOREGROUND_SERVICE_TYPE_MANIFEST`（回落到清单）；
/// - 全插件 `grep -c onTimeout` = **0** ⇒ Android 15+ 的 `dataSync`
///   「24h 内累计 6h」上限到点后**没有** `onTimeout` 收尾，系统直接抛
///   `android.app.RemoteServiceException`（Fatal，进程级）。
///
/// ⇒ **不得把 `dataSync` 放回 Dart 类型位**（F-2）。本文件是这条的机器判据。
///
/// ## 为什么锁 Dart 侧而不是清单侧
///
/// 运行时 type 位由 Dart 侧决定（见上），所以「服务到底是不是 dataSync 型」
/// 由这一处说了算。主清单 `:145` 仍写着 `mediaPlayback|dataSync`（多声明的位
/// **只是允许、不会自动生效**），属待清理项，见 `_pt/audit/E1-silent-fix.md`
/// 的「需主线程同步的连带改动」——本文件**不**锁清单，以免与那一步冲突。
///
/// ## 项目铁律：断言必须**非恒真**
///
/// 判定抽成顶层纯函数（[judgeFgsTypes]），并配**反面样本**（组 `FGS-90*`）
/// 证明它对「坏代码」真的会判红。文本扫描一律**先剥注释**（[stripComments]
/// 照抄 `silent_failure_locks_test.dart`）——**本文件注释里就写着 `dataSync`
/// 三个字**，不剥注释这条锁会把自己的说明文字当成违规（假红）。
///
/// ⚠️ **诚实声明边界**：这是**源码文本锁**，不是运行时取证。
/// `dataSync` 的 6h 上限在真机上的具体计法（多类型服务如何折算）**未验证**。
void main() {
  // `stripComments` 见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源）。

  final bgsSrc = stripComments(
      File('lib/services/background_service_manager.dart').readAsStringSync());

  group('FGS 前台服务类型位（F-2）', () {
    test('FGS-L01 Dart 类型位 = mediaPlayback，且**不含** dataSync / microphone', () {
      final v = judgeFgsTypes(bgsSrc);
      expect(v, isNull, reason: '$v');
    });
  });

  group('FGS-90 检测器有效性（反面样本必须判红）', () {
    test('FGS-90a [F-2] 修复前的双类型（mediaPlayback + dataSync）→ 判红', () {
      const old = '''
        foregroundServiceTypes: const [
          AndroidForegroundType.mediaPlayback,
          AndroidForegroundType.dataSync,
        ],
''';
      expect(judgeFgsTypes(old), isNotNull,
          reason: '★ 检测器对"dataSync 在位"判绿 = 恒真，整条锁是假的');
    });

    test('FGS-90b [F-2] 把 mediaPlayback 也删掉（只剩空列表）→ 判红', () {
      const empty = '''
        foregroundServiceTypes: const [],
''';
      expect(judgeFgsTypes(empty), isNotNull,
          reason: '★ 只锁"没有 dataSync"会放过"什么类型位都没有" —— '
              '那会让服务以 MANIFEST 语义启动，等于把类型位交回清单');
    });

    test('FGS-90c [F-2] microphone 混进来 → 判红', () {
      const mic = '''
        foregroundServiceTypes: const [
          AndroidForegroundType.mediaPlayback,
          AndroidForegroundType.microphone,
        ],
''';
      expect(judgeFgsTypes(mic), isNotNull,
          reason: '★ Android 14+ while-in-use：后台复活的 FGS 携带 microphone 会被拒');
    });
  });
}

// ══════════════════════════════════════════════════════════════════════════
// 源码文本锁判定器（顶层纯函数：输入剥过注释的源码，null=通过，非 null=具体缺失项）
// ══════════════════════════════════════════════════════════════════════════

/// [F-2] Dart 侧 `foregroundServiceTypes`：必须含 `mediaPlayback`，
/// **不得**含 `dataSync`（6h/24h 上限 + 插件无 `onTimeout`）与 `microphone`。
String? judgeFgsTypes(String src) {
  final i = src.indexOf('foregroundServiceTypes:');
  if (i < 0) {
    return '锚点丢失：找不到 foregroundServiceTypes 配置'
        '（插件将回落到清单类型位，F-2 的修复前提消失）';
  }
  final end = src.indexOf(']', i);
  if (end < 0) return '锚点丢失：foregroundServiceTypes 列表未闭合（无法判定内容）';
  final list = src.substring(i, end);

  if (!list.contains('AndroidForegroundType.mediaPlayback')) {
    return 'mediaPlayback 类型位丢了 —— 本工程后台确为「本地调度 + 定时播放」，'
        '且 mediaPlayback 不在 Android 15+ 的 6h 上限清单内，是唯一该留的位';
  }
  if (list.contains('AndroidForegroundType.dataSync')) {
    return '★ dataSync 又回来了：Android 15+ 对 dataSync 型 FGS 有'
        '「24h 内累计 6h」上限，到点系统回调 Service.onTimeout，而插件 '
        'BackgroundService.java 全文件 0 处 onTimeout（Config.java:81 只读此处'
        '写下的类型位）⇒ 到点抛 android.app.RemoteServiceException 杀进程（F-2）';
  }
  if (list.contains('AndroidForegroundType.microphone')) {
    return 'microphone 又回来了：Android 14+ while-in-use 限制下，'
        '后台复活的 FGS 携带 microphone 类型会被系统拒绝（SecurityException）';
  }
  return null;
}
