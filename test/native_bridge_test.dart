import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/scheduling/vibrate_resolve.dart';
import 'package:sonic_shield/services/native_bridge.dart';

/// `NativeBridge` 的**宿主机契约回归锁**。
///
/// ## 为什么需要这个文件
///
/// `NativeBridge` 此前**零覆盖**（本仓库也没有任何测试用过 mock channel）。
/// 它最大的风险不是"算错了"，而是**静默降级**：
///
/// ```dart
/// try { return await _ch.invokeMethod<T>(method, args); }
/// on PlatformException { return null; }
/// on MissingPluginException { return null; }
/// ```
///
/// 也就是说 —— **方法名拼错、原生侧漏了 case、桥未注册、平台不支持**，
/// 这四种情况全都收敛成同一个 `null`，不抛异常、不打日志。
/// 对 v1.7 新增的 `callState` / `networkType` 而言，`null` 会被
/// `TaskCondition` 解读为"无法判定" → **按"条件满足"处理** →
/// "通话中不执行"与"仅 Wi-Fi"两条约束会**永久静默失效**。
///
/// 所以本文件锁三件事：
/// 1. **通道名与方法名的字面量**（第九轮实测过设备端，但那是一次性证据，
///    不是回归锁；改错名字在设备上才会暴露，代价高）；
/// 2. **每个方法的降级返回值**（契约本身）；
/// 3. **与 `TaskCondition` 串联后的最终决策**（null 必须"放行"、false 必须"拦"）。
///
/// 设备端行为由 `integration_test/native_bridge_test.dart` 负责（真机/模拟器），
/// 两者互补：本文件管"契约没被改坏"，设备端管"原生真的这么实现"。
/// 测试用的"平台通道另一侧"。
TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'sonic_shield/native';
  const channel = MethodChannel(channelName);

  final log = <MethodCall>[];

  /// 装一个可编程的"原生端"：记录调用，并按 [fn] 返回预设值。
  void installNative(Object? Function(MethodCall call) fn) {
    _messenger.setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      return fn(call);
    });
  }

  /// 模拟"原生侧没有这个方法"（Kotlin `result.notImplemented()` 走的就是这条路）。
  void installNotImplemented() {
    _messenger.setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      throw MissingPluginException(
          'No implementation found for ${call.method}');
    });
  }

  setUp(log.clear);
  tearDown(() => _messenger.setMockMethodCallHandler(channel, null));

  // ==================== 1. 通道/方法名字面量 ====================

  group('NB-H · 通道与方法名字面量（防"拼错即静默失效"）', () {
    test('NB-H01 isInCall 必须打在 sonic_shield/native 的 callState 上', () async {
      installNative((c) => c.method == 'callState' ? true : null);
      await NativeBridge.isInCall();
      expect(
        log.map((c) => c.method).toList(),
        ['callState'],
        reason: '方法名是原生侧 `when(call.method)` 的匹配键；改错只会得到 null，'
            '不会报错 —— 这正是最难排查的一类失效。',
      );
      expect(channel.name, channelName);
    });

    test('NB-H02 networkType 必须打在 networkType 上', () async {
      installNative((c) => c.method == 'networkType' ? 'wifi' : null);
      await NativeBridge.networkType();
      expect(log.map((c) => c.method).toList(), ['networkType']);
    });

    test('NB-H03 isOnWifi 走 networkType（不另开原生方法）', () async {
      installNative((c) => c.method == 'networkType' ? 'wifi' : null);
      await NativeBridge.isOnWifi();
      expect(
        log.map((c) => c.method).toList(),
        ['networkType'],
        reason: 'isOnWifi 是 Dart 侧派生，不该有独立原生方法；'
            '若有人加了第二个方法，两处判定就会漂移。',
      );
    });

    test('NB-H04 这两个方法都不带参数（避免原生侧 argument 解析歧义）', () async {
      installNative((c) => c.method == 'callState' ? false : 'cellular');
      await NativeBridge.isInCall();
      await NativeBridge.networkType();
      expect(log.every((c) => c.arguments == null), isTrue);
    });
  });

  // ==================== 2. isInCall 契约 ====================

  group('NB-H · isInCall 契约', () {
    test('原生 true → true', () async {
      installNative((_) => true);
      expect(await NativeBridge.isInCall(), isTrue);
    });

    test('原生 false → false（"能判定且未通话"必须与"无法判定"区分开）', () async {
      installNative((_) => false);
      expect(await NativeBridge.isInCall(), isFalse);
    });

    test('原生返回 null → null（iOS 等无桥接平台）', () async {
      installNative((_) => null);
      expect(await NativeBridge.isInCall(), isNull);
    });

    test('原生抛 PlatformException → null（静默降级，不炸引擎）', () async {
      installNative((_) => throw PlatformException(code: 'NATIVE_ERROR'));
      expect(await NativeBridge.isInCall(), isNull);
    });

    test('原生无此方法（notImplemented）→ null 而不是抛异常', () async {
      installNotImplemented();
      expect(await NativeBridge.isInCall(), isNull);
      expect(log, hasLength(1));
    });
  });

  // ==================== 3. networkType 契约 ====================

  group('NB-H · networkType 契约', () {
    for (final t in const [
      'wifi',
      'cellular',
      'ethernet',
      'vpn',
      'none',
      'other',
    ]) {
      test('原生 "$t" → 原样透传', () async {
        installNative((_) => t);
        expect(await NativeBridge.networkType(), t);
      });
    }

    test('BUG-040：判定"是否 Wi-Fi"只认 wifi 一个取值', () async {
      const all = [
        'wifi',
        'cellular',
        'ethernet',
        'vpn',
        'none',
        'other',
        'unknown',
      ];
      final wifiLike = <String>[];
      for (final t in all) {
        installNative((_) => t);
        if (await NativeBridge.isOnWifi() == true) wifiLike.add(t);
      }
      expect(
        wifiLike,
        ['wifi'],
        reason: 'Kotlin 会返回 vpn（BUG-040 就是文档漏列了它）。'
            '这里锁住"只有 wifi 被认定为 Wi-Fi"这一契约 —— '
            '若有人把 ethernet/vpn 也放行，requireWifi 的语义就被悄悄放宽了。',
      );
    });

    test('原生返回 null → unknown（有默认值，调用方不必处理 null）', () async {
      installNative((_) => null);
      expect(await NativeBridge.networkType(), 'unknown');
    });

    test('原生抛异常 → unknown', () async {
      installNative((_) => throw PlatformException(code: 'NATIVE_ERROR'));
      expect(await NativeBridge.networkType(), 'unknown');
    });
  });

  // ==================== 4. isOnWifi 派生 ====================

  group('NB-H · isOnWifi 派生（只认 wifi）', () {
    test('"wifi" → true', () async {
      installNative((_) => 'wifi');
      expect(await NativeBridge.isOnWifi(), isTrue);
    });

    for (final t in const ['cellular', 'ethernet', 'vpn', 'other']) {
      test('"$t" → false', () async {
        installNative((_) => t);
        expect(await NativeBridge.isOnWifi(), isFalse);
      });
    }

    test('BUG-041："unknown" → null（"无法判定"不等于"不在 Wi-Fi 下"）', () async {
      installNative((_) => 'unknown');
      expect(
        await NativeBridge.isOnWifi(),
        isNull,
        reason: '原生侧在取不到 ConnectivityManager / 读不出 capabilities 时'
            '返回 unknown，桥不可用时 Dart 侧也回落到 unknown —— 两者都是'
            '"无法判定"。若这里返回 false，条件层会**拦下**任务并在审计里写'
            '"不在 Wi-Fi 下"（一个我们并不知道的原因），'
            '正好违反 TaskCondition "无法判定按满足"的既有约定。',
      );
    });

    test('"none" → false（这是"确实没有活跃网络"这个确定状态）', () async {
      installNative((_) => 'none');
      expect(
        await NativeBridge.isOnWifi(),
        isFalse,
        reason: 'none 与 unknown 必须区别对待：'
            'none 是"确定没有网络"，unknown 是"读不出来"。',
      );
    });

    test('无法判定（原生返回 null）→ null 而不是 false', () async {
      installNative((_) => null);
      expect(
        await NativeBridge.isOnWifi(),
        isNull,
        reason: 'null 与 false 语义完全不同：false 会**拦下**任务，'
            'null 按"满足"放行。若这里退化成 false，'
            '非 Android 平台上的自动化会被整片静默停掉。',
      );
    });

    test('桥异常 → null（同上，不能退化成 false）', () async {
      installNative((_) => throw PlatformException(code: 'NATIVE_ERROR'));
      expect(await NativeBridge.isOnWifi(), isNull);
    });
  });

  // ==================== 5. 与条件层串联（真正的决策面） ====================

  group('NB-H · 桥 × TaskCondition 串联（端到端决策）', () {
    const cond = TaskCondition(skipInCall: true, requireWifi: true);

    String? decide({bool? inCall, bool? onWifi}) => cond.firstUnmet(
          charging: true,
          batteryLevel: 100,
          now: DateTime(2026, 9, 18, 12),
          inCall: inCall,
          onWifi: onWifi,
        );

    test('桥读不到 → 两条约束都不拦（"无法判定按满足"）', () async {
      installNative((_) => null);
      final inCall = await NativeBridge.isInCall();
      final onWifi = await NativeBridge.isOnWifi();
      expect(decide(inCall: inCall, onWifi: onWifi), isNull);
    });

    test('BUG-041 后果锁定：网络类型 unknown → 同样不拦', () async {
      installNative((c) => c.method == 'networkType' ? 'unknown' : false);
      expect(
        decide(
          inCall: await NativeBridge.isInCall(),
          onWifi: await NativeBridge.isOnWifi(),
        ),
        isNull,
        reason: 'unknown 是"读不出来"，必须与"在移动网络"（会拦）区分开。',
      );
    });

    test('对照：确实在移动网络 → 必须拦（证明上一条不是恒真）', () async {
      installNative((c) => c.method == 'networkType' ? 'cellular' : false);
      expect(
        decide(
          inCall: await NativeBridge.isInCall(),
          onWifi: await NativeBridge.isOnWifi(),
        ),
        '不在 Wi-Fi 下',
      );
    });

    test('Wi-Fi 上且未通话 → 放行', () async {
      installNative((c) => c.method == 'networkType' ? 'wifi' : false);
      expect(
        decide(
          inCall: await NativeBridge.isInCall(),
          onWifi: await NativeBridge.isOnWifi(),
        ),
        isNull,
      );
    });

    test('移动网络 → 拦，原因是"不在 Wi-Fi 下"', () async {
      installNative((c) => c.method == 'networkType' ? 'cellular' : false);
      expect(
        decide(
          inCall: await NativeBridge.isInCall(),
          onWifi: await NativeBridge.isOnWifi(),
        ),
        '不在 Wi-Fi 下',
      );
    });

    test('通话中 → 拦，且通话原因**优先**于 Wi-Fi', () async {
      installNative((c) => c.method == 'networkType' ? 'cellular' : true);
      expect(
        decide(
          inCall: await NativeBridge.isInCall(),
          onWifi: await NativeBridge.isOnWifi(),
        ),
        '通话中（不打扰通话）',
      );
    });

    test('VPN → 按"非 Wi-Fi"拦下（当前语义，已在文档标注未在设备验证）', () async {
      installNative((c) => c.method == 'networkType' ? 'vpn' : false);
      expect(
        decide(
          inCall: await NativeBridge.isInCall(),
          onWifi: await NativeBridge.isOnWifi(),
        ),
        '不在 Wi-Fi 下',
        reason: 'vpn 的语义是"活跃网络是 VPN 且未读出底层承载"，'
            '原生判定顺序为 wifi→cellular→ethernet→vpn（物理承载优先）。'
            '真实 VPN 场景下是否误拦，需真机验证（docs/12 §18.6）。',
      );
    });
  });

  // ==================== 6. 既有方法的降级契约（顺带补零覆盖） ====================

  group('NB-H · 既有方法的降级默认值（此前零覆盖）', () {
    test('桥不可用时 isIgnoringBatteryOptimizations → true（桌面视为无需处理）', () async {
      installNotImplemented();
      expect(await NativeBridge.isIgnoringBatteryOptimizations(), isTrue);
    });

    test('桥不可用时 setExactAlarms → 0（排布 0 个，而不是抛）', () async {
      installNotImplemented();
      expect(await NativeBridge.setExactAlarms([1, 2, 3]), 0);
    });

    test('桥不可用时 exactAlarmSupported → false', () async {
      installNotImplemented();
      expect(await NativeBridge.exactAlarmSupported(), isFalse);
    });

    test('桥不可用时 serviceShouldRun → false（不自启）', () async {
      installNotImplemented();
      expect(await NativeBridge.serviceShouldRun(), isFalse);
    });

    test('setVolume 只下发传入的流（不误改另一条流）', () async {
      installNative((_) => true);
      await NativeBridge.setVolume(media: 0.5);
      expect(log.single.arguments, {'media': 0.5});

      log.clear();
      await NativeBridge.setVolume(alarm: 0.8);
      expect(log.single.arguments, {'alarm': 0.8});

      log.clear();
      await NativeBridge.setVolume(media: 0.1, alarm: 0.2);
      expect(log.single.arguments, {'media': 0.1, 'alarm': 0.2});
    });
  });

  // ===========================================================================
  // 7. 振动（v1.9 核心能力）与 FGS 入口 —— 第四十轮补齐。
  //
  // 此前 `vibrate` / `vibrateCommand` / `clearAlarms` / `startMicService` /
  // `stopMicService` **一次都没被任何测试调用过**（逐行覆盖证据：
  // `_pt/covblocks.py native_bridge 1`）。而 `vibrateCommand` 是
  // "随机振动 / 持续振动"**唯一**的下发口（docs/20 §7.2）。
  //
  // 为什么必须逐键锁而不是只锁"返回 true"：它的两个分支载荷形状**不一样**
  // （envelope 发 `points`、waveform 发 `timings`/`amplitudes`），
  // 而原生侧 `when(call.method)` + `arguments.getXxx` 对**键名写错**只会
  // 静默取到 null —— 表现是"振动功能没反应"，不是报错。
  // ===========================================================================
  group('NB-H · 振动与 FGS 入口（第四十轮）', () {
    test('固定节奏 vibrate → 方法名与节奏数组原样下发', () async {
      installNative((_) => null);
      await NativeBridge.vibrate(const [0, 120, 60, 120]);
      expect(log.single.method, 'vibrate');
      expect(log.single.arguments, {'pattern': [0, 120, 60, 120]});
    });

    test('桥不可用时 vibrate / clearAlarms / 麦克风 FGS 入口都不得抛', () async {
      installNotImplemented();
      await NativeBridge.vibrate(const [0, 100]);
      await NativeBridge.clearAlarms();
      await NativeBridge.startMicService();
      await NativeBridge.stopMicService();
      expect(log.map((c) => c.method).toList(),
          ['vibrate', 'clearAlarms', 'startMicService', 'stopMicService'],
          reason: '删闹钟与守卫 FGS 都是"必须能调到"的入口；'
              '宿主/桌面没有原生实现时只能静默降级，不能抛');
    });

    test('vibrateCommand(envelope) → vibrateEnvelope，控制点逐点展开 + 带 alarm 用法', () async {
      installNative((_) => true);
      const cmd = VibrateCommand(
        mode: VibrateMode.envelope,
        chunkMs: 4000,
        useAlarmUsage: true,
        points: [
          EnvelopePoint(intensity: 0.2, sharpness: 0, durationMs: 500),
          EnvelopePoint(intensity: 0.9, sharpness: 0.5, durationMs: 1500),
          EnvelopePoint(intensity: 0, sharpness: 0, durationMs: 0),
        ],
      );
      expect(await NativeBridge.vibrateCommand(cmd), isTrue);
      expect(log.single.method, 'vibrateEnvelope');
      final args = log.single.arguments! as Map;
      expect(args['useAlarmUsage'], isTrue,
          reason: 'USAGE_ALARM 是"穿透勿扰"的语义开关，丢了就等于夜间振不醒');
      expect(args['points'], [
        {'intensity': 0.2, 'sharpness': 0, 'durationMs': 500},
        {'intensity': 0.9, 'sharpness': 0.5, 'durationMs': 1500},
        {'intensity': 0, 'sharpness': 0, 'durationMs': 0},
      ]);
      expect(args.containsKey('timings'), isFalse,
          reason: 'envelope 分支不得夹带 waveform 的键，否则两份载荷会漂移');
    });

    test('vibrateCommand(waveformAmplitude) → vibrateWaveform，timings 与 amplitudes 一起下发', () async {
      installNative((_) => true);
      const cmd = VibrateCommand(
        mode: VibrateMode.waveformAmplitude,
        chunkMs: 1000,
        timings: [0, 200, 100],
        amplitudes: [0, 255, 0],
      );
      expect(await NativeBridge.vibrateCommand(cmd), isTrue);
      expect(log.single.method, 'vibrateWaveform');
      expect(log.single.arguments, {
        'timings': [0, 200, 100],
        'amplitudes': [0, 255, 0],
        'repeat': -1,
        'useAlarmUsage': false,
      });
    });

    test('vibrateCommand(waveformOnOff / legacy) 共用同一入口；amplitudes=null 时不得下发该键',
        () async {
      installNative((_) => true);
      for (final mode in [VibrateMode.waveformOnOff, VibrateMode.legacy]) {
        log.clear();
        final cmd =
            VibrateCommand(mode: mode, chunkMs: 500, timings: const [0, 80, 80]);
        expect(await NativeBridge.vibrateCommand(cmd), isTrue);
        expect(log.single.method, 'vibrateWaveform',
            reason: 'legacy(API<26) 由 Kotlin 按 SDK 分支，Dart 侧不该开第二条通道');
        final args = log.single.arguments! as Map;
        expect(args['timings'], [0, 80, 80]);
        expect(args.containsKey('amplitudes'), isFalse,
            reason: 'on/off 模式没有振幅数组；下发 null 会被原生当成空振幅 ⇒ 静默不振动');
        expect(args['repeat'], -1);
      }
    });

    test('桥不可用时 vibrateCommand → false（调用方必须留痕，不得报成功）', () async {
      installNotImplemented();
      const cmd = VibrateCommand(
          mode: VibrateMode.waveformOnOff, chunkMs: 500);
      expect(await NativeBridge.vibrateCommand(cmd), isFalse,
          reason: '契约：返回 false = 平台拒绝或桥不可用，调用方必须写审计');
      expect(log.single.method, 'vibrateWaveform');
    });
  });
}
