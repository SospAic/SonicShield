/// 远程连接节点的**候选目录**与**一键测速**（第八十二轮追加）。
///
/// ## 为什么要有它
/// 此前「MQTT 代理」只能手填一个主机名、通话 STUN 是写死的固定列表 ——
/// 使用者既看不到有哪些节点、也无从判断哪个**国内更快/更稳**。
/// 本文件把「候选节点」集中成可读目录，并提供**纯 IO 的时延探测**
/// （TCP/TLS 建连 / STUN 绑定请求往返），供 UI 做「下拉切换 + 一键测速」。
///
/// 目录只是**候选**：真正的连接目标仍由 `RemoteStore`（MQTT）/
/// `CallService`（STUN）决定，本文件不持有任何状态。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

/// 一个 MQTT 代理候选节点（传输恒为 TLS，端口即 TLS 端口）。
class MqttNode {
  const MqttNode({
    required this.host,
    required this.label,
    this.port = 8883,
    this.note = '',
    this.cn = false,
  });

  final String host;
  final String label;
  final int port;
  final String note;

  /// 是否**国内可达优先**（UI 上给「推荐」标记用）。
  final bool cn;

  /// 稳定标识（用于下拉选中值，与 host 解耦）。
  String get id => '$host:$port';
}

/// MQTT 代理候选（全部走 TLS；公共演示节点，生产建议自建 EMQX）。
///
/// `broker-cn.emqx.io` 是 EMQX 的**国内节点**（`broker.emqx.io` 的国内入口），
/// 国内直连通常明显更快；两者端口一致（8883 TLS / 8084 WSS）。
const List<MqttNode> kMqttNodes = <MqttNode>[
  MqttNode(
    host: 'broker-cn.emqx.io',
    label: 'EMQX 国内节点',
    note: '国内可达优先 · 公共演示（TLS 8883）',
    cn: true,
  ),
  MqttNode(
    host: 'broker.emqx.io',
    label: 'EMQX 全球（多区域）',
    note: '默认 · 全球多区域就近解析（TLS 8883）',
  ),
  MqttNode(
    host: 'test.mosquitto.org',
    label: 'Mosquitto 公共',
    note: '海外 · TLS 无认证（8883）',
  ),
  MqttNode(
    host: 'broker.hivemq.com',
    label: 'HiveMQ 公共',
    note: '海外 · 公共演示（8883）',
  ),
];

/// 一个 STUN 候选节点（ICE 用，UDP）。
class StunNode {
  const StunNode({
    required this.host,
    required this.label,
    this.port = 3478,
    this.cn = false,
  });

  final String host;
  final String label;
  final int port;
  final bool cn;

  String get url => 'stun:$host:$port';
  String get id => url;
}

/// STUN 候选（国内可达优先；保留 Google 一条作海外回落）。
const List<StunNode> kStunNodes = <StunNode>[
  StunNode(host: 'stun.miwifi.com', label: '小米', cn: true),
  StunNode(host: 'stun.chat.bilibili.com', label: '哔哩哔哩', cn: true),
  StunNode(host: 'stun.qq.com', label: '腾讯', cn: true),
  StunNode(host: 'stun.hitv.com', label: '芒果 TV', cn: true),
  StunNode(host: 'stun.syncthing.net', label: 'Syncthing'),
  StunNode(host: 'stun.cloudflare.com', label: 'Cloudflare'),
  StunNode(host: 'stun.l.google.com', label: 'Google（海外回落）', port: 19302),
];

/// 一次测速结果（`ms == null` 表示不可达 / 超时）。
class NodeProbe {
  const NodeProbe(this.id, this.ms);

  final String id;
  final int? ms;

  bool get ok => ms != null;
}

/// 节点时延探测（**纯 IO，可单测**：本地起服务端即可驱动）。
abstract final class NodeSpeedTest {
  NodeSpeedTest._();

  /// TCP（默认再叠一层 TLS 握手）建连时延（毫秒）；不可达/超时 → null。
  ///
  /// 对 MQTT 节点用 `tls: true`（8883 的真实建连成本含 TLS 握手）；
  /// 单测里对本地明文服务端用 `tls: false`。
  static Future<int?> connectLatency(
    String host,
    int port, {
    bool tls = true,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final sw = Stopwatch()..start();
    Socket? s;
    try {
      s = tls
          ? await SecureSocket.connect(host, port, timeout: timeout)
          : await Socket.connect(host, port, timeout: timeout);
      sw.stop();
      return sw.elapsedMilliseconds;
    } on Object {
      return null;
    } finally {
      try {
        s?.destroy();
      } on Object {
        // 关闭失败不影响测量结果。
      }
    }
  }

  /// STUN 绑定请求的往返时延（毫秒）；无响应/超时 → null。
  ///
  /// 发一个 RFC 5389 Binding Request（20 字节），等一个 `0x0101` 且
  /// 事务 ID 匹配的响应。DNS 解析失败、UDP 被墙、节点无响应都归为 null。
  static Future<int?> stunLatency(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    RawDatagramSocket? sock;
    StreamSubscription<RawSocketEvent>? sub;
    final sw = Stopwatch()..start();
    try {
      final txId = List<int>.generate(12, (_) => Random.secure().nextInt(256));
      final req = stunBindingRequest(txId);
      final addrs = await InternetAddress.lookup(host).timeout(timeout);
      if (addrs.isEmpty) return null;
      // socket 绑定的是 IPv4 ⇒ 必须挑 IPv4 目标；否则 `send` 会抛
      // "Address family not supported"（实测踩到）。
      final addr = addrs.firstWhere(
        (a) => a.type == InternetAddressType.IPv4,
        orElse: () => addrs.first,
      );
      if (addr.type != InternetAddressType.IPv4) return null;
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final done = Completer<bool>();
      sub = sock.listen((e) {
        if (e != RawSocketEvent.read) return;
        final dg = sock!.receive();
        final d = dg?.data;
        if (d != null && isStunBindingResponse(d, txId) && !done.isCompleted) {
          done.complete(true);
        }
      });
      sock.send(req, addr, port);
      final ok = await done.future.timeout(timeout, onTimeout: () => false);
      sw.stop();
      return ok ? sw.elapsedMilliseconds : null;
    } on Object {
      return null;
    } finally {
      try {
        await sub?.cancel();
      } on Object {
        // ignore
      }
      try {
        sock?.close();
      } on Object {
        // ignore
      }
    }
  }

  /// 构造一个 RFC 5389 STUN **Binding Request**（20 字节）。
  ///
  /// 头部：type=0x0001、length=0x0000、magic cookie=0x2112A442、12 字节事务 ID。
  /// 抽成纯函数是为了可单测（UDP 往返本身难在宿主上稳定复现）。
  static List<int> stunBindingRequest(List<int> txId) => <int>[
        0x00, 0x01, // Binding Request
        0x00, 0x00, // message length = 0
        0x21, 0x12, 0xA4, 0x42, // magic cookie
        ...txId.take(12),
      ];

  /// 校验一条 UDP 报文是否为**匹配事务 ID 的** Binding Success Response。
  static bool isStunBindingResponse(List<int> data, List<int> txId) {
    if (data.length < 20) return false;
    // type == 0x0101（Binding Success Response）
    if (data[0] != 0x01 || data[1] != 0x01) return false;
    // magic cookie 必须一致（防误把别的流量当响应）
    if (data[4] != 0x21 || data[5] != 0x12 || data[6] != 0xA4 || data[7] != 0x42) {
      return false;
    }
    for (var i = 0; i < 12; i++) {
      if (data[8 + i] != txId[i]) return false;
    }
    return true;
  }

  /// 给 MQTT 候选批量测速（并发），返回按「可达优先、时延升序」排好的结果。
  static Future<List<NodeProbe>> probeMqtt(
    List<MqttNode> nodes, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final rs = await Future.wait([
      for (final n in nodes)
        connectLatency(n.host, n.port, timeout: timeout)
            .then((ms) => NodeProbe(n.id, ms)),
    ]);
    return _sort(rs);
  }

  /// 给 STUN 候选批量测速（并发）。
  static Future<List<NodeProbe>> probeStun(
    List<StunNode> nodes, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final rs = await Future.wait([
      for (final n in nodes)
        stunLatency(n.host, n.port, timeout: timeout)
            .then((ms) => NodeProbe(n.id, ms)),
    ]);
    return _sort(rs);
  }

  /// 可达在前、时延升序；不可达保持原相对顺序。
  static List<NodeProbe> _sort(List<NodeProbe> rs) {
    final ok = rs.where((r) => r.ok).toList()
      ..sort((a, b) => a.ms!.compareTo(b.ms!));
    final bad = rs.where((r) => !r.ok).toList();
    return [...ok, ...bad];
  }
}

/// 远程 MQTT 的**传输方案**（第八十二轮：连接方案可在远程页选择）。
///
/// | 方案 | 端口 | 说明 |
/// |---|---|---|
/// | [tls] | 8883 | 标准 MQTT over TLS（默认，证书链强校验） |
/// | [wss] | 8084 | WebSocket over TLS，**封 TCP 的代理/企业网**更易穿透 |
/// | [quic] | 14567 | MQTT over QUIC（0-RTT）：⚠️ **当前 Dart 客户端库不支持**，
/// 选它会在连接时**回落 TLS 并明确告知**（不静默） |
///
/// ⚠️ 端口**不是**「关 TLS」的开关：三种方案都要求加密
/// （`secure = true`，`test/rc_transport_lock_test.dart` 锁着）。
enum RcTransport {
  tls('tls', 'TLS 8883', 8883, '标准 MQTT over TLS（默认）'),
  wss('wss', 'WSS 8084', 8084, 'WebSocket over TLS，封 TCP 的网络更易穿透'),
  quic('quic', 'QUIC 14567', 14567, '⚠️ 当前客户端库不支持，选它将回落 TLS');

  const RcTransport(this.id, this.label, this.defaultPort, this.note);

  final String id;
  final String label;
  final int defaultPort;
  final String note;

  /// 当前客户端库能否真正走该方案（QUIC 暂不能 → 回落 TLS）。
  bool get usable => this != RcTransport.quic;

  /// 容错解析（读不懂 → [tls]，与出厂默认一致，不抛）。
  static RcTransport parse(Object? raw) {
    if (raw is RcTransport) return raw;
    if (raw is String) {
      final t = raw.trim().toLowerCase();
      for (final v in values) {
        if (v.id == t) return v;
      }
    }
    return RcTransport.tls;
  }
}
