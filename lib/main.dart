import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/db/app_database.dart';
import 'domain/models/action.dart';
import 'remote/call_service.dart';
import 'remote/endpoint_service.dart';
import 'remote/remote_store.dart';
import 'remote/script_executor.dart';
import 'services/background_service_manager.dart';
import 'services/native_bridge.dart';
import 'services/notification_service.dart';
import 'services/playback_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // 创建通知渠道（必须在启动前台服务之前——flutter_background_service
  // 指定自定义 channel id 时不会自动创建，缺失会导致 FGS 崩溃）。
  await NotificationService.instance.createServiceChannel();
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
  // 韧性（BUG-026 教训）：这里是 `runApp` **之前**的 await 链，任何一处
  // 抛出都会让 `runApp` 永不执行 —— 表现为整屏白屏，用户完全无法自救
  // （远程模块是可选的附加能力，不该有能力让主应用起不来）。
  // 因此逐步隔离：远程装配失败只降级该模块，不阻断启动。
  try {
    await _wireRemoteEndpoint();
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
  await NotificationService.instance.ensure();
  runApp(const ProviderScope(child: SonicShieldApp()));
}

/// 远程端点启动装配（v1.6.1）。
///
/// 修复两个此前从未被端到端验证暴露的缺陷：
/// 1. **执行能力未注入（BUG-015）**：`playHandler`/`ttsHandler`/
///    `vibrateHandler` 全库无赋值 → 远程 sound.play、指令组 play/tts/vibrate
///    步骤与 PTT 播放全部空转（只写审计、不出声）。此处统一注入，
///    与引擎侧 `runSingle` 使用同一套 PlaybackService / NativeBridge。
/// 2. **无自恢复（BUG-017）**：远程模块启用状态持久化在 `rc_enabled`，
///    但此前仅由「远程遥控」页的开关触发 `start()`，应用重启后端点
///    长期离线（收不到命令、无法自动接通）。此处按状态自动拉起。
Future<void> _wireRemoteEndpoint() async {
  final playback = PlaybackService();

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
    ..ttsHandler = (text, volume) async {
      final tts = FlutterTts();
      try {
        // 超时保护：无 TTS 引擎的平台 speak/setLanguage 可能永不回调。
        await tts.setVolume(volume).timeout(const Duration(seconds: 8));
        await tts.setLanguage('zh-CN').timeout(const Duration(seconds: 8));
        await tts.speak(text).timeout(const Duration(seconds: 15));
      } on Object {
        // 无 TTS 引擎平台静默降级（审计由调用方记录）。
      } finally {
        try {
          await tts.stop().timeout(const Duration(seconds: 3));
        } on Object {
          // 清理失败不影响主流程。
        }
      }
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

  final prefs = await SharedPreferences.getInstance();
  final store = RemoteStore(prefs);
  if (store.enabled && store.deviceId.isNotEmpty) {
    await RcEndpointService.instance.start(store, await AppDatabase.open());
  }
}
