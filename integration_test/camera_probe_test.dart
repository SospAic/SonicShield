import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sonic_shield/features/remote/pair_qr_screen.dart';

/// 相机「探针」——**只做取证，不做断言修复**。
///
/// 目的：在真机进程内把三条相机路径逐一跑一遍，把"相机无法调用"这个
/// 模糊报告**定位到具体哪一条**：
///   1. 运行时权限（permission_handler）；
///   2. WebRTC `getUserMedia(video)`（视频通话出画面的前提）；
///   3. mobile_scanner 相机预览（扫码配对的前提）。
///
/// 每条都把真实异常原样打印（`debugPrint('PROBE-xx ...')`），
/// 便于 `flutter test ... -d <device>` 输出与 logcat 交叉核对。
Future<void> _settle(WidgetTester tester, {int ms = 1500}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('PROBE-1 相机运行时权限（只读，不弹窗）', (tester) async {
    // ⚠️ 刻意用 `.status` 而不是 `.request()`：MIUI 上 `request()` 会弹系统
    // 授权框，而本机 `input` 注入被禁 ⇒ 对话框无人可点 ⇒ 用例永久挂起。
    // 权限由外部 `adb shell pm grant` 预置。
    final status = await Permission.camera.status;
    debugPrint('PROBE-1 cameraPermission=$status granted=${status.isGranted}');
  });

  testWidgets('PROBE-2 WebRTC getUserMedia(video+audio)', (tester) async {
    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': 'user', 'width': 640, 'height': 480},
      });
      final vt = stream.getVideoTracks();
      debugPrint('PROBE-2 OK videoTracks=${vt.length} '
          'label=${vt.isEmpty ? "-" : vt.first.label}');
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      await stream.dispose();
    } catch (e, st) {
      debugPrint('PROBE-2 FAIL $e\n$st');
    }
    // 让原生资源有回收时间
    await _settle(tester, ms: 1200);
  });

  testWidgets('PROBE-3 mobile_scanner 相机预览（扫码页真实挂载）', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: PairQrScreen()),
    ));
    await _settle(tester, ms: 2000);

    final scanBtn = find.widgetWithText(FilledButton, '扫描对端二维码');
    expect(scanBtn, findsOneWidget, reason: '扫码入口按钮必须存在');
    await tester.tap(scanBtn);
    // 相机初始化 + 首帧需要一点时间
    await _settle(tester, ms: 6000);

    debugPrint('PROBE-3 widgetException=${tester.takeException()}');
    // 无论成功失败，页面上必须出现可读的面板（错误卡片 / 提示 / 手输入口）
    final manual = find.textContaining('手动输入');
    // 相机打开失败时 errorBuilder 会渲染「重试」与失败文案 —— 用它区分
    // 「预览真的挂上了」与「只是没抛异常的失败卡片」。
    final retry = find.widgetWithText(FilledButton, '重试');
    final scannerErr = find.textContaining('相机启动失败');
    final permErr = find.textContaining('相机权限被系统拒绝');
    debugPrint('PROBE-3 manualEntryVisible=${manual.evaluate().isNotEmpty} '
        'retryBtn=${retry.evaluate().isNotEmpty} '
        'scannerErrorPanel=${scannerErr.evaluate().isNotEmpty} '
        'permDeniedPanel=${permErr.evaluate().isNotEmpty}');
  });

  testWidgets('PROBE-4 WebRTC 本地协商（视频通话建立前的完整本地路径）', (tester) async {
    // 复刻 `CallService` 的本地路径：getUserMedia → createPeerConnection →
    // addTrack → createOffer → setLocalDescription。这条路径的原生面
    // （MediaStream / PeerConnectionFactory / JNI 加载的 org.webrtc.**）
    // 正是 release 下受 R8 影响的对象 —— 保住它们的**配置**由
    // `test/release_webrtc_keep_lock_test.dart` 在宿主侧钉住；本用例给的是
    // 真机进程内的**实际执行证据**。
    RTCPeerConnection? pc;
    MediaStream? stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {'facingMode': 'user', 'width': 640, 'height': 480},
      });
      final v = stream.getVideoTracks().length;
      final a = stream.getAudioTracks().length;
      debugPrint('PROBE-4 media videoTracks=$v audioTracks=$a');

      pc = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
        'sdpSemantics': 'unified-plan',
      });
      for (final t in stream.getTracks()) {
        await pc.addTrack(t, stream);
      }
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      final local = await pc.getLocalDescription();
      final sdp = local?.sdp ?? '';
      debugPrint('PROBE-4 offer type=${local?.type} sdpLen=${sdp.length} '
          'hasVideo=${sdp.contains('m=video')} '
          'hasAudio=${sdp.contains('m=audio')}');
      // 取到视频轨却协商不出 `m=video` = 视频面没进协商（"接通了但没画面"）。
      if (v > 0) {
        expect(sdp.contains('m=video'), isTrue,
            reason: '已取到视频轨，但本地 offer 里没有 m=video ⇒ 视频面未进入协商');
      }
    } catch (e, st) {
      debugPrint('PROBE-4 FAIL $e\n$st');
    } finally {
      try {
        await pc?.close();
        await pc?.dispose();
      } on Object {
        // ignore
      }
      final tracks = stream?.getTracks();
      if (tracks != null) {
        for (final t in tracks) {
          try {
            await t.stop();
          } on Object {
            // ignore
          }
        }
      }
      try {
        await stream?.dispose();
      } on Object {
        // ignore
      }
    }
    await _settle(tester, ms: 1200);
  });
}