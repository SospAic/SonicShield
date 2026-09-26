import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `record`（AudioRecorder）的方法通道桩。
///
/// ## 与 [permission_stub] 同原则：只桩"平台返回"，不桩业务判断
///
/// 通道名 / 方法名 / 参数形状全部照抄插件真实实现：
///
/// | 事实 | 出处 |
/// |---|---|
/// | 通道名 `com.llfbandit.record/messages` | `record_method_channel_mixin.dart:11` |
/// | `AudioRecorder()` 构造即 `create(recorderId)` | `record-7.1.1/lib/src/record.dart:31-41` |
/// | `hasPermission(recorderId, request)` → `bool?` | mixin `:20-28` |
/// | `start(recorderId, path, ...config)` → `void` | mixin `:54-68` |
/// | `stop(recorderId)` → `String?` | mixin `:89-96` |
///
/// ## 为什么默认 `hasPermission: false`
///
/// `RcControllerService.pttStart()` 在拿到权限后会走
/// `Directory.systemTemp.createTemp('ptt')` —— 这是**真实 dart:io**，
/// 在 `testWidgets` 的 `FakeAsync` 里**不会完成**（正是技能
/// `flutter-widget-test-harness` 记的那类坑）。
/// 所以默认让平台侧**拒绝录音权限**，把执行停在
/// `pttStart()` 的 `if (!await _rec.hasPermission()) return false;` ——
/// 这样覆盖的是**真实存在的失败分支**（"录音启动失败"提示），
/// 既不用真 IO，也不是编造的成功路径。
///
/// ⚠️ **必须在 `addTearDown` 里 `clearRecordStub()`**：通道处理器是全局的。
const MethodChannel recordChannel =
    MethodChannel('com.llfbandit.record/messages');

/// 安装桩。返回 [calls] 记录**被调用过的方法名序列**，供断言
/// （例："点了录音就必须真的调用 start，而不是只改界面状态"）。
List<String> stubRecord({
  bool hasPermission = false,
  String? stopPath,
}) {
  final calls = <String>[];

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(recordChannel, (call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'create':
      case 'start':
      case 'cancel':
      case 'dispose':
        return null;
      case 'hasPermission':
        return hasPermission;
      case 'stop':
        return stopPath;
      case 'isRecording':
      case 'isPaused':
        return false;
      case 'getAmplitude':
        return <String, double>{'current': -160.0, 'max': -160.0};
      default:
        // 不认识的调用必须炸 —— 静默放行等于给未来的调用偷偷开后门。
        throw MissingPluginException('未桩的 record 方法：${call.method}');
    }
  });
  return calls;
}

/// 卸载桩。见文件头 ⚠️。
void clearRecordStub() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(recordChannel, null);
}
