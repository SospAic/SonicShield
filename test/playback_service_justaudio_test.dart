/// `PlaybackService` 的**真实业务路径**行为锁 —— 第 46 轮新增（判据第六代推广）。
///
/// ## 为什么需要它
///
/// `test/cov_services_test.dart` 的 PB 组只能锁到 `play()` **第一个 await 之前**
/// 的同步登记（`playback_service.dart:119`）—— 宿主上再往下走，
/// `just_audio` 的 `_pluginPlatform.init(...)` 抛 `MissingPluginException`，
/// `durationCompleter` 永不完成 ⇒ `play()` **挂起**。
/// 于是「取会话 → 载入 → 设音量 → 循环填充 → 起播 → 随机时长到点收尾 →
/// 渐强/淡入/淡出 → 多轨混音」整条链路**一次都没被执行过**（76 行零覆盖）。
///
/// 这正是 `docs/17 §75.2` 判据第六代的形状：
/// **同一个域里只剩源码文本锁 ⇒ 先问这一域的平台依赖能不能做成替身。**
/// 这里是 `just_audio`；替身 = `test/support/just_audio_stub.dart`。
///
/// ⚠️ 本文件是 `test()` 而非 `testWidgets()`：`play()` 内部用真实
/// `Future.delayed` 轮询（`_waitPlayWindow` 50ms/tick），不是 fake-async，
/// 因此**不需要** `tester.runAsync`。也正因如此，每个用例都设了硬上界
/// （`Timeout`），防止替身漏掉某个方法名时整轮门禁被吊死。
///
/// ⚠️ 所有 `play` 用例的 `maxDurationMs` 都刻意取小（≤ 400ms），
/// 让"文件时长 > 目标时长"与"文件时长 < 目标时长"两条分支都能在毫秒级跑完。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart'
    show LoopModeMessage;
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/services/playback_service.dart';

import 'support/just_audio_stub.dart';

/// 宿主**墙钟上界**（⚠️ 只作"反挂死"护栏，**不是时长判据**）。
///
/// `play()` 返回的 `playedMs` 是 Stopwatch 实测的
/// **「前置 await（取音频会话 → 载入 → 设音量/循环 → 起播）+ 等待窗口」总和**，
/// 不是纯窗口时长。门禁在 `--coverage` + 整层默认并发下，插桩与本机 CPU 争用
/// 会把每个 `Future.delayed` 拉长数倍 —— 2026-10-04 门禁实测：target=300ms 的
/// 用例返回 **1550ms**（5.2×），PA-02/PA-03 的旧上界 `<1000` 因此偶发假红。
///
/// 纪律：**时长判据只用下界**（`>= target` 那侧 —— 证明确实等了窗口，而不是
/// 立刻返回 / 取了 maxDurationMs(0)）；上界只留一个足够宽的护栏，真正的
/// "挂死"由用例默认超时（30s）兜底。放松上界**不放宽**任何业务判据。
const int _playWallCeilingMs = 8000;

void main() {
  // ★ 必须先初始化 binding：`AudioSession` 的**构造器**会调用
  //   `_channel.setMethodCallHandler(...)`（`audio_session/src/core.dart:150`），
  //   而 `MethodChannel.setMethodCallHandler` 在 binary messenger 就绪前会
  //   **断言失败**（`platform_channel.dart:589`）。纯 `test()` 文件默认不初始化
  //   binding ⇒ 13 条用例在 `AudioPlayer()` 构造时全灭（第 46 轮实测）。
  //   这**不是** `tester.runAsync` 的场景：本文件不用 fake-async，
  //   `play()` 内部的 `Future.delayed` 走真实时钟。
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeJustAudio audio;

  setUp(() {
    audio = FakeJustAudio(fileDuration: const Duration(seconds: 5));
    audio.install();
    PlaybackService.resetRegistryForTest();
    addTearDown(() {
      PlaybackService.resetRegistryForTest();
      audio.uninstall();
    });
  });

  // ⚠️ 路径只是字符串：`setFilePath` 把路径交给**替身**，替身不读盘。
  //    所以这里不需要真实音频文件，也不会产生任何文件系统副作用。
  const p1 = 'cov_pa01_not_a_real_file.mp3';

  group('PA · PlaybackService 真实播放链路（just_audio 平台替身）', () {
    test('PA-01 正常播放：载入→设音量→起播→到点收尾，且循环模式最终回 off',
        () async {
      audio.fileDuration = const Duration(seconds: 2);
      final r = await PlaybackService().play(
        path: p1,
        channel: AudioChannel.media,
        volume: 0.4,
        maxDurationMs: 150,
      );

      expect(r.ok, isTrue, reason: '替身让整条链路跑通 ⇒ 必须报成功');
      expect(r.message, isNull);
      expect(r.playedMs, greaterThanOrEqualTo(100),
          reason: '到达 maxDurationMs 才收尾（不许提前返回）');

      // 平台侧真的收到了这四步 —— 证明显式调用链被执行过，不是常数。
      expect(audio.methods, containsAll(<String>['load', 'play', 'setVolume']));
      expect(audio.loadedUris.single, endsWith('cov_pa01_not_a_real_file.mp3'));
      // ⚠️ `volumes[0]` 是 just_audio **激活期**的音量恢复
      //    （`_setPlatformActive` 内 `await platform.setVolume(...)`，此刻是默认 1.0）；
      //    `playback_service` 设的目标音量是**最后**一次。
      expect(audio.volumes.first, closeTo(1.0, 1e-9),
          reason: '激活期先把播放器音量恢复为 1.0（插件自身行为，非本服务）');
      expect(audio.volumes.last, closeTo(0.4, 1e-9),
          reason: '服务设的目标音量必须真的落到平台上');
      // 非 loopFill：服务**不得**额外设置循环模式（平台上只有激活期那一次 off）。
      // （收尾的 `setLoopMode(off)` 排在 `await player.stop()` 之后，平台已切到 idle ⇒ 观测不到。）
      expect(audio.countOf('setLoopMode'), 1);
    });

    test('PA-02 maxDurationMs<=0 ⇒ 播完整段文件（target 取文件时长）', () async {
      audio.fileDuration = const Duration(milliseconds: 300);
      final r = await PlaybackService().play(
        path: p1,
        channel: AudioChannel.alarm,
        volume: 1.0,
        maxDurationMs: 0,
      );

      expect(r.ok, isTrue);
      expect(r.playedMs, greaterThanOrEqualTo(250),
          reason: 'target = 文件时长 300ms，不能取 maxDurationMs(0)');
      expect(r.playedMs, lessThan(_playWallCeilingMs),
          reason: '反挂死护栏（含前置 await，详见文件头说明）');
    });

    test('PA-03 文件时长未知（duration==null）⇒ 回落 maxDurationMs', () async {
      audio.fileDuration = null;
      final r = await PlaybackService().play(
        path: p1,
        channel: AudioChannel.media,
        volume: 0.7,
        maxDurationMs: 120,
      );

      expect(r.ok, isTrue);
      expect(r.playedMs, greaterThanOrEqualTo(80));
      expect(r.playedMs, lessThan(_playWallCeilingMs),
          reason: '反挂死护栏（不许挂到"文件自然结束"，但含前置 await；详见文件头）');
    });

    test('PA-04 loopFill ⇒ 先 setLoopMode(one) 填充，收尾复位 off', () async {
      audio.fileDuration = const Duration(milliseconds: 50);
      final r = await PlaybackService().play(
        path: p1,
        channel: AudioChannel.media,
        volume: 0.5,
        maxDurationMs: 220,
        loopFill: true,
      );

      expect(r.ok, isTrue);
      // 短音效（50ms）要被循环填充到 220ms，而不是 50ms 就结束。
      expect(r.playedMs, greaterThanOrEqualTo(180));
      // 观测序列：[0] = 激活期归位 off；[1] = loopFill 的 single-loop 填充。
      // ⚠️ 收尾的 `setLoopMode(off)`（playback_service.dart:167）**结构性观测不到**：
      //    它排在 `await player.stop()` 之后，此刻 `_platform` 已切到
      //    `_IdleAudioPlayer`（纯 Dart 无操作）⇒ 不经过插件接口。
      //    （已登记为"观测不到"而非"没执行"，见 docs/12 §79.5。）
      expect(audio.loopModes, <LoopModeMessage>[
        LoopModeMessage.off,
        LoopModeMessage.one,
      ], reason: 'loopFill 必须在起播前把循环模式设为 one（否则 50ms 音效 50ms 就结束）');
    });

    test('PA-05 rampUpMs ⇒ 从 5% 起线性渐强，终点兑现目标音量', () async {
      audio.fileDuration = const Duration(seconds: 2);
      final r = await PlaybackService().play(
        path: p1,
        channel: AudioChannel.alarm,
        volume: 0.8,
        maxDurationMs: 400,
        rampUpMs: 200,
      );

      expect(r.ok, isTrue);
      // [0] = 激活期恢复 1.0；[1] = 渐强的起点（playback_service.dart:130 的 volume*0.05）。
      expect(audio.volumes[1], closeTo(0.04, 1e-9));

      // ⚠️ `_rampUp` 是 **unawaited**（playback_service.dart:131），且它跑在播放窗口
      //    之外：窗口（400ms）与渐强（200ms）虽然标称同时起步，但渐强要排 40 个
      //    `Future.delayed`、窗口只排 8 个 —— 门禁在 `--coverage` + 整层默认并发下，
      //    前者的实际延迟被拉长得更多，窗口结束时渐强可能只爬到一半
      //    （2026-10-04 门禁实测末值 **0.363**，远未到 0.8）。
      //    判据要的是"**终点**兑现目标音量"，所以有界轮询到渐强末步真正落地再断言 ——
      //    确定性，且不放松任何业务判据（反而把"渐强真的爬到终点"锁得更死）。
      final rampDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (audio.volumes.last < 0.79 &&
          DateTime.now().isBefore(rampDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(audio.volumes.last, closeTo(0.8, 1e-9),
          reason: '_rampUp 末步 = 0.05 + 0.95 = 1.0 ⇒ 恰好目标音量');
      expect(audio.volumes.length, greaterThan(10), reason: '确实是"线性爬升"');
      // 渐强段（跳过激活期那一步）必须单调不减：睡眠唤醒场景骤降 = 把人吵醒。
      final ramp = audio.volumes.sublist(1);
      for (var i = 1; i < ramp.length; i++) {
        expect(ramp[i], greaterThanOrEqualTo(ramp[i - 1]));
      }
    });

    test('PA-06 fadeInMs ⇒ 普通淡入（不受渐强分支影响）', () async {
      audio.fileDuration = const Duration(seconds: 2);
      final r = await PlaybackService().play(
        path: p1,
        channel: AudioChannel.media,
        volume: 1.0,
        maxDurationMs: 400,
        fadeInMs: 200,
      );

      expect(r.ok, isTrue);
      // [0] = 激活期 1.0；[1] = 服务先设的目标音量 1.0；[2] = 淡入首步 = target * 1/20。
      expect(audio.volumes[1], closeTo(1.0, 1e-9));
      expect(audio.volumes[2], closeTo(0.05, 1e-9), reason: '淡入首步 = target * 1/20');
      expect(audio.volumes.last, closeTo(1.0, 1e-9));
    });

    test('PA-07 fadeOutMs ⇒ 结束前渐出到 0（不"啪"地掐断）', () async {
      audio.fileDuration = const Duration(seconds: 2);
      final r = await PlaybackService().play(
        path: p1,
        channel: AudioChannel.media,
        volume: 1.0,
        maxDurationMs: 160,
        fadeOutMs: 120,
      );

      expect(r.ok, isTrue);
      expect(audio.volumes.last, closeTo(0.0, 1e-9),
          reason: '_fadeOut 末步 = 0/20 = 0');
    });

    test('PA-08 stop() 打断 ⇒ 如实报失败（不是"播完了"）且循环复位', () async {
      // 窗口标称 60s、文件更长（600s）⇒ "提前打断"与"等满窗口"之间留出 60s 的
      // 判别余量：即便覆盖率插桩把每个 `Future.delayed` 拉长数倍，也不会把两者
      // 混为一谈（旧版 5s 窗口 + 固定 150ms 墙钟等待就栽在这里）。
      audio.fileDuration = const Duration(seconds: 600);
      final svc = PlaybackService();
      final fut = svc.play(
        path: p1,
        channel: AudioChannel.alarm,
        volume: 0.6,
        maxDurationMs: 60000,
      );

      // ⚠️ 不靠固定墙钟等待"前置步骤跑完" —— 覆盖率插桩 + 整层默认并发占满 CPU 时，
      //    前置 `AudioSession.configure` / `setFilePath` / `play` 会被拉长到未知毫秒数，
      //    固定 150ms 可能落在**起播之前**（于是压根没打断、等满窗口）。
      //    轮询到平台侧确实已起播再 stop —— 确定性，且业务语义不变（反而更准）。
      while (audio.countOf('play') == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await svc.stop();
      final r = await fut;

      expect(r.ok, isFalse,
          reason: '报成功会让控制端以为这段声音已正常播完（docs/17 §45 语义）');
      expect(r.message, contains('已终止'));
      expect(r.playedMs, lessThan(60000),
          reason: '停止后必须立刻收尾，不许等满 60s 窗口');
      // 停止路径同样不额外设置循环模式（收尾那次 off 排在 `player.stop()` 之后 ⇒ 观测不到）。
      expect(audio.countOf('setLoopMode'), 1);
    });

    test('PA-09 载入抛错 ⇒ 走 catch 分支，且登记表被 finally 清空', () async {
      audio.loadError = Exception('decode failed');
      final r = await PlaybackService().play(
        path: p1,
        channel: AudioChannel.media,
        volume: 0.5,
        maxDurationMs: 100,
      );

      expect(r.ok, isFalse);
      expect(r.message, contains('decode failed'));
      // finally 必须摘除登记（playback_service.dart:173）——
      // 否则远程「停止指令组」会永远握着一个已经死掉的实例。
      expect(await PlaybackService.stopAllPlaying(), 0,
          reason: '失败的播放不得残留在 _playing 登记表里');
    });

    test('PA-10 playSoundscape：多轨各自载入/循环/起播，收尾全部停止并释放',
        () async {
      audio.fileDuration = const Duration(milliseconds: 80);
      final r = await PlaybackService().playSoundscape(
        tracks: const <SoundscapeTrackInput>[
          SoundscapeTrackInput(path: 'cov_pa10_a.mp3'),
          SoundscapeTrackInput(path: 'cov_pa10_b.mp3', volume: 0.3),
        ],
        durationMs: 400,
        channel: AudioChannel.media,
        fadeOutMs: 240,
      );

      expect(r.ok, isTrue);
      expect(r.playedMs, greaterThanOrEqualTo(300));
      expect(audio.countOf('init'), 2, reason: '每轨一个独立 AudioPlayer');
      expect(audio.countOf('load'), 2);
      expect(audio.countOf('play'), 2);
      // 每轨 `p.stop()` 走 `_setPlatformActive(false)` ⇒ 各自把原生平台交还
      // （`just_audio` 文档：stop 即释放解码器）⇒ 两次 `disposePlayer`。
      expect(audio.countOf('disposePlayer'), 2,
          reason: '收尾必须把两轨的原生播放器都交还，不能只停不放');
      expect(audio.loadedUris[0], endsWith('cov_pa10_a.mp3'));
      expect(audio.loadedUris[1], endsWith('cov_pa10_b.mp3'));
      // 渐出后音量必须落到接近 0（这里按当前音量**逐步相乘**，故 < 0.05）。
      expect(audio.volumes.last, lessThan(0.05));
    });

    test('PA-11 stopSoundscape() ⇒ 提前打断等待窗口，仍如实报成功', () async {
      audio.fileDuration = const Duration(seconds: 30);
      final svc = PlaybackService();
      // 窗口标称 60s ⇒ 与"提前打断"之间留出 60s 判别余量（理由同 PA-08）。
      final fut = svc.playSoundscape(
        tracks: const <SoundscapeTrackInput>[
          SoundscapeTrackInput(path: 'cov_pa11.mp3'),
        ],
        durationMs: 60000,
        channel: AudioChannel.media,
        fadeOutMs: 0,
      );

      // ⚠️ 轮询到平台侧确实已起播（多轨是 `unawaited(p.play())`）再打断 —— 不再靠
      //    固定 300ms 墙钟：门禁实测那条固定等待被拉长后，"提前打断"根本没被驱动，
      //    playSoundscape 便一路等满窗口（旧版 5s）⇒ `playedMs < 2000` 假红。
      while (audio.countOf('play') == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      svc.stopSoundscape();
      final r = await fut;

      expect(r.ok, isTrue);
      expect(r.playedMs, lessThan(60000),
          reason: 'stopSoundscape 必须让 60s 等待窗口提前收尾（250ms 轮询），不许等满窗口');
    });

    test('PA-12 playSoundscape：只坏一轨 ⇒ 走 catch，两轨都被释放', () async {
      audio.fileDuration = const Duration(milliseconds: 80);
      audio.failLoadAt = 2; // 第二轨载入失败
      audio.loadThrow = Exception('第二轨已损坏');
      final r = await PlaybackService().playSoundscape(
        tracks: const <SoundscapeTrackInput>[
          SoundscapeTrackInput(path: 'cov_pa12_a.mp3'),
          SoundscapeTrackInput(path: 'cov_pa12_b.mp3'),
        ],
        durationMs: 400,
        channel: AudioChannel.media,
      );

      expect(r.ok, isFalse);
      expect(r.message, contains('第二轨已损坏'));
      expect(audio.countOf('init'), 2,
          reason: '两轨的播放器都已建出来 ⇒ catch 里必须逐个释放');
      expect(audio.countOf('play'), 0,
          reason: '坏轨之后不得继续起播（逐轨顺序执行）');
      // _mixStopped 必须复位，否则下一次混音一开播就被上一次的打断标志掐掉。
      final again = await PlaybackService().playSoundscape(
        tracks: const <SoundscapeTrackInput>[
          SoundscapeTrackInput(path: 'cov_pa12_c.mp3'),
        ],
        durationMs: 300,
        channel: AudioChannel.media,
        fadeOutMs: 0,
      );
      expect(again.ok, isTrue,
          reason: '_mixStopped 未复位 ⇒ 后续混音会被误判为"已被停止"');
    });

    test('PA-13 dispose() ⇒ 播放中释放 + 两道平台异常都被吞 + 字段无条件清空（幂等）',
        () async {
      // 原生释放炸 + 回落路径也炸 ⇒ `AudioPlayer.dispose()` 会把异常冒到调用方，
      // 而 `PlaybackService.dispose()` 的 `on Object` 必须把它吞掉
      // （调用点 `sound_library_screen.dart` 写的是不 await 的
      // `_previewPlayer.dispose();` —— 抛出去就是无人接的异步错误）。
      audio.disposePlayerError = Exception('native dispose boom');
      audio.disposeError = Exception('fallback dispose boom');

      final svc = PlaybackService();
      final fut = svc.play(
        path: p1,
        channel: AudioChannel.media,
        volume: 0.5,
        maxDurationMs: 400,
      );
      // ⚠️ 不靠固定墙钟等待"前置步骤跑完" —— 覆盖率插桩 + 整层默认并发占满
      //    CPU 时，`AudioSession.configure` / `setFilePath` / `play` 这些 await
      //    会被拉长到远超 120ms，于是 dispose() 可能落在**起播之前**，把
      //    play() 的 setup 打断成失败（2026-10-04 门禁实测 PA-13 偶发红）。
      //    判据要的是"播放中释放"，所以轮询到平台侧**确实已起播**再释放 ——
      //    确定性、且业务语义不变（反而更准）。
      while (audio.countOf('play') == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      await svc.dispose(); // 不得抛出
      final afterFirst = audio.countOf('disposePlayer');
      expect(afterFirst, 1, reason: '播放中释放 ⇒ 原生平台确实被交还过一次');

      // 释放不该把已经开始的那次播放"改写"成失败。
      final r = await fut;
      expect(r.ok, isTrue);

      // `_player = null` 在 finally 里无条件执行 ⇒ 二次调用不得再打平台。
      await svc.dispose();
      expect(audio.countOf('disposePlayer'), afterFirst,
          reason: '字段已清空，二次 dispose 不许重复打到平台');
    });

    test('PA-14 [P2-08] stop()/stopAllPlaying() 统一停止声景多轨并登记', () async {
      audio.fileDuration = const Duration(seconds: 30);
      final svc = PlaybackService();
      final fut = svc.playSoundscape(
        tracks: const <SoundscapeTrackInput>[
          SoundscapeTrackInput(path: 'cov_pa14_a.mp3'),
          SoundscapeTrackInput(path: 'cov_pa14_b.mp3'),
        ],
        durationMs: 60000,
        channel: AudioChannel.media,
        fadeOutMs: 0,
      );
      // 等到两轨都起播（多轨是 `unawaited(p.play())`）。
      while (audio.countOf('play') < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // 声景实例必须登记到统一会话表 —— 否则远程「停止指令组」拿不到它，
      // 声景会继续出声到窗口到点（旧实现的根因）。
      expect(await PlaybackService.stopAllPlaying(), 1,
          reason: '声景必须登记；不登记 ⇒ 停止指令组扑空、声景继续出声');

      final r = await fut;
      expect(r.ok, isTrue,
          reason: '被 stop 打断仍如实报"已停止"（与 stopSoundscape 同语义）');
      expect(r.playedMs, lessThan(60000),
          reason: 'stop() 必须立刻打断 60s 等待窗口，不许等满');
      // 各轨的原生播放器必须被交还（不再"只停主播放器、声景轨泄漏"）。
      expect(audio.countOf('disposePlayer'), greaterThanOrEqualTo(2));
    });
  });
}
