# =====================================================================
# 声盾 SonicShield —— Android 模拟器/真机联测脚本（Windows）
# 用法：.\scripts\emulator_test.ps1 [-ApkPath <path>]
# 前提：ANDROID_HOME 已配置；模拟器已启动（emulator -avd sonic_test）或真机已连接。
# 功能：安装 APK -> 静默授权全部运行时权限 -> 加入电池白名单 ->
#       启动应用 -> 抓取应用日志 -> 可选跑集成测试。
# =====================================================================
param(
    [string]$ApkPath = "..\build\app\outputs\flutter-apk\app-debug.apk"
)

$ErrorActionPreference = "Stop"
$pkg = "com.sonicshield.sonic_shield"

Write-Host "[1/6] 等待设备 ..." -ForegroundColor Cyan
adb wait-for-device
adb devices

Write-Host "[2/6] 安装 APK: $ApkPath" -ForegroundColor Cyan
adb install -r -t $ApkPath

Write-Host "[3/6] 静默授予运行时权限（模拟器测试专用；真机请走应用内引导）" -ForegroundColor Cyan
adb shell pm grant $pkg android.permission.POST_NOTIFICATIONS 2>$null
adb shell pm grant $pkg android.permission.RECORD_AUDIO 2>$null
adb shell appops set $pkg SCHEDULE_EXACT_ALARM allow 2>$null

Write-Host "[4/6] 电池优化白名单（模拟 Doze 放行）" -ForegroundColor Cyan
adb shell dumpsys deviceidle whitelist +$pkg | Out-Null
Write-Host "  -> 已加入 deviceidle whitelist"

Write-Host "[5/6] 启动应用" -ForegroundColor Cyan
adb shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 | Out-Null
Start-Sleep -Seconds 4

Write-Host "[6/6] 应用日志（最近 40 行）" -ForegroundColor Cyan
adb logcat -d -t 40 | Select-String -Pattern $pkg, "flutter", "AlarmWatchdog", "BootReceiver"

Write-Host ""
Write-Host "提示：验证后台保活可执行：" -ForegroundColor Green
Write-Host "  adb shell am kill $pkg            # 模拟进程被杀（闹钟看门狗应重新拉起）"
Write-Host "  adb shell dumpsys deviceidle force-idle   # 进入 Doze"
Write-Host "  adb shell dumpsys deviceidle step         # 逐步进入深度休眠"
Write-Host "  adb shell dumpsys deviceidle exit         # 退出 Doze"
Write-Host "  集成测试：flutter test integration_test/app_smoke_test.dart -d emulator-5554"
