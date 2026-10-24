/// 第九十六轮 · 覆盖率长尾补齐：**远程控制 UI 层**四个文件的残余未覆盖行。
///
/// ## 覆盖清单（行号按 `coverage/lcov.info` 实测，非推断）
///
/// | 文件 | 目标行 | 是什么分支 |
/// |---|---|---|
/// | `multi_video_screen.dart` | 53-54 | `_addDevice` 在 `_store == null`（初始化未完成）时的可见提示 |
/// | 同上 | 249 / 278 | `_VideoTile.didUpdateWidget` 贴新远端流；`_ready && remoteStream != null` 建 `RTCVideoView` |
/// | `device_list_screen.dart` | 145 / 163-164 / 171 | 删除对话框的「删除并重置配对码」→ 真轮换本机配对码 + 如实告知 |
/// | 同上 | 179-180 | `_createGroup` 的空勾选兜底（按钮 `onPressed` 仍是上一帧的快照） |
/// | `screen_viewer.dart` | 98-103 / 106-110 / 112 | `rc.inputAck` 消费：来源过滤、`castId` 过滤、ok/拒绝原因三档文案 |
/// | `remote_screen.dart` | 491 | 对讲权限被拒 → 可见提示且不弹面板 |
/// | 同上 | 1013 | 松手早于 `pttStart()` 完成 → 撤销这次启动（不留无人控制的录音） |
/// | 同上 | 1018-1020 / 1036-1040 | 录音真的起来 → 状态迁移 + 松手发送后的结果回显 |
/// | 同上 | 1021 | 60 秒上限计时器到点 → 自动停录并说明"到上限"（不是用户松手） |
///
/// ## 诚实登记：唯一一条**确实测不到**的行
/// - `remote_screen.dart:154`（`_speedTest` 的 `on Object` 兜底）：`probeMqtt` /
///   `probeStun` 内部逐节点 `catch (Object) → null`（`node_catalog.dart:128/177`），
///   `Future.wait` 因此**永不抛**；宿主与真机都不存在能让它抛出的输入。
///   硬凑只能改生产代码，故如实留红。
///
/// ## 遵守的宿主约束
/// 1. **不用 `pumpAndSettle` 等数据**（页面挂着常驻订阅）⇒ 有界 `waitFor`；
/// 2. 平台边界只装替身（`flutter_webrtc` / `permission_handler` / `record`
///    的**平台返回**），被驱动的仍是生产代码；
/// 3. 单例替身（`RecordPlatform.instance` / `SharedPreferencesStorePlatform.instance`
///    / `debugSendTo` / `debugSeed`）**一律在 tearDown 还原**；
/// 4. 需要真实异步（`Future.delayed` / 真实 IO）才能推进的分支，全部放进
///    `tester.runAsync`，不靠 `pump(Duration)` 推假时钟。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart'
    as spi;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/features/remote/device_list_screen.dart';
import 'package:sonic_shield/features/remote/multi_video_screen.dart';
import 'package:sonic_shield/features/remote/remote_screen.dart';
import 'package:sonic_shield/features/remote/screen_viewer.dart';
import 'package:sonic_shield/remote/controller_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/multi_call_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/permission_stub.dart';

// ══════════════════════════════════════════════════════════════════════
// 平台替身
// ══════════════════════════════════════════════════════════════════════

/// `SharedPreferences` 平台层替身：`getAll()` **慢一拍**。
///
/// 只为一个分支服务 —— `MultiVideoScreen._init()` 的第一句就是
/// `await SharedPreferences.getInstance()`，而真机上它是"读一次盘"的
/// 真实耗时。宿主里 mock 存储是**纯微任务**，`pumpWidget` 结束时 `_init`
/// 早已完成 ⇒「初始化未完成时点 +」这条分支**结构性到不了**。
/// 这里把平台层的 `getAll` 挂到一个**假计时器**上（`Future.delayed`），
/// 于是"未完成"变成可控状态，而 `_init` 之后的逻辑仍逐字节是生产代码。
class _SlowPrefsStore extends spi.SharedPreferencesStorePlatform {
  _SlowPrefsStore(this.delay);

  final Duration delay;
  final Map<String, Object> _bag = <String, Object>{};

  @override
  Future<Map<String, Object>> getAll() async {
    await Future<void>.delayed(delay);
    return Map<String, Object>.of(_bag);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _bag[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _bag.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    _bag.clear();
    return true;
  }
}

/// `record` 平台层替身：可编程的权限与耗时。
///
/// 与 `support/record_stub.dart` 的 `FakeRecordPlatform` 同一思路（只桩
/// **平台返回**），但多一个 [startDelay] —— 覆盖
/// 「松手早于 `pttStart()` 完成」必须让启动**确定性地慢于**抬手，
/// 否则"先松手"与"先启动完"是赛跑，用例会间歇性变红。
class _FakeRecordPlatform extends RecordPlatform {
  /// 可**就地改**：`RecordPlatform.instance` 必须在 `setUp`（真实 zone）里装好
  /// 并预热，而每个用例要的返回形状不同 ⇒ 只能在用例体里改字段，不能再换实例
  /// （换实例就要重新 `create()`，而那次往返在假 zone 里永远不完成）。
  bool permissionGranted = true;
  Duration? startDelay;

  final List<String> calls = <String>[];

  @override
  Future<void> create(String recorderId) async => calls.add('create');

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async {
    calls.add('hasPermission');
    return permissionGranted;
  }

  @override
  Future<void> start(String recorderId, RecordConfig config,
      {required String path}) async {
    calls.add('start');
    final d = startDelay;
    if (d != null) await Future<void>.delayed(d);
  }

  @override
  Future<String?> stop(String recorderId) async {
    calls.add('stop');
    return null;
  }

  @override
  Future<void> cancel(String recorderId) async => calls.add('cancel');

  @override
  Future<void> dispose(String recorderId) async => calls.add('dispose');

  @override
  Future<void> pause(String recorderId) async => calls.add('pause');

  @override
  Future<void> resume(String recorderId) async => calls.add('resume');

  @override
  Future<bool> isRecording(String recorderId) async => false;

  @override
  Future<bool> isPaused(String recorderId) async => false;

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -160, max: -160);

  @override
  Future<Stream<Uint8List>> startStream(
          String recorderId, RecordConfig config) async =>
      const Stream<Uint8List>.empty();

  @override
  Future<bool> isEncoderSupported(
          String recorderId, AudioEncoder encoder) async =>
      true;

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async =>
      const <InputDevice>[];

  @override
  void setOnConfigChanged(
      String recorderId, void Function(RecordConfig config)? handler) {}

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();
}

/// 远端 `MediaStream` 替身。
///
/// `MediaStream` 在宿主机上只能由 `flutter_webrtc` 的 `onTrack` 事件构造
/// （`MediaStreamNative.fromMap`，未导出），而本文件要断言的是
/// `_VideoTile` 在"远端流非空"时**渲染 `RTCVideoView`** 这一分支，
/// 不是插件解析逻辑（那由 `multi_call_service_connect_test` 覆盖）。
/// `RTCVideoRenderer.srcObject` 的 setter 只读 `id` / `ownerTag` 两个字段，
/// 故这里只给这两个；其余成员走 `noSuchMethod`（被调用即说明用错了替身）。
class _FakeMediaStream extends MediaStream {
  _FakeMediaStream(String id) : super(id, 'peer-r96');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ══════════════════════════════════════════════════════════════════════
// 通用工具
// ══════════════════════════════════════════════════════════════════════

/// 有界等待：最多 [rounds]×[step]，超时**显式 fail**。
///
/// 不用 `pumpAndSettle` 当"等数据"用 —— 它默认 10 分钟，失败形态是整轮门禁
/// 挂死而不是一条能读的红断言（`device_list_screen_test.dart` 头注同源）。
Future<void> _waitFor(
  WidgetTester tester,
  bool Function() cond, {
  required String reason,
  int rounds = 200,
  Duration step = const Duration(milliseconds: 25),
}) async {
  for (var i = 0; i < rounds; i++) {
    if (cond()) return;
    await tester.pump(step);
  }
  fail('有界等待超时（$rounds 轮）：$reason');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const perTest = Timeout(Duration(seconds: 120));

  const nativeChannel = MethodChannel('sonic_shield/native');
  const webrtcChannel = MethodChannel('FlutterWebRTC.Method');
  const textureChannel = MethodChannel('FlutterWebRTC/Texture1');
  const eventChannel = MethodChannel('FlutterWebRTC.Event');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void stubWebrtc() {
    messenger.setMockMethodCallHandler(nativeChannel, (call) async => null);
    messenger.setMockMethodCallHandler(webrtcChannel, (call) async {
      if (call.method == 'createVideoRenderer') {
        // 真实插件返回形状；不桩则宿主拿到 null，取 `['textureId']` 直接抛。
        return <String, dynamic>{'textureId': 1};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(textureChannel, (call) async => null);
    messenger.setMockMethodCallHandler(eventChannel, (call) async => null);
  }

  void clearWebrtc() {
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(webrtcChannel, null);
    messenger.setMockMethodCallHandler(textureChannel, null);
    messenger.setMockMethodCallHandler(eventChannel, null);
  }

  // ══════════════════════════════════════════════════════════════════
  // A · multi_video_screen.dart（53-54 / 249 / 278）
  // ══════════════════════════════════════════════════════════════════

  group('COV-A 多设备视频页残余分支', () {
    final svc = MultiCallService.instance;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      svc.debugClear();
      stubWebrtc();
    });

    tearDown(() {
      svc.debugClear();
      clearWebrtc();
    });

    PairedEndpoint peer(String id, String name) => PairedEndpoint(
          deviceId: id,
          name: name,
          secret: 'secret-$id',
          pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );

    MultiCallSession session(String id, String name) =>
        MultiCallSession(callId: 'call-$id', peer: peer(id, name));

    Future<void> drain(WidgetTester tester, {int rounds = 12}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 5));
      }
    }

    testWidgets('COV-01 初始化未完成就点 + → 明说"正在加载"，不许没反应（53-54）',
        (tester) async {
      // 平台层慢一拍：`_init()` 的 `await SharedPreferences.getInstance()`
      // 落在假计时器上 ⇒ `_store` 在首帧后仍是 null（真机上"读盘未回"同形状）。
      final prev = spi.SharedPreferencesStorePlatform.instance;
      spi.SharedPreferencesStorePlatform.instance =
          _SlowPrefsStore(const Duration(seconds: 1));
      addTearDown(() => spi.SharedPreferencesStorePlatform.instance = prev);

      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          MaterialApp(theme: ThemeData(platform: TargetPlatform.linux), home: const MultiVideoScreen()));

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();

      expect(find.text('正在加载设备列表，请稍后再试'), findsOneWidget,
          reason: '初始化没完成时点 + 必须给出可见反馈 —— 静默等于"按钮坏了"');

      // 把慢 getAll 的计时器推完（否则收尾判 pending timer）。
      await tester.pump(const Duration(seconds: 2));
      await drain(tester);
    }, timeout: perTest);

    testWidgets('COV-02 服务换了一份带远端流的会话 → 贴流并渲染 RTCVideoView（249/278）',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'rc_paired': '[{"deviceId":"d1","name":"客厅","secret":"s",'
            '"pairedAt":1700000000000}]',
      });
      svc.debugSeed([session('d1', '客厅')]);

      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: const MultiVideoScreen()));
      await drain(tester);

      // 前提：远端流未到 ⇒ 占位文案，没有画面视图。
      expect(find.text('连接中…'), findsOneWidget);
      expect(find.byType(RTCVideoView), findsNothing);

      // `didUpdateWidget` 比的是 `old.session.remoteStream` 与
      // `widget.session.remoteStream` —— 同一个对象上就地改字段，两侧读到的
      // 永远是同一个值（那是生产里"贴不上流"的形状）。服务**换一份会话对象**
      // （`_sessions[deviceId] = newSession`，重连即如此）才会让这两个值不同。
      final next = session('d1', '客厅')
        ..remoteStream = _FakeMediaStream('remote-r96')
        ..phase = MultiCallPhase.connected;
      svc.debugSeed([next]);
      await drain(tester);

      expect(find.byType(RTCVideoView), findsOneWidget,
          reason: '249 贴流 + 278 渲染：远端流非空时必须换成画面，而不是停在占位文案');
      expect(find.text('已连接（等待画面）'), findsNothing);
      expect(tester.takeException(), isNull);
    }, timeout: perTest);
  });

  // ══════════════════════════════════════════════════════════════════
  // B · device_list_screen.dart（145 / 163-164 / 171 / 179-180）
  // ══════════════════════════════════════════════════════════════════

  group('COV-B 我的设备页残余分支', () {
    PairedEndpoint ep(String id, String name) => PairedEndpoint(
          deviceId: id,
          name: name,
          secret: 's-$id',
          pairedAt: DateTime(2024, 3, 5),
        );

    Future<RemoteStore> pump(WidgetTester tester,
        {List<PairedEndpoint> endpoints = const []}) async {
      SharedPreferences.setMockInitialValues({});
      final store = RemoteStore(await SharedPreferences.getInstance());
      for (final e in endpoints) {
        await store.addPaired(e);
      }

      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, __) => const DeviceListScreen()),
          GoRoute(
            path: '/remote/pair-qr',
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('PAIR-QR-PAGE'))),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      return store;
    }

    Future<RemoteStore> store() async =>
        RemoteStore(await SharedPreferences.getInstance());

    testWidgets('COV-03 删除并重置配对码 → 真的轮换本机码并如实告知（145/163-164/171）',
        (tester) async {
      final s = await pump(tester, endpoints: [ep('ep-1', 'A')]);
      final before = await s.ensurePairingCode();
      expect(before, isNotEmpty, reason: '前提：本机配对码已生成');

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, '删除并重置配对码'));
      await tester.pumpAndSettle();

      expect((await store()).paired(), isEmpty, reason: '设备必须被解配对');
      expect((await store()).pairingCode, isNot(before),
          reason: '163：选了"重置配对码"就必须真的换一把新码 —— '
              '只删列表拦不住伪造 from 的旁路（BUG-110）');
      expect(find.textContaining('已删除「A」并重置配对码'), findsOneWidget,
          reason: '171：必须说清"其它设备要重新扫码"，否则用户以为只是删了一行');
    }, timeout: perTest);

    testWidgets('COV-04 勾选被清空的同一帧按下「建组」→ 明示"请先勾选"（179-180）',
        (tester) async {
      await pump(tester, endpoints: [ep('ep-1', 'A')]);

      // 勾选 → 按钮拿到 `onPressed: _createGroup`（此时非空）。
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      final btn = find.ancestor(
        of: find.textContaining('建组'),
        matching: find.byType(TextButton),
      );
      expect(tester.widget<TextButton>(btn).onPressed, isNotNull);

      // 取消勾选后**不重建**就按下：按钮元素里仍是上一帧的 widget，
      // `onPressed` 依然可点，而 `_checkedIds` 已经空了 —— 正是 179-180 兜底。
      await tester.tap(find.byType(Checkbox).first);
      await tester.tap(btn);
      await tester.pump();

      expect(find.text('请先勾选要入组的设备'), findsOneWidget,
          reason: '空勾选进建组会让用户白填一遍再被拒 —— 必须当场说明');
      expect(find.text('建组（0 台设备）'), findsNothing,
          reason: '不许真的弹出"0 台设备"的建组对话框');
    }, timeout: perTest);
  });

  // ══════════════════════════════════════════════════════════════════
  // C · screen_viewer.dart（98-103 / 106-110 / 112）
  //
  // `rc.inputAck` 的唯一消费者就在这个订阅里。它此前**一次都没被触发过**
  // （订阅体 12 行全红）—— 而它的作用恰恰是"远程控制失败在观看页可见"：
  // 端点没开无障碍 / 会话已停时，端点会回 `ok:false`，本页必须如实显示，
  // 否则用户看着一块静止画面，以为是自己没点准（BUG-029 同族）。
  //
  // 驱动方式：走**真密文**（`RcCodec` 真 HKDF + AES-GCM）+ 既有接缝
  // `debugSetOwnCode` / `debugHandleRaw`（与 `endpoint_inbound_raw_test`
  // 同一手法）。不桩解密、不伪造广播 —— 事件确实是从入站链路里出来的。
  // ══════════════════════════════════════════════════════════════════

  group('COV-C 投屏观看页：rc.inputAck 回执消费', () {
    const ownId = 'EPR96000000000abc';
    const ctrlId = 'CTRLR96000000001';

    final svc = RcEndpointService.instance;

    late SharedPreferences prefs;
    late RemoteStore store;
    late AppDatabase db;

    final peer = PairedEndpoint(
      deviceId: ctrlId,
      name: '客厅平板',
      secret: 'CODE0001',
      pairedAt: DateTime(2024, 1, 1),
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = RemoteStore(prefs);
      await store.setIdentity(ownId, '端点机');
      await store.ensurePairingCode();
      await store.addPaired(peer);
      db = await AppDatabase.open(inMemoryDatabasePath);
      svc.debugBind(store: store, db: db, saltStore: KdfSaltStore(prefs));
      svc.debugSetOwnCode(store.pairingCode);
      svc.debugSendTo = (endpoint, msg, s, enqueueOnFail) async => true;
      stubWebrtc();
    });

    tearDown(() async {
      svc.debugSendTo = null;
      svc.debugSetOwnCode('');
      clearWebrtc();
      await db.close();
    });

    String evtTopic(String peerId) => 'sonicshield/v1/$peerId/evt';

    /// 对端（控制端）把回执发到本机 `evt` 主题时的密封方式：
    /// 密钥 = 「本机 deviceId + 本机配对码」派生的 `evt` 上下文（与 `_handleRaw` 对称）。
    Future<String> sealEvt(RcMessage msg, String peerId) async {
      final key = await RcCodec.deriveKey(store.pairingCode, '$ownId|evt');
      return RcCodec.encode(msg, key, evtTopic(peerId));
    }

    Future<void> pumpViewer(WidgetTester tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: ScreenViewerScreen(endpoint: peer, castId: 'cast-r96'),
        ),
      ));
      // `_boot()` 的 `_remote.initialize()` 与两路订阅都是异步的 ⇒ 有界推帧。
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    /// 灌一条真密文进站，并等它的广播落到界面。
    Future<void> emit(
      WidgetTester tester,
      String type,
      Map<String, dynamic> payload, {
      String from = ctrlId,
    }) async {
      final n = RcMessage.now(type, payload);
      final msg = RcMessage(
          id: n.id, ts: n.ts, type: n.type, payload: n.payload, from: from);
      final wire = await sealEvt(msg, from);
      await tester.runAsync(() async {
        await svc.debugHandleRaw(evtTopic(from), wire);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }

    testWidgets('COV-05 端点回执 ok:true → 观看页显示「已执行」（98-103/106-110/112）',
        (tester) async {
      await pumpViewer(tester);
      expect(find.text('等待画面…'), findsWidgets, reason: '前提：还没收到任何回执');

      await emit(tester, RcEvt.inputAck, {'ok': true, 'castId': 'cast-r96'});

      expect(find.text('已执行'), findsWidgets,
          reason: '注入成功必须让控制端看见 —— 否则"点了一下没反应"无从判断');
      expect(find.text('等待画面…'), findsNothing,
          reason: '回执到了就不该继续显示"等待画面"（那是初始态）');
    }, timeout: perTest);

    testWidgets('COV-06 端点拒绝且给了原因 → 原样带出原因（112 的 why 分支）',
        (tester) async {
      await pumpViewer(tester);

      await emit(tester, RcEvt.inputAck,
          {'ok': false, 'castId': 'cast-r96', 'message': '端点未开启无障碍'});

      expect(find.text('未执行：端点未开启无障碍'), findsWidgets,
          reason: '只说"未执行"等于让用户自己猜端点为何拒 —— 原因必须一并显示');
    }, timeout: perTest);

    testWidgets('COV-07 端点拒绝但没给原因 → 回落成可读的通用原因（112 的 why==null 分支）',
        (tester) async {
      await pumpViewer(tester);

      await emit(tester, RcEvt.inputAck, {'ok': false, 'castId': 'cast-r96'});

      expect(find.text('未执行：端点拒绝或会话已停'), findsWidgets,
          reason: '原因缺失时也要给一句话，不能显示"未执行："这种半截文案');
    }, timeout: perTest);

    testWidgets('COV-08 castId 不匹配的回执必须丢弃（别的会话的回执不能改本页状态）',
        (tester) async {
      await pumpViewer(tester);

      await emit(tester,
          RcEvt.inputAck, {'ok': true, 'castId': 'cast-OTHER-SESSION'});

      expect(find.text('等待画面…'), findsWidgets,
          reason: '同时开着多个投屏会话时，串台的回执会把本页谎报成"已执行"');
      expect(find.text('已执行'), findsNothing);
    }, timeout: perTest);

    testWidgets('COV-09 来源不是本次观看的端点 → 丢弃（101-103 的 peerId 过滤）',
        (tester) async {
      await pumpViewer(tester);

      // 主题里的来源不是本页正在看的那台 ⇒ 即便 castId 撞上也不能采纳。
      await emit(tester, RcEvt.inputAck,
          {'ok': true, 'castId': 'cast-r96'}, from: 'OTHER-CTRL-000001');

      expect(find.text('已执行'), findsNothing,
          reason: '别的端点广播到同一 evt 主题的回执与本会话无关，采纳即串台');
      expect(find.text('等待画面…'), findsWidgets);
    }, timeout: perTest);
  });

  // ══════════════════════════════════════════════════════════════════
  // D · remote_screen.dart（491 / 1013 / 1018-1021 / 1036-1040）
  //
  // 对讲面板的四条残余分支，全部与"失败/边界必须可见"有关：
  // - 491：麦克风被拒时此前**静默 return**（BUG-062）⇒ 点了毫无反应；
  // - 1013：松手早于 `pttStart()` 完成 ⇒ 必须撤销这次启动，
  //   否则留下一段**没有任何界面入口**的录音（麦克风一直亮着）；
  // - 1018-1040：录音真的起来 → 状态迁移；松手 → 发送结果如实回显；
  // - 1021：到 60 秒上限 → 自动停录并说明是"到上限"。
  //
  // 录音插件用**平台层**替身（`RecordPlatform.instance`），理由同
  // `support/record_stub.dart`：`AudioRecorder._createFuture` 是 `late final`，
  // 用 method channel 桩跨用例后不再推进 ⇒ 之后任何 start/stop 都永久挂起。
  // ══════════════════════════════════════════════════════════════════

  group('COV-D 远程设置页：对讲面板残余分支', () {
    // ⚠️ 不在这里取单例：`RcControllerService` 的字段初始化会构造
    // `AudioRecorder()` 并立刻 `create()` 平台通道，而此处是**收集期**
    // （任何 setUp 之前）⇒ 直接 MissingPluginException。必须延迟到用例里取。

    PairedEndpoint ep() => PairedEndpoint(
          deviceId: '0123456789abcdef',
          name: '客厅平板',
          secret: 'AB2CD5EF',
          pairedAt: DateTime(2024, 1, 1),
        );

    RecordPlatform? prevPlatform;
    late _FakeRecordPlatform rec;

    // ⚠️ **必须在 setUp 里装替身并预热**（`setUp` 跑在真实 zone）：
    // `AudioRecorder` 是进程内单例，`_createFuture` 只在**首次构造**时创建，
    // 之后每次调用都先 `await` 它。若首次构造发生在用例体（假 zone），
    // 那个 future 的完成回调落在一个随后被销毁的 zone 里 ⇒ 下一个用例的
    // `stop()/hasPermission()` **永久挂起**（不是抛错）。实测症状：
    // 单跑 COV-11 通过，跟在 COV-10 之后跑就卡死在 `installRecorder` 的
    // `await pttCancel()` 上，整轮门禁挂死而不留红断言。
    setUp(() async {
      prevPlatform = RecordPlatform.instance;
      rec = _FakeRecordPlatform();
      RecordPlatform.instance = rec;
      await RcControllerService.instance.pttCancel();
      rec.calls.clear();
    });

    tearDown(() {
      final p = prevPlatform;
      if (p != null) RecordPlatform.instance = p;
      prevPlatform = null;
      clearPermissionStub();
    });

    Future<void> pumpRemote(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.addPaired(ep());

      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          const ProviderScope(child: MaterialApp(home: RemoteScreen())));
      await _waitFor(tester, () => find.text('客厅平板').evaluate().isNotEmpty,
          reason: '远程设置页必须列出已配对端点');
    }

    Future<void> openPttSheet(WidgetTester tester) async {
      await tester.tap(find.byTooltip('对讲机'));
      await _waitFor(
          tester, () => find.text('对讲机 → 客厅平板').evaluate().isNotEmpty,
          reason: '麦克风已授权时必须打开对讲面板');
      // 这里等的是**路由转场**（不是数据）：面板滑上来期间按当前位置下按会打空
      // （实测症状：`onTapDown` 一次都不触发，`rec.calls` 为空）。
      await tester.pumpAndSettle();
      expect(find.text('对讲机 → 客厅平板'), findsOneWidget);
    }

    testWidgets('COV-10 麦克风被拒 → 明说缺权限且不打开面板（491）', (tester) async {
      rec.permissionGranted = false;
      final requests = stubPermissions(
          {Permission.microphone: PermissionStatus.denied});
      await pumpRemote(tester);

      await tester.tap(find.byTooltip('对讲机'));
      await _waitFor(
          tester,
          () =>
              find.text('需要麦克风权限才能对讲').evaluate().isNotEmpty,
          reason: '权限被拒必须给可见反馈 —— 静默 return 等于"按了没反应"');

      expect(requests.single, [Permission.microphone], reason: '必须真的申请了麦克风权限');
      expect(find.text('对讲机 → 客厅平板'), findsNothing,
          reason: '没权限还弹出面板 ⇒ 用户说完才发现没录上（静默失败）');
      expect(rec.calls, isNot(contains('start')),
          reason: '没权限就不该去开录音');

      await tester.pump(const Duration(seconds: 5)); // 推掉 SnackBar 计时
    }, timeout: perTest);

    /// 交替推「真实异步」与「假时钟」。
    ///
    /// `_start()` / `_stopSend()` 的每个 `await` 都跨了两条车道：
    /// - 平台替身（`hasPermission` / `stop`）在**假 zone** 里完成 ⇒ 续体是
    ///   假 zone 的微任务，只有 `pump()` 会刷它；
    /// - `Directory.systemTemp.createTemp` / `File.exists` 是**真实 IO** ⇒
    ///   只有 `runAsync` 能让事件循环推进。
    /// 只推一种必然卡在另一种上（症状是"断言找不到文本"，不是抛错）。
    Future<void> pumpReal(WidgetTester tester, {int rounds = 30}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        // ⚠️ 必须带时长：`runAsync` 推的是**真实**事件循环，假 zone 里的
        // `Future.delayed`（如替身 `start()` 的 startDelay）只有假时钟前进才到点。
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// 下按并让 `onTapDown` 真的触发（= 按住不放）。
    ///
    /// ⚠️ 手势**必须**在假 zone 里下发：`TapGestureRecognizer` 的 100ms
    /// `kPressTimeout` 是 `Timer`，只有在假 zone 里创建才能被
    /// `pump(150ms)` 推动（实测：放进 `runAsync` 里下发时，本页的
    /// `onTapDown` 一次都不触发 —— 被 modal 路由的手势竞技场吞掉）。
    Future<TestGesture> pressDown(WidgetTester tester) async {
      final g = await tester
          .startGesture(tester.getCenter(find.byType(CircleAvatar)));
      await tester.pump(const Duration(milliseconds: 150));
      return g;
    }

    testWidgets('COV-11 松手早于 pttStart 完成 → 撤销启动，不留无人控制的录音（1013）',
        (tester) async {
      // 让启动**确定性地慢**：抬手发生在启动回来之前。
      rec.startDelay = const Duration(milliseconds: 300);
      stubPermissions({Permission.microphone: PermissionStatus.granted});
      await pumpRemote(tester);
      await openPttSheet(tester);

      final g = await pressDown(tester);
      // 启动还没回来就松手 ⇒ `_pressing` 先变 false。
      await g.up();
      await tester.pump();
      // 交替推真实异步（`createTemp` 的 IO）与假时钟（替身 `start()` 的 300ms）
      // 直到 `pttStart()` 回来 —— 它回来时手指已经松开，必须走撤销分支。
      await pumpReal(tester);

      expect(rec.calls, contains('start'), reason: '前提：启动确实发起了');
      expect(rec.calls, contains('stop'),
          reason: '1013：启动完成后发现手指已松开 ⇒ 必须 `onCancel` 撤销这次启动'
              '（`pttCancel()` 才会 stop），否则麦克风被一直占着');
      expect(find.text('未录到音频'), findsOneWidget,
          reason: '松手时还没开录，必须给出可见结果');
      expect(tester.takeException(), isNull);
    }, timeout: perTest);

    testWidgets('COV-12 按住真的开录 → 松手发送并回显结果（1018-1020/1036-1040）',
        (tester) async {
      stubPermissions({Permission.microphone: PermissionStatus.granted});
      await pumpRemote(tester);
      await openPttSheet(tester);

      final g = await pressDown(tester);
      await pumpReal(tester);

      expect(rec.calls, contains('start'), reason: '1018 的前提：录音真的起来了');
      expect(find.textContaining('正在录音…'), findsOneWidget,
          reason: '1018：开录成功后必须切到录音态（红按钮 + 计时文案），'
              '否则用户不知道已经在录');

      await g.up();
      await pumpReal(tester);

      expect(rec.calls, contains('stop'),
          reason: '1036：松手必须真的停录（`pttStopAndSend()` → `_rec.stop()`）');
      expect(find.text('按住下方按钮开始说话'), findsOneWidget,
          reason: '松手后必须回到待机态，不能一直显示"正在录音"');
      expect(find.text('未录到音频'), findsOneWidget,
          reason: '1039-1040：发送结果必须回显（宿主没有录音文件 ⇒ 如实说"未录到音频"，'
              '不许假装发出去了）');
      expect(tester.takeException(), isNull);
    }, timeout: perTest);

    testWidgets('COV-13 录音到 60 秒上限 → 自动停录并说明是"到上限"（1021/1040 自动档）',
        (tester) async {
      stubPermissions({Permission.microphone: PermissionStatus.granted});
      await pumpRemote(tester);
      await openPttSheet(tester);

      final g = await pressDown(tester);
      await pumpReal(tester);
      expect(find.textContaining('正在录音…'), findsOneWidget,
          reason: '前提：已经在录');

      // 一次性上限计时器到点（文案承诺"最长 60 秒"，必须有实现）。
      await tester.pump(const Duration(seconds: 61));
      await pumpReal(tester);

      expect(rec.calls, contains('stop'),
          reason: '1021：到上限必须自动停录 —— 否则麦克风会一直录下去');
      expect(find.textContaining('已到 60 秒上限，自动发送'), findsOneWidget,
          reason: '1040：自动发送必须说明是"到上限"而不是用户松手，'
              '否则用户以为自己没松手');
      // 手指仍按着，收尾把指针抬起来，避免残留 gesture。
      await g.up();
      await pumpReal(tester);
    }, timeout: perTest);
  });
}
