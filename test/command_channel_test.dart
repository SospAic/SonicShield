import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/source_text.dart';

/// 控制台**命令通道**（`RcCommandChannel`）的宿主测试 —— 第四十三轮新建。
///
/// ## 为什么此前是零专属覆盖
///
/// `command_channel.dart` 只有 29 行可执行代码，却被 6 行未覆盖卡在 79%：
/// 未覆盖的正是 **[PairedChannel]** 的三个成员 —— `events` / `canSend` /
/// `send`（`covblocks` 实测 L58-59 / L66-67 / L69-71）。
///
/// 原因不是"这段代码没人用"，而是**用它的测试全都换掉了实现**：
/// `remote_scripts_tab_test.dart` 注入的是 `_FakeScriptChannel`（它自己实现了
/// `RcCommandChannel`）⇒ 通道抽象跑通了，**生产实现一行没跑**。
/// 这正是「有测试 ≠ 被测过」的又一形态：**契约被假实现验证，真实现被绕过**。
///
/// ## 为什么这条路径值得锁
///
/// 控制台按钮的灰化（`canSend`）、进度流（`events`）、命令投递（`send`）
/// 三处都挂在它身上。`canSend` 若恒真 ⇒ 端点离线时按钮可点、点了没反应；
/// `events` 若接错了流 ⇒ 进度永远不出现（BUG-057 的同型）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = RcEndpointService.instance;

  late RemoteStore store;
  late PairedEndpoint ep;
  late PairedChannel ch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = RemoteStore(await SharedPreferences.getInstance());
    ep = PairedEndpoint(
      deviceId: 'a1b2c3d4e5f60718',
      name: '客厅手机',
      secret: 'AB2CD5EF',
      pairedAt: DateTime(2026, 1, 1),
    );
    ch = PairedChannel(ep, store);
  });

  test('CC-01 label 就是端点名（控制台标题栏靠它）', () {
    expect(ch.label, '客厅手机');
  });

  test('CC-02 events 必须直连端点服务的事件流（源码锁 + 广播性）', () {
    // ⚠️ 这里**不能用 `identical`** 判"是不是同一条流"：Dart 的
    // `StreamController.stream` 每次访问都会新建一个 `_ControllerStream`
    // 包装对象（SDK 行为，实测 `identical(ch.events, svc.events) == false`
    // 且 `identical(ch.events, ch.events) == false`）。"指向同一条流"这件事
    // 只能靠**代码指向**来锁 —— 这正是本项目 `test/support/source_text.dart` 的用法。
    final src = stripComments(
        File('lib/remote/command_channel.dart').readAsStringSync());
    final start = src.indexOf('class PairedChannel');
    expect(start, greaterThan(-1), reason: '`PairedChannel` 必须存在');
    final body = src.substring(start, src.indexOf('class AssistChannel'));

    expect(body.contains('RcEndpointService.instance.events'), isTrue,
        reason: '必须直连 `RcEndpointService.instance.events` ——'
            '包一层新流的话控制台再也收不到端点广播的进度/回执，'
            '而"收不到"在界面上表现为"点了没反应"，最难定位');
    expect(body.contains('StreamController'), isFalse,
        reason: '通道不得自建事件流（会在多页面间分成两条互不相通的流）');

    // 行为侧补一条：端点事件是**广播**语义（控制台与其它订阅者可同时听）。
    expect(ch.events.isBroadcast, isTrue,
        reason: '单订阅流在第二个订阅者出现时会抛 `Bad state: Stream has already been listened to`');
    expect(svc.events.isBroadcast, isTrue);
  });

  test('CC-03 canSend 必须跟随端点服务的运行态（不是恒真）', () {
    // 宿主没有 MQTT 连接 ⇒ isRunning 为 false ⇒ 按钮必须灰。
    expect(svc.isRunning, isFalse, reason: '前置：宿主上端点服务不应在跑');
    expect(ch.canSend, isFalse, reason: 'canSend 恒真 ⇒ 端点离线时按钮可点、点了没反应');
    expect(ch.canSend, svc.isRunning, reason: '两处口径必须同源');
  });

  test('CC-04 updates 是空流（配对通道无权限位模型，配对即全权）', () async {
    // 空流必须能正常结束，而不是挂住等一个永不到来的事件。
    expect(await ch.updates.isEmpty, isTrue);
  });

  test('CC-05 send 在无连接时如实返回 false，且**不抛**（调用方靠它决定提示）', () async {
    final ok = await ch.send(RcMessage.now(RcCmd.ping, const {}));

    expect(ok, isFalse,
        reason: '未发出必须是 false —— 返回 true 会让控制台报"已发送"却没有任何回音');
  });

  test('CC-06 dispose 可重复调用（页面重复销毁不得抛）', () async {
    await ch.dispose();
    await ch.dispose();
  });

  test('CC-07 pairedChannelOf：配对表里有 → 给通道；没有 → 给 null', () async {
    await store.addPaired(ep);

    final hit = await pairedChannelOf('a1b2c3d4e5f60718');
    expect(hit, isNotNull, reason: '已配对的设备必须能构造出通道');
    expect(hit!.endpoint.deviceId, ep.deviceId);
    expect(hit.canSend, svc.isRunning);

    expect(await pairedChannelOf('ffffffffffffffff'), isNull,
        reason: '未配对必须给 null，不能凭空造一个通道（否则命令会发给不存在的对端）');
  });

  test('CC-08 channelAllows：配对通道无权限位模型 ⇒ 恒放行（与协助通道区分）', () {
    expect(channelAllows(ch, 'sound.play'), isTrue);
    expect(channelAllows(ch, 'camera.snap'), isTrue,
        reason: '配对即全权：灰化判定不得因为"命令白名单"把已配对设备拦掉');
  });
}
