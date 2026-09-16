import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';

/// 指令组 Tab（v1.6）：收藏模板列表（一键发往选中端点/编辑/删除）
/// + 新建组装器入口。数据来自 RemoteStore.savedScripts。
class RemoteScriptsTab extends ConsumerStatefulWidget {
  const RemoteScriptsTab({super.key});

  @override
  ConsumerState<RemoteScriptsTab> createState() => _RemoteScriptsTabState();
}

class _RemoteScriptsTabState extends ConsumerState<RemoteScriptsTab> {
  List<PairedEndpoint> _endpoints = const [];
  String _selectedId = '';
  List<SavedScript> _saved = const [];

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
      _endpoints = store.paired();
      _saved = store.savedScripts();
      _selectedId = _endpoints.isEmpty
          ? ''
          : (_selectedId.isEmpty ? _endpoints.first.deviceId : _selectedId);
    });
  }

  Future<void> _send(SavedScript s) async {
    if (_selectedId.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择目标端点')));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    final ep = _endpoints.firstWhere((e) => e.deviceId == _selectedId);
    final ok = await RcEndpointService.instance
        .sendTo(ep, RcMessage.now(RcCmd.scriptRun, s.payload), store);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(ok ? '「${s.name}」已发送，端点立即执行（通知栏可终止）' : '端点离线：已入队，上线后自动补发')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('新建指令组'),
        onPressed: () async {
          if (_selectedId.isEmpty) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('请先完成端点配对')));
            return;
          }
          await context.push('/remote/script-builder/$_selectedId');
          await _load();
        },
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_endpoints.isNotEmpty)
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedId.isEmpty ? null : _selectedId,
                  decoration: const InputDecoration(
                      labelText: '发送目标端点', border: InputBorder.none),
                  items: [
                    for (final e in _endpoints)
                      DropdownMenuItem(value: e.deviceId, child: Text(e.name)),
                  ],
                  onChanged: (v) => setState(() => _selectedId = v ?? ''),
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (_saved.isEmpty)
            const Card(
                child: Padding(
                    padding: EdgeInsets.all(14),
                    child: Text('暂无收藏的指令组。点击右下角「新建指令组」组装动作与时延序列，'
                        '发送前可勾选「存为模板」。'))),
          for (final s in _saved)
            Card(
              child: ListTile(
                leading: const Icon(Icons.bolt),
                title: Text(s.name),
                subtitle: Text('已收藏 · ${s.payload['fromName'] ?? ''}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.tonal(
                        onPressed: () => _send(s), child: const Text('执行')),
                    IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final prefs = await SharedPreferences.getInstance();
                          await RemoteStore(prefs).deleteScript(s.id);
                          await _load();
                        }),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '指令组 = 动作 + 时延的有序序列（最多 50 步）。端点收到后立即执行，'
                '通知栏全程显示发送方与进度，可随时终止；全程审计留痕。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
