# =====================================================================
# 声盾 SonicShield —— 一键工程引导脚本（Windows PowerShell）
# 作用：本仓库手写了全部业务代码与平台配置；本脚本用 flutter create
#       补全官方样板（gradle wrapper 二进制、xcode 工程等），并确保
#       不覆盖我们已有的 lib/、android/ 关键文件与文档。
# 用法：在仓库根目录执行  .\bootstrap.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Host "[X] 未检测到 Flutter SDK。请先按 docs/10-构建发布指南.md 安装 Flutter 3.24+ 并配置 Android SDK。" -ForegroundColor Red
  exit 1
}

# 备份手写的关键文件，flutter create 之后恢复（防止被样板覆盖）
$keep = @(
  "lib", "docs", "test", "integration_test", "scripts", "assets", ".github",
  "android/app/src/main/AndroidManifest.xml",
  "android/app/src/main/kotlin",
  "android/app/build.gradle.kts",
  "android/app/src/main/res/values/strings.xml",
  "ios/Runner/Info.plist",
  "ios/Runner/AppDelegate.swift",
  "pubspec.yaml", "analysis_options.yaml", "README.md"
)
$tmp = Join-Path $env:TEMP ("sonicshield_keep_" + (Get-Date -Format "yyyyMMddHHmmss"))
New-Item -ItemType Directory -Path $tmp | Out-Null
foreach ($k in $keep) {
  if (Test-Path $k) {
    $dest = Join-Path $tmp $k
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item -Recurse -Force $k $dest
  }
}

Write-Host "[1/4] flutter create 补全平台样板 ..."
flutter create --project-name sonic_shield --org com.sonicshield --platforms android,ios .

Write-Host "[2/4] 恢复手写文件 ..."
foreach ($k in $keep) {
  $src = Join-Path $tmp $k
  if (Test-Path $src) { Copy-Item -Recurse -Force $src $k }
}
Remove-Item -Recurse -Force $tmp

Write-Host "[3/4] flutter pub get ..."
flutter pub get

Write-Host "[4/4] flutter analyze ..."
flutter analyze

Write-Host ""
Write-Host "完成。构建调试包：flutter build apk --debug" -ForegroundColor Green
Write-Host "安装到模拟器：scripts\emulator_test.ps1" -ForegroundColor Green
