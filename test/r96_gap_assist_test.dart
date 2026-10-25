/// 覆盖率收口（第九十六轮）：协助会话链路上「可达但一行未被执行」的剩余行。
///
/// ## 本轮目标（来自 lcov 的 DA 行，非推断）
///
/// | 目标 | 行 | 此前为什么没被执行过 |
/// |---|---|---|
/// | ① 协助虚拟对端名的两侧分支 | `endpoint_service.dart:525` | `_assistPeer()` 只在 `assist.onCommand` 被调用时才跑，既有用例从不直接驱动这个闭包。⚠️ 实测发现：lcov 的 DA:525 **只在 `session` 非空时**点亮（null 分支的短路指令被归到 524），任务书「需要 session 为 null」的归因是反的 —— 用例因此**两侧都锁**。 |
/// | ② 权限发布失败后的三步回退 | `assist_host.dart:274-276` | `grant()` 的失败分支要求 `_publish` **抛异常**；既有用例的替身传输只会成功。 |
/// | ③ 陌生会合主题上的握手报文 | `assist_host.dart:396-399` | `onUnknownWire` 的计数分支要求「主题形状合法 + 线格式合法 + 会话未激活」三条同时成立，既有用例只喂过垃圾串。 |
/// | ④ 接入流程中的未预期异常 | `assist_join.dart:273` | 需要 `try` 块内**抛异常**（如 SUBSCRIBE 被拒）；既有用例只测「超时/被拒」这两条正常失败。 |
/// | ⑤ 密文去重环淘汰最旧一条 | `assist_join.dart:510` | 需要往 `onWire` 灌 >512 条**互不相同**的密文，既有用例最多 3 条。 |
///
/// ## ⑥ `assist_join.dart:353` —— **没有**用例，因为它在当前实现里不可达
///
/// 那一行是 `send()` 里 `_publish` 返回 false 后的失败记账。要进入它，必须同时满足：
/// `_phase != closed`（否则 343 行早退）、`_topic` 非空（同上），而 `_publish` 又因
/// `_transport == null || _ctlKey == null || _topic` 为空而返回 false。
///
/// - `_transport` 只由 `bind()` 赋值（非空形参，永不置空）；
/// - `_ctlKey` / `_topic` 的唯一置空点是 `leave()`，而它把这两者与
///   `_phase = closed` 写在**同一个同步段**（之间没有 `await`）⇒ 不存在
///   「topic 还在、key 已空、phase 还活着」的中间态；
/// - `send` 的守卫与 `_publish` 的守卫之间只隔着 `_record`（纯同步：
///   List.add + 异步广播流的 `add`）⇒ 没有任何交错点。
///
/// 因此除非改动 `lib/`（本轮禁止），这条 `if (!ok)` 分支无法被任何输入触发。
/// 为一条不可达行去造一个"病态 Zone 让微任务同步执行"的测试，只会得到假绿，
/// 与全仓「不接受假绿」的判据冲突 ⇒ **如实留白**。
///
/// ## 为什么用 `test()` 而不是 `testWidgets()` + `runAsync`
///
/// 本轮五个目标**全部不在 UI 上**（虚拟对端构造、审计回退、入站拒绝链、去重环），
/// 没有任何 widget 需要挂载。`assist_host_screen_test.dart` 里 `open` / `waitReal`
/// / `activate` 那三个借 `tester.runAsync` 的 helper，存在的唯一理由是
/// **`testWidgets` 跑在 FakeAsync 里**，而 `DartPbkdf2` 每 2000 迭代
/// `await Future.delayed(1ms)` 在假时钟下永不完成。本文件用真异步 `test()`
/// （与同仓 `bq_gap_closure_test.dart` 同一套模式）⇒ 派生链天然跑完，
/// 不需要 `runAsync` 这层绕行，也不会因为忘了包 `runAsync` 而挂死。
///
/// ⚠️ 全部走**真** `RcCodec`（真 PBKDF2 / HKDF / AES-GCM）：密钥错了就必须解不开，
/// 不接受"打个桩让 decode 恒成功"的假绿。
///
/// ⚠️ `RcAssistHost` / `AssistJoinClient` / `RcEndpointService` 都是进程内单例。
/// 除 ① 必须用 `RcAssistHost.instance`（接线是 `svc.start()` 做的）外，其余用例
/// 一律用**新建实例**，避免 TTL / 失败计数 / 权限位互相污染；① 的接线副作用
/// 在 `tearDown` 显式还原。
@Timeout(Duration(seconds: 300))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/assist_join.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/mqtt_client_stub.dart';

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
    db = await AppDatabase.open(inMemoryDatabasePath);
    store = RemoteStore(await SharedPreferences.getInstance());
    // `_connect()` 第一行就是 `if (deviceId.isEmpty) return;` —— 空身份 ⇒
    // 客户端永不建立 ⇒ `svc.start()` 之后的传输层整段早退。
    await store.setIdentity('EP0096GAP001', '端点-R96');
    await store.ensurePairingCode();
    fake = FakeMqttServerClient('broker.r96.invalid', 'EP0096GAP001');
    svc.debugClientFactory = (b, c, p) => fake;
    svc.debugBind(store: store, db: db);
  });

  tearDown(() async {
    svc.debugClientFactory = null;
    svc.debugSendTo = null;
    // `_running` 是单例字段：不复位的话后续用例的 `start()` 直接 return。
    await svc.stop();
    await RcAssistHost.instance.close(reason: 'test-teardown', silent: true);
    await AssistJoinClient.instance.leave(silent: true);
    // `svc.start()` 把 `audit` / `onCommand` 写成**捕获当轮 db** 的闭包，
    // 而 `RcAssistHost` 是进程内单例 ⇒ 不清就会往已关闭的库写审计。
    RcAssistHost.instance.audit = null;
    RcAssistHost.instance.onCommand = null;
    await fake.dispose();
    try {
      await db.close();
    } on Object {
      // 忽略：在飞的收尾可能已经把库关掉。
    }
  });

  // ---------------- 工具 ----------------

  /// 有界轮询等待（禁 `pumpAndSettle` / 禁固定 sleep）。
  Future<void> waitFor(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// 走完 `assist.hello` 握手，把会话推进到 active。
  Future<void> activate(RcAssistHost host, AssistSession s,
      {String ctrlName = '小李的手机'}) async {
    await host.onWire(await RcCodec.encode(
        RcMessage.now(RcAssistCmd.hello, {'ctrlName': ctrlName}),
        await RcAssist.ctlKey(s.code, s.password),
        s.topic));
  }

  // ══════════════════════════════════════════════════════════════════════
  // ① endpoint_service.dart:525 —— `final name = s?.ctrlName ?? '';`
  //
  // `_assistPeer()` 是私有方法，唯一调用点是 `_wireAssist` 里注入给
  // `RcAssistHost.onCommand` 的闭包。因此驱动方式就是**照着生产的方式**调它：
  // `svc.start()` 完成接线 → 直接调 `onCommand`。
  //
  // 观察点选 `task.upsert` 的**非法定义**分支：它会把 `peer.name` 写进审计
  // （`by <name> · 定义校验失败`）—— 这是这条表达式唯一的外部可观测痕迹。
  //
  // ## ⚠️ 实测修正：lcov 的 DA:525 只在 **session 非空**时才点亮
  //
  // 任务书把 525 归因为「`??` 的 null 分支」，实测相反：`s == null` 时
  // `s?.ctrlName` 短路到常量 `''`，该语句**没有**落在 525 行上的指令
  // （全量套件里 `_assistPeer` 被调 3 次、全部 null 分支 ⇒ DA:525 恒 0，
  // 而 DA:524 = 2× 调用次数）；一旦 `s != null`（走 getter），525 立刻 +1。
  // 因此本用例**两侧都锁**：先无会话（`??` 的 null 分支，行为断言），
  // 再建会话（非空分支，同时点亮 DA:525）。
  // ══════════════════════════════════════════════════════════════════════

  test('GAP-01 虚拟对端名：无会话时回落「协助控制端」，有会话时用控制端名', () async {
    await svc.start(store, db);

    final host = RcAssistHost.instance;
    expect(host.session, isNull, reason: '前置：此刻没有任何协助会话');
    final handler = host.onCommand;
    expect(handler, isNotNull, reason: 'svc.start() 必须完成协助接线');

    // 非法任务定义（id 为空 ⇒ `TaskWire.fromWire` 返回 null）⇒ 只留审计 + ack，
    // 不会写库、不会触发任何执行体，是最干净的观测点。
    Future<void> probeTask() => handler!(RcMessage.now(RcCmd.taskUpsert, {
          'task': <String, dynamic>{'id': ''},
        }));

    Future<String> upsertAudit() async {
      final rows = await LogRepository(db).recent(limit: 100);
      return rows
          .where((r) => r['action'] == RcCmd.taskUpsert)
          .map((r) => r['message'] as String? ?? '')
          .join('\n');
    }

    // ---- 侧 1：session == null ⇒ `s?.ctrlName ?? ''` 的 null 分支 ----
    await probeTask();

    final noSession = await upsertAudit();
    expect(noSession, contains('by 协助控制端'),
        reason: '★ null 分支必须回落到空串，再由 `isEmpty` 兜底成「协助控制端」。'
            '若把 null 直接塞进 PairedEndpoint.name，审计与界面里就会出现字面量 '
            '"null" —— 使用者看到的是"by null"。');
    expect(noSession, isNot(contains('by null')));
    expect(host.session, isNull, reason: '构造虚拟对端不得凭空建出会话');

    // ---- 侧 2：session != null ⇒ 用控制端名（同时点亮 DA:525）----
    final s = await host.start();
    await activate(host, s, ctrlName: '小李的手机');
    expect(host.session, isNotNull);

    await probeTask();

    final withSession = await upsertAudit();
    expect(withSession, contains('by 小李的手机'),
        reason: '有会话时虚拟对端必须带控制端名 —— 否则审计里所有协助命令都署名'
            '「协助控制端」，事后无法区分是谁做的');
  });

  // ══════════════════════════════════════════════════════════════════════
  // ② assist_host.dart:274-276 —— 权限发布失败后的三步回退
  // ══════════════════════════════════════════════════════════════════════

  test('GAP-02 权限发布抛异常 ⇒ 本地权限回退 + 审计 failed + 广播（不留半放行）', () async {
    final host = RcAssistHost();
    final bus = _FakeTransport();
    final audits = <({String action, String status, String? message})>[];
    host
      ..bind(bus)
      ..endpointName = '端点-R96'
      ..audit =
          (a, s, m) async => audits.add((action: a, status: s, message: m));
    addTearDown(() => host.close(silent: true));

    final s = await host.start();
    await activate(host, s);
    expect(host.active, isTrue, reason: '前置：grant 只在 active 会话上生效');
    expect(s.perms.media, isFalse, reason: '前置：C5 默认全拒');

    // 真实场景：MQTT 客户端已被 dispose / 发布队列满 ⇒ publishWire 抛。
    bus.failPublish = true;
    final emitted = <AssistSession?>[];
    final sub = host.changes.listen(emitted.add);
    addTearDown(sub.cancel);

    final ok = await host.grant(const AssistPerms(media: true));

    expect(ok, isFalse, reason: '发布失败必须如实返回 false —— UI 不能显示"已放行"');
    expect(s.perms.media, isFalse,
        reason: '★ 回退：本地权限位不得停在"已放行"。'
            '否则本机显示已授权、控制端按钮仍灰着（或反之），两端状态静默不一致。');
    final failed = audits
        .where((a) => a.action == 'assist.perm' && a.status == 'failed')
        .toList();
    expect(failed, hasLength(1), reason: '失败必须留下审计，不能只回滚不记录');
    expect(failed.single.message, contains('发布失败，已回退'));
    await waitFor(() => emitted.isNotEmpty);
    expect(emitted, isNotEmpty,
        reason: '★ 回退后必须 _emit：否则界面上的开关停在被拨动后的样子，'
            '使用者以为已经放行了');
  });

  // ══════════════════════════════════════════════════════════════════════
  // ③ assist_host.dart:396-399 —— 「陌生会合主题上的握手报文」
  // ══════════════════════════════════════════════════════════════════════

  test('GAP-03 陌生会合主题上的握手报文 ⇒ 计入失败并写明原因（猜错密码的可见证据）', () async {
    final host = RcAssistHost();
    final bus = _FakeTransport();
    final audits = <({String action, String status, String? message})>[];
    host
      ..bind(bus)
      ..endpointName = '端点-R96'
      ..audit =
          (a, s, m) async => audits.add((action: a, status: s, message: m));
    addTearDown(() => host.close(silent: true));

    final s = await host.start();
    expect(s.phase, AssistPhase.waiting, reason: '前置：等待接入（既非 active 也非 closed）');

    // 攻击者用**错误密码**算出的候选主题：形状合法（16 位十六进制），
    // 但与本会话主题不同 —— 这正是"猜密码"在线上唯一的表现。
    final stranger = await RcAssist.topicFor('123456789', 'ABCDEFGHJKMNP');
    expect(stranger, isNot(s.topic));
    expect(RcAssist.isAssistTopic(stranger), isTrue,
        reason: '前置：必须通过主题形状门（随机灌 assist/xxx 的噪声不算猜密码）');

    final wire = await RcCodec.encode(
        RcMessage.now(RcAssistCmd.hello, {'ctrlName': '陌生人'}),
        await RcAssist.ctlKey(s.code, s.password),
        stranger);
    expect(looksLikeRcWire(wire), isTrue, reason: '前置：必须是合法线格式');

    await host.onUnknownWire(stranger, wire);

    expect(s.failures, 1,
        reason: '★ 猜错密码 ⇒ 主题算错 ⇒ 报文永远到不了本会话主题。'
            '若只在"本会话主题"上计数，5 次锁定对在线猜测毫无作用。');
    final handshake = audits
        .where((a) => a.action == 'assist.handshake')
        .toList();
    expect(handshake, hasLength(1), reason: '计数必须留审计');
    expect(handshake.single.message, contains('陌生会合主题上的握手报文'));
    expect(handshake.single.message, contains('第 1 次'),
        reason: '必须带次数：使用者据此判断"还剩几次就作废"');
    expect(host.active, isFalse, reason: '陌生主题的报文绝不能让本会话被激活');
  });

  // ══════════════════════════════════════════════════════════════════════
  // ④ assist_join.dart:273 —— `return _fail('接入失败：$e');`
  // ══════════════════════════════════════════════════════════════════════

  test('GAP-04 订阅抛异常 ⇒ 接入收敛为可读失败（不留 opening 卡死界面）', () async {
    final host = RcAssistHost();
    host.bind(_FakeTransport());
    addTearDown(() => host.close(silent: true));
    final s = await host.start();

    // 真实场景：broker 侧 ACL 拒绝 SUBSCRIBE / 客户端在 join 途中被 dispose。
    final client = AssistJoinClient()
      ..bind(_SubscribeThrowsTransport())
      ..helloRetryInterval = const Duration(milliseconds: 1);
    addTearDown(() => client.leave(silent: true));

    final ok = await client.join(s.code, s.password,
        timeout: const Duration(seconds: 2));

    expect(ok, isFalse);
    expect(client.info.error, contains('接入失败'),
        reason: '★ 未预期异常必须收口成**可见失败**，不能让 Future 带着异常逃逸');
    expect(client.info.error, contains('SUBSCRIBE 被拒'),
        reason: '原因要带出来，否则使用者无从判断该重试还是该找管理员');
    expect(client.phase, AssistPhase.closed,
        reason: '★ 必须复位 opening：`busy` 由 phase 推导，不复位则两个输入框与'
            '按钮全部禁用、错误区不显示，用户只能杀页面（R90-16 的原始形状）');
    expect(client.info.busy, isFalse);
  });

  // ══════════════════════════════════════════════════════════════════════
  // ⑤ assist_join.dart:510 —— `_seenWires.remove(_seenWires.first);`
  //
  // 密文去重环是 FIFO 且**有上限**（512）：环满后必须淘汰最旧一条，
  // 否则内存随会话时长无界增长（MQTT 公共 broker 上的噪声源源不断）。
  // ⚠️ 诚实边界：被淘汰那条"重新可被处理"这一步在外部**不可观测** ——
  // 它随后会被消息 ID 去重（`_seen`，10 分钟窗口）挡住，两条路都是静默 return。
  // 因此这里锁的是「淘汰动作本身不破坏收报文」+「最近窗口的去重不被削弱」。
  // ══════════════════════════════════════════════════════════════════════

  test('GAP-05 密文去重环满 512 条后淘汰最旧一条，且最近窗口的去重不被削弱', () async {
    final host = RcAssistHost();
    host.bind(_FakeTransport());
    addTearDown(() => host.close(silent: true));
    final s = await host.start();

    final bus = _FakeTransport();
    final client = AssistJoinClient()
      ..bind(bus)
      ..ctrlName = '控制端-R96'
      ..helloRetryInterval = const Duration(milliseconds: 1);
    addTearDown(() => client.leave(silent: true));

    // 静音总线 + 注入 accept：把时间完全交给测试，不与端点 1s 心跳赛跑。
    final fut = client.join(s.code, s.password,
        timeout: const Duration(seconds: 20));
    await waitFor(
        () => client.phase == AssistPhase.opening && bus.published.isNotEmpty);
    expect(bus.published, isNotEmpty, reason: '前置：hello 必须已发出');

    final ctl = await RcAssist.ctlKey(s.code, s.password);
    final ep = await RcAssist.epKey(s.code, s.password);
    var helloId = '';
    for (final p in bus.published.reversed) {
      final m = await RcCodec.decode(p.wire, ctl, s.topic);
      if (m?.type == RcAssistCmd.hello) {
        helloId = m!.id;
        break;
      }
    }
    expect(helloId, isNotEmpty, reason: '前置：必须拿到本轮 hello 的 ID');

    await client.onWire(await RcCodec.encode(
        RcMessage.now(RcAssistCmd.accept, {
          'for': helloId,
          'sessionId': 'sid-r96',
          'epName': '端点-R96',
          'expiresAt': DateTime.now()
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
          'perms': AssistPerms.none.toJson(),
        }),
        ep,
        s.topic));
    expect(await fut, isTrue, reason: '前置：接入成功后 onWire 才有解密密钥');

    final events = <Map<String, dynamic>>[];
    final sub = client.events.listen(events.add);
    addTearDown(sub.cancel);

    // 512 条互不相同的垃圾密文：每条都会记进密文去重环（解码失败不影响记账）。
    for (var i = 0; i < 512; i++) {
      await client.onWire('not-a-wire-$i');
    }

    final ack1 = await RcCodec.encode(
        RcMessage.now(RcEvt.ack, {'ok': true, 'for': 'r96-1'}), ep, s.topic);
    // 第 513 条 ⇒ `_seenWires.length > 512` ⇒ 淘汰最旧一条。
    await client.onWire(ack1);
    await waitFor(() => events.isNotEmpty);
    expect(events, hasLength(1),
        reason: '★ 环满之后的报文仍必须被处理（淘汰 ≠ 拒收）');

    // 对照：最新一条仍在去重窗口内 ⇒ 重放必须被挡住。
    await client.onWire(ack1);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(events, hasLength(1),
        reason: '淘汰最旧一条不得削弱"最近"这半边 —— 否则 QoS1 重投会被执行两次');

    // 淘汰之后仍能继续收新报文（环不会卡死在"满"状态）。
    final ack2 = await RcCodec.encode(
        RcMessage.now(RcEvt.ack, {'ok': true, 'for': 'r96-2'}), ep, s.topic);
    await client.onWire(ack2);
    await waitFor(() => events.length >= 2);
    expect(events, hasLength(2), reason: '去重环必须持续可写');
  });
}

/// 记录收发动作的假传输；[failPublish] 让发布**抛异常**（不是静默失败）。
class _FakeTransport implements AssistTransport {
  final subscribed = <String>[];
  final unsubscribed = <String>[];
  final published = <({String topic, String wire})>[];

  bool failPublish = false;

  @override
  Future<void> subscribe(String topic) async => subscribed.add(topic);

  @override
  Future<void> unsubscribe(String topic) async => unsubscribed.add(topic);

  @override
  Future<void> publishWire(String topic, String wire) async {
    if (failPublish) throw StateError('mqtt publish failed: client disposed');
    published.add((topic: topic, wire: wire));
  }
}

/// 订阅即抛的传输（broker ACL 拒绝 SUBSCRIBE / 客户端已被 dispose）。
///
/// `unsubscribe` 刻意**不抛**：`leave()` 里的退订是清理路径，抛了会把
/// "接入失败"这个被测结论变成"清理也炸了"的噪声。
class _SubscribeThrowsTransport implements AssistTransport {
  @override
  Future<void> subscribe(String topic) async =>
      throw StateError('SUBSCRIBE 被拒（ACL）');

  @override
  Future<void> unsubscribe(String topic) async {}

  @override
  Future<void> publishWire(String topic, String wire) async {}
}
