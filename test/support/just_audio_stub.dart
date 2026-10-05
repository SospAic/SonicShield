/// `just_audio` **平台接口假实现** —— 宿主测试专用（第 46 轮新增）。
///
/// ## 为什么需要它
///
/// `lib/services/playback_service.dart` 的整条业务路径（取音频会话 → 载入 →
/// 设音量/循环 → 起播 → 随机时长到点停止 → 渐强/淡入/淡出 → 多轨混音）
/// 都站在 `AudioPlayer` 后面，而宿主上没有 `just_audio` 的原生实现。
/// 第 34 轮实测形状（`test/cov_services_test.dart` PB06 段注释）：
/// `_pluginPlatform.init(...)` 抛 `MissingPluginException` ⇒
/// `durationCompleter`（`just_audio.dart:1313`）**永不完成** ⇒
/// `play()` **挂起而非报错**（`package:test` 30s 超时）。
/// 于是这 76 行此前只有"同步登记"那一步被测过。
///
/// ## 它不是"伪造生产逻辑"
///
/// 本桩**只**复刻 `just_audio_platform_interface` 的**平台侧返回形状**
/// （方法名、请求/响应类型、事件语义），不做任何业务判断。
/// 被驱动的是真实的 `playback_service.dart`：真实的 `play` / `_waitPlayWindow` /
/// `_fadeIn` / `_rampUp` / `_fadeOut` / `playSoundscape` / `stop` / `dispose`，
/// 桩只是把"手机那边的解码器"换成了一个可编程的替身。
///
/// ## 挂钩点（逐行核对 pub 缓存源码得出，非推测）
///
/// * `JustAudioPlatform.instance` —— 静态可写（`just_audio_platform_interface.dart:32`），
///   赋值会走 `PlatformInterface.verifyToken` ⇒ 替身必须 `extends JustAudioPlatform`。
/// * `JustAudioPlatform.init(InitRequest)` —— `just_audio.dart:1425` 的挂起根因点。
/// * `AudioPlayerPlatform.load(LoadRequest)` —— 返回值里的 `duration` 就是
///   `player.duration` 的来源之一；**还必须在此时推一条
///   `processingState != idle` 的播放事件**，否则
///   `just_audio.dart:891` 的
///   `processingStateStream.firstWhere((s) => s != ProcessingState.loading)`
///   **永远不会完成**（`_platformLoading` 需要靠事件清零）。
/// * `AudioPlayerPlatform.play(PlayRequest)` —— `play()`（`just_audio.dart:937`）
///   会 `await playCompleter.future`，而 `playCompleter` **只在**
///   `_sendPlayRequest` 里被 complete ⇒ 本桩必须让它立刻返回。
/// * `JustAudioPlatform.disposePlayer(DisposePlayerRequest)` —— `stop()`
///   走 `_setPlatformActive(false)` 时会调用它（`just_audio.dart:1559`）。
/// * `AudioSession.instance` / `configure` / `setActive` **不需要桩**：
///   三者都在 `audio_session` 内部 `try/catch` 吞掉 `MissingPluginException`
///   （`core.dart:26-45 / :201-214`），且宿主非 iOS/Android ⇒ `setActive` 直接
///   `return true`（`core.dart:296`）。
///
/// ## 已知边界
/// * **不**模拟真实解码/渲染/音频焦点：`duration` 是常量，
///   没有 PCM 输出，`position` 不会自己前进。
/// * **不**模拟 Android 真实 `AudioAttributes` 生效结果（只记录调用）。
library;

import 'dart:async';

import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// `just_audio` 平台族假实现。
///
/// 用法：
/// ```dart
/// final audio = FakeJustAudio(fileDuration: const Duration(seconds: 2));
/// setUp(audio.install);
/// tearDown(audio.uninstall);
/// // 驱动真实代码
/// final r = await PlaybackService().play(path: 'x.mp3', ...);
/// // 断言插件侧真的收到了什么
/// expect(audio.methods, contains('load'));
/// expect(audio.volumes.last, 0.5);
/// ```
class FakeJustAudio {
  FakeJustAudio({this.fileDuration = const Duration(seconds: 5)});

  /// `LoadResponse` 与首个 `ready` 事件里回报的文件时长。
  /// 设为 `null` 模拟"时长未知"（`player.duration == null`）。
  Duration? fileDuration;

  /// 平台侧**收到过的全部方法名**（按调用顺序）。
  final List<String> methods = <String>[];

  /// 每个方法收到的请求对象（便于断言实参）。
  final Map<String, List<Object>> requests = <String, List<Object>>{};

  /// `load` 抛这个（模拟文件损坏 / 解码失败）。
  Object? loadError;

  /// `play` 抛这个。
  Object? playError;

  /// `disposePlayer` 抛这个（模拟原生释放失败 ⇒ 插件回落到 `dispose`）。
  Object? disposePlayerError;

  /// 回落路径 `AudioPlayerPlatform.dispose(DisposeRequest)` 抛这个。
  /// 与 [disposePlayerError] 同时设置 ⇒ 两道都炸 ⇒ 冒泡到调用方。
  Object? disposeError;

  /// 第 n 次（**1 基**，按 `load` 调用顺序）`load` 抛 [loadThrow]。
  /// `null` = 不抛。用于多轨混音里"只坏一轨"的场景。
  int? failLoadAt;

  /// [failLoadAt] 指定的那一次 `load` 抛出的异常。
  Object? loadThrow;

  JustAudioPlatform? _saved;
  _StubPlayer? _player;

  /// `init` 被调用过几次（每个 `AudioPlayer()` 一次）。
  int get initCount => countOf('init');

  /// 安装替身（保存原平台，供 [uninstall] 还原）。
  void install() {
    _saved = JustAudioPlatform.instance;
    JustAudioPlatform.instance = _StubJustAudio(this);
  }

  /// 还原原平台。**必须还原**：`JustAudioPlatform.instance` 是静态的，
  /// 不还原会污染其它用到 `just_audio` 的测试文件（同一进程内）。
  void uninstall() {
    final saved = _saved;
    if (saved != null) JustAudioPlatform.instance = saved;
    _saved = null;
    _player = null;
  }

  /// 手动推一条播放事件（模拟平台侧异步状态变化）。
  void pushEvent({
    required ProcessingStateMessage processingState,
    Duration? duration,
    Duration position = Duration.zero,
    int? currentIndex = 0,
  }) {
    _player?._emit(
      processingState: processingState,
      duration: duration ?? fileDuration,
      position: position,
      currentIndex: currentIndex,
    );
  }

  void _record(String method, Object request) {
    methods.add(method);
    (requests[method] ??= <Object>[]).add(request);
  }

  /// 某方法被调用的次数。
  int countOf(String method) => methods.where((m) => m == method).length;

  /// `setVolume` 收到的音量序列（按调用顺序）。
  List<double> get volumes => (requests['setVolume'] ?? const <Object>[])
      .cast<SetVolumeRequest>()
      .map((r) => r.volume)
      .toList(growable: false);

  /// `setLoopMode` 收到的循环模式序列。
  List<LoopModeMessage> get loopModes =>
      (requests['setLoopMode'] ?? const <Object>[])
          .cast<SetLoopModeRequest>()
          .map((r) => r.loopMode)
          .toList(growable: false);

  /// `load` 收到的源 uri 序列。
  List<String> get loadedUris => (requests['load'] ?? const <Object>[])
      .cast<LoadRequest>()
      .map((r) => r.audioSourceMessage.toMap()['uri'].toString())
      .toList(growable: false);

  /// `load` 收到的**第 n 条**（0 基）的 uri。
  String loadedUriAt(int index) => loadedUris[index];
}

class _StubJustAudio extends JustAudioPlatform {
  _StubJustAudio(this.fake);

  final FakeJustAudio fake;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    fake._record('init', request);
    final player = _StubPlayer(fake, request.id);
    fake._player = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    fake._record('disposePlayer', request);
    final err = fake.disposePlayerError;
    if (err != null) throw err;
    return DisposePlayerResponse();
  }
}

/// 单个播放器的平台侧替身。
///
/// ⚠️ 按 `flutter_lints` 的 `library_private_types_in_public_api`，本类型**不**
/// 出现在 [FakeJustAudio] 的公开签名里 —— 要观测它的行为，走
/// [FakeJustAudio.methods] / [FakeJustAudio.requests] / [FakeJustAudio.pushEvent]。
class _StubPlayer extends AudioPlayerPlatform {
  _StubPlayer(this.fake, String id) : super(id);

  final FakeJustAudio fake;
  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _events.stream;

  /// 平台侧"准备好了"事件。
  ///
  /// ★ `processingState` **必须非 idle**：`just_audio.dart:1329-1331` 用它清零
  /// `_platformLoading`，而 `:891` 的 `firstWhere((s) => s != loading)`
  /// 正等这一下 —— 给 `idle` 会让 `load()` 挂死。
  void _emit({
    required ProcessingStateMessage processingState,
    required Duration? duration,
    required Duration position,
    required int? currentIndex,
  }) {
    if (_events.isClosed) return;
    _events.add(PlaybackEventMessage(
      processingState: processingState,
      updateTime: DateTime.now(),
      updatePosition: position,
      bufferedPosition: Duration.zero,
      duration: duration,
      icyMetadata: null,
      currentIndex: currentIndex,
      androidAudioSessionId: null,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    fake._record('load', request);
    final err = fake.loadError ??
        (fake.failLoadAt == fake.countOf('load') ? fake.loadThrow : null);
    if (err != null) throw err;
    _emit(
      processingState: ProcessingStateMessage.ready,
      duration: fake.fileDuration,
      position: Duration.zero,
      currentIndex: request.initialIndex ?? 0,
    );
    return LoadResponse(duration: fake.fileDuration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    fake._record('play', request);
    final err = fake.playError;
    if (err != null) throw err;
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    fake._record('pause', request);
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    fake._record('setVolume', request);
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    fake._record('setSpeed', request);
    return SetSpeedResponse();
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    fake._record('setPitch', request);
    return SetPitchResponse();
  }

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
      SetSkipSilenceRequest request) async {
    fake._record('setSkipSilence', request);
    return SetSkipSilenceResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    fake._record('setLoopMode', request);
    return SetLoopModeResponse();
  }

  /// 动态播放列表追加（流式对讲 v2 用）。
  ///
  /// `just_audio_platform_interface` 的默认实现**抛 UnimplementedError**
  /// （`just_audio_platform_interface.dart:185-189`）—— 不实现它，
  /// `ConcatenatingAudioSource.add()` 在宿主上会直接炸，流式会话的第二片
  /// 就永远追加不进去（症状是"只听到第一片"）。
  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    fake._record('concatenatingInsertAll', request);
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    fake._record('setShuffleMode', request);
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
      SetShuffleOrderRequest request) async {
    fake._record('setShuffleOrder', request);
    return SetShuffleOrderResponse();
  }

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) async {
    fake._record('setAutomaticallyWaitsToMinimizeStalling', request);
    return SetAutomaticallyWaitsToMinimizeStallingResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
      SetAndroidAudioAttributesRequest request) async {
    fake._record('setAndroidAudioAttributes', request);
    return SetAndroidAudioAttributesResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    fake._record('seek', request);
    return SeekResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    fake._record('dispose', request);
    final err = fake.disposeError;
    if (err != null) throw err;
    return DisposeResponse();
  }
}
