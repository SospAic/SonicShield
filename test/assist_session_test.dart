import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/assist.dart';

/// 临时协助会话（v1.7，docs/18）契约测试。
///
/// 重点锁定两类不变量：
/// 1. **安全核心**：会合主题必须同时依赖 临时码 + 密码，
///    只知临时码者无法算出主题（从而无法观测握手密文、无离线爆破素材）；
/// 2. **合规红线**：权限默认全拒、会话一次性且短 TTL。
void main() {
  group('AS 凭据生成与归一化', () {
    test('AS-01 临时码为 9 位纯数字且自校验通过', () {
      for (var i = 0; i < 50; i++) {
        final code = RcAssist.generateCode();
        expect(code.length, 9, reason: '长度必须为 9');
        expect(RegExp(r'^[0-9]{9}$').hasMatch(code), isTrue,
            reason: '必须全为数字：$code');
        expect(RcAssist.isValidCode(code), isTrue);
      }
    });

    test('AS-02 访问密码为 8 位且全在 Crockford 字母表内', () {
      const alphabet = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        final pw = RcAssist.generatePassword();
        expect(pw.length, 8);
        expect(pw.split('').every(alphabet.contains), isTrue,
            reason: '含字母表外字符：$pw');
        expect(RcAssist.isValidPassword(pw), isTrue);
        seen.add(pw);
      }
      // 50 次生成不应大量碰撞（40bit 熵，碰撞概率可忽略）
      expect(seen.length, greaterThan(45), reason: '随机性不足');
    });

    test('AS-03 临时码归一化：剔除空格与连字符', () {
      expect(RcAssist.normalizeCode('123 456 789'), '123456789');
      expect(RcAssist.normalizeCode('123-456-789'), '123456789');
      expect(RcAssist.normalizeCode(' 123456789 '), '123456789');
    });

    test('AS-04 密码归一化：大写 + 去分隔符 + 剔除字母表外字符', () {
      // 小写转大写
      expect(RcAssist.normalizePassword('abcd2345'), 'ABCD2345');
      // 带分隔符（用户常按 4-4 分组抄写）
      expect(RcAssist.normalizePassword('ABCD-2345'), 'ABCD2345');
      expect(RcAssist.normalizePassword('ABCD_2345'), 'ABCD2345');
      expect(RcAssist.normalizePassword('ABCD 2345'), 'ABCD2345');
      // 字母表外字符（I/L/O/U/0/1）被剔除——本字母表已排除这些易混字符
      expect(RcAssist.normalizePassword('AICD2345'), 'ACD2345');
      expect(RcAssist.normalizePassword('AOCD2345'), 'ACD2345');
      expect(RcAssist.normalizePassword('AUCD2345'), 'ACD2345');
      expect(RcAssist.normalizePassword('ABCD2340'), 'ABCD234');
    });

    test('AS-04b 归一化结果应可通过合法性校验（真实输入路径）', () {
      final pw = RcAssist.generatePassword();
      final messy = '${pw.substring(0, 4).toLowerCase()}-${pw.substring(4)}';
      expect(
          RcAssist.isValidPassword(RcAssist.normalizePassword(messy)), isTrue);
    });

    test('AS-04c 非法输入应被拒', () {
      expect(RcAssist.isValidCode('12345678'), isFalse, reason: '少一位');
      expect(RcAssist.isValidCode('1234567890'), isFalse, reason: '多一位');
      expect(RcAssist.isValidCode('12345678a'), isFalse, reason: '含非数字');
      expect(RcAssist.isValidPassword('ABCD234'), isFalse, reason: '少一位');
      expect(RcAssist.isValidPassword('ABCD23456'), isFalse, reason: '多一位');
    });
  });

  group('AS 会合主题（安全核心）', () {
    const code = '123456789';
    const pw = 'ABCD2345';

    test('AS-05 主题格式与确定性', () async {
      final t1 = await RcAssist.topicFor(code, pw);
      final t2 = await RcAssist.topicFor(code, pw);
      expect(t1, t2, reason: '同输入必须同主题（双方独立算出同值）');
      expect(t1.startsWith(RcAssist.topicPrefix), isTrue);
      final hash = t1.substring(RcAssist.topicPrefix.length);
      expect(hash.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(hash), isTrue);
    });

    test('AS-06 同一临时码 + 不同密码 → 主题不同', () async {
      final a = await RcAssist.topicFor(code, 'ABCD2345');
      final b = await RcAssist.topicFor(code, 'WXYZ6789');
      expect(a, isNot(b), reason: '主题必须依赖密码；否则攻击者可枚举临时码订阅全部会话');
    });

    test('AS-07 同一密码 + 不同临时码 → 主题不同', () async {
      final a = await RcAssist.topicFor('123456789', pw);
      final b = await RcAssist.topicFor('987654321', pw);
      expect(a, isNot(b));
    });

    test('AS-08 主题不可由临时码单独推导（防离线爆破的核心性质）', () async {
      final topic = await RcAssist.topicFor(code, pw);
      // 攻击者只知 code 时能想到的最强猜测：直接用 code 做摘要
      final naive = await Sha256().hash(utf8.encode(code));
      final naiveHex =
          naive.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final naiveTopic = '${RcAssist.topicPrefix}${naiveHex.substring(0, 16)}';
      expect(topic, isNot(naiveTopic),
          reason: '若直接用临时码派生主题，攻击者可枚举 30bit 主题收集密文离线爆破');

      // 更强的断言：任何"只依赖 code"的派生都不应等于真实主题
      for (final guess in ['$code|', '|$code', code, code.toUpperCase()]) {
        final h = await Sha256().hash(utf8.encode(guess));
        final hex =
            h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        expect(topic, isNot('${RcAssist.topicPrefix}${hex.substring(0, 16)}'));
      }
    });

    test('AS-09 主题对密码敏感（任一字符变化都换主题）', () async {
      final base = await RcAssist.topicFor(code, 'ABCD2345');
      // 字母表内任一位置替换
      for (final alt in ['BBCD2345', 'ABCD2346', 'ZBCD2345']) {
        expect(await RcAssist.topicFor(code, alt), isNot(base));
      }
    });
  });

  group('AS 会话密钥', () {
    const code = '123456789';
    const pw = 'ABCD2345';

    test('AS-10 双方独立派生得到相同密钥（对称性）', () async {
      // 控制端与端点各自用自己的输入派生，必须一致
      final ctl1 = await RcAssist.ctlKey(code, pw);
      final ctl2 = await RcAssist.ctlKey(code, pw);
      expect(ctl1, ctl2);
      expect(ctl1.length, 32, reason: 'AES-256 需 32 字节');
    });

    test('AS-11 方向隔离：ctlKey 与 epKey 必须不同', () async {
      final ctl = await RcAssist.ctlKey(code, pw);
      final ep = await RcAssist.epKey(code, pw);
      expect(ctl, isNot(ep), reason: '每方向独立密钥，防同密钥双向复用');
    });

    test('AS-12 密码错误 → 密钥不同（无法解密对端消息）', () async {
      final right = await RcAssist.ctlKey(code, 'ABCD2345');
      final wrong = await RcAssist.ctlKey(code, 'WXYZ6789');
      expect(right, isNot(wrong));
    });

    test('AS-13 会话主密钥与方向密钥互不相同', () async {
      final secret = await RcAssist.sessionSecret(code, pw);
      final ctl = await RcAssist.ctlKey(code, pw);
      expect(secret.length, 32);
      expect(secret, isNot(ctl));
    });
  });

  group('AS 合规红线', () {
    test('AS-14 权限默认全拒（C5）', () {
      const p = AssistPerms.none;
      final j = p.toJson();
      expect(j.values.every((v) => v == false), isTrue,
          reason: '会话建立时不得放行任何能力');
      // 显式构造的默认值也必须全 false
      const d = AssistPerms();
      expect(d.toJson().values.every((v) => v == false), isTrue);
    });

    test('AS-15 权限 JSON 往返不丢失', () {
      const p = AssistPerms(media: true, volume: true, script: true);
      final back = AssistPerms.fromJson(p.toJson());
      expect(back.media, isTrue);
      expect(back.volume, isTrue);
      expect(back.script, isTrue);
      expect(back.tts, isFalse);
      expect(back.location, isFalse);
      expect(back.video, isFalse);
      expect(back.vibrate, isFalse);
    });

    test('AS-16 权限位含全部 8 项且有中文标签', () {
      final keys = AssistPerms.none.toJson().keys.toSet();
      expect(keys.length, 8);
      for (final k in keys) {
        expect(AssistPerms.labels.containsKey(k), isTrue,
            reason: '权限位 $k 缺少 UI 标签');
      }
    });

    test('AS-17 会话默认 TTL 为 10 分钟且未过期', () {
      final s = AssistSession(
        code: '123456789',
        password: 'ABCD2345',
        topic: 'sonicshield/v1/assist/0123456789abcdef',
        expiresAt: DateTime.now().add(RcAssist.defaultTtl),
      );
      expect(RcAssist.defaultTtl, const Duration(minutes: 10));
      expect(s.expired, isFalse);
      expect(s.usable, isTrue);
      expect(s.phase, AssistPhase.waiting);
      expect(s.perms.toJson().values.every((v) => v == false), isTrue);
    });

    test('AS-18 失败达上限即作废（防在线猜测）', () {
      final s = AssistSession(
        code: '123456789',
        password: 'ABCD2345',
        topic: 'sonicshield/v1/assist/0123456789abcdef',
        expiresAt: DateTime.now().add(RcAssist.defaultTtl),
      );
      expect(RcAssist.maxFailures, 5);
      for (var i = 0; i < RcAssist.maxFailures - 1; i++) {
        expect(s.registerFailure(), isFalse, reason: '第 ${i + 1} 次未达上限');
      }
      expect(s.registerFailure(), isTrue, reason: '第 5 次应达上限');
      expect(s.locked, isTrue);
      expect(s.usable, isFalse, reason: '锁定后不可再用');
      expect(s.phase, AssistPhase.closed);
    });

    test('AS-19 TTL 到期即不可用', () {
      final s = AssistSession(
        code: '123456789',
        password: 'ABCD2345',
        topic: 'sonicshield/v1/assist/0123456789abcdef',
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      expect(s.expired, isTrue);
      expect(s.usable, isFalse);
      expect(s.remaining, Duration.zero, reason: '剩余时长不得为负');
    });

    test('AS-20 协议消息类型命名空间正确', () {
      expect(RcAssistCmd.hello, 'assist.hello');
      expect(RcAssistCmd.accept, 'assist.accept');
      expect(RcAssistCmd.reject, 'assist.reject');
      expect(RcAssistCmd.perm, 'assist.perm');
      expect(RcAssistCmd.close, 'assist.close');
    });

    test('AS-20b 不得保留"从不发出"的 rc.assist 死常量（P1-1 回归锁）', () {
      // 该常量全仓除定义外只有一条字面量断言，无任何生产侧发出/消费 ——
      // 保留它比删除更糟（让人以为"状态镜像已实现"）。若日后要真正做状态镜像，
      // 必须连同控制端的消费方一起提交。
      final src = File('lib/remote/assist.dart').readAsStringSync();
      expect(src.contains("'rc.assist'"), isFalse,
          reason: 'RcAssistCmd.state 已被删除，不得复活');
    });
  });
}
