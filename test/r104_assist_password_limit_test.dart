// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/assist_join_screen.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_join.dart';

/// R104 / BUG-152,153 回归锁：协助会话凭据输入框的**全部**协议参数
/// 必须由 `RcAssist` 真源派生，且用户敲进去的字符不会被静默吞掉。
///
/// ## 两个缺陷（同一次用户动作：照着端点屏幕敲密码）
/// - BUG-152：R94 / REM-04 把访问密码 8 → 12 位，改了协议、生成、校验、
///   端点侧与页面文案，却漏改 `LengthLimitingTextInputFormatter(8)`。
///   端点显示 12 位，控制端最多只能输 8 位 ⇒ `join()` 必报
///   「访问密码应为 12 位」，协助会话整体不可用。
/// - BUG-153：同一输入框的 `allow(RegExp(r'[A-Za-z0-9]'))` 放行
///   I/L/O/U/0/1，而 `normalizePassword` 会**静默剔除**它们 ——
///   用户看着框里已经 12 位，校验仍失败且看不到字符被吞。
///
/// 修法不是把 8 改成 12、把正则改严就完事（那还会再漂移一次），
/// 而是把位数与字母表**导出成协议真源的只读视图**，UI 一律引用；
/// 本锁用「源码契约 + 反面样本 + 真实 enterText」三层钉死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uiPath = 'lib/features/remote/assist_join_screen.dart';

  Future<void> pumpJoin(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final client = AssistJoinClient();
    addTearDown(() => client.leave(silent: true));
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: AssistJoinScreen(client: client)),
    ));
    await tester.pump();
    await tester.pump();
  }

  String typedPassword(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).last).controller?.text ?? '';

  group('SIM-ASSIST 协助会话凭据输入（R104 / BUG-152,153）', () {
    testWidgets('SIM-ASSIST-01 协议生成的 12 位合法密码能完整输入',
        (tester) async {
      await pumpJoin(tester);
      final pw = RcAssist.generatePassword();
      expect(pw.length, RcAssist.passwordLength,
          reason: '协议真源：访问密码位数以 RcAssist.passwordLength 为准');
      expect(RcAssist.isValidPassword(pw), isTrue);

      // ★ 真实用户动作：把端点屏幕上的密码逐字敲进第二个输入框。
      await tester.enterText(find.byType(TextField).last, pw);
      await tester.pump();

      final typed = typedPassword(tester);
      expect(typed.length, RcAssist.passwordLength,
          reason: 'BUG-152 复发：输入框把合法密码截断了，用户永远接不进会话');
      expect(typed, pw);
      expect(RcAssist.isValidPassword(RcAssist.normalizePassword(typed)), isTrue,
          reason: '输入内容必须仍是一条能被 join() 接受的合法密码');
    });

    testWidgets('SIM-ASSIST-01b 小写合法字符可输入，且 normalize 不再吞字符',
        (tester) async {
      await pumpJoin(tester);
      // 端点口述时用户常直接敲小写；normalizePassword 负责转大写。
      const lower = 'abcdefghjkmn';
      await tester.enterText(find.byType(TextField).last, lower);
      await tester.pump();

      final typed = typedPassword(tester);
      expect(typed.length, RcAssist.passwordLength);
      expect(RcAssist.isValidPassword(RcAssist.normalizePassword(typed)), isTrue,
          reason: '小写输入经归一后必须是一条完整合法密码');
    });

    testWidgets('SIM-ASSIST-01c 易混字符被白名单当场拦下（BUG-153）',
        (tester) async {
      await pumpJoin(tester);
      // 旧白名单 [A-Za-z0-9] 会全放行这些字符，随后 normalizePassword
      // 静默剔除 ⇒ 用户看到 10 位、提交时却只剩 4 位，且没有任何提示。
      const raw = 'ILOU01ABCD';
      await tester.enterText(find.byType(TextField).last, raw);
      await tester.pump();

      final typed = typedPassword(tester);
      expect(typed, 'ABCD',
          reason: 'I/L/O/U/0/1 必须在输入阶段就被挡掉，不能等到校验才消失');
      expect(RcAssist.normalizePassword(typed), typed.toUpperCase(),
          reason: '用户看到的字符 = 实际提交的字符：不允许任何静默吞字');
    });

    test('SIM-ASSIST-02 源码契约：UI 不得硬编码任何协议参数', () {
      final f = File(uiPath);
      expect(f.existsSync(), isTrue, reason: '找不到被测 UI 文件');
      final src = f.readAsStringSync();

      expect(
          src,
          isNot(contains(RegExp(r'LengthLimitingTextInputFormatter\(\d+\)'))),
          reason: '位数必须引用 RcAssist.*Length；硬编码就是下一次 R94 漏改');
      expect(src, contains('RcAssist.codeLength'));
      expect(src, contains('RcAssist.passwordLength'));
      expect(src, contains('RcAssist.passwordInputPattern'));
      expect(src, isNot(contains('[A-Za-z0-9]')),
          reason: '宽松白名单会放行易混字符（BUG-153）');

      // 文案里的位数同样不许与真源脱钩。
      final m = RegExp(r"labelText: '访问密码（(\d+) 位）'").firstMatch(src);
      expect(m, isNotNull, reason: '找不到密码框位数文案，锁会空转');
      expect(int.parse(m!.group(1)!), RcAssist.passwordLength,
          reason: '协议位数变了，页面文案必须一起变');
    });

    test('SIM-ASSIST-03 协议视图与私有真源逐位一致', () {
      expect(RcAssist.passwordLength, 12);
      expect(RcAssist.codeLength, 9);
      expect(RcAssist.generatePassword().length, RcAssist.passwordLength);
      expect(RcAssist.generateCode().length, RcAssist.codeLength);

      final allowed = RegExp('^${RcAssist.passwordInputPattern}+\$');
      final pw = RcAssist.generatePassword();
      expect(allowed.hasMatch(pw), isTrue,
          reason: '协议生成的每个字符都必须能被 UI 输入');
      expect(allowed.hasMatch(pw.toLowerCase()), isTrue,
          reason: '小写输入也必须允许（normalize 会转大写）');
      for (final c in 'ILOU01'.split('')) {
        expect(allowed.hasMatch(c), isFalse,
            reason: '易混字符 $c 必须被 UI 白名单挡住');
      }
    });

    test('SIM-ASSIST-90 反面样本：硬编码旧上限 8 能被判红', () {
      final src = File(uiPath).readAsStringSync();
      final reverted = src.replaceFirst(
          'LengthLimitingTextInputFormatter(RcAssist.passwordLength)',
          'LengthLimitingTextInputFormatter(8)');
      expect(reverted, isNot(src), reason: '反面样本构造失败 ⇒ 锁失去意义');
      expect(reverted, contains(RegExp(r'LengthLimitingTextInputFormatter\(\d+\)')),
          reason: '还原成 BUG-152 后必须能被 SIM-ASSIST-02 抓到');
    });

    test('SIM-ASSIST-91 反面样本：宽松白名单能被判红', () {
      final src = File(uiPath).readAsStringSync();
      final reverted = src.replaceFirst(
          'RegExp(RcAssist.passwordInputPattern)',
          "RegExp(r'[A-Za-z0-9]')");
      expect(reverted, isNot(src), reason: '反面样本构造失败 ⇒ 锁失去意义');
      expect(reverted, contains('[A-Za-z0-9]'),
          reason: '还原成 BUG-153 后必须能被 SIM-ASSIST-02 抓到');
    });
  });
}