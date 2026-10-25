/// R97 —— 覆盖率长尾补测第 3 组：16 个文件的碎片残差（19 行）。
///
/// ## 纪律
/// * 只新增本文件，`lib/**` 一行未改；
/// * 每条用例都**真实驱动**到目标行（不是断言别的东西顺带点亮）；
/// * 结构不可达的行**不硬凑**，在文件末尾「不可达登记」里逐条给理由与证据。
///
/// ## 装配来源（照抄既有用例，不自己发明）
/// * `R97-SL` ← `test/sound_library_screen_test.dart`（`runReal` 分段驱动 +
///   `flutter/assets` 与 `path_provider` 打桩）；
/// * `R97-AD` ← `test/r96_gap_ui_test.dart` 的 `pumpDashboard`；
/// * `R97-AHS` ← `test/assist_host_screen_test.dart` 的 `open` / `activate`；
/// * `R97-RCT` ← `test/r96_gap_ui_test.dart` 的 `pumpConsole`；
/// * `R97-PQ` ← `test/pair_qr_screen_test.dart` 的 `_pump`（**去掉 `const`**，
///   见该组注释：`const` 构造在编译期折叠 ⇒ 构造器那一行永远不计覆盖）；
/// * `R97-CSC` ← `test/call_screen_test.dart` 的 `pumpCall` + CSP-08。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/scheduling/run_pause.dart';
import 'package:sonic_shield/features/dashboard/dashboard_screen.dart';
import 'package:sonic_shield/features/remote/assist_host_screen.dart';
import 'package:sonic_shield/features/remote/call_screen.dart';
import 'package:sonic_shield/features/remote/pair_qr_screen.dart';
import 'package:sonic_shield/features/remote/remote_console_tab.dart';
import 'package:sonic_shield/features/sounds/sound_library_screen.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/playback_service.dart';
import 'package:sonic_shield/services/run_master_service.dart';

import 'support/permission_stub.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 小步推帧（`pumpAndSettle` 在含无限动画/进度圈的页面上会等满超时）。
Future<void> _frames(WidgetTester tester, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

ByteData _bytes(List<int> data) => Uint8List.fromList(data).buffer.asByteData();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ══════════════════════════════════════════════════════════════════════
  // R97-SL · sound_library_screen.dart:154-156
  //
  // 那三行是 `_importPresets()` 里传给 `importBundledPresets` 的
  // `removeFile` 闭包**函数体**。它只在「已落盘 ≥1 个文件、随后写库失败」
  // 的回滚路径上被调用（`preset_import.dart:207-215`）。
  //
  // 既有 SLB-15 只让 `materialize` 失败（`written` 为空 ⇒ 闭包一次都不调），
  // SLB-11 走的是**本地导入**的另一个同名闭包（`_importer` 里 93-96 行），
  // 所以预置库这一份从未被执行 —— 正是本组要补的碎片。
  // ══════════════════════════════════════════════════════════════════════
  group('R97-SL 预置库导入回滚闭包', () {
    const kPathProvider = MethodChannel('plugins.flutter.io/path_provider');
    const manifestKey = 'assets/audio/presets_manifest.json';

    late Directory tmp;
    late _FakeRepo repo;
    late _FakePlayer player;

    /// 清单内容替身（`null` = 资源缺失）。
    String? fakeManifest;

    /// 预置音频的合成字节数（`null` = 资源缺失）。
    int? fakeAudioBytes;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sonic_r97sl_');
      repo = _FakeRepo();
      player = _FakePlayer();
      fakeManifest = null;
      fakeAudioBytes = null;

      // `rootBundle` 是全局 `CachingAssetBundle`：缓存**跨用例存活**，必须清。
      rootBundle.clear();

      _messenger.setMockMethodCallHandler(kPathProvider, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') return tmp.path;
        if (call.method == 'getTemporaryDirectory') return tmp.path;
        return null;
      });
      // 接管资源通道（命中 mock 后 `send()` 不再转发给真实实现）。
      _messenger.setMockMessageHandler('flutter/assets', (message) async {
        final key = utf8.decode((message as ByteData).buffer.asUint8List());
        if (key == manifestKey) {
          final m = fakeManifest;
          return m == null ? null : _bytes(utf8.encode(m));
        }
        if (key.startsWith('assets/audio/')) {
          final n = fakeAudioBytes;
          return n == null ? null : _bytes(List<int>.filled(n, 7));
        }
        return null;
      });
    });

    tearDown(() {
      _messenger.setMockMethodCallHandler(kPathProvider, null);
      _messenger.setMockMessageHandler('flutter/assets', null);
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync(recursive: true);
        } on Object {
          // Windows 偶发"文件被占用"——夹具清理失败不该让用例红。
        }
      }
    });

    Map<String, Object> preset(String id, String category, String name) => {
          'id': id,
          'category': category,
          'name': name,
          'file': 'presets/$id.wav',
          'durationMs': 500,
        };

    /// 文档目录里本次导入落下的文件（`[\\/]` 切分，兼容 Windows 反斜杠）。
    List<String> leftoverFiles() => tmp
        .listSync()
        .whereType<File>()
        .map((f) => f.path.split(RegExp(r'[\\/]')).last)
        .where((n) => n.startsWith('audio_'))
        .toList();

    Future<void> pumpLib(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [assetRepoProvider.overrideWith((ref) async => repo)],
        child: MaterialApp(
          home: SoundLibraryScreen(previewPlayer: player, confirmDelete: false),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    /// 「导入预置库」按钮的 `onPressed`（静态类型 `VoidCallback`，
    /// 实际挂的是 `Future<void> Function()`，见 SLB 文件头的转型说明）。
    Future<void> Function() presetsCallback(WidgetTester tester) =>
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((w) => w is FilledButton).first)
            .onPressed! as Future<void> Function();

    /// **分段驱动**真实 I/O 链（机制见 `sound_library_screen_test.dart` §二：
    /// 一次 `runAsync` 在飞时 fake 微任务没人排空 ⇒ 必须"真实转一圈 + pump"交替）。
    Future<void> runReal(WidgetTester tester, Future<void> Function() body) async {
      var done = false;
      Object? error;
      StackTrace? stack;
      await tester.runAsync(() async {
        unawaited(body().then<void>((_) {
          done = true;
        }, onError: (Object e, StackTrace s) {
          error = e;
          stack = s;
          done = true;
        }));
      });
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!done && DateTime.now().isBefore(deadline)) {
        await tester.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
      }
      if (!done) fail('runReal 超时：链在 20s 内没走完（zone 死锁？）');
      if (error != null) Error.throwWithStackTrace(error!, stack!);
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
      }
    }

    testWidgets('R97-SL-01 预置已落盘但写库失败 → 回滚走 removeFile 闭包（154/155/156）',
        (tester) async {
      await pumpLib(tester);
      fakeManifest = jsonEncode({
        'items': [
          preset('knocks_door_single', 'knocks', '敲门（单下）'),
          preset('glass_break', 'glass', '玻璃破碎'),
        ],
      });
      fakeAudioBytes = 32;
      // 关键：落盘全部成功，**写库那一步**失败 ⇒ importAll 的 catch 才会
      // 拿着 `written`（2 条真实路径）逐个调 `removeFile`。
      repo.failOnSaveAll = StateError('磁盘满了');

      await runReal(tester, presetsCallback(tester));

      expect(repo.saveAllCalls, 1,
          reason: '前置自证：整批写库确实被调用过一次（否则回滚分支进不去）');
      expect(leftoverFiles(), isEmpty,
          reason: '★ 154-156：回滚闭包必须真的 `exists()` + `delete()`，'
              '否则写库失败会在私有目录留下两个孤儿 wav');
      expect(find.textContaining('导入失败（已回滚，库内无残留）'), findsOneWidget);

      // 排空 SnackBar 队列（每条 4s）。
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  // ══════════════════════════════════════════════════════════════════════
  // R97-AD · dashboard_screen.dart:300 / 314
  //
  // 300 = `auto && !paused` 的状态行文案，314 = 同一条件下的 tertiary 色调。
  // 判据是 `RunPause.paused(auto, DateTime.now())` —— 页面在 `build` 里直接
  // 读墙钟，仓库**没有时钟缝**（r96 GAP-03 已注明）。因此本用例只在
  // **非暂停窗口**内能点亮这两行；测量恰落在窗口内时显式 skip 而不是伪造断言。
  // ══════════════════════════════════════════════════════════════════════
  group('R97-AD 守护首页 auto 档位（非暂停分支）', () {
    const nativeChannel = MethodChannel('sonic_shield/native');

    testWidgets('R97-AD-01 auto 且不在暂停窗口 → 「自动运行中」+ tertiary（300/314）',
        (tester) async {
      SharedPreferences.setMockInitialValues({'compliance_accepted_v1': true});
      await SharedPreferences.getInstance();
      const state = EngineState(running: true, pendingCount: 0);
      BackgroundServiceManager.lastForTest = state;
      BackgroundServiceManager.stateForTest =
          Stream<EngineState>.multi((c) => c.add(state));
      stubPermissions({
        Permission.notification: PermissionStatus.granted,
        Permission.microphone: PermissionStatus.granted,
      });
      _messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        if (call.method == 'exactAlarmSupported') return true;
        return null;
      });
      addTearDown(() {
        BackgroundServiceManager.lastForTest = null;
        BackgroundServiceManager.stateForTest = null;
        BackgroundServiceManager.startHook = null;
        BackgroundServiceManager.invokeHook = null;
        clearPermissionStub();
        _messenger.setMockMethodCallHandler(nativeChannel, null);
      });

      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: const DashboardScreen(),
        ),
      ));
      await _frames(tester, 6);

      await RunMasterService.instance.set(RunMasterMode.auto);
      await _frames(tester, 4);

      // 两次取样分属不同分支 = 恰好跨过 20:00 / 21:00 边界 ⇒ 环境时序，不判定。
      final paused = RunPause.paused(RunMasterMode.auto, DateTime.now());
      final pausedAgain = RunPause.paused(RunMasterMode.auto, DateTime.now());
      if (paused != pausedAgain) {
        markTestSkipped('恰好跨过暂停窗口边界（两次取样不一致）');
        return;
      }
      if (paused) {
        // 休息日前夜 20:00 → 休息日 21:00 之间：300/314 结构上不可达（300 要求
        // `!paused`），且页面无时钟缝 ⇒ 只能如实跳过，绝不写"恒真断言"。
        markTestSkipped('墙钟落在暂停窗口内：本分支要求 !paused，页面无时钟缝');
        return;
      }

      expect(find.textContaining('自动运行中：到'), findsOneWidget,
          reason: '★ 300：auto 且未暂停时必须说"自动运行中：到 … 自动暂停"');
      expect(find.textContaining('自动暂停中：到'), findsNothing);
      expect(find.text('自动'), findsWidgets);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  // ══════════════════════════════════════════════════════════════════════
  // R97-AHS · assist_host_screen.dart:233
  //
  // 权限开关的 `onChanged` 里，"`grant()` 返回 false"（发布失败已回退）才走
  // 233-235 的提示。既有 AHW-04 用正常传输 ⇒ `grant()` 恒 true ⇒ 早退。
  // 这里换成**发布即抛**的传输：`RcAssistHost.grant` 的 catch 分支
  // （assist_host.dart:273-278）回退权限并返回 false。
  // ══════════════════════════════════════════════════════════════════════
  group('R97-AHS 权限发布失败后的可见提示', () {
    late RcAssistHost host;
    late _ThrowingTransport bus;

    setUp(() {
      host = RcAssistHost();
      bus = _ThrowingTransport();
      host
        ..bind(bus)
        ..endpointName = '端点-测试机';
    });

    tearDown(() async {
      await host.close(silent: true);
    });

    testWidgets('R97-AHS-01 拨开关但发布失败 → 提示「权限未生效」且开关回退（233）',
        (tester) async {
      // 真实异步区生成会话 + 完成 hello 握手（PBKDF2 在隔离区跑，
      // fake zone 里 `await` 永不恢复 —— 见 assist_host_screen_test 的注释）。
      final s = (await tester.runAsync(() => host.start()))!;
      final ctlKey =
          (await tester.runAsync(() => RcAssist.ctlKey(s.code, s.password)))!;
      await tester.runAsync(() async {
        await host.onWire(await RcCodec.encode(
            RcMessage.now(RcAssistCmd.hello, {'ctrlName': '小李的手机'}),
            ctlKey,
            s.topic));
      });
      expect(s.phase, AssistPhase.active, reason: '前置自证：会话已激活，权限开关才会出现');

      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: AssistHostScreen(host: host)));
      await tester.pump();
      expect(find.byType(SwitchListTile), findsNWidgets(AssistPerms.labels.length));

      // 握手已完成 ⇒ 从这里开始所有发布都失败（模拟"连接断了"）。
      bus.failPublish = true;

      await tester.tap(find.widgetWithText(SwitchListTile, '播放音效'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('权限未生效：通知控制端失败，请检查连接后重试'), findsOneWidget,
          reason: '★ 233：发布失败必须说出来 —— 开关悄悄弹回会让人以为"点坏了"');
      expect(s.perms.media, isFalse,
          reason: '发布失败必须回退本地权限位（R90-17：先发布、成功后才改本地）');

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  // ══════════════════════════════════════════════════════════════════════
  // R97-RCT · remote_console_tab.dart:1341
  //
  // `_field()` 里 Slider 的 `onChanged`。r96 GAP-11b 用
  // `find.byType(Slider).first` 驱动，命中的其实是**页面本体**的音量滑块
  // （remote_console_tab.dart:895，在对话框之下先入树）⇒ 1341 一直为 0。
  // 本用例把 finder 限定在 `AlertDialog` 子树内。
  // ══════════════════════════════════════════════════════════════════════
  group('R97-RCT 振动参数对话框的滑块回调', () {
    testWidgets('R97-RCT-01 拖动对话框内的参数滑块 → 值真的写回（1341）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance();
      final ch = _FakeChannel();

      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: RemoteConsoleTab(channel: ch)),
        ),
      ));
      await _frames(tester, 6);

      final btn = find.widgetWithText(OutlinedButton, '发送振动');
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await _frames(tester, 8);
      expect(find.byType(AlertDialog), findsOneWidget,
          reason: '前置自证：参数对话框真的打开了');

      final sliders = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(Slider));
      // fixed 模式两个字段：时长 + 强度（rcVibrateStartFixedFields）。
      expect(sliders, findsNWidgets(2));

      final before = tester.widget<Slider>(sliders.first);
      final target = before.value == before.max ? before.min : before.max;
      // 直接驱动真实回调（断言的是回调里的业务逻辑，不是手势命中）。
      before.onChanged!(target);
      await tester.pump();
      await tester.pump();

      expect(tester.widget<Slider>(sliders.first).value, target,
          reason: '★ 1341：`onChanged` 必须把值写回 `_v` 并触发重建（拖了不能等于没拖）');
      expect(find.textContaining('时长（秒）：'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  // ══════════════════════════════════════════════════════════════════════
  // R97-PQ · pair_qr_screen.dart:157
  //
  // `const PairQrScreen({super.key});` —— **构造器声明行**。
  // 既有 `pair_qr_screen_test.dart:_pump` 与 r96 GAP-19 都写 `const PairQrScreen()`：
  // `const` 表达式在编译期折叠成常量引用，**不产生运行期调用** ⇒ 该行恒为 0
  // （同仓反证：`action.dart:238` 等被非 const 调用的 const 构造器行都是命中）。
  // 本用例去掉 `const`，页面被真正构造 + 渲染。
  // ══════════════════════════════════════════════════════════════════════
  group('R97-PQ 扫码配对页构造器', () {
    testWidgets('R97-PQ-01 非 const 构造并渲染（157）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance();

      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // ⚠️ 不能写成 `const ProviderScope(child: MaterialApp(home: PairQrScreen()))`
      // —— 那会把构造器折叠掉，正是 157 恒为 0 的原因。
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: PairQrScreen(key: UniqueKey())),
      ));
      await tester.pumpAndSettle();

      expect(find.text('扫码配对'), findsWidgets,
          reason: '页面真的被构造并渲染（构造器行的运行期调用就是本用例的驱动点）');
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '身份生成完还转圈 ⇒ 卡在加载态');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  // ══════════════════════════════════════════════════════════════════════
  // R97-CSC · call_screen.dart:138
  //
  // `CallService.bindStore(() async => RemoteStore(await SharedPreferences…))`
  // 里那个**注入闭包**。137 行（调用点）早已覆盖，138 行（闭包体）要等
  // `CallService._storeRef` 真的被 call 一次 —— `_sendEndSignal` / `acceptPending`
  // / `declinePending` / `_sendLocalCandidate` 四处。这里用 `declinePending()`
  // （它第一件事就是 `await _storeRef?.call()`，随后因 `_phase != ringing` 立即返回）。
  // ══════════════════════════════════════════════════════════════════════
  group('R97-CSC 主叫注入的 store 闭包被真正调用', () {
    testWidgets('R97-CSC-01 发起语音呼叫后 CallService 取 store → 闭包体执行（138）',
        (tester) async {
      SharedPreferences.setMockInitialValues({'rc_call_auto_answer': false});
      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.addPaired(PairedEndpoint(
        deviceId: '0123456789abcdef',
        name: '客厅平板',
        secret: 'AB2CD5EF',
        pairedAt: DateTime(2026, 10, 1),
      ));

      stubPermissions({
        Permission.microphone: PermissionStatus.granted,
        Permission.camera: PermissionStatus.denied,
      });
      _messenger.setMockMethodCallHandler(
          const MethodChannel('sonic_shield/native'), (call) async => null);
      _messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'), (call) async => null);
      _messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'), (call) async => null);
      addTearDown(() {
        clearPermissionStub();
        _messenger.setMockMethodCallHandler(
            const MethodChannel('sonic_shield/native'), null);
        _messenger.setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Method'), null);
        _messenger.setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Event'), null);
      });

      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: const CallScreen(),
        ),
      ));
      await tester.pumpAndSettle();

      // 语音呼叫：麦克风已授 ⇒ 越过 `callStartBlockFor`，执行到 137 行
      // `CallService.bindStore(...)`；宿主无 WebRTC ⇒ `startCall` 返回 null。
      await tester.tap(find.text('语音呼叫'));
      await tester.pumpAndSettle();
      // 前置自证：确实越过了权限门禁、走进了 startCall（bindStore 就在它上面两行）。
      // 不写死"媒体失败"的具体文案 —— 那属于 `call_lifecycle` 的措辞，
      // 本用例只需证明链路走到了 137 行。
      expect(find.byType(SnackBar), findsOneWidget,
          reason: '前置自证：点击后进入了发起流程并给出了失败原因');
      expect(find.textContaining('需要麦克风权限'), findsNothing,
          reason: '麦克风已授 ⇒ 不得停在权限门禁（那样 bindStore 根本不会执行）');
      expect(find.textContaining('请先选择一个端点'), findsNothing,
          reason: '已预选配对端点 ⇒ 不得停在目标校验');

      // ★ 让 `_storeRef` 被调用一次 ⇒ 138 行的闭包体执行。
      await CallService.instance.declinePending();
      await tester.pump();
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

// ══════════════════════════════════════════════════════════════════════════
// 不可达登记（本组 19 行里 10 行结构上无法被任何输入点亮，逐条给证据）
//
// ① dashboard_screen.dart:300/314 —— **条件可达**（已由 R97-AD-01 处理）：
//    `switch (mode) { auto => paused ? …300… : … }` 与 `tone` 三元
//    （310-314）都要求 `RunPause.paused(auto, DateTime.now()) == false`；
//    `build` 直接读墙钟（294 行 `final now = DateTime.now();`），仓库无时钟缝，
//    故 20:00–21:00 前后无法点亮。**非暂停窗口内**由 R97-AD-01 覆盖。
//
// ② theme.dart:14 / native_bridge.dart:25 / json_list_codec.dart:57 /
//    export_crypto.dart:10 —— 四个 `Xxx._();` **私有命名构造器**。
//    全仓 `grep 'AppTheme\._'` 等 0 命中，类只以静态成员使用；私有构造器
//    在 `lib/` 外不可调用 ⇒ 无任何运行期调用点（改 lib 才可能覆盖）。
//
// ③ app_database.dart:93 `throw StateError('unreachable');` ——
//    `open()` 的 `for (var i = 0; i < attempts; i++)`（53 行，`attempts = 3`）
//    循环体只有两条出口：54-86 成功 `return`，或 87-90 的
//    `if (i == attempts - 1 || !_isLockedError(e)) rethrow;`（最后一轮必 rethrow）。
//    非 `DatabaseException` 直接穿透。⇒ 循环后不可达（这正是它被命名 unreachable 的原因）。
//
// ④ remote_scripts_tab.dart:239/240 与 ptt_tab.dart:100 —— 同一形状：
//    「`_selectedId` 非空但 `endpointById(_endpoints, _selectedId) == null`」。
//    * `_selectedId` 只在两处赋值：`_load()` 的
//      `initialSelectedId(_endpoints, persisted)`（remote_store.dart:149-155：
//      配对表为空 ⇒ `''`；否则必定是**配对表里某个 deviceId**），以及端点下拉的
//      `onChanged`（ptt_tab.dart:168 / remote_scripts_tab.dart:318，取值来自
//      `items:` 里由 `_endpoints` 生成的 `deviceId`）；
//    * `_endpoints` 只在 `_load()` 里赋值，且与 `_selectedId` 写在**同一个
//      `setState` 同步段**（ptt_tab.dart:75-79 / remote_scripts_tab.dart:207-212）。
//    ⇒ 非空 `_selectedId` 必存在于同一份快照里，`endpointById` 不可能返回 null。
//    旁证：remote_scripts_tab 若真出现"选中值不在 items 里"，`DropdownButton`
//    会直接 assert 崩溃（r96 GAP-09 组注释已实测记录），该状态连 UI 都构建不出来。
//
// ⑤ remote_screen.dart:154（`_speedTest` 的 `on Object` 兜底）——
//    try 块里只有两个 await：`NodeSpeedTest.probeMqtt` / `probeStun`。
//    两者的每个节点都在 `connectLatency` / `stunLatency` 的
//    `try { … } on Object { return null; }` 内（node_catalog.dart:122-130 / 158-186），
//    `Future.wait` 的 `.then` 只做 `NodeProbe(id, ms)` 构造 ⇒ 不会以错误完成；
//    其余语句是纯赋值。唯一可能抛的是 148 行 `setState`，而它前面 147 行
//    `if (!mounted) return;` 与它处于**同一同步段**（无 await 间隔）⇒ 不可中断。
//    ⇒ catch 分支无输入可触发。
//
// ⑥ assist_join_screen.dart:302（审计面板空态 `const Padding(`）——
//    `_AuditSheet` 只在 `_showAudit()`（assist_join_screen.dart:264-270）里挂载，
//    入口按钮位于 `_console()`（只当 `info.active` 时渲染，51-53 / 199-203）。
//    而 `AssistPhase.active` 只在 `assist_join.dart:441` 被置位，紧接 442 行
//    **无条件** `_record(accept)`；`_audit.clear()`（238）只发生在 `join()` 开头，
//    之后 `send(hello)` 又必然 `_record`（350）。⇒ 面板可见时 `auditLog.length >= 2`，
//    `if (log.isEmpty)` 恒假。（lcov 也印证：301 行命中 1 次而 302 恒 0。）
// ══════════════════════════════════════════════════════════════════════════

// ─────────────────────────── 夹具 ───────────────────────────

/// 内存版音源仓储（照抄 `sound_library_screen_test.dart` 的同名替身）。
class _FakeRepo implements AssetRepository {
  _FakeRepo([List<AudioAsset>? seed]) : items = [...?seed];

  final List<AudioAsset> items;

  /// 非 null 时 `upsertMany` 抛出它（模拟写库失败）。
  Object? failOnSaveAll;

  int saveAllCalls = 0;

  @override
  Future<List<AudioAsset>> listAll() async => List.of(items);

  @override
  Future<Set<String>> nameSet() async => items.map((a) => a.name).toSet();

  @override
  Future<void> upsert(AudioAsset a) async {
    items.removeWhere((x) => x.id == a.id);
    items.add(a);
  }

  @override
  Future<void> upsertMany(Iterable<AudioAsset> batch) async {
    saveAllCalls++;
    final f = failOnSaveAll;
    if (f != null) throw f;
    for (final a in batch) {
      items.removeWhere((x) => x.id == a.id);
      items.add(a);
    }
  }

  @override
  Future<void> delete(String id) async {
    items.removeWhere((x) => x.id == id);
  }

  @override
  Future<({int inserted, int skipped})> insertMissingByName(
      Iterable<AudioAsset> batch) async {
    final present = items.map((a) => a.name).toSet();
    final seen = <String>{};
    var inserted = 0;
    var skipped = 0;
    for (final a in batch) {
      if (present.contains(a.name) || !seen.add(a.name)) {
        skipped++;
        continue;
      }
      items.add(a);
      seen.add(a.name);
      inserted++;
    }
    return (inserted: inserted, skipped: skipped);
  }
}

/// 假播放器（`extends` 而非 `implements`：基类新增成员不会让本替身编译失败）。
class _FakePlayer extends PlaybackService {
  @override
  Future<PlayResult> play({
    required String path,
    required AudioChannel channel,
    required double volume,
    required int maxDurationMs,
    int fadeInMs = 0,
    int fadeOutMs = 0,
    int rampUpMs = 0,
    bool loopFill = false,
    PlayPriority priority = PlayPriority.normal,
  }) async =>
      const PlayResult(ok: true, playedMs: 10);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// 发布即抛的协助传输（只用于"权限发布失败"这一条分支）。
class _ThrowingTransport implements AssistTransport {
  bool failPublish = false;

  @override
  Future<void> subscribe(String topic) async {}

  @override
  Future<void> unsubscribe(String topic) async {}

  @override
  Future<void> publishWire(String topic, String wire) async {
    if (failPublish) throw StateError('网络中断（R97 夹具）');
  }
}

/// 假命令通道（与 `remote_console_tab_test.dart` 同形）。
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
}
