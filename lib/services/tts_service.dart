import 'dart:async';

import '../domain/models/tts_voice.dart';

/// 系统 TTS 播报委托：`text/volume/关键词` → 完成（失败抛出真实原因）。
///
/// 刻意做成**注入的闭包**而不是在本文件直接 `FlutterTts()`：平台插件在宿主
/// 测试里跑不了，而"选哪条路、失败了报什么"是**纯决策逻辑** —— 把它留在这里
/// 就能用替身把每条分支都锁住（对照 `remote_playback.dart` 的注入风格）。
typedef SystemTtsSpeak = Future<void> Function(
    String text, double volume, List<String> match);

/// 在线语音播报委托：合成 + 播放，返回**是否真的发声**。
///
/// 返回 `bool` 而不是"抛错/不抛错"：在线路径的失败形态很多（未配置 Key、
/// HTTP 非 2xx、返回体为空、播放器失败），调用方只关心"到底响了没有"，
/// 由委托内部把细节写进日志。
typedef OnlineTtsSpeak = Future<bool> Function(
    String text, double volume, String onlineVoiceName);

/// 内置神经 TTS 播报委托：本地合成 + 播放，返回**是否真的发声**。
///
/// 与 [SystemTtsSpeak] / [OnlineTtsSpeak] 同构：平台胶水（模型加载、合成、
/// 写 WAV、播放器）全部封在 `neural_tts.dart` 的 [NeuralTtsEngine] 里，这里
/// 只持有签名。失败时返回 `false`，由 [say] 负责优雅回落系统默认音色。
typedef NeuralTtsSpeak = Future<bool> Function(String text, double volume);

/// 一次 TTS 播报的结果（含"走的是在线还是离线"，供审计与回执）。
class TtsResult {
  const TtsResult({required this.ok, required this.online, this.message});

  final bool ok;
  final bool online;
  final String? message;
}

/// 统一 TTS 入口（v2.0）：按音色决定走系统 TTS 还是在线语音。
///
/// ## 契约
/// - 空文本 → **失败**（不静默成功，避免审计里出现"播报了空字符串"）。
/// - 在线音色但委托没发声 → **失败**（不假成功，控制端不会以为"已经喊了"）。
/// - 系统/在线委托抛错 → 包成失败结果，**异常不外泄**（调用点无需 try）。
class TtsService {
  const TtsService({
    required this.speakSystem,
    required this.speakOnline,
    required this.speakNeural,
  });

  final SystemTtsSpeak speakSystem;
  final OnlineTtsSpeak speakOnline;
  final NeuralTtsSpeak speakNeural;

  /// 按 [voiceId] 解析音色并播报 [text]。
  ///
  /// [volume] 夹到 `0..1`：越界值一律按边界处理，而不是抛错 —— 远程来的
  /// 音量值不可信，但也不该因为它就整个播报失败。
  Future<TtsResult> say(
    String text, {
    String voiceId = '',
    double volume = 0.8,
  }) async {
    final t = text.trim();
    final voice = TtsVoices.byId(voiceId);
    if (t.isEmpty) {
      return TtsResult(
          ok: false, online: voice.isOnline, message: '播报文本为空');
    }
    final v = volume.clamp(0.0, 1.0).toDouble();

    // 内置神经 TTS（离线、自然）：失败则优雅回落系统默认音色，不让喊话静默失败。
    if (voice.provider == TtsProvider.neural) {
      try {
        final ok = await speakNeural(t, v);
        if (ok) return const TtsResult(ok: true, online: false);
        // 神经引擎不可用（模型缺失/合成失败）→ 回落系统默认音色（不挑具体音色）。
        await speakSystem(t, v, const <String>[]);
        return const TtsResult(
          ok: true,
          online: false,
          message: '神经引擎不可用，已回落系统默认音色',
        );
      } on Object catch (e) {
        return TtsResult(ok: false, online: false, message: e.toString());
      }
    }

    if (voice.isOnline) {
      try {
        final ok = await speakOnline(t, v, voice.onlineVoiceName);
        return TtsResult(
          ok: ok,
          online: true,
          message: ok ? null : '在线语音未发声（未配置或服务失败）',
        );
      } on Object catch (e) {
        return TtsResult(ok: false, online: true, message: e.toString());
      }
    }
    try {
      await speakSystem(t, v, voice.systemMatch);
      return const TtsResult(ok: true, online: false);
    } on Object catch (e) {
      return TtsResult(ok: false, online: false, message: e.toString());
    }
  }
}