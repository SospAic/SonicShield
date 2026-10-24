import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_random.dart';
import 'package:sonic_shield/remote/rc_script.dart';

/// R93 振动「静默失败」链路：默认走 USAGE_ALARM + 系统状态可诊断。
///
/// ## 用户报障（2026-10-21）
/// 「手机震动的功能貌似不好使」。
///
/// ## 根因链
/// 振动动作默认 `respectDnd = true` ⇒ 原生走 **USAGE_NOTIFICATION**。
/// 系统**静音 / 勿扰**时该用法的整条振动会被吞掉，而
/// `vibrator.vibrate(...)` 依然返回成功 ⇒ 我们回执写 success、
/// 用户什么都没感觉到 —— 典型**静默失败**（本项目最忌讳的形态）。
///
/// ## 修法
/// 1. 本机自排的振动动作（模型默认 / 反击计划物化 / 编辑器新建）改为
///    `respectDnd = false`（USAGE_ALARM，等价"用户自己设的闹钟"）；
/// 2. 远程入站**仍强制 true**（对端不得绕过本机勿扰，合规红线不动）；
/// 3. `VibrateCaps` 增加 `ringerMode` / `dndActive`，让"调用成功却没震"
///    在审计日志里**可解释**（不再靠猜）。
void main() {
  group('R93 振动默认值：不再跟随勿扰', () {
    test('VD-01 三个振动模型的默认都是 false（= USAGE_ALARM）', () {
      expect(const RandomVibrateAction().respectDnd, isFalse);
      expect(const ContinuousVibrateAction().respectDnd, isFalse);
      // 音频**不动**：默认仍 true（静音时不该炸响）。
      expect(const PlayAudioAction().respectDnd, isTrue);
    });

    test('VD-02 JSON 缺省也随构造器（存量任务不得退回静默失败）', () {
      expect(RandomVibrateAction.fromJson(const {}).respectDnd, isFalse,
          reason: '旧数据没有 respectDnd 键，缺省必须是新默认');
      expect(ContinuousVibrateAction.fromJson(const {}).respectDnd, isFalse);
      // 音频**不动**：播放声音跟随勿扰（不炸别人的耳朵）。
      expect(PlayAudioAction.fromJson(const {}).respectDnd, isTrue);
    });

    test('VD-03 显式 true 仍然被尊重（用户可自己选择跟随勿扰）', () {
      expect(const RandomVibrateAction(respectDnd: true).respectDnd, isTrue);
      expect(
          RandomVibrateAction.fromJson(const {'respectDnd': true}).respectDnd,
          isTrue);
    });

    test('VD-04 反击计划物化出来的振动动作不走勿扰', () {
      final plan = CounterPlanRandom.generate(seed: 20261021);
      final tasks = CounterPlanMaterializer.materialize(
        plan,
        planId: 'p1',
        from: DateTime(2026, 10, 21, 12),
        days: 3,
        assetIdPool: const <String>{'annoy_spit'},
        now: null,
      );
      final vib = tasks
          .where((t) => t.action is RandomVibrateAction)
          .map((t) => t.action as RandomVibrateAction)
          .toList();
      expect(vib, isNotEmpty, reason: '默认参数下应有振动类反击任务');
      for (final a in vib) {
        expect(a.respectDnd, isFalse,
            reason: '反击计划是用户自己开的 ⇒ 必须等价闹钟，不能被静音吞掉');
      }
    });

    test('VD-05 远程入站仍强制 respectDnd=true（合规红线不动）', () {
      // 对端下发振动不得绕过本机勿扰 —— 这条是 docs/08 的红线，
      // R93 只放开"本机自排"，不放远程。随机/持续两种都验。
      final r = rcVibrateStartConfig(const {'mode': 'random'});
      expect(r, isA<RandomVibrateAction>());
      expect((r as RandomVibrateAction).respectDnd, isTrue,
          reason: '远程入站必须强制 true（对端不得绕过本机勿扰）');

      final c = rcVibrateStartConfig(const {'mode': 'continuous'});
      expect(c, isA<ContinuousVibrateAction>());
      expect((c as ContinuousVibrateAction).respectDnd, isTrue);
    });
  });

  group('R93 能力探测：系统状态可解释', () {
    test('VC-01 fromMap 解析 ringerMode / dndActive，缺失取保守值', () {
      final c = VibrateCaps.fromMap(const {
        'hasVibrator': true,
        'hasAmplitudeControl': false,
        'hasEnvelope': false,
        'minControlPointMs': 20,
        'platform': 'android',
        'ringerMode': 1,
        'dndActive': true,
      });
      expect(c.ringerMode, 1);
      expect(c.dndActive, isTrue);
      expect(c.notificationsMuted, isTrue, reason: '勿扰会被吞振动');
      // NAT-02：1 = 振动响铃态（该态下通知用法本就震，标签必须是"振动"）。
      // 旧代码把 1 当成"静音/正常"之外的第三态、把 0 与 2 的标签写反过。
      expect(c.ringerLabel, '振动');

      final d = VibrateCaps.fromMap(const {'hasVibrator': true});
      expect(d.ringerMode, -1, reason: '读不到必须如实标记为 -1，不得猜');
      // QUA-09：读不到 ⇒ null（不是 false）。false 必须是"确定没开"。
      expect(d.dndActive, isNull);
      expect(d.notificationsMuted, isFalse, reason: '读不到不谎称被吞');
      expect(d.ringerLabel, '读不到');
    });

    test('VC-01b NAT-02 映射三态：只有静音(0)算被吞（附反面样本）', () {
      VibrateCaps caps(int ringer, bool? dnd) => VibrateCaps(
            hasVibrator: true,
            hasAmplitudeControl: false,
            hasEnvelope: false,
            minControlPointMs: 20,
            platform: 'android',
            ringerMode: ringer,
            dndActive: dnd,
          );

      // 静音(0)：通知类振动被系统整条吞掉 ⇒ 必须算被吞。
      final silent = caps(RingerMode.silent, false);
      expect(silent.notificationsMuted, isTrue,
          reason: 'NAT-02 核心：静音必须算"会被吞"，旧代码放过了它');
      expect(silent.ringerLabel, '静音');

      // 振动(1)：该态下通知用法本就震 ⇒ 不算被吞（旧代码的反面）。
      final vib = caps(RingerMode.vibrate, false);
      expect(vib.notificationsMuted, isFalse,
          reason: 'NAT-02 反面样本：振动响铃态不是"被吞"态');
      expect(vib.ringerLabel, '振动');

      // 正常(2)：更不在列（旧代码把 2 当成"振动/被吞"，整体反向）。
      final normal = caps(RingerMode.normal, false);
      expect(normal.notificationsMuted, isFalse,
          reason: 'NAT-02 反面样本：正常响铃绝不算"会被吞"');
      expect(normal.ringerLabel, '正常');

      // 读不到(-1)：不知道就不下结论（BUG-041 口径）。
      final unknown = caps(RingerMode.unknown, null);
      expect(unknown.notificationsMuted, isFalse);
      expect(unknown.ringerLabel, '读不到');

      // 勿扰是独立维度：任何响铃态下 dndActive=true 都算被吞。
      expect(caps(RingerMode.normal, true).notificationsMuted, isTrue);
      expect(caps(RingerMode.vibrate, true).notificationsMuted, isTrue);
    });

    test('VC-02 toMap 往返一致', () {
      const c = VibrateCaps(
        hasVibrator: true,
        hasAmplitudeControl: false,
        hasEnvelope: false,
        minControlPointMs: 20,
        platform: 'android',
        ringerMode: RingerMode.normal,
        dndActive: false,
      );
      expect(VibrateCaps.fromMap(c.toMap()), c);
      expect(c.notificationsMuted, isFalse);
      expect(c.ringerLabel, '正常');
    });

    test('VC-03 勿扰（响铃正常）也算"通知类振动会被吞"', () {
      const c = VibrateCaps(
        hasVibrator: true,
        hasAmplitudeControl: false,
        hasEnvelope: false,
        minControlPointMs: 20,
        platform: 'android',
        ringerMode: RingerMode.normal,
        dndActive: true,
      );
      expect(c.notificationsMuted, isTrue);
      expect(c.ringerLabel, '正常', reason: '勿扰与响铃模式是两件事，标签分开');
    });
  });

  group('R93 原生侧源码锁（Kotlin 不被 analyze 覆盖）', () {
    final src =
        File('packages/native_bridge/android/src/main/kotlin/com/sonicshield/'
                'native_bridge/NativeBridgePlugin.kt')
            .readAsStringSync();

    test('VC-04 能力探测必须回传 ringerMode 与 dndActive', () {
      final region = _region(src, 'private fun vibrateCapabilities(',
          'private fun vibrationAttributes(');
      expect(region, contains('"ringerMode" to ringerMode'),
          reason: '不回传响铃模式 ⇒ "调用成功却没震"永远解释不了');
      expect(region, contains('"dndActive" to dndActive'),
          reason: '不回传勿扰状态同理');
      expect(region, contains('am?.ringerMode'),
          reason: '响铃模式要从 AudioManager 读，不能写死');
      expect(region, contains('currentInterruptionFilter'),
          reason: '勿扰状态要从 NotificationManager.currentInterruptionFilter 读');
    });

    test('VC-05 读系统状态一律 try/catch（不得因读不到就崩）', () {
      final region = _region(src, 'private fun vibrateCapabilities(',
          'private fun vibrationAttributes(');
      expect(region, contains('} catch (e: Exception) {'),
          reason: '两个新读点都必须兜异常');
      expect(_count(region, 'catch (e: Exception)'), greaterThanOrEqualTo(3),
          reason: 'hasVibrator / 振幅 / 包络 / 响铃 / 勿扰共 5 处，至少 3 处 catch');
    });
  });
}

String _region(String src, String from, String to) {
  final i = src.indexOf(from);
  expect(i, greaterThan(-1), reason: '定位不到起始签名：$from');
  final j = src.indexOf(to, i);
  expect(j, greaterThan(i), reason: '定位不到结束签名：$to');
  return src.substring(i, j);
}

int _count(String s, String needle) =>
    needle.allMatches(s).length;
