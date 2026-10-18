import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';

import 'support/source_text.dart';

void main() {
  group('R-4 终态载荷（纯函数）', () {
    test('RSS-01 state 映射：done ⇒ done，未完成 ⇒ stopped', () {
      expect(rcScriptStatePayload('s1', done: true)['state'], 'done');
      expect(rcScriptStatePayload('s1', done: false)['state'], 'stopped');
      expect(rcScriptStatePayload('s1', done: true)['scriptId'], 's1');
    });

    test('RSS-02 skipped 恒定存在（消费端不必区分"字段缺失"与"没有跳过"）', () {
      final p = rcScriptStatePayload('s1', done: true);
      expect(p.containsKey('skipped'), isTrue);
      expect(p['skipped'], isEmpty);
    });

    test('RSS-03 skipped 原样透传（顺序即步骤顺序）', () {
      final notes = ['步骤 2（record）未执行：麦克风权限未授予', '步骤 3（play）未执行：端点音源库为空'];
      final p = rcScriptStatePayload('s1', done: true, skipped: notes);
      expect(p['skipped'], notes);
      expect(p['state'], 'done',
          reason: '有跳过步骤时**仍**是 done（跑完了）；'
              '是 skipped 在说明"没全做成"，而不是把状态改成 stopped —— '
              '把两者混为一谈会让控制端分不清"被打断"与"跳了几步"');
    });
  });

  group('R-4 端点侧接线锁（源码契约）', () {
    final src = File('lib/remote/endpoint_service.dart').readAsStringSync();
    // BUG-121：一次脚本执行被拆成三段 ——
    // ① `_tryClaimScript`（检查 + 占位，**同步**原子段）
    // ② `_runScript`（占位失败的回执；占位成功后进实跑段）
    // ③ `_runClaimedScript`（heads-up / runner / 终态广播）
    // 这些锁的**语义范围**是"一次脚本执行"，故按源码顺序拼接起来看 ——
    // 拼接顺序即运行时顺序，`guard < success` / `guard < run` 这类顺序断言仍然成立。
    final runScript = methodBody(src, 'bool _tryClaimScript() {') +
        methodBody(src, 'Future<void> _runScript(') +
        methodBody(src, 'Future<void> _runClaimedScript(');
    final runner = methodBody(runScript, 'Future<void> runner(RcStep step)');

    test('RSS-04 ⚠️ "已在跑"的判定必须在 success 审计**之前**', () {
      final guard = runScript.indexOf('RcScriptExecutor.instance.isRunning');
      final success = runScript.indexOf("status: 'success'");
      expect(guard, greaterThanOrEqualTo(0),
          reason: '没有前置判定 ⇒ 第二条指令组照旧被 run() 静默拒绝，'
              '却先写了一条 success 审计');
      expect(success, greaterThanOrEqualTo(0));
      expect(guard, lessThan(success),
          reason: '顺序反了：先写 success 再判"已在跑" ⇒ 审计里躺着假成功（R-4①）');
    });

    test('RSS-05 ⚠️ "已在跑"的判定必须在 run() **之前**', () {
      final guard = runScript.indexOf('RcScriptExecutor.instance.isRunning');
      final run = runScript.indexOf('RcScriptExecutor.instance.run(');
      expect(run, greaterThanOrEqualTo(0));
      expect(guard, lessThan(run),
          reason: '放到 run() 之后就拦不住任何东西：run() 会返回 false，'
              '而 false 同时意味着"被终止"，于是第二条被报成 stopped（本缺陷）');
    });

    test('RSS-06 已在跑时显式回执 ok=false（不能静默）', () {
      expect(runScript, contains("_ack(msg, false, data: '已有指令组在执行')"));
      expect(runScript, contains("status: 'skipped'"));
    });

    test('RSS-07 终态事件带上 skipped（用纯函数构造，映射只有一处）', () {
      expect(runScript, contains('rcScriptStatePayload(script.scriptId'),
          reason: '终态必须走纯函数构造，否则 done/stopped 与 skipped 会各写一份');
      expect(runScript, contains('skipped: stepNotes'));
      expect(runScript, isNot(contains("'state': done ? 'done' : 'stopped'")),
          reason: '旧形状（内联三元 + 无 skipped）不应残留');
    });

    test('RSS-08 runner 把被拒步骤记进 stepNotes（不只是写审计）', () {
      expect(runner, contains('stepNotes.add('),
          reason: '只写审计 ⇒ 控制端仍只看到 state:done');
      final add = runner.indexOf('stepNotes.add(');
      final verdict = runner.indexOf('verdict.reason');
      expect(add, greaterThanOrEqualTo(0));
      expect(verdict, greaterThan(add),
          reason: '权限拒绝分支必须同时进 stepNotes 与审计（两者缺一都是静默）');
    });

    test('RSS-09 四条"没做成"的路径都进 stepNotes', () {
      // ⚠️ 数**调用次数**而不是"含某个词"：`（play）未执行` 这个短语在紧随其后的
      // `logs.append` 里也出现，只断言"包含它"会在删掉 stepNotes 那一行后**照样绿**
      // （实测踩到：M13 变异存活）。三条内联路径 = 权限拒绝 / play / tts。
      final adds = 'stepNotes.add('.allMatches(runner).length;
      expect(adds, greaterThanOrEqualTo(3),
          reason: '权限拒绝 / play 无音源 / tts 无处理器 三条路径都要进 stepNotes；'
              '只写审计 ⇒ 控制端仍只看到 state:done');
      expect(runner, contains('（play）未执行'),
          reason: 'play 静默什么都不放 = 承诺了没做到');
      expect(runner, contains('（tts）未执行'));
      // vibrate 走 _runVibrateStep，把 stepNotes 传下去
      expect(runner, contains('stepNotes)'),
          reason: '振动步必须把 stepNotes 传进 _runVibrateStep');
      // ⚠️ 参数表不在 methodBody 的返回范围里，故这两条断言查**整份源码**。
      expect(src, contains('List<String> stepNotes'),
          reason: '振动跳过（未接线/未注入处理器）此前只写审计，控制端看不到');
      expect(methodBody(src, 'Future<void> _runVibrateStep('),
          contains('stepNotes.add('));
      // record 走 _recordEvidence
      expect(src, contains('List<String>? stepNotes'),
          reason: '录音无权限/异常此前只写端点审计，控制端看不到');
      expect(methodBody(src, 'Future<void> _recordEvidence({'),
          contains('stepNotes?.add('));
      expect(runner, contains('stepNotes: stepNotes'),
          reason: 'record 步必须把 stepNotes 传进 _recordEvidence');
    });

    test('RSS-10 ⚠️ 不新增第二种回执形状：record 的结果**不单独发 ack**', () {
      final record = methodBody(src, 'Future<void> _recordEvidence({');
      expect(record, isNot(contains('_ack(')),
          reason: '录音结果若单独发 ack，控制端就要处理两种回执 —— '
              '它只需读终态的 skipped 列表（R-4③）');
    });

    test('RSS-11 ⚠️「检查 + 占位」必须在同一个同步段里（BUG-121）', () {
      final claim = methodBody(src, 'bool _tryClaimScript() {');
      expect(claim, contains('RcScriptExecutor.instance.isRunning'),
          reason: '检查被搬走后，闸门就不再是同一个原子段');
      expect(claim, contains('_scriptClaimed = true;'));
      expect(claim, isNot(contains('await ')),
          reason: '预占方法里出现 await ⇒ 两台控制端可同时穿过闸门：'
              '先到者起跑、后到者 run() 返回 false 却被记成 success（BUG-121 原症状）');
      // 置位/释放各只一处，否则"原子段"的前提不成立。
      // ⚠️ 释放只能在 `_runScript` 体内数 —— 字段声明 `bool _scriptClaimed = false;`
      // 本身就含 `_scriptClaimed = false;` 这个子串，扫全文会多数一个。
      final body = methodBody(src, 'Future<void> _runScript(');
      expect('_scriptClaimed = true;'.allMatches(src).length, 1);
      expect('_scriptClaimed = false;'.allMatches(body).length, 1);
      // 预占必须先于实跑段；释放必须在 finally（异常逃逸也要放锁）
      expect(body.indexOf('_tryClaimScript()'),
          lessThan(body.indexOf('_runClaimedScript(')),
          reason: '先占位再进实跑段；反过来等于没占位');
      final fin = body.indexOf('finally');
      expect(fin, greaterThan(body.indexOf('_runClaimedScript(')),
          reason: '漏释放预占 ⇒ 一次异常就让脚本功能永久锁死');
      expect(body.indexOf('_scriptClaimed = false;'), greaterThan(fin),
          reason: '释放必须写在 finally 里，不能写在 try 末尾');
    });
  });
}
