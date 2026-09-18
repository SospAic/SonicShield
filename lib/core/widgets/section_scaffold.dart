import 'package:flutter/material.dart';

/// 分组页骨架：把原先的多个顶级页面聚合到一个底部 TAB 之下。
///
/// 结构：`AppBar（标题 + 操作）` + `TabBar`（二级 TAB） + `TabBarView`。
///
/// 为什么用二级 TAB 而不是继续加底部 TAB：Material 3 底部导航建议 3–5 项，
/// 超过后触达率与可辨识度都会下降；把语义相近的功能收进同一分组，
/// 既保持底部导航精简，又不牺牲功能可达性（Gmail / Google Drive 同构）。
class SectionTabSpec {
  const SectionTabSpec({
    required this.label,
    required this.builder,
    this.icon,
  });

  final String label;
  final WidgetBuilder builder;

  /// 可选：仅用于语义化/无障碍提示，TabBar 本身不渲染图标以保持紧凑。
  final IconData? icon;
}

class SectionScaffold extends StatefulWidget {
  const SectionScaffold({
    super.key,
    required this.title,
    required this.tabs,
    this.actions = const [],
    this.initialIndex = 0,
  });

  final String title;
  final List<SectionTabSpec> tabs;
  final List<Widget> actions;
  final int initialIndex;

  @override
  State<SectionScaffold> createState() => _SectionScaffoldState();
}

class _SectionScaffoldState extends State<SectionScaffold>
    with SingleTickerProviderStateMixin {
  late final TabController _ctrl = TabController(
    length: widget.tabs.length,
    vsync: this,
    initialIndex:
        widget.initialIndex.clamp(0, widget.tabs.length - 1).toInt(),
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: widget.actions,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TabBar(
              controller: _ctrl,
              isScrollable: widget.tabs.length > 3,
              tabAlignment:
                  widget.tabs.length > 3 ? TabAlignment.start : TabAlignment.fill,
              indicatorColor: scheme.primary,
              tabs: [
                for (final t in widget.tabs)
                  Tab(
                    height: 44,
                    child: Text(t.label,
                        semanticsLabel: t.icon == null ? null : t.label),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _ctrl,
        children: [for (final t in widget.tabs) t.builder(context)],
      ),
    );
  }
}
