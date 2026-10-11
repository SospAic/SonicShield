import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db/app_database.dart';
import '../data/repositories/api_config_store.dart';
import '../data/repositories/counter_plan_store.dart';
import '../data/repositories/log_repository.dart';
import '../data/repositories/occurrence_repository.dart';
import '../data/repositories/task_repository.dart';
import '../domain/models/action.dart';
import '../domain/models/task.dart';
import '../domain/models/tts_voice.dart';
import '../services/background_service_manager.dart';
import '../services/counter_plan_service.dart';
import '../services/deepseek_service.dart';
import '../services/holiday_update_service.dart';
import '../services/online_tts_client.dart';
import '../services/playback_service.dart';
import '../services/tts_service.dart';
import '../services/neural_tts.dart';

/// 全局单例数据库（main 阶段 open；UI 层只读句柄）。
final databaseProvider = FutureProvider<AppDatabase>((_) => AppDatabase.open());

/// `SharedPreferences`（v2.0）：外部接口配置、反击计划持久化共用同一实例。
final sharedPrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

/// 外部 AI / 在线语音接口配置。
final apiConfigStoreProvider = FutureProvider<ApiConfigStore>((ref) async =>
    ApiConfigStore(await ref.watch(sharedPrefsProvider.future)));

/// DeepSeek 一键生成服务（含默认 http.Client）。
final deepseekServiceProvider = FutureProvider<DeepSeekService>((ref) async {
  final cfg = await ref.watch(apiConfigStoreProvider.future);
  return DeepSeekService(client: http.Client(), config: cfg);
});

/// 统一 TTS 入口（v2.0）：供设置页「试听」按音色走系统 TTS / 在线语音 / 神经 TTS。
///
/// 与 `main.dart` / `background_engine.dart` 的设备层装配同源：都是把
/// 「FlutterTts + 在线客户端 + 神经引擎 + 播放器」原语注入 [TtsService]，
/// 决策逻辑仍留在可测的 `tts_service.dart`。装配本身不触碰任何插件——只在
/// 真正 `say()` 时才拉起平台通道，因此宿主 `pump` 阶段是安全的。
///
/// 神经引擎是长生命周期单例：首次 `speak` 时才把模型资产拷贝到私有目录并
/// 构造原生句柄（[NeuralTtsEngine.ensureLoaded]），失败只返回 false、由
/// [TtsService] 回落系统音色，App 永不因此崩溃。
final _neuralTts = NeuralTtsEngine();

final ttsServiceProvider = FutureProvider<TtsService>((ref) async {
  final cfg = await ref.watch(apiConfigStoreProvider.future);
  final playback = PlaybackService();
  return TtsService(
    speakSystem: (text, volume, match) => _speakSystemTts(text, volume, match),
    speakNeural: _neuralTts.speak,
    speakOnline: (text, volume, voiceName) async {
      // 选通路（Edge 免 Key WebSocket / Azure REST）由 `buildOnlineTtsClient`
      // 统一决策；返回 null = 未配置或端点不可用，直接判失败、不发请求。
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
          play: (path, vol) async => (await playback.play(
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
    },
  );
});

/// 系统 TTS（离线）试听：音量/语言/按关键词猜音色后喊话。
///
/// 与 `main.dart` 的 `_speakSystemTts` 同一策略（超时保护 + 音色匹配失败
/// 视为降级而非错误）；异常如实上抛，由 [TtsService] 收敛成失败结果。
Future<void> _speakSystemTts(
    String text, double volume, List<String> match) async {
  final tts = FlutterTts();
  try {
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
        // 音色匹配是增强：失败交给系统默认音色。
      }
    }
    // ★ 离线播报「没声音」的根因修复：`speak` 在 Android/iOS 上**默认立即返回**
    //   （原生仅在 `awaitSpeakCompletion && QUEUE_FLUSH` 时才挂起 result），于是
    //   下面 finally 里的 `stop()` 会把刚排队的朗读**当场取消**。开启「等朗读完成」
    //   后 speak 真正等到 `onDone`，stop() 变成无害清理（默认 queueMode 即
    //   QUEUE_FLUSH，满足前提）。
    await tts.awaitSpeakCompletion(true).timeout(const Duration(seconds: 3));
    // 朗读预算按字数估（中文约 4 字/秒）+ 8s 余量，夹在 15..120s。
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

/// 反击计划持久化。
final counterPlanStoreProvider = FutureProvider<CounterPlanStore>((ref) async =>
    CounterPlanStore(await ref.watch(sharedPrefsProvider.future)));

/// 中国节假日**一键更新**（联网）：默认 DeepSeek 之外的独立 http 通道。
final holidayUpdateServiceProvider =
    FutureProvider<HolidayUpdateService>((ref) async =>
        HolidayUpdateService(client: http.Client()));

/// 反击计划编排服务（本机 UI / 远程共用同一通路）。
final counterPlanServiceProvider =
    FutureProvider<CounterPlanService>((ref) async {
  final tasks = await ref.watch(taskRepoProvider.future);
  final assets = await ref.watch(assetRepoProvider.future);
  final store = await ref.watch(counterPlanStoreProvider.future);
  return CounterPlanService(
    tasks: tasks,
    store: store,
    resolveAudioIds: (ids) async =>
        resolvePresetAudioIds(await assets.listAll(), ids),
    replan: () => BackgroundServiceManager.instance.replan(),
  );
});

final taskRepoProvider = FutureProvider<TaskRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return TaskRepository(db);
});

final occurrenceRepoProvider =
    FutureProvider<OccurrenceRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return OccurrenceRepository(db);
});

final logRepoProvider = FutureProvider<LogRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return LogRepository(db);
});

/// 本月夜间豁免次数（v1.9，docs/20 §8.2 约束 2：不得静默生效）。
///
/// 独立成 provider 而不是在设置页 `initState` 里直接查库，有两个原因：
/// 1. 页面**只消费**结果，不关心怎么算；
/// 2. **widget 测试必须能把它换掉** —— 真实 sqflite 往返跑在 `FakeAsync` 里
///    会留下未完成的锁超时 `Timer`，让整页用例连带失败（见
///    `flutter-widget-test-harness` 技能第 ③ 类假故障）。
///    测试里 `overrideWith((ref) async => 0)` 即可，无需打桩数据库。
///
/// ⚠️ **刻意不加 `autoDispose`**：`autoDispose` 的 provider 在最后一个监听者
/// 离开时会走 `Timer(Duration.zero)` 延迟销毁；在 `FakeAsync` 里这个零延时
/// Timer 常常来不及被 elapse，于是**任何渲染过设置页的用例**都可能在收尾时
/// 判「A Timer is still pending」（实测：`router_test` RTR-06 因它变红）。
/// 新鲜度由设置页在进入时 `ref.invalidate` 保证，不依赖自动销毁。
final quietExemptCountProvider = FutureProvider<int>((ref) async {
  final repo = await ref.watch(logRepoProvider.future);
  final now = DateTime.now();
  return repo.countQuietExemptSince(DateTime(now.year, now.month));
});

/// 夜间豁免「例外清单」候选：所有**带任务级显式设置**（`quietExempt != null`）的任务
/// （v79，主开关默认值 + 任务级双向覆盖）。
///
/// 这里只筛「是否显式设置过」，**不筛**是否与当前主开关偏离 —— 偏离与否取决于
/// **实时**的主开关取值（开启时"强制不豁免"才是例外，关闭时反之），
/// 由设置页按当时的 `enabled` 再过滤一次（`t.quietExempt != enabled`）。
/// 这样主开关一变动，清单无需重查库即可正确重算。
///
/// 同 [quietExemptCountProvider]：**刻意不加 `autoDispose`**（理由见上）。
final quietExemptOverrideTasksProvider = FutureProvider<List<Task>>((ref) async {
  final repo = await ref.watch(taskRepoProvider.future);
  final all = await repo.listAll();
  return all.where((t) => t.quietExempt != null).toList();
});

/// 全局执行总开关的「例外清单」：所有**开启强制例外**（`forceRun == true`）的任务
/// （v79，docs/20 §9）。暂停期间这些任务照常执行，因此设置页必须在总开关下
/// **显式列出**，避免"以为全停了、其实还有几条在响"。
///
/// 同 [quietExemptCountProvider]：**刻意不加 `autoDispose`**（理由见上）。
final forceRunTasksProvider = FutureProvider<List<Task>>((ref) async {
  final repo = await ref.watch(taskRepoProvider.future);
  final all = await repo.listAll();
  return all.where((t) => t.forceRun).toList();
});

/// 音源仓储（音源库界面的**唯一**数据入口：列表/批量导入/删除都走它，
/// 界面不再直接持有 `db` —— 否则批量写入与原子性无从复用）。
final assetRepoProvider = FutureProvider<AssetRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return AssetRepository(db);
});

/// 任务列表流（数据库层主动刷新；简单起见以 ref.invalidate 触发）。
final taskListProvider =
    FutureProvider.autoDispose<List<TaskWithMeta>>((ref) async {
  final repo = await ref.watch(taskRepoProvider.future);
  final occ = await ref.watch(occurrenceRepoProvider.future);
  final tasks = await repo.listAll();
  final now = DateTime.now();
  // P2-12：一次 GROUP BY 拿到**所有**任务的最近 pending，替代此前「逐任务各查
  // 一次 `pendingWithin` + 全局 limit 200」的 N+1 —— 后者任务/计划一多既慢，
  // 又会因全局截断让部分任务永远显示不出「下次触发」。
  final next = await occ.nextPendingByTask(now, now.add(const Duration(days: 7)));
  return [
    for (final t in tasks)
      TaskWithMeta(task: t, nextFireAt: next[t.id]),
  ];
});

class TaskWithMeta {
  const TaskWithMeta({required this.task, this.nextFireAt});

  final Task task;
  final DateTime? nextFireAt;
}

/// 引擎状态流。
final engineStateProvider = StreamProvider((ref) {
  return BackgroundServiceManager.instance.state;
});

/// 日志流。
final logListProvider =
    FutureProvider.autoDispose<List<Map<String, Object?>>>((ref) async {
  final repo = await ref.watch(logRepoProvider.future);
  return repo.recent(limit: 200);
});
