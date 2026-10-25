/// R97 · 覆盖率长尾补测（第 2 组：3 个界面 / 19 行）。
///
/// ## 本组只有 5 行是**可达**的
///
/// 逐行读源码 + 反查调用点后，19 行里 **14 行是结构性死代码**（穷尽性兜底臂 /
/// 恒假守卫），只有 `call_incoming_overlay.dart` 的 5 行能被真实驱动。
/// 每条死行的证据都写在下面 —— 不是"懒得测"，是**上游提前 return / 无 UI 入口**。
///
/// ### `script_builder_screen.dart`（9 行全不可达）
///
/// | 行 | 内容 | 不可达证据 |
/// |---|---|---|
/// | 110 | `_initialEditText` 的 `vibrate` 臂 | 唯一调用点 `166`，而 `_editStep` 在 `128-135` 对 vibrate **无条件 return**；该方法是库私有 `static`，测试无法直呼 |
/// | 120 | `_editLabelOf` 的 `vibrate` 臂 | 唯一调用点 `165`，同上 |
/// | 173 | `_editStep` 里 `case tts: s.params['text'] = text` | `139-159` 对 tts **无条件 return**（走专用音色对话框），到不了 `171` 的 switch |
/// | 183 | 同一 switch 的 `case vibrate: break` | 同上（`128-135` 已 return），留着只为让 switch 穷尽 |
/// | 210-214 | `_send` 的 `if (saveFirst) { await store.saveScript(...) }` | 全仓 `saveFirst` 只出现在本页；唯一入口是 `240` 的 `onPressed: _send`（**无参**）⇒ 恒为默认 `false`。第六十八轮起已登记（`docs/12 §102.5`、`test/script_builder_screen_test.dart` 文件头第 3 条） |
///
/// ### `task_editor_screen.dart`（5 行全不可达）
///
/// | 行 | 内容 | 不可达证据 |
/// |---|---|---|
/// | 1546 | `_setIcon` 的 `delay` 臂 | `_setItems` 只有两个写入点：`1522`（chips 来自 `1443-1449` 的 `kinds`，**没有 delay**）与 `433`（`_kindOfCandidate` → `stepKindOfAction`，`31-49` 对任何动作都**不返回** delay）⇒ 该臂恒不可选中 |
/// | 1555 | `_setLabel` 的 `delay` 臂 | 同上 |
/// | 1778 | `_buildTask` 里候选动作 switch 的 `delay` 臂 | 同上（`_setItems` 不含 delay） |
/// | 1798 | 随机振动「区间起点 > 终点」的 toast | 六个区间全部由 `_RangeSliderTile`（`2018-2056`，`RangeSlider` 的 `values` 保证 `start <= end`）写入，`_applyTask` 又只从模型回填；而 `RandomVibrateAction` 的 `assert`（`action.dart:379-390`）在 debug 下已保证有序 ⇒ 测试运行时该条件恒假（release 才是它的保护对象） |
/// | 1816 | 持续振动同款 toast | 同上（`action.dart:507-517`） |
///
/// 这两族与 `test/task_editor_vibrate_test.dart` 文件头"⚠️ 本文件没有覆盖的 5 行"
/// 完全对应（那轮的行号是 1275/1284/1412/1431-1432/1449-1450，本轮只是整体下移）。
///
/// ## 本文件唯一能消掉的 5 行
///
/// `call_incoming_overlay.dart` 的 `195` / `202` / `207-209`：
/// 都是 `phase == connected && hasMedia` / `_renderersReady && localStream != null`
/// 的内层节点。既有 `call_incoming_overlay_test.dart` 明确声明"不测媒体渲染
/// （宿主机没有纹理、没有流）"，所以这 5 行长期是 0。
///
/// 本文件用第 45 轮的 `test/support/webrtc_stub.dart` 把"手机那边"换成可编程替身，
/// 让**真实的** `CallService.startCall` 取到本地流、`onTrack` 收到远端流，再用
/// 既有 overlay 用例的渲染器桩把 `_CallView` 建起来 ⇒ 两条分支都真的执行。
///
/// ## 宿主硬约束（照抄既有装配，不另发明）
///
/// * 服务层是**真实异步**（`call_service_webrtc_test.dart` 头注：不用 fake-async）
///   ⇒ 取流/建 PC 包在 `tester.runAsync`，避免 FakeAsync 里 await 真实异步挂死；
/// * **不用 `pumpAndSettle` 等数据**：`_CallView` 的渲染器初始化是多段 await，
///   用有界轮询（`_waitFor`，超时显式 `fail`）；
/// * 平台通道替身全部在 `tearDown` 还原（`_unstubAll` + `rtc.uninstall`）。
@Timeout(Duration(seconds: 120))
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/core/app_keys.dart';
import 'package:sonic_shield/features/remote/call_incoming_overlay.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/webrtc_stub.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 原生桥通道：不打桩时 `invokeMethod` 的 future 可能永不 resolve。
const MethodChannel _nativeChannel = MethodChannel('sonic_shield/native');

/// flutter_webrtc 的方法通道（纹理创建/销毁）。
const MethodChannel _webrtcChannel = MethodChannel('FlutterWebRTC.Method');

/// `RTCVideoRenderer.initialize()` 会给每个纹理开一条 EventChannel
/// （名字就是 `FlutterWebRTC/Texture$textureId`）。
const MethodChannel _textureChannel = MethodChannel('FlutterWebRTC/Texture1');

/// 插件懒建的全局事件通道（不桩会被 `FlutterError.reportError` 上报 ⇒ 判失败）。
const MethodChannel _eventChannel = MethodChannel('FlutterWebRTC.Event');

/// 宿主 `child` 的锚点。
const Key _childKey = Key('overlay-child');

PairedEndpoint _peer() => PairedEndpoint(
      deviceId: 'EP9701',
      name: '客厅手机',
      secret: 'SECRET97',
      pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

/// 连推若干帧（`_initRenderers` 是多段 await，单帧推不完）。
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
}

/// 有界轮询。⚠️ 超时必须 `fail` —— 静默放行会让断言变成"永远看不到"的假绿。
Future<void> _waitFor(
  WidgetTester tester,
  bool Function() cond, {
  required String reason,
  int rounds = 120,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (cond()) return;
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('有界等待超时（$rounds 轮）：$reason');
}

/// 渲染器桩 —— 与 `call_incoming_overlay_test.dart` 的 CIO-04 装配逐字一致。
void _stubRendererChannels() {
  _messenger.setMockMethodCallHandler(_nativeChannel, (call) async => null);
  _messenger.setMockMethodCallHandler(_webrtcChannel, (call) async {
    if (call.method == 'createVideoRenderer') {
      // 复刻真实插件的响应形状；回 null 会让 `response['textureId']` 抛
      // NoSuchMethodError（异步未捕获错误）。
      return <String, dynamic>{'textureId': 1};
    }
    return null;
  });
  _messenger.setMockMethodCallHandler(_textureChannel, (call) async => null);
  _messenger.setMockMethodCallHandler(_eventChannel, (call) async => null);
}

void _unstubAll() {
  for (final channel in <MethodChannel>[
    _nativeChannel,
    _webrtcChannel,
    _textureChannel,
    _eventChannel,
  ]) {
    _messenger.setMockMethodCallHandler(channel, null);
  }
}

/// 按 `app.dart` 的真实装法挂起宿主。
///
/// 视口放大是必须的（默认 800×600 会让底部按钮落在折叠区）；
/// `platform: linux` 让任何平台探测同步落到 generic，避免异步竞态。
Future<void> _pumpHost(WidgetTester tester, CallPhase phase) async {
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    CallService.instance.setPhaseForTest(CallPhase.idle);
  });

  tearDown(() {
    RcEndpointService.instance.debugSendTo = null;
    _unstubAll();
    CallService.instance.setPhaseForTest(CallPhase.idle);
  });

  testWidgets(
      'R97-CIO-01 已接通且远端/本地流都就位 → 远端全屏(195) + 本地画中画(202/207-209)',
      (tester) async {
    // ── 1 · 用真实服务路径把两条流准备好（服务层是真实异步 ⇒ runAsync） ──
    final rtc = FakeWebrtc();
    // ⚠️ 不在用例中途 `uninstall`：`_pc` 的事件通道
    // （`FlutterWebRTC/peerConnectionEventpc-1`）必须一直有桩，否则
    // `_pc.dispose()` 里的 `EventChannel.cancel` 会走 MissingPluginException
    // 并被 `FlutterError.reportError` 上报 ⇒ 判用例失败。收尾统一在 tearDown。
    addTearDown(rtc.uninstall);
    final endpointSvc = RcEndpointService.instance;
    late RemoteStore store;

    await tester.runAsync(() async {
      rtc.install();
      // invite 的"已发出"必须为真，否则 `startCall` 会 `_teardown` 把流清空。
      endpointSvc.debugSendTo = (endpoint, msg, s, enqueueOnFail) async => true;
      store = RemoteStore(await SharedPreferences.getInstance());
      final callId =
          await CallService.instance.startCall(_peer(), store, video: true);
      expect(callId, isNotNull,
          reason: '前置：真实 startCall 必须走通（FakeWebrtc 只复刻插件返回形状）');
      // 远端流：`pc.onTrack` 是 `_remoteStream` 唯一的写入点。
      await rtc.pushTrack('remote-r97');
      await Future<void>.delayed(Duration.zero);
    });

    // 前置：两条流真的在单例上（195 依赖 remoteStream，202 依赖 localStream）。
    expect(CallService.instance.remoteStream, isNotNull,
        reason: '前置：远端流没贴上，195 的 hasMedia 恒假');
    expect(CallService.instance.localStream, isNotNull,
        reason: '前置：本地流没取到，202 的画中画分支恒假');

    // ── 2 · 覆盖 `FlutterWebRTC.Method`：`_CallView` 建渲染器时要
    //        `createVideoRenderer` 的**响应形状**，而 FakeWebrtc 对该方法恒回 null
    //        （`response['textureId']` 会抛 NoSuchMethodError）。其余方法回 null
    //        即可（关 PC / 销毁渲染器都只看"有没有报错"）。 ──
    _stubRendererChannels();

    await _pumpHost(tester, CallPhase.connected);
    await _waitFor(
      tester,
      () => find.byType(RTCVideoView).evaluate().length == 2,
      reason: '渲染器初始化完成后必须同时出现远端全屏与本地画中画两个 RTCVideoView',
    );

    // 195：`hasMedia` 为真 ⇒ 远端不再走 `_RemoteVideoPlaceholder`。
    // 202/207-209：`_renderersReady && localStream != null` ⇒ 画中画子树（含
    // `ClipRRect` 圆角与 `mirror: true` 的本地镜像）真的被构建。
    expect(find.byType(RTCVideoView), findsNWidgets(2),
        reason: '两个 RTCVideoView = 195（远端全屏）+ 209（本地画中画）');
    expect(find.text('通话已接通（媒体经 DTLS-SRTP 加密）'), findsNothing,
        reason: '有画面时不得再显示"无画面"占位 —— 那说明 hasMedia 判定错了');
    expect(find.byIcon(Icons.call_end), findsOneWidget,
        reason: '接通后仍须保留挂断入口（195 只换了画面，不该换掉控制条）');
    expect(tester.takeException(), isNull);

    // ── 3 · 收场：`hangUp` 会取消 `_startWaitTimer`（45s 真实计时器），
    //        否则它会跨用例残留 ──
    await tester.runAsync(() async {
      await CallService.instance.hangUp(store);
    });
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
  });
}
