import 'package:flutter/material.dart';

import 'ptt_tab.dart';

/// 对讲机独立页（/remote/ptt）。
///
/// 对讲是「按住说话」的持续按压交互，塞进二级 TAB 会与横滑切换手势冲突，
/// 因此从「通话」子页以整页方式进入——与微信/对讲机类应用的交互一致。
class PttScreen extends StatelessWidget {
  const PttScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('对讲机')),
      body: const PttTab(),
    );
  }
}
