import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/task_wire.dart';

import '../tool/rc_probe.dart';

/// 互通探针密钥对称性锁（BUG-052）。
///
/// **为什么需要这个文件**：探针用错身份派生密钥时**不会报错**——端点
/// `RcCodec.decode` 失败后静默 return，探针侧只看到"没有回执"，
/// 与"端点离线"完全同形。上一轮的交接报告正是据此宣称
/// "ping 探针 ✓ 全链路闭环"，而实测是 0/3。
/// 所以这里把**密钥对称性**变成可在宿主机断言的量：
/// 完全不需要 broker、不需要设备，就能证明"探针发的命令端点能解"。
///
/// 同时锁住**旧写法必须失败**——否则这组断言只是恒真。
void main() {
  const endpointId = 'e2e-endpoint-001';
  const endpointCode = '12345678'; // 端点自己的配对码（命令用它加密）
  const selfId = 'e2e-probe-000001';
  const selfCode = '87654321'; // 探针的配对码（端点用它加密回执）

  const cmdTopic = 'sonicshield/v1/$endpointId/cmd';
  const evtTopic = 'sonicshield/v1/$endpointId/evt';

  group('探针密钥对称性（接收方身份派生）', () {
    test('命令方向：探针的 cmd 密钥 == 端点 _handleRaw 的解密密钥', () async {
      final keys = await deriveProbeKeys(
        endpointId: endpointId,
        endpointCode: endpointCode,
        selfId: selfId,
        selfCode: selfCode,
      );
      // 端点侧：RcCodec.deriveKey(ownCode, '$ownId|cmd')
      final endpointKey = await RcCodec.deriveKey(
          endpointCode, '$endpointId|cmd');
      expect(keys.cmd, endpointKey);
    });

    test('回执方向：探针的 evt 密钥 == 端点 _send 的加密密钥', () async {
      final keys = await deriveProbeKeys(
        endpointId: endpointId,
        endpointCode: endpointCode,
        selfId: selfId,
        selfCode: selfCode,
      );
      // 端点侧：逐 peer 用 peer.secret + peer.deviceId 派生
      final endpointKey = await RcCodec.deriveKey(selfCode, '$selfId|evt');
      expect(keys.evt, endpointKey);
    });

    test('两个方向必须是不同的密钥（不能复用同一把）', () async {
      final keys = await deriveProbeKeys(
        endpointId: endpointId,
        endpointCode: endpointCode,
        selfId: selfId,
        selfCode: selfCode,
      );
      expect(keys.cmd, isNot(keys.evt));
    });
  });

  group('端到端往返（宿主机仿真两端，无需 broker）', () {
    test('命令：探针加密 → 端点解密 → 取到命令 id', () async {
      final keys = await deriveProbeKeys(
        endpointId: endpointId,
        endpointCode: endpointCode,
        selfId: selfId,
        selfCode: selfCode,
      );
      final endpointKey = await RcCodec.deriveKey(
          endpointCode, '$endpointId|cmd');

      final cmd = RcMessage.now(RcCmd.ping, const {});
      final wire = await RcCodec.encode(cmd, keys.cmd, cmdTopic);
      final got = await RcCodec.decode(wire, endpointKey, cmdTopic);

      expect(got, isNotNull, reason: '端点必须能解开探针发出的命令');
      expect(got!.type, RcCmd.ping);
      expect(got.id, cmd.id);
    });

    test('回执：端点加密 → 探针解密 → for 与命令 id 一致', () async {
      final keys = await deriveProbeKeys(
        endpointId: endpointId,
        endpointCode: endpointCode,
        selfId: selfId,
        selfCode: selfCode,
      );
      final endpointKey = await RcCodec.deriveKey(selfCode, '$selfId|evt');

      final cmd = RcMessage.now(RcCmd.taskList, const {});
      final reply = RcMessage.now(RcEvt.tasks, {'for': cmd.id, 'total': 0});
      final wire = await RcCodec.encode(reply, endpointKey, evtTopic);
      final got = await RcCodec.decode(wire, keys.evt, evtTopic);

      expect(got, isNotNull, reason: '探针必须能解开端点回执');
      expect(got!.type, RcEvt.tasks);
      expect(got.payload['for'], cmd.id);
    });

    test('AAD 绑定主题：命令密文搬到 evt 主题解不开', () async {
      final keys = await deriveProbeKeys(
        endpointId: endpointId,
        endpointCode: endpointCode,
        selfId: selfId,
        selfCode: selfCode,
      );
      final cmd = RcMessage.now(RcCmd.ping, const {});
      final wire = await RcCodec.encode(cmd, keys.cmd, cmdTopic);
      expect(await RcCodec.decode(wire, keys.cmd, evtTopic), isNull);
    });
  });

  group('回归：BUG-052 的旧写法必须失败（否则本组锁恒真）', () {
    test('用探针自身身份派生 cmd 密钥 → 端点解不开', () async {
      // 旧实现：deriveKey(selfCode, '$selfId|cmd')
      final wrong = await RcCodec.deriveKey(selfCode, '$selfId|cmd');
      final endpointKey = await RcCodec.deriveKey(
          endpointCode, '$endpointId|cmd');
      expect(wrong, isNot(endpointKey),
          reason: '两组身份不同就必须派生出不同密钥');

      final cmd = RcMessage.now(RcCmd.ping, const {});
      final wire = await RcCodec.encode(cmd, wrong, cmdTopic);
      expect(await RcCodec.decode(wire, endpointKey, cmdTopic), isNull,
          reason: '这正是上一轮"ping ✓"为假的原因：命令从未被解密');
    });

    test('端点用 cmd 密钥加密回执 → 探针的 evt 密钥解不开', () async {
      final keys = await deriveProbeKeys(
        endpointId: endpointId,
        endpointCode: endpointCode,
        selfId: selfId,
        selfCode: selfCode,
      );
      final reply = RcMessage.now(RcEvt.pong, const {});
      final wire = await RcCodec.encode(reply, keys.cmd, evtTopic);
      expect(await RcCodec.decode(wire, keys.evt, evtTopic), isNull);
    });
  });

  group('探针表与判据锁（源码契约）', () {
    /// 去掉行注释后再断言 —— `contains` 对**注释掉的代码**同样为真。
    String code(String src) => src
        .split('\n')
        .map((l) {
          final i = l.indexOf('//');
          return i < 0 ? l : l.substring(0, i);
        })
        .join('\n');

    late String src;
    setUpAll(() {
      src = code(_readProbeSource());
    });

    test('探针不再把"evt 出现密文"当作通过标准', () {
      expect(src.contains('sawCipher = true'), isFalse,
          reason: 'BUG-052：心跳每 60s 一条，足以让"密文到达"恒真');
      expect(src.contains('replies.add(msg)'), isTrue);
      expect(src.contains('typeOk && idOk'), isTrue);
    });

    test('心跳必须被显式排除在回执之外', () {
      expect(src.contains('RcEvt.heartbeat'), isTrue);
    });

    test('sound 探针不得点名音源（BUG-048 判据）', () {
      final spec = specOf('sound')!;
      final p = spec.payload;
      expect(p.containsKey('preset'), isFalse);
      expect(p.containsKey('assetId'), isFalse);
      expect(p.containsKey('category'), isFalse);
      expect(spec.expect, RcEvt.ack);
    });

    test('探针表覆盖文档声明的全部探针', () {
      for (final k in [
        'ping',
        'status',
        'tasks',
        'assets',
        'presets',
        'device',
        'logs',
        'sound'
      ]) {
        expect(specOf(k), isNotNull, reason: '探针表缺少 $k');
      }
      expect(specOf('nope'), isNull);
    });

    test('每种探针都必须声明期望回执类型（不能留空）', () {
      for (final k in [
        'ping',
        'status',
        'tasks',
        'assets',
        'presets',
        'device',
        'logs',
        'sound'
      ]) {
        final s = specOf(k)!;
        expect(s.expect, isNotEmpty);
        expect(s.type, isNotEmpty);
      }
    });
  });

  /// CRUD 载荷锁：探针**不能** import 领域模型（`trigger.dart` 依赖 `dart:ui`，
  /// `dart run` 的纯 VM 环境加载不了 —— 实测报
  /// `Dart library 'dart:ui' is not available on this platform`）。
  /// 于是它只能用字面量；这些字面量一旦与领域枚举漂移，设备上只会表现为
  /// 「任务定义非法」，看不出是探针的错。所以在这里逐条对齐。
  group('CRUD 载荷锁（探针字面量 ↔ 领域模型）', () {
    test('枚举名 / kind 名与领域模型一致', () {
      expect(crudTriggerType, TriggerType.dailyAt.name);
      expect(crudActionType, ActionType.notify.name);
      expect(crudQuietPolicy, QuietPolicy.skip.name);
      // kind 名是 fromJson 的 switch 分支键，与枚举名同源但独立
      expect(crudTriggerKind, 'dailyAt');
      expect(crudActionKind, 'notify');
    });

    test('载荷必须能过产品自己的入站校验器（零漂移）', () {
      final wire = crudTaskWire('e2e-crud-0001');
      final task = TaskWire.fromWire(wire);
      expect(task, isNotNull,
          reason: '探针发的任务定义必须能被端点 TaskWire.fromWire 接受');
      expect(task!.id, 'e2e-crud-0001');
      expect(task.name, isNotEmpty);
      expect(task.enabled, isTrue);
      expect(task.triggerType, TriggerType.dailyAt);
      expect(task.actionType, ActionType.notify);
    });

    test('线格式字段与 toWire 同构（不丢关键字段）', () {
      final wire = crudTaskWire('e2e-crud-0001');
      for (final k in [
        'id',
        'name',
        'enabled',
        'triggerType',
        'trigger',
        'actionType',
        'action',
        'assetIds',
        'cooldownSec',
        'quietPolicy',
        'priority',
        'createdAt',
        'updatedAt',
      ]) {
        expect(wire.containsKey(k), isTrue, reason: '线格式缺少 $k');
      }
    });
  });
}

/// 读取探针源码（用于源码契约锁）。
///
/// 放在文件末尾：Dart 不允许局部 getter，而 `expect` 又不能在 `test()`
/// 之外调用，所以这里只做一个纯 IO 读取，断言留给 `test()` 内。
String _readProbeSource() {
  // `flutter test` 的 cwd 是包根目录；测试直接跑单文件时可能是 test/。
  for (final c in ['tool/rc_probe.dart', '../tool/rc_probe.dart']) {
    final f = File(c);
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('找不到探针源码 tool/rc_probe.dart（cwd=${Directory.current.path}）');
}
