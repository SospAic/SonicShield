import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/rc_script.dart';

import 'support/source_text.dart';

const _allOn = AssistPerms(
  media: true,
  tts: true,
  vibrate: true,
  volume: true,
  location: true,
  video: true,
  script: true,
);

void main() {
  group('gateRcScriptStep：步骤 → 权限位', () {
    test('SP-01 只读步骤（delay/notify）在**全拒**权限下也必须放行', () {
      for (final k in [RcStepKind.delay, RcStepKind.notify]) {
        final v = gateRcScriptStep(k, perms: AssistPerms.none);
        expect(v.allowed, isTrue,
            reason: '$k 的 requiredStepPerm 是 null；若实现直接调 hasPerm(perms, null)'
                '会落到 `_ => false`，把无害步骤误拒');
      }
    });

    test('SP-02 record（录音取证）在**全放行**权限下也拒绝', () {
      final v = gateRcScriptStep(RcStepKind.record, perms: _allOn);
      expect(v.allowed, isFalse,
          reason: 'record 映射到 denyAll（未登记权限位）⇒ 任何权限都放行不了它；'
              '这正是"端点只放行 script 位、对端却能录音取证"的堵口');
      expect(v.reason, contains('一律拒绝'));
    });

    test('SP-03 play 要 media 位；只有 script 位时必须拒绝', () {
      final denied = gateRcScriptStep(RcStepKind.play,
          perms: const AssistPerms(script: true));
      expect(denied.allowed, isFalse);
      expect(denied.reason, contains('播放音效'));

      expect(gateRcScriptStep(RcStepKind.play, perms: _allOn).allowed, isTrue);
    });

    test('SP-04 权限位互不越权：media 位不能顶替 tts / vibrate', () {
      const mediaOnly = AssistPerms(media: true);
      expect(gateRcScriptStep(RcStepKind.tts, perms: mediaOnly).allowed, isFalse);
      expect(gateRcScriptStep(RcStepKind.vibrate, perms: mediaOnly).allowed,
          isFalse);
      expect(gateRcScriptStep(RcStepKind.play, perms: mediaOnly).allowed, isTrue);
    });

    test('SP-05 tts / vibrate 各自要自己的位', () {
      expect(
          gateRcScriptStep(RcStepKind.tts,
                  perms: const AssistPerms(tts: true))
              .allowed,
          isTrue);
      expect(
          gateRcScriptStep(RcStepKind.vibrate,
                  perms: const AssistPerms(vibrate: true))
              .allowed,
          isTrue);
    });
  });

  group('runner 接线锁（源码契约）', () {
    final src = File('lib/remote/endpoint_service.dart').readAsStringSync();

    test('SP-W1 runner 在 switch(step.kind) **之前**做步骤级裁决', () {
      final body = methodBody(src, 'Future<void> runner(RcStep step) async');

      final gate = body.indexOf('gateRcScriptStep(');
      final sw = body.indexOf('switch (step.kind)');
      expect(gate, greaterThanOrEqualTo(0), reason: '未接线 = requiredStepPerm 仍是死代码');
      expect(sw, greaterThanOrEqualTo(0));
      expect(gate, lessThan(sw),
          reason: '裁决必须发生在执行之前；放在 switch 之后就拦不住任何步骤');
    });

    test('SP-W2 只在协助会话下裁决（配对通道 = 全权，不能误伤）', () {
      final body = methodBody(src, 'Future<void> runner(RcStep step) async');
      expect(body, contains('assistReplyZone'),
          reason: 'runner 同时服务配对通道；配对没有权限位，无条件读协助权限'
              '会把已配对设备的指令组整体拒掉');
      expect(body, contains('Zone.current[assistReplyZone] == true'));
    });

    test('SP-W3 被拒步骤必须写 skipped 审计（不能静默跳过）', () {
      final body = methodBody(src, 'Future<void> runner(RcStep step) async');
      expect(body, contains("status: 'skipped'"));
      expect(body, contains('verdict.reason'));
    });
  });
}
