/// `call_media_profile.dart` 的**纯逻辑锁**（第七十八轮）。
///
/// 背景：真机实测「建立视频/语音通话后，发起方与接收方机器都爆卡」。根因是
/// 编码侧**完全没有上限**（不设帧率、从不 `setParameters`）且降级偏好缺省
/// `balanced`（又糊又卡）。本文件只锁**无副作用**的那半 —— 档位表、采集约束、
/// 降级偏好映射；"档位真的下发到 sender"属于有副作用的胶水，由
/// `call_service_webrtc_test.dart` 的 CS-K 组在真实调用链上驱动。
///
/// ⚠️ 这里刻意**逐档写死数字**（而不是 `expect(x, sendProfileFor(1).maxBitrateBps)`
/// 这种自证式断言）：档位是"与行业推荐表对齐"的工程取值，改它必须是**有意**
/// 的决定，不能让实现顺手带过。
@Timeout(Duration(seconds: 30))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:sonic_shield/remote/call_media_profile.dart';

void main() {
  group('CMP-A 采集约束（getUserMedia）', () {
    test('CMP-01 用 ideal 而非精确值，且帧率带硬上限', () {
      final c = videoConstraintsFor(callVideoCapture);

      expect(c['facingMode'], 'user',
          reason: '前置摄像头：通话是"对着自己"的场景');

      // ideal：精确值在"摄像头不支持该分辨率"的机型上会让整通电话起不来。
      expect(c['width'], <String, Object?>{'ideal': 640});
      expect(c['height'], <String, Object?>{'ideal': 480});

      // max 是硬上限：不显式给，部分机型会以 30/60fps 采集 ⇒ 低端机编码吃满 CPU。
      final fps = c['frameRate'] as Map<String, Object?>;
      expect(fps['ideal'], 24);
      expect(fps['max'], 24,
          reason: '没有 max ⇒ 帧率不受控，"防爆卡"的第一级就落空了');
    });

    test('CMP-02 默认采集档就是 640x480@24fps', () {
      expect(callVideoCapture.width, 640);
      expect(callVideoCapture.height, 480);
      expect(callVideoCapture.frameRate, 24);
    });
  });

  group('CMP-B 发送档位阶梯（按并发视频路数）', () {
    test('CMP-03 单路：600kbps / 24fps / 不缩放', () {
      final p = sendProfileFor(1);
      expect(p.maxBitrateBps, 600000);
      expect(p.maxFramerate, 24);
      expect(p.scaleResolutionDownBy, 1.0);
    });

    test('CMP-04 两路：各降码率，帧率略降', () {
      final p = sendProfileFor(2);
      expect(p.maxBitrateBps, 400000);
      expect(p.maxFramerate, 20);
      expect(p.scaleResolutionDownBy, 1.0);
    });

    test('CMP-05 三路：开始缩放分辨率（编码像素数显著下降）', () {
      final p = sendProfileFor(3);
      expect(p.maxBitrateBps, 260000);
      expect(p.maxFramerate, 15);
      expect(p.scaleResolutionDownBy, 1.5);
    });

    test('CMP-06 ≥4 路：保底"看得见"，优先不卡', () {
      for (final n in <int>[4, 5, 8]) {
        final p = sendProfileFor(n);
        expect(p.maxBitrateBps, 150000, reason: 'n=$n');
        expect(p.maxFramerate, 12, reason: 'n=$n');
        expect(p.scaleResolutionDownBy, 2.0, reason: 'n=$n');
      }
    });

    test('CMP-07 非法路数（0/负数）按单路处理，不得崩', () {
      expect(sendProfileFor(0).maxBitrateBps, 600000);
      expect(sendProfileFor(-3).maxBitrateBps, 600000);
    });

    test('CMP-08 路数越多，档位只降不升（单调不增/缩放单调不减）', () {
      var prevBitrate = 1 << 30;
      var prevFps = 1 << 30;
      var prevScale = 0.0;
      for (var n = 1; n <= 6; n++) {
        final p = sendProfileFor(n);
        expect(p.maxBitrateBps, lessThanOrEqualTo(prevBitrate),
            reason: 'n=$n 时码率不得高于更少路数');
        expect(p.maxFramerate, lessThanOrEqualTo(prevFps),
            reason: 'n=$n 时帧率不得高于更少路数');
        expect(p.scaleResolutionDownBy, greaterThanOrEqualTo(prevScale),
            reason: 'n=$n 时缩放倍数不得小于更少路数（否则画质会反升）');
        prevBitrate = p.maxBitrateBps;
        prevFps = p.maxFramerate;
        prevScale = p.scaleResolutionDownBy;
      }
    });

    test('CMP-09 所有档位都取 maintain-framerate（宁可糊一点也要跟手）', () {
      for (var n = 1; n <= 5; n++) {
        expect(sendProfileFor(n).degradation, CallDegradation.maintainFramerate,
            reason: 'n=$n：缺省 balanced 会同时掉分辨率和帧率 ⇒ "又糊又卡"');
      }
    });
  });

  group('CMP-C 降级偏好映射', () {
    test('CMP-10 三个纯逻辑值都映射到插件的同名枚举', () {
      expect(degradationToPlugin(CallDegradation.maintainFramerate),
          RTCDegradationPreference.MAINTAIN_FRAMERATE);
      expect(degradationToPlugin(CallDegradation.maintainResolution),
          RTCDegradationPreference.MAINTAIN_RESOLUTION);
      expect(degradationToPlugin(CallDegradation.balanced),
          RTCDegradationPreference.BALANCED);
    });
  });
}
