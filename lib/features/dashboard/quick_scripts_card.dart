import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/rc_script.dart';
import '../../remote/remote_store.dart';

/// 首页快捷指令组卡（v1.3）：展示收藏的指令组模板，一键发往第一配对端点。
/// 离线时自动进入 outbox，端点上线后冲刷（docs/14 §4）。
class QuickScriptsCard extends ConsumerStatefulWidget {
  const QuickScriptsCard({super.key});

  @override
  ConsumerState<QuickScriptsCard> createState() => QuickScriptsCardState();
}

class QuickScriptsCardState extends ConsumerState<QuickScriptsCard> {
  List<SavedScript> _saved = const [];
  String _firstEndpoint = '';

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
      _saved = store.savedScripts();
      final paired = store.paired();
      _firstEndpoint = paired.isEmpty ? '' : paired.first.deviceId;
    });
  }

  Future<void> _send(SavedScript s) async {
    if (_firstEndpoint.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    final paired = store.paired();
    final endpoint = paired.firstWhere((p) => p.deviceId == _firstEndpoint);
    final script = RcScript.fromJson(s.payload);
    final ok = await RcEndpointService.instance.sendTo(
        endpoint, RcMessage.now(RcCmd.scriptRun, script.toJson()), store);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              ok ? '「${script.name}」已发送，端点立即执行' : '端点离线：已加入待发队列，上线后自动补发')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_saved.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text('快捷指令组', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            for (final s in _saved.take(3))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(s.name),
                subtitle: Text(
                    '目标：${_firstEndpoint.isEmpty ? '未配对端点' : _firstEndpoint}',
                    style: const TextStyle(fontSize: 11)),
                trailing: FilledButton.tonal(
                  onPressed: _firstEndpoint.isEmpty ? null : () => _send(s),
                  child: const Text('执行'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
