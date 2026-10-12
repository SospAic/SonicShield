import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_console_tab.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 远程控制台的「静默失败」修复锁：R-3 / R-5 / R-7 / R-9。
///
/// ## 为什么单开一份（与 `remote_console_tab_test.dart` 并存）
///
/// 那份文件锁的是"命令发得对、回执渲染得对"；本文件锁的是**相反的那一半**：
/// 命令发出去了但**永远等不到回音**时，界面到底有没有说话。
/// 这类缺陷的共同形状是"代码跑了、界面毫无变化"，所以每条断言都盯着
/// **用户看得见的东西**（SnackBar 文案 / 卡片），而不是内部字段。
///
/// ## 两个容易踩的坑
///
/// * `RemoteConsoleTab` 需要宿主提供 `Scaffold`（`_snack` 依赖 `ScaffoldMessenger`）；
/// * 8 秒超时靠 1s 定时器推进，必须用**显式 `pump(Duration)`** 推假时钟；
///   本页无无限动画，`pumpAndSettle` 只用在"让 SnackBar 退场动画走完"处。
class _FakeChannel implements RcCommandChannel {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _updates = StreamController<void>.broadcast();
  final sent = <RcMessage>[];

  bool canSendValue = true;
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

  /// 回灌一条端点事件；[peerId] 非空即模拟"某个具体对端"发来的（R-5）。
  void emit(String type, Map<String, dynamic> payload, {String peerId = ''}) =>
      _events.add({
        'type': type,
        'payload': payload,
        if (peerId.isNotEmpty) 'peerId': peerId,
      });

  RcMessage lastOfType(String type) => sent.lastWhere((m) => m.type == type,
      orElse: () => throw StateError('未发送 $type'));
}

PairedEndpoint _ep(String id, String name) => PairedEndpoint(
    deviceId: id, name: name, secret: 's', pairedAt: DateTime.now());

/// 以**命令通道**形态挂载（协助会话 / 可注入回执）。
Future<_FakeChannel> _pumpCh(
  WidgetTester tester, {
  List<PairedEndpoint> eps = const [],
  String selected = '',
  bool enabled = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = RemoteStore(await SharedPreferences.getInstance());
  for (final e in eps) {
    await store.addPaired(e);
  }
  await store.setEnabled(enabled);
  if (selected.isNotEmpty) await store.setSelectedEndpoint(selected);

  final ch = _FakeChannel();
  addTearDown(ch.dispose);
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(home: Scaffold(body: RemoteConsoleTab(channel: ch))),
  ));
  await tester.pump();
  return ch;
}

/// 以**生产路径**形态挂载（`channel == null` → `RcEndpointService`）。
///
/// 宿主上该服务的 `_client` 恒为 null ⇒ `sendTo` 只入队并返回 false ——
/// 这正是真机"端点离线"（或"本机模块没开"）时走的同一条分支。
/// 需要真 GoRouter：`_enableHint` 的「去开启」与新增的 SnackBarAction 都会
/// `context.push(...)`。
Future<void> pumpProd(
  WidgetTester tester, {
  List<PairedEndpoint> eps = const [],
  String selected = '',
  bool enabled = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = RemoteStore(await SharedPreferences.getInstance());
  for (final e in eps) {
    await store.addPaired(e);
  }
  await store.setEnabled(enabled);
  if (selected.isNotEmpty) await store.setSelectedEndpoint(selected);

  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: RemoteConsoleTab())),
      GoRoute(
          path: '/remote/settings',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('REMOTE-SETTINGS-PAGE')))),
      GoRoute(
          path: '/remote/pair-qr',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('PAIR-QR-PAGE')))),
    ],
  );
  await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)));
  await tester.pump();
}

Future<void> tapBtn(WidgetTester tester, String label) async {
  final f = find.widgetWithText(FilledButton, label);
  expect(f, findsOneWidget, reason: '控制台应存在「$label」按钮');
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pump();
  await tester.pump();
}

Future<void> tapOutlined(WidgetTester tester, String label) async {
  final f = find.widgetWithText(OutlinedButton, label);
  expect(f, findsOneWidget, reason: '控制台应存在「$label」按钮');
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pump();
  await tester.pump();
}

/// 推进 [n] 秒（每秒一帧）—— 超时判定靠 1s 定时器，必须逐秒推。
Future<void> advance(WidgetTester tester, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

/// 推几帧。
///
/// ⚠️ 必须的：控制台的 `ListView` 子项是**懒构建**的，新增在列表**底部**的
/// 回执卡片在 emit 后的第一帧里往往还没被建出来（实测如此）——
/// 只 `pump()` 一次会让"卡片没渲染"与"事件没被消费"看起来一模一样。
Future<void> settle(WidgetTester tester, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 统计界面上**所有** `Text` 里 [needle] 出现的次数。
///
/// ⚠️ FR-79 起，远程动作回执全部 `join('\n')` 进**一个** `Text`（`_ReceiptConsole`）
/// ⇒ `find.textContaining(...)` 无论里面有几条都只算 **1 个 widget**。
/// 要判"同一条提示是否复弹"，必须数**出现次数**而不是 widget 数。
int countText(WidgetTester tester, String needle) {
  final re = RegExp(RegExp.escape(needle));
  var n = 0;
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    n += re.allMatches(w.data ?? '').length;
  }
  return n;
}

void main() {
  // ══════════════════════════════════════════════════════════════════
  // R-3 · 「请求-事件」类命令的失败必须可见
  // ══════════════════════════════════════════════════════════════════

  testWidgets('CN-01 专用事件类命令 8s 无响应 → 明确提示「端点未响应」（旧实现界面毫无变化）',
      (tester) async {
    final ch = await _pumpCh(tester);
    await tapBtn(tester, '状态快照');
    expect(ch.lastOfType(RcCmd.statusGet).type, RcCmd.statusGet);

    // 端点一声不吭（离线 / 配对码不一致 / 引擎卡住，三者外形完全相同）。
    await advance(tester, 8);
    await tester.pump(const Duration(milliseconds: 300)); // SnackBar 入场

    expect(
        find.textContaining('「状态快照」端点未响应：可能离线、配对码不一致或引擎未运行'),
        findsOneWidget,
        reason: '点了按钮却毫无回音时必须说出来 —— 这正是 R-3 的静默失败');
  });

  testWidgets('CN-02 收到响应即销账 → 之后不会误报「未响应」', (tester) async {
    final ch = await _pumpCh(tester);
    await tapBtn(tester, '状态快照');
    ch.emit(RcEvt.status, {'pendingCount': 1, 'version': '1.9.0'});
    await tester.pump();

    await advance(tester, 12);
    expect(find.textContaining('端点未响应'), findsNothing,
        reason: '回了就是回了；8s 后不该再报"未响应"（说明条目没被清除）');
  });

  testWidgets('CN-03 带 for 的事件只销对应的那一条（同类型两条命令互不牵连）', (tester) async {
    final ch = await _pumpCh(tester);
    await tapBtn(tester, '定位回传');
    await tapBtn(tester, '定位回传');
    expect(ch.sent.length, 2);
    final first = ch.sent[0].id;
    expect(first, isNot(ch.sent[1].id));

    // 只有**第一条**回了（端点载荷带 `for` = 第一条的命令 id）。
    ch.emit(RcEvt.location, {'for': first, 'lat': 1.0, 'lng': 2.0});
    await tester.pump();
    expect(find.text('定位回执'), findsOneWidget);

    await advance(tester, 8);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('端点未响应'), findsOneWidget,
        reason: '第二条没回，必须被报出来 —— 按类型清账会一次清两条（漏报）');
  });

  testWidgets('CN-04 超时条目会被**删除**（不泄漏、不反复刷屏）', (tester) async {
    await _pumpCh(tester);
    await tapBtn(tester, 'Ping');
    await advance(tester, 8);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('端点未响应'), findsOneWidget);

    // FR-79：超时不再弹「一闪即走」的 SnackBar，改写进**常驻可回看**的两行高回执行。
    // 故本条不再断言"文字消失"（回执本就常驻），改为断言**不复弹**：
    // 再推进 5s，若条目没被删除，1s 扫描会再报一条 ⇒ 出现 2 次。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(countText(tester, '端点未响应'), 1,
        reason: '条目必须在超时那一刻被删除 —— 否则每 8s 复弹一条且随点击次数无界增长');
  });

  testWidgets('CN-05 定位失败（error:true）也要渲染原因，不能被整个隐藏', (tester) async {
    final ch = await _pumpCh(tester);
    await tapBtn(tester, '定位回传');

    // 端点定位失败的真实载荷（见 endpoint_service._sendLocation 的 catch 分支）。
    ch.emit(RcEvt.location,
        {'for': ch.lastOfType(RcCmd.locationGet).id, 'lat': null, 'lng': null, 'error': true});
    await tester.pump();

    expect(find.text('定位回执'), findsOneWidget,
        reason: '失败也必须出现在界面上 —— 旧条件只认 `lat is num`，失败被整个隐藏');
    expect(find.textContaining('定位失败（端点未授权定位或定位服务未开启）'), findsOneWidget);
    expect(find.textContaining('lat null'), findsNothing,
        reason: '失败时不该渲染一个假的坐标');
  });

  testWidgets('CN-06 定位成功仍渲染坐标（失败分支没吃掉成功分支）', (tester) async {
    final ch = await _pumpCh(tester);
    await tapBtn(tester, '定位回传');
    ch.emit(RcEvt.location,
        {'for': ch.lastOfType(RcCmd.locationGet).id, 'lat': 31.23, 'lng': 121.47, 'acc': 12.6});
    await tester.pump();

    expect(find.textContaining('lat 31.23, lng 121.47'), findsOneWidget);
    expect(find.textContaining('±13 m'), findsOneWidget);
    expect(find.textContaining('定位失败'), findsNothing);
  });

  // ══════════════════════════════════════════════════════════════════
  // R-7 · 拍照回传是死分支，必须显式标注
  // ══════════════════════════════════════════════════════════════════

  testWidgets('CN-07 拍照按钮标注「暂未启用」；端点回 ack(false) 时显示原因，且永不进拍照态',
      (tester) async {
    final ch = await _pumpCh(tester);
    // 文案必须让用户知道"现在点了没用"，否则只会看到一句「✗ 拍照回传」，像坏了。
    expect(find.text('（暂未启用）'), findsOneWidget,
        reason: 'R-7：端点 camera.snap 恒降级，按钮必须标注暂未启用');

    await tapBtn(tester, '拍照回传');
    final m = ch.lastOfType(RcCmd.cameraSnap);
    expect(m.payload, isEmpty);

    // 端点的真实回执（endpoint_service 的 cameraSnap 分支）。
    ch.emit(RcEvt.ack,
        {'ok': false, 'for': m.id, 'forType': RcCmd.cameraSnap, 'data': 'camera.snap 暂未启用'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('✗ 拍照回传（暂未启用）（camera.snap 暂未启用）'),
        findsOneWidget,
        reason: '失败原因必须一并显示，不能只说"✗"');
    expect(find.text('拍照回执'), findsNothing,
        reason: 'R-7：rc.photo 无发出方，不得进入这个不可能到达的状态');
  });

  // ══════════════════════════════════════════════════════════════════
  // R-9 · outbox 提示必须与真实原因一致
  // ══════════════════════════════════════════════════════════════════

  testWidgets('CN-08 本机远程模块未开 → 说"命令不会补发"并给开启入口（不是"上线后自动执行"）',
      (tester) async {
    await pumpProd(tester, eps: [_ep('ep-1', '客厅手机')], enabled: false);
    await tapOutlined(tester, '守卫 开');
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('本机远程模块未开启，命令不会补发'), findsOneWidget,
        reason: '本机模块没开时命令不会补发，说成"上线后自动执行"是误导');
    expect(find.textContaining('端点离线'), findsNothing);

    // 入口必须真的能到达 —— 否则用户知道原因却无处可去。
    // FR-79 后反馈改走回执行、不再有 SnackBarAction ⇒ 入口只剩页面顶部
    // 「远程模块未开启」卡片里的「去开启」，故 finder 不再需要限定在 SnackBar 内。
    final action = find.widgetWithText(TextButton, '去开启');
    expect(action, findsOneWidget);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('REMOTE-SETTINGS-PAGE'), findsOneWidget);
  });

  testWidgets('CN-09 模块已开、只是 MQTT 没连上 → 仍说"已入队，上线后自动执行"（不误报）',
      (tester) async {
    await pumpProd(tester, eps: [_ep('ep-1', '客厅手机')], enabled: true);
    await tapOutlined(tester, '守卫 开');
    await tester.pump(const Duration(milliseconds: 300));

    expect(
        find.textContaining('端点离线，已入队（端点上线后自动执行）'),
        findsOneWidget,
        reason: '模块开着时命令**会**被补发，这里的提示不能跟着改错');
    expect(find.textContaining('本机远程模块未开启'), findsNothing);
  });

  // ══════════════════════════════════════════════════════════════════
  // R-5 · 业务事件按 peerId 过滤
  // ══════════════════════════════════════════════════════════════════

  testWidgets('CN-10 另一台端点的事件不得覆盖本页（跨设备串台）', (tester) async {
    final ch = await _pumpCh(tester,
        eps: [_ep('ep-1', '客厅手机'), _ep('ep-2', '书房平板')], selected: 'ep-1');

    ch.emit(RcEvt.status, {'pendingCount': 3, 'version': '1.9.0'}, peerId: 'ep-1');
    await settle(tester);
    expect(find.textContaining('端点待执行 3 条'), findsOneWidget);

    // ep-2 的列表/状态（用户当前操作的是 ep-1，这份数据与它无关）。
    ch.emit(RcEvt.status, {'pendingCount': 99, 'version': '9.9.9'}, peerId: 'ep-2');
    await settle(tester);

    expect(find.textContaining('端点待执行 3 条'), findsOneWidget,
        reason: '另一台的数据不得覆盖本页 —— 用户看着 A 的名字却是 B 的数据');
    expect(find.textContaining('端点待执行 99 条'), findsNothing);
    expect(find.textContaining('版本 9.9.9'), findsNothing);
  });

  testWidgets('CN-11 不带 peerId 的事件（协助会话）必须照常消费（不能过度过滤）',
      (tester) async {
    final ch = await _pumpCh(tester,
        eps: [_ep('ep-1', '客厅手机')], selected: 'ep-1');

    ch.emit(RcEvt.status, {'pendingCount': 7, 'version': '1.9.0'});
    await settle(tester);

    expect(find.textContaining('端点待执行 7 条'), findsOneWidget,
        reason: '协助会话的事件不带 peerId ⇒ 必须天然放行，否则协助页整个失效');
  });
}
