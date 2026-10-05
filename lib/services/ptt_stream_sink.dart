/// 对讲机 **v2 流式**播放会话的最小契约。
///
/// ## 为什么要有这一层抽象
///
/// 端点（`lib/remote/endpoint_service.dart`）在收到 `ptt.voice{seq}` 分片后
/// 需要"边收边放"：首片开播、后续续播、末片收尾。这段**会话状态机**属于端点，
/// 但真正的出声要靠 `just_audio`（`lib/services/playback_service.dart`）。
///
/// 端点若直接 `import` 播放服务，就会把 `just_audio` / `audio_session` 拖进
/// 端点的依赖树，宿主机上根本驱动不了（见 `test/support/just_audio_stub.dart`
/// 头注：宿主上没有原生实现，`play()` 会**挂起而非报错**）。
///
/// 因此把"会话"抽成一个**零第三方依赖**的接口放在这里：
/// - 端点只依赖本接口（`PttStreamSink`），装配期由 `main.dart` 注入具体实现；
/// - 具体实现（`PttPlaybackSession`）在 `PlaybackService` 一侧，与 just_audio 同层；
/// - 单测可以用极其轻量的替身驱动端点的整条会话状态机。
///
/// ⚠️ 与 `endpoint_service.playHandler`（单文件整段播放）**并存**：
/// 未注入本开缝时，`ptt.voice` 一律走 v1 整段路径（向后兼容旧对端）。
abstract interface class PttStreamSink {
  /// 追加一个分片文件（整数个 ADTS 帧，`.aac`）并在**首片**时起播。
  Future<void> append(String path, {double volume = 1.0});

  /// 收尾：不再追加分片，等当前队列播完自然结束。
  Future<void> end();

  /// 释放（停止 + 释放解码器）。**不**负责删除分片文件 —— 文件归调用方管理。
  Future<void> dispose();
}