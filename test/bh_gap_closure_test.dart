import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/guarded_dispatch.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/notification_service.dart';
import 'package:sonic_shield/services/vibrate_session.dart';

import 'support/mqtt_client_stub.dart';

/// 第五十八轮 · **覆盖率冲刺（第一轮）**：把「可测面残差」里**宿主上确实可达**
/// 的那部分逐个执行一遍，实测抬高覆盖率，并把**不可达**的残差逐行给出证据。
///
/// 本文件只放「此前从未被执行过、且宿主上能安全驱动」的路径；不写
/// 「为覆盖率而覆盖率」的空断言（项目既有裁决，见 `docs/12 §87`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // ══════════════════════════════════════════════════════════════════
  // G1 · 域 / 仓储层零散缺口（纯异步，无 widget 树）
  // ══════════════════════════════════════════════════════════════════

  group('G1 域 / 仓储零散缺口', () {
    late AppDatabase appDb;

    setUp(() async {
      appDb = await AppDatabase.open(inMemoryDatabasePath);
    });

    tearDown(() async {
      await appDb.close();
    });

    Task makeTask(String id) {
      final now = DateTime.now();
      return Task(
        id: id,
        name: '任务$id',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(volumeMin: 0.3, volumeMax: 0.7),
        assetIds: const ['a1'],
        cooldownSec: 300,
        quietPolicy: QuietPolicy.shift,
        priority: 2,
        createdAt: now,
        updatedAt: now,
      );
    }

    test('G1-01 OccurrenceRepository.lastDoneFor 命中 done 行并回填 fire_at', () async {
      await TaskRepository(appDb).upsert(makeTask('t1'));
      final repo = OccurrenceRepository(appDb);
      await repo.commitAll([
        PlannedOccurrence(
          id: 't1@1000',
          taskId: 't1',
          fireAt: DateTime.fromMillisecondsSinceEpoch(1000),
          status: OccurrenceStatus.pending,
        ),
      ]);
      // pending 不算「最近一次成功」⇒ null 分支。
      expect(await repo.lastDoneFor('t1'), isNull);

      await repo.markStatus('t1@1000', OccurrenceStatus.done);
      final got = await repo.lastDoneFor('t1');
      expect(got, isNotNull);
      expect(got!.millisecondsSinceEpoch, 1000);
    });

    test('G1-02 LogRepository.purgeOlderThan 删除早于阈值的日志', () async {
      final repo = LogRepository(appDb);
      await repo.append(source: 'test', action: 'a', status: 'success', message: 'old');
      await repo.append(source: 'test', action: 'b', status: 'success', message: 'new');

      final removed = await repo.purgeOlderThan(
          DateTime.now().add(const Duration(days: 1)));
      expect(removed, 2, reason: '阈值在未来 ⇒ 两条都早于阈值，全删');
      expect(await repo.recent(limit: 10), isEmpty);
    });

    test('G1-03 GuardedOutcome.toString 两种形态可读', () {
      expect(GuardedOutcome.success.toString(), 'GuardedOutcome.success');
      final f = GuardedOutcome.failed('boom', StateError('x'));
      expect(f.toString(), contains('GuardedOutcome.failed(boom'));
      expect(f.toString(), contains('auditOk=true'));
    });

    test('G1-04 NotificationService.plugin getter 暴露底层插件实例', () {
      expect(NotificationService.instance.plugin, isNotNull);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // G2 · EndpointService._send 的丢弃审计分支 + 协助传输订阅/退订
  // ══════════════════════════════════════════════════════════════════

  group('G2 EndpointService 出站丢弃审计 + 协助传输', () {
    const ownId = 'EP58own00000abc';
    const ctrlId = 'CTRL58peer00001';
    const brokerName = 'broker.round58.invalid';

    final svc = RcEndpointService.instance;

    late SharedPreferences prefs;
    late RemoteStore store;
    late KdfSaltStore salts;
    late AppDatabase db;
    late FakeMqttServerClient fake;
    late PairedEndpoint peer;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = RemoteStore(prefs);
      await store.setIdentity(ownId, '端点机58');
      await store.setBroker(brokerName);
      await store.ensurePairingCode();
      salts = KdfSaltStore(prefs);
      db = await AppDatabase.open(inMemoryDatabasePath);
      peer = PairedEndpoint(
        deviceId: ctrlId,
        name: '控制端58',
        secret: 'CODE5801',
        pairedAt: DateTime(2024, 1, 1),
      );

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
      await fake.dispose();
      await db.close();
    });

    RcMessage inbound(String type,
        {Map<String, dynamic> payload = const {}, String from = ctrlId}) {
      final n = RcMessage.now(type, payload);
      return RcMessage(
          id: n.id, ts: n.ts, type: n.type, payload: n.payload, from: from);
    }

    Future<void> settle([int rounds = 8]) async {
      for (var i = 0; i < rounds; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('G2-01 客户端存在但未连接 ⇒ 出站走「MQTT 未连接」留痕，不静默丢',
        () async {
      fake.failConnect = true;
      await store.addPaired(peer);
      await svc.start(store, db);
      await settle();

      await svc.debugDispatch(inbound(RcCmd.ping), peer);
      await settle();

      final logs = await LogRepository(db).recent(limit: 50);
      expect(
        logs.any((r) => (r['message'] as String? ?? '').contains('MQTT 未连接')),
        isTrue,
        reason: '僵尸连接（_client 在、状态非 connected）必须留痕，否则表现为"命令石沉大海"',
      );
    });

    test('G2-02 连接正常但配对表为空 ⇒ 出站走「无已配对端点」留痕', () async {
      // 刻意不 addPaired。
      await svc.start(store, db);
      await settle();

      await svc.debugDispatch(inbound(RcCmd.ping), peer);
      await settle();

      final logs = await LogRepository(db).recent(limit: 50);
      expect(
        logs.any((r) => (r['message'] as String? ?? '').contains('无已配对端点')),
        isTrue,
      );
    });

    test('G2-03 点名了不存在的控制端 ⇒ 显式留痕，绝不退而广播', () async {
      await store.addPaired(peer);
      await svc.start(store, db);
      await settle();

      await svc.debugDispatch(
          inbound(RcCmd.ping, from: 'GHOST00000000000'), peer);
      await settle();

      final logs = await LogRepository(db).recent(limit: 50);
      expect(
        logs.any((r) =>
            (r['message'] as String? ?? '').contains('目标控制端不在配对表')),
        isTrue,
        reason: '点名投递找不到人时广播 = 跨控制器泄露（本函数存在的意义）',
      );
      // 且：一条都没真发出去。
      expect(fake.sentWires, isEmpty);
    });

    test('G2-04 协助会话：start() 订阅会合主题，close() 退订 —— 走真实传输实现',
        () async {
      await store.addPaired(peer);
      await svc.start(store, db);
      await settle();
      fake.subscribed.clear();

      final session = await RcAssistHost.instance.start();
      expect(fake.subscribed, contains(session.topic),
          reason: '协助会话的会合主题必须真的订上，否则控制端接不进来');

      await RcAssistHost.instance.close(reason: 'local', silent: true);
      expect(fake.unsubscribed, contains(session.topic),
          reason: '会话终止必须退订，否则残订阅会持续收到已废弃会话的报文');
    });

    test('G2-05 振铃超时信号：生产注册的 onRingTimeout 闭包真的把 callMissed 交出去',
        () async {
      await store.addPaired(peer);
      await svc.start(store, db);
      await settle();

      // `_wireCall` 已在 start() 内装好回调 —— 这里驱动的是**生产代码注册的闭包
      // 本身**（宿主机造不出真实振铃超时），不是绕过生产路径。
      final cb = CallService.instance.onRingTimeout;
      expect(cb, isNotNull, reason: 'start() 必须接线；否则"没人接"永远发不出信令');
      final before = fake.sentWires.length;
      await cb!('call-58-x');
      await settle();

      expect(fake.sentWires.length, before + 1,
          reason: 'callMissed 必须真的经过出站通道（已配对 + 已连接 ⇒ 投递成功）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // G3 · 域模型 / 服务零散缺口（二）
  // ══════════════════════════════════════════════════════════════════

  group('G3 域模型 / 服务零散缺口（二）', () {
    test('G3-01 ActionConfig.kind 穷尽 switch：randomFrom / composite / soundscape',
        () {
      final set = ActionSetAction(candidates: [
        const ActionSetCandidate(
            weight: 1,
            action: PlayAudioAction(volumeMin: .1, volumeMax: .2)),
        const ActionSetCandidate(
            weight: 2,
            action: PlayAudioAction(volumeMin: .3, volumeMax: .4)),
      ]);
      expect(set.kind, 'randomFrom');

      const comp = CompositeAction(
          primary: PlayAudioAction(volumeMin: .1, volumeMax: .2));
      expect(comp.kind, 'composite');

      final sc = SoundscapeAction(
          tracks: [const SoundscapeTrack(presetCategory: 'ambient')]);
      expect(sc.kind, 'soundscape');
    });

    test('G3-02 VibrateSession.standard 装配成功 + 初始态 getter', () async {
      final db = await AppDatabase.open(inMemoryDatabasePath);
      addTearDown(db.close);

      final s = VibrateSession.standard(
        LogRepository(db),
        battery: () async => (level: 88, charging: false),
      );
      expect(s.isActive, isFalse);
      expect(s.activeCount, 0);
      expect(s.activeIds, isEmpty);
    });
  });
}
