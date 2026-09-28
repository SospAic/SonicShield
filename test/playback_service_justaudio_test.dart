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
      expect(r.playedMs, lessThan(1000));
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
      expect(r.playedMs, lessThan(1000), reason: '不许挂到"文件自然结束"');
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
      audio.fileDuration = const Duration(seconds: 5);
      final svc = PlaybackService();
      final fut = svc.play(
        path: p1,
        channel: AudioChannel.alarm,
        volume: 0.6,
        maxDurationMs: 5000,
      );

      await Future<void>.delayed(const Duration(milliseconds: 150));
      await svc.stop();
      final r = await fut;

      expect(r.ok, isFalse,
          reason: '报成功会让控制端以为这段声音已正常播完（docs/17 §45 语义）');
      expect(r.message, contains('已终止'));
      expect(r.playedMs, lessThan(2000), reason: '停止后必须立刻收尾，不许等满 5s');
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
      final fut = svc.playSoundscape(
        tracks: const <SoundscapeTrackInput>[
          SoundscapeTrackInput(path: 'cov_pa11.mp3'),
        ],
        durationMs: 5000,
        channel: AudioChannel.media,
        fadeOutMs: 0,
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));
      svc.stopSoundscape();
      final r = await fut;

      expect(r.ok, isTrue);
      expect(r.playedMs, lessThan(2000),
          reason: 'stopSoundscape 必须让等待窗口提前收尾（250ms 轮询）');
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
      await Future<void>.delayed(const Duration(milliseconds: 120));

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
  });
}
