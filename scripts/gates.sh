#!/usr/bin/env bash
# =====================================================================
# 声盾 SonicShield —— 统一门禁脚本（v1.7，落实 HANDOVER §6.11）
# 用法：
#   bash scripts/gates.sh                # 标准门禁：analyze + 功能 + 压测
#   WITH_DEVICE=1 bash scripts/gates.sh  # + 设备端全套（检测到设备时）
#   WITH_AOT=1 bash scripts/gates.sh     # + AOT 绝对验收（flutter drive --profile）
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
  FAIL=$((FAIL+1))
fi

# ---------- 设备端（可选）：integration_test/ 不在默认门禁内（BUG-045 洞） ----------
if [ "${WITH_DEVICE:-0}" = "1" ]; then
  DEV=$(adb devices | grep -E "emulator-|device$" | head -1 | cut -f1)
  if [ -n "${DEV:-}" ]; then
    echo "=== 门禁 4/5: 设备冒烟（app_smoke_test，3 例）on $DEV ==="
    out=$(flutter test integration_test/app_smoke_test.dart -d "$DEV" 2>&1 | tr '\r' '\n')
    echo "$out" | tail -1
    if echo "$out" | grep -q "All tests passed"; then
      echo "[PASS] 设备冒烟"
    else
      echo "[FAIL] 设备冒烟"; FAIL=$((FAIL+1))
    fi
    echo "=== 门禁 5/5: 设备桥接（native_bridge_test，6 例）==="
    out=$(flutter test integration_test/native_bridge_test.dart -d "$DEV" 2>&1 | tr '\r' '\n')
    echo "$out" | tail -1
    if echo "$out" | grep -q "All tests passed"; then
      echo "[PASS] 设备桥接"
    else
      echo "[FAIL] 设备桥接"; FAIL=$((FAIL+1))
    fi
  else
    echo "[SKIP] 设备端门禁：adb devices 为空"
  fi
fi

# ---------- AOT 绝对验收（可选） ----------
if [ "${WITH_AOT:-0}" = "1" ]; then
  echo "=== 门禁: AOT 绝对验收（perf_nfr_test，flutter drive --profile）==="
  out=$(flutter drive --driver=test_driver/integration_test.dart \
    --target=integration_test/perf_nfr_test.dart --profile -d emulator-5554 2>&1 | tr '\r' '\n')
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
