import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../domain/models/action.dart';

/// 播放结果（审计）。
class PlayResult {
  const PlayResult({required this.ok, this.playedMs = 0, this.message});

  final bool ok;
  final int playedMs;
  final String? message;
}

/// 播放服务：封装 just_audio + audio_session。
///
/// 关键行为：
/// - 按 channel 申请对应类型音频焦点（media / alarm），媒体通道尊重勿扰；
/// - 播放前设置目标音量（随机落点由调度引擎物化期决定）；
/// - [maxDurationMs] 到点淡出停止，实现“随机时长”；
/// - 播放结束释放解码器与唤醒（just_audio 内部持有 wakelock 到停止）。
class PlaybackService {
  PlaybackService();

  AudioPlayer? _player;

  Future<PlayResult> play({
    required String path,
    required AudioChannel channel,
    required double volume,
    required int maxDurationMs,
    int fadeInMs = 0,
    int fadeOutMs = 0,
  }) async {
    final player = _player ??= AudioPlayer();
    final sw = Stopwatch()..start();
    try {
      // 1) 申请音频会话/焦点：alarm 通道在 Android 上映射 USAGE_ALARM，
      //    可穿透勿扰与媒体静音（合规约束见 docs/08）。
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: channel == AudioChannel.alarm
              ? AndroidAudioUsage.alarm
              : AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ));

      // 2) 载入并播放。
      await player.setFilePath(path);
      await player.setVolume(volume);
      if (fadeInMs > 0) {
        unawaited(_fadeIn(player, volume, fadeInMs));
      }
      await player.play();

      // 3) 随机时长控制：到点停止（若文件更短则自然结束）。
      final fileMs = (player.duration ?? Duration.zero).inMilliseconds;
      final target = maxDurationMs <= 0
          ? fileMs
          : (fileMs <= 0 || fileMs > maxDurationMs ? maxDurationMs : fileMs);
      if (target > 0) {
        await Future<void>.delayed(Duration(milliseconds: target));
      }
      if (fadeOutMs > 0) {
        await _fadeOut(player, fadeOutMs);
      }
      await player.stop();
      return PlayResult(ok: true, playedMs: sw.elapsedMilliseconds);
    } catch (e) {
      return PlayResult(
          ok: false, playedMs: sw.elapsedMilliseconds, message: e.toString());
    }
  }

  Future<void> stop() async {
    try {
      await _player?.stop();
    } on Object {
      // 忽略停止异常：状态自愈。
    }
  }

  Future<void> _fadeIn(AudioPlayer p, double target, int ms) async {
    const steps = 20;
    for (var i = 1; i <= steps; i++) {
      await p.setVolume(target * i / steps);
      await Future<void>.delayed(Duration(milliseconds: ms ~/ steps));
    }
  }

  Future<void> _fadeOut(AudioPlayer p, int ms) async {
    const steps = 20;
    for (var i = steps; i >= 0; i--) {
      await p.setVolume(i / steps);
      await Future<void>.delayed(Duration(milliseconds: ms ~/ steps));
    }
  }

  Future<void> dispose() async {
    await _player?.dispose();
    _player = null;
  }
}
