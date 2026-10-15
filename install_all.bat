@echo off
REM ============================================================
REM  SonicShield  one-click installer  (all connected devices)
REM  - Wired USB devices + wireless ADB devices
REM  - Installs releases\SonicShield-Android.apk to every device
REM  - Auto-uninstalls an old build if the signature mismatches
REM  - Wireless via releases\wireless.txt: adb connect / adb pair
REM    (Android 11+ first-time pairing) / mdns auto-discovery
REM ============================================================
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion
title SonicShield - install all devices

set "REPO=%~dp0"
set "REL=%REPO%releases"
set "APK=%REL%\SonicShield-Android.apk"
set "IPA=%REL%\SonicShield-iOS.ipa"
set "PKG=com.sonicshield.sonic_shield"
set "DEV=%TEMP%\ss_devices.txt"
set "AOK=0"
set "AFAIL=0"

REM ---- locate adb (PATH first, then known SDK path) ----
REM   NOTE: every adb invocation in this file uses the call prefix on purpose.
REM   If PATH resolves adb to a .cmd/.bat shim instead of an .exe, a non-call
REM   batch invocation transfers control and never returns. Under cmd /c the
REM   child batch exit /b terminates the whole cmd.exe, silently ending this
REM   script with exit code 0. Do not remove the call prefixes.
set "ADB=adb"
where adb >nul 2>&1
if errorlevel 1 if exist "E:\dev\android-sdk\platform-tools\adb.exe" set "ADB=E:\dev\android-sdk\platform-tools\adb.exe"

echo ============================================================
echo   SonicShield : install to ALL connected devices
echo   release dir : %REL%
echo   adb         : %ADB%
echo ============================================================
echo.

if not exist "%APK%" (
  echo [ERROR] Android APK not found:
  echo         %APK%
  echo         Build it first:  flutter build apk --release
  goto :ios
)

REM ---- optional wireless provisioning (releases\wireless.txt) ----
REM   one entry per line; lines starting with # are ignored.
REM   Supported line formats:
REM     <host:port>              -> adb connect <host:port>
REM     pair <host:port> <code>  -> adb pair <host:port> <code>   (Android 11+ first-time pairing)
REM     mdns                     -> auto-discover + connect every _adb-tls-connect._tcp device
if exist "%REL%\wireless.txt" (
  echo [wireless] reading %REL%\wireless.txt ...
  for /f "usebackq eol=# tokens=*" %%w in ("%REL%\wireless.txt") do (
    set "line=%%w"
    if not "!line!"=="" (
      for /f "tokens=1*" %%a in ("!line!") do (
        if /i "%%~a"=="pair" (
          echo   pair %%b
          call "%ADB%" pair %%b >nul 2>&1
        ) else (
          if /i "%%~a"=="mdns" (
            call :mdns_connect
          ) else (
            echo   connect !line!
            call "%ADB%" connect !line! >nul 2>&1
          )
        )
      )
    )
  )
)

call "%ADB%" start-server >nul 2>&1
call "%ADB%" devices >"%DEV%" 2>nul

REM ---- count online devices (status == device) ----
set "COUNT=0"
for /f "tokens=1,2" %%a in ('type "%DEV%"') do if "%%b"=="device" set /a COUNT+=1

REM ---- diagnose devices that are NOT in device state (unauthorized/offline) ----
REM   most common wired-device failure: the USB debugging RSA dialog was never
REM   confirmed, so adb reports unauthorized. Make it visible here, otherwise
REM   "plugged in a new phone but nothing installed" looks like a script bug.
set "DIAG="
for /f "tokens=1,2" %%a in ('type "%DEV%"') do (
  set "S=%%b"
  if /i "!S!"=="unauthorized" set "DIAG=!DIAG! %%a"
  if /i "!S!"=="offline"     set "DIAG=!DIAG! %%a"
)
if not "!DIAG!"=="" (
  echo [Android] ^(!DIAG!^) devices not ready ^(unauthorized/offline^):
  echo           - unauthorized: 手机上确认「允许 USB 调试」弹窗（RSA 指纹）后重跑本脚本;
  echo           - offline     : 换数据线/换 USB 口，或执行 adb kill-server 后重插;
  echo.
)
echo.
echo [Android] devices online: %COUNT%
if %COUNT%==0 (
  echo [Android] no device found. Diagnostics:
  echo           1. 数据线需支持数据传输（非仅充电线）;
  echo           2. 手机 {开发者选项 - USB调试} 已开启;
  echo           3. Windows 设备管理器无黄色感叹号（缺驱动则装厂商 USB 驱动）;
  echo           4. 弹窗「允许 USB 调试」需在手机上点确认;
  echo           5. 无线调试设备见 releases\wireless.txt。
  goto :ios
)

for /f "tokens=1,2" %%a in ('type "%DEV%"') do if "%%b"=="device" (
  set "SER=%%a"
  set "SF=!SER::=_!"
  set "LOG=%REL%\.install_!SF!.log"
  REM 多设备场景显示型号+厂商，便于区分同序列号的近似设备
  set "MODEL="
  for /f "usebackq tokens=*" %%m in (`call "%ADB%" -s "!SER!" shell getprop ro.product.model 2^>nul`) do set "MODEL=%%m"
  for /f "usebackq tokens=*" %%v in (`call "%ADB%" -s "!SER!" shell getprop ro.product.manufacturer 2^>nul`) do set "BRAND=%%v"
  if not "!MODEL!"=="" (
    echo   --^> device !SER! ^(!BRAND! !MODEL!^)
  ) else (
    echo   --^> device !SER!
  )
  call "%ADB%" -s "!SER!" install -r "%APK%" >"!LOG!" 2>&1
  if !errorlevel!==0 (
    echo        [OK] installed
    set /a AOK+=1
  ) else (
    findstr /i /c:"INSTALL_FAILED_UPDATE_INCOMPATIBLE" "!LOG!" >nul 2>&1
    if !errorlevel!==0 (
      echo        [sig mismatch] uninstall old + reinstall ^(local data cleared^) ...
      call "%ADB%" -s "!SER!" uninstall %PKG% >nul 2>&1
      call "%ADB%" -s "!SER!" install "%APK%" >"!LOG!" 2>&1
      if !errorlevel!==0 (
        echo        [OK] reinstalled
        set /a AOK+=1
      ) else (
        echo        [FAIL] see !LOG!
        set /a AFAIL+=1
      )
    ) else (
      findstr /i /c:"INSTALL_FAILED_USER_RESTRICTED" "!LOG!" >nul 2>&1
      if !errorlevel!==0 (
        echo        [BLOCKED] MIUI: enable "Install via USB" in Developer options
      ) else (
        echo        [FAIL] see !LOG!
      )
      set /a AFAIL+=1
    )
  )
)
if exist "%DEV%" del "%DEV%" >nul 2>&1
echo [Android] success !AOK! / failed !AFAIL!

:ios
echo.
echo [iOS] checking %IPA% ...
if not exist "%IPA%" (
  echo [iOS] no IPA, skipped.
  goto :done
)
where ideviceinstaller >nul 2>&1
if errorlevel 1 (
  echo [iOS] ideviceinstaller not found; cannot sideload from Windows.
  echo       note: current IPA is UNSIGNED - re-sign before installing.
  echo       ipa path: %IPA%
) else (
  echo [iOS] installing via ideviceinstaller ...
  ideviceinstaller -i "%IPA%"
)

:done
echo.
echo ============================================================
echo   DONE.  Android: success !AOK! / failed !AFAIL!
echo ============================================================
set "FINAL=!AFAIL!"
endlocal & set "FINAL=%FINAL%"

REM ---- keep the window open only for interactive double-click runs ----
REM (when launched by explorer.exe the command line contains the script path;
REM  when launched by a runner/CI it does not, so we skip the pause and exit)
echo %cmdcmdline% | find /i "%~f0" >nul
if not errorlevel 1 pause
exit /b %FINAL%

REM ---- subroutine: mDNS wireless auto-discovery + connect ----
REM   Invoked via "call :mdns_connect" from a "mdns" directive line in wireless.txt.
REM   TAB is the delimiter: device names may contain spaces (e.g. "adb-XXXX (2)"),
REM   and "adb mdns services" prints TAB-separated fields (parsing verified CRLF-safe).
:mdns_connect
echo   [mdns] discovering wireless devices (adb mdns services) ...
for /f "tokens=1,2,3 delims=	" %%a in ('call "%ADB%" mdns services 2^>nul') do (
  if "%%b"=="_adb-tls-connect._tcp" (
    echo     found %%a -^> connect %%c
    call "%ADB%" connect "%%c" >nul 2>&1
  )
)
goto :eof
