/// 第八十八轮 · 覆盖率长尾补齐：远程 UI 两个文件（共 22 行未覆盖）。
///
/// ## 覆盖清单（行号按 R87 基线 `_pt/lcov_r87.info` 复核）
///
/// `lib/features/remote/remote_screen.dart`
/// - **100-102**：已开启状态下切换 MQTT 预设节点 → `stop → 取库 → start`
///   重启端点服务（不是只改界面）。
/// - **116-118**：已开启状态下切换传输方案（TLS → WSS）→ 同一条重启链路。
/// - **125**：选中 QUIC（当前客户端库不支持）→ 明示「暂不支持、已回落 TLS」。
/// - **386-388**：开启远程模块失败（数据库取不到）→ 可见错误提示，且
///   `enabled` **不落盘**、`_connecting` 必须复位。
/// - **151-152**：`_speedTest` 的 `on Object` 兜底 —— **结构性不可达**，如实登记：
///   `NodeSpeedTest.connectLatency` / `stunLatency` 内部就是 `catch (Object)`
///   后返回 `null`（`node_catalog.dart:128-130 / 177-179`），
///   `probeMqtt` / `probeStun` 的 `Future.wait` 因此**永不抛**；
///   宿主与真机都不存在能让这两个 await 抛出的输入。硬凑只能改生产代码，
///   故本文件不写该分支的假用例。
///
/// `lib/features/remote/screen_viewer.dart`
/// - **74-77**：进页面时 `CallService.remoteStream` 已就绪 → 直接接管画面。
/// - **81-85**：`remoteStreamChanges` 的「有流 / 断流」两个分支。
/// - **185-186**：`_ready && _hasMedia` 时构建 `RTCVideoView`。
///
/// ## 手法（不伪造生产逻辑）
/// - 平台边界只用替身：`FakeWebrtc`（flutter_webrtc 通道）、内存 sqflite、
///   `RcEndpointService.debugClientFactory` / `debugSendTo`；被驱动的仍是生产代码。
/// - **不用 `pumpAndSettle` 等数据**：页面挂着常驻订阅、服务有 60s 心跳，
///   一律有界 `pump` 轮询（见 [_waitFor]）。
/// - 平台单例替身全部在 `tearDown` 还原（`debugClientFactory` / `debugSendTo` /
///   `FakeWebrtc.uninstall`），服务必须停掉，否则下一例会早退或留 pending Timer。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/features/remote/remote_screen.dart';
import 'package:sonic_shield/features/remote/screen_viewer.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/node_catalog.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/mqtt_client_stub.dart';
import 'support/webrtc_stub.dart';

/// 有界等待：只在「数据/异步状态」上用，最多 [rounds]×20ms。
///
/// 不用 `pumpAndSettle` —— 远程页有常驻订阅、端点服务有 60s 心跳，
/// settle 会一直等不到「没有待处理帧」的瞬间（或者把 SnackBar 的 4s
/// 自动消失计时器一起推完，断言就找不到提示了）。
Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  int rounds = 60,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const perTest = Timeout(Duration(seconds: 90));
  const ownId = 'EPR8800000000abc';

  // ══════════════════════════════════════════════════════════════════
  // A · remote_screen.dart：节点/传输切换与失败提示
  // ══════════════════════════════════════════════════════════════════

  group('R88R 远程设置页长尾', () {
    final svc = RcEndpointService.instance;

    late AppDatabase db;
    late FakeMqttServerClient fake;
    late RemoteStore store;

    /// 工厂被真正调用时收到的 broker（`null` = 压根没启动服务）。
    String? seenBroker;

    setUp(() async {
      seenBroker = null;
      SharedPreferences.setMockInitialValues({});
      db = await AppDatabase.open(inMemoryDatabasePath);
      store = RemoteStore(await SharedPreferences.getInstance());
      fake = FakeMqttServerClient('broker.ignored.invalid', ownId);
      svc.debugClientFactory = (broker, clientId, port) {
        seenBroker = broker;
        return fake;
      };
      // 通话/端点共用的出站缝：本组不需要真发，但保持干净（防止上一文件残留）。
      svc.debugSendTo = (endpoint, msg, s, enqueueOnFail) async => true;
    });

    tearDown(() async {
      // 必须先停服务：`start()` 里的 60s 心跳是 pending Timer，
      // 只放 tearDown 会被 `_verifyInvariants` 判红；也会让下一例 start 早退。
      await svc.stop();
      svc.debugClientFactory = null;
      svc.debugSendTo = null;
      // `start()` 会把审计/命令回调绑到本用例的 db 上；不摘会在库关闭后被别的
      // 路径调到（写进已关闭的库 ⇒ 跨用例污染）。
      RcAssistHost.instance.audit = null;
      RcAssistHost.instance.onCommand = null;
      await fake.dispose();
      await db.close();
    });

    Future<void> pumpRemote(
      WidgetTester tester, {
      bool enabled = false,
      bool failDb = false,
    }) async {
      if (enabled) await store.setEnabled(true);
      if (enabled) await store.setIdentity(ownId, '声盾-${ownId.substring(0, 4)}');

      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async {
            if (failDb) throw StateError('R88R：数据库不可用');
            return db;
          }),
        ],
        child: const MaterialApp(home: RemoteScreen()),
      ));
      await _waitFor(
          tester, find.text(enabled ? '端点在线' : '端点已关闭'));
      await tester.pumpAndSettle();
    }

    testWidgets('R88R-01 已开启切 MQTT 预设节点 → stop+start 真重启并连新节点（100-102）',
        (tester) async {
      await pumpRemote(tester, enabled: true);
      expect(svc.isRunning, isFalse,
          reason: '前提：本页只展示状态，切换动作才真正启动服务');

      await tester.tap(find.textContaining('EMQX 全球').first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('EMQX 国内节点').last);
      await _waitFor(tester, find.textContaining('已切换到 EMQX 国内节点'));
      await tester.pumpAndSettle();

      expect(store.mqttNodeHost, 'broker-cn.emqx.io',
          reason: '预设节点必须落库（否则重启后回到旧节点）');
      expect(svc.isRunning, isTrue,
          reason: '已开启时切节点必须重启端点服务，否则新节点要等下次启动才生效');
      expect(seenBroker, 'broker-cn.emqx.io',
          reason: '重启后的连接必须用**新**节点 —— 用旧节点等于没重启');
      expect(fake.connectCalls, 1, reason: 'stop→start 应恰好重连一次');
      expect(find.textContaining('已切换到 EMQX 国内节点'), findsOneWidget,
          reason: '切换结果必须如实回显（含 host:port）');

      await svc.stop(); // 在用例体内取消 60s 心跳
    }, timeout: perTest);

    testWidgets('R88R-02 已开启切传输方案 TLS→WSS → stop+start 真重启（116-118）',
        (tester) async {
      await pumpRemote(tester, enabled: true);
      expect(store.transport, RcTransport.tls, reason: '前提：出厂 TLS');
      expect(svc.isRunning, isFalse);

      await tester.tap(find.text('TLS 8883'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('WSS 8084').last);
      await _waitFor(tester, find.textContaining('连接方案：WSS 8084'));
      await tester.pumpAndSettle();

      expect(store.transport, RcTransport.wss,
          reason: '传输方案必须落库（否则只是下拉框变了）');
      expect(svc.isRunning, isTrue,
          reason: '已开启时切传输必须重启端点服务，否则新方案下次启动才生效');
      expect(seenBroker, RemoteStore.defaultBroker,
          reason: '传输切换不应顺带改 broker');
      expect(fake.connectCalls, 1, reason: 'stop→start 应恰好重连一次');
      expect(find.textContaining('连接方案：WSS 8084'), findsOneWidget,
          reason: '必须告诉用户当前生效的连接方案');

      await svc.stop();
    }, timeout: perTest);

    testWidgets('R88R-03 选 QUIC（库不支持）→ 明示暂不支持并回落 TLS（125）',
        (tester) async {
      await pumpRemote(tester);

      await tester.tap(find.text('TLS 8883'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('QUIC 14567（暂不支持）').last);
      await _waitFor(
          tester, find.textContaining('暂不支持（当前客户端库无 QUIC），已回落 TLS'));
      await tester.pumpAndSettle();

      expect(store.transport, RcTransport.quic,
          reason: '选择要如实落库（连接时由端点服务回落 TLS）');
      expect(svc.isRunning, isFalse, reason: '未开启时不得偷偷起服务');
      expect(
          find.text('QUIC 14567 暂不支持（当前客户端库无 QUIC），已回落 TLS'),
          findsOneWidget,
          reason: '不能静默回落 —— 用户必须知道当前客户端库不支持 QUIC');
    }, timeout: perTest);

    testWidgets('R88R-04 开启失败（DB 不可用）→ 可见报错 + 不落 enabled + 复位连接中（386-388）',
        (tester) async {
      await pumpRemote(tester, failDb: true);
      expect(find.text('端点已关闭'), findsOneWidget);

      await tester.tap(find.byType(SwitchListTile));
      await _waitFor(tester, find.textContaining('远程模块启动失败'));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('远程模块启动失败'), findsOneWidget,
          reason: '异常必须可见 —— 否则用户只看到开关弹回去，不知道为什么');
      expect(find.textContaining('R88R：数据库不可用'), findsOneWidget,
          reason: '错误提示要带上真实原因，不能只说"失败了"');
      expect(store.enabled, isFalse,
          reason: '失败不得落盘 enabled，否则下次启动会"自己开着"（P1-10）');
      expect(find.byType(LinearProgressIndicator), findsNothing,
          reason: 'finally 必须复位 _connecting，否则界面永久"连接中"');
      expect(find.text('端点已关闭'), findsOneWidget);
      expect(svc.isRunning, isFalse, reason: '启动失败不得留下半启动的服务');
    }, timeout: perTest);
  });

  // ══════════════════════════════════════════════════════════════════
  // B · screen_viewer.dart：已有远端流 / 流变化 / RTCVideoView
  // ══════════════════════════════════════════════════════════════════

  group('R88R 投屏观看页长尾', () {
    const webrtcChannel = MethodChannel('FlutterWebRTC.Method');
    const textureChannel = MethodChannel('FlutterWebRTC/Texture1');

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final svc = RcEndpointService.instance;
    final call = CallService.instance;
    final rtc = FakeWebrtc();

    late RemoteStore store;
    late List<RcMessage> sent;

    final peer = PairedEndpoint(
      deviceId: 'CTRLR88000000001',
      name: '客厅平板',
      secret: 'CODE0001',
      pairedAt: DateTime(2024, 1, 1),
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = RemoteStore(await SharedPreferences.getInstance());
      sent = <RcMessage>[];
      rtc
        ..failUserMedia = false
        ..failCreateOffer = false
        ..withAudioTrack = true
        ..withVideoTrack = true
        ..resetObservations()
        ..install();
      messenger.setMockMethodCallHandler(textureChannel, (call) async => null);
      svc.debugSendTo = (endpoint, msg, s, enqueueOnFail) async {
        sent.add(msg);
        return true;
      };
    });

    tearDown(() async {
      if (call.inCall) await call.hangUp(store);
      svc.debugSendTo = null;
      rtc.uninstall();
      messenger.setMockMethodCallHandler(textureChannel, null);
    });

    /// `FakeWebrtc` 对 `createVideoRenderer` 回 null，而真实 renderer 会
    /// `response['textureId']`（null 上取下标直接抛）。这里只补这一条
    /// 插件返回形状；其余方法仍按「成功、无返回体」处理（close/dispose 等）。
    void stubTextureRenderer() {
      messenger.setMockMethodCallHandler(webrtcChannel, (c) async {
        if (c.method == 'createVideoRenderer') {
          return <String, dynamic>{'textureId': 1};
        }
        return null;
      });
    }

    Future<void> pumpViewer(WidgetTester tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: ScreenViewerScreen(endpoint: peer, castId: 'cast-r88'),
        ),
      ));
      // `_boot()` 的 `initialize()` 是异步的 ⇒ 有界推帧等它落地（不 settle）。
      // ⚠️ 不能只等 `等待画面…`：那正是初始 `_last`，首帧就有 —— 会误判
      // "_boot 已完成"（此时订阅还没装上）。
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('R88R-05 进页面时已有远端流 → 直接接管画面并构建 RTCVideoView（74-77, 185-186）',
        (tester) async {
      // 先用真实 CallService + 插件替身把「远端流已到达」造出来。
      await tester.runAsync(() async {
        final id = await call.startCall(peer, store);
        expect(id, isNotNull, reason: '前提：真实 CallService 建连成功');
        await rtc.pushTrack('remote-stream-r88a');
        await Future<void>.delayed(Duration.zero);
      });
      expect(call.remoteStream?.id, 'remote-stream-r88a',
          reason: '前提：远端流已在 CallService 上就位');
      expect(sent.map((m) => m.type), contains(RcCmd.callInvite),
          reason: '前提：真实 startCall 已把 invite 交给出站通道');

      stubTextureRenderer();
      await pumpViewer(tester);
      await _waitFor(tester, find.byType(RTCVideoView));
      await tester.pump();

      expect(find.byType(RTCVideoView), findsOneWidget,
          reason: '_ready && _hasMedia 时必须渲染画面，而不是停在占位文案');
      expect(find.text('已收到画面'), findsOneWidget,
          reason: '进页面即接管已有流时，状态条必须如实显示"已收到画面"');
      expect(tester.takeException(), isNull);

      await tester.runAsync(() => call.hangUp(store));
      await tester.pump();
    }, timeout: perTest);

    testWidgets('R88R-06 remoteStreamChanges：有流→渲染；断流→提示"画面已中断"（81-85）',
        (tester) async {
      // 进页面时没有流 ⇒ 先停在占位分支。
      // 页面初始化需要 `createVideoRenderer` 的 textureId，所以先装纹理桩；
      // boot 完成后再把方法通道还给 FakeWebrtc —— 后面的 startCall / hangUp
      // 要真实的 getUserMedia / createOffer / close 返回形状。
      stubTextureRenderer();
      await pumpViewer(tester);
      await _waitFor(tester, find.text('等待画面…'));
      expect(find.byType(RTCVideoView), findsNothing);
      rtc.uninstall();
      rtc.install();

      await tester.runAsync(() async {
        await call.startCall(peer, store);
        await rtc.pushTrack('remote-stream-r88b');
        await Future<void>.delayed(Duration.zero);
      });
      await _waitFor(tester, find.byType(RTCVideoView));
      await tester.pump();

      expect(find.byType(RTCVideoView), findsOneWidget,
          reason: '订阅收到非空流后必须切到画面（81-84 的非空分支）');
      expect(find.text('已收到画面'), findsOneWidget);

      // 断流：`hangUp` → `_teardown` → `remoteStreamChanges.add(null)`。
      await tester.runAsync(() => call.hangUp(store));
      await _waitFor(tester, find.text('画面已中断'));
      await tester.pump();

      expect(find.text('画面已中断'), findsNWidgets(2),
          reason: '断流必须让用户看见（中心占位 + 左下状态条），不能继续假装在投屏');
      expect(find.byType(RTCVideoView), findsNothing,
          reason: '断流后必须撤掉画面视图（否则是一块黑屏/最后一帧假象）');
      expect(tester.takeException(), isNull);
    }, timeout: perTest);
  });
}
