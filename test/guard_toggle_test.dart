import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/features/guard/guard_toggle.dart';

/// 守卫开关失败路径的回归锁（BUG-061）。
///
/// BUG-061 的形状：**三条失败路径全部静默** —— 开关弹回、页面无任何提示。
/// 真机探针实测：点开关后 value 保持 false、`mgr.last == null`，页面零解释。
///
/// 这些锁用**假依赖**驱动 `toggleGuard()`，因此每条失败路径都能在 host
/// 单测里真实触发（不需要真机引擎），并且能被变异证伪。
void main() {
  /// 记录被调用过的方法，用于断言"失败时不能再往下走"。
  final calls = <String>[];

  Future<GuardToggleFailure> run({
    required bool wanted,
    required bool engineRunning,
    bool micGranted = true,
    bool stateConfirms = true,
  }) async {
    calls.clear();
    return toggleGuard(
      wanted: wanted,
      engineRunning: engineRunning,
      requestMic: () async {
        calls.add('requestMic');
        return micGranted;
      },
      persist: () async {
        calls.add('persist');
      },
      startMicService: () async {
        calls.add('startMicService');
      },
      stopMicService: () async {
        calls.add('stopMicService');
      },
      setGuard: (v) async {
        calls.add('setGuard:$v');
      },
      waitForGuardActive: (expected) async {
        calls.add('wait:$expected');
        return stateConfirms;
      },
    );
  }

  test('GTO-01 引擎未运行 + 想开 -> engineNotRunning，且不下发命令', () async {
    final r = await run(wanted: true, engineRunning: false);
    expect(r, GuardToggleFailure.engineNotRunning);
    // 关键点：引擎没跑时 setGuard 是 no-op，不该假装下发过。
    expect(calls, isEmpty, reason: '引擎没跑时连权限都不该问，更不该 setGuard');
  });

  test('GTO-02 麦克风被拒 -> micDenied，且不下发命令', () async {
    final r = await run(wanted: true, engineRunning: true, micGranted: false);
    expect(r, GuardToggleFailure.micDenied);
    expect(calls, ['requestMic']);
    expect(calls.contains('setGuard:true'), isFalse);
  });

  test('GTO-03 下发后引擎未回投 -> engineNoResponse', () async {
    final r =
        await run(wanted: true, engineRunning: true, stateConfirms: false);
    expect(r, GuardToggleFailure.engineNoResponse);
    // 命令确实下发过，但没生效 —— 必须报出来，不能静默。
    expect(calls.contains('setGuard:true'), isTrue);
  });

  test('GTO-04 全部顺利 -> none', () async {
    final r = await run(wanted: true, engineRunning: true);
    expect(r, GuardToggleFailure.none);
    expect(calls.contains('persist'), isTrue);
    expect(calls.contains('startMicService'), isTrue);
    expect(calls.contains('setGuard:true'), isTrue);
  });

  test('GTO-05 关闭不要求引擎在跑、也不问麦克风', () async {
    final r = await run(wanted: false, engineRunning: false);
    expect(r, GuardToggleFailure.none);
    expect(calls.contains('requestMic'), isFalse);
    expect(calls.contains('stopMicService'), isTrue);
    expect(calls.contains('setGuard:false'), isTrue);
  });

  // ---- 展示/说明类查表：漏登记不编译报错，只能靠锁 ----
  test('GTO-06 每个失败分类都有非空文案（none 除外）', () {
    for (final f in GuardToggleFailure.values) {
      final t = guardFailureText(f);
      if (f == GuardToggleFailure.none) {
        expect(t, isEmpty);
      } else {
        expect(t.isNotEmpty, isTrue, reason: '$f 缺少用户可见的失败说明');
        // 文案要说清"该做什么"，不能只说"失败"。
        expect(t.length, greaterThan(8), reason: '$f 文案太短，说不清原因');
      }
    }
  });

  test('GTO-07 源码锁：失败文案必须是穷尽 switch 表达式（不得有兜底分支）', () {
    final src = File('lib/features/guard/guard_toggle.dart').readAsStringSync();
    final fn = src.substring(src.indexOf('String guardFailureText'));
    final body = fn.substring(0, fn.indexOf(';'));
    expect(body.contains('_ =>'), isFalse,
        reason: '出现 `_ =>` 兜底会静默吃掉新增枚举值（BUG-058 同形状）');
    expect(body.contains('default:'), isFalse,
        reason: 'default 兜底同样会让新枚举值没有专属文案');
    // 反向自检：锁本身要是抓不到东西就毫无意义。
    expect(body.contains('GuardToggleFailure.none'), isTrue);
  });
}
