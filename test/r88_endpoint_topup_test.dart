/// 第八十八轮：`lib/remote/endpoint_service.dart` 长尾补测（R88E-01…20）。
///
/// 目标文件 4468 行，R87 lcov 仅剩 51 行未覆盖 —— 本文件逐条驱动那些
/// **真实可达但此前没有用例走到**的分支：协助会话路由、撤销清场挂断、
/// 传输端口切换、默认 MQTT 客户端构造、心跳体、任务开关的失败回执、
/// 电池快照、守卫远程开关、TTS 截断/未发声、录音停止未确认、outbox 溢出。
///
/// ## 驱动方式
///
/// - 入站命令走既有 `@visibleForTesting` 接缝 `debugDispatch` / `debugHandleRaw`
///   （与 `endpoint_inbound_raw_test.dart` / `endpoint_script_run_test.dart` 同源）；
/// - 传输层用 `test/support/mqtt_client_stub.dart` 的实例注入型替身；
/// - 录音用 `test/support/record_stub.dart` 的平台层替身（本文件另加
///   "stop 抛错"的子类，不修改 support 目录）；
/// - 电池用 `battery_plus_platform_interface` 的平台层替身。
///
/// 全部走**真** `RcCodec`（真 HKDF / AES-GCM），回执都用对端密钥解回来断言，
/// 不接受"数条数"的假绿。
///
/// ## 结构性不可达（如实标注，未硬凑）
///
/// - **2641-2642**：`delay` 步的 `cancel?.sleep(...) ?? Future.delayed(...)`。
///   `runner` 只由 `RcScriptExecutor.run` 调用，而 `run` 在进入步骤循环前
///   必定先 `_cancel = RcCancel()`；执行期间 `activeCancel` 恒非空 ⇒ `??`
///   右侧是死分支。
/// - **2741 / 2745-2746**：`run()` 之后那道 `if (!isRunning)` 兜底。
///   `RcScriptExecutor.run` 只在 `isRunning == true` 时返回 false，而
///   `_current` 只在后续 `await` 之后才清空；从调用到该判断之间没有 `await`
///   ⇒ 判断恒为假。
/// - **3268**：`_rememberCmdTs` 的硬上限 `while (length > 200)`。
///   同一发送方 60s 窗口内最多放行 `rcRateLimitMaxPerWindow = 30` 条，
///   且每次记录先裁掉出窗条目 ⇒ 列表长度永远到不了 200。
/// - **3518-3520**：`flushOutbox` 里 `prepareOutboxReplay == null` 的兜底。
///   它与前一步 `peekOutboxType` 使用**完全相同**的解密参数（同 key / 同 topic /
///   同 3650 天时间窗）；peek 成功即必然能解，prepare 不可能返回 null。
library;

import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages -- battery_plus 的传递依赖，平台层替身必须用它的接口
import 'package:battery_plus_platform_interface/battery_plus_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/assist_join.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/node_catalog.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/remote/script_executor.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

import 'support/mqtt_client_stub.dart';
import 'support/record_stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const ownId = 'EP88own000000abc';
  const ctrlId = 'CTRL88peer000001';
  const brokerName = 'broker.round88.invalid';
  // 出站队列硬上限（P2-21）。真源 = lib/remote/remote_store.dart:564
  // `static const int maxOutboxEntries = 200;`；此处用字面量是因为该常量在
  // analyzer 视角下不属于 `RemoteStore`（`RemoteStore.maxOutboxEntries` 会报
  // undefined_getter，而 `RemoteStore.outboxFor` 正常），跨类引用会编译失败。
  // ⇒ 若 lib 侧改了 200 这个值，本用例必须同步（已在 R88 审计项里登记）。
  const maxOutboxEntries = 200;
  const notifChannel = 'dexterous.com/flutter/local_notifications';
  const pathProviderChannel = 'plugins.flutter.io/path_provider';

  final svc = RcEndpointService.instance;

  late SharedPreferences prefs;
  late RemoteStore store;
  late KdfSaltStore salts;
  late AppDatabase db;
  late FakeMqttServerClient fake;
  late PairedEndpoint peer;
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('ss_round88');

    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    await store.setIdentity(ownId, '端点机88');
    await store.setBroker(brokerName);
    await store.ensurePairingCode();
    salts = KdfSaltStore(prefs);
    db = await AppDatabase.open(inMemoryDatabasePath);
    peer = PairedEndpoint(
      deviceId: ctrlId,
      name: '控制端88',
      secret: 'CODE8801',
      pairedAt: DateTime(2024, 1, 1),
    );
    await store.addPaired(peer);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(notifChannel),
            (call) async {
      return call.method == 'initialize' ? true : null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(pathProviderChannel),
            (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tmpDir.path;
      }
      return null;
    });

    fake = FakeMqttServerClient(brokerName, ownId);
    svc.debugBind(store: store, db: db, saltStore: salts);
    svc.debugSetOwnCode(store.pairingCode);
    svc.debugClientFactory = (broker, clientId, port) => fake;
  });

  tearDown(() async {
    if (CallService.instance.inCall) {
      await CallService.instance.hangUp(store);
    }
    // 用例可能故意把审计替换成"必抛"版本（R88E-06）：先恢复，
    // 否则 stop() 收尾协助会话时会再次抛出，掩盖真正的断言失败。
    RcAssistHost.instance.audit = (action, status, message) async {};
    await svc.stop();
    svc.debugClientFactory = null;
    svc.debugSendTo = null;
    svc.debugSetOwnCode('');
    svc.playHandler = null;
    svc.ttsHandler = null;
    svc.vibrateHandler = null;
    svc.vibrateActionHandler = null;
    svc.resolvePresetHandler = null;
    RcScriptExecutor.instance.stop();
    BackgroundServiceManager.lastForTest = null;
    BackgroundServiceManager.invokeHook = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(notifChannel), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(pathProviderChannel), null);
    try {
      await tmpDir.delete(recursive: true);
    } on Object {
      // Windows 句柄释放可能滞后：清不掉就留给系统临时目录。
    }
    try {
      await db.close();
    } on Object {
      // 在飞的终态通知计时器可能已把库关掉。
    }
  });

  /// 有界条件轮询（项目铁律：禁止把 `pumpAndSettle` 当"等数据"用）。
  Future<void> until(bool Function() cond, String why,
      {int maxMs = 8000}) async {
    final sw = Stopwatch()..start();
    while (!cond()) {
      if (sw.elapsedMilliseconds > maxMs) {
        fail('waitFor 超时（${maxMs}ms）：$why');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<List<Map<String, Object?>>> logs() =>
      LogRepository(db).recent(limit: 500);

  Future<int> countLogs(
      {String? action, String? status, String? contains}) async {
    final rows = await logs();
    return rows.where((r) {
      if (action != null && r['action'] != action) return false;
      if (status != null && r['status'] != status) return false;
      if (contains != null &&
          !(r['message'] as String? ?? '').contains(contains)) {
        return false;
      }
      return true;
    }).length;
  }

  /// 用对端密钥把端点**刚发出的最后一条**事件解回来。
  Future<RcMessage?> unsealLastEvt() async {
    final out = fake.sentWires.last;
    final key = await RcCodec.deriveKey(
        peer.secret, '${peer.deviceId}|evt',
        salt: salts.saltFor(peer.deviceId));
    return RcCodec.decode(out.wire, key, out.topic);
  }

  RcScript script(List<RcStep> steps, String id) => RcScript(
        scriptId: id,
        name: 'R88 宏',
        fromName: '控制端88',
        sentAt: 1700000000000,
        steps: steps,
      );

  // ═══════════════════════════════════════ A · 协助会话与撤销清场

  group('R88E-A 协助会话 / 撤销清场', () {
    test('R88E-01 无协助会话时 _assistPeer 回落「协助控制端」（460）', () async {
      await svc.start(store, db);
      await RcAssistHost.instance.close(silent: true);

      final onCommand = RcAssistHost.instance.onCommand;
      expect(onCommand, isNotNull, reason: 'start() 必须装配协助命令入口');
      await onCommand!(
          RcMessage.now(RcCmd.taskToggle, {
        'taskId': 'no-such-task-88e01',
        'enabled': true,
      }));

      // 任务不存在的审计里带着 peer.name —— 会话为空时必须是兜底文案，
      // 不能是空串（空名字会让"谁下的命令"从日志里消失）。
      expect(
          await countLogs(
              action: 'task.toggle',
              status: 'failed',
              contains: '协助控制端'),
          1);
    });

    test('R88E-02 onPeerRevoked 撤销在途通话：store 非空 ⇒ 真挂断（548-549）',
        () async {
      svc.debugSendTo = (endpoint, msg, st, enqueueOnFail) async => true;

      final ringing = await CallService.instance.onIncomingCall(
          {'callId': 'call-88e02', 'video': false}, peer, store);
      expect(ringing, isTrue, reason: '前提：必须真的进入振铃态');
      expect(CallService.instance.peerDeviceId, ctrlId);
      expect(CallService.instance.inCall, isTrue);

      await svc.onPeerRevoked(ctrlId);

      expect(CallService.instance.inCall, isFalse,
          reason: '撤销配对必须立即挂断该设备的通话，而不是等它自然结束');
      expect(
          await countLogs(
              action: 'pair.revoke', status: 'success', contains: '通话'),
          1,
          reason: '清场必须如实记账"停掉了什么"');
    });

    test('R88E-03 传输方案 wss ⇒ _effectivePort 取 8084（572）', () async {
      await store.setTransport(RcTransport.wss);
      await svc.start(store, db);

      expect(fake.port, RcTransport.wss.defaultPort,
          reason: 'WSS 必须走 8084，而不是 TLS 的 8883');
    });

    test('R88E-04 传输方案 quic ⇒ 回落 TLS 端口（573）', () async {
      await store.setTransport(RcTransport.quic);
      await svc.start(store, db);

      expect(fake.port, RemoteStore.defaultBrokerPort,
          reason: '当前库不支持 QUIC ⇒ 必须回落 TLS 端口，不能留 14567');
    });

    test('R88E-05 未注入客户端工厂 ⇒ 走默认 withPort 构造（610-611）', () async {
      svc.debugClientFactory = null;
      // 本机回环 + 未监听端口：连接立刻被拒，不会真的握手到公网 broker。
      await store.setBrokerAdvanced(host: '127.0.0.1', port: 1);

      await svc.start(store, db);

      expect(svc.connState.phase, RcConnPhase.retrying,
          reason: '默认构造的客户端连不上也必须进入退避重连，而不是崩掉');
      expect(svc.connState.lastError, isNotEmpty,
          reason: '失败原因必须可见（UI 靠它提示"网络异常"）');
    });
  });

  // ═══════════════════════════════════════ B · 入站监听与心跳

  group('R88E-B 入站监听 / 心跳', () {
    test('R88E-06 入站处理器抛错被监听器兜底吞掉并打印（686）', () async {
      await svc.start(store, db);
      final session = await RcAssistHost.instance.start();

      // 让协助握手失败的审计抛错 ⇒ 异常会穿出 onWire → _handleRaw，
      // 落到 client.updates 监听器的最后一道 try/catch（print 兜底）。
      RcAssistHost.instance.audit =
          (action, status, message) async => throw StateError('audit down');

      await fake.emit(session.topic, 'r88e06-not-a-wire');
      await until(() => session.failures == 1, '失败计数应在审计抛错前已递增');

      expect(session.failures, 1,
          reason: '异常被监听器吞掉，但业务侧的失败计数必须已经生效');
      RcAssistHost.instance.audit = (action, status, message) async {};
    });

    testWidgets('R88E-07 心跳体：连接态补订+补发+心跳；断连后自取消（739-750）',
        (tester) async {
      await svc.start(store, db);
      expect(svc.connState.phase, RcConnPhase.online);

      final sentBefore = fake.sentWires.length;
      fake.subscribed.clear();

      await tester.pump(const Duration(seconds: 61));
      await tester.pump();

      expect(fake.subscribed, contains('sonicshield/v1/$ownId/cmd'),
          reason: '心跳必须顺带补齐订阅（新增配对后无需重连）');
      expect(fake.sentWires.length, sentBefore + 1,
          reason: '心跳体必须真的发出一条 rc.heartbeat');
      final beat = await unsealLastEvt();
      expect(beat?.type, RcEvt.heartbeat);

      // 断连后心跳体走 `t.cancel(); return;` 分支，不再发任何东西。
      fake.disconnect();
      final afterCancel = fake.sentWires.length;
      await tester.pump(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 120));

      expect(fake.sentWires.length, afterCancel,
          reason: '断连后心跳必须自毁，不能继续对空气发送');

      await svc.stop();
    });

    test('R88E-08 控制端接入会话中 refreshSubscriptions 补订会合主题（781）',
        () async {
      await svc.start(store, db);
      await RcAssistHost.instance.close(silent: true);

      final join = AssistJoinClient.instance;
      // REM-04：访问密码 **12 位**（Crockford 字母表）。旧 8 位夹具会在
      // join() 的格式校验处直接失败（_topic 永不算出来）⇒ 下面这句 until
      // 只会干等 8 秒超时，把"夹具过期"伪装成"派生挂起"。
      final joining = join.join('123456789', 'ABCDEFGHJKMN',
          timeout: const Duration(seconds: 2));
      await until(() => join.topic.isNotEmpty, 'join 应先算出会合主题');
      final topic = join.topic;
      // 先等 join 自己那次 subscribe 落定，再清空 —— 否则它迟到的订阅
      // 会把 refreshSubscriptions 的缺失掩盖成假绿。
      await until(
          () => fake.subscribed.contains(topic), 'join 自身订阅会合主题');

      fake.subscribed.clear();
      await svc.refreshSubscriptions();

      expect(fake.subscribed, contains(topic),
          reason: '重连/心跳补订必须覆盖控制端侧的会合主题，否则握手回执静默丢失');

      await joining;
    });

    test('R88E-09 协助会合主题按 Host 会话精确路由（835）', () async {
      await svc.start(store, db);
      final session = await RcAssistHost.instance.start();

      await svc.debugHandleRaw(session.topic, 'r88e09-not-a-wire');

      expect(session.failures, 1,
          reason: '主题命中 Host 会话 ⇒ 必须交给 Host.onWire（失败计数 +1）');
      expect(
          await countLogs(
              action: 'assist.handshake', status: 'skipped', contains: '密文校验失败'),
          1);
    });

    test('R88E-10 协助会合主题按 Join 会话精确路由（837）', () async {
      await svc.start(store, db);
      await RcAssistHost.instance.close(silent: true);

      final join = AssistJoinClient.instance;
      // REM-04：访问密码 **12 位**（Crockford 字母表）。旧 8 位夹具会在
      // join() 的格式校验处直接失败（_topic 永不算出来）⇒ 下面这句 until
      // 只会干等 8 秒超时，把"夹具过期"伪装成"派生挂起"。
      final joining = join.join('123456789', 'ABCDEFGHJKMN',
          timeout: const Duration(seconds: 2));
      await until(() => join.topic.isNotEmpty, 'join 应先算出会合主题');
      final topic = join.topic;

      // Host 侧审计换成探针：若误投给 Host，它会拿 ctlKey 解别人的报文并
      // 记一次握手失败 —— 那正是「误锁死自己的会话」的形状。
      final hostAudits = <String>[];
      RcAssistHost.instance.audit = (action, status, message) async {
        hostAudits.add('$action/$status');
      };

      await svc.debugHandleRaw(topic, 'r88e10-not-a-wire');

      expect(RcAssistHost.instance.session, isNull,
          reason: '前提：本机此刻没有托管会话，主题只能属于 Join 侧');
      expect(hostAudits, isEmpty,
          reason: '命中 Join 会话 ⇒ 不得落到 Host.onWire（否则握手失败计数被污染）');
      expect(join.phase, AssistPhase.opening,
          reason: '噪声报文只应被 Join 静默丢弃，不得改变接入相位');
      await joining;
    });
  });

  // ═══════════════════════════════════════ C · 命令处理长尾

  group('R88E-C 命令处理长尾', () {
    test('R88E-11 taskToggle 的 enabled 非布尔 ⇒ 显式失败回执（1203）', () async {
      await svc.start(store, db);
      await svc.debugDispatch(
          RcMessage.now(RcCmd.taskToggle, {
            'taskId': 't-88e11',
            'enabled': 'maybe',
          }),
          peer);

      final ack = await unsealLastEvt();
      expect(ack?.type, RcEvt.ack);
      expect(ack?.payload['ok'], isFalse);
      expect(ack?.payload['data'], 'enabled 必须是布尔（true/false/1/0）',
          reason: '读不懂就显式失败，绝不猜一个默认值（方向翻转比报错更贵）');
      expect(await countLogs(action: 'task.toggle'), 0,
          reason: '参数非法不得落到真正的开关逻辑');
    });

    test('R88E-12 taskToggle 任务不存在 ⇒ 失败回执 + failed 审计（1215-1221）',
        () async {
      await svc.start(store, db);
      await svc.debugDispatch(
          RcMessage.now(RcCmd.taskToggle, {
            'taskId': 'ghost-88e12',
            'enabled': true,
          }),
          peer);

      final ack = await unsealLastEvt();
      expect(ack?.payload['ok'], isFalse);
      expect(ack?.payload['data'], contains('任务不存在'));
      expect(
          await countLogs(
              action: 'task.toggle', status: 'failed', contains: '任务不存在'),
          1,
          reason: '0 行 update 静默成功是旧缺陷：必须显式失败并留痕');
    });

    test('R88E-13 已撤销设备重新配对 ⇒ 拒绝登记并留痕（1751-1757）', () async {
      await store.revoke(ctrlId);

      await svc.debugDispatch(
          RcMessage.now(RcCmd.pairRequest, {
            'deviceId': ctrlId,
            'code': 'CODE8801',
            'name': '撤销后重试',
          }),
          peer);

      expect(
          await countLogs(
              action: 'pair.request',
              status: 'failed',
              contains: '已被本机撤销授权'),
          1,
          reason: '撤销名单是比配对握手更强的否决：换 from 也登记不回来');
      expect(await countLogs(action: 'pair.request', status: 'success'), 0);
    });

    test('R88E-14 device.status 读电池：充电态与电量进入回执（2176-2177）',
        () async {
      final savedBattery = BatteryPlatform.instance;
      BatteryPlatform.instance =
          _FakeBatteryPlatform(level: 77, state: BatteryState.charging);
      addTearDown(() => BatteryPlatform.instance = savedBattery);

      await svc.start(store, db);
      await svc.debugDispatch(RcMessage.now(RcCmd.deviceStatus, {}), peer);
      await until(() => fake.sentWires.isNotEmpty, 'rc.device 回执投出');

      final evt = await unsealLastEvt();
      expect(evt?.type, RcEvt.device);
      expect(evt?.payload['batteryLevel'], 77,
          reason: '电量必须来自平台真实读数，不是恒 -1');
      expect(evt?.payload['charging'], isTrue,
          reason: 'charging / full 都必须算"正在充电"');
    });

    test('R88E-15 默认 locationFix 真走 Geolocator（宿主无插件 ⇒ 抛错）（2294-2295）',
        () async {
      // 默认 seam 是 `_systemLocationFix`；宿主没有 geolocator 平台实现，
      // 该调用必须以异常结束（而不是悄悄返回一个假坐标）。
      // `Future.sync` 兜住"同步抛"与"异步抛"两种形状。
      await expectLater(
        Future<Object?>.sync(() => svc.locationFix()),
        throwsA(anything),
        reason: '默认实现必须真的尝试取位置；能返回坐标反而说明被替身短路了',
      );
    });

    test('R88E-16 guard.set 引擎在跑 ⇒ 真调 setGuard + 等回投（2356-2357）',
        () async {
      BackgroundServiceManager.lastForTest =
          const EngineState(running: true, pendingCount: 0, guardActive: true);
      BackgroundServiceManager.invokeHook = (method, args) async {};

      await svc.debugDispatch(
          RcMessage.now(RcCmd.guardSet, {'enabled': true}), peer);

      expect(await countLogs(action: 'guard.set', status: 'success'), 1,
          reason: '引擎在跑时必须走 setGuard + waitForGuardActive，'
              '并按真实观察结果回执');
    });
  });

  // ═══════════════════════════════════════ D · 指令组步骤长尾

  group('R88E-D 指令组步骤', () {
    test('R88E-17 tts voiceId 超长被截到 64（2689）', () async {
      final voices = <String>[];
      svc.ttsHandler = (text, volume, {String voiceId = ''}) async {
        voices.add(voiceId);
        return true;
      };

      final longId = 'v' * 70;
      await svc.debugDispatch(
          RcMessage.now(RcCmd.scriptRun,
              script([
                RcStep(RcStepKind.tts, {'text': '你好', 'voiceId': longId}),
              ], 'sc-88e17')
                  .toJson()),
          peer);

      expect(voices, hasLength(1));
      expect(voices.single.length, 64,
          reason: '入站 voiceId 不可信：必须夹紧长度，不能把超长串透传下去');
      expect(voices.single, 'v' * 64);
    });

    test('R88E-18 tts 未发声 ⇒ failed 审计且原因可读（2693-2698）', () async {
      svc.ttsHandler = (text, volume, {String voiceId = ''}) async => false;

      await svc.debugDispatch(
          RcMessage.now(RcCmd.scriptRun,
              script([
                const RcStep(RcStepKind.tts, {'text': '把门关好'}),
              ], 'sc-88e18')
                  .toJson()),
          peer);

      expect(
          await countLogs(
              action: 'script.run',
              status: 'failed',
              contains: '（tts）未发声'),
          1,
          reason: '能力层说没出声就必须如实记账，不能只回 state:done');
    });

    test('R88E-19 record 停止未获确认 ⇒ failed 留痕并写明文件可能仍在写入（2868-2874）',
        () async {
      final savedRecord = RecordPlatform.instance;
      RecordPlatform.instance = _StopThrowsRecorder();
      addTearDown(() => RecordPlatform.instance = savedRecord);

      await svc.debugDispatch(
          RcMessage.now(RcCmd.scriptRun,
              script([
                const RcStep(RcStepKind.record, {'seconds': 1}),
              ], 'sc-88e19')
                  .toJson()),
          peer);

      expect(
          await countLogs(
              action: 'record', status: 'failed', contains: '未获确认'),
          1,
          reason: '点了停却停不掉是最严重的形状：必须让使用者看见');
      expect(await countLogs(action: 'record', status: 'success'), 0);
    });
  });

  // ═══════════════════════════════════════ E · 出站队列

  group('R88E-E 出站队列', () {
    test('R88E-20 sendTo 离线且 outbox 已满 ⇒ 丢弃最旧一条并留痕（3380-3383）',
        () async {
      await prefs.setString(
          'rc_outbox',
          jsonEncode([
            for (var i = 0; i < maxOutboxEntries; i++)
              {
                'id': 'o$i',
                'endpointId': ctrlId,
                'wire': 'w$i',
                'at': 1,
              }
          ]));

      final ok =
          await svc.sendTo(peer, RcMessage.now(RcCmd.ping, {}), store);

      expect(ok, isFalse, reason: '未连接 ⇒ 只能入队，不能假装已送达');
      expect(store.outboxFor(ctrlId), hasLength(maxOutboxEntries),
          reason: '队列必须维持硬上限，不能无限增长');
      expect(store.outboxFor(ctrlId).first['id'], 'o1',
          reason: '被挤掉的必须是最旧一条（o0）');
      expect(
          await countLogs(
              action: 'outbox.drop', status: 'failed', contains: '出站队列超限'),
          1,
          reason: '丢弃必须留痕，否则"命令没执行"无从追查');
    });
  });
}

/// 可编程电池平台（battery_plus 6.x 平台接口整体替换）。
class _FakeBatteryPlatform extends BatteryPlatform {
  _FakeBatteryPlatform({required this.level, required this.state});

  final int level;
  final BatteryState state;

  @override
  Future<int> get batteryLevel async => level;

  @override
  Future<BatteryState> get batteryState async => state;

  @override
  Future<bool> get isInBatterySaveMode async => false;

  @override
  Stream<BatteryState> get onBatteryStateChanged => const Stream.empty();
}

/// 录音平台替身：`stop()` 必抛 —— 驱动"已请求停止但未获确认"的终态。
///
/// 只覆写平台返回值，不替生产代码做任何判断；其余行为沿用 support 里的
/// `FakeRecordPlatform`（真实调用序列仍被记录）。
class _StopThrowsRecorder extends FakeRecordPlatform {
  _StopThrowsRecorder() : super(hasPermissionResult: true);

  @override
  Future<String?> stop(String recorderId) async {
    calls.add('stop');
    throw Exception('停止录音未获确认');
  }
}
