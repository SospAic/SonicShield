import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../remote/assist.dart';
import '../../remote/assist_host.dart';

/// 端点侧「临时协助会话」页（docs/18 §4.4 / S2）。
///
/// 这是**唯一**能创建协助会话的入口（C1：会话只能端点侧发起）。
/// 页面按会话状态机分三段渲染：
///
/// | 状态 | 内容 |
/// |---|---|
/// | 无会话 | 说明 + 「生成临时码」（唯一入口按钮） |
/// | 等待接入 | 大号临时码 + 访问密码 + 倒计时 + 失败计数 + 取消 |
/// | 已接入 | 控制端名 + 倒计时 + 7 个权限开关（默认全关）+ 终止 |
///
/// ## 合规硬边界（docs/08 红线）
/// - 临时码**只在端点屏幕上生成并显示**，必须由使用者主动口述给控制端 ——
///   与「物理在场扫码」等价，构成明示同意；
/// - 页面顶部常驻提示，不存在"隐蔽协助"形态（C2）；
/// - 权限开关**默认全关**，逐项显式开启（C5）；
/// - 倒计时到期自动终止，凭据只存内存不落盘（C4）。
class AssistHostScreen extends StatefulWidget {
  const AssistHostScreen({super.key});

  @override
  State<AssistHostScreen> createState() => _AssistHostScreenState();
}

class _AssistHostScreenState extends State<AssistHostScreen> {
  final _host = RcAssistHost.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('临时协助会话')),
      body: StreamBuilder<AssistSession?>(
        stream: _host.changes,
        initialData: _host.session,
        builder: (context, snap) {
          final s = snap.data;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _banner(context),
              const SizedBox(height: 12),
              if (s == null) ...[
                _intro(context),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.pin),
                  label: const Text('生成临时码'),
                  onPressed: _start,
                ),
              ] else ...[
                if (s.phase == AssistPhase.active)
                  _activeCard(context, s)
                else
                  _waitingCard(context, s),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('终止会话'),
                  onPressed: () => _host.close(reason: 'local'),
                ),
              ],
              const SizedBox(height: 16),
              _footnote(context),
            ],
          );
        },
      ),
    );
  }

  // ---------------- 分段 ----------------

  Widget _banner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = _host.session != null;
    return Card(
      color: live ? scheme.errorContainer : scheme.surfaceContainerHighest,
      child: ListTile(
        leading: Icon(live ? Icons.shield_moon : Icons.verified_user_outlined,
            color: live ? scheme.onErrorContainer : scheme.onSurfaceVariant),
        title: Text(live ? '协助会话进行中' : '本机未被任何人控制',
            style: TextStyle(
                color: live ? scheme.onErrorContainer : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600)),
        subtitle: Text(
          live
              ? '控制端的每一步操作都会写入审计日志；你可随时终止。'
              : '协助会话只能由你在本机发起，无法被远程唤醒。',
          style: TextStyle(
              color: live ? scheme.onErrorContainer : scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('如何协助他人',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('1. 在本机点击「生成临时码」，屏幕会显示 9 位临时码与 8 位访问密码；\n'
                '2. 把这两个值口述给你信任的人（对方在「远程 → 临时协助 → 接入」输入）；\n'
                '3. 对方接入后，逐项开启你允许的能力；不需要时点「终止会话」。'),
            const SizedBox(height: 12),
            Text(
              '访问密码是真正的安全边界：临时码只是"门牌号"，'
              '只拿到临时码的人算不出会话主题，也无法接入。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _waitingCard(BuildContext context, AssistSession s) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text('请把下面两个值口述给对方'),
            const SizedBox(height: 16),
            _codeBlock(context, '临时码', _group(s.code, 3), large: true),
            const SizedBox(height: 16),
            _codeBlock(context, '访问密码', _group(s.password, 4), large: true),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.timer_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Text('剩余 ${_mmss(s.remaining)} 后自动失效',
                    style: TextStyle(color: scheme.primary)),
              ],
            ),
            if (s.failures > 0) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: scheme.error, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '已拒绝 ${s.failures} 次密码错误的接入尝试'
                      '（连续 ${RcAssist.maxFailures} 次将作废本场会话）',
                      style: TextStyle(color: scheme.error, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('复制临时码 + 密码'),
              onPressed: () => _copy('${s.code} ${s.password}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _activeCard(BuildContext context, AssistSession s) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.support_agent,
                      color: scheme.onPrimaryContainer),
                ),
                const SizedBox(height: 10),
                Text('正在被「${s.ctrlName}」协助',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text('剩余 ${_mmss(s.remaining)}',
                    style: TextStyle(color: scheme.primary)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text('允许对方做什么（默认全部不允许）'),
              ),
              for (final e in AssistPerms.labels.entries)
                SwitchListTile(
                  dense: true,
                  title: Text(e.value),
                  subtitle: _permHint(e.key),
                  value: s.perms.flag(e.key),
                  onChanged: (v) => _host.grant(s.perms.withFlag(e.key, v)),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
                child: Text(
                  '关闭某项会立即生效：对方再发该类命令会被拒绝并记入审计。'
                  '「录音取证」不在可授权范围内，协助会话下一律拒绝。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _footnote(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          '安全说明：会话密钥由「临时码 + 访问密码」经 HKDF-SHA256 派生，'
          'MQTT 服务器（中继）只见密文；会话一次性、最长 10 分钟、'
          '凭据仅存内存。连续 ${RcAssist.maxFailures} 次密码错误会立即作废会话。',
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).colorScheme.outline),
        ),
      ),
    );
  }

  // ---------------- 交互 ----------------

  Future<void> _start() async {
    final scaffold = ScaffoldMessenger.of(context);
    try {
      await _host.start();
    } on Object catch (e) {
      scaffold.showSnackBar(SnackBar(content: Text('生成失败：$e')));
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制')));
  }

  // ---------------- 展示工具 ----------------

  Widget _codeBlock(BuildContext context, String label, String value,
      {bool large = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: scheme.outline)),
        const SizedBox(height: 4),
        SelectableText(
          value,
          style: TextStyle(
            fontSize: large ? 32 : 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 6,
            fontFamily: 'monospace',
            color: scheme.primary,
          ),
        ),
      ],
    );
  }

  /// 等宽 + 分组显示，降低口述误读率（docs/18 §10.3）。
  static String _group(String s, int n) {
    final out = <String>[];
    for (var i = 0; i < s.length; i += n) {
      out.add(s.substring(i, (i + n).clamp(0, s.length)));
    }
    return out.join(' ');
  }

  static String _mmss(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  static Widget? _permHint(String key) => switch (key) {
        'media' => const Text('播放本机音源', style: TextStyle(fontSize: 12)),
        'tts' => const Text('文字转语音喊话', style: TextStyle(fontSize: 12)),
        'vibrate' => const Text('震动提醒', style: TextStyle(fontSize: 12)),
        'volume' => const Text('调整媒体/闹钟音量', style: TextStyle(fontSize: 12)),
        'location' => const Text('回传本机位置（敏感）', style: TextStyle(fontSize: 12)),
        'video' => const Text('摄像头视频通话与拍照（敏感）',
            style: TextStyle(fontSize: 12)),
        'script' => const Text('执行指令组、增删改任务与守卫开关',
            style: TextStyle(fontSize: 12)),
        _ => null,
      };
}
