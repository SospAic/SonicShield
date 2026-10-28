import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 数字输入框 + 上下微调键。
///
/// 为什么不是滑块、也不是纯步进器：
/// - **滑块**在手机上的硬伤：手指挡住滑块，松手才发现差 3 档；大跨度
///   （1 → 120s）要么拖不准、要么来回拖半天。
/// - **纯步进器**：从 1 调到 120 要点 119 次。
/// - **输入框 + 上下键**把两种意图分开 —— 想跳到某个值就输入（弹数字键盘，
///   一次触达）；想微调一格就点上/下（一次一档）。
///
/// 交互契约（每一条都对应踩过的坑）：
/// - **输入中不夹取**：用户想输 `30` 时先敲的 `3` 若被立刻夹到下限，光标会跳、
///   数字会被吞 ⇒ 只在 `onSubmitted` / 失焦时校验回写。
/// - **非法输入不静默**：空串或非数字 ⇒ 回落到上一次合法值并回填，不留空框
///   （项目红线：失败必须可见，见 `silent_failure_locks_test`）。
/// - **越界夹取并回填**：提交时 `clamp(min, max)`，并把真实生效值写回输入框 ——
///   用户能看见"被改成了多少"，而不是以为输入成功。
/// - 上下键一次一档，到边界 `onTap = null` **自动置灰**，不做"点了没反应"。
///
/// 值域是**整数**：小数区间（如音量 0–1）由调用方乘 `scale`（×100）后传入，
/// 让用户敲 `30` 而不是 `0.3`。
class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.fieldKey,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.keyPrefix,
    this.suffix,
    this.width = 78,
  });

  /// `TextField` 自身的 key（测试与无障碍定位用）。
  final Key fieldKey;

  /// 上下键 key 前缀：`<prefix>_up` / `<prefix>_down`。
  final String? keyPrefix;

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final String? suffix;
  final double width;

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _c =
      TextEditingController(text: '${widget.value}');
  late final FocusNode _f = FocusNode();

  @override
  void initState() {
    super.initState();
    _f.addListener(() {
      if (!_f.hasFocus) _commit(_c.text);
    });
  }

  @override
  void didUpdateWidget(covariant NumberField old) {
    super.didUpdateWidget(old);
    // 外部改值（上/下键、恢复默认、另一端顶过来）时同步显示；
    // 但**正在输入**时不覆盖用户敲到一半的内容。
    if (!_f.hasFocus && widget.value != old.value) {
      _c.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  void _commit(String raw) {
    final parsed = int.tryParse(raw.trim());
    final next = (parsed ?? widget.value).clamp(widget.min, widget.max);
    if (_c.text != '$next') _c.text = '$next';
    if (next != widget.value) widget.onChanged(next);
  }

  void _nudge(int dir) {
    final next = (widget.value + dir).clamp(widget.min, widget.max);
    if (next == widget.value) return;
    HapticFeedback.selectionClick();
    _c.text = '$next';
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.width,
          child: TextField(
            key: widget.fieldKey,
            controller: _c,
            focusNode: _f,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              border: const OutlineInputBorder(),
              suffixText: widget.suffix,
            ),
            onSubmitted: _commit,
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SpinArrow(
              key: widget.keyPrefix == null
                  ? null
                  : ValueKey<String>('${widget.keyPrefix}_up'),
              icon: Icons.keyboard_arrow_up,
              tooltip: '增大',
              onTap: widget.value < widget.max ? () => _nudge(1) : null,
            ),
            _SpinArrow(
              key: widget.keyPrefix == null
                  ? null
                  : ValueKey<String>('${widget.keyPrefix}_down'),
              icon: Icons.keyboard_arrow_down,
              tooltip: '减小',
              onTap: widget.value > widget.min ? () => _nudge(-1) : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// 上下键：32×20 小箭头，禁用态置灰（不做"点了没反应"）。
class _SpinArrow extends StatelessWidget {
  const _SpinArrow({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 32,
          height: 20,
          child: Icon(
            icon,
            size: 18,
            color: onTap != null
                ? c.onSurfaceVariant
                : c.onSurface.withValues(alpha: 0.25),
          ),
        ),
      ),
    );
  }
}
