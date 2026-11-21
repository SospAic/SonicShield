// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **振动回执检查锁**（第三十四轮，来自 iOS 平台对账）。
///
/// ## 缺陷形状（实测确证）
///
/// `lib/services/background_engine.dart` 的 `VibrateAction` 分支此前是：
///
/// ```dart
/// await native.invokeMethod('vibrate', {'pattern': v.patternMs});
/// await logs.append(… status: 'success' …);
/// ```
///
/// 只看"有没有抛异常"。可是两端行为不同：
/// - **Android**：`NativeBridgePlugin.kt` 的 `"vibrate" -> { … result.success(true) }`；
/// - **iOS**：`HapticBridge.swift` **没有** `vibrate` 这个 case，也不会 `result(...)`
///   —— `invokeMethod` 返回 **null 且不抛**。
///
/// 于是 iOS 上审计写着一条**成功的振动**，而机器抖都没抖。这是项目红线
/// 「承诺了就必须做到，做不到必须留痕」被绕过的一种形态：**静默假成功**
/// （与 C-3 `volume.set` 在 iOS 恒 `ok=false`、`playHandler` 空转同族）。
///
/// ## 为什么是源码契约锁
///
/// 与 `test/engine_reentrancy_test.dart` 同一理由：`executeDue` 只在
/// `flutter_background_service` 的 isolate 里跑（真实 DB / 原生桥），宿主机
/// **实例化不了**。所以锁结构。
///
/// ## 项目铁律：断言必须**非恒真**
///
/// 这里把判定逻辑抽成 [judgeVibrateAck]，并且**用反面样本**证明它会判红
/// （[VIB-90]）—— 否则"检测器永远返回 true"也会让本文件全绿，那就是假锁。
void main() {
  final engineSrc = File('lib/services/background_engine.dart').readAsStringSync();

  /// 判定"振动回执是否被检查"。
  ///
  /// 返回 null = 通过；否则返回**具体缺失项**（便于定位，也便于反面样本断言）。
  String? judgeVibrateAck(String src) {
    final i = src.indexOf("invokeMethod('vibrate'");
    if (i < 0) return '源码里找不到 invokeMethod(\'vibrate\')';
    // 取该调用往后的一段（含赋值行 + 随后的分支）。
    final seg = src.substring(i, (i + 1400).clamp(0, src.length));

    // ① 结果必须被**捕获**：不能是裸 `await native.invokeMethod(...);`
    if (!RegExp(r'final\s+\w+\s*=\s*await\s+native\.invokeMethod\(\s*.vibrate.')
            .hasMatch(src.substring(
                (i - 80).clamp(0, src.length), (i + 200).clamp(0, src.length)))) {
      return '原生回执没有被捕获到变量（裸 await = 无法判断成败）';
    }
    // ② 必须对回执做真值判定
    if (!RegExp(r'\w+\s*==\s*true').hasMatch(seg)) {
      return '捕获了回执却没有真值判定（== true）';
    }
    // ③ success 审计必须出现在判定**之后**（在判定之前的 success 就是无条件成功）
    final judgeAt = seg.indexOf(RegExp(r'\w+\s*==\s*true').stringMatch(seg)!);
    final okAt = seg.indexOf("status: 'success'");
    if (okAt < 0) return '找不到 success 审计';
    if (okAt < judgeAt) return 'success 审计出现在真值判定之前（仍然是无条件成功）';
    // ④ 非 true 分支必须**如实留痕**（且不得也写 success）
    if (!seg.contains("status: 'skipped'")) {
      return '非 true 分支没有留下可辨的审计（skipped）';
    }
    if (!seg.contains('未确认')) {
      return '非 true 分支的文案没有说明"平台未确认"，用户无法区分"没做"和"做了"';
    }
    return null;
  }

  group('VIB 振动回执检查（源码契约锁）', () {
    test('VIB-00 抽取器锚定到真实调用点（防签名/写法变更后锁空转）', () {
      expect(engineSrc.contains("invokeMethod('vibrate'"), isTrue,
          reason: '锚点丢了 → 本锁整组空转');
      expect(judgeVibrateAck(engineSrc), isNull,
          reason: '当前源码应通过判定，缺：${judgeVibrateAck(engineSrc)}');
    });

    test('VIB-01 原生回执被捕获并做真值判定（不再是裸 await）', () {
      final verdict = judgeVibrateAck(engineSrc);
      expect(verdict, isNull, reason: '$verdict');
    });

    test('VIB-02 success 审计只在回执为真时出现（顺序锁）', () {
      final i = engineSrc.indexOf("invokeMethod('vibrate'");
      final seg = engineSrc.substring(i, (i + 1400).clamp(0, engineSrc.length));
      final judgeAt = seg.indexOf('== true');
      final okAt = seg.indexOf("status: 'success'");
      expect(judgeAt, greaterThanOrEqualTo(0));
      expect(okAt, greaterThan(judgeAt),
          reason: '★ 顺序反了就等于"先记成功、再看好坏" —— 与旧代码等价');
    });

    test('VIB-03 未确认时写 skipped 且说明"平台未确认"', () {
      final i = engineSrc.indexOf("invokeMethod('vibrate'");
      final seg = engineSrc.substring(i, (i + 1400).clamp(0, engineSrc.length));
      expect(seg.contains("status: 'skipped'"), isTrue,
          reason: '不写 failed：命令没错，是平台没实现这条通道');
      expect(seg.contains('未确认'), isTrue);
      // 回执原值要留在文案里，便于诊断
      expect(RegExp(r'原生回执=\$?\w+').hasMatch(seg), isTrue,
          reason: '把原生回执值写进审计，才能一眼分辨 null / false / 异常');
    });

    test('VIB-04 异常路径仍然写 failed（没有被本次改动吃掉）', () {
      final i = engineSrc.indexOf("invokeMethod('vibrate'");
      final seg = engineSrc.substring(i, (i + 1400).clamp(0, engineSrc.length));
      expect(seg.contains("status: 'failed'"), isTrue);
      expect(seg.contains('原生调用失败'), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 非恒真证明：用**反面样本**验证检测器真的会判红
  // ══════════════════════════════════════════════════════════════════
  group('VIB-90 检测器有效性（反面样本必须判红）', () {
    test('VIB-90a 旧写法（裸 await + 无条件 success）→ 判红', () {
      const old = '''
        try {
          await native.invokeMethod('vibrate', {'pattern': v.patternMs});
          await logs.append(
              source: source,
              action: 'vibrate',
              status: 'success',
              taskId: task.id,
              occurrenceId: occurrenceId);
        } on Object {
          await logs.append(
              source: source,
              action: 'vibrate',
              status: 'failed',
              taskId: task.id,
              occurrenceId: occurrenceId,
              message: '原生调用失败（桥不可用或被拒绝）');
        }
''';
      expect(judgeVibrateAck(old), isNotNull,
          reason: '★ 若这条样本被判为"通过"，说明检测器恒真 —— 整组锁是假的');
    });

    test('VIB-90b 捕获了回执但没判定 → 判红', () {
      const partial = '''
        try {
          final ack = await native.invokeMethod('vibrate', {'pattern': v.patternMs});
          await logs.append(status: 'success', message: 'ack=\$ack');
        } on Object {
          await logs.append(status: 'failed');
        }
''';
      expect(judgeVibrateAck(partial), isNotNull,
          reason: '捕获而不判定 = 仍然"有异常才算失败"，与旧行为等价');
    });

    test('VIB-90c 判定与 success 顺序颠倒 → 判红', () {
      const swapped = '''
        try {
          final ack = await native.invokeMethod('vibrate', {'pattern': v.patternMs});
          await logs.append(status: 'success');
          if (ack == true) {
            await logs.append(status: 'skipped', message: '平台未确认');
          }
        } on Object {
          await logs.append(status: 'failed');
        }
''';
      expect(judgeVibrateAck(swapped), isNotNull,
          reason: '顺序锁必须真的生效（先记成功再判断 = 假修复）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // BUG-157 / R105：固定节奏链路 USAGE_ALARM（R93 漏修的老链路）
  // ══════════════════════════════════════════════════════════════════
  group('VIB-157 固定节奏链路按来源选 USAGE（源码契约锁）', () {
    final kt = File('packages/native_bridge/android/src/main/kotlin/'
            'com/sonicshield/native_bridge/NativeBridgePlugin.kt')
        .readAsStringSync();
    final bridge = File('lib/services/native_bridge.dart').readAsStringSync();

    test('VIB-157-1 Kotlin vibrate 分支读取 useAlarmUsage 参数', () {
      final i = kt.indexOf('"vibrate" -> {');
      expect(i, greaterThanOrEqualTo(0), reason: '锚点丢失 → 锁空转');
      final seg = kt.substring(i, (i + 1200).clamp(0, kt.length));
      expect(seg.contains('call.argument<Boolean>("useAlarmUsage")'), isTrue,
          reason: '原生不读参数 ⇒ Dart 传什么都被忽略，修复无效');
      expect(RegExp(r'vibrate\(ctx,\s*pattern,\s*useAlarm\)').hasMatch(seg),
          isTrue,
          reason: '读到的参数必须透传给 vibrate()');
    });

    test('VIB-157-2 Kotlin vibrate() 默认 false 且透传 useAlarm 到 waveform', () {
      final i = kt.indexOf('private fun vibrate(');
      expect(i, greaterThanOrEqualTo(0));
      final seg = kt.substring(i, (i + 400).clamp(0, kt.length));
      expect(seg.contains('useAlarm: Boolean = false'), isTrue,
          reason: '默认必须 false = 远程入站跟随勿扰（合规红线）');
      expect(seg.contains('vibrateWaveform(ctx, pattern, null, -1, useAlarm)'),
          isTrue,
          reason: '必须把 useAlarm 透传，不能再写死 false');
    });

    test('VIB-157-3 Dart 桥接层 vibrate() 暴露可选参数，默认 false', () {
      expect(
          RegExp(r'static Future<void> vibrate\(List<int> patternMs,\s*'
                  r'\{bool useAlarmUsage = false\}')
              .hasMatch(bridge),
          isTrue,
          reason: '桥接层默认必须 false（远程入站合规）');
      expect(bridge.contains("'useAlarmUsage': useAlarmUsage"), isTrue,
          reason: '参数必须真正下发到 MethodChannel');
    });

    test('VIB-157-4 本机任务按 source 选 ALARM，远程保持 NOTIFICATION', () {
      final i = engineSrc.indexOf("invokeMethod('vibrate'");
      // 判定行在锚点**之前**（先算 useAlarmForFixed 再 invokeMethod），
      // 故往前取一段；参数下发行在锚点之后，往后取一段。两者都要验。
      final before = engineSrc.substring((i - 400).clamp(0, i), i);
      final after = engineSrc.substring(i, (i + 400).clamp(0, engineSrc.length));
      expect(before.contains('RemoteParity.enabled'), isTrue,
          reason: 'R105 对齐：远程任务也走 ALARM，由单一真源控制');
      expect(after.contains("'useAlarmUsage': useAlarmForFixed"), isTrue,
          reason: '判定结果必须下发到原生');
    });

    test('VIB-157-5 R105 对齐：远程入口按 RemoteParity 走 USAGE_ALARM', () {
      final mainSrc = File('lib/main.dart').readAsStringSync();
      // 锚点要用赋值行 `..vibrateHandler =`，不能用裸 `vibrateHandler`
      // （会命中第 104 行的文档注释，导致锁空转误判）。
      final i = mainSrc.indexOf('..vibrateHandler =');
      expect(i, greaterThanOrEqualTo(0), reason: '远程入口赋值锚点丢失');
      final seg = mainSrc.substring(i, (i + 260).clamp(0, mainSrc.length));
      expect(seg.contains('useAlarmUsage: RemoteParity.enabled'), isTrue,
          reason: 'R105 远程=本机对齐：远程固定节奏也走 ALARM，'
              '但必须由单一真源 RemoteParity 控制（可收回）');
      expect(seg.contains('NativeBridge.vibrate(pattern)'), isFalse,
          reason: '旧的无参数调用已不能表达对齐策略，必须显式带 useAlarmUsage');
    });

    test('VIB-157-6 RemoteParity 单一真源：对齐开关集中且默认 true', () {
      final constSrc = File('lib/core/constants.dart').readAsStringSync();
      expect(constSrc.contains('abstract final class RemoteParity'), isTrue,
          reason: '必须集中成一个真源，不得散落各处硬编码');
      expect(constSrc.contains('static const bool enabled = true'), isTrue,
          reason: 'R105 裁决：远程=本机对齐，默认开启');
    });
  });
}
