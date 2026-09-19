import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../remote/assist.dart';
import '../../remote/assist_join.dart';
import '../../remote/command_channel.dart';
import 'remote_console_tab.dart';

/// 控制端「接入协助会话」页（docs/18 S3）。
///
/// 流程：输入**临时码 + 访问密码**（由端点使用者口述）→ 握手 → 进入控制台。
/// 控制台**复用** [RemoteConsoleTab]（传入 [AssistChannel]），因此协助会话
/// 与已配对端点拥有完全相同的命令面板，不会出现两套会漂移的实现。
///
/// ## 合规与安全提示（页面上常驻）
/// - 临时码必须由**端点使用者主动告知**（等价于物理在场授权）；
/// - 权限由**端点**逐项放行，本端只能看到"已放行什么"，无法自行提权；
/// - 未授权命令即使发出也会被端点拒绝并记入其审计。
class AssistJoinScreen extends StatefulWidget {
  const AssistJoinScreen({super.key, this.client});

  /// 接入客户端；null = 生产单例。
  ///
  /// 与 [RemoteConsoleTab.channel] 同样的注入缝：单测需要**互不干扰**的实例
  /// （会话状态是纯内存的，共享单例会让用例之间互相污染），
  /// 且能注入假传输以便离线跑完整握手。
  final AssistJoinClient? client;

  @override
  State<AssistJoinScreen> createState() => _AssistJoinScreenState();
}

class _AssistJoinScreenState extends State<AssistJoinScreen> {
  late final AssistJoinClient _client =
      widget.client ?? AssistJoinClient.instance;
  final _codeCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();

  @override
  void dispose() {
    _codeCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AssistJoinInfo>(
      stream: _client.changes,
      initialData: _client.info,
      builder: (context, snap) {
        final info = snap.data!;
        if (info.active) return _console(info);
        return _form(info);
      },
    );
  }

  // ---------------- 接入表单 ----------------

  Widget _form(AssistJoinInfo info) {
    final scheme = Theme.of(context).colorScheme;
    final busy = info.busy;
    return Scaffold(
      appBar: AppBar(title: const Text('接入协助会话')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('输入端点提供的凭据',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _codeCtrl,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(9),
                    ],
                    style: const TextStyle(
                        fontSize: 24,
                        letterSpacing: 4,
                        fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      labelText: '临时码（9 位数字）',
                      hintText: '000 000 000',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pwCtrl,
                    enabled: !busy,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                      LengthLimitingTextInputFormatter(8),
                    ],
                    style: const TextStyle(
                        fontSize: 24,
                        letterSpacing: 4,
                        fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      labelText: '访问密码（8 位）',
                      hintText: 'ABCD EFGH',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (busy) ...[
                    Row(
                      children: [
                        const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Text('正在接入…（正在向端点发起握手）',
                            style: TextStyle(color: scheme.primary)),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (info.error != null && !busy) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline,
                            color: scheme.error, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(info.error!,
                              style: TextStyle(color: scheme.error)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.login),
                      label: Text(busy ? '接入中…' : '接入'),
                      onPressed: busy ? null : _join,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '安全说明：临时码是"门牌号"，访问密码才是真正的共享秘密 ——\n'
                '会话主题由两者共同派生，只拿到临时码的人既无法订阅也无法接入。\n'
                '接入后端点会常驻显示"正在被 X 协助"，你可执行的能力由端点逐项放行；\n'
                '未放行的命令会被端点拒绝并记入其审计日志。',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _join() async {
    final ok = await _client.join(_codeCtrl.text, _pwCtrl.text);
    if (!mounted || ok) return;
    final err = _client.info.error;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  // ---------------- 已接入：复用控制台 ----------------

  Widget _console(AssistJoinInfo info) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('协助会话 · ${info.epName}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '会话审计',
            onPressed: () => _showAudit(),
          ),
          IconButton(
            icon: const Icon(Icons.link_off),
            tooltip: '挂断',
            onPressed: () => _client.leave(),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: scheme.primaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.verified_user,
                    size: 18, color: scheme.onPrimaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '临时协助会话进行中 · 剩余 ${_mmss(info.remaining)}'
                    '${info.sessionId.isEmpty ? '' : ' · ${info.sessionId}'}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onPrimaryContainer),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RemoteConsoleTab(channel: AssistChannel(_client)),
          ),
        ],
      ),
    );
  }

  static String _mmss(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 会话审计面板（S4）：本会话的命令收发轨迹与端点拒绝原因。
  ///
  /// 存在的理由：未授权命令会被端点拒绝，若界面上不体现，使用者只会看到
  /// "点了没反应"（BUG-029 暴露过的同类问题）。把「发出 / 端点拒绝 / 原因」
  /// 摊开，使用者才能判断是该去端点开权限，还是命令本身有问题。
  void _showAudit() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _AuditSheet(client: _client),
    );
  }
}

/// 会话审计面板内容（实时跟随 [AssistJoinClient.auditChanges]）。
class _AuditSheet extends StatelessWidget {
  const _AuditSheet({required this.client});

  final AssistJoinClient client;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<void>(
      stream: client.auditChanges,
      builder: (context, _) {
        final log = client.auditLog;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('会话审计（本机记录）',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '端点侧同时落库到审计日志（source=assist）。'
                  '未放行的命令会被端点拒绝并在此显示原因。',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
                const SizedBox(height: 12),
                if (log.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('本会话尚无收发记录'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: log.length,
                      itemBuilder: (context, i) {
                        final e = log[log.length - 1 - i]; // 最新在上
                        final icon = e.outbound
                            ? Icons.north_east
                            : (e.ok ? Icons.south_west : Icons.block);
                        final color = e.ok ? scheme.primary : scheme.error;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(icon, size: 18, color: color),
                          title: Text(
                            '${e.outbound ? '发出' : '收到'} · ${e.type}',
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            '${_hms(e.at)}'
                            '${e.detail.isEmpty ? '' : ' · ${e.detail}'}',
                            style: TextStyle(
                                fontSize: 12,
                                color: e.ok ? scheme.outline : scheme.error),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _hms(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';
}

/// 协助会话的权限摘要（供「远程 → 设备」页在接入后展示）。
String assistPermSummary(AssistPerms perms) {
  final on = <String>[];
  for (final e in AssistPerms.labels.entries) {
    if (perms.flag(e.key)) on.add(e.value);
  }
  return on.isEmpty ? '未放行任何能力' : on.join('、');
}
