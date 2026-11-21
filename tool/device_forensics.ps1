param(
  [string]$Device = '',
  [string]$Connect = '',
  [string]$OutDir = ''
)

# One-shot, read-only forensics for docs/66. Pure ASCII on purpose:
# PowerShell 5.1 parses BOM-less non-ASCII .ps1 as GBK and breaks syntax.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$adbCandidates = @(
  (Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'),
  'E:\dev\android-sdk\platform-tools\adb.exe',
  'adb.exe'
)
$adbBin = $null
foreach ($c in $adbCandidates) {
  if ($null -eq $c) { continue }
  if (Get-Command $c -ErrorAction SilentlyContinue) { $adbBin = $c; break }
}
if ($null -eq $adbBin) { throw 'adb.exe not found. Install Android platform-tools.' }

# Wireless debugging: adb server does not survive across shells, so connect and
# collect in ONE process. Pair with `adb pair IP:pairPort CODE` first if needed.
if (-not [string]::IsNullOrWhiteSpace($Connect)) {
  & $adbBin kill-server 2>&1 | Out-Null
  & $adbBin start-server 2>&1 | Out-Null
  $connectOut = & $adbBin connect $Connect 2>&1 | Out-String
  $Device = $Connect
  Write-Output $connectOut
  if ($connectOut -notmatch 'connected to') {
    throw "adb connect failed: $connectOut"
  }
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $root ('evidence\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

function Invoke-Adb {
  param([string[]]$Args)
  if ([string]::IsNullOrWhiteSpace($Device)) {
    & $adbBin @Args 2>&1 | Out-String
  } else {
    & $adbBin -s $Device @Args 2>&1 | Out-String
  }
}

$log = Join-Path $OutDir 'forensics.log'
"START $(Get-Date -Format o)" | Out-File $log -Encoding utf8
"ADB=$adbBin DEVICE=$Device" | Out-File $log -Append -Encoding utf8

Invoke-Adb @('devices') | Out-File $log -Append -Encoding utf8
Invoke-Adb @('shell','getprop','ro.product.model') | Out-File (Join-Path $OutDir 'device-model.txt') -Encoding utf8
Invoke-Adb @('shell','getprop','ro.build.version.release') | Out-File (Join-Path $OutDir 'android-version.txt') -Encoding utf8
Invoke-Adb @('shell','dumpsys','package','com.sonicshield.sonic_shield') | Out-File (Join-Path $OutDir 'package.txt') -Encoding utf8

# V1: DND state
Invoke-Adb @('shell','settings','get','global','zen_mode') | Out-File (Join-Path $OutDir 'V1-zen-mode.txt') -Encoding utf8

# V3: vibrator usage (collect after reproducing the vibration task)
Invoke-Adb @('shell','dumpsys','vibrator') | Out-File (Join-Path $OutDir 'V3-vibrator.txt') -Encoding utf8

# A1/A3: audio focus + doze
Invoke-Adb @('shell','dumpsys','audio') | Out-File (Join-Path $OutDir 'A1-audio.txt') -Encoding utf8
Invoke-Adb @('shell','dumpsys','deviceidle') | Out-File (Join-Path $OutDir 'A3-deviceidle.txt') -Encoding utf8

# C4: CPU + frame stats
Invoke-Adb @('shell','top','-n','1') | Out-File (Join-Path $OutDir 'C4-top.txt') -Encoding utf8
Invoke-Adb @('shell','dumpsys','gfxinfo','com.sonicshield.sonic_shield') | Out-File (Join-Path $OutDir 'C4-gfxinfo.txt') -Encoding utf8

# S2: screen cast foreground service
Invoke-Adb @('shell','dumpsys','activity','services') | Out-File (Join-Path $OutDir 'S2-services.txt') -Encoding utf8

# Clear logcat so the operator can reproduce each symptom from a clean baseline.
Invoke-Adb @('logcat','-c') | Out-Null
"LOGCAT_CLEARED - reproduce each symptom now, then run:" | Out-File $log -Append -Encoding utf8
"  adb -s $Device logcat -s flutter:V NativeBridge:V AudioFocus:V webrtc:V ScreenCast:V | tee $(Join-Path $OutDir 'logcat.txt')" | Out-File $log -Append -Encoding utf8
"END $(Get-Date -Format o)" | Out-File $log -Append -Encoding utf8

Write-Output "EVIDENCE_DIR=$OutDir"
Get-ChildItem $OutDir | Select-Object Name,Length | Format-Table -AutoSize | Out-String
