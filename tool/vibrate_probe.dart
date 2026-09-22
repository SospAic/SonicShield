// ignore_for_file: avoid_print
/// 声盾**振动能力探针**（P0 设备取证，docs/20 §13 / docs/17 §52⑦ 入口 1）。
///
/// ## 它解决什么问题
///
/// docs/20 的整套降级设计（包络 → 波形+振幅 → on/off）建立在一组**设备能力假设**
/// 之上。这些假设**不能靠读文档或读代码确认** —— 必须真机实测：
///
/// 1. **`hasAmplitudeControl()` 的真实取值**。Android 官方文档明确：该值为 false 时
///    系统会把**所有非零振幅一律当成 100%**（"强度设置静默失效"）。同一份配置在
///    不同设备上体感完全不同**且不报错** —— 这正是本项目最忌讳的静默降级。
/// 2. **`areEnvelopeEffectsSupported()` 的真实取值**。⚠️ 关键：**"Android 16"≠"支持包络"**。
///    包络是 HAL 能力，系统版本只是必要条件。本探针存在的头号理由就是**把"版本够"
///    与"设备真的支持"分开**（本机实测结论见 docs/12 §54）。
/// 3. **BUG-069 的后果验证**：现有代码是否真的在**后台**发起了振动（而不是"以为发了"）。
///
/// ## 为什么不是纯 `adb shell dumpsys`
///
/// `dumpsys vibrator_manager` 能看到**系统侧**的记录（这是最终裁判，本探针也依赖它），
/// 但它看不到 **Dart 侧的解析结果** —— 而 `VibrateCaps.fromMap` 对缺失字段有一律取
/// 保守值的兜底（`?? false`）。若原生 handler 因异常没返回某个 key，dumpsys 完全正常，
/// 而 Dart 侧会**静默降级**。所以本探针**同时**打印：
/// - `A.raw`：原生**原样**回执（不经任何默认值兜底）→ 能看出"原生到底返回了什么"
/// - `B.caps`：Dart 解析后的结果 → 能看出"上层到底拿到了什么"
///
/// 两者不一致本身就是缺陷信号。
///
/// ## 用法（真机在线时）
///
/// ```bash
/// # 1) 取设备序列号（无线调试下形如 adb-XXXXX-YYYY._adb-tls-connect._tcp）
/// "$ADB" devices
/// # 2) 跑探针；flutter run 会把 print 输出（logcat tag=flutter）转发到本控制台
/// flutter run -d <serial> -t tool/vibrate_probe.dart
/// # 3) 探针结束后（或期间）取证系统侧记录
/// "$ADB" -s <serial> shell dumpsys vibrator_manager | grep -A2 -i sonic_shield
/// ```
///
/// ⚠️ 探针**不修改任何生产代码**，只调用 `NativeBridge` 的公开入口。
///
/// ## 输出约定
///
/// 所有行以 `[PROBE] ` 开头，形如 `[PROBE] A.raw = {...}`，便于 grep 与逐条复核。
/// 段位：A 原生原样 / B Dart 解析 / C usage A-B / D 包络 / E 停止 / F 后台 / G 收尾。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/domain/scheduling/vibrate_resolve.dart';
import 'package:sonic_shield/services/native_bridge.dart';

/// 应用包名（用于 dumpsys 里按包名过滤自己的振动记录）。
const String kProbePackage = 'com.sonicshield.sonic_shield';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ProbeApp());
}

void _log(String s) => print('[PROBE] $s');

class _ProbeApp extends StatefulWidget {
  const _ProbeApp();

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  final List<String> _lines = <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _emit(String s) {
    _log(s);
    if (mounted) {
      setState(() => _lines.add(s));
    }
  }

  Future<void> _run() async {
    final started = DateTime.now();
    _emit('===== SonicShield 振动能力探针（P0 设备取证，docs/20 §13）=====');
    _emit('时间 = ${started.toIso8601String()}');
    _emit('包名 = $kProbePackage（dumpsys 按此过滤）');

    // ---------------- A. 原生原样回执 ----------------
    _emit('');
    _emit('--- A. 能力探测：原生原样回执（不经 Dart 默认值兜底）---');
    const ch = MethodChannel(ChannelsMethod.channel);
    Map<Object?, Object?>? raw;
    try {
      raw = await ch.invokeMethod<Map<Object?, Object?>>('vibrateCapabilities');
      _emit('A.raw = $raw');
      _emit('A.raw.keys = ${raw?.keys.toList()}');
      if (raw != null) {
        for (final e in raw.entries) {
          _emit('A.raw[$e.key] = ${e.value}  (${e.value.runtimeType})');
        }
      }
    } on PlatformException catch (e) {
      _emit('A.raw.PlatformException = ${e.code} / ${e.message}');
    } on MissingPluginException catch (e) {
      _emit('A.raw.MissingPluginException = $e  ⇒ 桥未注册，后续全为兜底值');
    } catch (e) {
      _emit('A.raw.ERROR = $e');
    }

    // ---------------- B. Dart 侧解析 ----------------
    _emit('');
    _emit('--- B. Dart 侧解析（上层实际拿到的能力）---');
    final caps = await NativeBridge.vibrateCapabilities();
    _emit('B.caps = $caps');
    _emit('B.hasVibrator = ${caps.hasVibrator}');
    _emit('B.hasAmplitudeControl = ${caps.hasAmplitudeControl}');
    _emit('B.hasEnvelope = ${caps.hasEnvelope}');
    _emit('B.minControlPointMs = ${caps.minControlPointMs}');
    _emit('B.platform = ${caps.platform}');
    _emit('B.backgroundSupported = ${caps.backgroundSupported}');
    _emit('B.canExpressAmplitude = ${caps.canExpressAmplitude}');
    _emit('B.是 unknown 兜底吗 = ${caps == VibrateCaps.unknown}'
        '（true ⇒ 桥读不到，能力结论**不可用**）');
    _emit('B.是 none 兜底吗 = ${caps == VibrateCaps.none}');

    // 一致性自检：原生 raw 与 Dart 解析必须逐项一致，否则是缺陷。
    final rawMap = raw;
    if (rawMap != null) {
      final mism = <String>[];
      void cmp(String key, Object? dartVal) {
        final r = rawMap[key];
        if (r != dartVal) mism.add('$key: raw=$r vs dart=$dartVal');
      }

      cmp('hasVibrator', caps.hasVibrator);
      cmp('hasAmplitudeControl', caps.hasAmplitudeControl);
      cmp('hasEnvelope', caps.hasEnvelope);
      cmp('minControlPointMs', caps.minControlPointMs);
      cmp('platform', caps.platform);
      _emit('B.一致性自检 = ${mism.isEmpty ? 'PASS（逐项相同）' : 'FAIL：$mism'}');
    }

    // ---------------- C. usage 如实传递（A/B） ----------------
    _emit('');
    _emit('--- C. usage 如实传递：A=USAGE_ALARM / B=USAGE_NOTIFICATION ---');
    _emit('（两者都带 attributes，差别只在 usage；'
        'dumpsys 的 `usage:` 字段必须分别显示 ALARM / NOTIFICATION）');

    const waveAlarm = VibrateCommand(
      mode: VibrateMode.waveformAmplitude,
      chunkMs: 1200,
      timings: <int>[0, 400, 200, 400],
      amplitudes: <int>[0, 255, 0, 128],
      useAlarmUsage: true,
    );
    _emit('C.A.alarm.send = ${DateTime.now().toIso8601String()}');
    final okA = await NativeBridge.vibrateCommand(waveAlarm);
    _emit('C.A.alarm.ret = $okA  （false ⇒ 原生拒绝/异常，需查 logcat）');
    await Future<void>.delayed(const Duration(seconds: 3));

    const waveNotif = VibrateCommand(
      mode: VibrateMode.waveformAmplitude,
      chunkMs: 1200,
      timings: <int>[0, 400, 200, 400],
      amplitudes: <int>[0, 255, 0, 128],
      useAlarmUsage: false,
    );
    _emit('C.B.notification.send = ${DateTime.now().toIso8601String()}');
    final okB = await NativeBridge.vibrateCommand(waveNotif);
    _emit('C.B.notification.ret = $okB');
    await Future<void>.delayed(const Duration(seconds: 3));

    // ---------------- D. 包络路径（无论 caps 如何都调一次） ----------------
    _emit('');
    _emit('--- D. 包络路径（Android 16 / API 36）---');
    _emit('⚠️ 即使 caps.hasEnvelope=false 也调一次：'
        '要验证"不支持时**显式返回 false**，而不是静默降级"（docs/20 §5.2）。');

    const envCmd = VibrateCommand(
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
    _emit('D.envelope.send = ${DateTime.now().toIso8601String()}');
    final okD = await NativeBridge.vibrateCommand(envCmd);
    _emit('D.envelope.ret = $okD');
    _emit('D.caps.hasEnvelope = ${caps.hasEnvelope}');
    _emit('D.一致吗 = ${okD == caps.hasEnvelope ? 'PASS（探测与运行时行为一致）'
        : 'FAIL（探测=$caps.hasEnvelope 但运行时=$okD）'}');
    await Future<void>.delayed(const Duration(seconds: 3));

    // ---------------- E. vibrateStop ----------------
    _emit('');
    _emit('--- E. vibrateStop 生效（docs/20 §7.2 S3：任何时刻都能停）---');
    const longCmd = VibrateCommand(
      mode: VibrateMode.waveformAmplitude,
      chunkMs: 8000,
      timings: <int>[0, 8000],
      amplitudes: <int>[0, 255],
      useAlarmUsage: false,
    );
    _emit('E.long.send = ${DateTime.now().toIso8601String()}（8s 长振动）');
    final okE = await NativeBridge.vibrateCommand(longCmd);
    _emit('E.long.ret = $okE');
    await Future<void>.delayed(const Duration(seconds: 2));
    _emit('E.stop.send = ${DateTime.now().toIso8601String()}（此刻应仍在振动）');
    await NativeBridge.vibrateStop();
    _emit('E.stop.done  （dumpsys 的 CurrentVibration 应立刻变回 null）');
    await Future<void>.delayed(const Duration(seconds: 2));

    // ---------------- F. 后台振动（BUG-069 后果验证） ----------------
    _emit('');
    _emit('--- F. 后台振动：BUG-069 的**后果**验证 ---');
    _emit('⚠️ 取证要点：本段要在 App **退到后台**后触发振动，'
        '然后看 dumpsys 里是否**真的**留下记录。');
    _emit('👉 请在这 12 秒内按 HOME 把本 App 退到后台（或直接锁屏）。');
    for (var i = 12; i > 0; i -= 4) {
      _emit('F.countdown = $i');
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    _emit('F.bg.send = ${DateTime.now().toIso8601String()}（带 USAGE_ALARM）');
    final okF = await NativeBridge.vibrateCommand(waveAlarm);
    _emit('F.bg.ret = $okF');
    await Future<void>.delayed(const Duration(seconds: 4));
    _emit('F.bg.done = ${DateTime.now().toIso8601String()}');

    // ---------------- G. 收尾 ----------------
    final elapsed = DateTime.now().difference(started);
    _emit('');
    _emit('===== DONE（耗时 ${elapsed.inSeconds}s）=====');
    _emit('下一步（在主机上执行，不靠手感/听感）：');
    _emit('  \$ADB -s <serial> shell dumpsys vibrator_manager');
    _emit('  在 Recent vibrations 里按 `$kProbePackage` 过滤，逐条核对：');
    _emit('   · C 段两条 → usage 分别是 ALARM / NOTIFICATION');
    _emit('   · D 段     → 若 caps.hasEnvelope=false 则**不应**有 envelope 记录');
    _emit('   · E 段     → 8s 长振动记录存在，且 CurrentVibration 已回到 null');
    _emit('   · F 段     → 后台那次**必须**有记录（这就是 BUG-069 的结论）');
    _emit('');
    _emit('保持 15 秒供 dumpsys 取证…');
    await Future<void>.delayed(const Duration(seconds: 15));
    _emit('EXIT');
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('振动探针（P0）')),
        body: ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: _lines.length,
          itemBuilder: (_, i) => Text(
            _lines[i],
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ),
    );
  }
}
