@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title SonicShield 涓€閿畨瑁咃紙鏈夌嚎 + 鏃犵嚎锛?echo ============================================================
echo   SonicShield 涓€閿畨瑁咃細鎵€鏈夊凡杩炴帴璁惧锛堟湁绾?/ 鏃犵嚎锛?echo   鍙戝竷鍖呭浐瀹氫綅缃細%~dp0releases\
echo ============================================================

REM ===== 璺緞閰嶇疆锛堝闇€淇敼锛屽彧鏀硅繖閲岋級 =====
set "REPO=%~dp0"
set "REL=%REPO%releases"
set "APK=%REL%\SonicShield-Android.apk"
set "IPA=%REL%\SonicShield-iOS.ipa"
set "PKG=com.sonicshield.sonic_shield"
set "ADB=adb"
where adb >nul 2>&1 || set "ADB=E:\dev\android-sdk\platform-tools\adb.exe"

REM ===== 鏃犵嚎璁惧锛堝彲閫夛級锛歳eleases\wireless.txt 姣忚涓€涓?host:port =====
REM 渚嬶細192.168.1.50:5555   锛? 寮€澶翠负娉ㄩ噴锛屼細琚拷鐣ワ級
if exist "%REL%\wireless.txt" (
  echo [鏃犵嚎] 璇诲彇 %REL%\wireless.txt 骞跺皾璇?adb connect ...
  for /f "usebackq tokens=*" %%w in ("%REL%\wireless.txt") do (
    set "line=%%w"
    if not "!line!"=="" if not "!line:~0,1!"=="#" (
      echo   connect !line!
      "%ADB%" connect !line! >nul 2>&1
    )
  )
)

"%ADB%" start-server >nul 2>&1
"%ADB%" devices >nul 2>&1
if not !errorlevel!==0 (
  echo [Android] 閿欒锛歛db 涓嶅彲鐢紙%ADB%锛夈€傝纭 Android SDK 璺緞锛屾垨鎶?adb 鍔犲叆 PATH銆?  goto :ios
)

REM ===== Android锛氬畨瑁呭埌鎵€鏈夊湪绾胯澶?=====
set "AOK=0" & set "AFAIL=0"
if not exist "%APK%" (
  echo [Android] 閿欒锛氭壘涓嶅埌 %APK%
  goto :ios
)
echo.
echo [Android] 瀹夎 %APK% 鍒版墍鏈夊湪绾胯澶?...
for /f "tokens=1" %%d in ('"%ADB%" devices 2^>nul ^| findstr /r "device$"') do (
  set "SER=%%d"
  set "SF=!SER::=_!"
  set "LOG=%REL%\.android_!SF!.log"
  echo   -^> 璁惧 %%d
  "%ADB%" install -r -d "%APK%" >"!LOG!" 2>&1
  if !errorlevel!==0 (
    echo       [OK] 瀹夎鎴愬姛
    set /a AOK+=1
  ) else (
    findstr /i /c:"INSTALL_FAILED_UPDATE_INCOMPATIBLE" "!LOG!" >nul
    if !errorlevel!==0 (
      echo       [绛惧悕涓嶄竴鑷碷 鍏堝嵏杞芥棫鍖呭啀瀹夎锛堜細娓呴櫎搴旂敤鏁版嵁锛?..
      "%ADB%" uninstall %PKG% >nul 2>&1
      "%ADB%" install "%APK%" >"!LOG!" 2>&1
      if !errorlevel!==0 ( echo       [OK] 閲嶈浇瀹夎鎴愬姛 & set /a AOK+=1 ) else ( echo       [澶辫触] 瑙?!LOG! & set /a AFAIL+=1 )
    ) else (
      echo       [澶辫触] 瑙?!LOG!
      set /a AFAIL+=1
    )
  )
)
echo [Android] 鎴愬姛 !AOK! / 澶辫触 !AFAIL!

:ios
echo.
echo [iOS] 妫€鏌?%IPA% ...
if not exist "%IPA%" (
  echo [iOS] 鏈壘鍒?IPA锛岃烦杩囥€?  goto :done
)
where ideviceinstaller >nul 2>&1
if !errorlevel!==0 (
  echo [iOS] 浣跨敤 ideviceinstaller 瀹夎 ...
  ideviceinstaller -i "%IPA%"
) else (
  echo [iOS] 鏈娴嬪埌 ideviceinstaller锛圵indows 鐪熸満瀹夎闇€ libimobiledevice锛夈€?  echo        娉ㄦ剰锛氬綋鍓?IPA 涓?CI 鏈鍚嶅寘锛岀湡鏈哄畨瑁呭墠闇€鍏堥噸绛惧悕
  echo        锛堝紑鍙?/ 浼佷笟璇佷功锛夛紝鎴栫敤 Mac 鐨?xcrun devicectl / ios-deploy 瀹夎銆?  echo        宸插浐瀹氬湪锛?IPA%
)

:done
echo.
echo ============================================================
echo   瀹屾垚銆侫ndroid 鎴愬姛 !AOK! / 澶辫触 !AFAIL!
echo ============================================================