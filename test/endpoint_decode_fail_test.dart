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

    test('DF-07 ⚠️ evt 主题解密失败改为**按来源双重抑制**审计（P2-22）', () {
      // ⚠️ 这里**不能**用 methodBody：`_handlePeerEvent` 体内有字符串字面量
      // `'{'`（识别 LWT 明文哨兵用），朴素的大括号计数器会把它算成真括号，
      // 于是匹配范围越界、把后面几个方法一起吞进来（实测：连 `decode.fail`
      // 都被算作"在这个方法里"）。改用"到下一个方法声明为止"的切片。
      // 切片终点取紧随 `_handlePeerEvent` 之后的 `_tapAck`（P1-13 新增）。
      final start = src.indexOf('Future<void> _handlePeerEvent(');
      final end = src.indexOf('Future<void> _tapAck(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final peerEvent = src.substring(start, end);

      // P2-22：旧的"静默 return"必须消失，改为按来源限频审计。
      expect(peerEvent, isNot(contains('if (msg == null) return;')),
          reason: '静默 return ⇒ 盐/配对码不一致时端点零痕迹（P2-22 要修的正是它）');
      expect(peerEvent, contains('_auditPeerEvtDecodeFail(peerId)'),
          reason: 'evt 解密失败要按**来源**留痕，否则控制端只看到超时');
      expect(peerEvent, isNot(contains('_auditDecodeFail(topic)')),
          reason: '不能复用 cmd 主题的审计器（按主题限频会把另一来源的故障藏起来）');
    });

    test('DF-08 peer evt 失败审计必须"按来源 + 最近成功"双重抑制', () {
      final audit = methodBody(src, 'Future<void> _auditPeerEvtDecodeFail(');
      expect(audit, contains('peerEvtFailWorthAudit('),
          reason: '缺"最近成功"抑制 ⇒ 健康设备被广播副本噪声刷爆（每 60s 一条心跳）');
      expect(audit, contains('_peerEvtFail.allow('),
          reason: '缺按来源限频 ⇒ 错误配置被反复补发时刷爆审计');
      expect(audit, contains("action: 'decode.fail'"));
    });

    test('DF-09 peerEvtFailWorthAudit 真值表（含窗口边界）', () {
      expect(peerEvtFailWorthAudit(lastOkMs: null, nowMs: 1000), isTrue,
          reason: '从未成功 ⇒ 值得记（正是"配对成功却全解不开"的形状）');
      expect(
          peerEvtFailWorthAudit(lastOkMs: 1000, nowMs: 1000 + 599999), isFalse,
          reason: '最近成功未超 10 分钟 ⇒ 广播副本噪声，不记');
      expect(
          peerEvtFailWorthAudit(
              lastOkMs: 1000, nowMs: 1000 + rcPeerEvtNoiseWindowMs),
          isTrue,
          reason: '正好到窗口边界 ⇒ 重新值得记');
    });
  });
}
