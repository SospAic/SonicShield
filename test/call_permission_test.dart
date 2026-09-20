import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/call_permission.dart';

/// BUG-062：「自动接通」在权限被拒时**静默假装开启**的回归锁。
///
/// 原实现 `await [camera, microphone].request();` 把结果**丢弃**，
/// 然后无条件 `setAutoAnswer(v)` —— 用户看到"已开启"，实际来电接不起来，
/// 而且没有任何提示。与 BUG-061 同判据：**失败必须让用户知道**。
void main() {
  test('AAP-01 麦克风被拒 -> micDenied（哪怕相机已授予）', () {
    expect(
      autoAnswerBlockFor(micGranted: false, cameraGranted: true),
      AutoAnswerBlock.micDenied,
    );
  });

  test('AAP-02 麦克风有、相机被拒 -> cameraDenied', () {
    expect(
      autoAnswerBlockFor(micGranted: true, cameraGranted: false),
      AutoAnswerBlock.cameraDenied,
    );
  });

  test('AAP-03 两个都授予 -> none', () {
    expect(
      autoAnswerBlockFor(micGranted: true, cameraGranted: true),
      AutoAnswerBlock.none,
    );
  });

  test('AAP-04 两个都被拒 -> 先报麦克风（更根本的那个）', () {
    expect(
      autoAnswerBlockFor(micGranted: false, cameraGranted: false),
      AutoAnswerBlock.micDenied,
    );
  });

  // ---- 展示/说明类：漏登记不编译报错，只能靠锁 ----
  test('AAP-05 每个失败分类都有非空文案（none 除外）', () {
    for (final b in AutoAnswerBlock.values) {
      final t = autoAnswerBlockText(b);
      if (b == AutoAnswerBlock.none) {
        expect(t, isEmpty);
      } else {
        expect(t.isNotEmpty, isTrue, reason: '$b 缺少用户可见的失败说明');
        // 要同时说清"缺什么"和"会怎样"，不能只说"失败"。
        expect(t.length, greaterThan(10), reason: '$b 文案说不清原因');
      }
    }
  });

  test('AAP-06 源码锁：文案是穷尽 switch 表达式（不得有兜底分支）', () {
    final src = File('lib/remote/call_permission.dart').readAsStringSync();
    final fn = src.substring(src.indexOf('String autoAnswerBlockText'));
    final body = fn.substring(0, fn.indexOf(';'));
    expect(body.contains('_ =>'), isFalse,
        reason: '`_ =>` 兜底会静默吃掉新增枚举值（BUG-058 同形状）');
    expect(body.contains('default:'), isFalse);
    // 反向自检：抓不到东西说明锁本身失效了。
    expect(body.contains('AutoAnswerBlock.none'), isTrue);
  });

  // ---- 调用点必须真的用上判定（防"改回丢弃结果"）----
  test('AAP-07 源码锁：_toggleAuto 必须调用 autoAnswerBlockFor', () {
    final src = File('lib/features/remote/call_screen.dart').readAsStringSync();
    final fn = src.substring(src.indexOf('Future<void> _toggleAuto'));
    final body = fn.substring(0, fn.indexOf('\n  }'));
    expect(body.contains('autoAnswerBlockFor'), isTrue,
        reason: '没有判定就等于把权限结果丢弃 —— BUG-062 会原样复发');

    // 也不得再出现"只 request 不看结果"的写法。
    // ⚠️ 判据不能只看"是否出现 `].request();`" —— 赋值给变量的写法
    // 同样含有它（`final status = await [...].request();`），那样会**恒红**。
    // 真正的丢弃特征是：**整条语句以 `await [` 开头**（没有赋值目标）。
    final reqLines =
        body.split('\n').where((l) => l.contains('.request()')).toList();
    expect(reqLines, isNotEmpty, reason: '没找到 request 调用 —— 锁本身失效了（自检）');
    final discarded =
        reqLines.where((l) => l.trimLeft().startsWith('await [')).toList();
    expect(discarded, isEmpty,
        reason: '以下语句只 request 不接结果 —— 权限被拒会静默失效：\n  '
            '${discarded.join('\n  ')}');
  });

  test('AAP-08 源码锁：对讲入口在权限被拒时必须给提示（不得静默 return）', () {
    final src =
        File('lib/features/remote/remote_screen.dart').readAsStringSync();
    final fn = src.substring(src.indexOf('Future<void> _pttSheet'));
    final body = fn.substring(0, fn.indexOf('\n  }'));
    expect(body.contains('showSnackBar'), isTrue,
        reason: '麦克风被拒时若不提示，用户点了「对讲」会毫无反应');
    expect(body.contains('需要麦克风权限'), isTrue);
  });
}
