import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

void main() {
  final src = File('lib/remote/endpoint_service.dart').readAsStringSync();
  final dispatch =
      methodBody(src, 'Future<void> _dispatch(RcMessage msg, PairedEndpoint peer)');

  group('P1-A 回执正确性', () {
    test('PH-01 scriptStop 不匹配时回 ok=false（不再一律回成功）', () {
      expect(dispatch, contains("_ack(msg, false, data: '无匹配脚本')"),
          reason: '旧形状：不匹配也回 ack(true) → 控制器以为已终止，端点还在跑');
      expect(dispatch, contains("action: 'script.stop'"));
      expect(dispatch, contains("status: 'skipped'"));
    });

    test('PH-02 task.toggle / task.skipNext 缺 taskId 时显式失败', () {
      final inDispatch = "data: '缺少 taskId'".allMatches(dispatch).length;
      final wholeFile = "data: '缺少 taskId'".allMatches(src).length;
      expect(inDispatch, greaterThanOrEqualTo(2),
          reason: '旧形状里 toggle/skipNext 是 `if (id != null)` 没有 else → '
              '静默不回执，控制器只能等到超时');
      expect(wholeFile, greaterThanOrEqualTo(4),
          reason: 'task.delete / task.runNow / task.toggle / task.skipNext '
              '四条路径都必须显式回"缺少 taskId"（前两条在各自 helper 里）');
    });

    test('PH-03 status.get 的 engine 取自真实运行状态', () {
      expect(dispatch, contains("'engine': BackgroundServiceManager.instance.isRunning"),
          reason: '旧形状：硬编码 true —— 引擎没跑时控制端也显示"运行中"');
      expect(dispatch, isNot(contains("'engine': true")),
          reason: '硬编码 true 正是被修的缺陷形状');
    });

    test('PH-04 sound.play 失败时把原因放进回执', () {
      final body = methodBody(src, 'Future<void> _playRemote(');
      expect(body, contains('r.ok ? null : r.reason'),
          reason: '旧形状 `r.path == null ? r.reason : null`：播放器自身失败'
              '（path 非空但 ok=false）时原因被丢掉，对端只看到 ok=false');
    });

    test('PH-05 未知命令回 ack(false) + 审计（不再静默忽略）', () {
      expect(dispatch, contains('default:'));
      expect(dispatch, contains("data: '未知命令'"));
      expect(dispatch, contains("status: 'skipped'"));
    });
  });

  group('P1-B 失败必须留痕', () {
    test('PH-06 ptt.voice 三条失败路径全部回执 + 审计', () {
      final ptt = methodBody(src, 'Future<void> _playPtt(');
      final fail = methodBody(src, 'Future<void> _pttFailed(');

      expect(ptt, contains('_pttFailed('), reason: '缺 audioB64 / 播放器拒绝 / 异常都要走统一失败出口');
      expect(ptt, isNot(contains('if (audioB64 == null) return;')),
          reason: '旧形状：直接 return，对端永远收不到 rc.ptt 回执');
      expect(ptt, isNot(contains('// ignore')),
          reason: '旧形状：on Object 吞异常，什么都不留');
      expect(fail, contains("status: 'failed'"));
      expect(fail, contains("'ok': false"));
      expect(fail, contains('reason'));
    });

    test('PH-07 record 步骤失败写 failed 审计', () {
      // ⚠️ 签名带上 `({`：`_recordEvidence` 的具名参数已改为多行，
      // 必须跳过参数表那个 `{` 才能取到**方法体**（见 methodBody 的注记）。
      final body = methodBody(src, 'Future<void> _recordEvidence({');
      expect(body, contains("status: 'failed'"));
      expect(body, contains('麦克风权限未授予'),
          reason: '旧形状：`if (!await rec.hasPermission()) return;` 静默返回');
      expect(body, isNot(contains('// ignore')),
          reason: '旧形状：on Object 吞掉，录音没录成却零痕迹');
    });

    test('PH-08 location.get 失败写审计', () {
      final body = methodBody(src, 'Future<void> _sendLocation(');
      expect(body, contains("action: 'location'"));
      expect(body, contains("status: 'failed'"));
    });

    test('PH-09 _send 丢弃出站消息时写审计（回执丢失无痕的根因）', () {
      // ⚠️ 签名带上 `, {`：R-6 给 `_send` 加了可选 `targetPeerId`，
      // 必须跳过具名参数表的 `{` 才能取到方法体。
      final send = methodBody(src, 'Future<void> _send(RcMessage msg, {');
      final n = '_auditSendDrop('.allMatches(send).length;
      expect(n, greaterThanOrEqualTo(3),
          reason: '未启动 / MQTT 未连接 / 无已配对端点 三条静默 return 都要留痕');
      expect(send, isNot(contains('if (store == null || client == null) return;')));
      expect(send, isNot(contains('if (peers.isEmpty) return;')));

      final audit = methodBody(src, 'Future<void> _auditSendDrop(');
      expect(audit, contains('RcEvt.heartbeat'),
          reason: '心跳是 60s 一次的纯存活信号，记它会淹没真正的回执丢失');
    });
  });
}
