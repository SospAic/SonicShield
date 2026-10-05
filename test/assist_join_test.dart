import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/assist_join.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 协助会话**控制端**接入（v1.7 S3，docs/18 §4.5/§7）契约测试。
///
/// 本文件锁定控制端侧的四类不变量：
///
/// 1. **凭据派生一致性** —— 主题与方向密钥必须与端点侧逐字节一致，
///    否则"码是对的但连不上"（最难排查的一类故障）；
/// 2. **不可提权** —— 控制端只能**跟随**端点放行的权限位，任何本地状态都
///    不能让自己获得执行能力（真正的裁决永远在端点侧）；
/// 3. **方向密钥隔离** —— ctlKey 与 epKey 不可互换（换用即解密失败）；
/// 4. **失败关闭** —— 超时 / 拒绝 / 端点终止 / TTL 到期都收敛到 closed，
///    且清理掉主题与密钥（不留可复用的半开状态）。
///
/// ## 测试策略：环回总线 + 注入报文
///
/// - **正常路径**用"环回总线"把 [RcAssistHost] 与 [AssistJoinClient] 对接，
///   跑真实握手（含真实 AES-GCM 编解码），验证两端契约吻合；
/// - **异常路径**（reject / 过期 / 权限变更）改为**直接注入**端点方向的密文，
///   因为异常路径走环回会与端点自己的 TTL 心跳（1s 周期）赛跑 ——
///   端点心跳可能先把会话关掉，于是控制端看到的是"超时"而非"拒绝"，
///   断言随机失败。注入法把时间完全交给测试，确定且快。
///   端点侧**发出**这些报文的正确性由 `assist_host_test.dart`（AH-15 等）覆盖。
///
/// 另注：`helloRetryInterval` 被压到 1ms，否则每个握手用例都要真等 1.5s。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RcAssistHost host;
  late AssistJoinClient client;
  late _FakeTransport hostBus;
  late _FakeTransport joinBus;
  late List<({String action, String status, String? message})> hostAudits;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    host = RcAssistHost();
    client = AssistJoinClient();
    hostBus = _FakeTransport('host');
    joinBus = _FakeTransport('join');
    hostAudits = [];

    host
      ..bind(hostBus)
      ..endpointName = '端点-测试机'
      ..audit =
          (a, s, m) async => hostAudits.add((action: a, status: s, message: m));
    client
      ..bind(joinBus)
      ..ctrlName = '控制端A'
      ..helloRetryInterval = const Duration(milliseconds: 1);

    // 环回装配：两端互相投递，但**只投递给主题相符的一端** ——
    // 复刻 RcEndpointService._handleRaw 的按主题精确路由（一台设备可能
    // 同时托管会话又接入别人的会话，不做主题判定就会串台）。
    joinBus.onPublish = (topic, wire) async {
      if (host.session?.topic == topic) await host.onWire(wire);
    };
    hostBus.onPublish = (topic, wire) async {
      if (client.topic == topic) await client.onWire(wire);
    };
  });

  tearDown(() async {
    await client.leave(silent: true);
    await host.close(silent: true);
  });

  // ---------------- 工具 ----------------

  /// 轮询等待条件成立（避免固定 sleep 在负载下变脆）。
  Future<void> pumpUntil(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// 用端点方向密钥（epKey）构造一条端点 → 控制端的密文。
  Future<String> epWire(AssistSession s, String type,
      [Map<String, dynamic> payload = const {}]) async {
    final key = await RcAssist.epKey(s.code, s.password);
    return RcCodec.encode(RcMessage.now(type, payload), key, s.topic);
  }

  Future<String> lastHelloId(AssistSession s) async {
    final key = await RcAssist.ctlKey(s.code, s.password);
    for (final p in joinBus.published.reversed) {
      final m = await RcCodec.decode(p.wire, key, s.topic);
      if (m?.type == RcAssistCmd.hello) return m!.id;
    }
    return '';
  }

  Future<String> acceptWire(
    AssistSession s, {
    DateTime? expiresAt,
    AssistPerms perms = AssistPerms.none,
    String sessionId = 'sid-injected',
    String epName = '端点-测试机',
    String? forId,
  }) async =>
      epWire(s, RcAssistCmd.accept, {
        // P2-30：端点回执必须回指本轮 join 发出的 hello；默认取最近一条 hello 的 ID。
        'for': forId ?? await lastHelloId(s),
        'sessionId': sessionId,
        'epName': epName,
        'expiresAt':
            (expiresAt ?? DateTime.now().add(const Duration(minutes: 5)))
                .millisecondsSinceEpoch,
        'perms': perms.toJson(),
      });

  Future<String> rejectWire(AssistSession s, String reason) =>
      epWire(s, RcAssistCmd.reject, {'reason': reason});

  Future<String> permWire(AssistSession s, AssistPerms perms) => epWire(
      s, RcAssistCmd.perm, {'sessionId': s.sessionId, 'perms': perms.toJson()});

  /// 静音总线（hello 石沉大海）后开始接入，并等到握手循环真正跑起来。
  ///
  /// 返回 join 的 Future；调用方负责注入端点方向的报文。
  ///
  /// 等待条件必须是 `opening` **且已有 hello 发出**，不能只等 `topic` 非空：
  /// `join()` 里 `_topic` 先赋值、之后才置 `_phase = opening` 并派生密钥，
  /// 若在 `_topic` 刚赋值时就注入 accept，会被随后的 `_phase = opening` 覆盖
  /// （或 `_epKey` 尚未就绪而直接丢弃）→ 用例随机失败。
  Future<Future<bool>> joinMuted(AssistSession s, {Duration? timeout}) async {
    joinBus.mute = true;
    final fut = client.join(s.code, s.password,
        timeout: timeout ?? const Duration(seconds: 5));
    await pumpUntil(() =>
        client.phase == AssistPhase.opening && joinBus.published.isNotEmpty);
    return fut;
  }

  // ---------------- AJ-1x 输入校验与归一化 ----------------

  group('AJ 输入校验', () {
    test('AJ-10 临时码非法（长度不足/含非数字）→ 直接失败且不订阅', () async {
      await host.start();

      expect(await client.join('12345', 'ABCDEFGH'), isFalse);
      expect(client.info.error, contains('9 位数字'));
      expect(joinBus.subscribed, isEmpty, reason: '凭据非法时不得订阅任何主题');
      expect(client.phase, AssistPhase.closed);
    });

    test('AJ-11 密码非法（含字母表外字符 / 长度不足）→ 直接失败', () async {
      final s = await host.start();

      // I/L/O/U/0/1 不在 Crockford 字母表内 —— 归一化会剔除它们，
      // 于是长度不足 8 → 判非法（而不是静默纠正成别的字符）。
      expect(await client.join(s.code, 'ABCDEFGI'), isFalse);
      expect(client.info.error, contains('8 位'));
      expect(await client.join(s.code, 'ABC'), isFalse);
      expect(joinBus.subscribed, isEmpty);
    });

    test('AJ-12 未绑定传输 → 报"远程模块未开启"，不进入 opening', () async {
      final bare = AssistJoinClient();
      final s = await host.start();

      expect(await bare.join(s.code, s.password), isFalse);
      expect(bare.info.error, contains('远程模块未开启'));
      expect(bare.phase, AssistPhase.closed);
    });

    test('AJ-13 输入归一化：带空格/连字符/小写也能接入，且派生主题与端点一致', () async {
      final s = await host.start();

      // 模拟使用者按端点屏幕的显示格式原样输入（分组 + 小写）。
      final spaced = s.code.replaceAllMapped(
          RegExp(r'^(\d{3})(\d{3})(\d{3})$'), (m) => '${m[1]} ${m[2]} ${m[3]}');
      final hyphened = s.password.toLowerCase();

      expect(await client.join(spaced, hyphened), isTrue);
      expect(client.active, isTrue);
      expect(client.topic, s.topic, reason: '归一化不得改变派生主题');
      expect(client.epName, '端点-测试机');
    });
  });

  // ---------------- AJ-2x 握手 ----------------

  group('AJ 握手', () {
    test('AJ-20 正确凭据 → active，解析 sessionId/epName/expiresAt/perms', () async {
      final s = await host.start(ttl: const Duration(minutes: 7));

      expect(await client.join(s.code, s.password), isTrue);
      expect(client.phase, AssistPhase.active);
      expect(client.sessionId, isNotEmpty);
      expect(client.sessionId, s.sessionId, reason: '两端会话 ID 必须一致');
      expect(client.epName, '端点-测试机');
      expect(client.info.expiresAt, isNotNull);
      // 剩余时间应接近 TTL（允许 60s 误差，避免负载下脆断言）。
      expect(client.info.remaining.inSeconds, greaterThan(6 * 60 - 60));
      expect(client.perms.toJson().values.every((v) => v == false), isTrue,
          reason: 'C5：会话建立时端点默认全拒');
      expect(joinBus.subscribed, contains(s.topic));
      expect(host.active, isTrue);
    });

    test('AJ-21 主题由码+密码共同派生：仅知道码无法算出主题', () async {
      final s = await host.start();

      final right = await RcAssist.topicFor(s.code, s.password);
      final wrongPw = await RcAssist.topicFor(s.code, 'ZZZZZZZZ');
      final wrongCode = await RcAssist.topicFor('000000000', s.password);

      expect(right, s.topic);
      expect(wrongPw, isNot(right));
      expect(wrongCode, isNot(right));
      expect(right.length, s.topic.length);
    });

    test('AJ-22 密码错误 → 表现为"接入超时"（无可区分的失败信号）', () async {
      final s = await host.start();

      final ok = await client.join(s.code, 'ZZZZZZZZ',
          timeout: const Duration(milliseconds: 120));

      expect(ok, isFalse);
      // 密码错 → 主题不同 → 端点根本收不到 hello。因此**不能**给攻击者
      // 任何"密码接近"的信号：一律超时，与"端点离线"不可区分。
      expect(client.info.error, contains('接入超时'));
      expect(client.phase, AssistPhase.closed);
      expect(client.topic, isEmpty, reason: '失败后必须清理主题');
    });

    test('AJ-23 hello 需要重试：前几次丢包后仍能接入', () async {
      final s = await host.start();

      // 模拟 MQTT SUBSCRIBE 生效延迟 / 弱网：前 3 次 hello 石沉大海。
      joinBus.dropNext = 3;
      final ok = await client.join(s.code, s.password);

      expect(ok, isTrue, reason: '单发一次 hello 在真实网络上经常失败');
      expect(client.active, isTrue);
      expect(joinBus.published.length, greaterThanOrEqualTo(4),
          reason: '应至少重发了 4 次 hello');
      // 4 条 hello 内容相同、消息 ID 不同（重试不是重放）。
      final ids = <String>{};
      for (final p in joinBus.published) {
        final key = await RcAssist.ctlKey(s.code, s.password);
        final m = await RcCodec.decode(p.wire, key, s.topic);
        expect(m, isNotNull);
        ids.add(m!.id);
      }
      expect(ids.length, joinBus.published.length);
    });

    test('AJ-24 重复 join 幂等：端点重发同一会话的 accept，会话 ID 不变', () async {
      final s = await host.start();

      expect(await client.join(s.code, s.password), isTrue);
      final first = client.sessionId;

      expect(await client.join(s.code, s.password), isTrue);
      expect(client.sessionId, first, reason: '端点对重复 hello 幂等，不新建会话');
      expect(joinBus.unsubscribed, contains(s.topic), reason: '重复接入前应先退订旧主题');
      expect(joinBus.subscribed.where((t) => t == s.topic).length, 2);
    });

    test('AJ-24b P2-30：for 不匹配本轮 hello 的迟到 accept 必须被忽略（保持 opening）',
        () async {
      final s = await host.start();
      final fut = await joinMuted(s);

      // 注入一条 for 指向"别的 hello"的 accept（模拟上一轮 join 的存量回执重投）。
      await client.onWire(await acceptWire(s,
          forId: 'stale-hello-from-previous-attempt', sessionId: 'old-sid'));

      expect(client.active, isFalse,
          reason: '★ 不匹配的 accept 不得把控制端带入 active（否则会带着旧会话状态）');
      expect(client.phase, AssistPhase.opening);
      expect(client.sessionId, isEmpty, reason: '被忽略的 accept 不得写入任何会话字段');

      // 正确回执到达后仍能正常接入（证明上面不是"恒忽略"）。
      await client.onWire(await acceptWire(s, sessionId: 'new-sid'));
      expect(await fut, isTrue);
      expect(client.active, isTrue);
      expect(client.sessionId, 'new-sid');
    });

    test('AJ-24c P2-30：缺失 for 的 accept 也 fail closed（保持 opening）', () async {
      final s = await host.start();
      final fut = await joinMuted(s);

      await client.onWire(await acceptWire(s, forId: ''));

      expect(client.active, isFalse, reason: '缺 for 无法核对来源，按 fail closed 处理');
      expect(client.phase, AssistPhase.opening);

      // 收尾：注入正确 accept 让 join 正常结束，避免用例超时噪声。
      await client.onWire(await acceptWire(s));
      expect(await fut, isTrue);
    });

    test('AJ-25 端点 reject(ttl_expired) → 可读错误 + 清理', () async {
      final s = await host.start();
      final fut = await joinMuted(s);

      await client.onWire(await rejectWire(s, 'ttl_expired'));

      expect(await fut, isFalse);
      expect(client.info.error, contains('会话已过期'));
      expect(client.phase, AssistPhase.closed);
      expect(client.topic, isEmpty);
    });

    test('AJ-26 端点 reject(session_closed) → 可读错误', () async {
      final s = await host.start();
      final fut = await joinMuted(s);

      await client.onWire(await rejectWire(s, 'session_closed'));

      expect(await fut, isFalse);
      expect(client.info.error, contains('端点已关闭该会话'));
      expect(client.active, isFalse);
    });

    test('AJ-27 未知 reject 原因 → 原样带出，不吞掉信息', () async {
      final s = await host.start();
      final fut = await joinMuted(s);

      await client.onWire(await rejectWire(s, 'busy:someone_else'));

      expect(await fut, isFalse);
      expect(client.info.error, contains('busy:someone_else'));
    });

    test('AJ-28 端点无响应 → 超时失败（不会永久挂起）', () async {
      final s = await host.start();
      joinBus.mute = true;

      final sw = Stopwatch()..start();
      final ok = await client.join(s.code, s.password,
          timeout: const Duration(milliseconds: 150));
      sw.stop();

      expect(ok, isFalse);
      expect(client.info.error, contains('接入超时'));
      expect(sw.elapsedMilliseconds, lessThan(5000), reason: '超时必须生效');
    });
  });

  // ---------------- AJ-3x 权限（不可提权） ----------------

  group('AJ 权限跟随', () {
    test('AJ-30 accept 携带的权限位被如实镜像', () async {
      final s = await host.start();
      final fut = await joinMuted(s);

      await client.onWire(await acceptWire(s,
          perms: const AssistPerms(media: true, location: true)));
      expect(await fut, isTrue);

      expect(client.perms.media, isTrue);
      expect(client.perms.location, isTrue);
      expect(client.perms.script, isFalse);
    });

    test('AJ-31 端点后续 perm 变更即时生效并推送', () async {
      final s = await host.start();
      final fut = await joinMuted(s);
      await client.onWire(await acceptWire(s));
      expect(await fut, isTrue);

      final seen = <AssistJoinInfo>[];
      final sub = client.changes.listen(seen.add);

      await client.onWire(await permWire(s, const AssistPerms(script: true)));

      expect(client.perms.script, isTrue);
      await pumpUntil(() => seen.isNotEmpty);
      expect(seen.last.perms.script, isTrue);
      await sub.cancel();
    });

    test('AJ-32 权限可被端点收回（只减不增）', () async {
      final s = await host.start();
      final fut = await joinMuted(s);
      await client
          .onWire(await acceptWire(s, perms: const AssistPerms(media: true)));
      expect(await fut, isTrue);
      expect(client.allows(RcCmd.soundPlay), isTrue);

      await client.onWire(await permWire(s, AssistPerms.none));

      expect(client.perms.media, isFalse);
      expect(client.allows(RcCmd.soundPlay), isFalse);
    });

    test('AJ-33 allows() 与门控表一致：只读放行、未授权拒绝、未登记失败关闭', () async {
      final s = await host.start();
      final fut = await joinMuted(s);
      await client.onWire(await acceptWire(s));
      expect(await fut, isTrue);

      // 默认全拒时：只读命令仍可（会话存活所必需）
      expect(client.allows(RcCmd.ping), isTrue);
      expect(client.allows(RcCmd.statusGet), isTrue);
      // 作用于设备的一律拒绝
      expect(client.allows(RcCmd.soundPlay), isFalse);
      expect(client.allows(RcCmd.locationGet), isFalse);
      expect(client.allows(RcCmd.guardSet), isFalse);
      // 未登记命令失败关闭
      expect(client.allows('evil.cmd'), isFalse);
    });

    test('AJ-34 会话未激活时 allows() 恒为 false', () async {
      expect(client.active, isFalse);
      expect(client.allows(RcCmd.ping), isFalse);

      final s = await host.start();
      final fut = await joinMuted(s);
      // 仍在握手（已订阅、未 accept）
      expect(client.allows(RcCmd.ping), isFalse);

      await client.onWire(await acceptWire(s));
      await fut;
      expect(client.allows(RcCmd.ping), isTrue);
    });

    test('AJ-35 控制端无法在本地自行提权（perms 只能由端点写入）', () async {
      final s = await host.start();
      final fut = await joinMuted(s);
      await client.onWire(await acceptWire(s));
      expect(await fut, isTrue);
      expect(client.perms.toJson().values.any((v) => v == true), isFalse);

      // 控制端没有任何"设置权限"的入口；反复读取也不会变化。
      expect(client.perms.script, isFalse);
      expect(client.allows(RcCmd.scriptRun), isFalse);
      expect(client.perms.toJson().values.any((v) => v == true), isFalse);
    });
  });

  // ---------------- AJ-4x 收发 / 回执 / 生命周期 ----------------

  group('AJ 收发与生命周期', () {
    test('AJ-40 业务回执经会合主题返回，并进 events 流（信封与配对通道同形）', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      host.onCommand = (m) async {
        await host.sendReply(RcMessage.now(
            RcEvt.ack, {'ok': true, 'for': m.id, 'data': 'pong'}));
      };
      final events = <Map<String, dynamic>>[];
      final sub = client.events.listen(events.add);

      expect(await client.send(RcMessage.now(RcCmd.ping)), isTrue);
      await pumpUntil(() => events.isNotEmpty);

      expect(events, hasLength(1));
      expect(events.first['type'], RcEvt.ack);
      expect(events.first['assist'], isTrue, reason: '标记来源便于控制台区分通道');
      expect(events.first['peerName'], '端点-测试机');
      final payload = rcPayloadOf(events.first);
      expect(payload['ok'], isTrue);
      expect(payload['data'], 'pong');
      await sub.cancel();
    });

    test('AJ-41 未授权业务命令：端点拒绝并回 ack{ok:false}，且不执行', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      final executed = <String>[];
      host.onCommand = (m) async => executed.add(m.type);
      final events = <Map<String, dynamic>>[];
      final sub = client.events.listen(events.add);

      // 默认全拒 → sound.play 未放行
      expect(
          await client
              .send(RcMessage.now(RcCmd.soundPlay, {'category': 'alarms'})),
          isTrue,
          reason: '命令会发出（裁决在端点侧），但不会被执行');
      await pumpUntil(() => events.isNotEmpty);

      expect(executed, isEmpty, reason: '未授权命令绝不能被端点执行');
      expect(rcPayloadOf(events.first)['ok'], isFalse);
      expect(rcPayloadOf(events.first)['forType'], RcCmd.soundPlay);
      expect(hostAudits.map((a) => a.action), contains('assist.deny'));
      await sub.cancel();
    });

    test('AJ-42 端点放行后同一命令即可执行', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      final executed = <String>[];
      host.onCommand = (m) async {
        executed.add(m.type);
        await host
            .sendReply(RcMessage.now(RcEvt.ack, {'ok': true, 'for': m.id}));
      };
      await host.grant(const AssistPerms(media: true));

      expect(
          await client
              .send(RcMessage.now(RcCmd.soundPlay, {'category': 'nature'})),
          isTrue);
      await pumpUntil(() => executed.isNotEmpty);
      expect(executed, [RcCmd.soundPlay]);
    });

    test('AJ-43 端点 close → 控制端收敛为 closed 并清理', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      await host.close();

      await pumpUntil(() => client.phase == AssistPhase.closed);
      expect(client.phase, AssistPhase.closed);
      expect(client.info.error, contains('端点已终止'));
      expect(client.topic, isEmpty);
      expect(joinBus.unsubscribed, contains(s.topic));
    });

    test('AJ-44 控制端挂断 → 通知端点，端点会话终止并审计"控制端终止"', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      await client.leave();

      expect(client.phase, AssistPhase.closed);
      expect(host.session, isNull);
      final end = hostAudits.lastWhere((a) => a.action == 'assist.end');
      expect(end.message, contains('控制端终止'));
    });

    test('AJ-45 静默挂断不发 close 报文（本地清理但不打扰端点）', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);
      final before = hostBus.published.length;

      await client.leave(silent: true);

      expect(hostBus.published.length, before, reason: '静默挂断不得发报文');
      expect(host.active, isTrue, reason: '端点侧会话仍在（等它自己 TTL 到期）');
    });

    test('AJ-46 TTL 到期后 tick() 收敛为 closed 并给出可读原因', () async {
      final s = await host.start();
      final fut = await joinMuted(s);
      await client.onWire(await acceptWire(s,
          expiresAt: DateTime.now().subtract(const Duration(seconds: 1))));
      expect(await fut, isTrue);
      expect(client.active, isTrue, reason: 'accept 已到但 TTL 已过：先如实进入 active');

      client.tick();

      await pumpUntil(() => client.phase == AssistPhase.closed);
      expect(client.phase, AssistPhase.closed);
      expect(client.info.error, contains('已到期'));
      expect(client.topic, isEmpty);
    });

    test('AJ-47 会话终止后 send() 为无操作', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);
      await client.leave();
      final before = joinBus.published.length;

      expect(await client.send(RcMessage.now(RcCmd.ping)), isFalse);
      expect(joinBus.published.length, before);
    });

    test('AJ-53 tick()：active 未到期驱动倒计时；已关闭则只停表、不再推送', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);
      expect(client.active, isTrue);

      // active 且未到期：每次 tick 都必须推一次会话快照（这是倒计时的驱动源，
      // 不 emit 界面上倒计时就永远停住）。
      var emits = 0;
      final sub = client.changes.listen((_) => emits++);
      addTearDown(sub.cancel);
      client.tick();
      await pumpUntil(() => emits > 0);
      expect(emits, greaterThan(0), reason: 'active 下 tick 必须驱动倒计时');

      // 已关闭：tick 只应停表（1s 周期心跳不能继续空转、更不能乱推状态）。
      await client.leave();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final before = emits;
      client.tick();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.phase, AssistPhase.closed);
      expect(emits, before, reason: 'closed 后 tick 必须只停表，不得再推送');
    });

    test('AJ-48 端点未接入前 onWire 静默丢弃（无密钥，不解密）', () async {
      final s = await host.start();
      final wire = await acceptWire(s);

      // 从未 join：无主题无密钥 → 直接返回，不抛异常、不改变状态。
      await client.onWire(wire);

      expect(client.phase, AssistPhase.closed);
      expect(client.active, isFalse);
    });

    test('AJ-49 同一密文重放不重复进 events（按密文原文去重）', () async {
      final s = await host.start();
      final fut = await joinMuted(s);
      await client.onWire(await acceptWire(s));
      expect(await fut, isTrue);

      final events = <Map<String, dynamic>>[];
      final sub = client.events.listen(events.add);
      final ack = await epWire(s, RcEvt.ack, {'ok': true});

      await client.onWire(ack);
      await client.onWire(ack);
      await client.onWire(ack);
      await pumpUntil(() => events.isNotEmpty);

      expect(events, hasLength(1), reason: 'QoS1 重传 / 恶意重放只应处理一次');
      await sub.cancel();
    });

    test('AJ-50 方向密钥隔离：epKey 解不开 ctlKey 密文，反之亦然', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      final ctl = await RcAssist.ctlKey(s.code, s.password);
      final ep = await RcAssist.epKey(s.code, s.password);
      expect(ctl, isNot(ep));

      // 控制端发出的 hello（ctlKey 加密）不得被 epKey 解开
      final hello = joinBus.published.first;
      expect(await RcCodec.decode(hello.wire, ep, s.topic), isNull);
      expect(await RcCodec.decode(hello.wire, ctl, s.topic), isNotNull);

      // 端点的 accept（epKey 加密）不得被 ctlKey 解开
      final accept = hostBus.published.last;
      expect(await RcCodec.decode(accept.wire, ctl, s.topic), isNull);
      expect(await RcCodec.decode(accept.wire, ep, s.topic), isNotNull);
    });

    test('AJ-51 跨主题移植密文失败（AAD 绑定主题）', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      final ep = await RcAssist.epKey(s.code, s.password);
      final accept = hostBus.published.last;
      // 换一个会合主题做 AAD → 解密失败（防跨会话移植密文）。
      // 注意：不要在这里再 start() 一个会话 —— 那会顶掉当前会话，
      // 环回路由（按主题判定）随之失配，控制端只会看到超时。
      final otherTopic = await RcAssist.topicFor('000000000', 'ZZZZZZZZ');
      expect(otherTopic, isNot(s.topic));
      expect(await RcCodec.decode(accept.wire, ep, otherTopic), isNull);
      expect(await RcCodec.decode(accept.wire, ep, s.topic), isNotNull);
    });

    test('AJ-52 info.remaining 在无 expiresAt 时为 0，且不返回负数', () async {
      const info = AssistJoinInfo(phase: AssistPhase.closed);
      expect(info.remaining, Duration.zero);
      expect(info.active, isFalse);
      expect(info.busy, isFalse);

      final past = AssistJoinInfo(
          phase: AssistPhase.active,
          expiresAt: DateTime.now().subtract(const Duration(hours: 1)));
      expect(past.remaining, Duration.zero, reason: '过期不得返回负 Duration');
      expect(past.active, isTrue);
    });
  });

  // ---------------- AJ-7x 会话审计（S4） ----------------

  group('AJ 会话审计', () {
    test('AJ-70 记录握手与发出的命令', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      final log = client.auditLog;
      expect(log.any((e) => e.outbound && e.type == RcAssistCmd.hello), isTrue,
          reason: '握手过程应留痕');
      expect(
          log.any((e) => !e.outbound && e.type == RcAssistCmd.accept), isTrue,
          reason: '端点接受应留痕');
      expect(log.last.detail, contains(client.sessionId));

      host.onCommand = (m) async {};
      await client.send(RcMessage.now(RcCmd.ping));
      expect(client.auditLog.last.outbound, isTrue);
      expect(client.auditLog.last.type, RcCmd.ping);
    });

    test('AJ-71 端点拒绝时记录可读原因（不是"点了没反应"）', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);
      host.onCommand = (m) async {};

      await client.send(RcMessage.now(RcCmd.soundPlay, {'category': 'alarms'}));
      await pumpUntil(() => client.auditLog.any((e) => !e.ok));

      final denied = client.auditLog.lastWhere((e) => !e.ok);
      expect(denied.outbound, isFalse);
      expect(denied.type, RcEvt.ack);
      expect(denied.detail, contains('权限未放行'));
      expect(denied.detail, contains('播放音效'));
    });

    test('AJ-72 端点放行权限时记录放行摘要', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      await host.grant(const AssistPerms(media: true, location: true));
      await pumpUntil(
          () => client.auditLog.any((e) => e.type == RcAssistCmd.perm));

      final perm = client.auditLog.lastWhere((e) => e.type == RcAssistCmd.perm);
      expect(perm.detail, contains('播放音效'));
      expect(perm.detail, contains('获取定位'));

      await host.grant(AssistPerms.none);
      await pumpUntil(() => client.auditLog
          .any((e) => e.type == RcAssistCmd.perm && e.detail.contains('收回')));
      expect(
          client.auditLog.any(
              (e) => e.type == RcAssistCmd.perm && e.detail.contains('收回全部权限')),
          isTrue);
    });

    test('AJ-73 本端挂断留痕；新会话清空上一轮轨迹', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);
      await client.leave();

      expect(
          client.auditLog.any((e) =>
              e.outbound &&
              e.type == RcAssistCmd.close &&
              e.detail.contains('挂断')),
          isTrue);

      // 端点侧会话已结束，重新发起一次会话验证轨迹被清空。
      final s2 = await host.start();
      expect(await client.join(s2.code, s2.password), isTrue);
      expect(client.auditLog.any((e) => e.type == RcAssistCmd.close), isFalse,
          reason: '审计轨迹应随新会话重置');
    });

    test('AJ-74 审计轨迹有上限，不会无限增长', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);
      host.onCommand = (m) async {};

      for (var i = 0; i < 260; i++) {
        await client.send(RcMessage.now(RcCmd.ping, {'i': i}));
      }

      expect(client.auditLog.length, lessThanOrEqualTo(200));
      expect(client.auditLog.length, greaterThan(0));
    });

    test('AJ-75 auditLog 返回不可变视图（外部改不动内部状态）', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      expect(() => client.auditLog.clear(), throwsUnsupportedError);
    });
  });

  // ---------------- AJ-6x 命令通道抽象 ----------------

  group('AJ 命令通道', () {
    test('AJ-60 AssistChannel 未接入时不可发，label 用兜底名', () {
      final ch = AssistChannel(client);
      expect(ch.canSend, isFalse);
      expect(ch.label, '协助会话端点');
    });

    test('AJ-61 AssistChannel 接入后 label 带端点名与「协助」标记', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      final ch = AssistChannel(client);
      expect(ch.canSend, isTrue);
      expect(ch.label, '端点-测试机（协助）');
    });

    test('AJ-62 AssistChannel.send 对未授权命令仍然发出（裁决在端点侧）', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);
      final ch = AssistChannel(client);
      final before = joinBus.published.length;

      // 若在此静默拦截，使用者会以为"功能坏了"，看不到端点的拒绝原因。
      expect(await ch.send(RcMessage.now(RcCmd.guardSet, {'enabled': true})),
          isTrue);
      expect(joinBus.published.length, before + 1);
    });

    test('AJ-63 channelAllows：协助通道走门控，配对通道恒 true', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);
      final assist = AssistChannel(client);

      expect(channelAllows(assist, RcCmd.ping), isTrue);
      expect(channelAllows(assist, RcCmd.guardSet), isFalse);

      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.addPaired(PairedEndpoint(
          deviceId: 'dev-1',
          name: '端点A',
          secret: 'sec',
          pairedAt: DateTime.now()));
      final paired = await pairedChannelOf('dev-1');
      expect(paired, isNotNull);
      expect(paired!.label, '端点A');
      expect(channelAllows(paired, RcCmd.guardSet), isTrue,
          reason: '配对即全权，无权限位模型');
      expect(await pairedChannelOf('nope'), isNull);
    });

    test('AJ-64 dispose 不抛异常（协助通道的退订由 leave 负责）', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      await AssistChannel(client).dispose();
      await PairedChannel(
              PairedEndpoint(
                  deviceId: 'd',
                  name: 'n',
                  secret: 's',
                  pairedAt: DateTime.now()),
              RemoteStore(await SharedPreferences.getInstance()))
          .dispose();

      expect(client.active, isTrue, reason: 'dispose 不应顺带终止会话');
    });

    test('AJ-65 updates：协助通道随端点权限变更推送，配对通道不推', () async {
      final s = await host.start();
      expect(await client.join(s.code, s.password), isTrue);

      var assistPings = 0;
      final a = AssistChannel(client).updates.listen((_) => assistPings++);

      final store = RemoteStore(await SharedPreferences.getInstance());
      final paired = PairedChannel(
          PairedEndpoint(
              deviceId: 'd2',
              name: 'n2',
              secret: 's2',
              pairedAt: DateTime.now()),
          store);
      var pairedPings = 0;
      final p = paired.updates.listen((_) => pairedPings++);

      await host.grant(const AssistPerms(media: true));
      await pumpUntil(() => assistPings > 0);
      await pumpUntil(() => false, timeout: const Duration(milliseconds: 30));

      expect(assistPings, greaterThan(0), reason: '端点放行权限应触发控制台重建');
      expect(pairedPings, 0, reason: '配对通道无权限位模型，不应推送');

      await a.cancel();
      await p.cancel();
    });
  });
}

/// 记录收发动作的假传输；[mute] 丢弃全部发布，[dropNext] 丢弃前 N 次发布。
///
/// 这两个开关分别模拟两类真实故障：
/// - [mute]：端点未订阅（或网络不通）→ 报文石沉大海；
/// - [dropNext]：MQTT SUBSCRIBE 生效延迟 → 前几发丢失，之后恢复。
class _FakeTransport implements AssistTransport {
  _FakeTransport(this.side);

  final String side;
  final subscribed = <String>[];
  final unsubscribed = <String>[];
  final published = <({String topic, String wire})>[];

  bool mute = false;
  int dropNext = 0;

  Future<void> Function(String topic, String wire)? onPublish;

  @override
  Future<void> subscribe(String topic) async => subscribed.add(topic);

  @override
  Future<void> unsubscribe(String topic) async => unsubscribed.add(topic);

  @override
  Future<void> publishWire(String topic, String wire) async {
    published.add((topic: topic, wire: wire));
    if (mute) return;
    if (dropNext > 0) {
      dropNext--;
      return;
    }
    await onPublish?.call(topic, wire);
  }
}
