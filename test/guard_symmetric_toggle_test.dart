import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/features/guard/guard_toggle.dart';

import 'support/source_text.dart';

/// 守卫开关 **开 / 关对称性** 的回归锁（v1.10）。
///
/// ## 为什么需要这一组（真机取证）
///
/// | 设备 | 现象 | 取证 |
/// |---|---|---|
/// | Mi 14 Pro（Android 16 / API 36） | 引擎开关、守卫开关**都打不开** | logcat `[sonic_shield][engine] unhandled: DatabaseException(no such column: quiet_exempt)`；`shared_prefs` 里 `should_run=true`、`guard_enabled=true`；`exec_logs` 里**没有** guard 行 |
/// | MI MAX 2（API 25） | 守卫**开了关不掉** | `exec_logs`: `guard · start · failed · 麦克风权限被拒`，而 `dumpsys package` 显示 `RECORD_AUDIO: granted=true` |
///
/// 三处结构性缺陷（都能在 host 上断言，不需要真机）：
/// 1. 关闭分支**不做引擎侧确认**（`toggleGuard` 的 `else` 只 stop 本地）；
/// 2. 引擎 `broadcast()` 把 `running` 写死 `true`，且 `service.on('stop')`
///    **从不回投** `running:false` ⇒ 引擎开关永远关不掉；
/// 3. 引擎启动序列串行裸调 `replan()`，任一步抛出就跳过末尾的 `broadcast()`
///    ⇒ UI 永远看不到 `running:true` ⇒ 开关打不开。
void main() {
  final calls = <String>[];

  Future<GuardToggleOutcome> run({
    required bool wanted,
    required bool engineRunning,
    bool stateConfirms = true,
    bool micGranted = true,
    Object? throwOn,
    String? guardError,
  }) async {
    calls.clear();
    return toggleGuard(
      wanted: wanted,
      engineRunning: engineRunning,
      requestMic: () async {
        calls.add('requestMic');
        if (throwOn == 'requestMic') throw StateError('权限弹窗被打断');
        return micGranted;
      },
      persist: () async => calls.add('persist'),
      startMicService: () async {
        calls.add('startMicService');
        if (throwOn == 'startMicService') {
          throw StateError('前台服务启动被系统拒绝');
        }
      },
      stopMicService: () async {
        calls.add('stopMicService');
        if (throwOn == 'stopMicService') throw StateError('原生桥不可用');
      },
      setGuard: (v) async => calls.add('setGuard:$v'),
      waitForGuardActive: (expected) async {
        calls.add('wait:$expected');
        return stateConfirms;
      },
      lastGuardError: () => guardError,
    );
  }

  test('GTX-01 关闭 + 引擎在跑 + 引擎不确认 -> engineNoResponse（旧实现会静默返回 none）',
      () async {
    final r = await run(wanted: false, engineRunning: true, stateConfirms: false);
    expect(r.failure, GuardToggleFailure.engineNoResponse,
        reason: '引擎侧没确认停就报成功 = 界面显示已关闭、麦克风可能还在采（最危险的一类不一致）');
    expect(calls.contains('wait:false'), isTrue, reason: '必须真的去等引擎回投');
    // 停止方向走安全侧：无论引擎是否确认，都要撤掉麦克风通行证。
    expect(calls.contains('stopMicService'), isTrue);
  });

  test('GTX-02 关闭 + 引擎在跑 + 引擎确认 -> none', () async {
    final r = await run(wanted: false, engineRunning: true);
    expect(r.failure, GuardToggleFailure.none);
    // 顺序：先让引擎停，再撤麦克风通行证。
    expect(calls.indexOf('setGuard:false') < calls.indexOf('stopMicService'),
        isTrue, reason: '先撤通行证再停引擎会留下"通行证没了、引擎还在收流"的中间态');
    expect(calls.contains('wait:false'), isTrue);
  });

  test('GTX-03 startMicService 抛异常 -> unexpected（必须可见，不得静默弹回）', () async {
    final r = await run(
        wanted: true, engineRunning: true, throwOn: 'startMicService');
    expect(r.failure, GuardToggleFailure.unexpected,
        reason: 'BUG-061 的残留形状：异常穿透 onChanged ⇒ 开关弹回且零提示');
    expect(r.text.contains('前台服务启动被系统拒绝'), isTrue,
        reason: '异常原因必须原样转达给用户，而不是换成一句笼统的话');
  });

  test('GTX-04 引擎明确报出启动失败 -> guardStartFailed 且原因原样透传', () async {
    final r = await run(
      wanted: true,
      engineRunning: true,
      stateConfirms: false,
      guardError: '麦克风启动失败：PlatformException(AudioRecord init failed)',
    );
    expect(r.failure, GuardToggleFailure.guardStartFailed);
    expect(r.text.contains('AudioRecord init failed'), isTrue,
        reason: '引擎已经说清了原因，UI 不该退化成"引擎无响应"');
    // 反向自检：没有原因时才允许报 engineNoResponse。
    final r2 = await run(
        wanted: true, engineRunning: true, stateConfirms: false);
    expect(r2.failure, GuardToggleFailure.engineNoResponse);
  });

  test('GTX-05 开启路径：引擎在跑 + 权限被拒 -> 不下发 setGuard', () async {
    final r = await run(wanted: true, engineRunning: true, micGranted: false);
    expect(r.failure, GuardToggleFailure.micDenied);
    expect(calls.contains('setGuard:true'), isFalse);
  });

  // ---------- 引擎侧源码锁（引擎依赖真实 DB，宿主上跑不起来，只能锁形状） ----------

  // 源码锁公共工具（勿在本文件另造写法）：
  // `stripComments` 已收敛到 test/support/source_text.dart（第 36 轮）；
  // `methodBody` 本文件仍保留局部副本（具名参数表感知版），
  // 工具自检见 test/support_source_text_test.dart 的 STX 系列。

  // **剥掉注释**再做文本扫描 —— 本锁能被信任的前提。
  //
  // 本项目刻意在 `lib/` 的注释里**写明**"不要再出现 X"以及其理由。
  // 不剥注释：存在性断言会被注释冒充（假绿）；禁止性断言会把说明文字
  // 判成违规（假红），逼下一个人删掉最有价值的"为什么"。
  //
  // 实现见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源）。


  test('GTX-06 源码锁：引擎停止路径必须回投 running:false，且早于 stopSelf', () {
    final src = File('lib/services/background_engine.dart').readAsStringSync();
    // ⚠️ 必须匹配 `.listen`：注释里也出现过 `service.on('stop')` 这个字符串，
    // 用裸字符串会命中注释、锁变成永远假绿。
    final start = src.indexOf("service.on('stop').listen");
    expect(start, greaterThan(-1), reason: '锁本身失效：找不到停止监听器');
    // 同样要匹配**调用**而不是裸名字：注释里写着"必须在 `stopSelf()` 之前…"，
    // 用裸 `stopSelf` 会命中注释、把断言窗口截断成假红/假绿。
    final stopSelf = src.indexOf('await service.stopSelf()', start);
    expect(stopSelf, greaterThan(start));
    final block = src.substring(start, stopSelf);
    expect(block.contains('broadcast(running: false)'), isTrue,
        reason: '引擎停止必须回投 running:false：否则 UI 的 isRunning 永远停在 true'
            '（引擎已死，再没人能广播）⇒ 引擎开关开了关不掉（BUG-B）');
  });

  test('GTX-07 源码锁：broadcast() 不得把 running 写死为 true', () {
    final src = File('lib/services/background_engine.dart').readAsStringSync();
    // 花括号配对取函数体（W5 P1）：旧写法用「下一个函数名 pushExactAlarms」
    // 当右边界，一旦它被改名/挪到 broadcast 之前/删除，indexOf 返回 -1，
    // substring(0, -1) 抛 RangeError（假红）或取到错误区间（假绿）。
    // methodBody 会先配对跳过具名参数表 `{bool running = true}`，缩进无关。
    final body = methodBody(src, 'Future<void> broadcast(');
    expect(body.contains('running: true'), isFalse,
        reason: '写死 true 会让"引擎已停止"永远无法表达（BUG-B 的根因）');
    expect(body.contains('running: running'), isTrue,
        reason: '反向自检：必须由参数决定');
  });

  test('GTX-08 源码锁：引擎启动序列的每步都必须兜底（不得裸调 replan）', () {
    final src = File('lib/services/background_engine.dart').readAsStringSync();
    final code = stripComments(src);
    // 存在性断言收窄到启动序列所在的 `_engineBody` 函数体（W5 P1）：
    // 它必须真的落在启动路径上 —— 全文裸扫时，注释里写一句
    // `await stepGuarded('replan', replan)` 就能把这条锁永久喂绿。
    final body = methodBody(code, 'Future<void> _engineBody(');
    expect(body.contains("await stepGuarded('replan', replan)"), isTrue,
        reason: '裸调 replan() 时，老库缺列会抛 SQLITE_ERROR ⇒ 下面的 broadcast() '
            '永不执行 ⇒ 引擎/守卫开关都打不开（真机 Mi 14 Pro 实证，BUG-A）');
    // 禁止性断言剥注释后扫全文：注释里写「不许裸调 replan()」是理由，
    // 不是违规；不剥注释它反而会造成假红。
    expect(code.contains('await replan();'), isFalse,
        reason: '裸调必须清零，否则修复被绕过');
  });

  test('GTX-09 源码锁：守卫开关必须把主 isolate 的授权结论下发（引擎问不出结果）', () {
    // 剥注释（W5 P1）：存在性判据不能被注释里的示例字符串喂绿。
    final mgr = stripComments(File('lib/services/background_service_manager.dart')
        .readAsStringSync());
    expect(mgr.contains("'micGranted': micGranted"), isTrue,
        reason: 'record 插件在无 Activity 的引擎隔离里 hasPermission() 恒 false，'
            '授权结论只能由主 isolate 提供（BUG-A 根因之一）');
    final screen = stripComments(
        File('lib/features/guard/guard_screen.dart').readAsStringSync());
    expect(screen.contains('micGranted: enabled'), isTrue,
        reason: 'UI 侧必须真的把结论传下去，否则上面的通道是断的');
  });
}
