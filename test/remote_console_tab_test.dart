import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_console_tab.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_playback.dart';
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

/// 假音源库（BUG-048 链路锁用）：让"控制台发出的 payload"真正走一遍端点决策。
class _FakeLib {
  _FakeLib({this.byId = const {}, this.anyPath});

  final Map<String, String> byId;
  final String? anyPath;

  var anyQueries = 0;
  final played = <String>[];

  Future<String?> resolveId(String id) async => byId[id];
  Future<String?> resolveTag(String tag) async => null;
  Future<String?> resolveAny() async {
    anyQueries++;
    return anyPath;
  }

  Future<bool> play(String path, double volume, int durationMs,
      {bool loop = false}) async {
    played.add(path);
    return true;
  }
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
    await _tap(tester, '端点音源库');
    await _tap(tester, '预置分类');

    for (final cmd in const [
      RcCmd.statusGet,
      RcCmd.locationGet,
      RcCmd.deviceStatus,
      RcCmd.logsRecent,
      RcCmd.assetList,
      RcCmd.presetList,
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

  // ---------------- BUG-048（2026-09-19 审计发现）----------------
  //
  // 端点早已实现 `asset.list` / `preset.list` → `rc.assets` / `rc.presets`，
  // 但控制台**既无入口也无消费方**（HANDOVER §6.12 的 P2 项）：
  // 远程播放只能按固定分类"盲播"，选不了具体音源。
  // 更糟的是端点侧忽略 `assetId`（见 remote_playback_test.dart），
  // 于是"点选某一条"这件事**两端各自都说得通、链路却是断的**。

  testWidgets('音源库按钮发出 asset.list(limit=50) 并渲染音源列表', (tester) async {
    final ch = await _pump(tester);
    await _tap(tester, '端点音源库');
    expect(ch.lastOfType(RcCmd.assetList).payload['limit'], 50);

    ch.emit(RcEvt.assets, {
      'total': 2,
      'assets': [
        {
          'id': 'a-1',
          'name': '敲门声',
          'durationMs': 3000,
          'tags': ['预置/knocks'],
        },
        {'id': 'a-2', 'name': '雨声', 'durationMs': 65000, 'tags': <String>[]},
      ]
    });
    await tester.pumpAndSettle();

    expect(find.text('端点音源库回执（asset.list）'), findsOneWidget);
    expect(find.textContaining('共 2 条'), findsOneWidget);
    expect(find.text('敲门声'), findsOneWidget);
    expect(find.text('雨声'), findsOneWidget);
    expect(find.text('3s · 预置/knocks'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget, reason: '65s 应显示为 1:05');
  });

  testWidgets('点选音源 → sound.play 点名该 assetId，端点按它播放那一条（链路锁）',
      (tester) async {
    final ch = await _pump(tester);
    await _tap(tester, '端点音源库');
    ch.emit(RcEvt.assets, {
      'total': 2,
      'assets': [
        {'id': 'a-1', 'name': '敲门声', 'durationMs': 3000, 'tags': <String>[]},
        {'id': 'a-2', 'name': '雨声', 'durationMs': 65000, 'tags': <String>[]},
      ]
    });
    await tester.pumpAndSettle();

    final row = find.text('雨声');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    final payload = ch.lastOfType(RcCmd.soundPlay).payload;
    expect(payload['assetId'], 'a-2', reason: '必须点名用户点的那一条');

    // 把控制台**实际发出**的 payload 喂给端点的决策函数。
    // 只看两端各自都"对"，只有串起来才能发现链路是断的（本项目的老教训）。
    final lib = _FakeLib(byId: {'a-2': '/x/rain.wav'}, anyPath: '/x/newest.wav');
    final r = await performRemotePlay(
      payload,
      byId: lib.resolveId,
      byTag: lib.resolveTag,
      any: lib.resolveAny,
      play: lib.play,
    );

    expect(lib.played, ['/x/rain.wav'], reason: '端点必须播放被点选的那一条');
    expect(lib.anyQueries, 0, reason: '点名了就不该回落到"库里最新一条"');
    expect(r.ok, isTrue);
  });

  testWidgets('预置分类按钮发出 preset.list，点分类按 preset 播放', (tester) async {
    final ch = await _pump(tester);
    await _tap(tester, '预置分类');
    expect(ch.lastOfType(RcCmd.presetList).payload, isEmpty);

    ch.emit(RcEvt.presets, {
      'categories': ['ambient', 'nature']
    });
    await tester.pumpAndSettle();
    expect(find.text('端点预置分类回执（preset.list）'), findsOneWidget);

    // 注意：固定分类那排按钮里也有 nature/ambient，故按 ActionChip 精确定位。
    final chip = find.widgetWithText(ActionChip, 'nature');
    expect(chip, findsOneWidget);
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();

    final payload = ch.lastOfType(RcCmd.soundPlay).payload;
    expect(payload['preset'], 'nature');
    expect(payload.containsKey('assetId'), isFalse,
        reason: '按分类播放不应伪装成指定音源');
  });

  testWidgets('音源库 / 预置分类为空时给出明确提示（不显示空白卡片）', (tester) async {
    final ch = await _pump(tester);
    await _tap(tester, '端点音源库');
    ch.emit(RcEvt.assets, {'total': 0, 'assets': const <Object>[]});
    await tester.pumpAndSettle();
    expect(find.textContaining('端点音源库为空'), findsOneWidget);

    await _tap(tester, '预置分类');
    ch.emit(RcEvt.presets, {'categories': const <Object>[]});
    await tester.pumpAndSettle();
    expect(find.textContaining('端点无预置音源分类'), findsOneWidget);
  });
}
