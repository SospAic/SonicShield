import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'endpoint_service.dart';
import 'protocol.dart';
import 'rc_script.dart';
import 'remote_store.dart';
import '../domain/models/counter_plan.dart';

/// 远程遥控控制器（控制端能力）。
///
/// - 发送指令组（宏）到指定端点：组装器 UI → [sendScript]
/// - 发送即时命令：播放/启停任务/守卫/状态查询（远程总览页）
/// - 对讲机：按住说话 → 录制 AAC → 整段加密上传 → 端点自动播放
///   （v1 整段模式，参考微信语音；Zello 式流式为 v2 路线）
class RcControllerService {
  RcControllerService._();
  static final RcControllerService instance = RcControllerService._();

  final RcEndpointService _ep = RcEndpointService.instance;

  // ---------------- 指令组 ----------------

  Future<bool> sendScript(
      PairedEndpoint endpoint, RcScript script, RemoteStore store) async {
    final payload = <String, dynamic>{...script.toJson()};
    return _ep.sendTo(endpoint, RcMessage.now(RcCmd.scriptRun, payload), store);
  }

  Future<bool> sendScriptStop(PairedEndpoint endpoint, RemoteStore store,
      {String scriptId = '*'}) async {
    return _ep.sendTo(endpoint,
        RcMessage.now(RcCmd.scriptStop, {'scriptId': scriptId}), store);
  }

  // ---------------- 即时命令 ----------------

  Future<bool> sendSoundPlay(PairedEndpoint endpoint, RemoteStore store,
      {String? presetCategory,
      double volume = 0.9,
      int durationSec = 5,
      bool loop = false}) async {
    return _ep.sendTo(
        endpoint,
        RcMessage.now(RcCmd.soundPlay, {
          if (presetCategory != null) 'category': presetCategory,
          'volume': volume,
          'durationSec': durationSec,
          'loop': loop,
        }),
        store);
  }

  Future<bool> sendStatusGet(PairedEndpoint endpoint, RemoteStore store) =>
      _ep.sendTo(endpoint, RcMessage.now(RcCmd.statusGet), store);

  Future<bool> sendTaskToggle(PairedEndpoint endpoint, RemoteStore store,
          String taskId, bool enabled) =>
      _ep.sendTo(
          endpoint,
          RcMessage.now(
              RcCmd.taskToggle, {'taskId': taskId, 'enabled': enabled}),
          store);

  Future<bool> sendGuardSet(
          PairedEndpoint endpoint, RemoteStore store, bool enabled) =>
      _ep.sendTo(
          endpoint, RcMessage.now(RcCmd.guardSet, {'enabled': enabled}), store);

  // ---------------- 随机反击计划（v2.0） ----------------

  /// 下发并应用一份反击计划（端点侧走同一 `CounterPlanService.apply`）。
  Future<bool> sendPlanApply(PairedEndpoint endpoint, RemoteStore store,
          CounterPlan plan, {String? planId, bool replace = true}) =>
      _ep.sendTo(
          endpoint,
          RcMessage.now(RcCmd.planApply, {
            'plan': plan.toJson(),
            if (planId != null && planId.isNotEmpty) 'planId': planId,
            'replace': replace,
          }),
          store);

  /// 查询端点当前反击计划 → 端点回 `rc.plan`。
  Future<bool> sendPlanGet(PairedEndpoint endpoint, RemoteStore store) =>
      _ep.sendTo(endpoint, RcMessage.now(RcCmd.planGet), store);

  /// 下线端点反击计划。
  Future<bool> sendPlanStop(PairedEndpoint endpoint, RemoteStore store) =>
      _ep.sendTo(endpoint, RcMessage.now(RcCmd.planStop), store);

  // ---------------- 对讲机（v1 整段模式） ----------------

  static const int pttMaxSeconds = 60;
  static const int pttMaxBytes = 200000; // 公共 broker payload 上限内

  /// 对讲录音参数：**按"说完即到"选，而不是按音乐质量选**。
  ///
  /// v1 此前只写 `RecordConfig(encoder: aacLc)`，其余全用 `record` 插件的
  /// **默认值**（`record_platform_interface` 的 `RecordConfig`：128 kbps /
  /// 44.1 kHz / **立体声**）—— 那是音乐质量，60 秒要 **≈960 KB**，而
  /// [pttMaxBytes] 只有 200 KB ⇒ **任何超过约 12 秒的对讲都会被
  /// "音频过大"拒发**（界面上写的 60 秒上限形同虚设），且近 1 MB 的密文
  /// 在 broker 上往返、再解密落盘，正是"反应和播放太慢"的来源。
  ///
  /// 语音只需**宽带单声道**（行业惯例：Zello / WebRTC 语音链一律
  /// 16 kHz 单声道，见 RFC 6716 的 Opus 宽带档）：16 kHz / 单声道 /
  /// 24 kbps ⇒ 60 秒 ≈ 180 KB，**落在 200 KB 上限内**，整段体积约为原来的
  /// **1/5** —— 收发的每一步（读取、base64、加解密、落盘、播放器装载）
  /// 都随之缩短。AGC（小声也听得清）与降噪（单人对讲无需回声消除）一并对齐。
  static const RecordConfig pttRecordConfig = RecordConfig(
    encoder: AudioEncoder.aacLc,
    sampleRate: 16000,
    numChannels: 1,
    bitRate: 24000,
    autoGain: true,
    noiseSuppress: true,
  );

  final AudioRecorder _rec = AudioRecorder();
  String? _pttPath;
  final Stopwatch _pttStopwatch = Stopwatch();

  bool get pttRecording => _pttStopwatch.isRunning;

  /// 开始按住说话（需麦克风权限已授）。
  Future<bool> pttStart() async {
    if (pttRecording) return true;
    if (!await _rec.hasPermission()) return false;
    final dir = await Directory.systemTemp.createTemp('ptt');
    _pttPath = '${dir.path}/ptt_${const Uuid().v4()}.m4a';
    _pttStopwatch
      ..reset()
      ..start();
    await _rec.start(pttRecordConfig, path: _pttPath!);
    return true;
  }

  /// 松开发送：录制停止 → 读出 AAC → 加密发送。
  /// 返回发送是否成功（超长/超大拒绝并清理）。
  Future<PttSendResult> pttStopAndSend(
      PairedEndpoint endpoint, RemoteStore store) async {
    var path = await _rec.stop();
    _pttStopwatch.stop();
    if (path == null || path.isEmpty) path = _pttPath;
    final durMs = _pttStopwatch.elapsedMilliseconds;
    _pttPath = null;
    if (path == null || !await File(path).exists()) {
      return const PttSendResult(false, '未录到音频');
    }
    if (durMs > pttMaxSeconds * 1000) {
      await File(path).delete();
      return const PttSendResult(false, '超过 60 秒上限');
    }
    final bytes = await File(path).readAsBytes();
    await File(path).delete();
    if (bytes.length > pttMaxBytes) {
      return const PttSendResult(false, '音频过大（压缩率异常）');
    }
    final voiceId = const Uuid().v4();
    final ok = await _ep.sendTo(
        endpoint,
        RcMessage.now(RcCmd.pttVoice, {
          'voiceId': voiceId,
          'durationMs': durMs,
          'audioB64': base64Encode(bytes),
          'fromName': store.deviceName,
        }),
        store);
    return PttSendResult(
        ok, ok ? '已发送（${(durMs / 1000).toStringAsFixed(1)}s）' : '发送失败（端点离线）');
  }

  /// 松开前取消（滑出按钮区）。
  Future<void> pttCancel() async {
    var path = await _rec.stop();
    _pttStopwatch.stop();
    _pttPath = null;
    if (path != null) {
      try {
        await File(path).delete();
      } on Object {
        // ignore
      }
    }
  }

  // ---------------- 对讲机（v2 流式：边录边发） ----------------

  /// 分片聚合阈值（字节）：16 kHz / 单声道 / 24 kbps ≈ 3 KB/s，
  /// 取 1500 字节 ≈ **0.5 秒**一片 —— 兼顾时效（半秒内出声）与开销
  /// （不至于每帧都发一条 MQTT 消息）。
  static const int pttChunkBytes = 1500;

  StreamSubscription<Uint8List>? _pttSub;
  AdtsChunker? _pttChunker;
  PairedEndpoint? _pttEndpoint;
  RemoteStore? _pttStore;
  String _pttVoiceId = '';
  int _pttSeq = 0;

  /// 发送串行链：分片必须**按 seq 顺序**投递，故把每次 `sendTo` 串成一条
  /// Future 链（并发 `sendTo` 不保证到达顺序，会让端点按乱序拼音频）。
  Future<void> _pttSendChain = Future<void>.value();
  bool _pttAbort = false;

  /// 是否正在进行流式对讲（录音流已建立）。
  bool get pttStreaming => _pttSub != null;

  /// 开始流式对讲：`startStream` 边录边收，按 ADTS 帧边界聚齐成片后即时加密发送。
  ///
  /// 平台不支持流式（`startStream` 抛错）或权限被拒 ⇒ 返回 `false`，
  /// 由 UI 提示"录音启动失败"（不静默、不假成功）。
  Future<bool> pttStartStream(
      PairedEndpoint endpoint, RemoteStore store) async {
    if (_pttSub != null) return true;
    if (!await _rec.hasPermission()) return false;
    final Stream<Uint8List> stream;
    try {
      stream = await _rec.startStream(pttRecordConfig);
    } on Object {
      return false;
    }
    _pttEndpoint = endpoint;
    _pttStore = store;
    _pttVoiceId = const Uuid().v4();
    _pttSeq = 0;
    _pttAbort = false;
    _pttChunker = AdtsChunker(minBytes: pttChunkBytes);
    _pttStopwatch
      ..reset()
      ..start();
    _pttSendChain = Future<void>.value();
    _pttSub = stream.listen(_onPttChunk,
        onError: (Object _) {}, cancelOnError: false);
    return true;
  }

  void _onPttChunk(Uint8List data) {
    if (_pttAbort) return;
    final block = _pttChunker?.feed(data);
    if (block != null) _enqueuePttChunk(block, last: false);
    // 60 秒上限：与 v1 同一条边界，到点自动收尾（不必等用户松手）。
    if (_pttStopwatch.elapsedMilliseconds >= pttMaxSeconds * 1000) {
      unawaited(pttStopStream());
    }
  }

  void _enqueuePttChunk(Uint8List block, {required bool last}) {
    final endpoint = _pttEndpoint;
    final store = _pttStore;
    if (endpoint == null || store == null) return;
    final payload = <String, dynamic>{
      'voiceId': _pttVoiceId,
      'seq': _pttSeq++,
      'last': last,
      'fromName': store.deviceName,
    };
    if (block.isNotEmpty) payload['audioB64'] = base64Encode(block);
    _pttSendChain = _pttSendChain.then(
        (_) => _ep.sendTo(endpoint, RcMessage.now(RcCmd.pttVoice, payload), store));
  }

  /// 松开发送：关闭录音流 → 冲尾片（`last=true`）→ 等全部片投递完成。
  ///
  /// 末片即便没有音频字节也会发出（仅 `{voiceId, seq, last:true}`），
  /// 否则端点无法判定"语音结束"，会话会一直挂着等分片。
  Future<PttSendResult> pttStopStream() async {
    if (_pttSub == null) return const PttSendResult(false, '未在录音');
    _pttStopwatch.stop();
    final durMs = _pttStopwatch.elapsedMilliseconds;
    final sub = _pttSub;
    _pttSub = null;
    await sub?.cancel();
    try {
      await _rec.stop();
    } on Object {
      // 关闭流失败不阻断收尾（分片已在路上）。
    }
    final tail = _pttChunker?.flush();
    final hadAudio = _pttSeq > 0 || (tail != null && tail.isNotEmpty);
    _enqueuePttChunk(tail ?? Uint8List(0), last: true);
    await _pttSendChain;
    _resetPttStreamState();
    return PttSendResult(
        hadAudio,
        hadAudio
            ? '已发送（${(durMs / 1000).toStringAsFixed(1)}s）'
            : '未录到音频');
  }

  /// 松开前取消（滑出按钮区）：立即停录，并补一帧**终止帧**让端点收尾。
  ///
  /// 与 v1「取消 = 什么都不发」不同：v2 是边录边发，取消前若已有分片在路上，
  /// 那些分片**收不回来**（流式固有代价，与 Zello 一致）。但必须补发
  /// `last=true` 的终止帧，否则端点会话永远等不到末片、既不回执也不释放
  /// （分片文件与解码器会一直挂着）。
  ///
  /// 一片都没发过（`_pttSeq == 0`）时不补帧：端点根本没有会话，补帧反而会
  /// 被判成"缺少 audioB64"而误报失败。
  Future<void> pttCancelStream() async {
    _pttAbort = true;
    final sub = _pttSub;
    _pttSub = null;
    await sub?.cancel();
    try {
      await _rec.stop();
    } on Object {
      // ignore
    }
    if (_pttSeq > 0) {
      _enqueuePttChunk(Uint8List(0), last: true);
      await _pttSendChain;
    }
    _resetPttStreamState();
  }

  void _resetPttStreamState() {
    _pttAbort = false;
    _pttChunker = null;
    _pttEndpoint = null;
    _pttStore = null;
    _pttVoiceId = '';
    _pttSeq = 0;
    _pttSendChain = Future<void>.value();
  }
}

/// ADTS AAC 帧切分器（v2 流式对讲用）。
///
/// ## 为什么必须按**帧边界**切
///
/// `record` 的 `startStream` 在 Android 上当 `encoder == aacLc` 时输出的是
/// **ADTS 帧流**。控制端把字节流聚成"片"发出去，端点每片落成一个独立 `.aac`
/// 文件交给播放器 —— 若切片落在帧中间，该文件头就不是同步字 `0xFFFx`，
/// 解码器直接判为损坏（"后面几句听不到/杂音"）。因此每次切片都必须恰好覆盖
/// **整数个完整 ADTS 帧**。
class AdtsChunker {
  AdtsChunker({required this.minBytes});

  /// 聚到什么体量才切一片（见 [RcControllerService.pttChunkBytes]）。
  final int minBytes;

  final List<int> _buf = <int>[];

  /// 喂入新字节；当缓冲内的**完整帧**总量 ≥ [minBytes] 时切出并返回一块
  /// （整数个完整帧）；否则返回 `null`（还不到发送时机）。
  Uint8List? feed(Uint8List data) {
    _buf.addAll(data);
    final complete = _completeFramesEnd();
    if (complete < minBytes) return null;
    final out = Uint8List.fromList(_buf.sublist(0, complete));
    _buf.removeRange(0, complete);
    return out;
  }

  /// 冲尾：返回残留字节（可能含一个不完整帧；解码器在文件尾容忍截断帧）；
  /// 空则返回 `null`。
  Uint8List? flush() {
    if (_buf.isEmpty) return null;
    final out = Uint8List.fromList(_buf);
    _buf.clear();
    return out;
  }

  /// 从缓冲头部起逐个解析 ADTS 帧，返回"被完整帧覆盖的字节数"。
  int _completeFramesEnd() {
    var off = 0;
    while (true) {
      if (_buf.length - off < 7) break;
      // ADTS 同步字：12 个 1（0xFF 后高 4 位为 0xF）。
      if (_buf[off] != 0xFF || (_buf[off + 1] & 0xF0) != 0xF0) {
        // 非同步字：向前挪一字节重新对齐（防御性，正常流不应出现）。
        off += 1;
        continue;
      }
      final len = ((_buf[off + 3] & 0x03) << 11) |
          (_buf[off + 4] << 3) |
          ((_buf[off + 5] & 0xE0) >> 5);
      if (len < 7) {
        off += 1;
        continue;
      }
      if (_buf.length - off < len) break;
      off += len;
    }
    return off;
  }
}

class PttSendResult {
  const PttSendResult(this.ok, this.message);

  final bool ok;
  final String message;
}

// ---------------- 音量模块（v1.9 Y1：纯判定函数，不依赖任何实例） ----------------
//
// 判定与接线分离：payload 形状、文案、档位都收在这里，控制台只负责接线。
// 端点侧形状已核实（`endpoint_service._setVolumes`：读 `media`/`alarm`
// 两个 0..1 的 num，经 `NativeBridge.setVolume` 走原生桥 `volume.set`，
// 仅 Android 生效）——键名与取值范围不得另造。

/// 0–100 整数 → `volume.set` 端点 payload（`{'media': 0.0..1.0}`）。
///
/// 越界在**控制端钳制**：端点对 `media` 不做范围校验（`as num?` 后直接
/// 透传原生），发 1.2 这类值等于把边界契约留给没人负责的地方。
/// 只调媒体流，不触碰闹钟/铃声。
Map<String, Object?> volumePayloadForPercent(int percent) {
  final p = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
  return {'media': p / 100.0};
}

/// 音量文案：0 显示「静音」——比"媒体音量 0%"更快被识别为"无声"。
String volumeLabelForPercent(int percent) {
  final p = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
  return p == 0 ? '静音' : '媒体音量 $p%';
}

/// 快捷档位（0 = 静音）。
List<int> volumeQuickSteps() => const [0, 25, 50, 75, 100];
