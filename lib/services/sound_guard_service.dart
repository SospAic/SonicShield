import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

import '../domain/models/trigger.dart';

/// 声音分级（v2.0 阶段 D）：轻 / 中 / 重。
///
/// 只由「峰值 dBFS + 持续时长」两个既有量决定，不引入新采流、不改
/// [SoundEvent] 的构造签名（既有测试锁它们）—— 分级是**派生读数**。
enum SoundGrade {
  light('轻'),
  medium('中'),
  heavy('重');

  const SoundGrade(this.label);
  final String label;
}

/// 分级阈值（**唯一真源**，回归锁见 `test/reactive_counter_test.dart`）。
///
/// 判据是"响度"与"持续"的二维组合：一声脆响（高 dB、极短）与一段闷响
/// （中等 dB、很久）都应被注意到，但强度不同 —— 故每条都给了
/// 「硬阈」与「软阈 + 时长」两条进入条件。
abstract final class SoundGradeLimits {
  /// 峰值 ≥ 此值：无视时长直接判重。
  static const double heavyDb = -12;

  /// 峰值 ≥ [heavySoftDb] 且持续 ≥ [heavyMs]：判重。
  static const double heavySoftDb = -20;
  static const int heavyMs = 3000;

  /// 峰值 ≥ 此值：至少判中。
  static const double mediumDb = -25;

  /// 峰值 ≥ [mediumSoftDb] 且持续 ≥ [mediumMs]：至少判中。
  static const double mediumSoftDb = -30;
  static const int mediumMs = 2000;
}

/// 声音分级纯函数（宿主可穷举，无平台依赖）。
SoundGrade gradeOf(double peakDb, int durationMs) {
  if (peakDb >= SoundGradeLimits.heavyDb ||
      (peakDb >= SoundGradeLimits.heavySoftDb &&
          durationMs >= SoundGradeLimits.heavyMs)) {
    return SoundGrade.heavy;
  }
  if (peakDb >= SoundGradeLimits.mediumDb ||
      (peakDb >= SoundGradeLimits.mediumSoftDb &&
          durationMs >= SoundGradeLimits.mediumMs)) {
    return SoundGrade.medium;
  }
  return SoundGrade.light;
}

/// 声音事件（守卫模式输出）。
class SoundEvent {
  const SoundEvent(
      {required this.detectedAt,
      required this.peakDb,
      required this.durationMs});

  final DateTime detectedAt;
  final double peakDb; // dBFS
  final int durationMs;

  /// 本次事件的分级（由 [gradeOf] 从既有两字段派生，不改变构造签名）。
  SoundGrade get grade => gradeOf(peakDb, durationMs);
}

/// 守卫启动结果。
///
/// ⚠️ 为什么不再是 `bool`：`bool` 只能表达"成/败"，而失败时**必须能说清为什么**
/// （BUG-061 判据：要失败，但不要静默失败）。引擎把它**原样**回投给 UI
/// （`EngineState.guardError`），于是用户看到的不是笼统的"引擎无响应"，
/// 而是麦克风侧的真实原因。
class GuardStartResult {
  const GuardStartResult.ok() : message = null;
  const GuardStartResult.failed(this.message);

  /// null = 成功；非 null = 失败原因（直接给用户看）。
  final String? message;

  bool get ok => message == null;
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

  /// 「启动正在进行中」——从 `start()` 进入取流 await 起，到拿到流（或失败）为止。
  ///
  /// 🔴 R97（R88-AUD-03）：这个标志的唯一用途是让 [stop] 知道「现在停止会落在
  /// 取流窗口里」。窗口内 `_sub` 还是 null、`_running` 还是 false ⇒ 旧实现的
  /// `stop()` 会**什么都没做**（取消一个 null 订阅 + `isRecording()` 还是 false），
  /// 随后 `start()` 恢复执行把 `_running` 置回 true ⇒ **用户已经关了，麦克风还在采**，
  /// 而且引擎侧 `guardEnabled=false` 与 `guard.isRunning=true` 自相矛盾。
  bool _starting = false;

  /// 取流窗口内收到过停止请求 —— 拿到流之后必须**立刻放弃**，不得挂监听。
  bool _stopRequestedWhileStarting = false;

  final _events = StreamController<SoundEvent>.broadcast();
  final _levels = StreamController<double>.broadcast();

  /// 采流异常（麦克风被抢占 / 录音器崩溃）的广播流。
  ///
  /// 为什么要**单独一条流**：`events` 的消费者只处理"检测到声音"，把错误
  /// 混进去会让"出错"被当成"一次声音事件"，反而触发一堆动作。
  /// 此前这里只把 `_running` 置 false —— 流一断守卫就**悄悄停了**：
  /// UI 下次刷新只看到 `guardActive:false`，既没有原因也没有审计
  /// （"失败不可见"，BUG-061 判据）。现在由引擎订阅本流写审计并回投原因。
  final _errors = StreamController<Object>.broadcast();
  Stream<Object> get errors => _errors.stream;

  /// 实时电平（dBFS，供 UI 电平表）。
  Stream<double> get levels => _levels.stream;
  Stream<SoundEvent> get events => _events.stream;

  bool _running = false;
  bool get isRunning => _running;

  /// 启动守卫。必须在前台/带麦克风前台服务的上下文中调用。
  ///
  /// ⚠️ **不再用 `_recorder.hasPermission()` 做准入判定**（真机取证结论）：
  /// `record_android` 的 `PermissionManager.hasPermission()` 第一句就是
  /// `if (activity == null) { resultCallback.onResult(false); return }`
  /// （`record_android-2.2.0/.../permission/PermissionManager.kt:33-36`）。
  /// 本方法**只**运行在 `flutter_background_service` 的引擎隔离里 —— 那里
  /// 没有 Activity，于是该判定**恒为 false**，与系统实际授权无关。
  ///
  /// 实证（MI MAX 2 / API 25，`RECORD_AUDIO: granted=true`）：
  /// 审计表里留下 `guard · start · failed · 麦克风权限被拒` —— 用户点了开关、
  /// 系统权限也是开着的，守卫却起不来，且 UI 只报"引擎无响应"。
  ///
  /// 现在改为**直接尝试取流**：权限真的没给，`startStream` 会抛，异常文本
  /// 就是真实原因（比一句编造的"权限被拒"有用）。这也让 `_running` 的语义
  /// 变成"**确实拿到流了**"，而不是"我们打算开始"。
  Future<GuardStartResult> start(SoundTrigger cfg) async {
    if (_running) return const GuardStartResult.ok();

    // 🔴 R97（R88-AUD-03）：进入取流窗口前先立「启动中」旗，让并发到达的
    // [stop] 能把「停止」这件事**记住**（见 `_stopRequestedWhileStarting`）。
    _starting = true;
    _stopRequestedWhileStarting = false;

    // 16kHz 单声道 PCM16 足够做能量检测且功耗低。
    final Stream<Uint8List> stream;
    try {
      stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.mic),
      ));
    } on Object catch (e) {
      // ⚠️ 失败时 `_running` 必须是 false。旧实现先置 `true` 再取流，
      // 取流抛异常后 `_running` 停在 true ⇒ `guard.isRunning` 为真、
      // 引擎回投 `guardActive:true` ⇒ **UI 报"守卫运行中"，实际一个字节都没采**
      // （"成功不得被误报"，BUG-073 同类）。
      _starting = false;
      _running = false;
      return GuardStartResult.failed('麦克风启动失败：$e');
    }
    _starting = false;

    // 🔴 R97（R88-AUD-03）：取流窗口内被要求停止 ⇒ **不许**置 `_running`、
    // 不许挂监听，并把刚拿到的流立刻释放（否则原生录音器会一直采）。
    // 这是本缺陷最要命的一条：旧实现无条件往下走，于是「关了还在采」。
    if (_stopRequestedWhileStarting) {
      _stopRequestedWhileStarting = false;
      await _releaseRecorderQuietly();
      return const GuardStartResult.failed('启动完成时已被关闭请求取消（未开始采音）');
    }
    _running = true;

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
      // BUG-131：采流出错时**原生录音器必须一并收掉**。
      //
      // 旧实现只置 `_running = false` 再广播错误 —— `record` 插件的原生会话
      // （麦克风句柄 / 前台服务通道）留在原地：麦克风指示灯继续亮、系统麦克风
      // 被本应用长期占用；部分机型在旧会话未释放时 `startStream` 直接失败
      // ⇒ 表现为"守卫关了再也开不起来"，而 UI 只会说"引擎无响应"。
      //
      // `stop()` 的第一句就是同步落 `_running = false`，且自带"取消订阅 →
      // 有界停止录音器"的分层保证，从 `onError` 里调用它是安全的
      // （在 onError 内取消自身订阅是 Dart 允许的操作）。
      unawaited(stop());
      if (!_errors.isClosed) _errors.add(e);
    });
    return const GuardStartResult.ok();
  }

  /// 停止守卫。
  ///
  /// ⚠️ **`_running = false` 必须是本方法的第一个语句** —— 顺序在这里是**语义**，
  /// 不是风格。旧实现把它放在 `await _recorder.stop()` **之后**：
  /// `record` 插件的 `stop()` 在部分机型/版本上不回调（真机 MI MAX 2 / API 25
  /// 表现为守卫**开了关不掉**），于是 `_running` 永远停在 true ⇒
  /// `guard.isRunning` 为真 ⇒ 引擎回投 `guardActive:true` ⇒ UI 等
  /// `guardActive:false` 3 秒超时 ⇒ 用户看到"引擎无响应"、开关弹回。
  ///
  /// 现在分三层保证"停止"这件事一定完成：
  /// 1. 先落 `_running = false`（同步，不可能被打断）；
  /// 2. 取消订阅（纯 Dart，不依赖插件）；
  /// 3. 再去动录音器，且**每一步都带超时** —— 插件不回调也不会拖住调用方。
  /// 清理失败不改变"已停止"这一事实：宁可留一个需要 GC 的原生句柄，
  /// 也不能让 UI 永远卡在"运行中"。
  Future<void> stop() async {
    // 🔴 R97（R88-AUD-03）：停止请求若落在 `start()` 的取流窗口里，此刻
    // `_sub == null`、`_running == false` ⇒ 下面的清理**全是空操作**，
    // 随后 `start()` 恢复执行会把 `_running` 置回 true。因此先把这次停止
    // **记在旗子上**，由 `start()` 在拿到流之后自行放弃并释放录音器。
    if (_starting) _stopRequestedWhileStarting = true;
    _running = false;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    await _releaseRecorderQuietly();
  }

  /// 尽力释放原生录音器（**不抛、不拖**）：状态由调用方负责。
  ///
  /// 抽出来是因为现在有**两个**调用点（正常停止 / 启动窗口内被取消），
  /// 两处的纪律完全一致：宁可留一个等 GC 的句柄，也不能让 UI 卡在「运行中」。
  Future<void> _releaseRecorderQuietly() async {
    try {
      if (await _recorder.isRecording().timeout(const Duration(seconds: 2))) {
        await _recorder.stop().timeout(const Duration(seconds: 2));
      }
    } on Object {
      // 状态自愈：超时 / 插件异常都不影响"已停止"。
    }
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
    await _errors.close();
  }
}
