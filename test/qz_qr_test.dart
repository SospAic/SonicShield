import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sonic_shield/features/remote/pair_qr_screen.dart';

import 'support/source_text.dart';

/// 「扫码配对」页（pair_qr_screen.dart）的**扫码链路回归锁**。
///
/// 真机（MIUI）反馈「扫描二维码用不了」的根因链：
/// 1. 挂载 `MobileScanner` 前没有真正的权限面板 —— 被拒/永久拒都只剩黑屏；
/// 2. 相机打开失败（权限/被占用/热插拔）没有错误面，用户零反馈；
/// 3. `onDetect` 连击不去抖 —— 一秒内可能重复配对。
///
/// 本文件锁三件事：
/// A. 「权限状态 → UI 判定」纯函数 `qrGateFromPerm` 的穷举（判定与接线分离）；
/// B. 源码锁（剥注释后文本扫描）：权限申请 / 错误面 / 手电筒 / dispose 必须在；
/// C. 反例样本：旧代码（无权限面板、无错误面）喂给同一判定器必须判红。
void main() {
  // ---------- 剥注释：见 `test/support/source_text.dart`（第 36 轮收敛） ----------
  // ⚠️ 此前本文件用的是**不认字符串字面量**的退化版；收敛后字符串整段保留。

  group('A. qrGateFromPerm（权限状态 → UI 判定，穷举）', () {
    test('已授权 → 放行挂预览', () {
      expect(qrGateFromPerm(PermissionStatus.granted), QrScanGate.granted);
    });
    test('未决定 / 拒绝 → 可再弹窗要权限（denied 分支）', () {
      expect(qrGateFromPerm(PermissionStatus.denied), QrScanGate.denied);
      expect(qrGateFromPerm(PermissionStatus.limited), QrScanGate.denied);
      expect(qrGateFromPerm(PermissionStatus.provisional), QrScanGate.denied);
    });
    test('永久拒绝 / 系统级受限 → 只能给「打开系统设置」', () {
      expect(
          qrGateFromPerm(PermissionStatus.permanentlyDenied),
          QrScanGate.permanentlyDenied);
      expect(qrGateFromPerm(PermissionStatus.restricted),
          QrScanGate.permanentlyDenied);
    });
  });

  group('B. 源码锁（剥注释后扫描 pair_qr_screen.dart）', () {
    late final String code;
    setUpAll(() {
      final f = File('lib/features/remote/pair_qr_screen.dart');
      code = stripComments(f.readAsStringSync());
    });

    test('扫码入口先申请相机权限（不再是仅 SnackBar 后挂预览）', () {
      expect(code.contains('Permission.camera.request'), isTrue,
          reason: '点「扫码」必须先 Permission.camera.request()，'
              'MIUI 上首次使用没有权限前置就是黑屏');
      expect(code.contains('qrGateFromPerm'), isTrue,
          reason: '判定必须走顶层纯函数 qrGateFromPerm（判定与接线分离）');
    });

    test('相机打开失败必须渲染成可见错误面（6.x 的 errorBuilder）', () {
      // mobile_scanner 6.0.11 源码核实：构造参数没有 onError，
      // 错误面是 errorBuilder: Widget Function(BuildContext,
      // MobileScannerException, Widget?)，识别流异常走 onDetectError。
      expect(code.contains('errorBuilder'), isTrue,
          reason: '相机打开失败（权限/被占用/热插拔）必须经 errorBuilder '
              '渲染成可见错误卡片，而不是黑屏');
      expect(code.contains('onDetectError'), isTrue,
          reason: '识别流异常不得走 6.x 默认的静默空实现');
      expect(code.contains('MobileScannerException'), isTrue,
          reason: '错误面必须拿到 MobileScannerException 才能区分错误类型');
    });

    test('识别去抖必须存在', () {
      expect(code.contains('_handledCode'), isTrue,
          reason: 'onDetect 连击必须去抖：识别成功立刻停扫描再处理，'
              '防止一秒内重复配对');
    });

    test('手电筒开关（6.x 的 controller.toggleTorch）必须存在', () {
      expect(code.contains('toggleTorch'), isTrue,
          reason: '暗光环境最小成本解：手电筒开关必须接 controller.toggleTorch()');
    });

    test('controller 必须显式 dispose（6.x 生命周期硬要求）', () {
      expect(code.contains('dispose()'), isTrue,
          reason: 'mobile_scanner 6.x 的 MobileScannerController.dispose() '
              '是 Future<void>，离开页面/停止扫描必须释放，'
              '否则 MIUI 下一次打开报「相机被占用」');
    });
  });

  group('C. 反例样本：旧代码喂给同一判定器必须判红', () {
    // 修复前的实际写法（简化）：无权限面板、无错误面、无 dispose。
    const oldSrc = '''
import 'package:mobile_scanner/mobile_scanner.dart';
class _State {
  bool _scanning = false;
  Widget build(BuildContext context) {
    return ListView(children: [
      if (_scanning)
        SizedBox(
          height: 420,
          child: MobileScanner(onDetect: (capture) {}),
        ),
      FilledButton(
        onPressed: () async {
          final granted = await Permission.camera.request().isGranted;
          if (!granted) return;
        },
      ),
    ]);
  }
}
''';

    late final String oldCode;
    setUpAll(() => oldCode = stripComments(oldSrc));

    test('旧代码：无 errorBuilder → 判红', () {
      expect(oldCode.contains('errorBuilder'), isFalse,
          reason: '旧代码相机打开失败只有黑屏');
    });
    test('旧代码：无 onDetectError → 判红', () {
      expect(oldCode.contains('onDetectError'), isFalse);
    });
    test('旧代码：无 toggleTorch → 判红', () {
      expect(oldCode.contains('toggleTorch'), isFalse);
    });
    test('旧代码：无 controller dispose → 判红', () {
      expect(oldCode.contains('dispose()'), isFalse);
    });
    test('旧代码：有权限申请但无 qrGateFromPerm 判定 → 判红（接线绕过判定）', () {
      expect(oldCode.contains('qrGateFromPerm'), isFalse,
          reason: '旧代码把 isGranted 直接吞掉，被拒/永久拒不区分，无失败面板');
    });
  });
}
