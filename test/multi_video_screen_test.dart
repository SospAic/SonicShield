import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/features/remote/multi_video_screen.dart';
import 'package:sonic_shield/remote/call_lifecycle.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/multi_call_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/permission_stub.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 多设备视频页（`MultiVideoScreen`）宿主测试 —— **第三十八轮新建**。
///
/// ## 为什么此前 117 行未覆盖（LF=151 / LH=34）
/// 本页是**全项目唯一仍无专属测试文件的大文件**（`grep -rln "MultiVideoScreen"
/// test/` 零命中、`multi_video_screen.dart` 也从未被任何锁读过）。
/// 未覆盖面集中在三类**只在 `sessions` 非空时才存在**的 UI：
/// 窗口栅格、`_VideoTile`（约 100 行）、底部指令条。
///
/// 而宿主机上 `sessions` **恒为空** —— `MultiCallService.connect()` 的第一步
/// 就是 `_ensureLocalStream()` → `navigator.mediaDevices.getUserMedia()`，
/// 宿主既没相机也没另一侧的 `RTCPeerConnection`
/// ⇒ `connect` 恒返回 false ⇒ `_sessions` 永远是空表 ⇒ 整块界面结构上到不了。
///
/// 本文件用服务层新增的 `@visibleForTesting` 会话缝
/// `MultiCallService.debugSeed / debugClear`（照 `RcEndpointService.debugBind`、
/// `CallService.setPhaseForTest` 的先例）把会话注入到位，再断言**界面真的按
/// 会话状态渲染、交互真的改到状态**。
///
/// ## 边界（明确不测什么）
/// - **不测**真实画面：`RTCVideoView` 要纹理，宿主机没有。本文件只走到
///   "`_ready` 为真但 `remoteStream` 仍为 null"这一占位分支（与
///   `call_incoming_overlay_test.dart` 同一处理）。
/// - **不测** `_ensureLocalStream` 成功后的 `createPeerConnection` 中段：
///   宿主拿不到媒体，那是真实硬件路径。
/// - **不桩任何声盾生产逻辑**：只桩**插件通道**（`flutter_webrtc` 的纹理
///   创建 + `permission_handler` 的权限询问，通道名/方法名照插件真实实现）。
///
/// ## 遵守的宿主约束（与 `guard_screen_test.dart` / `call_incoming_overlay_test.dart` 同源）
/// 1. **不用 `pumpAndSettle`** —— 本页有 SnackBar 计时与常驻 `StreamBuilder`，
///    它的语义不可靠；一律用有界 `waitFor(cond)`，超时**显式 fail**。
/// 2. **收尾推掉 SnackBar 计时**（默认 4s），否则判 "A Timer is still pending"。
/// 3. **每个 `testWidgets` 显式 `timeout: 90s`** —— 默认 10 分钟的挂死会吃掉整轮。
/// 4. **视口放大** —— 栅格 + 底部指令条在默认 800×600 下会被折叠。
///
/// ## 断言准则
/// 断言"交互真的改了状态"（`activeId` / `sessions` 真的变了、文案随之变化、
/// 失败真的弹了 SnackBar），不写"控件存在"这类恒真断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const perTest = Timeout(Duration(seconds: 90));

  /// 原生桥通道：不打桩时 `invokeMethod` 的 future 可能永不 resolve。
  const nativeChannel = MethodChannel('sonic_shield/native');

  /// `flutter_webrtc` 的方法通道（纹理创建/销毁、`getUserMedia`、
  /// `createPeerConnection`）。桩只复刻**真实插件返回的形状**。
  const webrtcChannel = MethodChannel('FlutterWebRTC.Method');

  /// `RTCVideoRenderer.initialize()` 会给每个纹理开一条
  /// `FlutterWebRTC/Texture$textureId` 事件通道；桩上它 `listen`/`cancel`
  /// 才有确定性应答。
  const textureChannel = MethodChannel('FlutterWebRTC/Texture1');

  /// `flutter_webrtc` 的全局事件通道（首次 `invokeMethod` 时懒建）。
  /// ⚠️ 必须桩：未打桩时 `onListen` 的 `MissingPluginException` 会被
  /// `FlutterError.reportError` 上报 ⇒ 直接判用例失败。
  const eventChannel = MethodChannel('FlutterWebRTC.Event');

  late MultiCallService svc;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    svc = MultiCallService.instance;
    svc.debugClear();
    _messenger.setMockMethodCallHandler(nativeChannel, (call) async => null);
    _messenger.setMockMethodCallHandler(webrtcChannel, (call) async {
      if (call.method == 'createVideoRenderer') {
        // 不桩的话宿主机拿到 null，`response['textureId']` 会抛
        // NoSuchMethodError（异步未捕获错误）。
        return <String, dynamic>{'textureId': 1};
      }
      // 其余（`getUserMedia` / `createPeerConnection` / dispose…）**故意**返回
      // null —— 宿主机本来就该失败，本文件正是要断言"失败时必须可诊断"。
      return null;
    });
    _messenger.setMockMethodCallHandler(textureChannel, (call) async => null);
    _messenger.setMockMethodCallHandler(eventChannel, (call) async => null);
    addTearDown(() {
      clearPermissionStub();
      svc.debugClear();
      _messenger.setMockMethodCallHandler(nativeChannel, null);
      _messenger.setMockMethodCallHandler(webrtcChannel, null);
      _messenger.setMockMethodCallHandler(textureChannel, null);
      _messenger.setMockMethodCallHandler(eventChannel, null);
    });
  });

  // ───────────────────────── 夹具 ─────────────────────────

  PairedEndpoint peer(String id, String name) => PairedEndpoint(
        deviceId: id,
        name: name,
        secret: 'secret-$id',
        pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  /// 预置配对表（`RemoteStore.paired()` 读的就是 `rc_paired` 这个键）。
  void seedPaired(List<PairedEndpoint> peers) {
    SharedPreferences.setMockInitialValues({
      'rc_paired': jsonEncode([for (final p in peers) p.toJson()]),
    });
  }

  MultiCallSession session(
    String id,
    String name, {
    MultiCallPhase phase = MultiCallPhase.connecting,
    String? failure,
  }) {
    final s = MultiCallSession(callId: 'call-$id', peer: peer(id, name));
    s.phase = phase;
    s.failure = failure;
    return s;
  }

  /// 把真实异步推完再 `pump` 一帧让 `setState` 落到界面。
  /// ⚠️ **不要**用 `pumpAndSettle` 代替它。
  Future<void> drain(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 5));
    }
  }

  /// 有界轮询：条件成立才返回，否则**显式 fail**。
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() cond, {
    required String reason,
    int maxRounds = 200,
  }) async {
    for (var i = 0; i < maxRounds; i++) {
      if (cond()) return;
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 10));
    }
    fail('等待超时（$maxRounds 轮）：$reason');
  }

  Future<void> waitForText(WidgetTester tester, String substring) => waitFor(
        tester,
        () => find.textContaining(substring).evaluate().isNotEmpty,
        reason: '应出现含「$substring」的文案',
      );

  /// SnackBar 的自动消失计时（默认 4s）必须推掉，否则收尾判 pending timer。
  Future<void> retireSnackBars(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// pump 出多设备视频页（`initState._init` 是真实异步：prefs → RemoteStore）。
  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.linux),
      home: const MultiVideoScreen(),
    ));
    await drain(tester);
    // `_init` 完成后命令条文案才会从"未选择设备"变成真实目标。
    expect(find.text('多设备视频'), findsOneWidget, reason: '页面没起来');
  }

  /// 取栅格列数（断言"只有一路不切成两列"这类规则）。
  int crossAxisCount(WidgetTester tester) {
    final grid = tester.widget<GridView>(find.byType(GridView));
    final d = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    return d.crossAxisCount;
  }

  /// 某一路窗口上的「挂断这一路」按钮（与 AppBar 的「全部挂断」区分开）。
  Finder tileHangUp(String callId) => find.descendant(
        of: find.byKey(ValueKey(callId)),
        matching: find.byIcon(Icons.call_end),
      );

  // =====================================================================
  // 1 · 空态与命令条禁用
  // =====================================================================

  group('MV-01 空态（没有任何会话）与命令条防御分支', () {
    testWidgets('给可操作空态文案，且**整条指令条不渲染**（没有可发指令的目标）',
        (tester) async {
      seedPaired([peer('d1', '客厅')]);
      await pumpScreen(tester);

      expect(find.text('还没有视频连接'), findsOneWidget);
      expect(find.textContaining('点右上角 + 添加设备'), findsOneWidget);
      expect(find.byType(GridView), findsNothing);
      // ⚠️ 实测事实（本轮第一版断言错在这里）：空态走的是 `sessions.isEmpty`
      // 早返回分支，**`_CommandBar` 整块不构建** —— 所以它不是"禁用"，
      // 而是"根本不存在"。断言"禁用"会假红。
      expect(find.widgetWithText(TextButton, 'ping'), findsNothing);
      expect(find.widgetWithText(FilledButton, '取状态'), findsNothing);
    }, timeout: perTest);

    testWidgets('焦点指向已不存在的设备（防御分支）→ 指令条禁用，不崩溃不乱发',
        (tester) async {
      seedPaired([peer('d1', '客厅')]);
      // ⚠️ **诚实说明**：生产路径上 `_activeId` 不会指向已移除的设备
      // （`hangUp` 每次都过 `nextActiveId` 重算），本支路**仅经注入缝可达**。
      // 但它属于"指令条指向不存在的目标"这一防御分支，行为必须被锁死：
      // 禁用 + 明示"未选择设备"，绝不允许"点了却发到别的设备去"
      // （BUG-062 同族：不可用的入口要显式不可用）。
      svc.debugSeed([session('d1', '客厅')], activeId: 'ghost');
      await pumpScreen(tester);

      expect(find.text('未选择设备'), findsOneWidget);
      final ping =
          tester.widget<TextButton>(find.widgetWithText(TextButton, 'ping'));
      final status =
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, '取状态'));
      expect(ping.onPressed, isNull);
      expect(status.onPressed, isNull);
      // 会话本身不得因为焦点异常被丢掉。
      expect(find.text('客厅'), findsOneWidget);
      expect(svc.sessions.length, 1);
    }, timeout: perTest);

    testWidgets('未配对任何设备时点 + → 明确提示"没有可添加的设备"',
        (tester) async {
      seedPaired(const []);
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.add));
      await drain(tester);
      await waitForText(tester, '没有可添加的设备');

      expect(find.textContaining('都已连接或尚未配对'), findsOneWidget);
      await retireSnackBars(tester);
    }, timeout: perTest);
  });

  // =====================================================================
  // 2 · 栅格渲染：列数规则 + 设备名 + 「当前」标记
  // =====================================================================

  group('MV-02 窗口栅格', () {
    testWidgets('只有一路 → 单列；显示设备名并标出它是当前目标', (tester) async {
      seedPaired([peer('d1', '客厅')]);
      svc.debugSeed([session('d1', '客厅')]);
      await pumpScreen(tester);

      expect(crossAxisCount(tester), 1, reason: '只有一路时不该切成两列');
      expect(find.text('客厅 · 当前'), findsOneWidget);
      expect(find.text('当前目标：客厅'), findsOneWidget);
    }, timeout: perTest);

    testWidgets('两路 → 切成两列，只有当前那一路带「· 当前」', (tester) async {
      seedPaired([peer('d1', '客厅'), peer('d2', '卧室')]);
      svc.debugSeed([session('d1', '客厅'), session('d2', '卧室')]);
      await pumpScreen(tester);

      expect(crossAxisCount(tester), 2);
      expect(find.text('客厅 · 当前'), findsOneWidget);
      // 非当前那一路只显示设备名（不带后缀）—— 标错会让人发指令发错设备。
      expect(find.text('卧室'), findsOneWidget);
      expect(find.text('卧室 · 当前'), findsNothing);
    }, timeout: perTest);

    testWidgets('每一路按**自身**相位显示文案（失败要显示具体原因）',
        (tester) async {
      seedPaired([
        peer('d1', '客厅'),
        peer('d2', '卧室'),
        peer('d3', '书房'),
      ]);
      svc.debugSeed([
        session('d1', '客厅', phase: MultiCallPhase.connecting),
        session('d2', '卧室',
            phase: MultiCallPhase.failed, failure: '对方无应答'),
        session('d3', '书房', phase: MultiCallPhase.closed),
      ]);
      await pumpScreen(tester);

      expect(find.text('连接中…'), findsOneWidget);
      // failed 必须显示**具体原因**，而不是笼统的"连接失败"。
      expect(find.text('对方无应答'), findsOneWidget);
      expect(find.text('已挂断'), findsOneWidget);
      expect(find.text('连接失败'), findsNothing);
    }, timeout: perTest);

    testWidgets('已连通但远端画面未到 → 显示"等待画面"，不显示裸相位文案',
        (tester) async {
      seedPaired([peer('d1', '客厅')]);
      svc.debugSeed([session('d1', '客厅', phase: MultiCallPhase.connected)]);
      await pumpScreen(tester);

      expect(find.text('已连接（等待画面）'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);
    }, timeout: perTest);
  });

  // =====================================================================
  // 3 · 焦点切换：**不挂断任何一路**（本页存在的理由）
  // =====================================================================

  group('MV-03 点窗口切换目标', () {
    testWidgets('点第二路 → 焦点切过去，两路都还在，文案跟着变', (tester) async {
      seedPaired([peer('d1', '客厅'), peer('d2', '卧室')]);
      svc.debugSeed([session('d1', '客厅'), session('d2', '卧室')]);
      svc.setActive('d1');
      await pumpScreen(tester);
      expect(find.text('当前目标：客厅'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('call-d2')));
      await drain(tester);

      expect(svc.activeId, 'd2');
      expect(svc.sessions.length, 2, reason: '切换焦点**不得**挂断任何一路');
      expect(svc.isConnected('d1'), isFalse);
      expect(svc.sessionOf('d1'), isNotNull, reason: 'd1 必须仍然保持连接');
      expect(find.text('当前目标：卧室'), findsOneWidget);
      expect(find.text('卧室 · 当前'), findsOneWidget);
      expect(find.text('客厅 · 当前'), findsNothing);
    }, timeout: perTest);
  });

  // =====================================================================
  // 4 · 逐路挂断与全部挂断
  // =====================================================================

  group('MV-04 挂断', () {
    testWidgets('挂断非当前那一路 → 只移除它，当前焦点不动', (tester) async {
      seedPaired([peer('d1', '客厅'), peer('d2', '卧室')]);
      svc.debugSeed([session('d1', '客厅'), session('d2', '卧室')],
          activeId: 'd1');
      await pumpScreen(tester);

      await tester.tap(tileHangUp('call-d2'));
      await drain(tester);

      expect(svc.sessionOf('d2'), isNull);
      expect(svc.sessionOf('d1'), isNotNull, reason: '不该顺手把当前那路也断了');
      expect(svc.activeId, 'd1', reason: '当前那路仍在 → 焦点不该跳窗口');
      expect(find.text('当前目标：客厅'), findsOneWidget);
      expect(find.text('卧室'), findsNothing);
    }, timeout: perTest);

    testWidgets('挂断**当前**那一路 → 焦点回落到剩下的第一路（不跳成空白）',
        (tester) async {
      seedPaired([peer('d1', '客厅'), peer('d2', '卧室')]);
      svc.debugSeed([session('d1', '客厅'), session('d2', '卧室')],
          activeId: 'd1');
      await pumpScreen(tester);

      await tester.tap(tileHangUp('call-d1'));
      await drain(tester);

      expect(svc.sessionOf('d1'), isNull);
      expect(svc.activeId, 'd2', reason: '焦点必须回落到仍在的那一路');
      expect(find.text('当前目标：卧室'), findsOneWidget);
      expect(find.text('未选择设备'), findsNothing);
    }, timeout: perTest);

    testWidgets('「全部挂断」→ 会话清空并回到空态', (tester) async {
      seedPaired([peer('d1', '客厅'), peer('d2', '卧室')]);
      svc.debugSeed([session('d1', '客厅'), session('d2', '卧室')]);
      await pumpScreen(tester);

      await tester.tap(find.byTooltip('全部挂断'));
      await drain(tester);

      expect(svc.sessions, isEmpty);
      expect(svc.activeId, isNull);
      expect(find.text('还没有视频连接'), findsOneWidget);
      // 会话清空 ⇒ 指令条整块消失（与空态同一分支）。
      expect(find.widgetWithText(TextButton, 'ping'), findsNothing);
    }, timeout: perTest);
  });

  // =====================================================================
  // 5 · 底部指令条：真的发一条信令出去
  // =====================================================================

  group('MV-05 指令条', () {
    testWidgets('对当前目标发 ping → 宿主无 broker，明确提示"发送失败"而非静默',
        (tester) async {
      seedPaired([peer('d1', '客厅')]);
      svc.debugSeed([session('d1', '客厅')]);
      await pumpScreen(tester);

      await tester.tap(find.widgetWithText(TextButton, 'ping'));
      await drain(tester);
      await tester.pump(const Duration(milliseconds: 400)); // SnackBar 入场

      // `RcEndpointService.sendTo` 在无 broker 时返回 false（并把密文暂存
      // 到 outbox）⇒ 界面必须把"没发出去"讲出来。
      expect(find.textContaining('发送失败'), findsOneWidget);
      await retireSnackBars(tester);
    }, timeout: perTest);

    testWidgets('对当前目标发「取状态」且通道受理 → 明确回执"已向…发送"，与失败不混同',
        (tester) async {
      seedPaired([peer('d1', '客厅')]);
      svc.debugSeed([session('d1', '客厅')]);
      await pumpScreen(tester);

      // 宿主无 broker ⇒ `sendTo` 恒 false；用第 45 轮的注入缝驱动"已受理"一侧
      // （否则成功文案在宿主上**结构性不可达**，上面那条只测得到失败一侧）。
      var sent = 0;
      RcEndpointService.instance.debugSendTo =
          (endpoint, msg, store, enqueueOnFail) async {
        sent++;
        expect(msg.type, RcCmd.deviceStatus);
        return true;
      };
      addTearDown(() => RcEndpointService.instance.debugSendTo = null);

      await tester.tap(find.widgetWithText(FilledButton, '取状态'));
      await drain(tester);
      await tester.pump(const Duration(milliseconds: 400)); // SnackBar 入场

      expect(sent, 1, reason: '「取状态」必须真的把信令交出去一次，而不是只改界面');
      expect(find.textContaining('已向「客厅」发送'), findsOneWidget,
          reason: '受理后必须报"已发送" —— 与"发送失败（已暂存）"是两种后果，'
              '混同会让用户以为离线也能立即执行');
      await retireSnackBars(tester);
    }, timeout: perTest);
  });

  // =====================================================================
  // 6 · 添加一路：权限前置判定（BUG-062 同形状）
  // =====================================================================

  group('MV-06 添加一路视频', () {
    testWidgets('有可添加的设备但权限被拒 → 提示缺哪个权限，且**不**去建连',
        (tester) async {
      final requests = stubPermissions(const <Permission, PermissionStatus>{});
      seedPaired([peer('d1', '客厅')]);
      svc.debugSeed(const []); // 一路都没连 → d1 是可添加的候选
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.add));
      await drain(tester);
      await waitFor(
        tester,
        () => find.byType(SimpleDialog).evaluate().isNotEmpty,
        reason: '有候选设备时必须弹出选择框',
      );
      await tester.tap(find.text('客厅'));
      await drain(tester);
      await waitForText(tester, '需要麦克风权限');

      // 断言申请的就是**多路视频**缺一不可的两个权限（相机 + 麦克风）——
      // 这正是本页固定 `video: true` 的理由。
      expect(requests, isNotEmpty);
      expect(requests.first.toSet(),
          {Permission.microphone, Permission.camera});
      // 权限没给 ⇒ 不该留下任何半开会话。
      expect(svc.sessions, isEmpty);
      expect(find.text(callStartBlockText(CallStartBlock.micDenied)),
          findsOneWidget);
      // 宿主机建不起 PC，`connect` 恒 false —— 不该出现"连接中"的窗口。
      expect(find.byType(GridView), findsNothing);
      await retireSnackBars(tester);
    }, timeout: perTest);

    testWidgets('权限都给但宿主机拿不到媒体 → 明确"连接失败"，不留半开会话',
        (tester) async {
      stubPermissions({
        Permission.microphone: PermissionStatus.granted,
        Permission.camera: PermissionStatus.granted,
      });
      seedPaired([peer('d1', '客厅')]);
      svc.debugSeed(const []);
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.add));
      await drain(tester);
      await waitFor(
        tester,
        () => find.byType(SimpleDialog).evaluate().isNotEmpty,
        reason: '有候选设备时必须弹出选择框',
      );
      await tester.tap(find.text('客厅'));
      await drain(tester);
      await waitForText(tester, '连接失败');

      expect(find.textContaining('端点离线或无法获取麦克风/摄像头'), findsOneWidget);
      // 关键：`connect` 失败路径必须把自己清干净，不能留一路"僵尸会话"
      // 让界面显示一个永远连不上的窗口。
      expect(svc.sessions, isEmpty);
      expect(find.byType(GridView), findsNothing);
      await retireSnackBars(tester);
    }, timeout: perTest);

    testWidgets('候选里已连接的设备**不**再出现（不能重复连同一台）',
        (tester) async {
      stubPermissions({
        Permission.microphone: PermissionStatus.granted,
        Permission.camera: PermissionStatus.granted,
      });
      seedPaired([peer('d1', '客厅'), peer('d2', '卧室')]);
      svc.debugSeed([session('d1', '客厅')]);
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.add));
      await drain(tester);
      await waitFor(
        tester,
        () => find.byType(SimpleDialog).evaluate().isNotEmpty,
        reason: '还有 d2 没连，必须弹选择框',
      );

      // 对话框里只该有 d2。
      expect(
        find.descendant(
            of: find.byType(SimpleDialog), matching: find.text('卧室')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byType(SimpleDialog), matching: find.text('客厅')),
        findsNothing,
        reason: '已连接的那台不该出现在候选里',
      );

      // 关掉对话框（点遮罩外）→ 取消路径不得有任何副作用。
      // ⚠️ 必须把**退场动画**推完：`showDialog` 默认 `barrierDismissible`，
      // 点遮罩后 `SimpleDialog` 仍会在树上停留到转场结束（实测只 pump 60ms
      // 会假红"对话框还在"）。
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await drain(tester);
      expect(find.byType(SimpleDialog), findsNothing);
      expect(svc.sessions.length, 1);
      await retireSnackBars(tester);
    }, timeout: perTest);
  });
}
