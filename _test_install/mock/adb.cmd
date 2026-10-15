@echo off
REM ============================================================
REM  mock adb for install_all.bat verification (2026-10-15)
REM  scenario via env SS_MOCK_SCENARIO:
REM    mixed (default) : 1 ready / 1 unauthorized / 1 offline
REM    none            : 0 ready devices (all unauthorized/offline)
REM    sigfail         : install returns signature-mismatch failure
REM    mdns            : mdns services returns two connectable devices
REM ============================================================
if "%SS_MOCK_SCENARIO%"=="" set "SS_MOCK_SCENARIO=mixed"

if "%1"=="start-server" exit /b 0
if "%1"=="kill-server" exit /b 0
if "%1"=="devices" (
  echo List of devices attached
  if "%SS_MOCK_SCENARIO%"=="none" (
    echo DDDD4444	unauthorized
    echo EEEE5555	offline
  ) else (
    echo AAAA1111	device
    echo BBBB2222	unauthorized
    echo CCCC3333	offline
  )
  exit /b 0
)
if "%1"=="mdns" (
  if "%SS_MOCK_SCENARIO%"=="mdns" (
    echo adb-XXYY12	_adb-tls-connect._tcp	5555
    echo adb-ZZWW34	_adb-tls-connect._tcp	5556
  )
  exit /b 0
)
if "%1"=="-s" (
  if "%3"=="shell" (
    if "%5"=="ro.product.model" echo Pixel7Pro
    if "%5"=="ro.product.manufacturer" echo Google
    exit /b 0
  )
  if "%3"=="install" (
    if "%SS_MOCK_SCENARIO%"=="sigfail" (
      echo Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package com.sonicshield.sonic_shield signatures do not match previously installed version; ignoring!]
      exit /b 1
    )
    echo Success
    exit /b 0
  )
  if "%3"=="uninstall" (
    echo Success
    exit /b 0
  )
  exit /b 0
)
exit /b 0
