/// 通话**媒体档位**：把"是否视频 + 并发几路"映射成一组**可断言**的
/// 采集/编码参数（docs/16 §10）。
///
/// ## 为什么需要它（"建立视频/语音通话后，双方机器爆卡"）
///
/// 旧实现有两个结构性缺口：
///
/// 1. **编码器没有上限**。`getUserMedia` 只写死 `width:640,height:480`、
///    **完全不设帧率**，而且从不调用 `RTCRtpSender.setParameters`。
///    WebRTC 的默认行为是"带宽有多少就用多少"：BWE 会把码率一路抬上去，
///    低端机上编码线程吃满 CPU ⇒ 整机卡顿、发热、掉帧。
/// 2. **降级偏好缺省是 `balanced`**。CPU 吃紧时它**同时**掉分辨率和帧率 ——
///    用户看到的是"又糊又卡"。通话要的是"宁可糊一点，也要跟手"，
///    行业共识是 `maintain-framerate`（MDN `RTCRtpSender.setParameters`）。
///
/// 另外，多路同连时 **每一路各自跑一个编码器**（本模块是 P2P + MQTT 信令，
/// 没有 SFU，编码器无法复用）：路数越多，CPU 越爆。因此必须在路数上升时
/// **主动降分辨率/降码率**（行业做法：resolution ladder / 分层降级；
/// 见 docs/16 §10 的调研出处）。
///
/// ## 本文件的分工
///
/// 上半部分是**纯逻辑**（无副作用、可在宿主机逐条断言）—— 档位表、约束生成、
/// 降级偏好映射；下半部分是把档位**下发到 `RTCRtpSender`** 的胶水。
/// 调用点只有两处：`call_service.dart`（单路）与 `multi_call_service.dart`
/// （多路），两处共用同一张表，**避免参数漂移**。
///
/// ⚠️ 下发失败一律**吞掉**（不阻塞通话）：这里失败的是"画质/负载调优"，
/// 不是用户要求的那件事；编解码会退回 WebRTC 默认自适应，通话仍能建立。
/// 这与 `call_service._setSpeakerphone` 的取舍同款 —— 不是"静默失败"。
library;

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 降级偏好。与 `RTCDegradationPreference` 同名同义，但**不直接依赖插件枚举**，
/// 好让档位表保持纯逻辑（映射见 [degradationToPlugin]）。
enum CallDegradation {
  /// 保帧率、舍分辨率：通话首选（跟手比清晰更重要）。
  maintainFramerate,

  /// 保分辨率、舍帧率。
  maintainResolution,

  /// 两者兼顾（WebRTC 缺省，不推荐用于实时通话）。
  balanced,
}

/// 采集上限（`getUserMedia` 的约束）。
class CallCaptureProfile {
  const CallCaptureProfile({
    required this.width,
    required this.height,
    required this.frameRate,
  });

  final int width;
  final int height;
  final int frameRate;
}

/// 视频通话的采集档位：640x480 @ 24fps。
///
/// 为什么是 24fps 而不是 30：手机前摄 30fps 的采集+编码在低端机上已接近
/// 满负荷；24fps 肉眼几乎无感，却能把编码负载降掉约两成。这是"先砍帧率、
/// 再砍分辨率"这条行业梯度的第一级。
const CallCaptureProfile callVideoCapture =
    CallCaptureProfile(width: 640, height: 480, frameRate: 24);

/// 视频采集约束（`getUserMedia` 的 `video` 字段）。
///
/// ⚠️ 用 `ideal`（而非精确值）：精确值在"摄像头不支持该分辨率"的机型上会让
/// **整通电话直接起不来**；`ideal` 让平台挑最接近的一档（行业推荐写法）。
/// `max` 是硬上限，必须显式给 —— 否则部分机型会以 30/60fps 采集。
Map<String, Object?> videoConstraintsFor(CallCaptureProfile p) =>
    <String, Object?>{
      'facingMode': 'user',
      'width': <String, Object?>{'ideal': p.width},
      'height': <String, Object?>{'ideal': p.height},
      'frameRate': <String, Object?>{
        'ideal': p.frameRate,
        'max': p.frameRate,
      },
    };

/// 单路的发送（编码）档位。
class CallSendProfile {
  const CallSendProfile({
    required this.maxBitrateBps,
    required this.maxFramerate,
    required this.scaleResolutionDownBy,
    required this.degradation,
  });

  /// 编码码率上限（bps）。这是防"爆卡"的关键：没有它，BWE 会把码率抬到
  /// 编码器跑不动为止。
  final int maxBitrateBps;

  /// 编码帧率上限（fps）。
  final int maxFramerate;

  /// 在采集分辨率基础上再缩放多少倍（1.0 = 不缩放）。
  final double scaleResolutionDownBy;

  final CallDegradation degradation;
}

/// 按**并发视频路数**取档位（行业做法：分辨率/码率阶梯）。
///
/// | 路数 | 码率上限 | 帧率上限 | 缩放 | 说明 |
/// |---|---|---|---|---|
/// | 1 | 600 kbps | 24 | 1.0 | 单路：480p 够用，留足清晰度 |
/// | 2 | 400 kbps | 20 | 1.0 | 两台设备：各降码率，帧率略降 |
/// | 3 | 260 kbps | 15 | 1.5 | 480x320：编码像素数降约 55% |
/// | ≥4 | 150 kbps | 12 | 2.0 | 320x240：保底"看得见"，优先不卡 |
///
/// 参数区间取自行业推荐表（480p/24fps ≈ 600kbps；360p/15fps ≈ 250kbps；
/// 240p/12fps ≈ 150kbps），四舍五入到整档。
CallSendProfile sendProfileFor(int concurrentVideoSessions) {
  final n = concurrentVideoSessions < 1 ? 1 : concurrentVideoSessions;
  if (n <= 1) {
    return const CallSendProfile(
      maxBitrateBps: 600000,
      maxFramerate: 24,
      scaleResolutionDownBy: 1.0,
      degradation: CallDegradation.maintainFramerate,
    );
  }
  if (n == 2) {
    return const CallSendProfile(
      maxBitrateBps: 400000,
      maxFramerate: 20,
      scaleResolutionDownBy: 1.0,
      degradation: CallDegradation.maintainFramerate,
    );
  }
  if (n == 3) {
    return const CallSendProfile(
      maxBitrateBps: 260000,
      maxFramerate: 15,
      scaleResolutionDownBy: 1.5,
      degradation: CallDegradation.maintainFramerate,
    );
  }
  return const CallSendProfile(
    maxBitrateBps: 150000,
    maxFramerate: 12,
    scaleResolutionDownBy: 2.0,
    degradation: CallDegradation.maintainFramerate,
  );
}

/// 纯逻辑 → 插件枚举的映射（穷尽 switch：将来给 [CallDegradation] 加值会编译报错）。
RTCDegradationPreference degradationToPlugin(CallDegradation d) => switch (d) {
      CallDegradation.maintainFramerate =>
        RTCDegradationPreference.MAINTAIN_FRAMERATE,
      CallDegradation.maintainResolution =>
        RTCDegradationPreference.MAINTAIN_RESOLUTION,
      CallDegradation.balanced => RTCDegradationPreference.BALANCED,
    };

// ───────────────────────── 下发（胶水） ─────────────────────────

/// 把档位下发到一组 sender（非视频 sender 自动跳过）。
Future<void> applySendProfileToSenders(
    List<RTCRtpSender> senders, CallSendProfile profile) async {
  for (final s in senders) {
    await applySendProfileToSender(s, profile);
  }
}

/// 把档位下发到单个 sender。
///
/// ⚠️ 只改"不需要重新协商"的键（`maxBitrate` / `maxFramerate` /
/// `scaleResolutionDownBy` / `degradationPreference`）—— 这些是
/// `setParameters` 的正当用途（MDN）。改编码器/编解码才需要重协商。
///
/// ⚠️ 必须基于 `sender.parameters`（插件从 `addTrack` 返回的原生参数）**改**，
/// 而不是凭空调一个新的 `RTCRtpParameters`：Android 侧
/// `PeerConnectionObserver.updateRtpParameters` 是**按索引/rid 合并**进原生
/// 参数集的（不认识的字段会被忽略，`encodings` 为空则原地不动），
/// 因此传部分字段是安全的。
Future<void> applySendProfileToSender(
    RTCRtpSender sender, CallSendProfile profile) async {
  // 只调视频轨：音频轨没有码率/分辨率档位可调（Opus 由 WebRTC 自适应）。
  final track = sender.track;
  if (track == null || track.kind != 'video') return;
  try {
    final p = sender.parameters;
    p.degradationPreference = degradationToPlugin(profile.degradation);
    final encodings = (p.encodings == null || p.encodings!.isEmpty)
        ? <RTCRtpEncoding>[RTCRtpEncoding()]
        : p.encodings!;
    for (final e in encodings) {
      e.maxBitrate = profile.maxBitrateBps;
      e.maxFramerate = profile.maxFramerate;
      e.scaleResolutionDownBy = profile.scaleResolutionDownBy;
    }
    p.encodings = encodings;
    await sender.setParameters(p);
  } on Object {
    // 不挡通话：退回 WebRTC 默认自适应（文件头已说明这是刻意的非致命降级）。
  }
}
