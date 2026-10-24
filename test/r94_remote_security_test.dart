import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/credential_sealer.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/guarded_dispatch.dart';
import 'package:sonic_shield/remote/inbound_seen_store.dart';
import 'package:sonic_shield/remote/peer_key_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_playback.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// R94 远程遥控 / 安全修复轮（F1c）的回归锁。
///
/// 每条用例都带**反面样本**：只断言"正确路径能过"的测试是恒真的
/// （例如"解密成功"在密钥恰好对上时永远成立），无法证明修复存在。
/// 因此这里一律同时断言"错误路径必须失败"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CredentialSealer.resetForTest();
  });

  // ══════════════════════════════════════════════════════════════
  // REM-01：v3 每控制端密钥
  // ══════════════════════════════════════════════════════════════
  group('R94-V3 每控制端密钥（REM-01 根治）', () {
    const topic = 'sonicshield/v1/aaaaaaaaaaaaaaaa/cmd';
    const ctx = 'aaaaaaaaaaaaaaaa|cmd';

    test('V3-01 命中第二把候选 ⇒ 下标为 1（身份来自"用哪把钥匙解开"）', () async {
      final right = RcCodec.newPeerKey();
      final wrong = RcCodec.newPeerKey();
      expect(right.length, 32);
      expect(wrong, isNot(right));

      final msg = RcMessage.now('ping', const {'n': 1}, 'bbbbbbbbbbbbbbbb');
      final wire = await RcCodec.encode(msg, const <int>[], topic,
          peerKey: right, peerContext: ctx);

      final hit = await RcCodec.decodeWithCandidates(wire, topic,
          candidateKeys: <List<int>>[wrong, right], peerContext: ctx);
      expect(hit, isNotNull, reason: '正确 key 在候选里，必须解开');
      expect(hit!.candidateIndex, 1, reason: '★ 命中下标就是发送方身份的索引');
      expect(hit.message.type, 'ping');
      expect(hit.message.payload['n'], 1);
    });

    test('V3-02 反面：只给错误 key ⇒ 解不开（v3 绝不回落共享配对码）', () async {
      final right = RcCodec.newPeerKey();
      final wrong = RcCodec.newPeerKey();
      final wire = await RcCodec.encode(
          RcMessage.now('ping'), const <int>[], topic,
          peerKey: right, peerContext: ctx);

      final hit = await RcCodec.decodeWithCandidates(wire, topic,
          candidateKeys: <List<int>>[wrong], peerContext: ctx);
      expect(hit, isNull);

      // 再给一把"共享配对码派生"的兜底密钥：v3 报文仍不得被它打开。
      final legacy =
          await RcCodec.deriveKey('ABCD1234', ctx);
      final fallbackHit = await RcCodec.decodeWithCandidates(
        wire,
        topic,
        candidateKeys: <List<int>>[wrong],
        peerContext: ctx,
        fallbackKey: legacy,
      );
      expect(fallbackHit, isNull,
          reason: '★ v3 报文只能被 peerKey 打开；回落共享码等于撤销失效');
    });

    test('V3-03 反面：context 不符 ⇒ 解不开（AAD/派生上下文绑定）', () async {
      final key = RcCodec.newPeerKey();
      final wire = await RcCodec.encode(
          RcMessage.now('ping'), const <int>[], topic,
          peerKey: key, peerContext: ctx);
      final hit = await RcCodec.decodeWithCandidates(wire, topic,
          candidateKeys: <List<int>>[key],
          peerContext: 'cccccccccccccccc|cmd');
      expect(hit, isNull);
    });

    test('V3-04 撤销后旧密文永久解不开（removePaired 删 key）', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = RemoteStore(prefs);
      const ctrl = 'cccccccccccccccc';
      final key = RcCodec.newPeerKey();
      await store.addPaired(PairedEndpoint(
        deviceId: ctrl,
        name: '控制端',
        secret: 'ABCD1234',
        pairedAt: DateTime.now(),
      ));
      await store.setPeerKey(ctrl, key);
      expect(store.peerKeys.keyFor(ctrl), isNotNull);

      // 撤销**之前**的密文（模拟"对方手里那把钥匙加密的命令"）
      final wire = await RcCodec.encode(
          RcMessage.now('ping'), const <int>[], topic,
          peerKey: key, peerContext: ctx);
      expect(
          await RcCodec.decodeWithCandidates(wire, topic,
              candidateKeys: <List<int>>[key], peerContext: ctx),
          isNotNull);

      await store.removePaired(ctrl);

      expect(store.peerKeys.keyFor(ctrl), isNull,
          reason: '★ removePaired 必须同时删掉这把钥匙');
      expect(store.peerKeys.ids().contains(ctrl), isFalse);
      // 端点此刻的候选集合（= 配对表里所有有 key 的控制端）
      final candidates = <List<int>>[
        for (final p in store.paired())
          if (p.peerKeyBytes != null) p.peerKeyBytes!,
      ];
      expect(candidates, isEmpty);
      expect(
          await RcCodec.decodeWithCandidates(wire, topic,
              candidateKeys: candidates, peerContext: ctx),
          isNull,
          reason: '★ 撤销 = 凭据级失效：旧密文再也打不开');
    });

    test('V3-05 轮换配对码清空全部 peerKey，且记录里的 pk 一并抹掉', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = RemoteStore(prefs);
      await store.addPaired(PairedEndpoint(
        deviceId: 'dddddddddddddddd',
        name: '控制端',
        secret: 'ABCD1234',
        pairedAt: DateTime.now(),
      ));
      await store.setPeerKey('dddddddddddddddd', RcCodec.newPeerKey());
      expect(store.peerKeys.ids(), isNotEmpty);

      await store.rotatePairingCode();

      expect(store.peerKeys.ids(), isEmpty);
      expect(store.paired().first.peerKey, isNull,
          reason: '记录里残留 pk 会让出站误以为还能走 v3');
    });

    test('V3-06 PeerKeyStore save/load/delete/ids 往返（含坏值拒绝）', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = PeerKeyStore(prefs);
      final key = RcCodec.newPeerKey();
      await store.save('eeeeeeeeeeeeeeee', key);
      expect(store.keyFor('eeeeeeeeeeeeeeee'), key);
      expect(store.ids(), {'eeeeeeeeeeeeeeee'});

      // 长度不是 32 的值必须被拒（半截密钥比没有密钥更危险）。
      await prefs.setString(
          PeerKeyStore.storageKey,
          jsonEncode(<String, String>{
            'ffffffffffffffff': base64Encode(<int>[1, 2, 3]),
          }));
      expect(store.keyFor('ffffffffffffffff'), isNull);

      // 新实例读同一份存储（模拟进程重启）
      final reopened = PeerKeyStore(prefs);
      expect(reopened.ids(), {'ffffffffffffffff'});

      await reopened.remove('ffffffffffffffff');
      expect(reopened.ids(), isEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // REM-06 / REM-05：入站判据
  // ══════════════════════════════════════════════════════════════
  group('R94-INBOUND 入站判据', () {
    test('IB-01 deviceId 字符集白名单（REM-06）', () {
      expect(PairQrProtocol.isValidDeviceId('0123456789abcdef'), isTrue);
      expect(PairQrProtocol.isValidDeviceId('+/+/+/+/+/+/+/+a'), isFalse,
          reason: '★ 16 字符的通配符注入必须被字符集挡下');
      expect(PairQrProtocol.isValidDeviceId('sonicshield/v1/x'), isFalse);
      expect(PairQrProtocol.isValidDeviceId('0123456789abcde'), isFalse,
          reason: '长度 15 不是合法 ID');
      expect(PairQrProtocol.isValidDeviceId('0123456789abcdef0'), isFalse);
      expect(PairQrProtocol.isValidDeviceId('0123456789abcde '), isFalse);

      final bad = PairQrProtocol.parseUri(
          'sonicshield://pair/+/+/+/+/+/+/+/+a/name/ABCD1234');
      expect(bad, isNull, reason: '★ 扫码路径同样必须拒绝');
    });

    test('IB-02 廉价前置门：垃圾报文不进 PBKDF2（REM-05）', () async {
      expect(looksLikeRcWire(''), isFalse);
      expect(looksLikeRcWire('x' * 500), isFalse);
      expect(looksLikeRcWire('not-base64!!'), isFalse);

      // 合法线格式必须通过（反面：不能"为了安全把所有报文都挡掉"）
      final wire = await RcCodec.encode(
          RcMessage.now('ping'), await RcCodec.deriveKey('ABCD1234', 'ctx'),
          't');
      expect(looksLikeRcWire(wire), isTrue);
    });

    test('IB-03 每源滑窗限速：阈值内放行、超限拒绝、出窗恢复', () {
      final gate = RcWireGate(windowMs: 1000, maxPerWindow: 3);
      expect(gate.allow('t', 0), isTrue);
      expect(gate.allow('t', 10), isTrue);
      expect(gate.allow('t', 20), isTrue);
      expect(gate.allow('t', 30), isFalse, reason: '★ 第 4 条必须被挡');
      // 不同源互不影响
      expect(gate.allow('u', 30), isTrue);
      // 窗口滑过之后恢复
      expect(gate.allow('t', 2000), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // REM-07：sound.play 时长夹紧 + sound.stop
  // ══════════════════════════════════════════════════════════════
  group('R94-SOUND 远程播放（REM-07）', () {
    test('SD-01 durationSec 夹紧 600 且越界显式失败', () async {
      var played = false;
      final r = await performRemotePlay(
        <String, dynamic>{'durationSec': 999999999},
        byId: (_) async => 'x',
        byTag: (_) async => 'x',
        any: () async => 'x',
        play: (_, __, ___, {bool loop = false}) async {
          played = true;
          return true;
        },
      );
      expect(r.durationMs, rcSoundMaxDurationSec * 1000,
          reason: '★ 越界值必须被夹紧到 600 秒');
      expect(r.durationOutOfRange, isTrue);
      expect(r.ok, isFalse, reason: '★ 越界必须显式失败，不静默降级');
      expect(played, isFalse, reason: '越界请求不得真的开播');

      // 反面样本：合法时长必须照常播放
      final ok = await performRemotePlay(
        <String, dynamic>{'durationSec': 5},
        byId: (_) async => 'x',
        byTag: (_) async => 'x',
        any: () async => 'x',
        play: (_, __, ___, {bool loop = false}) async => true,
      );
      expect(ok.ok, isTrue);
      expect(ok.durationMs, 5000);
      expect(ok.durationOutOfRange, isFalse);
    });

    test('SD-02 下界 1 秒同样夹紧，sound.stop 属"停类"', () {
      expect(clampRemotePlayDuration(0).seconds, rcSoundMinDurationSec);
      expect(clampRemotePlayDuration(0).outOfRange, isTrue);
      expect(clampRemotePlayDuration(null).seconds, 5);
      expect(clampRemotePlayDuration(600).outOfRange, isFalse);

      expect(isStopCommand(RcCmd.soundStop), isTrue,
          reason: '★ 叫停必须能插队（先于限流）');
      expect(isStopCommand(RcCmd.soundPlay), isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // REM-04：协助会话主题必须慢哈希
  // ══════════════════════════════════════════════════════════════
  group('R94-ASSIST 协助会话凭据（REM-04）', () {
    test('AS-01 topicFor 不等于快速 SHA256 截断', () async {
      const code = '123456789';
      final pw = RcAssist.generatePassword();
      expect(RcAssist.isValidPassword(pw), isTrue);
      expect(pw.length, 12, reason: '★ 密码熵 40bit → 60bit');

      final topic = await RcAssist.topicFor(code, pw);
      final fast = await Sha256().hash(utf8.encode('$code|$pw'));
      final fastHex =
          fast.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fastTopic = '${RcAssist.topicPrefix}${fastHex.substring(0, 16)}';

      expect(topic, isNot(fastTopic),
          reason: '★ 若相等，等于给公开的临时码配了一个离线口令校验器');
      expect(topic.length, RcAssist.topicPrefix.length + 16);

      // 反面：8 位旧密码必须被拒（否则"加长"只是 UI 文案）
      expect(RcAssist.isValidPassword('ABCD2345'), isFalse);
      expect(RcAssist.isValidPassword('ABCD23456789'), isTrue);
    });

    test('AS-02 陌生会合主题的形状判据（防"5 条噪声锁死会话"）', () {
      expect(RcAssist.isAssistTopic('sonicshield/v1/assist/0123456789abcdef'),
          isTrue);
      expect(RcAssist.isAssistTopic('sonicshield/v1/assist/zzzz'), isFalse);
      expect(RcAssist.isAssistTopic('sonicshield/v1/assist/0123456789ABCDEF'),
          isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // REM-15：去重表落盘
  // ══════════════════════════════════════════════════════════════
  group('R94-SEEN 去重表持久化（REM-15）', () {
    test('SE-01 重启后同 ID 仍被拒；出窗条目被裁掉', () async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final a = InboundSeenStore(prefs);
      expect(a.reserve('id-1', now), isTrue);
      expect(a.reserve('id-1', now + 1), isFalse, reason: '同进程内重复');
      // 一条 20 分钟前的记录：超窗，不应恢复
      a.reserve('id-old', now - 20 * 60 * 1000);
      await a.flush(nowMs: now);

      final b = InboundSeenStore(prefs)..load(nowMs: now + 1000);
      expect(b.contains('id-1'), isTrue, reason: '★ 进程重启后仍要记得');
      expect(b.reserve('id-1', now + 2000), isFalse,
          reason: '★ 重启后重放必须被挡（这就是本条的修复点）');
      expect(b.contains('id-old'), isFalse, reason: '出窗条目必须被裁掉');

      // 反面：从未见过的 ID 必须放行
      expect(b.reserve('id-new', now + 3000), isTrue);
    });

    test('SE-02 存储被写坏 ⇒ 按空表处理（不放行也不崩）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(InboundSeenStore.storageKey, '{not json');
      final s = InboundSeenStore(prefs)..load();
      expect(s.length, 0);
      expect(s.reserve('x', DateTime.now().millisecondsSinceEpoch), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // REM-10 / REM-13：凭据落盘加密 + 异常脱敏
  // ══════════════════════════════════════════════════════════════
  group('R94-CRED 凭据与异常（REM-10 / REM-13）', () {
    test('CR-01 有设备秘密时落盘为密文，且能原值读回', () async {
      CredentialSealer.deviceSecretLoader = () async =>
          base64Encode(List<int>.generate(32, (i) => i + 1));
      await CredentialSealer.ensure();
      expect(CredentialSealer.ready, isTrue);

      final sealed = CredentialSealer.seal('ABCD1234');
      expect(sealed.startsWith(CredentialSealer.prefix), isTrue);
      expect(sealed.contains('ABCD1234'), isFalse, reason: '★ 不得明文落盘');
      expect(CredentialSealer.open(sealed), 'ABCD1234');

      // 反面：换一把设备秘密 ⇒ 解不开（返回空串，而不是密文或错值）
      CredentialSealer.resetForTest();
      CredentialSealer.deviceSecretLoader = () async =>
          base64Encode(List<int>.generate(32, (i) => 100 + i));
      await CredentialSealer.ensure();
      expect(CredentialSealer.open(sealed), '');
      // 旧明文值仍然原样可用（升级不丢配置）
      expect(CredentialSealer.open('ABCD1234'), 'ABCD1234');
    });

    test('CR-02 无设备秘密 ⇒ 降级明文（不阻断可用性）', () async {
      CredentialSealer.deviceSecretLoader = () async => null;
      await CredentialSealer.ensure();
      expect(CredentialSealer.ready, isFalse);
      expect(CredentialSealer.seal('ABCD1234'), 'ABCD1234');
      expect(CredentialSealer.open('ABCD1234'), 'ABCD1234');
    });

    test('CR-03 describeFailure 脱敏（路径 / SQL / 十六进制）', () {
      final s = describeFailure(
          'FileSystemException: /data/user/0/com.x/app_flutter/evidence.m4a '
          'SELECT * FROM exec_logs WHERE id=1 handle=0xdeadbeef');
      expect(s.contains('/data/'), isFalse, reason: '★ 本机路径不得回传对端');
      expect(s.contains('SELECT'), isFalse);
      expect(s.contains('0xdeadbeef'), isFalse);
      expect(s.length, lessThanOrEqualTo(161));
    });
  });
}
