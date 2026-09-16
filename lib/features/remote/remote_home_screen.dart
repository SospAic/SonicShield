import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/remote_store.dart';
import 'ptt_tab.dart';
import 'remote_console_tab.dart';
import 'remote_scripts_tab.dart';

/// 远程中心（v1.6 重构）：4 个完整功能子页——
/// 控制台（完全控制）/ 指令组（宏）/ 对讲机 / 通话。
class RemoteHomeScreen extends StatefulWidget {
  const RemoteHomeScreen({super.key});

  @override
  State<RemoteHomeScreen> createState() => _RemoteHomeScreenState();
}

class _RemoteHomeScreenState extends State<RemoteHomeScreen> {
  int _tab = 0;

  static const _titles = ['控制台', '指令组', '对讲机', '通话'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('远程中心 · ${_titles[_tab]}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '模块开关 · 身份 · 代理 · 配对管理',
            onPressed: () => context.push('/remote/settings'),
          ),
        ],
      ),
      body: _body(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        height: 64,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.gamepad_outlined), label: '控制台'),
          NavigationDestination(icon: Icon(Icons.data_object), label: '指令组'),
          NavigationDestination(icon: Icon(Icons.mic), label: '对讲机'),
          NavigationDestination(icon: Icon(Icons.videocam), label: '通话'),
        ],
        onDestinationSelected: (i) => setState(() => _tab = i),
      ),
    );
  }

  Widget _body() {
    switch (_tab) {
      case 1:
        return const RemoteScriptsTab();
      case 2:
        return const PttTab();
      case 3:
        return const RemoteCallEntry();
      default:
        return const RemoteConsoleTab();
    }
  }
}

/// 通话 Tab：入口卡（跳转完整通话页）。
class RemoteCallEntry extends StatelessWidget {
  const RemoteCallEntry({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.videocam, size: 32),
            title: const Text('发起视频/语音通话'),
            subtitle: const Text('WebRTC P2P · DTLS-SRTP 加密 · 支持自动接通（守护场景）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/remote/call'),
          ),
        ),
        const SizedBox(height: 8),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '合规提示：视频通话仅限家人守护（老人/儿童看护）与本人设备。'
              '接通即亮屏，系统摄像头指示灯正常工作，不提供隐蔽模式。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}

/// 供远程页快速跳转使用的 store 助手。
Future<RemoteStore> loadRemoteStore() async =>
    RemoteStore(await SharedPreferences.getInstance());
