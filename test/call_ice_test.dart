import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// ICE/TURN 配置与「无 TURN 降级」（v1.7 S5，docs/18 §S5）契约测试。
///
/// 本文件锁定两点：
///
/// 1. **TURN 是可选叠加，不是替换**：STUN 始终在列，TURN 配置后追加；
///    绝不能因为配了 TURN 就把 STUN 去掉（STUN 打洞成功时不该走中继 ——
///    中继耗带宽、绕远路，还可能经手使用者的媒体流）。
/// 2. **失败必须可诊断**：未配置 TURN 时的 ICE 失败不能只说"连接失败"，
///    否则使用者无从下手。提示必须指向"对称 NAT + 去配 TURN"。
///
/// 注意：真实打洞行为无法在单测里复现（需要真实网络与 NAT），
/// 因此这里只覆盖**配置组装**与**降级文案**这两处纯逻辑；
/// 对称 NAT 场景的真机验证仍属未闭环项（docs/17）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CS ICE 服务器组装', () {
    test('CS-01 未配置 TURN 时只给 STUN（默认可用）', () async {
      final servers = await CallService.iceServers();

      expect(servers, isNotEmpty);
      expect(servers.every((s) => (s['urls'] as String).startsWith('stun:')),
          isTrue);
      expect(servers.any((s) => (s['urls'] as String).startsWith('turn:')),
          isFalse);
    });

    test('CS-02 配置 TURN 后 STUN 仍在列，TURN（UDP+TCP 双通道）追加在后', () async {
      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.setTurn(
          url: 'turn:relay.example.com:3478', user: 'u', cred: 'p');

      final servers = await CallService.iceServers();

      final stunCount = servers
          .where((s) => (s['urls'] as String).startsWith('stun:'))
          .length;
      expect(stunCount, greaterThan(0), reason: 'STUN 不应被 TURN 顶掉');
      final turns = servers
          .where((s) => (s['urls'] as String).startsWith('turn:'))
          .toList();
      expect(turns, hasLength(2), reason: 'UDP + TCP 双通道，封 UDP 网络下仍能连');
      // UDP 优先（质量最好），TCP 兜底 —— 顺序不能反。
      expect(turns.first['urls'], 'turn:relay.example.com:3478');
      expect(turns.last['urls'], 'turn:relay.example.com:3478?transport=tcp');
      for (final t in turns) {
        expect(t['username'], 'u');
        expect(t['credential'], 'p', reason: '两条通道共用同一凭据');
      }
    });

    test('CS-03 TURN 无账号密码时不塞空字段（部分服务器不接受空凭据）', () async {
      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.setTurn(
          url: 'turn:relay.example.com:3478', user: '', cred: '');

      final turns = (await CallService.iceServers())
          .where((s) => (s['urls'] as String).startsWith('turn:'))
          .toList();

      expect(turns, isNotEmpty, reason: '前置：TURN 已配置');
      for (final t in turns) {
        expect(t.containsKey('username'), isFalse);
        expect(t.containsKey('credential'), isFalse);
      }
    });

    test('CS-04 关闭 TURN 后回到纯 STUN', () async {
      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.setTurn(url: 'turn:x:3478', user: 'u', cred: 'p');
      expect((await CallService.iceServers()).length, greaterThan(2));

      await store.setTurn(url: '', user: '', cred: '');

      expect(
          (await CallService.iceServers())
              .every((s) => (s['urls'] as String).startsWith('stun:')),
          isTrue);
    });
  });

  group('CS STUN 可达性（BUG-081：连接极慢/不可用）', () {
    test('CS-05 STUN 必须包含国内可达节点（不得回退成清一色 Google）', () async {
      final stun = (await CallService.iceServers())
          .where((s) => (s['urls'] as String).startsWith('stun:'))
          .map((s) => s['urls'] as String)
          .toList();

      expect(stun, contains('stun:stun.miwifi.com:3478'));
      expect(stun, contains('stun:stun.chat.bilibili.com:3478'));
      final cn = stun.where((u) => !u.contains('google')).length;
      expect(cn, greaterThanOrEqualTo(3),
          reason: 'Google STUN 在中国大陆基本不可达，不能是唯一来源；'
              '否则拿不到 srflx 候选 → 跨网直连必然失败（BUG-081）');
    });

    test('CS-06 指定首选 STUN 后只用它（第八十二轮：下拉切换）', () async {
      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.setStunSelectedUrl('stun:stun.qq.com:3478');

      final stun = (await CallService.iceServers())
          .where((s) => (s['urls'] as String).startsWith('stun:'))
          .map((s) => s['urls'] as String)
          .toList();

      expect(stun, ['stun:stun.qq.com:3478'],
          reason: '固定一个节点后就只用它；传空串才回到「自动：全部并行」');
    });
  });

  group('CS PeerConnection 统一配置（建连提速）', () {
    test('CS-20 关键 ICE 参数齐备（单路/多路共用同一份）', () async {
      final cfg = await CallService.peerConnectionConfig();

      expect(cfg['bundlePolicy'], 'max-bundle');
      expect(cfg['rtcpMuxPolicy'], 'require');
      expect(cfg['iceCandidatePoolSize'], CallService.iceCandidatePoolSize);
      expect(cfg['iceTransportPolicy'], 'all', reason: '直连优先，TURN 只兜底');
      expect(cfg['sdpSemantics'], 'unified-plan');
      expect(cfg['iceServers'], isA<List<dynamic>>());
    });

    test('CS-21 multi_call_service 必须复用同一份配置（不得各写一套）', () {
      final f = [
        'lib/remote/multi_call_service.dart',
        '../lib/remote/multi_call_service.dart',
      ].map(File.new).where((e) => e.existsSync()).toList();
      expect(f, isNotEmpty, reason: '找不到 multi_call_service.dart');
      final src = f.first.readAsStringSync();
      expect(src, contains('CallService.peerConnectionConfig()'),
          reason: '多路必须复用统一配置，否则"单路来电"与"多路同连"参数漂移');
      expect(src, isNot(contains("'iceServers': await CallService.iceServers()")),
          reason: '多路不得自己拼 iceServers（会漏掉 ICE 参数）');
    });
  });

  group('CS 无 TURN 降级提示', () {
    test('CS-10 未配置 TURN 的失败提示指向对称 NAT 与配置入口', () {
      final hint = CallService.failureHint(turnConfigured: false);

      expect(hint, contains('对称 NAT'));
      expect(hint, contains('TURN'));
      expect(hint, contains('远程'), reason: '必须告诉使用者去哪里配置');
      // 不能是"连接失败"这种无从下手的文案
      expect(hint.length, greaterThan(20));
    });

    test('CS-11 已配置 TURN 却仍失败时，提示转向排查 TURN 本身', () {
      final hint = CallService.failureHint(turnConfigured: true);

      expect(hint, contains('TURN'));
      expect(hint, isNot(contains('对称 NAT 时通话会直连失败')));
      expect(hint, contains('UDP'), reason: '提醒防火墙放行 UDP');
    });

    test('CS-12 两条提示必须不同（否则无法区分该去配中继还是查中继）', () {
      expect(CallService.failureHint(turnConfigured: false),
          isNot(CallService.failureHint(turnConfigured: true)));
    });

    test('CS-13 初始无失败原因，失败广播通道可订阅', () {
      expect(CallService.instance.failureReason, isNull);
      expect(CallService.instance.failures, isA<Stream<String>>());
    });
  });
}
