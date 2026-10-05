// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/dashboard/dashboard_screen.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/sound_guard_service.dart';

import 'support/permission_stub.dart';

import 'support/source_text.dart';

/// **静默失败锁**（X3 轮）：给 W2 轮修复的 **10 处「静默失败」** 逐处上锁
/// （修复清单见 `_pt/audit/W2-silent.md` 第二节 F1–F10）。
///
/// ## 锁的分档
///
/// | 锁 | 类型 | 理由 |
/// |---|---|---|
/// | F1（守卫 errors 流） | **行为** | `SoundGuardService` 可在宿主注入假录音器实例化 |
/// | F9（仪表盘启动失败 SnackBar） | **行为** | `BackgroundServiceManager.startHook` 测试缝可直接让 `start()` 返回 false |
/// | F2–F8（引擎侧 7 处） | **源码文本** | `background_engine.dart` 跑在 `flutter_background_service` 的
///   引擎 isolate、依赖真实平台插件，宿主**实例化不了**（覆盖率 0.44% 的根因）——
///   硬写行为测试只会假红/假绿，故锁结构（与 `engine_vibrate_ack_lock_test.dart` 同法） |
/// | F10（远程任务页未选端点提示） | **源码文本** | `initialSelectedId()` 在有端点时必回落第一条
///   （`remote_store.dart`），`_endpoint == null` 分支在本页 UI 上**结构不可达**
///   （`_endpoints.isEmpty` 时 build 提前走 `_noEndpoint()`，FAB 根本不渲染），
///   行为测试写不出来；锁「提示必须存在」防回归 |
/// | N-3 / F-3（两条 Kotlin 自恢复路径的静默 catch） | **源码文本** | 见下 |
///
/// ## N-3 / F-3 追加（SEC1 第 35 轮）
///
/// 两条「拉起前台服务失败」的路径此前都只写 logcat，用户与审计完全看不见：
///
/// | 文件 | 触发场景 |
/// |---|---|
/// | `packages/native_bridge/.../AlarmWatchdogReceiver.kt` | 通道B 精确闹钟唤醒引擎被平台拒 |
/// | `android/app/src/main/kotlin/.../BootReceiver.kt` | Android 15+ 禁止 `BOOT_COMPLETED` 启动 `mediaPlayback`/`dataSync` 型 FGS ⇒ 方案① 已改为排精确闹钟（见下） |
///
/// **F-3 方案①（第 70 轮）**：`BootReceiver` 不再直接 `startForegroundService`
/// （Android 12+ 后台启动 FGS 受限、Android 15+ 对 `BOOT_COMPLETED` 直接拒绝），
/// 改为排一次性精确闹钟、复用既有 `AlarmWatchdogReceiver` 拉起引擎。因此
/// `SLS-10` 的锚点从 `startForegroundService` 改为 `setExactAndAllowWhileIdle`，
/// 对应的反面样本 `SLX-90k` 也同步换成"排了闹钟但 catch 静默"的形状。
///
/// Kotlin **不在 `flutter analyze` 范围、宿主测试也不编译 Kotlin**（BUG-074），
/// 因此只能源码文本锁（与 `android_compat_lock_test.dart` 同法）。锁的是
/// 「catch 里必须调 `SelfHealNotice.failed(...)`」+「`SelfHealNotice` 必须真的
/// 发通知」，`SLX-90j/k/l` 是它们的反面样本。
/// ⚠️ 这三条只保证**代码形状**；Kotlin 是否编译通过、通知是否真的弹出
/// **只能靠真机构建验证**。
///
/// ## 项目铁律：断言必须**非恒真**
///
/// 每条源码锁的判定都抽成顶层纯函数（[judgeGuardErrWiring] …），并且每条都配
/// **反面样本**（组 `SLX-90*`）证明它对「坏代码」真的会判红 —— 否则一个恒真的
/// 检测器就能让整组锁假绿。文本扫描一律**先剥注释**（[stripComments] 见
/// `test/support/source_text.dart`）：本项目刻意在注释里写明缺陷形状，不剥注释
/// 锁会把自己的说明文字当成违规（假红）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ══════════════════════════════════════════════ 剥注释
  // 实现见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源）。

  final engineSrc = stripComments(
      File('lib/services/background_engine.dart').readAsStringSync());
  final tasksSrc = stripComments(
      File('lib/features/remote/remote_tasks_tab.dart').readAsStringSync());
  // N-3 / F-3（SEC1 第 35 轮）：两条 Kotlin 自恢复路径的静默 catch。
  // Kotlin 不在 `flutter analyze` 范围内，也无法在本环境编译 ⇒ 只能源码文本锁。
  final watchdogKt = stripComments(File(
          'packages/native_bridge/android/src/main/kotlin/com/sonicshield/'
          'native_bridge/AlarmWatchdogReceiver.kt')
      .readAsStringSync());
  final bootKt = stripComments(File(
          'android/app/src/main/kotlin/com/sonicshield/sonic_shield/'
          'BootReceiver.kt')
      .readAsStringSync());
  final selfHealKt = stripComments(File(
          'packages/native_bridge/android/src/main/kotlin/com/sonicshield/'
          'native_bridge/SelfHealNotice.kt')
      .readAsStringSync());
  // P2-33：精确闹钟权限重新授予的自动重排接收器（Kotlin 源码，同上只能文本锁）。
  final exactGrantKt = stripComments(File(
          'packages/native_bridge/android/src/main/kotlin/com/sonicshield/'
          'native_bridge/ExactAlarmPermissionReceiver.kt')
      .readAsStringSync());
  // P2-33 的注册载体：接收器必须在清单里声明 action，否则广播永远送不进来。
  final pluginManifest = File(
          'packages/native_bridge/android/src/main/AndroidManifest.xml')
      .readAsStringSync();
  // P2-16：`device.alert` 原生实现（全屏 intent 闸门 / 音频焦点申请与释放 / 音量还原）。
  final nativePluginKt = stripComments(File(
          'packages/native_bridge/android/src/main/kotlin/com/sonicshield/'
          'native_bridge/NativeBridgePlugin.kt')
      .readAsStringSync());

  // ══════════════════════════════════════════════ 行为锁：F1 守卫采流异常留痕
  group('SLB 行为锁（宿主可实例化）', () {
    test('SLB-01 [F1] 守卫采流中途出错 → errors 流留痕 + isRunning=false，错误不混进 events', () async {
      final rec = _FakeRecorder();
      final svc = SoundGuardService(recorder: rec);
      final errors = <Object>[];
      final events = <SoundEvent>[];
      final subs = <StreamSubscription<dynamic>>[
        svc.errors.listen(errors.add),
        svc.events.listen(events.add),
      ];
      final r = await svc.start(const SoundTrigger());
      expect(r.ok, isTrue);

      // 模拟「麦克风被其它应用抢占」：采流中途抛错。
      rec.chunks.addError(StateError('麦克风被抢占'));
      await pumpEventQueue();

      expect(errors, hasLength(1),
          reason: '★ W2-F1 之前 onError 只置 _running=false：守卫悄悄停了，'
              '「为什么」完全缺失。失败必须经 errors 流留痕');
      expect(errors.first.toString(), contains('麦克风被抢占'),
          reason: '留痕必须带真实原因，不能是一句编造的占位文案');
      expect(svc.isRunning, isFalse,
          reason: '停止方向走安全侧：流断即已停');
      expect(events, isEmpty,
          reason: '错误必须与声音事件分流 —— 混进 events 会被消费者当成一次声音事件触发动作');
      for (final s in subs) {
        await s.cancel();
      }
      await svc.dispose();
    });

    _dashboardLocks();
  });

  // ══════════════════════════════════════════════ 源码锁 + 非恒真证明
  _sourceLocks(engineSrc, tasksSrc, watchdogKt, bootKt, selfHealKt,
      exactGrantKt, pluginManifest, nativePluginKt);
}

// ══════════════════════════════════════════════════════════════════════════
// 行为锁：F9 仪表盘「启动失败必须提示」
// ══════════════════════════════════════════════════════════════════════════

/// 挂载仪表盘（缝与桩写法照抄 `dashboard_screen_test.dart` 的 pump）。
Future<void> _pumpDash(WidgetTester tester, {required bool startOk}) async {
  SharedPreferences.setMockInitialValues({'compliance_accepted_v1': true});
  await SharedPreferences.getInstance();

  const st = EngineState(running: false, pendingCount: 0);
  BackgroundServiceManager.lastForTest = st;
  BackgroundServiceManager.stateForTest = Stream.value(st);
  BackgroundServiceManager.startHook = () async => startOk;
  BackgroundServiceManager.invokeHook = (_, __) async {};

  stubPermissions({
    Permission.notification: PermissionStatus.granted,
    Permission.microphone: PermissionStatus.granted,
  });
  const nativeChannel = MethodChannel('sonic_shield/native');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(nativeChannel, (call) async => null);
  addTearDown(() {
    BackgroundServiceManager.lastForTest = null;
    BackgroundServiceManager.stateForTest = null;
    BackgroundServiceManager.startHook = null;
    BackgroundServiceManager.invokeHook = null;
    clearPermissionStub();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
  });

  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.linux),
      home: const DashboardScreen(),
    ),
  ));
  await tester.pump();
}

void _dashboardLocks() {
  testWidgets('SLB-02 [F9] mgr.start() 返回 false → 必须弹 SnackBar 指明排查方向', (tester) async {
    await _pumpDash(tester, startOk: false);
    // running=false → 开关当前为关，点击 = 请求启动
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SnackBar), findsOneWidget,
        reason: '★ W2-F9 之前 onChanged 忽略 start() 的返回值：启动失败 → 开关弹回 + 零提示');
    expect(find.textContaining('守护启动失败：后台服务未响应'), findsOneWidget,
        reason: '文案必须指向真实排查方向（电池优化白名单/厂商自启动），不能只说"失败了"');

    // 冲掉 SnackBar 的 4s 自动消失 Timer 与退出动画，避免"Timer still pending"误报。
    await tester.pump(const Duration(seconds: 4, milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('SLB-03 [F9 反例] start() 成功 → 不弹失败提示（证明 SLB-02 判得有区分度）',
      (tester) async {
    await _pumpDash(tester, startOk: true);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SnackBar), findsNothing,
        reason: '成功路径弹提示 = 假失败提示；若本条判红说明 SLB-02 只在数 SnackBar，是恒真锁');
  });
}

// ══════════════════════════════════════════════════════════════════════════
// 源码文本锁判定器（顶层纯函数：输入剥过注释的源码，null=通过，非 null=具体缺失项）
// ══════════════════════════════════════════════════════════════════════════

/// [F2] 守卫采流异常的**订阅与生命周期**必须真的接上。
String? judgeGuardErrWiring(String src) {
  final i = src.indexOf('guardErrSub = guard.errors.listen');
  if (i < 0) return '锚点丢失：找不到 guard.errors 的订阅（W2-F2 被移除或改名）';
  final wired = src.substring((i - 120).clamp(0, src.length),
      (i + 200).clamp(0, src.length));
  if (!wired.contains('onGuardStreamError')) {
    return 'errors 流订阅没有接到 onGuardStreamError（错误又没人处理了）';
  }
  final cancels = 'guardErrSub?.cancel()'.allMatches(src).length;
  if (cancels < 2) {
    return 'guardErrSub?.cancel() 只出现 $cancels 次（<2）：守卫关闭与引擎停止两条路径'
        '至少各一处对称取消，否则换目标/停引擎后旧订阅泄漏';
  }
  if (!src.contains('guardErrSub = null')) {
    return '守卫关闭分支未把 guardErrSub 置空（与 guardSub 的生命周期不再同形）';
  }
  return null;
}

/// [F3] `onGuardStreamError` 必须回投原因 + 写 failed 审计 + 广播。
String? judgeOnGuardStreamError(String src) {
  final i = src.indexOf('Future<void> onGuardStreamError');
  if (i < 0) return '锚点丢失：onGuardStreamError 被删除';
  final body = src.substring(i, (i + 700).clamp(0, src.length));
  if (!body.contains('guardError =')) return '未把原因回投到 guardError（UI 拿不到"为什么"）';
  if (!body.contains('守卫已停止：采流异常')) return '回投文案缺失（UI 与审计必须同源）';
  if (!body.contains("status: 'failed'")) return '没有写 failed 审计（失败再次静默）';
  if (!body.contains('broadcast()')) return '写完审计没有广播（UI 停在上一帧）';
  return null;
}

/// [F4] `pushExactAlarms`：异常 → failed；回执 null → skipped。不得空 catch。
///
/// [P1-04 加强] 除 null/异常两态外，还必须**解析结构化结果**并把降级回投给 UI：
/// 旧实现把"权限被拒返回 `0`"当成普通成功，界面照常显示运行中，系统级唤醒却没排上。
String? judgePushExactAlarms(String src) {
  final i = src.indexOf('Future<void> pushExactAlarms');
  if (i < 0) return '锚点丢失：pushExactAlarms 被删除';
  final body = src.substring(i, (i + 1400).clamp(0, src.length));
  if (!body.contains("invokeMethod('setExactAlarms'")) {
    return '锚点丢失：setExactAlarms 调用不在函数体内';
  }
  if (!body.contains('if (n == null)')) {
    return '没有检查原生回执为 null 的分支（iOS/桌面未实现该通道 → 通道B失效但零痕迹）';
  }
  if (!body.contains("status: 'skipped'") ||
      !body.contains('进程被杀后不再补触发')) {
    return 'null 回执分支没有写 skipped 审计并说明后果';
  }
  if (!body.contains('AlarmScheduleResult.fromRaw') ||
      !body.contains('res.degraded')) {
    return '★ P1-04：没有解析结构化排布结果 —— 权限被拒/部分排布会被当成成功'
        '（界面显示运行中，系统级唤醒却没排上）';
  }
  if (!body.contains('alarmDiag =')) {
    return '★ P1-04：降级原因没有回投到 alarmDiag（UI 拿不到"为什么/怎么办"）';
  }
  if (!body.contains('on Object catch (e)') ||
      !body.contains("status: 'failed'") ||
      !body.contains('精确闹钟排布失败')) {
    return '异常分支没有写 failed 审计（空 catch = 排布失败零痕迹）';
  }
  return null;
}

/// [F5] `clearAllAlarms`：清理失败必须留痕（否则残留过期闹钟，到点还会唤醒一次）。
String? judgeClearAllAlarms(String src) {
  final i = src.indexOf('Future<void> clearAllAlarms');
  if (i < 0) return '锚点丢失：clearAllAlarms 被删除';
  final body = src.substring(i, (i + 700).clamp(0, src.length));
  if (!body.contains("invokeMethod('clearAlarms'")) {
    return '锚点丢失：clearAlarms 调用不在函数体内';
  }
  if (!body.contains('on Object catch (e)') || !body.contains("status: 'failed'")) {
    return '清理失败没有写 failed 审计（空 catch = 闹钟泄漏无迹可寻）';
  }
  if (!body.contains('残留过期闹钟')) {
    return '审计文案没有说明后果（"可能残留过期闹钟"是定位泄漏的唯一线索）';
  }
  return null;
}

/// [P1-03] `service.on('stop')` 必须**对称撤销**原生精确闹钟。
///
/// 旧实现停止时只取消 Dart 层守卫/播放器就 `stopSelf()`，`AlarmManager` 里
/// 排定的闹钟仍在 ⇒ 到点由 `AlarmWatchdogReceiver` 重新拉起前台服务并执行
/// 到期任务，用户以为"已关闭"、系统却再次运行（docs/50 §4.1 P1-03）。
/// 判定：`stop` 监听器体内、`stopSelf()` **之前**必须出现 `await clearAllAlarms();`。
String? judgeStopClearsAlarms(String src) {
  final i = src.indexOf("service.on('stop')");
  if (i < 0) return '锚点丢失：stop 通道被删除';
  final scope = src.substring(i, (i + 3200).clamp(0, src.length));
  final stopSelf = scope.indexOf('service.stopSelf()');
  if (stopSelf < 0) return '锚点丢失：stop 监听器里不再 stopSelf';
  if (!scope.substring(0, stopSelf).contains('await clearAllAlarms();')) {
    return '★ 停止时只停 Dart 层守卫/播放器、没有 clearAllAlarms() ⇒ '
        'AlarmManager 里排定的闹钟仍在，到点由看门狗重新拉起引擎并执行任务 —— '
        '用户以为"已关闭"，系统却再次运行（P1-03）';
  }
  return null;
}

/// [P2-15] 引擎 stop 必须**对称撤下**麦克风前台服务通行证。
///
/// `MicGuardService` 是独立 sticky service，Dashboard 关闭引擎走 `mgr.stop()`；
/// 若停止路径不调 `stopMicService()`，原生 FGS 与常驻通知会残留（dumpsys 可见），
/// 与"引擎已关"的界面语义不一致。判定：`stop` 监听器体内、`stopSelf()` 之前
/// 必须出现 `invokeMethod('stopMicService')`。
String? judgeStopStopsMicService(String src) {
  final i = src.indexOf("service.on('stop')");
  if (i < 0) return '锚点丢失：stop 通道被删除';
  final scope = src.substring(i, (i + 3200).clamp(0, src.length));
  final stopSelf = scope.indexOf('service.stopSelf()');
  if (stopSelf < 0) return '锚点丢失：stop 监听器里不再 stopSelf';
  if (!scope.substring(0, stopSelf).contains("invokeMethod('stopMicService')")) {
    return '★ 停止路径没有 stopMicService() ⇒ 引擎已关但麦克风前台服务与'
        '常驻通知残留，dumpsys 与界面不一致（P2-15）';
  }
  return null;
}

/// [P1-03] 看门狗接收器在拉起引擎前必须核对 `should_run` 与启用代次。
///
/// Dart 侧 `stop` 的 `clearAllAlarms()` 只能清掉**已知**闹钟；系统级残留 /
/// "关闭→重启"竞态仍可能送进一条旧闹钟广播。接收器是最后一道闸：只有
/// `should_run==true` 且闹钟携带的代次等于当前持久化代次时，才允许 `startForegroundService`。
String? judgeWatchdogGenerationGate(String src) {
  final i = src.indexOf('class AlarmWatchdogReceiver');
  if (i < 0) return '锚点丢失：AlarmWatchdogReceiver 被删除';
  final scope = src.substring(i, (i + 1600).clamp(0, src.length));
  if (!scope.contains('KEY_SHOULD_RUN')) {
    return '★ 接收器没有核对 should_run ⇒ 引擎已关闭时残留闹钟仍会拉起（P1-03）';
  }
  if (!scope.contains('EXTRA_GENERATION') || !scope.contains('KEY_GENERATION')) {
    return '★ 接收器没有核对启用代次 ⇒ "关闭→重启"竞态下旧闹钟会复活引擎（P1-03）';
  }
  return null;
}

/// [F6] runNow 缺 taskId：必须写 failed 审计并立即回投 ok:false + 原因。
String? judgeRunNowMissingTaskId(String src) {
  final i = src.indexOf('if (taskId == null || taskId.isEmpty)');
  if (i < 0) return '锚点丢失：runNow 的缺参判定被删除';
  final body = src.substring(i, (i + 900).clamp(0, src.length));
  if (!body.contains("status: 'failed'")) return '缺参分支没有写 failed 审计';
  if (!body.contains("invoke('rcRunResult'")) {
    return '缺参分支没有回投 rcRunResult（发送端只能干等到超时）';
  }
  if (!body.contains("'ok': false")) return '回执没有明确 ok:false（等于假装执行了）';
  if (!body.contains('缺少 taskId')) return '回执没有说明真实原因（"缺少 taskId"）';
  if (!body.contains('return;')) return '缺参分支必须终止执行（防继续跑空任务）';
  return null;
}

/// [F7] runNow 的 catch：异常除了回投，还必须落本机审计。
String? judgeRunNowCatchAudit(String src) {
  final i = src.indexOf("service.on('runNow')");
  if (i < 0) return '锚点丢失：runNow 通道被删除';
  final scope = src.substring(i, (i + 4200).clamp(0, src.length));
  final c = scope.indexOf('on Object catch (e)');
  if (c < 0) return 'runNow 没有 catch 块（异常会直接炸掉监听器）';
  final cbody = scope.substring(c, (c + 700).clamp(0, scope.length));
  if (!cbody.contains('logs.append') || !cbody.contains("status: 'failed'")) {
    return 'catch 块只回投不落本机审计（"远程点了一下没反应"事后查无痕迹）';
  }
  if (!cbody.contains('远程立即执行异常')) return '审计文案没有带上异常上下文';
  return null;
}

/// [F8] 取证哈希：算不出来必须如实说"未生成"，承诺了才说"含完整性哈希"。
String? judgeEvidenceHashHonesty(String src) {
  final i = src.indexOf("var sha256Hex = ''");
  if (i < 0) return '锚点丢失：取证哈希变量被删除';
  final body = src.substring(i, (i + 1600).clamp(0, src.length));
  if (!body.contains('sha256Hex.isEmpty')) return '没有按"哈希是否为空"分支（空哈希被当作正常值写进审计）';
  if (!body.contains('（文件不可读，未生成完整性哈希）')) {
    return '审计文案没有在哈希为空时如实说明（只留 sha256= 会被读成"算出来了只是空"）';
  }
  if (!body.contains('完整性哈希未生成')) {
    return '通知文案没有在哈希为空时改口（仍在承诺"含完整性哈希" = 假承诺，BUG-056 同族）';
  }
  if (!body.contains('含完整性哈希')) return '正常分支的通知丢失了哈希承诺文案';
  if (!body.contains("status: 'success'")) {
    return '录音成功时状态仍必须是 success（本修复只纠正"没做到的部分"，不得把成功改报失败）';
  }
  return null;
}

/// [F10] `_openEditor`：未选端点时必须提示，不得静默 return。
String? judgeOpenEditorSnack(String src) {
  final i = src.indexOf('Future<void> _openEditor');
  if (i < 0) return '锚点丢失：_openEditor 被删除';
  final body = src.substring(i, (i + 900).clamp(0, src.length));
  if (!body.contains('if (ep == null)')) return '没有"未选端点"的前置判定';
  if (!body.contains("_snack('请先选择端点')")) {
    return '★ W2-F10 之前该分支静默 return：点「新建/编辑」毫无反应（失败不可见）';
  }
  return null;
}

/// [N-3 / F-3] 自恢复路径的 `catch` **不得静默**：拉起引擎失败时，
/// 除 logcat 外必须经 `SelfHealNotice.failed(...)` 留一条用户可见痕迹。
///
/// 适用两个文件（形状同构，故共用一个判定器）：
/// - `packages/native_bridge/.../AlarmWatchdogReceiver.kt`（N-3 看门狗闹钟）
///   → 锚点是 `startForegroundService`（它自己直接拉起前台服务）。
/// - `android/app/src/main/kotlin/.../BootReceiver.kt`（F-3 开机自启）
///   → 锚点是 `setExactAndAllowWhileIdle`：方案① 已把开机自启从"直接
///   startForegroundService"改成"排一次性精确闹钟，复用看门狗接收器"，
///   故启动符号随之改变（[anchor] 参数化）。
String? judgeSelfHealNotSilent(String src,
    {String anchor = 'startForegroundService'}) {
  final i = src.indexOf(anchor);
  if (i < 0) {
    return '锚点丢失：不再有 $anchor —— 自恢复路径被删除或改名，'
        '本锁会因此空转';
  }
  final c = src.indexOf('catch (e: Exception)', i);
  if (c < 0) {
    return '锚点丢失：启动调用（$anchor）之后找不到 `catch (e: Exception)`。'
        '若异常不再被捕获，接收器会直接崩（比静默更糟）';
  }
  final body = src.substring(c, (c + 600).clamp(0, src.length));
  if (!body.contains('SelfHealNotice.failed(')) {
    return '★ 该 catch 只写 logcat（用户与审计完全看不见）—— 这正是 N-3 / F-3 '
        '的静默形状：平台拒绝拉起前台服务时，用户永远不知道"开机自恢复/闹钟自愈"没生效';
  }
  if (!body.contains('Log.w(')) {
    return 'catch 里丢了 logcat 留痕（开发者排查线索也没了）；'
        '通知在 Android 13+ 可能被用户拒绝而静默丢弃，两条留痕缺一不可';
  }
  return null;
}

/// [P2-33] 精确闹钟权限**重新授予**后的自动重排接收器必须成立且不滥用 FGS。
///
/// 用户在系统设置里撤销「闹钟和提醒」授权时，系统会取消该应用所有未来精确闹钟；
/// 再次授予后已排闹钟**不会自动恢复** —— 引擎若仍在跑就长期处于"计划看着有、
/// 系统级唤醒为空集"的降级态。旧实现没有处理
/// `ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`。
///
/// ⚠️ 本锁只保证**代码形状**；`撤销 → 重授予 → 不手动重开即恢复排布` 的
/// 真实行为**只能靠 API 31+ 设备验证**（宿主门禁不构建 Android ⇒ BLOCKED）。
String? judgeExactRegrantReceiver(String kotlin, String manifest) {
  final i = kotlin.indexOf('class ExactAlarmPermissionReceiver');
  if (i < 0) return '锚点丢失：ExactAlarmPermissionReceiver 被删除';
  final scope = kotlin.substring(i);
  if (!scope.contains('ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED')) {
    return '未按权限恢复 action 过滤（系统仅在授予时派发该 action）';
  }
  if (!scope.contains('KEY_SHOULD_RUN')) {
    return '★ 未核对 should_run ⇒ 用户关着引擎时，一次系统级重授权也会拉起前台服务（P1-03 同族）';
  }
  if (!scope.contains('EXTRA_GENERATION') || !scope.contains('KEY_GENERATION')) {
    return '★ 未携带当前持久化代次 ⇒ 看门狗会把它当旧代次闹钟 no-op，重排静默失效';
  }
  if (!scope.contains('AlarmWatchdogReceiver')) {
    return '未复用看门狗一次性闹钟踢醒（Android 12+ 后台直接 startForegroundService 会被拒）';
  }
  if (!scope.contains('SelfHealNotice.failed(')) {
    return '★ 排程失败只写 logcat ⇒ 用户与审计看不见（N-3 / F-3 同族静默）';
  }
  if (!manifest.contains('ExactAlarmPermissionReceiver')) {
    return '★ 清单未注册接收器 ⇒ 系统广播永远送不进来，重授权自动重排形同不存在';
  }
  if (!manifest.contains('SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED')) {
    return '★ 清单未声明该 action 的 intent-filter ⇒ 接收器收不到广播';
  }
  return null;
}

/// [P2-16] `device.alert` 原生实现必须"全屏降级可见、音频副作用可还原"。
///
/// 旧实现把媒体音量顶到最大后**从不还原**，也从不申请/释放音频焦点；且无论
/// API 34+ 是否允许都硬塞 `setFullScreenIntent` —— 系统不兑现时只剩一条普通通知，
/// 用户却以为"设备找回"已全屏。本锁核对三件事：
/// 1. 全屏 intent 必须过 `canUseFullScreenIntent(ctx)` 闸门（不满足时退回高优先级横幅）；
/// 2. 必须**申请**音频焦点（否则打断别人播放却不受焦点规则协调）；
/// 3. 必须**释放**焦点并还原原音量（否则"临时最大音量"变成永久副作用）。
///
/// ⚠️ 只锁**代码形状**；`API 34+ 拒绝全屏、无媒体播放时提示音与音量还原`的真实
/// 行为只能靠真机验证（宿主门禁不构建 Android ⇒ BLOCKED）。
String? judgeDeviceAlertDegrade(String kotlin) {
  final i = kotlin.indexOf('private fun deviceAlert(');
  if (i < 0) return '锚点丢失：deviceAlert 被删除';
  final end = kotlin.indexOf('private fun canUseFullScreenIntent', i);
  final body = end > i ? kotlin.substring(i, end) : kotlin.substring(i);
  if (!body.contains('setFullScreenIntent(')) {
    return '锚点丢失：deviceAlert 里找不到 setFullScreenIntent 调用';
  }
  if (!body.contains('canUseFullScreenIntent(ctx)')) {
    return '★ setFullScreenIntent 未过 canUseFullScreenIntent 闸门 ⇒ API 34+ '
        '系统不兑现时仍宣称全屏，用户以为已生效（P2-16 旧缺陷）';
  }
  if (!body.contains('requestAudioFocus(')) {
    return '★ 未申请音频焦点 ⇒ 打断用户正在播放的音频却不受焦点规则协调（P2-16）';
  }
  if (!body.contains('abandonAudioFocus(')) {
    return '★ 申请了焦点却从不释放 ⇒ 其它应用无法按焦点规则恢复播放（P2-16）';
  }
  if (!body.contains('origMusicVolume') || !body.contains('setStreamVolume(')) {
    return '★ 把媒体音量顶到最大后未还原 ⇒ 用户音量被永久改动（P2-16 旧缺陷）';
  }
  return null;
}

/// [N-3 / F-3 落点] `SelfHealNotice.failed` 必须**真的发通知**，
/// 否则它只是把静默换了个位置。
String? judgeSelfHealNoticeReal(String src) {
  final i = src.indexOf('fun failed(');
  if (i < 0) return '锚点丢失：SelfHealNotice.failed 被删除';
  final body = src.substring(i, (i + 1600).clamp(0, src.length));
  if (!body.contains('nm.notify(')) {
    return '★ SelfHealNotice 没有真的发通知（又变成静默留痕）';
  }
  if (!body.contains('NotificationChannel(')) {
    return 'API 26+ 未创建通知渠道 ⇒ 系统会静默丢弃该通知'
        '（渠道不存在时 NotificationCompat 发布无效）';
  }
  if (!body.contains('catch (e: Exception)')) {
    return '通知路径没有自己的 catch：从 BroadcastReceiver 里抛异常会崩进程';
  }
  return null;
}

// ══════════════════════════════════════════════════════════════════════════
// 源码锁本体 + 非恒真证明（反面样本必须判红）
// ══════════════════════════════════════════════════════════════════════════

void _sourceLocks(String engineSrc, String tasksSrc, String watchdogKt,
    String bootKt, String selfHealKt, String exactGrantKt, String pluginManifest,
    String nativePluginKt) {
  group('SLS 源码文本锁（引擎隔离 / 结构不可达处）', () {
    test('SLS-01 [F2] guard.errors 订阅接线与生命周期对称取消', () {
      final v = judgeGuardErrWiring(engineSrc);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-02 [F3] onGuardStreamError：回投原因 + failed 审计 + 广播', () {
      final v = judgeOnGuardStreamError(engineSrc);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-03 [F4] pushExactAlarms：异常 → failed，回执 null → skipped', () {
      final v = judgePushExactAlarms(engineSrc);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-04 [F5] clearAllAlarms：清理失败留痕并说明"残留过期闹钟"', () {
      final v = judgeClearAllAlarms(engineSrc);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-05 [F6] runNow 缺 taskId：failed 审计 + 立即回投 ok:false/缺少 taskId', () {
      final v = judgeRunNowMissingTaskId(engineSrc);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-06 [F7] runNow 异常：回投之外还落本机 failed 审计', () {
      final v = judgeRunNowCatchAudit(engineSrc);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-07 [F8] 取证哈希为空 → 审计与通知都如实说"未生成"', () {
      final v = judgeEvidenceHashHonesty(engineSrc);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-08 [F10] _openEditor 未选端点 → _snack(\'请先选择端点\')', () {
      final v = judgeOpenEditorSnack(tasksSrc);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-09 [N-3] AlarmWatchdogReceiver 拉起失败 → SelfHealNotice 留痕', () {
      final v = judgeSelfHealNotSilent(watchdogKt);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-10 [F-3] BootReceiver 开机自启排程失败 → SelfHealNotice 留痕', () {
      final v = judgeSelfHealNotSilent(bootKt, anchor: 'setExactAndAllowWhileIdle');
      expect(v, isNull, reason: '$v');
    });

    test('SLS-11 [N-3/F-3] SelfHealNotice 必须真的发通知（不是换个地方静默）', () {
      final v = judgeSelfHealNoticeReal(selfHealKt);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-12 [P1-03] 引擎 stop 必须对称撤销原生精确闹钟', () {
      final v = judgeStopClearsAlarms(engineSrc);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-13 [P1-03] 看门狗接收器拉起前必须核对 should_run 与启用代次', () {
      final v = judgeWatchdogGenerationGate(watchdogKt);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-14 [P2-15] 引擎 stop 必须对称撤下麦克风前台服务通行证', () {
      final v = judgeStopStopsMicService(engineSrc);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-15 [P2-33] 精确闹钟重授权接收器：核对 should_run/代次 + 清单注册', () {
      final v = judgeExactRegrantReceiver(exactGrantKt, pluginManifest);
      expect(v, isNull, reason: '$v');
    });

    test('SLS-16 [P2-16] device.alert 原生：全屏过闸门 + 音频焦点申请/释放 + 音量还原', () {
      final v = judgeDeviceAlertDegrade(nativePluginKt);
      expect(v, isNull, reason: '$v');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // 非恒真证明：每条判定器喂一段"坏代码"样本，必须判红。
  // 若下面任何一条判绿，说明对应检测器恒真 —— 那一组锁全是假的。
  // ══════════════════════════════════════════════════════════════════════
  group('SLX-90 检测器有效性（反面样本必须判红）', () {
    test('SLX-90a [F2] 只订 events 不订 errors（W2 前旧形状）→ 判红', () {
      const old = '''
        guardSub = guard.events.listen((e) => unawaited(onSoundEvent(e.detectedAt, e.peakDb)));
''';
      expect(judgeGuardErrWiring(old), isNotNull,
          reason: '★ 检测器对"无 errors 订阅"判绿 = 恒真，整组锁是假的');
    });

    test('SLX-90b [F2] 订了 errors 但从不取消（订阅泄漏）→ 判红', () {
      const leak = '''
        guardErrSub = guard.errors.listen((e) { unawaited(onGuardStreamError(e)); });
''';
      expect(judgeGuardErrWiring(leak), isNotNull,
          reason: '★ 只锁"有订阅"不锁"有取消" = 半截锁');
    });

    test('SLX-90c [F3] 只回投不写审计 → 判红', () {
      const partial = '''
        Future<void> onGuardStreamError(Object e) async {
          guardError = '守卫已停止：采流异常（\$e）';
        }
''';
      expect(judgeOnGuardStreamError(partial), isNotNull,
          reason: '★ UI 有原因但审计无痕 = 事后排查依然瞎');
    });

    test('SLX-90d [F4] 旧空 catch + 不看回执 → 判红', () {
      const old = '''
        Future<void> pushExactAlarms(List<int> times) async {
          try {
            await native.invokeMethod('setExactAlarms', {'times': times});
          } on Object {
          }
        }
''';
      expect(judgePushExactAlarms(old), isNotNull,
          reason: '★ W2-F4 修复前的形状必须被判红，否则锁对真实回归无效');
    });

    test('SLX-90e [F5] 清理失败吞掉（旧空 catch）→ 判红', () {
      const old = '''
        Future<void> clearAllAlarms() async {
          try {
            await native.invokeMethod('clearAlarms');
          } on Object {
          }
        }
''';
      expect(judgeClearAllAlarms(old), isNotNull,
          reason: '★ 空 catch 必须被判红');
    });

    test('SLX-90f [F6] 缺参直接 return（W2 前旧形状）→ 判红', () {
      const old = '''
        if (taskId == null || taskId.isEmpty) {
          return;
        }
''';
      expect(judgeRunNowMissingTaskId(old), isNotNull,
          reason: '★ 静默 return 必须判红：发送端只会看到"超时"，真实原因丢失');
    });

    test('SLX-90g [F7] catch 只回投不落审计（W2 前旧形状）→ 判红', () {
      const old = '''
        service.on('runNow').listen((m) async {
        } );
        void other() {
          on Object catch (e) {
            message = e.toString();
          }
        }
''';
      expect(judgeRunNowCatchAudit(old), isNotNull,
          reason: '★ 只改回执不补审计的"半修复"必须判红');
    });

    test('SLX-90h [F8] 无条件"含完整性哈希"（W2 前旧形状）→ 判红', () {
      const old = '''
        await logs.append(
            source: source,
            action: 'record',
            status: 'success',
            message: 'sha256=\$sha256Hex path=\$path');
        await NotificationService.instance.showEvent(
          title: '声盾 · 取证完成',
          body: '已保存到应用私有目录（含完整性哈希）',
        );
''';
      expect(judgeEvidenceHashHonesty(old), isNotNull,
          reason: '★ P0 修复前的假承诺必须被判红');
    });

    test('SLX-90i [F10] 未选端点静默 return（W2 前旧形状）→ 判红', () {
      const old = '''
        Future<void> _openEditor({Map<String, dynamic>? wire}) async {
          final ep = _endpoint;
          if (ep == null) return;
        }
''';
      expect(judgeOpenEditorSnack(old), isNotNull,
          reason: '★ 静默 return 必须判红：点了按钮界面毫无变化');
    });

    test('SLX-90j [N-3] 看门狗只写 logcat（修复前旧形状）→ 判红', () {
      const old = '''
        try {
            val svc = Intent()
                .setClassName(context, "id.flutter.flutter_background_service.BackgroundService")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(svc)
            } else {
                context.startService(svc)
            }
        } catch (e: Exception) {
            Log.w("AlarmWatchdog", "kick failed: \${e.message}")
        }
''';
      expect(judgeSelfHealNotSilent(old), isNotNull,
          reason: '★ N-3 修复前的形状必须被判红（且必须是"静默 catch"这条判红，'
              '不是"锚点丢失"）—— 否则锁对真实回归无效');
    });

    test('SLX-90k [F-3] 开机自启排程只写 logcat（方案① 前的静默形状）→ 判红', () {
      const old = '''
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val at = System.currentTimeMillis() + 10_000L
            val pi = PendingIntent.getBroadcast(context, 0x0B07, intent, flags)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } else {
                am.setExact(AlarmManager.RTC_WAKEUP, at, pi)
            }
        } catch (e: Exception) {
            Log.w(TAG, "boot kick blocked: \${e.message}")
        }
''';
      expect(
          judgeSelfHealNotSilent(old, anchor: 'setExactAndAllowWhileIdle'), isNotNull,
          reason: '★ F-3 方案① 若只搬了机制（startForegroundService → 精确闹钟）'
              '却把 catch 又写成静默，锁必须判红 —— 否则"换了个地方静默"'
              '会被当成已修复');
    });

    test('SLX-90l [N-3/F-3] 只 Log.w 的 SelfHealNotice 空壳 → 判红', () {
      const stub = '''
        object SelfHealNotice {
            fun failed(context: Context, reason: String) {
                Log.w(TAG, "self-heal blocked: \$reason")
            }
        }
''';
      expect(judgeSelfHealNoticeReal(stub), isNotNull,
          reason: '★ 把静默换个函数名不算修复：必须真的发通知，否则锁是假的');
    });

    test('SLX-90m [P1-03] stop 只停守卫/播放器、不清理闹钟（旧形状）→ 判红', () {
      const old = '''
        service.on('stop').listen((_) async {
          await guard.stop();
          await playback.stop();
          await broadcast(running: false);
          await service.stopSelf();
        });
''';
      expect(judgeStopClearsAlarms(old), isNotNull,
          reason: '★ 停止不清闹钟的旧形状必须判红 —— 否则"引擎关不掉"回归无人拦');
    });

    test('SLX-90n [P1-03] 接收器无 should_run/代次校验（旧形状）→ 判红', () {
      const old = '''
        class AlarmWatchdogReceiver : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                context.startForegroundService(svc)
            }
        }
''';
      expect(judgeWatchdogGenerationGate(old), isNotNull,
          reason: '★ 无闸门校验的旧形状必须判红，否则残留闹钟复活引擎无人拦');
    });

    test('SLX-90o [P1-04] 只看 null/异常、把 0 当成功（旧形状）→ 判红', () {
      const old = '''
        Future<void> pushExactAlarms(List<int> times) async {
          try {
            final n = await native.invokeMethod('setExactAlarms', {'times': times});
            if (n == null) {
              await logs.append(status: 'skipped', message: '进程被杀后不再补触发（仅通道A生效）');
            }
          } on Object catch (e) {
            await logs.append(status: 'failed', message: '精确闹钟排布失败（仅通道A生效）：\$e');
          }
        }
''';
      expect(judgePushExactAlarms(old), isNotNull,
          reason: '★ P1-04 修复前的形状必须被判红：权限被拒返回 0 会被当成成功，'
              '否则"精确闹钟没排上却显示运行中"回归无人拦');
    });

    test('SLX-90p [P2-15] stop 清了闹钟但没撤麦克风 FGS（半修复）→ 判红', () {
      const old = '''
        service.on('stop').listen((_) async {
          await guard.stop();
          await playback.stop();
          await clearAllAlarms();
          await broadcast(running: false);
          await service.stopSelf();
        });
''';
      expect(judgeStopStopsMicService(old), isNotNull,
          reason: '★ 只清闹钟不撤麦克风通行证 = 原生 FGS/通知残留，锁必须判红');
    });

    test('SLX-90q [P2-33] 重授权接收器无闸门 / 清单未注册 → 判红', () {
      // (a) 直接拉起前台服务、不核对 should_run/代次（旧形状）。
      const noGate = '''
        class ExactAlarmPermissionReceiver : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED) return
                context.startForegroundService(Intent(context, Svc::class.java))
            }
        }
''';
      expect(judgeExactRegrantReceiver(noGate, ''), isNotNull,
          reason: '★ 无闸门的旧形状必须判红，否则"用户关着引擎却被重授权拉起"无人拦');
      // (b) Kotlin 齐全但清单未注册 ⇒ 广播送不进来（证明清单检查非恒真）。
      const goodKt = '''
        class ExactAlarmPermissionReceiver : BroadcastReceiver() {
            KEY_SHOULD_RUN
            EXTRA_GENERATION KEY_GENERATION
            AlarmWatchdogReceiver
            SelfHealNotice.failed(ctx, "x")
            ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED
        }
''';
      expect(judgeExactRegrantReceiver(goodKt, ''), isNotNull,
          reason: '★ 清单未注册时判绿 = 清单检查恒真，锁是假的');
    });

    test('SLX-90r [P2-16] 旧 deviceAlert：全屏不过闸门 / 无音频焦点 / 不还原音量 → 判红',
        () {
      // (a) 旧形状：硬塞全屏 intent，音量顶最大后不还原，也不碰音频焦点。
      const old = '''
        private fun deviceAlert(ctx: Context, message: String): Boolean {
            val b = Notification.Builder(ctx, "ch")
            if (pi != null) b.setFullScreenIntent(pi, true)
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.setStreamVolume(AudioManager.STREAM_MUSIC,
                am.getStreamMaxVolume(AudioManager.STREAM_MUSIC), 0)
            return true
        }
''';
      expect(judgeDeviceAlertDegrade(old), isNotNull,
          reason: '★ P2-16 修复前的形状必须判红：全屏不受闸门、音量被永久改动、'
              '打断他人播放却不受焦点规则协调');

      // (b) 半修复：全屏过了闸门，也申请/释放了焦点，却仍不还原音量。
      //     证明"音量还原"这条判定不是恒真（否则会漏掉真实的音量副作用回归）。
      const noRestore = '''
        private fun deviceAlert(ctx: Context, message: String): Boolean {
            if (pi != null && canUseFullScreenIntent(ctx)) b.setFullScreenIntent(pi, true)
            am.requestAudioFocus(null, AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            am.abandonAudioFocus(null)
            return true
        }
''';
      expect(judgeDeviceAlertDegrade(noRestore), isNotNull,
          reason: '★ 申请了焦点却不还原音量必须判红，否则"音量还原"检查恒真');
    });
  });
}

/// 假录音器（形状照抄 `sound_guard_lifecycle_test.dart` 的 _FakeRecorder）。
class _FakeRecorder implements AudioRecorder {
  final _chunks = StreamController<Uint8List>.broadcast();

  /// 采流句柄：测试用它向"守卫正在读的流"注入错误。
  StreamController<Uint8List> get chunks => _chunks;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async =>
      _chunks.stream;

  @override
  Future<bool> isRecording() async => true;

  @override
  Future<String?> stop() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
