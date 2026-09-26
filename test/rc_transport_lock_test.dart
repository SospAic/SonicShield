// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/source_text.dart';

/// **远程遥控传输层锁**（第三十四轮，C-13 P0）。
///
/// ## 缺陷形状（实测发现的 P0，不是推测）
///
/// `lib/remote/endpoint_service.dart` 的 `_connect()` 此前是：
///
/// ```dart
/// _client = MqttServerClient.withPort(store.broker, deviceId, 1883)
///   ..port = 1883
/// ```
///
/// —— **明文 1883**。而同一个文件的类注释写着「传输：MQTT（TLS）」，docs/14 的
/// 架构图也画着 `MQTT/TLS`。也就是说：**文档声称加密，代码在裸奔**。
///
/// ## 为什么"业务已经是 E2E 加密"不能替代 TLS
///
/// | 攻击面 | E2E（AES-256-GCM） | TLS |
/// |---|---|---|
/// | broker 看内容 | ✅ 挡住 | ✅ 挡住 |
/// | 链路上看**元数据**（谁和谁通信、消息长度/时序、`clientId` 里的设备 ID） | ❌ 完全无能为力 | ✅ 挡住 |
/// | 链路**篡改**信封 | ❌ 能改（改了会被 GCM 拒，但连接被打断/降级仍可能） | ✅ 挡住 |
/// | 链路**丢弃/抑制**信封（例如把 `script.stop` 丢掉） | ❌ **没有任何防线** | ✅ 挡住 |
///
/// 重放有 ±90s 时间窗 + 消息 ID 去重挡着，但**抑制**（"什么都不做"）在 E2E 之下
/// 是无解的 —— 这正是 TLS 不可省的理由。
///
/// ## 本锁锁什么
///
/// | 组 | 不变量 |
/// |---|---|
/// | PORT  | broker 端口常量恰为 **8883**，且**不是**任何明文端口 |
/// | TLS   | 客户端构造处出现 `secure = true`，且**不出现** `onBadCertificate` |
/// | PLAIN | 整个 `lib/` 里**不再出现** 1883 / 明文 `withPort(..., 1883)` |
/// | DOC   | 协议文件头不再把 TLS 当作"未来时"，而是与实现一致 |
///
/// ⚠️ **诚实声明本锁的能力边界**：这是**源码文本锁**，不是 TLS 测试。
/// 它能抓住「有人把端口改回明文」「有人加了忽略证书的回调」这类**回归**；
/// 抓不住「证书链校验在真机上是否真的生效」。后者只能靠真机 + 抓包取证
/// （本轮**没有**做，已在 docs/14 的诚实边界里写明）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final endpointSrc = File('lib/remote/endpoint_service.dart').readAsStringSync();
  final protocolSrc = File('lib/remote/protocol.dart').readAsStringSync();

  /// 收集 `lib/` 下所有 Dart 源码（本锁的 PLAIN 组要**全量**扫，不能只看一个文件）。
  ///
  /// ⚠️ `listSync` 在 Windows 上给的是反斜杠路径，统一归一成正斜杠再做字符串比较
  /// —— 否则"路径写法不同"会被误报成"多了一个构造点"（假红）。
  List<File> allLibDart() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  String norm(String p) => p.replaceAll(r'\', '/');

  // **剥掉注释**再做文本扫描 —— 这是本锁能被信任的前提。
  //
  // 本项目刻意在 `lib/` 的注释里**写明**"不要再出现 1883 / onBadCertificate"
  // 以及其理由。若不剥注释，锁会把自己的**说明文字**当成违规（假红），
  // 于是下一个人只会去删注释 —— 把最有价值的"为什么"删掉，锁反而变成负资产。
  //
  // 字符串字面量整段保留（字符串里的 `1883` 仍然是**代码级**的违规，必须被抓）。
  // 实现见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源 ——
  // 本文件此前是仓内 10 份逐字相同副本的"被抄源"，现已全部指向那里）。

  /// 需要纳入 PLAIN 扫描的目录：`lib/`（生产代码）+ 端到端工具与集成测试
  /// （它们**自己也是 MQTT 客户端**，控制端侧忘了同步 TLS 就等于实测工具废掉）。
  List<File> scannableDart() {
    final out = <File>[];
    for (final dir in ['lib', 'tool', 'integration_test']) {
      if (!Directory(dir).existsSync()) continue;
      out.addAll(Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')));
    }
    return out;
  }

  // ══════════════════════════════════════════════════════ PORT · 端口常量
  group('TL-PORT 端口常量', () {
    test('TL-01 broker 端口常量恰为 TLS 8883', () {
      expect(RemoteStore.defaultBrokerPort, 8883,
          reason: 'TLS 标准端口。改成 1883 就等于把明文装回来');
    });

    test('TL-02 端口常量不是任何明文 MQTT 端口', () {
      const plaintextPorts = <int>[1883, 8080, 80];
      expect(plaintextPorts.contains(RemoteStore.defaultBrokerPort), isFalse,
          reason: 'SonicShield 的遥控信道**不允许**存在明文端口这一档');
    });

    test('TL-03 客户端构造实际使用了该常量（而不是又写死一个数字）', () {
      expect(endpointSrc.contains('RemoteStore.defaultBrokerPort'), isTrue,
          reason: '常量定义了却不用 = 假修复；端口必须只有一个真源');
      // `withPort(` 的第三个实参必须就是该常量。
      final m = RegExp(r'MqttServerClient\.withPort\(([^)]*)\)')
          .firstMatch(endpointSrc);
      expect(m, isNotNull, reason: '源码里找不到 MqttServerClient.withPort 构造');
      expect(m!.group(1), contains('RemoteStore.defaultBrokerPort'));
    });
  });

  // ══════════════════════════════════════════════════════ TLS · 强制加密
  group('TL-TLS 强制加密与证书校验', () {
    test('TL-04 客户端级联里出现 secure = true', () {
      final i = endpointSrc.indexOf('MqttServerClient.withPort');
      expect(i, greaterThan(0));
      final cascade = endpointSrc.substring(i, i + 700);
      expect(cascade.contains('secure = true'), isTrue,
          reason: 'mqtt_client 只有在 secure=true 时才走 SecureSocket.connect');
    });

    test('TL-05 **不出现** onBadCertificate（一旦出现即为中间人后门）', () {
      // ⚠️ 必须剥注释：`endpoint_service.dart` 的 C-13 说明里**故意**写着
      // "不提供 onBadCertificate"，那是本锁的**理由**，不是违规。
      final offenders = <String>[];
      for (final f in scannableDart()) {
        if (stripComments(f.readAsStringSync()).contains('onBadCertificate')) {
          offenders.add(norm(f.path));
        }
      }
      expect(offenders, isEmpty,
          reason: '`mqtt_client` 在 secure=true 且 onBadCertificate 为 null 时，'
              '对无效/自签证书**握手直接失败**（fail-closed）。'
              '任何人加一个 `=> true` 的回调都是把"忽略证书"装回来。'
              'offenders=$offenders');
    });

    test('TL-06 不出现 securityContext 放宽（例如 withTrustedRoots: false 之后自建空上下文）', () {
      // 允许出现 securityContext（默认实现就是它），但**不允许**显式构造一个
      // 空信任根的上下文 —— 那等于"不校验任何证书"。
      final bad = RegExp(r'SecurityContext\s*\(\s*withTrustedRoots\s*:\s*false');
      expect(bad.hasMatch(stripComments(endpointSrc)), isFalse,
          reason: 'withTrustedRoots:false 的上下文没有任何受信根，等价于不校验');
    });

    test('TL-07 没有"关闭 TLS"的运行时开关（无 prefs 键可回落明文）', () {
      final storeSrc = File('lib/remote/remote_store.dart').readAsStringSync();
      final hasTlsToggle = RegExp(r'_k[A-Za-z]*Tls').hasMatch(storeSrc) ||
          RegExp(r'setBrokerUseTls|brokerUseTls').hasMatch(storeSrc);
      expect(hasTlsToggle, isFalse,
          reason: '存在一个可以在生产上悄悄关掉 TLS 的偏好项 = 明文后门。'
              'TLS 是硬约束，不是偏好（C-13）。');
    });
  });

  // ══════════════════════════════════════════════════════ PLAIN · 全量排查
  group('TL-PLAIN 明文端口全量排查（含端到端工具与集成测试）', () {
    test('TL-08 生产代码 + 端到端工具里不再出现 1883（剥注释后）', () {
      final offenders = <String>[];
      for (final f in scannableDart()) {
        final lines = stripComments(f.readAsStringSync()).split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('1883')) offenders.add('${norm(f.path)}:${i + 1}');
        }
      }
      expect(offenders, isEmpty,
          reason: '明文 MQTT 端口不应再出现在任何可执行 Dart 代码里 —— '
              '**包括 `tool/` 与 `integration_test/`**：它们自己也是 MQTT 客户端，'
              '控制端侧忘了同步 TLS，实测工具就会在 TLS-only 的 broker 上直接连不上 '
              '（"修完反而测不了"）。offenders=$offenders');
    });

    test('TL-09 不存在其它绕过常量的 MQTT 客户端构造点', () {
      // 生产代码里只允许 `_connect()` 里那一处。
      final hits = <String>[];
      for (final f in allLibDart()) {
        final n = RegExp(r'MqttServerClient\.withPort')
            .allMatches(stripComments(f.readAsStringSync()))
            .length;
        if (n > 0) hits.add('${norm(f.path)} ×$n');
      }
      expect(hits, equals(['lib/remote/endpoint_service.dart ×1']),
          reason: '多一个构造点就多一处可能忘记开 TLS 的地方。hits=$hits');
    });

    test('TL-13 ★ 每一个 MQTT 构造点（含工具/集成测试）都必须开 TLS', () {
      final offenders = <String>[];
      for (final f in scannableDart()) {
        final src = stripComments(f.readAsStringSync());
        for (final m
            in RegExp(r'MqttServerClient\.withPort').allMatches(src)) {
          // 从构造点往后取一段"级联语句"范围，检查里面有没有 secure = true。
          final seg = src.substring(
              m.start, (m.start + 600).clamp(0, src.length));
          if (!seg.contains('secure = true')) {
            final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
            offenders.add('${norm(f.path)}:$line');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '★ 只把生产代码改到 TLS、却漏掉工具/集成测试的客户端，'
              '等于"端点只认 TLS，而验证工具只会说明文" —— 本轮实测流程会整条断掉。'
              '每个构造点都必须是 secure = true。offenders=$offenders');
    });

    test('TL-10 协助会话不另起传输（复用同一客户端 → 同样受 TLS 约束）', () {
      // 协助会话（assist_host / assist_join）若自建 socket，就会绕过本锁。
      for (final name in ['assist_host.dart', 'assist_join.dart']) {
        final src = File('lib/remote/$name').readAsStringSync();
        expect(stripComments(src).contains('MqttServerClient'), isFalse,
            reason: '$name 不应自己 new 一个 MQTT 客户端（否则 TLS 约束不覆盖它）');
      }
    });
  });

  // ══════════════════════════════════════════════════════ DOC · 文档与实现一致
  group('TL-DOC 协议注释与实现一致', () {
    test('TL-11 protocol.dart 头部把传输写成 TLS 8883（而非含糊的"（TLS）"）', () {
      final i = protocolSrc.indexOf('/// 传输：');
      expect(i, greaterThan(0), reason: 'protocol.dart 头部应有"传输："一行');
      final line = protocolSrc.substring(i, protocolSrc.indexOf('\n', i));
      expect(line.contains('8883'), isTrue,
          reason: '应写明端口。含糊的"MQTT（TLS）"正是本次事故的温床：'
              '文档说 TLS、代码写 1883，两边都不算撒谎，但合起来是假的。line=$line');
    });

    test('TL-12 endpoint_service.dart 的端口必须来自共享常量（不许就地写死）', () {
      // ⚠️ 本条最初写成 `if (endpointSrc.contains('TLS')) { expect(...) }` ——
      // 那是**条件断言**：一旦注释里不再出现 TLS 字样，整条 expect 一行都不跑，
      // 用例**永久恒绿**。而 `endpoint_service.dart` 里 3 处 TLS 全在注释里
      // （子 Agent W5 实测核对），这个「前提」随时会因为**改注释**而翻转。
      // 现改为**直接断言 + 先剥注释**，与 TL-03 去重（那条锁的是 `secure`）。
      final code = stripComments(endpointSrc);
      expect(code.contains('RemoteStore.defaultBrokerPort'), isTrue,
          reason: '★ 端点必须引用共享常量取端口 —— 就地写死一个数字，'
              '就是"文档说 TLS、代码连 1883"那类事故的温床');
      expect(code.contains('MqttServerClient.withPort'), isTrue,
          reason: '前提：构造点必须显式指定端口（不指定的话走的是默认 1883）');

      final portLiterals = RegExp(r'\b(1883|8883)\b')
          .allMatches(code)
          .map((m) => m.group(0)!)
          .toList();
      expect(portLiterals, isEmpty,
          reason: '★ 剥注释后仍出现端口字面量 $portLiterals —— '
              '端口的唯一真源是 `lib/remote/protocol.dart` 的 `rcBrokerPort`，'
              '任何就地写死的端口都会让"改一处忘一处"重新成为可能');
    });
  });
}
