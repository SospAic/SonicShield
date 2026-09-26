import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_tasks_tab.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 远程「任务」子页的 R-5 / R-9 修复锁。
///
/// * **R-5**：本页对 `rc.tasks` 是**直接赋值**，不看 `peerId` ⇒ 多端点场景下
///   另一台的列表会整片覆盖本页，用户会在**错误的对象**上启停/删除。
/// * **R-9**：`sendTo` 返回 false 的原因不止一种，一律说"上线后自动执行"
///   会让"本机远程模块没开"的用户一直等一个永远等不到的补发。
///
/// ⚠️ 本页 `_loading || _awaiting` 时渲染 `CircularProgressIndicator`（无限动画）
/// → **不要用 `pumpAndSettle`**，用显式 `pump(duration)`。
class _FakeChannel implements RcCommandChannel {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _updates = StreamController<void>.broadcast();
  final sent = <RcMessage>[];

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

  void emit(String type, Map<String, dynamic> payload, {String peerId = ''}) =>
      _events.add({
        'type': type,
        'payload': payload,
        if (peerId.isNotEmpty) 'peerId': peerId,
      });
}

PairedEndpoint _ep(String id, String name) => PairedEndpoint(
    deviceId: id, name: name, secret: 's', pairedAt: DateTime.now());

Map<String, dynamic> _task({String id = 't1', String name = '早间播报'}) => {
      'id': id,
      'name': name,
      'enabled': true,
      'triggerType': 'dailyAt',
      'trigger': {
        'time': {'hour': 7, 'minute': 30}
      },
      'actionType': 'tts',
      'action': {'kind': 'tts', 'text': '早上好'},
      'cooldownSec': 0,
      'assetIds': const <String>[],
    };

Future<_FakeChannel?> _pumpTab(
  WidgetTester tester, {
  bool enabled = true,
  List<PairedEndpoint> endpoints = const [],
  String selected = '',
  bool injectChannel = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = RemoteStore(await SharedPreferences.getInstance());
  for (final e in endpoints) {
    await store.addPaired(e);
  }
  if (enabled) await store.setEnabled(true);
  if (selected.isNotEmpty) await store.selectEndpoint(selected);

  final ch = injectChannel ? _FakeChannel() : null;
  if (ch != null) addTearDown(ch.dispose);

  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // 外层 Scaffold 是**还原生产形状**：本页在 `_load() → refresh() → _send()`
  // 这条纯微任务链里就会 `_snack()`，那时页面自己的 Scaffold 还没挂上。
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(home: Scaffold(body: RemoteTasksTab(channel: ch))),
  ));
  await tester.pump();
  await tester.pump(const Duration(seconds: 3)); // refresh 的 2s 兜底延迟
  if (ch != null) {
    ch.emit(RcEvt.status, {'pendingCount': 0, 'version': '1.9.0-alpha'});
    await tester.pump();
  }
  return ch;
}

void main() {
  testWidgets('CT-01 另一台端点的 rc.tasks 不得覆盖本页列表（否则会在错误对象上操作）',
      (tester) async {
    final ch = await _pumpTab(
      tester,
      endpoints: [_ep('dev-a', 'A 机'), _ep('dev-b', 'B 机')],
      selected: 'dev-a',
    );

    ch!.emit(RcEvt.tasks, {
      'tasks': [_task(id: 'a1', name: 'A 机的任务')]
    }, peerId: 'dev-a');
    await tester.pump();
    expect(find.text('A 机的任务'), findsOneWidget);
    expect(find.text('端点任务（1）'), findsOneWidget);

    // B 机回传自己的列表（本页当前目标是 A）。
    ch.emit(RcEvt.tasks, {
      'tasks': [
        _task(id: 'b1', name: 'B 机的任务'),
        _task(id: 'b2', name: 'B 机的另一个任务'),
      ]
    }, peerId: 'dev-b');
    await tester.pump();

    expect(find.text('A 机的任务'), findsOneWidget,
        reason: 'R-5：另一台的列表不得覆盖本页 —— 覆盖后启停/删除会落在错误的对象上');
    expect(find.text('B 机的任务'), findsNothing);
    expect(find.text('端点任务（1）'), findsOneWidget);
  });

  testWidgets('CT-02 不带 peerId 的事件（协助会话）仍必须被消费（不能过度过滤）',
      (tester) async {
    final ch = await _pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);

    ch!.emit(RcEvt.tasks, {
      'tasks': [_task(name: '无 peerId 的任务')]
    });
    await tester.pump();

    expect(find.text('无 peerId 的任务'), findsOneWidget,
        reason: '协助会话事件不带 peerId ⇒ 必须天然放行');
  });

  testWidgets('CT-03 本机远程模块未开 → 说"命令不会补发"，不是"上线后自动执行"（R-9）',
      (tester) async {
    // 生产路径（不注入通道）+ 未开启模块：`sendTo` 走"入队 + 返回 false"，
    // 而本机模块没开时这条命令**不会**被补发。
    await _pumpTab(tester,
        enabled: false, endpoints: [_ep('dev-a', 'A 机')], injectChannel: false);

    expect(find.textContaining('本机远程模块未开启，命令不会补发'), findsOneWidget,
        reason: 'R-9：原因不同提示必须不同 —— 否则用户一直等一个不会来的补发');
    expect(find.textContaining('上线后自动执行'), findsNothing);

    await tester.pump(const Duration(seconds: 3)); // 收尾 refresh 的兜底 Timer
  });

  testWidgets('CT-04 模块已开、只是没连上 → 仍说"已入队，上线后自动执行"（不误报）',
      (tester) async {
    await _pumpTab(tester,
        enabled: true, endpoints: [_ep('dev-a', 'A 机')], injectChannel: false);

    expect(find.textContaining('端点离线：命令已入队，上线后自动执行'), findsOneWidget,
        reason: '模块开着时命令**会**被补发，提示不能跟着改错');
    expect(find.textContaining('本机远程模块未开启'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
  });
}
