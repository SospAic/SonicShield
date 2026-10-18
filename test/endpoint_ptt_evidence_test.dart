import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/remote/script_executor.dart';

import 'support/mqtt_client_stub.dart';
import 'support/record_stub.dart';

/// 第四十九轮：**PTT 音频桶 + 录音取证桶 + 音源库桶**的宿主行为锁。
///
/// ## 为什么需要这一份
///
/// 第 48 轮拿下 MQTT 传输整层后，`endpoint_service` 剩 190 行里最大的三个
/// 可达桶（`docs/17 §78.5` 的 ②③ 号桶）：
///
/// | 桶 | 行数 | 此前状态 | 本轮驱动方式 |
/// |---|---|---|---|
/// | ③ PTT 音频（`_playPtt` / `_pttFailed`） | ≈34 | 只有源码文本锁 | `client.updates` 真入口投 `ptt.voice`（真密文）+ 注入 `playHandler` |
/// | ② 录音取证（`_recordEvidence`） | ≈30 | **从未被执行**（含权限拒绝/成功/异常/终止四条终态） | 指令组 `record` 步骤 + `RecordPlatform` 假实现（`test/support/record_stub.dart`，本轮给它加了可编程 `startError`） |
/// | ② 音源库（`_sendAssets` / `_assetPathById`） | ≈9 | 只有文本锁 | `rc.assetList` / `sound.play{assetId}` 命令 |
///
/// ## 替身面（与 45/46/48 轮同一纪律：替身只复刻平台侧返回形状）
///
/// - `getApplicationDocumentsDirectory`：桩 `plugins.flutter.io/path_provider`
///   通道（`path_provider` 默认实现就是这条通道）⇒ 指向**真实临时目录**，
///   文件真的落盘、真的可断言存在。
/// - `AudioRecorder`：`RecordPlatform.instance` 平台层假实现 ——
///   第 41 轮实测：通道桩在跨用例后 `create()` 永不推进 ⇒ **必须用平台层**。
///   本文件全是**真异步**（`test()`，无 fake-async）⇒ 不踩 §75.4 的跨 zone 坑。
/// - `NotificationService`：通道桩（`initialize` 必须返回 `true`，44 轮实测）。
/// - MQTT：`FakeMqttServerClient`（48 轮，实例注入型，无需全局还原）。
///
/// ⚠️ 全部走**真** `RcCodec`（真 HKDF / AES-GCM）：出站回执**用对端密钥解回来**
/// 断言内容，不接受"只数条数"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const ownId = 'EP49own00000abc';
  const ctrlId = 'CTRL49peer00001';
  const brokerName = 'broker.round49.invalid';
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

  final shown = <Object?>[];
  final played = <({String path, double volume, int durationMs, bool loop})>[];

  setUp(() async {
    shown.clear();
    played.clear();
    tmpDir = await Directory.systemTemp.createTemp('ss_round49');

    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    await store.setIdentity(ownId, '端点机49');
    await store.setBroker(brokerName);
    // 与 48 轮同序：先 ensurePairingCode 再 debugSetOwnCode（空配对码会让
    // _handleRaw 直接返回 —— 症状是"什么都没发生"，不是抛错）。
    await store.ensurePairingCode();
    salts = KdfSaltStore(prefs);
    db = await AppDatabase.open(inMemoryDatabasePath);
    peer = PairedEndpoint(
      deviceId: ctrlId,
      name: '控制端49',
      secret: 'CODE4901',
      pairedAt: DateTime(2024, 1, 1),
    );
    await store.addPaired(peer);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(notifChannel),
            (call) async {
      if (call.method == 'show') shown.add(call.arguments);
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
    svc.debugSetOwnCode('');
    svc.playHandler = null;
    svc.resolvePresetHandler = null;
    RcScriptExecutor.instance.stop();
    restoreRecordPlatform();
    try {
      await tmpDir.delete(recursive: true);
    } on Object {
      // Windows 上句柄释放可能滞后：清不掉就留给系统临时目录，不影响判定。
    }
    try {
      await db.close();
    } on Object {
      // 同 ESR：在飞的终态通知计时器可能已把库关掉。
    }
    // 通道桩是全局的：必须摘掉，否则泄漏到下一个用例（跨文件同理）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(notifChannel), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(pathProviderChannel),
            null);
  });

  Future<void> settle([int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 有界条件轮询（项目铁律：**禁止 pumpAndSettle 当"等数据"用**，超时显式 fail）。
  ///
  /// ⚠️ 本文件必须用它而不是固定轮数的 `settle`：入站链路里有
  /// `getApplicationDocumentsDirectory` / sqflite isolate 等**事件队列**往返，
  /// 固定微任务轮次会和断言**竞速**（第三十九轮同款教训）。
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

  String cmdTopicOf(String id) => 'sonicshield/v1/$id/cmd';

  RcMessage inbound(String type,
      [Map<String, dynamic> payload = const {}, String from = ctrlId]) {
    final n = RcMessage.now(type, payload);
    return RcMessage(
        id: n.id, ts: n.ts, type: n.type, payload: n.payload, from: from);
  }

  /// cmd 方向：控制端用「端点配对码 + 端点ID|cmd」加密（与生产一致）。
  Future<String> sealCmd(RcMessage msg) async {
    final key = await RcCodec.deriveKey(store.pairingCode, '$ownId|cmd');
    return RcCodec.encode(msg, key, cmdTopicOf(ownId));
  }

  /// 把端点**刚发出的最后一条回执**用对端密钥解回来（`_send` 的 evt 命名空间）。
  Future<RcMessage?> unsealLastEvt() async {
    final wire = fake.sentWires.last.wire;
    final salt = salts.saltFor(ctrlId);
    final key = await RcCodec.deriveKey(peer.secret, '$ctrlId|evt', salt: salt);
    return RcCodec.decode(wire, key, 'sonicshield/v1/$ownId/evt');
  }

  /// 等到端点把**本条命令**的收尾回执真正投出去。
  ///
  /// 为什么等它就等于等全链路：`_playPtt` / `_pttFailed` 都是
  /// **先 `await logs.append` 再 `unawaited(_send)`** ——
  /// 回执出现在 `sentWires` 里 ⇒ 审计行必然已落库（第三十九轮"竞速"教训）。
  Future<void> waitPttAckSent(int sentBefore) =>
      until(() => fake.sentWires.length > sentBefore, 'ptt 收尾回执投出');

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

  /// 从 `client.updates` **真入口**投一条真密文命令（与 48 轮 MQ-11 同法）。
  Future<void> emitCmd(RcMessage msg) async {
    await fake.emit(cmdTopicOf(ownId), await sealCmd(msg));
    await settle();
  }

  group('PT · 对讲接收 _playPtt（五条路径，此前全部静默/零执行）', () {
    test('PT-01 缺 audioB64 → 失败留痕 + rc.ptt{ok:false, reason} 定向回执', () async {
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;
      await emitCmd(inbound(RcCmd.pttVoice, {'voiceId': 'v-01'}));
      await waitPttAckSent(sentBefore);

      expect(await countLogs(action: 'ptt.play', status: 'failed'),
          1, reason: '三条失败路径不再静默 —— 必须留痕');
      final evt = await unsealLastEvt();
      expect(evt, isNotNull, reason: '对端松开对讲必须收到明确回执');
      expect(evt!.type, RcEvt.pttAck);
      expect(evt.payload['ok'], false);
      expect(evt.payload['reason'], '缺少 audioB64');
      expect(evt.payload['voiceId'], 'v-01', reason: 'voiceId 必须原样透传，'
          '否则发起方对不上是哪一条语音');
    });

    test('PT-02 有音频但端点未装配播放能力 → 如实回执，不得假装成功', () async {
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;
      // playHandler 保持 null（装配缝没接播放器）。
      await emitCmd(inbound(
          RcCmd.pttVoice, {'voiceId': 'v-02', 'audioB64': base64Encode([1, 2, 3])}));
      await waitPttAckSent(sentBefore);

      expect(
          await countLogs(
              action: 'ptt.play', status: 'failed', contains: '端点未装配播放能力'),
          1);
      final evt = await unsealLastEvt();
      expect(evt!.payload['ok'], false);
      expect(evt.payload['reason'], '端点未装配播放能力');
    });

    test('PT-03 音频先落盘、播放器拒绝 → 文件已在、回执 ok:false', () async {
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;
      svc.playHandler = (path, volume, durationMs, {loop = false}) async {
        played.add((path: path, volume: volume, durationMs: durationMs, loop: loop));
        return false;
      };
      final bytes = base64Encode([9, 8, 7, 6]);
      await emitCmd(inbound(
          RcCmd.pttVoice, {'voiceId': 'v-03', 'audioB64': bytes}));
      await waitPttAckSent(sentBefore);

      expect(played, hasLength(1), reason: '播放器真的被调用了');
      expect(File(played.single.path).existsSync(), isTrue,
          reason: '解密出的音频必须先真实落盘（文件名 ptt_*.m4a）');
      expect(played.single.path.contains('ptt_'), isTrue);
      final evt = await unsealLastEvt();
      expect(evt!.payload['ok'], false);
      expect(evt.payload['reason'], '播放器未接受该音频');
    });

    test('PT-04 全链路成功 → 通知 + 审计 success + rc.ptt{ok:true}', () async {
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;
      var existedAtPlay = false;
      svc.playHandler = (path, volume, durationMs, {loop = false}) async {
        played.add((path: path, volume: volume, durationMs: durationMs, loop: loop));
        // 播放器被调用的**那一刻**文件必须已经落盘 —— 这是 PT-03 的前提，
        // 也是"先落盘再播"的顺序锁。不能改成播完再看（见下面的清理断言）。
        existedAtPlay = File(path).existsSync();
        return true;
      };
      await emitCmd(inbound(RcCmd.pttVoice,
          {'voiceId': 'v-04', 'audioB64': base64Encode([4, 5, 6]), 'fromName': '老王'}));
      await waitPttAckSent(sentBefore);

      expect(played.single.path.endsWith('.m4a'), isTrue);
      expect(existedAtPlay, isTrue,
          reason: '交给播放器的路径必须指向已真实落盘的文件');
      // BUG-114：播放成功后必须删掉临时文件 —— v1 对讲曾把音频写进文档目录
      // 后从不删除，每用一次就永久残留一个 m4a。
      expect(File(played.single.path).existsSync(), isFalse,
          reason: '播放结束后必须清理临时音频，否则对讲用一次漏一个文件');
      expect(shown, hasLength(1), reason: '"来自 x 的语音"必须真的发了通知');
      expect(
          (shown.single as Map)['title'], '声盾 · 对讲');
      expect(
          ((shown.single as Map)['body'] as String).contains('老王'), isTrue,
          reason: 'fromName 缺省时用 peer.name，给了就用消息里的名字');
      expect(await countLogs(action: 'ptt.play', status: 'success'), 1);
      final evt = await unsealLastEvt();
      expect(evt!.payload['ok'], true);
      expect(evt.payload['voiceId'], 'v-04');
    });

    test('PT-05 播放器抛异常 → on Object 兜底接管，异常文本进留痕与回执', () async {
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;
      svc.playHandler = (path, volume, durationMs, {loop = false}) async {
        throw Exception('codec 不支持');
      };
      await emitCmd(inbound(
          RcCmd.pttVoice, {'voiceId': 'v-05', 'audioB64': base64Encode([7])}));
      await waitPttAckSent(sentBefore);

      expect(
          await countLogs(
              action: 'ptt.play', status: 'failed', contains: 'codec 不支持'),
          1, reason: '异常不能被吞 —— 文本必须进审计');
      final evt = await unsealLastEvt();
      expect(evt!.payload['ok'], false);
      expect((evt.payload['reason'] as String).contains('codec 不支持'), isTrue);
    });
  });

  group('EV · 录音取证 _recordEvidence（指令组 record 步骤，此前零执行）', () {
    RcScript script(List<RcStep> steps, {String id = 'sc-ev-1'}) => RcScript(
          scriptId: id,
          name: '取证宏',
          fromName: '控制端49',
          sentAt: 1700000000000,
          steps: steps,
        );

    test('EV-01 麦克风权限未授予 → 留痕 failed，绝不静默 return', () async {
      installFakeRecordPlatform(hasPermissionResult: false);
      await svc.debugDispatch(
          inbound(RcCmd.scriptRun,
              script([const RcStep(RcStepKind.record, {'seconds': 1})]).toJson()),
          peer);
      await settle();

      expect(
          await countLogs(
              action: 'record', status: 'failed', contains: '麦克风权限未授予'),
          1, reason: '"没录成且一条日志都没有"正是这条分支要消灭的形状');
      // 权限拒绝发生在 start 之前：一次 start 都不该有。
      expect(
          await countLogs(action: 'record', status: 'success'), 0);
    });

    test('EV-02 授权 + 正常到点 → 文件名进审计（success），状态不是"完成"二字能混的',
        () async {
      final rec = installFakeRecordPlatform(
          hasPermissionResult: true, stopPath: '/fake/out.m4a');
      await svc.debugDispatch(
          inbound(RcCmd.scriptRun,
              script([const RcStep(RcStepKind.record, {'seconds': 1})],
                  id: 'sc-ev-2').toJson()),
          peer);
      await settle();

      expect(rec.calls, containsAll(['create', 'hasPermission', 'start', 'stop']),
          reason: '真的走了录音通道（平台层假实现的真实调用序列）');
      final rows = await logs();
      final hit = rows
          .where((r) => r['action'] == 'record' && r['status'] == 'success')
          .toList();
      expect(hit, hasLength(1));
      expect((hit.single['message'] as String).contains('evidence_rc_'), isTrue,
          reason: '审计里必须能找回证据文件名');
    });

    test('EV-03 start 即失败 → on Object 兜底：留痕 failed 且带原因', () async {
      installFakeRecordPlatform(
          hasPermissionResult: true, startError: Exception('麦克风被占用'));
      await svc.debugDispatch(
          inbound(RcCmd.scriptRun,
              script([const RcStep(RcStepKind.record, {'seconds': 1})],
                  id: 'sc-ev-3').toJson()),
          peer);
      await settle();

      expect(
          await countLogs(
              action: 'record', status: 'failed', contains: '麦克风被占用'),
          1);
    });

    test('EV-04 终止令牌在窗口内到达 → aborted：状态是 skipped，不是 success',
        () async {
      installFakeRecordPlatform(hasPermissionResult: true);
      // 窗口 3 秒，300ms 时叫停 —— runRecordWindow 的"收到终止且已停掉"终态。
      unawaited(Future<void>.delayed(const Duration(milliseconds: 300))
          .then((_) => RcScriptExecutor.instance.stop()));
      await svc.debugDispatch(
          inbound(RcCmd.scriptRun,
              script([const RcStep(RcStepKind.record, {'seconds': 3})],
                  id: 'sc-ev-4').toJson()),
          peer);
      await settle();

      expect(
          await countLogs(
              action: 'record', status: 'skipped', contains: '录音取证被终止'),
          1, reason: '被终止的取证不算成功 —— 三种终态必须可分');
      expect(await countLogs(action: 'record', status: 'success'), 0);
    });
  });

  group('AS · 音源库桶（_sendAssets / _assetPathById）', () {
    Future<void> seedAssets() async {
      final repo = AssetRepository(db);
      await repo.upsert(AudioAsset(
        id: 'a1',
        name: '白噪声',
        path: 'assets_sounds/a1.m4a',
        durationMs: 32000,
        tags: const ['预置/雨声'],
        createdAt: DateTime(2024, 1, 1),
      ));
      await repo.upsert(AudioAsset(
        id: 'a2',
        name: '海浪',
        path: 'assets_sounds/a2.m4a',
        durationMs: 51000,
        tags: const ['预置/海浪'],
        createdAt: DateTime(2024, 1, 2),
      ));
    }

    test('AS-01 rc.assetList → rc.assets 真回执：total 与 limit 截断都对', () async {
      await seedAssets();
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;
      await emitCmd(inbound(RcCmd.assetList, {'limit': 1}));
      await until(() => fake.sentWires.length > sentBefore, 'rc.assets 回执投出');

      final evt = await unsealLastEvt();
      expect(evt, isNotNull);
      expect(evt!.type, RcEvt.assets);
      expect(evt.payload['total'], 2, reason: 'total 是全库数，不是截断后的数');
      final assets =
          (evt.payload['assets'] as List).cast<Map<Object?, Object?>>();
      expect(assets, hasLength(1), reason: 'limit=1 必须真的截断');
      expect(assets.single['id'], 'a2',
          reason: 'listAll 按 created_at DESC ⇒ **最新在前**（a2 是后写入的）');
      expect(assets.single['name'], '海浪');
      expect(assets.single['durationMs'], 51000);
      expect(assets.single['tags'], ['预置/海浪']);
    });

    test('AS-02 sound.play{assetId} → 按 ID 精确取音源（BUG-048 的行为侧锁）',
        () async {
      await seedAssets();
      await svc.start(store, db);
      final sentBefore = fake.sentWires.length;
      svc.playHandler = (path, volume, durationMs, {loop = false}) async {
        played.add((path: path, volume: volume, durationMs: durationMs, loop: loop));
        return true;
      };
      await emitCmd(
          inbound(RcCmd.soundPlay, {'assetId': 'a2', 'volume': 0.5}));
      await until(() => fake.sentWires.length > sentBefore, 'rc.ack 投出');

      expect(played, hasLength(1));
      expect(played.single.path, 'assets_sounds/a2.m4a',
          reason: '必须按 assetId 精确命中 —— 被忽略 ID 就是 BUG-048 复活');
      expect(played.single.volume, 0.5);
      expect(await countLogs(action: 'play', status: 'success'), 1);
    });
  });
}
