import 'package:shared_preferences/shared_preferences.dart';

import '../remote/endpoint_service.dart';
import '../remote/protocol.dart';
import '../remote/remote_store.dart';

/// 本机名称服务（FR-77，第八十四轮用户明文）。
///
/// ## 需求原文
///
/// 「本机和远程设备名称支持自定义名称，**本机名称修改需要通知所有已绑定远程
/// 设备并在他们的列表中同步更新**，本机更新远程机器名称相当于为当机器取别名，
/// 显示为 `别名（远程机器真实名称）`，**别名只在本机显示**。」
///
/// ## 本服务负责哪一半
///
/// 本服务只做**本机名**这一半（「通知所有已绑定远程设备」）：改名 → 落盘 →
/// 对**每个已配对端点**下发 `device.rename {name}`。另一半（给远程机器取别名）
/// 是**纯本机数据**（`RemoteStore.renamePaired`），不发任何网络消息 ——
/// 别名只在本机显示，这是需求里的硬边界。
///
/// ## 为什么单独一个服务而不是塞进 UI
///
/// 广播逻辑要能**离线**、要能**被测试**（不发真网络）。把它抽出来：
/// - UI 只调 [renameLocal]；
/// - 门禁测试可用 [senderOverride] 注入替身，断言"确实对每个端点都发了一条"，
///   而不必起真 broker（与 `endpoint_service.sendTo` 的宿主替身同一套路）。
class DeviceNameService {
  DeviceNameService._();

  static final DeviceNameService instance = DeviceNameService._();

  /// 本机名长度上限（与 `RemoteStore` 侧一致；过长会撑坏对端列表 UI）。
  static const int maxLen = 32;

  /// 出站发送的宿主替身（测试注入；**不改生产默认行为**）。
  ///
  /// 签名与 [RcEndpointService.sendTo] 对齐：返回是否**已发成功**。
  /// 未注入时走真实 [RcEndpointService.instance.sendTo]。
  Future<bool> Function(PairedEndpoint endpoint, RcMessage msg,
          RemoteStore store)?
      senderOverride;

  /// 把本机名改为 [name] 并**广播给所有已绑定端点**。
  ///
  /// 返回广播结果：`total` = 已配对端点数，`ok` = 成功下发数。
  /// 名称为空 / 超长一律**拒绝**（不写盘、不广播）—— 静默写一个空名会让对端
  /// 列表出现"（未知设备）"，属"失败不可静默"要防的那类。
  Future<DeviceRenameResult> renameLocal(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const DeviceRenameResult(ok: false, total: 0, sent: 0,
          error: '名称不能为空');
    }
    if (trimmed.length > maxLen) {
      return const DeviceRenameResult(ok: false, total: 0, sent: 0,
          error: '名称不能超过 $maxLen 个字符');
    }

    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    // ① 先落盘：即使一台都没发出去，本机名也已生效（下次上线仍广播）。
    final self = store.deviceId;
    await store.setIdentity(self.isEmpty ? _genSelfId() : self, trimmed);

    // ② 再广播给所有已绑定端点（别名不参与，只广播真名）。
    final paired = store.paired();
    var sent = 0;
    for (final e in paired) {
      final msg = RcMessage.now(RcCmd.deviceRename, {'name': trimmed});
      final ok = await _send(e, msg, store);
      if (ok) sent++;
    }
    return DeviceRenameResult(
        ok: true, total: paired.length, sent: sent, error: '');
  }

  Future<bool> _send(
      PairedEndpoint e, RcMessage msg, RemoteStore store) async {
    final override = senderOverride;
    if (override != null) return override(e, msg, store);
    return RcEndpointService.instance.sendTo(e, msg, store);
  }

  /// 生成本机 ID（16 位十六进制，与配对流程同形）。
  static String _genSelfId() {
    const alphabet = '0123456789abcdef';
    final rnd = DateTime.now().microsecondsSinceEpoch;
    final buf = StringBuffer();
    var x = rnd;
    for (var i = 0; i < 16; i++) {
      buf.write(alphabet[(x + i * 7) % 16]);
      x = x ~/ 3 + 11;
    }
    return buf.toString();
  }
}

/// 本机改名广播的结果（值即语义，便于 UI 如实回报）。
class DeviceRenameResult {
  const DeviceRenameResult({
    required this.ok,
    required this.total,
    required this.sent,
    required this.error,
  });

  /// 是否**成功受理**（名校验通过并已落盘）。注意：受理成功 ≠ 全部端点已收到
  /// （端点可能离线，那属于 [sent] < [total]，UI 要如实说，不许假成功）。
  final bool ok;

  /// 已绑定端点总数。
  final int total;

  /// 成功下发的端点数。
  final int sent;

  /// 失败原因（[ok] 为 false 时非空）。
  final String error;
}
