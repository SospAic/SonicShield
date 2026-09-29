// `Uint8List` 由 `package:flutter/services.dart` 转出，别单独 import `dart:typed_data`
// （analyze 的 `unnecessary_import` 会让门禁第 1 步直接判红）。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

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

// =====================================================================
// 第二层（**平台层**）：直接替换 `RecordPlatform.instance`
// =====================================================================
//
// ## 为什么通道桩不够（第四十一轮用探针实测换来）
//
// `RcControllerService` 是**进程内单例**，其 `_rec` 是
// `final AudioRecorder _rec = AudioRecorder()`（`controller_service.dart:78`）——
// **首次构造**时只发起一次 `create()`，而 `AudioRecorder._safeCall` 每次调用
// 都先 `await _createFuture`（`record-7.1.1/lib/src/record.dart:216-224`）。
//
// 实测证据（`_pt/q5_probe_raw.txt`，两条用例顺序执行）：
// ```
// probe t1: fresh singleton + create   → CALLS=[create]
// probe t2: reuse the SAME singleton   → DONE=false CALLS=[]     ← 永久挂起
// ```
// 即：**用 method channel 桩时，`create()` 的往返在跨用例后不再推进**
// ⇒ `_createFuture` 永久不完成 ⇒ 同一进程内**任何**
// `start() / stop() / hasPermission()` 都**永久挂起**（不是抛错！）。
// 症状极具误导性：断言报"找不到某段文本"，看起来像 UI 缺陷，根因却在
// 十几条用例之前的一次单例构造。`_pt/q4_probe_raw.txt` 又证明
// **同一条用例内**通道桩完全可用（`CALLS=[create, hasPermission, stop]`）——
// 所以这不是"桩写错了"，而是"跨用例的异步完成时机"问题。
//
// ⇒ 平台层桩把 `create()` 变成**纯 microtask**（无平台消息往返），
// 配合 `setUp` 里的**真实 zone 预热**，让 `_createFuture` 在用例开始前
// 就真正完成。这是插件架构本身提供的扩展点
// （`RecordPlatform.instance` 是公开可写静态字段，无 token 校验）。
//
// ⚠️ 只桩"平台返回"，不桩业务判断：`hasPermission` / `stop` 的返回值仍由
// 用例显式给出，且这里**不实现任何录制**（宿主本来也录不了）。

/// 平台层假实现：记录被调用的方法名，按用例给定的返回值作答。
class FakeRecordPlatform extends RecordPlatform {
  FakeRecordPlatform(
      {this.hasPermissionResult = false, this.stopPath, this.startError});

  /// `hasPermission` 的返回值（默认 false = 平台拒绝录音，与 [stubRecord] 同侧）。
  bool hasPermissionResult;

  /// `stop()` 返回的路径；null 表示"没录到文件"（大多数宿主用例的期望）。
  String? stopPath;

  /// 非 null ⇒ `start()` 抛出该对象（第 49 轮：`_recordEvidence` 的 catch
  /// 兜底路径需要"开始录音就失败"的可编程失败，不能只靠 hasPermission）。
  Object? startError;

  /// 被调用的方法名序列 —— 断言"真的走了录音通道"用它，别断言界面文案。
  final List<String> calls = <String>[];

  bool _recording = false;

  @override
  Future<void> create(String recorderId) async => calls.add('create');

  @override
  Future<void> start(String recorderId, RecordConfig config,
      {required String path}) async {
    calls.add('start');
    final err = startError;
    if (err != null) throw err;
    _recording = true;
  }

  @override
  Future<Stream<Uint8List>> startStream(
      String recorderId, RecordConfig config) async {
    calls.add('startStream');
    _recording = true;
    return const Stream<Uint8List>.empty();
  }

  @override
  Future<String?> stop(String recorderId) async {
    calls.add('stop');
    _recording = false;
    return stopPath;
  }

  @override
  Future<void> cancel(String recorderId) async {
    calls.add('cancel');
    _recording = false;
  }

  @override
  Future<void> pause(String recorderId) async => calls.add('pause');

  @override
  Future<void> resume(String recorderId) async => calls.add('resume');

  @override
  Future<bool> isRecording(String recorderId) async {
    calls.add('isRecording');
    return _recording;
  }

  @override
  Future<bool> isPaused(String recorderId) async {
    calls.add('isPaused');
    return false;
  }

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async {
    calls.add('hasPermission');
    return hasPermissionResult;
  }

  @override
  Future<void> dispose(String recorderId) async => calls.add('dispose');

  @override
  Future<Amplitude> getAmplitude(String recorderId) async {
    calls.add('getAmplitude');
    return Amplitude(current: -160, max: -160);
  }

  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder encoder) async {
    calls.add('isEncoderSupported');
    return true;
  }

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async {
    calls.add('listInputDevices');
    return const <InputDevice>[];
  }

  @override
  void setOnConfigChanged(
      String recorderId, void Function(RecordConfig config)? handler) {}

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();
}

RecordPlatform? _savedPlatform;

/// 装上平台层假实现，返回它（便于断言 [FakeRecordPlatform.calls]）。
/// 用 [restoreRecordPlatform] 还原 —— **必须在 tearDown 里调用**。
FakeRecordPlatform installFakeRecordPlatform({
  bool hasPermissionResult = false,
  String? stopPath,
  Object? startError,
}) {
  _savedPlatform ??= RecordPlatform.instance;
  final fake = FakeRecordPlatform(
      hasPermissionResult: hasPermissionResult,
      stopPath: stopPath,
      startError: startError);
  RecordPlatform.instance = fake;
  return fake;
}

/// 还原平台实现。
void restoreRecordPlatform() {
  final saved = _savedPlatform;
  if (saved != null) {
    RecordPlatform.instance = saved;
    _savedPlatform = null;
  }
}
