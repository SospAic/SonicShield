import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/services/native_bridge.dart';

/// v1.7 条件层「**设备端验证**」（docs/17 §15.5 第 4 项）。
///
/// ## 为什么要单独做这件事
///
/// 第八轮新增了两个原生桥接方法（Kotlin `callState` / `networkType`），
/// 它们支撑两条新的执行条件（`skipInCall` / `requireWifi`）。
/// 那一轮**只验证到编译通过**（`NativeBridgePlugin.class` 是新鲜产物），
/// 但方法名是否对得上、返回值是否落在文档枚举内、在真实 Android 运行时
/// 是否真的"零权限可判定"——**全都没有执行过**。
///
/// 这类"每一端自己都对、链路却是断的"缺陷（方法名拼写、返回类型、
/// 枚举漏项）单测与 mock 都发现不了，必须真的把 Kotlin 跑起来。
///
/// 运行：
/// ```
/// flutter test integration_test/native_bridge_test.dart -d emulator-5554
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// `networkType` 的**文档枚举**。
  ///
  /// 注意：Dart 侧文档注释只列了 wifi/cellular/ethernet/none/other/unknown，
  /// 而 Kotlin 实现还会返回 `vpn` —— 这个不一致本身就是本测试要盯住的点。
  const allowedTypes = <String>{
    'wifi',
    'cellular',
    'ethernet',
    'vpn',
    'none',
    'other',
    'unknown',
  };

  testWidgets('NB-01 callState：Android 上必须可判定（返回非 null）', (_) async {
    final inCall = await NativeBridge.isInCall();
    debugPrint('[NB-01] isInCall=$inCall');
    expect(
      inCall,
      isNotNull,
      reason: 'Android 侧必须始终可判定。返回 null 说明桥接未注册、'
          '方法名不匹配（Kotlin 侧 case 与 Dart 侧 method 字符串不一致），'
          '或被 _invoke 的 PlatformException 分支静默吞掉 —— '
          '任何一种都会让"通话中不执行"这条安全护栏**静默失效**。',
    );
  });

  testWidgets('NB-02 networkType：返回值必须落在文档枚举内', (_) async {
    final type = await NativeBridge.networkType();
    debugPrint('[NB-02] networkType=$type');
    expect(
      allowedTypes.contains(type),
      isTrue,
      reason: '未登记的网络类型 "$type" —— Dart 侧文档只列了 6 种，'
          'Kotlin 实现会返回 vpn；若出现枚举外取值，requireWifi 的判定会漂移。',
    );
    expect(
      type,
      isNot('unknown'),
      reason: 'Android 上 ConnectivityManager 必然可用，落到 unknown 说明'
          '系统服务获取失败（Kotlin 的 as? 静默转换失败也会走到这里）。',
    );
  });

  testWidgets('NB-03 isOnWifi 与 networkType 必须同源一致', (_) async {
    final type = await NativeBridge.networkType();
    final wifi = await NativeBridge.isOnWifi();
    debugPrint('[NB-03] networkType=$type isOnWifi=$wifi');
    expect(wifi, isNotNull, reason: 'Android 上 isOnWifi 不应退化为 null');
    expect(
      wifi,
      equals(type == 'wifi'),
      reason: 'isOnWifi 由 networkType 派生，两者必须自洽',
    );
  });

  testWidgets('NB-04 条件层 × 真实设备读数：决策必须与读数自洽', (_) async {
    final inCall = await NativeBridge.isInCall();
    final onWifi = await NativeBridge.isOnWifi();
    debugPrint('[NB-04] inCall=$inCall onWifi=$onWifi');

    const c = TaskCondition(skipInCall: true, requireWifi: true);
    final reason = c.firstUnmet(
      charging: true,
      batteryLevel: 100,
      now: DateTime.now(),
      inCall: inCall,
      onWifi: onWifi,
    );
    debugPrint('[NB-04] firstUnmet=$reason');

    // 用真实读数驱动纯逻辑，断言"决策 = 读数"这一不变式。
    // 注意判据顺序与 firstUnmet 的实现一致：通话优先于 Wi-Fi。
    if (inCall == true) {
      expect(reason, '通话中（不打扰通话）');
    } else if (onWifi == false) {
      expect(reason, '不在 Wi-Fi 下');
    } else {
      expect(reason, isNull);
    }
  });

  testWidgets('NB-05 零权限证据：不持有电话权限也能读到通话状态', (_) async {
    final phoneStatus = await Permission.phone.status;
    final inCall = await NativeBridge.isInCall();
    debugPrint('[NB-05] Permission.phone=$phoneStatus isInCall=$inCall');

    // 本应用在 Manifest 中**没有声明** READ_PHONE_STATE（docs/08 最小权限）。
    expect(
      phoneStatus,
      isNot(PermissionStatus.granted),
      reason: '若这里变成 granted，说明有人给应用加上了电话权限 —— '
          '与"零权限判定通话"的设计前提冲突，必须回头审 Manifest。',
    );
    expect(
      inCall,
      isNotNull,
      reason: '不持有电话权限时仍必须能判定通话状态，这正是选 '
          'AudioManager.getMode() 而非 TelephonyManager 的理由。',
    );
  });

  testWidgets('NB-06 平台通道稳定性：连续 300 轮（600 次调用）无异常', (_) async {
    final sw = Stopwatch()..start();
    for (var i = 0; i < 300; i++) {
      final a = await NativeBridge.isInCall();
      final b = await NativeBridge.networkType();
      expect(a, isNotNull);
      expect(allowedTypes.contains(b), isTrue);
    }
    sw.stop();
    final perCall = sw.elapsedMicroseconds / 600.0;
    debugPrint(
      '[NB-06] 600 次桥接调用 ${sw.elapsedMilliseconds}ms'
      '（${perCall.toStringAsFixed(0)}µs/次）',
    );
    expect(
      sw.elapsedMilliseconds,
      lessThan(60000),
      reason: '单次调用应远低于 100ms；异常膨胀说明通道排队/泄漏',
    );
  });
}
