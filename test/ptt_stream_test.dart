import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart'
    show ProcessingStateMessage;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/remote/controller_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/playback_service.dart';
import 'package:sonic_shield/services/ptt_stream_sink.dart';

import 'support/just_audio_stub.dart';
import 'support/mqtt_client_stub.dart';
import 'support/record_stub.dart';

/// 第七十四轮：**对讲机 v2 流式**（边录边发 / 边收边放）的宿主行为锁。
///
/// ## 这份锁在防什么
///
/// 第七十三轮"通话发起即崩溃"之所以逃过多轮测试，根因是**替身把真实契约
/// 吃掉了**（`webrtc_stub` 不读 `streamIds`）。流式对讲引入了全新的跨层契约
/// （控制端切 ADTS 帧 → 端点落分片 → 播放会话增量追加），如果不把**每一段
/// 真实状态机**驱动起来，"全绿"只会再次证明"实现符合我们自写的模型"。
///
/// 因此本文件用**真** `AdtsChunker` / **真** `RcControllerService` /
/// **真** `RcEndpointService` 会话状态机 / **真** `PlaybackService` 会话
/// （仅平台返回被替身替换），逐段断言：
///
/// | 组 | 真实链 |
/// |---|---|
/// | AD | `AdtsChunker`：按**帧边界**切，切片落在帧中间即为缺陷 |
/// | CS | 控制端：`startStream` 帧流 → 分片 → 串行 `sendTo`（seq/last 语义） |
/// | EP | 端点：首片开会话、中间片追加、末片收尾 + `rc.ptt` 定向回执 + 清理 |
/// | PB | 播放会话：`ConcatenatingAudioSource` 增量追加（第二片必须 `concatenatingInsertAll`） |
///
/// ⚠️ 全部走**真** `RcCodec`（真 HKDF / AES-GCM）：端点回执用对端密钥解回来断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // ---------------- AD：ADTS 帧切分（纯函数，无任何替身） ----------------

  /// 造一个 `frameLen` 字节的**合法 ADTS 帧**（头 7 字节 + 填充）。
  Uint8List adtsFrame(int frameLen) {
    final b = Uint8List(frameLen);
    b[0] = 0xFF;
    b[1] = 0xF1;
    b[2] = 0x50;
    b[3] = (frameLen >> 11) & 0x03;
    b[4] = (frameLen >> 3) & 0xFF;
    b[5] = ((frameLen & 0x07) << 5) | 0x1F;
    b[6] = 0xFC;
    return b;
  }

  Uint8List concat(List<Uint8List> parts) {
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    final out = Uint8List(total);
    var off = 0;
    for (final p in parts) {
      out.setRange(off, off + p.length, p);
      off += p.length;
    }
    return out;
  }

  group('AD · ADTS 帧切分器（切片必须恰好覆盖整数个完整帧）', () {
    test('AD-01 未聚满 minBytes → 不切；聚满 → 切出**整数帧**大小的块', () {
      final c = AdtsChunker(minBytes: 500);
      // 两帧各 200 字节 = 400 < 500 ⇒ 不切。
      expect(c.feed(concat([adtsFrame(200), adtsFrame(200)])), isNull);
      // 再来一帧 ⇒ 600 ≥ 500 ⇒ 切出 600（3 整帧）。
      final block = c.feed(adtsFrame(200));
      expect(block, isNotNull);
      expect(block!.length, 600, reason: '必须切出整数个完整帧');
    });

    test('AD-02 帧未收全时**绝不**切半帧（否则端点文件头不是同步字 ⇒ 解码失败）', () {
      final c = AdtsChunker(minBytes: 100);
      // 一个 300 字节帧只喂前 100 字节 ⇒ 头 7 字节齐全、长度说 300、
      // 但缓冲不足 300 ⇒ 不能切。
      final partial = adtsFrame(300).sublist(0, 100);
      expect(c.feed(Uint8List.fromList(partial)), isNull,
          reason: '半帧切片是"后面几句听不到/杂音"的直接成因');
      // 补齐剩余 200 字节 ⇒ 现在可切 300。
      final block = c.feed(Uint8List.fromList(adtsFrame(300).sublist(100)));
      expect(block!.length, 300);
    });

    test('AD-03 flush 冲尾：返回残留字节；空缓冲返回 null', () {
      final c = AdtsChunker(minBytes: 1000);
      expect(c.flush(), isNull, reason: '空缓冲不该吐空块');
      c.feed(concat([adtsFrame(120), adtsFrame(120)]));
      final tail = c.flush();
      expect(tail!.length, 240);
      expect(c.flush(), isNull, reason: '冲尾后缓冲必须清空');
    });

    test('AD-04 非同步字自动重新对齐（防御性；正常流不该出现）', () {
      final c = AdtsChunker(minBytes: 100);
      // 3 字节垃圾 + 1 个 200 字节帧 ⇒ 必须跳过垃圾切出 200 帧。
      final junk = Uint8List.fromList([1, 2, 3]);
      final block = c.feed(concat([junk, adtsFrame(200)]));
      expect(block, isNotNull);
      // 切出的块含垃圾 + 完整帧（重新对齐后完整帧边界是 203）。
      expect(block!.length, 203);
    });

    test('AD-05 同步字合法但长度域非法（<7）→ 逐字节跳过，绝不按非法长度切', () {
      final c = AdtsChunker(minBytes: 100);
      // 7 字节伪帧头：同步字合法（0xFF 0xF1）但长度域为 0（非法）。
      // 若不判 `len < 7`，解析器会按 0 长度"原地打转"或错切到后续字节。
      final bogus =
          Uint8List.fromList(<int>[0xFF, 0xF1, 0x50, 0x00, 0x00, 0x00, 0x00]);
      final block = c.feed(concat([bogus, adtsFrame(200)]));
      expect(block, isNotNull);
      expect(block!.length, greaterThanOrEqualTo(200),
          reason: '非法长度域必须被当作垃圾跳过，真帧仍要被完整切出');
    });
  });

  // ---------------- CS：控制端流式发送 ----------------

  group('CS · 控制端边录边发（真实 startStream → 分片 → 串行 sendTo）', () {
    late SharedPreferences prefs;
    late RemoteStore store;
    late PairedEndpoint endpoint;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = RemoteStore(prefs);
      await store.setIdentity('ctrl00000000a1', '控制端74');
      endpoint = PairedEndpoint(
          deviceId: 'ep0000000000b2',
          name: '端点74',
          secret: 'AB2CD5EF',
          pairedAt: DateTime(2024, 1, 1));
      await store.addPaired(endpoint);
    });

    tearDown(() async {
      RcEndpointService.instance.debugSendTo = null;
      restoreRecordPlatform();
      await RcControllerService.instance.pttCancelStream();
    });

    test('CS-01 聚满一片即发（seq=0,last=false），松手补末片（seq=1,last=true）',
        () async {
      final ctrl = StreamController<Uint8List>();
      final captured = <RcMessage>[];
      RcEndpointService.instance.debugSendTo =
          (e, m, s, enqueueOnFail) async {
        captured.add(m);
        return true;
      };
      final rec = installFakeRecordPlatform(
          hasPermissionResult: true, streamResult: ctrl.stream);

      final svc = RcControllerService.instance;
      expect(await svc.pttStartStream(endpoint, store), isTrue);
      expect(rec.calls, containsAll(['hasPermission', 'startStream']),
          reason: '必须真的走流式录音通道，而不是整段 start');

      // 8 帧 × 200 = 1600 ≥ 1500(pttChunkBytes) ⇒ 切一片。
      for (var i = 0; i < 8; i++) {
        ctrl.add(adtsFrame(200));
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(captured, hasLength(1), reason: '聚满阈值必须立刻发，而不是等松手');
      expect(captured[0].type, RcCmd.pttVoice);
      expect(captured[0].payload['seq'], 0);
      expect(captured[0].payload['last'], false);
      expect(
          base64Decode(captured[0].payload['audioB64'] as String).length, 1600,
          reason: '发出的必须是整数帧的字节');

      final r = await svc.pttStopStream();
      expect(r.ok, isTrue);
      expect(captured, hasLength(2));
      expect(captured[1].payload['seq'], 1);
      expect(captured[1].payload['last'], true,
          reason: '末片必须带 last 标记，否则端点会话永远不收尾');
      expect(captured[1].payload.containsKey('audioB64'), isFalse,
          reason: '恰好整除时末片无音频字节，只作收尾信号');
      expect(captured[0].payload['voiceId'], captured[1].payload['voiceId'],
          reason: '同一段语音必须共用 voiceId');

      await ctrl.close();
    });

    test('CS-02 尾片含残余帧 → 作为带音频的 last 片发出', () async {
      final ctrl = StreamController<Uint8List>();
      final captured = <RcMessage>[];
      RcEndpointService.instance.debugSendTo =
          (e, m, s, enqueueOnFail) async {
        captured.add(m);
        return true;
      };
      installFakeRecordPlatform(
          hasPermissionResult: true, streamResult: ctrl.stream);
      final svc = RcControllerService.instance;
      await svc.pttStartStream(endpoint, store);

      for (var i = 0; i < 8; i++) {
        ctrl.add(adtsFrame(200));
      }
      ctrl.add(adtsFrame(120)); // 残余 < 1500 ⇒ 不切
      await Future<void>.delayed(Duration.zero);

      expect(captured, hasLength(1), reason: '残余未达阈值不该提前发');

      final r = await svc.pttStopStream();
      expect(r.ok, isTrue);
      expect(captured, hasLength(2));
      expect(captured[1].payload['last'], true);
      expect(base64Decode(captured[1].payload['audioB64'] as String).length, 120,
          reason: '尾片必须把残余帧带上，否则最后一句被吞');

      await ctrl.close();
    });

    test('CS-03 取消 → 立即停录；已发出的分片收不回，但必须补终止帧让端点收尾',
        () async {
      final ctrl = StreamController<Uint8List>();
      final captured = <RcMessage>[];
      RcEndpointService.instance.debugSendTo =
          (e, m, s, enqueueOnFail) async {
        captured.add(m);
        return true;
      };
      final rec = installFakeRecordPlatform(
          hasPermissionResult: true, streamResult: ctrl.stream);
      final svc = RcControllerService.instance;
      await svc.pttStartStream(endpoint, store);
      for (var i = 0; i < 8; i++) {
        ctrl.add(adtsFrame(200));
      }
      await Future<void>.delayed(Duration.zero);

      await svc.pttCancelStream();
      expect(rec.calls, contains('stop'), reason: '取消必须真的释放麦克风');
      expect(svc.pttStreaming, isFalse);

      // 流式固有：取消前已聚满一片（1600B ≥ 1500）⇒ 那片已经上路、收不回。
      // 但取消**必须**再补一帧 `last=true` 的终止帧，否则端点会话永远等不到
      // 末片：不回执、不释放、分片文件一直挂着。
      expect(captured, hasLength(2));
      expect(captured.first.payload['last'], false);
      expect(captured.last.payload['last'], true,
          reason: '取消必须补终止帧，否则端点悬挂');
      expect(captured.last.payload.containsKey('audioB64'), isFalse,
          reason: '终止帧只作收尾信号，不带音频');
      expect(captured.last.payload['voiceId'], captured.first.payload['voiceId'],
          reason: '终止帧必须用同一 voiceId，端点才认得出是哪条会话');

      await ctrl.close();
    });

    test('CS-04 权限被拒 / 平台不支持流式 → 如实 false，不进入录制态', () async {
      installFakeRecordPlatform(hasPermissionResult: false);
      final svc = RcControllerService.instance;
      expect(await svc.pttStartStream(endpoint, store), isFalse);
      expect(svc.pttStreaming, isFalse);
    });

    test('CS-05 录音流中途报错 → 兜住不崩溃；一帧未产出则如实"未录到音频"', () async {
      final ctrl = StreamController<Uint8List>();
      final captured = <RcMessage>[];
      RcEndpointService.instance.debugSendTo =
          (e, m, s, enqueueOnFail) async {
        captured.add(m);
        return true;
      };
      installFakeRecordPlatform(
          hasPermissionResult: true, streamResult: ctrl.stream);
      final svc = RcControllerService.instance;
      expect(await svc.pttStartStream(endpoint, store), isTrue);

      // 平台侧编码器中途报错：流带错误在真实设备上会发生（录音通道被抢占），
      // `onError` 兜住即可 —— 绝不能把错误当音频发，也不能让异常冒泡崩掉。
      ctrl.addError(StateError('编码器挂了'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(captured, isEmpty, reason: '流错误不得被误当成音频发出去');
      final r = await svc.pttStopStream();
      expect(r.ok, isFalse, reason: '一帧未产出必须如实报告，不能假成功');
      // BUG-120：中断原因必须说出来。旧实现把 `onError` 吞成空闭包，
      // 松手时只会得到"未录到音频" —— 用户以为是没说话，实际是录音通道挂了。
      expect(r.message, contains('录音中断'),
          reason: '录音器中途故障必须如实回报原因，不能伪装成"未录到音频"');
      expect(svc.pttStreaming, isFalse);
      await ctrl.close();
    });
  });

  // ---------------- EP：端点流式会话 ----------------

  group('EP · 端点边收边放（会话状态机 + rc.ptt 定向回执 + 清理）', () {
    const ownId = 'EP74own000abc';
    const ctrlId = 'CTRL74peer0001';
    const brokerName = 'broker.round74.invalid';
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
      tmpDir = await Directory.systemTemp.createTemp('ss_round74');
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = RemoteStore(prefs);
      await store.setIdentity(ownId, '端点机74');
      await store.setBroker(brokerName);
      await store.ensurePairingCode();
      salts = KdfSaltStore(prefs);
      db = await AppDatabase.open(inMemoryDatabasePath);
      peer = PairedEndpoint(
          deviceId: ctrlId,
          name: '控制端74',
          secret: 'CODE7401',
          pairedAt: DateTime(2024, 1, 1));
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
      RcEndpointService.pttStreamKeepAlive = const Duration(seconds: 5);
    });

    tearDown(() async {
      await svc.stop();
      svc.debugClientFactory = null;
      svc.debugSetOwnCode('');
      svc.pttStreamOpener = null;
      RcEndpointService.pttStreamKeepAlive = const Duration(seconds: 90);
      try {
        await tmpDir.delete(recursive: true);
      } on Object {
        // Windows 句柄释放可能滞后。
      }
      try {
        await db.close();
      } on Object {
        // ignore
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(notifChannel), null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(pathProviderChannel), null);
    });

    String cmdTopicOf(String id) => 'sonicshield/v1/$id/cmd';

    RcMessage inbound(String type, Map<String, dynamic> payload) {
      final n = RcMessage.now(type, payload);
      return RcMessage(
          id: n.id, ts: n.ts, type: n.type, payload: n.payload, from: ctrlId);
    }

    Future<void> sealAndEmit(RcMessage msg) async {
      final key = await RcCodec.deriveKey(store.pairingCode, '$ownId|cmd');
      final wire = await RcCodec.encode(msg, key, cmdTopicOf(ownId));
      await fake.emit(cmdTopicOf(ownId), wire);
    }

    /// 有界条件轮询：入站链路里有 `writeAsBytes` / sqflite isolate 等**真实
    /// 异步**（非纯微任务），固定轮次 `await Future.delayed(Duration.zero)`
    /// 会和断言**竞速**（第 39 轮同款教训）。超时显式 fail，绝不静默放行。
    Future<void> until(bool Function() cond, String why,
        {int maxMs = 8000}) async {
      final sw = Stopwatch()..start();
      while (!cond()) {
        if (sw.elapsedMilliseconds > maxMs) {
          fail('waitFor 超时（${maxMs}ms）: $why');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<RcMessage?> unsealLastEvt() async {
      final wire = fake.sentWires.last.wire;
      final key = await RcCodec.deriveKey(peer.secret, '$ctrlId|evt',
          salt: salts.saltFor(ctrlId));
      return RcCodec.decode(wire, key, 'sonicshield/v1/$ownId/evt');
    }

    Future<int> countLogs({String? action, String? status}) async {
      final rows = await LogRepository(db).recent(limit: 500);
      return rows
          .where((r) =>
              (action == null || r['action'] == action) &&
              (status == null || r['status'] == status))
          .length;
    }

    test('EP-01 首片开会话起播、中间片追加、末片收尾 + rc.ptt{ok:true,chunks}',
        () async {
      final sink = _FakePttSink();
      svc.pttStreamOpener = () => sink;
      await svc.start(store, db);

      await sealAndEmit(inbound(RcCmd.pttVoice, {
        'voiceId': 'v-74',
        'seq': 0,
        'last': false,
        'audioB64': base64Encode(adtsFrame(300)),
        'fromName': '老王',
      }));
      await until(() => sink.appended.length == 1, '首片落盘并起播');
      expect(sink.appended, hasLength(1), reason: '首片到达必须立刻起播');
      expect(File(sink.appended[0]).existsSync(), isTrue,
          reason: '分片必须真实落盘（文件名 .aac）');
      expect(sink.appended[0].endsWith('.aac'), isTrue);

      await sealAndEmit(inbound(RcCmd.pttVoice, {
        'voiceId': 'v-74',
        'seq': 1,
        'last': false,
        'audioB64': base64Encode(adtsFrame(300)),
      }));
      await until(() => sink.appended.length == 2, '中间片续播');
      expect(sink.appended, hasLength(2), reason: '中间片续播');

      final sentBefore = fake.sentWires.length;
      await sealAndEmit(inbound(RcCmd.pttVoice, {
        'voiceId': 'v-74',
        'seq': 2,
        'last': true,
        'audioB64': base64Encode(adtsFrame(300)),
      }));
      await until(() => sink.endCalls == 1, '末片收尾会话');
      await until(() => fake.sentWires.length > sentBefore, '末片回 rc.ptt');
      expect(sink.endCalls, 1, reason: '末片必须收尾会话');
      expect(await countLogs(action: 'ptt.play', status: 'success'), 1);

      final evt = await unsealLastEvt();
      expect(evt, isNotNull);
      expect(evt!.type, RcEvt.pttAck);
      expect(evt.payload['ok'], true);
      expect(evt.payload['voiceId'], 'v-74');
      expect(evt.payload['chunks'], 3);

      // 服务停止 ⇒ 会话释放 + 分片清理。
      final files = List<String>.of(sink.appended);
      await svc.stop();
      expect(sink.disposeCalls, 1, reason: '停服必须释放播放会话');
      for (final f in files) {
        expect(File(f).existsSync(), isFalse, reason: '分片文件必须被清理');
      }
    });

    test('EP-02 缺 voiceId → 失败留痕 + rc.ptt{ok:false}', () async {
      final sink = _FakePttSink();
      svc.pttStreamOpener = () => sink;
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;
      await sealAndEmit(inbound(RcCmd.pttVoice, {
        'voiceId': '',
        'seq': 0,
        'last': false,
        'audioB64': base64Encode(adtsFrame(200)),
      }));

      await until(() => fake.sentWires.length > sentBefore, '失败回执投出');
      expect(sink.appended, isEmpty);
      expect(await countLogs(action: 'ptt.play', status: 'failed'), 1);
      final evt = await unsealLastEvt();
      expect(evt!.payload['ok'], false);
    });

    test('EP-03 首片无音频 → 与 v1 同一判据"缺少 audioB64"', () async {
      final sink = _FakePttSink();
      svc.pttStreamOpener = () => sink;
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;
      await sealAndEmit(inbound(RcCmd.pttVoice, {
        'voiceId': 'v-empty',
        'seq': 0,
        'last': false,
      }));

      await until(() => fake.sentWires.length > sentBefore, '失败回执投出');
      expect(sink.appended, isEmpty);
      final evt = await unsealLastEvt();
      expect(evt!.payload['ok'], false);
      expect(evt.payload['reason'], '缺少 audioB64');
    });

    test('EP-04 追加抛错 → 会话销毁 + 失败留痕 + 释放（不假成功）', () async {
      final sink = _FakePttSink()..throwOnAppend = true;
      svc.pttStreamOpener = () => sink;
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;
      await sealAndEmit(inbound(RcCmd.pttVoice, {
        'voiceId': 'v-bad',
        'seq': 0,
        'last': false,
        'audioB64': base64Encode(adtsFrame(200)),
      }));

      await until(() => sink.disposeCalls == 1, '失败销毁会话');
      await until(() => fake.sentWires.length > sentBefore, '失败回执投出');
      expect(sink.disposeCalls, 1, reason: '失败必须销毁会话（否则泄漏）');
      expect(await countLogs(action: 'ptt.play', status: 'failed'), 1);
      expect(await countLogs(action: 'ptt.play', status: 'success'), 0,
          reason: '播放失败绝不许记成功');
      final evt = await unsealLastEvt();
      expect(evt!.payload['ok'], false);
    });

    test('EP-05 未装配流式开缝 → 带 seq 也回落 v1 整段路径（向后兼容）', () async {
      // pttStreamOpener 保持 null。
      final played = <String>[];
      svc.playHandler = (path, volume, durationMs, {loop = false}) async {
        played.add(path);
        return true;
      };
      await svc.start(store, db);
      await sealAndEmit(inbound(RcCmd.pttVoice, {
        'voiceId': 'v-v1',
        'seq': 0,
        'last': true,
        'audioB64': base64Encode(adtsFrame(200)),
      }));

      await until(() => played.length == 1, 'v1 播放路径落盘');
      expect(played, hasLength(1), reason: '未装配开缝必须走 v1 playHandler');
      expect(played.single.endsWith('.m4a'), isTrue);
      svc.playHandler = null;
    });

    test('EP-06 同一 voiceId 又收到 seq==0 → 丢弃旧会话重开（QoS1 重投 / 对端重录）',
        () async {
      // 每次开缝返回**新** sink：重开必须"换一个新会话"，而不是续在旧会话上。
      final sinks = <_FakePttSink>[];
      svc.pttStreamOpener = () {
        final s = _FakePttSink();
        sinks.add(s);
        return s;
      };
      await svc.start(store, db);

      await sealAndEmit(inbound(RcCmd.pttVoice, {
        'voiceId': 'v-reopen',
        'seq': 0,
        'last': false,
        'audioB64': base64Encode(adtsFrame(300)),
      }));
      await until(() => sinks.length == 1 && sinks[0].appended.length == 1,
          '首片开会话');

      // 同 voiceId 再来一个 seq==0（QoS1 重投会原样重发首片）：旧会话必须被
      // 丢弃（释放播放器 + 删分片）再开新的，否则新旧分片会混进同一条播放队列。
      await sealAndEmit(inbound(RcCmd.pttVoice, {
        'voiceId': 'v-reopen',
        'seq': 0,
        'last': false,
        'audioB64': base64Encode(adtsFrame(300)),
      }));
      await until(() => sinks.length == 2 && sinks[1].appended.length == 1,
          '重开必须新建会话并落新首片');

      expect(sinks[0].disposeCalls, 1, reason: '旧会话必须被释放（否则解码器泄漏）');
      expect(sinks[1].appended, hasLength(1),
          reason: '新会话必须从自己的首片开始，不能续在旧会话队列上');
      expect(File(sinks[1].appended.single).existsSync(), isTrue,
          reason: '新首片必须真实落盘');
    });

    test('EP-07 会话空闲超过 keepAlive → 自动回收（释放 + 清理分片）', () async {
      // 把 keepAlive 压到 200ms，让"对端中途崩了、不再补末片"可被快速观测。
      RcEndpointService.pttStreamKeepAlive = const Duration(milliseconds: 200);
      final sink = _FakePttSink();
      svc.pttStreamOpener = () => sink;
      await svc.start(store, db);

      await sealAndEmit(inbound(RcCmd.pttVoice, {
        'voiceId': 'v-idle',
        'seq': 0,
        'last': false,
        'audioB64': base64Encode(adtsFrame(300)),
      }));
      await until(() => sink.appended.length == 1, '首片开会话');

      await until(() => sink.disposeCalls == 1, '空闲超时自动回收会话', maxMs: 6000);
      // ⚠️ 「释放会话」与「删分片」是**两拍**：`_closePttStream` 先调
      //    `sink.dispose()`（`disposeCalls` 立即可见），**随后**才
      //    `await File(p).delete()`；而空闲回收走的是 `unawaited(...)`
      //    （Timer 回调里无法 await 任何人）。因此必须**等文件真的消失**
      //    再断言 —— 直接 `expect(existsSync(), isFalse)` 会在并行跑测试时
      //    观测到"已释放、还没删完"的中间态（第 78 轮实测 flake，
      //    单跑必过、并发偶红）。判据不变：分片最终必须被清理。
      await until(() => !File(sink.appended[0]).existsSync(),
          '空闲回收必须清理分片，不留悬挂会话/文件');
    });
  });

  // ---------------- PB：播放会话增量追加 ----------------

  group('PB · 流式播放会话（ConcatenatingAudioSource 增量追加）', () {
    late FakeJustAudio audio;

    setUp(() {
      audio = FakeJustAudio();
      audio.install();
      PlaybackService.resetRegistryForTest();
    });

    tearDown(() {
      PlaybackService.resetRegistryForTest();
      audio.uninstall();
    });

    test('PB-01 首片 load、后续片 concatenatingInsertAll、dispose 释放', () async {
      final svc = PlaybackService();
      final sink = svc.openPttStream();
      await sink.append('/tmp/ptt_a.aac');
      await sink.append('/tmp/ptt_b.aac');
      await sink.append('/tmp/ptt_c.aac');
      await sink.end();

      expect(audio.countOf('load'), 1, reason: '只有首片走 setAudioSource');
      expect(audio.countOf('concatenatingInsertAll'), 2,
          reason: '第 2、3 片必须走动态追加，否则"只听到第一片"');
      expect(audio.countOf('play'), greaterThanOrEqualTo(1));

      await sink.dispose();
      expect(audio.countOf('disposePlayer'), greaterThanOrEqualTo(1));
    });

    test('PB-02 会话登记进 stopAllPlaying（远程"停止"能掐断对讲出声）', () async {
      final svc = PlaybackService();
      final sink = svc.openPttStream();
      await sink.append('/tmp/ptt_x.aac');
      final stopped = await PlaybackService.stopAllPlaying();
      expect(stopped, greaterThanOrEqualTo(1),
          reason: '对讲出声必须被"端点静音"覆盖，否则用户点了停还在响');
      await sink.dispose();
    });

    test('PB-03 end 后不再追加（避免会话收尾后又塞进新片）', () async {
      final svc = PlaybackService();
      final sink = svc.openPttStream();
      await sink.append('/tmp/ptt_e1.aac');
      await sink.end();
      await sink.append('/tmp/ptt_e2.aac');
      expect(audio.countOf('concatenatingInsertAll'), 0,
          reason: '收尾后不得再追加');
      await sink.dispose();
    });

    test('PB-04 队列播空后再来分片 → 从新片续播；started 随首片翻转', () async {
      final svc = PlaybackService();
      final sink = svc.openPttStream() as PttPlaybackSession;
      expect(sink.started, isFalse, reason: '一帧未到不许自称"已开播"');

      await sink.append('/tmp/ptt_s1.aac');
      expect(sink.started, isTrue, reason: '首片起播后 started 必须为真');

      // 模拟平台侧把队列播空（首片太短 / 片间空隙过大时真实会发生）。
      audio.pushEvent(processingState: ProcessingStateMessage.completed);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      await sink.append('/tmp/ptt_s2.aac');
      expect(audio.countOf('seek'), greaterThanOrEqualTo(1),
          reason: '队列播空后必须从新片重新起播，否则"后面几句听不到"');
      await sink.dispose();
    });
  });
}

class _FakePttSink implements PttStreamSink {
  final List<String> appended = <String>[];
  int endCalls = 0;
  int disposeCalls = 0;
  bool throwOnAppend = false;

  @override
  Future<void> append(String path, {double volume = 1.0}) async {
    if (throwOnAppend) throw StateError('解码失败');
    appended.add(path);
  }

  @override
  Future<void> end() async => endCalls++;

  @override
  Future<void> dispose() async => disposeCalls++;
}