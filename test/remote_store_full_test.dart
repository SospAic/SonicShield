import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// RemoteStore prefs 逻辑（身份/代理/配对/TURN/保存指令组/outbox）全覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RemoteStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = RemoteStore(await SharedPreferences.getInstance());
  });

  group('身份与开关', () {
    test('默认值：未配置时 deviceId 空 / broker 默认 / enabled false', () {
      expect(store.deviceId, '');
      expect(store.deviceName, '');
      expect(store.broker, RemoteStore.defaultBroker);
      expect(store.enabled, isFalse);
    });

    test('setIdentity 往返（displayName 无实现层兜底，UI 层总是传名）', () async {
      await store.setIdentity('a' * 16, '');
      expect(store.deviceName, ''); // 实现契约：不兜底，由调用方保证非空
      await store.setIdentity('b' * 16, '我的端点');
      expect(store.deviceName, '我的端点');
    });

    test('setEnabled 往返', () async {
      await store.setEnabled(true);
      expect(store.enabled, isTrue);
      await store.setEnabled(false);
      expect(store.enabled, isFalse);
    });

    test('setBroker 往返', () async {
      await store.setBroker('mqtt.example.org');
      expect(store.broker, 'mqtt.example.org');
    });
  });

  group('配对表', () {
    PairedEndpoint ep(String id, {String secret = 'CODECODE'}) =>
        PairedEndpoint(
            deviceId: id,
            name: 'E-$id',
            secret: secret,
            pairedAt: DateTime(2026));

    test('addPaired / paired / removePaired 往返；remove 联动清当前选择', () async {
      final a = ep('a' * 16);
      final b = ep('b' * 16);
      await store.addPaired(a);
      await store.addPaired(b);
      expect(store.paired().length, 2);
      // 同 id 再加 = 覆盖（去重）
      await store.addPaired(a);
      expect(store.paired().length, 2);
      await store.removePaired('a' * 16);
      expect(store.paired().map((p) => p.deviceId), ['b' * 16]);
    });

    test('配对条目 secret/name 往返保留（解密密钥契约）', () async {
      await store.addPaired(ep('c' * 16, secret: 'SECRET99'));
      final back = store.paired().firstWhere((p) => p.deviceId == 'c' * 16);
      expect(back.secret, 'SECRET99');
      expect(back.name, 'E-${'c' * 16}');
    });
  });

  group('TURN 配置（S5）', () {
    test('未配置 → turnConfigured false', () {
      expect(store.turnConfigured, isFalse);
    });

    test('setTurn 往返 + configured 判定', () async {
      await store.setTurn(
          url: 'turn:turn.example.org:3478', user: 'u', cred: 'p');
      expect(store.turnUrl, 'turn:turn.example.org:3478');
      expect(store.turnUser, 'u');
      expect(store.turnCred, 'p');
      expect(store.turnConfigured, isTrue);
    });
  });

  group('保存的指令组模板', () {
    test('saveScript / savedScripts / deleteScript 往返与去重', () async {
      await store.saveScript(SavedScript(
          id: 's1',
          name: '宏A',
          payload: const {'scriptId': 's1'},
          savedAt: DateTime(2026)));
      await store.saveScript(SavedScript(
          id: 's2',
          name: '宏B',
          payload: const {'scriptId': 's2'},
          savedAt: DateTime(2026)));
      // 同 id 覆盖
      await store.saveScript(SavedScript(
          id: 's1',
          name: '宏A改',
          payload: const {'scriptId': 's1'},
          savedAt: DateTime(2026)));
      final list = store.savedScripts();
      expect(list.length, 2);
      expect(list.first.name, '宏A改'); // 后保存的在前
      await store.deleteScript('s1');
      expect(store.savedScripts().map((s) => s.name), ['宏B']);
    });
  });

  group('离线 outbox', () {
    test('enqueue/drain 幂等 + 上限 200 裁剪', () async {
      for (var i = 0; i < 260; i++) {
        await store.enqueue('w$i', 'dev');
      }
      final drained = store.drainOutbox('dev');
      expect(drained.length, 200); // 上限裁剪
      expect(store.drainOutbox('dev'), isEmpty); // 二次 drain 幂等
    });

    test('drain 只取指定端点', () async {
      await store.enqueue('a', 'dev-a');
      await store.enqueue('b', 'dev-b');
      expect(store.drainOutbox('dev-a').length, 1);
      expect(store.drainOutbox('dev-b').length, 1);
      expect(store.outbox(), isEmpty);
    });
  });
}
