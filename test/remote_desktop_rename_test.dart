/// FR-77「本机名称自定义 + 广播同步」的宿主测试 —— 第八十四轮续二。
///
/// ## 覆盖的未覆盖块
/// - `lib/features/remote/remote_screen.dart` 的 `_renameLocal`（约 24 行，0% 覆盖）：
///   对话框 → 调 `DeviceNameService.renameLocal` → **如实回报** `sent/total`
///   三种分支（无端点 / 全部同步 / 部分离线）；
/// - `lib/services/device_name_service.dart` 的 `_genSelfId`（无身份时自动生成）
///   与真实 `sendTo` 分支（未注入替身时）。
///
/// ## 为什么必须测「部分同步」这一支
/// FR-77 的用户明文是"改名后通知所有已绑定设备"。`sent < total`（有端点离线）
/// 若被谎报成"全部同步成功"，用户会以为别的设备已经改了名 —— 属
/// "失败不可静默"要防的那一类。故三种回报必须各自可达。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/features/remote/remote_screen.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/device_name_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const perTest = Timeout(Duration(seconds: 90));
  const nativeChannel = MethodChannel('sonic_shield/native');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final dns = DeviceNameService.instance;

  setUp(() {
    messenger.setMockMethodCallHandler(nativeChannel, (call) async => null);
  });

  tearDown(() {
    dns.senderOverride = null;
    messenger.setMockMethodCallHandler(nativeChannel, null);
  });

  PairedEndpoint ep(String id, String name) => PairedEndpoint(
      deviceId: id, name: name, secret: 'AB2CD5EF', pairedAt: DateTime.now());

  Future<RemoteStore> pump(
    WidgetTester tester, {
    String deviceId = 'EP00000000000001',
    String deviceName = '我的手机',
    List<PairedEndpoint> endpoints = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = RemoteStore(await SharedPreferences.getInstance());
    await store.setIdentity(deviceId, deviceName);
    for (final e in endpoints) {
      await store.addPaired(e);
    }
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: RemoteScreen())));
    await tester.pumpAndSettle();
    return store;
  }

  /// 点「本机身份」卡片 → 填名 → 保存并同步。
  Future<void> renameTo(WidgetTester tester, String name) async {
    await tester.tap(find.widgetWithText(ListTile, '本机身份'));
    await tester.pumpAndSettle();
    expect(find.text('给本机起个名字'), findsOneWidget, reason: '改名对话框必须出现');
    await tester.enterText(find.byType(TextField), name);
    await tester.tap(find.widgetWithText(FilledButton, '保存并同步'));
    await tester.pumpAndSettle();
  }

  testWidgets('RS-01 改名（暂无已绑定端点）→ 如实说「暂无已绑定设备」', (tester) async {
    final store = await pump(tester);

    await renameTo(tester, '客厅主机');

    expect(store.deviceName, '客厅主机', reason: '本机名必须真的落盘');
    expect(find.text('本机名称已更新（暂无已绑定设备）'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('RS-02 改名（2 台全部同步成功）→ 报「已同步到全部 2 台设备」',
      (tester) async {
    await pump(tester, endpoints: [ep('CTRL0001aaaa', 'A'), ep('CTRL0002bbbb', 'B')]);
    var calls = 0;
    dns.senderOverride = (e, msg, store) async {
      calls++;
      return true;
    };

    await renameTo(tester, '新名字');

    expect(calls, 2, reason: '必须对**每个**已绑定端点各发一条 device.rename');
    expect(find.text('本机名称已更新，并已同步到全部 2 台设备'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('RS-03 ★ 改名（2 台只成功 1 台）→ 不谎报全成功，报 1/2 台已同步',
      (tester) async {
    await pump(tester, endpoints: [ep('CTRL0001aaaa', 'A'), ep('CTRL0002bbbb', 'B')]);
    var i = 0;
    dns.senderOverride = (e, msg, store) async => (i++ == 0);

    await renameTo(tester, '新名字');

    expect(find.textContaining('本机名称已更新：1/2 台已同步'), findsOneWidget,
        reason: '有端点离线时必须如实说"其余离线"，绝不假成功');
    expect(find.textContaining('已同步到全部'), findsNothing);
  }, timeout: perTest);

  testWidgets('RS-04 取消对话框 → 不改名、不留回执', (tester) async {
    final store = await pump(tester);
    final before = store.deviceName;

    await tester.tap(find.widgetWithText(ListTile, '本机身份'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(store.deviceName, before, reason: '取消不得写入任何名称');
    expect(find.textContaining('本机名称已更新'), findsNothing);
  }, timeout: perTest);

  testWidgets('RS-05 空名 → 对话框返回空串 ⇒ 不改名（空名会被 DNS 拒绝）',
      (tester) async {
    final store = await pump(tester);
    final before = store.deviceName;

    await renameTo(tester, '   ');

    expect(store.deviceName, before, reason: '空名不得覆盖既有名称');
    expect(find.textContaining('改名失败：名称不能为空'), findsOneWidget);
  }, timeout: perTest);

  // ─────────────────── DeviceNameService 自身的两条未覆盖分支 ───────────────────

  test('DNS-01 无身份时改名 → 自动生成 16 位十六进制 ID 并落盘', () async {
    SharedPreferences.setMockInitialValues({});
    final store = RemoteStore(await SharedPreferences.getInstance());
    expect(store.deviceId, isEmpty);

    final r = await dns.renameLocal('无名机');

    expect(r.ok, isTrue);
    expect(r.total, 0);
    final id = store.deviceId;
    expect(id, hasLength(16), reason: '自动生成的 ID 必须是 16 位（与配对流程同形）');
    expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(id), isTrue);
    expect(store.deviceName, '无名机');
  });

  test('DNS-02 未注入替身 + 有已配对端点 → 走真实 sendTo（离线时 sent=0 但不假成功）',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = RemoteStore(await SharedPreferences.getInstance());
    await store.setIdentity('EP00000000000001', '旧名');
    await store.addPaired(ep('CTRL0001aaaa', 'A'));

    final r = await dns.renameLocal('新名');

    expect(r.ok, isTrue, reason: '受理成功（已落盘）');
    expect(r.total, 1);
    expect(r.sent, 0, reason: '宿主无 broker ⇒ 发送必失败，sent 必须如实为 0');
  });

  test('DNS-03 超长名（>32）→ 拒绝且不写盘、不广播', () async {
    SharedPreferences.setMockInitialValues({});
    final store = RemoteStore(await SharedPreferences.getInstance());
    await store.setIdentity('EP00000000000001', '旧名');
    var calls = 0;
    dns.senderOverride = (e, msg, s) async {
      calls++;
      return true;
    };

    final r = await dns.renameLocal('x' * 33);

    expect(r.ok, isFalse);
    expect(r.error, contains('32'));
    expect(calls, 0, reason: '校验失败不得广播');
    expect(store.deviceName, '旧名', reason: '校验失败不得写盘');
  });
}
