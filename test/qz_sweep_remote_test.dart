// QR2 扫描（远程模块）配套纯逻辑测试。
//
// 覆盖扫描中确认的三条链路（均为纯函数，宿主机可直接跑）：
// 1. `rc.script` 进度解析：未知状态不猜（BUG-050 判据）、终态判定；
// 2. 进度文案：运行中带/不带总步数、终态文案；
// 3. 协助会话权限摘要（assist_join_screen.assistPermSummary）：
//    默认全关 → 「未放行任何能力」；放行后摘要按 labels 顺序列出。
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/features/remote/assist_join_screen.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/script_progress.dart';

void main() {
  group('parseScriptProgress / shouldApplyProgress', () {
    test('running 携带 0-based stepIndex', () {
      final p = parseScriptProgress({
        'scriptId': 's1',
        'state': 'running',
        'stepIndex': 2,
      });
      expect(p.scriptId, 's1');
      expect(p.state, ScriptState.running);
      expect(p.stepIndex, 2);
      expect(p.isTerminal, isFalse);
      expect(shouldApplyProgress(p), isTrue);
    });

    test('done / stopped 都是终态', () {
      expect(parseScriptProgress({'state': 'done'}).isTerminal, isTrue);
      expect(parseScriptProgress({'state': 'stopped'}).isTerminal, isTrue);
    });

    test('未知状态一律不猜：shouldApplyProgress 为假', () {
      final p = parseScriptProgress({'scriptId': 's1', 'state': 'wat'});
      expect(p.state, ScriptState.unknown);
      expect(shouldApplyProgress(p), isFalse);
    });

    test('缺字段不崩：scriptId 空、stepIndex 空', () {
      final p = parseScriptProgress({});
      expect(p.scriptId, '');
      expect(p.stepIndex, isNull);
      expect(p.state, ScriptState.unknown);
      expect(shouldApplyProgress(p), isFalse);
    });
  });

  group('describeScriptProgress', () {
    test('运行中：总步数已知显示 N/M，未知只显示第 N 步', () {
      final p = parseScriptProgress({'state': 'running', 'stepIndex': 0});
      expect(describeScriptProgress(p, totalSteps: 3), '执行中 · 第 1/3 步');
      expect(describeScriptProgress(p), '执行中 · 第 1 步');
    });

    test('终态文案区分完成与终止', () {
      expect(describeScriptProgress(parseScriptProgress({'state': 'done'})),
          '已完成');
      expect(
          describeScriptProgress(parseScriptProgress({'state': 'stopped'})),
          '已终止');
    });
  });

  group('assistPermSummary', () {
    test('默认全关：明确说「未放行任何能力」而不是空串', () {
      expect(assistPermSummary(AssistPerms.none), '未放行任何能力');
    });

    test('放行后按 labels 列出；未放行的位不出现', () {
      final perms =
          AssistPerms.none.withFlag('media', true).withFlag('audit', true);
      final s = assistPermSummary(perms);
      expect(s, contains('播放音效'));
      expect(s, contains('查看审计日志'));
      expect(s, isNot(contains('视频通话')));
      expect(s, isNot('未放行任何能力'));
    });

    test('未登记的键名写不进权限位（失败关闭）', () {
      final perms = AssistPerms.none.withFlag('root', true);
      expect(perms.flag('root'), isFalse);
      expect(assistPermSummary(perms), '未放行任何能力');
    });
  });
}
