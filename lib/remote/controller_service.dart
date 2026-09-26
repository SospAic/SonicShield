import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'endpoint_service.dart';
import 'protocol.dart';
import 'rc_script.dart';
import 'remote_store.dart';

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

  // ---------------- 对讲机（v1 整段模式） ----------------

  static const int pttMaxSeconds = 60;
  static const int pttMaxBytes = 200000; // 公共 broker payload 上限内

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
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc),
        path: _pttPath!);
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
