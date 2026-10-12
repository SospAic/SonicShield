import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/protocol.dart';

/// 远程桌面级控制（docs/25）**契约锁**。
///
/// ## 它防的是什么（两类静默失败）
/// 1. **权限位漏登记**：`RcPermGate.requiredPerm` 对**未登记**命令返回 `denyAll`
///    （默认拒绝）。新命令忘记登记 ⇒ 端点**永远拒绝**它，而控制器只会等到超时 ——
///    完全分不清"没收到 / 不认识 / 没权限"。这是本仓库反复踩过的形状
///    （docs/14 的"未知命令静默忽略"）。
/// 2. **协议常量漂移**：命令/事件字面量是**跨端约定**（控制端与端点必须逐字一致），
///    改错一个字母 = "命令发不出去且无任何报错"（与 `PairQrProtocol` 大小写
///    归一化同一族：**写在一处、用在另一处**的字符串必须有锁）。
void main() {
  group('RDP · 远程桌面级控制契约（docs/25）', () {
    test('RDP-01 命令 / 事件字面量固定（跨端约定，改错即静默失联）', () {
      expect(RcCmd.screenCastRequest, 'screen.cast.request');
      expect(RcCmd.screenCastStop, 'screen.cast.stop');
      expect(RcCmd.inputTap, 'input.tap');
      expect(RcCmd.inputSwipe, 'input.swipe');
      expect(RcCmd.inputKey, 'input.key');
      expect(RcCmd.inputText, 'input.text');
      expect(RcEvt.screen, 'rc.screen');
      expect(RcEvt.inputAck, 'rc.inputAck');
    });

    test('RDP-02 ★ 全部控制命令必须登记权限位 = script（漏登记即 denyAll 永久拒绝）', () {
      const cmds = <String>[
        RcCmd.screenCastRequest,
        RcCmd.screenCastStop,
        RcCmd.inputTap,
        RcCmd.inputSwipe,
        RcCmd.inputKey,
        RcCmd.inputText,
      ];
      for (final c in cmds) {
        expect(RcPermGate.requiredPerm(c), 'script',
            reason: '$c 未登记 ⇒ requiredPerm 返回 denyAll ⇒ 端点永久拒绝（静默）');
      }
    });

    test('RDP-03 有 script 位才放行；无 script 位一律拒（默认拒绝）', () {
      const withScript = AssistPerms(script: true);
      const without = AssistPerms();
      const cmds = <String>[
        RcCmd.screenCastRequest,
        RcCmd.screenCastStop,
        RcCmd.inputTap,
        RcCmd.inputSwipe,
        RcCmd.inputKey,
        RcCmd.inputText,
      ];
      for (final c in cmds) {
        expect(RcPermGate.allows(withScript, c), isTrue, reason: '$c 应放行');
        expect(RcPermGate.allows(without, c), isFalse,
            reason: '$c 无 script 位必须拒（输入注入是最高危能力）');
      }
    });

    test('RDP-04 反例证伪：未登记的自造命令必须落到 denyAll（判据非恒真）', () {
      expect(RcPermGate.requiredPerm('screen.cast.__nope__'), RcPermGate.denyAll);
      expect(RcPermGate.allows(const AssistPerms(script: true),
          'screen.cast.__nope__'), isFalse,
          reason: '未登记命令即使有 script 位也必须拒 —— 默认拒绝不是"默认放行"');
    });
  });
}
