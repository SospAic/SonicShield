import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/webrtc_stub.dart';

/// 第七十四轮：**替身边界登记锁**（防"静默换桩"与"漏真机冒烟"复发）。
///
/// ## 这份锁在防什么（直接回答第七十三轮的复盘）
///
/// 第七十三轮「发起通话即崩溃」（BUG-080）逃过了**多轮宿主测试全绿**，
/// 根因不是"测试跑得少"，而是**替身把真实契约吃掉了**：
/// `test/support/webrtc_stub.dart` 的 `addTrack` 完全不读 `streamIds`、
/// 恒回成功 —— 于是"漏传本地流"这条必然导致原生 NPE/SIGABRT 的路径，
/// 在宿主上**永远是绿的**。全绿只证明"实现符合我们自写的那部分模型"，
/// 不证明真实插件契约为真。
///
/// 这类事故的共同形状是：**新增/改动了一个替身，但没有人知道它遮蔽了
/// 生产代码的哪条边界、也没有人负责到真机上去验一遍**。
///
/// 因此本锁强制两条纪律：
///
/// 1. **登记制**：`test/support/*_stub.dart` 的集合必须与 `_registry`
///    完全相等。新增未登记的替身 ⇒ 判红（逼作者回答"它遮蔽什么边界、
///    谁去真机验"）。
/// 2. **可追溯**：每个替身都必须登记 ① 遮蔽的**生产文件**（必须存在）、
///    ② 驱动它的**真实链宿主测试**（必须真的 import 该替身）、
///    ③ 对应的**真机冒烟功能点**（非空）。生产文件改名/删除、替身闲置、
///    真机清单被清空 ⇒ 判红。
///
/// ## 为什么"登记"能防复发（而不是又一纸空文）
///
/// 宿主测试的**替身**是唯一的"真相接口"。只要替身集合被机器盯着，
/// 就不会再出现"某个边界悄悄被一个恒真的桩遮住，却没人负责真机验证"。
/// 再加 [BUG-080 复发锁] 把最致命的那条契约（addTrack 必须带流）
/// 固化成**行为断言**：谁敢把替身改回"恒回成功"，此锁立刻红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const supportDir = 'test/support';

  /// 实际存在的替身文件（只认 `*_stub.dart`；`feature_point_inventory.dart`
  /// / `source_text.dart` 是测试基础设施，不是平台替身，刻意不在其列）。
  List<String> actualStubs() {
    final dir = Directory(supportDir);
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('_stub.dart'))
        .toList()
      ..sort();
  }

  group('SBL · 替身边界登记锁', () {
    test('SBL-01 替身集合与登记表**完全相等**（新增未登记替身 ⇒ 红）', () {
      final actual = actualStubs().toSet();
      final registered = _registry.keys.toSet();

      final unregistered = actual.difference(registered);
      final missing = registered.difference(actual);

      expect(unregistered, isEmpty,
          reason: '发现未登记的替身：$unregistered\n'
              '宿主替身会遮蔽生产边界。请在 _registry 中登记：它遮蔽哪些生产'
              '文件、由哪些真实链测试驱动、需要哪条真机冒烟功能点 —— '
              '否则"漏传契约参数"这类缺陷会像 BUG-080 一样永远绿。');
      expect(missing, isEmpty,
          reason: '登记表里的替身已不存在：$missing\n'
              '删除替身时请同步删除登记，避免留下"假装还在跑"的覆盖记录。');
      expect(actual, hasLength(_registry.length));
    });

    for (final entry in _registry.entries) {
      final name = entry.key;
      final sub = entry.value;

      test('SBL · $name 遮蔽的生产边界都存在', () {
        expect(sub.boundary, isNotEmpty,
            reason: '$name 必须登记它遮蔽的生产文件（否则无从追溯）');
        for (final p in sub.boundary) {
          expect(File(p).existsSync(), isTrue,
              reason: '$name 登记的生产边界 $p 不存在 —— '
                  '生产文件已改名/移动？请同步更新登记表。');
        }
      });

      test('SBL · $name 有真实链宿主测试驱动（且真的 import 了它）', () {
        expect(sub.realChainTests, isNotEmpty,
            reason: '$name 必须登记驱动它的真实链测试；'
                '没有真实链的替身 = 遮蔽了边界却无人验证');
        for (final t in sub.realChainTests) {
          final path = 'test/$t';
          final file = File(path);
          expect(file.existsSync(), isTrue, reason: '$name 登记的真实链测试 $path 不存在');
          expect(file.readAsStringSync().contains('support/$name'), isTrue,
              reason: '$path 并未 import $name —— '
                  '登记表声称它驱动该替身，实际没有。请修正登记或补测试。');
        }
      });

      test('SBL · $name 登记了真机冒烟功能点', () {
        expect(sub.deviceSmoke.trim(), isNotEmpty,
            reason: '$name 必须登记对应的**真机冒烟**功能点：'
                '宿主替身再全绿，也不能替代真机验证真实插件契约'
                '（BUG-080 的教训）。');
      });
    }
  });

  group('SBL · BUG-080 复发锁（替身必须复刻真实契约，不得恒回成功）', () {
    // ⚠️ 直接用**生产代码同款**的调用方式打 MethodChannel：真实插件
    // `RTCPeerConnectionNative.addTrack` 会发出 `'streamIds': [stream?.id]`；
    // 漏传 stream 时即 `[null]`，原生侧取 null ⇒ NPE ⇒ SIGABRT。
    // 替身**必须**同样拒绝 —— 否则宿主永远绿、真机必崩。
    late FakeWebrtc rtc;
    setUp(() => rtc = FakeWebrtc()..install());
    tearDown(() => rtc.uninstall());

    const channel = MethodChannel('FlutterWebRTC.Method');

    test('SBL-02 漏传本地流（streamIds 含 null/空）→ 必须拒绝，绝不假成功', () async {
      // stream == null 的真实形态：`[null]`。
      await expectLater(
        channel.invokeMethod('addTrack', <String, dynamic>{
          'peerConnectionId': 'pc-1',
          'trackId': 't1',
          'streamIds': <dynamic>[null],
        }),
        throwsA(isA<PlatformException>()),
        reason: '替身对"漏传 stream"的 addTrack 若放行，'
            'BUG-080 会再次逃过所有宿主测试。',
      );
      // streamIds 缺失 / 空列表同样必须拒绝。
      await expectLater(
        channel.invokeMethod('addTrack', <String, dynamic>{
          'peerConnectionId': 'pc-1',
          'trackId': 't1',
        }),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        channel.invokeMethod('addTrack', <String, dynamic>{
          'peerConnectionId': 'pc-1',
          'trackId': 't1',
          'streamIds': <dynamic>[],
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(rtc.called('addTrack'), isTrue, reason: '确实调到了插件的 addTrack');
    });

    test('SBL-03 带本地流（生产同款）→ 放行并回 sender', () async {
      final sender = await channel.invokeMethod('addTrack', <String, dynamic>{
        'peerConnectionId': 'pc-1',
        'trackId': 't1',
        'streamIds': <dynamic>['stream-1'],
      });
      expect(sender, isA<Map<dynamic, dynamic>>(),
          reason: '合法调用必须正常返回，否则真机路径会被替身误伤');
    });
  });
}

/// 一个替身的登记项：遮蔽什么、谁驱动、真机验什么。
class _Sub {
  const _Sub({
    required this.boundary,
    required this.realChainTests,
    required this.deviceSmoke,
  });

  /// 被该替身遮蔽的生产文件（必须真实存在）。
  final List<String> boundary;

  /// 驱动真实链的宿主测试文件名（`test/` 下；必须 import 该替身）。
  final List<String> realChainTests;

  /// 该边界对应的**真机冒烟**功能点（宿主替身无法替代）。
  final String deviceSmoke;
}

/// ⚠️ 新增任何 `test/support/*_stub.dart` 都必须在此登记，否则 SBL-01 判红。
const Map<String, _Sub> _registry = <String, _Sub>{
  'just_audio_stub.dart': _Sub(
    boundary: <String>['lib/services/playback_service.dart'],
    realChainTests: <String>[
      'playback_service_justaudio_test.dart',
      'ptt_stream_test.dart',
    ],
    deviceSmoke: '端点真机出声：音景播放、远程音频播放、对讲流式"边收边放"',
  ),
  'mqtt_client_stub.dart': _Sub(
    boundary: <String>[
      'lib/remote/endpoint_service.dart',
      'lib/remote/controller_service.dart',
    ],
    realChainTests: <String>[
      'endpoint_mqtt_link_test.dart',
      'endpoint_ptt_evidence_test.dart',
      'ptt_stream_test.dart',
    ],
    deviceSmoke: '两台真机扫码配对后，远程控制指令真可达（第七十三轮故障点）',
  ),
  'permission_stub.dart': _Sub(
    boundary: <String>[
      'lib/services/permission_flow.dart',
      'lib/features/guard/guard_screen.dart',
    ],
    realChainTests: <String>[
      'permission_flow_test.dart',
      'ptt_tab_test.dart',
    ],
    deviceSmoke: '真机权限弹窗：麦克风/相机/定位的授权与拒绝两条路径',
  ),
  'record_stub.dart': _Sub(
    boundary: <String>[
      'lib/remote/controller_service.dart',
      'lib/remote/endpoint_service.dart',
    ],
    realChainTests: <String>[
      'ptt_tab_test.dart',
      'endpoint_ptt_evidence_test.dart',
      'ptt_stream_test.dart',
    ],
    deviceSmoke: '对讲真机收发：按住说话 → 端点出声（含 v2 流式分片）',
  ),
  'webrtc_stub.dart': _Sub(
    boundary: <String>[
      'lib/remote/call_service.dart',
      'lib/remote/multi_call_service.dart',
    ],
    realChainTests: <String>[
      'call_service_webrtc_test.dart',
      'multi_call_service_connect_test.dart',
      'substitute_boundary_lock_test.dart',
    ],
    deviceSmoke: '两台真机：语音/视频通话、多路通话"发起即通"（BUG-080 故障点）',
  ),
};