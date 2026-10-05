import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/source_text.dart';

PairedEndpoint _ep(String id) => PairedEndpoint(
    deviceId: id, name: '控制器 $id', secret: 'AB2CD5EF', pairedAt: DateTime.now());

void main() {
  group('R-6 resolveRcDelivery：投递集合的判定', () {
    final a = _ep('a' * 16);
    final b = _ep('b' * 16);

    test('RT-01 定向：只投给点名的那个（A 的请求不再落到 B）', () {
      final got = resolveRcDelivery([a, b], 'a' * 16);
      expect(got, isNotNull);
      expect(got!.length, 1, reason: '旧实现返回 2 条 = A 的任务列表同时发给 B');
      expect(got.single.deviceId, 'a' * 16);
    });

    test('RT-02 点名了但不在配对表 ⇒ null（必须留痕丢弃，绝不退化成广播）', () {
      expect(resolveRcDelivery([a, b], 'c' * 16), isNull,
          reason: '退化成广播就是本缺陷本身；返回 null 让调用方写审计');
    });

    test('RT-03 未定向（null）⇒ 广播给全部（心跳/通话状态/指令组进度靠它）', () {
      expect(resolveRcDelivery([a, b], null)!.length, 2);
    });

    test('RT-04 空串 ⇒ 广播（发送方未标识自己，如 tool/rc_probe.dart 探针）', () {
      expect(resolveRcDelivery([a, b], '')!.length, 2,
          reason: '探针不填 from；空串若被当成"点名了一个不存在的端点"，'
              '探针会整体失联（它已在配对表里）');
    });

    test('RT-05 无已配对端点 ⇒ 空表（由调用方按"无已配对端点"留痕）', () {
      expect(resolveRcDelivery(const [], 'a' * 16), isEmpty);
      expect(resolveRcDelivery(const [], null), isEmpty);
    });

    test('RT-06 单端点时定向与广播等价（不会因为定向而漏发）', () {
      expect(resolveRcDelivery([a], 'a' * 16)!.single.deviceId, 'a' * 16);
    });
  });

  group('R-6 端点侧接线锁（源码契约）', () {
    final src = File('lib/remote/endpoint_service.dart').readAsStringSync();

    test('RT-07 _send 接受 targetPeerId 且真的走 resolveRcDelivery', () {
      final send = methodBody(src, 'Future<void> _send(RcMessage msg, {');
      expect(send, contains('resolveRcDelivery(paired, targetPeerId)'),
          reason: '没有这一步 ⇒ 定向参数形同虚设，回执照样广播给所有人');
      expect(send, contains('目标控制端不在配对表'),
          reason: '点名找不到必须留痕（否则"回执没发出去"又是无痕的）');
    });

    test('RT-08 _ack 定向回发起方', () {
      // ⚠️ 签名必须带 `, {`：否则会命中**参数表**那个 `{`（methodBody 的已知陷阱）。
      final ack = methodBody(src, 'Future<void> _ack(RcMessage forMsg, bool ok, {');
      expect(ack, contains('targetPeerId: forMsg.from'),
          reason: '通用回执是**响应式**的：只该回给发命令的那台控制器');
    });

    test('RT-09 响应式回执全部定向（tasks/task/assets/presets/device/location/exec/ptt）',
        () {
      for (final sig in [
        'Future<void> _sendTaskList(',
        'Future<void> _sendTask(',
        'Future<void> _sendAssets(',
        'Future<void> _sendPresets(',
        'Future<void> _sendDeviceStatus(',
        'Future<void> _sendLocation(',
        'Future<void> _runTaskNow(',
        'Future<void> _playPtt(',
        'Future<void> _pttFailed(',
      ]) {
        final body = methodBody(src, sig);
        expect(body, contains('targetPeerId: msg.from'),
            reason: '$sig 是响应式回执，必须只回发起方');
      }
    });

    test('RT-10 内联回执（ping→pong / status.get / logs.recent）也定向', () {
      // A14：原来只数 `targetPeerId: msg.from` 的出现次数（`>= 3`）—— 计数下限
      // 可被**别处凑数**喂绿：只要 dispatch 里任何位置多一个定向调用就够了，
      // 真正漏掉 ping / status / logs 中的一条也照样通过。改为**逐分支**点名。
      final dispatch = methodBody(
          stripComments(src),
          'Future<void> _dispatch(RcMessage msg, PairedEndpoint peer)');

      /// 取 `case RcCmd.<cmd>:` 到下一个 `case` 之间的分支体（不写死缩进）。
      String branchOf(String cmd) {
        final start = dispatch.indexOf('case RcCmd.$cmd:');
        expect(start, greaterThan(0), reason: '找不到 $cmd 分支（改名了？）');
        final rest = dispatch.substring(start);
        final next = RegExp(r'\n[ \t]*case RcCmd\.').firstMatch(rest);
        return next == null ? rest : rest.substring(0, next.start);
      }

      const inline = <String, String>{
        'ping': 'pong',
        'statusGet': 'status',
        'logsRecent': 'logs',
      };
      inline.forEach((cmd, evt) {
        final b = branchOf(cmd);
        expect(b, contains('RcMessage.now(RcEvt.$evt'),
            reason: '$cmd 分支应回 RcEvt.$evt');
        expect(b, contains('targetPeerId: msg.from'),
            reason: '$cmd → RcEvt.$evt 是响应式回执，必须只回发起方；'
                '漏掉就意味着那类数据仍会泄露给同端点的另一台控制器');
      });
    });

    test('RT-11 ⚠️ 广播型事件**不得**被顺手定向（心跳定向=在线探测失效）', () {
      expect(src, contains('unawaited(_send(RcMessage.now(RcEvt.heartbeat)));'),
          reason: '心跳必须广播：它是"端点还活着"的信号，任何一台控制器都该收到');
      expect(
          src,
          contains('await _send(RcMessage.now(RcEvt.callMissed, '
              "{'callId': callId}));"),
          reason: '来电未接通知必须广播（主叫据此结束等待）');
      final runScript = methodBody(src, 'Future<void> _runScript(');
      expect(runScript, contains("'state': 'running'"),
          reason: '指令组进度保持广播（控制端 UI 靠它显示进度）');
      expect(runScript, contains('rcScriptStatePayload(script.scriptId'),
          reason: '终态同样广播，只多带一个 skipped 列表');
      expect(runScript, isNot(contains('targetPeerId')),
          reason: 'rc.script 进度/终态是**广播型**事件，不该被定向');
    });
  });
}
