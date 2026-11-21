# Run this ONCE from an elevated PowerShell (Run as Administrator).
# Purpose: re-enumerate the Huawei ADB USB node when adb sees VID_12D1/PID_107E
# in Device Manager but bulk endpoint reads fail with Error 5 (access denied).
$ErrorActionPreference = 'Continue'

$principal = New-Object Security.Principal.WindowsPrincipal(
  [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'ADMIN REQUIRED: right-click PowerShell -> Run as Administrator, then rerun this script.'
}

$adb = 'E:\dev\android-sdk\platform-tools\adb.exe'
if (Test-Path $adb) { & $adb kill-server 2>&1 | Out-Null }

$targets = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
  Where-Object {
    $_.InstanceId -match 'VID_12D1' -and
    ($_.FriendlyName -match 'ADB' -or $_.InstanceId -match 'MI_01')
  }

if (-not $targets) {
  Write-Output 'NO_HUAWEI_ADB_NODE: plug the phone in USB file-transfer mode with USB debugging on.'
} else {
  foreach ($d in $targets) {
    Write-Output ("REMOVE " + $d.InstanceId)
    pnputil /remove-device $d.InstanceId 2>&1 | Out-String | Write-Output
  }
  pnputil /scan-devices 2>&1 | Out-String | Write-Output
}

Write-Output 'NEXT: unplug and replug USB; on the phone choose File Transfer (MTP) and tap Allow USB debugging.'
Write-Output 'THEN: adb kill-server; adb devices -l   (expect a serial, not an empty list)'
