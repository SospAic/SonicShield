/// 第九十六轮 · **覆盖率缺口补齐（协议内部碎片）**。
///
/// 本轮只针对 `lib/remote/protocol.dart` 中三处"可达但从未被执行"的行：
/// - `InboundSeenTable.restore` 的 `nowMs ?? DateTime.now()` 默认值分支；
/// - `RcWireGate.allow` 的源数量超限清理语句；
/// - `RcWireGate.sourceCount` 诊断 getter。
///
/// ## 纪律
///
/// - **不改 `lib/`**：本轮是纯测试补洞。
/// - **不依赖墙钟**：`restore` 的默认分支一旦走墙钟，就只喂 `ts = 0`
///   （epoch 毫秒恒远大于任何窗口），因此"全部出窗被裁掉"与真实时间无关，
///   断言恒成立；任何需要"窗口内"的断言都显式传 `nowMs`。
/// - 断言的是**可观测副作用**（表长度 / 桶存活），不是"没抛异常"。
///
/// ## 明确不测（结构性不可达）
///
/// `RcCodec.rotatedPairingCode` 的 `while` 重试体（`protocol.dart:677`
/// `next = gen();`）：`gen()` 用 `Random.secure()` 从 31 个字符里取 8 位，
/// 要进入循环体必须与 `current` **逐字符完全碰撞**（概率 1/31^8 ≈ 1e-12），
/// 且生成器不可注入。同一结论已登记于 `test/bj_gap_closure_test.dart:20`。
@Timeout(Duration(seconds: 120))
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:sonic_shield/remote/protocol.dart';

void main() {
  group('InboundSeenTable.restore 的墙钟默认分支（protocol.dart:744）', () {
    test('GAP-01 restore 不传 nowMs 时走默认分支，出窗条目被裁掉', () {
      final table = InboundSeenTable();
      // 非空快照才会越过 `data.isEmpty` 提前返回，从而执行到 nowMs 默认值那一行。
      // ts = 0（epoch）在任何真实时钟下都远早于 now - windowMs，故必然出窗。
      table.restore(<String, int>{'a': 0, 'b': 0});

      expect(table.length, 0, reason: '出窗条目必须被裁掉，表应为空');
      expect(table.contains('a'), isFalse);
      expect(table.contains('b'), isFalse);
      expect(table.snapshot(), isEmpty);
    });

    test('GAP-02 构造器不给 nowMs 时同样走默认分支', () {
      // 构造器把 initial/nowMs 直接转交 restore，是本行的第二个调用点。
      final table = InboundSeenTable(initial: <String, int>{'x': 0});

      expect(table.length, 0);
      expect(table.contains('x'), isFalse);
    });

    test('GAP-03 显式 nowMs 时窗口内条目保留（对照组，证明 744 只在缺省时走）', () {
      final table = InboundSeenTable();
      // nowMs 显式给定：in 在 10 分钟窗口内（差 1ms），out 早于窗口 40 万毫秒。
      table.restore(<String, int>{'in': 999999, 'out': 0}, nowMs: 1000000);

      expect(table.length, 1, reason: '窗口内保留、出窗丢弃');
      expect(table.contains('in'), isTrue);
      expect(table.contains('out'), isFalse);
      expect(table.snapshot()['in'], 999999);
    });
  });

  group('RcWireGate 源桶清理与计数（protocol.dart:1060 / 1066）', () {
    test('GAP-04 源数量超过 maxSources 时执行清理语句，但有流量的桶不被误删', () {
      // maxSources = 1：第二个源入库后 _ts.length(2) > 1，必然执行 removeWhere。
      // 两个桶都刚 add 过时间戳（非空），所以清理语句执行了却不应删任何桶 ——
      // 这正是源码注释强调的"误删等于给它重置额度"。
      final gate = RcWireGate(windowMs: 1000, maxPerWindow: 10, maxSources: 1);

      expect(gate.sourceCount, 0, reason: '初始无源');

      expect(gate.allow('cmd/dev-a', 0), isTrue);
      expect(gate.sourceCount, 1);

      expect(gate.allow('evt/dev-b', 0), isTrue);
      expect(gate.sourceCount, 2, reason: '有流量的源不得被清理掉');

      // 同一源重复到达不新增桶（sourceCount 只数"源"，不数"条"）。
      expect(gate.allow('cmd/dev-a', 10), isTrue);
      expect(gate.sourceCount, 2);
    });

    test('GAP-05 单源场景下 sourceCount 稳定为 1，额度耗尽后仍不新增源', () {
      final gate = RcWireGate(windowMs: 1000, maxPerWindow: 2, maxSources: 4);

      expect(gate.sourceCount, 0);
      expect(gate.allow('assist/dev-c', 0), isTrue);
      expect(gate.sourceCount, 1);

      expect(gate.allow('assist/dev-c', 1), isTrue);
      expect(gate.sourceCount, 1, reason: '同一主题多次到达仍是同一个源');

      // 额度用尽：拒绝且不记账（桶仍是那一个）。
      expect(gate.allow('assist/dev-c', 2), isFalse);
      expect(gate.sourceCount, 1);
    });

    test('GAP-06 窗口滑过后旧时间戳被清空，同源继续放行且源数不变', () {
      final gate = RcWireGate(windowMs: 100, maxPerWindow: 1, maxSources: 4);

      expect(gate.allow('cmd/dev-d', 0), isTrue);
      // 窗口内第二次被拒（maxPerWindow = 1，且旧时间戳未出窗）。
      expect(gate.allow('cmd/dev-d', 50), isFalse);
      expect(gate.sourceCount, 1);

      // 出窗后清空旧时间戳，同源重新获得额度。
      expect(gate.allow('cmd/dev-d', 500), isTrue);
      expect(gate.sourceCount, 1);
    });
  });
}
