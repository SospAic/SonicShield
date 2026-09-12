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
}
