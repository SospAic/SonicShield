import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/device_name_service.dart';

/// FR-77「设备名称自定义 + 别名广播」的回归锁（第八十四轮用户明文）。
///
/// ## 需求拆成可断言的三条
///
/// 1. **本机改名 → 通知所有已绑定端点**（[DeviceNameService.renameLocal] 对
///    **每一个**已配对端点都下发一条 `device.rename`）；
/// 2. **别名只在本机显示**（别名的展示格式 `别名（真名）` 只在**本机**计算，
///    广播出去的载荷里**只有真名**，不含别名 —— 这是需求里的硬边界）；
/// 3. **名称校验失败不入库、不广播**（空名 / 超长一律拒绝，防静默写脏名）。
///
/// ## 为什么能测（干净缝）
///
/// 广播依赖 MQTT 发送（[RcEndpointService.sendTo]）—— 真发要起 broker。
/// 本文件用 [DeviceNameService.senderOverride] 注入宿主替身，**记录每条出站
/// 消息**并断言其形状。生产代码路径不变（未注入时走真实发送）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RemoteStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = RemoteStore(await SharedPreferences.getInstance());
  });

  PairedEndpoint ep(String id, {String name = '端点', String? alias}) =>
      PairedEndpoint(
        deviceId: id,
        name: name,
        secret: 's-$id',
        pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        alias: alias,
      );

  group('DNS 本机改名广播（FR-77）', () {
    test('DNS-01 改名 → 对每个已绑定端点各发一条 device.rename（含新名）',
        () async {
      await store.setIdentity('self000000000001', '旧名');
      await store.addPaired(ep('a', name: 'A 机'));
      await store.addPaired(ep('b', name: 'B 机'));

      final sent = <({String to, String type, String name})>[];
      DeviceNameService.instance.senderOverride = (e, msg, s) async {
        sent.add((
          to: e.deviceId,
          type: msg.type,
          name: (msg.payload['name'] as String?) ?? '',
        ));
        return true;
      };
      addTearDown(() => DeviceNameService.instance.senderOverride = null);

      final r = await DeviceNameService.instance.renameLocal('新名');
      expect(r.ok, isTrue);
      expect(r.total, 2);
      expect(r.sent, 2);
      expect(sent.length, 2, reason: '每个已绑定端点都要收到一条（用户明文：通知所有已绑定远程设备）');
      expect(sent.map((e) => e.to).toSet(), {'a', 'b'});
      expect(sent.every((e) => e.type == RcCmd.deviceRename), isTrue);
      expect(sent.every((e) => e.name == '新名'), isTrue,
          reason: '载荷里必须是新名');

      // 本机名已落盘（幂等：即使一台都没发出去，本机名也应生效）。
      expect(store.deviceName, '新名');
    });

    test('DNS-02 无已绑定端点 → 仅落盘，total/sent 均为 0（不谎报）', () async {
      await store.setIdentity('self000000000002', '旧名');
      DeviceNameService.instance.senderOverride = (e, m, s) async => true;
      addTearDown(() => DeviceNameService.instance.senderOverride = null);

      final r = await DeviceNameService.instance.renameLocal('孤名');
      expect(r.ok, isTrue);
      expect(r.total, 0);
      expect(r.sent, 0);
      expect(store.deviceName, '孤名', reason: '一台没发也要落盘（下次上线仍广播）');
    });

    test('DNS-03 端点离线 → sent < total（如实回报，不假成功）', () async {
      await store.setIdentity('self000000000003', '旧名');
      await store.addPaired(ep('online'));
      await store.addPaired(ep('offline'));

      DeviceNameService.instance.senderOverride =
          (e, m, s) async => e.deviceId == 'online';
      addTearDown(() => DeviceNameService.instance.senderOverride = null);

      final r = await DeviceNameService.instance.renameLocal('部分');
      expect(r.ok, isTrue);
      expect(r.total, 2);
      expect(r.sent, 1, reason: '离线端点没收到就要如实计入失败，不许报"全部同步"');
    });

    test('DNS-04 空名 / 纯空格 → 拒绝，且不落盘、不广播', () async {
      await store.setIdentity('self000000000004', '原名');
      await store.addPaired(ep('a'));

      var called = 0;
      DeviceNameService.instance.senderOverride = (e, m, s) async {
        called++;
        return true;
      };
      addTearDown(() => DeviceNameService.instance.senderOverride = null);

      final r = await DeviceNameService.instance.renameLocal('   ');
      expect(r.ok, isFalse);
      expect(r.error, isNotEmpty);
      expect(called, 0, reason: '校验不过不得广播');
      expect(store.deviceName, '原名', reason: '校验不过不得落盘（防静默脏名）');
    });

    test('DNS-05 超长名（> 32）→ 拒绝', () async {
      await store.setIdentity('self000000000005', '原名');
      final r = await DeviceNameService.instance.renameLocal('x' * 33);
      expect(r.ok, isFalse);
      expect(store.deviceName, '原名');
    });
  });

  group('DNS 别名只在本机（FR-77 硬边界）', () {
    test('DNS-06 广播载荷只含真名，绝不含别名', () async {
      await store.setIdentity('self000000000006', '旧名');
      // 本机给这台端点起了别名 —— 别名绝不能出现在出站载荷里。
      await store.addPaired(ep('a', name: '客厅电视', alias: '爸爸的电视'));

      final payloads = <Map<String, dynamic>>[];
      DeviceNameService.instance.senderOverride = (e, msg, s) async {
        payloads.add(Map<String, dynamic>.from(msg.payload));
        return true;
      };
      addTearDown(() => DeviceNameService.instance.senderOverride = null);

      await DeviceNameService.instance.renameLocal('新本机名');
      expect(payloads, isNotEmpty);
      for (final p in payloads) {
        expect(p.keys.contains('alias'), isFalse,
            reason: '别名只在本机显示，绝不能进广播载荷（FR-77 硬边界）');
        expect(p.values.join().contains('爸爸的电视'), isFalse,
            reason: '载荷值里也不得出现别名字样');
      }
    });

    test('DNS-07 别名的展示格式是「别名（真名）」，且只在本机计算', () {
      // 展示格式由 PairedEndpoint.displayName 决定 —— 本机视角。
      final e = ep('a', name: '客厅电视', alias: '爸爸的电视');
      expect(e.displayName, '爸爸的电视（客厅电视）');
      // 真名（对端上报、跨机一致）不受影响。
      expect(e.name, '客厅电视');
    });
  });
}
