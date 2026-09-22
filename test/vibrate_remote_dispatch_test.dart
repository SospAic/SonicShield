import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

/// `BackgroundServiceManager` 的振动转发（v1.9，docs/20 §10.2 / §10.1）。
///
/// 锁两件事：
/// 1. `stopVibrate` **两条腿都要走**：转交引擎（清活跃表 → 停掉分片续发）
///    + 直调原生 cancel（引擎没跑时的兜底）。
///    只做前者：引擎未运行时"停止"没有任何效果（发向不存在的服务）。
///    只做后者：引擎会在下一片到期时**自己震起来**。
/// 2. `runVibrateStep` 在引擎未运行时**如实返回失败**，
///    不在主 isolate 私自下发（那样会绕过分片续发、`vibrate.stop`
///    与低电量降级 —— 见 `background_engine` 的 `vibrateStep` 监听处注记）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeCh = MethodChannel('sonic_shield/native');
  late List<MethodCall> nativeCalls;

  setUp(() {
    nativeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeCh, (call) async {
      nativeCalls.add(call);
      return null;
    });
    BackgroundServiceManager.invokeHook = null;
  });

  tearDown(() {
    BackgroundServiceManager.invokeHook = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeCh, null);
  });

  test('BD-V01 stopVibrate：引擎转交 + 原生 cancel，两条腿都走', () async {
    final invoked = <String>[];
    BackgroundServiceManager.invokeHook = (method, args) async {
      invoked.add(method);
    };

    await BackgroundServiceManager.instance.stopVibrate(reason: '远程停止');

    expect(invoked, contains('vibrateStop'),
        reason: '不转交引擎 → 活跃表没清 → 分片续发会在下一片到期时自己震起来');
    expect(nativeCalls.map((c) => c.method), contains('vibrateStop'),
        reason: '引擎没跑时"转交"发向不存在的服务没有效果，必须直调原生 cancel 兜底');
  });

  test('BD-V02 stopVibrate 把 reason 一起转交（审计要能对上"谁停的"）', () async {
    Map<String, Object?>? seen;
    BackgroundServiceManager.invokeHook = (method, args) async {
      if (method == 'vibrateStop') seen = args;
    };

    await BackgroundServiceManager.instance
        .stopVibrate(reason: '远程停止：客厅音箱');

    expect(seen, isNotNull);
    expect(seen!['reason'], '远程停止：客厅音箱');
  });

  test('BD-V03 runVibrateStep：引擎未运行 → 如实失败，不私自下发', () async {
    BackgroundServiceManager.invokeHook = (method, args) async {};

    final r = await BackgroundServiceManager.instance.runVibrateStep(
      action: const ContinuousVibrateAction(),
      occurrenceId: 'o1',
    );

    expect(r.ok, isFalse);
    expect(r.message, contains('调度引擎未运行'));
    expect(nativeCalls, isEmpty,
        reason: '不在主 isolate 私自下发 —— 那样会绕过分片续发与 vibrate.stop');
  });

  test('BD-V04 runNow 同样在引擎未运行时如实失败（回归：重构后行为不变）',
      () async {
    BackgroundServiceManager.invokeHook = (method, args) async {};

    final r = await BackgroundServiceManager.instance.runNow('t1');

    expect(r.ok, isFalse);
    expect(r.message, contains('调度引擎未运行'));
  });
}
