@echo off
REM ============================================================
REM  SonicShield device prep: make lock-screen automation reliable
REM  Run ONCE per device before integration_test / CI / long-run automation.
REM
REM  What this fixes (see docs/59-lock-screen-automation.md):
REM    - screen lock / timeout killing UI-driven automation (Appium, flutter drive)
REM    - Doze + App Standby delaying scheduled tasks while the screen is off
REM    - default screen_off_timeout locking the device mid-test
REM
REM  Usage:
REM    prepare_device.bat                 apply all settings to every device
REM    prepare_device.bat -s 5555         single device (serial or host:port)
REM    prepare_device.bat --restore       restore sane defaults (30s timeout etc.)
REM    prepare_device.bat --verify        print current values only, change nothing
REM
REM  Notes:
REM    - Writes go to adb shell settings / dumpsys, nothing is uninstalled or deleted.
REM    - Idempotent: safe to re-run; --restore undoes the risky subset.
REM    - dumpsys deviceidle whitelist needs shell privileges; on some ROMs
REM      it reports "Cannot whitelist from shell" - the in-app battery-optimization
REM      dialog (PowerService.requestBatteryOptimizationExemption) remains the
REM      user-facing path for those devices.
REM ============================================================
setlocal enabledelayedexpansion
title SonicShield - prepare device for automation

set "SERIALS="
set "MODE=apply"

:parse
if "%~1"=="" goto :parsed
if /i "%~1"=="-s" (
  set "SERIALS=%~2"
  shift
  shift
  goto :parse
)
if /i "%~1"=="--restore" (
  set "MODE=restore"
  shift
  goto :parse
)
if /i "%~1"=="--verify" (
  set "MODE=verify"
  shift
  goto :parse
)
if /i "%~1"=="--help" (
  echo Usage: prepare_device.bat [-s serial] [--restore] [--verify]
  exit /b 0
)
echo [WARN] unknown argument: %~1
shift
goto :parse

:parsed
call adb start-server >nul 2>&1

REM ---- collect target devices ----
set "COUNT=0"
if not "%SERIALS%"=="" (
  set "TARGETS=%SERIALS%"
) else (
  call adb devices > "%TEMP%\ss_prep_dev.txt" 2>nul
  set "TARGETS="
  for /f "tokens=1,2" %%a in ('type "%TEMP%\ss_prep_dev.txt"') do (
    if /i "%%b"=="device" (
      set "TARGETS=!TARGETS! %%a"
    )
  )
)

for %%s in (%TARGETS%) do (
  echo ============================================================
  echo   device: %%s
  echo ============================================================
  call :prep_one %%s
)

if not exist "%TEMP%\ss_prep_dev.txt" goto :done
del "%TEMP%\ss_prep_dev.txt" >nul 2>&1

:done
echo.
echo [done] mode=%MODE% devices=%COUNT%
if "%MODE%"=="apply" (
  echo   screen will stay on while charging; Doze/standby relaxed for this app.
  echo   revert with: prepare_device.bat --restore
)
exit /b 0

REM ============================================================
REM  per-device preparation
REM ============================================================
:prep_one
set "S=%~1"
set /a COUNT+=1

if "%MODE%"=="verify" goto :verify

REM ---- 1. keep screen awake (the single biggest lock-screen killer) ----
REM    any-charging constant-on: USB=1 AC=2 wireless=4, 3 = USB|AC
call adb -s "%S%" shell svc power stayon true
call adb -s "%S%" shell settings put global stay_on_while_plugged_in 3
REM    2147483647 ms = never (only meaningful when unplugged; belt-and-braces)
call adb -s "%S%" shell settings put system screen_off_timeout 2147483647

if "%MODE%"=="restore" goto :restore_one

REM ---- 2. drop the lockscreen (swipe/keyguard cannot drive automation) ----
REM    fails harmlessly if a secure lock is set (needs user unlock once)
call adb -s "%S%" shell locksettings set-disabled true
call adb -s "%S%" shell wm dismiss-keyguard

REM ---- 3. wake once so a currently-locked device becomes usable NOW ----
call adb -s "%S%" shell input keyevent 224
call adb -s "%S%" shell input keyevent 82

REM ---- 4. Doze whitelist (network + alarm deferral while screen off) ----
call adb -s "%S%" shell dumpsys deviceidle whitelist +com.sonicshield.sonic_shield

REM ---- 5. App Standby bucket: active = no deferred jobs while screen off ----
call adb -s "%S%" shell am set-standby-bucket com.sonicshield.sonic_shield active

REM ---- 6. allow exact alarms (Android 12+ special permission) ----
call adb -s "%S%" shell appops set com.sonicshield.sonic_shield SCHEDULE_EXACT_ALARM allow

echo   [ok] automation prep applied to %S%
goto :eof

:restore_one
REM    undo only the device-global bits we own; app-level whitelist stays
REM    (removing it would re-introduce the original bug; do it by hand if needed:
REM     adb shell dumpsys deviceidle whitelist -com.sonicshield.sonic_shield)
call adb -s "%S%" shell settings put system screen_off_timeout 30000
call adb -s "%S%" shell settings put global stay_on_while_plugged_in 0
call adb -s "%S%" shell svc power stayon false
echo   [ok] screen defaults restored on %S% (app whitelist kept)
goto :eof

:verify
for %%v in (
  "settings get system screen_off_timeout|screen_off_timeout"
  "settings get global stay_on_while_plugged_in|stay_on_while_plugged_in"
  "dumpsys deviceidle whitelist|doze_whitelist"
  "am get-standby-bucket com.sonicshield.sonic_shield|standby_bucket"
  "appops get com.sonicshield.sonic_shield SCHEDULE_EXACT_ALARM|exact_alarm_op"
) do (
  for /f "tokens=1* delims=|" %%c in ("%%~v") do (
    echo   [verify] %%~d:
    call adb -s "%S%" shell %%~c
  )
)
goto :eof
