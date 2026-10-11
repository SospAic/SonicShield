import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_console_tab.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_playback.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 远程控制台的可测性来自 [RcCommandChannel] 抽象：注入一个假通道即可
/// 捕获"发了什么命令"并回灌"收到什么事件"，无需真机与 broker。
class _FakeChannel implements RcCommandChannel {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _updates = StreamController<void>.broadcast();
  final sent = <RcMessage>[];

  /// `canSend` 的返回值。默认 true —— 与旧行为一致，既有用例一字未改。
  bool canSendValue = true;

  /// `send` 的返回值。默认 true —— 同上。
  bool sendOk = true;

  @override
  String get label => '假端点';

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Stream<void> get updates => _updates.stream;

  @override
  bool get canSend => canSendValue;

  @override
  Future<bool> send(RcMessage msg) async {
    sent.add(msg);
    return sendOk;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await _updates.close();
  }

  /// 回灌一次"权限/可用性变更"（协助会话里端点放行或收回权限）。
  /// 页面必须因此重建，否则按钮灰化会停在旧值（BUG-030）。
  void bump() => _updates.add(null);

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

  RcMessage lastOfType(String type) => sent.lastWhere((m) => m.type == type,
      orElse: () => throw StateError('未发送 $type'));
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

/// 点一个 **OutlinedButton**（守卫/音量/停止指令组/停止振动/固定分类那几排）。
Future<void> _tapOutlined(WidgetTester tester, String label) async {
  final f = find.widgetWithText(OutlinedButton, label);
  expect(f, findsOneWidget, reason: '控制台应存在「$label」按钮');
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

PairedEndpoint _ep(String id, String name) => PairedEndpoint(
    deviceId: id, name: name, secret: 's', pairedAt: DateTime.now());

/// 以「**已配对端点**」形态挂载（`channel: null`）—— 走 `RcEndpointService` 那条路。
///
/// 为什么宿主上能安全驱动：该服务在**未启动**时 `_client == null`，
/// `sendTo` 因此只把命令写进 outbox 并返回 `false`（**不发任何网络**），
/// 于是"端点离线：已入队，端点上线后自动执行"这条**真实分支**可以端到端走到。
///
/// 需要真 GoRouter：`_enableHint` 的「去开启」与「尚未配对端点」卡片都会
/// `context.push(...)`，用裸 `MaterialApp` 会直接抛。
Future<void> _pumpNoChannel(
  WidgetTester tester, {
  bool enabled = false,
  List<PairedEndpoint> eps = const [],
  String? selected,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = RemoteStore(await SharedPreferences.getInstance());
  for (final e in eps) {
    await store.addPaired(e);
  }
  await store.setEnabled(enabled);
  if (selected != null) await store.setSelectedEndpoint(selected);

  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      // 包一层 Scaffold 还原生产形状（整页组件依赖宿主提供外层 Scaffold）。
      GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: RemoteConsoleTab())),
      GoRoute(
          path: '/remote/pair-qr',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('PAIR-QR-PAGE')))),
      GoRoute(
          path: '/remote/settings',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('REMOTE-SETTINGS-PAGE')))),
    ],
  );
  await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)));
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
    expect(find.textContaining('09:05:03 · schedule/play · success'),
        findsOneWidget);
    expect(find.textContaining('09:06:30 · remote/guard.set · failed'),
        findsOneWidget);
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
  testWidgets('专用事件类命令不记账：回灌 rc.ack 不弹提示（无 pendingAcks 泄漏）', (tester) async {
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
    expect(find.textContaining('已离线'), findsNothing, reason: '初始状态不应显示离线横幅');

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

  testWidgets('点选音源 → sound.play 点名该 assetId，端点按它播放那一条（链路锁）', (tester) async {
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
    final lib =
        _FakeLib(byId: {'a-2': '/x/rain.wav'}, anyPath: '/x/newest.wav');
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
    expect(payload.containsKey('assetId'), isFalse, reason: '按分类播放不应伪装成指定音源');
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

  // ================= 第二十九轮补测（88 行未覆盖）=================
  //
  // 上面那些用例全部走**协助会话**通道（`channel != null`），于是控制台的
  // **另一半**从来没被执行过：
  //   · 「已配对端点」路径（`_endpointSelector` / `_endpoint` / `_store` /
  //     `_send` 的端点分支 / 「端点离线：已入队」提示）；
  //   · 「远程模块未开启」引导与「尚未配对」空态（连跳转都没点过）；
  //   · 通道的两条**失败**分支（`canSend == false` / `send` 返回 false）；
  //   · `updates` 流（BUG-030 的重建钩子）；
  //   · 一半的命令按钮（Ping / 拍照 / 固定分类 / 守卫关 / 音量 / 停止指令组 /
  //     停止振动）—— 它们各自绑着不同的 payload，**没人点过就等于没验过**；
  //   · 四条回执事件（pong / status / location / photo）与它们各自的卡片。

  // ---------------- A · 「已配对端点」路径（channel == null）----------------

  testWidgets('RCT-01 未启用且未配对：显示「远程模块未开启」引导与「尚未配对端点」，引导可跳设置',
      (tester) async {
    await _pumpNoChannel(tester);
    expect(find.text('远程模块未开启'), findsOneWidget,
        reason: '端点服务未运行则所有命令都不会被接收，必须明说');
    expect(find.textContaining('端点服务未运行'), findsOneWidget);
    expect(find.text('尚未配对端点'), findsOneWidget);
    expect(find.textContaining('扫码配对'), findsOneWidget);

    await tester.tap(find.text('去开启'));
    await tester.pumpAndSettle();
    expect(find.text('REMOTE-SETTINGS-PAGE'), findsOneWidget);
  });

  testWidgets('RCT-02 未配对时点卡片跳到扫码配对页', (tester) async {
    await _pumpNoChannel(tester);
    await tester.tap(find.text('尚未配对端点'));
    await tester.pumpAndSettle();
    expect(find.text('PAIR-QR-PAGE'), findsOneWidget);
  });

  testWidgets('RCT-03 已配对且已启用：下拉框列出端点，切换后写入全局选择', (tester) async {
    await _pumpNoChannel(tester,
        enabled: true,
        eps: [_ep('ep-1', '客厅手机'), _ep('ep-2', '书房平板')],
        selected: 'ep-1');
    expect(find.text('远程模块未开启'), findsNothing);
    expect(find.text('目标端点'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书房平板').last);
    await tester.pumpAndSettle();

    final store = RemoteStore(await SharedPreferences.getInstance());
    expect(store.selectedEndpointId, 'ep-2',
        reason: '换页/重启后仍应是这台（与「我的设备」共享同一份选择）');
  });

  testWidgets('RCT-04 已配对端点：命令经端点服务发出，未连接时入队并如实提示（不装作已发）',
      (tester) async {
    await _pumpNoChannel(tester,
        enabled: true, eps: [_ep('ep-1', '客厅手机')], selected: 'ep-1');
    await _tapOutlined(tester, '守卫 开');

    expect(find.textContaining('端点离线：'), findsOneWidget,
        reason: '端点未连接时必须说清"没立刻执行"');
    expect(find.textContaining('已入队，端点上线后自动执行'), findsOneWidget,
        reason: '同时要说清"命令没丢" —— 否则使用者会以为坏了');

    // 命令**真的**进了 outbox（不是只弹了个提示）。
    final store = RemoteStore(await SharedPreferences.getInstance());
    expect(store.outbox(), isNotEmpty, reason: '离线命令必须落进 outbox');
  });

  testWidgets('RCT-05 未选中端点：命令不发出去，提示「请先选择端点」', (tester) async {
    await _pumpNoChannel(tester, enabled: true); // 已启用但没有任何端点
    await _tapOutlined(tester, '守卫 开');
    await tester.pumpAndSettle();
    expect(find.text('请先选择端点'), findsOneWidget);
  });

  // ---------------- B · 协助会话通道的两条失败分支 ----------------

  testWidgets('RCT-06 协助会话未激活：命令被拦下并提示（不静默丢弃）', (tester) async {
    final ch = await _pump(tester);
    ch.canSendValue = false;
    await _tap(tester, 'Ping');
    expect(find.text('协助会话未激活'), findsOneWidget);
    expect(ch.sent, isEmpty, reason: '未激活就不该真的发出去');
  });

  testWidgets('RCT-07 发送失败：如实提示「发送失败」而不是装作已发', (tester) async {
    final ch = await _pump(tester);
    ch.sendOk = false;
    await _tap(tester, 'Ping');
    await tester.pumpAndSettle();
    expect(find.textContaining('发送失败：「Ping 测试」'), findsOneWidget);
  });

  testWidgets('RCT-08 权限/可用性变更（updates）触发重建，按钮不被误灰化（BUG-030）',
      (tester) async {
    final ch = await _pump(tester);
    ch.bump();
    await tester.pumpAndSettle();
    // 配对通道无权限位模型（配对即全权）→ 重建后按钮仍应可用。
    expect(find.text('设备快照与动作'), findsOneWidget);
    final ping = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Ping'));
    expect(ping.onPressed, isNotNull, reason: '配对通道不该把按钮灰化');
  });

  // ---------------- C · 其余命令入口（各自绑不同的 payload）----------------

  testWidgets('RCT-09 其余命令入口都发出正确命令（Ping/拍照/分类/守卫关/音量/停止组/停止振动）',
      (tester) async {
    final ch = await _pump(tester);

    await _tap(tester, 'Ping');
    expect(ch.lastOfType(RcCmd.ping).payload, isEmpty);

    await _tap(tester, '拍照回传');
    expect(ch.lastOfType(RcCmd.cameraSnap).payload, isEmpty);

    // 固定猜测的分类按钮（OutlinedButton，不是 FilledButton）。
    await _tapOutlined(tester, 'knocks');
    final play = ch.lastOfType(RcCmd.soundPlay).payload;
    expect(play['category'], 'knocks');
    expect(play['volume'], 0.9);
    expect(play['durationSec'], 8);
    expect(play.containsKey('assetId'), isFalse, reason: '按分类播放不应伪装成指定音源');

    await _tapOutlined(tester, '守卫 关');
    expect(ch.lastOfType(RcCmd.guardSet).payload['enabled'], isFalse,
        reason: '「守卫 关」必须发 false —— 发成 true 是静默的反向操作');

    // 音量模块（Y1）：写死的「音量 80%」按钮已替换为滑杆 + 快捷档位。
    // 点 50% 档：payload 必须是 {'media': 0.5} —— 端点对 media 不做范围校验，
    // 控制端 `volumePayloadForPercent` 的钳制是唯一边界。
    await _tapOutlined(tester, '50%');
    expect(ch.lastOfType(RcCmd.volumeSet).payload['media'], 0.5,
        reason: '快捷档位 50% 必须映射 0.5（端点侧不校验范围，控制端钳制是唯一边界）');

    await _tapOutlined(tester, '静音');
    expect(ch.lastOfType(RcCmd.volumeSet).payload['media'], 0.0,
        reason: '0 档 = 静音，必须发 0.0 而不是不发');

    await _tapOutlined(tester, '停止指令组');
    expect(ch.lastOfType(RcCmd.scriptStop).type, RcCmd.scriptStop);

    await _tapOutlined(tester, '停止端点振动');
    expect(ch.lastOfType(RcCmd.vibrateStop).type, RcCmd.vibrateStop,
        reason: '持续振动"不设时长上限"的另一半就是"任何时刻都能停"');
  });

  // ══════════════ RCT-VS 远程发送振动（v2.x） ══════════════
  //
  // 「发送振动」是新增的**主动**命令：与「停止端点振动」成对。
  // 锁的是"对话框确实把参数带进了 payload" —— 只断言"发了 vibrate.start"
  // 会漏掉"参数丢了、端点只能取默认值"的静默降级。

  testWidgets('RCT-VS 发送振动（固定）→ vibrate.start 带 mode/时长/强度', (tester) async {
    final ch = await _pump(tester);

    await _tapOutlined(tester, '发送振动');
    // 对话框默认「固定」+ 5 秒 / 60%，直接确认。
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();

    final m = ch.lastOfType(RcCmd.vibrateStart);
    expect(m.payload['mode'], 'fixed');
    expect(m.payload['durationSec'], 5);
    expect(m.payload['intensity'], 0.6);
  });

  testWidgets('RCT-VS2 切到「随机」→ payload 带随机区间字段', (tester) async {
    final ch = await _pump(tester);

    await _tapOutlined(tester, '发送振动');
    await tester.tap(find.text('随机'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();

    final m = ch.lastOfType(RcCmd.vibrateStart);
    expect(m.payload['mode'], 'random');
    // 随机模式必须带上区间字段，否则端点只能落默认值（表单填了等于没填）。
    expect(m.payload.containsKey('durationSecMin'), isTrue);
    expect(m.payload.containsKey('durationSecMax'), isTrue);
    expect(m.payload.containsKey('amplitudeMin'), isTrue);
    expect(m.payload.containsKey('amplitudeMax'), isTrue);
  });

  // ---------------- D · 回执事件与卡片 ----------------

  testWidgets('RCT-10 回执事件（pong/status/location/photo）各自渲染卡片', (tester) async {
    final ch = await _pump(tester);

    await _tap(tester, 'Ping');
    ch.emit(RcEvt.pong, {'at': DateTime.now().millisecondsSinceEpoch - 42});
    await tester.pumpAndSettle();
    expect(find.textContaining('往返'), findsOneWidget);

    await _tap(tester, '状态快照');
    ch.emit(RcEvt.status, {'pendingCount': 3, 'version': '1.7.0'});
    await tester.pumpAndSettle();
    expect(find.text('状态回执（status.get）'), findsOneWidget);
    expect(find.textContaining('端点待执行 3 条'), findsOneWidget);
    expect(find.textContaining('版本 1.7.0'), findsOneWidget);

    await _tap(tester, '定位回传');
    ch.emit(RcEvt.location, {'lat': 31.23, 'lng': 121.47, 'acc': 12.6});
    await tester.pumpAndSettle();
    expect(find.text('定位回执'), findsOneWidget);
    expect(find.textContaining('lat 31.23, lng 121.47'), findsOneWidget);
    expect(find.textContaining('±13 m'), findsOneWidget, reason: '12.6 应四舍五入为 13');

    await _tap(tester, '拍照回传');
    // 有效 base64（解码成功才会走到 `Image.memory`；字节本身不是合法图片，
    // 于是由 `errorBuilder` 兜底 —— 两条路径都在这一条用例里走过）。
    ch.emit(RcEvt.photo, {'photoB64': base64Encode(const [1, 2, 3, 4])});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('拍照回执'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    // 图片解码走的是**真实异步**（`ui.instantiateImageCodec`），fake 时钟推不动它
    // → 给它一次真实事件循环的机会（`runAsync` + 真实 Timer），再回到 fake 世界
    // 排空微任务（`pump`）。这就是 `flutter-widget-test-harness` 里的"分段驱动"。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('图片解码失败'), findsOneWidget,
        reason: '解不开就必须如实说"解码失败"，而不是留一块空白');
  });

  testWidgets('RCT-11 记账命令收到 rc.ack 时弹出回执提示（ok 与 fail 两种）', (tester) async {
    final ch = await _pump(tester);

    await _tapOutlined(tester, '守卫 开');
    ch.emit(RcEvt.ack, {'ok': true, 'for': ch.lastOfType(RcCmd.guardSet).id});
    await tester.pumpAndSettle();
    expect(find.textContaining('✓ 开启端点守卫'), findsOneWidget);

    // 冲掉上一条（SnackBar 是串行的，不排空就看不到第二条）。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await _tapOutlined(tester, '停止指令组');
    ch.emit(RcEvt.ack, {'ok': false, 'for': ch.lastOfType(RcCmd.scriptStop).id});
    await tester.pumpAndSettle();
    expect(find.textContaining('✗ 停止端点指令组'), findsOneWidget);
  });

  // ---------------- E · 音量滑杆与「最后成功值」（第四十四轮） ----------------

  testWidgets('RCT-12 音量滑杆：拖动过程只改界面，松手才发命令；回执 ok 才记住该值',
      (tester) async {
    final ch = await _pump(tester);

    // 滑杆是本页唯一的 Slider（快捷档位是 OutlinedButton）。
    final slider = tester
        .widgetList<Slider>(find.byType(Slider))
        .firstWhere((s) => s.max == 100 && s.divisions == 100);

    await tester.ensureVisible(find.byType(Slider));
    slider.onChanged!(42);
    await tester.pump();
    expect(find.text('42%'), findsOneWidget, reason: '拖动过程必须实时反映到界面');
    expect(ch.sent.where((m) => m.type == RcCmd.volumeSet), isEmpty,
        reason: '拖动过程发命令 = 刷屏（每个像素一条 MQTT），必须只在松手时发');

    slider.onChangeEnd!(42);
    await tester.pumpAndSettle();

    final cmd = ch.lastOfType(RcCmd.volumeSet);
    expect(cmd.payload['media'], closeTo(0.42, 1e-9),
        reason: '42% → 0.42（端点侧不校验范围，控制端钳制是唯一边界）');

    // 落盘点：**回执 ok 之后**才写「最后成功设置的音量」。
    final prefs = await SharedPreferences.getInstance();
    final volKeys =
        prefs.getKeys().where((k) => k.startsWith('rc:volume:')).toList();
    expect(volKeys, isEmpty, reason: '命令只是发出去了 —— 还没成功，不能先记账');

    ch.emit(RcEvt.ack, {'ok': true, 'for': cmd.id, 'data': ''});
    await tester.pumpAndSettle();
    // 回执提示用的是命令描述（`volumeLabelForPercent`）而不是命令名。
    expect(find.textContaining('✓ 媒体音量 42%'), findsOneWidget);

    expect(prefs.getKeys().where((k) => k.startsWith('rc:volume:')).toList(),
        isNotEmpty,
        reason: '回执 ok 必须把该值落盘 —— 否则下次进页又回到 80%，用户的重设白做');
    expect(prefs.getInt(volKeys.isEmpty ? 'rc:volume:assist' : volKeys.first), 42);

    // 收尾推掉 SnackBar 计时，避免 pending timer。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('RCT-13 音量回执 ok=false → 不记账（端点拒绝的值不得当成已生效）',
      (tester) async {
    final ch = await _pump(tester);

    await _tapOutlined(tester, '50%');
    final cmd = ch.lastOfType(RcCmd.volumeSet);

    ch.emit(RcEvt.ack, {'ok': false, 'for': cmd.id, 'data': 'iOS 不支持调节音量'});
    await tester.pumpAndSettle();

    expect(find.textContaining('iOS 不支持调节音量'), findsOneWidget,
        reason: '失败原因必须显示 —— 只说 ✗ 等于让用户自己猜');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith('rc:volume:')), isEmpty,
        reason: '"发送即记忆"会把端点拒掉的值记成已生效（假成功）');

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ---------------- F · `_send` 的**成功**分支（第四十五轮） ----------------

  /// RCT-14（第四十五轮）：`_send` 端点分支的 `if (ok)`（本文件 L372-373）
  /// 此前**结构上到不了** —— `_pumpNoChannel` 走 `RcEndpointService.sendTo`，
  /// 而宿主上端点服务 `_client == null` ⇒ 该调用**恒返回 `false`**（这正是
  /// RCT-04 的锁：「未连接 → 已入队」）。于是"真的发出去了"那一半从未被执行。
  ///
  /// 第四十五轮给 `RcEndpointService` 加了 `@visibleForTesting debugSendTo`
  /// **出站替身**（`sendTo` 的成功分支要求 `_client` 存在且连接态为 connected，
  /// 宿主上不可能满足，只能注入）。本用例用它把这一半补齐，并顺带验证：
  /// ★ 记账（`_armExpectation`）与「8 秒未响应」提示是**同一套状态机的两端** ——
  ///   只记不报会让用户对着一个永远不动的界面干等。
  testWidgets('RCT-14 端点在线：命令发出即记账，8 秒无回执必须如实报「端点未响应」',
      (tester) async {
    final svc = RcEndpointService.instance;
    addTearDown(() => svc.debugSendTo = null);
    // 只有"真的发出去了"才记账 ⇒ 这里让 sendTo 报成功。
    svc.debugSendTo = (ep, msg, store, enqueueOnFail) async => true;

    await _pumpNoChannel(tester,
        enabled: true, eps: [_ep('ep-1', '客厅手机')], selected: 'ep-1');
    await _tap(tester, 'Ping');

    expect(find.textContaining('端点离线'), findsNothing,
        reason: '命令确实发出去了 —— 再说"离线/已入队"就是自相矛盾的提示');

    // `_ackTimeoutSec = 8`，扫描器每 1s 一轮 ⇒ 推到第 9 秒必已过期。
    await tester.pump(const Duration(seconds: 9));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('端点未响应'), findsOneWidget,
        reason: '记了账却没等来回执，必须把"点了没反应"的三种常见原因说出来');

    // 收尾推掉 SnackBar 计时，避免 pending timer。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ══════════════ RCT-RM 全局执行总开关·远程控制回显（第八十二轮） ══════════════
  //
  // 「总执行开关需要支持远程控制」：命令 `run.master.set` 自第 79 轮就绪，但
  // 控制台**不回显当前档** —— 用户点了按钮只能靠记忆判断"到底改没改"。
  // 本组锁：① 发命令；② 据 `rc.status` 回显当前档与暂停态；③ 当前档高亮。

  testWidgets('RCT-RM1 发 run.master.set，并按 rc.status 回显当前档 + 高亮',
      (tester) async {
    final ch = await _pump(tester);

    // 初始未取到状态 ⇒ 回显"未知"，三档均 OutlinedButton（不高亮）。
    expect(find.textContaining('端点当前：未知'), findsOneWidget);

    await _tapOutlined(tester, '强制关闭');
    expect(ch.lastOfType(RcCmd.runMasterSet).payload['mode'], 'off',
        reason: '「强制关闭」必须发 off —— 发成别的档是静默的反向操作');

    // 端点回执 rc.status（真实载荷形状见 endpoint_service 的 statusGet 分支）。
    ch.emit(RcEvt.status, {
      'pendingCount': 0,
      'version': '1.9.0',
      'runMasterMode': 'off',
      'paused': true,
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('端点当前：强制关闭'), findsOneWidget);
    expect(find.textContaining('暂停中'), findsOneWidget);
    // 当前档高亮为 FilledButton（其余仍 OutlinedButton）—— 回显必须可辨。
    expect(find.widgetWithText(FilledButton, '● 强制关闭'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '自动'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '强制开启'), findsOneWidget);
  });

  testWidgets('RCT-RM2 三档各自发出正确的 mode；未取状态时不高亮任何档',
      (tester) async {
    final ch = await _pump(tester);
    // 未取到状态 ⇒ 不高亮。
    expect(find.widgetWithText(FilledButton, '● 强制关闭'), findsNothing);

    await _tapOutlined(tester, '强制开启');
    expect(ch.lastOfType(RcCmd.runMasterSet).payload['mode'], 'on');

    await _tapOutlined(tester, '自动');
    expect(ch.lastOfType(RcCmd.runMasterSet).payload['mode'], 'auto',
        reason: '「自动」必须发 auto（回到跟随法定休息日窗口）');
  });
}
