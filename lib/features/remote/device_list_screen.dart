import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/remote_store.dart';

/// 「最近连接」的相对时间文案。
///
/// 抽成纯函数：这是**展示类**逻辑，写错不会抛异常、只会显示错，
/// 因此必须能被单测逐档位断言（项目纪律：展示类只能靠锁）。
String formatLastConnected(DateTime? at, DateTime now) {
  if (at == null) return '从未连接';
  final d = now.difference(at);
  if (d.isNegative) return '刚刚'; // 时钟回拨/跨设备数据，不显示负时间
  if (d.inSeconds < 60) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 30) return '${d.inDays} 天前';
  return '${at.year}-${_p(at.month)}-${_p(at.day)}';
}

String _p(int v) => v.toString().padLeft(2, '0');

/// 「我的设备」列表（向日葵式：保存连接 + 快速连接）。
///
/// 与既有「远程 → 设备」页的分工：
/// - 本页 = **连接管理**（保存了哪些、连哪台、备注、删除）—— 面向"我的设备清单"；
/// - 控制台 = **对单台设备的操作**（发命令）—— 面向"当前目标"。
///
/// 点一张卡片即"快速连接"：把该端点设为**当前目标并持久化**，
/// 控制台 / 对讲 / 指令组初始化时读取同一份选择，无需每页重选。
class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key, this.embedded = false});

  /// 作为分组页子 TAB 使用时不再自带 AppBar。
  final bool embedded;

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  List<PairedEndpoint> _endpoints = const [];
  String _selectedId = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<RemoteStore> _store() async =>
      RemoteStore(await SharedPreferences.getInstance());

  Future<void> _load() async {
    final store = await _store();
    if (!mounted) return;
    setState(() {
      _endpoints = store.paired();
      _selectedId = store.selectedEndpointId;
      _loading = false;
    });
  }

  Future<void> _connect(PairedEndpoint e) async {
    final store = await _store();
    await store.selectEndpoint(e.deviceId);
    if (!mounted) return;
    setState(() => _selectedId = e.deviceId);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已连接到「${e.displayName}」')),
    );
  }

  Future<void> _rename(PairedEndpoint e) async {
    final ctrl = TextEditingController(text: e.alias ?? e.name);
    final ok = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备注名'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: '给这台设备起个好认的名字',
            hintText: '留空则显示设备自报名',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok == null) return;
    final store = await _store();
    await store.renamePaired(e.deviceId, ok);
    await _load();
  }

  Future<void> _remove(PairedEndpoint e) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这台设备？'),
        content: Text('将移除「${e.displayName}」的配对信息。'
            '重新连接需要再次扫码配对。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (yes != true) return;
    final store = await _store();
    await store.removePaired(e.deviceId);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已删除「${e.displayName}」')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = _loading
        ? const Center(child: LinearProgressIndicator())
        : _endpoints.isEmpty
            ? _emptyState()
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final e in _endpoints) _deviceCard(e, scheme),
                ],
              );

    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的设备'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: '扫码配对新设备',
            onPressed: () => context.push('/remote/pair-qr'),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.devices_other,
                  size: 56, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              const Text('还没有保存的设备'),
              const SizedBox(height: 6),
              Text(
                '扫码配对后，设备会保存在这里，之后点一下即可连接。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => context.push('/remote/pair-qr'),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码配对'),
              ),
            ],
          ),
        ),
      );

  Widget _deviceCard(PairedEndpoint e, ColorScheme scheme) {
    final isCurrent = e.deviceId == _selectedId;
    return Card(
      color: isCurrent ? scheme.primaryContainer : null,
      child: ListTile(
        leading: Icon(
          isCurrent ? Icons.link : Icons.link_off,
          color: isCurrent ? scheme.primary : scheme.outline,
        ),
        title: Row(
          children: [
            Expanded(child: Text(e.displayName)),
            if (isCurrent)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('当前',
                    style:
                        TextStyle(fontSize: 11, color: scheme.onPrimary)),
              ),
          ],
        ),
        subtitle: Text(
          '${e.deviceId}\n'
          '配对于 ${_p(e.pairedAt.year)}-${_p(e.pairedAt.month)}-${_p(e.pairedAt.day)}'
          ' · ${formatLastConnected(e.lastConnectedAt, DateTime.now())}',
        ),
        isThreeLine: true,
        onTap: () => _connect(e),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'rename') await _rename(e);
            if (v == 'remove') await _remove(e);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('改备注名')),
            PopupMenuItem(value: 'remove', child: Text('删除')),
          ],
        ),
      ),
    );
  }
}
