import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

/// `PlaybackService.dispose()` 的**失败路径**锁（PB09）。
///
/// ## 为什么必须用「源码锁」而不是行为用例
///
/// 要触发 `dispose()` 的失败分支，得让 `_player` 在 `dispose()` 里抛异常。而：
/// - `_player` 是**私有字段**，全仓唯一赋值点是 `play()` 内的
///   `_player ??= AudioPlayer()`；
/// - 宿主测试没有 just_audio 平台实现，也没有注入 `_player` 的缝
///   （`PlaybackService()` 构造器不收参数）。
///
/// ⇒ 该分支在宿主上**结构不可达**。
///
/// ⚠️ 这里**刻意不写**一个 `extends PlaybackService` 覆写 `dispose()` 的替身用例：
/// 那测的是**替身自己的方法**，无论生产代码怎么写都会绿 —— 恒真断言等于没测
/// （本项目已明令禁止，见 `docs/17 §62.2`）。
/// 故改用本项目对不可达分支的既定做法：**源码锁 + 变异证伪**（同 BUG-065 的
/// `dir_path_interpolation_test.dart`）。本用例的可失败性已用变异证明
/// （去掉 `try`/`finally` 即红，见 `docs/12 §63`）。
///
/// ## 锁的是什么行为
///
/// 真实调用点 `lib/features/sounds/sound_library_screen.dart:321`：
///
/// ```dart
/// @override
/// void dispose() {
///   _previewPlayer.dispose();   // ← 无人 await（fire-and-forget）
///   super.dispose();
/// }
/// ```
///
/// 因为**没有 await**，`dispose()` 一旦抛异常就会升级成**未处理的异步错误**
/// （页面退出时冒一条谁也读不懂的栈）。而原实现是：
///
/// ```dart
/// Future<void> dispose() async {
///   await _player?.dispose();   // ← 抛了
///   _player = null;             // ← 永不执行
/// }
/// ```
///
/// 两个后果，正是本锁要钉住的：
/// 1. 异常逃逸到调用方（→ 未处理异步错误）；
/// 2. `_player = null` 在抛点之后 ⇒ **已销毁的播放器被留在字段里**，
///    后续 `play()` 的 `_player ??=` 会复用它（`stop()` 早已是吞异常语义，
///    `dispose()` 与之不一致 ⇒ 属"单点偏离既有惯例"，人眼评审抓不到）。
void main() {
  final src = File('lib/services/playback_service.dart').readAsStringSync();

  test('PB09 dispose 必须吞掉释放异常，且 `_player = null` 无条件执行', () {
    final body = methodBody(src, 'Future<void> dispose() async {');

    expect(body, isNotEmpty,
        reason: '没找到 `Future<void> dispose() async {` —— 源码锁定位已失效，'
            '请同步更新本测试（不要直接删掉它）');

    // 反面样本：证明取到的**确实是 dispose()** 而不是隔壁的 stop()。
    // 没有这一条的话，`methodBody` 一旦定位错方法，下面两条断言可能
    // 恰好被 stop() 满足 ⇒ 锁失效却仍然全绿。
    expect(body, isNot(contains('_stopRequested')),
        reason: '取到的方法体像是 stop() —— 源码锁定位失效');
    expect(body, contains('_player'),
        reason: '取到的方法体里没有 `_player` —— 源码锁定位失效');

    // ① 必须捕获异常（否则 fire-and-forget 的调用方会被未处理异步错误打中）。
    expect(body, contains('on Object'),
        reason: 'dispose() 必须吞掉播放器释放异常（与 stop() 同一处置）；'
            '否则 sound_library_screen 的 `_previewPlayer.dispose()` '
            '（无人 await）会变成未处理异步错误');

    // ② `_player = null` 必须在 `finally` 内 —— 放在 try 之后的话，
    //    一次抛异常就把**已销毁的播放器**留在字段里。
    final finIdx = body.indexOf('finally');
    expect(finIdx, greaterThan(-1),
        reason: 'dispose() 必须用 finally 保证字段清空（try/catch 不够）');
    expect(body.substring(finIdx), contains('_player = null'),
        reason: '`_player = null` 必须落在 finally 内，才能无条件执行');
  });
}


