// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';

/// **Q10 命令限流 + 停类优先锁**（第三十六轮）。
///
/// ## 本锁锁什么
///
/// | 组 | 不变量 |
/// |---|---|
/// | RL  | `rateLimitFor` 滑窗判据：窗口内 0/max-1/max/max+1、跨窗口重置、retryAfterMs 精确 |
/// | STOP | `isStopCommand` 穷举三条 + 反例（`sound.play` 必须不是停类） |
/// | WIRE | 接线：停类先于限流、内存表上限、拒绝时 `skipped` 审计 + `rc.ack{ok:false,data:'限流'}` |
/// | Q4 | `_sendLocation` 失败回执带前台引导文案；**不承诺**后台定位 |
/// | PRIO | 停类排队复用执行器既有终止令牌机制（不重写，只锁存在） |
///
/// ⚠️ 端点服务本体依赖 MQTT/DB/插件实例，宿主无法实例化（既有做法）：
/// 判定走纯函数穷举，接线用源码契约锁。
void main() {
  final endpointSrc =
      File('lib/remote/endpoint_service.dart').readAsStringSync();
  final executorSrc =
      File('lib/remote/script_executor.dart').readAsStringSync();

  /// 剥掉 Dart 注释再断言 —— 与 rc_transport_lock_test 同一理由：
  /// 本项目刻意在注释里写明"为什么不做某事"，不剥离会把说明文字当违规。
  String stripDartComments(String s) {
    s = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    final sb = StringBuffer();
    for (final line in s.split('\n')) {
      final i = line.indexOf('//');
      sb.writeln(i < 0 ? line : line.substring(0, i));
    }
    return sb.toString();
  }

  // ════════════════════════════════════ RL · 滑窗限流纯函数穷举
  group('Q10-RL rateLimitFor 穷举', () {
    const dev = 'device-0001';
    const win = rcRateLimitWindowMs; // 60000
    const max = rcRateLimitMaxPerWindow; // 30
    const now = 1000000;

    test('RL-01 窗口内 0 条 → 放行', () {
      expect(rateLimitFor(dev, now, const <int>[]).allowed, isTrue);
    });

    test('RL-02 窗口内 max-1 条 → 放行（本条是第 30 条）', () {
      final ts = List.generate(max - 1, (i) => now - 1000 + i);
      expect(rateLimitFor(dev, now, ts).allowed, isTrue);
    });

    test('RL-03 窗口内 max 条 → 拒绝，retryAfterMs = 最早一条滑出窗口的时间', () {
      final ts = List.generate(max, (i) => now - 1000 + i);
      final v = rateLimitFor(dev, now, ts);
      expect(v.allowed, isFalse);
      // 最早一条 now-1000，滑出窗口还需 windowMs - (now - oldest) = 59000。
      expect(v.retryAfterMs, 59000);
      expect(v.retryAfterMs, greaterThan(0));
    });

    test('RL-04 窗口内 max+1 条 → 拒绝（多出来的条目不放大等待时间以外的影响）', () {
      final ts = List.generate(max + 1, (i) => now - 2000 + i);
      final v = rateLimitFor(dev, now, ts);
      expect(v.allowed, isFalse);
      expect(v.retryAfterMs, 58000, reason: '由窗口内最早一条决定，与总数无关');
    });

    test('RL-05 跨窗口重置：全部时间戳出窗 → 放行（旧行为不追债）', () {
      final stale = List.generate(50, (i) => now - win - i - 1);
      expect(rateLimitFor(dev, now, stale).allowed, isTrue);
    });

    test('RL-06 窗口边界：恰好等于 cutoff 的条目视为出窗（半开区间）', () {
      final ts = <int>[now - win, ...List.generate(max - 1, (i) => now - i)];
      expect(rateLimitFor(dev, now, ts).allowed, isTrue);
    });

    test('RL-07 自定义窗口/条数参数生效', () {
      final v = rateLimitFor(dev, now, [now - 1, now - 2],
          windowMs: 1000, maxPerWindow: 2);
      expect(v.allowed, isFalse);
      expect(v.retryAfterMs, 998);
    });

    test('RL-08 未来时间戳不计入（脏数据不把人锁在门外）', () {
      final ts = List.generate(max, (i) => now + 10000 + i);
      expect(rateLimitFor(dev, now, ts).allowed, isTrue);
    });
  });

  // ════════════════════════════════════ STOP · 停类判定穷举
  group('Q10-STOP isStopCommand 穷举', () {
    test('ST-01 三条停类命令全部为真', () {
      expect(isStopCommand(RcCmd.scriptStop), isTrue);
      expect(isStopCommand(RcCmd.vibrateStop), isTrue);
      expect(isStopCommand(RcCmd.callEnd), isTrue);
    });

    test('ST-02 反例：sound.play 不是停类', () {
      expect(isStopCommand(RcCmd.soundPlay), isFalse);
    });

    test('ST-03 反例：空串 / 未知类型 / 停类前缀混淆都不是停类', () {
      expect(isStopCommand(''), isFalse);
      expect(isStopCommand('script.run'), isFalse);
      expect(isStopCommand('script.stopx'), isFalse);
      expect(isStopCommand('call.end.all'), isFalse);
    });
  });

  // ════════════════════════════════════ WIRE · 接线源码契约
  group('Q10-WIRE 接线锁（源码契约）', () {
    test('WR-01 `_handleRaw` 里停类判定在限流判定**之前**（停类恒放行）', () {
      final i = endpointSrc.indexOf('Future<void> _handleRaw(');
      expect(i, greaterThan(0));
      final body = endpointSrc.substring(
          i, endpointSrc.indexOf('/// 对端广播的回执'));
      final stopIdx = body.indexOf('isStopCommand(');
      final rateIdx = body.indexOf('rateLimitFor(');
      expect(stopIdx, greaterThan(0), reason: '停类判定必须真的被调用');
      expect(rateIdx, greaterThan(stopIdx),
          reason: '★ 顺序即语义：停类必须先于限流放行，'
              '否则窗口刷满时连"叫停"都发不进来');
    });

    test('WR-02 内存表存在、类型正确、有硬上限防涨', () {
      expect(endpointSrc.contains('Map<String, List<int>>'), isTrue);
      expect(endpointSrc.contains('maxCmdTsPerEndpoint'), isTrue);
      expect(maxCmdTsPerEndpoint, 200);
    });

    test('WR-03 被拒时写 skipped 审计（含「限流」）并回 rc.ack{ok:false,data:限流}', () {
      final i = endpointSrc.indexOf('Future<void> _auditRateLimited(');
      expect(i, greaterThan(0));
      final body = endpointSrc.substring(
          i, endpointSrc.indexOf('出站消息被丢弃时的审计'));
      final stripped = stripDartComments(body);
      expect(stripped.contains("'skipped'"), isTrue,
          reason: '限流拒绝必须留痕（skipped）');
      expect(stripped.contains('限流'), isTrue, reason: '审计必须含「限流」字样');
      expect(RegExp(r"_ack\(msg, false, data: '限流'\)").hasMatch(endpointSrc),
          isTrue, reason: '控制端必须收到明确的失败回执，而不是等到超时');
    });

    test('WR-04 限流参数默认 60s 窗 30 条', () {
      expect(rcRateLimitWindowMs, 60000);
      expect(rcRateLimitMaxPerWindow, 30);
    });
  });

  // ════════════════════════════════════ Q4 · 定位失败引导文案
  group('Q4 定位失败回执的前台引导', () {
    /// `_sendLocation` 区域：签名 → seam 字段的**第二次**出现
    /// （第一次出现在方法体开头的调用里，不能当右边界）。
    ///
    /// ⚠️ 不能写成「group 体里的立即执行闭包 + expect」：`expect` 只能出现在
    /// `test()` 内，否则加载期抛 `OutsideTestException` 整个文件加载失败。
    String sendLocBody() {
      final i = endpointSrc.indexOf('Future<void> _sendLocation(');
      expect(i, greaterThan(0));
      final first = endpointSrc.indexOf('locationPermissionGate', i);
      final end = endpointSrc.indexOf('locationPermissionGate', first + 1);
      return endpointSrc.substring(i, end);
    }

    test('Q4-01 剥注释后 `_sendLocation` 含「前台」引导文案', () {
      final stripped = stripDartComments(sendLocBody());
      expect(stripped.contains('前台'), isTrue,
          reason: 'permissionDenied / serviceDisabled 的失败回执必须带'
              '"点亮屏幕在前台重试 + 系统设置允许定位"级别的引导');
      expect(stripped.contains('请点亮屏幕后在前台重试'), isTrue);
      expect(stripped.contains('系统设置中允许定位'), isTrue);
    });

    test('Q4-02 反例：不承诺后台定位（A+C 决策：诚实失败 + 引导，不做后台）', () {
      final stripped = stripDartComments(sendLocBody());
      expect(stripped.contains('后台定位'), isFalse,
          reason: '后台定位属后续独立决策（政策 + FGS 类型位）；'
              '文案里不得暗示"稍后会自动重试/后台也能定位"');
      expect(stripped.contains('自动重试'), isFalse);
    });

    test('Q4-03 失败回执带 data 字段（此前只有 error:true，控制端无从下手）', () {
      expect(sendLocBody().contains("'data':"), isTrue);
      expect(sendLocBody().contains("'error': true"), isTrue);
    });
  });

  // ════════════════════════════════════ PRIO · 复用既有终止机制
  group('Q10-PRIO 停类排队复用执行器既有机制（不重写，只锁存在）', () {
    test('PR-01 执行器每步前检查终止令牌（既有机制未被移除）', () {
      expect(
          RegExp(r'if \(_stopping \|\| cancel\.cancelled\)')
              .hasMatch(executorSrc),
          isTrue,
          reason: '步骤间的终止检查是"停类优先"的真实排队点，'
              '移除它等于退回"点了停还在响"的 BUG');
    });

    test('PR-02 执行器用 Future.any 竞速而非无条件 await（既有机制未被移除）', () {
      expect(executorSrc.contains('Future.any<bool>'), isTrue);
    });

    test('PR-03 `_runScript` 步骤 runner 拿到 activeCancel 并检查 cancelled', () {
      final i = endpointSrc.indexOf('Future<void> _runScript(');
      expect(i, greaterThan(0));
      final body = endpointSrc.substring(
          i, endpointSrc.indexOf('/// 执行指令组里的一个振动步骤'));
      expect(body.contains('RcScriptExecutor.instance.activeCancel'), isTrue);
      expect(body.contains('cancel?.cancelled'), isTrue,
          reason: '步骤内（解析/起播前）的二次终止检查是既有修复（R2②），不得退化');
    });
  });
}
