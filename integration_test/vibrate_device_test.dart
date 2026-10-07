// ignore_for_file: avoid_print
/// **P0 设备取证**：振动能力四条实测 + usage 传递 + 停止（docs/20 §13 设备层 /
/// docs/17 §52⑦ 入口 1）。
///
/// ## 这个文件存在的理由
///
/// docs/20 的整套降级设计（包络 → 波形+振幅 → on/off）建立在**设备能力假设**上，
/// 而这类假设**读文档读代码都确认不了**，必须真机跑。三条最要命的：
///
/// 1. **`hasAmplitudeControl()`**：Android 官方文档明确该值为 false 时，系统会把
///    **所有非零振幅一律当成 100%**（"强度设置静默失效"）。同一份配置在不同设备
///    上体感完全不同**且不报错** —— 正是本项目最忌讳的静默降级。
/// 2. **`areEnvelopeEffectsSupported()`**：⚠️ **"Android 16" ≠ "支持包络"**。
///    包络是 **HAL 能力**，系统版本只是必要条件。本文件头号价值就是把
///    「版本够」与「设备真的支持」分开 —— 本机实测结论见 docs/12 §54。
/// 3. **`VibrateCaps.fromMap` 的兜底会掩盖缺陷**：它对缺失字段一律取保守值
///    （`?? false`）。若 Kotlin handler 因异常没返回某个 key，**上层会静默降级**
///    而设备侧毫无异常。所以 VD-02 直接比对**原生原样回执**与 Dart 解析结果。
///
/// ## BUG-069 的定性方式（本文件只做一半，另一半在主机侧）
///
/// BUG-069 的**后果**是"任务到点了但没震"——即振动调用**返回成功却没真的发生**。
/// 这**不能靠 Dart 侧断言证明**（`vibrateCommand` 返回 true 只说明 Kotlin 没抛异常）。
/// 唯一裁判是**系统侧的 `dumpsys vibrator_manager`**：
///
/// ```bash
/// # 跑完本文件后，在主机侧核对（不靠手感/听感）
/// "$ADB" -s <serial> shell dumpsys vibrator_manager | grep -i sonic_shield
/// ```
///
/// 本文件负责把每次调用打上**可辨识的时间戳**（`[VD-xx] ... at=<ISO8601>`），
/// 主机侧据此在 `Recent vibrations` 里逐条对上号。
///
/// **后台场景**由主机侧制造：跑测试期间循环执行
/// `am start -a android.intent.action.MAIN -c android.intent.category.HOME`
/// 把本 App 挤到后台（⚠️ 不能用 `input keyevent`：小米 HyperOS 缺 `INJECT_EVENTS`，
/// 见 `scripts/gates.sh` 的实测注记）。
///
/// ## 运行
///
/// ```bash
/// export ANDROID_HOME='E:\dev\android-sdk'
/// flutter test integration_test/vibrate_device_test.dart -d <serial> --no-uninstall
/// ```
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/domain/scheduling/vibrate_resolve.dart';
import 'package:sonic_shield/services/native_bridge.dart';

/// 本应用包名（主机侧 dumpsys 按此过滤）。
const String kProbePackage = 'com.sonicshield.sonic_shield';

const MethodChannel _ch = MethodChannel(ChannelsMethod.channel);

/// 打一条**带时间戳**的取证行 —— 主机侧靠它把 Dart 调用与 dumpsys 记录对上号。
void _evidence(String tag, String msg) {
  debugPrint('[$tag] $msg at=${DateTime.now().toIso8601String()}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('VD-01 能力探测：桥必须真的应答（不能落到 unknown 兜底）', (_) async {
    final raw =
        await _ch.invokeMethod<Map<Object?, Object?>>('vibrateCapabilities');
    _evidence('VD-01', 'raw=$raw');

    expect(
      raw,
      isNotNull,
      reason: '原生 handler 没应答。此时 VibrateCaps.fromMap 会用 `?? false` '
          '兜底 → 上层**静默降级**到"设备无能力"，而设备侧毫无异常。'
          '这正是必须直接看 raw 的原因。',
    );

    final caps = await NativeBridge.vibrateCapabilities();
    _evidence('VD-01', 'caps=$caps');

    expect(
      caps.platform,
      'android',
      reason: 'platform=unknown 说明桥不可用（与"设备真的没有振动器"是两码事，'
          '见 VibrateCaps.unknown 的文档：两者后果相同但排查结论完全不同）。',
    );
    expect(caps, isNot(VibrateCaps.unknown),
        reason: 'unknown 是"读不到"的兜底，不是真实能力。');
    expect(
      caps.hasVibrator,
      isTrue,
      reason: '真机必须有振动器；false 说明探测链断了（不是"设备没有"）。',
    );

    // 四条能力的**真实取值**——这就是 P0 要交付的取证数据。
    _evidence(
      'VD-01',
      '四条能力 hasVibrator=${caps.hasVibrator} '
      'hasAmplitudeControl=${caps.hasAmplitudeControl} '
      'hasEnvelope=${caps.hasEnvelope} '
      'minControlPointMs=${caps.minControlPointMs}',
    );
    _evidence('VD-01', 'canExpressAmplitude=${caps.canExpressAmplitude}');
  });

  testWidgets('VD-02 原生原样回执 与 Dart 解析必须逐项一致', (_) async {
    final raw =
        await _ch.invokeMethod<Map<Object?, Object?>>('vibrateCapabilities');
    expect(raw, isNotNull);
    final caps = await NativeBridge.vibrateCapabilities();

    final mismatches = <String>[];
    void cmp(String key, Object? dartVal) {
      final r = raw![key];
      if (r != dartVal) mismatches.add('$key: raw=$r vs dart=$dartVal');
    }

    cmp('hasVibrator', caps.hasVibrator);
    cmp('hasAmplitudeControl', caps.hasAmplitudeControl);
    cmp('hasEnvelope', caps.hasEnvelope);
    cmp('minControlPointMs', caps.minControlPointMs);
    cmp('platform', caps.platform);

    _evidence('VD-02', 'mismatches=$mismatches');
    expect(
      mismatches,
      isEmpty,
      reason: '原生回执与 Dart 解析不一致 ⇒ 中间有静默改写（默认值兜底/类型丢精度），'
          '上层拿到的能力就不是设备真实能力。',
    );
  });

  testWidgets('VD-03 usage 如实传递：ALARM 与 NOTIFICATION 都必须被接受', (_) async {
    // 两条除 usage 外**完全相同**的命令。主机侧 dumpsys 的 `usage:` 字段
    // 必须分别显示 ALARM / NOTIFICATION —— 这才证明 attributes 真的传下去了。
    const alarm = VibrateCommand(
      mode: VibrateMode.waveformAmplitude,
      chunkMs: 1200,
      timings: <int>[0, 400, 200, 400],
      amplitudes: <int>[0, 255, 0, 128],
      useAlarmUsage: true,
    );
    const notif = VibrateCommand(
      mode: VibrateMode.waveformAmplitude,
      chunkMs: 1200,
      timings: <int>[0, 400, 200, 400],
      amplitudes: <int>[0, 255, 0, 128],
      useAlarmUsage: false,
    );

    _evidence('VD-03', 'A(ALARM) 即将下发');
    final okA = await NativeBridge.vibrateCommand(alarm);
    _evidence('VD-03', 'A(ALARM) ret=$okA');
    await Future<void>.delayed(const Duration(seconds: 2));

    _evidence('VD-03', 'B(NOTIFICATION) 即将下发');
    final okB = await NativeBridge.vibrateCommand(notif);
    _evidence('VD-03', 'B(NOTIFICATION) ret=$okB');
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(okA, isTrue,
        reason: '带 USAGE_ALARM 的命令被原生拒绝 —— 后台振动的主路径，必须成立。');
    expect(okB, isTrue, reason: '带 USAGE_NOTIFICATION 的命令被原生拒绝。');
  });

  testWidgets('VD-04 包络：探测值与运行时行为必须一致（不静默降级）', (_) async {
    final caps = await NativeBridge.vibrateCapabilities();

    // ⚠️ 无论探测结果如何都**下发一次**：要验证"不支持时**显式返回 false**"。
    // docs/20 §5.2 明确：系统**不为包络效果提供 fallback**，不支持时会被
    // **完全忽略**（不报错）—— 所以原生必须自己把 false 传回来，上层才能走降级链。
    const env = VibrateCommand(
      mode: VibrateMode.envelope,
      chunkMs: 900,
      points: <EnvelopePoint>[
        EnvelopePoint(intensity: 0.2, sharpness: 0.3, durationMs: 200),
        EnvelopePoint(intensity: 1.0, sharpness: 0.8, durationMs: 300),
        EnvelopePoint(intensity: 0.4, sharpness: 0.2, durationMs: 200),
        // 官方硬约束：基础包络必须以 intensity == 0 的控制点结尾。
        EnvelopePoint(intensity: 0, sharpness: 0, durationMs: 20),
      ],
      useAlarmUsage: true,
    );

    _evidence('VD-04', 'caps.hasEnvelope=${caps.hasEnvelope} 即将下发 envelope');
    final ok = await NativeBridge.vibrateCommand(env);
    _evidence('VD-04', 'envelope ret=$ok');
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      ok,
      caps.hasEnvelope,
      reason: '探测与运行时行为不一致：探测=${caps.hasEnvelope} 运行时=$ok。'
          '若探测 true 而运行时 false ⇒ 上层会以为自己能用包络；'
          '若探测 false 而运行时 true ⇒ 说明探测链漏判（白白降级）。',
    );
  });

  testWidgets('VD-05 vibrateStop：长振动可被立即停止（S3：任何时刻都能停）', (_) async {
    const long = VibrateCommand(
      mode: VibrateMode.waveformAmplitude,
      chunkMs: 8000,
      timings: <int>[0, 8000],
      amplitudes: <int>[0, 255],
      useAlarmUsage: false,
    );

    _evidence('VD-05', '下发 8s 长振动');
    final ok = await NativeBridge.vibrateCommand(long);
    _evidence('VD-05', 'long ret=$ok');
    expect(ok, isTrue);

    await Future<void>.delayed(const Duration(seconds: 2));
    _evidence('VD-05', '此刻应仍在振动 → 调用 vibrateStop');
    await NativeBridge.vibrateStop();
    _evidence('VD-05', 'vibrateStop 已返回');
    await Future<void>.delayed(const Duration(seconds: 2));

    // 主机侧核对：dumpsys 的 `CurrentVibration` 应已回到 null。
    _evidence('VD-05', '主机侧请核对 CurrentVibration 已回到 null');
  });

  testWidgets('VD-06 取证收尾：打印包名与时间窗供 dumpsys 对号', (_) async {
    _evidence('VD-06', 'package=$kProbePackage');
    _evidence(
      'VD-06',
      '主机侧核对命令：'
      'dumpsys vibrator_manager | grep -i sonic_shield',
    );
    expect(kProbePackage, 'com.sonicshield.sonic_shield');
  });
}
