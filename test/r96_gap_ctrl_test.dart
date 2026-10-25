/// 覆盖率补强（第 96 轮）：13 条「可达却未被执行」的行。
///
/// | 目标 | 行 | 用例 |
/// |---|---|---|
/// | `notification_service.dart` | 52 | GAP-01 |
/// | `controller_service.dart` | 68-69 | GAP-02 |
/// | `controller_service.dart` | 89、91-92 | GAP-03 |
/// | `call_service.dart` | 568-569 | GAP-04 |
/// | `call_service.dart` | 582 | GAP-05 |
/// | `call_service.dart` | 890 | GAP-06 |
/// | `controller_service.dart` | 176、286 | GAP-07 |
///
/// ## 几条硬约束（照抄本仓既有测试的教训）
///
/// - **平台通道桩必须在 tearDown 还原**：`TestDefaultBinaryMessenger` 的
///   handler 是进程级全局状态，泄漏到下一个用例只会得到"看起来像产品缺陷"
///   的假红。
/// - **WebRTC / 录音一律走 `test/support` 里的平台层替身**：不建真连接、
///   不碰真相机麦克风。被驱动的仍是真实的 `call_service.dart` /
///   `controller_service.dart`。
/// - **GAP-07 必须真等 60 秒**：`RcControllerService` 的 60 秒上限读的是
///   `Stopwatch`（真实单调时钟），`FakeAsync` / `tester.pump` 推的是**假**
///   时钟，对 `Stopwatch` 无效 —— 只有真实流逝能推进那两条判定。
///   （与 `call_service_webrtc_test.dart` 的 CS-40 真等 45s 同一取舍。）
/// - **GAP-01 必须排在最前**：`FlutterLocalNotificationsPlugin` 在**构造时**
///   按 `defaultTargetPlatform` 选定平台实现；iOS 分支只有在构造之前把
///   平台覆盖成 iOS 才可能被解析出来。
@Timeout(Duration(seconds: 300))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/controller_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/notification_service.dart';

import 'support/record_stub.dart';
import 'support/webrtc_stub.dart';

/// 真实异步推进若干轮（服务层不用 fake-async，`await` 的插件调用要真事件循环）。
Future<void> _settle([int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rtc = FakeWebrtc();
  final sent = <RcMessage>[];
  late RemoteStore store;
  late PairedEndpoint endpoint;
  late FakeRecordPlatform rec;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = RemoteStore(await SharedPreferences.getInstance());
    await store.setIdentity('ctrl-gap', '控制端GAP');
    endpoint = PairedEndpoint(
      deviceId: 'dev-gap',
      name: '端点GAP',
      secret: 'SECRETGAP01',
      pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    // 录音走**平台层**替身（不是通道桩）：`RcControllerService._rec` 是
    // 单例字段，通道桩在跨用例时会因 `create()` 往返不再推进而永久挂起
    // （见 `test/support/record_stub.dart` 文件头）。平台层替身把 `create()`
    // 变成纯 microtask，不受用例边界影响。
    rec = installFakeRecordPlatform(hasPermissionResult: true);
    addTearDown(restoreRecordPlatform);
    rtc.resetObservations();
    rtc.install();
    addTearDown(rtc.uninstall);
    sent.clear();
    RcEndpointService.instance.debugSendTo =
        (e, m, s, enqueueOnFail) async {
      sent.add(m);
      return true;
    };
    addTearDown(() => RcEndpointService.instance.debugSendTo = null);
    CallService.bindStore(() async => store);
  });

  tearDown(() async {
    // 收尾：否则振铃/等应答计时器会跨用例残留（45s 真实 Timer）。
    await CallService.instance.onRemoteEnd();
    await _settle(4);
  });

  // ══════════════════════════════════════════════════════════════════
  // GAP-01 · 通知：iOS 侧三项权限申请（notification_service.dart:52）
  // ══════════════════════════════════════════════════════════════════
  group('GAP-A 通知权限', () {
    const notifyChannel =
        MethodChannel('dexterous.com/flutter/local_notifications');
    final log = <MethodCall>[];

    setUp(() {
      log.clear();
      // ⚠️ 必须在 `NotificationService.instance` 首次被访问**之前**覆盖：
      // 插件在构造时按 `defaultTargetPlatform` 绑定平台实现。
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notifyChannel, (call) async {
        log.add(call);
        // `initialize` 要 bool：回 null 会让插件把它当失败。
        return call.method == 'initialize' ? true : null;
      });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notifyChannel, null);
    });

    test('GAP-01 iOS 侧 requestPermission 必须真的申请 alert/badge/sound 三项', () async {
      await NotificationService.instance.requestPermission();

      expect(log.map((c) => c.method), contains('initialize'),
          reason: '申请权限前必须先初始化插件');
      final reqs =
          log.where((c) => c.method == 'requestPermissions').toList();
      expect(reqs, hasLength(1),
          reason: 'iOS 实现必须真的发起一次权限申请 —— '
              '只调 Android 那条会让 iOS 用户的告警通知永远静默');
      expect(reqs.single.arguments, <String, bool>{
        'sound': true,
        'alert': true,
        'badge': true,
        'provisional': false,
        'critical': false,
      }, reason: '三项权限缺一不可：少 sound ⇒ 守卫告警没声，少 alert ⇒ 不弹横幅');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // GAP-02/03 · 控制器即时命令（controller_service.dart:68-69、89-92）
  // ══════════════════════════════════════════════════════════════════
  group('GAP-B 控制器即时命令', () {
    test('GAP-02 sendSoundStop 下发 rc.soundStop（空载荷）并回报投递结果', () async {
      final ok =
          await RcControllerService.instance.sendSoundStop(endpoint, store);

      expect(ok, isTrue, reason: '替身回执"已投递" ⇒ 必须如实返回 true');
      expect(sent, hasLength(1));
      expect(sent.single.type, RcCmd.soundStop);
      expect(sent.single.payload, isEmpty,
          reason: '叫停是"停全部"，带参数说明实现漂移（端点只认空载荷）');
    });

    test('GAP-03 sendRunMasterSet 下发 rc.runMasterSet{mode}', () async {
      final ok = await RcControllerService.instance
          .sendRunMasterSet(endpoint, store, 'off');

      expect(ok, isTrue);
      expect(sent.single.type, RcCmd.runMasterSet);
      expect(sent.single.payload, <String, dynamic>{'mode': 'off'},
          reason: '总开关三档 auto/on/off 原样上线协议，不得在控制端改写成 bool');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // GAP-04/05/06 · 通话（call_service.dart:568-569、582、890）
  // ══════════════════════════════════════════════════════════════════
  group('GAP-C 通话：不可信 invite / 重复投递 / 屏幕共享', () {
    test('GAP-04 invite 缺 callId ⇒ 回 call.end{invalid} 而不是静默丢弃', () async {
      final svc = CallService.instance;

      // ① 字段缺失；② 类型不对（旧版本/恶意端可能发数字）。
      expect(
        await svc.onIncomingCall(<String, dynamic>{'sdp': 'v=0'}, endpoint, store),
        isFalse,
      );
      expect(
        await svc.onIncomingCall(
            <String, dynamic>{'callId': 42, 'sdp': 'v=0'}, endpoint, store),
        isFalse,
      );

      expect(sent, hasLength(2),
          reason: '两条都必须回一条 end —— 静默丢弃会让主叫白等 45 秒');
      for (final m in sent) {
        expect(m.type, RcCmd.callEnd);
        expect(m.payload['callId'], isNull,
            reason: '没有可信 callId 时只能回 null，不得编造一个');
        expect(m.payload['reason'], 'invalid',
            reason: '必须让主叫看出"这通邀请是坏的"，而不是笼统的 busy/hangup');
      }
      expect(svc.currentPhase, CallPhase.idle,
          reason: '坏 invite 不得把本机推进 ringing/connecting');
    });

    test('GAP-05 同一 callId 的重复 invite 在振铃期幂等受理，绝不回 busy', () async {
      final svc = CallService.instance;
      final invite = <String, dynamic>{
        'callId': 'gap-dup-1',
        'sdp': rtc.localSdp,
        'type': 'offer',
      };

      expect(await svc.onIncomingCall(invite, endpoint, store), isTrue);
      expect(svc.currentPhase, CallPhase.ringing);
      final firstRound = sent.length;

      // 网络抖动 / 控制端 outbox 补发 ⇒ 同一条 invite 再来一次。
      expect(await svc.onIncomingCall(invite, endpoint, store), isTrue,
          reason: '重复投递是"同一通电话"，必须当作幂等成功');

      expect(sent.length, firstRound,
          reason: '★ BUG-140：重复 invite 若回 busy，对端会把这通正在振铃的电话'
              '直接挂掉 —— 这里必须一条信令都不发');
      expect(svc.callId, 'gap-dup-1');
      expect(svc.currentPhase, CallPhase.ringing);
    });

    test('GAP-06 屏幕共享走 getDisplayMedia；采集不可用 ⇒ 如实报 media 失败并收场', () async {
      final svc = CallService.instance;
      final invite = <String, dynamic>{
        'callId': 'gap-screen-1',
        'sdp': rtc.localSdp,
        'type': 'offer',
        'kind': 'screen',
      };
      expect(await svc.onIncomingCall(invite, endpoint, store), isTrue,
          reason: '前置：先进入振铃，接听路径才可达');
      sent.clear();

      // 宿主没有屏幕采集能力（替身对 getDisplayMedia 回"无应答"）。
      final accepted = await svc.acceptIncoming(invite, endpoint, store);
      await _settle();

      expect(rtc.called('getDisplayMedia'), isTrue,
          reason: '★ kind=screen 必须走屏幕采集，而不是复用摄像头/麦克风');
      expect(rtc.called('getUserMedia'), isFalse,
          reason: '投屏默认只传屏幕：顺手开麦开摄像头属于越权采集');
      expect(accepted, isFalse, reason: '采不到画面就不能假装接通');
      final end = sent.where((m) => m.type == RcCmd.callEnd).toList();
      expect(end, hasLength(1));
      expect(end.single.payload['reason'], 'media',
          reason: '必须把失败原因定位到"媒体"（可操作），而不是让主叫干等');
      expect(svc.currentPhase, CallPhase.idle,
          reason: '失败后必须收场回 idle，否则下一通电话会被判成"占线"');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // GAP-07 · 对讲 60 秒上限（controller_service.dart:176、286）
  // ══════════════════════════════════════════════════════════════════
  group('GAP-D 对讲 60 秒上限', () {
    test('GAP-07 秒表越过 60 秒 ⇒ v1 拒发并删文件、v2 分片到点自动收尾', () async {
      final dir = Directory.systemTemp.createTempSync('r96_gap_ptt');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/gap.m4a')
        ..writeAsBytesSync(List<int>.filled(16, 1));
      final ctrl = StreamController<Uint8List>();
      addTearDown(ctrl.close);

      rec.stopPath = file.path;
      rec.streamResult = ctrl.stream;

      final svc = RcControllerService.instance;
      expect(await svc.pttStartStream(endpoint, store), isTrue);

      // ⚠️ 真实等待：上限判定读的是 `Stopwatch`（单调真实时钟），
      // 假时钟推不动它 —— 这一条是本文件唯一的墙钟依赖，理由见文件头。
      await Future<void>.delayed(const Duration(seconds: 61));

      // ---- v2：流式模式的分片到点自动收尾（:286） ----
      //
      // ⚠️ 必须排在 v1 **之前**：`AudioRecorder.stop()` 会 `_stopRecordStream()`
      // 关掉插件内部的广播流（`record_stream.dart:28`），此后 `ctrl.add()`
      // 再也到不了业务层 —— 顺序颠倒只会得到"到点没触发"的假红。
      ctrl.add(Uint8List.fromList(<int>[0xFF, 0xF1, 0, 0, 0, 0, 0, 0]));
      await _settle();

      expect(svc.pttStreaming, isFalse,
          reason: '★ 到点必须自己收尾：不然用户不松手时麦克风会被一直占着');
      expect(sent, hasLength(1), reason: '收尾要补一帧终止帧，端点才知道会话结束');
      expect(sent.single.type, RcCmd.pttVoice);
      expect(sent.single.payload['last'], isTrue);
      expect(sent.single.payload['seq'], 0);

      // ---- v1：整段模式撞上限 ⇒ 拒发 + 删临时文件（:176） ----
      // 秒表在 v2 收尾时被 stop，但**累计值仍在**（`Stopwatch.stop` 不清零），
      // 于是 `pttStopAndSend` 读到的仍是 61s ⇒ 命中上限分支。
      final r = await svc.pttStopAndSend(endpoint, store);
      expect(r.ok, isFalse);
      expect(r.message, '超过 60 秒上限',
          reason: '超长必须明确拒绝，不能把 60 秒的语音硬塞进 broker');
      expect(file.existsSync(), isFalse,
          reason: '拒发后临时录音必须立刻删掉，否则每次超长都留一份无人回收的残留');
      expect(sent, hasLength(1), reason: '被拒的语音一个字都不该发出去');
    });
  });
}
