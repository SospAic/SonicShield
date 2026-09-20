#!/usr/bin/env bash
# =====================================================================
# 声盾 SonicShield —— 把**可启动的真包**装到设备上
# （修复"打开应用就黑屏 / 一直停在闪屏"）
#
# 【为什么需要它】
#   `flutter test integration_test/…` 会把
#     build/app/outputs/flutter-apk/app-debug.apk
#   **覆盖成"测试入口包"** —— 那个 APK 的 Dart 入口是
#   `integration_test/xxx_test.dart`（在等 driver 连接）。
#   它装得上、跑测试也正常，但从桌面启动会
#   **永久停在闪屏/黑屏，且没有任何报错**（不建 DB、不连 broker）。
#   2026-09-20 实测：跑完设备层门禁后手机上留下的正是这个包
#   （144,591,645 B）。
#
# 【判据（本脚本自带，`--check-only` 可单独用）】
#   解出 APK 里的 `assets/flutter_assets/kernel_blob.bin` 后：
#     ├─ 含 `main.dart` 且不含 `integration_test/`
#     │     → **真包**（可启动；实测 ~245,669,568 B ≈ 245MB）
#     └─ 含 `integration_test/` 且不含 `main.dart`
#           → **测试入口包**（不可启动；实测 ~144,591,645 B ≈ 144MB）
#   ⚠️ 体积只是**旁证**，别只凭体积判断 —— 见 `apk_identity()` 的注释。
#
# 【用法】
#   bash scripts/install_app.sh              # 构建真包 + 覆盖安装 + 启动验证
#   bash scripts/install_app.sh --check-only # 只检查现有 APK 身份（不构建不安装）
#   DEV=<serial> bash scripts/install_app.sh # 指定设备
#   APK=<path> bash scripts/install_app.sh --check-only   # 检查任意 APK（可覆盖）
#
# 退出码：0=成功；1=失败；3=没有可用设备（环境阻塞，非代码问题）
# =====================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="${APK:-$ROOT/build/app/outputs/flutter-apk/app-debug.apk}"
APP_ID="${APP_ID:-com.sonicshield.sonic_shield}"
LOG="${GATE_LOG_DIR:-/tmp}/build_real_apk.log"
MODE="${1:-}"

# APK 身份判定：解 kernel_blob.bin 看 Dart 入口是不是**测试**。
#
# 判据（实测校准，2026-09-20）：
#   `integration_test/` 只可能出现在 dev_dependency 被编译进 kernel 时
#   → **命中即"测试入口包"**（真实 `flutter build apk` 命中数恒为 0）。
#   真包的特征串是 **`lib/main.dart`**（实测 `file:///E:/SonicShield/lib/main.dart`）。
#
# ⚠️ **不要用宽泛的 `main\.dart`**：真包与测试包里都含框架样板串
#    `file:///path/to/main.dart` 与 `http://localhost:8080/main.dart`
#    → 两边都命中，判据失效（本脚本第一版就是这么错的，靠"证伪"发现）。
# ⚠️ 体积只是**旁证**：不同 ABI / 增量构建都会让体积漂移，别只凭体积判断。
apk_identity() {  # $1=apk 路径 → real | test | unknown | missing
  local apk="$1" tmp kb n_itest n_main
  [ -f "$apk" ] || { echo missing; return; }
  tmp=$(mktemp -d)
  if ! unzip -o -q "$apk" "assets/flutter_assets/kernel_blob.bin" -d "$tmp" 2>/dev/null; then
    rm -rf "$tmp"; echo unknown; return
  fi
  kb="$tmp/assets/flutter_assets/kernel_blob.bin"
  if [ ! -f "$kb" ]; then rm -rf "$tmp"; echo unknown; return; fi
  n_itest=$(grep -a -c "integration_test/" "$kb" || true)
  n_main=$(grep -a -c "lib/main\.dart" "$kb" || true)
  rm -rf "$tmp"
  if [ "${n_itest:-0}" -gt 0 ]; then echo test
  elif [ "${n_main:-0}" -gt 0 ]; then echo real
  else echo unknown; fi
}

# 供 --check-only 打印判据命中数（便于人工复核，而不是只给一个结论）。
apk_markers() {  # $1=apk 路径 → "integration_test/<n> lib/main.dart=<n>"
  local apk="$1" tmp kb n_itest n_main
  tmp=$(mktemp -d)
  unzip -o -q "$apk" "assets/flutter_assets/kernel_blob.bin" -d "$tmp" 2>/dev/null || { rm -rf "$tmp"; echo "（无法解出 kernel_blob）"; return; }
  kb="$tmp/assets/flutter_assets/kernel_blob.bin"
  n_itest=$(grep -a -c "integration_test/" "$kb" || true)
  n_main=$(grep -a -c "lib/main\.dart" "$kb" || true)
  rm -rf "$tmp"
  echo "integration_test/ 命中 ${n_itest:-0} 处 · lib/main.dart 命中 ${n_main:-0} 处"
}

apk_path_win() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$APK"; else printf '%s' "$APK"; fi
}

pick_device() {
  if [ -n "${DEV:-}" ]; then echo "$DEV"; return; fi
  local emu
  emu=$(MSYS_NO_PATHCONV=1 adb devices 2>/dev/null | awk '/^emulator-[0-9]+[ \t]+device$/{print $1}' | head -1)
  if [ -n "$emu" ]; then echo "$emu"; return; fi
  MSYS_NO_PATHCONV=1 adb devices 2>/dev/null | awk '/[ \t]device$/{print $1}' | head -1
}

# ---------- --check-only：只判定现有产物 ----------
if [ "$MODE" = "--check-only" ]; then
  id=$(apk_identity "$APK")
  echo "APK   : $APK"
  ls -l "$APK" 2>/dev/null || echo "  （不存在）"
  echo "判据  : $(apk_markers "$APK")"
  echo "身份  : $id"
  case "$id" in
    real) echo "✅ 可启动的真包"; exit 0 ;;
    test) echo "❌ 测试入口包 —— 从桌面启动会永久黑屏/停在闪屏"; exit 1 ;;
    *)    echo "❓ 无法判定（产物缺失或结构异常）"; exit 1 ;;
  esac
fi

echo "=== 1/3 构建真包（Dart 入口 = lib/main.dart）==="
echo "  ⚠️ 构建输出重定向到文件：`flutter build apk` 经管道会被 SIGTERM。"
if ! flutter build apk --debug > "$LOG" 2>&1; then
  echo "[FAIL] 构建失败 —— 完整日志: $LOG"
  tail -15 "$LOG"
  exit 1
fi
tail -2 "$LOG"

echo "=== 2/3 校验产物身份（拒绝把测试入口包装给用户）==="
id=$(apk_identity "$APK")
echo "  身份: $id    （真包 ~245MB / 测试入口包 ~144MB）"
if [ "$id" != "real" ]; then
  echo "[FAIL] 构建产物不是可启动的真包（$id）—— 已拒绝安装到设备。"
  echo "       排查：是否用了 --target=integration_test/… 构建？"
  exit 1
fi

echo "=== 3/3 覆盖安装 ==="
if ! command -v adb >/dev/null 2>&1; then
  echo "[SKIP] PATH 上没有 adb（需要 \$ANDROID_HOME/platform-tools）"; exit 3
fi
TARGET=$(pick_device)
if [ -z "${TARGET:-}" ]; then
  echo "[SKIP] 没有可用设备（adb devices 为空）"
  echo "       真机走无线调试时：adb pair <ip>:<pairPort> <6位码> → mDNS 自动连上连接端口。"
  exit 3
fi
echo "  设备: $TARGET"
# ⚠️ MSYS_NO_PATHCONV=1 + Windows 路径：否则 adb.exe 收到 /e/… 会 failed to stat。
MSYS_NO_PATHCONV=1 adb -s "$TARGET" install -r -t "$(apk_path_win)" 2>&1 | tr -d '\r'
if ! MSYS_NO_PATHCONV=1 adb -s "$TARGET" shell pm list packages 2>/dev/null | tr -d '\r' | grep -q "package:$APP_ID"; then
  echo "[FAIL] 设备上仍未看到 $APP_ID —— 安装未成功"
  exit 1
fi

echo "=== 启动验证（确认不再黑屏）==="
MSYS_NO_PATHCONV=1 adb -s "$TARGET" shell "monkey -p $APP_ID -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1
sleep 6
FOCUS=$(MSYS_NO_PATHCONV=1 adb -s "$TARGET" shell "dumpsys window | grep mCurrentFocus" 2>/dev/null | tr -d '\r')
echo "  当前前台: ${FOCUS:-（读不到）}"
if printf '%s' "$FOCUS" | grep -q "$APP_ID"; then
  echo "✅ 应用已在前台运行（真包，可正常启动）"
  exit 0
fi
echo "⚠️ 前台不是 $APP_ID —— 可能是启动器权限/首次启动引导，请人工看一眼设备屏幕"
echo "   （若仍黑屏，用 --check-only 复核 APK 身份，并确认装的是真包）"
exit 1
