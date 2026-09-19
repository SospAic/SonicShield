import 'dart:async';
import 'dart:math';

import 'assist.dart';
import 'protocol.dart';
import 'rc_script.dart';

/// 协助会话的传输抽象。
///
/// 会话托管只关心「订阅会合主题 / 发布密文 / 退订」，不关心底层是 MQTT 还是
/// 其它通道。把传输做成接口有两个好处：
/// 1. **可单测**：握手、失败锁定、TTL 到期、权限门控都能用假传输完整覆盖，
///    不需要真实 broker；
/// 2. **职责清晰**：`RcEndpointService` 只负责连接与收发字节，
///    密钥与会话状态由本模块独占，避免"密钥散落在网络层"。
abstract interface class AssistTransport {
  Future<void> subscribe(String topic);
  Future<void> unsubscribe(String topic);

  /// 发布**已加密**的线格式字符串（由会话托管用会话密钥加密后交出）。
  Future<void> publishWire(String topic, String wire);
}

/// Zone 键：标记「当前异步调用链的出站回执应走协助会话会合主题」。
///
/// 端点服务的 `_send()` 读取该键决定回执通道：协助会话期间对端**不是已配对
/// 设备**，收不到 `sonicshield/v1/{deviceId}/evt`，回执必须原路返回会合主题。
///
/// 为什么用 Zone 而不是实例上的布尔标志位：协助命令与配对命令可能**并发在途**
/// （每个 `await` 都是交错点），标志位会被另一条链覆盖导致串台；Zone 随异步链
/// 自动传播，天然按调用链隔离，且不需要给 `_dispatch` 的每个调用点加参数。
final Object assistReplyZone = Object();

/// 一次协助会话的方向密钥对。
///
/// - [ctlKey]：控制端 → 端点（端点用它解密收到的指令）
/// - [epKey]：端点 → 控制端（端点用它加密回执）
class AssistKeySet {
  const AssistKeySet({
    required this.sessionId,
    required this.ctlKey,
    required this.epKey,
  });

  final String sessionId;
  final List<int> ctlKey;
  final List<int> epKey;
}

/// 端点侧协助会话托管（docs/18 §4.4 / §7）。
///
/// ## 职责
/// - 生成一次性凭据（临时码 + 访问密码），订阅**密码认证会合主题**；
/// - 处理 `assist.hello` 握手 → 校验 TTL / 失败计数 → 回 `assist.accept`；
/// - 持有会话方向密钥（密钥环），供端点服务解密/加密 assist 通道消息；
/// - 权限位逐项放行（默认全拒）、TTL 到期自动终止、任一方可终止；
/// - 全程审计。
///
/// ## 合规硬边界（docs/08 红线，不可协商）
/// - **会话只能由端点侧发起**（C1）：本类不提供任何"接受外部唤醒建会话"的入口，
///   `start()` 只能被端点 UI 调用；
/// - 会话**一次性**且 TTL 有限（C4），凭据只存内存、不落盘；
/// - 权限**默认全 false**（C5），必须端点使用者逐项开启；
/// - 端点横幅常驻可见（C2），不存在隐蔽模式。
///
/// ## 实例化
/// 生产环境用 [instance] 单例（端点服务在启动时 `bind()` 一次）；
/// 构造函数公开是为了让单测能拿到**互不干扰**的实例 —— 会话状态是纯内存的，
/// 测试间共享单例会让 TTL / 失败计数互相污染。
class RcAssistHost {
  RcAssistHost();

  static final RcAssistHost instance = RcAssistHost();

  AssistTransport? _transport;
  AssistSession? _session;
  AssistKeySet? _keys;
  Timer? _ticker;

  /// 已处理消息 ID（沿用 ±90s 时间窗 + 去重，防重放）。
  final _seen = <String, int>{};

  /// 已处理**密文原文**（FIFO，上限 [maxSeenWires]）。
  ///
  /// 与 [_seen] 的分工：[_seen] 按消息 ID 去重（需解密后才能读到 ID），
  /// 本集合按密文原文去重（解密前即可判定），专门用来把"重放"挡在
  /// **握手失败计数**之外 —— 见 [onWire] 注释。
  final _seenWires = <String>{};

  /// 密文去重窗口上限；超出后按插入序淘汰最旧的一条。
  static const maxSeenWires = 512;

  /// 审计钩子（由端点服务注入，写入 exec_logs，source=assist）。
  Future<void> Function(String action, String status, String? message)? audit;

  /// 业务命令处理钩子：**已解密且已过权限门控**的业务命令交给端点服务执行。
  ///
  /// 由 `RcEndpointService` 注入（指向其 `_dispatch`）。钩子内部发回执时，
  /// `_send()` 会依据 [assistReplyZone] 自动改走会合主题。
  Future<void> Function(RcMessage msg)? onCommand;

  /// 端点显示名（由端点服务注入，用于控制端 UI 展示）。
  String endpointName = '声盾端点';

  final _changes = StreamController<AssistSession?>.broadcast();

  /// 会话状态变更广播（UI 订阅以刷新倒计时/权限/横幅）。
  Stream<AssistSession?> get changes => _changes.stream;

  AssistSession? get session => _session;

  /// 当前会话密钥；无活动会话时为 null。
  AssistKeySet? get keys => _keys;

  /// 会话是否已建立（可接受业务命令）。
  bool get active => _session?.phase == AssistPhase.active;

  void bind(AssistTransport transport) => _transport = transport;

  void _emit() {
    if (!_changes.isClosed) _changes.add(_session);
  }

  // ---------------- 生命周期 ----------------

  /// 端点使用者主动发起：生成凭据并进入等待接入状态（C1：唯一入口）。
  Future<AssistSession> start({Duration ttl = RcAssist.defaultTtl}) async {
    await close(reason: 'superseded', silent: true);

    final code = RcAssist.generateCode();
    final password = RcAssist.generatePassword();
    final topic = await RcAssist.topicFor(code, password);
    final session = AssistSession(
      code: code,
      password: password,
      topic: topic,
      expiresAt: DateTime.now().add(ttl),
    );
    _session = session;
    _seen.clear();
    _seenWires.clear();

    await _transport?.subscribe(topic);
    await audit?.call(
        'assist.start', 'success', '等待接入（TTL ${ttl.inMinutes} 分钟）');

    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    _emit();
    return session;
  }

  /// 周期心跳：刷新倒计时并处理 TTL 到期自动终止（C4）。
  void tick() {
    final s = _session;
    if (s == null) return;
    if (s.phase == AssistPhase.closed) {
      _ticker?.cancel();
      return;
    }
    if (s.expired) {
      unawaited(close(reason: 'ttl'));
      return;
    }
    _emit(); // 驱动 UI 倒计时
  }

  /// 终止会话（端点主动 / 控制端请求 / TTL 到期 / 失败超限）。
  Future<void> close({String reason = 'local', bool silent = false}) async {
    final s = _session;
    if (s == null) return;
    _ticker?.cancel();
    _ticker = null;

    if (s.phase != AssistPhase.closed) {
      // 通知对端（控制端可能已断开，失败不影响本地终止）。
      if (!silent && _transport != null && _keys != null) {
        try {
          await _publish(
              _keys!.epKey,
              RcMessage.now(RcAssistCmd.close, {
                'sessionId': s.sessionId,
                'reason': reason,
              }));
        } on Object {
          // 对端不可达：终止仍须在本地生效
        }
      }
      s.phase = AssistPhase.closed;
    }

    await _transport?.unsubscribe(s.topic);
    _keys = null;
    await audit?.call('assist.end', 'success', '原因：${_reasonLabel(reason)}');
    _emit();
    _session = null;
    _emit();
  }

  static String _reasonLabel(String reason) => switch (reason) {
        'ttl' => 'TTL 到期',
        'local' => '端点主动终止',
        'remote' => '控制端终止',
        'locked' => '握手失败次数超限',
        'superseded' => '被新会话替换',
        _ => reason,
      };

  // ---------------- 权限 ----------------

  /// 逐项放行/收回权限，并即时通知控制端（C5：默认全拒）。
  Future<bool> grant(AssistPerms perms) async {
    final s = _session;
    final k = _keys;
    if (s == null || k == null || s.phase != AssistPhase.active) return false;
    s.perms = perms;
    await _publish(
        k.epKey,
        RcMessage.now(RcAssistCmd.perm, {
          'sessionId': s.sessionId,
          'perms': perms.toJson(),
        }));
    await audit?.call('assist.perm', 'success', _permSummary(perms));
    _emit();
    return true;
  }

  static String _permSummary(AssistPerms p) {
    final on = <String>[];
    final j = p.toJson();
    for (final e in j.entries) {
      if (e.value == true) on.add(AssistPerms.labels[e.key] ?? e.key);
    }
    return on.isEmpty ? '全部拒绝' : '放行：${on.join('、')}';
  }

  /// 命令 → 所需权限位（转发到协议层 [RcPermGate]）。
  ///
  /// 门控表由**两端共用**：控制端用它灰化未授权按钮，端点侧用它拒绝越权命令。
  /// 本类只做转发，不再自持一份 —— 两份映射必然漂移（详见 [RcPermGate] 注释）。
  static String? requiredPerm(String cmd) => RcPermGate.requiredPerm(cmd);

  /// 该权限位是否已放行。
  static bool hasPerm(AssistPerms p, String perm) =>
      RcPermGate.hasPerm(p, perm);

  /// 该命令在当前权限下是否可执行。
  static bool allows(AssistPerms p, String cmd) => RcPermGate.allows(p, cmd);

  /// 指令组步骤 → 所需权限位。
  static String? requiredStepPerm(RcStepKind kind) =>
      RcPermGate.requiredStepPerm(kind);

  // ---------------- 入站处理 ----------------

  /// 端点服务把**会合主题上的原始密文**交给本方法（密钥不出本模块）。
  Future<void> onWire(String wire) async {
    final s = _session;
    if (s == null) return;

    // 同一密文的重复投递（MQTT QoS1 重传 / 恶意重放）直接忽略。
    //
    // 必须在这里拦，不能只靠 `_seen`（消息 ID 去重）：ID 要解密后才能看到，
    // 而**解密失败的报文恰恰是计失败数的那些** —— 若把重放也算作"猜密码失败"，
    // 攻击者只要重放一次抓到的密文 5 遍就能把会话锁死。
    if (_seenWires.contains(wire)) return;
    _rememberWire(wire);

    // 等待期只有 ctlKey 可用（hello 由控制端用 ctlKey 加密）。
    final k = _keys;
    final key = k?.ctlKey ?? await RcAssist.ctlKey(s.code, s.password);
    final msg = await RcCodec.decode(wire, key, s.topic, seenIds: _seen);
    if (msg == null) {
      // 会话已认证后，解密失败只可能是噪声或 broker 侧观察者灌的垃圾报文。
      // 此时**不计失败**：否则知道会合主题（= 知道密码，或从端点自己发布的
      // accept 报文中观察得到）的一方可以 spam 5 条垃圾把会话"锁死" ——
      // 虽然锁死是失败关闭（只减权限不增权限），但白送一个拒绝服务面没有意义。
      if (s.phase == AssistPhase.active) return;
      // 等待期解密失败 = 对方不知道密码（或密文被篡改）→ 计入失败，防在线猜测。
      await _onHandshakeFailure(s, '密文校验失败');
      return;
    }
    _rememberSeen(msg.id);

    if (msg.type == RcAssistCmd.hello) {
      await _onHello(s, msg);
    } else if (msg.type == RcAssistCmd.close) {
      await close(reason: 'remote');
    } else if (RcAssistCmd.isControl(msg.type)) {
      // 未知的 assist.* 控制消息：静默忽略（向后兼容，新控制消息不打断旧端点）。
    } else {
      await _onBusiness(s, msg);
    }
  }

  /// 业务命令：会话必须已激活，且逐条过权限门控（C5 默认拒绝）。
  ///
  /// 通过门控后交由端点服务的 [onCommand] 执行；执行期间的出站回执由
  /// [assistReplyZone] 自动改走会合主题。
  Future<void> _onBusiness(AssistSession s, RcMessage msg) async {
    final k = _keys;
    if (s.phase != AssistPhase.active || k == null) {
      // 未完成握手的会话不得执行业务命令 —— 包括只读命令。
      await audit?.call('assist.deny', 'skipped', '${msg.type} · 会话未激活');
      return;
    }

    final need = requiredPerm(msg.type);
    if (!allows(s.perms, msg.type)) {
      await audit?.call(
          'assist.deny', 'skipped', '${msg.type} · 权限「${need ?? '未登记'}」未放行');
      // 必须显式回执拒绝：否则控制端只会看到"点了没反应"，无限重试。
      await _publish(
          k.epKey,
          RcMessage.now(RcEvt.ack, {
            'ok': false,
            'for': msg.id,
            'forType': msg.type,
            'data': need == null
                ? '已拒绝'
                : '权限未放行：${AssistPerms.labels[need] ?? need}',
          }));
      return;
    }

    final handler = onCommand;
    if (handler == null) return; // 端点未接入执行层（不应发生）
    await runZoned(() => handler(msg), zoneValues: {assistReplyZone: true});
  }

  /// 业务回执：走会合主题、epKey 加密（由端点服务的 `_send` 在
  /// [assistReplyZone] 内调用）。
  Future<void> sendReply(RcMessage msg) async {
    final k = _keys;
    if (k == null || _session == null) return;
    await _publish(k.epKey, msg);
  }

  Future<void> _onHello(AssistSession s, RcMessage msg) async {
    if (s.phase == AssistPhase.active) {
      // 已建立会话时重复 hello：视为对方重试，重发 accept（幂等）。
      await _sendAccept(s, msg);
      return;
    }
    if (!s.usable) {
      await _reject(s, s.expired ? 'ttl_expired' : 'session_closed');
      return;
    }

    s.phase = AssistPhase.opening;
    s.ctrlName = (msg.payload['ctrlName'] as String?)?.trim() ?? '';
    if (s.ctrlName.isEmpty) s.ctrlName = '未命名控制端';
    if (s.ctrlName.length > 60) s.ctrlName = s.ctrlName.substring(0, 60);

    // 会话密钥就绪（此后本模块独占密钥，不外传）。
    final ctl = await RcAssist.ctlKey(s.code, s.password);
    final ep = await RcAssist.epKey(s.code, s.password);
    s.sessionId = _newSessionId();
    _keys = AssistKeySet(sessionId: s.sessionId, ctlKey: ctl, epKey: ep);
    s.phase = AssistPhase.active;

    await audit?.call(
        'assist.accept', 'success', '控制端「${s.ctrlName}」已接入（权限默认全拒）');
    await _sendAccept(s, msg);
    _emit();
  }

  Future<void> _sendAccept(AssistSession s, RcMessage forMsg) async {
    final k = _keys;
    if (k == null) return;
    await _publish(
        k.epKey,
        RcMessage.now(RcAssistCmd.accept, {
          'for': forMsg.id,
          'sessionId': s.sessionId,
          'expiresAt': s.expiresAt.millisecondsSinceEpoch,
          'epName': endpointName,
          'perms': s.perms.toJson(),
        }));
  }

  Future<void> _reject(AssistSession s, String reason) async {
    final key = await RcAssist.epKey(s.code, s.password);
    await _publish(key, RcMessage.now(RcAssistCmd.reject, {'reason': reason}));
  }

  /// 握手失败计数；达到上限立即作废整场会话（防在线暴力猜测）。
  Future<void> _onHandshakeFailure(AssistSession s, String why) async {
    final locked = s.registerFailure();
    await audit?.call('assist.handshake', locked ? 'failed' : 'skipped',
        '$why（第 ${s.failures} 次）');
    if (locked) {
      await close(reason: 'locked');
    } else {
      _emit();
    }
  }

  Future<void> _publish(List<int> key, RcMessage msg) async {
    final t = _transport;
    final s = _session;
    if (t == null || s == null) return;
    final wire = await RcCodec.encode(msg, key, s.topic);
    await t.publishWire(s.topic, wire);
  }

  void _rememberSeen(String id) {
    if (id.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _seen[id] = now;
    _seen.removeWhere((_, t) => now - t > 10 * 60 * 1000);
  }

  /// 记录密文并淘汰超限的最旧条目（[Set] 保持插入序）。
  void _rememberWire(String wire) {
    _seenWires.add(wire);
    while (_seenWires.length > maxSeenWires) {
      _seenWires.remove(_seenWires.first);
    }
  }

  static String _newSessionId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(16, (_) => chars[r.nextInt(chars.length)]).join();
  }
}
