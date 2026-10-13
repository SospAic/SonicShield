/// 远程桌面级控制（docs/61 §5 P3）**观看/控制页**（`ScreenViewerScreen`）宿主测试
/// —— 第八十四轮续二。
///
/// ## 为什么此前 90/90 行（0%）未覆盖
///
/// 该页是 P3 新增文件，只挂在 `remote_console_tab` 的「请求远程控制」按钮后，
/// 全项目此前**无任何测试引用它**（`grep -rln "ScreenViewerScreen" test/` 零命中）。
///
/// ## 为什么宿主机**可以**驱动它（不是"设备层豁免"）
///
/// 它确实是 WebRTC 页，但被驱动的是**真实的 `screen_viewer.dart` 代码**：
/// - `RTCVideoRenderer.initialize()` 走 `flutter_webrtc` 的**平台通道**
///   （`FlutterWebRTC.Method` 的 `createVideoRenderer`）—— 宿主可用通道桩复刻
///   插件返回形状（`{'textureId': 1}`），与 `multi_video_screen_test.dart` 同法；
/// - 手势 → **归一化坐标** → `RcCmd.input.tap` / `input.swipe` 是**纯 Dart 逻辑**，
///   必须宿主测（严格遵循 `tool/coverage_report.dart` 的豁免收录标准：
///   纯逻辑一律不收，必须写宿主测试）。
///
/// ## 边界（明确不测什么）
/// - **不测**真实画面渲染：`RTCVideoView` 要纹理，宿主机没有 ⇒ 只走到
///   "`_ready` 为真但 `remoteStream` 仍为 null"的占位分支
///   （`CallService._remoteStream` 无测试缝，`remoteStreamChanges` 也推不进去）。
/// - **不桩任何声盾生产逻辑**：只桩**插件通道**。
///
/// ## 遵守的宿主约束
/// 1. 不用 `pumpAndSettle`（页面挂常驻 `Stream` 订阅）⇒ 有界 `waitFor`；
/// 2. 每个 `testWidgets` 显式 `timeout`；
/// 3. 断言落在**真实副作用**上：出站命令的 type/payload（经 `debugSendTo` 捕获）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/features/remote/screen_viewer.dart';
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
  final svc = RcEndpointService.instance;

  late List<RcMessage> sent;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sent = <RcMessage>[];
    messenger.setMockMethodCallHandler(nativeChannel, (call) async => null);
    messenger.setMockMethodCallHandler(webrtcChannel, (call) async {
      if (call.method == 'createVideoRenderer') {
        return <String, dynamic>{'textureId': 1};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(textureChannel, (call) async => null);
    messenger.setMockMethodCallHandler(eventChannel, (call) async => null);
    svc.debugSendTo = (endpoint, msg, store, enqueueOnFail) async {
      sent.add(msg);
      return true;
    };
  });

  tearDown(() {
    svc.debugSendTo = null;
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(webrtcChannel, null);
    messenger.setMockMethodCallHandler(textureChannel, null);
    messenger.setMockMethodCallHandler(eventChannel, null);
  });

  final peer = PairedEndpoint(
    deviceId: 'CTRL0001abcdef',
    name: '客厅平板',
    secret: 'CODE0001',
    pairedAt: DateTime(2024, 1, 1),
  );

  Future<void> pumpViewer(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: ScreenViewerScreen(endpoint: peer, castId: 'cast-42'),
      ),
    ));
    // `_boot()` 的 `_remote.initialize()` 是异步的 ⇒ 有界等它落地（不 pumpAndSettle）。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('SVW-01 红线文案 + 标题 + 停止按钮渲染（可见性告知不可省）',
      (tester) async {
    await pumpViewer(tester);

    expect(find.text('对方设备可见本次操作指示，且可随时停止'), findsOneWidget,
        reason: 'docs/61 §1 红线：控制端必须知道这是**对方可见**的实时屏幕');
    expect(find.text('远程控制 · 客厅平板'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    // `_ready` 为真但无远端流 ⇒ 占位分支（不是空白屏）：占位中心 + 左下角状态条
    // 各一处，故恰好 2 个。
    expect(find.text('等待画面…'), findsNWidgets(2));
  }, timeout: perTest);

  testWidgets('SVW-02 点按 → 下发归一化坐标的 input.tap（0..1，非像素）',
      (tester) async {
    await pumpViewer(tester);

    final box = tester.getRect(find.byType(GestureDetector).first);
    // 点在 GestureDetector 的 3/4 宽、1/2 高处。
    await tester.tapAt(Offset(box.left + box.width * 0.75,
        box.top + box.height * 0.5));
    await tester.pump();

    final taps = sent.where((m) => m.type == RcCmd.inputTap).toList();
    expect(taps, hasLength(1), reason: '一次点按只发一条 input.tap');
    final p = taps.single.payload;
    expect(p['castId'], 'cast-42');
    final x = (p['x'] as num).toDouble();
    final y = (p['y'] as num).toDouble();
    expect(x, inInclusiveRange(0.0, 1.0));
    expect(y, inInclusiveRange(0.0, 1.0));
    expect(x, closeTo(0.75, 0.02), reason: '归一化坐标必须反映点击位置');
    expect(find.textContaining('tap '), findsWidgets,
        reason: '本页必须把刚下发的坐标如实回显给用户');
  }, timeout: perTest);

  testWidgets('SVW-03 拖拽 → 只在 panEnd 下发一条 input.swipe（四坐标归一化）',
      (tester) async {
    await pumpViewer(tester);

    final box = tester.getRect(find.byType(GestureDetector).first);
    final from = Offset(box.left + box.width * 0.2, box.top + box.height * 0.2);
    final to = Offset(box.left + box.width * 0.8, box.top + box.height * 0.8);
    await tester.dragFrom(from, to - from);
    await tester.pump();

    final swipes = sent.where((m) => m.type == RcCmd.inputSwipe).toList();
    expect(swipes, hasLength(1),
        reason: '避免每帧发命令：起点/终点各记一次，只在 panEnd 下发一条');
    final p = swipes.single.payload;
    expect(p['castId'], 'cast-42');
    for (final k in ['x1', 'y1', 'x2', 'y2']) {
      expect((p[k] as num).toDouble(), inInclusiveRange(0.0, 1.0),
          reason: '$k 必须是归一化坐标');
    }
    expect((p['x2'] as num).toDouble(),
        greaterThan((p['x1'] as num).toDouble()));
    expect(p['durationMs'], 220);
    expect(find.textContaining('swipe'), findsWidgets);
  }, timeout: perTest);

  testWidgets('SVW-04 停止按钮 → 下发 screen.cast.stop 并退出本页', (tester) async {
    await pumpViewer(tester);

    await tester.tap(find.text('停止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final stops = sent.where((m) => m.type == RcCmd.screenCastStop).toList();
    expect(stops, hasLength(1));
    expect(stops.single.payload['castId'], 'cast-42',
        reason: '停止必须点名 castId —— 端点据此失效会话锁');
  }, timeout: perTest);
}
