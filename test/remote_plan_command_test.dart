import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/counter_plan_store.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/mqtt_client_stub.dart';

/// v2.0 远程反击计划命令（`plan.apply` / `plan.get` / `plan.stop`）的回归锁
/// （计划第 23 条：远程 plan 命令权限与回执）。
///
/// ## 锁什么
/// 1. `RcPermGate` 对三条命令的**权限映射**（只读免授权 / 需 `script` 位 /
///    未登记 denyAll）——默认拒绝，判据非恒真；
/// 2. `plan.apply` 的**回执**：合法计划 ack ok 且真落库；非法计划 ack 失败且
///    **绝不落库**；
/// 3. `plan.stop` 的**回执**：下线后 ack ok 且启用位翻 false；
/// 4. `plan.get` 的**回执**：发 `rc.plan` 事件，for/enabled/planId/taskCount/plan
///    逐字段真实。
///
/// ## 手法（与既有夹具同族，不复制大文件）
/// 命令经 `debugDispatch` 驱动**真** `_dispatch`；`_send` / `_ack` 的落点用
/// `debugClientFactory` 注入 `FakeMqttServerClient`（`endpoint_mqtt_link_test.dart`
/// 的替身）让回执**真的发出去**，再用**对端密钥**把密文解回来逐字段断言 ——
/// 不是"打个桩让发送恒成功"，跑的是生产发送链路本身。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const ownId = 'EPRPown000000abc';
  const ctrlId = 'CTRLRPpeer000001';
  const broker = 'broker.roundrp.invalid';

  final svc = RcEndpointService.instance;

  late SharedPreferences prefs;
  late RemoteStore store;
  late AppDatabase db;
  late FakeMqttServerClient fake;
  late PairedEndpoint peer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    await store.setIdentity(ownId, '端点RP');
    await store.setBroker(broker);
    await store.ensurePairingCode();
    db = await AppDatabase.open(inMemoryDatabasePath);
    peer = PairedEndpoint(
      deviceId: ctrlId,
      name: '控制端RP',
      secret: 'CODERP01',
      pairedAt: DateTime(2024, 1, 1),
    );
    await store.addPaired(peer);
    fake = FakeMqttServerClient(broker, ownId);
    svc.debugClientFactory = (broker, clientId, port) => fake;
    await svc.start(store, db);
  });

  tearDown(() async {
    await svc.stop();
    svc.debugClientFactory = null;
    await fake.dispose();
    await db.close();
  });

  RcMessage cmd(String type, [Map<String, dynamic> payload = const {}]) {
    final n = RcMessage.now(type, payload);
    return RcMessage(
        id: n.id, ts: n.ts, type: n.type, payload: n.payload, from: ctrlId);
  }

  Future<void> settle([int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 驱动一条命令，返回**本次**新发出的全部密文（清空前序残留）。
  Future<List<FakeMqttPublish>> dispatchCapture(RcMessage msg) async {
    fake.sentWires.clear();
    await svc.debugDispatch(msg, peer);
    await settle();
    return List<FakeMqttPublish>.of(fake.sentWires);
  }

  /// 用**对端密钥**把端点发到本机 evt 主题的密文解回来。
  Future<RcMessage?> decode(FakeMqttPublish p) async {
    final key = await RcCodec.deriveKey(peer.secret, '${peer.deviceId}|evt');
    return RcCodec.decode(p.wire, key, p.topic);
  }

  Future<RcMessage?> findSent(List<FakeMqttPublish> wires, String type) async {
    for (final w in wires) {
      final m = await decode(w);
      if (m != null && m.type == type) return m;
    }
    return null;
  }

  Future<bool> hasLog(
      {String? action, String? status, String? contains}) async {
    final rows = await LogRepository(db).recent(limit: 200);
    return rows.any((r) {
      if (action != null && r['action'] != action) return false;
      if (status != null && r['status'] != status) return false;
      if (contains != null &&
          !((r['message'] as String? ?? '').contains(contains))) {
        return false;
      }
      return true;
    });
  }

  // ═══════════════════════════════ RP-01 权限闸门

  group('RP-01 RcPermGate：plan 命令的权限映射', () {
    test('RP-01a plan.get 只读免授权；plan.apply / plan.stop 需 script 位', () {
      expect(RcPermGate.requiredPerm(RcCmd.planGet), isNull,
          reason: '查询快照是只读，不应要求授权');
      expect(RcPermGate.requiredPerm(RcCmd.planApply), 'script',
          reason: '应用计划会持久改写端点状态，必须持 script 位');
      expect(RcPermGate.requiredPerm(RcCmd.planStop), 'script',
          reason: '下线计划同样改写持久状态，必须持 script 位');
    });

    test('RP-01b 默认全拒：未放行 script 时 apply / stop 均被拒（含相反用例）', () {
      expect(RcPermGate.allows(AssistPerms.none, RcCmd.planApply), isFalse);
      expect(RcPermGate.allows(AssistPerms.none, RcCmd.planStop), isFalse);
      // 反例：全拒下只读命令仍放行 ⇒ 闸门不是恒 false（判据非恒真）。
      expect(RcPermGate.allows(AssistPerms.none, RcCmd.planGet), isTrue);
    });

    test('RP-01c 放行 script 位后 apply / stop 才可执行；映射未漂移', () {
      const script = AssistPerms(script: true);
      expect(RcPermGate.allows(script, RcCmd.planApply), isTrue);
      expect(RcPermGate.allows(script, RcCmd.planStop), isTrue);
      // 反例：script 位不应顺带放行其它域的命令。
      expect(RcPermGate.allows(script, RcCmd.soundPlay), isFalse,
          reason: 'script 位 ≠ media 位，映射不得漂移');
      // 未登记命令 → denyAll，恒被拒（默认拒绝，失败关闭）。
      expect(RcPermGate.requiredPerm('plan.unknown'), RcPermGate.denyAll);
      expect(RcPermGate.allows(script, 'plan.unknown'), isFalse);
    });
  });

  // ═══════════════════════════════ RP-02 plan.apply（合法）

  group('RP-02 plan.apply 回执：合法计划落库 + ack ok', () {
    test('RP-02 合法计划 → ack ok 且 counter_plan_enabled 真为 true', () async {
      final msg = cmd(RcCmd.planApply, {
        'plan': CounterPlan.defaults().toJson(),
      });
      final wires = await dispatchCapture(msg);

      expect(prefs.getBool('counter_plan_enabled'), isTrue,
          reason: '回执 ok 必须与"计划真的落库并启用"一致');
      expect(prefs.getString('counter_plan_json'), isNotNull);

      final ack = await findSent(wires, RcEvt.ack);
      expect(ack, isNotNull, reason: 'plan.apply 必须回 rc.ack');
      expect(ack!.payload['for'], msg.id);
      expect(ack.payload['ok'], isTrue);
      expect(ack.payload['data'] as String, startsWith('tasks='));
      expect(await hasLog(action: 'plan.apply', status: 'success'), isTrue);
    });
  });

  // ═══════════════════════════════ RP-03 plan.apply（非法）

  group('RP-03 plan.apply 回执：非法计划 ack 失败且绝不落库', () {
    test('RP-03a 缺 plan → 明确回执"缺少 plan"，且不落库', () async {
      final msg = cmd(RcCmd.planApply);
      final wires = await dispatchCapture(msg);

      final ack = await findSent(wires, RcEvt.ack);
      expect(ack, isNotNull);
      expect(ack!.payload['for'], msg.id);
      expect(ack.payload['ok'], isFalse);
      expect(ack.payload['data'], '缺少 plan');
      expect(prefs.getBool('counter_plan_enabled'), isNot(true));
      expect(prefs.getString('counter_plan_json'), isNull,
          reason: '缺 plan 时绝不能留下任何计划痕迹');
    });

    test('RP-03b 校验不过的计划 → ack 失败，且不落库', () async {
      // schema 不匹配 + 动作池为空 ⇒ validate() 非空 ⇒ apply 前置失败。
      final bad = CounterPlan.defaults().toJson()
        ..['schema'] = 'sonicshield.counterPlan/999'
        ..['presetIds'] = <String>[]
        ..['ttsTexts'] = <String>[];
      final msg = cmd(RcCmd.planApply, {'plan': bad});
      final wires = await dispatchCapture(msg);

      final ack = await findSent(wires, RcEvt.ack);
      expect(ack, isNotNull);
      expect(ack!.payload['for'], msg.id);
      expect(ack.payload['ok'], isFalse);
      expect(ack.payload['data'] as String, contains('校验未通过'));
      expect(prefs.getBool('counter_plan_enabled'), isNot(true),
          reason: '不合格计划绝不落库');
      expect(prefs.getString('counter_plan_json'), isNull);
      expect(await hasLog(action: 'plan.apply', status: 'failed'), isTrue);
    });
  });

  // ═══════════════════════════════ RP-04 plan.stop

  group('RP-04 plan.stop 回执：下线启用计划', () {
    test('RP-04 先落启用计划 → stop → ack ok 且 enabled 翻 false', () async {
      await CounterPlanStore(prefs)
          .savePlan(CounterPlan.defaults(), id: 'rpstop', enabled: true);
      expect(prefs.getBool('counter_plan_enabled'), isTrue);

      final msg = cmd(RcCmd.planStop);
      final wires = await dispatchCapture(msg);

      expect(prefs.getBool('counter_plan_enabled'), isFalse,
          reason: 'stop 必须真的把启用位置 false');
      final ack = await findSent(wires, RcEvt.ack);
      expect(ack, isNotNull);
      expect(ack!.payload['for'], msg.id);
      expect(ack.payload['ok'], isTrue);
      expect(ack.payload['data'] as String, startsWith('stopped='));
      expect(await hasLog(action: 'plan.stop', status: 'success'), isTrue);
    });
  });

  // ═══════════════════════════════ RP-05 plan.get

  group('RP-05 plan.get 回执：rc.plan 快照逐字段', () {
    test('RP-05 已应用计划 → for/enabled/planId/taskCount/plan 均真实', () async {
      final applyMsg =
          cmd(RcCmd.planApply, {'plan': CounterPlan.defaults().toJson()});
      final applyWires = await dispatchCapture(applyMsg);
      final applyAck = await findSent(applyWires, RcEvt.ack);
      final applied = int.parse(
          (applyAck!.payload['data'] as String).substring('tasks='.length));
      expect(applied, greaterThan(0), reason: '前提：合法计划确已排出任务');

      final getMsg = cmd(RcCmd.planGet);
      final wires = await dispatchCapture(getMsg);
      final snapshot = await findSent(wires, RcEvt.plan);
      expect(snapshot, isNotNull, reason: 'plan.get 必须回传 rc.plan 事件');
      expect(snapshot!.payload['for'], getMsg.id);
      expect(snapshot.payload['enabled'], isTrue);
      expect(snapshot.payload['planId'], isA<String>());
      expect(snapshot.payload['taskCount'], applied,
          reason: 'taskCount 必须等于端点真实已排计划任务数（与 apply 回执一致）');
      expect(snapshot.payload['plan'], isA<Map<String, dynamic>>());
    });

    test('RP-05b 空配置 → rc.plan 仍发出，enabled=false / plan=null / taskCount=0',
        () async {
      final getMsg = cmd(RcCmd.planGet);
      final wires = await dispatchCapture(getMsg);
      final snapshot = await findSent(wires, RcEvt.plan);
      expect(snapshot, isNotNull);
      expect(snapshot!.payload['for'], getMsg.id);
      expect(snapshot.payload['enabled'], isFalse);
      expect(snapshot.payload['plan'], isNull);
      expect(snapshot.payload['taskCount'], 0);
    });
  });
}