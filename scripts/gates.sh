#!/usr/bin/env bash
# =====================================================================
# 声盾 SonicShield —— 统一门禁脚本（v1.7，落实 HANDOVER §6.11）
# 用法：
#   bash scripts/gates.sh                # 标准门禁：analyze + 功能 + 压测
#   WITH_DEVICE=1 bash scripts/gates.sh  # + 设备端全套（检测到设备时）
#   WITH_AOT=1 bash scripts/gates.sh     # + AOT 绝对验收（flutter drive --profile）
#   DEV=emulator-5554 bash ...           # 指定设备（不指定则优先模拟器，见下方 pick_device）
#   SKIP_PREINSTALL=1 bash ...           # 跳过真机预装检查（默认不跳，见 ensure_device_app）
#   PREINSTALL_TRIES=3 bash ...          # 真机预装的重试次数（默认 3）
#   RESTORE_APP=0 bash ...               # 跳过"跑完设备层自动装回可启动真包"（默认做）
#   ONLY_DEVICE=1 bash ...               # 只跑设备层（迭代设备用例时不必重跑 465 例宿主测试）
#   APP_ID=... bash ...                  # 覆盖包名（默认 com.sonicshield.sonic_shield）
# 退出码：0=全绿；1=有门禁失败（代码回归）；3=代码全绿但有**环境阻塞**（未执行，非失败）。
# 任何一步失败立即退出非零 —— CI 与本地同一套判据。
# 注意：flutter test 输出需 tr '\r' '\n'（compact reporter 刷行）；构建类输出要落盘。
# =====================================================================
set -u
FAIL=0
BLOCKED=0          # 环境阻塞（未执行 ≠ 失败），见文件末尾的退出码说明
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="${APP_ID:-com.sonicshield.sonic_shield}"

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

# `ONLY_DEVICE=1` 只跑设备层：迭代设备用例时不必重跑 465 例宿主测试。
if [ "${ONLY_DEVICE:-0}" != "1" ]; then

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
run_perf() { flutter test --tags perf --concurrency=1 2>&1 | tr '\r' '\n'; }
out=$(run_perf)
echo "$out" | tail -1
if echo "$out" | grep -q "All tests passed"; then
  echo "[PASS] 压测层"
else
  # ⚠️ 压测层红**先怀疑测量，不先改代码**（已复现 3 次，见 docs/12 §37.5）：
  # 它跑在 analyze + 功能层之后，机器热/后台负载会让它整体偏慢，
  # 表现为"多条用例一起超阈值、且超出幅度彼此不成比例"。
  # → 自动单独重跑一次确认（`PERF_RETRY=0` 可关），把噪声在脚本层面消化掉。
  echo "[?] 压测层首次未过，单独重跑一次确认是噪声还是回归…"
  echo "$out" | grep -E "\[E\]|Expected:|Actual:" | head -6 || true
  fail_dump 压测层首次 "$out"
  if [ "${PERF_RETRY:-1}" = "1" ]; then
    out2=$(run_perf)
    echo "$out2" | tail -1
    if echo "$out2" | grep -q "All tests passed"; then
      echo "[PASS] 压测层（重跑确认 ✅）"
      echo "  ⚠️ 首次未过是**机器负载噪声**，不是代码回归。首次实测见上方 dump。"
      echo "     若想每次都一次定生死：PERF_RETRY=0 bash scripts/gates.sh"
    else
      echo "[FAIL] 压测层（重跑仍未过 → 真回归）"
      echo "$out2" | grep -E "\[E\]|Expected:|Actual:" | head -6 || true
      fail_dump 压测层重跑 "$out2"
      FAIL=$((FAIL+1))
    fi
  else
    echo "[FAIL] 压测层（PERF_RETRY=0，未重跑确认）"
    FAIL=$((FAIL+1))
  fi
fi

fi   # ONLY_DEVICE

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

# ---- 真机前置：确保设备上**已有应用** --------------------------------------
# ★ 2026-09-20 实测：厂商安装确认框的触发条件是「设备上有没有这个应用」，
#   **与传输方式无关**（USB / 无线调试都一样弹，标题仍叫「USB 安装提示」）：
#     无应用 → 全新安装 → 弹 [继续安装] [拒绝（10）] → 10 秒倒计时**默认拒绝**
#             → INSTALL_FAILED_USER_RESTRICTED: Install canceled by user
#     有应用 → 覆盖安装 → Success 且**无弹窗**
#   而 `flutter test integration_test/…` **默认跑完就卸载应用**（--uninstall 默认 on）
#   → 下一次又退回"全新安装" → 每个设备用例文件都要人工点一次。
# 所以本脚本做两件事，把"每次都点"摊薄成"点一次就够"：
#   ① 开跑前 `ensure_device_app`：应用不在就先装（引导人工点一次确认框）；
#   ② 设备用例一律加 `--no-uninstall`：跑完**保留应用**，下次直接走覆盖安装。
# ⚠️ 人工点击**不可自动化**：设备缺 INJECT_EVENTS，`input tap` 代点会被拒。
#    因此这里只做"引导 + 重试 + 明确报告"，**不假装能全自动**。
apk_path() {  # adb 是 Windows 原生程序 → 必须给 Windows 形式的路径
  local p="$ROOT/build/app/outputs/flutter-apk/app-debug.apk"
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$p"; else printf '%s' "$p"; fi
}

device_has_app() {  # $1=serial → 0=设备上已装本项目
  MSYS_NO_PATHCONV=1 adb -s "$1" shell pm list packages 2>/dev/null \
    | tr -d '\r' | grep -q "package:$APP_ID"
}

device_alive() {  # $1=serial → 0=当前可连
  MSYS_NO_PATHCONV=1 adb -s "$1" get-state 2>/dev/null | tr -d '\r' | grep -q '^device$'
}

# ★ 2026-09-20 实测：真机走**无线调试**时链路**不持久** ——
#   一次 `flutter test` 里的 Gradle 构建（68.6s）期间 adb server 死掉，
#   设备从 `adb devices` 消失，报：
#     ADB exited with exit code 1 / adb.exe: device '…' not found
#     Unable to start the app on the device
#   若把它读成"桥接用例失败"就是**假红**（会浪费一整轮排查）。
#   判据：错误文本里出现"设备找不到/起不来"，而不是断言失败。
is_transport_failure() {  # $1=用例输出
  printf '%s' "$1" | grep -qE "device '[^']*' not found|Unable to start the app|ADB exited with exit code"
}

run_device_test() {  # $1=显示名  $2=用例文件  $3=日志标签
  local label="$1" file="$2" tag="$3"
  echo "=== 门禁: $label on $TARGET ==="
  if ! device_alive "$TARGET"; then
    echo "[BLOCKED] $label —— 设备当前不可连（无线调试链路不持久，见 device_alive 注释）"
    BLOCKED=$((BLOCKED+1))
    return
  fi
  local out
  # ⚠️ `--no-uninstall`：跑完**保留应用**，否则下一次又退回"全新安装"（见上）。
  out=$(flutter test "$file" -d "$TARGET" --no-uninstall 2>&1 | tr '\r' '\n')
  echo "$out" | tail -1
  if echo "$out" | grep -q "All tests passed"; then
    echo "[PASS] $label"
  elif is_transport_failure "$out"; then
    echo "[BLOCKED] $label —— 传输链路掉了，**不是代码回归**（完整输出见下）"
    fail_dump "$tag" "$out"
    BLOCKED=$((BLOCKED+1))
  else
    echo "[FAIL] $label"
    fail_dump "$tag" "$out"
    FAIL=$((FAIL+1))
  fi
}

ensure_device_app() {  # $1=serial → 0=可以跑设备测试
  local d="$1"
  if ! device_alive "$d"; then
    echo "  [BLOCKED] 设备 $d 当前不可连 —— 无法预装，也无法跑设备用例"
    return 1
  fi
  if device_has_app "$d"; then
    echo "  [OK] 设备上已有 $APP_ID → 设备用例走**覆盖安装**（无弹窗）"
    return 0
  fi
  local apk; apk=$(apk_path)
  if [ ! -f "$ROOT/build/app/outputs/flutter-apk/app-debug.apk" ]; then
    echo "  [BLOCKED] 缺少 $apk —— 先跑一次 \`flutter build apk --debug\`"
    return 1
  fi
  echo ""
  echo "  ⚠️  设备上没有 $APP_ID —— 这是**全新安装**，厂商 ROM 会弹确认框："
  echo "      「USB 安装提示」 [继续安装] [拒绝（10）]，10 秒倒计时**默认拒绝**。"
  echo "      设备缺 INJECT_EVENTS，input tap 代点不可用 →"
  echo "      **只能人工在设备屏上点「继续安装」**。"
  local tries="${PREINSTALL_TRIES:-3}" i=1
  while [ "$i" -le "$tries" ]; do
    echo "  → 第 $i/$tries 次安装尝试：设备屏若弹确认框，请点「继续安装」…"
    # ⚠️ 不要 `tail -1`：实测这一行会把失败原因吞成空行（与 `fail_dump` 同一条教训）。
    local iout rc
    iout=$(MSYS_NO_PATHCONV=1 adb -s "$d" install -r -t "$apk" 2>&1 | tr -d '\r'); rc=$?
    if [ -n "$iout" ]; then
      printf '%s\n' "$iout" | tail -3
    else
      echo "      [adb install] 无输出（RC=$rc）—— 安装被系统静默拒绝，弹窗多半已超时"
    fi
    if device_has_app "$d"; then
      echo "  [OK] 应用已装上 → 后续设备用例可自动（覆盖安装 + --no-uninstall）"
      return 0
    fi
    i=$((i+1))
  done
  return 1
}

# ---- 收尾：把**可启动的真包**装回去（否则手机上应用会永久黑屏）--------------
# 为什么必须做：设备用例会把 app-debug.apk 覆盖成"测试入口包" ——
#   从桌面启动**永久停在闪屏/黑屏、且无任何报错**（2026-09-20 用户真实提问）。
# 做法：设备用例开跑**之前**先缓存一份真包副本（若当时正好是真包），
#   跑完之后用 `--no-build` 装回去 → **省一次 ~50s 的 Gradle 构建**。
# 默认开启（`RESTORE_APP=0` 可关）—— 目标是"**门禁跑完，手机一定可用**"。
REAL_APK_CACHE="$ROOT/build/app/outputs/flutter-apk/app-debug-real.apk"

cache_real_apk() {
  local src="$ROOT/build/app/outputs/flutter-apk/app-debug.apk"
  [ -f "$src" ] || { echo "  [缓存] 尚无 app-debug.apk，跳过"; return 1; }
  # 复用 install_app.sh 的判据，**不在两个脚本里各写一份**（会漂移）。
  if APK="$src" bash "$ROOT/scripts/install_app.sh" --check-only >/dev/null 2>&1; then
    cp -f "$src" "$REAL_APK_CACHE" &&
      echo "  [缓存] 真包副本 → $(basename "$REAL_APK_CACHE")"
    return 0
  fi
  echo "  [缓存] 当前 app-debug.apk 不是真包（多半是测试入口包），不缓存"
  return 1
}

restore_real_apk() {  # $1=serial → 0=已恢复
  local d="$1"
  if [ -f "$REAL_APK_CACHE" ]; then
    echo "  装回缓存的真包副本（--no-build，不重跑 Gradle）…"
    APK="$REAL_APK_CACHE" DEV="$d" bash "$ROOT/scripts/install_app.sh" --no-build
    return $?
  fi
  echo "  没有缓存副本 → 走完整构建（较慢：Gradle ~50s + 安装）…"
  DEV="$d" bash "$ROOT/scripts/install_app.sh"
}

if [ "${WITH_DEVICE:-0}" = "1" ]; then
  TARGET=""
  if ! command -v adb >/dev/null 2>&1; then
    echo "[SKIP] 设备端门禁：PATH 上没有 adb（需要 \$ANDROID_HOME/platform-tools）"
  else
    TARGET=$(pick_device)
  fi
  if [ -n "${TARGET:-}" ]; then
    echo "  ⚠️ 提醒：设备用例会把 app-debug.apk 覆盖成**测试入口包**，从桌面启动会"
    echo "     永久黑屏 —— 本脚本跑完会**自动装回可启动的真包**"
    echo "     （RESTORE_APP=0 可关；手工恢复：bash scripts/install_app.sh）"
    DEVICE_OK=1
    if [ "${SKIP_PREINSTALL:-0}" = "1" ]; then
      echo "  [SKIP] 跳过预装检查（SKIP_PREINSTALL=1）"
    else
      ensure_device_app "$TARGET" || DEVICE_OK=0
    fi
    if [ "$DEVICE_OK" != "1" ]; then
      echo ""
      echo "  [BLOCKED] 设备端门禁**未执行**：设备不可连，或设备上无应用且预装未成功。"
      echo "            **这不是代码回归** —— 不要把本项读成测试失败。"
      echo "            处置：到设备屏上点一次「继续安装」后重跑；或先手动执行"
      echo "            MSYS_NO_PATHCONV=1 adb -s $TARGET install -r -t \"$(apk_path)\""
      BLOCKED=$((BLOCKED+1))
    else
      cache_real_apk || true
      run_device_test "设备冒烟（app_smoke_test，4 例）" integration_test/app_smoke_test.dart device_smoke
      run_device_test "设备桥接（native_bridge_test，6 例）" integration_test/native_bridge_test.dart device_bridge
      # ---- 收尾：把可启动的真包装回去 ----
      if [ "${RESTORE_APP:-1}" = "1" ]; then
        echo "=== 收尾: 恢复可启动的真包（不恢复的话手机上打开会永久黑屏）==="
        if ! restore_real_apk "$TARGET"; then
          echo "  [BLOCKED] 恢复真包失败 —— 设备上现在是不可启动的测试入口包"
          echo "            **这不是代码回归**；手工补救：bash scripts/install_app.sh"
          BLOCKED=$((BLOCKED+1))
        fi
      else
        echo "  [skip] RESTORE_APP=0 —— 设备上现在是不可启动的测试入口包"
      fi
    fi
  else
    echo "[SKIP] 设备端门禁：没有可用设备（adb devices 为空）"
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
if [ "$FAIL" -eq 0 ] && [ "$BLOCKED" -eq 0 ]; then
  echo "全部门禁通过 ✅"
  exit 0
elif [ "$FAIL" -eq 0 ]; then
  echo "代码门禁全绿 ✅，但有 $BLOCKED 项**环境阻塞**（未执行，不是失败）⚠️"
  exit 3
else
  echo "$FAIL 项门禁失败 ❌（另有 $BLOCKED 项环境阻塞）"
  exit 1
fi
