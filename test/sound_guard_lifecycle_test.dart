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
}
