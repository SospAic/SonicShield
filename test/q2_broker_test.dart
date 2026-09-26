// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/source_text.dart';

/// **Q2.B 用户自带 broker 回归锁**。
///
/// ## 背景
///
/// 远程遥控此前只支持固定公共 broker（`broker.emqx.io`，TLS 8883）。
/// Q2.B 拍板：支持用户自带 broker —— host/port/用户名/密码**全配置化**，
/// 但**默认行为必须一字不变**：不配置时 `store.broker` 返回原公共地址。
///
/// ## 本锁锁什么
///
/// | 组 | 不变量 |
/// |---|---|
/// | STORE | 四个新字段（`brokerHost`/`brokerPort`/`brokerUsername`/`brokerPassword`）的默认值、覆盖语义与往返持久化 |
/// | FALLBACK | `broker` getter 的回落链：brokerHost → rc_broker → defaultBroker，未配置时与旧版完全一致 |
/// | SRC | 剥注释后 `remote_store.dart` 必须含四个新字段名（防"字段被顺手删掉"） |
///
/// ⚠️ **诚实声明能力边界**：SRC 组是源码文本锁，只保证字段**存在**；
/// 「未配置回落默认」这类**行为**由 STORE/FALLBACK 组的行为测试兜住
/// （见文件末尾注释的变异证伪分析）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final storeSrc = File('lib/remote/remote_store.dart').readAsStringSync();

  // **剥掉注释**再做文本扫描 —— 本锁能被信任的前提。
  //
  // 本项目刻意在注释里写明字段名与理由；不剥注释的话，锁会把**说明文字**
  // 当成违规证据（假红），于是下一个人只会去删注释 —— 锁变成负资产。
  //
  // 实现见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源）。

  /// 四个新字段名**全部**出现在剥注释后的源码里才算过。
  bool hasAllBrokerFields(String src) {
    const fields = [
      'brokerHost',
      'brokerPort',
      'brokerUsername',
      'brokerPassword',
    ];
    for (final f in fields) {
      if (!src.contains(f)) return false;
    }
    return true;
  }

  // ════════════════════════════════════════ STORE · 存储层行为
  group('QB-STORE 存储层行为', () {
    late RemoteStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = RemoteStore(await SharedPreferences.getInstance());
    });

    test('QB-01 默认全空 → broker 返回原公共地址（一字不变）', () {
      expect(store.brokerHost, isEmpty);
      expect(store.brokerPort, isNull);
      expect(store.brokerUsername, isEmpty);
      expect(store.brokerPassword, isEmpty);
      // ★ 默认行为不变异：未配置时必须还是公共演示节点。
      expect(store.broker, RemoteStore.defaultBroker);
    });

    test('QB-02 配置自定义 host 后 broker 返回自定义值', () async {
      await store.setBrokerAdvanced(
          host: 'mqtt.example.com',
          port: 8884,
          username: 'u1',
          password: 'p1');

      expect(store.brokerHost, 'mqtt.example.com');
      expect(store.broker, 'mqtt.example.com',
          reason: '配置了自定义 host，broker getter 应优先返回它');
      expect(store.brokerPort, 8884);
      expect(store.brokerUsername, 'u1');
      expect(store.brokerPassword, 'p1');
    });

    test('QB-03 port 默认 null（=回落默认 TLS 8883），显式配置才覆盖', () async {
      expect(store.brokerPort, isNull,
          reason: 'null 语义 = 用 RemoteStore.defaultBrokerPort（8883）');
      expect(RemoteStore.defaultBrokerPort, 8883);

      await store.setBrokerAdvanced(host: 'mqtt.example.com', port: 9001);
      expect(store.brokerPort, 9001);

      // 端口传 null / 非正数 → 清除回落默认（不许有"存了 0"这种脏值）。
      await store.setBrokerAdvanced(host: 'mqtt.example.com');
      expect(store.brokerPort, isNull);
      await store.setBrokerAdvanced(host: 'mqtt.example.com', port: -1);
      expect(store.brokerPort, isNull);
    });

    test('QB-04 四字段往返持久化（新实例读回）', () async {
      final prefs = await SharedPreferences.getInstance();
      await RemoteStore(prefs).setBrokerAdvanced(
          host: ' mqtt.example.org ',
          port: 9883,
          username: ' sonic ',
          password: 's3cr3t');

      // 新实例（模拟重启后）从同一份 prefs 读回。
      final back = RemoteStore(await SharedPreferences.getInstance());
      expect(back.brokerHost, 'mqtt.example.org', reason: 'host 去首尾空白');
      expect(back.brokerPort, 9883);
      expect(back.brokerUsername, 'sonic', reason: '用户名去首尾空白');
      expect(back.brokerPassword, 's3cr3t', reason: '密码原样保存（可能含空白）');
    });

    test('QB-05 host 传空串即整体清除，回到默认公共（且旧 rc_broker 不受损）', () async {
      await store.setBroker('legacy.broker.example.com');
      await store.setBrokerAdvanced(
          host: 'mqtt.example.com',
          port: 8884,
          username: 'u',
          password: 'p');
      expect(store.broker, 'mqtt.example.com');

      await store.setBrokerAdvanced(host: '');

      expect(store.brokerHost, isEmpty);
      expect(store.brokerPort, isNull);
      expect(store.brokerUsername, isEmpty);
      expect(store.brokerPassword, isEmpty);
      // 回落链下一级：rc_broker 仍在 → 回到用户旧设的地址；再无才回落公共。
      expect(store.broker, 'legacy.broker.example.com');
    });

    test('QB-06 broker 配置与配对表 / TURN 互不干扰', () async {
      await store.setBrokerAdvanced(
          host: 'mqtt.example.com',
          port: 8884,
          username: 'u',
          password: 'p');
      await store.addPaired(PairedEndpoint(
          deviceId: '0123456789abcdef',
          name: '端点',
          secret: 'AB2CD5EF',
          pairedAt: DateTime.now()));
      await store.setTurn(url: 'turn:x:3478', user: '', cred: '');

      expect(store.brokerHost, 'mqtt.example.com');
      expect(store.paired(), hasLength(1));
      expect(store.turnConfigured, isTrue);
    });
  });

  // ════════════════════════════════════════ SRC · 源码锁
  group('QB-SRC 源码锁（剥注释后）', () {
    test('QB-07 remote_store.dart 必须含四个新 broker 字段名', () {
      final code = stripComments(storeSrc);
      expect(hasAllBrokerFields(code), isTrue,
          reason: 'Q2.B 的四个字段（brokerHost/brokerPort/brokerUsername/'
              'brokerPassword）是连接侧接线的契约 —— 缺任何一个，'
              '主线程按字段名接线就会编译失败或读到空值');
    });

    test('QB-08 broker getter 必须引用 brokerHost（回落逻辑不可整段删除）', () {
      // 只看 getter 本体附近，不靠全文 contains（字段 getter 自己也含该名，
      // 那样这条锁会恒真）。取 `String get broker` 到下一个 `}` 之间的片段。
      final code = stripComments(storeSrc);
      final i = code.indexOf('String get broker {');
      expect(i, greaterThan(0),
          reason: 'broker getter 应保持块体形式（含回落判断）');
      final end = code.indexOf('\n  }', i);
      expect(end, greaterThan(i));
      final body = code.substring(i, end);
      expect(body.contains('brokerHost'), isTrue,
          reason: '「未配置自定义 host 时返回原公共地址」的回落必须真的引用 '
              'brokerHost，否则自定义 host 永远不生效（假实现）');
    });

    test('QB-09 反例样本：检测函数对缺失样本必须返回 false', () {
      // 证明 hasAllBrokerFields 不是恒真 —— 缺任何一个字段都抓得住。
      expect(hasAllBrokerFields(''), isFalse);
      expect(hasAllBrokerFields('String get brokerHost => "";'), isFalse,
          reason: '只写一个字段不够');
      expect(
          hasAllBrokerFields('brokerHost brokerPort brokerUsername'), isFalse,
          reason: '缺 brokerPassword 必须红');
      // 正例对照（防反例把函数改成恒 false）。
      expect(
          hasAllBrokerFields(
              'brokerHost brokerPort brokerUsername brokerPassword'),
          isTrue);
    });
  });
}

/// ## 变异证伪（纸面推演）
///
/// | 变异 | 会红哪条 |
/// |---|---|
/// | 删掉 `broker` getter 里的「未配置返回默认」回落（直接 `return brokerHost`） | **QB-01** 红（默认空时 `broker` 变空串而非 `broker.emqx.io`）；既有 `remote_store_full_test.dart` 的「默认 broker」断言同红 |
/// | 删掉整个回落分支（`broker` 只读 `rc_broker ?? defaultBroker`，忽略 host） | **QB-02** 红（配置后 `broker` 仍是公共地址）+ **QB-08** 红（getter 本体不再引用 brokerHost） |
/// | `brokerPort` 默认改成 0 而非 null | **QB-03** 红（`isNull` 断言失败） |
/// | `setBrokerAdvanced` 不再 trim host/username | **QB-04** 红（往返读到带空白原值） |
/// | 端口非正数时仍写入而非清除 | **QB-03** 红（`port: -1` 后仍非 null） |
/// | 整段删除四个字段 | **QB-07** 红 + 编译期即失败（连接侧与 QB-STORE 全组引用这些名字） |
/// | `hasAllBrokerFields` 被改成恒 true | **QB-09** 红（反例样本） |
/// | QB-08 的 getter 本体提取被改成全文 contains | **QB-08 自身退化为恒真** —— 这正是 QB-08 里"不靠全文 contains"注释存在的原因；反例由 QB-09 对检测函数的正/反对照兜住 |
