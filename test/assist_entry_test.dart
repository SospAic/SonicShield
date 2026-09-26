import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P0-1 根因 a 回归锁：协助会话入口必须是**可见文字**。
///
/// 缺陷形状：入口此前只有 AppBar 上的 4 个纯图标 `IconButton`，说明只写在
/// `tooltip` 里 —— 移动端 tooltip 仅在**长按**时出现，全应用没有任何可见文字
/// 提到"临时协助"。使用者反馈"本机根本没有显示临时码"，实际连入口都没看见。
///
/// 这里用源码契约锁住"文字入口存在"，理由与 `endpoint_script_step_perm_test`
/// 的 runner 接线锁一致：这是**布局意图**，纯单测渲染 [RemoteSection] 需要
/// 路由 + Provider + SharedPreferences 三套环境（成本远高于收益），而意图本身
/// 可以用"目标文案 + 目标路由必须成对出现"精确锁定。
///
/// 变异证伪点：把文字入口改回 `IconButton`（只留 tooltip）→ 红。
void main() {
  final src =
      File('lib/features/remote/remote_section.dart').readAsStringSync();

  test('AE-01 「我的设备」Tab 有可见文字的协助会话入口', () {
    expect(src, contains("Text('临时协助会话（生成临时码）')"),
        reason: '必须有可见文字说明"临时协助"，不能只靠长按 tooltip');
    expect(src, contains("Text('接入协助会话')"));
  });

  test('AE-02 文字入口指向与 AppBar 快捷图标相同的路由', () {
    expect(src, contains("context.push('/remote/assist')"));
    expect(src, contains("context.push('/remote/assist/join')"));
    // AppBar 图标作为快捷方式保留。
    expect(src, contains('Icons.support_agent'));
    expect(src, contains('Icons.login'));
  });

  test('AE-03 入口挂在「我的设备」Tab（不能只留在 AppBar）', () {
    // 设备列表必须与文字入口同处一个 Tab 子树。
    expect(src, contains('DeviceListScreen(embedded: true)'));
    expect(src, contains("label: '我的设备'"));
  });
}
