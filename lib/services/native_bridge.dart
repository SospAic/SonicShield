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
/// - setPersistentWakeLock：性能优先档的常驻唤醒锁（锁屏/Doze 不冻结 CPU）。
class NativeBridge {
  NativeBridge._();

  static const MethodChannel _ch = MethodChannel(ChannelsMethod.channel);

  static Future<T?> _invoke<T>(String method,
      [Map<String, dynamic>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on PlatformException {
      // 桌面/测试/未实现平台上静默降级；日志由调用方记录。
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 提交精确闹钟（毫秒时间戳列表）。返回成功排布的数量。
  static Future<int> setExactAlarms(List<int> epochMs) async {
    final r = await _invoke<int>('setExactAlarms', {'times': epochMs});
    return r ?? 0;
  }

  static Future<void> clearAlarms() => _invoke<Object?>('clearAlarms');

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
  /// 由引擎按电源模式调用（performance ⇒ 持锁，其余 ⇒ 释放）。持锁期间锁屏 /
  /// Doze 也不会冻结 CPU，通道 A（应用内 Dart Timer）可像前台一样准点触发 ——
  /// 这是"锁屏后功能全部失效"（仅通道 B 生效）的**可选**兜底方案。
  /// **代价是持续耗电**，故仅当用户显式选「性能优先」时才持有。
  ///
  /// 返回 true = 当前处于持锁状态（桥不可用 / 非 Android 返回 false）。
  static Future<bool> setPersistentWakeLock(bool enabled) async {
    final r = await _invoke<bool>('setPersistentWakeLock', {'enabled': enabled});
    return r ?? false;
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
  /// 返回 false = 平台拒绝或桥不可用（**调用方必须留痕**，不得静默）——
  /// 与 [setVolume] 的 ack 语义一致。
  static Future<bool> alert({required String message}) async {
    final r = await _invoke<bool>('alert', {'message': message});
    return r ?? false;
  }

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
  /// 复用已授权的 MediaProjection（**不重复弹窗**）。未在投屏 / 未授权 / 超时
  /// ⇒ `null`（**如实失败**，调用方必须回 `rc.ack{ok:false}`，不得静默）。
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
  static Future<bool> screenCastStart() async {
    try {
      final r = await _screenCastCh.invokeMethod<bool>('screenCastStart');
      return r ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

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

  /// 是否发生降级（权限被拒 / 平台不支持 / 部分排布 / 排布异常）。
  bool get degraded =>
      denied || unsupported || error != null || scheduled < expected;

  bool get ok => !degraded;

  /// 面向 UI 与审计的降级原因；未降级时为 null。
  String? get reason {
    if (denied) return '精确闹钟权限未授予：进程被杀后不保证准点唤醒，可在系统设置中恢复';
    if (unsupported) return '本平台不支持精确闹钟：仅进程存活时可执行';
    if (error != null) return '精确闹钟排布异常：$error';
    if (scheduled < expected) {
      return '精确闹钟仅排布 $scheduled/$expected：部分计划在进程被杀后不保证触发';
    }
    return null;
  }

  /// 解析原生回执（纯函数，便于宿主断言）。
  ///
  /// - `Map`：新版原生结构化字段；
  /// - `num`：**旧版原生**返回的"成功条数"，按兼容解析（不被误判为权限拒绝）；
  /// - 其他/`null`：平台未回执 → 归为 `unsupported` 降级。
  static AlarmScheduleResult fromRaw(Object? raw, {required int expected}) {
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
    return AlarmScheduleResult(
      expected: expected,
      scheduled: 0,
      denied: false,
      unsupported: true,
    );
  }
}
