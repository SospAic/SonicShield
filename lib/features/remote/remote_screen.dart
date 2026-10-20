import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../remote/controller_service.dart';
import '../../remote/endpoint_service.dart';
import '../../remote/node_catalog.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';
import '../../services/device_name_service.dart';
import 'pair_qr_screen.dart' show notifyPeerOfPairing;

/// 远程遥控总览：模块开关 / 设备身份 / broker / 配对端点管理 /
/// 指令组装器入口 / 对讲机 / 快捷命令（播放/状态/守卫）。
///
/// 合规：默认关闭；仅支持本人或已授权设备配对；全部流量端到端加密；
/// 接收端全程审计。详见 docs/14。
class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key});

  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen> {
  bool _enabled = false;
  bool _connecting = false;
  String _deviceId = '';
  String _deviceName = '';
  String _broker = RemoteStore.defaultBroker;
  String _brokerHost = '';
  int? _brokerPort;
  String _brokerUser = '';
  String _turnUrl = '';
  List<PairedEndpoint> _endpoints = const [];

  // ---- 第八十二轮：节点下拉 + 一键测速 ----
  int _mqttNodePort = RemoteStore.defaultBrokerPort;
  RcTransport _transport = RcTransport.tls;
  String _stunUrl = '';
  List<NodeProbe>? _mqttProbes;
  List<NodeProbe>? _stunProbes;
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (!mounted) return;
    setState(() {
      _enabled = store.enabled;
      _deviceId = store.deviceId;
      _deviceName = store.deviceName;
      _broker = store.broker;
      _brokerHost = store.brokerHost;
      _brokerPort = store.brokerPort;
      _brokerUser = store.brokerUsername;
      _turnUrl = store.turnUrl;
      _endpoints = store.paired();
      _mqttNodePort = store.mqttNodePort ?? RemoteStore.defaultBrokerPort;
      _transport = store.transport;
      _stunUrl = store.stunSelectedUrl;
    });
  }

  /// 当前 MQTT 节点对应的下拉选中 id（不落在预设里 → null，下拉留空）。
  String? get _mqttDropdownValue {
    for (final n in kMqttNodes) {
      if (n.host == _broker) return n.id;
    }
    return null;
  }

  /// 当前 STUN 选中值（不在目录里 → 回到「自动」）。
  String get _stunDropdownValue {
    for (final n in kStunNodes) {
      if (n.url == _stunUrl) return n.url;
    }
    return '__auto__';
  }

  static String _fmtMs(int? ms) => ms == null ? '不可达/超时' : '$ms ms';

  /// 选中一个 MQTT 预设节点：落盘 host+port 并**重启远程模块**（与手填 broker 同一路径）。
  Future<void> _selectMqttNode(MqttNode n) async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    await store.setMqttNode(n.host, port: n.port);
    if (_enabled) {
      await RcEndpointService.instance.stop();
      final db = await ref.read(databaseProvider.future);
      await RcEndpointService.instance.start(store, db);
    }
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到 ${n.label}（${n.host}:${n.port}）')));
  }

  /// 选中 MQTT **传输方案**（TLS / WSS / QUIC）：落盘并重启远程模块。
  Future<void> _selectTransport(RcTransport t) async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    await store.setTransport(t);
    if (_enabled) {
      await RcEndpointService.instance.stop();
      final db = await ref.read(databaseProvider.future);
      await RcEndpointService.instance.start(store, db);
    }
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t.usable
            ? '连接方案：${t.label}'
            : '${t.label} 暂不支持（当前客户端库无 QUIC），已回落 TLS')));
  }

  /// 选中首选 STUN 节点（空串 = 自动：全部并行，默认行为）。
  Future<void> _selectStun(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await RemoteStore(prefs).setStunSelectedUrl(url);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(url.isEmpty ? 'STUN：自动（全部并行）' : 'STUN 已固定为 $url')));
  }

  /// 一键测速：并发探测全部 MQTT / STUN 候选节点，按「可达优先、时延升序」展示。
  Future<void> _speedTest() async {
    setState(() => _probing = true);
    try {
      final mqtt = await NodeSpeedTest.probeMqtt(kMqttNodes);
      final stun = await NodeSpeedTest.probeStun(kStunNodes);
      if (!mounted) return;
      setState(() {
        _mqttProbes = mqtt;
        _stunProbes = stun;
        _probing = false;
      });
    } on Object {
      if (mounted) setState(() => _probing = false);
    }
  }

  /// 测速结果列表（可达在前；最快的一条打 ★）。
  Widget _probeList(List<NodeProbe>? probes, String Function(String id) label) {
    if (probes == null) return const SizedBox.shrink();
    String? fastest;
    for (final p in probes) {
      if (p.ok) {
        fastest = p.id;
        break;
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final p in probes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${p.id == fastest ? '★ ' : '· '}${label(p.id)}：${_fmtMs(p.ms)}',
                style: AppText.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  /// 编辑 TURN 中继配置（S5）。
  ///
  /// 不内置公共 TURN：中继会经手媒体流量，把使用者的通话交给来路不明的
  /// 免费中继既不安全也不可靠。默认留空（纯 STUN 打洞），由使用者填自建服务。
  ///
  /// ⚠️ **BUG-064：controller 的释放时机**。
  ///
  /// 原实现在 `await showDialog(...)` 之后**立刻** `dispose()` 三个
  /// `TextEditingController`。但 `showDialog` 的 future 在 `Navigator.pop`
  /// 那一刻就完成了，而路由的**退场动画**还在跑 —— `TextField` 仍挂在树上
  /// 引用这些 controller，于是抛
  /// `A TextEditingController was used after being disposed`
  /// （debug 下对话框关闭时红屏；该异常还会污染同文件后续用例）。
  ///
  /// 现在把 controller 的所有权交给 [_TurnDialog]：框架会在路由真正
  /// 移除子树后才调它的 `dispose()`，时机由框架保证，不靠人估延时。
  Future<void> _editTurn() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);

    // 跨 await 后必须复查 mounted 才能用 context（use_build_context_synchronously）。
    if (!mounted) return;

    final v = await showDialog<({String url, String user, String cred})>(
      context: context,
      builder: (_) => _TurnDialog(
        url: store.turnUrl,
        user: store.turnUser,
        cred: store.turnCred,
      ),
    );
    if (v == null) return;
    await store.setTurn(url: v.url, user: v.user, cred: v.cred);
    await _load();
  }

  /// 编辑自定义 MQTT 代理（Q2.B，高级可选）。
  ///
  /// 连接侧接线不在本页做：本页只落盘四个字段（host/port/用户名/密码），
  /// 远程模块在下一次启动时读取并重连 —— 因此界面上写明
  /// 「保存后重启远程模块生效」，避免用户以为保存即已切换。
  ///
  /// controller 的释放时机与 [_TurnDialog] 同理（BUG-064）：交给对话框
  /// widget 自己 dispose，调用方不估延时。
  Future<void> _editBrokerAdvanced() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);

    // 跨 await 后必须复查 mounted 才能用 context（use_build_context_synchronously）。
    if (!mounted) return;

    final v = await showDialog<
        ({String host, int? port, String user, String pass})>(
      context: context,
      builder: (_) => _BrokerAdvancedDialog(
        host: store.brokerHost,
        port: store.brokerPort,
        user: store.brokerUsername,
        pass: store.brokerPassword,
      ),
    );
    if (v == null) return;
    await store.setBrokerAdvanced(
        host: v.host, port: v.port, username: v.user, password: v.pass);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存：重启远程模块后生效')));
  }

  /// 一键测速按钮（MQTT + STUN 同时探测）。
  Widget _speedTestButton() => FilledButton.tonalIcon(
        icon: _probing
            ? const SizedBox(
                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.speed, size: 18),
        label: const Text('一键测速'),
        onPressed: _probing ? null : _speedTest,
      );

  /// 节点 id → 展示名（找不到回落到 id，不抛）。
  static String _mqttLabel(String id) {
    for (final n in kMqttNodes) {
      if (n.id == id) return n.label;
    }
    return id;
  }

  static String _stunLabel(String id) {
    for (final n in kStunNodes) {
      if (n.url == id) return n.label;
    }
    return id;
  }

  /// 手填自定义 MQTT 代理地址（原「MQTT 代理」对话框，保留为兜底入口）。
  Future<void> _editBrokerCustom() async {
    // ⚠️ **不用 `TextEditingController`**：`showDialog` 的 future 在 `pop` 那刻就
    // 完成，而路由**退场动画仍在跑**、`TextField` 仍挂在树上 —— 此时 dispose 控制器
    // 会抛 "A TextEditingController was used after being disposed"（BUG-064 同款）。
    // 改用 `TextFormField(initialValue:) + onChanged`：没有控制器就没有释放时机问题。
    var text = _broker;
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('MQTT 代理地址'),
        content: TextFormField(
          initialValue: _broker,
          onChanged: (s) => text = s,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    // 手填 = 清掉预设下拉，避免"选了预设又手填"时两个来源打架。
    await RemoteStore(prefs).setMqttNode('');
    await RemoteStore(prefs).setBroker(v);
    if (mounted && _enabled) {
      await RcEndpointService.instance.stop();
      final store = RemoteStore(prefs);
      final db = await ref.read(databaseProvider.future);
      await RcEndpointService.instance.start(store, db);
    }
    await _load();
  }

  /// 本机改名（FR-77，第八十四轮用户明文）：改名 + **广播给所有已绑定端点**。
  ///
  /// 广播结果**如实回报**：`sent < total` 说明有端点离线没收到（下次它上线时
  /// 仍会从别的通路得知，但此刻不能谎报"全部同步成功"）。
  Future<void> _renameLocal() async {
    final ctrl = TextEditingController(text: _deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('本机名称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: DeviceNameService.maxLen,
          decoration: const InputDecoration(
            labelText: '给本机起个名字',
            hintText: '如：我的手机 / 客厅主机',
            helperText: '改名后会通知所有已绑定设备，并在它们的列表中同步更新',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('保存并同步')),
        ],
      ),
    );
    if (name == null || !mounted) return;
    final r = await DeviceNameService.instance.renameLocal(name);
    await _load();
    if (!mounted) return;
    final text = !r.ok
        ? '改名失败：${r.error}'
        : (r.total == 0
            ? '本机名称已更新（暂无已绑定设备）'
            : r.sent == r.total
                ? '本机名称已更新，并已同步到全部 ${r.total} 台设备'
                : '本机名称已更新：${r.sent}/${r.total} 台已同步'
                    '（其余离线，下次上线后同步）');
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _toggleEnabled(bool v) async {
    setState(() => _connecting = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final store = RemoteStore(prefs);
      if (v) {
        if (store.deviceId.isEmpty) {
          final id = RcCodec.generateDeviceId();
          await store.setIdentity(id, '声盾-${id.substring(0, 4)}');
        }
        final db = await ref.read(databaseProvider.future);
        await RcEndpointService.instance.start(store, db);
      } else {
        await RcEndpointService.instance.stop();
      }
      // P1-10 / P2-14：**只在成功路径落盘 enabled**。失败不得留下
      // "以为已开启"的持久化状态，否则下次启动会"自己开着"。
      await store.setEnabled(v);
      if (!mounted) return;
      _enabled = v;
      await _load();
    } on Object catch (e) {
      // P1-10 / P2-14：异常必须可见。旧实现没有 try/finally —— 任一异步异常
      // 都会让 `_connecting` 永不复位（界面永久"连接中"），且没有任何错误提示。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('远程模块${v ? '启动' : '停止'}失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _addPairDialog() async {
    final idCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final codeCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('配对新端点'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: idCtrl,
                decoration: const InputDecoration(labelText: '端点设备 ID（16 位）')),
            TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '端点名称')),
            TextField(
                controller: codeCtrl,
                decoration:
                    const InputDecoration(labelText: '配对码（端点显示，如 AB2C-D5EF）'),
                textCapitalization: TextCapitalization.characters),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('配对')),
        ],
      ),
    );
    if (ok != true) return;
    final secret = codeCtrl.text.trim().replaceAll('-', '').toUpperCase();
    if (idCtrl.text.trim().length != 16 || secret.length != 8) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('设备 ID 须 16 位、配对码须 8 位')));
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    final endpoint = PairedEndpoint(
      deviceId: idCtrl.text.trim(),
      name: nameCtrl.text.trim().isEmpty ? '未命名端点' : nameCtrl.text.trim(),
      secret: secret,
      pairedAt: DateTime.now(),
    );
    await store.addPaired(endpoint);
    // 立即订阅新对端的 evt 主题（否则收不到其回执，BUG-013）。
    await RcEndpointService.instance.refreshSubscriptions();
    await _load();
    if (!mounted) return;
    // R-2：只做"本机落盘"是不够的 —— 对端表里没有本机时，它**执行了却发不出
    // 回执**。这里立刻通知对端，并把结果如实告诉用户（8 秒没有回音也算结果，
    // 且必须说出来：否则用户会以为配对失败而反复重试）。
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
        const SnackBar(content: Text('配对完成，正在通知对端确认…')));
    final outcome = await notifyPeerOfPairing(endpoint, store);
    // 用 hide + show 而不是排队：排队会让两条"配对完成…"同时挂在屏幕上，
    // 用户看到的是两条互相矛盾的消息。
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        content: Text('配对完成：${outcome.message}'),
        duration: Duration(seconds: outcome.confirmed ? 4 : 10)));
    await _load();
  }

  Future<void> _pttSheet(PairedEndpoint endpoint) async {
    if (!mounted) return;
    final granted = await Permission.microphone.request().isGranted;
    if (!granted) {
      // ⚠️ BUG-062：此前这里**静默 return**，用户点了「对讲」毫无反应、
      // 也不知道是麦克风权限没给 —— 与 BUG-061 同形状（失败必须让用户知道）。
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('需要麦克风权限才能对讲')));
      return;
    }
    if (!mounted) return;
    final controller = RcControllerService.instance;
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _PttSheet(
        endpointName: endpoint.name,
        onStart: () => controller.pttStart(),
        onStopAndSend: () => controller.pttStopAndSend(endpoint, store),
        onCancel: () => controller.pttCancel(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('远程中心 · 设置')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Card(
            color: _enabled
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: SwitchListTile(
              secondary: Icon(
                  _enabled ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                  size: 30),
              title: Text(_enabled ? '端点在线' : '端点已关闭',
                  style: Theme.of(context).textTheme.titleMedium),
              subtitle: const Text('允许已配对设备通过公网遥控本机（MQTT·端到端加密）'),
              value: _enabled,
              onChanged: _connecting ? null : _toggleEnabled,
            ),
          ),
          if (_connecting) const LinearProgressIndicator(),
          const SizedBox(height: 10),
          Card(
            child: ListTile(
              leading: const Icon(Icons.badge),
              title: const Text('本机身份'),
              subtitle: Text(
                  _deviceId.isEmpty ? '开启后自动生成' : '$_deviceName\n$_deviceId'),
              isThreeLine: _deviceId.isNotEmpty,
              // FR-77（第八十四轮用户明文）：本机名称支持自定义，改名后**通知所有
              // 已绑定远程设备**并在它们的列表同步更新。点标题即改名。
              onTap: _deviceId.isEmpty ? null : _renameLocal,
              trailing: _deviceId.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _deviceId));
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('设备 ID 已复制')));
                      },
                    ),
            ),
          ),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ListTile(
                  leading: Icon(Icons.dns),
                  title: Text('MQTT 代理节点'),
                  subtitle: Text('连接方案 / 节点下拉切换 · 一键测速选最快'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: _transport.id,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: '连接方案（传输）', border: OutlineInputBorder()),
                    items: [
                      for (final t in RcTransport.values)
                        DropdownMenuItem(
                            value: t.id,
                            child: Text(
                                '${t.label}${t.usable ? '' : '（暂不支持）'}',
                                overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (id) {
                      if (id != null) _selectTransport(RcTransport.parse(id));
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: _mqttDropdownValue,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: '节点', border: OutlineInputBorder()),
                    hint: Text('当前：$_broker:$_mqttNodePort'),
                    items: [
                      for (final n in kMqttNodes)
                        DropdownMenuItem(
                            value: n.id,
                            child: Text('${n.label}（${n.host}）',
                                overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (id) {
                      if (id == null) return;
                      for (final n in kMqttNodes) {
                        if (n.id == id) {
                          _selectMqttNode(n);
                          break;
                        }
                      }
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Row(
                    children: [
                      _speedTestButton(),
                      const SizedBox(width: 8),
                      TextButton(
                          onPressed: _editBrokerCustom,
                          child: const Text('自定义…')),
                    ],
                  ),
                ),
                _probeList(_mqttProbes, _mqttLabel),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: ListTile(
              leading: const Icon(Icons.lan),
              title: const Text('MQTT 代理（高级，可选）'),
              subtitle: Text(
                _brokerHost.isEmpty
                    ? '未配置：使用默认公共节点。自建 EMQX/Mosquitto 可在此接管'
                    : '$_brokerHost:'
                        '${_brokerPort ?? RemoteStore.defaultBrokerPort}'
                        '${_brokerUser.isEmpty ? '' : ' · 用户名 $_brokerUser'}'
                        '（保存后重启远程模块生效）',
                style: AppText.bodySmall,
              ),
              isThreeLine: _brokerHost.isEmpty,
              trailing: const Icon(Icons.edit, size: 18),
              onTap: _editBrokerAdvanced,
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('TURN 中继（可选）'),
              subtitle: Text(
                _turnUrl.isEmpty
                    ? '未配置：仅用 STUN 打洞。双方均为对称 NAT 时通话会直连失败'
                    : '$_turnUrl（已启用中继）',
                style: AppText.bodySmall,
              ),
              isThreeLine: _turnUrl.isEmpty,
              trailing: const Icon(Icons.edit, size: 18),
              onTap: _editTurn,
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ListTile(
                  leading: Icon(Icons.hub),
                  title: Text('STUN 节点（通话打洞）'),
                  subtitle: Text('默认「自动：全部并行」；也可固定一个节点'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: _stunDropdownValue,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: '首选节点', border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem(
                          value: '__auto__', child: Text('自动（全部并行，推荐）')),
                      for (final n in kStunNodes)
                        DropdownMenuItem(
                            value: n.url,
                            child: Text('${n.label}（${n.host}）',
                                overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) =>
                        _selectStun(v == null || v == '__auto__' ? '' : v),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: _speedTestButton(),
                ),
                _probeList(_stunProbes, _stunLabel),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('已配对端点（${_endpoints.length}）',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                tooltip: '扫码配对',
                onPressed: () async {
                  await context.push('/remote/pair-qr');
                  await _load();
                },
              ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('手输'),
                onPressed: _addPairDialog,
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_endpoints.isEmpty)
            const Card(
                child: Padding(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    child: Text('尚未配对端点。在另一台设备上打开声盾 → 远程遥控 → '
                        '复制其设备 ID 与配对码，在此处添加配对。'))),
          for (final e in _endpoints)
            Card(
              child: ListTile(
                leading: const Icon(Icons.phone_android),
                title: Text(e.name),
                subtitle: Text(e.deviceId),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.build),
                      tooltip: '指令组装器',
                      onPressed: () =>
                          context.push('/remote/script-builder/${e.deviceId}'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.mic),
                      tooltip: '对讲机',
                      onPressed: () => _pttSheet(e),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '取消配对',
                      onPressed: () async {
                        final prefs = await SharedPreferences.getInstance();
                        await RemoteStore(prefs).removePaired(e.deviceId);
                        // P1：同「我的设备」页 —— 撤销后立刻清掉该端点在跑的
                        // 在途指令组/通话（顺序：先出配对表，再清在途）。
                        await RcEndpointService.instance.onPeerRevoked(e.deviceId);
                        await _load();
                      },
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Card(
            color: AppColors.dangerWash,
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text(
                '⚠️ 安全与合规：\n'
                '· 仅与本人或已获明确授权的设备配对；\n'
                '· 远程播放/指令组的滥用同样受噪声与治安法规约束；\n'
                '· 接收端全程审计留痕，通知栏可见且可随时终止；\n'
                '· 全部流量端到端加密（AES-256-GCM），代理服务器不可见内容。',
                style: AppText.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const _HowItWorks(),
        ],
      ),
    );
  }
}

/// TURN 配置对话框。
///
/// 单独做成 StatefulWidget 的唯一理由是 **controller 的释放时机**（BUG-064）：
/// `showDialog` 的 future 在 `Navigator.pop` 时就完成，而退场动画尚未结束，
/// 调用方此时 `dispose()` 会让仍在树上的 `TextField` 引用到已释放的 controller。
/// 交给本 widget 在 `dispose()` 中释放 —— 框架保证那时子树已经摘除。
///
/// 返回值：保存时回传三项配置；取消时回传 null（[Navigator.pop] 无参）。
class _TurnDialog extends StatefulWidget {
  const _TurnDialog({
    required this.url,
    required this.user,
    required this.cred,
  });

  final String url;
  final String user;
  final String cred;

  @override
  State<_TurnDialog> createState() => _TurnDialogState();
}

class _TurnDialogState extends State<_TurnDialog> {
  late final TextEditingController _url =
      TextEditingController(text: widget.url);
  late final TextEditingController _user =
      TextEditingController(text: widget.user);
  late final TextEditingController _cred =
      TextEditingController(text: widget.cred);

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _cred.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('TURN 中继'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '仅在双方都处于对称 NAT（常见于 4G/5G、企业网）时才需要。'
              '留空即关闭中继。',
              style: AppText.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: '地址',
                hintText: 'turn:example.com:3478',
              ),
            ),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: '用户名（可选）'),
            ),
            TextField(
              controller: _cred,
              decoration: const InputDecoration(labelText: '密码（可选）'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            url: _url.text.trim(),
            user: _user.text.trim(),
            cred: _cred.text,
          )),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 自定义 MQTT 代理配置对话框（Q2.B）。
///
/// 单独做成 StatefulWidget 的理由与 [_TurnDialog] 相同（BUG-064）：
/// controller 由本 widget 在 `dispose()` 中释放，时机由框架保证。
///
/// 返回值：保存时回传四项配置（port 为 null = 用默认 TLS 8883）；
/// 取消时回传 null（[Navigator.pop] 无参）。
class _BrokerAdvancedDialog extends StatefulWidget {
  const _BrokerAdvancedDialog({
    required this.host,
    required this.port,
    required this.user,
    required this.pass,
  });

  final String host;
  final int? port;
  final String user;
  final String pass;

  @override
  State<_BrokerAdvancedDialog> createState() => _BrokerAdvancedDialogState();
}

class _BrokerAdvancedDialogState extends State<_BrokerAdvancedDialog> {
  late final TextEditingController _host =
      TextEditingController(text: widget.host);
  late final TextEditingController _port =
      TextEditingController(text: widget.port?.toString() ?? '');
  late final TextEditingController _user =
      TextEditingController(text: widget.user);
  late final TextEditingController _pass =
      TextEditingController(text: widget.pass);

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('MQTT 代理（高级，可选）'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '自建 EMQX/Mosquitto 时填写。自定义主机留空即用默认公共节点；'
              '无论连哪个代理，传输都固定走 TLS（不支持明文端口）。'
              '保存后重启远程模块生效。',
              style: AppText.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: '自定义主机（空 = 默认公共）',
                hintText: 'mqtt.example.com',
              ),
            ),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '端口（默认 ${RemoteStore.defaultBrokerPort}，TLS）',
                hintText: '${RemoteStore.defaultBrokerPort}',
              ),
            ),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: '用户名（可选）'),
            ),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码（可选）'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final portText = _port.text.trim();
            Navigator.pop(context, (
              host: _host.text.trim(),
              port: portText.isEmpty ? null : int.tryParse(portText),
              user: _user.text.trim(),
              pass: _pass.text,
            ));
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _PttSheet extends StatefulWidget {
  const _PttSheet({
    required this.endpointName,
    required this.onStart,
    required this.onStopAndSend,
    required this.onCancel,
  });

  final String endpointName;
  final Future<bool> Function() onStart;
  final Future<PttSendResult> Function() onStopAndSend;
  final Future<void> Function() onCancel;

  @override
  State<_PttSheet> createState() => _PttSheetState();
}

class _PttSheetState extends State<_PttSheet> {
  bool _recording = false;
  String? _result;

  /// 手指是否仍按在按钮上（R90-02）。
  ///
  /// `_start()` 要跨"请求麦克风权限 → `pttStart()`"两段 await；用户若在它们
  /// 完成前松手，`_stopSend()` 先跑（此时尚未开录，返回"未录到音频"），随后
  /// `_start()` 仍会把录音拉起来 —— 一段**无人控制**的录音。本标志在 await
  /// 之后复核"是否仍按住"，已松手则撤销启动（与 `ptt_tab.dart` 的 P2-25 同判据）。
  bool _pressing = false;

  /// 录音时长上限（R90-02：文案承诺的"最长 60 秒"此前**没有任何实现**）。
  ///
  /// 用**一次性** Timer 而不是 `Timer.periodic` 数秒：周期计时器会在整个录音
  /// 期间不断调度帧，`pumpAndSettle` 永远等不到静止（RRS-26 实测超时）。
  /// 时长上限本来只需要一个到点回调。
  Timer? _limitTimer;

  static const int _maxRecSec = 60;

  Future<void> _start() async {
    if (_recording) return;
    _pressing = true;
    final ok = await widget.onStart();
    // 松手早于启动完成 ⇒ 撤销这次启动，不留无人控制的录音。
    // ⚠️ 必须先判 `_pressing` 再判 `mounted`：面板已被下滑关闭时 `mounted`
    // 为 false，但此时若 onStart 成功，麦克风已经起来了 —— 必须撤销。
    if (!_pressing) {
      if (ok) unawaited(widget.onCancel());
      return;
    }
    if (!mounted) return;
    if (!ok) return;
    setState(() => _recording = true);
    _limitTimer?.cancel();
    _limitTimer = Timer(const Duration(seconds: _maxRecSec), () {
      if (mounted) unawaited(_stopSend(auto: true));
    });
  }

  Future<void> _stopSend({bool auto = false}) async {
    _pressing = false;
    _limitTimer?.cancel();
    _limitTimer = null;
    if (!_recording) {
      // 没起来（权限弹窗期间松手 / 启动失败）：**直接给出可见反馈**。
      // 不调 `onStopAndSend()` —— 那会在"从未开录"时走一遍插件往返，
      // 宿主环境下该 Future 可能永不完成（RRS-26 实测 90s 超时）。
      if (mounted) setState(() => _result = '未录到音频');
      return;
    }
    setState(() => _recording = false);
    final r = await widget.onStopAndSend();
    if (!mounted) return;
    setState(() => _result =
        auto ? '已到 $_maxRecSec 秒上限，自动发送：${r.message}' : r.message);
  }

  /// 撤销：停表 + 撤销录音（关闭面板 / 手势取消 / 销毁三条路径共用）。
  ///
  /// ⚠️ **无条件**调用 `onCancel`：它内部 `pttCancel()` 对"尚未开录"是幂等的，
  /// 而漏调一次的代价是麦克风被一直占着（RRS-27 锁的就是这一点）。
  void _cancel() {
    // 空闲关闭（没录、也没有在飞的启动）不需要碰录音插件 —— 那会在宿主
    // 环境留下一个永不完成的 stop Future，污染**后续**用例（RRS-26 实测：
    // 单独跑 2 秒通过，跟在 RRS-19b 之后跑就卡死在 pumpAndSettle）。
    final active = _recording || _pressing;
    _pressing = false;
    _limitTimer?.cancel();
    _limitTimer = null;
    if (mounted && _recording) setState(() => _recording = false);
    if (active) {
      // fire-and-forget：撤销是"尽力而为"，不能因为插件 Future 不返回就卡住
      // 关闭按钮/手势回调（与旧实现 `() => widget.onCancel()` 同语义）。
      unawaited(widget.onCancel());
    }
  }

  @override
  void dispose() {
    _limitTimer?.cancel();
    _pressing = false;
    // R90-02：录音中（或启动请求仍在飞）直接销毁 —— 必须撤销，否则麦克风在
    // **没有任何界面入口**的状态下持续采集。
    if (_recording || _pressing) unawaited(widget.onCancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('对讲机 → ${widget.endpointName}',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
                _recording
                    ? '正在录音…（最长 $_maxRecSec 秒，松开发送）'
                    : '按住下方按钮开始说话',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            GestureDetector(
              onTapDown: (_) => _start(),
              onTapUp: (_) => _stopSend(),
              onTapCancel: () => _cancel(),
              child: CircleAvatar(
                radius: 44,
                backgroundColor:
                    _recording ? AppColors.dangerDeep : AppTheme.shieldMid,
                child: Icon(_recording ? Icons.stop : Icons.mic,
                    size: 40, color: Colors.white),
              ),
            ),
            const SizedBox(height: 16),
            if (_result != null) Text(_result!),
            const SizedBox(height: 8),
            TextButton(
                // 关闭只做 pop：录音的撤销交给 `dispose()`（它按
                // `_recording || _pressing` 判定是否需要 `onCancel`）。
                // 旧实现在 pop 之后再调一次撤销，会在已弹出的路由上 setState，
                // 宿主环境里表现为下一个用例的 `pumpAndSettle` 永不静止。
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭')),
          ],
        ),
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    return const ExpansionTile(
      title: Text('工作原理'),
      children: [
        Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Text(
            '1. 两台设备均开启端点并连接同一 MQTT 代理；\n'
            '2. 互相输入对方设备 ID + 配对码完成配对'
            '（配对码即共享秘密，派生 AES-256-GCM 密钥）；\n'
            '3. 指令组/对讲/查询全部走「端到端加密」，代理只见密文；\n'
            '4. 端点收到指令组立即执行：通知栏显示发送方与进度，'
            '可点【终止执行】或由发送方远程终止；\n'
            '5. 执行完成通知自动消失，全程审计留痕。',
            style: AppText.bodySmall,
          ),
        ),
      ],
    );
  }
}
