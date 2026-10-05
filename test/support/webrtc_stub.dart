/// `flutter_webrtc` **平台通道假实现** —— 宿主测试专用（第 45 轮新增）。
///
/// ## 为什么需要它
///
/// 通话模块（`CallService` / `MultiCallService`）的绝大部分行都挂在
/// `RTCPeerConnection` 与 `getUserMedia` 后面，而宿主机既没有相机麦克风、
/// 也没有真实的对端 —— 于是这些行此前**一条都没被执行过**，
/// 只有 `test/call_flow_test.dart` 的 **35 条源码文本锁**在兜底。
/// 这正是 `docs/17 §74` 判据第五代的形状：
/// **"源码锁是绿的" ≠ "那条业务路径被执行过"**。
///
/// ## 它不是"伪造生产逻辑"
///
/// 本桩**只**复刻 `flutter_webrtc` 插件的**平台侧返回形状**（通道名、方法名、
/// 返回 map 的字段），不做任何业务判断。被驱动的是真实的
/// `call_service.dart` 代码：真实的 `_createPc` / `_teardown` /
/// `onCandidate` / `acceptIncoming`，桩只是把"手机那边"换成了一个可编程的替身。
///
/// 通道与形状全部**照插件 1.6.2+hotfix.3 的源码**抄写：
/// * `FlutterWebRTC.Method` —— 全局方法通道（`WebRTC.invokeMethod`）；
/// * `FlutterWebRTC/peerConnectionEvent<peerConnectionId>` —— 每个
///   `RTCPeerConnectionNative` 在构造时 `listen` 的事件通道
///   （`rtc_peerconnection_impl.dart` 的 `_eventChannelFor`）；
/// * `FlutterWebRTC.Event` —— 插件懒建的全局事件通道（不打桩时
///   `MissingPluginException` 会被 `FlutterError.reportError` 上报 ⇒ 判用例失败）。
///
/// ## 已知边界
/// * **不**模拟真实媒体协商：SDP 是常量字符串，ICE 不真的打洞。
/// * **不**模拟真实编解码/渲染：`RTCVideoView` 需要的纹理不在此列。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一帧可编程的"平台侧" reply。
typedef WebrtcReply = Object? Function(MethodCall call);

/// `flutter_webrtc` 通道族假实现。
///
/// 用法：
/// ```dart
/// final rtc = FakeWebrtc();
/// setUp(() { rtc.install(); });
/// tearDown(() { rtc.uninstall(); });
/// // 驱动真实代码
/// await CallService.instance.startCall(peer, store);
/// // 断言插件侧真的收到了什么
/// expect(rtc.methods, contains('createOffer'));
/// // 模拟对端/网络层事件
/// await rtc.pushEvent({'event': 'peerConnectionState', 'state': 'connected'});
/// ```
class FakeWebrtc {
  FakeWebrtc({this.peerConnectionId = 'pc-1', this.streamId = 'stream-1'});

  /// `createPeerConnection` 回的 id（决定事件通道名）。
  final String peerConnectionId;
  final String streamId;

  // ───────────────────────── 可编程开关 ─────────────────────────

  /// `getUserMedia` 抛 `PlatformException`（无相机/麦克风权限、设备被占用）。
  bool failUserMedia = false;

  /// `createOffer` 抛 `PlatformException`。
  bool failCreateOffer = false;

  /// `setRemoteDescription` 抛 `PlatformException`（SDP 不合法的常见形态）。
  bool failSetRemoteDescription = false;

  /// `addCandidate` 抛 `PlatformException`（单条候选失败，不得影响整路）。
  bool failAddCandidate = false;

  /// `enableSpeakerphone` 抛 `PlatformException`（平台不支持免提 → 静默忽略）。
  bool failSpeakerphone = false;

  /// `switchCamera` 抛 `PlatformException`（部分机型/后置摄像头不支持）。
  bool failSwitchCamera = false;

  /// `getLocalDescription` 回的 SDP。设为空串即复刻"空 SDP 假成功"分支。
  String localSdp = 'v=0\r\no=- 4611 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n';

  /// 是否在 `getUserMedia` 里带**音频轨**（`toggleMute` 的前置）。
  bool withAudioTrack = true;

  /// 是否在 `getUserMedia` 里带**视频轨**（`switchCamera` 的前置）。
  bool withVideoTrack = true;

  // ───────────────────────── 观测面 ─────────────────────────

  /// 按调用顺序记录的方法名（断言"插件真的被调用了"）。
  final List<String> methods = <String>[];

  /// 完整记录（需要看参数时用）。
  final List<MethodCall> calls = <MethodCall>[];

  /// 曾收到的 `addCandidate` 候选 SDP（断言缓存重放真的喂了进去）。
  final List<String> addedCandidates = <String>[];

  bool get installed => _installed;
  bool _installed = false;

  static const MethodChannel _method = MethodChannel('FlutterWebRTC.Method');
  static const MethodChannel _globalEvent = MethodChannel('FlutterWebRTC.Event');

  String get _eventChannelName =>
      'FlutterWebRTC/peerConnectionEvent$peerConnectionId';

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // ───────────────────────── 安装 / 卸载 ─────────────────────────

  /// 安装全部桩。可重复调用（幂等）。
  void install() {
    if (_installed) return;
    _installed = true;
    _messenger.setMockMethodCallHandler(_method, _handle);
    _messenger.setMockMethodCallHandler(
        MethodChannel(_eventChannelName), (call) async => null);
    _messenger.setMockMethodCallHandler(_globalEvent, (call) async => null);
  }

  /// 卸载。**不**清空观测面（有些用例在 `tearDown` 里才断言）。
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    _messenger.setMockMethodCallHandler(_method, null);
    _messenger.setMockMethodCallHandler(MethodChannel(_eventChannelName), null);
    _messenger.setMockMethodCallHandler(_globalEvent, null);
  }

  /// 清空观测面（跨用例隔离用）。
  void resetObservations() {
    methods.clear();
    calls.clear();
    addedCandidates.clear();
  }

  int countOf(String method) => methods.where((m) => m == method).length;

  bool called(String method) => methods.contains(method);

  Map<String, dynamic>? lastArgs(String method) {
    for (final c in calls.reversed) {
      if (c.method == method) return _asMap(c.arguments);
    }
    return null;
  }

  /// 取某次调用的嵌套 `constraints`（已规整为普通 map）。
  ///
  /// ⚠️ **不能用 `as Map<String, dynamic>` 直接转**：`StandardMessageCodec`
  /// 解出来的嵌套 map 运行时类型是 `_Map<Object?, Object?>`
  /// ⇒ 强转会抛 `type '_Map<Object?, Object?>' is not a subtype of type
  /// 'Map<String, dynamic>'`（第 45 轮实测）。这里显式重建一层。
  Map<String, Object?> constraintsOf(String method) {
    final raw = lastArgs(method)?['constraints'];
    if (raw is! Map) return <String, Object?>{};
    return raw.map<String, Object?>((k, v) => MapEntry(
          '$k',
          v is Map
              ? v.map<String, Object?>((k2, v2) => MapEntry('$k2', v2))
              : v,
        ));
  }

  // ───────────────────────── 事件注入 ─────────────────────────

  /// 往 `FlutterWebRTC/peerConnectionEvent<pcId>` 推一条平台事件。
  ///
  /// 事件名与载荷字段照 `RTCPeerConnectionNative.eventListener` 的 `switch`：
  /// `peerConnectionState` / `iceConnectionState` / `onCandidate` / `onTrack` …
  Future<void> pushEvent(Map<String, dynamic> event) async {
    await _messenger.handlePlatformMessage(
      _eventChannelName,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  /// 推一条"连接状态"事件（`connected` / `failed` / `closed` / …）。
  Future<void> pushConnectionState(String state) =>
      pushEvent(<String, dynamic>{
        'event': 'peerConnectionState',
        'state': state,
      });

  /// 推一条 **本端** ICE 候选（插件语义：`onIceCandidate` = 本机已收集到候选，
  /// 应用应把它经信令发给对端）。
  ///
  /// ⚠️ 名字容易误会：对端候选**不经**此通道进入 —— 它走 `pc.addCandidate`，
  /// 由应用侧的 `CallService.onCandidate` 主动喂进来。
  Future<void> pushIceCandidate(
    String candidate, {
    String? sdpMid,
    int? sdpMLineIndex,
  }) =>
      pushEvent(<String, dynamic>{
        'event': 'onCandidate',
        'candidate': <String, dynamic>{
          'candidate': candidate,
          'sdpMid': sdpMid ?? '0',
          'sdpMLineIndex': sdpMLineIndex ?? 0,
        },
      });

  /// 推一条 `onTrack`（远端流到达）。字段形状照 `fromMap` 的需要给全。
  Future<void> pushTrack(String remoteStreamId) => pushEvent(<String, dynamic>{
        'event': 'onTrack',
        'streams': <dynamic>[
          <String, dynamic>{
            'streamId': remoteStreamId,
            'ownerTag': peerConnectionId,
            'audioTracks': <dynamic>[
              _trackMap('remote-audio', 'audio'),
            ],
            'videoTracks': <dynamic>[
              _trackMap('remote-video', 'video'),
            ],
          },
        ],
        'receiver': <String, dynamic>{
          'receiverId': 'receiver-1',
          'track': _trackMap('remote-video', 'video'),
          'rtpParameters': _rtpParameters,
        },
        'track': _trackMap('remote-video', 'video'),
      });

  // ───────────────────────── 内部 ─────────────────────────

  static Map<String, dynamic> _asMap(Object? o) =>
      o is Map ? o.cast<String, dynamic>() : <String, dynamic>{};

  static Map<String, dynamic> _trackMap(
    String id,
    String kind, {
    bool enabled = true,
  }) =>
      <String, dynamic>{
        'id': id,
        'label': id,
        'kind': kind,
        'enabled': enabled,
        'settings': <String, dynamic>{},
      };

  /// `RTCRtpParameters.fromMap` 要求 `encodings` / `headerExtensions` /
  /// `codecs` / `rtcp` **四个键都非 null**（缺一个就 `NoSuchMethodError`）。
  ///
  /// ⚠️ 而 `rtcp` 里的 `cname` / `reducedSize` 是**非空参数**
  /// （`RTCRTCPParameters(this.cname, this.reducedSize)`）——
  /// 传 `{}` 或 `null` 会抛 `type 'Null' is not a subtype of type 'bool'`
  /// （第 45 轮实测，错误发生在 `pc.addTrack` 这条**没人 await** 的路径上，
  /// 症状是"整个用例莫名失败"）。
  static final Map<String, dynamic> _rtpParameters = <String, dynamic>{
    'transactionId': 'tx-1',
    'encodings': <dynamic>[],
    'headerExtensions': <dynamic>[],
    'codecs': <dynamic>[],
    'rtcp': <String, dynamic>{'cname': 'fake-cname', 'reducedSize': false},
    'degradationPreference': null,
  };

  Future<Object?> _handle(MethodCall call) async {
    methods.add(call.method);
    calls.add(call);
    final args = _asMap(call.arguments);
    switch (call.method) {
      case 'getUserMedia':
        if (failUserMedia) {
          throw PlatformException(code: 'userMediaFailed', message: '无可用设备');
        }
        return <String, dynamic>{
          'streamId': streamId,
          'audioTracks': <dynamic>[
            if (withAudioTrack) _trackMap('local-audio', 'audio'),
          ],
          'videoTracks': <dynamic>[
            if (withVideoTrack) _trackMap('local-video', 'video'),
          ],
        };
      case 'createPeerConnection':
        return <String, dynamic>{'peerConnectionId': peerConnectionId};
      case 'createOffer':
        if (failCreateOffer) {
          throw PlatformException(code: 'offerFailed', message: 'SDP 生成失败');
        }
        return <String, dynamic>{'sdp': localSdp, 'type': 'offer'};
      case 'createAnswer':
        return <String, dynamic>{'sdp': localSdp, 'type': 'answer'};
      case 'getLocalDescription':
        return <String, dynamic>{'sdp': localSdp, 'type': 'offer'};
      case 'setRemoteDescription':
        if (failSetRemoteDescription) {
          throw PlatformException(code: 'badSdp', message: 'SDP 不合法');
        }
        return null;
      case 'addCandidate':
        if (failAddCandidate) {
          throw PlatformException(code: 'badCandidate', message: '候选不可用');
        }
        addedCandidates.add('${_asMap(args['candidate'])['candidate']}');
        return null;
      case 'addTrack':
        // ⚠️ BUG-080（第七十三轮）：真实插件写死 `'streamIds': [stream?.id]`
        // （rtc_peerconnection_impl.dart:604）—— 省略 `stream` 参数时发过去的
        // 就是 `[null]`，Java 侧 `String[null]`、原生 `nativeAddTrack` 取 null
        // ⇒ NPE ⇒ `RTC_CHECK(false)` ⇒ SIGABRT（**整个进程崩溃**）。
        //
        // 本桩**必须复刻这条拒绝**：第 45 轮版本对 addTrack 恒回成功、
        // 完全不读 `streamIds`，于是"漏传本地流"在宿主上永远是绿的 ——
        // 这正是「发起通话即崩溃」能逃过多轮宿主测试的根因。桩一旦恒真，
        // 全绿只证明"实现符合我们自写的模型"，不证明真实契约为真。
        final ids = args['streamIds'];
        final streamOk = ids is List &&
            ids.isNotEmpty &&
            ids.every((e) => e is String && e.isNotEmpty);
        if (!streamOk) {
          throw PlatformException(
              code: 'addTrackFailed',
              message: 'streamIds 为空（漏传本地流 ⇒ 原生 NPE）');
        }
        // `RTCRtpSenderNative.fromMap` 要求 `track` / `rtpParameters` 齐全：
        // `track` 为空 map ⇒ sender 的 track 为 null（本桩不关心发送侧）。
        return <String, dynamic>{
          'senderId': 'sender-1',
          'track': <dynamic, dynamic>{},
          'rtpParameters': _rtpParameters,
          'ownsTrack': false,
        };
      case 'enableSpeakerphone':
        if (failSpeakerphone) {
          throw PlatformException(code: 'noSpeaker', message: '不支持免提');
        }
        return null;
      // ⚠️ 通道方法名不是 `switchCamera`：`Helper.switchCamera` 实际用
      // `mediaStreamTrackSwitchCamera`（第 45 轮实测 —— 桩里写错方法名时
      // 断言会静默变成"平台没被调用"，那是**假红**，会让人去查生产代码）。
      case 'mediaStreamTrackSwitchCamera':
        if (failSwitchCamera) {
          throw PlatformException(code: 'noCamera', message: '不支持切换');
        }
        return true;
      default:
        return null;
    }
  }
}
