import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/models/vibrate_caps.dart';
import '../domain/scheduling/vibrate_resolve.dart';

/// 与原生层（Android MainActivity / Kotlin）通信的唯一入口。
///
/// 原生端能力：
/// - setExactAlarms / clearAlarms：把已提交计划的触发时刻写入
///   AlarmManager（setExactAndAllowWhileIdle），Doze 下也能唤醒
///   前台服务执行 —— 双通道触发的“原生子通道”。
/// - exactAlarmSupported / openExactAlarmSettings：Android 12+ 特殊权限。
/// - isIgnoringBatteryOptimizations / requestIgnoreBatteryOptimizations。
/// - openOemAutostart：跳转主流厂商的自启动/电池白名单页。
/// - setServiceShouldRun：开机自启标志（BootReceiver 读取）。
/// - setPersistentWakeLock / setPowerMode / releaseWakeLock：唤醒锁
///   （NAT-07 分级：performance 常驻，balanced/saver 按需+显式释放）。
/// - isMicServiceRunning / stopMicGuardService：麦克风 FGS 通行证的
///   探测与撤下（NAT-03 / NAT-11）。
/// - setSecureFlag：Activity FLAG_SECURE（F1 QR 页禁截屏）。
/// - getOrCreateDeviceSecret：设备秘密 base64（F1 REM-10 落盘加密）。
class NativeBridge {
  NativeBridge._();

  static const MethodChannel _ch = MethodChannel(ChannelsMethod.channel);

  /// 最近一次通道调用的**原生错误**（NAT-13；成功 / 无实现时为 null）。
  ///
  /// 为什么需要它：`_invoke` 的契约是"读不到 ⇒ null ⇒ 调用方如实降级"
  /// （BUG-125），但把 `PlatformException`（原生明确报错）与
  /// `MissingPluginException`（平台没这个通道）**一律折叠成 null** 会让审计
  /// 把"权限被拒 / 契约违例"误报成"平台未实现"—— 排障方向整个错。
  /// 这里保留最近一次错误的**种类与信息**，诊断类调用方
  /// （如 [setExactAlarms] → [AlarmScheduleResult.nativeError]）据此区分
  /// "真不支持"与"原生失败"。
  static Object? lastNativeError;

  /// 统一的通道调用出口。
  ///
  /// ## 为什么必须兜到 `Object`（BUG-125）
  /// 旧实现只捕 `PlatformException` / `MissingPluginException`，漏掉**第三类**
  /// 失败：**回执类型不匹配**。`invokeMethod<T>` 在解码后要 `as T?`，原生若
  /// 返回了别的类型（老版本插件、Kotlin 侧分支漏改、Map 的键类型是 `Object?`
  /// 而非 `String`），抛的是 `TypeError` —— 它会**穿透**这两个 catch，
  /// 一路逃到调用栈顶变成未处理异步错误。
  ///
  /// 后果在引擎侧尤其严重：`_invoke` 的调用点（闹钟排布 / 振动 / 音量）
  /// 都在 tick 的关键路径上，异常逃出去就**整轮 tick 中断**，表现为
  /// "某天起所有任务都不触发了"，而审计里一条记录都没有。
  ///
  /// `_invoke` 的契约本来就是“读不到 ⇒ null ⇒ 调用方如实降级”，把
  /// `TypeError` 也归到 null 是同一条语义，不是新加一层静默。
  ///
  /// ## NAT-13：错误种类保留在 [lastNativeError]
  /// 每次调用先清空、失败时记录：调用方随后读到的一定是**本次**调用的
  /// 错误（而不是更早某次调用的残留）。
  static Future<T?> _invoke<T>(String method,
      [Map<String, dynamic>? args]) async {
    lastNativeError = null;
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      // 原生明确报错（SecurityException / IllegalStateException …）：
      // 保留种类与信息，仍按契约返回 null（不炸 tick）。
      lastNativeError = e;
      return null;
    } on MissingPluginException catch (e) {
      // 平台没有这个通道（iOS 未实现 / 桌面）—— 这才是"真不支持"。
      lastNativeError = e;
      return null;
    } on Object {
      // 类型不匹配（TypeError）/ 通道被销毁等：同样归为"读不到"。
      return null;
    }
  }

  /// 提交精确闹钟（毫秒时间戳列表）。返回成功排布的数量。
  ///
  /// [useAlarmClock]（docs/59 缺口1，2026-10）：true 时原生走
  /// `AlarmManager.setAlarmClock` 特权通道 —— Doze 深度休眠中**准时**触发、
  /// 不受 `setExactAndAllowWhileIdle` 的 9 分钟最小间隔限制（闹钟类应用的
  /// 标准做法）。代价：状态栏常驻闹钟图标（用户可见性契约）。排布失败时
  /// 原生逐条回退常规精确闹钟，并把降级原因写进 [AlarmScheduleResult.error]
  /// —— 调用方（引擎 `alarmDiag`）必须如实呈现，不许静默。
  static Future<AlarmScheduleResult> setExactAlarms(
    List<int> epochMs, {
    bool useAlarmClock = false,
  }) async {
    final r = await _invoke<Object>('setExactAlarms', {
      'times': epochMs,
      'useAlarmClock': useAlarmClock,
    });
    // NAT-13：把本次通道错误的**种类**一起交给解析器 ——
    // PlatformException（原生明确报错）≠ MissingPluginException（平台无此通道），
    // 前者必须记 failed + 异常类型名，后者才是 unsupported。
    return AlarmScheduleResult.fromRaw(r,
        expected: epochMs.length, nativeError: lastNativeError);
  }

  static Future<void> clearAlarms() => _invoke<Object?>('clearAlarms');

  /// Android 12+ `SCHEDULE_EXACT_ALARM` 特殊权限是否已授予。
  ///
  /// ## iOS 语义（NAT-12）
  /// iOS **没有** Android 的「闹钟和提醒」特殊权限概念 —— 该检查在 iOS 上
  /// 不适用。iOS 侧桥（HapticBridge）对本方法返回 **true**（"本平台不适用
  /// 该检查"），于是 Dashboard 不会渲染"精确闹钟权限未开启"这条**永远修不了**
  /// 的告警（旧实现 iOS 恒 false ⇒ 永久误报）。Android 语义不变：
  /// true = 已授予 / API<31 恒可授权；false = 未授予（可跳系统设置恢复）；
  /// 桥不可用（桌面/测试）仍折叠为 false。
  static Future<bool> exactAlarmSupported() async {
    final r = await _invoke<bool>('exactAlarmSupported');
    return r ?? false;
  }

  static Future<void> openExactAlarmSettings() =>
      _invoke<Object?>('openExactAlarmSettings');

  static Future<bool> isIgnoringBatteryOptimizations() async {
    final r = await _invoke<bool>('isIgnoringBatteryOptimizations');
    return r ?? true; // 桌面/iOS 视为无需处理
  }

  static Future<void> requestIgnoreBatteryOptimizations() =>
      _invoke<Object?>('requestIgnoreBatteryOptimizations');

  /// vendor: xiaomi|huawei|oppo|vivo|samsung|meizu|oneplus|generic
  static Future<void> openOemAutostart(String vendor) =>
      _invoke<Object?>('openOemAutostart', {'vendor': vendor});

  /// 「性能优先」极致保活档：持有 / 释放**常驻** `PARTIAL_WAKE_LOCK`。
  ///
  /// ## NAT-07（老板裁决：分级跟随 powerMode）
  /// - `performance`：本方法 acquire 的锁**常驻**，直到
  ///   `setPersistentWakeLock(false)` 或切档释放；
  /// - `balanced` / `saver`：引擎**按需** acquire（仍走本方法），但必须在
  ///   任务结束时调 [releaseWakeLock] 显式释放 —— 这两档常驻持锁是
  ///   **策略禁止**的（"平衡/省电模式不持锁"的产品承诺）。切档到这两档时
  ///   上一档留下的常驻锁会被原生**立即释放**（策略在切档点强制执行）。
  ///
  /// 由引擎按电源模式调用（performance ⇒ 持锁，其余 ⇒ 释放）。持锁期间锁屏 /
  /// Doze 也不会冻结 CPU，通道 A（应用内 Dart Timer）可像前台一样准点触发 ——
  /// 这是"锁屏后功能全部失效"（仅通道 B 生效）的**可选**兜底方案。
  /// **代价是持续耗电**，故仅当用户显式选「性能优先」时才常驻持有。
  ///
  /// 返回 true = 当前处于持锁状态（桥不可用 / 非 Android 返回 false）。
  static Future<bool> setPersistentWakeLock(bool enabled) async {
    final r = await _invoke<bool>('setPersistentWakeLock', {'enabled': enabled});
    return r ?? false;
  }

  /// NAT-07：把电源模式同步给原生唤醒锁分级策略。
  ///
  /// `performance` / `balanced` / `saver` 三档语义见 [setPersistentWakeLock]。
  /// 由 `power_service.syncNativeWakeLockPolicy` 在用户切档时调用
  /// （`BackgroundServiceManager.setPowerMode` 是唯一漏斗）。
  ///
  /// 为什么必须**直连原生**而不只 invoke 引擎：唤醒锁是**进程级**资源
  /// （插件 companion 单例），与后台引擎是否在跑无关 —— 引擎没起来时
  /// invoke 无人接收，策略会停在上一档。
  static Future<void> setPowerMode(String mode) =>
      _invoke<Object?>('setPowerMode', {'mode': mode});

  /// NAT-07：balanced/saver 档"按需 acquire、任务结束显式释放"的释放出口。
  ///
  /// // F2 调用点：`background_engine.dart` 在任务执行结束 / 停机时调用
  /// // （performance 档请走 setPersistentWakeLock(false) 的正规路径）。
  /// 幂等：未持锁时调用也无副作用。桥不可用 / 非 Android 静默降级
  /// （释放失败的最坏后果由下一次切档的强制释放兜底）。
  static Future<void> releaseWakeLock() => _invoke<Object?>('releaseWakeLock');

  /// 本应用当前 **App Standby Bucket**（docs/59 缺口2）。
  ///
  /// 取值：`active` / `working_set` / `frequent` / `rare` / `restricted` /
  /// `unknown` / `unauthorized` / `unsupported`。
  /// - `unknown` = **无法判定**（服务缺失 / 平台异常）—— 不是"某种确定状态"，
  ///   与 [isOnWifi] 的 null 语义同先例（BUG-041）；
  /// - `unauthorized` = **未授予使用情况访问权**（NAT-14：`PACKAGE_USAGE_STATS`
  ///   已从清单移除，本产品不提供该授权入口 —— 显式降级，不再用 unknown
  ///   掩盖"永远读不到"）；
  /// - `unsupported` = API<28，平台没有这个语义；
  /// - 桥不可用（桌面 / iOS）也回落到 `unknown`。
  static Future<String> appStandbyBucket() async {
    final r = await _invoke<String>('standbyBucket');
    return r ?? 'unknown';
  }

  static Future<void> setServiceShouldRun(bool v) =>
      _invoke<Object?>('setServiceShouldRun', {'value': v});

  static Future<bool> serviceShouldRun() async {
    final r = await _invoke<bool>('getShouldRun');
    return r ?? false;
  }

  // ---------------- 环境状态（v1.7 条件层扩展） ----------------

  /// 是否正在通话（含 VoIP/视频通话）。
  ///
  /// 由 `AudioManager.getMode()` 判定（MODE_IN_CALL / MODE_IN_COMMUNICATION），
  /// **不需要任何权限** —— 这是刻意选择：用 `TelephonyManager` 读通话状态要
  /// READ_PHONE_STATE，会给使用者增加授权负担，也与最小权限原则冲突。
  ///
  /// 返回 null 表示**本平台无法判定**（如 iOS 无对应桥接）。调用方按
  /// "未通话"处理（与电池条件的既有约定一致），详见 `TaskCondition` 类文档。
  static Future<bool?> isInCall() => _invoke<bool>('callState');

  /// 当前网络类型。
  ///
  /// 取值：`wifi` / `cellular` / `ethernet` / `vpn` / `none` / `other` / `unknown`。
  ///
  /// **`unknown` 的语义是"无法判定"，不是"某种确定的网络"**：原生侧在
  /// `ConnectivityManager` 取不到、或拿到了活跃网络却读不出 capabilities 时返回它，
  /// 桥不可用时 Dart 侧也回落到它。`none` 才是"确实没有活跃网络"这个确定状态。
  ///
  /// 判定顺序（原生侧）为 wifi → cellular → ethernet → vpn，即**物理承载优先**：
  /// 只有当前网络的 capabilities 里连物理承载都读不到时才会落到 `vpn`。
  /// 因此 `vpn` 的语义是"活跃网络是 VPN 且未能读出底层承载"，而不是
  /// "一定不在 Wi-Fi 下"。**在真实 VPN 场景下的取值尚未在设备上验证**
  /// （见 docs/12 §18.6 观察项）。
  static Future<String> networkType() async {
    final r = await _invoke<String>('networkType');
    return r ?? 'unknown';
  }

  /// 是否在 Wi-Fi 下；**无法判定时返回 null**（调用方按"满足"处理）。
  ///
  /// `unknown` 与桥不可用一样属于"无法判定"，必须返回 `null` 而不是 `false`：
  /// 两者对条件层是完全相反的后果 —— `false` 会**拦下**任务并在审计里写
  /// "不在 Wi-Fi 下"（一个我们其实不知道的原因），`null` 才按既有约定放行。
  /// 把"读不到"误报成"不满足"正是 `TaskCondition` 类文档要避免的
  /// "某平台读不到状态就把全部自动化静默停掉"（BUG-041）。
  static Future<bool?> isOnWifi() async {
    final t = await _invoke<String>('networkType');
    if (t == null || t == 'unknown') return null;
    return t == 'wifi';
  }

  /// 守卫模式：前台启动麦克风类型 FGS（while-in-use 通行证）。
  /// 必须在用户前台交互（点击守卫开关）时调用（docs/05 §1.4）。
  static Future<void> startMicService() => _invoke<Object?>('startMicService');

  static Future<void> stopMicService() => _invoke<Object?>('stopMicService');

  /// NAT-11：远程/本地关闭守卫时**必须**调用 —— 撤下 `MicGuardService`
  /// （microphone 型 FGS 通行证）与其常驻通知。
  ///
  /// **契约（调用方 = F1 `endpoint_service` 的远程关守卫路径）**：
  /// 任何"关闭守卫"的入口都必须成对撤下通行证 —— 本地开关（guard_toggle）、
  /// 远程 `guard.set{enabled:false}`（F1）、引擎停机（background_engine）
  /// 三条路径一致。漏掉的后果：常驻通知"正在监听声音事件"残留，与
  /// "守卫已关"矛盾（隐私感知问题），且麦克风通行证被长期占用（耗电）。
  ///
  /// 与 [stopMicService] 是同一原生动作（幂等）：本方法是跨包契约名，
  /// 旧名保留给既有调用方（guard_toggle / background_engine）。
  static Future<void> stopMicGuardService() =>
      _invoke<Object?>('stopMicGuardService');

  /// NAT-03：麦克风采集中台（MicGuardService）是否**真的**在运行。
  ///
  /// **F2 调用点**（`background_engine.dart` 引擎 bootstrap 自恢复守卫前）：
  /// 守卫自恢复必须先确认 microphone 型 FGS 通行证存活。Android 11+
  /// while-in-use 语义下，后台（无 microphone FGS）`AudioRecord` **不抛异常
  /// 但只回静音** —— 直接自恢复会采到全静音，而 UI 仍报"守卫运行中"
  /// （核心安全能力静默失效，本项目最忌讳的形态）。拿不到通行证 ⇒
  /// **不启动采音**，如实置 `guardError` 并回投 `guardActive:false`。
  ///
  /// 返回 false = 通行证不在 / 探测失败（fail-closed：不可静默采音）。
  static Future<bool> isMicServiceRunning() async {
    final r = await _invoke<bool>('isMicServiceRunning');
    return r ?? false;
  }

  /// 震动（毫秒节奏数组，遵循 Android Vibrator 语义：交替的
  /// 静止/震动时长，首元素为起始静止时长）。无震动能力平台静默降级。
  ///
  /// ⚠️ 这是 v1.x 的**固定节奏**入口（`VibrateAction`）。v1.9 起的随机/持续振动
  /// 走 [vibrateCommand]（能表达振幅与包络），**不要**再往这里塞新能力。
  static Future<void> vibrate(List<int> patternMs) =>
      _invoke<Object?>('vibrate', {'pattern': patternMs});

  // ---------------- 振动能力（v1.9，docs/20 §5.1 / FR-38） ----------------

  /// 振动能力探测。
  ///
  /// 返回 [VibrateCaps.unknown] 表示**桥不可用/读不到**（不是"设备没有"）。
  /// 两者的后果都是降级，但对排查是完全不同的结论 —— 与 `isOnWifi()` 返回
  /// null 而非 false 同一先例（BUG-041）。
  static Future<VibrateCaps> vibrateCapabilities() async {
    final r = await _invoke<Map<Object?, Object?>>('vibrateCapabilities');
    if (r == null) return VibrateCaps.unknown;
    return VibrateCaps.fromMap(r.map((k, v) => MapEntry('$k', v)));
  }

  /// 下发**一次**振动命令（持续振动由执行层按片续发，docs/20 §7.2）。
  ///
  /// 返回 false = 平台拒绝或桥不可用（**调用方必须留痕**，不得静默）。
  static Future<bool> vibrateCommand(VibrateCommand cmd) async {
    final ok = switch (cmd.mode) {
      VibrateMode.envelope => await _invoke<bool>('vibrateEnvelope', {
          'points': [
            for (final p in cmd.points ?? const <EnvelopePoint>[]) p.toMap(),
          ],
          'useAlarmUsage': cmd.useAlarmUsage,
        }),
      // legacy（API<26）与两种 waveform 共用同一入口，由 Kotlin 按 SDK 分支。
      VibrateMode.waveformAmplitude ||
      VibrateMode.waveformOnOff ||
      VibrateMode.legacy =>
        await _invoke<bool>('vibrateWaveform', {
          'timings': cmd.timings,
          if (cmd.amplitudes != null) 'amplitudes': cmd.amplitudes,
          'repeat': cmd.repeat,
          'useAlarmUsage': cmd.useAlarmUsage,
        }),
    };
    return ok ?? false;
  }

  /// 停止本应用发起的所有振动（`Vibrator.cancel()`）。
  ///
  /// ⚠️ 这是"不设时长硬上限"（D1）能成立的前提之一（docs/20 §7.2 S3）：
  /// 任何时刻都必须能停。
  static Future<void> vibrateStop() => _invoke<Object?>('vibrateStop');

  /// 设置媒体/闹钟音量（0..1 归一化，原生按流最大音量换算）。
  /// 用于远程 volume.set（docs/16 §9），不影响铃声音量。
  static Future<bool> setVolume({double? media, double? alarm}) async {
    final r = await _invoke<bool>('volume.set', {
      if (media != null) 'media': media,
      if (alarm != null) 'alarm': alarm,
    });
    return r ?? false;
  }

  /// 找回动作（Q9.B）：远端触发设备本地提醒。
  ///
  /// 原生侧执行：点亮屏幕 → 高优先级全屏通知横幅显示 [message] →
  /// 媒体音量置最大并播放约 3 秒提示音（响铃振动沿用既有动作另行下发）。
  ///
  /// ## NAT-10：通知被拒 ⇒ 假成功红线
  /// 原生回执已改为结构化 Map（`{ok, screen, notification, sound, reason}`）：
  /// Android 13+ 用户拒绝 `POST_NOTIFICATIONS` 时 `notify()` 是**静默
  /// no-op**，旧实现照样回 true —— 远程收到"找回告警已展示"而通知栏
  /// 什么都没有。现在通知权限未授予时整体 `ok=false` 并带原因。
  /// 本方法仍按 **bool** 消费（`map['ok']`，兼容旧版原生的裸 bool 回执），
  /// 最近一次的失败原因留在 [lastAlertReason] 供诊断。
  ///
  /// 返回 false = 通知被拦截 / 平台拒绝 / 桥不可用（**调用方必须留痕**，
  /// 不得静默）—— 与 [setVolume] 的 ack 语义一致。
  static Future<bool> alert({required String message}) async {
    final r = await _invoke<Object>('alert', {'message': message});
    if (r is Map) {
      final ok = r['ok'] == true;
      lastAlertReason = ok ? null : (r['reason'] as String?);
      return ok;
    }
    // 旧版原生回执是裸 bool：按原样解析（升级路径兼容）。
    lastAlertReason = null;
    return r == true;
  }

  /// 最近一次 [alert] 的降级原因（成功 / 未调用时为 null；NAT-10 诊断用）。
  static String? lastAlertReason;

  // ---------------- 远程桌面级控制（docs/61 P0，看 + 控） ----------------
  //
  // ⚠️ 输入注入是**高危能力**：本桥只"转发 + 如实回执"；授权（MediaProjection
  // 弹窗 / 系统无障碍开关）与权限位（`RcPermGate`）在端点层把关，桥不重复判定。

  /// 无障碍服务是否已开启（决定远程输入是否可用）。
  ///
  /// 未开启时**所有** `input*` 注入都会如实失败 —— 调用方必须据此引导用户到
  /// 系统设置开启，**不得静默降级**（docs/61 §1、G8）。
  static Future<bool> accessibilityEnabled() async {
    final r = await _invoke<bool>('accessibilityEnabled');
    return r ?? false;
  }

  /// 停止投屏前台服务（幂等）。**不触碰授权**（授权由系统弹窗持有，docs/61 §1）。
  static Future<void> screenCastStop() => _invoke<Object?>('screenCastStop');

  /// 归一化坐标点击（`x`/`y` ∈ 0..1）。返回是否受理（未开无障碍 / 桥不可用 → false）。
  static Future<bool> inputTap(double x, double y, {int durationMs = 0}) async {
    final r = await _invoke<bool>(
        'inputTap', {'x': x, 'y': y, 'durationMs': durationMs});
    return r ?? false;
  }

  /// 归一化坐标滑动 / 拖拽（各坐标 ∈ 0..1）。返回是否受理。
  static Future<bool> inputSwipe(double x1, double y1, double x2, double y2,
      {int durationMs = 200}) async {
    final r = await _invoke<bool>('inputSwipe',
        {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'durationMs': durationMs});
    return r ?? false;
  }

  /// 导航类按键（Android `KeyEvent` 常量：返回 / Home / 最近任务）。
  /// ⚠️ 系统级按键（电源 / 音量）无障碍**做不到**，原生侧如实返回 false。
  static Future<bool> inputKey(int keyCode) async {
    final r = await _invoke<bool>('inputKey', {'keyCode': keyCode});
    return r ?? false;
  }

  /// 文本注入（对活动窗口**已聚焦**输入框）。返回是否受理。
  static Future<bool> inputText(String text) async {
    final r = await _invoke<bool>('inputText', {'text': text});
    return r ?? false;
  }

  /// 抓**一帧**屏幕，返回 JPEG 的 base64（docs/24 阶段1 / docs/61 P1）。
  ///
  /// 复用已授权的 MediaProjection（**不重复弹窗**；R94 起抓帧模型为
  /// "一次 VirtualDisplay、多次读帧"，见原生侧 ScreenCastService）。
  ///
  /// ## 失败回执（NAT-01/13）
  /// 未在投屏 / 未授权 ⇒ 原生回 `CAST_NOT_ACTIVE` 错误；抓帧本身失败
  /// （契约违例 / 授权丢失 / 超时）⇒ `CAPTURE_FAILED` 且**带异常类型名**。
  /// 两者都经 [_invoke] 折叠为 null（**如实失败**，调用方必须回
  /// `rc.ack{ok:false}`，不得静默）；异常种类保留在 [lastNativeError]。
  static Future<String?> screenCaptureOnce({int timeoutMs = 5000}) async {
    return await _invoke<String>('screenCaptureOnce', {'timeoutMs': timeoutMs});
  }

  /// 发起投屏授权并启动投屏前台服务（**必须由前台 UI 触发**）。
  ///
  /// 走**独立通道** `sonic_shield/screencast`（由 `MainActivity` 处理）：
  /// `createScreenCaptureIntent` 需要 Activity 承载系统授权弹窗，且返回的
  /// `resultCode` + `data` 只能在 `onActivityResult` 里拿到 —— 这是 Android 的
  /// 硬约束（docs/61 §1「授权不可绕过」）。返回 true = 用户同意且服务已启动；
  /// false = 拒绝 / 取消 / 桥不可用。
  ///
  /// ## NAT-09：双侧超时
  /// 原生侧 60s 无结果回 `CAST_TIMEOUT` error、`startActivityForResult`
  /// 抛错回 `CAST_START_FAILED`、Activity 销毁回 `CAST_CANCELLED` ——
  /// 在途状态**恰好清空一次**，一次异常不会把后续请求永久打成"用户拒绝"。
  /// Dart 侧再兜底 70s 超时（略大于原生，正常情况下先收到原生 error）。
  static Future<bool> screenCastStart() async {
    try {
      final r = await _screenCastCh
          .invokeMethod<bool>('screenCastStart')
          .timeout(const Duration(seconds: 70));
      return r ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } on TimeoutException {
      // 双侧超时都没兜住（极端情况）：按"未受理"收口，不挂调用方。
      return false;
    } on Object {
      // 同 [_invoke]：类型不匹配也归为"未受理"，不得让异常逃到调用栈顶。
      return false;
    }
  }

  /// F1 调用点（QR 页）：设置 / 清除 Activity 的 `FLAG_SECURE`
  /// （禁截屏、禁录屏、最近任务缩略图打码）。配对二维码页进入时
  /// `on: true`，退出时 `on: false`。
  ///
  /// 只在 **UI 引擎**可用（有 Activity）；后台引擎 / 桌面 / iOS 返回 false
  /// （桥未实现 ⇒ null ⇒ false，调用方据此降级，不假装生效）。
  static Future<bool> setSecureFlag({required bool on}) async {
    final r = await _invoke<bool>('setSecureFlag', {'on': on});
    return r ?? false;
  }

  /// F1 调用点（REM-10）：取**设备秘密**（base64），供落盘加密使用。
  ///
  /// Android：Keystore AES-256-GCM 封存的 32 字节 CSPRNG 秘密 ——
  /// 首次生成后**稳定**（prefs 里只有密文，私钥材料不出 TEE），随应用
  /// 卸载 / 清除数据一并失效；Keystore 不可用时降级为设备指纹派生
  /// （ANDROID_ID + Build 信息 SHA-256，**安全性折扣**：无硬件保护、
  /// 同输入可复现，仅兜底 —— 详见原生侧注释）。
  ///
  /// 返回 null = 取不到（iOS / 桌面桥未实现，或两条路径都失败）——
  /// 调用方必须按"没有设备密钥"降级，**不得**把 null 当空串去加密
  /// （那等于没加密）。
  static Future<String?> getOrCreateDeviceSecret() =>
      _invoke<String>('getOrCreateDeviceSecret');

  /// 投屏授权通道（Activity 承载，区别于插件的主方法通道）。
  static const MethodChannel _screenCastCh =
      MethodChannel('sonic_shield/screencast');
}

/// 避免与 services 包内其它 Channels 常量冲突的私有命名空间。
abstract final class ChannelsMethod {
  static const channel = 'sonic_shield/native';
}

/// 精确闹钟**排布结果**（P1-04）。
///
/// 为什么需要它：原生旧实现权限不足时直接返回 `0`，Dart 侧只区分「null 回执」
/// 与「抛异常」，把 `0` 当成普通的"排了 0 条"成功 —— 界面继续显示运行中与
/// 计划数，而系统级定时唤醒根本没排上（进程被回收后不再准点）。结构化结果让
/// 「权限被拒」「部分排布」「平台不支持」三类降级都可见、可展示、可恢复。
class AlarmScheduleResult {
  const AlarmScheduleResult({
    required this.expected,
    required this.scheduled,
    required this.denied,
    required this.unsupported,
    this.error,
    this.nativeError,
  });

  /// 期望排布的条数。
  final int expected;

  /// 实际排上的条数。
  final int scheduled;

  /// 精确闹钟特殊权限未授予（Android 12+ `SCHEDULE_EXACT_ALARM`）。
  final bool denied;

  /// 本平台根本没有这条通道（iOS/桌面/旧版原生）。
  final bool unsupported;

  /// 逐条排布时的原生异常信息（无异常为 null）。
  final String? error;

  /// NAT-13：原生**明确报错**的类型化信息（`code: message`，无错为 null）。
  ///
  /// 与 [unsupported] 互斥的失败维度：`PlatformException`
  /// （SecurityException / IllegalStateException …）= 原生失败了，
  /// **不是**"平台没这功能"；`MissingPluginException` 才是真不支持。
  /// 旧实现把两者一律折叠成 unsupported ⇒ 审计写"本平台未实现精确闹钟"，
  /// 用户按提示也修不好（真实原因是权限/系统拒绝）。
  final String? nativeError;

  /// 是否发生降级（权限被拒 / 平台不支持 / 部分排布 / 排布异常 / 原生报错）。
  bool get degraded =>
      denied || unsupported || error != null || nativeError != null ||
      scheduled < expected;

  bool get ok => !degraded;

  /// 面向 UI 与审计的降级原因；未降级时为 null。
  String? get reason {
    if (denied) return '精确闹钟权限未授予：进程被杀后不保证准点唤醒，可在系统设置中恢复';
    if (unsupported) return '本平台不支持精确闹钟：仅进程存活时可执行';
    if (error != null) return '精确闹钟排布异常：$error';
    if (nativeError != null) return '精确闹钟排布被原生拒绝：$nativeError';
    if (scheduled < expected) {
      return '精确闹钟仅排布 $scheduled/$expected：部分计划在进程被杀后不保证触发';
    }
    return null;
  }

  /// 解析原生回执（纯函数，便于宿主断言）。
  ///
  /// - `Map`：新版原生结构化字段；
  /// - `num`：**旧版原生**返回的"成功条数"，按兼容解析（不被误判为权限拒绝）；
  /// - 其他/`null`：平台未回执 —— 此时看 [nativeError]（NAT-13）：
  ///   `PlatformException`（原生明确报错）记 failed 并带出错误码；
  ///   `code == 'UNSUPPORTED'`（Kotlin 侧 UnsupportedOperationException）
  ///   记 unsupported；`MissingPluginException`（通道未实现）才是
  ///   "平台不支持"；两者都无才归 unsupported。
  static AlarmScheduleResult fromRaw(Object? raw,
      {required int expected, Object? nativeError}) {
    if (raw is Map) {
      return AlarmScheduleResult(
        expected: (raw['expected'] as num?)?.toInt() ?? expected,
        scheduled: (raw['scheduled'] as num?)?.toInt() ?? 0,
        denied: raw['denied'] == true,
        unsupported: raw['unsupported'] == true,
        error: raw['error'] as String?,
      );
    }
    if (raw is num) {
      return AlarmScheduleResult(
        expected: expected,
        scheduled: raw.toInt(),
        denied: false,
        unsupported: false,
      );
    }
    if (nativeError is PlatformException) {
      final unsupported = nativeError.code == 'UNSUPPORTED';
      return AlarmScheduleResult(
        expected: expected,
        scheduled: 0,
        denied: false,
        unsupported: unsupported,
        nativeError:
            unsupported ? null : '${nativeError.code}: ${nativeError.message}',
      );
    }
    return AlarmScheduleResult(
      expected: expected,
      scheduled: 0,
      denied: false,
      unsupported: true,
    );
  }
}
