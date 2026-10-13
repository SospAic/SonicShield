/// 系统 TTS（离线）装配的宿主测试 —— 第八十四轮续二。
///
/// ## 覆盖的未覆盖块
/// `lib/core/providers.dart` 的 `_speakSystemTts`（约 22 行，0% 覆盖）：
/// `ttsServiceProvider` 的 `speakSystem` 闭包此前从未被调用过 —— 只测了
/// `speakOnline`（`providers_v2_test.dart`）。这条路径正是 R82「离线播报没声音」
/// 的根因修复处（`awaitSpeakCompletion(true)` 必须在 `speak` 之前），
/// 必须有行为用例守住，而不是只靠源码锁。
///
/// ## 驱动方式
/// 打桩 `flutter_tts` 的方法通道（通道名/方法名照插件 4.2.5 真实现），
/// 记录**收到的调用**；再经 `ttsServiceProvider` 取出真实 `TtsService`，
/// 调它的 `speakSystem` —— 跑的是**生产代码本身**，不是复制品。
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/core/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// `flutter_tts` 的方法通道（见插件 `flutter_tts.dart:330`）。
  const ttsChannel = MethodChannel('flutter_tts');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ttsChannel, (call) async {
      calls.add(call);
      if (call.method == 'getVoices') {
        // 形状照 Android 侧 `TextToSpeech.getVoices()` 的 map 列表。
        return <Map<String, String>>[
          {'name': 'Chinese Female', 'locale': 'zh-CN'},
          {'name': 'Chinese Male', 'locale': 'zh-CN'},
        ];
      }
      return 1;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(ttsChannel, null);
  });

  bool called(String m) => calls.any((c) => c.method == m);
  MethodCall? firstOf(String m) =>
      calls.where((c) => c.method == m).cast<MethodCall?>().firstWhere(
            (c) => c!.method == m,
            orElse: () => null,
          );

  test('PST-01 speakSystem（无音色匹配）→ 走完 setVolume/setLanguage/'
      'awaitSpeakCompletion/speak/stop，且顺序正确', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final svc = await c.read(ttsServiceProvider.future);

    await svc.speakSystem('你好世界', 0.7, const <String>[]);

    expect(firstOf('setVolume')!.arguments, 0.7);
    expect(firstOf('setLanguage')!.arguments, 'zh-CN');
    // ★ R82 根因修复：必须先开「等朗读完成」，否则随后的 stop() 会把刚排队的
    //   朗读当场取消（表现为"离线播报没声音"）。
    expect(firstOf('awaitSpeakCompletion')!.arguments, true);
    expect(firstOf('speak')!.arguments.toString(), contains('你好世界'));
    expect(called('stop'), isTrue, reason: '收尾必须清理，避免残留朗读');
    expect(called('getVoices'), isFalse,
        reason: '没有音色匹配需求时不该去查系统音色列表（多余往返）');

    final order = calls.map((e) => e.method).toList();
    expect(order.indexOf('awaitSpeakCompletion'), lessThan(order.indexOf('speak')),
        reason: 'awaitSpeakCompletion 必须**先于** speak —— 顺序反了就是没声音');
  });

  test('PST-02 speakSystem（带音色匹配）→ 查系统音色并 setVoice 选中命中项', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final svc = await c.read(ttsServiceProvider.future);

    await svc.speakSystem('播报', 0.5, const <String>['female']);

    expect(called('getVoices'), isTrue);
    expect(called('setVoice'), isTrue, reason: '命中系统音色后必须真的切过去');
    final v = firstOf('setVoice')!.arguments as Map;
    expect(v['name'], 'Chinese Female');
    expect(v['locale'], 'zh-CN');
    expect(called('speak'), isTrue);
  });

  test('PST-03 音色匹配失败（列表里没有命中项）→ 不 setVoice，但朗读照常进行',
      () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final svc = await c.read(ttsServiceProvider.future);

    await svc.speakSystem('播报', 0.5, const <String>['不存在的音色zzz']);

    expect(called('getVoices'), isTrue);
    expect(called('setVoice'), isFalse,
        reason: '音色匹配是增强，没命中就交给系统默认，不是错误');
    expect(called('speak'), isTrue, reason: '匹配失败不得让整条朗读失败');
  });
}
