import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';

/// 协助会话端点侧托管（v1.7，docs/18 §4.4/§7）契约测试。
///
/// 本文件锁定三类**安全不变量**，它们都不是"功能正确性"而是"边界正确性"：
///
/// 1. **会话只能端点侧发起**（C1）—— 本模块不暴露任何外部唤醒入口；
/// 2. **默认拒绝**（C5）—— 权限全 false 起步，未登记命令失败关闭（fail-closed）；
/// 3. **失败关闭**（fail-safe）—— TTL 到期 / 失败超限 / 任一方终止都收敛到"无权限"，
///    不存在任何路径能让攻击者**取得**权限。
///
/// 另外锁定两个反 DoS 细节：密文重放不得计入握手失败（否则重放 5 次即锁死），
/// 以及会话激活后的垃圾报文不得计入失败（否则 broker 侧观察者可锁死会话）。
void main() {
  late RcAssistHost host;
  late _FakeTransport bus;
  late List<({String action, String status, String? message})> audits;

  setUp(() {
    host = RcAssistHost();
    bus = _FakeTransport();
    audits = [];
    host.bind(bus);
    host.endpointName = '端点-测试机';
    host.audit =
        (a, s, m) async => audits.add((action: a, status: s, message: m));
  });

  tearDown(() async {
    await host.close(silent: true);
  });

  // ---------------- 工具 ----------------

  /// 构造一条控制端 → 端点的 `assist.hello` 密文。
  Future<String> helloWire(
    AssistSession s, {
    String ctrlName = '控制端A',
    String? passwordOverride,
    String? idOverride,
  }) async {
    final key = await RcAssist.ctlKey(s.code, passwordOverride ?? s.password);
    final msg = RcMessage.now(RcAssistCmd.hello, {'ctrlName': ctrlName});
    return RcCodec.encode(msg, key, s.topic);
  }

  /// 用指定密钥解开最近一次发布。
  Future<RcMessage?> openLast(List<int> key) async {
    expect(bus.published, isNotEmpty, reason: '预期端点有回执发布');
    final p = bus.published.last;
    return RcCodec.decode(p.wire, key, p.topic);
  }

  /// 与密码无关的、必然解密失败的密文。
  Future<String> garbageWire(AssistSession s) async {
    final wrong = await RcAssist.ctlKey(s.code, 'ZZZZZZZZ');
    return RcCodec.encode(
        RcMessage.now(RcAssistCmd.hello, {'ctrlName': '攻击者'}), wrong, s.topic);
  }

  /// 轮询等待会话真实到期。
  ///
  /// **不要用固定 `Future.delayed(ttl + margin)`**：`RcAssistHost` 的 TTL 走
  /// `DateTime.now()`（FakeAsync 虚拟化不了），而 CI/本机负载下 `start()` 内的
  /// 密钥派生耗时可能把固定余量吃掉 → 断言随机失败（AH-32 曾因此 flaky）。
  /// 轮询到条件成立为止，既确定又不受负载影响。
  Future<void> untilExpired(AssistSession s) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!s.expired && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  // ---------------- AH-0x 会话建立 ----------------

  group('AH 会话建立与凭据', () {
    test('AH-01 start() 生成合法凭据并订阅会合主题', () async {
      final s = await host.start();

      expect(RcAssist.isValidCode(s.code), isTrue);
      expect(RcAssist.isValidPassword(s.password), isTrue);
      expect(s.topic.startsWith(RcAssist.topicPrefix), isTrue);
      expect(s.phase, AssistPhase.waiting);
      expect(host.session, isNotNull);
      expect(host.active, isFalse, reason: '尚未握手，不应视为已建立');
      expect(bus.subscribed, [s.topic]);
      expect(audits.single.action, 'assist.start');
    });

    test('AH-02 会合主题由「临时码 + 密码」共同决定（只知临时码算不出）', () async {
      const code = '123456789';
      final a = await RcAssist.topicFor(code, 'ABCDEFGH');
      final b = await RcAssist.topicFor(code, 'ABCDEFGJ');

      expect(a, isNot(b), reason: '密码不同 → 主题必须不同');
      expect(a, await RcAssist.topicFor(code, 'ABCDEFGH'), reason: '确定性');

      // 主题里不得出现临时码明文（否则窃听者可直接订阅）。
      expect(a.contains(code), isFalse);
      expect(a.substring(RcAssist.topicPrefix.length).length, 16);
      expect(
          RegExp(r'^[0-9a-f]{16}$')
              .hasMatch(a.substring(RcAssist.topicPrefix.length)),
          isTrue);
    });

    test('AH-03 hello 握手成功 → 回 accept、会话激活、密钥就绪', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s, ctrlName: '  控制端A  '));

      expect(host.active, isTrue);
      expect(s.phase, AssistPhase.active);
      expect(s.ctrlName, '控制端A', reason: '两端空白应被裁剪');
      expect(host.keys, isNotNull);
      expect(host.keys!.sessionId, s.sessionId);
      expect(s.sessionId, isNotEmpty);

      final accept = await openLast(await RcAssist.epKey(s.code, s.password));
      expect(accept, isNotNull);
      expect(accept!.type, RcAssistCmd.accept);
      expect(accept.payload['epName'], '端点-测试机');
      expect(accept.payload['sessionId'], s.sessionId);
      expect(accept.payload['expiresAt'], s.expiresAt.millisecondsSinceEpoch);
    });

    test('AH-04 accept 回执中权限默认全拒（C5）', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));

      final accept = await openLast(await RcAssist.epKey(s.code, s.password));
      final perms =
          AssistPerms.fromJson((accept!.payload['perms'] as Map).cast());
      expect(perms.toJson().values.every((v) => v == false), isTrue,
          reason: '会话建立时不得放行任何能力');
    });

    test('AH-05 重复 hello 幂等：重发 accept 且 sessionId 不变', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      final first = s.sessionId;
      final countAfterFirst = bus.published.length;

      await host.onWire(await helloWire(s, ctrlName: '控制端A'));

      expect(s.sessionId, first);
      expect(bus.published.length, countAfterFirst + 1, reason: '应重发一条 accept');
      expect(s.phase, AssistPhase.active);
    });

    test('AH-06 控制端显示名为空时回落占位名，且超长被截断', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s, ctrlName: '   '));
      expect(s.ctrlName, '未命名控制端');

      await host.close(silent: true);
      final s2 = await host.start();
      await host.onWire(await helloWire(s2, ctrlName: 'x' * 200));
      expect(s2.ctrlName.length, 60);
    });
  });

  // ---------------- AH-1x 防爆破与生命周期 ----------------

  group('AH 防爆破与生命周期', () {
    test('AH-10 密码错误的密文 → 计入握手失败，不回 accept', () async {
      final s = await host.start();
      await host.onWire(await garbageWire(s));

      expect(s.failures, 1);
      expect(host.active, isFalse);
      expect(bus.published, isEmpty, reason: '不应向未认证方回执');
      expect(audits.last.action, 'assist.handshake');
      expect(audits.last.status, 'skipped');
    });

    test('AH-11 握手失败 5 次 → 会话作废并退订主题', () async {
      final s = await host.start();
      final topic = s.topic;

      for (var i = 0; i < RcAssist.maxFailures; i++) {
        await host.onWire(await garbageWire(s));
      }

      expect(s.failures, RcAssist.maxFailures);
      expect(host.session, isNull, reason: '超限应立即作废整场会话');
      expect(host.keys, isNull);
      expect(bus.unsubscribed, contains(topic));
      expect(audits.where((a) => a.action == 'assist.handshake').length,
          RcAssist.maxFailures);
      expect(audits.last.action, 'assist.end');
      expect(audits.last.message, contains('失败次数超限'));
    });

    test('AH-12 同一密文重放不计失败（否则重放 5 次即可锁死会话）', () async {
      final s = await host.start();
      final replayed = await garbageWire(s);

      for (var i = 0; i < 10; i++) {
        await host.onWire(replayed);
      }

      expect(s.failures, 1, reason: '重复密文只应计一次失败');
      expect(host.session, isNotNull, reason: '会话不应被重放锁死');
    });

    test('AH-13 会话激活后垃圾密文不计失败（防 broker 侧 DoS）', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      expect(host.active, isTrue);

      for (var i = 0; i < 10; i++) {
        await host.onWire(await garbageWire(s));
      }

      expect(s.failures, 0, reason: '已认证会话的噪声不应消耗失败额度');
      expect(host.active, isTrue);
      expect(host.session, isNotNull);
    });

    test('AH-14 TTL 到期 → tick() 自动终止并退订（C4）', () async {
      final s = await host.start(ttl: const Duration(milliseconds: 200));
      await untilExpired(s);
      expect(s.expired, isTrue);

      host.tick();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(host.session, isNull);
      expect(host.keys, isNull);
      expect(bus.unsubscribed, contains(s.topic));
      expect(audits.last.message, contains('TTL 到期'));
    });

    test('AH-15 会话过期后 hello → 回 reject(ttl_expired)', () async {
      final s = await host.start(ttl: const Duration(milliseconds: 200));
      await untilExpired(s);
      await host.onWire(await helloWire(s));

      final reject = await openLast(await RcAssist.epKey(s.code, s.password));
      expect(reject, isNotNull);
      expect(reject!.type, RcAssistCmd.reject);
      expect(reject.payload['reason'], 'ttl_expired');
      expect(host.active, isFalse, reason: '过期会话不得被激活');
      expect(s.phase, AssistPhase.waiting, reason: '拒绝不得推进状态机');
    });

    test('AH-16 控制端发起 close → 端点终止且不再回执', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      final ctlKey = await RcAssist.ctlKey(s.code, s.password);

      await host.onWire(await RcCodec.encode(
          RcMessage.now(RcAssistCmd.close), ctlKey, s.topic));

      expect(host.session, isNull);
      expect(bus.unsubscribed, contains(s.topic));
      expect(audits.last.message, contains('控制端终止'));
    });

    test('AH-17 start() 替换旧会话：旧主题退订、新主题订阅', () async {
      final s1 = await host.start();
      final s2 = await host.start();

      expect(bus.unsubscribed, contains(s1.topic));
      expect(bus.subscribed, [s1.topic, s2.topic]);
      expect(host.session, same(s2));
      expect(s1.topic, isNot(s2.topic), reason: '新会话必须是全新凭据');

      final superseded = audits.where((a) => a.action == 'assist.end');
      expect(superseded, hasLength(1), reason: '旧会话应被审计为终止');
      expect(superseded.first.message, contains('被新会话替换'));
    });

    test('AH-18 会话结束后 onWire 为无操作', () async {
      final s = await host.start();
      final wire = await helloWire(s);
      await host.close();
      final published = bus.published.length;

      await host.onWire(wire);

      expect(bus.published.length, published);
      expect(host.session, isNull);
    });

    test('AH-19 未知消息类型静默忽略（向后兼容）', () async {
      final s = await host.start();
      final ctlKey = await RcAssist.ctlKey(s.code, s.password);

      await host.onWire(
          await RcCodec.encode(RcMessage.now('assist.未来扩展'), ctlKey, s.topic));

      expect(s.phase, AssistPhase.waiting, reason: '未知类型不应改变会话状态');
      expect(bus.published, isEmpty);
    });
  });

  // ---------------- AH-2x 权限门控 ----------------

  group('AH 权限门控（默认拒绝 / 失败关闭）', () {
    const allOn = AssistPerms(
      media: true,
      tts: true,
      vibrate: true,
      volume: true,
      location: true,
      video: true,
      script: true,
    );

    test('AH-20 只读命令无需授权即可放行', () {
      for (final c in [
        RcCmd.ping,
        RcCmd.statusGet,
        RcCmd.deviceStatus,
        RcCmd.taskList,
        RcCmd.taskGet,
        RcCmd.assetList,
        RcCmd.presetList,
      ]) {
        expect(RcAssistHost.requiredPerm(c), isNull, reason: '$c 应为只读');
        expect(RcAssistHost.allows(AssistPerms.none, c), isTrue);
      }
    });

    test('AH-20b logs.recent 必须授权：默认全拒下不可读（P2-1 回归锁）', () {
      // 审计日志会回传端点操作轨迹 —— 曾经它与 ping/status 同列"免授权"，
      // 未放行任何权限的对端即可读取，与"默认全拒"矛盾。
      expect(RcAssistHost.requiredPerm(RcCmd.logsRecent), 'audit');
      expect(RcAssistHost.allows(AssistPerms.none, RcCmd.logsRecent), isFalse,
          reason: '默认全拒下必须拒绝 logs.recent');
      // 只有 audit 位能放行它；script 位**不能**顶替（互不越权）。
      expect(RcAssistHost.allows(const AssistPerms(script: true),
          RcCmd.logsRecent), isFalse);
      expect(RcAssistHost.allows(const AssistPerms(audit: true),
          RcCmd.logsRecent), isTrue);
    });

    test('AH-21 动作命令默认全拒，授权后放行', () {
      const cases = {
        RcCmd.soundPlay: 'media',
        RcCmd.pttVoice: 'media',
        RcCmd.volumeSet: 'volume',
        RcCmd.locationGet: 'location',
        RcCmd.cameraSnap: 'video',
        RcCmd.callInvite: 'video',
        RcCmd.callEnd: 'video',
        RcCmd.scriptRun: 'script',
        RcCmd.scriptStop: 'script',
        RcCmd.taskRunNow: 'script',
        RcCmd.taskToggle: 'script',
        RcCmd.taskUpsert: 'script',
        RcCmd.taskDelete: 'script',
        RcCmd.guardSet: 'script',
      };
      cases.forEach((cmd, perm) {
        expect(RcAssistHost.requiredPerm(cmd), perm, reason: cmd);
        expect(RcAssistHost.allows(AssistPerms.none, cmd), isFalse,
            reason: '$cmd 默认必须拒绝');
        expect(RcAssistHost.allows(allOn, cmd), isTrue,
            reason: '$cmd 全放行后应可执行');
      });
    });

    test('AH-22 未登记命令失败关闭（即使全放行也拒绝）', () {
      for (final cmd in ['', 'unknown.cmd', 'task.upsert2', 'ASSIST.HELLO']) {
        final need = RcAssistHost.requiredPerm(cmd);
        expect(need, isNotNull, reason: '未登记命令必须返回非 null 权限要求');
        expect(RcAssistHost.allows(allOn, cmd), isFalse,
            reason: '$cmd 未登记 → 必须失败关闭，而不是默认放行');
      }
    });

    test('AH-23 指令组步骤权限：record 在协助会话下一律拒绝', () {
      expect(RcAssistHost.requiredStepPerm(RcStepKind.play), 'media');
      expect(RcAssistHost.requiredStepPerm(RcStepKind.tts), 'tts');
      expect(RcAssistHost.requiredStepPerm(RcStepKind.vibrate), 'vibrate');
      expect(RcAssistHost.requiredStepPerm(RcStepKind.delay), isNull);
      expect(RcAssistHost.requiredStepPerm(RcStepKind.notify), isNull);

      // 录音取证：没有任何权限位能放行它（保守拒绝，待独立权限位评估）。
      final recPerm = RcAssistHost.requiredStepPerm(RcStepKind.record);
      expect(recPerm, isNotNull);
      expect(RcAssistHost.hasPerm(allOn, recPerm!), isFalse);
    });

    test('AH-24 grant() 下发 assist.perm 并审计', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      final before = bus.published.length;

      final ok = await host.grant(const AssistPerms(media: true, volume: true));

      expect(ok, isTrue);
      expect(s.perms.media, isTrue);
      expect(s.perms.script, isFalse, reason: '未显式开启的位必须保持 false');
      expect(bus.published.length, before + 1);

      final perm = await openLast(await RcAssist.epKey(s.code, s.password));
      expect(perm!.type, RcAssistCmd.perm);
      expect((perm.payload['perms'] as Map)['media'], isTrue);

      final entry = audits.last;
      expect(entry.action, 'assist.perm');
      expect(entry.message, contains('播放音效'));
      expect(entry.message, contains('调节音量'));
      expect(entry.message, isNot(contains('执行指令组')));
    });

    test('AH-25 未建立会话时 grant() 不生效（无会话即无权限）', () async {
      expect(await host.grant(const AssistPerms(media: true)), isFalse);
      expect(bus.published, isEmpty);

      final s = await host.start();
      expect(await host.grant(const AssistPerms(media: true)), isFalse,
          reason: '等待接入阶段尚无密钥，不得下发');
      expect(s.perms.media, isFalse);
    });
  });

  // ---------------- AH-3x 审计与状态广播 ----------------

  group('AH 审计与状态广播', () {
    test('AH-30 关键节点均写入审计', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      await host.grant(const AssistPerms(script: true));
      await host.close();

      expect(
        audits.map((a) => a.action).toList(),
        ['assist.start', 'assist.accept', 'assist.perm', 'assist.end'],
      );
    });

    test('AH-31 changes 广播会话状态（UI 倒计时/横幅数据源）', () async {
      final seen = <AssistPhase?>[];
      final sub = host.changes.listen((s) => seen.add(s?.phase));

      final session = await host.start();
      await host.onWire(await helloWire(session));
      await Future<void>.delayed(Duration.zero);

      expect(seen, contains(AssistPhase.waiting));
      expect(seen, contains(AssistPhase.active));

      await sub.cancel();
    });

    test('AH-32 remaining 倒计时不为负，且过期后钳到 0', () async {
      final s = await host.start(ttl: const Duration(seconds: 30));
      expect(s.remaining.inMilliseconds, greaterThan(0));
      expect(s.remaining.inMilliseconds, lessThanOrEqualTo(30000));

      // 已过期会话的 remaining 必须是 0 而不是负数 ——
      // 否则 UI 会渲染出 "-1:-1" 这种倒计时。
      final past = AssistSession(
        code: '123456789',
        password: 'ABCDEFGH',
        topic: 'x',
        expiresAt: DateTime.now().subtract(const Duration(seconds: 5)),
      );
      expect(past.expired, isTrue);
      expect(past.remaining, Duration.zero);
    });

    test('AH-33 会话凭据为一次性：两次 start() 的码与密码均不同', () async {
      final a = await host.start();
      final b = await host.start();

      expect(a.code, isNot(b.code));
      expect(a.password, isNot(b.password));
      expect(a.topic, isNot(b.topic));
    });
  });
  // ---------------- AH-4x 业务命令门控与回执通道 ----------------

  group('AH 业务命令门控与回执通道', () {
    /// 以控制端身份向会话发送一条业务命令。
    Future<void> business(AssistSession s, String type,
        {Map<String, dynamic> payload = const {}}) async {
      final ctlKey = await RcAssist.ctlKey(s.code, s.password);
      await host.onWire(
          await RcCodec.encode(RcMessage.now(type, payload), ctlKey, s.topic));
    }

    test('AH-40 会话未激活时业务命令不执行、不回调执行层', () async {
      final s = await host.start();
      final seen = <String>[];
      host.onCommand = (m) async => seen.add(m.type);

      await business(s, RcCmd.ping);

      expect(seen, isEmpty, reason: '未握手不得执行任何业务命令（含只读）');
      expect(audits.last.action, 'assist.deny');
      expect(audits.last.message, contains('会话未激活'));
    });

    test('AH-41 只读业务命令无需授权即可执行并回调', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      final seen = <String>[];
      host.onCommand = (m) async => seen.add(m.type);

      await business(s, RcCmd.ping);

      expect(seen, [RcCmd.ping]);
    });

    test('AH-42 动作命令未授权 → 回 rc.ack{ok:false} 且不回调执行层', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      final seen = <String>[];
      host.onCommand = (m) async => seen.add(m.type);

      await business(s, RcCmd.soundPlay, payload: {'assetId': 'a1'});

      expect(seen, isEmpty, reason: '默认全拒（C5）：未授权命令绝不能到达执行层');

      final ack = await openLast(await RcAssist.epKey(s.code, s.password));
      expect(ack, isNotNull, reason: '拒绝必须显式回执，否则控制端会无限重试');
      expect(ack!.type, RcEvt.ack);
      expect(ack.payload['ok'], isFalse);
      expect(ack.payload['forType'], RcCmd.soundPlay);
      expect(ack.payload['data'], contains('播放音效'));
      expect(audits.last.action, 'assist.deny');
    });

    test('AH-43 授权后回调执行层，且回调运行在 assistReplyZone 内', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      await host.grant(const AssistPerms(media: true));

      final seen = <String>[];
      var inAssistZone = false;
      host.onCommand = (m) async {
        seen.add(m.type);
        // 端点服务的 _send 靠这个 Zone 标记把回执改走会合主题。
        inAssistZone = Zone.current[assistReplyZone] == true;
      };

      await business(s, RcCmd.soundPlay, payload: {'assetId': 'a1'});

      expect(seen, [RcCmd.soundPlay]);
      expect(inAssistZone, isTrue, reason: '执行层回执必须被路由到会合主题');
    });

    test('AH-44 执行层回执经 sendReply 走会合主题、epKey 加密', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      await host.grant(const AssistPerms(media: true));
      host.onCommand = (m) async {
        await host
            .sendReply(RcMessage.now(RcEvt.ack, {'ok': true, 'for': m.id}));
      };

      await business(s, RcCmd.soundPlay);

      final ack = await openLast(await RcAssist.epKey(s.code, s.password));
      expect(ack, isNotNull);
      expect(ack!.type, RcEvt.ack);
      expect(ack.payload['ok'], isTrue);
      expect(bus.published.last.topic, s.topic, reason: '回执必须发在会合主题上');

      // 控制端用 ctlKey 无法解开 epKey 加密的回执（方向密钥隔离）。
      final wrong = await RcCodec.decode(bus.published.last.wire,
          await RcAssist.ctlKey(s.code, s.password), s.topic);
      expect(wrong, isNull);
    });

    test('AH-45 未登记业务命令失败关闭：拒绝且不回调', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      await host.grant(const AssistPerms(
        media: true,
        tts: true,
        vibrate: true,
        volume: true,
        location: true,
        video: true,
        script: true,
      ));
      final seen = <String>[];
      host.onCommand = (m) async => seen.add(m.type);

      await business(s, 'evil.cmd');

      expect(seen, isEmpty, reason: '未登记命令即使全放行也不得执行');
      final ack = await openLast(await RcAssist.epKey(s.code, s.password));
      expect(ack!.payload['ok'], isFalse);
    });

    test('AH-46 会话终止后 sendReply 为无操作', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      await host.close();
      final published = bus.published.length;

      await host.sendReply(RcMessage.now(RcEvt.ack, {'ok': true}));

      expect(bus.published.length, published);
    });
  });

  // ---------------- AH-6x D-7 载荷级裁决 + 执行层异常兜底 ----------------

  /// D-7（docs/22 §9）与 BUG-051 同源面：
  ///
  /// - **命令级门控只认命令类型** —— `task.upsert` 只需 `script` 位，
  ///   若不在载荷层再看一眼动作类型，只放行 `script` 的对端即可塞进
  ///   `actionType:'recordEvidence'` 的任务绕开步骤级 `denyAll`；
  /// - **执行层抛异常必须变成"审计 + 显式回执"** —— 否则控制端只看到
  ///   "点了没反应"，与权限拒绝无法区分（BUG-051 的形状）。
  group('AH D-7 任务载荷裁决与执行层异常兜底', () {
    const allOn = AssistPerms(
      media: true,
      tts: true,
      vibrate: true,
      volume: true,
      location: true,
      video: true,
      script: true,
      audit: true,
    );

    /// 以控制端身份向会话发送一条业务命令。
    Future<void> business(AssistSession s, String type,
        {Map<String, dynamic> payload = const {}}) async {
      final ctlKey = await RcAssist.ctlKey(s.code, s.password);
      await host.onWire(
          await RcCodec.encode(RcMessage.now(type, payload), ctlKey, s.topic));
    }

    test('AH-60 task.upsert 载荷含 record 动作 → 载荷级裁决拒绝（D-7 回归锁）', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      await host.grant(allOn);
      final seen = <String>[];
      host.onCommand = (m) async => seen.add(m.type);
      final before = bus.published.length;

      await business(s, RcCmd.taskUpsert, payload: {
        'task': {'name': '取证', 'action': {'kind': 'record'}},
      });

      expect(seen, isEmpty,
          reason: '命令级只有 script 位 —— 不看载荷就会让 record 动作绕过步骤级 denyAll');
      final ack = await openLast(await RcAssist.epKey(s.code, s.password));
      expect(ack!.type, RcEvt.ack);
      expect(ack.payload['ok'], isFalse);
      expect(ack.payload['forType'], RcCmd.taskUpsert);
      expect(ack.payload['data'], contains('未放行'));
      expect(audits.last.action, 'assist.deny');
      expect(audits.last.message, contains('任务动作需要权限'));
      expect(bus.published.length, before + 1, reason: '拒绝必须只发一条回执');
    });

    test('AH-61 task.upsert 载荷无可拒绝动作 → 放行到执行层', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      await host.grant(allOn);
      final seen = <String>[];
      host.onCommand = (m) async => seen.add(m.type);

      await business(s, RcCmd.taskUpsert, payload: {
        'task': {'name': '提示', 'action': {'kind': 'notify'}},
      });

      expect(seen, [RcCmd.taskUpsert], reason: '无危险动作不得被误拒');
    });

    test('AH-62 task.upsert 的 task 字段结构非法 → 本层不拒，交 TaskWire 兜底', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      await host.grant(allOn);
      final seen = <String>[];
      host.onCommand = (m) async => seen.add(m.type);

      await business(s, RcCmd.taskUpsert, payload: {'task': 'not-a-map'});

      expect(seen, [RcCmd.taskUpsert], reason: '结构非法由 TaskWire.fromWire 兜底拒绝');
    });

    test('AH-63 执行层抛异常 → 审计 failed + 显式回执拒绝（BUG-051 同源）', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      await host.grant(allOn);
      host.onCommand = (m) async => throw StateError('db locked');

      await business(s, RcCmd.soundPlay, payload: {'assetId': 'a1'});

      expect(audits.last.action, RcCmd.soundPlay);
      expect(audits.last.status, 'failed');
      expect(audits.last.message, contains('处理器异常'));

      final ack = await openLast(await RcAssist.epKey(s.code, s.password));
      expect(ack!.type, RcEvt.ack);
      expect(ack.payload['ok'], isFalse);
      expect(ack.payload['data'], contains('处理器异常'));
      expect(ack.payload['data'], contains('db locked'),
          reason: '真实原因必须回传，否则只剩下"20 秒超时"');
      expect(bus.published.last.topic, s.topic, reason: '回执必须走会合主题');
    });

    test('AH-64 tick()：会话健康时广播一次，驱动 UI 倒计时', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      final seen = <AssistSession?>[];
      final sub = host.changes.listen(seen.add);
      await Future<void>.delayed(Duration.zero); // 广播控制器是异步投递

      host.tick();
      await Future<void>.delayed(Duration.zero);

      expect(seen, isNotEmpty);
      expect(seen.last, same(s));
      await sub.cancel();
    });

    test('AH-65 tick()：失败超限后 phase=closed 但 _session 未清 → 自停计时器不广播',
        () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));

      // 生产侧同形窗口：`_onHandshakeFailure` 先 `registerFailure()`
      // （锁定时把 phase 置 closed），再 `await audit` —— 这段时间里
      // `_session` 仍非空。此时周期 tick 必须自停而不是继续广播。
      for (var i = 0; i < RcAssist.maxFailures; i++) {
        s.registerFailure();
      }
      expect(s.phase, AssistPhase.closed);
      expect(host.session, isNotNull, reason: 'close() 尚未走到，会话对象还在');

      final seen = <AssistSession?>[];
      final sub = host.changes.listen(seen.add);
      await Future<void>.delayed(Duration.zero);

      host.tick();
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty, reason: '会话已判决关闭 ⇒ 不应再驱动倒计时');
      await sub.cancel();
    });

    test('AH-66 密文去重窗口超限后按插入序淘汰最旧（窗口有界 + ID 去重不被破坏）',
        () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      final calls = <String>[];
      host.onCommand = (m) async => calls.add(m.id);

      final ctlKey = await RcAssist.ctlKey(s.code, s.password);
      final wires = <String>[];
      for (var i = 0; i < RcAssistHost.maxSeenWires + 3; i++) {
        wires.add(await RcCodec.encode(
            RcMessage.now(RcCmd.ping, {'i': i}), ctlKey, s.topic));
      }
      for (final w in wires) {
        await host.onWire(w);
      }

      expect(calls.length, RcAssistHost.maxSeenWires + 3,
          reason: '每条都是不同密文 ⇒ 全部应被执行');

      // 最旧的 3 条已被淘汰出"密文窗口"，重放它们会再次进入 _rememberWire，
      // 但 ID 去重必须仍然生效 —— 否则重放等于可重复执行。
      await host.onWire(wires.first);
      await host.onWire(wires.last);
      expect(calls.length, RcAssistHost.maxSeenWires + 3,
          reason: '淘汰密文窗口不得破坏 ±90s 的 ID 去重');
    });
  });

  // ---------------- AH-5x 生命周期顺序与守卫（P0-1） ----------------

  group('AH 生命周期顺序与守卫（P0-1）', () {
    test('AH-50 start()：审计抛异常不得阻断会话建立与广播（根因 b）', () async {
      // 真实 sqflite insert 会抛（磁盘满 / 锁表）。
      host.audit = (a, s, m) async => throw StateError('audit boom');
      final seen = <AssistSession?>[];
      final sub = host.changes.listen(seen.add);

      final s = await host.start();
      await Future<void>.delayed(Duration.zero);

      expect(host.session, isNotNull, reason: '审计失败不得阻断会话创建');
      // 若 _emit() 在 audit 之后，这里不会出现 s —— 即"看不到码"的原始形状。
      expect(seen, contains(s), reason: '_emit 必须发生在 audit 之前');
      await sub.cancel();
    });

    test('AH-51 start()：订阅抛异常不得阻断会话建立（码仍可见）', () async {
      final t = _FakeTransport()..failSubscribe = true;
      final h = RcAssistHost()..bind(t);
      try {
        final s = await h.start();
        expect(h.session, isNotNull);
        expect(RcAssist.isValidCode(s.code), isTrue);
      } finally {
        await h.close(silent: true);
      }
    });

    test('AH-52 close()：审计抛异常不得留下"僵尸会话"（根因 b 同类）', () async {
      final s = await host.start();
      await host.onWire(await helloWire(s));
      host.audit = (a, st, m) async => throw StateError('audit boom');

      await host.close();

      expect(host.session, isNull, reason: 'close 后 _session 必须为 null');
      expect(host.keys, isNull);
      // 且必须还能立刻生成新会话（不被僵尸状态卡住）。
      host.audit = (a, st, m) async {};
      final again = await host.start();
      expect(again.code, isNot(s.code));
    });

    test('AH-53 模块未开启（未绑定传输）→ start() 明确拒绝，不生成死码', () async {
      final offline = RcAssistHost();
      await expectLater(offline.start(), throwsA(isA<StateError>()));
      expect(offline.session, isNull, reason: '被拒绝时不得留下任何会话');
    });
  });
}

/// 记录所有收发动作的假传输（不碰网络，便于确定性断言）。
class _FakeTransport implements AssistTransport {
  final subscribed = <String>[];
  final unsubscribed = <String>[];
  final published = <({String topic, String wire})>[];

  /// 置 true 时 [subscribe] 抛异常（模拟 broker 不可达）。
  bool failSubscribe = false;

  @override
  Future<void> subscribe(String topic) async {
    if (failSubscribe) throw StateError('broker down');
    subscribed.add(topic);
  }

  @override
  Future<void> unsubscribe(String topic) async => unsubscribed.add(topic);

  @override
  Future<void> publishWire(String topic, String wire) async =>
      published.add((topic: topic, wire: wire));
}
