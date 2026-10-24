library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

/// R94 原生桥接 / 生命周期修复的**源码契约锁**（NAT-01 / 08 / 14 / 16 / 17）。
///
/// ## 为什么原生侧只能靠源码锁
///
/// 沙箱里没有 Gradle / Android SDK，Kotlin **编译不了**；真机验证又要等
/// 用户给无线调试地址。所以这一层用「剥注释后的源码必须含某调用」来锁
/// **结构性契约** —— 它抓不到运行时行为，但能抓住"有人把修复删了"
/// 这一类回归（历史上 `registerCallback` 就是被这样漏掉的）。
///
/// ## 判据纪律
///
/// 每条锁都配**反面样本**：改错值必须判红。否则一条恒真断言同样能让
/// 门禁变绿，那是自欺（`methodBody` 找不到签名会抛 `StateError`，
/// 天然提供"删了方法就红"的副作用）。

/// 读文件并剥注释（Kotlin/Swift 的行注释与块注释都在 `stripComments` 覆盖范围内）。
String src(String path) => stripComments(File(path).readAsStringSync());

void main() {
  const castService =
      'android/app/src/main/kotlin/com/sonicshield/sonic_shield/ScreenCastService.kt';
  const micGuard =
      'packages/native_bridge/android/src/main/kotlin/com/sonicshield/native_bridge/MicGuardService.kt';
  const plugin =
      'packages/native_bridge/android/src/main/kotlin/com/sonicshield/native_bridge/NativeBridgePlugin.kt';
  const bridgeManifest =
      'packages/native_bridge/android/src/main/AndroidManifest.xml';
  const appManifest = 'android/app/src/main/AndroidManifest.xml';
  const nativeBridge = 'lib/services/native_bridge.dart';

  group('NAT-01 · Android 14+ 抓帧契约', () {
    test('registerCallback 必须出现在 createVirtualDisplay 之前', () {
      final s = src(castService);
      final regIdx = s.indexOf('mp.registerCallback(');
      expect(regIdx, greaterThanOrEqualTo(0),
          reason: 'NAT-01①：API 34+ 未注册回调就 createVirtualDisplay 会抛 '
              'IllegalStateException，且被记成"用户拒绝授权"（Redmi K70 Pro 必现）');
      final vdIdx = s.indexOf('projection?.createVirtualDisplay(');
      expect(vdIdx, greaterThanOrEqualTo(0), reason: '抓帧必须创建 VirtualDisplay');
      expect(regIdx, lessThan(vdIdx),
          reason: '顺序即契约：registerCallback 必须在 createVirtualDisplay 之前。'
              '反过来写等于没修');

      // onDestroy 必须注销，否则回调泄漏（Service 重建时旧回调还在）。
      expect(s.contains('unregisterCallback'), isTrue,
          reason: 'NAT-01：配对释放，否则每次投屏都多留一个回调');
    });

    test('captureOnce 不得再 createVirtualDisplay（一次 VD、多次读帧）', () {
      final s = src(castService);
      final body = methodBody(s, 'fun captureOnce(');
      expect(body, isNotEmpty, reason: 'captureOnce 必须存在');
      expect(body.contains('createVirtualDisplay'), isFalse,
          reason: 'NAT-01②：一个 MediaProjection 实例只能 createVirtualDisplay '
              '一次（第二次抛 SecurityException）。旧实现"每次抓帧复用"在 '
              'Android 14+ 必失败');
      // 读帧形状是「长驻 VD + listener 持续换帧 + 抓帧只快照」：
      // captureOnce 自己**不得** acquireLatestImage —— acquire 会顺手丢弃
      // 队列里更旧的未取帧，每次抓帧 acquire 等于把"读最近一帧"退回
      // "取下一帧"（镜像只在内容变化时产帧 ⇒ 静止画面必挂到超时）。
      expect(body.contains('acquireLatestImage'), isFalse,
          reason: 'NAT-01②：抓帧不得自己 acquireLatestImage；换帧必须由 '
              'listener 做（见 startVirtualDisplay 的 setOnImageAvailableListener）');
      expect(body.contains('snapshotFrame'), isTrue,
          reason: '抓帧应改为读长驻 VD 的最近一帧'
              '（snapshotFrame 在 frameLock 内从帧缓存取像素副本）');
      // 供给侧契约（VD 与 listener 必须建在 captureOnce 之前，即"长驻"）：
      // 否则帧缓存永远是空的，"读最近一帧"无从谈起。
      final supply = s.substring(0, s.indexOf('fun captureOnce('));
      expect(supply, isNotEmpty, reason: 'captureOnce 之前必须有 VD 供给段');
      expect(supply.contains('setOnImageAvailableListener'), isTrue,
          reason: '长驻 ImageReader 必须挂 listener 持续换帧');
      expect(supply.contains('acquireLatestImage'), isTrue,
          reason: 'listener 必须 acquireLatestImage 把最新帧换进帧缓存');
      expect(supply.contains('createVirtualDisplay'), isTrue,
          reason: 'VD 必须在 captureOnce 之前建好（长驻，一次建成多次读帧）');
    });
  });

  group('ARCH-02 / NAT-16 · 精确闹钟先清后排', () {
    test('scheduleExactAlarms 排布前必须 clearExactAlarms', () {
      final s = src(plugin);
      final body = methodBody(s, 'private fun scheduleExactAlarms(');
      final clearIdx = body.indexOf('clearExactAlarms(ctx)');
      expect(clearIdx, greaterThanOrEqualTo(0),
          reason: 'ARCH-02：只排新不撤旧 ⇒ 孤儿闹钟在任务改期后仍按旧时刻拉起引擎');
      final loopIdx = body.indexOf('for (t in times)');
      expect(loopIdx, greaterThanOrEqualTo(0), reason: '排布循环必须存在');
      expect(clearIdx, lessThan(loopIdx),
          reason: '顺序即契约：必须先撤后建。撤在循环之后 = 每轮都撤自己刚建的');

      // KEY_ALARMS 现在必须是全集（clear 只遍历它，漏一个就永久残留）。
      expect(body.contains('putStringSet(KEY_ALARMS'), isTrue,
          reason: '排完必须把新全集写回 KEY_ALARMS，否则 clearExactAlarms '
              '下次撤不干净');
    });
  });

  group('NAT-08 · microphone 型 FGS 不得 START_STICKY', () {
    test('MicGuardService.onStartCommand 不返回 START_STICKY', () {
      final s = src(micGuard);
      final body = methodBody(s, 'override fun onStartCommand(');
      expect(body.contains('START_STICKY'), isFalse,
          reason: 'NAT-08：microphone 型 FGS 受 while-in-use 约束，系统从后台'
              '重启服务时 startForeground 必然抛异常；返回 START_STICKY 会让它'
              '反复重启反复崩');
      expect(body.contains('START_NOT_STICKY'), isTrue,
          reason: '反面样本：必须显式返回 START_NOT_STICKY，而不是靠默认值');
    });
  });

  group('NAT-14 · 无授权入口的权限不得声明', () {
    test('两个 Manifest 都不再声明 PACKAGE_USAGE_STATS', () {
      for (final m in [bridgeManifest, appManifest]) {
        expect(src(m).contains('PACKAGE_USAGE_STATS'), isFalse,
            reason: 'NAT-14：$m 声明了该权限却没有授权入口 ⇒ appStandbyBucket '
                '恒 unknown，省电桶自检是死功能。要么补入口，要么别声明');
      }
    });
  });

  group('跨包契约 · Dart 侧必须真的暴露 F4 的 5 个方法', () {
    test('native_bridge.dart 暴露 isMicServiceRunning 等 5 个方法', () {
      final s = src(nativeBridge);
      const expected = [
        'isMicServiceRunning',
        'stopMicGuardService',
        'setSecureFlag',
        'getOrCreateDeviceSecret',
        'releaseWakeLock',
      ];
      for (final m in expected) {
        expect(s.contains('static Future<') && s.contains(m), isTrue,
            reason: 'F2/F1 依赖 $m；缺一个就是编译错误或运行期 '
                'MissingPluginException');
      }
      // 反面样本：这些方法必须走 invokeMethod（不是空实现），否则调用方
      // 会拿到一个永远成功的假 Future。
      expect(s.contains('invokeMethod'), isTrue,
          reason: '桥方法必须真的过 MethodChannel');
    });
  });
}
