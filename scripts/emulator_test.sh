#!/usr/bin/env bash
# 声盾 SonicShield —— Android 模拟器/真机联测脚本（macOS/Linux/Git Bash）
# 用法：bash scripts/emulator_test.sh [apk路径]
set -euo pipefail

APK="${1:-build/app/outputs/flutter-apk/app-debug.apk}"
PKG="com.sonicshield.sonic_shield"

echo "[1/6] 等待设备 ..."
adb wait-for-device
adb devices

echo "[2/6] 安装 APK: $APK"
adb install -r -t "$APK"

echo "[3/6] 静默授予运行时权限"
adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
adb shell pm grant "$PKG" android.permission.RECORD_AUDIO 2>/dev/null || true
adb shell appops set "$PKG" SCHEDULE_EXACT_ALARM allow 2>/dev/null || true

echo "[4/6] 电池优化白名单"
adb shell dumpsys deviceidle whitelist +"$PKG" >/dev/null || true

echo "[5/6] 启动应用"
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
sleep 4

echo "[6/6] 应用日志（最近 40 行）"
adb logcat -d -t 40 | grep -E "$PKG|flutter|AlarmWatchdog|BootReceiver" || true

cat <<'TIP'

验证后台保活：
  adb shell am kill com.sonicshield.sonic_shield   # 模拟进程被杀
  adb shell dumpsys deviceidle force-idle          # 进入 Doze
  adb shell dumpsys deviceidle step
  adb shell dumpsys deviceidle exit
集成测试：flutter test integration_test/app_smoke_test.dart -d emulator-5554
TIP
