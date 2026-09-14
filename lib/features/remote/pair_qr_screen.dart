import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (store.deviceId.isEmpty) {
      final id = RcCodec.generateDeviceId();
      await store.setIdentity(id, '声盾-${id.substring(0, 4)}');
    }
    // 持久配对码：首次生成后固定（多台控制器可重复扫码配对本机）。
    var code = prefs.getString('rc_pair_code');
    if (code == null || code.length != 8) {
      code = RcCodec.generatePairingCode().replaceAll('-', '');
      await prefs.setString('rc_pair_code', code);
    }
    if (!mounted) return;
    setState(() {
      _deviceId = store.deviceId;
      _deviceName = store.deviceName;
      _pairCode = code!;
    });
  }

  String _myUri() =>
      'sonicshield://pair/$_deviceId/${Uri.encodeComponent(_deviceName)}/'
      '$_pairCode';

  /// 解析对端配对二维码；格式不符返回 null。
  static ({String deviceId, String name, String code})? parseUri(String uri) {
    const prefix = 'sonicshield://pair/';
    if (!uri.startsWith(prefix)) return null;
    final parts = uri.substring(prefix.length).split('/');
    if (parts.length < 3) return null;
    final id = parts[0];
    final name = Uri.decodeComponent(parts[1]);
    final code = parts[2].replaceAll('-', '').toUpperCase();
    if (id.length != 16 || code.length != 8) return null;
    return (deviceId: id, name: name, code: code);
  }

  Future<void> _pairFromUri(String uri) async {
    final parsed = parseUri(uri);
    if (parsed == null) {
      if (mounted) setState(() => _result = '二维码不是有效的声盾配对码');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    await store.addPaired(PairedEndpoint(
      deviceId: parsed.deviceId,
      name: parsed.name,
      secret: parsed.code,
      pairedAt: DateTime.now(),
    ));
    if (mounted) {
      setState(() {
        _result = '已配对：${parsed.name}（${parsed.deviceId}）';
        _scanning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码配对')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_scanning)
            SizedBox(
              height: 420,
              child: MobileScanner(
                onDetect: (capture) {
                  for (final b in capture.barcodes) {
                    final raw = b.rawValue;
                    if (raw != null && raw.startsWith('sonicshield://pair/')) {
                      _pairFromUri(raw);
                      break;
                    }
                  }
                },
              ),
            )
          else ...[
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
                color: Theme.of(context).colorScheme.primaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.check_circle),
                  title: Text(_result!),
                ),
              ),
            FilledButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫描对端二维码'),
              onPressed: () async {
                final scaffold = ScaffoldMessenger.of(context);
                final granted = await Permission.camera.request().isGranted;
                if (!granted) {
                  scaffold.showSnackBar(
                      const SnackBar(content: Text('需要相机权限进行扫码')));
                  return;
                }
                if (mounted) setState(() => _scanning = true);
              },
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
