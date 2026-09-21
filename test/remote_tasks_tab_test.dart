import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_tasks_tab.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 远程「任务」子页的宿主测试。
///
/// 本页原先**无法宿主测试**：它直接依赖单例 `RcEndpointService.instance`，
/// 既不能注入事件源，也不能观察"发了什么命令"（对应 0% 覆盖率）。
/// 本轮按它两个兄弟页（`RemoteConsoleTab` / `RemoteScriptsTab`）的既有形状
/// 补上 [RcCommandChannel] 注入缝后即可驱动。
///
/// ⚠️ 全程**不要用 `pumpAndSettle`**：本页在 `_loading || _awaiting` 时渲染
/// `CircularProgressIndicator`（无限动画）→ `pumpAndSettle` 必然超时。
/// 统一用显式 `pump(duration)`。
class _FakeChannel implements RcCommandChannel {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _updates = StreamController<void>.broadcast();
  final sent = <RcMessage>[];

  /// `send` 的返回值：false 模拟"端点离线，命令入队未发出"。
  bool sendResult = true;

  @override
  String get label => '假端点';

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Stream<void> get updates => _updates.stream;

  @override
  bool get canSend => true;

  @override
  Future<bool> send(RcMessage msg) async {
    sent.add(msg);
    return sendResult;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await _updates.close();
  }

  /// 回灌一条端点事件（信封形状与 `RcEndpointService.events` 一致：
  /// 业务字段在 `payload` 内，见 BUG-023）。
  void emit(String type, Map<String, dynamic> payload) =>
      _events.add({'type': type, 'payload': payload});

  bool sentType(String type) => sent.any((m) => m.type == type);

  RcMessage lastOfType(String type) => sent.lastWhere((m) => m.type == type,
      orElse: () => throw StateError('未发送 $type'));

  int countOfType(String type) => sent.where((m) => m.type == type).length;
}

PairedEndpoint _ep(String id, String name) => PairedEndpoint(
    deviceId: id, name: name, secret: 's', pairedAt: DateTime.now());

/// 一条最小可渲染的端点任务线格式。
Map<String, dynamic> _task({
  String id = 't1',
  String name = '早间播报',
  bool enabled = true,
  int cooldownSec = 0,
  List<String> assetIds = const [],
}) =>
    {
      'id': id,
      'name': name,
      'enabled': enabled,
      'triggerType': 'dailyAt',
      'trigger': {
        'time': {'hour': 7, 'minute': 30}
      },
      'actionType': 'tts',
      'action': {'kind': 'tts', 'text': '早上好'},
      'cooldownSec': cooldownSec,
      'assetIds': assetIds,
    };

/// 挂载本页并把 `_load()/refresh()` 的异步尾巴跑干净。
Future<_FakeChannel> _pump(
  WidgetTester tester, {
  bool enabled = true,
  List<PairedEndpoint> endpoints = const [],
  String selected = '',
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = RemoteStore(await SharedPreferences.getInstance());
  for (final e in endpoints) {
    await store.addPaired(e);
  }
  if (enabled) await store.setEnabled(true);
  if (selected.isNotEmpty) await store.selectEndpoint(selected);

  final ch = _FakeChannel();
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(home: RemoteTasksTab(channel: ch)),
  ));
  await tester.pump(); // 让 _load() 的 setState 生效
  // refresh() 里有 2 秒兜底延迟（端点离线时不回执）—— 冲掉它，否则
  // `_loading` 恒真、转圈不停。
  await tester.pump(const Duration(seconds: 3));
  // 再回一条 status，把 `_awaiting` 也清掉，页面进入稳定态。
  ch.emit(RcEvt.status, {'pendingCount': 0, 'version': '1.8.0-alpha'});
  await tester.pump();
  return ch;
}

void main() {
  group('RTT 远程任务子页', () {
    testWidgets('RTT-01 未配对端点 → 空态引导（不是白屏，也不是空列表）', (tester) async {
      await _pump(tester);

      expect(find.text('尚未配对端点设备'), findsOneWidget);
      expect(find.text('去配对'), findsOneWidget);
      // 反例：不能渲染成"有端点但 0 条任务"。
      expect(find.textContaining('端点任务（'), findsNothing);
    });

    testWidgets('RTT-02 远程模块未开启 → 说明后果（收不到命令也收不到回执）', (tester) async {
      await _pump(tester, enabled: false, endpoints: [_ep('dev-a', 'A 机')]);

      expect(find.text('远程模块未开启'), findsOneWidget);
      expect(find.textContaining('收不到命令'), findsOneWidget);
      expect(find.text('去开启'), findsOneWidget);
    });

    testWidgets('RTT-03 已配对且已开启 → 主动拉取端点任务全貌与状态', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);

      expect(find.text('目标端点'), findsOneWidget);
      expect(find.text('新建端点任务'), findsOneWidget);
      expect(ch.sentType(RcCmd.taskList), isTrue,
          reason: '进页面就该拉列表，否则用户看到的是空列表而不是"还没拉"');
      expect(ch.sentType(RcCmd.statusGet), isTrue,
          reason: '摘要卡要显示待执行数与版本，必须同时拉 status');
    });

    testWidgets('RTT-04 收到 rc.tasks → 渲染任务名与触发/动作摘要', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);

      ch.emit(RcEvt.tasks, {
        'tasks': [_task()]
      });
      await tester.pump();

      expect(find.text('端点任务（1）'), findsOneWidget);
      expect(find.text('早间播报'), findsOneWidget);
      expect(find.textContaining('每天 07:30'), findsOneWidget);
      expect(find.textContaining('语音喊话 · 早上好'), findsOneWidget);
    });

    testWidgets('RTT-05 空任务列表 → 给出"怎么新建"的引导而不是空白', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);

      ch.emit(RcEvt.tasks, {'tasks': const <Map<String, dynamic>>[]});
      await tester.pump();

      expect(find.text('端点任务（0）'), findsOneWidget);
      expect(find.textContaining('端点暂无自动化任务'), findsOneWidget);
    });

    testWidgets('RTT-06 收到 rc.status → 摘要显示待执行数与端点版本', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);

      ch.emit(RcEvt.status, {'pendingCount': 3, 'version': '1.8.0-alpha'});
      await tester.pump();

      expect(find.textContaining('待执行 3 条'), findsOneWidget);
      expect(find.textContaining('版本 1.8.0-alpha'), findsOneWidget);
    });

    testWidgets('RTT-07 任务列表非空时显示冷却与音源池，冷却 0 显示"无"', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);

      ch.emit(RcEvt.tasks, {
        'tasks': [_task(cooldownSec: 3600, assetIds: ['a', 'b'])]
      });
      await tester.pump();

      expect(find.textContaining('冷却 1h'), findsOneWidget);
      expect(find.textContaining('音源池 2 条'), findsOneWidget);
    });

    testWidgets('RTT-08 切换开关 → 发送 task.toggle 且带上目标 enabled', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);
      ch.emit(RcEvt.tasks, {
        'tasks': [_task(enabled: true)]
      });
      await tester.pump();

      await tester.tap(find.byType(Switch));
      await tester.pump();

      final m = ch.lastOfType(RcCmd.taskToggle);
      expect(m.payload['taskId'], 't1');
      expect(m.payload['enabled'], false, reason: '关掉开关必须显式下发 false，不能只靠本地状态');
    });

    testWidgets('RTT-09 「跳过下一次」只在任务启用时出现，点击发 task.skipNext', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);
      ch.emit(RcEvt.tasks, {
        'tasks': [_task(enabled: false)]
      });
      await tester.pump();

      // 停用的任务没有"跳过下一次"的意义 —— 不应出现。
      expect(find.byTooltip('跳过下一次'), findsNothing);

      ch.emit(RcEvt.tasks, {
        'tasks': [_task(enabled: true)]
      });
      await tester.pump();
      expect(find.byTooltip('跳过下一次'), findsOneWidget);

      await tester.tap(find.byTooltip('跳过下一次'));
      await tester.pump();
      expect(ch.lastOfType(RcCmd.taskSkipNext).payload['taskId'], 't1');
    });

    testWidgets('RTT-10 删除走"确认 + 等回执"：确认后才发，且拿到 ack 才报成功', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);
      ch.emit(RcEvt.tasks, {
        'tasks': [_task()]
      });
      await tester.pump();

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(find.text('删除端点任务'), findsOneWidget);
      expect(find.textContaining('此操作不可撤销'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump();

      final del = ch.lastOfType(RcCmd.taskDelete);
      expect(del.payload['taskId'], 't1');

      // 回执到达前**不能**报成功（离线入队被误报成功是 docs/14 §2.1 的老问题）。
      expect(find.textContaining('已在端点删除'), findsNothing);

      ch.emit(RcEvt.ack, {'ok': true, 'for': del.id});
      await tester.pump();
      expect(find.textContaining('已在端点删除「早间播报」'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3)); // 冲掉 refresh 的兜底延迟
    });

    testWidgets('RTT-11 删除对话框点「取消」→ 一条命令都不发', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);
      ch.emit(RcEvt.tasks, {
        'tasks': [_task()]
      });
      await tester.pump();

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(ch.sentType(RcCmd.taskDelete), isFalse,
          reason: '取消必须真的不发 —— 否则"确认框"就是装饰');
    });

    testWidgets('RTT-12 立即执行发 task.runNow；未收到回执 → 明确告知"未执行"', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);
      ch.emit(RcEvt.tasks, {
        'tasks': [_task()]
      });
      await tester.pump();

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即执行'));
      await tester.pump();

      expect(ch.lastOfType(RcCmd.taskRunNow).payload['taskId'], 't1');

      // runNow 的超时是 50s；推进假时钟让它超时。
      await tester.pump(const Duration(seconds: 51));
      expect(find.textContaining('端点未执行「早间播报」'), findsOneWidget,
          reason: '拿不到回执必须说"没执行"，不能静默当作成功');
    });

    // ⚠️ 成功与失败拆成两条独立用例：SnackBar 是**排队**的，
    // 同一个 testWidgets 里连弹两条时，第二条要等第一条 4 秒后消失才出现，
    // 混在一起会得到"找不到文案"的假红。
    testWidgets('RTT-13 rc.exec 成功 → 提示执行成功', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);

      ch.emit(RcEvt.exec, {'ok': true, 'taskName': '早间播报'});
      await tester.pump();

      expect(find.textContaining('✓ 端点已执行「早间播报」'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // 冲掉 exec 触发的 refresh
    });

    testWidgets('RTT-13b rc.exec 失败 → 必须带上失败原因（不能只说"失败了"）', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);

      ch.emit(RcEvt.exec,
          {'ok': false, 'taskName': '早间播报', 'message': '麦克风被占用'});
      await tester.pump();

      expect(find.textContaining('✗ 端点执行失败：麦克风被占用'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('RTT-14 即时操作的无主回执（成功）→ 提示已执行，且不再一直转圈', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);

      ch.emit(RcEvt.ack, {'ok': true, 'for': ''});
      await tester.pump();

      expect(find.text('✓ 端点已执行'), findsOneWidget);
      // 回执到达即解除等待态 —— 否则刷新按钮会一直是个转圈。
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('RTT-14b 即时操作的无主回执（被拒）→ 明确说"拒绝或未执行"', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);

      ch.emit(RcEvt.ack, {'ok': false, 'for': ''});
      await tester.pump();

      expect(find.text('✗ 端点拒绝或未执行'), findsOneWidget);
    });

    testWidgets('RTT-15 命令未发出（端点离线）→ 说明"已入队"，不假装已生效', (tester) async {
      final ch = await _pump(tester, endpoints: [_ep('dev-a', 'A 机')]);
      ch.emit(RcEvt.tasks, {
        'tasks': [_task()]
      });
      await tester.pump();

      ch.sendResult = false;
      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(find.textContaining('端点离线：命令已入队'), findsOneWidget);
    });

    // ------------------------------------------------------------------
    // BUG-063 回归锁
    // ------------------------------------------------------------------

    testWidgets('RTT-16 跟随**共享选择**：设备列表选了 B，本页必须指向 B（BUG-063）',
        (tester) async {
      final ch = await _pump(
        tester,
        endpoints: [_ep('dev-a', 'A 机'), _ep('dev-b', 'B 机')],
        selected: 'dev-b',
      );

      // 摘要卡显示的是**当前操作对象**。
      expect(find.text('B 机'), findsWidgets,
          reason: '共享选择是 B，本页就该显示 B');
      expect(find.text('A 机'), findsNothing,
          reason: 'A 未被选中，闭合态下拉里不应出现 —— '
              '出现即说明本页回落到 endpoints.first，会静默操作错误的设备');
      expect(ch.sentType(RcCmd.taskList), isTrue);
    });

    testWidgets('RTT-17 共享选择指向已解配对的设备 → 回落第一条而不是空白（BUG-063 边界）',
        (tester) async {
      await _pump(
        tester,
        endpoints: [_ep('dev-a', 'A 机')],
        selected: 'dev-gone', // 共享选择是个已不存在的端点
      );

      expect(find.text('A 机'), findsWidgets,
          reason: '旧选择失效时必须回落，不能留空导致整页无操作对象');
    });
  });
}
