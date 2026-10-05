import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_bridge.dart';

/// 权限与合规流程集中地。
///
/// 合规门：首次启动必须阅读并同意《合规使用须知》（docs/08 摘要），
/// 同意后才可开启引擎。该记录持久化于 SharedPreferences。

const _kComplianceAccepted = 'compliance_accepted_v1';

Future<bool> isComplianceAccepted() async =>
    (await SharedPreferences.getInstance()).getBool(_kComplianceAccepted) ??
    false;

/// 合规准入闸（P1-02）：返回"用户现在是否已同意"。
///
/// 这是**引擎启动的唯一准入层**：首启引导与引擎开关都走这里。
/// 旧实现里"不同意"只写了一个 `false`，而引擎开关**从不读它**，
/// 于是用户明确拒签《合规使用须知》后仍能开启自动化 —— 合规门形同虚设。
///
/// 与首启引导的区别只是调用方：本函数在"未同意"时**必然弹出**须知
/// （可重读），返回用户当次的选择；已同意则直接返回 true，不再打扰。
Future<bool> ensureComplianceAccepted(BuildContext context) async {
  if (await isComplianceAccepted()) return true;
  if (!context.mounted) return false;
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('使用前必读 · 合规红线'),
      content: const SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('本工具仅限合法的个人自动化与自我保护用途，例如：'
                '定时提醒、助眠/专注音、习惯养成、对骚扰噪声进行录音取证、'
                '守护模式提醒。'),
            SizedBox(height: 8),
            Text('禁止用途：', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('· 利用随机时间/随机音量播放声音骚扰、恐吓、报复他人；\n'
                '· 在居民区夜间等时段制造噪声（《噪声污染防治法》《治安管理处罚法》'
                '均可能适用）；\n'
                '· 任何侵犯他人合法权益的行为。'),
            SizedBox(height: 8),
            Text('应用内置强制免打扰时段、音量上限与冷却机制，'
                '并完整记录执行日志。使用本工具产生的一切后果由使用者本人承担。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('不同意'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('我已阅读并承诺合法使用'),
        ),
      ],
    ),
  );
  final prefs = await SharedPreferences.getInstance();
  // 只在**明确同意**时写 true；拒绝/关闭一律写 false，准入闸保持关闭。
  await prefs.setBool(_kComplianceAccepted, accepted == true);
  return accepted == true;
}

/// 首次启动引导：未同意才弹一次，已同意直接跳过（不再打扰）。
Future<void> showComplianceGateOnce(BuildContext context, WidgetRef ref) async {
  await ensureComplianceAccepted(context);
}

/// 一站式权限申请的结果（P2-16）。
///
/// ⚠️ 为什么需要它：旧实现 `await Permission.notification.request()` **丢弃了
/// 返回值** —— Android 13+ 用户拒绝通知后，引擎照常"开启"、计划照常排布，
/// 但后台提醒、设备找回通知与执行结果提示**全都不会出现**，而界面没有任何
/// 降级说明，用户只会认定"功能坏了"。把两项结果回传给调用方，由调用方在
/// 用户可操作的位置给出**可执行的**降级提示（去系统设置重开）。
class PermissionRequestOutcome {
  const PermissionRequestOutcome({
    required this.notification,
    required this.microphone,
  });

  final PermissionStatus notification;
  final PermissionStatus microphone;

  /// 通知未授予（含"拒绝"与"永久拒绝"）—— 后台提醒会静默缺失。
  bool get notificationDenied =>
      notification.isDenied || notification.isPermanentlyDenied;

  /// 麦克风未授予 —— 守卫/录音取证不可用。
  bool get microphoneDenied =>
      microphone.isDenied || microphone.isPermanentlyDenied;
}

/// 一站式权限申请（开启引擎前调用）。
///
/// 返回各项权限的**真实结果**（而非静默丢弃）：调用方据此给出降级反馈。
Future<PermissionRequestOutcome> requestAllPermissions(WidgetRef ref) async {
  // 通知（Android 13+ / iOS）—— 结果必须回传（P2-16）。
  final notification = await Permission.notification.request();
  // 麦克风（守卫/取证）
  final microphone = await Permission.microphone.request();
  // 精确闹钟（Android 12+ 特殊权限）
  final exact = await NativeBridge.exactAlarmSupported();
  if (exact) {
    // 原生层已检查；未授权时跳转系统设置由引导页完成。
  }
  // 电池优化白名单（可跳过，引导页处理）。
  //
  // ⚠️ 只在**尚未加白**时才弹系统框：无条件弹会让「每次开引擎 / 开守卫」
  // 都弹出一次系统对话框，用户只能反复点掉；已加白的情况等于白弹一次。
  if (!await NativeBridge.isIgnoringBatteryOptimizations()) {
    await NativeBridge.requestIgnoreBatteryOptimizations();
  }
  return PermissionRequestOutcome(
    notification: notification,
    microphone: microphone,
  );
}

/// 厂商保活引导：识别品牌并给出操作指引 + 深链跳转。
Future<void> showKeepAliveGuide(BuildContext context) async {
  final vendor = await _detectVendor(context);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => _KeepAliveSheet(vendor: vendor),
  );
}

Future<String> _detectVendor(BuildContext context) async {
  try {
    if (Theme.of(context).platform == TargetPlatform.android) {
      final android = await DeviceInfoPlugin().androidInfo;
      return android.manufacturer.toLowerCase();
    }
  } on Object {
    // 桌面/测试
  }
  return 'generic';
}

class _KeepAliveSheet extends StatelessWidget {
  const _KeepAliveSheet({required this.vendor});

  final String vendor;

  static const Map<String, (String, String)> _guides = {
    'xiaomi': (
      '小米 / 红米 (MIUI·澎湃OS)',
      '设置 → 应用设置 → 应用管理 → 声盾 → 省电策略 → 无限制；并开启「自启动」。'
    ),
    'redmi': (
      '小米 / 红米 (MIUI·澎湃OS)',
      '设置 → 应用设置 → 应用管理 → 声盾 → 省电策略 → 无限制；并开启「自启动」。'
    ),
    'huawei': (
      '华为 / 荣耀 (EMUI·MagicOS)',
      '设置 → 电池 → 更多电池设置 → 关闭「休眠时始终保持网络连接」；应用启动管理 → 声盾 → 手动管理，三项全开。'
    ),
    'honor': (
      '华为 / 荣耀 (EMUI·MagicOS)',
      '设置 → 电池 → 更多电池设置 → 关闭「休眠时始终保持网络连接」；应用启动管理 → 声盾 → 手动管理，三项全开。'
    ),
    'oppo': (
      'OPPO / 一加 (ColorOS)',
      '设置 → 电池 → 更多 → 应用速冻/睡眠待机优化 关闭；应用管理 → 声盾 → 允许自启动、关联启动、后台运行。'
    ),
    'oneplus': (
      'OPPO / 一加 (ColorOS)',
      '设置 → 电池 → 更多 → 应用速冻/睡眠待机优化 关闭；应用管理 → 声盾 → 允许自启动、关联启动、后台运行。'
    ),
    'vivo': (
      'vivo / iQOO (OriginOS)',
      '设置 → 电池 → 后台耗电管理 → 声盾 → 允许后台高耗电；并允许自启动。'
    ),
    'iqoo': (
      'vivo / iQOO (OriginOS)',
      '设置 → 电池 → 后台耗电管理 → 声盾 → 允许后台高耗电；并允许自启动。'
    ),
    'samsung': (
      '三星 (One UI)',
      '设置 → 电池 → 后台使用限制 → 将声盾移出「睡眠中」列表；设置 → 应用 → 声盾 → 电池 → 无限制。'
    ),
    'meizu': ('魅族 (Flyme)', '手机管家 → 权限管理 → 声盾 → 后台保活；并开启自启动。'),
  };

  @override
  Widget build(BuildContext context) {
    final guide = _guides[vendor];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('后台保活设置（${vendor.toUpperCase()}）',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (guide != null) ...[
              Text(guide.$1,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(guide.$2),
            ] else
              const Text('通用步骤：系统设置 → 电池/应用管理 → 声盾 → 允许自启动、'
                  '取消电池优化（无限制）、锁定后台。'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.battery_saver),
                  label: const Text('申请电池白名单'),
                  onPressed: () =>
                      NativeBridge.requestIgnoreBatteryOptimizations(),
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.alarm),
                  label: const Text('精确闹钟权限'),
                  onPressed: () => NativeBridge.openExactAlarmSettings(),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.launch),
                  label: const Text('厂商自启动页'),
                  onPressed: () => NativeBridge.openOemAutostart(vendor),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
