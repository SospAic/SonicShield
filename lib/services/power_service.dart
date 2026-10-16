import 'package:battery_plus/battery_plus.dart';

import '../core/constants.dart';
import 'native_bridge.dart';

/// 电源模式（设置页可切换；saver 可被低电量自动接管）。
enum PowerMode {
  performance, // 精确优先：全部能力拉满（精确闹钟 + 守卫 + 最高优先级）
  balanced, // 平衡（默认）
  saver, // 省电：暂停随机类任务与守卫，仅保留固定定时
  ;

  String get label => switch (this) {
        PowerMode.performance => '性能优先',
        PowerMode.balanced => '平衡',
        PowerMode.saver => '省电',
      };
}

/// 电源管理服务：读电量/充电状态 + 一站式白名单引导。
class PowerService {
  PowerService(this._battery);

  final Battery _battery;

  Future<int> batteryLevel() => _battery.batteryLevel;
  Future<BatteryState> batteryState() => _battery.batteryState;
  Future<bool> isCharging() async =>
      (await _battery.batteryState) == BatteryState.charging ||
      (await _battery.batteryState) == BatteryState.full;

  /// 根据电量/充电状态建议生效模式（saver 自动接管）。
  Future<PowerMode> effectiveMode(PowerMode userMode) async {
    if (userMode == PowerMode.saver) return PowerMode.saver;
    try {
      final level = await _battery.batteryLevel;
      final charging = await isCharging();
      if (level >= 0 && level < PowerConfig.saverBatteryLevel && !charging) {
        return PowerMode.saver;
      }
    } on Object {
      // 桌面/测试无电池：维持用户选择。
    }
    return userMode;
  }

  Future<bool> batteryOptimizedAway() =>
      NativeBridge.isIgnoringBatteryOptimizations();
  Future<void> requestBatteryOptimizationExemption() =>
      NativeBridge.requestIgnoreBatteryOptimizations();
  Future<void> openExactAlarmSettings() =>
      NativeBridge.openExactAlarmSettings();
  Future<void> openOemAutostart(String vendor) =>
      NativeBridge.openOemAutostart(vendor);

  /// 本应用当前 App Standby 桶（docs/59 缺口2）。
  ///
  /// `unknown` = **无法判定**（API<28 / 未授予使用情况访问权 / 桥不可用），
  /// 调用方必须按"不知道"处理：既不弹警告也不报告"正常"。
  Future<String> standbyBucket() => NativeBridge.appStandbyBucket();

  /// 桶是否已降到会**明显推迟**后台任务的两档（rare / restricted）。
  ///
  /// 这两档里 JobScheduler/AlarmManager 任务可被推迟数小时；app 内无法
  /// 自提权（`am set-standby-bucket` 要 shell 权限），只能提示用户去
  /// 厂商设置页。`unknown` 返回 **false** —— 读不到 ≠ 受限，不能拿猜测
  /// 去骚扰用户（BUG-041 同款纪律）。
  Future<bool> standbyRestricted() async {
    final b = await standbyBucket();
    return b == 'rare' || b == 'restricted';
  }

  /// 面向 UI 的桶状态人话（无法判定给 null，让调用方决定不显示）。
  static String? standbyBucketLabel(String bucket) => switch (bucket) {
        'active' => '活跃（不受省电策略限制）',
        'working_set' => '常用（限制很轻）',
        'frequent' => '较常用（轻度限制）',
        'rare' => '很少使用（后台任务可能被大幅推迟，建议处理）',
        'restricted' => '受限（后台任务几乎被冻结，建议立即处理）',
        _ => null,
      };
}
