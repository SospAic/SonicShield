import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 在线语音合成的**最小客户端契约**（v2.0 起两条通路共用）。
///
/// 两条通路：
/// - [OnlineTtsClient]：兼容 Azure Speech 的 REST `synthesis` 端点（需 Key）；
/// - [EdgeTtsClient]：Microsoft Edge「大声朗读」公开 WebSocket 端点（**免 Key**）。
///
/// [OnlineTtsSpeaker] 只依赖本接口 ⇒「用哪条路」是**装配期**决策
/// （见 [buildOnlineTtsClient]），"何时出声、失败怎么收敛"的策略与通路无关，
/// 因此能在宿主测试里被穷举。
abstract interface class TtsSynthClient {
  /// 合成 [text]（用 [voiceName] 音色），成功返回音频字节，失败返回 `null`。
  Future<Uint8List?> synthesize(String text, String voiceName);

  /// 释放底层连接（HTTP 连接 / WebSocket）。
  void close();
}

/// 在线语音合成客户端（v2.0）—— 兼容 Azure Speech 的 REST `synthesis` 端点。
///
/// ## 为什么单独一个文件、且 `http.Client` 是注入的
///
/// "把一段文字变成一段音频字节"是**纯逻辑**：SSML 拼装、请求头、非 2xx/空体
/// 的判定，全都能在宿主测试里用假 `http.Client` 打全。平台相关的那一点点
/// （写临时文件 + 交给 `PlaybackService` 出声）留在 `main.dart`（设备层豁免），
/// 于是这个文件的每一行都进**可测面**分母，不再有"测不到的胶水"。
///
/// ## 失败方向：只回 `null`，不抛
///
/// 在线路径的可能失败形态很多（未配置、超时、非 2xx、空体、网络异常、编码错误），
/// 但调用方（`TtsService.speakOnline`）只关心"到底有没有拿到音频"。把细节收敛成
/// `null` 让调用点无需 `try`，也不会把网络栈的异常泄漏进调度/远程链路。
class OnlineTtsClient implements TtsSynthClient {
  OnlineTtsClient({
    required http.Client client,
    required String endpoint,
    required String apiKey,
  })  : _client = client,
        _endpoint = endpoint.trim(),
        _apiKey = apiKey.trim();

  final http.Client _client;
  final String _endpoint;
  final String _apiKey;

  /// 输出音频格式：24 kHz / 48 kbps 单声道 MP3。
  ///
  /// 与项目其它音频链路一致（`docs/06` 音效为 22.05 kHz 单声道）：语音不需要
  /// 立体声与高码率，48 kbps 在"清晰但省流量"之间平衡（在线语音是计费/流量敏感项）。
  static const outputFormat = 'audio-24khz-48kbitrate-mono-mp3';

  /// 单次合成文本上限（与 `TaskWire.maxTextLen` 同源语义）。
  static const maxTextLen = 500;

  /// 单次请求超时：语音要即时，超时就当"没说出来"（不长时间占住调度）。
  static const timeout = Duration(seconds: 15);

  /// 端点与 Key 是否都已配置。
  bool get configured => _endpoint.isNotEmpty && _apiKey.isNotEmpty;

  /// 释放底层 HTTP 连接（临时客户端用完即关，不做连接池）。
  @override
  void close() => _client.close();

  /// 合成 [text]（用 [voiceName] 音色），成功返回音频字节，失败返回 `null`。
  @override
  Future<Uint8List?> synthesize(String text, String voiceName) async {
    if (!configured) return null;
    final t = text.trim();
    if (t.isEmpty) return null;
    final clipped = t.length > maxTextLen ? t.substring(0, maxTextLen) : t;
    try {
      final resp = await _client
          .post(
            Uri.parse(_endpoint),
            headers: <String, String>{
              'Ocp-Apim-Subscription-Key': _apiKey,
              'Content-Type': 'application/ssml+xml',
              'X-Microsoft-OutputFormat': outputFormat,
              'User-Agent': 'SonicShield',
            },
            body: utf8.encode(buildSsml(clipped, voiceName)),
          )
          .timeout(timeout);
      if (resp.statusCode != 200) return null;
      final bytes = resp.bodyBytes;
      return bytes.isEmpty ? null : bytes;
    } on Object {
      return null;
    }
  }

  /// 拼装 SSML（独立成静态函数：可被宿主测试逐字断言，不必发网络）。
  static String buildSsml(
    String text,
    String voiceName, {
    String locale = 'zh-CN',
  }) {
    final v = voiceName.trim().isEmpty ? 'zh-CN-XiaoxiaoNeural' : voiceName.trim();
    return '<speak version="1.0" '
        'xmlns="http://www.w3.org/2001/10/synthesis" '
        'xml:lang="${_xmlEscape(locale)}">'
        '<voice name="${_xmlEscape(v)}">${_xmlEscape(text)}</voice>'
        '</speak>';
  }

  /// XML 文本转义。文本来自用户/AI，可能含 `&`/`<` 等会破坏 SSML 结构的字符。
  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

// ───────────────────────── Edge「大声朗读」免 Key 通路 ─────────────────────────

/// Edge WebSocket 的最小抽象：收窄成"发文本帧 / 收帧流 / 关连接"三件事。
///
/// 把它抽出来，[EdgeTtsClient] 的协议拼装（帧格式、`turn.end` 判定、二进制取
/// 音频）就是**纯逻辑**，宿主测试注入假 socket 逐帧断言即可，不必真联网。
/// 生产默认实现是 [defaultEdgeSocketConnector]（`dart:io` 的 `WebSocket`）。
abstract interface class EdgeSocket {
  /// 收到的帧：文本帧为 `String`，二进制帧为 `List<int>`。
  Stream<Object?> get stream;

  /// 发送一个文本帧。
  void add(String data);

  /// 关闭连接。
  Future<void> close();
}

/// 建连函数（可注入替身）。
typedef EdgeSocketConnector = Future<EdgeSocket> Function(
  Uri url, {
  Map<String, dynamic>? headers,
});

/// 生产默认连接器：`dart:io` 的 `WebSocket.connect`。
///
/// 刻意**不新增 pubspec 依赖** —— Flutter 移动端本就可用 `dart:io` 建 WebSocket。
/// 发送最小必要请求头（部分网关要求非浏览器来源），失败由上层的 `try` 收敛成 `null`。
Future<EdgeSocket> defaultEdgeSocketConnector(
  Uri url, {
  Map<String, dynamic>? headers,
}) async {
  final ws = await WebSocket.connect(
    url.toString(),
    headers: headers ?? const <String, dynamic>{},
  );
  return _IoEdgeSocket(ws);
}

/// [EdgeSocket] 的 `dart:io` 实现（仅生产使用，不进宿主测试）。
class _IoEdgeSocket implements EdgeSocket {
  _IoEdgeSocket(this._ws);

  final WebSocket _ws;

  @override
  Stream<Object?> get stream => _ws;

  @override
  void add(String data) => _ws.add(data);

  @override
  Future<void> close() => _ws.close();
}

/// Microsoft Edge「大声朗读」在线语音客户端（**免 Key**）。
///
/// ## 为什么它值得独立成一条通路
///
/// 用户要"开箱可用"的在线语音（含东北话），但 Azure 那套要账号 + Key。
/// Edge 浏览器「大声朗读」背后的公开端点走同一批神经网络音色
/// （`zh-CN-XiaoxiaoNeural` / `zh-CN-liaoning-XiaobeiNeural` 等），
/// 只需一个固定公开 `TrustedClientToken`，**无需注册**。于是它可以当作出厂默认，
/// 而 Azure REST 通路（需 Key）保留给想用自己的账号/区域的高级用法。
///
/// ## 协议（每条连接一次合成）
///
/// 1. 连上后先发一帧 `speech.config`（声明输出格式）；
/// 2. 再发一帧 `ssml`（携带待合成文本）；
/// 3. 服务端回**文本帧**（含 `Path:turn.end` 即本轮结束）与**二进制帧**
///    （`[2 字节大端 header 长度][header][payload]`，header 含 `Path:audio`
///    时 payload 才是音频）；
/// 4. 收齐后关连接。全过程任何异常都收敛成 `null`。
class EdgeTtsClient implements TtsSynthClient {
  EdgeTtsClient({
    required String endpoint,
    required EdgeSocketConnector connector,
    String? requestId,
  })  : _endpoint = endpoint.trim(),
        _connector = connector,
        _requestId = requestId ?? newRequestId();

  final String _endpoint;
  final EdgeSocketConnector _connector;
  final String _requestId;

  /// 与 REST 通路一致的输出格式（24 kHz / 48 kbps 单声道 MP3）。
  static const outputFormat = OnlineTtsClient.outputFormat;

  /// 单次合成文本上限（与 REST 通路同源）。
  static const maxTextLen = OnlineTtsClient.maxTextLen;

  /// 合成总超时（含建连与收流）。
  static const timeout = OnlineTtsClient.timeout;

  /// Edge 端点公开的固定令牌（官方前端内置，非用户密钥）。
  static const trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

  /// 端点非空即视为可用（**免 Key**）。
  bool get configured => _endpoint.isNotEmpty;

  /// 每次合成各自建连、`finally` 关连接，故无可跨调用持有的资源。
  @override
  void close() {
    // 无跨调用资源；保留以满足 [TtsSynthClient] 契约。
  }

  @override
  Future<Uint8List?> synthesize(String text, String voiceName) async {
    if (!configured) return null;
    final t = text.trim();
    if (t.isEmpty) return null;
    final clipped = t.length > maxTextLen ? t.substring(0, maxTextLen) : t;
    EdgeSocket? socket;
    try {
      socket = await _connector(Uri.parse(_endpoint)).timeout(timeout);
      socket.add(configMessage(_requestId));
      socket.add(speechMessage(
          _requestId, OnlineTtsClient.buildSsml(clipped, voiceName)));
      final audio = BytesBuilder();
      var turnEnded = false;
      await for (final frame in socket.stream.timeout(timeout)) {
        if (frame is String) {
          if (frame.contains('Path:turn.end')) {
            turnEnded = true;
            break;
          }
        } else if (frame is List<int>) {
          final payload = audioPayload(Uint8List.fromList(frame));
          if (payload != null) audio.add(payload);
        }
      }
      // 没收到 turn.end 就中断（对端异常关闭/超时）= 合成不完整，宁可当失败，
      // 也不播一段残缺音频。
      if (!turnEnded) return null;
      final bytes = audio.toBytes();
      return bytes.isEmpty ? null : bytes;
    } on Object {
      return null;
    } finally {
      try {
        await socket?.close();
      } on Object {
        // 关连接失败不影响结果。
      }
    }
  }

  /// `speech.config` 文本帧（先发，声明音频输出格式）。
  static String configMessage(String requestId) => 'X-RequestId:$requestId\r\n'
      'Content-Type:application/json; charset=utf-8\r\n'
      'Path:speech.config\r\n'
      '\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":'
      '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
      '"outputFormat":"$outputFormat"}}}}';

  /// `ssml` 文本帧（后发，携带 SSML）。
  static String speechMessage(String requestId, String ssml) =>
      'X-RequestId:$requestId\r\n'
      'Content-Type:application/ssml+xml\r\n'
      'Path:ssml\r\n'
      '\r\n'
      '$ssml';

  /// 从二进制帧取音频负载：`[2 字节大端 header 长度][header][payload]`；
  /// 仅当 header 声明 `Path:audio` 时返回 payload，否则 `null`。
  static Uint8List? audioPayload(Uint8List frame) {
    if (frame.length < 2) return null;
    final headerLen = (frame[0] << 8) | frame[1];
    if (frame.length < 2 + headerLen) return null;
    final header = utf8.decode(
      frame.sublist(2, 2 + headerLen),
      allowMalformed: true,
    );
    if (!header.contains('Path:audio')) return null;
    return Uint8List.sublistView(frame, 2 + headerLen);
  }

  /// 生成 32 位十六进制请求 id（Edge 协议要求，无连字符）。
  static String newRequestId() {
    final rnd = Random();
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      sb.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

/// 按端点协议装配在线语音客户端（**唯一的"选通路"决策点**）。
///
/// - 端点空 → `null`（未配置，调用方直接返回 `false`，不发任何请求）；
/// - `ws://` / `wss://` → [EdgeTtsClient]（免 Key，出厂默认走这条）；
/// - `http(s)://` → [OnlineTtsClient]（Azure 兼容 REST，端点与 Key 都必须有，
///   否则 `null`）。
TtsSynthClient? buildOnlineTtsClient({
  required String endpoint,
  required String apiKey,
  http.Client? httpClient,
  EdgeSocketConnector? connector,
}) {
  final ep = endpoint.trim();
  if (ep.isEmpty) return null;
  final lower = ep.toLowerCase();
  if (lower.startsWith('ws://') || lower.startsWith('wss://')) {
    return EdgeTtsClient(
      endpoint: ep,
      connector: connector ?? defaultEdgeSocketConnector,
    );
  }
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    final key = apiKey.trim();
    if (key.isEmpty) return null;
    return OnlineTtsClient(
      client: httpClient ?? http.Client(),
      endpoint: ep,
      apiKey: key,
    );
  }
  return null;
}

/// 播放"一段字节音频"所需的最小平台能力（临时文件 + 播放器）。
///
/// 把这两件事注入进来，[OnlineTtsSpeaker] 的编排逻辑（合成→落盘→播放→清理）
/// 就成了**纯逻辑**：宿主测试用假 sink + 假 HTTP 就能锁住"合成失败要不要落盘、
/// 播放失败要不要清理"这类分支，不必碰真实文件系统或音频设备。
class TtsAudioSink {
  const TtsAudioSink({
    required this.writeTemp,
    required this.deleteTemp,
    required this.play,
  });

  /// 把音频字节写进临时文件，返回路径。
  final Future<String> Function(Uint8List bytes, String ext) writeTemp;

  /// 删除临时文件。
  final Future<void> Function(String path) deleteTemp;

  /// 播放该文件，返回是否真的出声。
  final Future<bool> Function(String path, double volume) play;
}

/// 在线语音的"合成 + 出声"编排（v2.0）。
///
/// 契约（与 `TtsService` 的在线分支对齐）：
/// - 合成失败 / 未配置 → `false`，**不写任何临时文件**（不产生垃圾）；
/// - 播放失败 → `false`，但临时文件**照样清理**（`finally`）。
class OnlineTtsSpeaker {
  const OnlineTtsSpeaker({required this.client, required this.sink});

  final TtsSynthClient client;
  final TtsAudioSink sink;

  Future<bool> speak(String text, String voiceName, double volume) async {
    final Uint8List? bytes = await client.synthesize(text, voiceName);
    if (bytes == null) return false;
    String? path;
    try {
      path = await sink.writeTemp(bytes, 'mp3');
      return await sink.play(path, volume);
    } on Object {
      return false;
    } finally {
      if (path != null) {
        try {
          await sink.deleteTemp(path);
        } on Object {
          // 清理失败不影响结果（缓存目录由系统回收）。
        }
      }
    }
  }
}
