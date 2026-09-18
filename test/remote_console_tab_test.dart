import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_console_tab.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 远程控制台的可测性来自 [RcCommandChannel] 抽象：注入一个假通道即可
/// 捕获"发了什么命令"并回灌"收到什么事件"，无需真机与 broker。
class _FakeChannel implements RcCommandChannel {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _updates = StreamController<void>.broadcast();
  final sent = <RcMessage>[];

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
    return true;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await _updates.close();
  }

  /// 回灌一条端点事件（信封形状与 RcEndpointService.events 一致：
  /// 业务字段在 payload 内，见 BUG-023；peerId/peerName 在顶层，见 _broadcast）。
  void emit(String type, Map<String, dynamic> payload,
          {String peerId = '', String peerName = ''}) =>
      _events.add({
        'type': type,
        'payload': payload,
        if (peerId.isNotEmpty) 'peerId': peerId,
        if (peerName.isNotEmpty) 'peerName': peerName,
      });

  RcMessage lastOfType(String type) =>
      sent.lastWhere((m) => m.type == type, orElse: () => throw StateError('未发送 $type'));
}

Future<_FakeChannel> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final ch = _FakeChannel();
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(home: Scaffold(body: RemoteConsoleTab(channel: ch))),
  ));
  await tester.pumpAndSettle();
  return ch;
}

/// 预置一个已配对端点，使控制台的 `_selectedId` 指向它
/// （离线哨兵按"当前选中的端点"判定，故必须先有选择）。
Future<_FakeChannel> _pumpWithPaired(
    WidgetTester tester, String id, String name) async {
  SharedPreferences.setMockInitialValues({});
  final store = RemoteStore(await SharedPreferences.getInstance());
  await store.addPaired(PairedEndpoint(
      deviceId: id, name: name, secret: 's', pairedAt: DateTime.now()));
  final ch = _FakeChannel();
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(home: Scaffold(body: RemoteConsoleTab(channel: ch))),
  ));
  await tester.pumpAndSettle();
  return ch;
}

Future<void> _tap(WidgetTester tester, String label) async {
  final f = find.widgetWithText(FilledButton, label);
  expect(f, findsOneWidget, reason: '控制台应存在「$label」按钮');
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  /// BUG-037 回归锁（2026-09-18 审计发现）：
  /// 端点早已实现 `device.status`（电量/充电/版本/待执行数），控制台也早已
  /// 有「设备快照回执」卡片，但**没有任何入口发这条命令** → 卡片永久为空，
  /// 该命令与 `_sendDeviceStatus` 属不可达代码。
  testWidgets('设备状态按钮发出 device.status 并渲染设备快照回执', (tester) async {
    final ch = await _pump(tester);
    await _tap(tester, '设备状态');
    expect(ch.lastOfType(RcCmd.deviceStatus).type, RcCmd.deviceStatus);

    ch.emit(RcEvt.device, {
      'batteryLevel': 73,
      'charging': true,
      'pendingCount': 5,
      'version': '1.7.0-alpha.1',
    });
    await tester.pumpAndSettle();
    expect(find.text('设备快照回执'), findsOneWidget);
    expect(find.textContaining('电量 73%'), findsOneWidget);
    expect(find.textContaining('充电中'), findsOneWidget);
    expect(find.textContaining('待执行 5 条'), findsOneWidget);
  });

  /// BUG-037 同类：`logs.recent` → `rc.logs` 此前**收发两端皆无**
  /// （端点有实现、事件无人消费、控制器无入口）。
  testWidgets('端点日志按钮发出 logs.recent(limit=20) 并渲染日志回执', (tester) async {
    final ch = await _pump(tester);
    await _tap(tester, '端点日志');
    final m = ch.lastOfType(RcCmd.logsRecent);
    expect(m.payload['limit'], 20);

    ch.emit(RcEvt.logs, {
      'logs': [
        {
          't': DateTime(2026, 9, 18, 9, 5, 3).millisecondsSinceEpoch,
          'source': 'schedule',
          'action': 'play',
          'status': 'success',
        },
        {
          't': DateTime(2026, 9, 18, 9, 6, 30).millisecondsSinceEpoch,
          'source': 'remote',
          'action': 'guard.set',
          'status': 'failed',
        },
      ]
    });
    await tester.pumpAndSettle();
    expect(find.text('端点日志回执（logs.recent）'), findsOneWidget);
    expect(find.textContaining('09:05:03 · schedule/play · success'), findsOneWidget);
    expect(find.textContaining('09:06:30 · remote/guard.set · failed'), findsOneWidget);
  });

  testWidgets('端点日志为空时给出明确提示（不显示空白卡片）', (tester) async {
    final ch = await _pump(tester);
    await _tap(tester, '端点日志');
    ch.emit(RcEvt.logs, {'logs': const <Object>[]});
    await tester.pumpAndSettle();
    expect(find.text('端点暂无执行日志'), findsOneWidget);
  });

  /// BUG-038 回归锁（2026-09-18 审计发现）：
  /// `status.get` / `device.status` / `location.get` / `logs.recent` 的响应是
  /// **专用事件**（rc.status / rc.device / rc.location / rc.logs），端点**不会**
  /// 回 `rc.ack`。但 `_send` 默认 `trackAck: true` → `_pendingAcks` 里的条目
  /// 永不清理，随会话次数无界增长。
  ///
  /// 判定方式：若某命令被记账，则回灌一条 `for` 指向它的 `rc.ack` 会弹出
  /// SnackBar；修正为 `trackAck: false` 后**不应**弹出。
  testWidgets('专用事件类命令不记账：回灌 rc.ack 不弹提示（无 pendingAcks 泄漏）',
      (tester) async {
    final ch = await _pump(tester);
    await _tap(tester, '状态快照');
    await _tap(tester, '定位回传');
    await _tap(tester, '设备状态');
    await _tap(tester, '端点日志');

    for (final cmd in const [
      RcCmd.statusGet,
      RcCmd.locationGet,
      RcCmd.deviceStatus,
      RcCmd.logsRecent,
    ]) {
      final id = ch.lastOfType(cmd).id;
      ch.emit(RcEvt.ack, {'ok': true, 'for': id});
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing,
          reason: '$cmd 的响应是专用事件，不应被当作 ack 记账');
    }
  });

  /// BUG-039 回归锁（2026-09-18 审计发现）：
  /// broker 代发的 LWT 明文离线哨兵 `rc.offline` 被端点服务正确识别并附上
  /// `peerId`/`peerName` 转发（docs/14 §4 把"LWT 离线哨兵"列为可用性特性），
  /// 但**没有任何 UI 消费** → 端点离线时使用者毫无提示，
  /// 只能等点下命令后从"已入队"的提示里间接得知。
  testWidgets('离线哨兵：rc.offline 显示离线横幅，心跳恢复后消失', (tester) async {
    final ch = await _pumpWithPaired(tester, 'ep-1', '客厅手机');
    expect(find.textContaining('已离线'), findsNothing,
        reason: '初始状态不应显示离线横幅');

    ch.emit(RcEvt.offline, const {}, peerId: 'ep-1', peerName: '客厅手机');
    await tester.pumpAndSettle();
    expect(find.textContaining('客厅手机 已离线'), findsOneWidget);
    expect(find.textContaining('端点上线后自动执行'), findsOneWidget,
        reason: '必须说明命令没丢（进 outbox），否则使用者会以为坏了');

    // 心跳（端点每 60s 一次）是恢复信号里最慢的一种，也必须能解除横幅。
    ch.emit(RcEvt.heartbeat, const {}, peerId: 'ep-1');
    await tester.pumpAndSettle();
    expect(find.textContaining('已离线'), findsNothing);
  });

  testWidgets('离线哨兵：其它端点离线不影响当前目标（不误报）', (tester) async {
    final ch = await _pumpWithPaired(tester, 'ep-1', '客厅手机');
    ch.emit(RcEvt.offline, const {}, peerId: 'ep-2', peerName: '书房平板');
    await tester.pumpAndSettle();
    expect(find.textContaining('已离线'), findsNothing,
        reason: '当前选中的是 ep-1，ep-2 离线不应影响它');
  });
}
