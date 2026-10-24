import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/task_wire.dart';

import 'support/source_text.dart';

/// 第 35 轮端点接线回归锁：Q2.B 自带 broker 连接侧 / Q1.B 每设备随机盐 /
/// D-7 残余面（动作级权限裁决）。
///
/// 端点服务是**单例**、依赖 MQTT / DB / 插件实例，宿主**无法实例化** —— 因此
/// 本文件分两层：
/// 1. **能直接调用的纯逻辑**（[RcCodec.deriveKey]、`taskActionPermDeny`）：
///    直接断言逐字节等价 / 真值表；
/// 2. **接线本身**：源码契约锁（剥注释后扫方法体 / 调用点），每条锁都配
///    **反例样本**证明检查器不是恒真。
///
/// ⚠️ 诚实边界：本文件**不能**证明"真机上盐确实生效 / 自建 broker 鉴权确实
/// 通过"（那需要两台设备 + 抓包 + 一台开了鉴权的 broker）。它锁的是
/// "接线写了、且未配置时默认行为逐字节不变"。

// 剥掉行注释与块注释（字符串字面量整段保留 —— 字符串里的违规仍是**代码级**
// 违规，必须被抓）。实现见 `test/support/source_text.dart`
// （第 36 轮收敛到唯一真源，勿再在本文件复制）。


/// Q2.B：端口是否来自 `store.brokerPort`（而非写死默认常量）。
bool portComesFromStore(String body) {
  // 旧形状：`withPort(store.broker, deviceId, RemoteStore.defaultBrokerPort)`。
  if (RegExp(r'deviceId\s*,\s*RemoteStore\.defaultBrokerPort\s*\)').hasMatch(body)) {
    return false;
  }
  // 两处（withPort 实参 + `..port =`）都必须引用用户配置。
  return 'brokerPort'.allMatches(body).length >= 2;
}

/// Q2.B：凭据门是否"两者都非空才携带"，且用的是 mqtt_client 的真实 API。
bool credentialGateOk(String body) =>
    body.contains('authenticateAs(') &&
    RegExp(r'brokerUser\.isNotEmpty\s*&&\s*brokerPass\.isNotEmpty').hasMatch(body) &&
    !body.contains('withCredentials');

/// 取 `RcCodec.deriveKey(` 这次调用的**平衡括号**实参文本（含两端括号）。
String deriveCallText(String src, int start) {
  final open = src.indexOf('(', start);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '(') depth++;
    if (src[i] == ')') {
      depth--;
      if (depth == 0) return src.substring(open, i + 1);
    }
  }
  return '';
}

/// Q1.B：**每一个** `RcCodec.deriveKey(` 调用点都必须同时满足：
/// 1. 显式传 `salt:`（漏传 = 退化成 v1 无盐派生，与带盐对端静默失配）；
/// 2. 不得写死 `salt: null`（零盐 / 默认盐，任务书明令禁止）；
/// 3. 实参内或附近（±窗口）必须出现 `saltFor(` —— 盐的**唯一来源**；
/// 4. 盐以**形参**透传时（派生被抽成缓存助手，如 R94/REM-05 的 `_cmdKey`），
///    `saltFor` 只出现在助手的**调用方**：改为传递校验 —— 该助手的每个
///    `await <助手>(` 调用点附近都必须有 `saltFor(`。否则"提取方法"这类
///    无害重构会让窗口检查假红，逼人把助手内联回去（那反而更糟）。
///
/// ⚠️ 第 3、4 条是字符级粗筛：对"两段相距很远"的样本窗口会整段覆盖，单独用
/// 会**恒真**。所以第 1、2 条是**逐调用**的硬判据（反例 Q1-08 正是靠
/// "第二个调用点没写 `salt:`" 判红的 —— 短样本里窗口检查会给假通过）。
bool allDeriveSitesNearSalt(String src) {
  final sites = RegExp(r'RcCodec\.deriveKey\(').allMatches(src).toList();
  if (sites.isEmpty) return false;
  for (final m in sites) {
    final call = deriveCallText(src, m.start);
    if (!call.contains('salt:')) return false;
    if (call.contains('salt: null')) return false;
    if (call.contains('saltFor(')) continue;
    final lo = (m.start - 600).clamp(0, src.length);
    final hi = (m.end + 400).clamp(0, src.length);
    if (src.substring(lo, hi).contains('saltFor(')) continue;
    // 第 4 条：盐由形参透传 ⇒ 校验助手自身的调用点都带 saltFor 来源。
    if (!_helperCallersNearSalt(src, m.start)) return false;
  }
  return true;
}

/// 包含 [offset] 的方法名（向上找最近的方法声明头）；找不到返回 null。
String? _enclosingMethod(String src, int offset) {
  final header = RegExp(r'(?:Future<[^;(]*>|void|bool|int|String)\s+(\w+)\s*\(');
  String? name;
  for (final m in header.allMatches(src)) {
    if (m.start >= offset) break;
    name = m.group(1);
  }
  return name;
}

/// 助手的每个 `await <name>(` 调用点附近（±窗口）是否都有 `saltFor(`。
///
/// 只数 `await` 调用点：方法声明头（`Future<...> name(`）不是调用，
/// 否则声明自身会因窗口里没有 saltFor 而误判。找不到助手或没有任何调用点
/// 时返回 false（失败关闭：验不了来源就不放行）。
bool _helperCallersNearSalt(String src, int offset) {
  final name = _enclosingMethod(src, offset);
  if (name == null) return false;
  final callers = RegExp('await\\s+$name\\(').allMatches(src).toList();
  if (callers.isEmpty) return false;
  for (final c in callers) {
    final lo = (c.start - 600).clamp(0, src.length);
    final hi = (c.end + 400).clamp(0, src.length);
    if (!src.substring(lo, hi).contains('saltFor(')) return false;
  }
  return true;
}

/// D-7：裁决调用必须出现在**执行之前**。
bool gateBeforeExec(String body, String gate, String exec) {
  final g = body.indexOf(gate);
  final e = body.indexOf(exec);
  return g >= 0 && e >= 0 && g < e;
}

void main() {
  final src = File('lib/remote/endpoint_service.dart').readAsStringSync();
  final code = stripComments(src);
  // ⚠️ 剥注释后再做内容断言：`_connect` 的说明文字里**故意**写着
  // "没有 withCredentials"（那是本锁的理由），不剥会把说明当成违规（假红）。
  final connect = stripComments(methodBody(src, 'Future<void> _connect() async'));

  // ══════════════════════════════════════════════════ Q2.B · 自带 broker
  group('Q2.B 连接侧：端口与鉴权', () {
    test('QW-01 _connect 的端口取自 store.brokerPort（withPort 实参 + ..port 两处）', () {
      expect(portComesFromStore(connect), isTrue,
          reason: '旧形状把 8883 写死在两处，用户配的 rc_broker_port 完全不生效');
      expect(connect.contains('RemoteStore.defaultBrokerPort'), isTrue,
          reason: '未配置时仍须回落共享常量（TL-03/TL-12 也锁着这一点）');
      expect(connect.contains('store.brokerPort'), isTrue);
    });

    test('QW-02 反例：旧的"裸写死默认端口"样本必须判红', () {
      const bad = '''
Future<void> _connect() async {
  final client = MqttServerClient.withPort(
      store.broker, deviceId, RemoteStore.defaultBrokerPort)
    ..port = RemoteStore.defaultBrokerPort;
}
''';
      expect(
          portComesFromStore(
              stripComments(methodBody(bad, 'Future<void> _connect() async'))),
          isFalse);
    });

    test('QW-03 用户名 + 密码**都非空**才携带凭据（用 authenticateAs，不是 withCredentials）',
        () {
      expect(credentialGateOk(connect), isTrue,
          reason: '已核对 pub 缓存 mqtt_client-10.11.11 源码：MqttConnectMessage '
              '只有 authenticateAs(username, password)，**没有** withCredentials');
      expect(connect.contains('store.brokerUsername'), isTrue);
      expect(connect.contains('store.brokerPassword'), isTrue);
    });

    test('QW-04 反例：半套凭据 / 凭空调用 withCredentials 的样本必须判红', () {
      const halfCred = '''
Future<void> _connect() async {
  final m = MqttConnectMessage();
  if (store.brokerUsername.isNotEmpty) {
    m.authenticateAs(store.brokerUsername, store.brokerPassword);
  }
}
''';
      expect(
          credentialGateOk(
              stripComments(methodBody(halfCred, 'Future<void> _connect() async'))),
          isFalse);
      const ghostApi = '''
Future<void> _connect() async {
  final m = MqttConnectMessage().withCredentials('u', 'p');
}
''';
      expect(
          credentialGateOk(
              stripComments(methodBody(ghostApi, 'Future<void> _connect() async'))),
          isFalse);
    });

    test('QW-05 TLS 硬约束未被本轮改动破坏（secure=true 无条件、无 onBadCertificate）', () {
      expect(connect.contains('secure = true'), isTrue,
          reason: '端口可配置**不等于** TLS 可配置；secure 必须无条件为 true');
      expect(connect.contains('onBadCertificate'), isFalse,
          reason: '出现 onBadCertificate 就是把"忽略证书"的后门装回来');
      expect(connect.contains('1883'), isFalse,
          reason: '明文端口不得以任何形式回归（TL-08）');
    });
  });

  // ══════════════════════════════════════════════════ Q1.B · 每设备盐
  group('Q1.B 每设备盐：兼容铁证', () {
    const secret = 'AB2CD5EF';
    const context = 'aaaaaaaaaaaaaaaa|cmd';

    test('Q1-01 saltFor 为 null（→ 不传盐）时 deriveKey 与今天**逐字节相同**', () async {
      final today = await RcCodec.deriveKey(secret, context);
      final nullSalt = await RcCodec.deriveKey(secret, context, salt: null);
      expect(nullSalt, today,
          reason: '★ 兼容铁证：旧配对端点（无存盐）必须走 v1 旧路径；'
              '一旦这里不等，全部已配对设备升级后**静默失联**');
    });

    test('Q1-02 有盐 != 无盐（加盐确实改变派生结果）', () async {
      final salt = RcCodec.newSalt();
      final withSalt = await RcCodec.deriveKey(secret, context, salt: salt);
      final noSalt = await RcCodec.deriveKey(secret, context);
      expect(withSalt.length, 32);
      expect(withSalt, isNot(noSalt));
    });
  });

  group('Q1.B 每设备盐：接线锁（源码契约）', () {
    test('Q1-03 端点 ack 携带 kdfsalt，盐经"复用优先"的 _ensureSalt 落盘', () {
      final pair = methodBody(src, 'Future<void> _handlePairRequest(');
      expect(pair.contains("'kdfsalt': base64Encode(salt)"), isTrue,
          reason: '盐必须随配对成功回执下发给控制端');
      expect(pair.contains('_ensureSalt(ctrlId)'), isTrue,
          reason: '生成/复用必须走单一真源，避免每次重新生成');
      expect(pair.contains('withSalt: false'), isTrue,
          reason: '★ 这条回执是盐的**引导报文**：接收方此刻还没有盐，'
              '若用盐加密它，接收方永远解不开 ⇒ 永远拿不到盐');

      // 第 36 轮：语义**真源已抽到顶层函数** `ensureSaltForDevice`
      // （`RcEndpointService` 私有构造、宿主无法实例化 ⇒ 内联在方法里时只能被
      // 源码锁覆盖，而源码锁锁不住语义；行为锁见 `test/salt_reuse_lock_test.dart`）。
      // ⚠️ 必须 `stripComments`：否则下面几条会被**文档注释**里的同名文字满足 ⇒ 恒真。
      final ensure = stripComments(
          methodBody(src, 'Future<List<int>?> ensureSaltForDevice('));
      expect(ensure.contains('saltFor('), isTrue,
          reason: '★ 重复配对必须**复用已存盐**；每次重新生成会让两端密钥不一致');
      expect(ensure.contains('KdfSaltStore.newSalt()'), isTrue);
      expect(ensure.contains('saveSalt('), isTrue);
      expect(code.contains('ensureSaltForDevice(_saltStore, deviceId)'), isTrue,
          reason: '_ensureSalt 必须**转发**到顶层真源，否则两处语义会漂移');
    });

    test('Q1-04 控制端消费回执并落盘对端盐（同文件内，无需越界）', () {
      // P1-13 重构后，"消费回执 → 落对端盐"从 `requestPairing` 的**内联等待**
      // 下沉到回执关联真源 `_tapAck`：这样**迟到**的 ack（8s UI 窗口之外）
      // 也能完成绑定与落盐 —— 若仍锁在 `requestPairing` 里，反而会把
      // "只认 8 秒内回执"的旧缺陷重新锁死。判据意图不变：
      // **ack 里的 kdfsalt 必须被解出来落盘**。
      final tap = methodBody(src, 'Future<void> _tapAck(');
      expect(tap.contains('RcEvt.ack'), isTrue,
          reason: '落盐发生在 ack 消费点，不是任意消息');
      expect(tap.contains('_savePeerSalt('), isTrue);
      expect(tap.contains("msg.payload['kdfsalt']"), isTrue);

      final save = methodBody(src, 'Future<void> _savePeerSalt(');
      expect(save.contains('base64Decode('), isTrue);
      expect(save.contains('saveSalt('), isTrue);
    });

    test('Q1-05 每个 deriveKey 调用点都带 saltFor 派生的盐（剥注释后扫）', () {
      expect(allDeriveSitesNearSalt(code), isTrue,
          reason: '任一条链路退化成无盐派生，就会与带盐的对端静默失配');
      // 逐点复核盐来源（避免"窗口碰巧够到隔壁"）。
      expect(code.contains("RcCodec.deriveKey(ownCode, '\$ownId|cmd', salt: salt)"),
          isTrue,
          reason: 'cmd 接收（_handleRaw 经 _cmdKey 缓存助手派生）：候选里有 saltFor');
      expect(code.contains("RcCodec.deriveKey(ownCode, '\$ownId|evt', salt: salt)"),
          isTrue, reason: 'evt 接收（_handlePeerEvent）');
      expect(
          code.contains("'\${peer.deviceId}|evt', salt: salt)"),
          isTrue,
          reason: '发送回执（_send）：按对端 deviceId 取盐');
      // REM-01 v3 重构后 sendTo 的本地变量改名 target（`fresh ?? endpoint`），
      // flushOutbox 仍叫 endpoint —— 两处都必须按**对端 deviceId** 取盐，
      // 否则补发密文与在线路径密钥不一致，接收端一律解不开（BUG-053 同族）。
      expect('saltFor(target.deviceId)'.allMatches(code).length, 1,
          reason: 'sendTo：按对端 deviceId 取盐（无存盐 → null → v1）');
      expect('saltFor(endpoint.deviceId)'.allMatches(code).length, 1,
          reason: 'flushOutbox：与 sendTo 同一份盐，变量名不同但语义同一');
    });

    test('Q1-06 deriveKey 调用点恰为 5 个（新增未加盐的调用点会判红）', () {
      expect('RcCodec.deriveKey('.allMatches(code).length, 5,
          reason: 'Q1 报告的 5 个调用点：_cmdKey（缓存助手，_handleRaw 经它派生）'
              '/ _handlePeerEvent / _send / sendTo / flushOutbox');
    });

    test('Q1-07 反例：无盐调用样本必须判红（证明窗口检查非恒真）', () {
      const bad = r'''
Future<int> flushOutbox(RemoteStore store, PairedEndpoint endpoint) async {
  final key = await RcCodec.deriveKey(endpoint.secret, '${endpoint.deviceId}|cmd');
  return 0;
}
''';
      expect(allDeriveSitesNearSalt(bad), isFalse);
      expect(allDeriveSitesNearSalt(''), isFalse,
          reason: '空样本不得被判成"通过"（否则检查器恒真）');
    });

    test('Q1-08 反例：部分调用点漏盐 / 写死 salt: null 都必须判红', () {
      const partial = r'''
Future<void> a() async {
  final s = saltFor('x');
  final k = await RcCodec.deriveKey('sec', 'ctx', salt: s);
}
Future<void> b() async {
  final k = await RcCodec.deriveKey('sec', 'ctx');
}
''';
      expect(allDeriveSitesNearSalt(partial), isFalse,
          reason: '第二个调用点**没写 salt:** ⇒ 必须判红（逐调用点都要过；'
              '这条同时证明"字符窗口"不是唯一判据 —— 短样本里窗口会把整段覆盖）');

      const zeroSalt = r'''
Future<void> c() async {
  final k = await RcCodec.deriveKey('sec', 'ctx', salt: null);
}
''';
      expect(allDeriveSitesNearSalt(zeroSalt), isFalse,
          reason: '写死 `salt: null` = 零盐/默认盐，任务书明令禁止');

      // 形参透传（提取方法）也不是免检牌：助手被**无 saltFor 来源**的实参
      // 调用时，传递校验必须判红 —— 证明第 4 条分支不是恒真。
      const helperConstSalt = r'''
Future<List<int>> helper(String code, List<int>? salt) async {
  return await RcCodec.deriveKey(code, 'x|cmd', salt: salt);
}
Future<void> caller() async {
  final k = await helper('code', const [1, 2, 3]);
}
''';
      expect(allDeriveSitesNearSalt(helperConstSalt), isFalse,
          reason: '助手的调用点窗口里没有 saltFor ⇒ 盐来源不可证，必须判红');
    });

    test('Q1-09 两个接收链路都保留了 null 候选（v1 兜底不得被删）', () {
      final raw = methodBody(src, 'Future<void> _handleRaw(String topic, String wire)');
      expect(raw.contains('<List<int>?>[null]'), isTrue,
          reason: 'cmd 接收的候选必须**首项为 null**：否则未存盐的旧控制端全被拒收');
      final evt =
          methodBody(src, 'Future<void> _handlePeerEvent(');
      expect(evt.contains('<List<int>?>[null, _saltStore?.saltFor(peerId)]'), isTrue,
          reason: 'evt 接收同样要保留 null：配对成功回执本身是 v1 引导报文');
    });
  });

  // ══════════════════════════════════════════════════ D-7 · 动作级裁决
  group('D-7 残余面：纯判据真值表', () {
    test('D7-01 缺位 → 拒绝（只放行 script 的协助方不能触发 record 任务）', () {
      final required = TaskWire.requiredPermBitsForTaskAction(
          {'kind': 'record', 'seconds': 30});
      expect(required, {'record'});
      final deny =
          taskActionPermDeny(required, (bit) => bit == 'script', enabling: true);
      expect(deny, isNotNull);
      expect(deny, contains('未放行'));
    });

    test('D7-02 全部放行 → 放行（判据非恒真）', () {
      expect(
          taskActionPermDeny({'record'}, (_) => true, enabling: true), isNull);
    });

    test('D7-03 空 required → 放行（不需要额外权限位的动作）', () {
      expect(taskActionPermDeny(const <String>{}, (_) => false, enabling: true),
          isNull);
    });

    test('D7-04 ★ enabled=false（关任务）缺位也放行 —— 不得降级到更不安全的一侧', () {
      expect(taskActionPermDeny({'record'}, (bit) => false, enabling: false), isNull,
          reason: '拒绝"关闭"等于把越权打开的任务锁死在使用者无法关闭的状态');
    });

    test('D7-05 嵌套 composite.primary=record 也能识别（不能只看顶层 kind）', () {
      final required = TaskWire.requiredPermBitsForTaskAction({
        'kind': 'composite',
        'primary': {'kind': 'record', 'seconds': 10},
      });
      expect(required, {'record'});
      expect(taskActionPermDeny(required, (bit) => bit == 'script', enabling: true),
          isNotNull);
    });

    test('D7-06 randomFrom 候选里的 record 也能识别', () {
      final required = TaskWire.requiredPermBitsForTaskAction({
        'kind': 'randomFrom',
        'candidates': [
          {'weight': 1, 'action': {'kind': 'play'}},
          {'weight': 1, 'action': {'kind': 'record', 'seconds': 5}},
        ],
      });
      expect(required, {'record'});
    });

    test('D7-07 非敏感动作不需要额外位 → 放行', () {
      final required = TaskWire.requiredPermBitsForTaskAction(
          {'kind': 'play', 'assetIds': <String>[]});
      expect(required, isEmpty);
      expect(taskActionPermDeny(required, (bit) => false, enabling: true), isNull);
    });
  });

  group('D-7 残余面：接线锁（源码契约）', () {
    test('D7-08 _runTaskNow 在**执行之前**做动作级裁决，且缺位时 skipped + 拒绝', () {
      final body = methodBody(src, 'Future<void> _runTaskNow(');
      expect(
          gateBeforeExec(body, '_assistActionDeny(', 'BackgroundServiceManager.instance.runNow('),
          isTrue,
          reason: '★ 未接线 / 裁决排在执行之后 ⇒ 协助方仍可绕开采集红线');
      expect(body.contains("status: 'skipped'"), isTrue,
          reason: '被拒必须留痕，不能静默');
      expect(body.contains('_ack(msg, false, data: deny)'), isTrue,
          reason: '必须显式回执拒绝，否则控制端只看到超时');
    });

    test('D7-09 taskToggle 只在"开启"时裁决，且缺位时 skipped + 拒绝', () {
      final body = methodBody(
          src, 'Future<void> _dispatch(RcMessage msg, PairedEndpoint peer)');
      expect(body.contains('_assistActionDeny('), isTrue);
      expect(body.contains('enabling: enabled'), isTrue,
          reason: '把 enabled 传进判据 —— 关闭必须永远放行');
      expect(body.contains("action: 'task.toggle'"), isTrue);
      expect(body.contains("status: 'skipped'"), isTrue);
    });

    test('D7-10 裁决只在协助会话下生效（配对通道 = 全权，不得误伤）', () {
      final helper = methodBody(src, 'String? _assistActionDeny(Task task, {required bool enabling})');
      expect(helper.contains('Zone.current[assistReplyZone] != true'), isTrue,
          reason: '配对通道没有权限位；无条件读协助权限会把已配对设备整体拒掉');
      expect(helper.contains('RcPermGate.hasPerm'), isTrue);
      expect(helper.contains('requiredPermBitsForTaskAction'), isTrue);
    });

    test('D7-11 反例：没有裁决调用 / 裁决排在执行之后的样本必须判红', () {
      const noGate = '''
Future<void> _runTaskNow(RcMessage msg) async {
  final r = await BackgroundServiceManager.instance.runNow('x');
}
''';
      final b1 = methodBody(noGate, 'Future<void> _runTaskNow(');
      expect(b1.contains('_assistActionDeny('), isFalse);
      expect(
          gateBeforeExec(
              b1, '_assistActionDeny(', 'BackgroundServiceManager.instance.runNow('),
          isFalse);

      const lateGate = '''
Future<void> _runTaskNow(RcMessage msg) async {
  final r = await BackgroundServiceManager.instance.runNow('x');
  final deny = _assistActionDeny(task, enabling: true);
}
''';
      final b2 = methodBody(lateGate, 'Future<void> _runTaskNow(');
      expect(
          gateBeforeExec(
              b2, '_assistActionDeny(', 'BackgroundServiceManager.instance.runNow('),
          isFalse,
          reason: '裁决排在执行之后等于没裁决');
    });
  });
}
