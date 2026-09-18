import 'package:flutter/material.dart';

import '../../core/widgets/section_scaffold.dart';
import '../guard/guard_screen.dart';
import '../sounds/sound_library_screen.dart';
import '../tasks/task_list_screen.dart';

/// 「自动化」分组页（新 IA）：本机自动化的三要素——任务定义、音源素材、声音守卫。
///
/// 原「任务 / 音源 / 守卫」三个底部 TAB 合并为一个分组 + 三个二级 TAB：
/// 三者本就是同一条流水线（**守卫**监听声音 → 命中**任务** → 播放**音源**），
/// 放在一起比分散在底部导航更贴合心智模型，也让底部导航从 6 项降到 5 项。
class LocalSection extends StatelessWidget {
  const LocalSection({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  Widget build(BuildContext context) {
    return SectionScaffold(
      title: '自动化',
      initialIndex: initialIndex,
      tabs: [
        SectionTabSpec(
          label: '任务',
          icon: Icons.schedule,
          builder: (_) => const TaskListScreen(embedded: true),
        ),
        SectionTabSpec(
          label: '音源',
          icon: Icons.library_music,
          builder: (_) => const SoundLibraryScreen(embedded: true),
        ),
        SectionTabSpec(
          label: '守卫',
          icon: Icons.mic,
          builder: (_) => const GuardScreen(embedded: true),
        ),
      ],
    );
  }
}
