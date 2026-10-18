import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/script_executor.dart';
import 'package:sonic_shield/services/playback_service.dart';

import 'support/source_text.dart';

/// 远程指令组「停得掉」契约测试（审计 A2/A3 的 P0）。
///
/// ## 锁的是什么
///
/// 旧实现只在**步骤之间**检查终止令牌，且无条件 `await runner(step)`：
/// 一个"播放 10 分钟"的 `play` 会把终止拖到它自然结束，端点**继续出声**；
/// `record` 更彻底 —— 它是 `await Future.delayed(seconds)`，令牌完全不参与，
/// 用户点了「停止指令组」录音**仍在写文件**（未授权的隐蔽采集，docs/08 红线）。
///
/// 这些断言**不是恒真**，每条都有明确的变异击穿路径（见各 reason）：
/// - 去掉 `run` 里的 `Future.any` 竞速 → T1 超时（onTimeout 返回 true 使其红而非挂起）；
/// - 去掉 `stop()` 里的 `_haltMedia()` → T5 的 `halted` 停在 0；
/// - 把 `_haltMedia` 的失败吞掉（不写 `_lastStopNote`）→ T6 两条断言同时红；
/// - 把 `runRecordWindow` 的等待换回 `Future.delayed` → T7 的 `aborted` 为 false；
/// - 从 `record` 调用点删掉 `cancel: cancel` → T10 红（纯函数再对也接不上链路）；
/// - 把 `_recordEvidence` 内的 `runRecordWindow` 换回无条件 `Future.delayed`
///   → T11 红；把终止态压成 `success` → T12 红。
///
/// 通知插件经 mock channel 短路（show/cancel 返回 null），执行器逻辑因此在
/// 宿主机即可完整验证；通道处理器**全程挂着不撤**，因为执行器会在 run 结束后
/// 3 秒再取消一次通知，撤掉会让那次调用以 MissingPluginException 逃逸。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const notifChannel =
      MethodChannel('dexterous.com/flutter/local_notifications');

  /// `show` 的原始参数串（不做键名假设：插件版本间 key 有差异，
  /// 这里只关心"发过什么内容"）。
  var notifCalls = <String>[];

  setUp(() {
    notifCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifChannel, (call) async {
      if (call.method == 'show') {
        notifCalls.add(call.arguments?.toString() ?? '');
      }
      return null;
    });
  });

  RcScript mkScript(String id, List<RcStep> steps) => RcScript(
        scriptId: id,
        name: '测试宏',
        fromName: '控制器',
        sentAt: DateTime.now().millisecondsSinceEpoch,
        steps: steps,
      );

  /// 终止后允许的总等待 = 收尾窗口 + 余量。
  final waitForStop = RcScriptExecutor.abortGrace + const Duration(seconds: 2);

  group('RcScriptExecutor 终止契约', () {
    test('T1 终止：进行中的步骤不再把「停」拖到自然结束', () async {
      final exec = RcScriptExecutor.instance;
      final gate = Completer<void>();
      final ran = <RcStepKind>[];

      final run = exec.run(
        mkScript('f3-stop-1', const [
          RcStep(RcStepKind.play, {'durationSec': 600}),
          RcStep(RcStepKind.vibrate, {}),
        ]),
        // 永不返回：模拟"正在播 10 分钟"的步骤。
        runner: (s) {
          ran.add(s.kind);
          return gate.future;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(exec.isRunning, isTrue, reason: '步骤挂起中，执行器应在运行态');

      exec.stop();

      final ok = await run.timeout(waitForStop, onTimeout: () => true);
      expect(ok, isFalse,
          reason: '超时说明终止被拖到步骤自然结束（run 里缺 Future.any 竞速）');
      expect(ran, [RcStepKind.play], reason: '终止后不得再执行后续步骤');
      expect(exec.lastStopNote, isNotNull,
          reason: '步骤没在收尾窗口内返回 → 必须留下可诊断的降级说明，不得静默');
      expect(exec.lastStopNote, contains('play'));

      gate.complete();
    });

    test('T2 未终止：顺序执行全部步骤且不留降级说明（防"恒真"锁）', () async {
      final exec = RcScriptExecutor.instance;
      final ran = <RcStepKind>[];

      final ok = await exec.run(
        mkScript('f3-ok-1', const [
          RcStep(RcStepKind.notify, {'title': 'T', 'body': 'B'}),
          RcStep(RcStepKind.vibrate, {}),
        ]),
        runner: (s) async => ran.add(s.kind),
      );

      expect(ok, isTrue);
      expect(ran, [RcStepKind.notify, RcStepKind.vibrate]);
      expect(exec.lastStopNote, isNull,
          reason: '干净执行不得留下降级说明（否则"总有告警"等于没有告警）');
    });

    test('T3 record 步骤必须有进行中的常驻可见指示（不得无声采集）', () async {
      final exec = RcScriptExecutor.instance;

      final ok = await exec.run(
        mkScript('f3-rec-1', const [RcStep(RcStepKind.record, {'seconds': 30})]),
        runner: (s) async {},
      );

      expect(ok, isTrue);
      expect(notifCalls.any((a) => a.contains('录音取证')), isTrue,
          reason: '录音步骤开始必须发布可感知的指示（docs/08：不得无声录制）');
    });

    test('T4 反向断言：终止后步骤抛异常也不得继续执行', () async {
      final exec = RcScriptExecutor.instance;
      final ran = <RcStepKind>[];

      final ok = await exec.run(
        mkScript('f3-stop-2', const [
          RcStep(RcStepKind.play, {}),
          RcStep(RcStepKind.play, {}),
        ]),
        runner: (s) async {
          ran.add(s.kind);
          if (ran.length == 1) {
            exec.stop();
            await Future<void>.delayed(const Duration(milliseconds: 20));
            // 停止之后才抛：绝不能被"单步失败不中断整体"的 catch 吃成继续执行。
            throw Exception('boom');
          }
        },
      );

      expect(ok, isFalse);
      expect(ran.length, 1, reason: '终止信号一旦到达，后续步骤一律不得执行');
    });

    test('T5 终止必须立刻请求掐断正在出声的播放', () async {
      final exec = RcScriptExecutor.instance;
      var halted = 0;
      exec.mediaStopper = () async {
        halted++;
        return 1;
      };
      addTearDown(() => exec.mediaStopper = PlaybackService.stopAllPlaying);

      final gate = Completer<void>();
      final run = exec.run(
        mkScript('f3-stop-3', const [
          RcStep(RcStepKind.play, {'durationSec': 600}),
        ]),
        runner: (s) => gate.future,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      exec.stop();
      await run.timeout(waitForStop, onTimeout: () => true);

      expect(halted, 1, reason: '「停」必须先是听觉事实：立刻掐断播放器');
      gate.complete();
    });

    test('T6 掐不断播放时必须留下降级说明并进入终态通知', () async {
      final exec = RcScriptExecutor.instance;
      // 显式返回类型：`() async { throw ... }` 的返回类型靠上下文推断不稳，
      // 这里用局部函数把 `Future<int>` 钉死。
      Future<int> failStop() async {
        throw StateError('无播放句柄');
      }

      exec.mediaStopper = failStop;
      addTearDown(() => exec.mediaStopper = PlaybackService.stopAllPlaying);

      final gate = Completer<void>();
      final run = exec.run(
        mkScript('f3-stop-4', const [
          RcStep(RcStepKind.play, {'durationSec': 600}),
        ]),
        runner: (s) => gate.future,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      exec.stop();
      final ok = await run.timeout(waitForStop, onTimeout: () => true);

      expect(ok, isFalse);
      expect(exec.lastStopNote, contains('未能确认停止播放'),
          reason: '停不掉必须如实记录，不得静默假装已停');
      expect(notifCalls.any((a) => a.contains('未能确认停止播放')), isTrue,
          reason: '降级说明必须进入终态通知，而不是只躺在内存里');
      gate.complete();
    });
  });

  group('runRecordWindow 录音窗口契约', () {
    test('T7 收到终止必须停止录音，且不得报成功', () async {
      final cancel = RcCancel();
      var stopped = false;

      final fut = runRecordWindow(
        const Duration(seconds: 60),
        cancel: cancel,
        stop: () async {
          stopped = true;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(stopped, isFalse, reason: '终止到达前不得停止录音');

      cancel.cancel();
      final out = await fut.timeout(const Duration(seconds: 3));

      expect(out.aborted, isTrue,
          reason: '若等待换回 Future.delayed，终止根本不参与 → 这里为 false');
      expect(out.ok, isFalse, reason: '被终止不是"录音完成"');
      expect(out.stopConfirmed, isTrue);
      expect(stopped, isTrue, reason: '终止后必须真的去停录音器（否则继续写文件）');
    });

    test('T8 停止未获确认时必须显式说明文件可能仍在写入', () async {
      final cancel = RcCancel()..cancel();

      final out = await runRecordWindow(
        const Duration(seconds: 60),
        cancel: cancel,
        stop: () async => throw StateError('插件不回调'),
      );

      expect(out.ok, isFalse);
      expect(out.stopConfirmed, isFalse);
      expect(out.message, contains('文件可能仍在写入'));
    });

    test('T9 自然到点：报到点完成，且同样停掉录音器', () async {
      var stopped = false;

      final out = await runRecordWindow(
        const Duration(milliseconds: 200),
        stop: () async {
          stopped = true;
        },
      );

      expect(out.ok, isTrue);
      expect(out.aborted, isFalse);
      expect(out.stopConfirmed, isTrue);
      expect(stopped, isTrue, reason: '到点也必须停录音器');
      expect(out.message, '录音取证完成');
    });
  });

  // 纯函数 `runRecordWindow` 全过，**不等于**录音真的能被停掉：若端点调用点没把
  // 终止令牌传下去、或 `_recordEvidence` 仍在无条件 `await Future.delayed`，
  // 就是本项目反复踩的"两端各自都对、链路却是断的"。`_recordEvidence` 依赖
  // MQTT / 数据库 / 录音插件，宿主无法实例化 ⇒ 退一步锁**接线本身**（源码契约，
  // 与 endpoint_script_skipped_test / endpoint_dispatch_hardening_test 同法）。
  group('端点接线锁（源码契约）：终止必须真的能停掉录音', () {
    final src = File('lib/remote/endpoint_service.dart').readAsStringSync();

    // BUG-121 把一次脚本执行拆成「预占段 `_runScript`」+「实跑段
    // `_runClaimedScript`」。锁的语义范围是"一次执行"，故按源码顺序拼接。
    String execScope() =>
        methodBody(src, 'Future<void> _runScript(') +
        methodBody(src, 'Future<void> _runClaimedScript(');

    test('T10 record 调用点把终止令牌传进 _recordEvidence', () {
      final runner = methodBody(execScope(), 'Future<void> runner(RcStep step)');
      final recordCase = runner.indexOf('case RcStepKind.record:');
      expect(recordCase, greaterThanOrEqualTo(0));
      expect(runner.substring(recordCase), contains('cancel: cancel'),
          reason: 'record 调用点没传 cancel ⇒ 终止令牌到不了录音器：'
              '用户点了「终止执行」后麦克风仍在录音、文件仍在写入（docs/08 红线）');
    });

    test('T11 _recordEvidence 经 runRecordWindow 等待，并把 cancel 交给它', () {
      final body = methodBody(src, 'Future<void> _recordEvidence({');
      expect(body, contains('runRecordWindow('),
          reason: '仍在 `await Future.delayed(seconds)` 上等 ⇒ 令牌完全不参与，'
              'T7 的纯函数再正确也接不上链路');
      expect(body, contains('cancel: cancel'),
          reason: '窗口必须拿到终止令牌，否则收不到 cancel');
      expect(body, contains('stop: () async {'),
          reason: 'stop 必须包一层 async 闭包：rec.stop() 的返回类型不保证是 Future<void>');
      expect(
          body,
          isNot(contains(
              'await Future<void>.delayed(Duration(seconds: seconds))')),
          reason: '旧的无条件等待若还在，终止依旧参与不进来（改了但没生效）');
    });

    test('T12 三种终态落到既有状态值，"没停掉"必须显式可见', () {
      final body = methodBody(src, 'Future<void> _recordEvidence({');
      expect(body, contains("status: 'success'"));
      expect(body, contains("status: 'skipped'"),
          reason: '被终止必须记 skipped（沿用既有状态值，不发明新状态）');
      expect(body, contains("status: 'failed'"));
      expect(body, contains('!outcome.stopConfirmed'),
          reason: '必须先分支处理"停止未获确认"这一最严重形状（文件可能仍在写入）');
      expect(body, contains('outcome.message'),
          reason: '"文件可能仍在写入"的文案必须真的被写进审计/步骤说明');
      expect(body, contains('stepNotes?.add('),
          reason: '被终止 / 没停掉都要进 stepNotes，随终态回给控制端，不得静默');
    });

    test('T13 误导性 no-op（_interruptibleWatch）已移除', () {
      expect(src, isNot(contains('_interruptibleWatch')),
          reason: '它是 `await cancel.future` 的 no-op，注释却称"立即停掉播放器"：'
              '注释比代码乐观，留着会误导后来人');
    });
  });
}
