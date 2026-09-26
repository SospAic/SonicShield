import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

/// `permission_handler` 的方法通道桩 —— 让**权限分支**在宿主测试里真实执行。
///
/// ## 为什么要它
///
/// 生产代码里 7 处 `Permission.*.request()`（`guard_screen` / `call_screen` /
/// `pair_qr_screen` / `ptt_tab` / `remote_screen` / `permission_flow`），
/// 而宿主测试**一处都没走到过** —— 因为 `Permission.microphone.request()`
/// 会打到真通道，宿主没有实现 → `MissingPluginException`。
/// 结果是：「权限被拒」这类**用户最容易撞上的分支**长期零覆盖。
///
/// ## 为什么这样桩是"真的"而不是"假用例"
///
/// 通道名、方法名、编解码**全部照抄插件真实实现**，不是随手返回一个 bool：
///
/// | 事实 | 出处 |
/// |---|---|
/// | 通道名 `flutter.baseflow.com/permissions/methods` | `method_channel_permission_handler.dart:9` |
/// | 方法 `requestPermissions(List<int>)` → `Map<int,int>` | 同上 `:84-91` |
/// | 方法 `checkPermissionStatus(int)` → `int` | 同上 `:16-24` |
/// | 编码 = `Permission.value` | `codec.dart:28` `encodePermissions` |
/// | 解码 = `PermissionStatusValue.statusByValue` | `codec.dart:4` |
///
/// 桩里**不硬编码** `microphone = 7` / `granted = 1`，一律用 `.value` / `.index` 引用真枚举
/// ⇒ 插件升级改了编码，桩自动跟着变，不会静默撒谎。
///
/// ## 用法
///
/// ```dart
/// stubPermissions({Permission.microphone: PermissionStatus.granted});
/// addTearDown(clearPermissionStub);
/// ```
///
/// ⚠️ **必须在 `addTearDown` 里清掉**：`TestDefaultBinaryMessengerBinding` 的
/// 处理器是**全局**的，漏清会串到同进程的下一个用例。
const MethodChannel permissionChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');

/// 安装桩。`statuses` 里没列的权限 → 视为 `denied`（保守侧：
/// 与项目通则「安全选项的失败路径不得降级到更不安全的一侧」一致）。
///
/// 记录 [requests] 供断言"到底申请了哪些权限"（防止"申请了却没用结果"这类
/// BUG-062 形态复发）。
List<List<Permission>> stubPermissions(
  Map<Permission, PermissionStatus> statuses,
) {
  final encoded = <int, int>{
    for (final e in statuses.entries) e.key.value: e.value.index,
  };
  final requests = <List<Permission>>[];

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(permissionChannel, (call) async {
    switch (call.method) {
      case 'requestPermissions':
        final ids = (call.arguments as List).cast<int>();
        requests.add([for (final id in ids) Permission.byValue(id)]);
        // 只回填**被申请**的那些：和真机行为一致（没申请的不会出现在结果里）。
        return <int, int>{
          for (final id in ids) id: encoded[id] ?? PermissionStatus.denied.index,
        };
      case 'checkPermissionStatus':
        final id = call.arguments as int;
        return encoded[id] ?? PermissionStatus.denied.index;
      case 'openAppSettings':
        return true;
      case 'shouldShowRequestRationale':
        return false;
      default:
        // 不认识的调用**必须炸**，否则等于给未来的调用偷偷放行。
        throw MissingPluginException('未桩的 permission 方法：${call.method}');
    }
  });
  return requests;
}

/// 卸载桩。见文件头的 ⚠️。
void clearPermissionStub() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(permissionChannel, null);
}
