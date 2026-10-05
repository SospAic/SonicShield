import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:just_audio/just_audio.dart';

import '../domain/models/action.dart';
import 'ptt_stream_sink.dart';

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
/// ATTR-02 单出口：`AudioSessionConfiguration`（含 `AndroidAudioAttributes`）
/// 只允许在这里构造一次；`play` 与 `playSoundscape` 两条路都走它
/// （`android_compat_lock_test` ATTR-02 锁定构造出口唯一，防两条路漂移）。
AudioSessionConfiguration audioSessionConfigFor(AudioChannel channel) =>
    AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: channel == AudioChannel.alarm
            ? AndroidAudioUsage.alarm
            : AndroidAudioUsage.media,
      ),
      // 焦点类型按通道区分，见 focusGainFor() 的说明。
      androidAudioFocusGainType: PlaybackService.focusGainFor(channel),
      androidWillPauseWhenDucked: true,
    );

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

  /// 声景多轨播放器登记（P2-08）。
  ///
  /// 与主 [_player] 分开存放（声景可能有 N 轨），但必须同样受 [stop] 统一停止：
  /// 远程「停止指令组」只握有 `PlaybackService` 实例，拿不到 `playSoundscape`
  /// 里局部创建的各个 `AudioPlayer`。旧实现 `stop()` 只停 `_player`，
  /// 声景会继续出声直到 `durationMs` 到点 —— 用户"点了停却还在响"。
  final List<AudioPlayer> _mixPlayers = <AudioPlayer>[];

  /// 正在进行的流式对讲会话数（v2）。
  ///
  /// 用于**引用计数**：多个对讲会话共享同一个 [PlaybackService] 实例，
  /// 只有最后一个会话释放时才把本实例从 [_playing] 登记表摘掉 ——
  /// 否则第一个会话结束就会让「停止指令组」再也拿不到本实例，
  /// 第二个会话便停不下来。
  int _pttStreams = 0;

  bool _mixStopped = false;

  /// [stop] 已被请求；正在 [_waitPlayWindow] 里等待的 [play] 据此**提前收尾，
  /// 并把结果如实标成失败**（不是"播完了"）。
  bool _stopRequested = false;

  /// **正在播放**的实例登记表。
  ///
  /// 为什么必须是**静态**表：远程「停止指令组」要在**拿不到实例引用**的前提下
  /// 立刻掐断出声的播放 —— 端点侧的 `playHandler` 是装配期注入的闭包，
  /// 执行器只握有那个闭包（见 `lib/remote/script_executor.dart` 的 `mediaStopper`）。
  static final Set<PlaybackService> _playing = <PlaybackService>{};

  /// 停止全部正在播放的实例；返回**实际发出停止请求**的实例数。
  ///
  /// ⚠️ 语义是"端点静音"而非"停掉某一项任务"：用户按下「停止指令组」时
  /// 要的是**立刻不再出声**，因此不区分这段声音来自哪一次调度。
  static Future<int> stopAllPlaying() async {
    final snapshot = _playing.toList(growable: false);
    for (final p in snapshot) {
      await p.stop();
    }
    return snapshot.length;
  }

  /// 测试缝：清空 [_playing] 登记表。
  ///
  /// ## 为什么需要它
  ///
  /// [_playing] 是**静态**表（远程「停止指令组」要在拿不到实例引用的前提下
  /// 掐断出声的播放，见上文），因此它**跨用例存活**：一条用例里 `play()`
  /// 登记进来的实例，会污染下一条用例对 [stopAllPlaying] 计数与
  /// "登记表是否已归零"的断言 —— 第 34 轮实测形状就是
  /// **PB07 期望 1 实得 2 / PB08 期望 0 实得 2**（`play()` 的 `finally`
  /// 还没跑到，用例就结束了），三条用例相互级联假红、最终被删除
  /// （`docs/17 §61.5-3`）。没有这条缝，任何"登记表"相关的行为锁都写不稳。
  ///
  /// ## 边界（刻意只做一件事）
  ///
  /// **只清表**：不调 `stop()`、不 dispose、不碰任何实例、不改任何标志 ——
  /// 它**不可能**改变生产路径的行为，也**不能**让"播放真的跑起来"。
  /// 生产代码从不调用（`@visibleForTesting` 由 `analysis_options.yaml` 的
  /// `invalid_use_of_visible_for_testing_member: error` 强制）。
  @visibleForTesting
  static void resetRegistryForTest() => _playing.clear();

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
    _stopRequested = false; // 上一次 stop() 不得影响这一次播放
    _playing.add(this);
    final sw = Stopwatch()..start();
    try {
      // 1) 申请音频会话/焦点：alarm 通道在 Android 上映射 USAGE_ALARM，
      //    可穿透勿扰与媒体静音（合规约束见 docs/08）。
      final session = await AudioSession.instance;
      await session.configure(audioSessionConfigFor(channel));

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
        await _waitPlayWindow(Duration(milliseconds: target));
      }
      if (_stopRequested) {
        // 收到停止：**立刻静音**（不做淡出 —— 用户要的就是停），并把结果
        // 如实标成失败。报成功会让控制端以为"这段声音已经正常播完了"。
        await player.stop();
        await player.setLoopMode(LoopMode.off);
        return PlayResult(
            ok: false,
            playedMs: sw.elapsedMilliseconds,
            message: '已终止（收到停止请求）');
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
    } finally {
      _playing.remove(this);
    }
  }

  /// 等待播放窗口；期间收到 [stop]（[_stopRequested]）立即返回。
  ///
  /// 50ms 一轮 ⇒ 终止的延迟上界 = 一个 tick，CPU 代价可忽略
  /// （对照 `playSoundscape` 的 250ms 轮询）。
  /// 旧实现是裸 `await Future.delayed(maxDurationMs)`：`stop()` 只是把播放器
  /// 停了，等待方仍要傻等到时长耗尽才返回 —— 端点因此"点了停却继续出声"。
  Future<void> _waitPlayWindow(Duration total) async {
    const tick = Duration(milliseconds: 50);
    var left = total;
    while (left > Duration.zero) {
      if (_stopRequested) return;
      final step = left < tick ? left : tick;
      await Future<void>.delayed(step);
      left -= step;
    }
  }

  /// 终止当前混音（供引擎/UI 调用）。
  void stopSoundscape() => _mixStopped = true;

  Future<void> stop() async {
    // ⚠️ **先落标志再停播放器**：正在 [_waitPlayWindow] 里等待的 play() 会在
    // 下一个 tick 退出并如实报失败。顺序在这里是语义不是风格 —— 只停播放器
    // 而不通知等待方，play() 仍会等满 maxDurationMs（远程「停止指令组」
    // 在端点侧"点了停却继续出声"的根因之一）。
    _stopRequested = true;
    // P2-08：`stop()` 是"端点静音"的统一出口（`stopAllPlaying` 也只调它）。
    // 除了主 [_player]，还必须打断声景混音 —— 否则声景几轨会继续出声到窗口到点。
    _mixStopped = true;
    try {
      await _player?.stop();
    } on Object {
      // 忽略停止异常：状态自愈。
    }
    for (final p in List<AudioPlayer>.of(_mixPlayers)) {
      try {
        await p.stop();
      } on Object {
        // 忽略停止异常：状态自愈。
      }
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

  /// 释放播放器（**吞异常 + 无条件清空字段**，与 [stop] 同一处置）。
  ///
  /// 两条理由都来自真实调用点 `lib/features/sounds/sound_library_screen.dart`
  /// 的 `State.dispose()`，那里写的是 `_previewPlayer.dispose();` —— **没有 await**：
  ///
  /// 1. fire-and-forget ⇒ `dispose()` 一旦抛，就升级成**未处理的异步错误**
  ///    （页面退出时冒一条谁都读不懂的栈，且没人能 catch）。
  /// 2. `_player = null` 原本排在 `await` **之后** ⇒ 一次释放异常就把它跳过，
  ///    **已销毁的播放器被留在字段里**；后续 `play()` 的 `_player ??=` 会复用
  ///    它，表现为播放静默失效。`finally` 保证清空**无条件**发生。
  ///
  /// 行为锁：`test/playback_dispose_lock_test.dart`（PB09）。该失败分支在宿主上
  /// **结构不可达**（`_player` 私有、唯一赋值点在 `play()` 内、无注入缝），
  /// 故用源码锁 + 变异证伪，而不是写一个覆写 `dispose()` 的替身（那是恒真断言）。
  Future<void> dispose() async {
    try {
      await _player?.dispose();
    } on Object {
      // 忽略释放异常：状态自愈（与 stop() 同一处置）。
    } finally {
      _player = null;
    }
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
    // P2-08：登记到统一会话表 —— 否则远程「停止指令组」拿不到本实例，
    // 声景会继续出声。同时清掉上一次的停止标志（本次是新的混音）。
    PlaybackService._playing.add(this);
    _mixStopped = false;
    final players = <AudioPlayer>[];
    try {
      final session = await AudioSession.instance;
      await session.configure(audioSessionConfigFor(channel));
      for (final t in tracks) {
        final p = AudioPlayer();
        players.add(p);
        _mixPlayers.add(p); // P2-08：逐轨登记，stop() 才能统一停止。
        await p.setFilePath(t.path);
        await p.setVolume(t.volume);
        if (t.loop) await p.setLoopMode(LoopMode.one);
      }
      // 尽量同时起播。
      for (final p in players) {
        unawaited(p.play());
      }
      // 等待总时长，期间可被 stopSoundscape / stop 打断（_mixStopped 标志）。
      while (sw.elapsedMilliseconds < durationMs) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (_mixStopped) break;
      }
      // 被 stop() 打断时各轨已被统一停掉，无需再渐出（用户要的是立刻静音）；
      // 正常到点则渐出后全停。
      if (!_mixStopped) {
        final fo = fadeOutMs.clamp(0, durationMs);
        const steps = 12;
        for (var s = 1; s <= steps; s++) {
          for (final p in players) {
            await p.setVolume(p.volume * (1 - s / steps));
          }
          await Future<void>.delayed(Duration(milliseconds: fo ~/ steps));
        }
      }
      for (final p in players) {
        await p.stop();
        await p.dispose();
      }
      return PlayResult(ok: true, playedMs: sw.elapsedMilliseconds);
    } catch (e) {
      for (final p in players) {
        try {
          await p.dispose();
        } on Object {
          // ignore
        }
      }
      return PlayResult(
          ok: false, playedMs: sw.elapsedMilliseconds, message: e.toString());
    } finally {
      // 无条件清理登记（两条路径都不残留），并复位停止标志 ——
      // 否则下一次混音一开播就被上一次的标志掐掉（PA-12 锁住的性质）。
      for (final p in players) {
        _mixPlayers.remove(p);
      }
      _mixStopped = false;
      PlaybackService._playing.remove(this);
    }
  }

  /// 终止当前混音（外部 stop() 或条件变化时调用）。
  void stopSoundscape() => _mixStopped = true;
}

extension PlaybackPttStream on PlaybackService {
  /// 开一个流式对讲会话（`PttStreamSink` 的 just_audio 实现）。
  ///
  /// 端点侧收到 `ptt.voice{seq}` 分片后逐片落盘，再通过本会话**边收边放**：
  /// 首片到达即起播、后续无缝续播、末片收尾 —— 把 v1 的「整段说完才播」
  /// 变成「边说边播」（Zello 式实时对讲的落点）。
  PttStreamSink openPttStream() => PttPlaybackSession._(this);
}

/// 对流式对讲会话的 just_audio 实现。
///
/// ## 为什么用 `ConcatenatingAudioSource` 而不是"不断换源"
///
/// 每个分片是一个**独立文件**，但听感上必须连成一句话。"换播放器 / 换源"
/// 会在每片之间留下一道可闻的停顿与起播延迟；`ConcatenatingAudioSource` 是
/// just_audio 官方给出的**动态播放列表**用法（`add()` 可在播放中追加），
/// 平台侧（ExoPlayer/AVPlayer）会把相邻音源串成一条队列，片间缝隙最小。
///
/// ## 与端点静音的接线
///
/// 会话的播放器登记进 [PlaybackService] 的混音表（[_mixPlayers]），
/// 因此远程「停止指令组」的 `stopAllPlaying()` / [PlaybackService.stop]
/// 能**立刻掐断对讲出声** —— 与声景同一语义（"端点静音"），
/// 否则用户点了停，对讲还在响。
class PttPlaybackSession implements PttStreamSink {
  PttPlaybackSession._(this._service) {
    _service._mixPlayers.add(_player);
    _service._pttStreams++;
    // 登记到静态表 ⇒「停止指令组」的 stopAllPlaying() 能拿到本实例并静音。
    PlaybackService._playing.add(_service);
  }

  final PlaybackService _service;
  final AudioPlayer _player = AudioPlayer();
  final ConcatenatingAudioSource _source =
      ConcatenatingAudioSource(children: <AudioSource>[]);

  StreamSubscription<ProcessingState>? _stateSub;
  bool _started = false;
  bool _closed = false;

  /// 首片是否已到达并起播（供调用方判定"会话真的开起来了"）。
  bool get started => _started;

  @override
  Future<void> append(String path, {double volume = 1.0}) async {
    if (_closed) return;
    final src = AudioSource.uri(Uri.file(path));
    if (!_started) {
      _started = true;
      // 申请音频会话/焦点（media 通道）：与 v1 整段播放同一出口
      // `audioSessionConfigFor`（ATTR-02 锁：配置只允许在这一条路构造）。
      final session = await AudioSession.instance;
      await session.configure(audioSessionConfigFor(AudioChannel.media));
      // ⚠️ 顺序：先入 children（此时 `_player == null` ⇒ 只记列表），
      // 再 `setAudioSource` 交给平台 —— 反过来会先加载一个空列表。
      await _source.add(src);
      await _player.setAudioSource(_source);
      await _player.setVolume(volume);
      unawaited(_player.play());
      _stateSub = _player.processingStateStream.listen((s) {
        if (s == ProcessingState.completed) _onCompleted = true;
      });
      return;
    }
    await _source.add(src);
    // 队列若在中途播空（`completed`）后又收到分片，需从新分片重新起播，
    // 否则 just_audio 停在 completed 不再出声（"后面几句听不到"）。
    if (_onCompleted) {
      _onCompleted = false;
      await _player.seek(Duration.zero, index: _source.children.length - 1);
      unawaited(_player.play());
    }
  }

  bool _onCompleted = false;

  @override
  Future<void> end() async {
    _closed = true;
    await _stateSub?.cancel();
    _stateSub = null;
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    await _stateSub?.cancel();
    _stateSub = null;
    try {
      await _player.stop();
    } on Object {
      // 忽略停止异常：状态自愈（与 PlaybackService.stop 同一处置）。
    }
    _service._mixPlayers.remove(_player);
    _service._pttStreams--;
    if (_service._pttStreams <= 0) {
      _service._pttStreams = 0;
      PlaybackService._playing.remove(_service);
    }
    try {
      await _player.dispose();
    } on Object {
      // 忽略释放异常。
    }
  }
}
