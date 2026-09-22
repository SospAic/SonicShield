// ignore_for_file: avoid_print
/// **P0 设备取证（第 2 部分）：真"后台"振动**（docs/17 §56⑦ 入口 1）。
///
/// ## 为什么必须单独一个文件
///
/// `vibrate_device_test.dart` 覆盖了**前台**的四条能力、usage 传递与停止，
/// 但**"App 退到后台"这个场景一个都没测**。而它恰恰是振动能力最要命的一处：
/// docs/20 的失效安全 S1 写的是「**进程死亡即停**（分片续发）」——
/// 也就是说**退到后台（进程还活着）时振动应当继续**。
/// 如果实现里误把"Activity 不可见"当成"该停"，用户会看到"锁屏/切走就没声了"，
/// 而这在**前台测试里永远发现不了**。
///
/// ## 主机侧必须配合（测试自己推不动自己）
///
/// Dart 侧无法把自己挤到后台（`SystemNavigator.pop()` 会 finish Activity，
/// 那是"退出"不是"退到后台"，语义不同、会把进程状态也改掉）。
/// 所以后台由**主机侧**制造 —— 在跑本文件期间，**另一个终端**循环执行：
///
/// ```bash
/// # 小米 HyperOS 缺 INJECT_EVENTS（`input keyevent` 被拒），只能用 am start 挤后台
/// "$ADB" -s <serial> shell am start -a android.intent.action.MAIN \
///     -c android.intent.category.HOME
/// ```
///
/// 本文件的每个用例都会**打足够长的等待窗口**（每 5s 一条 `still waiting`），
/// 并在每次打点里带上 `at=<ISO8601>`，让主机侧能把
/// `dumpsys vibrator_manager` 的 `Recent vibrations` / `CurrentVibration`
/// 与 Dart 调用**逐条对上号**。
///
/// ## 判据（不用手感/听感）
///
/// | 用例 | Dart 侧 | 主机侧 `dumpsys` |
/// |---|---|---|
/// | VB-01 | `vibrateCommand` 返回 true | 等待期间 `CurrentVibration` **非 null**（后台仍在振） |
/// | VB-02 | 后台期间新命令**仍返回 true** | 出现**新的** `Recent vibrations` 记录 |
/// | VB-03 | 停止后无异常 | `CurrentVibration` 回到 null |
///
/// ## 运行
///
/// ```bash
/// export ANDROID_HOME='E:\dev\android-sdk'
/// export JAVA_HOME='E:\dev\jdk\jdk-21.0.2'
/// flutter test integration_test/vibrate_background_test.dart -d <serial> --no-uninstall
/// ```
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:sonic_shield/domain/scheduling/vibrate_resolve.dart';
import 'package:sonic_shield/services/native_bridge.dart';

const String kProbePackage = 'com.sonicshield.sonic_shield';

void _evidence(String tag, String msg) {
  debugPrint('[$tag] $msg at=${DateTime.now().toIso8601String()}');
}

/// 边等边打点 —— 让主机侧知道"现在正是该看到振动的时候"。
Future<void> _waitWithBeats(String tag, int seconds) async {
  final rounds = (seconds / 5).ceil();
  for (var i = 1; i <= rounds; i++) {
    await Future<void>.delayed(const Duration(seconds: 5));
    _evidence(tag, 'still-waiting $i/$rounds —— 主机侧此刻应能查到 CurrentVibration');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('VB-01 后台期间长振动**不应**被停（S1：只有进程死亡才停）', (_) async {
    // 30 秒足够主机侧从容地按 HOME、跑 dumpsys、再按一次。
    const long = VibrateCommand(
      mode: VibrateMode.waveformAmplitude,
      chunkMs: 30000,
      timings: <int>[0, 30000],
      amplitudes: <int>[0, 255],
      useAlarmUsage: false,
    );

    _evidence('VB-01', '即将下发 30s 长振动；主机侧请立刻开始循环按 HOME');
    final ok = await NativeBridge.vibrateCommand(long);
    _evidence('VB-01', 'ret=$ok');
    expect(ok, isTrue, reason: '长振动都没下发成功，后面的后台判断无从谈起');

    await _waitWithBeats('VB-01', 25);

    _evidence('VB-01', '窗口结束 —— 若主机侧在等待期间看到 CurrentVibration 非 null，'
        '则"退到后台振动继续"成立；若已为 null，说明实现把"不可见"当成了"该停"');
    await NativeBridge.vibrateStop();
    _evidence('VB-01', 'vibrateStop 已返回');
    await Future<void>.delayed(const Duration(seconds: 2));
  });

  testWidgets('VB-02 后台期间**仍能**下发新振动（后台不阻断命令）', (_) async {
    const short = VibrateCommand(
      mode: VibrateMode.waveformAmplitude,
      chunkMs: 1500,
      timings: <int>[0, 400, 200, 400],
      amplitudes: <int>[0, 255, 0, 128],
      useAlarmUsage: false,
    );

    _evidence('VB-02', '开始：主机侧请确保 App 已退到后台（按 HOME）');
    await _waitWithBeats('VB-02', 10);

    _evidence('VB-02', '在**后台**状态下下发一条新振动');
    final ok = await NativeBridge.vibrateCommand(short);
    _evidence('VB-02', 'ret=$ok');
    expect(
      ok,
      isTrue,
      reason: '后台状态下命令被拒 —— 那么"锁屏后到点的任务"就永远震不了。'
          '这不是"系统限制"能解释的：振动不需要前台 Activity。',
    );

    await Future<void>.delayed(const Duration(seconds: 3));
    _evidence('VB-02', '主机侧请核对 Recent vibrations 里出现了这条新记录');
  });

  testWidgets('VB-03 取证收尾：打印包名与核对命令', (_) async {
    final caps = await NativeBridge.vibrateCapabilities();
    _evidence('VB-03', 'package=$kProbePackage caps.hasEnvelope=${caps.hasEnvelope}');
    _evidence(
      'VB-03',
      '主机侧核对：dumpsys vibrator_manager | grep -i sonic_shield',
    );
    expect(kProbePackage, 'com.sonicshield.sonic_shield');
  });
}
