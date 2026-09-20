import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/section_scaffold.dart';
import 'device_list_screen.dart';
import 'remote_console_tab.dart';
import 'remote_scripts_tab.dart';
import 'remote_tasks_tab.dart';

/// 「远程」分组页（新 IA）：远程遥控中心。
///
/// 四个二级 TAB 按「**先选设备，再看它的状态，然后操作**」的信息层级排列：
/// 设备（实时控制台）/ 任务（端点任务管理）/ 指令组（宏）/ 通话（视频 + 对讲）。
///
/// 视频通话与对讲并入本页而非独立底部 TAB：两者都是「与某个已配对端点
/// 建立实时会话」，与遥控共享同一份配对表与在线状态，放在一起可复用
/// 设备选择上下文，也让底部导航保持在 5 项。
class RemoteSection extends StatelessWidget {
  const RemoteSection({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  Widget build(BuildContext context) {
    return SectionScaffold(
      title: '远程',
      initialIndex: initialIndex,
      actions: [
        IconButton(
          icon: const Icon(Icons.support_agent),
          tooltip: '临时协助会话（本机被协助 · 临时码）',
          onPressed: () => context.push('/remote/assist'),
        ),
        IconButton(
          icon: const Icon(Icons.login),
          tooltip: '接入协助会话（输入临时码 + 密码）',
          onPressed: () => context.push('/remote/assist/join'),
        ),
        IconButton(
          icon: const Icon(Icons.qr_code_scanner),
          tooltip: '扫码配对',
          onPressed: () => context.push('/remote/pair-qr'),
        ),
        IconButton(
          icon: const Icon(Icons.tune),
          tooltip: '模块开关 · 身份 · 代理 · 配对管理',
          onPressed: () => context.push('/remote/settings'),
        ),
      ],
      tabs: [
        SectionTabSpec(
          label: '我的设备',
          icon: Icons.devices,
          builder: (_) => const DeviceListScreen(embedded: true),
        ),
        SectionTabSpec(
          label: '控制台',
          icon: Icons.gamepad_outlined,
          builder: (_) => const RemoteConsoleTab(),
        ),
        SectionTabSpec(
          label: '任务',
          icon: Icons.checklist,
          builder: (_) => const RemoteTasksTab(),
        ),
        SectionTabSpec(
          label: '指令组',
          icon: Icons.data_object,
          builder: (_) => const RemoteScriptsTab(),
        ),
        SectionTabSpec(
          label: '通话',
          icon: Icons.videocam,
          builder: (_) => const RemoteCallEntry(),
        ),
      ],
    );
  }
}

/// 通话子页：发起视频/语音通话 + 对讲入口 + 合规提示。
class RemoteCallEntry extends StatelessWidget {
  const RemoteCallEntry({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.videocam, color: scheme.onPrimaryContainer),
            ),
            title: const Text('发起视频 / 语音通话'),
            subtitle: const Text('WebRTC P2P · DTLS-SRTP 加密 · 支持自动接通（家人守护场景）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/remote/call'),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.secondaryContainer,
              child: Icon(Icons.mic, color: scheme.onSecondaryContainer),
            ),
            title: const Text('对讲机'),
            subtitle: const Text('按住说话 · 端到端加密 · 端点自动播放并回执'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/remote/ptt'),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          color: scheme.surfaceContainerHighest,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '合规提示：视频通话与对讲仅限家人守护（老人/儿童看护）与本人设备。'
              '接通即亮屏，系统摄像头指示灯正常工作，不提供隐蔽模式。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}
