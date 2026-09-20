#!/usr/bin/env bash
# =====================================================================
# 声盾 SonicShield —— 统一门禁脚本（v1.7，落实 HANDOVER §6.11）
# 用法：
#   bash scripts/gates.sh                # 标准门禁：analyze + 功能 + 压测
#   WITH_DEVICE=1 bash scripts/gates.sh  # + 设备端全套（检测到设备时）
#   WITH_AOT=1 bash scripts/gates.sh     # + AOT 绝对验收（flutter drive --profile）
#   DEV=emulator-5554 bash ...           # 指定设备（不指定则优先模拟器，见下方 pick_device）
# 任何一步失败立即退出非零 —— CI 与本地同一套判据。
# 注意：flutter test 输出需 tr '\r' '\n'（compact reporter 刷行）；构建类输出要落盘。
# =====================================================================
set -u
FAIL=0

gate() {
  local name="$1" expect="$2"; shift 2
  echo ""
  echo "=== 门禁: $name ==="
  local out
  out=$("$@" 2>&1 | tr '\r' '\n')
  echo "$out" | tail -2
  if echo "$out" | grep -qE "$expect"; then
    echo "[PASS] $name"
  else
    echo "[FAIL] $name （期望匹配: $expect）"
    echo "$out" | grep -E "\[E\]|Expected:|Actual:" | head -6 || true
    FAIL=$((FAIL+1))
  fi
}

# 失败时把**完整输出**落盘并回显尾部。
# 为什么必须这么做：2026-09-20 真机设备层报「No tests were found.」，
# 而脚本只 `tail -1` → 只剩一行，既看不到 Gradle/安装阶段，也无法判断
# 是"没构建"还是"构建了但设备上没跑起测试"。**证据必须在失败时留下。**
fail_dump() {  # $1=标签  $2=完整输出
  local f="${GATE_LOG_DIR:-/tmp}/gates_$1.log"
  printf '%s\n' "$2" > "$f"
  echo "  ── 完整输出已存: $f ──"
  printf '%s\n' "$2" | tail -15
}

echo "=== 门禁 1/3: flutter analyze ==="
out=$(flutter analyze 2>&1 | tr '\r' '\n')
echo "$out" | tail -1
if echo "$out" | grep -q "No issues found"; then
  echo "[PASS] analyze"
else
  echo "[FAIL] analyze"; FAIL=$((FAIL+1))
fi

echo "=== 门禁 2/3: 功能层（--exclude-tags perf）==="
out=$(flutter test --exclude-tags perf 2>&1 | tr '\r' '\n')
echo "$out" | tail -1
if echo "$out" | grep -q "All tests passed"; then
  echo "[PASS] 功能层"
else
  echo "[FAIL] 功能层"
  echo "$out" | grep -E "\[E\]|Expected:|Actual:" | head -6 || true
  fail_dump 功能层 "$out"
  FAIL=$((FAIL+1))
fi

echo "=== 门禁 3/3: 压测层（--tags perf --concurrency=1，必须单并发）==="
out=$(flutter test --tags perf --concurrency=1 2>&1 | tr '\r' '\n')
echo "$out" | tail -1
if echo "$out" | grep -q "All tests passed"; then
  echo "[PASS] 压测层"
else
  echo "[FAIL] 压测层"
  echo "$out" | grep -E "\[E\]|Expected:|Actual:" | head -6 || true
  fail_dump 压测层 "$out"
  FAIL=$((FAIL+1))
fi

# ---------- 设备端（可选）：integration_test/ 不在默认门禁内（BUG-045 洞） ----------
# 设备选择：显式 `DEV=<serial>` 优先；否则**优先模拟器**。
# 为什么不能只取"第一台设备"：真机可能被厂商策略禁止 adb 安装
# （2026-09-19 实测小米 HyperOS 报 INSTALL_FAILED_USER_RESTRICTED，
# 且 `input keyevent` 同时缺 INJECT_EVENTS → 既不能装也不能驱动 UI），
# 此时"有设备"不等于"能跑设备门禁"，会得到一个看不懂的红。
pick_device() {
  if [ -n "${DEV:-}" ]; then echo "$DEV"; return; fi
  local emu
  emu=$(adb devices | awk '/^emulator-[0-9]+[ \t]+device$/{print $1}' | head -1)
  if [ -n "$emu" ]; then echo "$emu"; return; fi
  adb devices | awk '/[ \t]device$/{print $1}' | head -1
}

if [ "${WITH_DEVICE:-0}" = "1" ]; then
  TARGET=$(pick_device)
  if [ -n "${TARGET:-}" ]; then
    echo "=== 门禁 4/5: 设备冒烟（app_smoke_test，4 例）on $TARGET ==="
    out=$(flutter test integration_test/app_smoke_test.dart -d "$TARGET" 2>&1 | tr '\r' '\n')
    echo "$out" | tail -1
    if echo "$out" | grep -q "All tests passed"; then
      echo "[PASS] 设备冒烟"
    else
      echo "[FAIL] 设备冒烟"
      fail_dump device_smoke "$out"
      FAIL=$((FAIL+1))
    fi
    echo "=== 门禁 5/5: 设备桥接（native_bridge_test，6 例）==="
    out=$(flutter test integration_test/native_bridge_test.dart -d "$TARGET" 2>&1 | tr '\r' '\n')
    echo "$out" | tail -1
    if echo "$out" | grep -q "All tests passed"; then
      echo "[PASS] 设备桥接"
    else
      echo "[FAIL] 设备桥接"
      fail_dump device_bridge "$out"
      FAIL=$((FAIL+1))
    fi
  else
    echo "[SKIP] 设备端门禁：adb devices 为空"
  fi
fi

# ---------- AOT 绝对验收（可选） ----------
if [ "${WITH_AOT:-0}" = "1" ]; then
  echo "=== 门禁: AOT 绝对验收（perf_nfr_test，flutter drive --profile）on ${DEV:-emulator-5554} ==="
  out=$(flutter drive --driver=test_driver/integration_test.dart \
    --target=integration_test/perf_nfr_test.dart --profile \
    -d "${DEV:-emulator-5554}" 2>&1 | tr '\r' '\n')
  echo "$out" | tail -1
  if echo "$out" | grep -q "All tests passed"; then
    echo "[PASS] AOT 验收"
  else
    echo "[FAIL] AOT 验收"; FAIL=$((FAIL+1))
  fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "全部门禁通过 ✅"
  exit 0
else
  echo "$FAIL 项门禁失败 ❌"
  exit 1
fi
