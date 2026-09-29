import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/endpoint_service.dart';
import '../../remote/protocol.dart';
import '../../remote/remote_store.dart';

/// 扫码配对（v1.5）：
/// - 「我的二维码」：展示本机设备 ID + 配对码（对端扫码即配对本机）；
/// - 「扫码添加」：扫描对端二维码自动填充并完成配对。
///
/// 配对内容编码：sonicshield://pair/{deviceId}/{name}/{code(8位,去连字符)}
///
/// 合规：物理在场（两台设备可互扫）即最强同意证明——替代手输配对码，
/// 是对「免同意远程控制」需求的安全实现（docs/16 §8，docs/14 §7.5）。
/// 配对成功后的**对端通知**（R-2）：把本机身份 + 本机配对码发给对端，
/// 让它把本机登记进它的配对表。
///
/// ## 为什么必须有这一步
///
/// 配对此前只做了"本机落盘"这一半：A 扫了 B 的码 ⇒ A 的表里有 B，
/// 而 **B 的表里没有 A**。于是 B 执行了 A 的命令，回执却在
/// `_send` 的 `peers.isEmpty` 分支被直接丢弃 —— 现象就是"端点执行了
/// 却毫无回音"，控制端只能等到超时。配对不是单向授权，是**双向信任**。
///
/// ⚠️ payload 里的 `code`（本机配对码）**不是可选装饰**：对端回执的密钥是
/// `deriveKey(本机配对码, '{本机ID}|evt')`。不发码，对端就没有可用密钥，
/// 回执**永远发不出去**。
///
/// 为什么函数放在本文件（而不是端点服务里）：
/// `test/rc_protocol_coverage_test.dart` 的门禁要求「每条 `RcCmd` 至少有一个
/// **非端点**发送方」。扫码页与手输对话框共用本函数，避免两份 payload 各自漂移。
Future<PairConfirmOutcome> notifyPeerOfPairing(
    PairedEndpoint endpoint, RemoteStore store) async {
  // 对端要用「本机 deviceId + 本机配对码」给回执加密；没有身份就谈不上配对。
  if (store.deviceId.isEmpty) {
    final id = RcCodec.generateDeviceId();
    await store.setIdentity(id, '声盾-${id.substring(0, 4)}');
  }
  final request = RcMessage.now(RcCmd.pairRequest, {
    'deviceId': store.deviceId,
    'name': store.deviceName,
    'code': await store.ensurePairingCode(),
  });
  return RcEndpointService.instance.requestPairing(endpoint, store, request);
}

/// 「权限状态 → UI 判定」的顶层纯函数（判定与接线分离）。
///
/// 扫码入口按钮只负责**接线**（request → 本函数 → 分支渲染），
/// 判定本身可被 `test/qz_qr_test.dart` 穷举锁住。
enum QrScanGate { granted, denied, permanentlyDenied }

QrScanGate qrGateFromPerm(PermissionStatus status) {
  if (status.isGranted) return QrScanGate.granted;
  // restricted（家长控制/MDM）与永久拒绝同样只能去系统设置解，无法弹窗再要。
  if (status.isPermanentlyDenied || status.isRestricted) {
    return QrScanGate.permanentlyDenied;
  }
  return QrScanGate.denied;
}

/// 扫描到的一条码该怎么处理（判定与接线分离，宿主可穷举）。
enum QrDetectKind {
  /// 空值或**明确的一维条码**（商品 EAN/UPC/Code128…）→ 不打扰用户。
  ignore,

  /// 声盾配对码（`sonicshield://pair/`）→ 走配对。
  sonicShield,

  /// 是二维码但不是声盾配对码 → 一次性提示「这不是声盾配对码」。
  foreignQr,
}

/// 把 `MobileScanner` 的识别结果分类（纯函数）。
///
/// P0-4：此前 `_onDetect` 只认 `sonicshield://pair/` 前缀，别家二维码被**静默
/// 忽略** —— 用户对准微信/支付宝码毫无反馈，这正是「扫不了码」最大的困惑源。
///
/// 只对**二维码**提示、放过一维条码：`unknown` 归到二维码侧 —— 部分机型对 QR
/// 返回 `unknown`，漏判会把本页最想消除的「毫无反馈」又放回来（宁可多提示）。
QrDetectKind classifyDetectedQr(String? raw, BarcodeFormat format) {
  if (raw == null || raw.isEmpty) return QrDetectKind.ignore;
  if (raw.startsWith(PairQrProtocol.prefix)) return QrDetectKind.sonicShield;
  return switch (format) {
    BarcodeFormat.ean13 ||
    BarcodeFormat.ean8 ||
    BarcodeFormat.upcA ||
    BarcodeFormat.upcE ||
    BarcodeFormat.code128 ||
    BarcodeFormat.code39 ||
    BarcodeFormat.code93 ||
    BarcodeFormat.codabar ||
    BarcodeFormat.itf =>
      QrDetectKind.ignore,
    _ => QrDetectKind.foreignQr,
  };
}

/// 设备 ID：16 位十六进制（大小写均可，生成端恒为小写）。
final RegExp _hex16 = RegExp(r'^[0-9a-fA-F]{16}$');

/// 配对码字符集：与 `RcCodec.generatePairingCode` 的 Crockford 风格 Base32
/// 字母表 `ABCDEFGHJKMNPQRSTVWXYZ23456789` 一致（去掉易混的 0/1/I/L/O）。
final RegExp _base32Code = RegExp(r'^[ABCDEFGHJKMNPQRSTVWXYZ23456789]{8}$');

/// 手输配对码归一化：**复用协议层口径**（剥连字符 + 转大写），不另拷一份。
///
/// 做法是把用户输入的码塞进一个「ID 合法、名字占位」的 URI 交给
/// [PairQrProtocol.parseUri] 解析：归一化因此永远只有协议层一处实现，
/// 协议层将来改了码的格式，这里自动跟着变，杜绝两份解析器漂移。
/// 返回 `null` 表示协议层不接受该码（为空 / 去连字符后不是 8 位）。
String? manualPairNormalizedCode(String rawCode) {
  final parsed = PairQrProtocol.parseUri(
    '${PairQrProtocol.prefix}0000000000000000/n/${rawCode.trim()}',
  );
  return parsed?.code;
}

/// 手输配对「字段级」校验（纯函数）。
///
/// 返回 `null` 表示 ID 与码都合法；否则返回**指明是哪个字段错**的就地提示文案
/// —— 调用方把它渲染在输入框下方，而不是只弹一条 SnackBar（用户需要知道
/// 到底改哪一个框，16 位 hex 人工转录极易出错）。
///
/// 校验口径与 [PairQrProtocol.parseUri] 一致（ID 16 位、码 8 位，码允许
/// `XXXX-XXXX` 连字符与小写），并额外收紧字符集。归一化复用
/// [manualPairNormalizedCode]，本函数不自己实现剥连字符/转大写。
String? manualPairFieldError(String rawId, String rawCode) {
  final id = rawId.trim();
  if (id.isEmpty) return '请输入对端设备 ID';
  if (id.length != 16) {
    return '设备 ID 必须是 16 位（当前 ${id.length} 位）';
  }
  if (!_hex16.hasMatch(id)) return '设备 ID 只能是 0-9 与 a-f 的十六进制';
  final raw = rawCode.trim();
  if (raw.isEmpty) return '请输入 8 位配对码';
  final code = manualPairNormalizedCode(raw);
  if (code == null) {
    return '配对码必须是 8 位（可写成 AB2C-D5EF 或小写）';
  }
  if (!_base32Code.hasMatch(code)) {
    return '配对码含非法字符（仅 A-Z 与 2-9，不含 0/1/I/L/O）';
  }
  return null;
}

class PairQrScreen extends ConsumerStatefulWidget {
  const PairQrScreen({super.key});

  @override
  ConsumerState<PairQrScreen> createState() => _PairQrScreenState();
}

class _PairQrScreenState extends ConsumerState<PairQrScreen> {
  bool _scanning = false;
  String _deviceId = '';
  String _deviceName = '';
  String _pairCode = '';
  String? _result;

  /// 结果卡片是否要按"未确认/需处理"着色（R-2：不得把未确认画成成功）。
  bool _resultWarn = false;

  /// 权限闸门未通过时的判定结果（null = 已放行/未尝试）。
  QrScanGate? _permGate;

  /// 相机预览控制器。mobile_scanner 6.x 要求**显式 dispose**（源码
  /// mobile_scanner_controller.dart:440 `Future<void> dispose()`），
  /// 否则相机被占着，MIUI 上下一次打开直接失败。
  MobileScannerController? _controller;

  /// 去抖节流：**最近一次已作出反应**的码。扫码与「非声盾码提示」共用这一个
  /// 状态（P0-4 要求复用同一节流，不能另起一套）：
  /// - 声盾配对码：置位并停扫描（见 [_handleDetectedCode]）；
  /// - 非声盾二维码：仅置位用于「同一个码不重复提示」，**不停扫描**
  ///   （用户可换角度重扫；停掉就真卡死了）。
  /// 连续帧重复读到同一个 raw 时直接短路，避免提示每帧刷一次。
  String _handledCode = '';

  /// 非声盾二维码的一次性提示开关（就地渲染，不弹 SnackBar —— 每帧弹一次
  /// 会刷屏并撑爆 SnackBar 队列）。
  bool _foreignQrNotice = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _stopScan();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (store.deviceId.isEmpty) {
      final id = RcCodec.generateDeviceId();
      await store.setIdentity(id, '声盾-${id.substring(0, 4)}');
    }
    // 持久配对码：首次生成后固定（多台控制器可重复扫码配对本机）。
    final code = await store.ensurePairingCode();
    if (!mounted) return;
    setState(() {
      _deviceId = store.deviceId;
      _deviceName = store.deviceName;
      _pairCode = code;
    });
  }

  String _myUri() =>
      '${PairQrProtocol.prefix}$_deviceId/${Uri.encodeComponent(_deviceName)}/'
      '$_pairCode';

  // ⚠️ 这里**曾经**有一份 `parseUri` 的完整拷贝，与
  // `PairQrProtocol.parseUri`（lib/remote/protocol.dart）逐行相同。
  // 两份"配对码解析器"是隐患：一旦其中一侧改了长度/前缀校验，
  // 就会出现"扫码页认为合法、协议层认为非法"（或反之）的静默分歧 ——
  // 而这条路径决定**跟谁配对**，配错就是安全事故。
  // 第三十二轮改为单点复用；`test/pair_qr_screen_test.dart` 用往返校验锁住
  // 「本页生成的 URI 必须能被协议层解析回同一个 (id, name, code)」。

  Future<void> _pairFromUri(String uri) async {
    final parsed = PairQrProtocol.parseUri(uri);
    if (parsed == null) {
      if (mounted) setState(() => _result = '二维码不是有效的声盾配对码');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    final endpoint = PairedEndpoint(
      deviceId: parsed.deviceId,
      name: parsed.name,
      secret: parsed.code,
      pairedAt: DateTime.now(),
    );
    await store.addPaired(endpoint);
    // 立即订阅新对端的 evt 主题，否则收不到其回执与通话信令（BUG-013）。
    await RcEndpointService.instance.refreshSubscriptions();
    if (mounted) {
      setState(() {
        _result = '已配对：${parsed.name}（${parsed.deviceId}）';
        _resultWarn = false;
        _scanning = false;
      });
    }
    // R-2：立刻通知对端把它那边的配对补齐（8 秒内没有回音必须说出来）。
    final outcome = await notifyPeerOfPairing(endpoint, store);
    if (mounted) {
      setState(() {
        _result = '已配对：${parsed.name}（${parsed.deviceId}）\n${outcome.message}';
        _resultWarn = !outcome.confirmed;
      });
    }
  }

  /// 手输提交：把「对端 ID + 可选名字 + 码」组装成与二维码**完全相同**的 URI，
  /// 交给 [_pairFromUri] —— 手输与扫码因此共用同一条「落盘 → 订阅 → 通知对端」
  /// 路径，杜绝两份回执 payload 漂移（docs/25 §4 红线）。
  ///
  /// 码**不在这里归一化**：交给 `_pairFromUri → PairQrProtocol.parseUri`
  /// 单点处理（剥连字符 + 转大写），保证归一化只有协议层一处实现。
  ///
  /// ⚠️ BUG-077（第四十九轮修）：此前本方法的失败会**裸奔** ——
  /// `_handleDetectedCode`（扫码路径）有自己的 `try/catch`，手输路径却没有；
  /// 落盘失败（盘满 / prefs 异常）时用户看到的是**未处理异常**而不是失败卡片。
  /// 现在与扫码路径同文案同警示（`配对失败：$e` + `_resultWarn`）。
  Future<void> _submitManualPair(
      String rawId, String rawName, String rawCode) async {
    final uri = '${PairQrProtocol.prefix}${rawId.trim()}/'
        '${Uri.encodeComponent(rawName.trim())}/${rawCode.trim()}';
    try {
      await _pairFromUri(uri);
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = '配对失败：$e';
          _resultWarn = true;
        });
      }
    }
  }

  /// 停止扫描并释放相机（mobile_scanner 6.x：controller 用后必须 dispose，
  /// 否则 MIUI 报「相机被占用」）。幂等，可安全在 dispose() 里调用。
  void _stopScan() {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      unawaited(controller.dispose());
    }
  }

  /// 扫码入口（接线）：先过权限闸门，再挂相机预览。
  ///
  /// 每次进入都换**全新** controller：MobileScanner 的 State 把 controller
  /// 存成 `late final` 且无 didUpdateWidget（包源码 mobile_scanner.dart:315），
  /// 换实例必须靠 key 强制重建子树；旧实例在重建前先 dispose，
  /// widget 内部的 stop() 对已释放实例是安全 no-op（源码 _stop() 的
  /// `_isDisposed` 守卫）。
  Future<void> _onScanPressed() async {
    final status = await Permission.camera.request();
    final gate = qrGateFromPerm(status);
    if (!mounted) return;
    _stopScan();
    if (gate == QrScanGate.granted) {
      setState(() {
        _permGate = null;
        _handledCode = '';
        _foreignQrNotice = false;
        _result = null;
        _scanning = true;
        _controller = MobileScannerController(
          autoStart: true,
          torchEnabled: false,
        );
      });
    } else {
      // 不再挂黑屏的 MobileScanner：直接给可读的失败面板。
      setState(() {
        _permGate = gate;
        _scanning = false;
      });
    }
  }

  /// 处理识别到的码：先停扫描（去抖 + 释放资源），再异步配对。
  /// 解析/落盘/通知任何一步抛异常都要变成**可见**的结果卡片。
  Future<void> _handleDetectedCode(String raw) async {
    _handledCode = raw;
    if (mounted) {
      setState(() {
        _scanning = false;
        _foreignQrNotice = false;
      });
    }
    _stopScan();
    try {
      await _pairFromUri(raw);
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = '配对失败：$e';
          _resultWarn = true;
        });
      }
    }
  }

  void _onDetect(BarcodeCapture capture) {
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      final kind = classifyDetectedQr(raw, b.format);
      if (kind == QrDetectKind.ignore) continue;
      // 与识别去抖**共用同一个节流状态**：同一个码只在第一次作出反应，
      // 连续帧重复读到它时直接短路（否则提示会每帧刷一次）。
      if (raw == _handledCode) return;
      if (kind == QrDetectKind.sonicShield) {
        unawaited(_handleDetectedCode(raw!));
        return;
      }
      // 是二维码但不是声盾配对码：就地一次性提示，**不停扫描**（用户可换角度
      // 重扫或改用手输）。不弹 SnackBar：每帧弹一次会刷屏并撑爆队列。
      _handledCode = raw!;
      if (mounted) setState(() => _foreignQrNotice = true);
      return;
    }
  }

  /// 扫码页内嵌的「手动输入配对码」入口（P0-3）。
  ///
  /// 扫不了码的用户此前被卡死在扫码页（手输入口只在远程遥控页，且要同时手输
  /// 16 位 ID + 名字 + 码）。这里只要求 **对端 16 位 ID + 8 位码**（名字可选），
  /// 字段级错误**就地**显示在输入框下方（不是只弹一条 SnackBar）。
  /// 提交走 [_submitManualPair] → [_pairFromUri]，与扫码完全同一条路径。
  Future<void> _openManualPairDialog() async {
    final idCtrl = TextEditingController();
    final codeCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    String? fieldError;
    final submit = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('手动输入配对码'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('扫不了码时，可在对端「我的设备」页抄下设备 ID 与配对码。'),
                const SizedBox(height: 8),
                TextField(
                  controller: idCtrl,
                  decoration: const InputDecoration(
                      labelText: '对端设备 ID（16 位十六进制）'),
                ),
                TextField(
                  controller: codeCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                      labelText: '配对码（8 位，如 AB2C-D5EF）'),
                ),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '对端名称（可选）'),
                ),
                if (fieldError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    fieldError!,
                    key: const Key('manual-pair-error'),
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final err = manualPairFieldError(idCtrl.text, codeCtrl.text);
                if (err != null) {
                  setLocal(() => fieldError = err);
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('配对'),
            ),
          ],
        ),
      ),
    );
    if (submit != true) return;
    await _submitManualPair(idCtrl.text, nameCtrl.text, codeCtrl.text);
  }

  /// 从任意失败态（扫描中扫不到 / 相机打开失败 / 权限被拒）切到「手动输入」：
  /// 先收掉扫描并释放相机，再开对话框。三个入口共用，避免各自漏掉 _stopScan
  /// （漏掉就会把相机占着，MIUI 上下一次打开直接失败）。
  Future<void> _switchToManual() async {
    if (_scanning) setState(() => _scanning = false);
    _stopScan();
    await _openManualPairDialog();
  }

  /// mobile_scanner 6.x 的错误面是 `errorBuilder`（相机打开失败：
  /// 权限被系统层拒 / 相机被其它应用占用 / 热插拔），
  /// 渲染成可见错误卡片，绝不黑屏。
  Widget _onScanError(
      BuildContext context, MobileScannerException error, Widget? child) {
    final detail = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied => '相机权限被系统拒绝：'
          '请到 系统设置 → 应用 → 声盾 → 权限 开启相机',
      _ => '相机启动失败（MIUI 常见：相机被其它应用占用）。'
          '请关闭其它使用相机的应用后重试',
    };
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.camera_alt_outlined,
                color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 8),
            Text(detail, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
              onPressed: _onScanPressed,
            ),
            // 相机打开失败同样是「扫不了码」，别让用户卡死：给手输出口。
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.keyboard),
              label: const Text('改用手动输入配对码'),
              onPressed: _switchToManual,
            ),
          ],
        ),
      ),
    );
  }

  /// 手电筒开关。toggleTorch 是 async 函数——异常（相机尚未初始化 /
  /// 无手电筒）会进 Future 而不是同步抛出，必须在 await 侧接住。
  Future<void> _toggleTorch(MobileScannerController controller) async {
    try {
      await controller.toggleTorch();
    } catch (_) {
      // 静默忽略：未初始化时 toggleTorch 是 no-op 或抛 controllerUninitialized。
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码配对')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_scanning) ...[
            SizedBox(
              height: 420,
              child: MobileScanner(
                // controller 是 late final 且无 didUpdateWidget，
                // 换实例必须用 key 强制重建扫描子树（见 _onScanPressed）。
                key: ValueKey<MobileScannerController?>(_controller),
                controller: _controller,
                onDetect: _onDetect,
                onDetectError: (Object error, StackTrace stackTrace) {
                  // 识别流异常不静默吞掉（6.x 默认是空实现）。
                  debugPrint('mobile_scanner detect error: $error');
                },
                errorBuilder: _onScanError,
              ),
            ),
            // 手电筒开关：暗光环境下扫不了码的最小成本解。
            ListenableBuilder(
              listenable: _controller ?? Listenable.merge([]),
              builder: (context, _) {
                final controller = _controller;
                final torchOn = controller?.value.torchState == TorchState.on;
                return IconButton(
                  tooltip: torchOn ? '关闭手电筒' : '打开手电筒',
                  icon: Icon(torchOn ? Icons.flashlight_on : Icons.flashlight_off),
                  onPressed: controller == null
                      ? null
                      : () {
                          unawaited(_toggleTorch(controller));
                        },
                );
              },
            ),
            const SizedBox(height: 4),
            const Text(
              '对准另一台设备「我的设备」页出示的配对码',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
            // P0-4：检测到「是二维码但不是声盾配对码」的一次性去抖提示。
            if (_foreignQrNotice)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '这不是声盾配对码，请扫描对方的声盾配对二维码',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            TextButton.icon(
              icon: const Icon(Icons.close),
              label: const Text('取消扫码'),
              onPressed: () {
                setState(() => _scanning = false);
                _stopScan();
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.keyboard),
              label: const Text('扫不了码？手动输入'),
              onPressed: _switchToManual,
            ),
          ] else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text('我的配对二维码',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    if (_deviceId.isEmpty)
                      const CircularProgressIndicator()
                    else ...[
                      Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(8),
                        child: QrImageView(
                          data: _myUri(),
                          size: 220,
                          backgroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(_deviceName,
                          style: Theme.of(context).textTheme.titleSmall),
                      SelectableText(_pairCode,
                          style: Theme.of(context).textTheme.bodyLarge),
                      const SizedBox(height: 6),
                      const Text('对端扫码即与本机配对（物理在场 = 授权确认）',
                          style: TextStyle(fontSize: 12)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_result != null)
              Card(
                color: _resultWarn
                    ? Theme.of(context).colorScheme.errorContainer
                    : Theme.of(context).colorScheme.primaryContainer,
                child: ListTile(
                  leading: Icon(_resultWarn
                      ? Icons.error_outline
                      : Icons.check_circle),
                  title: Text(_result!),
                ),
              ),
            if (_permGate != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(Icons.no_photography_outlined,
                          color: Theme.of(context).colorScheme.error),
                      const SizedBox(height: 8),
                      Text(
                        _permGate == QrScanGate.permanentlyDenied
                            ? '相机权限已被永久拒绝。'
                                '请到 系统设置 → 应用 → 声盾 → 权限 手动开启相机'
                            : '扫码需要相机权限，当前未获授权。'
                                '可到 系统设置 → 应用 → 声盾 → 权限 手动开启',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      if (_permGate == QrScanGate.permanentlyDenied)
                        FilledButton.icon(
                          icon: const Icon(Icons.settings),
                          label: const Text('打开系统设置'),
                          onPressed: () {
                            unawaited(openAppSettings());
                          },
                        ),
                      // P0-2：权限全拒也必须能完成配对 —— 面板内常驻手输出口。
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.keyboard),
                        label: const Text('改用手动输入配对码'),
                        onPressed: _switchToManual,
                      ),
                    ],
                  ),
                ),
              ),
            FilledButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫描对端二维码'),
              onPressed: _onScanPressed,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.keyboard),
              label: const Text('扫不了码？手动输入'),
              onPressed: _switchToManual,
            ),
            const SizedBox(height: 12),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '安全说明：配对码即共享秘密（HKDF→AES-256-GCM 派生密钥）。'
                  '仅与本人或已获明确授权的设备配对；配对完成即永久互信，'
                  '可随时在「远程遥控」页取消。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
