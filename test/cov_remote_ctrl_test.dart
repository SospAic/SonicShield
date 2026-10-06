import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/remote/controller_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/multi_call_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/record_stub.dart';

/// 覆盖率补强：`controller_service.dart` / `multi_call_service.dart` 的
/// **宿主机可达行为**（不动既有源码锁测试的任何断言）。
///
/// ## 思路
///
/// - **控制器命令**：`RcEndpointService.sendTo` 在宿主机上必然走
///   "未连接 → 密文入 outbox → 返回 false"分支（`_client == null`）。
///   于是每条命令都能被**端到端断言**：outbox 里那条密文用
///   `RcCodec.deriveKey(secret, '{deviceId}|cmd')` 解开，
///   逐字段核对 type / payload / from —— 不是"调用了就算过"。
/// - **对讲机（PTT）**：平台侧照抄 `test/support/record_stub.dart` 打桩
///   （通道名/方法名来自插件真实实现）；临时文件是**真实 dart:io**，
///   宿主机可真写真删真校验。
/// - **多路会话**：`MultiCallService` 是单例、事件路由与收尾是宿主可达的；
///   `connect` 在宿主机必然因拿不到本地媒体返回 false —— 这本身就是
///   生产里"权限被拒"分支的真实形状。
///
/// ⚠️ 不写源码锁（TL/LG/OB/UR/MCS 系列已覆盖），全部为行为断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RemoteStore store;
  late PairedEndpoint endpoint;

  setUp(() async {
    // 默认桩（拒权限）：保证 RcControllerService.instance 首次构造时
    // AudioRecorder 的 'create' 调用不会 MissingPluginException。
    stubRecord();
    addTearDown(clearRecordStub);

    SharedPreferences.setMockInitialValues({});
    store = RemoteStore(await SharedPreferences.getInstance());
    await store.setIdentity('ctrl-1', '控制端A');
    endpoint = PairedEndpoint(
      deviceId: 'dev-1',
      name: '端点一',
      secret: 'secret-dev-1',
      pairedAt: DateTime.now(),
    );
  });

  /// 取 outbox 里唯一一条暂存密文并解开（宿主机 sendTo 必走离线暂存分支）。
  Future<RcMessage> decodeFirstOutbox() async {
    final box = store.outboxFor('dev-1');
    expect(box, hasLength(1), reason: '离线时命令必须被密文暂存进 outbox');
    final key = await RcCodec.deriveKey('secret-dev-1', 'dev-1|cmd');
    final msg = await RcCodec.decode(
      box.first['wire'] as String,
      key,
      'sonicshield/v1/dev-1/cmd',
    );
    expect(msg, isNotNull, reason: '暂存的必须是 RcCodec.encode 的密文（否则补发必死）');
    return msg!;
  }

  group('控制器命令：离线 → 密文暂存，字段端到端可核对', () {
    test('RC-01 sendScriptStop：实时信令离线**不入队**（P1-15），构造字段仍可核对', () async {
      final svc = RcControllerService.instance;

      // ① 真源判据：stop 属 live —— 端点上线时早已没有要停的对象，补发有害。
      expect(rcOutboxFreshness(RcCmd.scriptStop), RcOutboxFreshness.live);

      // ② 真实路径（不注入替身）：离线 ⇒ 明确失败，且**不**暂存。
      //    P1-15 前这里会存进 outbox 等"上线后自动执行" —— 一个错误的承诺：
      //    既占满队列挤掉可补发的命令，又让 UI"待发 N 条"虚高。
      final ok = await svc.sendScriptStop(endpoint, store, scriptId: 's-1');
      expect(ok, isFalse, reason: '宿主机无 MQTT 客户端，必然走离线分支');
      expect(store.outboxFor('dev-1'), isEmpty,
          reason: '★ live 信令禁止离线补发：不得占用队列、不得让"待发"虚高');

      // ③ 构造侧字段核对：用宿主替身捕获 sendTo 收到的信封（不依赖入队）。
      RcMessage? captured;
      RcEndpointService.instance.debugSendTo =
          (e, m, s, enqueueOnFail) async { captured = m; return false; };
      addTearDown(() => RcEndpointService.instance.debugSendTo = null);
      await svc.sendScriptStop(endpoint, store, scriptId: 's-2');
      expect(captured!.type, RcCmd.scriptStop);
      expect(captured!.payload['scriptId'], 's-2');
    });

    test('RC-02 sendScript：payload 就是 script.toJson() 原样', () async {
      final svc = RcControllerService.instance;
      const script = RcScript(
        scriptId: 'sc-1',
        name: '夜间守护',
        fromName: '控制端A',
        sentAt: 1727136000000,
        steps: [RcStep(RcStepKind.delay, {'ms': 500})],
      );
      final ok = await svc.sendScript(endpoint, script, store);
      expect(ok, isFalse);

      final msg = await decodeFirstOutbox();
      expect(msg.type, RcCmd.scriptRun);
      expect(msg.payload, script.toJson());
    });

    test('RC-03 sendSoundPlay 带预置分类：四个字段都进密文', () async {
      final svc = RcControllerService.instance;
      await svc.sendSoundPlay(endpoint, store,
          presetCategory: 'alarm', volume: 0.5, durationSec: 3, loop: true);

      final msg = await decodeFirstOutbox();
      expect(msg.type, RcCmd.soundPlay);
      expect(msg.payload['category'], 'alarm');
      expect(msg.payload['volume'], 0.5);
      expect(msg.payload['durationSec'], 3);
      expect(msg.payload['loop'], true);
    });

    test('RC-04 sendSoundPlay 默认参数：volume 0.9 / 5s / 不循环 / 无 category', () async {
      final svc = RcControllerService.instance;
      await svc.sendSoundPlay(endpoint, store);

      final msg = await decodeFirstOutbox();
      expect(msg.type, RcCmd.soundPlay);
      expect(msg.payload.containsKey('category'), isFalse,
          reason: '未指定分类时不得塞 null 进密文');
      expect(msg.payload['volume'], 0.9);
      expect(msg.payload['durationSec'], 5);
      expect(msg.payload['loop'], false);
    });

    test('RC-05 sendStatusGet：空 payload 的状态查询', () async {
      final svc = RcControllerService.instance;
      await svc.sendStatusGet(endpoint, store);

      final msg = await decodeFirstOutbox();
      expect(msg.type, RcCmd.statusGet);
      expect(msg.payload, isEmpty);
    });

    test('RC-06 sendTaskToggle：taskId 与 enabled 原样', () async {
      final svc = RcControllerService.instance;
      await svc.sendTaskToggle(endpoint, store, 't-9', true);

      final msg = await decodeFirstOutbox();
      expect(msg.type, RcCmd.taskToggle);
      expect(msg.payload['taskId'], 't-9');
      expect(msg.payload['enabled'], true);
    });

    test('RC-07 sendGuardSet(false)：enabled=false 原样', () async {
      final svc = RcControllerService.instance;
      await svc.sendGuardSet(endpoint, store, false);

      final msg = await decodeFirstOutbox();
      expect(msg.type, RcCmd.guardSet);
      expect(msg.payload['enabled'], false);
    });
  });

  group('反击计划命令（v2.0）：信封字段端到端可核对', () {
    test('RC-20 sendPlanApply 带 planId 与 replace=false → 三字段原样进密文',
        () async {
      final svc = RcControllerService.instance;
      RcMessage? captured;
      RcEndpointService.instance.debugSendTo =
          (e, m, s, enqueueOnFail) async {
        captured = m;
        return true;
      };
      addTearDown(() => RcEndpointService.instance.debugSendTo = null);

      final plan = CounterPlan.defaults();
      final ok = await svc.sendPlanApply(endpoint, store, plan,
          planId: 'p-1', replace: false);

      expect(ok, isTrue);
      expect(captured!.type, RcCmd.planApply);
      expect(captured!.payload['plan'], plan.toJson());
      expect(captured!.payload['planId'], 'p-1');
      expect(captured!.payload['replace'], false,
          reason: 'replace 必须原样透传，否则端点会误删仍要保留的旧任务');
    });

    test('RC-21 sendPlanApply 不带 planId（默认 replace=true）→ 不塞空 planId',
        () async {
      final svc = RcControllerService.instance;
      RcMessage? captured;
      RcEndpointService.instance.debugSendTo =
          (e, m, s, enqueueOnFail) async {
        captured = m;
        return true;
      };
      addTearDown(() => RcEndpointService.instance.debugSendTo = null);

      final plan = CounterPlan.defaults();
      await svc.sendPlanApply(endpoint, store, plan);

      expect(captured!.type, RcCmd.planApply);
      expect(captured!.payload.containsKey('planId'), isFalse,
          reason: '未指定 planId 时不得塞 null/空串（空 id 会污染端点命名空间）');
      expect(captured!.payload['replace'], true);
    });

    test('RC-22 sendPlanGet / sendPlanStop → 两条空 payload 的计划命令', () async {
      final svc = RcControllerService.instance;
      final sent = <RcMessage>[];
      RcEndpointService.instance.debugSendTo =
          (e, m, s, enqueueOnFail) async {
        sent.add(m);
        return true;
      };
      addTearDown(() => RcEndpointService.instance.debugSendTo = null);

      await svc.sendPlanGet(endpoint, store);
      await svc.sendPlanStop(endpoint, store);

      expect(sent.map((m) => m.type).toList(), [RcCmd.planGet, RcCmd.planStop]);
      expect(sent.every((m) => m.payload.isEmpty), isTrue,
          reason: '查询 / 下线都不需要额外参数，塞参数说明实现漂移');
    });
  });

  group('对讲机 PTT：平台打桩 + 真实临时文件', () {
    test('RC-10 未录到音频就松开 → 明确失败，不发也不暂存', () async {
      // 单例此时从未 pttStart：stop 返回 null 且 _pttPath 为 null。
      final r = await RcControllerService.instance
          .pttStopAndSend(endpoint, store);
      expect(r.ok, isFalse);
      expect(r.message, '未录到音频');
      expect(store.outboxFor('dev-1'), isEmpty,
          reason: '没录到东西不得产生任何暂存命令');
    });

    test('RC-11 无权限 → pttStart 明确 false，且不会进入录制状态', () async {
      final calls = stubRecord(hasPermission: false);
      final svc = RcControllerService.instance;

      expect(await svc.pttStart(), isFalse);
      expect(calls, contains('hasPermission'), reason: '必须真的问过平台权限');
      expect(svc.pttRecording, isFalse);
    });

    test('RC-12 pttStart 成功后幂等：第二次不再问权限、不再 start', () async {
      final calls = stubRecord(hasPermission: true);
      final svc = RcControllerService.instance;

      expect(await svc.pttStart(), isTrue);
      expect(svc.pttRecording, isTrue, reason: '秒表启动 = 录制中');
      expect(await svc.pttStart(), isTrue, reason: '按住中再次触发不得重开一路');
      expect(calls.where((c) => c == 'hasPermission'), hasLength(1));
      expect(calls.where((c) => c == 'start'), hasLength(1));
    });

    test('RC-13 实时语音离线**不入队**（P1-15）：文件已清理，构造字段仍可核对',
        () async {
      final bytes = List<int>.generate(1024, (i) => i % 256);
      String mkPath() =>
          '${Directory.systemTemp.path}/ptt_cov_small_${DateTime.now().microsecondsSinceEpoch}.bin';
      final svc = RcControllerService.instance;

      // ① 真源判据：PTT 语音属 live —— 端点上线时这段话早已过时，补发有害。
      expect(rcOutboxFreshness(RcCmd.pttVoice), RcOutboxFreshness.live);

      // ② 真实路径（不注入替身）：离线 ⇒ 明确失败、删临时文件、**不**暂存。
      final path1 = mkPath();
      File(path1).writeAsBytesSync(bytes);
      stubRecord(hasPermission: true, stopPath: path1);
      expect(await svc.pttStart(), isTrue);

      final r = await svc.pttStopAndSend(endpoint, store);
      expect(r.ok, isFalse, reason: '宿主机离线，发送必失败');
      expect(r.message, '发送失败（端点离线）');
      expect(File(path1).existsSync(), isFalse, reason: '读出字节后必须删临时文件');
      expect(store.outboxFor('dev-1'), isEmpty,
          reason: '★ PTT 是实时语音：端点上线时早已过时，禁止离线补发/占队列');

      // ③ 构造侧字段核对：用宿主替身捕获 sendTo 收到的信封（不依赖入队）。
      RcMessage? captured;
      RcEndpointService.instance.debugSendTo =
          (e, m, s, enqueueOnFail) async { captured = m; return false; };
      addTearDown(() => RcEndpointService.instance.debugSendTo = null);
      final path2 = mkPath();
      File(path2).writeAsBytesSync(bytes);
      stubRecord(hasPermission: true, stopPath: path2);
      expect(await svc.pttStart(), isTrue);
      await svc.pttStopAndSend(endpoint, store);

      expect(captured!.type, RcCmd.pttVoice);
      expect(captured!.payload['audioB64'], base64Encode(bytes),
          reason: '音频字节必须原样（base64）进密文');
      expect(captured!.payload['durationMs'], isA<int>());
      expect((captured!.payload['voiceId'] as String).isNotEmpty, isTrue);
      expect(captured!.payload['fromName'], '控制端A');
    });

    test('RC-14 超过 200KB 上限 → 拒发并清理，不留暂存', () async {
      final bytes = List<int>.filled(200001, 7);
      final path =
          '${Directory.systemTemp.path}/ptt_cov_big_${DateTime.now().microsecondsSinceEpoch}.bin';
      File(path).writeAsBytesSync(bytes);

      stubRecord(hasPermission: true, stopPath: path);
      final svc = RcControllerService.instance;

      final r = await svc.pttStopAndSend(endpoint, store);
      expect(r.ok, isFalse);
      expect(r.message, '音频过大（压缩率异常）');
      expect(File(path).existsSync(), isFalse);
      expect(store.outboxFor('dev-1'), isEmpty);
    });

    test('RC-15 松开前取消：平台 stop 被调用，临时文件被删除', () async {
      final path =
          '${Directory.systemTemp.path}/ptt_cov_cancel_${DateTime.now().microsecondsSinceEpoch}.bin';
      File(path).writeAsBytesSync([1, 2, 3]);

      final calls = stubRecord(hasPermission: true, stopPath: path);
      final svc = RcControllerService.instance;
      expect(await svc.pttStart(), isTrue);

      await svc.pttCancel();
      expect(calls, contains('stop'));
      expect(File(path).existsSync(), isFalse, reason: '取消也必须清理临时文件');
      expect(svc.pttRecording, isFalse);
    });

    test('RC-16 ★ 录音参数按语音预算选（否则 60s 对讲必被"音频过大"拒发）', () {
      // 真源判据：v1 曾直接吃 `record` 插件默认值（128 kbps / 44.1 kHz /
      // 立体声）⇒ 60 s ≈ 960 KB，远超 pttMaxBytes=200 KB ⇒ 超过约 12 s 的
      // 对讲全部被"音频过大（压缩率异常）"拒发，"≤60s" 的上限形同虚设。
      // 语音改用宽带单声道（行业惯例 16 kHz / 单声道）后整段体积≈1/5。
      // ⚠️ 这里必须 `final` 而非 `const`：cfg 本身是 const，但下面的 bitRate
      //    是**实例字段**，常量表达式里访问实例字段会被编译器拒绝
      //    （const_eval_property_access）——所以整段算式只能在运行期做。
      // ignore: prefer_const_declarations
      final cfg = RcControllerService.pttRecordConfig;
      expect(cfg.sampleRate, 16000, reason: '语音宽带 16 kHz 足够，44.1 kHz 是无谓体积');
      expect(cfg.numChannels, 1, reason: '对讲是单声道，立体声白占一倍体积');
      expect(cfg.autoGain, isTrue, reason: '小声说话也要听得清（AGC）');
      // ★ 硬预算：整段最大体积必须落在上限内（编码器还会有一点浮动余量）。
      final worstBytes =
          cfg.bitRate * RcControllerService.pttMaxSeconds ~/ 8;
      expect(worstBytes, lessThan(RcControllerService.pttMaxBytes),
          reason: '${RcControllerService.pttMaxSeconds}s × ${cfg.bitRate}bps '
              '= $worstBytes B 必须 < ${RcControllerService.pttMaxBytes} B');
    });
  });

  group('多路会话：宿主可达的路由 / 收尾 / 失败分支', () {
    test('MC-20 一路会话初值：connecting / 未应答 / 无计时器', () {
      final s = MultiCallSession(callId: 'c-1', peer: endpoint);
      expect(s.callId, 'c-1');
      expect(s.peer.deviceId, 'dev-1');
      expect(s.phase, MultiCallPhase.connecting);
      expect(s.answered, isFalse);
      expect(s.pc, isNull);
      expect(s.remoteStream, isNull);
      expect(s.failure, isNull);
      expect(s.waitTimer, isNull);
    });

    test('MC-21 宿主机 connect 必然失败（拿不到本地媒体），不留半开会话',
        () async {
      final svc = MultiCallService.instance;
      final ok = await svc.connect(endpoint, store);
      expect(ok, isFalse, reason: '宿主机无相机/麦克风，_ensureLocalStream 必败');
      expect(svc.sessions, isEmpty, reason: '失败不得留下僵尸会话');
      expect(svc.isConnected('dev-1'), isFalse);
      expect(svc.activeId, isNull);
      expect(svc.activeSession, isNull);
      expect(svc.sessionOf('dev-1'), isNull);
    });

    test('MC-22 非自有 callId 的事件全部被丢弃，且不产生任何更新', () async {
      final svc = MultiCallService.instance;
      final events = StreamController<Map<String, dynamic>>();
      addTearDown(events.close);
      svc.attach(events.stream);

      final updates = <void>[];
      final sub = svc.updates.listen(updates.add);
      addTearDown(sub.cancel);

      events.add({
        'type': RcCmd.callAnswer,
        'payload': {'callId': 'not-mine', 'sdp': 'v=0'},
      });
      events.add({
        'type': RcCmd.callCandidate,
        'payload': {'callId': 'not-mine', 'candidate': 'bad-shape'},
      });
      events.add({
        'type': RcCmd.callEnd,
        'payload': {'callId': 'not-mine'},
      });
      events.add({'type': 'garbage'});
      await pumpEventQueue();

      expect(updates, isEmpty, reason: '别人的信令一条都不许碰、不许响');
      expect(svc.sessions, isEmpty);
    });

    test('MC-23 对未知设备挂断/切焦点是无害空操作', () async {
      final svc = MultiCallService.instance;
      await svc.hangUp('nobody');
      await svc.hangUpAll();
      svc.setActive('nobody');
      expect(svc.sessions, isEmpty);
      expect(svc.activeId, isNull);
    });

    test('MC-24 dispose 后事件不再被消费，会话清空', () async {
      final svc = MultiCallService.instance;
      final events = StreamController<Map<String, dynamic>>();
      svc.attach(events.stream);
      await svc.dispose();
      await events.close();

      expect(svc.sessions, isEmpty, reason: 'dispose 必须清掉全部会话');
      expect(svc.activeId, isNull);
    });
  });
}
