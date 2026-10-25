import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_background_service/flutter_background_service.dart';

import '../core/constants.dart';
import '../domain/models/action.dart';
import 'background_engine.dart';
import 'native_bridge.dart';
import 'permission_flow.dart';
import 'power_service.dart';

/// UI 侧对后台服务的封装：启动/停止、开关守卫、订阅引擎状态。
class BackgroundServiceManager {
  BackgroundServiceManager._();

  static final BackgroundServiceManager instance = BackgroundServiceManager._();

  final FlutterBackgroundService _svc = FlutterBackgroundService();

  final _stateCtrl = StreamController<EngineState>.broadcast();
  // 测试缝：注入 state 流以驱动 `engineStateProvider` 的 data/error 分支；
  // 生产代码不设置，走真实 `_stateCtrl.stream`。
  static Stream<EngineState>? _stateOverride;
  @visibleForTesting
  static set stateForTest(Stream<EngineState>? s) => _stateOverride = s;
  Stream<EngineState> get state => _stateOverride ?? _stateCtrl.stream;
  EngineState? _last;
  EngineState? get last => _last;

  /// `init()` 失败的原因（成功时为 null）。
  ///
  /// 🔴 R89：`main.dart` 对 `init()` 做了降级 try/catch（避免白屏，BUG-108 同源
  /// 纪律），但降级后**没有任何人知道后台服务其实没配好** —— 此时
  /// `startService()` 必然无效或抛错，而 UI 只看到「开关弹回、零提示」，
  /// 用户完全无从判断是权限、电池优化还是服务本身坏了。
  /// 这里把原因留住，由守护页开关失败时原样转达。
  String? _initError;
  String? get initError => _initError;

  /// 最近一次 [start] 失败的真实原因（成功时清空）。
  ///
  /// 与 [guardError] 同源纪律：**要失败，但不要静默失败**。
  /// 旧实现 `start()` 只回 `bool`，而 `_svc.startService()` 在原生侧拒绝
  /// （Android 14+ 前台服务类型限制 / 厂商后台限制）时**抛 `PlatformException`**，
  /// 异常一路穿透到 `onChanged` 的 async 闭包 → 变成未捕获异步错误：
  /// 开关弹回、零提示，用户感知就是「点了完全没反应」。
  String? _startError;
  String? get startError => _startError;
  // 测试缝：注入 `last` 以驱动依赖它的 UI（下一触发倒计时 / 守卫态渲染）；
  // 生产代码不设置，走真实 `_last`。
  @visibleForTesting
  static set lastForTest(EngineState? s) => instance._last = s;

  /// 远程「立即执行」的待决请求（reqId → 完成器）。
  ///
  /// 引擎隔离内执行完毕后经 `rcRunResult` 回投；端点服务 await 该 Future
  /// 后才回 `rc.ack`，避免"回执成功但实际没出声"（docs/14 §2.1）。
  final _pendingRun = <String, Completer<RunNowResult>>{};
  var _runSeq = 0;

  Future<void> init() async {
    try {
      await _initInner();
      _initError = null;
    } on Object catch (e) {
      // 记住原因（守护页开关失败时原样转达），再交回 `main.dart` 的降级
      // catch —— 它只 print、不阻断 runApp（远程/后台两处同纪律）。
      _initError = '$e';
      rethrow;
    }
  }

  /// [init] 的实际装配体（异常由 [init] 统一收口成 [initError]）。
  Future<void> _initInner() async {
    await _svc.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: engineEntryPoint,
        isForegroundMode: true,
        autoStart: false, // 由用户在首页显式开启（合规与功耗友好）
        // autoStartOnBoot 在插件里的**默认值是 true**（platform_interface 5.1.2
        // configs.dart:73），它会让插件自带的 id.flutter.background_service.BootReceiver
        // 在 BOOT_COMPLETED 上**直接** startForegroundService(mediaPlayback)——而
        // Android 15+（targetSdk 35+）明确禁止从 BOOT_COMPLETED 启动 mediaPlayback 型
        // FGS ⇒ 进程在开机时被 ForegroundServiceStartNotAllowedException 打死、
        // 反复重启并弹崩溃对话框（API 36 模拟器实测复现，见 docs/05）。
        // 开机恢复改由本工程自己的 BootReceiver 排一次性精确闹钟（豁免路径）完成，
        // 故此处必须显式关掉插件的开机自启。
        autoStartOnBoot: false,
        notificationChannelId: NotificationChannels.service,
        initialNotificationTitle: '声盾 SonicShield',
        initialNotificationContent: '调度引擎运行中',
        foregroundServiceNotificationId: 0x521ED,
        // 不含 microphone：Android 14+ while-in-use 限制下，后台复活的
        // 服务携带 microphone 类型会被拒绝。麦克风访问由本地插件的
        // MicGuardService 在用户前台交互时独立持有（docs/05 §1.4）。
        //
        // 不含 dataSync（F-2，SEC1 第 35 轮）：Android 15+ 对 dataSync 型
        // 前台服务有「24 小时内累计 6 小时」上限，到点系统回调
        // Service.onTimeout；而插件 flutter_background_service_android 6.3.1
        // 的 BackgroundService.java **全文件 0 处 onTimeout**（Config.java:81
        // 只读本处写下的类型位，不与清单求并；BackgroundService.java:169-173
        // 把它算成 startForeground 的 type 位）⇒ 到点即抛
        // android.app.RemoteServiceException 杀进程（Fatal）。本引擎是
        // 7×24 常驻 ⇒ 必然命中。mediaPlayback **不在**该上限清单内，且本工程
        // 后台确为「本地调度 + 定时播放」，语义成立。
        foregroundServiceTypes: const [
          AndroidForegroundType.mediaPlayback,
        ],
      ),
      iosConfiguration: IosConfiguration(
        onForeground: engineEntryPoint,
        onBackground: (ServiceInstance s) async => true, // iOS 后台无 UI 隔离
        autoStart: false,
      ),
    );
    _svc.on('state').listen((m) {
      final data = m ?? <String, Object?>{};
      _last = EngineState(
        running: data['running'] as bool? ?? false,
        pendingCount: (data['pendingCount'] as num?)?.toInt() ?? 0,
        nextFireAt: data['nextFireAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(data['nextFireAt'] as int),
        lastAction: data['lastAction'] as String?,
        guardActive: data['guardActive'] as bool? ?? false,
        guardError: data['guardError'] as String?,
        alarmDiag: data['alarmDiag'] as String?,
      );
      _stateCtrl.add(_last!);
    });
    _svc.on('rcRunResult').listen((m) {
      final reqId = (m ?? <String, Object?>{})['reqId'] as String? ?? '';
      final c = _pendingRun.remove(reqId);
      if (c == null || c.isCompleted) return;
      c.complete(RunNowResult(
        ok: (m!['ok'] as bool?) ?? false,
        message: (m['message'] as String?) ?? '',
      ));
    });
  }

  Future<bool> start() async {
    final hook = startHook;
    if (hook != null) return hook();
    // P1-02 服务边界准入：合规同意是引擎启动的**唯一准入层**，任何调用方
    //（不只首页开关）都不得绕过。未同意 → 拒绝启动（返回 false，调用方提示）。
    if (!await isComplianceAccepted()) {
      _startError = '未同意《合规使用须知》';
      return false;
    }
    // R89：初始化失败的引擎**不可能**起来。旧实现在这里继续调
    // `startService()`，原生侧要么无回执（永久挂起）要么抛错，两者都
    // 只表现为「开关弹回、零提示」。直接给出可行动的原因。
    final initErr = _initError;
    if (initErr != null) {
      _startError = '后台服务未初始化：$initErr';
      return false;
    }
    final call = startServiceHook ?? _svc.startService;
    try {
      // 🔴 R89：**必须带超时**。`startService()` 是 MethodChannel 调用，
      // 原生侧若因前台服务被拒（Android 14+ 类型限制 / 厂商后台限制）而不
      // 回执，`await` 会**永久挂起** —— 用户看到的是「点了完全没反应」，
      // 连失败提示都出不来（不是异常，是永远不返回）。
      final ok = await call().timeout(startServiceTimeout);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (ok) {
        _startError = null;
      } else {
        _startError = '前台服务未接受启动请求（startService 返回 false）';
      }
      return ok;
    } on TimeoutException {
      _startError = '前台服务 12 秒无回执（可能被系统或厂商后台策略拦截）';
      return false;
    } on Object catch (e) {
      // 原生侧明确拒绝（如 ForegroundServiceStartNotAllowedException）会以
      // PlatformException 形式抛出 —— 原样转达，不再让它穿透成未捕获异步
      // 错误（那正是「开关弹回 + 零提示」的形状，与 BUG-061 同源）。
      _startError = '前台服务启动被拒：$e';
      return false;
    }
  }

  /// 测试缝：替换真实的 `_svc.startService()`（只用于验证 [start] 的失败分类）。
  ///
  /// 与 [startHook] 的区别：[startHook] 短路**整个** `start()`（现有 widget
  /// 测试用），本钩子只替换最内层平台调用，于是「超时 / 抛异常 / 返回 false」
  /// 三条失败路径都能在宿主里真实触发并断言。
  @visibleForTesting
  static Future<bool> Function()? startServiceHook;

  /// 启动等待窗口（生产 12 秒）。测试置短值即可真实触发超时分支，
  /// 不必真等 12 秒。
  @visibleForTesting
  static Duration startServiceTimeout = const Duration(seconds: 12);

  /// 测试缝：注入 / 清除 [initError]。
  ///
  /// 宿主测试里 `init()` **必然失败**（`_svc.configure()` 在非 Android/iOS
  /// 直接抛 `UnsupportedError`），所以无法用它制造"初始化成功"或"指定原因"
  /// 的状态，只能直接注入。
  @visibleForTesting
  static set initErrorForTest(String? v) => instance._initError = v;

  /// 测试缝：注入 / 清除 [startError]（单例跨用例复用，必须显式复位）。
  @visibleForTesting
  static set startErrorForTest(String? v) => instance._startError = v;

  /// 测试缝（与 [invokeHook] 同形）：widget 测试中 `_svc.startService()` 会
  /// 触碰 `FlutterBackgroundService` 平台实例，非 Android/iOS 直接抛
  /// `UnsupportedError`。测试注入本钩子短路；生产代码不设置，走真实启动。
  @visibleForTesting
  static Future<bool> Function()? startHook;

  /// 关闭引擎。
  ///
  /// 🔴 R89：旧实现就是一句 `_invoke('stop')`（fire-and-forget）。引擎**还活着**
  /// 时它会回投 `running:false`（BUG-B 已修），但引擎**已经死了**的时候
  /// （被系统杀 / 崩溃 / 厂商后台清理）——`invoke` 发向一个不存在的服务，
  /// 没有任何人回投，而 `_last` 是主 isolate 里的静态缓存 ⇒ 开关永远卡在
  /// 「守护已开启」，用户再点也关不掉，感知就是「点了没反应」。
  ///
  /// 停止方向一律走**安全侧**：`invoke` 之后**立即**本地置 `running:false`。
  ///
  /// 为什么不等引擎确认再改：`state` 流在测试里可能被注入成**单订阅流**
  /// （`Stream.value`），二次 `listen` 会抛 `Bad state: Stream has already been
  /// listened to`；而且等待窗口在 widget 测试里会留下 pending timer。
  /// 乐观更新是安全的 —— 引擎若还活着，它收到 `stop` 后回投的
  /// `running:false` 会经 `_svc.on('state')` **覆盖**这里的兜底值（含真实
  /// `pendingCount`），两者方向一致，不存在"UI 说关了、引擎还在跑"的持久分叉。
  Future<void> stop() async {
    await _invoke('stop');
    // 本来就没在跑：没有陈旧状态需要纠正，保持原样（含 pendingCount /
    // nextFireAt —— 它们对"已关闭"的页面仍有参考价值）。
    if (_last?.running != true) return;
    final prev = _last;
    _last = EngineState(
      running: false,
      pendingCount: prev?.pendingCount ?? 0,
      // 引擎已停 ⇒ 下一触发与闹钟降级诊断都不再成立，一并清掉；
      // 留着会让首页继续显示一个不存在的倒计时。
      nextFireAt: null,
      lastAction: prev?.lastAction,
      // 引擎已停 ⇒ 守卫必然不在跑（引擎侧 `stop` 会 `guard.stop()`），
      // 幽灵守卫态会让守卫页开关显示为"开"。
      guardActive: false,
      guardError: null,
      alarmDiag: null,
    );
    _stateCtrl.add(_last!);
  }

  /// 测试缝（v1.8）：widget 测试中后台服务未初始化，`invoke(...)` 会**抛**。
  ///
  /// 具体机制：`FlutterBackgroundService.invoke` → `FlutterBackgroundService
  /// Platform.instance`，而该 getter 内部判平台，**非 Android/iOS 直接抛**
  /// `UnsupportedError('FlutterBackgroundService is currently supported for
  /// Android and iOS Platform only.')`（实测：宿主 widget 测试里点一下
  /// 「电源策略」就炸，且异常发生在 `setState` 之前 → 界面停在旧值）。
  ///
  /// 测试注入本钩子短路。生产代码不设置此值，走真实服务调用。
  @visibleForTesting
  static Future<void> Function(String method, Map<String, Object?>? args)?
      invokeHook;

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    final hook = invokeHook;
    if (hook != null) {
      await hook(method, args);
      return;
    }
    _svc.invoke(method, args); // 返回 void（fire-and-forget）
  }

  /// 测试缝（v1.8）：widget 测试中后台服务未初始化，`invoke('replan')`
  /// 会抛（见 `invokeHook`）。测试注入本钩子短路。
  /// 生产代码不设置此值，走真实服务调用。
  @visibleForTesting
  static Future<void> Function()? replanHook;

  Future<void> replan() async {
    final hook = replanHook;
    if (hook != null) {
      await hook();
      return;
    }
    await _invoke('replan');
  }

  /// 开关守卫。
  ///
  /// [micGranted]：**主 isolate 的权威授权结论**（UI 刚 `request()` 出来的）。
  ///
  /// ⚠️ 为什么必须由 UI 传下来、而不是让引擎自己查：引擎跑在
  /// `flutter_background_service` 的隔离里，**没有 Activity**，而
  /// `record` 插件的 `hasPermission()` 在 `activity == null` 时**直接返回 false**
  /// （`record_android-2.2.0/.../PermissionManager.kt:33-36`）——
  /// 与系统实际授权无关。真机实证：`RECORD_AUDIO: granted=true` 的设备上，
  /// 审计里仍然写着"麦克风权限被拒"（BUG-A）。所以授权与否**只能**由
  /// 有能力询问系统的那一侧（主 isolate）回答。
  Future<void> setGuard(bool enabled, {bool? micGranted}) => _invoke('guard', {
        'enabled': enabled,
        if (micGranted != null) 'micGranted': micGranted,
      });

  /// 开关「实时随机动态反击」（v2.0 阶段 D）。
  ///
  /// 与 [setGuard] 同为 **fire-and-forget** invoke：引擎未运行时调用无副作用，
  /// 但 UI 侧已把开关持久化（`PrefsKeys.reactiveCounterEnabled`），下一次守卫
  /// 启动会据此自动装配 —— 因此"现在没引擎"不会让用户的意愿丢失。
  ///
  /// 动态反击**只在守卫运行时**有效（它消费守卫的声音事件），所以引擎侧在
  /// 守卫没跑时只落 prefs、不装配。
  Future<void> setReactiveCounter(bool enabled) =>
      _invoke('reactive', {'enabled': enabled});
  /// 切换电源模式（设置页保存后调用）。
  ///
  /// NAT-07：电源模式同时决定**原生**唤醒锁分级策略（performance 常驻 /
  /// balanced·saver 按需+显式释放），故先直连同步原生，再转交引擎。
  /// 两步都不能省：只 invoke 引擎 ⇒ 引擎没起来时原生策略停在上一档
  /// （唤醒锁是进程级资源，与引擎运行与否无关）；只同步原生 ⇒ 引擎内的
  /// 电源模式行为（如暂停随机类任务）不生效。
  Future<void> setPowerMode(String mode) async {
    final parsed = PowerMode.values.firstWhere(
      (m) => m.name == mode,
      orElse: () => PowerMode.balanced,
    );
    await syncNativeWakeLockPolicy(parsed);
    await _invoke('powerMode', {'mode': mode});
  }

  /// 远程 `vibrate.stop`（v1.9）：停止全部进行中的振动。
  ///
  /// 两步都要做：
  /// 1. `vibrateStop` 转交引擎 → 清活跃表（**停掉分片续发**，否则下一片
  ///    到期会自己震起来）+ 原生 cancel；
  /// 2. 兜底直调原生 cancel —— 引擎没跑时第 1 步发向不存在的服务没有效果。
  ///    原生 cancel 幂等，引擎在跑时重复调一次无害。
  Future<void> stopVibrate({String reason = '远程停止'}) async {
    await _invoke('vibrateStop', {'reason': reason});
    await NativeBridge.vibrateStop();
  }

  /// 远程「立即执行任务动作」：转交引擎隔离执行并等待结果。
  ///
  /// 引擎未运行时直接返回失败（调用方据此回 `rc.ack ok=false` 并给出
  /// 可操作提示），不静默成功。
  Future<RunNowResult> runNow(String taskId,
      {Duration timeout = const Duration(seconds: 45)}) async {
    if (!isRunning) {
      return const RunNowResult(ok: false, message: '调度引擎未运行');
    }
    final reqId = 'run${_runSeq++}_${DateTime.now().microsecondsSinceEpoch}';
    return _awaitResult(
        reqId, 'runNow', {'taskId': taskId, 'reqId': reqId}, timeout);
  }

  /// 远程指令组里的振动步骤（v1.9，docs/20 §11.1）。
  ///
  /// 与 [runNow] 同构：转交引擎隔离执行并等回投。引擎没跑时直接返回失败 ——
  /// 不在主 isolate 私自下发，因为那样会绕过分片续发与 `vibrate.stop`（见
  /// `background_engine` 的 `vibrateStep` 监听处的注记）。
  Future<RunNowResult> runVibrateStep({
    required ActionConfig action,
    required String occurrenceId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isRunning) {
      return const RunNowResult(ok: false, message: '调度引擎未运行');
    }
    final reqId = 'vib${_runSeq++}_${DateTime.now().microsecondsSinceEpoch}';
    return _awaitResult(reqId, 'vibrateStep', {
      'reqId': reqId,
      'occurrenceId': occurrenceId,
      'action': jsonEncode(action.toJson()),
    }, timeout);
  }

  /// 发出命令并等 `rcRunResult` 回投（超时是**返回值**而非异常）。
  Future<RunNowResult> _awaitResult(String reqId, String method,
      Map<String, Object?> args, Duration timeout) async {
    final completer = Completer<RunNowResult>();
    _pendingRun[reqId] = completer;
    // invoke 返回 void（fire-and-forget）：结果由 rcRunResult 回投。
    //
    // BUG-097：`invoke` 本身可能**同步抛**（服务已死但 `isRunning` 还是陈旧
    // true；非移动平台会抛 UnsupportedError）。旧写法把 `_pendingRun[reqId]`
    // 永久留在表里（completer 永不完成 ⇒ 每次泄漏一个），异常还会穿透到
    // `runNow` 的调用方（UI 侧变成未捕获异步错误）。
    try {
      _svc.invoke(method, args);
    } on Object catch (e) {
      _pendingRun.remove(reqId);
      return RunNowResult(ok: false, message: '引擎调用失败：$e');
    }
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return const RunNowResult(ok: false, message: '引擎执行超时');
    } finally {
      // 🔴 R97：三个出口统一摘表。
      //
      // 旧写法在 `on TimeoutException` 与 `on Object` 里各写一遍 `remove`，
      // 其中 `on Object` 分支**恒不可达**：`completer.future` 的唯一完成点是
      // 回投侧的 `_pendingRun.remove(reqId)` + `complete(...)`（全仓**没有**
      // `completeError` 调用点），而 `.timeout()` 只可能抛 `TimeoutException`
      // ⇒ 那两行是死代码，且"正常回投"这条真实出口反而**没有**在这里摘表。
      // 改成 `finally` 后三条出口一致、无死代码；回投侧已先摘表，
      // 这里再摘一次是幂等的。
      _pendingRun.remove(reqId);
    }
  }

  bool get isRunning => _last?.running ?? false;
  bool get guardActive => _last?.guardActive ?? false;

  /// 引擎自报的**守卫启动失败原因**（成功时为 null）。
  ///
  /// 存在的意义（BUG-061 判据的加强）：`waitForGuardActive(true)` 超时只能
  /// 说"没等到"，说不出"为什么没等到"。有了它，UI 就能把麦克风侧的真实
  /// 原因原样转达给用户，而不是一律归咎于"引擎无响应"。
  String? get guardError => _last?.guardError;

  /// 等待引擎回投状态，直到 `guardActive == expected` 或超时。
  ///
  /// 存在意义（BUG-061）：`setGuard()` 是 **fire-and-forget** 的 `invoke`，
  /// 调用返回**不代表生效**。引擎没跑时它发向不存在的服务、完全没反应，
  /// UI 若只看"调用完成"就会显示错误的成功。
  /// 有了这个等待，UI 才能区分"生效了"与"引擎无响应"。
  ///
  /// 返回 true = 观察到期望状态；false = 超时。
  ///
  /// ⚠️ 刻意**不用** `state.firstWhere(...)`：`firstWhere` 不带 `orElse`
  /// 会在流关闭时抛 `Bad state: No element`（全局锁 EBI-04 禁止该形态）。
  /// 这里用 Completer + `timeout(onTimeout:)`，超时是**返回值**而非异常。
  Future<bool> waitForGuardActive(bool expected,
      {Duration timeout = const Duration(seconds: 3)}) async {
    if (guardActive == expected) return true;
    final c = Completer<bool>();
    StreamSubscription<EngineState>? sub;
    sub = state.listen((s) {
      if (c.isCompleted) return;
      if (s.guardActive == expected) {
        c.complete(true);
      } else if (expected && s.guardError != null) {
        // 引擎已**明确**报出启动失败原因（如"麦克风启动失败：…"）：
        // 这时不可能再等到 `guardActive:true`，立刻结束等待把原因交给 UI，
        // 不必白等满 3 秒再报一句含糊的"引擎无响应"。
        c.complete(false);
      }
    });
    try {
      return await c.future.timeout(timeout, onTimeout: () => false);
    } finally {
      await sub.cancel();
    }
  }
}

/// 远程「立即执行」结果。
class RunNowResult {
  const RunNowResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}
