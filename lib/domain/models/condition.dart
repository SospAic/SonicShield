import 'dart:convert';

/// 任务执行前置条件层（v1.3，借鉴 Tasker/MacroDroid 的条件段）。
///
/// 满足全部已配置条件才允许执行；任一不满足 → 计划标 skipped（审计留痕）。
/// v1.3 覆盖：充电状态 / 最低电量 / 每日时段窗口。
/// **v1.7 新增**：Wi-Fi 条件（`requireWifi`）与**通话中不执行**（`skipInCall`）。
///
/// ## 为什么"通话中不执行"默认开启（安全默认）
///
/// 定时/随机播放的音频如果在**通话中**触发，声音会灌进通话里 —— 对通话双方都是
/// 干扰，且属于使用者无法预期的行为。行业领先的自动化工具（MacroDroid 的
/// Call State 约束、Tasker 的 Call 状态）都把通话状态作为一等条件。
///
/// 本项目用 `AudioManager.mode`（而非 `TelephonyManager`）判定通话，
/// **不需要任何权限**（连 READ_PHONE_STATE 都不用），因此不会给使用者增加
/// 授权负担，也不会与合规红线（docs/08 最小权限）冲突。
///
/// ## 无法判定时的方向（与既有约定一致：视为满足）
///
/// `inCall` / `onWifi` 传 `null` 表示**本平台无法判定**（如 iOS 无对应桥接）。
/// 此时按"条件满足"处理 —— 与既有代码对电池条件的处理一致
/// （见 `background_engine.conditionFailed` 的"无电池平台视为满足"）。
/// 这样不会因为某个平台读不到状态就把全部自动化静默停掉；
/// Android 侧始终能判定，因此实际防护不受影响。
/// 一次条件评估所需的全部**平台来源**输入（快照）。
///
/// ## 为什么要把它单独抽出来
///
/// 这些值都来自**平台通道**（电量 / 充电 / 通话 / 网络），每次读取
/// 在设备上 ≈1.5–2ms（BUG-035 / BUG-042 实测）。调度引擎一轮会遍历
/// **所有**到期计划，逐任务读取就是 4N 次往返；同一轮内所有任务面对的
/// 是同一个物理环境，所以读一次即可（见 `RoundConditionEnv`）。
///
/// 抽成值对象后，"读平台"与"判定条件"解耦：判定变成纯函数，可离线测试。
///
/// ## 默认值刻意与改造前的引擎初值一致
///
/// `batteryLevel = 100`、`charging = false`、`inCall`/`onWifi` 为 `null`，
/// 因此"平台读不到"时的行为**与改造前逐字相同**：
/// - `batteryLevel = 100` → 电量条件视为满足（"无电池平台视为满足"的既有约定）；
/// - `inCall` / `onWifi` 为 `null` → 视为**无法判定**，按满足处理（BUG-041 的约定）；
/// - `charging = false` → 保留原行为（充电条件在无电池平台上仍会拦下任务）。
class ConditionEnv {
  const ConditionEnv({
    this.charging = false,
    this.batteryLevel = 100,
    this.inCall,
    this.onWifi,
  });

  /// 是否处于充电（或已充满）。
  final bool charging;

  /// 电量百分比（0–100）。
  final int batteryLevel;

  /// 是否通话中；`null` = **无法判定**（不是"没在通话"）。
  final bool? inCall;

  /// 是否在 Wi-Fi 下；`null` = **无法判定**（不是"不在 Wi-Fi"）。
  final bool? onWifi;

  @override
  String toString() =>
      'ConditionEnv(charging: $charging, batteryLevel: $batteryLevel, '
      'inCall: $inCall, onWifi: $onWifi)';
}

class TaskCondition {
  const TaskCondition({
    this.requireCharging = false,
    this.minBatteryPct,
    this.windowStartMin,
    this.windowEndMin,
    this.windowEndNextDay = false,
    this.requireWifi = false,
    this.skipInCall = true,
  });

  final bool requireCharging; // 仅充电时执行
  final int? minBatteryPct; // 电量 ≥ 此值（0-100，null 不限制）
  final int? windowStartMin; // 每日时段窗口（分钟 0-1439，含端点）
  final int? windowEndMin;
  final bool windowEndNextDay;

  /// 仅在 Wi-Fi 网络下执行（v1.7；避免消耗移动流量、也常被用作"到家了"的代理信号）。
  final bool requireWifi;

  /// **通话中不执行**（v1.7，默认 true —— 安全默认，见类文档）。
  final bool skipInCall;

  bool get hasAny =>
      requireCharging ||
      minBatteryPct != null ||
      windowStartMin != null ||
      requireWifi ||
      skipInCall;

  Map<String, dynamic> toJson() => {
        'requireCharging': requireCharging,
        if (minBatteryPct != null) 'minBatteryPct': minBatteryPct,
        if (windowStartMin != null) 'windowStartMin': windowStartMin,
        if (windowEndMin != null) 'windowEndMin': windowEndMin,
        'windowEndNextDay': windowEndNextDay,
        'requireWifi': requireWifi,
        'skipInCall': skipInCall,
      };

  static TaskCondition? fromJsonOrNull(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return TaskCondition(
        requireCharging: j['requireCharging'] as bool? ?? false,
        minBatteryPct: (j['minBatteryPct'] as num?)?.toInt(),
        windowStartMin: (j['windowStartMin'] as num?)?.toInt(),
        windowEndMin: (j['windowEndMin'] as num?)?.toInt(),
        windowEndNextDay: j['windowEndNextDay'] as bool? ?? false,
        requireWifi: j['requireWifi'] as bool? ?? false,
        // 缺键时取默认（true）—— 老任务升级后自动获得通话保护。
        skipInCall: j['skipInCall'] as bool? ?? true,
      );
    } on Object {
      return null; // 解析失败视为无条件（不阻塞执行）
    }
  }

  /// 返回**首个**未满足条件的人话描述；全部满足返回 null。
  ///
  /// 比 [describe] 更适合写审计：`describe` 给的是"配了哪些条件"，
  /// 而排障时想知道的是"这次**为什么**没执行"。
  String? firstUnmet({
    required bool charging,
    required int batteryLevel,
    required DateTime now,
    bool? inCall,
    bool? onWifi,
  }) {
    if (skipInCall && inCall == true) return '通话中（不打扰通话）';
    if (requireCharging && !charging) return '未充电';
    if (minBatteryPct != null && batteryLevel < minBatteryPct!) {
      return '电量 $batteryLevel% < $minBatteryPct%';
    }
    if (requireWifi && onWifi == false) return '不在 Wi-Fi 下';
    if (windowStartMin != null && windowEndMin != null) {
      final cur = now.hour * 60 + now.minute;
      final s = windowStartMin!;
      final e = windowEndMin!;
      // windowEndNextDay 影响的是"窗口跨零点"的语义表达；两种写法在
      // 跨零点（s > e）时结果一致，这里统一按 s>e 判定跨天。
      final inWindow = s <= e ? (cur >= s && cur < e) : (cur >= s || cur < e);
      if (!inWindow) return '不在时段窗口内';
    }
    return null;
  }

  /// 评估：全部条件满足返回 true。
  bool evaluate({
    required bool charging,
    required int batteryLevel,
    required DateTime now,
    bool? inCall,
    bool? onWifi,
  }) =>
      firstUnmet(
        charging: charging,
        batteryLevel: batteryLevel,
        now: now,
        inCall: inCall,
        onWifi: onWifi,
      ) ==
      null;

  /// 用**已读好的环境快照**评估（[ConditionEnv]，一轮只读一次平台状态）。
  ///
  /// 与 [firstUnmet] 的唯一差别是**输入的来源**：这里不自己去读平台，
  /// 而是消费调用方已经读好的快照，从而把一轮内 N 个任务的 4N 次
  /// 平台往返压到 4 次。判定逻辑**完全复用** [firstUnmet]，
  /// 不存在"两条路径判得不一样"的可能。
  ///
  /// `now` 单独传入而不进快照：它是本地时钟（无平台通道开销），
  /// 保持实时取值让时段窗口判定更准。
  String? firstUnmetIn(ConditionEnv env, {required DateTime now}) => firstUnmet(
        charging: env.charging,
        batteryLevel: env.batteryLevel,
        now: now,
        inCall: env.inCall,
        onWifi: env.onWifi,
      );

  String describe() {
    final parts = <String>[];
    if (skipInCall) parts.add('通话中不执行');
    if (requireCharging) parts.add('仅充电');
    if (minBatteryPct != null) parts.add('电量≥$minBatteryPct%');
    if (requireWifi) parts.add('仅 Wi-Fi');
    if (windowStartMin != null && windowEndMin != null) {
      String hm(int m) =>
          '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
      parts.add('${hm(windowStartMin!)}–${hm(windowEndMin!)}');
    }
    return parts.isEmpty ? '无条件' : parts.join(' · ');
  }
}
