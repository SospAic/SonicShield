import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/db/app_database.dart';
import 'data/repositories/api_config_store.dart';
import 'domain/models/action.dart';
import 'domain/models/tts_voice.dart';
import 'remote/call_service.dart';
import 'remote/endpoint_service.dart';
import 'remote/remote_store.dart';
import 'remote/script_executor.dart';
import 'services/background_service_manager.dart';
import 'services/native_bridge.dart';
import 'services/notification_service.dart';
import 'services/online_tts_client.dart';
import 'services/playback_service.dart';
import 'services/tts_service.dart';
import 'services/neural_tts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // 创建通知渠道（必须在启动前台服务之前——flutter_background_service
  // 指定自定义 channel id 时不会自动创建，缺失会导致 FGS 崩溃）。
  //
  // BUG-108：这是 `runApp` 之前**唯一**没有包 try/catch 的 await（同文件
  // 下方远程/后台两处都有降级注释）。插件在非 Android 平台或初始化异常时
  // 会直接抛出 ⇒ `runApp` 永不执行 ⇒ 整屏白屏且无法自救。
  // 渠道创建失败最坏是通知不可用，不该有能力拖死主应用。
  try {
    await NotificationService.instance.createServiceChannel();
  } on Object catch (e) {
    // ignore: avoid_print
    print('[sonic_shield] notification channel failed (降级启动): $e');
  }
  // 远程指令组的「终止执行」通知按钮回调（docs/14 §5）。
  RcScriptExecutor.registerStopHandler(NotificationService.instance.plugin, () {
    RcScriptExecutor.instance.stop();
  });
  // 视频通话的 store 注入（ICE 候选发送需要，docs/16 §4）。
  CallService.bindStore(() async {
    final prefs = await SharedPreferences.getInstance();
    return RemoteStore(prefs);
  });
  // 通话状态镜像：把端点的**已解密事件流**接给通话服务（BUG-050）。
  //
  // 修之前：`rc.call` / `rc.call.missed` 在 App 内**无人消费**
  // （只有 `tool/` 的桌面 E2E 工具看得到）→ 主叫看不到"对方振铃中"，
  // 也收不到被叫判定的"未接"。
  CallService.instance.attach(RcEndpointService.instance.events);
  // 远程端点：注入执行能力 + 按启用状态自恢复（见下方说明）。
  //
  // 韧性（BUG-026 教训）：`runApp` 之前的 await 链任何一处抛出都会让
  // `runApp` 永不执行 —— 表现为整屏白屏，用户完全无法自救
  // （远程模块是可选的附加能力，不该有能力让主应用起不来）。
  //
  // ARCH-04：这里只做**同步的 handler 注入**（纯内存装配，不触网）；
  // 真正可能长时间阻塞的 `start()`（内部 `await client.connect()`，
  // mqtt_client 默认 5s 超时）移到 `runApp` 之后的
  // [_startRemoteEndpointAfterFirstFrame] —— 首帧不再被可选模块的
  // 网络可达性阻塞（broker 不可达时最多白屏约 5s 的形状就此消除）。
  try {
    _wireRemoteEndpointHandlers();
  } on Object catch (e) {
    // ignore: avoid_print
    print('[sonic_shield] remote wiring failed (降级启动): $e');
  }
  // 后台服务引擎先注册（不自动启动，由用户显式开启 —— 见 docs/05）。
  try {
    await BackgroundServiceManager.instance.init();
  } on Object catch (e) {
    // ignore: avoid_print
    print('[sonic_shield] background service init failed (降级启动): $e');
  }
  try {
    await NotificationService.instance.ensure();
  } on Object catch (e) {
    // ignore: avoid_print
    print('[sonic_shield] notification init failed (降级启动): $e');
  }
  runApp(const ProviderScope(child: SonicShieldApp()));
  // ARCH-04：首帧之后再在后台启动远程模块（fire-and-forget）。
  // 失败只影响远程功能（回执/指令/PTT/通话信令），不影响主应用。
  unawaited(_startRemoteEndpointAfterFirstFrame());
}

/// 远程端点的**执行能力注入**（同步装配，不触网）。
///
/// 从 `_wireRemoteEndpoint` 拆出（ARCH-04）：注入必须在 `runApp` 之前完成
/// —— 首帧之后随时可能有远程事件 / PTT 帧 / `rc.call` 进来，handler 为空
/// 等于静默空转（只写审计、不出声，正是 BUG-015 的形状）。
/// 注入本身是纯内存操作（闭包与级联赋值），没有任何 await。
///
/// 修复两个此前从未被端到端验证暴露的缺陷：
/// 1. **执行能力未注入（BUG-015）**：`playHandler`/`ttsHandler`/
///    `vibrateHandler` 全库无赋值 → 远程 sound.play、指令组 play/tts/vibrate
///    步骤与 PTT 播放全部空转（只写审计、不出声）。此处统一注入，
///    与引擎侧 `runSingle` 使用同一套 PlaybackService / NativeBridge。
/// 2. **无自恢复（BUG-017）**：远程模块启用状态持久化在 `rc_enabled`，
///    但此前仅由「远程遥控」页的开关触发 `start()`，应用重启后端点
///    长期离线（收不到命令、无法自动接通）。启动按状态自动拉起
///    （见 `_startRemoteEndpointAfterFirstFrame`）。
void _wireRemoteEndpointHandlers() {
  final playback = PlaybackService();

  // v2.0：语音播报统一走 `TtsService` —— 按音色 id 决定用**系统 TTS**（离线）
  // 还是**在线语音**（含东北话，需配置 Key）。两条路都在这里装配成闭包，
  // 于是"选哪条路、失败报什么"的决策留在可测的 `tts_service.dart`，
  // 本文件只承担平台胶水（FlutterTts 实例 / 临时文件 / 播放器 / 神经引擎）。
  // 神经引擎为长生命周期单例：首次 speak 才把模型资产落到私有目录并构造原生句柄。
  //
  // ARCH-04：`speakOnline` 里的 prefs 延迟到**调用时**取（`getInstance()`
  // 命中进程内缓存，开销可忽略）—— 注入阶段因此不需要 await，
  // 首帧不被 SharedPreferences 的平台往返阻塞。
  final neuralTts = NeuralTtsEngine();
  final tts = TtsService(
    speakSystem: _speakSystemTts,
    speakNeural: neuralTts.speak,
    speakOnline: (text, volume, voiceName) async {
      final prefs = await SharedPreferences.getInstance();
      return _speakOnlineTts(
          text, volume, voiceName, ApiConfigStore(prefs), playback);
    },
  );

  RcEndpointService.instance
    ..playHandler = (path, volume, durationMs, {loop = false}) async {
      final r = await playback.play(
        path: path,
        channel: AudioChannel.media,
        volume: volume,
        maxDurationMs: durationMs,
        loopFill: loop,
      );
      return r.ok;
    }
    // v2 流式对讲：端点"边收边放"的播放会话开缝（`PttStreamSink`）。
    // 用同一套 PlaybackService ⇒ 与端点静音（远程停止）接线一致。
    ..pttStreamOpener = playback.openPttStream
    // v2.0：携带 `voiceId`。`TtsService.say` 内部把"空文本/在线未配置/委托抛错"
    // 一律收敛成失败结果，**不向外抛** —— 指令组执行链路不会因一次播报失败而中断。
    // **返回是否真的发声**：控制端据此得到"喊话成功/失败"的真实回执。
    // ⚠️ 必须用**块体**（不能写成 `=> ...`）：箭头体的 body 是 expression，
    // 而级联也是 expression —— 不括起来会把后面的 `..vibrateHandler` 吃进来
    // （见下方 `..vibrateHandler` 处的注记）。
    ..ttsHandler = (text, volume, {String voiceId = ''}) async {
      final r = await tts.say(text, voiceId: voiceId, volume: volume);
      return r.ok;
    }
    // ⚠️ 箭头函数**必须加括号**：`..a = (x) => f(x)` 的 body 是 `expression`，
    // 而级联也是 expression —— 不括起来，`=>` 会一路把后面的 `..vibrateActionHandler`
    // 吃成 `f(x)..vibrateActionHandler = ...`（实测报错："setter 未定义于 Future<void>"，
    // 完全指不到真正的原因）。
    ..vibrateHandler = ((pattern) => NativeBridge.vibrate(pattern))
    // v1.9：随机/持续振动步骤转交**引擎隔离**的 VibrateSession。
    // 不在本 isolate 直接下发：分片续发、`vibrate.stop`、低电量降级都只在
    // 引擎里（见 `background_engine` 的 `vibrateStep` 监听处注记）。
    // 引擎未运行时返回失败，端点据此写 skipped 审计，不静默成功。
    ..vibrateActionHandler = (({
      required ActionConfig action,
      required String occurrenceId,
    }) =>
        BackgroundServiceManager.instance
            .runVibrateStep(action: action, occurrenceId: occurrenceId));
}

/// 远程端点的**启动**（`runApp` 之后的后台任务，ARCH-04）。
///
/// 读启用状态并按状态自恢复（BUG-017）：`rc_enabled` + `deviceId` 齐全才
/// `start()`。`start()` 内部 `await _connect()` → `client.connect()`
/// （mqtt_client 默认 5s 超时）—— broker 不可达 / DNS 慢 / TLS 卡住时
/// 最多耗时约 5s。这正是**不能**放在 `runApp` 之前的原因（ARCH-04：
/// 可选模块不应有能力推迟首帧）。
///
/// 失败只降级远程功能：`_connect` 内部 catch 后 `_scheduleReconnect`，
/// 运行期重连在事件循环里异步进行；本函数的 try/catch 兜住的是
/// "连 store 都没读成"这类装配期异常。
Future<void> _startRemoteEndpointAfterFirstFrame() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (store.enabled && store.deviceId.isNotEmpty) {
      await RcEndpointService.instance.start(store, await AppDatabase.open());
    }
  } on Object catch (e) {
    // ignore: avoid_print
    print('[sonic_shield] remote start failed (降级启动): $e');
  }
}

/// 系统 TTS（离线）播报：音量 + 语言 + **按关键词猜音色** + 喊话。
///
/// ## 两条与旧实现的差异
///
/// 1. **不再吞掉异常**：旧实现把 `speak` 的失败 catch 掉当没发生，端点照样写
///    success 审计（"喊了"和"没喊成"在日志里长得一样）。现在异常如实上抛，
///    由 `TtsService` 收敛成失败结果。
/// 2. **音色可挑**：`getVoices()` 拿到的语音列表交给可测的
///    `TtsVoices.pickSystemVoice` 匹配；**匹配不到不失败**（交给系统默认音色）——
///    机型上装没装对应引擎不归我们管，这属于降级不属于错误。
Future<void> _speakSystemTts(
    String text, double volume, List<String> match) async {
  final tts = FlutterTts();
  try {
    // 超时保护：无 TTS 引擎的平台 speak/setLanguage 可能永不回调。
    await tts.setVolume(volume).timeout(const Duration(seconds: 8));
    await tts.setLanguage('zh-CN').timeout(const Duration(seconds: 8));
    if (match.isNotEmpty) {
      try {
        final voices = await tts.getVoices.timeout(const Duration(seconds: 8));
        final picked = TtsVoices.pickSystemVoice(voices, match);
        if (picked != null) {
          await tts.setVoice(picked).timeout(const Duration(seconds: 8));
        }
      } on Object {
        // 音色匹配是**增强**：拿不到语音列表/设置失败都不该让播报失败。
      }
    }
    // ★ 离线播报「没声音」的根因修复：`speak` 在 Android/iOS 上**默认立即返回**
    //   （原生仅在 `awaitSpeakCompletion && QUEUE_FLUSH` 时才挂起 result），于是
    //   下面 finally 里的 `stop()` 会把刚排队的朗读**当场取消** —— 离线语音因此
    //   几乎听不到。开启「等朗读完成」后 speak 真正等到 `onDone`，stop() 变成
    //   无害清理（插件默认 queueMode 即 QUEUE_FLUSH，满足前提）。
    await tts.awaitSpeakCompletion(true).timeout(const Duration(seconds: 3));
    // 朗读预算按字数估（中文约 4 字/秒）+ 8s 余量，夹在 15..120s：
    // 既不让长文本被 15s 截断，也不让「无引擎」时无限等。
    final secs = (8 + text.length ~/ 4).clamp(15, 120).toInt();
    await tts.speak(text).timeout(Duration(seconds: secs));
  } finally {
    try {
      await tts.stop().timeout(const Duration(seconds: 3));
    } on Object {
      // 清理失败不影响主流程。
    }
  }
}

/// 在线语音（含东北话）播报的平台胶水：只提供"临时文件 + 播放器"两个原语，
/// 编排逻辑（合成→落盘→播放→清理）在可测的 `OnlineTtsSpeaker` 里。
///
/// 返回**是否真的发声**（`false` 覆盖：未配置 / 合成失败 / 播放失败）。
Future<bool> _speakOnlineTts(
  String text,
  double volume,
  String voiceName,
  ApiConfigStore cfg,
  PlaybackService playback,
) async {
  final client = buildOnlineTtsClient(
    endpoint: cfg.ttsEndpoint,
    apiKey: cfg.ttsApiKey,
  );
  if (client == null) return false;
  final speaker = OnlineTtsSpeaker(
    client: client,
    sink: TtsAudioSink(
      writeTemp: (bytes, ext) async {
        final dir = await getTemporaryDirectory();
        final f = File(
            '${dir.path}/tts_${DateTime.now().microsecondsSinceEpoch}.$ext');
        await f.writeAsBytes(bytes, flush: true);
        return f.path;
      },
      deleteTemp: (path) => File(path).delete(),
      play: (path, vol) async =>
          (await playback.play(
        // `play` 会 await 整个播放窗口，因此随后的删除是安全的。
        path: path,
        channel: AudioChannel.media,
        volume: vol,
        maxDurationMs: 60000,
      ))
              .ok,
    ),
  );
  try {
    return await speaker.speak(text, voiceName, volume);
  } finally {
    client.close();
  }
}
