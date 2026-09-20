import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sonic_shield/remote/script_progress.dart';

/// `rc.script`（`RcEvt.scriptState`）**主叫侧进度**的宿主侧回归锁。
///
/// ## 为什么要有这个文件
///
/// 协议三向覆盖锁（`rc_protocol_coverage_test.dart`）会检查"每个事件在 App 内
/// 都有消费者"，但它只能检查**有没有引用**，检查不了**消费得对不对**。
/// 而"消费得对不对"恰恰是最容易出错的地方：端点将来新增一个 `state` 值时，
/// 若主叫侧把它猜成"完成"，进度卡会**假装完成**；猜成"运行中"则**永远转圈**。
///
/// 所以这里锁两件事：
/// 1. 纯逻辑层对**未知状态**必须"什么都不做"（`shouldApplyProgress == false`）；
/// 2. UI 层必须**真的调用**那个判定 —— 否则纯函数写得再对也没人用
///    （BUG-048 / BUG-056 的教训：值算得出、读得到，但没人用）。
void main() {
  /// 剥掉行注释 —— 源码契约锁必须防止被"注释掉的代码"骗过。
  String code(String src) => src
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i < 0 ? l : l.substring(0, i);
      })
      .join('\n');

  /// 大括号配对抽方法体，让断言限定在**单个方法**内
  /// （文件级 `contains` 会被同文件其它方法误伤）。
  ///
  /// ⚠️ 两个坑都真实踩过，且都会让断言**静默失效**：
  /// 1. 不能取"签名后的第一个 `{`" —— Dart 的**具名参数**也用大括号
  ///    （`String f(int a, {int? b}) { ... }`），会抽到参数列表；
  /// 2. 不能取"后一个前面是 `)` 的 `{`" —— `) async {` 的 `{` 前面是 `async`。
  ///
  /// 正确做法：先按括号配对**跳过整个参数表**，再取其后第一个 `{`。
  /// 自检见本文件 SP-11。
  String methodBody(String src, String signature) {
    final i = src.indexOf(signature);
    if (i < 0) throw StateError('找不到 `$signature`');
    // 1) 跳过参数表（具名参数的 `{}` 也一并配对掉）
    var depth = 0;
    var k = src.indexOf('(', i + signature.length - 1);
    if (k < 0) throw StateError('`$signature` 后面找不到 `(`');
    for (; k < src.length; k++) {
      final c = src[k];
      if (c == '(' || c == '[' || c == '{') {
        depth++;
      } else if (c == ')' || c == ']' || c == '}') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (depth != 0) throw StateError('`$signature` 的参数表未闭合');
    // 2) 参数表之后的第一个 `{` 即方法体
    final open = src.indexOf('{', k);
    if (open < 0) throw StateError('`$signature` 没有函数体');
    if (src.substring(k, open).contains('=>')) {
      throw StateError('`$signature` 是表达式体（`=>`），本工具只支持块体');
    }
    // 3) 大括号配对
    var d = 0;
    for (var j = open; j < src.length; j++) {
      final c = src[j];
      if (c == '{') {
        d++;
      } else if (c == '}') {
        d--;
        if (d == 0) return src.substring(open, j + 1);
      }
    }
    throw StateError('`$signature` 的函数体未闭合');
  }

  group('SP 进度解析（纯逻辑）', () {
    test('SP-01 running 带 0-based stepIndex → 显示为 1-based「第 n/N 步」', () {
      final p = parseScriptProgress(
          const {'scriptId': 's1', 'state': 'running', 'stepIndex': 0});
      expect(p.state, ScriptState.running);
      expect(p.scriptId, 's1');
      expect(p.stepIndex, 0);
      expect(describeScriptProgress(p, totalSteps: 3), '执行中 · 第 1/3 步');
    });

    test('SP-02 模板不在本机（总步数未知）时只显示「第 n 步」', () {
      final p = parseScriptProgress(
          const {'scriptId': 's2', 'state': 'running', 'stepIndex': 4});
      expect(describeScriptProgress(p), '执行中 · 第 5 步');
    });

    test('SP-03 done / stopped 都是终止态，文案不得混用', () {
      final done = parseScriptProgress(const {'scriptId': 's', 'state': 'done'});
      final stopped =
          parseScriptProgress(const {'scriptId': 's', 'state': 'stopped'});
      expect(done.isTerminal, isTrue);
      expect(stopped.isTerminal, isTrue);
      expect(describeScriptProgress(done), '已完成');
      expect(describeScriptProgress(stopped), '已终止');
      // 终止事件不带 stepIndex → 不能残留上一次的步数文案
      expect(describeScriptProgress(done, totalSteps: 3), '已完成');
    });

    test('SP-04 未知 state → unknown，且**不猜**（不谎报完成、不谎报终止）', () {
      for (final raw in const ['paused', '', 'RUNNING', 'DONE']) {
        final p = parseScriptProgress({'scriptId': 's', 'state': raw});
        expect(p.state, ScriptState.unknown,
            reason: '`$raw` 不是协议已知状态，必须映射为 unknown');
        expect(shouldApplyProgress(p), isFalse,
            reason: '未知状态必须"什么都不做"，否则 UI 会显示错误进度');
        final text = describeScriptProgress(p, totalSteps: 3);
        expect(text.contains('完成'), isFalse);
        expect(text.contains('终止'), isFalse);
      }
    });

    test('SP-05 缺 state / 缺 scriptId 不抛异常（载荷残缺也要稳）', () {
      final p = parseScriptProgress(const {});
      expect(p.state, ScriptState.unknown);
      expect(p.scriptId, '');
      expect(shouldApplyProgress(p), isFalse);
    });

    test('SP-06 已知状态一律应当被应用（防 shouldApplyProgress 恒假）', () {
      for (final raw in const ['running', 'done', 'stopped']) {
        final p = parseScriptProgress({'scriptId': 's', 'state': raw});
        expect(shouldApplyProgress(p), isTrue, reason: '`$raw` 应当被应用');
      }
    });
  });

  group('SP 源码契约锁（穷尽性与接线）', () {
    final logic = File('lib/remote/script_progress.dart').readAsStringSync();
    final tab =
        File('lib/features/remote/remote_scripts_tab.dart').readAsStringSync();

    test('SP-07 describeScriptProgress 必须穷尽 ScriptState（不得有 default:）', () {
      final body = code(methodBody(logic, 'String describeScriptProgress('));
      for (final v in ScriptState.values) {
        // ⚠️ 必须用 `v.name`：`'$v'` 会插值成 `ScriptState.running`，
        // 于是 `'ScriptState.$v'` 变成 `ScriptState.ScriptState.running`
        // —— 恒假断言（本条最初就是这么写错的）。
        expect(body.contains('ScriptState.${v.name}'), isTrue,
            reason: '`ScriptState.${v.name}` 没有出现在 describeScriptProgress 里 —— '
                '新增状态必须显式处理，否则会静默沿用兜底文案');
      }
      expect(body.contains('default:'), isFalse,
          reason: '判定类 switch 必须穷尽、不得写 `default:` —— '
              '`default:` 会让新增状态**静默走兜底**而不是编译报错');
    });

    test('SP-08 UI 层必须消费 RcEvt.scriptState（否则纯逻辑没人用）', () {
      final body = code(methodBody(tab, 'void _onEvent('));
      expect(body.contains('RcEvt.scriptState'), isTrue,
          reason: '_onEvent 没有过滤 rc.script —— 进度事件会被丢弃');
    });

    test('SP-09 UI 层必须调用 shouldApplyProgress（未知状态不得直接落库）', () {
      final body = code(methodBody(tab, 'void _onEvent('));
      expect(body.contains('shouldApplyProgress'), isTrue,
          reason: 'UI 直接 `_progress[...] = p` 而不经判定，会让未知状态'
              '被当成已知状态显示 —— 纯逻辑层的防护形同虚设');
    });

    test('SP-10 进度卡必须真的渲染（不能只存状态不显示）', () {
      final src = code(tab);
      expect(src.contains('describeScriptProgress'), isTrue,
          reason: '界面没有用 describeScriptProgress 渲染进度文案 —— '
              '事件被消费了但用户看不到，等于没修');
      expect(src.contains('_active'), isTrue,
          reason: '缺少"正在执行的指令组"面板');
    });

    test('SP-11 【工具自检】methodBody 必须能跳过具名参数与 `async`', () {
      // 这条锁的是**工具本身**。`methodBody` 写错过两次，两次都会让本文件的
      // 源码契约锁**静默失效**（断言还在、测试还绿，但已经没在测任何东西）：
      //   ① 取"签名后第一个 `{`" → 抽到具名参数列表；
      //   ② 取"前面是 `)` 的 `{`" → `) async {` 的 `{` 前面是 `async`，被跳过。
      //
      // 判据必须**只在方法体里出现、不在参数表里出现**的 token。
      final lifecycle =
          File('lib/remote/call_lifecycle.dart').readAsStringSync();
      // 具名参数：参数表里有 `autoAnswer`，方法体里才有 `rejectBusy`
      final a = code(methodBody(lifecycle, 'CalleeAction calleeActionFor('));
      expect(a, contains('rejectBusy'),
          reason: 'methodBody 抽到的是具名参数列表而不是方法体');
      // async 块体：方法体里才有 `ringUser` 相关判定
      final ep = File('lib/remote/endpoint_service.dart').readAsStringSync();
      final b = code(
          methodBody(ep, 'Future<void> _handleCallInvite('));
      expect(b, contains('onIncomingCall'),
          reason: 'methodBody 没能跳过 `) async {` —— 抽到的不是方法体');
    });
  });
}
