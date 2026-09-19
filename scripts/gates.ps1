# =====================================================================
# 声盾 SonicShield —— 统一门禁脚本（v1.7，落实 HANDOVER §6.11）
# 用法：
#   .\scripts\gates.ps1                  # 标准门禁：analyze + 功能 + 压测
#   .\scripts\gates.ps1 -WithDevice      # + 设备端全套（检测到模拟器/真机时）
#   .\scripts\gates.ps1 -WithAot         # + AOT 绝对验收（flutter drive --profile）
# 任何一步失败立即退出非零 —— CI 与本地同一套判据。
# =====================================================================
param(
    [switch]$WithDevice,
    [switch]$WithAot
)

$ErrorActionPreference = "Stop"
$fail = 0

function Run-Gate([string]$name, [scriptblock]$cmd, [string]$expect) {
    Write-Host "`n=== 门禁: $name ===" -ForegroundColor Cyan
    & $cmd 2>&1 | ForEach-Object { "$_" } | Tee-Object -Variable out | Select-Object -Last 2
    $joined = ($out -join "`n")
    if ($joined -match $expect) {
        Write-Host "[PASS] $name" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $name （期望匹配: $expect）" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "=== 门禁 1/3: flutter analyze ===" -ForegroundColor Cyan
flutter analyze 2>&1 | Tee-Object -Variable out | Select-Object -Last 1
if (($out -join "`n") -match "No issues found") {
    Write-Host "[PASS] analyze" -ForegroundColor Green
} else {
    Write-Host "[FAIL] analyze" -ForegroundColor Red
    $fail++
}

Write-Host "=== 门禁 2/3: 功能层（--exclude-tags perf）===" -ForegroundColor Cyan
flutter test --exclude-tags perf 2>&1 | ForEach-Object { $_ -replace "`r", "`n" } |
    Tee-Object -Variable out | Select-Object -Last 1
if (($out -join "`n") -match "All tests passed") {
    Write-Host "[PASS] 功能层" -ForegroundColor Green
} else {
    Write-Host "[FAIL] 功能层" -ForegroundColor Red
    $fail++
}

Write-Host "=== 门禁 3/3: 压测层（--tags perf --concurrency=1，必须单并发）===" -ForegroundColor Cyan
flutter test --tags perf --concurrency=1 2>&1 | ForEach-Object { $_ -replace "`r", "`n" } |
    Tee-Object -Variable out | Select-Object -Last 1
if (($out -join "`n") -match "All tests passed") {
    Write-Host "[PASS] 压测层" -ForegroundColor Green
} else {
    Write-Host "[FAIL] 压测层" -ForegroundColor Red
    $fail++
}

# ---------- 设备端（可选）：integration_test/ 不在默认门禁内（BUG-045 洞） ----------
if ($WithDevice) {
    $devices = (adb devices) | Select-String "device`$"
    if ($devices) {
        $dev = ($devices -split "`t")[0]
        Write-Host "=== 门禁 4/5: 设备冒烟（app_smoke_test，3 例）on $dev ===" -ForegroundColor Cyan
        flutter test integration_test/app_smoke_test.dart -d $dev 2>&1 |
            ForEach-Object { $_ -replace "`r", "`n" } | Tee-Object -Variable out |
            Select-Object -Last 1
        if (($out -join "`n") -match "All tests passed") {
            Write-Host "[PASS] 设备冒烟" -ForegroundColor Green
        } else { Write-Host "[FAIL] 设备冒烟" -ForegroundColor Red; $fail++ }

        Write-Host "=== 门禁 5/5: 设备桥接（native_bridge_test，6 例）===" -ForegroundColor Cyan
        flutter test integration_test/native_bridge_test.dart -d $dev 2>&1 |
            ForEach-Object { $_ -replace "`r", "`n" } | Tee-Object -Variable out |
            Select-Object -Last 1
        if (($out -join "`n") -match "All tests passed") {
            Write-Host "[PASS] 设备桥接" -ForegroundColor Green
        } else { Write-Host "[FAIL] 设备桥接" -ForegroundColor Red; $fail++ }
    } else {
        Write-Host "[SKIP] 设备端门禁：adb devices 为空" -ForegroundColor Yellow
    }
}

# ---------- AOT 绝对验收（可选）：flutter drive --profile ----------
if ($WithAot) {
    Write-Host "=== 门禁: AOT 绝对验收（perf_nfr_test，flutter drive --profile）===" -ForegroundColor Cyan
    flutter drive --driver=test_driver/integration_test.dart `
        --target=integration_test/perf_nfr_test.dart --profile -d emulator-5554 |
        Tee-Object -Variable out | Select-Object -Last 1
    if (($out -join "`n") -match "All tests passed") {
        Write-Host "[PASS] AOT 验收" -ForegroundColor Green
    } else { Write-Host "[FAIL] AOT 验收" -ForegroundColor Red; $fail++ }
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "全部门禁通过 ✅" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$fail 项门禁失败 ❌" -ForegroundColor Red
    exit 1
}
