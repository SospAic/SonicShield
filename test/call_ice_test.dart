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

    test('CS-02 配置 TURN 后 STUN 仍在列，TURN 追加在后（可选叠加）', () async {
      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.setTurn(
          url: 'turn:relay.example.com:3478', user: 'u', cred: 'p');

      final servers = await CallService.iceServers();

      final stunCount =
          servers.where((s) => (s['urls'] as String).startsWith('stun:')).length;
      expect(stunCount, greaterThan(0), reason: 'STUN 不应被 TURN 顶掉');
      final turn = servers.last;
      expect(turn['urls'], 'turn:relay.example.com:3478');
      expect(turn['username'], 'u');
      expect(turn['credential'], 'p');
    });

    test('CS-03 TURN 无账号密码时不塞空字段（部分服务器不接受空凭据）', () async {
      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.setTurn(url: 'turn:relay.example.com:3478', user: '', cred: '');

      final turn = (await CallService.iceServers()).last;

      expect(turn.containsKey('username'), isFalse);
      expect(turn.containsKey('credential'), isFalse);
    });

    test('CS-04 关闭 TURN 后回到纯 STUN', () async {
      final store = RemoteStore(await SharedPreferences.getInstance());
      await store.setTurn(url: 'turn:x:3478', user: 'u', cred: 'p');
      expect((await CallService.iceServers()).length, greaterThan(2));

      await store.setTurn(url: '', user: '', cred: '');

      expect((await CallService.iceServers()).every(
              (s) => (s['urls'] as String).startsWith('stun:')),
          isTrue);
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
