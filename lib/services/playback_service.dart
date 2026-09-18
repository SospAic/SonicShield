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

  /// 按输出通道选择**音频焦点类型**（纯函数，便于测试锁定）。
  ///
  /// 依据 Android 官方音频焦点指引与行业惯例：
  /// - `alarm`：抢占式 `gain` —— 闹钟/唤醒必须被听见，允许暂停他人播放；
  /// - `media`：`gainTransientMayDuck` —— 短提示音只让别人的音乐**闪避**
  ///   （压低音量）而非**暂停**。若对 media 也用 `gain`，使用者正在听的音乐会被
  ///   打断再恢复，是明显的体验损伤，也容易被误读为"应用在抢音频"。
  ///
  /// 抽成静态函数是为了让这条决策可被单测锁定 —— 它藏在 `AudioSession.configure`
  /// 的参数里，一旦被改回 `gain` 不会有任何编译或运行期报错，只会"听起来很烦"。
  static AndroidAudioFocusGainType focusGainFor(AudioChannel channel) =>
      channel == AudioChannel.alarm
          ? AndroidAudioFocusGainType.gain
          : AndroidAudioFocusGainType.gainTransientMayDuck;

  AudioPlayer? _player;
  bool _mixStopped = false;

  Future<PlayResult> play({
    required String path,
    required AudioChannel channel,
    required double volume,
    required int maxDurationMs,
    int fadeInMs = 0,
    int fadeOutMs = 0,
    int rampUpMs = 0, // 渐强唤醒：音量 5%→目标 线性爬升
    bool loopFill = false, // 短音效循环填充到目标时长
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
        // 焦点类型按通道区分，见 focusGainFor() 的说明。
        androidAudioFocusGainType: focusGainFor(channel),
        androidWillPauseWhenDucked: true,
      ));

      // 2) 载入并播放。渐强唤醒优先于普通淡入。
      await player.setFilePath(path);
      if (rampUpMs > 0) {
        await player.setVolume(volume * 0.05);
        unawaited(_rampUp(player, volume, rampUpMs));
      } else {
        await player.setVolume(volume);
        if (fadeInMs > 0) {
          unawaited(_fadeIn(player, volume, fadeInMs));
        }
      }
      if (loopFill) {
        await player.setLoopMode(LoopMode.one); // 单曲循环填充
      }
      await player.play();

      // 3) 随机时长控制：到点停止（非循环时若文件更短则自然结束）。
      final fileMs = (player.duration ?? Duration.zero).inMilliseconds;
      final target = maxDurationMs <= 0
          ? fileMs
          : (loopFill || fileMs <= 0 || fileMs > maxDurationMs
              ? maxDurationMs
              : fileMs);
      if (target > 0) {
        await Future<void>.delayed(Duration(milliseconds: target));
      }
      if (fadeOutMs > 0) {
        await _fadeOut(player, fadeOutMs);
      }
      await player.stop();
      await player.setLoopMode(LoopMode.off);
      return PlayResult(ok: true, playedMs: sw.elapsedMilliseconds);
    } catch (e) {
      return PlayResult(
          ok: false, playedMs: sw.elapsedMilliseconds, message: e.toString());
    }
  }

  /// 终止当前混音（供引擎/UI 调用）。
  void stopSoundscape() => _mixStopped = true;

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

  /// 渐强唤醒（Sleep Cycle 式）：5% 起线性爬升，步进柔和。
  Future<void> _rampUp(AudioPlayer p, double target, int ms) async {
    const steps = 40;
    for (var i = 1; i <= steps; i++) {
      await p.setVolume(target * (0.05 + 0.95 * i / steps));
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

/// 声景轨（混音输入）：已解析的文件路径 + 音量 + 循环。
class SoundscapeTrackInput {
  const SoundscapeTrackInput(
      {required this.path, this.volume = 0.6, this.loop = true});

  final String path;
  final double volume;
  final bool loop;
}

extension PlaybackSoundscape on PlaybackService {
  /// 多轨混音：每轨独立 AudioPlayer 同时播放，durationMs 到点全部渐停。
  /// 返回实际播放毫秒数。
  Future<PlayResult> playSoundscape({
    required List<SoundscapeTrackInput> tracks,
    required int durationMs,
    required AudioChannel channel,
    int fadeOutMs = 3000,
  }) async {
    final sw = Stopwatch()..start();
    if (tracks.isEmpty) {
      return const PlayResult(ok: false, message: '声景无轨道');
    }
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: channel == AudioChannel.alarm
            ? AndroidAudioUsage.alarm
            : AndroidAudioUsage.media,
      ),
      // 同单轨播放：media 通道用 mayDuck，避免打断使用者正在听的音乐。
      // （扩展内引用静态成员必须带类型名限定。）
      androidAudioFocusGainType: PlaybackService.focusGainFor(channel),
      androidWillPauseWhenDucked: true,
    ));

    final players = <AudioPlayer>[];
    try {
      for (final t in tracks) {
        final p = AudioPlayer();
        players.add(p);
        await p.setFilePath(t.path);
        await p.setVolume(t.volume);
        if (t.loop) await p.setLoopMode(LoopMode.one);
      }
      // 尽量同时起播。
      for (final p in players) {
        unawaited(p.play());
      }
      // 等待总时长，期间可被 stopSoundscape 打断（通过 _mixStopped 标志）。
      while (sw.elapsedMilliseconds < durationMs) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (_mixStopped) break;
      }
      // 渐出后全停。
      final fo = fadeOutMs.clamp(0, durationMs);
      const steps = 12;
      for (var s = 1; s <= steps; s++) {
        for (final p in players) {
          await p.setVolume(p.volume * (1 - s / steps));
        }
        await Future<void>.delayed(Duration(milliseconds: fo ~/ steps));
      }
      for (final p in players) {
        await p.stop();
        await p.dispose();
      }
      _mixStopped = false;
      return PlayResult(ok: true, playedMs: sw.elapsedMilliseconds);
    } catch (e) {
      for (final p in players) {
        try {
          await p.dispose();
        } on Object {
          // ignore
        }
      }
      _mixStopped = false;
      return PlayResult(
          ok: false, playedMs: sw.elapsedMilliseconds, message: e.toString());
    }
  }

  /// 终止当前混音（外部 stop() 或条件变化时调用）。
  void stopSoundscape() => _mixStopped = true;
}
