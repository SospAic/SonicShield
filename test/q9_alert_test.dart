// Q9.B 找回动作（device.alert）回归锁：
// 1. 通道桩行为测试 —— NativeBridge.alert 的 ack / 降级语义；
// 2. 源码锁 —— 剥注释后 native_bridge.dart 必须保留 alert 签名、
//    NativeBridgePlugin.kt 必须保留 alert 分支与 deviceAlert 实现
//    （防止有人悄悄删桥接方法）；反例样本确保锁不误报。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/services/native_bridge.dart';

import 'support/source_text.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

const _channel = MethodChannel('sonic_shield/native');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('QA · NativeBridge.alert 通道行为', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
    });

    tearDown(() {
      _messenger.setMockMethodCallHandler(_channel, null);
    });

    test('QA01 原生 ack true → 返回 true，参数按约定透传', () async {
      _messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return call.method == 'alert' ? true : null;
      });
      final ok = await NativeBridge.alert(message: '手机在这');
      expect(ok, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'alert');
      expect(calls.single.arguments, {'message': '手机在这'});
    });

    test('QA02 原生 ack false → 返回 false（不吞成 true）', () async {
      _messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return call.method == 'alert' ? false : null;
      });
      expect(await NativeBridge.alert(message: 'x'), isFalse);
    });

    test('QA03 MissingPluginException（桥不可用/桌面）→ 静默降级 false', () async {
      _messenger.setMockMethodCallHandler(_channel, (call) async {
        throw MissingPluginException('No implementation found');
      });
      expect(await NativeBridge.alert(message: 'x'), isFalse);
    });

    test('QA04 PlatformException（原生异常）→ 静默降级 false 不抛', () async {
      _messenger.setMockMethodCallHandler(_channel, (call) async {
        throw PlatformException(code: 'NATIVE_ERROR', message: 'boom');
      });
      expect(await NativeBridge.alert(message: 'x'), isFalse);
    });

    test('QA05 未打桩（无 handler）→ MissingPluginException 路径 → false', () async {
      expect(await NativeBridge.alert(message: 'x'), isFalse);
    });
  });

  group('QB · 源码锁（剥注释后签名必须存在）', () {
    /// 剥掉 // 行注释与 /* */ 块注释。
    ///
    /// 实现见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源）。
    /// ⚠️ 此前本文件用的是**只认单引号**的状态机版 —— 本组同时扫 Kotlin
    /// （`"` 字符串），双引号字面量里的 `//` 会被误当注释开始；收敛后
    /// 单/双引号都按字符串字面量整段保留。

    final dartSrc = stripComments(
        File('lib/services/native_bridge.dart').readAsStringSync());
    final kotlinSrc = stripComments(File(
            'packages/native_bridge/android/src/main/kotlin/'
            'com/sonicshield/native_bridge/NativeBridgePlugin.kt')
        .readAsStringSync());

    test('QB01 native_bridge.dart 剥注释后含 alert 签名', () {
      expect(
        dartSrc.contains(
            'static Future<bool> alert({required String message})'),
        isTrue,
        reason: '找回动作（Q9.B）依赖 NativeBridge.alert 桥接签名，'
            '签名被改动/删除会静默破坏 device.alert 端点，必须同步更新本锁。',
      );
    });

    test('QB02 NativeBridgePlugin.kt 剥注释后含 alert 分支与实现', () {
      expect(kotlinSrc.contains('"alert" ->'), isTrue,
          reason: '通道 method 分发缺 alert case 会落到 notImplemented，'
              'Dart 侧收到 MissingPluginException 静默降级 —— 找回动作整体失效。');
      expect(kotlinSrc.contains('private fun deviceAlert('), isTrue,
          reason: 'deviceAlert 实现被删等于 alert 分支空转，必须同步更新本锁。');
    });

    test('QB03 反例：形变签名不得命中锁（锁必须精确）', () {
      // 这些形变都【不】应匹配 Dart 锁。
      const dartNegatives = <String>[
        'static Future<bool> alert(String message)', // 位置参数，非命名
        'static Future<void> alert({required String message})', // 返回类型错
        'static Future<bool> alertx({required String message})', // 方法名错
        'Future<bool> alert({required String message})', // 缺 static
        'static Future<bool> alert({String message})', // 缺 required
      ];
      const dartLock =
          'static Future<bool> alert({required String message})';
      for (final n in dartNegatives) {
        expect(n.contains(dartLock), isFalse, reason: '反例 "$n" 不应命中锁');
      }
      // Kotlin 锁同理：引号缺失/方法名变形都不应命中。
      expect(kotlinSrc.contains("'alert' ->"), isFalse,
          reason: 'Kotlin 用双引号字符串；单引号样本不应命中（防锁过松）');
      expect(kotlinSrc.contains('private fun deviceAlertX('), isFalse);
    });
  });
}
