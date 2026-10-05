// ignore_for_file: avoid_print
/// 声盾远程互通探针（v1.8，docs/19 §8；BUG-052 修复于第十七轮）。
///
/// 作用：以**控制器身份**直连公网 broker，向已配对端点发送真实加密命令
/// （ping / status / tasks / assets / presets / device / sound / **crud**），
/// **解密回执并核对命令 id**，输出往返延迟与回执内容 ——
/// 多机远程"可用性 / 准确性"的自动化验证工具。
///
/// 加密与产品代码**零漂移**：直接复用 lib/remote/protocol.dart 的
/// RcCodec / RcMessage（同一次 HKDF 派生、同一 AAD 绑定）；
/// CRUD 载荷的形状与枚举名由宿主机锁 `test/rc_probe_keys_test.dart` 校验
/// （本文件不能 import 领域模型，见 `crudTriggerType` 上方的 dart:ui 注记）。
///
/// ## 密钥模型（BUG-052 的修复点，务必读完再改）
///
/// 产品按**接收方身份**派生密钥：
/// - 控制器 → 端点：`deriveKey(端点配对码, '{端点ID}|cmd')`，发到 `{端点ID}/cmd`
/// - 端点 → 控制器：`deriveKey(控制器配对码, '{控制器ID}|evt')`，发到 `{端点ID}/evt`
///
/// 早期探针用 `(selfCode, '{selfId}|cmd')` 派生**命令**密钥 —— 与端点的
/// `(ownCode, '{ownId}|cmd')` **永不相等**：端点解密失败后 `decode` 返回
/// null 并静默 return（协议有意如此），于是命令**从未被处理**；
/// 而探针把"evt 主题上出现任意密文"当作通过标准，端点每 60s 的心跳
/// 恰好能满足它 → **工具给出假的"全链路闭环"**。
/// 现在：命令密钥取**端点**身份；回执必须**解密成功 + 类型对 + id 对上**
/// 才算通过；失败时把"看到多少密文 / 多少心跳"一并打印，用于区分
/// 「端点离线」与「密钥不匹配」。
///
/// 用法（先在端点 App「远程中心 → 手输配对」中添加本探针的身份，
/// 并取得**端点的配对码**）：
///   dart run tool/rc_probe.dart \
///     endpoint=<端点16位设备ID> endpointcode=<端点8位配对码> \
///     selfid=<探针16位设备ID> selfcode=<探针8位配对码> \
///     [broker=host] [probe=ping,status|crud] [onlinewait=秒]
///
/// 参数用 `key=value`（无 `--` 前缀）：`dart run` 会吞掉连字符开头的参数。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'package:sonic_shield/remote/protocol.dart';

/// 探针两侧密钥 —— **按接收方身份派生**（与端点完全对称）。
///
/// - [cmd]：探针发给端点的命令密钥。接收方是**端点**，故用端点身份。
/// - [evt]：端点回给探针的回执密钥。接收方是**探针自己**，故用自身身份。
///
/// 抽成纯函数是为了能在宿主机上锁死这个对称性
/// （见 `test/rc_probe_keys_test.dart`）—— 用错身份不会报错，只会静默失败。
Future<({List<int> cmd, List<int> evt})> deriveProbeKeys({
  required String endpointId,
  required String endpointCode,
  required String selfId,
  required String selfCode,
}) async => (
      cmd: await RcCodec.deriveKey(endpointCode, '$endpointId|cmd'),
      evt: await RcCodec.deriveKey(selfCode, '$selfId|evt'),
    );

/// 单个探针定义。
typedef ProbeSpec = ({
  String name,
  String type,
  String expect,
  Map<String, dynamic> payload,
});

ProbeSpec? specOf(String key) => switch (key) {
      'ping' => (
          name: 'ping',
          type: RcCmd.ping,
          expect: RcEvt.pong,
          payload: const <String, dynamic>{},
        ),
      'status' => (
          name: 'status.get',
          type: RcCmd.statusGet,
          expect: RcEvt.status,
          payload: const <String, dynamic>{},
        ),
      'tasks' => (
          name: 'task.list',
          type: RcCmd.taskList,
          expect: RcEvt.tasks,
          payload: const <String, dynamic>{},
        ),
      'assets' => (
          name: 'asset.list',
          type: RcCmd.assetList,
          expect: RcEvt.assets,
          payload: const <String, dynamic>{},
        ),
      'presets' => (
          name: 'preset.list',
          type: RcCmd.presetList,
          expect: RcEvt.presets,
          payload: const <String, dynamic>{},
        ),
      'device' => (
          name: 'device.status',
          type: RcCmd.deviceStatus,
          expect: RcEvt.device,
          payload: const <String, dynamic>{},
        ),
      'logs' => (
          name: 'logs.recent',
          type: RcCmd.logsRecent,
          expect: RcEvt.logs,
          payload: const <String, dynamic>{'limit': 20},
        ),
      // 完全**不点名**音源（无 preset/assetId/category）→ 走端点兜底，
      // 只验证"链路 + 回执"，不替业务结果背书（见 BUG-048 判据）。
      'sound' => (
          name: 'sound.play',
          type: RcCmd.soundPlay,
          expect: RcEvt.ack,
          payload: const <String, dynamic>{'volume': 0.5, 'durationSec': 2},
        ),
      _ => null,
    };

/// CRUD 序列使用的任务 id（固定，便于重复运行幂等）。
const crudTaskId = 'e2e-crud-0001';

// ---------------------------------------------------------------------------
// 任务线格式里用到的枚举名 / kind 名。
//
// **本文件刻意不 import 领域模型**：`lib/domain/models/trigger.dart` 依赖
// `dart:ui`，而探针跑在纯 Dart VM（`dart run`）上 —— 实测直接报
// `Dart library 'dart:ui' is not available on this platform`。
// 所以这里用字面量，并把这些字面量与领域枚举的一致性**挪到宿主机锁**里
// （`test/rc_probe_keys_test.dart` 逐条断言 `X == EnumX.name`），
// 改名时锁会立刻红，而不是到设备上表现为"任务定义非法"。
// ---------------------------------------------------------------------------

/// == `TriggerType.dailyAt.name`
const crudTriggerType = 'dailyAt';

/// == `TriggerConfig.fromJson` 的 `kind` 分支名
const crudTriggerKind = 'dailyAt';

/// == `ActionType.notify.name`
const crudActionType = 'notify';

/// == `ActionConfig.fromJson` 的 `kind` 分支名
const crudActionKind = 'notify';

/// == `QuietPolicy.skip.name`
const crudQuietPolicy = 'skip';

/// 触发时刻：**明确落在默认免打扰（22:00-07:00）之外**。
///
/// 第一版探针用了 03:30，结果 `ack` 回 `planned=0` —— 一度被当成"远程建的任务
/// 不会物化"的缺陷。实际是 `QuietPolicy.skip` 按设计丢弃了免打扰内的时刻
/// （见 `ScheduleEngine._applyQuiet` + `ComplianceGuardrails.defaultQuiet*`）。
/// **红灯先怀疑测量与阈值**：改成正午即稳定物化。
const crudFireHour = 12;
const crudFireMinute = 30;

/// 触发时刻：**故意落在默认免打扰之内**，用于验证 `quietPolicy=skip` 会丢弃它。
const crudQuietHour = 3;
const crudQuietMinute = 30;

/// 构造 CRUD 探针用的**任务线格式**（形状与 `TaskWire.toWire` 同构）。
Map<String, dynamic> crudTaskWire(
  String id, {
  int hour = crudFireHour,
  int minute = crudFireMinute,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'id': id,
    'name': 'E2E 探针任务',
    'enabled': true,
    'triggerType': crudTriggerType,
    'trigger': {
      'kind': crudTriggerKind,
      'time': {'hour': hour, 'minute': minute},
    },
    'actionType': crudActionType,
    'action': {'kind': crudActionKind, 'title': '声盾 E2E', 'body': '互通探针'},
    'assetIds': const <String>[],
    'cooldownSec': 300,
    'quietPolicy': crudQuietPolicy,
    'priority': 0,
    'createdAt': now,
    'updatedAt': now,
  };
}

/// 回执是否**精确指向**本条命令（P2-20）。
///
/// 旧实现 `f == null || f == cmdId` 把"没有 `for` 的回执"也当成本条命令的回执 ——
/// 迟到/无关的同类型 ack 都能满足等待，探针于是**假绿**。
/// 收紧为：
/// * `for` 存在 ⇒ 必须与本条命令 id 相等；
/// * `for` 缺失 ⇒ **仅**非 `rc.ack` 的响应（`rc.pong`/`rc.status` 等本就不带
///   `for` 的广播式回执）视为匹配；`rc.ack` 缺 `for` 一律不匹配。
bool forOk(RcMessage r, String cmdId) {
  final f = r.payload['for'];
  if (f == null) return r.type != RcEvt.ack;
  return f == cmdId;
}

Future<void> main(List<String> args) async {
  var broker = 'broker.emqx.io';
  String? endpointId;
  var endpointCode = '';
  var selfId = '';
  var selfCode = '';
  var probes = 'ping,status';
  var onlineWait = 0;

  for (final a in args) {
    final eq = a.indexOf('=');
    if (eq <= 0) continue;
    final k = a.substring(0, eq);
    final v = a.substring(eq + 1);
    switch (k) {
      case 'broker':
        broker = v;
      case 'endpoint':
        endpointId = v;
      case 'endpointcode':
        endpointCode = v;
      case 'selfid':
        selfId = v;
      case 'selfcode':
        selfCode = v;
      case 'probe':
        probes = v;
      case 'onlinewait':
        onlineWait = int.tryParse(v) ?? 0;
    }
  }

  if (endpointId == null ||
      selfId.length != 16 ||
      selfCode.length != 8 ||
      endpointCode.length != 8) {
    print('用法: dart run tool/rc_probe.dart endpoint=<16位端点ID> '
        'endpointcode=<8位端点配对码> selfid=<16位探针ID> '
        'selfcode=<8位探针配对码> [broker=host] [probe=ping,status|crud] '
        '[onlinewait=秒]');
    print('实际收到 args: $args');
    print('');
    print('提示：endpointcode 是**端点**的配对码（命令用它的身份加密），');
    print('      selfcode   是**本探针**的配对码（回执用它自己的身份解密）。');
    exit(2);
  }

  // CRUD 载荷的形状校验在 `test/rc_probe_keys_test.dart` 里做
  // （那里能 import TaskWire —— 本文件不能，见上文 dart:ui 注记）。

  final keys = await deriveProbeKeys(
    endpointId: endpointId,
    endpointCode: endpointCode,
    selfId: selfId,
    selfCode: selfCode,
  );

  // 控制端侧必须与端点同档传输（C-13）：端点只认 TLS 8883。
  final client = MqttServerClient.withPort(broker, selfId, rcBrokerPort)
    ..port = rcBrokerPort
    ..secure = true
    ..keepAlivePeriod = 30
    ..logging(on: false);
  client.connectionMessage = MqttConnectMessage()
      .withClientIdentifier(selfId)
      .startClean();

  stdout.writeln('[probe] 连接 broker $broker …');
  try {
    await client.connect();
  } on Object catch (e) {
    stdout.writeln('[probe] 连接失败: $e');
    exit(1);
  }
  if (client.connectionStatus?.state != MqttConnectionState.connected) {
    stdout.writeln('[probe] 连接失败: ${client.connectionStatus?.state}');
    exit(1);
  }
  stdout.writeln('[probe] 已连接');

  final cmdTopic = 'sonicshield/v1/$endpointId/cmd';
  final evtTopic = 'sonicshield/v1/$endpointId/evt';
  client.subscribe(evtTopic, MqttQos.atLeastOnce);

  var sawCipher = 0;
  var sawHeartbeat = 0;
  var sawPlainSentinel = 0;
  var sawUndecryptable = 0;
  final replies = <RcMessage>[];

  final sub = client.updates!.listen((c) async {
    for (final m in c) {
      if (m.topic != evtTopic) continue;
      final payload = m.payload as MqttPublishMessage;
      final text = utf8.decode(payload.payload.message, allowMalformed: true);
      final trimmed = text.trimLeft();
      // LWT 离线哨兵是 broker 代发的**明文** JSON（无敏感内容）。
      if (trimmed.startsWith('{')) {
        sawPlainSentinel++;
        stdout.writeln('[probe] ← 明文哨兵: $trimmed');
        continue;
      }
      sawCipher++;
      final msg = await RcCodec.decode(text, keys.evt, evtTopic);
      if (msg == null) {
        sawUndecryptable++;
        stdout.writeln('[probe] ← 密文到达但**解密失败**（${text.length}B）'
            '—— 端点侧密钥/身份不匹配');
        continue;
      }
      if (msg.type == RcEvt.heartbeat) {
        sawHeartbeat++;
        continue;
      }
      replies.add(msg);
      final forId = msg.payload['for'];
      stdout.writeln('[probe] ← 回执 ${msg.type}'
          '${forId == null ? '' : ' for=$forId'}');
    }
  });

  if (onlineWait > 0) {
    stdout.writeln('[probe] 等待端点上线（最多 ${onlineWait}s，看 evt 心跳）…');
    final dl = DateTime.now().add(Duration(seconds: onlineWait));
    while (DateTime.now().isBefore(dl) && sawCipher == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    stdout.writeln(sawCipher > 0
        ? '[probe] 端点在线（evt 已有密文，心跳 $sawHeartbeat 条）'
        : '[probe] ⚠ 端点疑似离线：${onlineWait}s 内 evt 无任何密文');
  }

  /// 发一条命令，收集回执直到 [until] 成立或超时。
  Future<({String id, List<RcMessage> got})> sendCollect(
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 20),
    bool Function(List<RcMessage> got)? until,
  }) async {
    replies.clear();
    final cmd = RcMessage.now(type, payload);
    final wire = await RcCodec.encode(cmd, keys.cmd, cmdTopic);
    final builder = MqttClientPayloadBuilder()..addString(wire);
    client.publishMessage(cmdTopic, MqttQos.atLeastOnce, builder.payload!,
        retain: false);
    stdout.writeln('[probe] → $type (id=${cmd.id}) 已发送');
    final deadline = DateTime.now().add(timeout);
    bool done() {
      if (replies.isEmpty) return false;
      final u = until;
      return u == null ? true : u(replies);
    }

    while (DateTime.now().isBefore(deadline) && !done()) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return (id: cmd.id, got: List<RcMessage>.from(replies));
  }

  /// 在收集到的回执里找指定类型 + `for` 匹配的一条。
  RcMessage? find(List<RcMessage> got, String id, String type) {
    for (final r in got) {
      if (r.type == type && forOk(r, id)) return r;
    }
    return null;
  }

  String dump(List<RcMessage> got) =>
      got.isEmpty ? '无回执' : got.map((r) => r.type).join(',');

  var pass = 0;
  var total = 0;

  // ---------------- CRUD 序列（远程任务增/查/物化/删） ----------------
  Future<bool> runCrud() async {
    stdout.writeln('[probe] ── CRUD 序列：远程任务增 / 查 / 计划物化 / 删 ──');
    var ok = 0;
    var steps = 0;

    Future<void> step(String label, Future<bool> Function() body) async {
      steps++;
      if (await body()) {
        ok++;
        stdout.writeln('[probe]   ✓ $label');
      } else {
        stdout.writeln('[probe]   ✗ $label');
      }
    }

    bool ackOk(List<RcMessage> got, String id) {
      final a = find(got, id, RcEvt.ack);
      return a != null && a.payload['ok'] == true;
    }

    /// 从 `rc.ack.data` 里取 `planned=N`（端点自报的物化条数）。
    int? plannedOf(List<RcMessage> got, String id) {
      final a = find(got, id, RcEvt.ack);
      final d = a?.payload['data'];
      if (d is! String) return null;
      final m = RegExp(r'planned=(\d+)').firstMatch(d);
      return m == null ? null : int.parse(m.group(1)!);
    }

    /// upsert 一步：同时收 `rc.task` + `rc.ack`。
    Future<({String id, List<RcMessage> got})> upsert(
        {required int hour, required int minute}) async {
      return sendCollect(
        RcCmd.taskUpsert,
        {'task': crudTaskWire(crudTaskId, hour: hour, minute: minute)},
        until: (g) => g.length >= 2,
      );
    }

    // 0) 先清场（上一次运行可能残留），失败不计数。
    final pre = await sendCollect(RcCmd.taskDelete, {'taskId': crudTaskId});
    stdout.writeln('[probe]   · 清场 task.delete → ${dump(pre.got)}');

    // 1) 新建（正午触发）：端点应回 rc.task + rc.ack(ok)，且 planned ≥ 1
    await step('task.upsert 新建（$crudFireHour:${crudFireMinute.toString().padLeft(2, '0')}）'
        '→ planned ≥ 1', () async {
      final r = await upsert(hour: crudFireHour, minute: crudFireMinute);
      final t = find(r.got, r.id, RcEvt.task);
      final created = t?.payload['task'];
      final idBack = created is Map ? created['id'] : null;
      // **ack 必须无条件打印**：它的 `data` 带 `planned=N`，
      // 是判断"计划是否真的物化"的唯一线索。
      final a = find(r.got, r.id, RcEvt.ack);
      final planned = plannedOf(r.got, r.id);
      stdout.writeln('[probe]     ↳ ack=${a?.payload} rc.task.id=$idBack');
      return idBack == crudTaskId &&
          ackOk(r.got, r.id) &&
          (planned ?? -1) >= 1;
    });

    // 2) 列表：应包含新任务（验证跨设备可见）
    await step('task.list 含新任务', () async {
      final r = await sendCollect(RcCmd.taskList, const {});
      final t = find(r.got, r.id, RcEvt.tasks);
      if (t == null) return false;
      final list = (t.payload['tasks'] as List?) ?? const [];
      final ids = [
        for (final e in list)
          if (e is Map) e['id'],
      ];
      stdout.writeln('[probe]     ↳ total=${t.payload['total']} ids=$ids');
      return ids.contains(crudTaskId);
    });

    // 3) 计划已入库：status.get 走 pendingWithin/pendingCountAfter（**查库路径**）
    await step('status.get → pendingCount ≥ 1（计划已物化并入库）', () async {
      final r = await sendCollect(RcCmd.statusGet, const {});
      final s = find(r.got, r.id, RcEvt.status);
      if (s == null) return false;
      final n = (s.payload['pendingCount'] as num?)?.toInt() ?? -1;
      stdout.writeln('[probe]     ↳ pendingCount=$n '
          'nextFireAt=${s.payload['nextFireAt']} '
          'version=${s.payload['version']}');
      return n >= 1;
    });

    // 4) 免打扰语义：改到 03:30（落在默认免打扰 22:00-07:00）+ quietPolicy=skip
    //    → 端点应**如实**回 planned=0，且 pendingCount 归零。
    //    这条同时是"改定义会重建计划"的证据（旧计划被清、新计划为 0）。
    await step('改成免打扰内时刻 → planned=0 且 pendingCount 归零', () async {
      final r = await upsert(hour: crudQuietHour, minute: crudQuietMinute);
      final planned = plannedOf(r.got, r.id);
      final st = await sendCollect(RcCmd.statusGet, const {});
      final s = find(st.got, st.id, RcEvt.status);
      final n = (s?.payload['pendingCount'] as num?)?.toInt() ?? -1;
      stdout.writeln('[probe]     ↳ planned=$planned pendingCount=$n');
      return planned == 0 && n == 0;
    });

    // 5) 改回正午：计划应重新物化（证明重建真的发生）
    await step('改回正午 → planned ≥ 1 且 pendingCount ≥ 1（重建生效）', () async {
      final r = await upsert(hour: crudFireHour, minute: crudFireMinute);
      final planned = plannedOf(r.got, r.id);
      final st = await sendCollect(RcCmd.statusGet, const {});
      final s = find(st.got, st.id, RcEvt.status);
      final n = (s?.payload['pendingCount'] as num?)?.toInt() ?? -1;
      stdout.writeln('[probe]     ↳ planned=$planned pendingCount=$n');
      return (planned ?? -1) >= 1 && n >= 1;
    });

    // 6) 改：停用
    await step('task.toggle 停用', () async {
      final r = await sendCollect(
          RcCmd.taskToggle, {'taskId': crudTaskId, 'enabled': false});
      if (!ackOk(r.got, r.id)) stdout.writeln('[probe]     ↳ ${dump(r.got)}');
      return ackOk(r.got, r.id);
    });

    // 7) 删
    await step('task.delete 删除', () async {
      final r = await sendCollect(RcCmd.taskDelete, {'taskId': crudTaskId});
      if (!ackOk(r.got, r.id)) stdout.writeln('[probe]     ↳ ${dump(r.got)}');
      return ackOk(r.got, r.id);
    });

    // 8) 收尾：列表应不含该任务，且其计划一并清空
    await step('task.list 已不含该任务、pendingCount 归零（清理干净）', () async {
      final r = await sendCollect(RcCmd.taskList, const {});
      final t = find(r.got, r.id, RcEvt.tasks);
      if (t == null) return false;
      final list = (t.payload['tasks'] as List?) ?? const [];
      final ids = [
        for (final e in list)
          if (e is Map) e['id'],
      ];
      final st = await sendCollect(RcCmd.statusGet, const {});
      final s = find(st.got, st.id, RcEvt.status);
      final n = (s?.payload['pendingCount'] as num?)?.toInt() ?? -1;
      stdout.writeln('[probe]     ↳ total=${t.payload['total']} ids=$ids '
          'pendingCount=$n');
      return !ids.contains(crudTaskId) && n == 0;
    });

    stdout.writeln('[probe] CRUD 序列: $ok/$steps');
    return ok == steps;
  }

  // ---------------- 单命令探针 ----------------
  for (final p in probes.split(',')) {
    final key = p.trim();
    if (key == 'crud') {
      total++;
      if (await runCrud()) pass++;
      continue;
    }
    final spec = specOf(key);
    if (spec == null) {
      stdout.writeln('[probe] 跳过未知探针 $p');
      continue;
    }
    total++;
    final r = await sendCollect(spec.type, spec.payload);
    if (r.got.isEmpty) {
      stdout.writeln('[probe] ✗ ${spec.name} → 20s 内无回执'
          '（累计 evt 密文 $sawCipher / 心跳 $sawHeartbeat / 明文哨兵 '
          '$sawPlainSentinel）');
      stdout.writeln(sawCipher == 0
          ? '         → 端点离线或未连接 broker'
          : '         → 端点在线但未回应本命令：密钥不匹配或命令被拒');
      continue;
    }
    final got = r.got.first;
    final forId = got.payload['for'];
    final typeOk = got.type == spec.expect;
    final idOk = forOk(got, r.id);
    if (typeOk && idOk) {
      pass++;
      stdout.writeln('[probe] ✓ ${spec.name} → ${got.type}${_brief(got)}');
    } else {
      stdout.writeln('[probe] ✗ ${spec.name} → 回执不匹配：'
          '期望 ${spec.expect}${forId == null ? '' : '/for=${r.id}'}，'
          '实收 ${got.type}${forId == null ? '' : '/for=$forId'}');
    }
  }

  await sub.cancel();
  client.disconnect();
  stdout.writeln('');
  stdout.writeln('探针结果: $pass/$total 通过'
      '（判据 = 回执**解密成功** + 类型对 + `for` 与命令 id 一致）');
  stdout.writeln('链路统计: evt 密文 $sawCipher（其中心跳 $sawHeartbeat、'
      '解密失败 $sawUndecryptable）、明文哨兵 $sawPlainSentinel');
  exit(pass == total ? 0 : 1);
}

/// 回执内容摘要（只挑几个通用字段，避免打印超长 payload）。
String _brief(RcMessage r) {
  final p = r.payload;
  final parts = <String>[];
  for (final k in ['ok', 'device', 'version', 'total', 'pendingCount']) {
    if (p.containsKey(k)) parts.add('$k=${p[k]}');
  }
  final data = p['data'];
  if (data != null) parts.add('data=$data');
  return parts.isEmpty ? '' : ' · ${parts.join(', ')}';
}
