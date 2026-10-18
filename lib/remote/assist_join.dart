import 'dart:async';

import '../core/constants.dart';
import 'assist.dart';
import 'assist_host.dart' show AssistTransport;
import 'protocol.dart';

/// 控制端侧的一条会话审计记录（内存态，随会话结束清空）。
///
/// 端点侧审计落库（`exec_logs`，`source=assist`）；控制端侧只保留**本会话**的
/// 收发轨迹，用于回答使用者最关心的两个问题：
/// 「我发的命令端点到底收到了吗」「端点为什么拒绝我」。
/// 未授权命令会被端点回 `rc.ack{ok:false, data:原因}` —— 不展示出来，
/// 使用者只会以为"点了没反应"（这正是 BUG-029 暴露过的一类问题）。
class AssistAuditEntry {
  const AssistAuditEntry({
    required this.at,
    required this.type,
    required this.outbound,
    required this.ok,
    this.detail = '',
  });

  final DateTime at;

  /// 命令/事件类型（如 `sound.play`、`rc.ack`）。
  final String type;

  /// true = 本端发出；false = 端点返回。
  final bool outbound;

  /// 结果：发出/成功为 true；被拒绝或失败为 false。
  final bool ok;

  /// 补充说明（端点拒绝原因等）。
  final String detail;
}

/// 控制端接入协助会话的状态快照（不可变，供 UI 渲染）。
class AssistJoinInfo {
  const AssistJoinInfo({
    required this.phase,
    this.sessionId = '',
    this.epName = '',
    this.perms = AssistPerms.none,
    this.expiresAt,
    this.error,
  });

  final AssistPhase phase;

  /// 端点分配的会话 ID（握手成功后才有）。
  final String sessionId;

  /// 端点显示名（端点页的「声盾端点」/设备名）。
  final String epName;

  /// 端点当前放行的权限位（**默认全拒**，端点使用者逐项开启后才变化）。
  final AssistPerms perms;

  final DateTime? expiresAt;

  /// 失败原因（人话）；无错误时为 null。
  final String? error;

  bool get active => phase == AssistPhase.active;
  bool get busy => phase == AssistPhase.opening;

  Duration get remaining {
    final e = expiresAt;
    if (e == null) return Duration.zero;
    final d = e.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }
}

/// 控制端侧的协助会话客户端（docs/18 S3）。
///
/// 与 [RcAssistHost] 的关系：两者是同一协议的两端，共用 [RcAssist] 的
/// 凭据/主题/密钥派生与 [RcPermGate] 的门控表，但**职责相反**：
///
/// | | 端点侧 `RcAssistHost` | 控制端侧 `AssistJoinClient` |
/// |---|---|---|
/// | 凭据 | **生成**临时码+密码 | **输入**临时码+密码 |
/// | 会合主题 | 生成后订阅 | 由码+密码**派生**后订阅 |
/// | 方向密钥 | ctlKey 解密 / epKey 加密 | ctlKey 加密 / epKey 解密 |
/// | 权限 | 逐项放行（唯一决策方） | 只读跟随，用于灰化按钮 |
/// | 失败计数 | 计入并锁定（防在线猜测） | 不计（没有"被猜"的语义） |
///
/// ## 安全边界
/// 控制端**无法**自行开启权限、延长 TTL 或规避门控 —— 这些全部由端点侧
/// 决定。本类只做"派生密钥 → 发 hello → 等 accept → 收发业务命令"，
/// 任何越权尝试都会被端点侧拒绝并记入其审计。
class AssistJoinClient {
  AssistJoinClient();

  static final AssistJoinClient instance = AssistJoinClient();

  AssistTransport? _transport;

  String _topic = '';
  List<int>? _ctlKey;
  List<int>? _epKey;

  AssistPhase _phase = AssistPhase.closed;
  String _sessionId = '';
  String _epName = '';
  AssistPerms _perms = AssistPerms.none;
  DateTime? _expiresAt;
  String? _error;

  Timer? _ticker;

  /// 控制端显示名（端点横幅会展示「正在被 X 协助」——C2 可见性）。
  String ctrlName = '声盾控制端';

  /// `assist.hello` 的重发间隔。
  ///
  /// 生产用 1.5 s：太密会在弱网下把 broker 打满，太疏则接入感知很慢。
  /// 做成字段是为了让单测能压到毫秒级 —— 否则每个握手用例都要真等 1.5 s，
  /// 整个套件会被这一处拖慢十几秒（且负载下更糟）。
  Duration helloRetryInterval = const Duration(milliseconds: 1500);

  /// 已处理消息 ID / 密文原文（防重放，语义同端点侧）。
  final _seen = <String, int>{};
  final _seenWires = <String>{};
  static const _maxSeenWires = 512;

  /// 本轮 `join()` 已发出的 `assist.hello` 消息 ID 集合（P2-30）。
  ///
  /// 端点回执把 hello 的 ID 写在 `payload.for`（见 `assist_host._sendAccept`）。
  /// 控制端**必须**核对 accept 的 `for` 属于本轮发出的 hello —— 否则一次
  /// 较早接入尝试的迟到 accept（QoS1 重投 / 上一轮 join 的存量回执）会被
  /// 当成**本次**接入成功，控制端就此进入 `active`，而其 `sessionId`/权限/TTL
  /// 全部来自**上一次**尝试，与界面当前显示的接入不一致（"看着连上了，其实
  /// 是旧会话的残留状态"）。
  final _pendingHellos = <String>{};
  static const _maxPendingHellos = 32;

  /// 本会话审计轨迹（FIFO 环形，上限 [_maxAudit]）。
  final _audit = <AssistAuditEntry>[];
  static const _maxAudit = 200;

  /// 会话审计轨迹（最新在末尾）；供控制端"审计"面板展示。
  List<AssistAuditEntry> get auditLog => List.unmodifiable(_audit);

  final _auditChanges = StreamController<void>.broadcast();

  /// 审计轨迹变更广播（UI 据此刷新面板）。
  Stream<void> get auditChanges => _auditChanges.stream;

  /// 业务回执广播：格式与 [RcEndpointService.events] 一致，
  /// 使控制台无需区分"配对通道"还是"协助通道"。
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  final _changes = StreamController<AssistJoinInfo>.broadcast();
  Stream<AssistJoinInfo> get changes => _changes.stream;

  /// 当前会合主题；未接入时为空串（端点服务据此路由入站报文）。
  String get topic => _topic;

  AssistPhase get phase => _phase;
  AssistPerms get perms => _perms;
  String get epName => _epName;

  /// 端点分配的会话 ID；未接入时为空串。
  String get sessionId => _sessionId;

  bool get active => _phase == AssistPhase.active;

  AssistJoinInfo get info => AssistJoinInfo(
        phase: _phase,
        sessionId: _sessionId,
        epName: _epName,
        perms: _perms,
        expiresAt: _expiresAt,
        error: _error,
      );

  void bind(AssistTransport transport) => _transport = transport;

  void _emit() {
    if (!_changes.isClosed) _changes.add(info);
  }

  // ---------------- 接入 ----------------

  /// 用「临时码 + 访问密码」接入端点会话。
  ///
  /// 返回是否成功建立会话；失败原因见 [info].error。
  ///
  /// **hello 需要重试**：MQTT 的 SUBSCRIBE 生效有往返延迟，且端点可能刚
  /// 生成凭据（订阅尚未建立）。单发一次 hello 在真实网络上经常石沉大海，
  /// 表现为"码是对的但一直连不上"。端点侧对重复 hello 幂等（重发 accept），
  /// 因此重试是安全的。
  Future<bool> join(
    String code,
    String password, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await leave(silent: true);

    final c = RcAssist.normalizeCode(code);
    final p = RcAssist.normalizePassword(password);
    if (!RcAssist.isValidCode(c)) {
      return _fail('临时码应为 9 位数字');
    }
    if (!RcAssist.isValidPassword(p)) {
      return _fail('访问密码应为 8 位（字母表内字符，不含 I/L/O/U/0/1）');
    }

    final transport = _transport;
    if (transport == null) return _fail('远程模块未开启，无法接入');

    _topic = await RcAssist.topicFor(c, p);
    _ctlKey = await RcAssist.ctlKey(c, p);
    _epKey = await RcAssist.epKey(c, p);
    _phase = AssistPhase.opening;
    _error = null;
    _seen.clear();
    _seenWires.clear();
    _pendingHellos.clear();
    _audit.clear(); // 新会话：审计轨迹只反映当前会话，不带上一轮的记录
    _emit();

    await transport.subscribe(_topic);

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_phase == AssistPhase.active) break;
      if (_phase == AssistPhase.closed) break; // 已被 reject / 终止
      final hello = RcMessage.now(RcAssistCmd.hello, {
        'ctrlName': ctrlName,
        'ver': AppMeta.version,
      });
      // 先登记 ID 再发送：端点回得比本地登记快时会变成"自己的 hello 认不出"。
      _pendingHellos.add(hello.id);
      while (_pendingHellos.length > _maxPendingHellos) {
        _pendingHellos.remove(_pendingHellos.first);
      }
      await send(hello);
      await Future<void>.delayed(helloRetryInterval);
    }

    if (_phase == AssistPhase.active) {
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
      _emit();
      return true;
    }
    if (_phase != AssistPhase.closed) {
      await leave(silent: true);
      return _fail('接入超时：请确认临时码与访问密码正确，且端点仍显示"等待接入"');
    }
    return false; // 已被端点 reject（错误原因已由 onWire 写入）
  }

  /// 结束本地会话（不通知端点时为 [silent]；主动挂断应传 false）。
  Future<void> leave({bool silent = false}) async {
    _ticker?.cancel();
    _ticker = null;

    final transport = _transport;
    final topic = _topic;
    if (!silent && transport != null && _ctlKey != null && topic.isNotEmpty) {
      try {
        await _publish(RcMessage.now(RcAssistCmd.close, {
          'sessionId': _sessionId,
          'reason': 'remote',
        }));
        _record(RcAssistCmd.close, outbound: true, ok: true, detail: '本端主动挂断');
      } on Object {
        // 对端不可达不影响本地挂断
      }
    }
    if (transport != null && topic.isNotEmpty) {
      await transport.unsubscribe(topic);
    }

    _topic = '';
    _ctlKey = null;
    _epKey = null;
    _sessionId = '';
    _epName = '';
    _perms = AssistPerms.none;
    _expiresAt = null;
    _phase = AssistPhase.closed;
    _emit();
  }

  /// TTL 心跳：端点过期后本端也应停止发送（端点会拒收并回 reject）。
  void tick() {
    if (_phase != AssistPhase.active) {
      _ticker?.cancel();
      return;
    }
    final e = _expiresAt;
    if (e != null && DateTime.now().isAfter(e)) {
      unawaited(_expire());
      return;
    }
    _emit(); // 驱动倒计时
  }

  Future<void> _expire() async {
    await leave(silent: true);
    _fail('会话已到期（端点侧 TTL 结束），请让端点重新生成临时码');
  }

  // ---------------- 收发 ----------------

  /// 发送业务命令（ctlKey 加密 → 会合主题）。
  ///
  /// 返回是否已发出。**注意**：发出 ≠ 被允许 —— 端点侧会逐条过权限门控，
  /// 未授权命令会回 `rc.ack{ok:false}`（见 [RcPermGate]）。
  Future<bool> send(RcMessage msg) async {
    if (_phase == AssistPhase.closed || _topic.isEmpty) return false;
    // 先记"发出"再发布。
    //
    // 若改为发布完成后再记，在**快通道**上（测试环回、局域网、broker 与
    // 端点同机）端点的回执会先于本端记录落账，审计顺序颠倒 ——
    // 表现为"先看到收到、后看到发出"，排障时会把人带偏。
    // 审计顺序不应依赖传输延迟。
    _record(msg.type, outbound: true, ok: true);
    final ok = await _publish(msg);
    if (!ok) {
      _record(msg.type, outbound: true, ok: false, detail: '发送失败：通道未就绪');
    }
    return ok;
  }

  void _record(
    String type, {
    required bool outbound,
    required bool ok,
    String detail = '',
  }) {
    _audit.add(AssistAuditEntry(
      at: DateTime.now(),
      type: type,
      outbound: outbound,
      ok: ok,
      detail: detail,
    ));
    while (_audit.length > _maxAudit) {
      _audit.removeAt(0);
    }
    if (!_auditChanges.isClosed) _auditChanges.add(null);
  }

  Future<bool> _publish(RcMessage msg) async {
    final transport = _transport;
    final key = _ctlKey;
    if (transport == null || key == null || _topic.isEmpty) return false;
    final wire = await RcCodec.encode(msg, key, _topic);
    await transport.publishWire(_topic, wire);
    return true;
  }

  /// 端点服务把会合主题上的密文交给本方法（epKey 解密）。
  Future<void> onWire(String wire) async {
    final key = _epKey;
    if (key == null || _topic.isEmpty) return;

    if (_seenWires.contains(wire)) return;
    _rememberWire(wire);

    final msg = await RcCodec.decode(wire, key, _topic, seenIds: _seen);
    // 控制端**不计**解密失败：本端没有"被暴力猜测"的语义，
    // 且端点在未接入前根本不会往该主题发东西（垃圾报文只可能是噪声）。
    if (msg == null) return;
    // BUG-119：`decode(seenIds: _seen)` 只是**只读查重**，与这里的写入之间
    // 隔着一次异步解密 ⇒ 并发的同 ID 报文可以双双通过（QoS1 重投 + nonce 随机
    // ⇒ 密文字节不同，密文级去重挡不住）⇒ 业务命令可能被执行两次。
    // 改用与端点同款的**原子预占**：查重与写入在同一同步段完成。
    if (!RcCodec.reserveInboundId(
        _seen, msg.id, DateTime.now().millisecondsSinceEpoch)) {
      return; // 重复投递：不得执行任何副作用
    }

    switch (msg.type) {
      case RcAssistCmd.accept:
        // ---- P2-30：accept 必须回指本轮 join 发出的某个 hello ----
        //
        // 端点把被确认的 hello ID 写在 `payload.for`。若不核对，一条**迟到**的
        // accept（上一轮 join 的存量回执被 QoS1 重投）会被当成本次接入成功，
        // 控制端进入 active 却带着旧 sessionId/TTL/权限 —— 界面显示"已接入"
        // 而实际会话状态错位。核对失败时**保持 opening**（继续等正确回执），
        // 不置 active、不改任何会话字段。
        final forId = msg.payload['for'] as String? ?? '';
        if (forId.isEmpty || !_pendingHellos.contains(forId)) {
          _record(RcAssistCmd.accept,
              outbound: false,
              ok: false,
              detail: '忽略不匹配的 accept（for=${forId.isEmpty ? '缺失' : forId}）');
          return;
        }
        _sessionId = msg.payload['sessionId'] as String? ?? '';
        _epName = msg.payload['epName'] as String? ?? '声盾端点';
        final exp = (msg.payload['expiresAt'] as num?)?.toInt();
        _expiresAt =
            exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp);
        final raw = msg.payload['perms'];
        _perms = raw is Map
            ? AssistPerms.fromJson(raw.cast<String, dynamic>())
            : AssistPerms.none;
        _phase = AssistPhase.active;
        _record(RcAssistCmd.accept,
            outbound: false, ok: true, detail: '会话 $_sessionId');
        _emit();
      case RcAssistCmd.reject:
        final reason = msg.payload['reason'] as String? ?? '';
        _record(RcAssistCmd.reject,
            outbound: false, ok: false, detail: _rejectLabel(reason));
        unawaited(leave(silent: true).then((_) => _fail(_rejectLabel(reason))));
      case RcAssistCmd.perm:
        final raw = msg.payload['perms'];
        if (raw is Map) {
          _perms = AssistPerms.fromJson(raw.cast<String, dynamic>());
          _record(RcAssistCmd.perm,
              outbound: false, ok: true, detail: _permDetail(_perms));
          _emit();
        }
      case RcAssistCmd.close:
        _record(RcAssistCmd.close, outbound: false, ok: true, detail: '端点终止会话');
        unawaited(leave(silent: true).then((_) => _fail('端点已终止协助会话')));
      default:
        // 业务回执（rc.pong / rc.status / rc.ack / rc.device / rc.location…）
        // 与配对通道保持同一信封形状，控制台可直接复用渲染逻辑。
        final okFlag = msg.payload['ok'];
        _record(
          msg.type,
          outbound: false,
          ok: okFlag != false,
          detail: okFlag == false
              ? (msg.payload['data'] as String? ?? '端点拒绝执行')
              : '',
        );
        _emitEvent(msg);
    }
  }

  /// 权限位的人类可读摘要（审计用）。
  static String _permDetail(AssistPerms p) {
    final on = <String>[];
    for (final e in AssistPerms.labels.entries) {
      if (p.flag(e.key)) on.add(e.value);
    }
    return on.isEmpty ? '端点收回全部权限' : '端点放行：${on.join('、')}';
  }

  void _emitEvent(RcMessage msg) {
    if (_events.isClosed) return;
    _events.add({
      ...msg.toJson(),
      if (_epName.isNotEmpty) 'peerName': _epName,
      'assist': true,
    });
  }

  /// 该命令在当前会话权限下是否**预计**可执行（用于灰化按钮）。
  ///
  /// 仅是 UI 提示：真正裁决在端点侧，端点权限随时可变（[changes] 会推送）。
  bool allows(String cmd) =>
      _phase == AssistPhase.active && RcPermGate.allows(_perms, cmd);

  bool _fail(String reason) {
    _error = reason;
    _phase = AssistPhase.closed;
    _emit();
    return false;
  }

  static String _rejectLabel(String reason) => switch (reason) {
        'ttl_expired' => '会话已过期：请让端点重新生成临时码',
        'session_closed' => '端点已关闭该会话',
        _ => reason.isEmpty ? '端点拒绝了接入请求' : '端点拒绝：$reason',
      };


  void _rememberWire(String wire) {
    _seenWires.add(wire);
    while (_seenWires.length > _maxSeenWires) {
      _seenWires.remove(_seenWires.first);
    }
  }
}
