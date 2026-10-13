/// 远程桌面级控制（docs/61）**端点侧处理器**的行为驱动 —— 第八十四轮续二。
///
/// ## 为什么需要本文件
///
/// `RcEndpointService` 里 `screen.cast.request` / `screen.cast.stop` /
/// `input.*` / `device.rename` 这 5 个子处理器此前**一行都没被执行过**：
/// 它们只挂在入站链路 `_handleRaw → _dispatch` 上，而那条链路的唯一生产调用者
/// 是真实 MQTT 监听器 —— 宿主机连不上 broker。于是「契约层被锁住」
/// （`remote_desktop_lock_test.dart` 的 RDP-01…04 只锁字面量与权限位）
/// **≠**「这条业务路径被执行过」。这正是本仓库反复踩的形状。
///
/// ## 驱动方式（零生产代码改动，`lib/**` 一字未动 ⇒ 分母不变）
///
/// 全部走既有 `@visibleForTesting` 缝 + 公开 API：
/// - `debugBind(store:, db:)` + `debugDispatch(msg, peer)`：直接喂入站命令；
/// - `debugClientFactory` + `svc.start()`：让「有 client 且已连接」成立，
///   `_send` 因此走**真实出站路径**，落到 `FakeMqttServerClient.sentWires`；
/// - 出站断言用**真 `RcCodec` 解真密文**（不是「sentWires 非空」这种弱判据）；
/// - `MethodChannel` 打桩：`sonic_shield/native`（无障碍 / 输入注入 / 抓帧）
///   与 `sonic_shield/screencast`（投屏授权），并**记录收到的调用**，
///   让「桥真的被以正确参数调用」可断言。
///
/// 断言一律落在**真实副作用**上：解出来的出站载荷、`castActive` 可见性信号、
/// 审计行落库、桥收到的参数 —— 而不是「执行了没抛异常」。
///
/// ⚠️ 会话锁 `_castSessionId` 是单例私有状态，跨用例存活。`setUp` 用一次
/// `screen.cast.stop` 显式归零，保证每例起点确定（不靠"用例顺序"）。
@Timeout(Duration(seconds: 180))
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/assist_join.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/mqtt_client_stub.dart';

/// 主方法通道（`NativeBridge.ChannelsMethod.channel`）。
const _nativeCh = 'sonic_shield/native';

/// 投屏授权通道（Activity 承载，独立于插件主通道）。
const _castCh = 'sonic_shield/screencast';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final svc = RcEndpointService.instance;
  late SharedPreferences prefs;
  late AppDatabase db;
  late RemoteStore store;
  late FakeMqttServerClient fake;
  late PairedEndpoint peer;

  const ownId = 'EPI00001abcdef12';

  /// 桥收到的调用（断言"以正确参数真的调了"）。
  late List<MethodCall> nativeCalls;
  late List<MethodCall> castCalls;

  /// 桥的返回值表（method → 返回值）。用例可逐项改写。
  late Map<String, Object?> nativeReply;
  late Object? castReply;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  PairedEndpoint peerOf(String id, String name, String code) => PairedEndpoint(
      deviceId: id, name: name, secret: code, pairedAt: DateTime(2024, 1, 1));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    nativeCalls = <MethodCall>[];
    castCalls = <MethodCall>[];
    castReply = true;
    nativeReply = <String, Object?>{
      'accessibilityEnabled': false,
      'inputTap': true,
      'inputSwipe': true,
      'inputKey': true,
      'inputText': true,
      'screenCastStop': null,
      'screenCaptureOnce': 'QkFTRTY0',
    };
    messenger.setMockMethodCallHandler(const MethodChannel(_nativeCh),
        (call) async {
      nativeCalls.add(call);
      return nativeReply[call.method];
    });
    messenger.setMockMethodCallHandler(const MethodChannel(_castCh),
        (call) async {
      castCalls.add(call);
      return castReply;
    });

    prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    await store.setIdentity(ownId, '端点机');
    await store.ensurePairingCode();
    db = await AppDatabase.open(inMemoryDatabasePath);
    svc.debugBind(store: store, db: db, saltStore: KdfSaltStore(prefs));
    svc.debugSetOwnCode(store.pairingCode);

    peer = peerOf('CTRL0001abcdef', '测试控制端', 'CODE0001');
    await store.addPaired(peer);

    fake = FakeMqttServerClient('broker.rdh.invalid', ownId);
    svc.debugClientFactory = (b, c, p) => fake;
    await svc.start(store, db);

    // 会话锁归零：不依赖用例顺序（`_castSessionId` 是单例私有状态）。
    // 归零动作本身会产生审计行与一次 `screenCastStop` 桥调用 ⇒ 一并清干净，
    // 否则每例的"没有 success / 没碰桥"类断言都会被 setUp 自己污染。
    await svc.debugDispatch(RcMessage.now(RcCmd.screenCastStop, const {}), peer);
    nativeCalls.clear();
    castCalls.clear();
    fake.sentWires.clear();
    await db.db.delete('exec_logs');
  });

  tearDown(() async {
    // 全局单例上的注入能力必须清干净，否则污染后续用例。
    svc.debugClientFactory = null;
    svc.debugSendTo = null;
    if (svc.isRunning) await svc.stop();
    await RcAssistHost.instance.close(reason: 'test-teardown', silent: true);
    await AssistJoinClient.instance.leave(silent: true);
    // `svc.start()` 把 audit/onCommand 写成捕获当轮 db 的闭包（进程内单例）⇒
    // 不清会让下一例往**已关闭的库**写审计（`endpoint_service` 同族实测）。
    RcAssistHost.instance.audit = null;
    RcAssistHost.instance.onCommand = null;
    messenger.setMockMethodCallHandler(const MethodChannel(_nativeCh), null);
    messenger.setMockMethodCallHandler(const MethodChannel(_castCh), null);
    try {
      await db.close();
    } on Object {
      // 忽略：在飞的终态计时器可能已把库关掉。
    }
  });

  RcMessage cmd(String type, [Map<String, dynamic> payload = const {}]) =>
      RcMessage.now(type, payload);

  Future<List<Map<String, Object?>>> logs() =>
      LogRepository(db).recent(limit: 200);

  Future<bool> hasLog(String action, String status, {String? contains}) async {
    final rows = await logs();
    return rows.any((r) {
      if (r['action'] != action || r['status'] != status) return false;
      final m = r['message'] as String? ?? '';
      return contains == null || m.contains(contains);
    });
  }

  /// 把 `sentWires` 里每条密文按**对端身份**解开（真 `RcCodec` 真密文）。
  Future<List<RcMessage>> decodedSent() async {
    final key = await RcCodec.deriveKey(peer.secret, '${peer.deviceId}|evt');
    final out = <RcMessage>[];
    for (final w in fake.sentWires) {
      final m = await RcCodec.decode(w.wire, key, w.topic);
      if (m != null) out.add(m);
    }
    return out;
  }

  /// 解出某类型的出站消息。
  Future<List<RcMessage>> sentOf(String type) async =>
      (await decodedSent()).where((m) => m.type == type).toList();

  /// 桥是否以某 method 被调用（可带参数断言）。
  bool calledNative(String method, {bool Function(MethodCall)? where}) =>
      nativeCalls.any((c) => c.method == method && (where?.call(c) ?? true));

  /// 走一遍"建立控制会话"的前置：无障碍开 + 授权同意。
  Future<void> establishControlSession(String castId) async {
    nativeReply['accessibilityEnabled'] = true;
    castReply = true;
    await svc.debugDispatch(
      cmd(RcCmd.screenCastRequest, {'castId': castId, 'kind': 'control'}),
      peer,
    );
    fake.sentWires.clear();
  }

  // ───────────────────────── 会话建立 _screenCastRequest ─────────────────────────

  group('RDH-A screen.cast.request', () {
    test('RDH-A1 castId 缺失 → 显式拒绝且**不触碰**投屏授权通道', () async {
      await svc.debugDispatch(
          cmd(RcCmd.screenCastRequest, {'kind': 'view'}), peer);

      expect(castCalls, isEmpty,
          reason: 'castId 都没有就必须拒绝，绝不该弹出授权窗');
      expect(svc.castActive.value, isFalse);
      final acks = await sentOf(RcEvt.ack);
      expect(acks, hasLength(1));
      expect(acks.single.payload['ok'], isFalse);
      expect(acks.single.payload['data'], contains('castId 缺失'));
    });

    test('RDH-A2 view 模式 → 启动投屏 + 可见性信号置位 + success 审计', () async {
      await svc.debugDispatch(
          cmd(RcCmd.screenCastRequest, {'castId': 'c-1', 'kind': 'view'}),
          peer);

      expect(calledNative('screenCastStop'), isFalse,
          reason: 'view 模式不需要无障碍，也不该去停别的会话');
      expect(castCalls.map((c) => c.method), contains('screenCastStart'));
      expect(svc.castActive.value, isTrue,
          reason: '可见性红线：任何像素出屏前端点必须有醒目指示');
      expect(await hasLog('screen.cast', 'success', contains: '开始控制会话'),
          isTrue);

      final screen = await sentOf(RcEvt.screen);
      expect(screen, hasLength(1));
      expect(screen.single.payload['state'], 'streaming');
      expect(screen.single.payload['castId'], 'c-1');
      expect((await sentOf(RcEvt.ack)).single.payload['ok'], isTrue);
    });

    test('RDH-A3 control 模式但无障碍未开 → 如实拒绝（**不静默降级为仅看**）', () async {
      nativeReply['accessibilityEnabled'] = false;
      await svc.debugDispatch(
          cmd(RcCmd.screenCastRequest, {'castId': 'c-2', 'kind': 'control'}),
          peer);

      expect(calledNative('accessibilityEnabled'), isTrue);
      expect(castCalls, isEmpty, reason: '输入不可用就不该起投屏 —— 拒绝而非降级');
      expect(svc.castActive.value, isFalse);
      expect(await hasLog('screen.cast', 'skipped', contains: '未开启无障碍'),
          isTrue);
      expect((await sentOf(RcEvt.screen)).single.payload['state'], 'denied');
      expect((await sentOf(RcEvt.ack)).single.payload['ok'], isFalse);
    });

    test('RDH-A4 control 模式 + 无障碍已开 → 放行建立会话', () async {
      await establishControlSession('c-3');

      expect(calledNative('accessibilityEnabled'), isTrue);
      expect(castCalls.map((c) => c.method), contains('screenCastStart'));
      expect(svc.castActive.value, isTrue);
      expect(await hasLog('screen.cast', 'success', contains: 'kind=control'),
          isTrue);
    });

    test('RDH-A5 用户拒绝投屏授权（桥返回 false）→ 拒绝 + 不留 success', () async {
      nativeReply['accessibilityEnabled'] = true;
      castReply = false;
      await svc.debugDispatch(
          cmd(RcCmd.screenCastRequest, {'castId': 'c-4', 'kind': 'view'}),
          peer);

      expect(svc.castActive.value, isFalse);
      expect(await hasLog('screen.cast', 'skipped', contains: '用户拒绝投屏授权'),
          isTrue);
      expect(await hasLog('screen.cast', 'success'), isFalse);
      expect((await sentOf(RcEvt.screen)).single.payload['state'], 'denied');
    });

    test('RDH-A6 once:true 单帧路径 → 抓一帧、立即停会话、可见性信号回落', () async {
      await svc.debugDispatch(
        cmd(RcCmd.screenCastRequest,
            {'castId': 'c-5', 'kind': 'view', 'once': true}),
        peer,
      );

      expect(calledNative('screenCaptureOnce'), isTrue);
      final photos = await sentOf(RcEvt.photo);
      expect(photos, hasLength(1));
      expect(photos.single.payload['photoB64'], 'QkFTRTY0');
      expect(calledNative('screenCastStop'), isTrue,
          reason: '本次授权只覆盖这一帧 ⇒ 必须立刻停会话（授权最小化）');
      expect(svc.castActive.value, isFalse);
      expect(await hasLog('screen.cast', 'success', contains: '单帧抓取成功'),
          isTrue);
    });

    test('RDH-A7 once:true 抓帧失败 → failed 审计 + ack ok=false', () async {
      nativeReply['screenCaptureOnce'] = null;
      await svc.debugDispatch(
        cmd(RcCmd.screenCastRequest,
            {'castId': 'c-6', 'kind': 'view', 'once': true}),
        peer,
      );

      expect(await sentOf(RcEvt.photo), isEmpty);
      expect(await hasLog('screen.cast', 'failed', contains: '单帧抓取失败'),
          isTrue);
      expect((await sentOf(RcEvt.ack)).single.payload['ok'], isFalse);
    });

    test('RDH-A8 新 castId 替换旧会话 → 先停旧投屏服务（单会话纪律）', () async {
      await establishControlSession('c-old');
      castCalls.clear();

      await svc.debugDispatch(
          cmd(RcCmd.screenCastRequest, {'castId': 'c-new', 'kind': 'view'}),
          peer);

      expect(calledNative('screenCastStop'), isTrue,
          reason: '新会话必须替换旧会话，否则两路投屏并存');
      expect(castCalls.map((c) => c.method), contains('screenCastStart'));
      expect(svc.castActive.value, isTrue);
    });
  });

  // ───────────────────────── 会话停止 ─────────────────────────

  group('RDH-B 停止控制会话', () {
    test('RDH-B1 远程 screen.cast.stop → 失效会话锁 + 停服务 + 回落指示', () async {
      await establishControlSession('c-9');

      await svc.debugDispatch(
          cmd(RcCmd.screenCastStop, {'castId': 'c-9'}), peer);

      expect(svc.castActive.value, isFalse);
      expect(calledNative('screenCastStop'), isTrue);
      expect(await hasLog('screen.cast', 'success', contains: '停止控制会话'),
          isTrue);
      expect((await sentOf(RcEvt.screen)).single.payload['state'], 'stopped');
      expect((await sentOf(RcEvt.ack)).single.payload['ok'], isTrue);
    });

    test('RDH-B2 端点本机一键停止 → 同一副作用路径 + 留痕（无需回执）', () async {
      await establishControlSession('c-10');
      nativeCalls.clear();
      fake.sentWires.clear();

      await svc.stopCastByUser();

      expect(svc.castActive.value, isFalse);
      expect(calledNative('screenCastStop'), isTrue);
      expect(
          await hasLog('screen.cast', 'success',
              contains: '端点用户本机停止控制会话'),
          isTrue);
      expect(fake.sentWires, isEmpty, reason: '本机停止由端点自己发起，不产生对端回执');
    });
  });

  // ───────────────────────── 输入注入 _inputInject ─────────────────────────

  group('RDH-C input.* 注入（两道前置：会话锁 + 无障碍）', () {
    test('RDH-C1 无活动会话 → 拒绝，桥一次都不碰', () async {
      await svc.debugDispatch(
          cmd(RcCmd.inputTap, {'castId': 'c-x', 'x': 0.5, 'y': 0.5}), peer);

      expect(calledNative('inputTap'), isFalse);
      final ack = (await sentOf(RcEvt.inputAck)).single;
      expect(ack.payload['ok'], isFalse);
      expect(ack.payload['message'], contains('无匹配的活动会话'));
      expect(await hasLog('input.tap', 'success'), isFalse);
    });

    test('RDH-C2 有会话但无障碍关闭 → 拒绝，桥一次都不碰', () async {
      await establishControlSession('c-11');
      nativeReply['accessibilityEnabled'] = false;

      await svc.debugDispatch(
          cmd(RcCmd.inputTap, {'castId': 'c-11', 'x': 0.1, 'y': 0.2}), peer);

      expect(calledNative('inputTap'), isFalse);
      expect((await sentOf(RcEvt.inputAck)).single.payload['message'],
          contains('端点未开启无障碍'));
    });

    test('RDH-C3 会话 + 无障碍齐备 → tap 以归一化坐标下发 + success 审计', () async {
      await establishControlSession('c-12');
      nativeReply['accessibilityEnabled'] = true;

      await svc.debugDispatch(
        cmd(RcCmd.inputTap,
            {'castId': 'c-12', 'x': 0.25, 'y': 0.75, 'durationMs': 120}),
        peer,
      );

      expect(
          calledNative('inputTap',
              where: (c) =>
                  (c.arguments as Map)['x'] == 0.25 &&
                  (c.arguments as Map)['y'] == 0.75 &&
                  (c.arguments as Map)['durationMs'] == 120),
          isTrue,
          reason: '桥必须收到**归一化**坐标与时长，不能是像素值');
      expect((await sentOf(RcEvt.inputAck)).single.payload['ok'], isTrue);
      expect(await hasLog('input.tap', 'success'), isTrue);
    });

    test('RDH-C4 swipe 四坐标 + 缺省时长 200 落到桥上', () async {
      await establishControlSession('c-13');
      nativeReply['accessibilityEnabled'] = true;

      await svc.debugDispatch(
        cmd(RcCmd.inputSwipe, {
          'castId': 'c-13',
          'x1': 0.1,
          'y1': 0.2,
          'x2': 0.8,
          'y2': 0.9,
        }),
        peer,
      );

      expect(
          calledNative('inputSwipe',
              where: (c) {
                final a = c.arguments as Map;
                return a['x1'] == 0.1 &&
                    a['y1'] == 0.2 &&
                    a['x2'] == 0.8 &&
                    a['y2'] == 0.9 &&
                    a['durationMs'] == 200;
              }),
          isTrue);
      expect(await hasLog('input.swipe', 'success'), isTrue);
    });

    test('RDH-C5 key 注入 → keyCode 透传', () async {
      await establishControlSession('c-14');
      nativeReply['accessibilityEnabled'] = true;

      await svc.debugDispatch(
          cmd(RcCmd.inputKey, {'castId': 'c-14', 'keyCode': 4}), peer);

      expect(
          calledNative('inputKey',
              where: (c) => (c.arguments as Map)['keyCode'] == 4),
          isTrue);
      expect(await hasLog('input.key', 'success'), isTrue);
    });

    test('RDH-C6 text 注入 → 文本透传', () async {
      await establishControlSession('c-15');
      nativeReply['accessibilityEnabled'] = true;

      await svc.debugDispatch(
          cmd(RcCmd.inputText, {'castId': 'c-15', 'text': '你好'}), peer);

      expect(
          calledNative('inputText',
              where: (c) => (c.arguments as Map)['text'] == '你好'),
          isTrue);
      expect(await hasLog('input.text', 'success'), isTrue);
    });

    test('RDH-C7 桥返回 false（系统限制）→ failed 审计 + ack ok=false', () async {
      await establishControlSession('c-16');
      nativeReply['accessibilityEnabled'] = true;
      nativeReply['inputKey'] = false;

      await svc.debugDispatch(
          cmd(RcCmd.inputKey, {'castId': 'c-16', 'keyCode': 26}), peer);

      final ack = (await sentOf(RcEvt.inputAck)).single;
      expect(ack.payload['ok'], isFalse);
      expect(ack.payload['message'], contains('注入未被受理'));
      expect(await hasLog('input.key', 'failed'), isTrue);
    });

    test('RDH-C8 ★ 会话停止后携旧 castId 的输入一律拒（会话失效锁 G4）', () async {
      await establishControlSession('c-17');
      await svc.debugDispatch(
          cmd(RcCmd.screenCastStop, {'castId': 'c-17'}), peer);
      nativeCalls.clear();
      fake.sentWires.clear();

      await svc.debugDispatch(
          cmd(RcCmd.inputTap, {'castId': 'c-17', 'x': 0.5, 'y': 0.5}), peer);

      expect(calledNative('inputTap'), isFalse,
          reason: '会话已停，旧 castId 的输入必须拒 —— 杜绝"停了还能操作"');
      expect((await sentOf(RcEvt.inputAck)).single.payload['ok'], isFalse);
    });
  });

  // ───────────────────────── 控制器改名 _handleDeviceRename ─────────────────────────

  group('RDH-D device.rename', () {
    RcMessage rename(String from, String name) => RcMessage(
          id: 'rename-${from.hashCode}-${name.hashCode}',
          ts: DateTime.now().millisecondsSinceEpoch,
          type: RcCmd.deviceRename,
          payload: {'name': name},
          from: from,
        );

    test('RDH-D1 合法改名 → 配对表原位更新 + success 审计', () async {
      await svc.debugDispatch(rename(peer.deviceId, '客厅手机'), peer);

      expect(endpointById(store.paired(), peer.deviceId)?.name, '客厅手机');
      expect(await hasLog('device.rename', 'success', contains: '名称已更新'),
          isTrue);
      expect((await sentOf(RcEvt.ack)).single.payload['ok'], isTrue);
    });

    test('RDH-D2 空名 / 超 32 字符 → 拒绝且配对表不动', () async {
      await svc.debugDispatch(rename(peer.deviceId, '   '), peer);
      expect(endpointById(store.paired(), peer.deviceId)?.name, peer.name,
          reason: '空名必须拒，且不得改写既有名称');

      await svc.debugDispatch(rename(peer.deviceId, 'x' * 33), peer);
      expect(endpointById(store.paired(), peer.deviceId)?.name, peer.name);
      expect(await hasLog('device.rename', 'success'), isFalse);
    });

    test('RDH-D3 送方不在配对表 → 拒绝（不静默写入陌生设备）', () async {
      await svc.debugDispatch(rename('GHOST00000000', '伪装'), peer);

      expect(store.paired().any((p) => p.name == '伪装'), isFalse);
      expect(await hasLog('device.rename', 'failed', contains: '不在配对表内'),
          isTrue);
      // 回执**点名**发给一个不在配对表里的 deviceId ⇒ 出站必须显式丢弃留痕，
      // 绝不"退而求其次广播给所有人"（跨控制器泄露）。
      expect(await sentOf(RcEvt.ack), isEmpty);
      expect(await hasLog(RcEvt.ack, 'skipped', contains: '不在配对表'), isTrue);
    });
  });
}
