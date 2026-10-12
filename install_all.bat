@echo off
REM ============================================================
REM  SonicShield  one-click installer  (all connected devices)
REM  - Wired USB devices + wireless ADB devices
REM  - Installs releases\SonicShield-Android.apk to every device
REM  - Auto-uninstalls an old build if the signature mismatches
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

REM ---- optional wireless reconnect list (releases\wireless.txt) ----
REM   one "host:port" per line; lines starting with # are ignored
if exist "%REL%\wireless.txt" (
  echo [wireless] reading %REL%\wireless.txt ...
  for /f "usebackq eol=# tokens=*" %%w in ("%REL%\wireless.txt") do (
    set "line=%%w"
    if not "!line!"=="" (
      echo   connect !line!
      "%ADB%" connect !line! >nul 2>&1
    )
  )
)

"%ADB%" start-server >nul 2>&1
"%ADB%" devices >"%DEV%" 2>nul

REM ---- count online devices (status == device) ----
set "COUNT=0"
for /f "tokens=1,2" %%a in ('type "%DEV%"') do if "%%b"=="device" set /a COUNT+=1
echo.
echo [Android] devices online: %COUNT%
if %COUNT%==0 (
  echo [Android] no device found. Check USB debugging / adb connect.
  goto :ios
)

for /f "tokens=1,2" %%a in ('type "%DEV%"') do if "%%b"=="device" (
  set "SER=%%a"
  set "SF=!SER::=_!"
  set "LOG=%REL%\.install_!SF!.log"
  echo   --^> device !SER!
  "%ADB%" -s "!SER!" install -r "%APK%" >"!LOG!" 2>&1
  if !errorlevel!==0 (
    echo        [OK] installed
    set /a AOK+=1
  ) else (
    findstr /i /c:"INSTALL_FAILED_UPDATE_INCOMPATIBLE" "!LOG!" >nul 2>&1
    if !errorlevel!==0 (
      echo        [sig mismatch] uninstall old + reinstall ^(local data cleared^) ...
      "%ADB%" -s "!SER!" uninstall %PKG% >nul 2>&1
      "%ADB%" -s "!SER!" install "%APK%" >"!LOG!" 2>&1
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
