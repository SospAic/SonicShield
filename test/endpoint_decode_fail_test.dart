import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';

import 'support/source_text.dart';

void main() {
  group('R-2 DecodeFailThrottle：同主题 10s 一条', () {
    test('DF-01 首次放行，窗口内一律不放行', () {
      final t = DecodeFailThrottle();
      expect(t.allow('t/cmd', 1000), isTrue);
      expect(t.allow('t/cmd', 1001), isFalse);
      expect(t.allow('t/cmd', 9999), isFalse);
      expect(t.allow('t/cmd', 10999), isFalse,
          reason: '差 1ms 到窗口仍应抑制 —— 错码命令会被反复补发，'
              '差一点点就放行等于没限频');
    });

    test('DF-02 窗口边界：正好 10s 之后放行', () {
      final t = DecodeFailThrottle();
      expect(t.allow('t/cmd', 1000), isTrue);
      expect(t.allow('t/cmd', 11000), isTrue);
    });

    test('DF-03 按**主题**独立：另一主题不受影响（多端点/多主题互不牵连）', () {
      final t = DecodeFailThrottle();
      expect(t.allow('ep1/cmd', 1000), isTrue);
      expect(t.allow('ep2/cmd', 1000), isTrue,
          reason: '不同主题各自限频；共用一个窗口会把"另一台设备也配错了"藏起来');
      expect(t.allow('ep1/cmd', 1000), isFalse);
    });

    test('DF-04 窗口可配置（默认 10s，测试与将来调参都不必改判据）', () {
      expect(DecodeFailThrottle().windowMs, 10000);
      final t = DecodeFailThrottle(windowMs: 100);
      expect(t.allow('t', 0), isTrue);
      expect(t.allow('t', 99), isFalse);
      expect(t.allow('t', 100), isTrue);
    });
  });

  group('R-2 端点侧接线锁（源码契约）', () {
    final src = File('lib/remote/endpoint_service.dart').readAsStringSync();

    test('DF-05 _handleRaw 的 decode==null 分支不再静默', () {
      final raw = methodBody(src, 'Future<void> _handleRaw(');
      expect(raw, isNot(contains('if (msg == null) return;')),
          reason: '旧形状：静默 return ⇒ 配对码录错时端点零痕迹');
      expect(raw, contains('_auditDecodeFail(topic)'));
    });

    test('DF-06 审计的动作名与文案是约定的那一对', () {
      final audit = methodBody(src, 'Future<void> _auditDecodeFail(');
      expect(audit, contains("action: 'decode.fail'"));
      expect(audit, contains('密钥不匹配（配对码可能录错）'),
          reason: '文案必须直指"配对码"：写"解密失败"用户只会去查网络');
      expect(audit, contains('_decodeFail.allow('),
          reason: '必须走限频器，否则错码命令的每次补发都写一条');
    });

    test('DF-07 ⚠️ 只在 cmd 主题审计，不在 evt 主题审计（防心跳噪声）', () {
      // ⚠️ 这里**不能**用 methodBody：`_handlePeerEvent` 体内有字符串字面量
      // `'{'`（识别 LWT 明文哨兵用），朴素的大括号计数器会把它算成真括号，
      // 于是匹配范围越界、把后面几个方法一起吞进来（实测：连 `decode.fail`
      // 都被算作"在这个方法里"）。改用"到下一个方法声明为止"的切片。
      final start = src.indexOf('Future<void> _handlePeerEvent(');
      final end = src.indexOf('void _rememberSeen(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final peerEvent = src.substring(start, end);

      expect(peerEvent, contains('if (msg == null) return;'),
          reason: '广播型事件是"每个已配对端点各一份密文"发到同一 evt 主题的，'
              '端点侧解不开**别人**那一份是正常现象；在那里记会变成每 60s 一条的'
              '噪声，把真正需要被看见的那条淹掉');
      expect(peerEvent, isNot(contains('decode.fail')));
      expect(peerEvent, isNot(contains('_auditDecodeFail')));
    });
  });
}
