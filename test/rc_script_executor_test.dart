import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/script_executor.dart';

/// 通知插件通道名（mock 与"平台 → Dart 回投递"两侧共用）。
const _notifChannel = 'dexterous.com/flutter/local_notifications';

/// 指令组模型（RcScript/RcStep）与端点执行器（RcScriptExecutor）测试。
///
/// 通知插件经 mock channel 短路（show/cancel 返回 null），
/// 执行器逻辑（顺序/终止/进度回调）在宿主机即可完整验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_notifChannel),
      // `initialize` 的平台层声明返回 bool（非 bool?）—— 桩返回 null 会在
      // 宿主上炸 `Null is not a subtype of FutureOr<bool>`（异步未捕获错误）。
      (call) async => call.method == 'initialize' ? true : null,
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

  // ---------------- 第 44 轮补：可中断等待原语 / 组装器 wire / 通知终止回调 ----------------

  group('RcCancel 与 runRecordWindow 的可中断语义', () {
    test('RcCancel.sleep：自然到点时正常返回，不视为取消', () async {
      final c = RcCancel();
      await c.sleep(const Duration(milliseconds: 20));
      expect(c.cancelled, isFalse);
    });

    test('RcCancel.sleep：令牌一到立刻醒，不等满时长', () async {
      final c = RcCancel();
      final sw = Stopwatch()..start();
      final waiting = c.sleep(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c.cancel();
      await waiting;
      sw.stop();

      expect(c.cancelled, isTrue);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: '「任何时刻都能停」的兑现点：令牌一到必须立刻放行');
    });

    test('runRecordWindow：带令牌自然到点 → ok=true / aborted=false（v2 分流）',
        () async {
      var stopped = 0;
      final out = await runRecordWindow(
        const Duration(milliseconds: 30),
        stop: () async => stopped++,
        cancel: RcCancel(),
        tick: const Duration(milliseconds: 10),
      );

      expect(out.ok, isTrue);
      expect(out.aborted, isFalse);
      expect(out.stopConfirmed, isTrue);
      expect(stopped, 1, reason: '无论走哪条路都必须请求停止');
      expect(out.message, '录音取证完成');
    });

    test('activeCancel：未运行时为 null（端点 runner 据此判定"无可响应令牌"）', () {
      expect(RcScriptExecutor.instance.isRunning, isFalse);
      expect(RcScriptExecutor.instance.activeCancel, isNull);
    });
  });

  group('ScriptDraft 组装器 wire', () {
    test('toPayload 产出可往返的 RcScript wire（含 sentAt）', () {
      final draft = ScriptDraft(name: '草稿', steps: [
        ScriptDraftStep(RcStepKind.tts, {'text': 'x'}),
      ]);
      expect(draft.validate(), isNull);

      final p = draft.toPayload(scriptId: 'sid', fromName: '控制器');

      expect(p['scriptId'], 'sid');
      expect(p['name'], '草稿');
      expect(p['fromName'], '控制器');
      expect(p['sentAt'], isA<int>());
      expect(RcScript.fromJson(p).steps.single.describe(), '播报「x」');
    });

    test('validate 透传 RcScript.validate：空步骤被拒', () {
      expect(ScriptDraft(name: '空', steps: []).validate(), isNotNull);
    });

    test('RcStep.describe 对 vibrate 步给出固定文案（组装器占位行）', () {
      expect(const RcStep(RcStepKind.vibrate, {}).describe(), '震动');
    });
  });

  group('RcScript 时间面与反序列化入口', () {
    test('worstCaseMs：record 按 seconds×1000 计（缺省 30s）', () {
      expect(const RcStep(RcStepKind.record, {}).worstCaseMs(), 30000);
      expect(
          const RcStep(RcStepKind.record, {'seconds': 5}).worstCaseMs(), 5000);
    });

    test('fromJsonString 与 fromJson(JSON.decode) 等价', () {
      const src = RcScript(
        scriptId: 'sid-2',
        name: '反序列化',
        fromName: '控制器',
        sentAt: 1700000000000,
        steps: [RcStep(RcStepKind.delay, {'seconds': 2})],
      );

      final back = RcScript.fromJsonString(jsonEncode(src.toJson()));

      expect(back.scriptId, 'sid-2');
      expect(back.name, '反序列化');
      expect(back.sentAt, 1700000000000);
      expect(back.steps.single.kind, RcStepKind.delay);
    });
  });

  group('registerStopHandler（通知【终止执行】按钮接线）', () {
    /// 模拟 Android 侧把通知按钮点击回投给插件。
    Future<void> deliverAction(Object? actionId) async {
      final call = MethodCall('didReceiveNotificationResponse', <String, Object?>{
        'notificationId': 0x5C81,
        'actionId': actionId,
        'input': null,
        'payload': null,
        'notificationResponseType': 0,
      });
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _notifChannel,
        const StandardMethodCodec().encodeMethodCall(call),
        (_) {},
      );
    }

    test('只有 actionId=rc_script_stop 触发终止回调，其它按钮不误触发', () async {
      final plugin = FlutterLocalNotificationsPlugin();
      var stopped = 0;
      RcScriptExecutor.registerStopHandler(plugin, () => stopped++);
      await Future<void>.delayed(Duration.zero);

      await deliverAction('other_action');
      expect(stopped, 0, reason: '非终止按钮不得掐断正在执行的指令组');

      await deliverAction('rc_script_stop');
      expect(stopped, 1);
    });
  });
}
