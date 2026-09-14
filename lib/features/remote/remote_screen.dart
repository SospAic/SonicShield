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
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';

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
  List<PairedEndpoint> _endpoints = const [];

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
      _endpoints = store.paired();
    });
  }

  Future<void> _toggleEnabled(bool v) async {
    setState(() => _connecting = true);
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
    await store.setEnabled(v);
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _enabled = v;
      _deviceId = store.deviceId;
      _deviceName = store.deviceName;
    });
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
    await store.addPaired(PairedEndpoint(
      deviceId: idCtrl.text.trim(),
      name: nameCtrl.text.trim().isEmpty ? '未命名端点' : nameCtrl.text.trim(),
      secret: secret,
      pairedAt: DateTime.now(),
    ));
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('配对完成，可发送指令组')));
    }
  }

  Future<void> _pttSheet(PairedEndpoint endpoint) async {
    if (!mounted) return;
    final granted = await Permission.microphone.request().isGranted;
    if (!granted || !mounted) return;
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
      appBar: AppBar(title: const Text('远程遥控')),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
            child: ListTile(
              leading: const Icon(Icons.dns),
              title: const Text('MQTT 代理'),
              subtitle: Text('$_broker（公共演示节点，建议自建 EMQX）'),
              onTap: () async {
                final ctrl = TextEditingController(text: _broker);
                final v = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('MQTT 代理地址'),
                    content: TextField(controller: ctrl),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                          child: const Text('保存')),
                    ],
                  ),
                );
                if (v != null && v.isNotEmpty) {
                  final prefs = await SharedPreferences.getInstance();
                  await RemoteStore(prefs).setBroker(v);
                  if (mounted && _enabled) {
                    await RcEndpointService.instance.stop();
                    final store = RemoteStore(prefs);
                    final db = await ref.read(databaseProvider.future);
                    await RcEndpointService.instance.start(store, db);
                  }
                  await _load();
                }
              },
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
                    padding: EdgeInsets.all(14),
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
                        await _load();
                      },
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Card(
            color: Color(0x14C62828),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '⚠️ 安全与合规：\n'
                '· 仅与本人或已获明确授权的设备配对；\n'
                '· 远程播放/指令组的滥用同样受噪声与治安法规约束；\n'
                '· 接收端全程审计留痕，通知栏可见且可随时终止；\n'
                '· 全部流量端到端加密（AES-256-GCM），代理服务器不可见内容。',
                style: TextStyle(fontSize: 12),
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

  Future<void> _start() async {
    final ok = await widget.onStart();
    if (mounted) setState(() => _recording = ok);
  }

  Future<void> _stopSend() async {
    final r = await widget.onStopAndSend();
    if (mounted) setState(() => _result = r.message);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('对讲机 → ${widget.endpointName}',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(_recording ? '正在录音…（松开发送，最长 60 秒）' : '按住下方按钮开始说话',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            GestureDetector(
              onTapDown: (_) => _start(),
              onTapUp: (_) => _stopSend(),
              onTapCancel: () => widget.onCancel(),
              child: CircleAvatar(
                radius: 44,
                backgroundColor:
                    _recording ? AppTheme.danger : AppTheme.shieldMid,
                child: Icon(_recording ? Icons.stop : Icons.mic,
                    size: 40, color: Colors.white),
              ),
            ),
            const SizedBox(height: 16),
            if (_result != null) Text(_result!),
            const SizedBox(height: 8),
            TextButton(
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
          padding: EdgeInsets.all(12),
          child: Text(
            '1. 两台设备均开启端点并连接同一 MQTT 代理；\n'
            '2. 互相输入对方设备 ID + 配对码完成配对'
            '（配对码即共享秘密，派生 AES-256-GCM 密钥）；\n'
            '3. 指令组/对讲/查询全部走「端到端加密」，代理只见密文；\n'
            '4. 端点收到指令组立即执行：通知栏显示发送方与进度，'
            '可点【终止执行】或由发送方远程终止；\n'
            '5. 执行完成通知自动消失，全程审计留痕。',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}
