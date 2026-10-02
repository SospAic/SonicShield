/// 覆盖率冲刺（第十轮）—— `endpoint_service.dart` 三块**真实可达**的未覆盖分支。
///
/// ## 本轮的三块目标（来自第六十六轮 lcov 实测归因，非推断）
///
/// | 块 | 行 | 为什么此前没被执行过 |
/// |---|---|---|
/// ① 协助会话的**步骤级**权限裁决 | 1708–1717 | `gateRcScriptStep` **纯函数**在 `endpoint_script_step_perm_test.dart` 被穷举断言过，但 `runner(RcStep)` 里那段 Zone 裁决**只在协助会话内**才进（判据是 `Zone.current[assistReplyZone] == true`）。既有 `B-07` 只驱了**动作级**（`task.runNow` / `task.toggle`），**步骤级**这条整块一行没跑过。 |
/// ② `refreshSubscriptions` 的**协助**主题补订 | 557 | 传输层测试（`endpoint_mqtt_link_test.dart`）只验证「本机 `cmd` + 端点 `evt`」两条主线；协助会话主题的补订只有外层 `if` 守卫被走过，**订阅动作那一行**从未执行。 |
/// ③ `_MqttAssistTransport.publishWire` | 2495–2502 | `AssistTransport` 的 `publishWire` **替身实现**在测试里各有一份（`assist_*_test.dart`），**生产这一份**从未被驱动 —— 它是协助链路的**真实出站**。 |
///
/// ## 驱动方式（零生产代码改动，`lib/**` 一字未动 ⇒ 分母不变）
///
/// 全部走既有 `@visibleForTesting` 缝 + **公开 API**：
/// - `debugClientFactory`（假 MQTT 客户端，第 48 轮新增）—— 让「有 client 且已连接」成立；
/// - `svc.start()` —— 生产路径，会 `bind()` 两个 transport（`assist_host.dart` / `assist_join.dart`）；
/// - `RcAssistHost.instance.start()` + `grant(...)` —— **公开**入口建会话与开权限位
///   （`AssistHost._session` 是私有字段且**故意没有**测试缝：本轮不为测试改生产代码）；
/// - `AssistJoinClient.instance.join(...)` —— 公开入口，同上（`_topic` 私有、无缝）。
///
/// ① 的关键是要**真的进 `assistReplyZone`** —— 与 `B-07` 同款：
/// `runZoned(body, zoneValues: {assistReplyZone: true})`。
///
/// ## 诚实边界
///
/// - ① 只断言**审计行**（`script.run` / `skipped`）与拒绝理由；不试图驱动被拒步骤的
///   **执行体**（那正是要被权限门挡住的东西）。
/// - ② 只断言**订阅主题集合**，不连真 broker；协助会话的 `start()` 会自己订阅一次，
///   所以断言的是「集合里**有**它」而不是「恰好一次」。
/// - ③ 断言**真的发出了密文**且**能按协助会话身份解开**（真 `RcCodec` 真密文，
///   与 `B-04` 同款判据），不只看 `sentWires` 非空。
@Timeout(Duration(seconds: 180))
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/assist_join.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/remote/script_executor.dart';

import 'support/mqtt_client_stub.dart';

const _notifChannel = 'dexterous.com/flutter/local_notifications';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final svc = RcEndpointService.instance;
  late AppDatabase db;
  late RemoteStore store;
  late FakeMqttServerClient fake;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_notifChannel), (call) async {
      // `initialize` 的平台层返回 bool（非 bool?）⇒ 桩必须回 true，否则
      // `Null is not a subtype of FutureOr<bool>`（第四十四轮实测）。
      return call.method == 'initialize' ? true : null;
    });
    db = await AppDatabase.open(inMemoryDatabasePath);
    store = RemoteStore(await SharedPreferences.getInstance());
    // ★ 必须先装配身份：`_connect()` 的第一行就是 `if (deviceId.isEmpty) return;`
    //   （`endpoint_service.dart`）—— 空身份 ⇒ 连接从未建立 ⇒ `refreshSubscriptions`
    //   与 `publishWire` 都在 `client == null` 处早退。本组要测的正是这两条传输路径。
    //   这与 `remote_screen.dart:138-143`（首次启动装配身份）是同一条生产逻辑。
    await store.setIdentity('EP0067BQ0001', '声盾-BQ');
    fake = FakeMqttServerClient('broker.bq.invalid', 'EP0067BQ0001');
    svc.debugClientFactory = (b, c, p) => fake;
    svc.debugBind(store: store, db: db);
  });

  tearDown(() async {
    // 单例注入必须清干净（`RcEndpointService` / `RcAssistHost` / `AssistJoinClient`
    // 都是进程内单例，残留会污染同文件后续用例的 TTL 与权限位）。
    svc.debugClientFactory = null;
    svc.debugSendTo = null;
    svc.playHandler = null;
    svc.resolvePresetHandler = null;
    svc.ttsHandler = null;
    svc.vibrateHandler = null;
    svc.vibrateActionHandler = null;
    RcScriptExecutor.instance.stop();
    // 🔴 必须 `stop()`：`RcEndpointService.start()` 开头是 `if (_running) return;`
    //   —— `_running` 是**单例字段**，不复位的话第 2 例起 `start()` 直接 return，
    //   `debugClientFactory` 永不被调用、`_client` 恒为 null ⇒
    //   `refreshSubscriptions` / `publishWire` 全在 `client == null` 处早退，
    //   表现为「订阅集合恒为空」（首跑实测：B1/B3/C1 三例集体假红）。
    await svc.stop();
    await RcAssistHost.instance.close(reason: 'test-teardown', silent: true);
    await AssistJoinClient.instance.leave(silent: true);
    // 🔴 必须还原 `audit` / `onCommand`：`svc.start()` 把它们写成**捕获当轮 `db`**
    //   的闭包，而 `RcAssistHost` 是进程内单例。不清 ⇒ 下一例的握手会往
    //   **已关闭的库**写审计，抛 `DatabaseException(error database_closed)`
    //   （首跑实测：A2/A3 双双假红，症状与被测点毫无关系）。
    RcAssistHost.instance.audit = null;
    RcAssistHost.instance.onCommand = null;
    try {
      await db.close();
    } on Object {
      // 忽略：在飞的终态通知计时器可能已把库关掉。
    }
  });

  RcMessage cmd(String type, [Map<String, dynamic> payload = const {}]) =>
      RcMessage.now(type, payload);

  PairedEndpoint peerOf(String id, String name, String code) => PairedEndpoint(
        deviceId: id,
        name: name,
        secret: code,
        pairedAt: DateTime(2024, 1, 1),
      );

  RcScript script(List<RcStep> steps, {String id = 'sc-bq'}) => RcScript(
        scriptId: id,
        name: '宏',
        fromName: '控制器',
        sentAt: 1700000000000,
        steps: steps,
      );

  Future<bool> hasLog(String action, String status, {String? contains}) async {
    final rows = await LogRepository(db).recent(limit: 200);
    return rows.any((r) {
      if (r['action'] != action || r['status'] != status) return false;
      final m = r['message'] as String? ?? '';
      return contains == null || m.contains(contains);
    });
  }

  /// 等 `RcScriptExecutor` 的收尾定时器落定，否则下一条会撞上「上一次仍在跑」。
  Future<void> settle() async {
    for (var i = 0; i < 80 && RcScriptExecutor.instance.isRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 协助会话的业务命令**永远**跑在这个 Zone 里（`RcAssistHost._onBusiness`
  /// 用 `runZoned` 注入，Zone 随异步链传播）。
  Future<void> inAssistZone(Future<void> Function() body) =>
      runZoned(body, zoneValues: {assistReplyZone: true});

  /// 走完 `assist.hello` 握手，把会话推进到 `active`。
  ///
  /// ★ 为什么必须这一步：[RcAssistHost.grant] 的第一道守卫是
  /// `if (s == null || k == null || s.phase != AssistPhase.active) return false`
  /// —— `start()` 之后的 phase 是 `waiting`、密钥环还是 null。跳过握手就
  /// `grant` 会静默返回 false、权限位**一位都没开**，于是「有 media 位就放行」
  /// 那半边断言会以 `played == []` 假红（首跑实测踩到）。
  Future<AssistSession> startActiveSession({
    String ctrlName = '协助控制端',
  }) async {
    final s = await RcAssistHost.instance.start();
    final wire = await RcCodec.encode(
      RcMessage.now(RcAssistCmd.hello, {'ctrlName': ctrlName}),
      await RcAssist.ctlKey(s.code, s.password),
      s.topic,
    );
    await RcAssistHost.instance.onWire(wire);
    expect(RcAssistHost.instance.active, isTrue,
        reason: '前置：握手必须真的把 phase 推进到 active');
    return s;
  }

  // ══════════════════════════════════════════════════════════════════════
  // ① 协助会话的步骤级权限裁决（1708–1717）
  // ══════════════════════════════════════════════════════════════════════

  group('BQ-A 协助会话「步骤级」权限裁决（Zone 内集成路径）', () {
    test('BQ-A1 record 步在协助会话内必须被步骤级裁决拦下并写明拒绝理由', () async {
      // ★ 本组三例都**必须**先 `svc.start()`：它才是给 `RcAssistHost` / 
      // `AssistJoinClient` bind transport 的地方，也是端点服务「已启动」的
      // 真实前提（`_store` / `_db` 非空）。
      await svc.start(store, db);
      // 端点侧发起协助会话（公开 API）。此刻 phase=waiting、perms=全 false。
      final session = await RcAssistHost.instance.start();
      expect(RcAssistHost.instance.session, isNotNull);

      // `record` 映射到 denyAll ⇒ **任何**权限位都放行不了它。
      final s = script(const [RcStep(RcStepKind.record, {'seconds': 1})]);
      await inAssistZone(() async {
        await svc.debugDispatch(
            cmd(RcCmd.scriptRun, s.toJson()), peerOf('CTRLQ', '协助控制端', 'S'));
      });
      await settle();

      expect(
          await hasLog('script.run', 'skipped', contains: '被拒绝'),
          isTrue,
          reason: '★ 命令级门控只把 `script.run` 映射到 `script` 位 —— 不做**步骤级**'
              '裁决，只放行 script 位的协助方就能借指令组完成录音取证（denyAll）。'
              '这条整块此前只有纯函数被测，Zone 内的集成裁决一行没跑过。');
      expect(
          await hasLog('script.run', 'skipped', contains: 'record'),
          isTrue,
          reason: '拒绝理由必须**指名道姓**说出第几步、什么 kind，'
              '否则协助方无法判断该改权限还是该改脚本');
      expect(session.code, isNotEmpty);
    });

    test('BQ-A2 play 步在只有 script 位时同样被拒；补上 media 位后放行', () async {
      await svc.start(store, db);
      await startActiveSession();

      // 缺 media 位 ⇒ play 步**根本不该进播放分支**（用可观测替身判定）。
      final played = <String?>[];
      svc.resolvePresetHandler = (cat) async {
        played.add(cat);
        return '/tmp/bq-a2.wav';
      };
      addTearDown(() => svc.resolvePresetHandler = null);

      await inAssistZone(() async {
        await svc.debugDispatch(
            cmd(
                RcCmd.scriptRun,
                script(const [
                  RcStep(RcStepKind.play, {'presetCategory': '闹钟'})
                ], id: 'sc-bq-a2-deny')
                    .toJson()),
            peerOf('CTRLQ', '协助控制端', 'S'));
      });
      await settle();
      expect(played, isEmpty, reason: '缺 media 位时 play 步不该进播放分支');
      expect(await hasLog('script.run', 'skipped', contains: '播放'), isTrue,
          reason: '拒绝理由要点明缺的是哪条能力位');

      // 走**真实**的授权入口开位：只有 script（仍无 media）⇒ 还是拒绝；
      // 再加上 media ⇒ 必须真的放行（否则本条会把「一律拒绝」锁成正确行为，假绿）。
      expect(await RcAssistHost.instance.grant(const AssistPerms(script: true)),
          isTrue,
          reason: '前置：授权必须真的生效 —— `grant` 在 phase≠active / 密钥环缺失时'
              '会**静默返回 false**，位一位都没开（首跑实测踩到这条静默失败）');
      await inAssistZone(() async {
        await svc.debugDispatch(
            cmd(
                RcCmd.scriptRun,
                script(const [
                  RcStep(RcStepKind.play, {'presetCategory': '闹钟'})
                ], id: 'sc-bq-a2-still-deny')
                    .toJson()),
            peerOf('CTRLQ', '协助控制端', 'S'));
      });
      await settle();
      expect(played, isEmpty,
          reason: '⚠️ 反例对照：grant(script) **不含** media ⇒ 仍须被拒。'
              '若这里就放行，说明权限位映射被写成了「有 script 就能播」，'
              '那正是 docs/18 §10 要堵的越权。');

      expect(await RcAssistHost.instance
              .grant(const AssistPerms(script: true, media: true)), isTrue,
          reason: '前置：media 位必须真的开上');
      await inAssistZone(() async {
        await svc.debugDispatch(
            cmd(
                RcCmd.scriptRun,
                script(const [
                  RcStep(RcStepKind.play, {'presetCategory': '闹钟'})
                ], id: 'sc-bq-a2-allow')
                    .toJson()),
            peerOf('CTRLQ', '协助控制端', 'S'));
      });
      await settle();
      expect(played, ['闹钟'],
          reason: '★ 有了 media 位就必须真的放行 —— 否则本条锁会把'
              '「一律拒绝」当成正确行为锁死（假绿）');
    });

    test('BQ-A3 步骤级裁决只作用于协助会话：配对通道（无 Zone）同一脚本必须真的跑',
        () async {
      await svc.start(store, db);
      // 即使**在**协助会话里，配对通道的脚本也不进 assist Zone ⇒ 裁决整段跳过。
      await startActiveSession();
      await RcAssistHost.instance
          .grant(const AssistPerms(script: true, media: true));

      // **不**进 assist Zone —— 配对 = 全权，没有权限位。
      // 用 notify（requiredStepPerm 为 null ⇒ 任何权限都放行）验证整条链没被误伤。
      await svc.debugDispatch(
          cmd(
              RcCmd.scriptRun,
              script(const [
                RcStep(RcStepKind.notify, {'title': 'hi', 'body': 'b'})
              ], id: 'sc-bq-a3')
                  .toJson()),
          peerOf('CTRLQ', '普通控制端', 'S'));
      await settle();

      expect(await hasLog('script.run', 'success'), isTrue,
          reason: '⚠️ 配对通道**没有** `assistReplyZone` ⇒ 步骤级裁决整段跳过。'
              '若这条假红，说明裁决被错误地推广到了配对通道（安全侧被误伤）');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // ② refreshSubscriptions 的协助主题补订（557）
  // ══════════════════════════════════════════════════════════════════════

  group('BQ-B 订阅集合补齐（协助会话主题）', () {
    test('BQ-B1 协助会话在册时 refreshSubscriptions 必须补订协助主题', () async {
      await svc.start(store, db);
      // `start()` 自己就订阅了一次；显式再刷一次，锁的是
      // `refreshSubscriptions` 这条路径（心跳每 60s 调它，靠它补齐新增订阅）。
      final session = await RcAssistHost.instance.start();
      fake.subscribed.clear();
      await svc.refreshSubscriptions();

      expect(fake.subscribed, contains(session.topic),
          reason: '★ 与 BUG-013 同类：订阅集合不补齐 ⇒ 协助链路的回执一条都收不到。'
              '此前这条补订只有外层 `if` 守卫被走过，订阅动作那一行从未执行。');
    });

    test('BQ-B2 无协助会话时不得凭空订阅协助主题（不制造幽灵订阅）', () async {
      await svc.start(store, db);
      expect(RcAssistHost.instance.session, isNull,
          reason: '前置：tearDown 已清会话，本例必须从「没有会话」开始');
      fake.subscribed.clear();
      await svc.refreshSubscriptions();

      expect(
          fake.subscribed.where((t) => t.startsWith(RcAssist.topicPrefix)),
          isEmpty,
          reason: '⚠️ 没有会话就没有协助主题 —— 凭空订阅等于把端点暴露给'
              '一个不存在的会话（且每次心跳都白订一次）。'
              '这条是 ① 的**反向**守卫：防止"把 if 删了也能过"的自欺锁。');
    });

    test('BQ-B3 控制端侧 join 会补订对方会合主题（另一条补订路径）', () async {
      await svc.start(store, db);
      final code = RcAssist.generateCode();
      final password = RcAssist.generatePassword();
      final topic = await RcAssist.topicFor(code, password);

      fake.subscribed.clear();
      // `join` 会循环发 hello 直到 active 或超时；这里**不**指望握手成功
      // （对端不在），只锁「主题一算出来就补订」这条线（生产第 205/215 行）。
      // 短超时 ⇒ 立刻进入超时分支返回 false，不拖满默认 20s。
      final joined = await AssistJoinClient.instance
          .join(code, password, timeout: const Duration(milliseconds: 300));
      expect(joined, isFalse, reason: '对端不在线 ⇒ 握手必然失败（前置，非被测点）');

      expect(fake.subscribed, contains(topic),
          reason: '★ 控制端侧接入的会话同样要补订会合主题，否则协商报文收不到。'
              '这一条与 ① 同源（都是「订阅集合要跟着会话走」），但走的是'
              '`AssistJoinClient` 这条独立路径。');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // ③ _MqttAssistTransport.publishWire（2495–2502）
  // ══════════════════════════════════════════════════════════════════════

  group('BQ-C 协助链路的真实出站（publishWire）', () {
    test('BQ-C1 join 的 hello 出站必须经生产 publishWire 发出可解开的真密文', () async {
      await svc.start(store, db);
      final code = RcAssist.generateCode();
      final password = RcAssist.generatePassword();
      final topic = await RcAssist.topicFor(code, password);

      // ★ 驱动方式说明：`_MqttAssistTransport.publishWire` 是 `AssistTransport`
      // 接口在**生产侧**的唯一实现（替身都在测试里）。它的调用者是
      // `AssistJoinClient._publish`，而 `join()` 的 hello 重试循环**必然**会发一次
      // hello ⇒ 走这条**公开 API**就能驱动生产实现，**不需要为测试加任何缝**
      // （`AssistJoinClient._topic` / `_ctlKey` 是私有字段且**故意没有** visibleForTesting）。
      // 对端不在 ⇒ 循环跑到超时返回 false，但**出站已经发生** —— 那正是被测点。
      final joined = await AssistJoinClient.instance.join(code, password,
          timeout: const Duration(milliseconds: 300));
      expect(joined, isFalse, reason: '对端不在线 ⇒ 握手必然失败（前置，非被测点）');

      final hello = fake.sentWires
          .where((m) => m.topic == topic)
          .toList(growable: false);
      expect(hello, isNotEmpty,
          reason: '★ 协助控制端的 hello 必须真的经 `_MqttAssistTransport.publishWire` '
              '投递出去。此前该方法（2495–2502）**一行都没被执行过** —— '
              '测试里用的全是 `AssistTransport` 替身，生产的这份从未被驱动。'
              '若它坏了，真实设备上表现为「临时码正确但永远连不上」。');

      // 必须是**真密文**且能按会合方向密钥解开（明文/错密钥 ⇒ 控制端永远解不出）。
      final key = await RcAssist.ctlKey(code, password);
      final back = await RcCodec.decode(hello.last.wire, key, hello.last.topic);
      expect(back, isNotNull,
          reason: '出站必须是能按 `ctlKey` 解开的真密文 —— '
              '明文或错密钥都会让协助控制端收不到任何东西');
      expect(back!.type, RcAssistCmd.hello,
          reason: '第一条出站必须是 hello（`join` 的握手起点）');
      expect(hello.last.retain, isFalse,
          reason: '⚠️ 实时信令**不能** retain —— broker 会把它当作"最后状态"'
              '推给后续订阅者，等于把一次性的 hello/密文泄漏给别的会话');
    });

    test('BQ-C2 未连接时 publishWire 静默 return，不崩也不谎报已发', () async {
      // 模拟「broker 拒绝会话」：connect() 正常返回但状态停在 disconnected。
      fake.stayDisconnected = true;
      await svc.start(store, db);
      expect(fake.connectionStatus?.state, MqttConnectionState.disconnected,
          reason: '前置：确实处于未连接态');

      final code = RcAssist.generateCode();
      final password = RcAssist.generatePassword();
      final topic = await RcAssist.topicFor(code, password);
      await AssistJoinClient.instance
          .join(code, password, timeout: const Duration(milliseconds: 300));

      expect(fake.sentWires.where((m) => m.topic == topic), isEmpty,
          reason: '⚠️ 未连接时 publishWire 的连接守卫必须**静默 return**（安全的一侧）—— '
              '若改成抛异常，协助握手会整条崩掉；'
              '若守卫失效而照发，则会在断线时把明文意图写进 socket。'
              '这条同时是 ① 的反向守卫：防止「把 if 删了也能过」的自欺锁。');
    });
  });
}
