import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/script_executor.dart';

/// 指令组模型（RcScript/RcStep）与端点执行器（RcScriptExecutor）测试。
///
/// 通知插件经 mock channel 短路（show/cancel 返回 null），
/// 执行器逻辑（顺序/终止/进度回调）在宿主机即可完整验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async => null,
    );
  });

  group('RcStep.describe 全 kind', () {
    test('六种 kind 的文案', () {
      expect(
          const RcStep(RcStepKind.play,
              {'presetCategory': 'nature', 'durationSec': 10}).describe(),
          '播放（nature） 10s');
      expect(const RcStep(RcStepKind.tts, {'text': '你好'}).describe(), '播报「你好」');
      expect(
          const RcStep(RcStepKind.notify, {'title': 'T'}).describe(), '通知「T」');
      expect(const RcStep(RcStepKind.vibrate, {}).describe(), '震动');
      expect(const RcStep(RcStepKind.record, {'seconds': 30}).describe(),
          '录音取证 30s');
      expect(
          const RcStep(RcStepKind.delay, {'seconds': 5}).describe(), '等待 5s');
    });

    test('fromJson 未知 kind 抛 ArgumentError', () {
      expect(() => RcStep.fromJson({'kind': 'boom'}), throwsArgumentError);
    });

    test('toJson 去掉 kind 后保留参数', () {
      final j = const RcStep(RcStepKind.delay, {'seconds': 5}).toJson();
      expect(j['kind'], 'delay');
      expect(j['seconds'], 5);
    });
  });

  group('RcScript.validate', () {
    RcStep step(RcStepKind k, [Map<String, dynamic> p = const {}]) =>
        RcStep(k, p);

    test('空步骤 → 提示', () {
      expect(RcScript.validate([]), isNotNull);
    });

    test('超 50 步 → 拒绝', () {
      expect(
          RcScript.validate(List.generate(51, (_) => step(RcStepKind.vibrate))),
          isNotNull);
    });

    test('delay 超上限（>600s）→ 拒绝', () {
      expect(
          RcScript.validate([
            step(RcStepKind.delay, {'seconds': 601})
          ]),
          isNotNull);
    });

    test('delay 下限以下（<0.5s）→ 拒绝', () {
      expect(
          RcScript.validate([
            step(RcStepKind.delay, {'seconds': 0})
          ]),
          isNotNull);
    });

    test('合法序列 → null', () {
      expect(
          RcScript.validate([
            step(RcStepKind.play, {'durationSec': 10}),
            step(RcStepKind.delay, {'seconds': 600}),
            step(RcStepKind.vibrate, {}),
          ]),
          isNull);
    });
  });

  group('RcScript 序列化往返', () {
    test('fromJson/fromPayload/toJson 一致', () {
      const script = RcScript(
        scriptId: 's1',
        name: '宏',
        fromName: '控制器A',
        sentAt: 1700000000000,
        steps: [
          RcStep(RcStepKind.tts, {'text': 'x'}),
          RcStep(RcStepKind.delay, {'seconds': 2}),
        ],
      );
      final back = RcScript.fromJson(
          jsonDecode(jsonEncode(script.toJson())) as Map<String, dynamic>);
      expect(back.scriptId, 's1');
      expect(back.name, '宏');
      expect(back.fromName, '控制器A');
      expect(back.steps.length, 2);
      expect(back.steps[0].describe(), '播报「x」');
    });
  });

  group('RcScriptExecutor 行为（单例生命周期：合并单用例顺序验证）', () {
    // 单例 _current 由 run 结束后的 3 秒定时器清空；拆成多个 test 会互相污染，
    // 故合并为一个 test 按时间顺序验证全部行为。
    test('全生命周期：完成/终止/占线/单步异常', () async {
      final exec = RcScriptExecutor.instance;
      RcScript mk(List<RcStep> steps) => RcScript(
            scriptId: 'sc',
            name: '测试宏',
            fromName: '控制器',
            sentAt: DateTime.now().millisecondsSinceEpoch,
            steps: steps,
          );

      // 1) 顺序执行
      final ran = <RcStepKind>[];
      final idx = <int>[];
      final ok1 = await exec.run(
        mk([
          const RcStep(RcStepKind.vibrate, {}),
          const RcStep(RcStepKind.notify, {'title': 'T', 'body': 'B'}),
          const RcStep(RcStepKind.vibrate, {}),
        ]),
        runner: (s) async => ran.add(s.kind),
        onStep: (i, _) => idx.add(i),
      );
      expect(ok1, isTrue);
      expect(ran, [RcStepKind.vibrate, RcStepKind.notify, RcStepKind.vibrate]);
      expect(idx, [0, 1, 2]);
      // run 返回即同步清空运行态（3 秒定时器只清通知）
      expect(exec.isRunning, isFalse);

      // 2) 占线：第一次 run 挂在 Completer 门上（gate 未放行）
      final gate = Completer<void>();
      final busy = exec.run(mk([const RcStep(RcStepKind.vibrate, {})]),
          runner: (_) => gate.future);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(exec.isRunning, isTrue, reason: 'busy run 挂起中');
      final ok2 = await exec.run(mk([const RcStep(RcStepKind.vibrate, {})]),
          runner: (_) async {});
      expect(ok2, isFalse, reason: '占线：第二次 run 应被拒');

      // 放行第一次 run 走完（3 秒清除定时器随后走完）
      gate.complete();
      await busy;
      await Future<void>.delayed(const Duration(seconds: 3, milliseconds: 200));
      expect(exec.isRunning, isFalse);

      // 4) 终止：runner 内 stop → false
      final ok3 = await exec.run(
        mk([
          const RcStep(RcStepKind.delay, {'seconds': 60}),
          const RcStep(RcStepKind.vibrate, {}),
        ]),
        runner: (s) async => exec.stop(),
      );
      expect(ok3, isFalse);
      await Future<void>.delayed(const Duration(seconds: 3, milliseconds: 200));

      // 5) 单步抛异常不中断整体
      final ran2 = <RcStepKind>[];
      final ok4 = await exec.run(
        mk([
          const RcStep(RcStepKind.notify, {'title': 'T', 'body': 'B'}),
          const RcStep(RcStepKind.vibrate, {}),
        ]),
        runner: (s) async {
          ran2.add(s.kind);
          if (s.kind == RcStepKind.notify) throw Exception('boom');
        },
      );
      expect(ok4, isTrue);
      expect(ran2, [RcStepKind.notify, RcStepKind.vibrate]);
    });
  });
}
