#!/usr/bin/env bash
# 声盾 SonicShield —— 一键工程引导脚本（macOS / Linux / Git Bash）
# 作用与 bootstrap.ps1 相同：补全 flutter create 样板并保留手写文件。
set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
  echo "[X] 未检测到 Flutter SDK，请先阅读 docs/10-构建发布指南.md" >&2
  exit 1
fi

keep=(lib docs test integration_test scripts assets .github \
  android/app/src/main/AndroidManifest.xml android/app/src/main/kotlin \
  android/app/build.gradle.kts android/app/src/main/res/values/strings.xml \
  ios/Runner/Info.plist ios/Runner/AppDelegate.swift \
  pubspec.yaml analysis_options.yaml README.md)

tmp=$(mktemp -d)
mkdir -p "$tmp/keep"
for k in "${keep[@]}"; do
  if [ -e "$k" ]; then mkdir -p "$tmp/keep/$(dirname "$k")"; cp -r "$k" "$tmp/keep/$k"; fi
done

echo "[1/4] flutter create 补全平台样板 ..."
flutter create --project-name sonic_shield --org com.sonicshield --platforms android,ios .

echo "[2/4] 恢复手写文件 ..."
cp -r "$tmp/keep/." .
rm -rf "$tmp"

echo "[3/4] flutter pub get ..."
flutter pub get

echo "[4/4] flutter analyze ..."
flutter analyze

echo "完成。构建：flutter build apk --debug ；模拟器联测：bash scripts/emulator_test.sh"
