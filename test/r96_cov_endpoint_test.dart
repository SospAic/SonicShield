/// 第九十六轮：`lib/remote/endpoint_service.dart` 覆盖率补测（COV-01…COV-11）。
///
/// 目标：R95 lcov 里该文件仍剩 59 行未覆盖（97.72% 门禁缺口的一部分）。
/// 本文件只挑**不依赖真实 broker / 真机**的分支：
/// v3 每控制端密钥的入站/出站、配对回执的 `pk` 落盘、明文垃圾的审计、
/// 投屏会话归属拒绝、远程停止类命令的回执形状、以及 outbox 补发判据的
/// 纯函数入口。
///
/// ## 驱动方式（与 r88/r94 同源，不新造 harness）
///
/// - 传输层：`test/support/mqtt_client_stub.dart` 的实例注入型替身；
/// - 入站：`debugHandleRaw`（等价于 broker 投递那一刻）/ `debugDispatch`
///   （等价于解密 + 准入 + 限流均通过之后）；
/// - 原生：只对投屏授权通道做**平台层替身**（返回 `true`），其余通道
///   保持"宿主无实现"，让生产代码走它自己的降级分支。
///
/// ## 如实标注：本轮确实到不了的行
///
/// - **3030-3031**：`delay` 步 `cancel?.sleep(...) ?? Future.delayed(...)`。
///   `runner` 只由 `RcScriptExecutor.run` 调用，进入步骤循环前必先
///   `_cancel = RcCancel()` ⇒ 右侧死分支。
/// - **3130-3135**：`run()` 之后 `if (!isRunning)`。`run()` 返回 false 的
///   唯一原因是 `_current != null`，而 `isRunning` 正是 `_current != null`，
///   且两步之间没有 `await` ⇒ 恒为假。
/// - **2852 / 2856**：`_stopVibrate` 的原生失败分支。`NativeBridge.vibrateStop`
///   走 `_invoke`，它把 `PlatformException` / `MissingPluginException` /
///   `TypeError` 全部折叠成 `null`（NAT-13 的既有契约）⇒ 永不抛出。
/// - **2876**：`_stopSound` 的 catch。`PlaybackService.stopAllPlaying()` 只
///   遍历登记表并 `await p.stop()`；宿主上无法构造"已登记且 stop 抛错"的
///   实例（`_playing` 是私有静态表，登记只发生在真实 `play()` 成功之后）。
/// - **3679**：`_rememberCmdTs` 的硬上限 `while`。窗口内最多放行
///   `rcRateLimitMaxPerWindow` 条，长度到不了上限。
/// - **3954-3956**：`flushOutbox` 的 `prepareOutboxReplay == null` 兜底。它与
///   前一步 `peekOutboxType` 用完全相同的解密参数，peek 成功即必然能解。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/playback_service.dart';
import 'package:sonic_shield/remote/script_executor.dart';

import 'support/mqtt_client_stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const ownId = 'EP96own0000000ab';
  const ctrlId = 'CTRL96peer000001';
  const brokerName = 'broker.round96.invalid';
  const nativeChannel = 'sonic_shield/native';
  const castChannel = 'sonic_shield/screencast';
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

  /// 端点自己的设备 ID（服务把 `store.deviceId` 当发送方标识）。
  String own() => store.deviceId;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('ss_round96');

    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    await store.setIdentity(ownId, '端点机96');
    await store.setBroker(brokerName);
    await store.ensurePairingCode();
    salts = KdfSaltStore(prefs);
    db = await AppDatabase.open(inMemoryDatabasePath);
    peer = PairedEndpoint(
      deviceId: ctrlId,
      name: '控制端96',
      secret: 'CODE9601',
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
    PlaybackService.resetRegistryForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(nativeChannel), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(castChannel), null);
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

  String cmdTopic() => 'sonicshield/v1/${own()}/cmd';
  String evtTopicOf(String senderId) => 'sonicshield/v1/$senderId/evt';

  /// 用**端点侧**每控制端密钥解回最后一条出站事件。
  Future<RcMessage?> unsealLastEvtByPeerKey(List<int> key) async {
    final out = fake.sentWires.last;
    final hit = await RcCodec.decodeWithCandidates(
      out.wire,
      out.topic,
      candidateKeys: <List<int>>[key],
      peerContext: '$ctrlId|evt',
    );
    return hit?.message;
  }

  // ══════════════════════════════════════ A · v3 每控制端密钥

  group('COV96-A v3 每控制端密钥', () {
    test('COV-01 cmd 入站：密钥命中即身份重写（信封自报 from 不作数）', () async {
      await svc.start(store, db);
      final key = RcCodec.newPeerKey();
      await store.setPeerKey(ctrlId, key);

      // 信封里自称是另一个设备（v1/v2 时代 from 就是身份；v3 之后不是）。
      const liar = 'ffffffffffffffff';
      final wire = await RcCodec.encode(
        RcMessage.now(RcCmd.ping, const {}, liar),
        const <int>[],
        cmdTopic(),
        peerKey: key,
        peerContext: '${own()}|cmd',
      );

      await svc.debugHandleRaw(cmdTopic(), wire);

      // 回执按**密钥对应的 deviceId**（ctrlId）定向投递，而不是信封里的 liar。
      final pong = await unsealLastEvtByPeerKey(key);
      expect(pong?.type, RcEvt.pong,
          reason: 'v3 命中后必须正常执行 ping，且用 ctrlId 的密钥加密回执');
      expect(fake.sentWires.last.topic, evtTopicOf(own()),
          reason: '回执走端点自己的 evt 主题');
      expect(
          await countLogs(status: 'skipped', contains: liar),
          0,
          reason: '★ 身份重写后不得再拿信封自报的 from 去查配对表');
    });

    test('COV-02 cmd 主题上的非密文报文 ⇒ 记 decode.fail（不静默）', () async {
      await svc.start(store, db);

      await svc.debugHandleRaw(cmdTopic(), 'not-base64-at-all!!');

      expect(
          await countLogs(
              action: 'decode.fail',
              status: 'failed',
              contains: '密钥不匹配（配对码可能录错）'),
          1,
          reason: '配对码录错时端点必须留下可读的审计，否则无从排查');
      expect(fake.sentWires, isEmpty, reason: '解不开的报文不得产生任何回执');
    });

    test('COV-03 evt 入站：有 peerKey 时走 v3 解密并广播给 UI', () async {
      await svc.start(store, db);
      final key = RcCodec.newPeerKey();
      await store.setPeerKey(ctrlId, key);

      final seen = <Map<String, dynamic>>[];
      final sub = svc.events.listen(seen.add);
      addTearDown(sub.cancel);

      final wire = await RcCodec.encode(
        RcMessage.now(RcEvt.heartbeat, const {}, ctrlId),
        const <int>[],
        evtTopicOf(ctrlId),
        peerKey: key,
        peerContext: '${own()}|evt',
      );
      await svc.debugHandleRaw(evtTopicOf(ctrlId), wire);
      await until(() => seen.isNotEmpty, '广播流投递（broadcast 默认异步）');

      expect(seen, hasLength(1),
          reason: 'v3 evt 解开的报文必须进广播流（否则 UI 永远停在"离线"）');
      expect(seen.single['type'], RcEvt.heartbeat);
      expect(seen.single['peerId'], ctrlId);
    });

    test('COV-04 配对回执里的 pk ⇒ 落盘为每控制端密钥', () async {
      await svc.start(store, db);
      final key = RcCodec.newPeerKey();
      final salt = List<int>.generate(16, (i) => i + 1);
      final request =
          RcMessage.now(RcCmd.pairRequest, {'deviceId': own(), 'name': '端点机96'});

      final pairing = svc.requestPairing(peer, store, request,
          timeout: const Duration(seconds: 5));
      await until(
          () => fake.sentWires.any((w) => w.topic == 'sonicshield/v1/$ctrlId/cmd'),
          '配对请求必须先投出去');

      // 对端（端点）回执：ok + 盐 + 32 字节 pk。
      final ack = RcMessage.now(RcEvt.ack, {
        'for': request.id,
        'ok': true,
        'kdfsalt': base64Encode(salt),
        'pk': base64Encode(key),
      }, ctrlId);
      final ownKey = await RcCodec.deriveKey(store.pairingCode, '${own()}|evt');
      final wire =
          await RcCodec.encode(ack, ownKey, evtTopicOf(ctrlId));
      await svc.debugHandleRaw(evtTopicOf(ctrlId), wire);

      final outcome = await pairing;
      expect(outcome.confirmed, isTrue);
      expect(store.peerKeys.keyFor(ctrlId), key,
          reason: '★ 配对回执的 pk 必须落盘，否则后续出站永远走不回 v3');
      expect(salts.saltFor(ctrlId), salt);
    });

    test('COV-05 出站事件：有 peerKey 时只发 v3 一份（不再派生共享码密钥）',
        () async {
      await svc.start(store, db);
      final key = RcCodec.newPeerKey();
      await store.setPeerKey(ctrlId, key);

      final before = fake.sentWires.length;
      await svc.debugDispatch(
          RcMessage.now(RcCmd.ping, const {}, ctrlId), peer);

      expect(fake.sentWires.length, before + 1);
      final pong = await unsealLastEvtByPeerKey(key);
      expect(pong?.type, RcEvt.pong,
          reason: '★ v3 出站必须能被该控制端的密钥解开');

      // 反面：共享配对码派生出来的密钥**解不开**它（撤销 = 凭据级失效）。
      final legacy = await RcCodec.deriveKey(peer.secret, '$ctrlId|evt');
      final wrong = await RcCodec.decode(
          fake.sentWires.last.wire, legacy, fake.sentWires.last.topic);
      expect(wrong, isNull,
          reason: '★ 有 peerKey 时不得再往报文里塞共享码密钥');
    });

    test('COV-06 sendTo：目标端点有 peerKey ⇒ v3 编码', () async {
      await svc.start(store, db);
      final key = RcCodec.newPeerKey();
      await store.setPeerKey(ctrlId, key);

      final sent = await svc.sendTo(
          peer, RcMessage.now(RcCmd.ping, const {}, own()), store);

      expect(sent, isTrue);
      final out = fake.sentWires.last;
      expect(out.topic, 'sonicshield/v1/$ctrlId/cmd');
      final hit = await RcCodec.decodeWithCandidates(
        out.wire,
        out.topic,
        candidateKeys: <List<int>>[key],
        peerContext: '$ctrlId|cmd',
      );
      expect(hit?.message.type, RcCmd.ping,
          reason: '★ 出站命令必须能被对端的每控制端密钥解开');
    });
  });

  // ══════════════════════════════════════ B · 投屏会话归属

  group('COV96-B 投屏会话归属（REM-11）', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(castChannel),
              (call) async {
        if (call.method == 'screenCastStart') return true;
        return null;
      });
    });

    test('COV-07 非发起方用错误 castId 停会话 ⇒ 拒绝并如实回执', () async {
      await svc.start(store, db);

      await svc.debugDispatch(
          RcMessage.now(RcCmd.screenCastRequest,
              {'castId': 'cast-a', 'kind': 'view'}, ctrlId),
          peer);
      expect(svc.castActive.value, isTrue, reason: '前提：会话必须真的起来了');

      await svc.debugDispatch(
          RcMessage.now(RcCmd.screenCastStop, {'castId': 'cast-b'}, ctrlId),
          peer);

      expect(
          await countLogs(
              action: 'screen.cast.stop',
              status: 'rejected',
              contains: '不是该控制会话的发起方'),
          1,
          reason: '★ 瞎写的 castId 不得打断别人的会话，且必须留痕');
      expect(svc.castActive.value, isTrue,
          reason: '★ 被拒绝的停止请求不得真的把会话停掉');

      final ack = await RcCodec.decode(
        fake.sentWires.last.wire,
        await RcCodec.deriveKey(peer.secret, '$ctrlId|evt'),
        fake.sentWires.last.topic,
      );
      expect(ack?.payload['ok'], isFalse);
      expect(ack?.payload['data'], '不是本次控制会话的发起方：无权停止');
    });

    test('COV-08 非发起方注入输入 ⇒ 拒绝（会话归属只认开启者）', () async {
      await svc.start(store, db);
      await svc.debugDispatch(
          RcMessage.now(RcCmd.screenCastRequest,
              {'castId': 'cast-a', 'kind': 'view'}, ctrlId),
          peer);

      // 同一 castId，但发送方是另一台设备：归属判据必须挡下。
      await svc.debugDispatch(
          RcMessage.now(RcCmd.inputTap,
              {'castId': 'cast-a', 'x': 0.5, 'y': 0.5}, 'ffffffffffffffff'),
          peer);

      expect(
          await countLogs(action: 'input.tap', status: 'failed'), 0,
          reason: '被拒绝的注入不得被记成执行失败（它压根没执行）');
      expect(svc.castActive.value, isTrue);
    });
  });

  // ══════════════════════════════════════ C · 停止类命令

  group('COV96-C 停止类命令', () {
    test('COV-09 vibrate.stop：引擎不可达时如实标注「未运行」', () async {
      await svc.start(store, db);
      // 引擎隔离不可达：`stopVibrate` 的 `_invoke` 抛错 ⇒ engineOk=false。
      BackgroundServiceManager.invokeHook =
          (method, args) async => throw StateError('engine unreachable');

      await svc.debugDispatch(
          RcMessage.now(RcCmd.vibrateStop, const {}, ctrlId), peer);

      expect(
          await countLogs(
              action: 'vibrate.stop', status: 'success', contains: '引擎=未运行'),
          1,
          reason: '引擎没跑不等于失败，但必须在审计里说清楚');
      expect(await countLogs(action: 'vibrate.stop', status: 'failed'), 0);
    });

    test('COV-10 sound.stop：回执带真实停止条数（0 也如实回 0）', () async {
      await svc.start(store, db);
      PlaybackService.resetRegistryForTest();

      await svc.debugDispatch(
          RcMessage.now(RcCmd.soundStop, const {}, ctrlId), peer);

      expect(
          await countLogs(
              action: 'sound.stop', status: 'success', contains: 'stopped=0'),
          1);
      final ack = await RcCodec.decode(
        fake.sentWires.last.wire,
        await RcCodec.deriveKey(peer.secret, '$ctrlId|evt'),
        fake.sentWires.last.topic,
      );
      expect(ack?.payload['ok'], isTrue);
      expect(ack?.payload['data'], 'stopped=0',
          reason: '★ 0 条就回 0，不得包装成"成功停止 N 项"');
    });
  });

  // ══════════════════════════════════════ D · outbox 补发判据（纯函数）

  group('COV96-D 补发判据的 v3 入口', () {
    test('COV-11 peekOutboxType / prepareOutboxReplay 支持 peerKey', () async {
      final key = RcCodec.newPeerKey();
      const topic = 'sonicshield/v1/$ctrlId/cmd';
      const ctx = '$ctrlId|cmd';
      final wire = await RcCodec.encode(
        RcMessage.now(RcCmd.ping, const {'n': 9}, own()),
        const <int>[],
        topic,
        peerKey: key,
        peerContext: ctx,
      );

      expect(
          await peekOutboxType(wire, const <int>[], topic,
              peerKey: key, peerContext: ctx),
          RcCmd.ping,
          reason: '裁决只看类型，但必须能用 peerKey 解开');

      final reEnc = await prepareOutboxReplay(wire, const <int>[], topic,
          peerKey: key, peerContext: ctx);
      expect(reEnc, isNotNull);
      final replayed = await RcCodec.decodeWithCandidates(
        reEnc!,
        topic,
        candidateKeys: <List<int>>[key],
        peerContext: ctx,
      );
      expect(replayed?.message.type, RcCmd.ping);
      expect(replayed?.message.payload['n'], 9,
          reason: '重编码必须保留业务负载');

      // 反面：不给 peerKey 时 v3 报文解不开 ⇒ 类型未知 / 无法重放。
      expect(await peekOutboxType(wire, const <int>[], topic), isNull);
      expect(await prepareOutboxReplay(wire, const <int>[], topic), isNull,
          reason: '★ 撤销删掉钥匙后，队列里的密文必须永久作废');
    });
  });
}
