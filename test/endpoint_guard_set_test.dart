import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';

import 'support/source_text.dart';

void main() {
  group('decideGuardSet：按真实结果裁决', () {
    test('GS-01 引擎没跑 → 失败，且明确指向"去端点开引擎"', () {
      final r = decideGuardSet(
          enabled: true, engineRunning: false, observed: false);
      expect(r.ok, isFalse, reason: '引擎没跑时 setGuard 是发向不存在的服务，'
          '绝不能再回 ok=true（这正是被修的假成功）');
      expect(r.reason, contains('引擎未运行'));
    });

    test('GS-02 引擎没跑 + 开启 → 必须点出"需端点前台授权麦克风"', () {
      final on = decideGuardSet(
          enabled: true, engineRunning: false, observed: false);
      final off = decideGuardSet(
          enabled: false, engineRunning: false, observed: false);

      expect(on.reason, contains('前台'),
          reason: '远程无法申请麦克风权限，不说清楚对端只会反复重试');
      expect(off.reason, isNot(contains('麦克风')),
          reason: '关闭不需要麦克风 —— 指引必须与开启不同（合并即静默失败）');
    });

    test('GS-03 观察到期望状态 → 成功', () {
      expect(
          decideGuardSet(enabled: true, engineRunning: true, observed: true).ok,
          isTrue);
      expect(
          decideGuardSet(enabled: false, engineRunning: true, observed: true).ok,
          isTrue);
    });

    test('GS-04 引擎报了启动失败原因 → 失败，且原因原样转达 + 点出前台授权', () {
      final r = decideGuardSet(
        enabled: true,
        engineRunning: true,
        observed: false,
        guardError: '麦克风启动失败：被其它应用占用',
      );
      expect(r.ok, isFalse);
      expect(r.reason, contains('麦克风启动失败：被其它应用占用'),
          reason: '引擎已经说清了原因，丢掉它就退回含糊的"引擎无响应"');
      expect(r.reason, contains('前台'));
    });

    test('GS-05 等不到回音且无具体原因 → 失败，报"引擎无响应"', () {
      final r = decideGuardSet(
          enabled: true, engineRunning: true, observed: false);
      expect(r.ok, isFalse);
      expect(r.reason, contains('无响应'));
    });

    test('GS-06 关闭方向失败不冒用"麦克风"措辞（对称性）', () {
      final r = decideGuardSet(
        enabled: false,
        engineRunning: true,
        observed: false,
        guardError: '麦克风启动失败：被其它应用占用',
      );
      expect(r.ok, isFalse);
      expect(r.reason, isNot(contains('麦克风')),
          reason: 'guardError 是上一次**开启**残留的原因，'
              '关闭失败时照抄它会给出完全错误的指引');
    });
  });

  group('guard.set 接线锁（源码契约）', () {
    final src = File('lib/remote/endpoint_service.dart').readAsStringSync();

    test('GS-W1 guard.set 走 _setRemoteGuard（不再直接写 pref）', () {
      final body = methodBody(
          src, 'Future<void> _dispatch(RcMessage msg, PairedEndpoint peer)');
      expect(body, contains('await _setRemoteGuard(msg, peer, logs)'));
      expect(body, isNot(contains("'guard_enabled'")),
          reason: '旧形状：只写 pref → 引擎在跑时是 no-op，而回执却说成功');
    });

    test('GS-W2 _setRemoteGuard 真调引擎 + 等状态回投 + 按结果回 ack', () {
      final body = methodBody(src, 'Future<void> _setRemoteGuard(');

      expect(body, contains('setGuard('),
          reason: '必须走 BackgroundServiceManager（引擎侧真开关）');
      expect(body, contains('waitForGuardActive('),
          reason: 'setGuard 是 fire-and-forget，不等回投就会重演假成功');
      expect(body, contains('decideGuardSet('));
      expect(body, contains('_ack(msg, outcome.ok'),
          reason: 'ok 必须来自真实裁决，不能是常量 true');
      expect(body, isNot(contains('_ack(msg, true)')),
          reason: '常量 true 正是被修的缺陷形状');
    });

    test('GS-W3 失败必须写审计（不能只在回执里说）', () {
      final body = methodBody(src, 'Future<void> _setRemoteGuard(');
      expect(body, contains('status: outcome.ok ? '));
      expect(body, contains('action: \'guard.set\''));
    });
  });
}
