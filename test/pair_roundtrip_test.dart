import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/pair_qr_screen.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/source_text.dart';

const _ctrlId = '0123456789abcdef';
const _ctrlCode = 'AB2CD5EF';
const _ctrlName = '客厅手机';
const _epId = 'fedcba9876543210';
const _epCode = 'WXYZ2345';

/// 控制端要发出去的 `pair.request`（与 `notifyPeerOfPairing` 同形）。
///
/// `from` 由 `sendTo` 统一补上（= 本机 deviceId），这里照做，以便断言
/// "信封 from 与 payload 一致"这一审计口径。
RcMessage _pairRequest() => RcMessage(
      id: 'req-1',
      ts: DateTime.now().millisecondsSinceEpoch,
      type: RcCmd.pairRequest,
      payload: {
        'deviceId': _ctrlId,
        'name': _ctrlName,
        'code': _ctrlCode,
      },
      from: _ctrlId,
    );

String _cmdTopic(String endpointId) => 'sonicshield/v1/$endpointId/cmd';

String _evtTopic(String endpointId) => 'sonicshield/v1/$endpointId/evt';

void main() {
  // SharedPreferences 的 mock 需要绑定（PR-12 会真的读写 store）。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('R-2 配对请求的加密往返', () {
    test('PR-01 控制端加密 → 端点用「本机码」解开，payload 带齐身份三件套', () async {
      final req = _pairRequest();
      final topic = _cmdTopic(_epId);
      final wire = await RcCodec.encode(
          req, await RcCodec.deriveKey(_epCode, '$_epId|cmd'), topic);

      // 端点侧：用自己的配对码 + 自己的 deviceId 解密（密钥按接收方身份派生）。
      final got = await RcCodec.decode(
          wire, await RcCodec.deriveKey(_epCode, '$_epId|cmd'), topic);

      expect(got, isNotNull, reason: '端点必须能解开控制端的配对请求');
      expect(got!.type, RcCmd.pairRequest);
      expect(got.payload['deviceId'], _ctrlId);
      expect(got.payload['name'], _ctrlName);
      expect(got.payload['code'], _ctrlCode,
          reason: '⚠️ 必须携带控制端配对码 —— 端点回执的密钥就是它派生的；'
              '不携带则回执永远发不出去（本缺陷的根因）');
      expect(got.from, _ctrlId, reason: '信封 from 供审计比对，但不参与鉴权');
    });

    test('PR-02 变异证伪：码不对 ⇒ 端点**解不开**（"能解密即持有本机码"的依据）',
        () async {
      final req = _pairRequest();
      final topic = _cmdTopic(_epId);
      final wire = await RcCodec.encode(
          req, await RcCodec.deriveKey(_epCode, '$_epId|cmd'), topic);

      // 端点用的是**别人的**码（模拟录错配对码）→ 必须解不开。
      final wrong = await RcCodec.decode(
          wire, await RcCodec.deriveKey('ZZZZ2345', '$_epId|cmd'), topic);
      expect(wrong, isNull,
          reason: '若这里能解开，说明"能解密即证明持有本机配对码"不成立，'
              'pair.request 的准入条件就是空的');

      // 主题绑进 AAD：换主题也解不开（防跨主题重放）。
      final otherTopic = await RcCodec.decode(
          wire, await RcCodec.deriveKey(_epCode, '$_epId|cmd'), _evtTopic(_epId));
      expect(otherTopic, isNull, reason: 'AAD 绑定主题，换主题必须失败');
    });

    test('PR-03 回执可送达：端点用 payload 里的码派生 evt 密钥，控制端解得开', () async {
      final req = _pairRequest();
      final topic = _evtTopic(_epId);
      // 端点侧按配对表（= 控制端的 deviceId + 控制端的码）派生回执密钥。
      final ack = RcMessage(
        id: 'ack-1',
        ts: DateTime.now().millisecondsSinceEpoch,
        type: RcEvt.ack,
        payload: {
          'ok': true,
          'for': req.id,
          'forType': RcCmd.pairRequest,
          'data': '已配对',
        },
        from: _epId,
      );
      final wire = await RcCodec.encode(
          ack, await RcCodec.deriveKey(_ctrlCode, '$_ctrlId|evt'), topic);

      // 控制端侧：用自己的码 + 自己的 deviceId 解密（与 _handlePeerEvent 同法）。
      final got = await RcCodec.decode(
          wire, await RcCodec.deriveKey(_ctrlCode, '$_ctrlId|evt'), topic);
      expect(got, isNotNull, reason: '控制端必须能解开端点回执 —— 否则配对白做');
      expect(got!.type, RcEvt.ack);
      expect(got.payload['ok'], isTrue);
      expect(got.payload['for'], req.id,
          reason: '回执必须能按 for 对上是哪一条请求（控制端 8 秒等待靠它匹配）');
    });

    test('PR-04 变异证伪：端点若用**自己的**码当回执密钥 ⇒ 控制端解不开', () async {
      final topic = _evtTopic(_epId);
      final ack = RcMessage.now(RcEvt.ack, {'ok': true, 'for': 'x'});
      // 这是"payload 不带 code 时只能瞎猜密钥"的那种实现。
      final wire = await RcCodec.encode(
          ack, await RcCodec.deriveKey(_epCode, '$_ctrlId|evt'), topic);

      final got = await RcCodec.decode(
          wire, await RcCodec.deriveKey(_ctrlCode, '$_ctrlId|evt'), topic);
      expect(got, isNull,
          reason: '这条断言锁死"回执密钥必须来自控制端的码"：'
              '任何用错密钥的实现都会在这里红，而不是在真机上静默无回音');
    });
  });

  group('R-2 提权面：协助会话必须拒绝 pair.request', () {
    const allOn = AssistPerms(
      media: true,
      tts: true,
      vibrate: true,
      volume: true,
      location: true,
      video: true,
      script: true,
    );

    test('PR-05 未登记权限位 ⇒ denyAll；**全放行**也拒绝', () {
      expect(RcPermGate.requiredPerm(RcCmd.pairRequest), RcPermGate.denyAll,
          reason: '协助对端**未配对**，允许它等于借"临时协助"把自己变成'
              '已配对设备（提权面）。它必须落到 `_ => denyAll`。');
      expect(RcPermGate.allows(allOn, RcCmd.pairRequest), isFalse,
          reason: '即使端点把权限位全开，pair.request 也必须被拒 —— '
              '一旦有人给它配上真实权限位，这条会红');
      expect(RcPermGate.allows(AssistPerms.none, RcCmd.pairRequest), isFalse);
    });
  });

  group('R-2 端点侧接线锁（源码契约）', () {
    final src = File('lib/remote/endpoint_service.dart').readAsStringSync();
    final body = methodBody(src, 'Future<void> _handlePairRequest(');

    test('PR-06 _dispatch 有 pair.request 分支', () {
      expect(src, contains('case RcCmd.pairRequest'),
          reason: '没有分支 ⇒ 落到 default 被当"未知命令"拒绝，配对永远双向不了');
    });

    test('PR-07 ⚠️ 顺序：addPaired 必须在回执**之前**', () {
      final add = body.indexOf('addPaired(');
      final ack = body.indexOf('RcEvt.ack');
      expect(add, greaterThanOrEqualTo(0));
      expect(ack, greaterThanOrEqualTo(0));
      expect(add, lessThan(ack),
          reason: '回执密钥取自配对表（_send 遍历 store.paired()）；'
              '先回执后落表 ⇒ 表里还没有这台控制端 ⇒ 回执被 `peers.isEmpty` 丢弃，'
              '正是本缺陷本身。顺序不可交换。');
    });

    test('PR-08 ⚠️ 已配对控制端的 secret 不得被覆盖（同 deviceId 码不符必须拒绝）', () {
      final guardStart = body.indexOf('existing.secret != code');
      expect(guardStart, greaterThanOrEqualTo(0),
          reason: '缺少"码不符即拒绝"的判据：addPaired 是同 deviceId **原位覆盖**，'
              '任一已配对控制器都能顶掉另一台的密钥，从而劫持发给它的全部回执');
      final guardEnd = body.indexOf('return;', guardStart);
      expect(guardEnd, greaterThan(guardStart));
      final guard = body.substring(guardStart, guardEnd);
      expect(guard, contains('_ack(msg, false'), reason: '拒绝必须显式回执，不能静默');
      expect(guard, isNot(contains('addPaired')),
          reason: '拒绝分支里**不得**出现 addPaired —— 出现即等于覆盖');
    });

    test('PR-09 成功回执定向发给 ctrlId（身份以 payload 为准，不信 msg.from）', () {
      expect(body, contains('targetPeerId: ctrlId'),
          reason: 'msg.from 不可信（信封由发送方自报）；'
              '成功路径应按刚登记的身份定向回执');
    });

    test('PR-10 控制端 UI 真的构造这条命令（覆盖门禁的"发送方"判据）', () {
      final ui = File('lib/features/remote/pair_qr_screen.dart').readAsStringSync();
      final settings =
          File('lib/features/remote/remote_screen.dart').readAsStringSync();
      expect(ui, contains('RcCmd.pairRequest'));
      expect(ui, contains('notifyPeerOfPairing'));
      expect(settings, contains('notifyPeerOfPairing'),
          reason: '手输配对也必须通知对端，否则只有"扫码"这一半是双向的');
    });

    test('PR-11 ⚠️ payload 三件套齐备（少 code = 回执永远发不出去）', () {
      final ui = File('lib/features/remote/pair_qr_screen.dart').readAsStringSync();
      // 控制端 UI 依赖 SharedPreferences/MQTT，宿主无法走完整条链；而这条链的
      // **唯一**失败模式恰恰是"payload 少带一项"—— 它不报错、只是静默无回音。
      expect(ui, contains("'deviceId': store.deviceId"),
          reason: '对端要用本机 deviceId 反查并派生回执密钥');
      expect(ui, contains("'name': store.deviceName"),
          reason: '对端列表要显示可辨认的名字（否则只看到一串 ID）');
      expect(ui, contains("'code': await store.ensurePairingCode()"),
          reason: '⚠️ 不携带码 ⇒ 对端没有可用回执密钥 ⇒ 回执永远发不出去'
              '（本缺陷的根因，也是 R-2 要求"payload 必须携带配对码"的原因）');
    });

    test('PR-12 控制端在"发不出去"时给出**明确**结论（不得静默）', () async {
      SharedPreferences.setMockInitialValues({});
      final store = RemoteStore(await SharedPreferences.getInstance());
      final endpoint = PairedEndpoint(
          deviceId: _epId, name: '端点', secret: _epCode, pairedAt: DateTime.now());

      // 宿主无 MQTT 客户端 ⇒ sendTo 必然失败。此时**不能**假装配对成功。
      final r = await notifyPeerOfPairing(endpoint, store);

      expect(r.confirmed, isFalse);
      expect(r.message, contains('未能通知对端'),
          reason: '发不出去必须说出来，且要说清下一步（否则用户只会反复重试）');
      expect(store.deviceId.length, 16,
          reason: '本机没有身份时要先补齐 —— 对端要靠它给回执加密');
    });
  });
}
