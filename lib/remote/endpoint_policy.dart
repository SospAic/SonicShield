part of 'endpoint_service.dart';

/// [AssistTransport] 的 MQTT 实现：只负责"订阅 / 退订 / 发布字节"。
///
/// 定义在**同一文件内**是为了访问 [RcEndpointService] 的私有连接状态
/// （Dart 私有性按库划分）；它刻意不持有任何密钥 —— 密文由
/// [RcAssistHost] 加密后传入，密钥不出该模块。
class _MqttAssistTransport implements AssistTransport {
  _MqttAssistTransport(this._svc);

  final RcEndpointService _svc;

  @override
  Future<void> subscribe(String topic) async {
    final client = _svc._client;
    if (client == null) return;
    if (client.connectionStatus?.state != MqttConnectionState.connected) return;
    client.subscribe(topic, MqttQos.atLeastOnce);
  }

  @override
  Future<void> unsubscribe(String topic) async {
    _svc._client?.unsubscribe(topic);
  }

  @override
  Future<void> publishWire(String topic, String wire) async {
    final client = _svc._client;
    if (client == null) return;
    if (client.connectionStatus?.state != MqttConnectionState.connected) return;
    final builder = MqttClientPayloadBuilder()..addString(wire);
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
        retain: false);
  }
}

// ==================== 可测的纯裁决（端点服务内部逻辑的外提） ====================
//
// 下面几个函数从 [RcEndpointService] 的私有方法里抽出：它们的输入是
// 「已经读到的外部状态」，输出是「该怎么回执 / 该不该执行」——
// 与 MQTT、数据库、插件实例全都无关，因此可以在 host 单测里**穷举组合**
// 来锁死行为。端点服务的接线部分由 `test/endpoint_*_test.dart` 的
// 源码契约锁兜住（私有方法无法在宿主机实例化，这是本项目既有做法）。

/// 解析一条出站事件的**投递集合**（R-6，纯函数 → 可穷举断言）。
///
/// 返回：
/// - `null`：**无法投递**（点名了某控制端但它不在配对表）→ 调用方必须留痕并
///   放弃发送。**不得**退化成"广播给所有人" —— 那正是跨控制器泄露本身；
/// - 空列表：无已配对端点（由调用方按"无已配对端点"留痕）；
/// - 非空列表：实际要逐份加密的目标。`paired` 非空时必定非空（只会是它的子集）。
///
/// ⚠️ `targetPeerId` 为**空串**时按广播处理：发送方未标识自己
/// （`tool/rc_probe.dart` 探针不填 `from`），无法定向；丢弃会让探针整体失联。
/// `null`（调用方明确要求广播）与空串在此**同义**，这是有意为之。
List<PairedEndpoint>? resolveRcDelivery(
    List<PairedEndpoint> paired, String? targetPeerId) {
  if (paired.isEmpty) return const <PairedEndpoint>[];
  if (targetPeerId == null || targetPeerId.isEmpty) return paired;
  final only = endpointById(paired, targetPeerId);
  return only == null ? null : <PairedEndpoint>[only];
}

/// 入站配对遥控命令的**准入裁决**（纯函数 → 可在宿主机穷举断言）。
///
/// ## 为什么必须有它（P0：解除配对后授权未撤销）
///
/// 修复前，`/cmd` 的准入**只有一条**：「能用本机配对码 + `{本机ID}|cmd`
/// 解密成功」。而配对码是**全体已配对控制端共享**的、且**无轮换入口**
/// （`ensurePairingCode` 只在长度≠8 时生成一次）。于是 `removePaired(id)` 只把
/// 该控制端移出本机列表，**拦不住它的任何命令** —— 「配对移出了列表，但对方
/// 仍能控制本机」。更糟的是 `_peerOf` 在列表里查不到时还会**构造占位对端**
/// 继续 `_dispatch`，等于默认放行。
///
/// 现在补上真正在**执行之前**的判据：发送方必须**仍在**当前配对表里。
///
/// ## 判据（顺序即优先级）
///
/// 1. `pair.request` → [RcAdmission.allowPairing]：它正是"把控制端登记进本机
///    配对表"的握手；若连它也拒，解除配对后将**永远无法重新配对**（在配对码
///    无轮换入口的前提下，这是唯一恢复路径）。
/// 2. `senderId` 为空 → [RcAdmission.rejectUnidentified]：**拒绝**。
/// 3. `senderPaired` 为真 → [RcAdmission.allowPaired]。
/// 4. 其余 → [RcAdmission.rejectUnpaired]：**点名了发送方却不在表里**
///    （从未配对，或**已被解除配对**）→ 拒绝（fail-closed）。
///
/// ## 判据**无状态**：同一输入恒得同一裁决（幂等），且判决某一发送方**不会**
/// 改变其它发送方的裁决 —— 故"解除配对一台"不影响其它已配对端点。
///
/// ## R94：为什么"空 from"必须拒绝（原 P0-001 / REM-01）
///
/// 旧实现在这一格返回 `allowUnidentified`（放行），理由是"探针/旧控制端可能
/// 不填 `from`"。而 `msg.from` 是信封里由发送方**自报**的字段（见
/// `RcMessage.from` 注释「不参与鉴权」），且它**在密文之内** —— 持有配对码者
/// 可写入任意值。于是 `senderId.isEmpty → 放行` 直接给出了一条**绕过整条
/// 准入判据**的旁路：任何拿到配对码的人只要把 `from` 留空，就能跳过
/// [RcAdmission.rejectUnpaired] / [RcAdmission.rejectRevoked]，对已被
/// **解除配对**的设备继续下发全部指令。这正是「未经授权控制他人设备」
/// （`docs/08 §2` 红线）的实现级缺口。
///
/// 裁决（R94）：**fail-closed**。识别不了发送方就拒绝执行，并在审计里留痕。
/// 代价是探针工具必须显式填写 `from`（`tool/rc_probe.dart` /
/// `tool/rc_e2e_controller.dart` 已同步补上），旧控制端若真不填 `from` 也会
/// 被拒 —— 这是有意为之：**"我不知道你是谁" 不等于 "我允许你做任何事"**。
///
/// 真正的根治是 per-controller 密钥（v3）：身份由"用哪把 peerKey 解开"
/// 决定，不再依赖自报字段。见 [RcCodec.decodeWithCandidates] 与
/// `peer_key_store.dart`。本判据在 v3 之后仍然保留，作为 v1/v2 旧配对的
/// 兜底防线（纵深防御，不是过渡遗留）。
RcAdmission decideRcAdmission({
  required String senderId,
  required String type,
  required bool senderPaired,
  bool senderRevoked = false,
}) {
  // BUG-110：**已撤销授权**的设备一律拒，且**连配对握手也不放行**。
  //
  // 旧实现在第一行就无条件 `allowPairing`，于是「删掉设备」之后它只要再发
  // 一次 `pair.request` 就能把自己重新登记回去（`_handlePairRequest` 查不到
  // 记录就 `addPaired`），而配对码是共享且未轮换的 ⇒ 撤销形同虚设。
  // 判据放在**最前**：撤销是比"配对握手"更强的否决。
  // 恢复路径仍然存在 —— 本机轮换配对码（`rotatePairingCode` 会清空撤销表）。
  if (senderRevoked) return RcAdmission.rejectRevoked;
  if (type == RcCmd.pairRequest) return RcAdmission.allowPairing;
  // R94 / P0-001：识别不了发送方 ⇒ **拒绝**（旧实现在此放行，构成撤销绕过）。
  if (senderId.isEmpty) return RcAdmission.rejectUnidentified;
  if (senderPaired) return RcAdmission.allowPaired;
  return RcAdmission.rejectUnpaired;
}

/// [decideRcAdmission] 的裁决结果（值即语义，供审计与测试断言）。
enum RcAdmission {
  /// 配对握手：无条件放行（登记控制端）。
  allowPairing,

  /// 发送方**未标识**自身（`from` 为空）：**拒绝执行**（R94 / P0-001）。
  ///
  /// 旧值 `allowUnidentified` 是放行，等价于「我不知道你是谁，但我允许你做
  /// 任何事」—— 持有配对码者只要把 `from` 留空即可绕过全部准入判据。
  rejectUnidentified,

  /// 发送方在当前配对表内：放行。
  allowPaired,

  /// 发送方已不在配对表（从未配对或**已被解除配对**）：**拒绝执行**。
  rejectUnpaired,

  /// 发送方在**撤销名单**里（本机主动解除过它的配对）：**拒绝执行**，
  /// 且**连配对握手都拒**（BUG-110）。恢复需本机轮换配对码。
  rejectRevoked;

  /// 是否放行。**唯一**决定"要不要 `_dispatch`"的判据。
  ///
  /// R94 起改为**白名单**（只列放行项）而不是黑名单（列拒绝项）：今后若再
  /// 新增裁决值，默认落到"拒绝"，不会因为忘记在 `allowed` 里补一条就静默
  /// 放行 —— 这正是 P0-001 的教训。
  bool get allowed =>
      this == RcAdmission.allowPairing || this == RcAdmission.allowPaired;
}

/// 解密失败审计的**限频器**（R-2）：同一主题 [windowMs] 内只放行一条。
///
/// 抽成独立类是为了能在宿主机上直接断言"10s 内只写一条" ——
/// 端点服务本身依赖 MQTT/数据库/插件实例，宿主无法实例化。
class DecodeFailThrottle {
  DecodeFailThrottle({this.windowMs = 10000});

  final int windowMs;
  final Map<String, int> _lastAt = <String, int>{};

  /// 该主题此刻是否应当写审计；返回 true 时同时记下本次时刻。
  ///
  /// ⚠️ 用 `containsKey` 而不是 `?? 0` 判"没记过"：后者把"从未见过"与
  /// "见过（时刻为 0）"混为一谈 —— 依赖调用方传入的时间戳足够大才能正确工作，
  /// 而这种隐式前提正是单元测试里第一个被踩到的坑。
  bool allow(String topic, int nowMs) {
    final last = _lastAt[topic];
    if (last != null && nowMs - last < windowMs) return false;
    _lastAt[topic] = nowMs;
    return true;
  }
}

/// 点名 peer evt 解密失败的"最近成功"抑制窗口（P2-22，10 分钟）。
const int rcPeerEvtNoiseWindowMs = 10 * 60 * 1000;

/// 远程 TTS 步骤携带的**音色 id** 长度上限（v2.0）。
///
/// 音色 id 是 "sys_zh_female" / "az_db_male_yunbiao" 这类稳定短标识（≤ 32），
/// 给一倍余量到 64 只为**挡住畸形超长串**（入站数据不可信）。未知 id 不影响
/// 正确性 —— `TtsVoices.byId` 会回落默认音色，不需要在这里做白名单校验。
const int _maxVoiceIdLen = 64;

/// 点名 peer evt 解密失败是否**值得审计**（P2-22 纯判据）。
///
/// 该来源**从未成功**或**最近一次成功已超过 [rcPeerEvtNoiseWindowMs]** ⇒ 值得记；
/// 反之（最近成功过）= 整体链路是通的，期间解不开多半是"广播副本"噪声，不记。
bool peerEvtFailWorthAudit({int? lastOkMs, required int nowMs}) =>
    lastOkMs == null || nowMs - lastOkMs >= rcPeerEvtNoiseWindowMs;

/// 配对登记的最长存活时间（P1-13）：弱网下 ack 可能迟到，但不能无限增长。
const int rcPairPendingTtlMs = 10 * 60 * 1000;

/// 一次进行中的配对请求（P1-13）。
///
/// `waiter` 供 [RcEndpointService._awaitAck] 等 UI 结果；注册表里的登记**不因
/// 8 秒超时而撤销** —— 迟到 ack 到达时 `_tapAck` 仍会落盐并 complete 它。
class _PendingPair {
  _PendingPair(this.endpointId, this.createdAtMs)
      : waiter = Completer<Map<String, dynamic>?>();

  final String endpointId;
  final int createdAtMs;
  final Completer<Map<String, dynamic>?> waiter;
}

/// 指令组**终态**事件载荷（R-4，纯函数）。
///
/// `skipped` 列出**被跳过/未执行**的步骤（权限拒绝、振动无处理器、
/// 录音无权限、播放无音源…），随 `state` 一并回给控制端。
///
/// ⚠️ 为什么必须带上它：`state:done` 只说明"跑完了"，不说明"每一步都做了"。
/// 端点跳过 3 步与全部做完，在控制端**看起来完全一样** ——
/// 这正是"成功被误报"的同一形状。`skipped` 恒定存在（可为空列表），
/// 让消费端不必区分"字段缺失"与"没有跳过"。
Map<String, dynamic> rcScriptStatePayload(
  String scriptId, {
  required bool done,
  List<String> skipped = const <String>[],
}) =>
    {
      'scriptId': scriptId,
      'state': done ? 'done' : 'stopped',
      'skipped': skipped,
    };

/// 配对请求的结局（R-2，控制端 UI 据此提示，**绝不静默**）。
///
/// `message` 是**可直接展示**的中文结论：成功、对端明确拒绝、
/// 8 秒内没有回音、或本机根本没发出去 —— 四种情形对用户而言
/// 需要完全不同的下一步动作，合并成一句"配对失败"就是新的静默失败。
class PairConfirmOutcome {
  const PairConfirmOutcome(this.confirmed, this.message);

  final bool confirmed;
  final String message;
}

/// 远程 `guard.set` 的裁决结果。
class GuardSetOutcome {
  const GuardSetOutcome(this.ok, this.reason);

  final bool ok;

  /// 可直接回给对端的原因（成功时是一句确认语）。
  final String reason;
}

/// 由「引擎是否在跑 + 是否观察到期望状态」推导 `guard.set` 回执。
///
/// ⚠️ 三种失败必须给出**互不相同**的指引，合并成一句就是新的静默失败：
/// - 引擎没跑 → 远程**不能**替端点开引擎（那是端点的本地设置）；
/// - 引擎明确报了启动失败原因 → 多半是麦克风权限，而远程**无法弹权限窗**；
/// - 等不到回音 → 引擎无响应（卡住 / 被杀）。
GuardSetOutcome decideGuardSet({
  required bool enabled,
  required bool engineRunning,
  required bool observed,
  String? guardError,
}) {
  if (!engineRunning) {
    return GuardSetOutcome(
      false,
      enabled
          ? '后台引擎未运行：需端点在「守护」页开启引擎；开启守卫还需端点在前台授予麦克风权限'
          : '后台引擎未运行：需端点在「守护」页开启引擎',
    );
  }
  if (observed) {
    return GuardSetOutcome(true, enabled ? '守卫已开启' : '守卫已关闭');
  }
  final e = guardError;
  if (enabled && e != null && e.isNotEmpty) {
    return GuardSetOutcome(
        false, '守卫启动失败：$e（远程无法申请麦克风权限，需端点在前台授权）');
  }
  return const GuardSetOutcome(false, '引擎无响应：未能确认守卫状态');
}

/// 协助会话下**指令组步骤**的权限裁决。
class RcStepVerdict {
  const RcStepVerdict(this.allowed, this.reason);

  final bool allowed;
  final String reason;
}

/// 指令组步骤在当前协助权限下是否可执行。
///
/// ⚠️ **必须显式处理 `need == null`**：`RcPermGate.hasPerm(perms, null)` 会落到
/// `_ => false` 分支，把只读步骤（`delay` / `notify`）误判为拒绝 ——
/// 那样一个只有 `script` 位的对端连"等 5 秒"都做不到。
///
/// `record`（录音取证）返回 [RcPermGate.denyAll]：它不是任何权限位，
/// 因此**任何** [AssistPerms] 都放行不了它 —— 协助会话下一律拒绝（docs/18 §10）。
RcStepVerdict gateRcScriptStep(RcStepKind kind, {required AssistPerms perms}) {
  final need = RcPermGate.requiredStepPerm(kind);
  if (need == null) return const RcStepVerdict(true, '');
  if (RcPermGate.hasPerm(perms, need)) return const RcStepVerdict(true, '');
  return RcStepVerdict(
    false,
    need == RcPermGate.denyAll
        ? '该步骤类型在协助会话下一律拒绝（未登记权限位）'
        : '权限「${AssistPerms.labels[need] ?? need}」未放行',
  );
}

/// D-7 残余面：任务**动作级**权限裁决（纯函数 → 宿主可穷举断言）。
///
/// 返回 null = 放行；否则为**可直接回给对端**的拒绝原因。
///
/// ## 为什么必须有它
///
/// 命令级门控（[RcPermGate.requiredPerm]）只把 `task.runNow` / `task.toggle`
/// 映射到 `script` 位。若不在**动作层**再看一眼，只放行 `script` 位的协助方
/// 可对**既有** `recordEvidence` 任务触发录音（`task.runNow`）或把它打开
/// （`task.toggle{enabled:true}`），绕开
/// `RcPermGate.requiredStepPerm(record) == denyAll` 与 docs/22 §9 采集红线。
///
/// `task.upsert` 已在 `RcAssistHost._taskPayloadDeny` 于**载荷层**拦住（第 34
/// 轮 X1）；`task.runNow` 只带 `taskId`、`task.toggle` 只带 `taskId + enabled`，
/// 宿主层**无从得知**目标任务的动作类型 —— 必须在端点服务**装配任务之后**、
/// **执行之前**用本函数裁决（接线见 `_assistActionDeny` → `_runTaskNow` /
/// `taskToggle`）。
///
/// ## 关闭任务永远放行（铁律）
///
/// `enabling == false`（关任务）**无条件**放行：关掉是**更安全**的一侧。
/// 安全选项的失败路径**不得**降级到更不安全的一侧 —— 若因"缺权限"而拒绝
/// 关闭，等于把越权打开的任务锁死在使用者无法关闭的状态。
///
/// ## 判据非恒真
///
/// - `required` 为空（动作不需要额外权限位）→ 放行；
/// - `required` 有缺位 → 拒绝（[TaskWire.firstMissingPermBit]）。
String? taskActionPermDeny(
  Set<String> required,
  bool Function(String) granted, {
  required bool enabling,
}) {
  if (!enabling) return null;
  final missing = TaskWire.firstMissingPermBit(required, granted);
  if (missing == null) return null;
  return '任务动作需要权限「${AssistPerms.labels[missing] ?? missing}」，未放行';
}

/// 把 outbox 里的一条暂存线格式**重放就绪**：解密（**忽略时间窗**）→
/// 换新时间戳与新 ID → 重新加密。返回 null 表示该条目无法重放（密文损坏 /
/// 密钥不符）→ 调用方应丢弃它，否则它会**永久卡住整个队列**。
///
/// ⚠️ 为什么必须重盖时间戳与 ID：`RcCodec.decode` 有 ±90s 时间窗，且接收端
/// 按 ID 去重。一条两小时前入 outbox 的命令，若原样重发，接收端会**因为超窗
/// 而拒收**（或因为 ID 已见过而判重放）—— 那样"端点上线后自动执行"仍然是
/// 一句空话，只是失败点从"没人补发"挪到了"补发了但被丢"。
/// 重放是**此刻的发送行为**，信封就该是此刻的。
/// [peerKey] 非空 ⇒ 按 **v3** 试解/重编码（候选只有这一把，因为 outbox 是
/// 按端点分桶的，不存在"猜是哪台控制端"的问题）。v3 报文在 `peerKey` 缺失时
/// 解不开是**正确行为**：撤销删掉钥匙后，队列里那些密文就该永久作废。
Future<String?> prepareOutboxReplay(
  String wire,
  List<int> key,
  String topic, {
  List<int>? peerKey,
  String peerContext = '',
}) async {
  // 窗口放到极大：这里要的是"把当年那条命令解出来"，不是"验证它还新"。
  final stale = await RcCodec.decode(wire, key, topic,
      maxSkewMs: const Duration(days: 3650).inMilliseconds,
      candidateKeys: peerKey == null ? const <List<int>>[] : <List<int>>[peerKey],
      peerContext: peerContext);
  if (stale == null) return null;
  final fresh = RcMessage(
    id: RcMessage.now(stale.type).id,
    ts: DateTime.now().millisecondsSinceEpoch,
    type: stale.type,
    payload: stale.payload,
    from: stale.from,
  );
  return peerKey == null
      ? RcCodec.encode(fresh, key, topic)
      : RcCodec.encode(fresh, key, topic,
          peerKey: peerKey, peerContext: peerContext);
}

// ══════════════════════════════════════════════════════════════════════
// 第三十四轮：C-1 / P1 的**顶层判据**
// ══════════════════════════════════════════════════════════════════════
//
// 项目通则：**判据与接线分离**。凡是"该不该做 / 该做哪一些"的决策，都抽成
// 不依赖插件实例的纯函数放在这里（同 `decideRcAdmission` / `gateRcScriptStep`），
// 于是宿主测试能穷举断言 + 变异证伪；服务方法里只留
// "取状态 → 调判据 → 执行 → 记账"。
//
// 这不是为了覆盖率好看：本轮两个改动（定位三步闸门、撤销清场）此前都会埋在
// 私有方法里、依赖 geolocator/DB/MQTT 实例，**只能靠真机取证**；抽出来之后
// 每一条分支都能在 `flutter test` 里被钉住。

/// 配对撤销时**该清掉哪些在途作业**的判据（P1）。
///
/// ## 为什么必须逐项归属，而不是"有在途就全停"
///
/// 一台设备可以同时被**多个**控制端配对。撤销其中一台时，若写成
/// "停掉所有在途作业"，就会**误伤**另一台仍在授权中的控制端 ——
/// 它下发的指令组会被莫名终止（使用者看到"没人点它，它自己停了"）。
/// 撤销必须是**逐发送方**、**无状态**的（与 `decideRcAdmission` 同一纪律）。
///
/// ⚠️ `scriptOwnerId` / `callPeerId` 为 null 时**一律不停**：
/// "不知道是谁在跑的" ≠ "就是它"。宁可漏停一次（下一轮命令会被准入拒掉），
/// 也不能误停另一个授权控制端的作业。
class RcRevokePlan {
  const RcRevokePlan({required this.stopScript, required this.hangUpCall});

  /// 终止在途指令组。
  final bool stopScript;

  /// 挂断在途通话。
  final bool hangUpCall;

  /// 无事可做 —— 调用方据此**不写**审计，避免把日志刷成噪声。
  bool get isEmpty => !stopScript && !hangUpCall;

  /// 审计文案里"停掉了什么"。
  String get label => [if (stopScript) '指令组', if (hangUpCall) '通话'].join('、');
}

/// 决定撤销 [revokedId] 时要清掉哪些在途作业。
RcRevokePlan decideRevokeCleanup({
  required String revokedId,
  required String? scriptOwnerId,
  required bool scriptRunning,
  required String? callPeerId,
  required bool callActive,
}) {
  final hit = revokedId.isNotEmpty;
  return RcRevokePlan(
    stopScript:
        hit && scriptRunning && scriptOwnerId != null && scriptOwnerId == revokedId,
    hangUpCall: hit && callActive && callPeerId != null && callPeerId == revokedId,
  );
}

/// 定位获取失败的原因（C-1）。
///
/// 三种原因的**用户指引互不相同** —— 合并成一句"定位失败"就是新的静默失败
/// （同 `guardSetVerdict` 的纪律）：
/// - 没授权 → 要去系统**弹窗/settings** 里允许定位；
/// - GPS 关着 → 要去系统设置里**打开定位服务**（此时权限可能已是 granted）；
/// - 都正常却取不到 → 无信号 / 超时 / 平台异常，重试或换个环境。
enum RcLocationFailure {
  /// 权限未授予（端点上没人点"允许"，或已被永久拒绝）。
  permissionDenied,

  /// 系统定位服务（GPS 总开关）关闭。
  serviceDisabled,

  /// 权限与服务都正常，但取位置本身失败（无信号 / 超时 / 平台异常）。
  fixFailed,
}

/// 一次定位探测的结果：要么带坐标，要么带**可展示的原因**。
class RcLocationProbe {
  const RcLocationProbe.ok(Position this.position)
      : failure = null,
        detail = '';

  const RcLocationProbe.failed(RcLocationFailure this.failure, this.detail)
      : position = null;

  final Position? position;
  final RcLocationFailure? failure;
  final String detail;

  bool get ok => position != null;
}

/// 「取一次位置」的三步闸门（C-1）。
///
/// 三步**都不做任何绕过**：
/// 1. 运行时权限（危险权限，必须端点上的人点"允许"）；
/// 2. 系统定位服务开关；
/// 3. 取一次位置。
///
/// **顺序是语义要求**：先权限、后服务。反过来的话，权限被拒时用户会先被
/// 引导去"打开 GPS"，打开了还是不行 —— 白折腾一轮，而且真正的原因
/// （没授权）反而被掩盖。
Future<RcLocationProbe> acquireLocationOnce({
  required Future<bool> Function() permissionGate,
  required Future<bool> Function() serviceEnabled,
  required Future<Position> Function() fix,
}) async {
  try {
    if (!await permissionGate()) {
      return const RcLocationProbe.failed(RcLocationFailure.permissionDenied,
          '定位权限未授予（需端点在系统弹窗中允许定位）');
    }
    if (!await serviceEnabled()) {
      return const RcLocationProbe.failed(RcLocationFailure.serviceDisabled,
          '系统定位服务已关闭（需端点在系统设置中开启定位）');
    }
    return RcLocationProbe.ok(await fix());
  } on Object catch (e) {
    return RcLocationProbe.failed(RcLocationFailure.fixFailed,
        '定位失败：$e（需端点授予定位权限并开启定位服务）');
  }
}

// ══════════════════════════════════════════════════════════════════════
// Q10：命令限流 + 停类优先（判据与接线分离，宿主可穷举断言）
// ══════════════════════════════════════════════════════════════════════

/// Q10 限流窗口默认长度（毫秒）：60s 窗。
const rcRateLimitWindowMs = 60 * 1000;

/// Q10 限流窗口内默认允许条数：30 条。
const rcRateLimitMaxPerWindow = 30;

/// 单端点时间戳内存表硬上限（防涨；出窗即裁后通常远小于此值）。
const maxCmdTsPerEndpoint = 200;

/// 滑窗限流的裁决结果（Q10）。
class RateLimitVerdict {
  const RateLimitVerdict.allow()
      : allowed = true,
        retryAfterMs = 0;
  const RateLimitVerdict.reject(this.retryAfterMs) : allowed = false;

  /// 是否放行本条命令。
  final bool allowed;

  /// 拒绝时建议等待的毫秒数（恒 > 0；放行时为 0）。
  final int retryAfterMs;
}

/// 滑动窗口限流判定（Q10，纯函数 → 可穷举断言）。
///
/// [recentTs] 是该发送方**已被放行**命令的时间戳（毫秒）。调用方在**放行前**
/// 调用本函数：窗口 `(nowMs - windowMs, nowMs]` 内已有 [maxPerWindow] 条
/// ⇒ 本条是第 max+1 条，拒绝；否则放行。默认 60s 窗 30 条。
///
/// 纯函数：不改 [recentTs]、不落库、不依赖实例状态。[deviceId] 只是桶标识
/// （判定本身只依赖时间戳），供调用方按端点分表使用。拒绝时给出
/// [RateLimitVerdict.retryAfterMs]（窗口内最早一条滑出窗口所需的时间），
/// 让控制端能提示"何时可重试"。被拒的命令**不记入** [recentTs]：
/// 否则每次拒绝都会把窗口往后推，形成"越拒越久"的惩罚螺旋。
RateLimitVerdict rateLimitFor(
  String deviceId,
  int nowMs,
  List<int> recentTs, {
  int windowMs = rcRateLimitWindowMs,
  int maxPerWindow = rcRateLimitMaxPerWindow,
}) {
  final cutoff = nowMs - windowMs;
  var oldest = -1;
  var count = 0;
  for (final t in recentTs) {
    if (t <= cutoff || t > nowMs) continue;
    count++;
    if (oldest < 0 || t < oldest) oldest = t;
  }
  if (count < maxPerWindow) return const RateLimitVerdict.allow();
  return RateLimitVerdict.reject(oldest + windowMs - nowMs);
}

/// 「停」类命令判定（Q10 停类优先，纯函数）。
///
/// `script.stop` / `vibrate.stop` / `call.end` / `sound.stop` 是安全底线：
/// **永远**要在限流判定之前放行 —— 否则窗口被刷满时，连"叫停"都发不进来。
/// 真实排队只发生在指令组步骤之间（[RcScriptExecutor.run] 每步前检查终止
/// 令牌，既有机制，不再重造），MQTT 命令本身到达即处理，无需优先级队列。
///
/// R94 / REM-07 补入 `sound.stop`：远程发起的持续出声必须有对应的远程叫停，
/// 而"停"必须比"放"更容易到达 —— 它同样享受插队权。
bool isStopCommand(String type) =>
    type == RcCmd.scriptStop ||
    type == RcCmd.vibrateStop ||
    type == RcCmd.callEnd ||
    type == RcCmd.soundStop;

/// 取得（必要时生成并持久化）与 [deviceId] 关联的盐；未装配盐存储时返回 null。
///
/// ★ **复用优先**：该设备已有盐时必须**原样返回**，绝不重新生成 ——
/// 重复配对时重新生成会让控制端存下新盐、而本机（或对端）仍按旧盐派生，
/// 两端密钥不一致，表现为**静默失联**（配对成功，之后所有命令与回执都解不开）。
/// 这是本函数存在的唯一理由，也是 `test/salt_reuse_lock_test.dart` 锁住的东西。
///
/// ⚠️ **为什么是顶层函数**：`RcEndpointService` 是私有构造的单例
/// （`RcEndpointService._()`），宿主测试**无法实例化** ⇒ 逻辑内联在 `_ensureSalt`
/// 里就只能被**源码锁**覆盖，而源码锁锁不住语义（把"取已存盐"与"生成新盐"
/// 写反了照样能过）。抽到顶层后可传入真实/替身盐存储做**行为**断言。
///
/// 边界（刻意收窄）：存储未装配、或 [deviceId] 为空 ⇒ 返回 null。调用方**必须**
/// 据此回落到**无盐的 v1 派生路径**，绝不能传零盐/默认盐等替代品 ——
/// 那会让已配对设备在升级后**静默失联**。
Future<List<int>?> ensureSaltForDevice(
    KdfSaltStore? store, String deviceId) async {
  if (store == null || deviceId.isEmpty) return null;
  final salt = store.saltFor(deviceId) ?? KdfSaltStore.newSalt();
  await store.saveSalt(deviceId, salt);
  return salt;
}

// ══════════════════════════════════════════════════════════════════════
// P1-10 / P1-12：连接生命周期状态机 + 重连退避（判据与接线分离）
// ══════════════════════════════════════════════════════════════════════
//
// 与项目通则一致（见上「可测的纯裁决」）：把"连接处于什么阶段 / 下一次该等多久"
// 抽成**不依赖 MQTT 实例**的纯类型，于是宿主测试能穷举断言 + 变异证伪；
// 服务里只留"取状态 → 调判据 → 定时/重连 → 记账"。旧实现里这段是私有的、
// 依赖真连 broker 才能到达 ⇒ 只能靠真机取证（P1-12 的退避/预算尤其如此）。

/// 连接生命周期阶段（P1-10）。
///
/// UI 必须靠它区分「已启用」（服务在跑）与「在线」（真的连上了）——
/// 旧的 `isRunning` 把两者混为一谈，"开关是开的、实际已经断连"在界面上
/// 看起来完全正常，使用者无从判断。
enum RcConnPhase {
  /// 服务未启动。
  stopped,

  /// 正在建立连接（首连或重连中）。
  connecting,

  /// 已连接：可收发。
  online,

  /// 连接失败，退避等待中（下一次重试时刻见 [RcConnState.nextRetryAt]）。
  retrying,

  /// 已连接但部分能力不可用（预留：订阅/补发部分失败时的降级态）。
  degraded,

  /// 重试预算耗尽：停止空转，等待外部干预（改设置 / 重新开启）。
  failed,
}

/// 连接状态快照（不可变，供 UI 渲染）。
class RcConnState {
  const RcConnState(
    this.phase, {
    this.lastConnectedAt,
    this.nextRetryAt,
    this.lastError = '',
  });

  final RcConnPhase phase;

  /// 最近一次成功连接的时刻（毫秒；从未连上为 null）。
  final int? lastConnectedAt;

  /// [RcConnPhase.retrying] 时的下一次重试时刻（毫秒）。
  final int? nextRetryAt;

  /// 最近一次连接失败的原因（人读字符串；无失败为空串）。
  final String lastError;

  /// 是否在线（唯一可靠的"能收发"判据 —— 注意与 [phase] 等价，勿用
  /// `phase != stopped` 代替：那会把"重连中"误当成"可用"）。
  bool get online => phase == RcConnPhase.online;

  /// 是否"服务已启用但当前不在线"（UI 提示"正在重连…"的条件）。
  bool get enabledButOffline =>
      phase != RcConnPhase.stopped && phase != RcConnPhase.online;

  RcConnState copyWith({
    RcConnPhase? phase,
    int? lastConnectedAt,
    int? nextRetryAt,
    String? lastError,
    bool clearRetry = false,
  }) =>
      RcConnState(
        phase ?? this.phase,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
        nextRetryAt: clearRetry ? null : (nextRetryAt ?? this.nextRetryAt),
        lastError: lastError ?? this.lastError,
      );
}

/// 重连退避策略（P1-12）：**指数退避 + Full Jitter + 重试预算**。
///
/// ## 为什么是这三样
///
/// - **指数退避**：broker 长时间不可用时，固定间隔（旧的 10s）会持续产生
///   无效连接尝试；指数增长把压力降下来。
/// - **Full Jitter**（AWS 推荐形状）：延迟取 `random(min, capped)` 而不是
///   恒定值 —— 大量设备同时掉线时若都用同一条退避曲线，会在同一时刻
///   集体重连，把刚恢复的 broker **再次打垮**（惊群）。抖动把重连时刻打散。
/// - **重试预算**：连续失败 [maxAttempts] 次后返回 null（进入
///   [RcConnPhase.failed] 而非永久空转）。成功即 [reset]。
///
/// **可注入 [Random]**：单测用固定种子 ⇒ 抖动区间可被断言，而不是"随机"。
/// ⚠️ `minDelay` 是**下限**而非 0：纯 full jitter 的 `random(0, cap)`
/// 可能抽到 0ms ⇒ 立刻重连（退避形同虚设）。下限保证每次重试至少等一会儿。
class RcReconnectPolicy {
  RcReconnectPolicy({
    this.baseDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(minutes: 2),
    this.minDelay = const Duration(milliseconds: 500),
    this.maxAttempts = 8,
    Random? random,
  }) : _random = random ?? Random();

  /// 退避基数（第 0 次延迟的**上界**基数：`base * 2^attempt`）。
  final Duration baseDelay;

  /// 单次延迟上界（指数增长到此为止）。
  final Duration maxDelay;

  /// 单次延迟下界（防止 jitter 抽到 0 ⇒ 退避失效）。
  final Duration minDelay;

  /// 连续失败预算：超过后 [nextDelay] 返回 null（进入 failed）。
  final int maxAttempts;

  final Random _random;

  int _attempt = 0;

  /// 当前累计的连续失败次数（成功连接后由调用方 [reset]）。
  int get attempt => _attempt;

  /// 连接成功：清零预算，让下一次断线重新从最小退避开始。
  void reset() => _attempt = 0;

  /// 计算下一次重连延迟；预算耗尽返回 null。
  ///
  /// 第 `n` 次调用（`n` 从 0 起）的上界为 `min(baseDelay * 2^n, maxDelay)`，
  /// 实际返回 `random(minDelay, 上界)`（上界 ≤ minDelay 时直接返回上界）。
  Duration? nextDelay() {
    if (_attempt >= maxAttempts) return null;
    final expMs = baseDelay.inMilliseconds * (1 << _attempt);
    final capped =
        expMs > maxDelay.inMilliseconds ? maxDelay.inMilliseconds : expMs;
    _attempt++;
    final lo = minDelay.inMilliseconds;
    if (capped <= lo) return Duration(milliseconds: capped);
    return Duration(milliseconds: lo + _random.nextInt(capped - lo + 1));
  }
}

// ══════════════════════════════════════════════════════════════════════
// P1-15 / P2-21：出站暂存（outbox）的新鲜度与补发裁决（判据与接线分离）
// ══════════════════════════════════════════════════════════════════════
//
// outbox 承诺的是"端点上线后自动执行"，但**不是所有命令都该被补发**：
// 一条几小时前的 `script.stop` / `call.end` 补发出去，不是"可靠"，而是
// 对着早已结束的会话乱喊 —— 陈旧动作甚至有害。`prepareOutboxReplay` 把旧
// 命令重新签成"刚发出"解决的是**密码包过窗**，不等于**业务授权仍有效**
// （这正是 P1-15 指出的两个问题被混为一谈）。
//
// 与项目通则一致：把"该不该补发 / 补发窗口多长"抽成不依赖 MQTT 实例的
// **纯函数**，宿主测试可穷举断言 + 变异证伪；服务里只留
// "取类型 → 调判据 → 执行 / 丢弃并记账"。

/// 出站暂存条目的**新鲜度类别**（P1-15）。
enum RcOutboxFreshness {
  /// 实时信令：会话时效极短（PTT / 通话 / ICE / stop）。
  /// 端点上线时该会话早已结束 ⇒ **禁止补发**。
  live,

  /// 瞬时动作：只有短窗口内补发才有意义（声音提示 / 找回告警 / 音量）。
  transient,

  /// 状态收敛类：较长时间内补发仍正确（配置、查询、任务 CRUD）。
  durable,
}

/// 实时信令集合：过期即无意义、补发有害（P1-15 / P2-21）。
const Set<String> rcLiveOutboxTypes = {
  RcCmd.pttVoice,
  RcCmd.callInvite,
  RcCmd.callAnswer,
  RcCmd.callCandidate,
  RcCmd.callEnd,
  RcCmd.scriptStop,
  RcCmd.vibrateStop,
  RcCmd.pairRequest,
};

/// 瞬时动作集合：短 TTL 内补发仍有意义。
const Set<String> rcTransientOutboxTypes = {
  RcCmd.soundPlay,
  RcCmd.deviceAlert,
  RcCmd.volumeSet,
  RcCmd.vibrateStart,
};

/// 瞬时动作的补发窗口（10 分钟）。
const int rcTransientOutboxTtlMs = 10 * 60 * 1000;

/// 状态收敛类的补发窗口（24 小时）。
const int rcDurableOutboxTtlMs = 24 * 60 * 60 * 1000;

/// 判定某命令类型的补发新鲜度。
///
/// 未登记的类型一律按 [RcOutboxFreshness.durable] 处理：新协议命令在明确
/// 归类前**宁可多补发一次**也不静默丢弃 —— 丢命令比补一条陈旧的状态查询更糟。
RcOutboxFreshness rcOutboxFreshness(String type) {
  if (rcLiveOutboxTypes.contains(type)) return RcOutboxFreshness.live;
  if (rcTransientOutboxTypes.contains(type)) return RcOutboxFreshness.transient;
  return RcOutboxFreshness.durable;
}

/// 入队时该写入的 TTL（毫秒）。实时类返回 0（无窗口 ⇒ 不入队/不补发）。
int rcOutboxTtlMs(String type) {
  switch (rcOutboxFreshness(type)) {
    case RcOutboxFreshness.live:
      return 0;
    case RcOutboxFreshness.transient:
      return rcTransientOutboxTtlMs;
    case RcOutboxFreshness.durable:
      return rcDurableOutboxTtlMs;
  }
}

/// 补发前对一条暂存命令的**裁决**（P1-15 / P2-21）。
enum RcOutboxReplay {
  /// 可以补发（重盖时间戳与 ID 后投出）。
  replay,

  /// 密文解不开（密钥已变更 / 损坏）⇒ 丢弃。
  undecodable,

  /// 实时信令 ⇒ 禁止补发，丢弃。
  liveOnly,

  /// 已过新鲜度窗口 ⇒ 丢弃。
  expired,
}

/// 决定一条暂存命令**该不该补发**。
///
/// [type] 为 null 视为不可解密（调用方 peek 失败）；[expiresAt] 为 null 表示
/// 无 TTL（老数据兼容 ⇒ 恒可补发，不能因升级把历史命令一次性判死）。
RcOutboxReplay decideOutboxReplay({
  String? type,
  int? expiresAt,
  required int nowMs,
}) {
  if (type == null) return RcOutboxReplay.undecodable;
  if (rcOutboxFreshness(type) == RcOutboxFreshness.live) {
    return RcOutboxReplay.liveOnly;
  }
  if (expiresAt != null && nowMs > expiresAt) return RcOutboxReplay.expired;
  return RcOutboxReplay.replay;
}

/// 丢弃暂存命令时的**用户可见原因**（写进审计，绝不静默）。
String rcOutboxDropReason(RcOutboxReplay verdict) {
  switch (verdict) {
    case RcOutboxReplay.undecodable:
      return '暂存命令无法解密（密钥已变更？）';
    case RcOutboxReplay.liveOnly:
      return '实时命令禁止补发（会话时效已过）';
    case RcOutboxReplay.expired:
      return '暂存命令已过期（超过补发窗口）';
    case RcOutboxReplay.replay:
      return '';
  }
}

/// 解密一条暂存密文、只取回其命令类型（忽略时间窗）。
///
/// 与 [prepareOutboxReplay] 的区别：这里**只读类型**用于裁决，不做重编码。
/// 时间窗放到极大：要的是"这条当年是什么命令"，不是"它还新不新"。
Future<String?> peekOutboxType(
  String wire,
  List<int> key,
  String topic, {
  List<int>? peerKey,
  String peerContext = '',
}) async {
  final msg = await RcCodec.decode(wire, key, topic,
      maxSkewMs: const Duration(days: 3650).inMilliseconds,
      candidateKeys: peerKey == null ? const <List<int>>[] : <List<int>>[peerKey],
      peerContext: peerContext);
  return msg?.type;
}

/// 流式对讲会话（v2）：一个 `voiceId` 对应一个播放会话 + 一批分片文件。
///
/// 会话状态由 [RcEndpointService._onPttVoiceStream] 读写，
/// [RcEndpointService._closePttStream] 负责释放播放会话并按需删除分片文件。
class _PttStreamSession {
  _PttStreamSession({required this.sink, required this.from, required this.dir});

  /// 播放会话（`PlaybackService` 侧实现；未注入开缝时不会构造到此处）。
  final PttStreamSink sink;

  /// 发起方 deviceId（回执定向用）。
  final String from;

  /// 分片落盘目录（`getApplicationDocumentsDirectory`）。
  final Directory dir;

  /// 已落盘的分片文件名（清理时逐个删除）。
  final List<String> files = <String>[];

  /// 期望的下一个分片序号（诊断用；MQTT 同主题保序，正常无需重排）。
  int nextSeq = 0;

  /// 空闲超时计时器（每片顺延；静默超时即回收，防悬挂会话）。
  Timer? idle;
}
