import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

import '../domain/models/trigger.dart';

/// 声音事件（守卫模式输出）。
class SoundEvent {
  const SoundEvent(
      {required this.detectedAt,
      required this.peakDb,
      required this.durationMs});

  final DateTime detectedAt;
  final double peakDb; // dBFS
  final int durationMs;
}

/// 声音守卫：麦克风采流 -> 滑动 RMS -> dBFS 阈值判定。
///
/// v1 为纯能量阈值检测（零依赖、低功耗、可解释）；
/// v2 路线图接入 YAMNet/TFLite 声音事件分类（区分说话/喊叫/音乐/敲击），
/// 接口保持不变（SoundEvent 增加分类字段即可）。
///
/// 隐私红线（docs/08）：音频仅在内存中计算能量，原始数据不落盘、不上传。
class SoundGuardService {
  SoundGuardService({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  StreamSubscription<Uint8List>? _sub;

  final _events = StreamController<SoundEvent>.broadcast();
  final _levels = StreamController<double>.broadcast();

  /// 实时电平（dBFS，供 UI 电平表）。
  Stream<double> get levels => _levels.stream;
  Stream<SoundEvent> get events => _events.stream;

  bool _running = false;
  bool get isRunning => _running;

  /// 启动守卫。必须在前台/带麦克风前台服务的上下文中调用。
  Future<bool> start(SoundTrigger cfg) async {
    if (_running) return true;
    if (!await _recorder.hasPermission()) return false;
    _running = true;

    // 16kHz 单声道 PCM16 足够做能量检测且功耗低。
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.mic),
    ));

    var loudSince = DateTime.now();
    var peak = -120.0;
    var inEvent = false;
    final cooldown = Duration(seconds: cfg.cooldownSec);
    var lastFired = DateTime.fromMillisecondsSinceEpoch(0);

    _sub = stream.listen((chunk) async {
      final db = rmsDbfs(chunk);
      _levels.add(db);
      if (db >= cfg.thresholdDb) {
        peak = math.max(peak, db);
        if (!inEvent) {
          inEvent = true;
          loudSince = DateTime.now();
        }
        final held = DateTime.now().difference(loudSince).inMilliseconds;
        final cooled = DateTime.now().isAfter(lastFired.add(cooldown));
        if (held >= cfg.minDurationMs && cooled) {
          lastFired = DateTime.now();
          _events.add(SoundEvent(
            detectedAt: lastFired,
            peakDb: peak,
            durationMs: held,
          ));
          peak = -120.0;
          inEvent = false;
        }
      } else {
        inEvent = false;
        peak = -120.0;
      }
    }, onError: (Object e) {
      _running = false;
    });
    return true;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } on Object {
      // 状态自愈
    }
    _running = false;
  }

  /// 静态公开以便宿主机单测（纯函数，无平台依赖）。
  static double rmsDbfs(Uint8List bytes) {
    if (bytes.length < 2) return -120;
    // 每 8 字节取样一次即可（~4 sample 抽 1），进一步降 CPU。
    double sum = 0;
    var n = 0;
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i + 1 < bytes.length; i += 8) {
      final s = bd.getInt16(i, Endian.little) / 32768.0;
      sum += s * s;
      n++;
    }
    if (n == 0) return -120;
    final rms = math.sqrt(sum / n);
    return rms <= 0 ? -120 : 20 * math.log(rms) / math.ln10;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _levels.close();
  }
}
