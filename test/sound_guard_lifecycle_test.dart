import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/services/sound_guard_service.dart';

/// `SoundGuardService` 生命周期回归锁（v1.10）。
///
/// ## 真机取证（MI MAX 2 / API 25）
///
/// 审计表：`guard · start · failed · 麦克风权限被拒`，而
/// `dumpsys package com.sonicshield.sonic_shield` 显示
/// `android.permission.RECORD_AUDIO: granted=true`。
///
/// 两处结构性缺陷（都能在宿主上断言）：
/// 1. `start()` 用 `_recorder.hasPermission()` 做准入 —— 而
///    `record_android-2.2.0/.../PermissionManager.kt:33-36` 的第一句是
///    `if (activity == null) { resultCallback.onResult(false); return }`。
///    引擎隔离里没有 Activity ⇒ **恒为 false**，与系统授权无关。
/// 2. `start()` 先置 `_running = true` 再取流 ⇒ 取流失败后仍自称"运行中"
///    （**成功被误报**）；`stop()` 把 `_running = false` 放在
///    `await _recorder.stop()` **之后** ⇒ 插件不回调时永远回投不到停止
///    （**关了关不掉**）。
class _FakeRecorder implements AudioRecorder {
  _FakeRecorder({
    this.throwOnStart = false,
    this.recordStopHangs = false,
  });

  final bool throwOnStart;

  /// true = 模拟"`stop()` 永不回调"的真机行为。
  final bool recordStopHangs;

  final _chunks = StreamController<Uint8List>.broadcast();
  int stopCalls = 0;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    if (throwOnStart) {
      throw StateError('AudioRecord init failed（模拟无权限/被占用）');
    }
    return _chunks.stream;
  }

  /// 第四十轮：把一帧 PCM16 块**真的喂进** `start()` 里那条 listen 回调。
  ///
  /// 此前两个声盾测试文件都不喂块（一个只锁 `rmsDbfs` 纯函数、一个只锁
  /// start/stop 的顺序与状态位），于是"阈值 / 最短持续 / 冷却 / 峰值 /
  /// 事件复位"整段检测逻辑零覆盖。
  void emitChunk(Uint8List chunk) => _chunks.add(chunk);

  /// 模拟采流异常（麦克风被抢占 / 录音器崩溃）。
  void emitError(Object error) => _chunks.addError(error);

  @override
  Future<bool> isRecording() async => true;

  @override
  Future<String?> stop() {
    stopCalls++;
    if (recordStopHangs) {
      // 永不 complete：真机上表现为"守卫开了关不掉"。
      return Completer<String?>().future;
    }
    return Future<String?>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  test('SGL-01 取流失败 -> ok=false 且 isRunning=false（不得误报成功）', () async {
    final svc = SoundGuardService(recorder: _FakeRecorder(throwOnStart: true));
    final r = await svc.start(const SoundTrigger());
    expect(r.ok, isFalse);
    expect(r.message, isNotNull);
    expect(r.message!.contains('AudioRecord init failed'), isTrue,
        reason: '必须把真实异常带给用户，而不是编一句"权限被拒"');
    expect(svc.isRunning, isFalse,
        reason: '旧实现先置 _running=true 再取流 ⇒ 取流失败后仍自称运行中，'
            '引擎回投 guardActive:true ⇒ UI 显示"守卫运行中"，实际一个字节都没采');
    await svc.dispose();
  });

  test('SGL-02 取流成功 -> ok=true 且 isRunning=true', () async {
    final svc = SoundGuardService(recorder: _FakeRecorder());
    final r = await svc.start(const SoundTrigger());
    expect(r.ok, isTrue);
    expect(svc.isRunning, isTrue);
    await svc.dispose();
  });

  test('SGL-03 重复 start 幂等（已在跑不重复取流）', () async {
    final svc = SoundGuardService(recorder: _FakeRecorder());
    await svc.start(const SoundTrigger());
    final r = await svc.start(const SoundTrigger());
    expect(r.ok, isTrue);
    expect(svc.isRunning, isTrue);
    await svc.dispose();
  });

  test('SGL-04 录音器 stop() 永不回调时，stop() 仍必须返回且 isRunning=false', () async {
    final rec = _FakeRecorder(recordStopHangs: true);
    final svc = SoundGuardService(recorder: rec);
    await svc.start(const SoundTrigger());
    expect(svc.isRunning, isTrue);

    // 旧实现会在这里永久挂起（`_running = false` 排在 await 之后）。
    await svc.stop().timeout(const Duration(seconds: 8));

    expect(svc.isRunning, isFalse,
        reason: '这是"守卫开了关不掉"的根因：_running 必须与"用户按了停止"同步落位');
    await svc.dispose();
  });

  test('SGL-05 未启动就 stop() 不抛异常', () async {
    final svc = SoundGuardService(recorder: _FakeRecorder());
    await svc.stop();
    expect(svc.isRunning, isFalse);
    await svc.dispose();
  });

  test('SGL-06 源码锁：_running 的置位/清位顺序是语义，不是风格', () {
    final src =
        File('lib/services/sound_guard_service.dart').readAsStringSync();

    // ① stop() 的第一条语句必须是 _running = false，早于任何 await。
    final stopIdx = src.indexOf('Future<void> stop() async {');
    expect(stopIdx, greaterThan(-1), reason: '锁失效：找不到 stop()');
    final stopBody = src.substring(stopIdx, stopIdx + 400);
    final firstAwait = stopBody.indexOf('await ');
    final flagClear = stopBody.indexOf('_running = false');
    expect(flagClear, greaterThan(-1));
    expect(flagClear < firstAwait, isTrue,
        reason: '`_running = false` 若排在 await 之后，插件不回调时永远执行不到 ⇒ 关不掉');

    // ② start() 里不得再用 hasPermission() 做准入判定。
    final startIdx = src.indexOf('Future<GuardStartResult> start(');
    final startBody = src.substring(startIdx, src.indexOf('Future<void> stop()'));
    expect(startBody.contains('hasPermission'), isFalse,
        reason: 'record 插件在无 Activity 的引擎隔离里 hasPermission() 恒 false '
            '（PermissionManager.kt:33-36）—— 用它做准入等于"授权了也起不来"');

    // ③ 反向自检：_running = true 必须出现在取流之后。
    final streamIdx = startBody.indexOf('startStream');
    final trueIdx = startBody.indexOf('_running = true');
    expect(trueIdx > streamIdx, isTrue,
        reason: '_running = true 必须晚于 startStream，否则失败时仍自称运行中');
  });

  // ---------------------------------------------------------------------------
  // 第四十轮新增：**检测语义**（把 PCM 块真的喂进 listen 回调）。
  //
  // 这一组是"守卫到底会不会响"的核心判据，此前**零覆盖**：
  // 阈值比较、最短持续、冷却门控、峰值取块内最大、静音复位、采流异常广播。
  // 全部用注入的 `_FakeRecorder` 驱动，零平台依赖。
  // ---------------------------------------------------------------------------
  group('SGD 守卫检测语义（第四十轮）', () {
    /// 造一帧 PCM16 单声道块（`sample` 是 int16 幅值）。
    Uint8List pcm(int sample, {int samples = 64}) {
      final bytes = Uint8List(samples * 2);
      final bd = ByteData.sublistView(bytes);
      for (var i = 0; i < samples; i++) {
        bd.setInt16(i * 2, sample, Endian.little);
      }
      return bytes;
    }

    final full = pcm(32767); // ≈ 0 dBFS
    final half = pcm(16000); // ≈ -6.2 dBFS
    final silence = pcm(0); // rms <= 0 → -120（rmsDbfs 的钳位分支）

    /// 让 broadcast 流把已 add 的事件派发到监听者（纯 Dart，无需打桩）。
    Future<void> flush() async {
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('SGD-01 峰值取"本事件内最大值"而不是最后一帧', () async {
      final rec = _FakeRecorder();
      final svc = SoundGuardService(recorder: rec);
      final events = <SoundEvent>[];
      final levels = <double>[];
      svc.events.listen(events.add);
      svc.levels.listen(levels.add);
      addTearDown(svc.dispose);

      // minDurationMs=10：逼出"多帧累积成一个事件"，否则第一帧就发射。
      await svc.start(const SoundTrigger(
          thresholdDb: -50, minDurationMs: 10, cooldownSec: 0));

      rec.emitChunk(full); // 峰值抬到 ≈0，但时长不够 → 不发射
      await flush();
      expect(events, isEmpty, reason: '最短持续没到就不该发射（防一声脆响误触发）');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      rec.emitChunk(half); // 这一帧只有 -6.2 dBFS
      await flush();

      expect(events, hasLength(1));
      expect(events.single.peakDb, closeTo(0, 0.5),
          reason: '峰值必须取事件内最大值（≈0）；若报 -6.2 说明它只看了最后一帧');
      expect(levels, hasLength(2), reason: '电平流每帧都要出，UI 电平表靠它');
    });

    test('SGD-02 静音帧复位"在响"状态：时长从零重新计（不得累加成假事件）', () async {
      final rec = _FakeRecorder();
      final svc = SoundGuardService(recorder: rec);
      final events = <SoundEvent>[];
      svc.events.listen(events.add);
      addTearDown(svc.dispose);

      await svc.start(const SoundTrigger(
          thresholdDb: -50, minDurationMs: 10, cooldownSec: 0));

      rec.emitChunk(full); // 起事件（时长不足，未发射）
      await flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      rec.emitChunk(silence); // 静音 → 必须复位
      await flush();
      rec.emitChunk(half); // 复位后重新计时 → 时间不够
      await flush();

      expect(events, isEmpty,
          reason: '静音没复位的话，这里会把"两段响声"拼成一次事件发射出去');
    });

    test('SGD-03 冷却门控：冷却期内的第二次响声不得再触发', () async {
      final rec = _FakeRecorder();
      final svc = SoundGuardService(recorder: rec);
      final events = <SoundEvent>[];
      svc.events.listen(events.add);
      addTearDown(svc.dispose);

      // cooldownSec=3600 ⇒ 第二次响必然落在冷却期内（不依赖墙钟精度）。
      await svc.start(const SoundTrigger(
          thresholdDb: -50, minDurationMs: 0, cooldownSec: 3600));

      rec.emitChunk(full);
      await flush();
      expect(events, hasLength(1), reason: '首次（lastFired=纪元）必须触发');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      rec.emitChunk(full);
      await flush();

      expect(events, hasLength(1),
          reason: '冷却机制就是防连环执行的，第二次必须被吃掉');
    });

    test('SGD-04 采流异常 → errors 广播 + isRunning 立刻落位（不得静默停摆）', () async {
      final rec = _FakeRecorder();
      final svc = SoundGuardService(recorder: rec);
      final errors = <Object>[];
      svc.errors.listen(errors.add);
      addTearDown(svc.dispose);

      await svc.start(const SoundTrigger(
          thresholdDb: -50, minDurationMs: 0, cooldownSec: 0));
      expect(svc.isRunning, isTrue);

      rec.emitError(StateError('麦克风被其它应用抢占'));
      await flush();

      expect(errors, hasLength(1),
          reason: '错误必须走独立一条流：混进 events 会被当成"一次声音事件"去触发动作');
      expect(svc.isRunning, isFalse,
          reason: '流断了还自称运行中 = "失败不可见"（BUG-061 判据）');
    });

    test('SGD-05 默认构造（不注入录音器）也必须可用且 stop/dispose 不炸', () async {
      // 覆盖 `_recorder = recorder ?? AudioRecorder()` 的右侧分支：
      // 生产路径（引擎里 new SoundGuardService()）走的正是这一支。
      final svc = SoundGuardService();
      expect(svc.isRunning, isFalse);
      expect(svc.levels, isNotNull);
      expect(svc.events, isNotNull);
      expect(svc.errors, isNotNull);
      await svc.stop();
      await svc.dispose();
    });
  });
}
