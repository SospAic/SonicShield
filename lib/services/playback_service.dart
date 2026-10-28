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

/// 播放优先级（ARCH-09：播放无优先级仲裁 —— 计划 / 远程 / TTS 三路可同时出声）。
///
/// ## 调用方约定（本包只定义 + 实现 + 默认值；传参归各调用方）
///
/// - **F2 计划执行**（`background_engine` 的 `play` / `playSoundscape` 调用点）：
///   传 `PlayPriority.normal`（默认值即可）—— 计划任务与用户自排内容同级；
/// - **F1 远程播放**（`main.dart` 的 `playHandler` / 端点指令组 play 步）：
///   传 `PlayPriority.high` —— 远程喊话/取证播报必须被听见；
/// - **TTS**（`neural_tts` / `tts_service` / `online_tts_client`）与远程
///   **同级**：双方同优先级时按**到达顺序**排队（FIFO），不互抢占；
/// - 未显式传参的调用方（含既有代码）走默认 [PlayPriority.normal]，
///   行为与本轮之前完全一致。
///
/// ## 语义
///
/// - 高优先级播放前**打断**所有正在播放的更低优先级 solo 播放
///   （被打断方如实报 `ok:false` + 原因，绝不记 success）；
/// - 同级**不互打断**：按到达顺序并行（与 R90-07 的并发隔离一致，
///   不引入新的互斥）；
/// - 低优先级播放遇到正在进行的更高优先级 ⇒ **让行**（yield）：
///   不播放，如实报 `ok:false` + 原因，不覆盖高优先级的声音；
/// - 声景多轨与对讲会话**不参与**抢占：混音是产品特性（docs/20 声景），
///   一刀切"新播放停旧播放"会破坏它（ARCH-09 Regression Risks）。
enum PlayPriority { low, normal, high, urgent }

/// 播放服务：封装 just_audio + audio_session。
///
/// 关键行为：
/// - 按 channel 申请对应类型音频焦点（media / alarm），媒体通道尊重勿扰；
/// - **焦点配对放弃**（NAT-04）：最后一路播放结束/停止/异常/释放时
///   `setActive(false)`，不再"只申请不放弃"（否则别人的音乐被 duck 后
///   音量一直偏低、被暂停后不自动恢复）；
/// - **优先级仲裁**（ARCH-09）：`play(priority:)` 高优先级打断低优先级、
///   同级按到达顺序不互抢、低优先级向更高优先级让行（调用方约定见
///   [PlayPriority] 注释）；
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

  /// 最近一次 solo 播放使用的播放器（[dispose] 兜底）。
  ///
  /// R90-07（2026-10-19）：**不再是复用句柄** —— `play()` 每次新建一个播放器，
  /// 并发路径（定时任务 / 声音守卫 / 远程立即执行）各持各的，互不打断。
  /// 本字段只保留"最后一次"的引用，供 [dispose] 释放；在飞的那几个由各自
  /// 的 `finally` 释放。
  AudioPlayer? _player;

  /// 所有**在飞**的 solo 播放器（R90-07 并发隔离）。
  final Set<AudioPlayer> _soloPlayers = <AudioPlayer>{};

  /// 在飞 solo 播放器的**优先级台账**（ARCH-09）：player → priority。
  ///
  /// 与 [_soloPlayers] 同增同消（`play()` 的 `finally` 里一起清）。
  final Map<AudioPlayer, PlayPriority> _soloPriority =
      <AudioPlayer, PlayPriority>{};

  /// 被更高优先级**抢占**的在飞播放器（ARCH-09）。
  ///
  /// 为什么需要显式标记而不只 `stop()` 播放器：`_waitPlayWindow` 按代次
  /// （[_stopGen]）判断"是否收到停止"，而抢占是**按优先级**的精确打断
  /// （不能推全局代次 —— 那会误伤同级的另一路）。等待循环每 tick 查一次
  /// 本表，被标中的播放立刻退出并如实报失败。
  final Set<AudioPlayer> _preempted = <AudioPlayer>{};

  /// 在飞 solo 播放的**引用计数**。
  ///
  /// [_playing] 是 `Set<PlaybackService>`（实例级），并发两路播放时若第一路
  /// 结束时无条件 `remove(this)`，第二路就再也停不下来（"停止指令组"拿不到
  /// 本实例）。与 [_pttStreams] 同一处置：只有最后一个结束才摘登记。
  int _activePlays = 0;

  /// 停止**代次**（R90-07）：[stop] 递增；每个 `play()` 记住启动时的代次，
  /// 代次变了即"这次播放已被要求停止"，如实报失败。
  ///
  /// 为什么不用单个 bool：旧实现 `_stopRequested = false` 写在 `play()` 开头，
  /// 于是**后一次播放会把前一次尚未察觉的停止请求清掉**（前一次继续出声到窗口
  /// 结束，还记 success）；反过来 `stop()` 置 true 又会误伤**之后**才启动的
  /// 那次播放。代次把"停止"绑定到"启动时的那一代"，两个方向都正确。
  int _stopGen = 0;

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

  /// 是否有**任何**实例正在播放（手动 / 调度 / 声景 / 对讲）。
  ///
  /// 只读探测，供「实时随机动态反击」做互斥判断：手动或调度正在出声时，
  /// 反击**不得叠加**（叠加既难听又易踩播放器）。之所以复用 [_playing]
  /// 登记表而不是自建标志：那张表正是"谁在出声"的唯一真源，自建标志一定会漂移。
  static bool get anyPlaying => _playing.isNotEmpty;

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
    /// 显式要求**整段循环**（声景铺底）。
    ///
    /// R100 起「文件比目标时长短」**自动**循环填充（老板需求：不许播完就静默），
    /// 调用方不再需要为短音效传 true；此参数只用于「文件够长、但仍要整段循环」
    /// 的场景（声景多轨铺底）。
    bool loopFill = false,
    PlayPriority priority = PlayPriority.normal, // ARCH-09：调用方约定见枚举注释
  }) async {
    final player = AudioPlayer();
    _player = player;
    _soloPlayers.add(player);
    _soloPriority[player] = priority;
    _activePlays++;
    _playing.add(this);
    final gen = _stopGen;
    final sw = Stopwatch()..start();
    try {
      // ARCH-09：优先级仲裁必须发生在起播之前 —— 抢占是"可感知"的
      // （立刻静音），让行则根本不出声。放在这里而不是 `configure` 之后：
      // 仲裁失败时不该留下任何已申请的资源。
      if (await _arbitratePriority(priority, player)) {
        return PlayResult(
            ok: false,
            playedMs: sw.elapsedMilliseconds,
            message: '已有更高优先级的播放在进行，本次让行未播放（ARCH-09）');
      }
      // 1) 申请音频会话/焦点：alarm 通道在 Android 上映射 USAGE_ALARM，
      //    可穿透勿扰与媒体静音（合规约束见 docs/08）。
      final session = await AudioSession.instance;
      await session.configure(audioSessionConfigFor(channel));

      // 2) 载入并播放。渐强唤醒优先于普通淡入。
      await player.setFilePath(path);
      // R100（老板需求）：**音效短于目标时长 ⇒ 循环播放填满**，不许"播完就静默"。
      //
      // 旧行为：`loopFill` 默认 false，短音效播完就结束，剩余时长是**静默**——
      // 用户设了「随机时长 30 秒」，实际只响 1.3 秒，体感是"没生效"。
      // 现在：`setFilePath` 完成即可拿到 `duration`（just_audio 会等元数据），
      // 只要「文件比目标短」就自动 `LoopMode.one`，到目标时长再硬停。
      //
      // `loopFill` 参数保留原语义（**即使文件够长也循环**，用于声景铺底），
      // 短音效不再需要用户手动开这个开关。
      //
      // ⚠️ `duration` 拿不到（null/0）时**不自动循环**：无法判断是否够长，
      // 盲目循环会让"只该响一遍"的长音频变成无限循环。此时退回旧行为
      // （等到 maxDurationMs 后硬停），已登记为已知限制。
      final fileMs = (player.duration ?? Duration.zero).inMilliseconds;
      final autoFill = fileMs > 0 && maxDurationMs > 0 && fileMs < maxDurationMs;
      if (rampUpMs > 0) {
        await player.setVolume(volume * 0.05);
        unawaited(_rampUp(player, volume, rampUpMs));
      } else {
        await player.setVolume(volume);
        if (fadeInMs > 0) {
          unawaited(_fadeIn(player, volume, fadeInMs));
        }
      }
      if (loopFill || autoFill) {
        await player.setLoopMode(LoopMode.one); // 单曲循环填充到目标时长
      }
      await player.play();

      // 3) 时长控制：目标就是 `maxDurationMs`（`<= 0` 表示不限制 ⇒ 播一遍文件）。
      //
      // R100 之前这里还有一档 `fileMs < maxDurationMs ? fileMs : ...`——
      // 即"文件比目标短就按文件时长收尾"，剩下的时间静默。现在 `autoFill`
      // 已把短音效循环到目标，那一档会让循环**白设**（50ms 的文件仍然 50ms 就停）。
      final target = maxDurationMs <= 0 ? fileMs : maxDurationMs;
      if (target > 0) {
        await _waitPlayWindow(Duration(milliseconds: target), gen, player);
      }
      if (gen != _stopGen) {
        // 收到停止：**立刻静音**（不做淡出 —— 用户要的就是停），并把结果
        // 如实标成失败。报成功会让控制端以为"这段声音已经正常播完了"。
        await _hardStop(player);
        return PlayResult(
            ok: false,
            playedMs: sw.elapsedMilliseconds,
            message: '已终止（收到停止请求）');
      }
      if (_preempted.remove(player)) {
        // ARCH-09：被更高优先级抢占 —— 与"收到停止"同口径：如实报失败。
        // 记 success 会让排障者以为这段声音播完了（实际被掐掉）。
        await _hardStop(player);
        return PlayResult(
            ok: false,
            playedMs: sw.elapsedMilliseconds,
            message: '被更高优先级的播放抢占（ARCH-09）');
      }
      if (fadeOutMs > 0) {
        await _fadeOut(player, fadeOutMs);
      }
      await _hardStop(player);
      return PlayResult(ok: true, playedMs: sw.elapsedMilliseconds);
    } catch (e) {
      // BUG-122：失败路径**也必须让声音停下来**。
      //
      // 旧写法直接 `return PlayResult(ok:false)`，播放器与 `LoopMode.one`
      // 原封不动。一旦异常发生在 `setLoopMode(one)` + `play()` **之后**
      // （`_waitPlayWindow` / `_fadeOut` 抛错、平台通道抖动、音频会话被抢），
      // 这段短音效会**无限循环**下去；而 `finally` 已把实例从 `_playing`
      // 摘掉 ⇒ 连「停止指令组」的 `stopAllPlaying()` 都拿不到它，只能等用户
      // 手动杀应用。失败可以，失控不行。
      await _hardStop(player);
      return PlayResult(
          ok: false, playedMs: sw.elapsedMilliseconds, message: e.toString());
    } finally {
      _soloPlayers.remove(player);
      _soloPriority.remove(player);
      _preempted.remove(player);
      // R90-07：每路播放器独立释放 —— 共享句柄时"后一次 setFilePath 打断前一次"
      // 与"前一次的 _hardStop 静音后一次"都会发生，且两边都记 success。
      try {
        await player.dispose();
      } on Object {
        // 释放失败不影响已完成的播放语义。
      }
      // 引用计数归零才摘登记（并发两路时第一路结束不得让第二路失联）。
      _activePlays--;
      if (_activePlays <= 0) {
        _activePlays = 0;
        _playing.remove(this);
        // NAT-04：**最后一路**播放结束才放弃音频焦点。
        await _abandonAudioFocus();
      }
    }
  }

  /// ARCH-09：播放优先级仲裁。返回 true = 本次播放应**让行**（有更高
  /// 优先级正在播放）；同时把**正在播放的更低优先级**全部抢占。
  ///
  /// 抢占动作 = 标记 + 立刻静音：被抢占方的 `_waitPlayWindow` 在下一个
  /// tick（≤50ms）发现标记后退出，如实报 `ok:false`。不能只静音不标记 ——
  /// 那样等待方要等满整个窗口（"点了停却继续出声"的同款问题）。
  Future<bool> _arbitratePriority(
      PlayPriority priority, AudioPlayer self) async {
    var yieldToHigher = false;
    for (final p in List<AudioPlayer>.of(_soloPlayers)) {
      if (identical(p, self)) continue;
      final other = _soloPriority[p];
      if (other == null) continue;
      if (priority.index > other.index) {
        _preempted.add(p);
        await _hardStop(p);
      } else if (priority.index < other.index) {
        yieldToHigher = true;
      }
      // 同级：不抢不让，按到达顺序并行（R90-07 语义不变）。
    }
    return yieldToHigher;
  }

  /// NAT-04：放弃音频焦点（`audio_session` 只在 `setActive(false)` 时
  /// `abandonAudioFocus`）。
  ///
  /// 为什么必须配对：just_audio 在 `play()` 时 `setActive(true)` 申请焦点，
  /// 而 `stop()` / `dispose()` 都不会放弃，本项目此前也没补 —— 于是从
  /// 第一次播放起一直持有焦点：别人的音乐被 duck 后**音量一直偏低**、
  /// 被暂停后不会自动恢复（A5 NAT-04）。引用计数收口：还有在飞播放
  /// （solo / 声景 / 对讲）时**不**释放，否则会盖掉仍在播的那一路。
  Future<void> _abandonAudioFocus() async {
    if (_soloPlayers.isNotEmpty || _mixPlayers.isNotEmpty || _pttStreams > 0) {
      return;
    }
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } on Object {
      // 放弃失败不影响播放语义：进程死亡时焦点由系统回收。
      // （宿主测试环境 `setActive` 直接 return true，不走平台通道。）
    }
  }

  /// 兜底静音：**先关循环** → 停播 → 确认已停（不行就静音）。
  ///
  /// R101（老板实测「铺满时长后还在响」）：R100 的顺序是 `stop()` → `setLoopMode(off)`，
  /// 这个顺序在 `LoopMode.one` 下有个致命缝隙 —— 若 `stop()` 因平台抖动失败
  /// （异常被吞），随后的 `setLoopMode(off)` 只会让它在**本轮循环播完时**停下，
  /// 而不是立刻停。1.3 秒的音效因此还要再响一整轮，听感就是"该停没停"。
  /// **先关循环**则即使 `stop()` 失败也不会续播下一轮。
  ///
  /// 第二道兜底：`stop()` 后仍 `playing` ⇒ `pause()`；还不行 ⇒ 音量归零。
  /// 本项目红线是「失败必须可见、失控必须止住」——宁可哑掉，也不能一直响。
  Future<void> _hardStop(AudioPlayer player) async {
    try {
      await player.setLoopMode(LoopMode.off);
    } on Object {
      // 关循环失败也要继续停播：下一步才是真正止声的那一步。
    }
    try {
      await player.stop();
    } on Object {
      // 停不掉就交给下面的兜底。
    }
    try {
      if (player.playing) {
        await player.pause();
      }
    } on Object {
      // 继续兜底。
    }
    try {
      if (player.playing) {
        await player.setVolume(0);
      }
    } on Object {
      // 三条都失败：`finally` 的 `dispose()` 是最后一道保险。
    }
  }

  /// 等待播放窗口；期间若 [stop] 把代次推进（[gen] != [_stopGen]）立即返回。
  ///
  /// 50ms 一轮 ⇒ 终止的延迟上界 = 一个 tick，CPU 代价可忽略
  /// （对照 `playSoundscape` 的 250ms 轮询）。
  /// 旧实现是裸 `await Future.delayed(maxDurationMs)`：`stop()` 只是把播放器
  /// 停了，等待方仍要傻等到时长耗尽才返回 —— 端点因此"点了停却继续出声"。
  ///
  /// [player] 参与 ARCH-09 抢占轮询：被更高优先级标中（[_preempted]）时
  /// 同样立刻返回，由调用方如实报失败。
  Future<void> _waitPlayWindow(Duration total, int gen, AudioPlayer player) async {
    const tick = Duration(milliseconds: 50);
    var left = total;
    while (left > Duration.zero) {
      if (gen != _stopGen) return;
      if (_preempted.contains(player)) return;
      final step = left < tick ? left : tick;
      await Future<void>.delayed(step);
      left -= step;
    }
  }

  /// 终止当前混音（供引擎/UI 调用）。
  void stopSoundscape() => _mixStopped = true;

  Future<void> stop() async {
    // ⚠️ **先推代次再停播放器**：正在 [_waitPlayWindow] 里等待的 play() 会在
    // 下一个 tick 退出并如实报失败。顺序在这里是语义不是风格 —— 只停播放器
    // 而不通知等待方，play() 仍会等满 maxDurationMs（远程「停止指令组」
    // 在端点侧"点了停却继续出声"的根因之一）。
    //
    // R90-07：代次（而非 bool）保证"停"只作用于**本次 stop 之前**启动的播放，
    // 不会误伤之后才启动的那一路。
    _stopGen++;
    // P2-08：`stop()` 是"端点静音"的统一出口（`stopAllPlaying` 也只调它）。
    // 除了 solo 播放器，还必须打断声景混音 —— 否则声景几轨会继续出声到窗口到点。
    _mixStopped = true;
    for (final p in List<AudioPlayer>.of(_soloPlayers)) {
      try {
        await p.stop();
      } on Object {
        // 忽略停止异常：状态自愈。
      }
    }
    try {
      await _player?.stop();
    } on Object {
      // 兼容旧字段（通常已在 _soloPlayers 内，重复 stop 是幂等的）。
    }
    for (final p in List<AudioPlayer>.of(_mixPlayers)) {
      try {
        await p.stop();
      } on Object {
        // 忽略停止异常：状态自愈。
      }
    }
    // NAT-04：端点静音后焦点也该放手（还有在飞播放时内部会跳过释放）。
    await _abandonAudioFocus();
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
    // NAT-04：播放器都放了，音频焦点一起放弃（幂等；仍有在飞播放时
    // `_abandonAudioFocus` 内部会跳过 —— 引用计数收口）。
    await _abandonAudioFocus();
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
      // NAT-04：混音收尾放弃焦点（仍有 solo/对讲在飞时内部跳过）。
      await _abandonAudioFocus();
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
    // NAT-04：对讲会话结束也要放弃焦点（最后一个会话才真正释放）。
    await _service._abandonAudioFocus();
  }
}
