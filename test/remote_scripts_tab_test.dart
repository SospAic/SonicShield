import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_scripts_tab.dart';
import 'package:sonic_shield/remote/protocol.dart';

/// 「指令组执行进度」的**用户可见后果**锁（BUG-057 的兄弟缺陷 `rc.script` 无消费者）。
///
/// 源码契约锁（`test/script_progress_test.dart` SP-08…SP-10）只能证明
/// **代码里引用了事件**；本文件证明**用户真的看得到**：
/// 往事件流里灌一条 `rc.script`，界面上必须出现进度文案。
///
/// 注入点：[RemoteScriptsTab.events]（默认走端点服务广播流）。
void main() {
  /// 一条收藏的指令组模板（3 步）。
  const scriptId = 'sc-1';
  final saved = jsonEncode([
    {
      'id': 'saved-1',
      'name': '回家提醒',
      'savedAt': 1700000000000,
      'payload': {
        'scriptId': scriptId,
        'name': '回家提醒',
        'fromName': '我',
        'sentAt': 1700000000000,
        'steps': [
          {'kind': 'tts', 'text': '到家了', 'volume': 0.8},
          {'kind': 'delay', 'seconds': 2},
          {'kind': 'notify', 'title': '已到家'},
        ],
      },
    }
  ]);

  late StreamController<Map<String, dynamic>> bus;

  setUp(() {
    SharedPreferences.setMockInitialValues({'rc_scripts': saved});
    bus = StreamController<Map<String, dynamic>>.broadcast();
  });

  tearDown(() async => bus.close());

  /// 推进固定帧数。
  ///
  /// ⚠️ **不能用 `pumpAndSettle`**：进度卡里是 `CircularProgressIndicator`，
  /// 它是**无限动画**，`pumpAndSettle` 会一直等它静止 → 超时（本文件最初就是这么挂的：
  /// RS-01/02/03 各挂 20–60s，而没进度卡的 RS-04 反而通过）。
  /// 这与"测试视口是隐式契约"是同一类问题。
  ///
  /// ⚠️ Dart 的**局部函数不提升**：本函数必须声明在调用它的 [pump] 之前。
  Future<void> frames(WidgetTester tester, [int n = 3]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> pump(WidgetTester tester) async {
    // 视口约定：ListView 屏幕外条目**不构建**，控件类断言会悄悄依赖"都在首屏内"。
    final view = tester.view;
    view.physicalSize = const Size(1200, 4000);
    view.devicePixelRatio = 1.0;
    addTearDown(view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: RemoteScriptsTab(events: bus.stream)),
    ));
    await frames(tester);
  }

  void emit(String type, Map<String, dynamic> payload) => bus.add({
        'type': type,
        'payload': payload,
      });

  testWidgets('RS-01 收到 rc.script(running) → 界面出现「第 n/N 步」', (tester) async {
    await pump(tester);
    expect(find.text('回家提醒'), findsOneWidget, reason: '收藏模板应先列出来');

    emit(RcEvt.scriptState,
        {'scriptId': scriptId, 'state': 'running', 'stepIndex': 1});
    await frames(tester);

    // 总步数来自本机模板（3 步），stepIndex 0-based → 第 2/3 步
    expect(find.textContaining('执行中 · 第 2/3 步'), findsWidgets,
        reason: '用户看不到进度 = 这个事件仍然没有消费者');
    // 两条**不同**的用户可见面：顶部进度卡 + 该模板自己的副标题。
    // 只断言前者会被"横幅显示但列表项不显示"的实现骗过（注入变异时实测如此）。
    expect(find.textContaining('已收藏 · 我 · 执行中 · 第 2/3 步'), findsOneWidget,
        reason: '模板副标题也必须带进度 —— 否则进度只挂在横幅上，'
            '同时跑多条指令组时看不出是哪一条');
  });

  testWidgets('RS-02 收到 done → 进度变成「已完成」且不再显示"执行中"', (tester) async {
    await pump(tester);
    emit(RcEvt.scriptState,
        {'scriptId': scriptId, 'state': 'running', 'stepIndex': 0});
    await frames(tester);
    expect(find.textContaining('执行中'), findsWidgets);

    emit(RcEvt.scriptState, {'scriptId': scriptId, 'state': 'done'});
    await frames(tester);

    expect(find.textContaining('已完成'), findsWidgets);
    expect(find.textContaining('执行中'), findsNothing,
        reason: '终止态之后不得残留"执行中"');
  });

  testWidgets('RS-03 未知 state → 界面**什么都不做**（不谎报完成 / 不永远转圈）',
      (tester) async {
    await pump(tester);
    emit(RcEvt.scriptState,
        {'scriptId': scriptId, 'state': 'running', 'stepIndex': 0});
    await frames(tester);
    expect(find.textContaining('执行中 · 第 1/3 步'), findsWidgets);

    // 端点将来新增的状态：本端不认识
    emit(RcEvt.scriptState, {'scriptId': scriptId, 'state': 'paused'});
    await frames(tester);

    expect(find.textContaining('执行中 · 第 1/3 步'), findsWidgets,
        reason: '未知状态必须保留上一次的已知进度');
    expect(find.textContaining('已完成'), findsNothing);
    expect(find.textContaining('已终止'), findsNothing);
  });

  testWidgets('RS-04 其他事件不得被误当成进度', (tester) async {
    await pump(tester);
    emit(RcEvt.exec, {'taskId': 't1', 'ok': true});
    emit(RcEvt.heartbeat, {});
    await frames(tester);

    expect(find.textContaining('执行中'), findsNothing);
    expect(find.textContaining('已完成'), findsNothing);
  });
}
