import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../domain/models/action.dart' show AudioChannel;
import 'playback_service.dart';

/// 内置神经 TTS 引擎（sherpa-onnx VITS，离线中文女声 `vits-piper-zh_CN-xiao_ya-medium`）。
///
/// ## 为什么要把资产拷到私有目录
/// sherpa-onnx 只能读**文件路径**，不能读 Flutter asset 字节流，所以首次使用
/// 时把 `assets/tts/<modelDir>/` 下的模型文件拷贝到应用支持目录，再构造
/// [sherpa.OfflineTts]。拷贝是幂等的（已存在则跳过）。
///
/// ## 永不崩溃契约
/// 模型缺失 / 拷贝失败 / 合成抛错 / 播放异常 —— 任何一步都让 [speak] 返回
/// `false`，App 不会因 TTS 引擎而崩；上层会回落到系统默认音色（见
/// `tts_service.dart` 的 neural 分支）。
class NeuralTtsEngine {
  NeuralTtsEngine({
    this.modelDir = 'vits-piper-zh_CN-xiao_ya-medium',
    this.assetPrefix = 'assets/tts',
  });

  final String modelDir;
  final String assetPrefix;

  sherpa.OfflineTts? _tts;
  bool _failed = false;

  /// 上次加载失败的时刻（BUG-129）。
  ///
  /// ## 为什么不能一失败就永久判死
  /// 旧实现把 `_failed` 设成**单向闩锁**：只要第一次 `ensureLoaded()` 失败
  /// （磁盘临时满、模型还没拷完、`getApplicationSupportDirectory` 偶发超时、
  /// 用户正在迁移数据），本次进程生命周期内神经音色就**再也不可用** ——
  /// 界面照样显示"神经音色"可选，点了却没声音，且没有任何重试路径。
  ///
  /// 现在改成**带冷却的失败记忆**：冷却期内直接短路（避免每次 `speak` 都去
  /// 重试一个必然失败的原生构造），冷却期外允许再试一次。这样既不会热循环，
  /// 也不会把偶发故障钉成永久故障。
  DateTime? _failedAt;

  /// 失败后的重试冷却。
  static const Duration _retryCooldown = Duration(seconds: 30);

  /// 临时 WAV 的序号（BUG-130）。
  ///
  /// 文件名若只由**文本哈希**决定，同一句话并发 `speak`（例如两条任务同时
  /// 触发同一条语音）会写到同一个路径：后写者覆盖前者的文件、先结束者把文件
  /// 删掉 —— 表现为"播放突然中断 / 时长变成 0"。序号 + 微秒时间戳保证唯一。
  int _tmpSeq = 0;

  /// 模型目录里需要随包发布并拷贝的文件（与 `flutter-examples/tts` 的
  /// `model_config.dart` 索引 1 配置一一对应）。
  static const List<String> _modelFiles = <String>[
    'zh_CN-xiao_ya-medium.onnx',
    'tokens.txt',
    'lexicon.txt',
    'phone.fst',
    'date.fst',
    'number.fst',
  ];

  /// 引擎是否已成功加载（可用于 UI 提示"神经音色可用"）。
  bool get ready => _tts != null;

  /// 拷贝模型资产 → 构造引擎。幂等；失败记下时刻并返回 false。
  ///
  /// 失败后的**冷却期**内直接短路（见 [_failedAt]），冷却期外允许重试。
  Future<bool> ensureLoaded() async {
    if (_tts != null) return true;
    if (_failed) {
      final at = _failedAt;
      if (at != null && DateTime.now().difference(at) < _retryCooldown) {
        return false;
      }
      // 冷却已过：清掉失败记忆，走一次完整重试。
      _failed = false;
      _failedAt = null;
    }
    try {
      // ⚠️ 目录 API 的返回值必须**显式赋给局部变量**：`test/dir_path_interpolation_test.dart`
      // 的 DIP 锁靠"赋值行"识别目录变量（否则它会判定本文件"调了目录 API 却没提取到
      // 变量"→ 门禁红）。所以这里不抽 `_supportDir()` 那种"直接 return API"的写法。
      final support = await getApplicationSupportDirectory();
      final dest = Directory(p.join(support.path, 'sonic_shield_tts', modelDir));
      if (!await dest.exists()) {
        await dest.create(recursive: true);
        for (final f in _modelFiles) {
          final data = await rootBundle.load('$assetPrefix/$modelDir/$f');
          await File(p.join(dest.path, f)).writeAsBytes(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        }
      }
      final cfg = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: p.join(dest.path, 'zh_CN-xiao_ya-medium.onnx'),
            tokens: p.join(dest.path, 'tokens.txt'),
            lexicon: p.join(dest.path, 'lexicon.txt'),
          ),
          numThreads: 2,
          debug: false,
        ),
        // 中文 G2P：数字 / 日期 / 拼音规则（sherpa-onnx 要求的绝对路径）。
        ruleFsts: _modelFiles
            .where((f) => f.endsWith('.fst'))
            .map((f) => p.join(dest.path, f))
            .join(','),
        maxNumSenetences: 1,
      );
      _tts = sherpa.OfflineTts(cfg);
      return true;
    } on Object {
      _failed = true;
      _failedAt = DateTime.now();
      return false;
    }
  }

  /// 合成并播放 [text]；[volume] 夹到 `0..1`。返回是否真的发声。
  ///
  /// ## 两条硬约束（BUG-128 / BUG-130）
  /// 1. **必须能被「停止指令组」掐断**。旧实现自建一个 `AudioPlayer` 播临时
  ///    WAV，而这个播放器**没有登记进** `PlaybackService` 的静态表 ——
  ///    远程「停止」与端点的 `stopAllPlaying()` 都拿不到它，语音会一直念到
  ///    自然结束。现在改走 [PlaybackService.play]：它登记进同一张表，并
  ///    统一申请音频会话/焦点（此前这里完全绕过 `AudioSession`，神经语音
  ///    因此不走 media/alarm 通道语义，也抢不到正确焦点）。
  /// 2. **临时文件必须唯一且必删**。文件名带序号 + 微秒戳，删除放进 `finally`。
  Future<bool> speak(String text, double volume) async {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (!await ensureLoaded()) return false;
    final tts = _tts;
    if (tts == null) return false;
    final playback = PlaybackService();
    File? tmp;
    try {
      final audio = tts.generate(text: t, sid: 0, speed: 1.0);
      final wav = encodeWav(audio.samples, audio.sampleRate);
      // 同 ensureLoaded：目录 API 的返回值必须显式赋给局部变量（DIP 锁要求）。
      final support = await getApplicationSupportDirectory();
      final stamp = '${_tmpSeq++}_${DateTime.now().microsecondsSinceEpoch}';
      tmp = File(p.join(
          support.path, 'sonic_shield_tts', 'tts_${_hash(t)}_$stamp.wav'));
      await tmp.writeAsBytes(wav);

      // `maxDurationMs: 0` ⇒ 播完整个文件即返回（内部按文件时长等待）。
      // 被 `stopAllPlaying()` 掐断时返回 `ok:false`（"已终止"），如实上报。
      final r = await playback.play(
        path: tmp.path,
        channel: AudioChannel.media,
        volume: volume.clamp(0.0, 1.0).toDouble(),
        maxDurationMs: 0,
      );
      return r.ok;
    } on Object {
      return false;
    } finally {
      final f = tmp;
      if (f != null) {
        try {
          await f.delete();
        } on Object {
          /* 临时文件，删不掉也不影响功能 */
        }
      }
      // 释放本次创建的播放器：每次 speak 都 new 一个，不释放就是原生句柄泄漏。
      await playback.dispose();
    }
  }

  /// 释放原生引擎（进程退出 / 引擎废弃时调用）。
  void dispose() {
    _tts?.free();
    _tts = null;
  }

  static String _hash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h.toRadixString(16);
  }
}

/// Float32 单声道 PCM（-1..1）→ 16-bit WAV 字节。
///
/// sherpa-onnx 的 `GeneratedAudio.samples` 正是 [-1,1] 浮点，直接落进 16-bit PCM
/// 即可被 `just_audio` 播放，无需额外依赖。
Uint8List encodeWav(Float32List samples, int sampleRate) {
  final bd = ByteData(44 + samples.length * 2);
  bd
    ..setUint32(0, 0x52494646, Endian.little) // 'RIFF'
    ..setUint32(4, 36 + samples.length * 2, Endian.little)
    ..setUint32(8, 0x57415645, Endian.little) // 'WAVE'
    ..setUint32(12, 0x666d7420, Endian.little) // 'fmt '
    ..setUint32(16, 16, Endian.little) // fmt chunk size
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little) // byte rate
    ..setUint16(32, 2, Endian.little) // block align
    ..setUint16(34, 16, Endian.little) // bits per sample
    ..setUint32(36, 0x64617461, Endian.little) // 'data'
    ..setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    // clamp 到 [-1,1] 后 ×32767 必落在 int16 范围内，round() 直接得到 int。
    final pcm = (samples[i].clamp(-1.0, 1.0) * 32767.0).round();
    bd.setInt16(44 + i * 2, pcm, Endian.little);
  }
  return bd.buffer.asUint8List();
}
