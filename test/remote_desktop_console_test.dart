/// 远程桌面级控制（docs/61）**控制台消费端**宿主测试 —— 第八十四轮续二。
///
/// ## 覆盖的未覆盖块（来自第八十四轮续 lcov 实测归因，非推断）
///
/// `remote_console_tab.dart` 有 19 行缺口，集中在 docs/61 新增的两处：
/// - **回执消费**（`RcEvt.screen` / `RcEvt.inputAck` → 回执行）——
///   端点授权/拒绝/开流/停止、每条输入注入的成功/失败原因，此前无任何用例回灌过；
/// - **「请求远程控制」/「停止远程控制」按钮**（含 push 观看页）。
///
/// ## 驱动方式
///
/// 复用既有可测性缝 `RcCommandChannel`（注入假通道 ⇒ 捕获"发了什么命令" +
/// 回灌"收到什么事件"，无需真机与 broker），与 `remote_console_tab_test.dart` 同源。
/// `ScreenViewerScreen` 被 push 时构造 `RTCVideoRenderer` ⇒ 按
/// `multi_video_screen_test.dart` 的手法桩 `flutter_webrtc` 通道。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/features/remote/remote_console_tab.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const perTest = Timeout(Duration(seconds: 90));

  const nativeChannel = MethodChannel('sonic_shield/native');
  const webrtcChannel = MethodChannel('FlutterWebRTC.Method');
  const textureChannel = MethodChannel('FlutterWebRTC/Texture1');
  const eventChannel = MethodChannel('FlutterWebRTC.Event');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(nativeChannel, (call) async => null);
    messenger.setMockMethodCallHandler(webrtcChannel, (call) async {
      if (call.method == 'createVideoRenderer') {
        return <String, dynamic>{'textureId': 1};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(textureChannel, (call) async => null);
    messenger.setMockMethodCallHandler(eventChannel, (call) async => null);
    // 观看页 push 后 `sendTo` 会走端点服务的出站；宿主无 broker ⇒ 直接短路，
    // 不让 outbox 落盘干扰。
    RcEndpointService.instance.debugSendTo =
        (endpoint, msg, store, enqueueOnFail) async => true;
  });

  tearDown(() {
    RcEndpointService.instance.debugSendTo = null;
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(webrtcChannel, null);
    messenger.setMockMethodCallHandler(textureChannel, null);
    messenger.setMockMethodCallHandler(eventChannel, null);
  });

  Future<_FakeChannel> pumpWithPaired(
      WidgetTester tester, String id, String name) async {
    SharedPreferences.setMockInitialValues({});
    final store = RemoteStore(await SharedPreferences.getInstance());
    await store.addPaired(PairedEndpoint(
        deviceId: id, name: name, secret: 's', pairedAt: DateTime.now()));
    final ch = _FakeChannel();
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: Scaffold(body: RemoteConsoleTab(channel: ch))),
    ));
    await tester.pumpAndSettle();
    return ch;
  }

  Future<void> tapButton(WidgetTester tester, String label) async {
    final f = find.widgetWithText(FilledButton, label);
    expect(f, findsOneWidget, reason: '控制台应存在「$label」按钮');
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets('RDC-01 「请求远程控制」→ 发 screen.cast.request(kind:control) 并进入观看页',
      (tester) async {
    final ch = await pumpWithPaired(tester, 'CTRL0001abcdef', '客厅平板');

    await tapButton(tester, '请求远程控制');

    final req = ch.lastOfType(RcCmd.screenCastRequest);
    expect(req.payload['kind'], 'control');
    expect((req.payload['castId'] as String), startsWith('cast_'),
        reason: 'castId 由控制端生成，端点据此把输入落回本会话');
    // 授权是异步的（端点弹系统窗）⇒ 必须先进观看页等画面，而不是停在控制台。
    expect(find.text('远程控制 · 客厅平板'), findsOneWidget,
        reason: '必须 push 观看页（否则用户看不到"等待画面/被拒"的如实反馈）');
    expect(find.text('对方设备可见本次操作指示，且可随时停止'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('RDC-02 「停止远程控制」→ 发 screen.cast.stop', (tester) async {
    final ch = await pumpWithPaired(tester, 'CTRL0001abcdef', '客厅平板');

    await tapButton(tester, '停止远程控制');

    expect(ch.lastOfType(RcCmd.screenCastStop).type, RcCmd.screenCastStop);
    expect(find.textContaining('已发出'), findsWidgets,
        reason: '每个动作都要在回执行留下痕迹');
  }, timeout: perTest);

  testWidgets('RDC-03 rc.screen 事件 → 回执行出现「屏幕会话：<state>」', (tester) async {
    final ch = await pumpWithPaired(tester, 'CTRL0001abcdef', '客厅平板');

    ch.emit(RcEvt.screen, {'state': 'denied', 'castId': 'cast_1'});
    await tester.pumpAndSettle();

    expect(find.textContaining('屏幕会话：denied'), findsOneWidget,
        reason: '端点拒绝必须让控制端看得见 —— 而不是静默停在"等待画面"');
  }, timeout: perTest);

  testWidgets('RDC-04 rc.inputAck ok=true → 回执行出现「✓ 输入注入」', (tester) async {
    final ch = await pumpWithPaired(tester, 'CTRL0001abcdef', '客厅平板');

    ch.emit(RcEvt.inputAck, {'ok': true, 'castId': 'cast_1'});
    await tester.pumpAndSettle();

    expect(find.textContaining('✓ 输入注入'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('RDC-05 rc.inputAck ok=false → 回执行带出端点拒绝原因', (tester) async {
    final ch = await pumpWithPaired(tester, 'CTRL0001abcdef', '客厅平板');

    ch.emit(RcEvt.inputAck,
        {'ok': false, 'castId': 'cast_1', 'message': '端点未开启无障碍'});
    await tester.pumpAndSettle();

    expect(find.textContaining('✗ 输入注入（端点未开启无障碍）'), findsOneWidget,
        reason: '只说"✗"等于让用户自己猜端点为何拒 —— 原因必须一并显示');
  }, timeout: perTest);

  testWidgets('RDC-06 回执行上限 200：溢出后裁剪最早的（防无界增长）', (tester) async {
    final ch = await pumpWithPaired(tester, 'CTRL0001abcdef', '客厅平板');

    // 灌 205 条，跨过 `_kReceiptMax = 200` 的裁剪分支。
    for (var i = 0; i < 205; i++) {
      ch.emit(RcEvt.screen, {'state': 's$i'});
    }
    await tester.pumpAndSettle();

    // 最早的几条已被裁掉，最新的仍在。
    expect(find.textContaining('屏幕会话：s204'), findsOneWidget);
    expect(find.textContaining('屏幕会话：s0'), findsNothing,
        reason: '超出上限后必须裁剪最早的，否则内存无界增长');
  }, timeout: perTest);
}

/// 假命令通道：捕获"发了什么命令" + 回灌"收到什么事件"（与既有控制台测试同源）。
class _FakeChannel implements RcCommandChannel {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _updates = StreamController<void>.broadcast();
  final sent = <RcMessage>[];

  @override
  String get label => '假端点';

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Stream<void> get updates => _updates.stream;

  @override
  bool get canSend => true;

  @override
  Future<bool> send(RcMessage msg) async {
    sent.add(msg);
    return true;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await _updates.close();
  }

  void emit(String type, Map<String, dynamic> payload,
          {String peerId = '', String peerName = ''}) =>
      _events.add({
        'type': type,
        'payload': payload,
        if (peerId.isNotEmpty) 'peerId': peerId,
        if (peerName.isNotEmpty) 'peerName': peerName,
      });

  RcMessage lastOfType(String type) => sent.lastWhere((m) => m.type == type,
      orElse: () => throw StateError('未发送 $type'));
}
