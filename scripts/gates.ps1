﻿# =====================================================================
# 声盾 SonicShield —— 统一门禁脚本（v1.9.0-alpha 同步版，落实 HANDOVER §6.11）
#
# ⚠️ 本文件与 scripts/gates.sh 必须是**同一套判据**。历史上 .ps1 停在「3 步、
#    无覆盖率 ratchet」而 .sh 已到 4 步，结果走 .ps1 的路线**完全不受 ratchet 约束**
#    —— 覆盖率掉多少都不红（2026-09-24 审计 P0-T-03 实测：.ps1 停在 v1.7，
#    既无 ratchet 也无「环境阻塞 RC=3」语义）。现在补齐第 4 步；
#    同时 CI（.github/workflows/ci.yml）用 `flutter analyze --fatal-infos`，
#    比本脚本的 grep 判据更严 —— **三条路线（local .sh / local .ps1 / CI）任一条红即红**。
#
# 用法：
#   .\scripts\gates.ps1                  # analyze + 功能(+覆盖率) + 压测 + 覆盖率ratchet
#   .\scripts\gates.ps1 -WithDevice      # + 设备端全套（检测到模拟器/真机时）
#   .\scripts\gates.ps1 -WithAot         # + AOT 绝对验收（flutter drive --profile）
#   $env:COVERAGE_MIN = '97.7'           # 可覆盖 ratchet 阈值（默认见下，**必须与 gates.sh 同值**）
#   $env:MIN_COVERED  = '9371'           # 可覆盖"绝对覆盖行"下限（同上）
#   第 45 轮（2026-09-28）：90.4 / 8680 → 92.6 / 8892（可测面 92.82% / 8898 分子 − 6 行余量）。
#   $env:SKIP_COVERAGE = '1'             # 只在排查覆盖率工具本身时用
# 任何一步失败立即退出非零 —— CI 与本地同一套判据。
# ⚠️ 覆盖率阈值是 **ratchet 地板，只升不降，不是目标值**：
#    涨了就同步抬高；跌了必须补测试，或**有意识地下调并在 docs/12 写明理由**。
# =====================================================================
param(
    [switch]$WithDevice,
    [switch]$WithAot
)

$ErrorActionPreference = "Stop"
$fail = 0
# 环境阻塞（未执行 ≠ 失败）—— 与 gates.sh 的 BLOCKED/RC=3 语义对齐。
$blocked = $false

# 功能层"红"的**定性**：Dart VM 自身因宿主内存/线程耗尽而崩 ≠ 代码回归。
# 2026-09-28 实测：`--coverage` 全量跑在 01:28 处整进程崩，74 例 "did not complete"，
# 日志里一条断言失败都没有，只有 vm/zone.cc `Out of memory.` 与
# vm/os_thread.cc `Could not start thread DartWorker`（三个 pid 同时崩）。
# 判据与 gates.sh 的 is_vm_resource_crash 同源 —— 两条入口不允许漂移。
function Test-VmResourceCrash([string]$text) {
    if ($text -match 'error: Out of memory\.') { return $true }
    if ($text -match 'Could not start thread DartWorker') { return $true }
    if ($text -match 'Crash occurred when compiling') { return $true }
    return $false
}

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

Write-Host "=== 门禁 1/4: flutter analyze ===" -ForegroundColor Cyan
flutter analyze 2>&1 | Tee-Object -Variable out | Select-Object -Last 1
if (($out -join "`n") -match "No issues found") {
    Write-Host "[PASS] analyze" -ForegroundColor Green
} else {
    Write-Host "[FAIL] analyze" -ForegroundColor Red
    # 只 tail -1 会得到一句 "N issues found." —— 是哪一条被吞掉了。失败必须留证据。
    ($out | Select-String -Pattern '^\s*(info|warning|error)\s*-' | Select-Object -First 20) |
        ForEach-Object { Write-Host "  $_" }
    $fail++
}

Write-Host "=== 门禁 2/4: 功能层（--exclude-tags perf，顺带产出 coverage/lcov.info）===" -ForegroundColor Cyan
# 功能层**顺带产出**覆盖率（第 4 步的 ratchet 据此判定），不额外多跑一遍测试。
# ⚠️ 并发**只在"撞上 VM 资源耗尽"的重跑里**下调：首次仍用默认并发，
#    这样"正常路径"的覆盖率口径与历史各轮逐字一致。
$covFlag = @()
if ($env:SKIP_COVERAGE -ne '1') { $covFlag = @('--coverage') }
$funcConc = @()
flutter test --exclude-tags perf @covFlag @funcConc 2>&1 | ForEach-Object { $_ -replace "`r", "`n" } |
    Tee-Object -Variable out | Select-Object -Last 1
$joined = ($out -join "`n")
if ($joined -match "All tests passed") {
    Write-Host "[PASS] 功能层" -ForegroundColor Green
} elseif (Test-VmResourceCrash $joined) {
    Write-Host "[?] 功能层首次撞上 Dart VM 资源耗尽（无任何断言失败）→ 降并发重跑确认…" -ForegroundColor Yellow
    $retryConc = if ($env:FUNC_RETRY_CONC) { $env:FUNC_RETRY_CONC } else { '4' }
    if ($env:FUNC_RETRY -eq '0') {
        Write-Host "[FAIL] 功能层（FUNC_RETRY=0，未降并发重跑确认）" -ForegroundColor Red
        $fail++
    } else {
        $funcConc = @("--concurrency=$retryConc")
        flutter test --exclude-tags perf @covFlag @funcConc 2>&1 | ForEach-Object { $_ -replace "`r", "`n" } |
            Tee-Object -Variable out2 | Select-Object -Last 1
        $joined2 = ($out2 -join "`n")
        if ($joined2 -match "All tests passed") {
            Write-Host "[PASS] 功能层（降并发重跑确认，并发=$retryConc）" -ForegroundColor Green
        } elseif (Test-VmResourceCrash $joined2) {
            Write-Host "[BLOCKED] 功能层：连续两次 Dart VM 资源耗尽 —— 不是代码回归，也不是通过" -ForegroundColor Yellow
            $blocked = $true
        } else {
            Write-Host "[FAIL] 功能层（重跑未过，且不是 VM 资源耗尽 → 真回归）" -ForegroundColor Red
            $fail++
        }
    }
} else {
    Write-Host "[FAIL] 功能层" -ForegroundColor Red
    ($out | Select-String -Pattern '\[E\]|Expected:|Actual:' | Select-Object -First 6) |
        ForEach-Object { Write-Host "  $_" }
    $fail++
}

Write-Host "=== 门禁 3/4: 压测层（--tags perf --concurrency=1，必须单并发）===" -ForegroundColor Cyan
flutter test --tags perf --concurrency=1 2>&1 | ForEach-Object { $_ -replace "`r", "`n" } |
    Tee-Object -Variable out | Select-Object -Last 1
if (($out -join "`n") -match "All tests passed") {
    Write-Host "[PASS] 压测层" -ForegroundColor Green
} else {
    Write-Host "[FAIL] 压测层" -ForegroundColor Red
    $fail++
}

# ---------- 门禁 4/4：覆盖率 ratchet（与 gates.sh 同源同阈值） ----------
# 语义是 ratchet（只降不升），不是"目标值"。
#
# ⚠️ 下面两个默认值**必须与 `scripts/gates.sh` 逐字一致** ——
#    两条入口（bash / PowerShell）判据不一致时，走 .ps1 的那条就成了**更松的门**，
#    覆盖率回归可以静默通过。本项目已发生过两次漂移：
#      · 2026-09-25 之前：.ps1 停在 3 步（**整个第 4 步缺失**）；
#      · 2026-09-26 第 36 轮实测：第 4 步已补，但阈值停在 **72.5**（第 33 轮值），
#        且**完全没有 `MIN_COVERED`**（第 34 轮给 gates.sh 加的"分母稀释"防线在 .ps1 上缺失）。
#    该一致性现在由 `test/gate_entrypoint_consistency_test.dart` **机器锁定**。
if ($env:SKIP_COVERAGE -ne '1') {
    $covMin = if ($env:COVERAGE_MIN) { $env:COVERAGE_MIN } else { '97.7' }
    $minCov = if ($env:MIN_COVERED) { $env:MIN_COVERED } else { '9371' }
    Write-Host "=== 门禁 4/4: 覆盖率 ratchet（COVERAGE_MIN=$covMin% / MIN_COVERED=$minCov）===" -ForegroundColor Cyan
    if (-not (Test-Path 'coverage/lcov.info')) {
        # 没有产物**不等于**通过 —— 与"设备没接上"同源（未执行 ≠ 成功）。
        Write-Host "[BLOCKED] 覆盖率：找不到 coverage/lcov.info（功能层可能没跑成）" -ForegroundColor Yellow
        $blocked = $true
    } else {
        $out = dart run tool/coverage_report.dart "--gate=$covMin" "--min-covered=$minCov" 2>&1 |
            ForEach-Object { $_ -replace "`r", "`n" }
        ($out | Select-String -Pattern '全局|可测面|门禁|不可信' | Select-Object -First 6) |
            ForEach-Object { Write-Host "  $_" }
        $joined = ($out -join "`n")
        if ($joined -match "门禁通过") {
            Write-Host "[PASS] 覆盖率 ratchet" -ForegroundColor Green
        } elseif ($joined -match "门禁未过") {
            Write-Host "[FAIL] 覆盖率 ratchet：跌破 $covMin%" -ForegroundColor Red
            Write-Host "  ⇒ 两条路：① 补测试把它推回去；② **有意识地**下调 COVERAGE_MIN，"
            Write-Host "     并在 docs/12 本轮章节写明理由（下调留痕，否则 ratchet 失效）。"
            $fail++
        } else {
            # 工具自报"报告不可信"（分母不完整/豁免幽灵文件/白名单失效）——
            # 这类问题危险之处是**它会让数字变好看**，必须当失败处理。
            Write-Host "[FAIL] 覆盖率报告不可信 —— 先修工具报的问题" -ForegroundColor Red
            $fail++
        }
    }
}

# ---------- 设备端（可选）：integration_test/ 不在默认门禁内（BUG-045 洞） ----------
if ($WithDevice) {
    $devices = (adb devices) | Select-String "device`$"
    if ($devices) {
        $dev = ($devices -split "`t")[0]
        Write-Host "=== 门禁: 设备冒烟（app_smoke_test，3 例）on $dev ===" -ForegroundColor Cyan
        flutter test integration_test/app_smoke_test.dart -d $dev 2>&1 |
            ForEach-Object { $_ -replace "`r", "`n" } | Tee-Object -Variable out |
            Select-Object -Last 1
        if (($out -join "`n") -match "All tests passed") {
            Write-Host "[PASS] 设备冒烟" -ForegroundColor Green
        } else { Write-Host "[FAIL] 设备冒烟" -ForegroundColor Red; $fail++ }

        Write-Host "=== 门禁: 设备桥接（native_bridge_test，6 例）===" -ForegroundColor Cyan
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
if ($fail -eq 0 -and -not $blocked) {
    Write-Host "全部门禁通过 ✅" -ForegroundColor Green
    exit 0
} elseif ($fail -eq 0) {
    # 与 gates.sh 同语义：代码全绿但有环境阻塞 → RC=3（未执行，不是失败）。
    Write-Host "代码门禁全绿 ✅，但存在**环境阻塞**（未执行，不是失败）⚠️" -ForegroundColor Yellow
    exit 3
} else {
    Write-Host "$fail 项门禁失败 ❌" -ForegroundColor Red
    exit 1
}
