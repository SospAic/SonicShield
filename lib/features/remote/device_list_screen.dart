import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/device_group.dart';
import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';
import '../../core/theme.dart';

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
  List<DeviceGroup> _groups = const [];
  final Set<String> _checkedIds = <String>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<RemoteStore> _store() async =>
      RemoteStore(await SharedPreferences.getInstance());

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    final groups = DeviceGroupStore(prefs);
    if (!mounted) return;
    setState(() {
      _endpoints = store.paired();
      _selectedId = store.selectedEndpointId;
      _groups = groups.groups();
      _loading = false;
    });
  }

  /// 打开扫码配对页，**返回后重新载入**设备列表。
  ///
  /// P2-13：本页在 `IndexedStack` 中会被保留，`initState` 只跑一次；扫码成功
  /// 写盘后返回若不显式 `_load()`，列表会停留在配对前的快照（新设备看不到）。
  Future<void> _openPairing() async {
    await context.push('/remote/pair-qr');
    if (mounted) await _load();
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
        content: Text('将移除「${e.displayName}」的配对信息，并立即终止它名下的'
            '在途作业（指令组 / 通话）。重新连接需要再次扫码配对。\n\n'
            '⚠️ 撤销强度说明（P1-01）：所有控制端共用同一个配对码；'
            '若该码曾被泄露，仅删除设备不足以阻止伪造发送方。'
            '需要彻底失效时，请到「扫码配对」页使用「重置配对码」。'),
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
    // P1：撤销授权只删列表**不够**（`RemoteStore.removePaired` 自己的注释也在
    // 说这件事）。必须先踢出配对表（让它的后续命令立刻被准入拒掉），
    // **再**清掉它名下已经在跑的在途作业（指令组 / 通话）——
    // 顺序不能反：反了就会出现"在途已停，但窗口期内它又下发了一条新命令"。
    await RcEndpointService.instance.onPeerRevoked(e.deviceId);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已删除「${e.displayName}」')));
  }

  // ---------------- 设备组（Q6.B：建组 / 删组 / 组内群发 Ping） ----------------

  Future<void> _createGroup() async {
    if (_checkedIds.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先勾选要入组的设备')));
      return;
    }
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('建组（${_checkedIds.length} 台设备）'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: '给这批设备起个组名',
            hintText: '如：一楼展厅、设备间',
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
    if (name == null) return;
    // 判定在纯函数里（可锁），这里只执行其结论。
    final err = validateGroupName(name);
    if (err.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await DeviceGroupStore(prefs).save(DeviceGroup(
      id: DeviceGroupStore.newId(),
      name: name.trim(),
      memberIds: _checkedIds.toList(),
    ));
    setState(_checkedIds.clear);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已创建设备组「${name.trim()}」')));
  }

  Future<void> _deleteGroup(DeviceGroup g) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个设备组？'),
        content: Text('将移除分组「${g.name}」（组内 ${g.memberIds.length} 台）。'
            '不影响设备本身的配对关系。'),
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
    final prefs = await SharedPreferences.getInstance();
    await DeviceGroupStore(prefs).delete(g.id);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已删除分组「${g.name}」')));
  }

  Future<void> _groupPing(DeviceGroup g) async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    // 目标 = 组名单 ∩ 当前配对表（判定在纯函数里）；组名单本身不可信。
    final targets = resolveGroupTargets(g, store.paired());
    if (!mounted) return;
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('组「${g.name}」没有可用设备（成员可能已全部解配对）')));
      return;
    }
    final byId = {for (final e in store.paired()) e.deviceId: e};
    final failed = <String>[];
    for (final id in targets) {
      final ok = await RcEndpointService.instance
          .sendTo(byId[id]!, RcMessage.now(RcCmd.ping), store);
      if (!ok) failed.add(byId[id]!.displayName);
    }
    if (!mounted) return;
    final okCount = targets.length - failed.length;
    if (failed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '「${g.name}」群发 Ping 完成：已发 ${targets.length} 台 / 失败 0 台')));
      return;
    }
    // 失败必须点名（不许静默）：弹窗逐行列出，比一闪而过的 SnackBar 稳。
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「${g.name}」群发 Ping 汇总'),
        content: Text('已发 $okCount 台 / 失败 ${failed.length} 台：\n'
            '${failed.map((n) => '· $n').join('\n')}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = _loading
        ? const Center(child: LinearProgressIndicator())
        : _endpoints.isEmpty
            ? _emptyState()
            : ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  _groupSection(scheme),
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
            onPressed: _openPairing,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
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
                onPressed: _openPairing,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码配对'),
              ),
            ],
          ),
        ),
      );

  Widget _groupSection(ColorScheme scheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('设备组',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton.icon(
                  onPressed: _checkedIds.isEmpty ? null : _createGroup,
                  icon: const Icon(Icons.create_new_folder_outlined,
                      size: 18),
                  label: Text(_checkedIds.isEmpty
                      ? '建组'
                      : '建组（已选 ${_checkedIds.length} 台）'),
                ),
              ],
            ),
            if (_groups.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.sm, bottom: AppSpacing.sm),
                child: Text(
                  '还没有设备组：勾选下面的设备，再点「建组」。',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.outline),
                ),
              )
            else
              for (final g in _groups)
                ListTile(
                  contentPadding: const EdgeInsets.only(left: AppSpacing.sm),
                  leading: const Icon(Icons.devices_other),
                  title: Text(g.name),
                  subtitle: Text('${g.memberIds.length} 台设备'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '组内群发 Ping',
                        icon: const Icon(Icons.notifications_active_outlined),
                        onPressed: () => _groupPing(g),
                      ),
                      IconButton(
                        tooltip: '删除组',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteGroup(g),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

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
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('当前',
                    style: AppText.labelSmall.copyWith(color: scheme.onPrimary)),
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 勾选 = 只用于「建组」的临时选择，与「当前目标」（卡片本体
            // 点击）互不干扰：勾选不改选择状态、不写连接时间。
            Checkbox(
              value: _checkedIds.contains(e.deviceId),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _checkedIds.add(e.deviceId);
                } else {
                  _checkedIds.remove(e.deviceId);
                }
              }),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'rename') await _rename(e);
                if (v == 'remove') await _remove(e);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('改备注名')),
                PopupMenuItem(value: 'remove', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
