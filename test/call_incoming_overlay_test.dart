/// 通话 UI 宿主（`CallOverlayHost`，`lib/features/remote/call_incoming_overlay.dart`）
/// 宿主机测试 —— 第五轮补测。
///
/// ## 为什么这个文件之前是 0 覆盖（93 行里只有 2 行被执行）
///
/// 宿主挂在 `MaterialApp.builder` 上、按 `CallService.phase` 弹出覆盖层。
/// 三个渲染分支各自绑死一种**真实相位**：
/// - `ringing` 需要真的收到 invite 并进入振铃；
/// - `connecting` / `connected` 需要 `getUserMedia`（相机/麦克风）+
///   `RTCPeerConnection` 真的连上。
///
/// 宿主机两样都没有 ⇒ 整块覆盖层（含被叫**唯一**的接听入口，BUG-056）
/// 长期无人执行。本文件用服务层新增的 `@visibleForTesting` 相位缝
/// `CallService.setPhaseForTest`（与 `BackgroundServiceManager.stateForTest`
/// 同形）把相位推到位，再断言**界面真的按相位渲染**。
///
/// ## 边界（明确不测什么）
///
/// - **不测** `_CallView` 的媒体渲染：真实画面由 `flutter_webrtc` 的
///   `RTCVideoView` 承担，宿主机没有纹理。本文件只走到
///   "`_renderersReady` 为真、但没有任何流"这一边界（即占位分支），
///   远端画面/本地画中画（`srcObject != null`）属真实硬件。
/// - **不测** `_endCall` → `declinePending` 那条（振铃中点「拒接」）：
///   它要求 `_peer != null`，即必须真的走一遍 `onIncomingCall` 信令，
///   会牵出 MQTT 连接 —— 属设备/集成层。
/// - **不桩任何声盾生产逻辑**：只桩**插件通道**（`_CallView` 里
///   `RTCVideoRenderer.initialize()` 会调 `createVideoRenderer` 并取
///   `response['textureId']`，桩只是复刻真实插件返回的形状）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/core/app_keys.dart';
import 'package:sonic_shield/features/remote/call_incoming_overlay.dart';
import 'package:sonic_shield/remote/call_lifecycle.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 原生桥通道：不打桩时 `invokeMethod` 的 future 可能永不 resolve。
const MethodChannel _nativeChannel = MethodChannel('sonic_shield/native');

/// flutter_webrtc 的方法通道（纹理创建/销毁）。
const MethodChannel _webrtcChannel = MethodChannel('FlutterWebRTC.Method');

/// `RTCVideoRenderer.initialize()` 会给每个纹理开一条 EventChannel
/// （名字就是 `FlutterWebRTC/Texture$textureId`）。桩上它，`listen`/`cancel`
/// 才能确定性地被应答，不必依赖 flutter_tester 对**未知通道**的兜底行为。
const MethodChannel _textureChannel = MethodChannel('FlutterWebRTC/Texture1');

/// flutter_webrtc 的全局事件通道（`FlutterWebRTCEventChannel` 单例在
/// `WebRTC.invokeMethod` 首次调用时懒建）。⚠️ 必须桩：未打桩时
/// `EventChannel.onListen` 的 `invokeMethod('listen')` 会抛
/// `MissingPluginException`，而它被 `FlutterError.reportError` 捕获上报 ——
/// 那会直接判本用例失败（`flutter_test` 的 `FlutterError.onError` 会记 pending 异常）。
const MethodChannel _eventChannel = MethodChannel('FlutterWebRTC.Event');

/// 宿主 `child` 的锚点：idle 时它必须原样可见（覆盖层不得挡住它）。
const Key _childKey = Key('overlay-child');

/// 连推若干帧。
///
/// `_CallView.initState` 的 `_initRenderers()`、以及 `_endCall` 里的
/// `SharedPreferences → hangUp → _teardown` 都是多段 await，
/// 单帧推不完；每次 `pump` 会冲掉一批 microtask。
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
}

/// 把相位推到 [phase]，再按 `app.dart` 的真实装法挂起宿主。
///
/// 视口放大是必须的（默认 800×600 会让底部按钮落在折叠区）；
/// `platform: linux` 让任何平台探测同步落到 generic，避免异步竞态。
Future<void> _pumpHost(WidgetTester tester, CallPhase phase) async {
  CallService.instance.setPhaseForTest(phase);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        scaffoldMessengerKey: scaffoldMessengerKey,
        theme: ThemeData(platform: TargetPlatform.linux),
        builder: (context, child) => CallOverlayHost(child: child),
        home: const Scaffold(
          body: Center(child: Text('宿主内容', key: _childKey)),
        ),
      ),
    ),
  );
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await _flush(tester);
}

/// 卸载整棵树，强制走 `CallOverlayHost` / `_CallView` 的 `dispose`。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _flush(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    _messenger.setMockMethodCallHandler(_nativeChannel, (call) async => null);
    _messenger.setMockMethodCallHandler(_webrtcChannel, (call) async {
      if (call.method == 'createVideoRenderer') {
        // 复刻真实插件的响应形状（一个纹理 id）；不桩的话宿主机拿到 null，
        // `response['textureId']` 会抛 NoSuchMethodError（异步未捕获错误）。
        return <String, dynamic>{'textureId': 1};
      }
      return null;
    });
    _messenger.setMockMethodCallHandler(_textureChannel, (call) async => null);
    _messenger.setMockMethodCallHandler(_eventChannel, (call) async => null);
    // `CallService` 是单例：每个用例都从 idle 起步。
    CallService.instance.setPhaseForTest(CallPhase.idle);
  });

  tearDown(() {
    _messenger.setMockMethodCallHandler(_nativeChannel, null);
    _messenger.setMockMethodCallHandler(_webrtcChannel, null);
    _messenger.setMockMethodCallHandler(_textureChannel, null);
    _messenger.setMockMethodCallHandler(_eventChannel, null);
    CallService.instance.setPhaseForTest(CallPhase.idle);
  });

  // =====================================================================
  // 1 · idle：没有通话 ⇒ 不渲染任何覆盖层
  // =====================================================================

  testWidgets('CIO-01 idle 时不渲染覆盖层，宿主 child 原样可见', (tester) async {
    await _pumpHost(tester, CallPhase.idle);
    // 判据：接听/挂断入口只可能来自 `_CallView`；idle 时一个都不该有。
    expect(find.byKey(_childKey), findsOneWidget,
        reason: '覆盖层不该把宿主 child 换掉（它是 Stack 的第一层）');
    expect(find.byIcon(Icons.call_end), findsNothing,
        reason: '没有通话却出现挂断按钮 = 覆盖层在 idle 就弹了');
    expect(find.byIcon(Icons.call), findsNothing,
        reason: '没有来电却出现接听按钮 = 覆盖层在 idle 就弹了');
    expect(find.text('来电…'), findsNothing);
    expect(find.byIcon(Icons.videocam), findsNothing);
    await _unmount(tester);
  });

  // =====================================================================
  // 2 · ringing（被叫振铃）：接听/拒接入口必须出现
  // =====================================================================

  testWidgets('CIO-02 ringing 时出现「接听 + 拒接」两个入口（BUG-056 的界面半边）',
      (tester) async {
    await _pumpHost(tester, CallPhase.ringing);
    // 判据：这三个元素都只由 `_CallView` 的振铃分支产出。
    expect(find.text('来电…'), findsOneWidget,
        reason: 'ringing 必须显示"来电…"，否则被叫不知道有人在呼入');
    expect(find.byIcon(Icons.videocam), findsOneWidget,
        reason: '振铃占位头像（非 connected 分支）');
    expect(find.byIcon(Icons.call), findsOneWidget,
        reason: 'ringing 且非主叫时必须有「接听」入口 —— 没有它，'
            '关掉自动接通后来电全部变成"无人接听"（BUG-056）');
    expect(find.byIcon(Icons.call_end), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNWidgets(2),
        reason: '接听 + 拒接 = 两个 FAB；少一个就是入口不完整');
    await _unmount(tester);
  });

  testWidgets('CIO-03 connecting（协商中）不出现「接听」，但保留挂断入口',
      (tester) async {
    await _pumpHost(tester, CallPhase.connecting);
    // 判据：`connectingText(unknown)` 的确定文案 + 接听按钮的缺席。
    expect(find.text('连接中…'), findsOneWidget,
        reason: '协商中必须显示"连接中…"（点完接听后界面不能消失）');
    expect(find.byIcon(Icons.call), findsNothing,
        reason: '「接听」只在真振铃时可用；协商中还能点 = 重复接通');
    expect(find.byIcon(Icons.call_end), findsOneWidget,
        reason: '协商中必须能取消，否则用户在这段时间里没有出口');
    await _unmount(tester);
  });

  // =====================================================================
  // 3 · connected：远端画面占位（无流时的边界）
  // =====================================================================

  testWidgets('CIO-04 connected 且无媒体流时渲染"已接通"占位', (tester) async {
    await _pumpHost(tester, CallPhase.connected);
    // 判据：占位文案/图标只在 `phase == connected && hasMedia == false` 下产出。
    expect(find.byIcon(Icons.connected_tv), findsOneWidget,
        reason: '接通后没有画面（宿主机无纹理）必须给占位说明，不能黑屏');
    expect(find.text('通话已接通（媒体经 DTLS-SRTP 加密）'), findsOneWidget);
    expect(find.text('来电…'), findsNothing,
        reason: '已接通不该还显示来电文案');
    expect(find.byType(FloatingActionButton), findsOneWidget,
        reason: '接通后只保留「挂断」');
    await _unmount(tester);
  });

  // =====================================================================
  // 4 · 结束提示（BUG-050）：该说的说、不该说的不说
  // =====================================================================

  testWidgets('CIO-05 对端占线结束 → 宿主弹出「对方正在通话中」（常驻所以任何页面都收得到）',
      (tester) async {
    await _pumpHost(tester, CallPhase.connecting);
    // 真实生产路径：`rc.call` 的结束信令由 endpoint_service 分派到这里。
    await CallService.instance.onRemoteEnd(<String, dynamic>{'reason': 'busy'});
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 600)); // SnackBar 入场
    // 判据：文案取自 `callEndText(busy)`，只有宿主真的订阅了 `callEnded`
    // 才会出现 —— 未接/占线"无声无息退回上一页"正是 BUG-050 的症状。
    expect(find.text('对方正在通话中'), findsOneWidget,
        reason: '对端占线必须弹提示，且文案来自纯逻辑 callEndText');
    expect(find.byIcon(Icons.call_end), findsNothing,
        reason: '结束后覆盖层必须收起');
    // 走完 4s 展示期并退场：否则残留的 SnackBar 定时器会让用例结束时报
    // "A Timer is still pending"。
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('对方正在通话中'), findsNothing,
        reason: 'SnackBar 是 transient 提示，展示期结束后必须自行消失');
    await _unmount(tester);
  });

  testWidgets('CIO-06 本端挂断结束 → 事件照广播，但**不**弹提示（避免噪音）',
      (tester) async {
    await _pumpHost(tester, CallPhase.connecting);
    final reasons = <CallEndReason>[];
    final sub = CallService.instance.callEnded.listen(reasons.add);
    addTearDown(sub.cancel);
    final prefs = await SharedPreferences.getInstance();
    // 本机主动挂断（未接通）→ `CallEndReason.hangup`。
    await CallService.instance.hangUp(RemoteStore(prefs));
    await _flush(tester);
    // 判据是**一对**：事件确实广播了（证明 showEndNotice 真的被调用过），
    // 但界面没有提示 —— 只有两者同时成立，"本端挂断不弹"这条过滤才是真的。
    expect(reasons, contains(CallEndReason.hangup),
        reason: '本端挂断也必须广播结束原因（否则无法区分"没广播"与"被过滤"）');
    expect(find.byType(SnackBar), findsNothing,
        reason: '用户刚自己点的挂断，再弹一次就是噪音');
    await _unmount(tester);
  });

  // =====================================================================
  // 5 · 覆盖层上的「挂断」按钮真的能收场
  // =====================================================================

  testWidgets('CIO-07 点覆盖层上的「挂断」→ 通话收场、覆盖层收起', (tester) async {
    await _pumpHost(tester, CallPhase.connecting);
    expect(find.byType(FloatingActionButton), findsOneWidget,
        reason: '前置条件：协商中只有一个「挂断」FAB');
    await tester.tap(find.byType(FloatingActionButton));
    await _flush(tester);
    // 判据：`inCall` 从真实的 `CallService` 读出来，且覆盖层真的从树上消失。
    expect(CallService.instance.inCall, isFalse,
        reason: '点了挂断却没结束会话 = 按钮是死的');
    expect(find.byIcon(Icons.call_end), findsNothing,
        reason: '会话已结束，覆盖层必须收起（否则用户被黑屏挡住）');
    await _unmount(tester);
  });

  // =====================================================================
  // 5.5 · 对端 `rc.call` 状态推送 → 覆盖层文案即时刷新（第六十六轮）
  //       `_CallView._remoteStateSub` 此前从未被驱动过：状态镜像变了却
  //       不重建 ⇒ "对方振铃中…" 永远不出现，主叫分不清"对方在响"与
  //       "信令没送到"（这正是 BUG-050 的另一半）。
  // =====================================================================

  testWidgets('CIO-10 对端振铃状态推送 → 文案从"连接中…"变成"对方振铃中…"',
      (tester) async {
    final bus = StreamController<Map<String, dynamic>>.broadcast();
    CallService.instance.attach(bus.stream);
    addTearDown(() async {
      await bus.close();
      // 还原：本文件其它用例不依赖任何注入流。
      CallService.instance.attach(const Stream.empty());
    });

    await _pumpHost(tester, CallPhase.connecting);
    expect(find.text('连接中…'), findsOneWidget, reason: '前置：未收到对端状态时是通用文案');

    // 真实生产入口：`rc.call` 的 state 由 endpoint_service 分派进 CallService。
    bus.add(<String, dynamic>{
      'type': RcEvt.callState,
      'payload': <String, dynamic>{'state': 'ringing'},
    });
    await _flush(tester);

    expect(find.text('对方振铃中…'), findsOneWidget,
        reason: '对端已振铃必须与"信令根本没送到"区分开 —— '
            '订阅了却不重建，界面就永远停在"连接中…"（BUG-050 的症状）');
    expect(find.text('连接中…'), findsNothing);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  // =====================================================================
  // 6 · 振铃时点「接听 / 拒接」：无待接 invite 时必须是**安全 no-op**
  //     （`acceptPending` / `declinePending` 的契约：按钮可能被连点，
  //     也可能在超时收尾之后才被点到 ⇒ 返回 false / 静默收场，绝不误接通/崩）
  // =====================================================================

  testWidgets('CIO-08 ringing 点「接听」但已无待接 invite → 不得误接通、界面不崩',
      (tester) async {
    await _pumpHost(tester, CallPhase.ringing);
    // 前置：振铃时「接听」入口在（CIO-02 已证）。
    expect(find.byIcon(Icons.call), findsOneWidget);
    await tester.tap(find.byIcon(Icons.call));
    await _flush(tester);
    // 判据：没有待接 invite ⇒ 不得把相位错误推进「协商中」，也不得抛异常。
    expect(CallService.instance.currentPhase, CallPhase.ringing,
        reason: '无 invite 却切成协商中 = 按钮制造了一通根本不会建立的通话');
    expect(find.text('来电…'), findsOneWidget,
        reason: '接听失败后界面必须仍停在振铃态，用户还能再点一次');
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('CIO-09 ringing 点「拒接」→ 走 declinePending，无 invite 时安全收场不崩',
      (tester) async {
    await _pumpHost(tester, CallPhase.ringing);
    await tester.tap(find.byIcon(Icons.call_end));
    await _flush(tester);
    // 判据：`_endCall` 在振铃态必须走 `declinePending`（而非 hangUp 死路），
    // 且没有待接 invite 时安静收场 —— 不抛异常、界面不残留半死状态。
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.call_end), findsOneWidget,
        reason: '收场由服务层相位驱动；此处仅证「点了不崩」（真实拒接信令属设备层）');
    await _unmount(tester);
  });
}
