import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

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
class OnlineTtsClient {
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
  void close() => _client.close();

  /// 合成 [text]（用 [voiceName] 音色），成功返回音频字节，失败返回 `null`。
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

  final OnlineTtsClient client;
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