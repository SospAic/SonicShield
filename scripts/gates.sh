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
#   ALLOW_DEVICE_SKIP=1 bash ...         # 无 adb/无设备时**显式**放行跳过设备层（默认 BLOCKED/RC=3）
#   RESTORE_APP=0 bash ...               # 跳过"跑完设备层自动装回可启动真包"（默认做）
#   ONLY_DEVICE=1 bash ...               # 只跑设备层（迭代设备用例时不必重跑 465 例宿主测试）
#   COVERAGE_MIN=70 bash ...             # 覆盖率 ratchet 阈值（默认见下方 COVERAGE_MIN）
#   SKIP_COVERAGE=1 bash ...             # 跳过覆盖率 ratchet（只在排查覆盖率工具本身时用）
#   FUNC_RETRY=0 bash ...               # 功能层撞上 Dart VM 资源耗尽时不降并发重跑（默认重跑）
#   FUNC_RETRY_CONC=4 bash ...           # 重跑的并发度（默认 4）
#   APP_ID=... bash ...                  # 覆盖包名（默认 com.sonicshield.sonic_shield）
# 退出码：0=全绿；1=有门禁失败（代码回归）；3=代码全绿但有**环境阻塞**（未执行，非失败）。
#   ⚠️ 压测层红时先看整机负载：负载 ≥60% 判为"墙钟预算测量无效"→ 归入 3（环境阻塞），
#      而不是 1（真回归）。判定依据见 machine_load() 的注释（2026-09-21 实证）。
# 任何一步失败立即退出非零 —— CI 与本地同一套判据。
# 注意：flutter test 输出需 tr '\r' '\n'（compact reporter 刷行）；构建类输出要落盘。
# =====================================================================
set -u
FAIL=0
BLOCKED=0          # 环境阻塞（未执行 ≠ 失败），见文件末尾的退出码说明
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="${APP_ID:-com.sonicshield.sonic_shield}"

# =====================================================================
# 环境自愈（2026-09-22 实测）
#
# 两个与代码**完全无关**的环境问题会让门禁给出**误导性的红**：
#
# 1) `%PROGRAMFILES(X86)% environment variable not found.`（RC=1，只有这一行）
#    Windows 上 `flutter` 的批处理包装会读该变量；受限宿主（沙箱 / CI 的
#    Git Bash）可能不注入它。bash 无法 `export` 带括号的变量名，
#    因此用 `env` 重新执行本脚本。
#
# 2) `Unable to connect to flutter_tester process:
#     WebSocketException: Invalid WebSocket upgrade request`
#    `flutter test` 与被测进程通过 **127.0.0.1 随机端口**的 WebSocket 通信。
#    若环境里存在 `http_proxy` / `https_proxy`（宿主注入的沙箱代理），
#    该连接会被代理接管而失败。报错里**一个字都没提代理** ——
#    极易被误读成"测试坏了"。
#
# 两者都不是回归。门禁在此主动消除，避免把环境问题记成代码问题。
# =====================================================================
if ! env | grep -q '^PROGRAMFILES(X86)='; then
  export SONICSHIELD_ENV_HEALED=1
  exec env 'PROGRAMFILES(X86)=C:\Program Files (x86)' bash "${BASH_SOURCE[0]}" "$@"
fi
if [ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${all_proxy:-}" ]; then
  echo "[env] 检测到代理变量，已为本次门禁清除（flutter_tester 走本机 WebSocket，不能经代理）"
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
fi

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

# 整机 CPU 负载探针（0–100；-1 = 取不到）。
#
# 为什么门禁需要它：压测层是**墙钟预算**（"≤3s"、"≤8000ms"），
# 别的项目吃 CPU 时会把结果整体推高。而下面"首次失败 → 重跑一次"的
# 重跑机制在**持续争用**下两次都会红，于是把噪声判成"真回归"。
#
# 2026-09-21 实测：另一个项目的 Docker 构建让整机 CPU 长时间 84–91%，
# 压测层两条墙钟预算用例分别超出 8% 与 69%，门禁报"[FAIL] 真回归"——
# 而本轮只新增了一个测试文件，与数据层写入/调度物化毫无因果关系。
# 结论：**没有负载证据的"真回归"判定是不可信的**。
machine_load() {
  if command -v typeperf >/dev/null 2>&1; then
    typeperf "\Processor(_Total)\% Processor Time" -sc 3 2>/dev/null \
      | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+"$' | tr -d '"' \
      | awk '{s+=$1;n++} END{if(n>0)printf "%d",s/n; else print -1}'
  elif [ -r /proc/loadavg ]; then
    awk -v n="$(nproc 2>/dev/null || echo 1)" '{printf "%d", $1*100/n}' /proc/loadavg
  else
    echo -1
  fi
}

# 负载 ≥ 该值时，压测层的墙钟预算视为**测量无效**（不是失败）。可用环境变量覆盖以便自测。
#
# 标定（2026-09-21 同一份代码、同一套预算，三次实测）：
#   整机负载 33–52% → 压测 24/24 全绿
#   整机负载 66%    → 压测 24/24 全绿
#   整机负载 84–91% → 两条最紧的墙钟预算破线（+8.3% / +69%）
# 破线点落在 66%~84% 之间。**故意取偏低的 60%**：宁可多要一次人工复跑，
# 也不要误报"真回归"（误报回归会让人去追一个不存在的 bug —— 那是更贵的错误）。
# 判为 BLOCKED 时退出码是 3（非零），所以**不会被静默放过**。
LOAD_SUSPECT="${LOAD_SUSPECT:-60}"

# ---------- 覆盖率 ratchet（v1.9.0-alpha 起进门禁） ----------
#
# 为什么要有它：覆盖率**只会悄悄退步**。在此之前每次都得靠人记得跑
# `dart run tool/coverage_report.dart` 并肉眼比对 —— 这正是"靠自觉"的护栏，
# 而本项目已经吃过一次亏：旧的 57.5% 分母漏算了 30 个**从未被 import** 的文件，
# 长期没人发现（docs/17 §46⑤）。现在它变成门禁的一部分。
#
# 语义是 **ratchet（只降不升）**，不是"目标值"：
#   - 涨了 → 下次把这行数字往上改（门槛跟着涨，不回落）；
#   - 跌了 → **红**。要么补测试，要么**有意识地**下调，并在 docs/12 记录理由。
#     ⚠️ 下调必须留痕：否则"阈值"就变成了"事后追认现状"，ratchet 失效。
#
# ⚠️ 这里用工具的 `--gate` 而不是自己比大小：口径（分母完整性、豁免白名单、
#    声明式文件反向锁）都在工具里，门禁只消费结论。
#
# ⚠️ **阈值必须比实测值留一点余量**（2026-09-22 实测踩到）：
#    同一份代码、同一条命令，两次跑出 **5506 / 5507 行**（差 1 行 = 0.012pt）。
#    第一版把阈值写成 64.45，正好卡在两次实测值（64.4487% / 64.4604%）**中间**
#    → 同一份代码会时红时绿。这与压测层的"负载噪声"是同一类错误：
#    **ratchet 要抓的是真回落，不是测量抖动**。
#    因此取比实测低约 0.05pt 的整数刻度：容忍 ±1–2 行抖动，
#    但真回落（通常一次掉几十行）照样红。
#
# ⚠️ **这是地板，不是目标值 —— 每次补完测试必须同步抬高**（第二十七～二十九轮实测）：
#    5506/8543（64.45%）→ 5711/8543（66.85%，+205 行）→ 阈值 64.4 → 66.8
#    → 5823/8543（68.16%，+112 行）→ 阈值 66.8 → 68.1
#    → 5918/8545（69.26%，+95 行）→ 阈值 68.1 → **69.2**。
#    忘了抬 = ratchet 形同虚设（下一轮掉 100 行也照样绿）。
#    归因用**对照跑**（把新测试文件移出 test/ 再跑一次全量，逐行 diff 两份 lcov）：
#    第二十八轮 +112 行中 111 行来自 `remote_tasks_tab.dart`（111 → 0，355/355），
#    另 1 行是同批补的 `notify` 分支；**其他文件一行未变**。
#    第二十九轮 +95 行中 94 行来自 `sound_library_screen.dart`（94 → 0，120/120），
#    另 1 行是顺带走到的 `assist_host_screen.dart` 公共路径；**其余 74 个文件 0 行变化**。
#    ⚠️ 该轮分母 8543 → 8545（+2）：给该页加了 `@visibleForTesting` 注入缝，
#    可执行行净增 2 —— 是**可复核的源码事实**（`git diff` 可验），不是测量噪声。
#    第三十轮 +87 行**全部**来自 `remote_console_tab.dart`（88 → 0，331/331）；
#    该轮**只加测试、零生产代码改动**，故分母 8545 不变 —— 这与上一轮的
#    "+2 行"形成对照：分母变了才需要解释，没变就是纯收益。
#
#    第三十三轮（2026-09-24，全功能点高可用性审计与整改）实测 **72.59%（6749/9297）**
#    → 阈值 72.2 → **72.5**（取 floor 到 0.1：72.59 → 72.5，留 ~8 行余量）。
#
#    ⚠️ 本轮出现过一次**必须记录的口径事故**：上一轮交接文档宣称
#    "1213 例全绿 EXIT=0 / 覆盖率 72.27%"，而**实际工作区同时红在第 1 步
#    （`flutter analyze` 9 issues）与第 4 步（实测 71.43% < 72.2）** ——
#    即"全绿"只覆盖了**用例数**，门禁四步从未真正跑绿。
#
#    ⚠️ **本轮阈值为「有意识下调」，理由如下（本项目规则要求必须留痕）**：
#      · 轮内曾在 72.68%（6749/9286）时把阈值抬到 72.6；
#      · 随后「录音中断接线」补丁（`_recordEvidence` 收 `RcCancel` → `runRecordWindow`，
#        关闭 docs/08「用户点了停却仍在采集」红线）在 `endpoint_service.dart` 净增
#        **11 行可执行代码**，这些行位于**宿主结构上不可达**的方法内
#        （需 `AudioRecorder` 插件实例 + 私有 `_db`），宿主测试无法触达；
#      · 结果：**分子 6749 不变**（未删任何用例、未削弱任何断言），**分母 9286 → 9297**，
#        百分比 72.68% → 72.59%。即"覆盖率下降"全部来自分母而非测试倒退。
#      · 判据：ratchet 要防的是"**被测代码**悄悄回落"；本次是**新增不可达的安全必需代码**，
#        两者形状不同。故按 floor(0.1) 下调到 72.5，并在此 + docs/12 §58 双向留痕。
#      · 若日后给 `EndpointService` 加 `_db` 注入缝把这段接进覆盖，**必须同步抬回**。
#
#    分母 9209 → 9286 → 9297：+77 中 +2 来自 `CallService.setPhaseForTest` 注入缝
#    （可复核 `git diff lib/remote/call_service.dart`），其余来自新增测试文件触达的
#    新库；分子 6578 → 6749（+171）来自本轮补齐的 B 桶缺口。
#
#    第三十五轮（2026-09-25/26，交接续作 + 6 Agent 并发）实测 **74.08%（7443/10047）**
#    → 阈值 73.2 → **74.0**（floor(0.1)：74.08 → 74.0，留 ~8 行余量）。
#    · 分子 7264 → 7443（**+179**）：新增测试文件 `test/cov_remote_ctrl2_test.dart`（13 例，
#      隔离区回归）、`test/q35_endpoint_wiring_test.dart`、`test/doc_gate_consistency_test.dart`、
#      `test/foreground_service_lock_test.dart`，以及 `test/pair_qr_screen_test.dart`
#      追加 PQR-09..20（12 例）与 `test/cov_services_test.dart` 恢复 PB06/07/08。
#    · 分母 9905 → 10047（**+142**）：本轮新增生产代码（Q1 盐接线 / Q2 broker 接线 /
#      D-7 残余面裁决 / 扫码页手输兜底 / 通知式自愈留痕）。
#    · 这是**上调**（ratchet 正向），无需下调留痕；但仍按项目规则在 docs/12 §62 记录。
#
#    第三十六轮（2026-09-26 凌晨，自恢复续作）实测 **74.14%（7448/10046）**
#    → 阈值 74.0 → **74.1**（floor(0.1)：74.14 → 74.1，留 ~4 行余量）。
#    · 分子 7443 → 7448（**+5**）：新增 `test/salt_reuse_lock_test.dart`（7 例）覆盖了
#      抽到顶层的 `ensureSaltForDevice`。
#    · 分母 10047 → 10046（**−1**）：删除了**零调用点**的 `injectSaltStore` 注入缝
#      （`RcEndpointService` 是私有构造的单例 ⇒ 宿主永远无法实例化 ⇒ 该缝是死代码）。
#    · 归因是**可复核的源码事实**（`git diff lib/remote/endpoint_service.dart`），
#      不是测量噪声：净增测试 + 净减死代码 ⇒ 比率 +0.06pt，属**净收益**。
#    · 这是**上调**（ratchet 正向）；留痕见 `docs/12 §63.9`。
# 第三十六轮续四实测（2026-09-26）：**可测面 78.47%（7499 / 9556）**、
# 全局 74.67%（7501 / 10046）。阈值 74.1 → **78.4**。
#   ⚠️ **本轮首次启用设备层豁免**（`tool/coverage_report.dart` 的 `_deviceOnly`），
#   因此两个口径**第一次不再相等**：
#     · 分母 10046 → 9556（**−490**）：豁免 `background_engine.dart`(454) + `main.dart`(36)。
#       两者都是"宿主物理不可达"的代码（引擎 isolate / runApp 装配入口），
#       证据由 `test/device_exemption_lock_test.dart`（DEX 系列）机器绑定。
#     · 分子 7501 → 7499（**−2**）：被豁免文件里原本只覆盖到 2 行。
#     · 全局 7448 → 7501（**+53**）：本轮新增 3 个测试文件 36 例真实覆盖。
#   ⚠️ **豁免不产生任何"新的已覆盖行"** —— 它只是把宿主不可达的代码移出
#   门禁口径。百分比因此被抬高 **4.33pt，而真实进度只有 +53 行**。
#   这个差别必须在 `docs/12 §66` 与 `CHANGELOG` 里同时写清楚，
#   否则就退化成"靠改口径美化指标"。
#
#   ⚠️ **每日门禁值守（2026-09-26 晚间自动化复跑）阈值上调纠正**：
#      续五实测可测面 **79.91%（7641 / 9562）**、全局 **76.03%（7643 / 10052）**、
#      功能层 1677 例 / 压测层 24 例全绿（RC=0）。续五曾"**未抬高**"阈值（78.4 / 7494），
#      但实测 79.91% 明显高于地板，按 ratchet 规则（实测高于阈值必须同步抬高，否则
#      ratchet 失效）**纠正抬高**：阈值 78.4 → **79.8**（79.91% 留约 ~10 行抖动余量）、
#      `MIN_COVERED` 7494 → **7637**（可测面分子 7641 − 4 行）。双向留痕见 `docs/12 §69`
#      与 `CHANGELOG`「已知限制」段。
#   ⚠️ **第三十六轮续六**实测可测面 **82.36%（7875 / 9562）** ⇒ 阈值 79.8 → **82.2**、
#      `MIN_COVERED` 7637 → **7867**（留 ~8 行抖动余量）。留痕见 `docs/12 §70`。
#   ⚠️ **第三十七轮（2026-09-27）**：本轮**没有加新功能**，而是修掉一个
#      **挂死整轮**的测试文件（`test/guard_screen_test.dart` 首版在 `FakeAsync` 内
#      直接 `await` 后台 isolate 的 SQLite ⇒ 实测硬超时 240s 才被杀，门禁既不是绿
#      也不是红，是**挂死**）。修复后该文件 10/10 全绿（3s），
#      `lib/features/guard/guard_screen.dart` 未覆盖 **87 → 13 行**。
#      实测可测面 **83.13%（7949 / 9562）** ⇒ 阈值 82.2 → **83.0**、
#      `MIN_COVERED` 7867 → **7943**（可测面分子 7949 − 6 行抖动余量）。
#      双向留痕见 `docs/12 §71` 与 `CHANGELOG`「已知限制」段。
#   ⚠️ **第三十八轮（2026-09-27）**：`multi_video_screen.dart` 是**全项目最后一个
#      没有专属测试文件的大文件**（宿主上 `MultiCallService.connect()` 恒 false ⇒
#      `sessions` 永空 ⇒ 窗口栅格 / `_VideoTile` / 指令条结构上到不了）。
#      本轮照 `RcEndpointService.debugBind` 的先例给该服务加 `@visibleForTesting`
#      会话注入缝（`debugSeed` / `debugClear`），新增 `test/multi_video_screen_test.dart`
#      **15 例**：该文件未覆盖 **117 → 6 行**（LF=151 / LH=145），
#      `multi_call_service.dart` 未覆盖 117 → 100 行（LF 179 / LH 79）。
#      实测可测面 **84.49%（8091 / 9576）** ⇒ 阈值 83.0 → **84.3**、
#      `MIN_COVERED` 7943 → **8085**（可测面分子 8091 − 6 行抖动余量）。
#      双向留痕见 `docs/12 §72` 与 `CHANGELOG`「已知限制」段。
#   ⚠️ **第三十九轮（2026-09-27）**：本轮**零生产代码改动**，补两块**从未被 pump 过的写路径**：
#      ① `device_list_screen.dart` 的**设备组**整块（建组 / 删组 / 组内群发 Ping，91 行未覆盖）
#         —— 三个纯函数被测得很扎实，但"页面上点得到底对不对"从没验证；
#      ② `quick_scripts_card.dart`（46 行里 30 行未覆盖，**全项目唯一既无专属测试文件、
#         又能被首页直接渲染的写路径**）。新增 `test/quick_scripts_card_test.dart` 6 例
#         + `device_list_screen_test.dart` 扩 10 例（共 **16 例**，DLSW-01..21 / QSC-01..06）。
#      `device_list_screen.dart` 未覆盖 **91 → 5 行**（LF=234 / LH=229）、
#      `quick_scripts_card.dart` 未覆盖 **30 → 1 行**（LF=46 / LH=45）；
#      残留 6 行**全部宿主物理不可达**（需真实 MQTT broker 的"在线成功"分支 4 行 +
#      按钮已禁用故结构上点不到的防御守卫 2 行），逐行登记于 `docs/12 §73.5`。
#      实测可测面 **85.69%（8206 / 9576）** ⇒ 阈值 84.3 → **85.5**、
#      `MIN_COVERED` 8085 → **8200**（可测面分子 8206 − 6 行抖动余量）。
#      双向留痕见 `docs/12 §73` 与 `CHANGELOG`「已知限制」段。
#   ⚠️ **第四十轮（2026-09-27）**：本轮补的是"**有测试但整块逻辑从没被驱动**"的四块
#      （`covhomoscan 10` 复核：全库最大连续未覆盖块仍只有 12 行 ⇒ 同源红利依旧为零）：
#      ① `pair_qr_screen.dart` —— 手输**合法**配对码的完整提交路径（此前只测过"非法输入"）
#         + 权限闸门全档位（permanentlyDenied / restricted / limited / provisional）
#         + **授权后的扫描态**（`_pt` 实测：宿主里 `MobileScanner` 走 errorBuilder，
#         可见错误面）⇒ 未覆盖 **112 → 49 行**；
#      ② `sound_guard_service.dart` —— 把 PCM 块**真的喂进** `start()` 的 listen 回调，
#         锁死"阈值 / 最短持续 / 冷却 / 峰值取事件内最大 / 静音复位 / 采流异常广播"
#         ⇒ 未覆盖 **15 → 0 行**（LF=58 / LH=58）；
#      ③ `app_database.dart` —— 造 v1/v2 **旧版真库**驱动 `_onUpgrade` 的两条 ALTER
#         （此前所有用例都从 `:memory:` 起步，直接建到 v3 ⇒ 迁移路径零验证）
#         ⇒ 未覆盖 **12 → 0 行**（LF=40 / LH=40）；
#      ④ `native_bridge.dart` —— 补 `vibrate` / `vibrateCommand`（envelope + 三种 waveform）
#         / `clearAlarms` / 麦克风 FGS 入口的逐键载荷锁 ⇒ 未覆盖 **20 → 1 行**
#         （残余 1 行是私有构造 `NativeBridge._()`，**结构性不可达**）。
#      另修 **BUG-075**：`PairQrProtocol.parseUri` 只归一化配对码、**不归一化 deviceId**
#      ⇒ 用户手抄成大写时"配对成功但命令永远发不出去、回执永远解不开"，且全程无报错。
#      实测可测面 **86.83%（8315 / 9576）** ⇒ 阈值 85.5 → **86.6**、
#      `MIN_COVERED` 8200 → **8309**（可测面分子 8315 − 6 行抖动余量）。
#      双向留痕见 `docs/12 §74` 与 `CHANGELOG`「已知限制」段。
#   ⚠️ **第四十一轮（2026-09-27）**：本轮补的是"**测试文件覆盖的是哪一层**"判据下的两块：
#      ① `permission_flow.dart`（13 行未覆盖、**零专属测试文件**）—— 新建
#         `test/permission_flow_test.dart`（PFL-01…05）：合规门两条出口（同意 / 拒绝都要
#         显式落库，key 缺失 ≠ 拒绝过）、一站式权限申请（**此前唯一路径把
#         `isIgnoringBatteryOptimizations` 桩成 true ⇒「未加白 → 真的请求加白」从未执行**）、
#         保活引导三个入口逐键载荷 ⇒ 未覆盖 **13 → 4 行**（残余 4 行见下）；
#      ② `call_screen` / `ptt_tab` / `remote_screen` 三块「有测试但整块分支没被驱动」——
#         初装端点两键禁用 / 预选不存在的端点 / 视频通话双权限失败文案 / **语音通话不得
#         被"相机被拒"误拦** / `连接中` 相位与挂断入口 / 对端振铃文案切换 /
#         对讲面板按住松手与滑出取消（**必须真的走到 `_rec.stop()`**）⇒
#         三文件分别 45 → 0（call_screen 已满覆盖）/ 31 → 22 / 74 → 11 行。
#      实测可测面 **88.13%（8446 / 9584）** ⇒ 阈值 86.6 → **87.9**、
#      `MIN_COVERED` 8309 → **8440**（可测面分子 8446 − 6 行抖动余量）。
#      ⚠️ 本轮**分母 +8 行**（9576 → 9584）：来自 `remote_screen.dart` 的 LF 323 → 331。
#      原因已实测确认——Dart 覆盖率**只收录"被编译过的行"**，此前从未被 pump 的
#      `_PttSheet` 相关行**根本不在报告里**（既不计分母也不计分子）；本轮把它们驱动起来后
#      这些行**才进入分母**。属"如实计入"，不是豁免口径变动。
#      ⚠️ 另一处如实记录：`pair_qr_screen.dart` 未覆盖 **49 → 50（+1 行，方向不利）**。
#      证据：第四十轮终验产物 `_pt/p7verify.txt` 记 `LF:259 / LH:210`，本轮两次独立全量
#      运行均为 `LF:259 / LH:209`（`_pt/lcovA.info` / `lcovB.info`，DA 逐行相同）；
#      而**只跑该文件**时为 LH=208 —— 证明它的命中数与**同时运行的其它测试文件**有关
#      （`L43/L44` 已证只在全量运行被顺带覆盖）。∴ 判为**跨轮 ±1 行差异**，已计入净数。
#      ⚠️ 同轮流程补强：每轮把 `coverage/lcov.info` 另存为 `_pt/lcov_<轮次>.info`，
#      否则下一轮无法逐行归因（第四十轮的 lcov 就是被同路径覆盖写掉的）。
#      ⚠️ 值得记下的**陷阱**：`TestDefaultBinaryMessenger.send` 对**没打过桩**的通道会落回
#      `delegate.send` ⇒ 宿主无引擎 ⇒ 回调**永不触发**，`await` **永久挂起**（不是抛错）。
#      症状是"断言找不到文本"，根因却在十几行之前的通道没桩。见 `docs/12 §75.5`。
#      双向留痕见 `docs/12 §75` 与 `CHANGELOG`「已知限制」段。
#   ⚠️ **第四十三轮（2026-09-28）**：本轮判据再推一格 ——
#      **「插件不推回调」≠「回调不可执行」**。前三轮把 `pair_qr_screen` 的
#      `onDetect` / `errorBuilder` 登记为"宿主物理不可达"，那条判断**只对
#      "经由插件运行期触发"成立**：`MobileScanner` 的这两个字段都是**公开 final**
#      （`mobile_scanner-6.0.11/lib/src/mobile_scanner.dart:47/56/68`），
#      宿主上可以取出**同一个闭包**并用真实形状的 `BarcodeCapture` /
#      `MobileScannerException` 驱动 —— 跑的是生产代码本身，不是伪造输入。
#      本轮五块（**生产代码 0 行改动**）：
#      ① `pair_qr_screen.dart` 未覆盖 **50 → 7**（8 例 PQR-28…35：别家二维码就地提示
#         且**不停扫描** / 商品一维码不打扰 / 声盾码走与手输**同一条**落盘路径 /
#         前缀对但字段不全 → 不落盘 / `errorBuilder` 两类失败**两句话**（权限被拒 vs
#         MIUI 占用）/ 手电筒可点不炸 / ★**手输「取消」必须什么都不写**
#         —— 否则用户以为没配上，实际已经授权了对方）；
#      ② `remote_scripts_tab.dart` 未覆盖 **33 → 12**（5 例 RS-09…13：
#         此前**所有用例都在协助会话下跑**，于是 `ch == null` 这条**默认形态**从未执行 ——
#         未选目标即点执行 / 离线落 outbox 且如实说"已入队" / 目标选择真的落 prefs /
#         删除真的写盘 / 未配对点新建必须说明原因）；
#      ③ **新建 `test/command_channel_test.dart`（8 例 CC-01…08）** ——
#         `command_channel.dart` 未覆盖 **6 → 0（满覆盖）**：`PairedChannel` 的三个成员
#         此前**从未被执行**（用它的测试全都注入 `_FakeScriptChannel` 假实现 ⇒
#         **契约被假实现验证、真实现被绕过**）；
#      ④ `assist_host_screen.dart` 未覆盖 **14 → 0（满覆盖）**（AHW-13/14：
#         防爆破告警行"已拒绝 N 次"必须可见 + 「复制临时码+密码」剪贴板内容逐字断言）；
#      ⑤ `guard_screen.dart` 未覆盖 **13 → 2**（GS-04/05/06：库里已有配置必须**恢复**而不是
#         回默认 / 守卫**正在跑**时改参数必须**先停后起**（只落库不重启 = 静默失效）/
#         引擎在跑 + 麦克风已授权 → 必须走到「申请麦克风前台服务」那一段）。
#      新增 **26 例**（功能层 1788 → **1814**）；实测可测面 **89.13%（8542 / 9584）**
#      ⇒ 阈值 87.9 → **88.9**、`MIN_COVERED` 8440 → **8536**（可测面分子 8542 − 6 行抖动余量）。
#      ⚠️ 本轮**分母 9584 / 10074 一字未动**（生产代码 0 行改动）—— 真实进度 **8448 → 8544（+96 行）**。
#      ⚠️ 同轮记下的**陷阱**：`StreamController.stream` 每次访问都会新建一个
#      `_ControllerStream` 包装 ⇒ **`identical()` 判"是不是同一条流"必然为假**
#      （实测 `identical(ch.events, ch.events) == false`）。"指向同一条流"要用源码锁 +
#      广播性（`isBroadcast`）来锁，见 `test/command_channel_test.dart` CC-02。
#      双向留痕见 `docs/12 §76` 与 `CHANGELOG`「已知限制」段。
# ── 第四十四轮（2026-09-28）────────────────────────────────────────────
#      判据再换代：**「源码锁是绿的」≠「那条业务路径被执行过」** ——
#      `_runScript`（远程指令组执行）此前只被 RSS-04…RSS-10 的 `methodBody` **文本锁**
#      与纯函数断言覆盖，于是 **`runner` 的九分支 `switch` 一条都没跑过**。
#      本轮用既有 `debugBind` + `debugDispatch` 接缝**真实驱动整条链路**：
#      `delay`/`play`(空库+起播)/`tts`/`notify`/`vibrate`(三路由)/并发拒绝/`script.stop` 中止
#      ⇒ `endpoint_service.dart` 未覆盖 **527 → 435（+92 行）**，占本轮 +144 行的 64%。
#      另清尾：`script_executor.dart` **14 → 0（满覆盖）**、`assist_host.dart` **22 → 0（满覆盖）**
#      （含 D-7 载荷级裁决拒绝 / 执行层抛异常必须留审计+显式回执）、`guard_screen.dart`
#      **2 → 0（满覆盖）**、`rc_script.dart` **6 → 0**、`remote_console_tab.dart` **8 → 6**、
#      `pair_qr_screen.dart` **7 → 5**。
#      新增 **34 例**（功能层 1814 → **1848**）；实测可测面 **90.63%（8686 / 9584）**
#      ⇒ 阈值 88.9 → **90.4**、`MIN_COVERED` 8536 → **8680**（可测面分子 8686 − 6 行抖动余量）。
#      ⚠️ 本轮**分母 9584 / 10074 一字未动**（生产代码 0 行改动）—— 真实进度 **8544 → 8688（+144 行）**。
#      ⚠️ 同轮记下的**两个陷阱**：① `mobile_scanner 6.0.11` 的 `onDetectError` 是**非空**参数
#      （不是可空公开字段）⇒ 多写一个 `!` 会被 analyze 判 `unnecessary_non_null_assertion`；
#      ② `flutter_local_notifications` 的 `initialize` 平台层声明返回 `bool`（**非** `bool?`）
#      ⇒ mock 桩一律返回 `null` 会在宿主上炸 `Null is not a subtype of FutureOr<bool>`。
#      双向留痕见 `docs/12 §77` 与 `CHANGELOG`「已知限制」段。
# ── 第四十五轮（2026-09-28）────────────────────────────────────────────
#      判据再推一格（第六代）：**「同一域里"只有源码文本锁"的整块」可以用
#      「平台通道替身」拿下** —— `call_service.dart`(132 行未覆盖) 与
#      `multi_call_service.dart`(100 行未覆盖) 此前**只有 `methodBody` 文本锁**
#      （`call_flow_test.dart` 35 条源码断言），**从没有一次真实的 WebRTC 会话
#      被执行过**：宿主上 `RTCPeerConnection` 一碰插件就挂，于是"取流→建联→
#      ICE→收尾"整条链路零执行。
#      本轮**不改生产逻辑**（唯一行为改动是 BUG-076 的一个实参），新增
#      `test/support/webrtc_stub.dart`（照 `flutter_webrtc 1.6.2+hotfix.3` 的
#      **真实通道名与返回形状**写的平台替身），并新增
#      `test/call_service_webrtc_test.dart`(39 例) +
#      `test/multi_call_service_connect_test.dart`(23 例)。
#      ⇒ `call_service` 未覆盖 **132 → 14**、`multi_call_service` **100 → 12**。
#      另设 `RcEndpointService.debugSendTo`（`@visibleForTesting`）出站替身，
#      让 `sendTo` 的**成功分支**在宿主上可达 —— 顺手清掉
#      `remote_console_tab.dart` 的最后 2 行（**8 → 2 → 0 满覆盖**）。
#      ⚠️ 并抓修 **BUG-076**：`CallService.startCall` 发出的 `callInvite` **漏了**
#      `enqueueOnFail: false`（默认 `true`）⇒ 本端已 `_teardown` 后，对端上线仍会
#      收到**上一通的过期 invite** 并照常振铃 —— 自动接通开着时更会静默建立一路
#      **无人管理**的会话（麦/摄像头已开，且因 `_answered=true` 连 45s 振铃超时都不启动）。
#      ⇒ 阈值 90.4 → **92.6**、`MIN_COVERED` 8680 → **8892**（可测面分子 8898 − 6 行抖动余量）。
#      ⚠️ 本轮分母 **9584 → 9586 / 10074 → 10076（+2）**：来自 `endpoint_service.dart`
#      新增的 `debugSendTo` 注入缝**自身的可执行行**，如实计入分母
#      （与第三十八轮同型 —— 注入缝的行不许藏、也不许塞进豁免）。
#      双向留痕见 `docs/12 §78` 与 `CHANGELOG`「已知限制」段。
#      第四十六轮（判据第六代**换域**到 `just_audio`）：新建
#      `test/support/just_audio_stub.dart`（照 `just_audio_platform_interface 4.6.0` 的
#      `JustAudioPlatform` / `AudioPlayerPlatform` 写）与
#      `test/playback_service_justaudio_test.dart`（**13 例**）⇒
#      `playback_service.dart` 未覆盖 **76 → 2 行（98.2%）**。
#      ⚠️ **分母 9586 / 10076 一字未动**（替身是测试侧文件，不产生新的生产行）⇒ 纯收益。
#      ⇒ 阈值 92.6 → **93.3**、`MIN_COVERED` 8892 → **8966**（可测面分子 8972 − 6 行抖动余量）。
#      双向留痕见 `docs/12 §79` 与 `CHANGELOG`「已知限制」段。
#      第四十七轮（**入站原始报文链路**上机）：新增两个 `@visibleForTesting` 缝
#      `debugSetOwnCode` / `debugHandleRaw`，+ 新建
#      `test/endpoint_inbound_raw_test.dart`（**15 例** IR-01…15）⇒
#      `endpoint_service.dart` 未覆盖 **435 → 约 310 行**（`_handleRaw` / `_handlePeerEvent`
#      / `_peerName` / `_broadcast` / `_rememberSeen` / 三个审计限频器 / `_rememberCmdTs`
#      / `_awaitAck` / `requestPairing` / `_savePeerSalt` 第一次被**行为**驱动）。
#      ⚠️ 分母 **9586 → 9590 / 10076 → 10080（+4）**：两个注入缝自身的可执行行，
#      如实计入（同第三十八/四十五轮纪律：缝的行不许藏、不许塞豁免）。
#      ⇒ 阈值 93.3 → **94.8**、`MIN_COVERED` 8966 → **9091**（可测面分子 9097 − 6 行抖动余量）。
#      双向留痕见 `docs/12 §80` 与 `CHANGELOG`「已知限制」段。
# 第四十九轮（2026-09-29）实测可测面 **96.89%**（9298/9596）→ 阈值 95.9 → **96.8**
#   （−0.09pt ≈ 9 行余量；MIN_COVERED = 9298 − 6 行抖动余量 = 9292）。
# 第五十八轮（2026-10-01）实测可测面 **97.18%**（9326/9597）→ 阈值 96.8 → **97.1**
#   （−0.08pt ≈ 7 行余量；MIN_COVERED = 9326 − 6 行抖动余量 = 9320）。
# 第五十九轮（2026-10-01）实测可测面 **97.71%**（9377/9597）→ 阈值 97.1 → **97.7**
#   （−0.01pt ≈ 6 行余量；MIN_COVERED = 9377 − 6 行抖动余量 = 9371）。
#   ⚠️ 本轮为**覆盖率冲刺第二轮**（新增 `test/bi_gap_closure2_test.dart` 14 例，`lib/**` 一字未动
#   ⇒ 分母 9597/10087 不变），真实进度 **+51 行**（9326 → 9377）。双向留痕见 `docs/12 §92`。
# 第六十轮（2026-10-01）实测可测面 **97.88%**（9394/9597）→ 阈值 97.7 → **97.8**
#   （−0.01pt ≈ 6 行余量；MIN_COVERED = 9394 − 6 行抖动余量 = 9388）。
# 第六十一轮（2026-10-01 深夜）实测可测面 **98.11%**（9416/9597）→ 阈值 97.8 → **98.0**
#   （−0.11pt ≈ 10 行余量；MIN_COVERED = 9416 − 6 行抖动余量 = 9410）。
#   ⚠️ 本轮为**覆盖率冲刺第四轮**（补既有未覆盖分支：新建 `test/bk_gap_closure_test.dart` 2 例
#   + 4 个既有文件追加 7 例，`lib/**` 一字未动 ⇒ 分母 9597/10087 不变），真实进度 **+22 行**（9394 → 9416）。
#   ⚠️ 阈值取整数刻度 98.0（非 98.1）：98.11 − 98.1 = 0.01pt < 1 行，低于本文件要求的
#   「约 0.05pt / ±1~2 行」抖动余量 ⇒ 取 98.0 让 MIN_COVERED(9410) 成为约束项，余量 6 行。
# 第六十二轮（2026-10-02 凌晨）实测可测面 **98.36%**（9440/9597）→ 阈值 98.0 → **98.3**
#   （−0.06pt ≈ 6 行余量；MIN_COVERED = 9440 − 6 行抖动余量 = 9434）。
#   ⚠️ 本轮为**覆盖率冲刺第五轮**（新建 `test/bl_gap_closure_test.dart` 3 例 + `quick_scripts_card_test.dart`
#   追加 1 例，`lib/**` 一字未动 ⇒ 分母 9597/10087 不变），真实进度 **+24 行**（9416 → 9440）。
#   ⚠️ 98.36 − 98.3 = 0.06pt ≥ 0.05pt ⇒ 取 98.3（不是再下一档）。
# 第六十三轮（2026-10-02 晨）实测可测面 **98.52%**（9455/9597）→ 阈值 98.3 → **98.4**
#   （−0.12pt ≈ 12 行余量；MIN_COVERED = 9455 − 6 行抖动余量 = 9449）。
#   ⚠️ 本轮为**覆盖率冲刺第六轮**（补既有未覆盖分支：`permission_flow_test.dart` +1 例、
#   `sound_library_screen_test.dart` +2 例、`assist_join_screen_test.dart` +1 例、
#   `multi_video_screen_test.dart` +1 例，`lib/**` 一字未动 ⇒ 分母 9597/10087 不变），
#   真实进度 **+15 行**（9440 → 9455）。逐文件归因：`sound_library_screen` +5（136/136 满覆盖）、
#   `assist_join_screen` +5（155/156）、`permission_flow` +4（52/52 满覆盖）、`multi_video_screen` +1。
#   ⚠️ 98.52 − 98.5 = 0.02pt **< 0.05pt** ⇒ 取下一档 **98.4**（让 MIN_COVERED 成为约束项）。
#   ⚠️ 第六十四轮实测 **98.67** ⇒ 98.67 − 98.6 = 0.07pt **≥ 0.05pt** ⇒ 取 **98.6**（不再下一档）。
# 第六十五轮（2026-10-02 午）实测可测面 **98.81%**（9483/9597）→ 阈值 98.6 → **98.7**
#   （−0.11pt ≈ 10 行余量；MIN_COVERED = 9483 − 6 行抖动余量 = 9477）。
#   ⚠️ 本轮为**覆盖率冲刺第八轮**（补既有未覆盖分支：`endpoint_inbound_raw_test.dart` +2 例、
#   `deep_endpoint_dispatch_test.dart` +1 例、`assist_join_test.dart` +1 例、
#   `log_stats_screen_test.dart` +1 例、`call_screen_test.dart` +1 例，`lib/**` 一字未动
#   ⇒ 分母 9597/10087 不变），真实进度 **+14 行**（9469 → 9483）。逐文件归因：
#   `endpoint_service` +8（51→43）、`log_screen` +3（3→0 满覆盖）、`assist_join` +2（4→2）、
#   `call_screen` +1（2→1）。
#   ⚠️ 98.81 − 98.8 = 0.01pt **< 0.05pt** ⇒ 取下一档 **98.7**（让 MIN_COVERED 成为约束项）。
# 第六十六轮（2026-10-02 下午）实测可测面 **98.92%**（9493/9597）→ 阈值 98.7 → **98.8**
#   （−0.12pt ≈ 12 行余量；MIN_COVERED = 9493 − 6 行抖动余量 = 9487）。
#   ⚠️ 本轮为**覆盖率冲刺第九轮**（补既有未覆盖分支：`remote_scripts_tab_test.dart` +2 例、
#   `call_incoming_overlay_test.dart` +1 例、`call_service_webrtc_test.dart` +1 例，`lib/**` 一字未动
#   ⇒ 分母 9597/10087 不变），真实进度 **+10 行**（9483 → 9493）。
#   ⚠️ 98.92 − 98.9 = 0.02pt **< 0.05pt** ⇒ 取下一档 **98.8**（让 MIN_COVERED 成为约束项）。
# 第六十七轮（2026-10-02 晚）实测可测面 **99.08%**（9509/9597）→ 比率阈值**不动**（98.8）
#   （98.95 − 98.9 = 0.05pt ⇒ 不触发"再下一档"；且 98.9 的余量仅 1 行 < 抖动余量），
#   **只抬绝对下限** `MIN_COVERED` = 9509 − 6 行抖动余量 = **9503**。
#   ⚠️ 本轮为**覆盖率冲刺第十轮**（补既有未覆盖分支：`call_service_webrtc_test.dart` +1 例
#   `CS-41` 被叫振铃 45s 无人接听 ⇒ 主动上报 `rc.call.missed` 并收尾；`lib/**` 一字未动
#   ⇒ 分母 9597/10087 不变），真实进度 **+13 行**（9493 → 9509）。
# 第六十八轮（2026-10-03 晨）实测可测面 **99.10%**（9511/9597）→ 比率阈值**不动**（98.8）
#   （只抬绝对下限 `MIN_COVERED` = 9511 − 8 行抖动余量 = **9503 保持**）。
#   ⚠️ 本轮为**覆盖率冲刺第十一轮**（`remote_screen_test.dart` RRS-19b 对讲面板「关闭」真关闭
#   + `endpoint_mqtt_link_test.dart` MQ-22 丢弃缺 `wire` 的畸形 outbox 条目，`lib/**` 一字未动
#   ⇒ 分母 9597/10087 不变），真实进度 **+2 行**（9509 → 9511）。
# 第六十九轮（2026-10-03 上午）实测可测面 **99.20%**（9520/9597）→ 比率阈值**不动**（98.8）
#   （99.20 − 99.2 = 0.00pt < 0.05pt ⇒ 本可下一档；但为**避免为追数字抬比率**且让
#   `MIN_COVERED` 继续作约束项，比率保持 98.8），**只抬绝对下限**
#   `MIN_COVERED` = 9520 − 8 行抖动余量 = **9512**。
#   ⚠️ 本轮为**覆盖率冲刺第十二轮**（新建 `test/bs_gap_closure_test.dart` 5 例撬开四处
#   `docs/17 §97.5` 复核结论的**翻转**：BS-01/BS-02 端点开关 + 改 broker、BS-03 写库失败提示、
#   BS-04 发送失败回到宿主、BS-05 协助注入 `_assistPeer`；`lib/**` 一字未动 ⇒ 分母不变），
#   真实进度 **+9 行**（9511 → 9520）。
# 第七十轮（2026-10-03 下午）实测可测面 **99.21%**（9552/9628）→ 比率阈值**不动**（98.8）
#   （99.21 − 99.2 = 0.01pt < 0.05pt ⇒ 本可下一档；沿用第六十九轮的做法：不为追数字
#   抬比率，让 `MIN_COVERED` 继续作约束项），**只抬绝对下限**。
#   ⚠️ 本轮为**产品层修复 + 测试质量加固**（F-3 开机自启 + DB v3→v4 幂等补列 +
#   轮换配对码 UI + A12–A15），**含 `lib/**` 改动** ⇒ 可测面分母 9597 → **9628（+31）**、
#   分子 9521 → **9552（+31）**，真实进度 **+31 行**。
COVERAGE_MIN="${COVERAGE_MIN:-98.8}"

# ── 第三十四轮：再补一个**分子**硬下限 ────────────────────────────────────
#
# 为什么光有百分比不够：**分母不是常数**。合规地新增"宿主不可达但安全/正确性
# 必需"的代码（MQTT 连接、平台插件胶水、原生桥调用）时，分母变大、百分比被稀释。
# 于是"什么都不做"比"老实加防护"更好看 —— 这个指标在**奖励错误的行为**。
#
# 本轮实测：**73.26%（7254 / 9902）**（扫码修复 + 三路全量扫描 + 设备组/找回告警/限流
# 等新功能使分母 9410 → 9902（+492）、分子 7063 → 7254（+191）⇒ 比率被稀释 74.63% → 73.26%）。
# 阈值 74.5 → **73.2**（floor(73.26)=73.2，留 ~5.6 行余量）。
#
# 使用纪律（与 COVERAGE_MIN 相同）：想改低它，必须在这里 + docs/12 双向写明理由。
#
# 第三十五轮实测 **7443** → 阈值 7248 → **7438**（分子下限 = 实测 − 5 行抖动余量）。
# 第三十六轮实测 **7448** → 阈值 7438 → **7443**（同上：实测 − 5 行抖动余量）。
# 第三十六轮续四实测：**可测面分子 7499**（全局 7501 − 豁免文件已覆盖的 2 行）
# → 阈值 7443 → **7494**（实测 − 5 行抖动余量）。
#   ⚠️ 分子下限是**绝对数**，不随豁免口径变化 ⇒ 它是"豁免有没有被用来掩盖
#   真实倒退"的最后一道防线：豁免只会让**分母**变小，改不动分子。
# 第四十六轮实测 **8972**（可测面分子）→ 阈值 8892 → **8966**（实测 − 6 行抖动余量）。
# 第四十七轮实测 **9097**（可测面分子）→ 阈值 8966 → **9091**（实测 − 6 行抖动余量）。
# 第四十九轮实测 **9298**（可测面分子）→ 阈值 9217 → **9292**（实测 − 6 行抖动余量）。
# 第五十八轮实测 **9326**（可测面分子）→ 阈值 9292 → **9320**（实测 − 6 行抖动余量）。
# 第五十九轮实测 **9377**（可测面分子）→ 阈值 9320 → **9371**（实测 − 6 行抖动余量）。
# 第六十轮实测 **9394**（可测面分子）→ 阈值 9371 → **9388**（实测 − 6 行抖动余量）。
# 第六十一轮实测 **9416**（可测面分子）→ 阈值 9388 → **9410**（实测 − 6 行抖动余量）。
# 第六十二轮实测 **9440**（可测面分子）→ 阈值 9410 → **9434**（实测 − 6 行抖动余量）。
# 第六十三轮实测 **9455**（可测面分子）→ 阈值 9434 → **9449**（实测 − 6 行抖动余量）。
# 第六十四轮实测 **9469**（可测面分子）→ 阈值 9449 → **9463**（实测 − 6 行抖动余量）。
# 第六十五轮实测 **9483**（可测面分子）→ 阈值 9463 → **9477**（实测 − 6 行抖动余量）。
# 第六十六轮实测 **9493**（可测面分子）→ 阈值 9477 → **9487**（实测 − 6 行抖动余量）。
# 第六十七轮实测 **9509**（可测面分子）→ 阈值 9487 → **9503**（实测 − 6 行抖动余量）。
# 第六十八轮实测 **9511**（可测面分子）→ 阈值 **9503 保持**（实测 − 8 行抖动余量）。
# 第六十九轮实测 **9520**（可测面分子）→ 阈值 9503 → **9512**（实测 − 8 行抖动余量）。
# 第七十轮实测 **9552**（可测面分子）→ 阈值 9512 → **9544**（实测 − 8 行抖动余量）。
# 第七十一轮（2026-10-04）实测 **9873**（可测面 9873/9982；全局 9881/10527）→ 阈值 9544
#   → **9865**（实测 − 8 行抖动余量）。⚠️ 本轮为 **docs/50 全量代码审查整改**（阶段 A/B/D
#   修复 + 阶段 C 平台能力），**含 `lib/**`/原生/测试改动** ⇒ 可测面分母 9628 → 9982（+354）、
#   分子 9552 → 9873（+321）。比率阈值**不动**（98.8，沿用第六十九轮做法：不为追数字抬比率，
#   让 `MIN_COVERED` 继续作约束项）。
# 第七十二轮（2026-10-04 夜）实测 **10033**（可测面 10033/10153；全局 10041/10705）→ 阈值
#   9865 → **10025**（实测 − 8 行抖动余量）。⚠️ 本轮为**全功能点用例库 + release 守护锁**
#   （R8/proguard 接入、WebRTC 保留、相机探针）——**纯测试侧改动** ⇒ 可测面分母 10153 一字未动、
#   分子 10032 → **10033（+1）**（r71 末值见 `HANDOVER` ★ 块：10032/10153）。
#   比率阈值**不动**（98.8，沿用第六十九轮做法：不为追数字抬比率，让 `MIN_COVERED` 继续作约束项）。
# 第七十三轮（2026-10-05）实测 **10035**（可测面 10035/10156；全局 10043/10708）→ 阈值 **10025 保持**
#   （实测 − 10 行抖动余量）。⚠️ 全量 release 全功能点测试用例库轮（`docs/12 §106`）。
#   `COVERAGE_MIN` 保持 98.8。
# 第七十四轮（2026-10-05）实测 **10217**（可测面 10217/10339；全局 10225/10892）→ 阈值
#   10025 → **10209**（实测 − 8 行抖动余量）。⚠️ 本轮为 **PTT v2 全量真流式**（控制端边录边发
#   ADTS 帧分片、端点 just_audio 播放列表边收边放）+ **替身边界真实链冒烟**防复发机制（BUG-080）
#   ⇒ **含 `lib/**` 改动** ⇒ 可测面分母 10156 → 10339（+183）、分子 10035 → 10217（+182）。
#   比率阈值**不动**（98.8，沿用第六十九轮做法：不为追数字抬比率，让 `MIN_COVERED` 继续作约束项）。
# 第七十五轮（2026-10-06）实测可测面 **98.83%**（10277/10399）→ 比率阈值**不动**（98.8），
#   只抬绝对下限：**10209 → 10269**（实测 − 8 行抖动余量）。
#   ⚠️ 本轮为 **WebRTC 建连提速（国内可达 STUN + ICE 参数 + TURN UDP/TCP 双通道）+
#   BUG-081（应答后建连超时）修复**，**含 `lib/**` 改动** ⇒ 可测面分母 10339 → 10399（+60）、
#   分子 10217 → 10277（+60）；功能层 2284 → 2297。
MIN_COVERED="${MIN_COVERED:-10269}"
#   ⚠️ 第四十五轮（2026-09-28）实测可测面分子 **8898** → 阈值 8680 → **8892**（实测 − 6 行抖动余量）。
#      ⚠️ 本轮分母 **9584 → 9586 / 10074 → 10076（+2）**（新增注入缝自身的行）；真实进度
#      **8688 → 8900（+212 行）**，其中 **+210** 来自两个新增 WebRTC 行为测试文件、
#      **+2** 来自 `remote_console_tab` 的 `_armExpectation` 成功分支清尾。
#      ⚠️ 分子下限是**绝对数、不随口径变化** ⇒ 它照旧是"分母被稀释/被豁免掩盖"的最后防线。
#   ⚠️ 第四十四轮（2026-09-28）实测可测面分子 **8686** → 阈值 8536 → **8680**（实测 − 6 行抖动余量）。
#      ⚠️ 本轮分母 **9584 / 10074 一字未动**；真实进度 **8544 → 8688（+144 行）**，生产代码 0 行改动。
#      ⚠️ 分子下限是**绝对数、不随口径变化** ⇒ 它照旧是"分母被稀释/被豁免掩盖"的最后防线。
#   ⚠️ 第四十三轮（2026-09-28）实测可测面分子 **8542** → 阈值 8440 → **8536**（实测 − 6 行抖动余量）。
#      ⚠️ 本轮分母 **9584 / 10074 一字未动**；真实进度 **8448 → 8544（+96 行）**，生产代码 0 行改动。
#      ⚠️ 分子下限是**绝对数、不随口径变化** ⇒ 它照旧是"分母被稀释/被豁免掩盖"的最后防线。
#   ⚠️ 每日门禁值守（2026-09-26 晚间）续五实测可测面分子 **7641** → 阈值 7494 → **7637**（实测 − 4 行抖动余量）。
#   ⚠️ 第三十七轮（2026-09-27）实测可测面分子 **7949** → 阈值 7867 → **7943**（实测 − 6 行抖动余量）。
#   ⚠️ 第三十八轮（2026-09-27）实测可测面分子 **8091** → 阈值 7943 → **8085**（实测 − 6 行抖动余量）。
#   ⚠️ 第三十九轮（2026-09-27）实测可测面分子 **8206** → 阈值 8085 → **8200**（实测 − 6 行抖动余量）。
#   ⚠️ 第四十轮（2026-09-27）实测可测面分子 **8315** → 阈值 8200 → **8309**（实测 − 6 行抖动余量）。
#      ⚠️ 本轮分母 **9576 / 10066 一字未动**（唯一的生产代码改动是 BUG-075 的
#      `parts[0]` → `parts[0].toLowerCase()`，**改的是既有行、不增行**）。
#   ⚠️ 第四十一轮（2026-09-27）实测可测面分子 **8446** → 阈值 8309 → **8440**（实测 − 6 行抖动余量）。
#      ⚠️ 本轮分母**涨了 8 行**（可测面 9576 → 9584 / 全局 10066 → 10074），
#      来源与判据见文件上方 COVERAGE_MIN 的「第四十一轮」段（Dart 只收录被编译过的行）。
#      真实进度 **8317 → 8448（+131 行）**；其中 `pair_qr_screen` **−1 行**已如实计入。
#      ⚠️ 分子下限是**绝对数、不随口径变化** ⇒ 它照旧是"分母被稀释/被豁免掩盖"的最后防线。
#   ⚠️ 第三十八轮（2026-09-27）实测可测面分子 **8091** → 阈值 7943 → **8085**（实测 − 6 行抖动余量）。
#      ⚠️ 本轮分母也涨了 14 行（可测面 9562 → 9576）：那是**注入缝自身的可执行行**，
#      如实计入分母 —— 不许靠"把新代码算进豁免"来美化比率（分子 7951 → 8091，**+140 行**）。

# 压测层"红"的**定性**：负载高 → 测量无效（环境阻塞）；负载正常 → 真回归。
#
# 抽成函数只有一个理由：**判定逻辑要能被单独验证**（注入式验证见 docs/17 §47⑦）。
# 内联在 if 里的话，验证它就得跑完整门禁 —— 而它决定的是 RC=1 还是 RC=3，
# 判错方向的代价（把回归当噪声放过去 / 把噪声当回归报上去）都不小。
#   用法： verdict=$(perf_verdict "$LOAD_START" "$LOAD_NOW")
perf_verdict() {  # $1=压测前负载  $2=失败时负载  → 回显 BLOCKED | FAIL
  if [ "${1:--1}" -ge "$LOAD_SUSPECT" ] || [ "${2:--1}" -ge "$LOAD_SUSPECT" ]; then
    echo "BLOCKED"
  else
    echo "FAIL"
  fi
}

# 功能层"红"的**定性**：Dart VM 自身因宿主内存/线程耗尽而崩 ≠ 代码回归。
#
# 2026-09-28 实测（第四十八轮 post-ratchet 终验 X9）：
#   `flutter test --exclude-tags perf --coverage` 在 01:28 处**整进程崩**，
#   74 例被标 "did not complete"，日志里**一条断言失败都没有**，只有：
#     Shell: === Crash occurred when compiling ...persistent_hash_map... in optimizing JIT mode
#     Shell: .../dart/runtime/vm/zone.cc: 95: error: Out of memory.
#     Shell: .../dart/runtime/vm/os_thread.cc: 345: error: Could not start thread DartWorker: 22
#   且**三个不同 pid 同时崩** ⇒ 宿主级内存/线程耗尽
#   （本机 16 逻辑核 ⇒ 多路并发的 flutter_tester 各自跑 optimizing JIT）。
#   **这不是代码回归** —— 不区分就会报成 `[FAIL] 功能层`
#   （RC=1 代码回归），让人去追一个不存在的 bug。
#   与压测层同哲学：**把噪声当回归报上去是更贵的错误**。
is_vm_resource_crash() {  # $1=输出 → 0 = 撞上 Dart VM 自身的资源耗尽（非断言失败）
  printf '%s' "$1" \
    | grep -qE "error: Out of memory\.|Could not start thread DartWorker|Crash occurred when compiling"
}

# 开工前的整机负载提示（只提示，不改判定；判定逻辑在压测层失败分支）。
LOAD_START=$(machine_load)
if [ "$LOAD_START" -ge "$LOAD_SUSPECT" ]; then
  echo "⚠️  整机 CPU 负载 = ${LOAD_START}% —— 压测层（墙钟预算）结果可能不可信。"
  echo "    常见来源：另一个项目的 Docker / WSL2（vmmemWSL）/ 模拟器 / 构建。"
  echo "    建议等它结束再跑；否则压测层若红，门禁会按**环境阻塞(RC=3)**报，而不是真回归。"
  echo "    查占用： tasklist | grep -iE 'vmmem|docker|wsl'"
fi

# `ONLY_DEVICE=1` 只跑设备层：迭代设备用例时不必重跑 465 例宿主测试。
if [ "${ONLY_DEVICE:-0}" != "1" ]; then

echo "=== 门禁 1/4: flutter analyze ==="
out=$(flutter analyze 2>&1 | tr '\r' '\n')
echo "$out" | tail -1
if echo "$out" | grep -q "No issues found"; then
  echo "[PASS] analyze"
else
  # ⚠️ 只 `tail -1` 会得到一句 "N issues found." —— **是哪一条被吞掉了**。
  # 2026-09-21 实测踩到：门禁报 "[FAIL] analyze" 却看不到问题，
  # 只能手工再跑一次 analyze 才知道。与 `fail_dump` 同源（失败必须留证据）。
  echo "[FAIL] analyze"
  echo "$out" | grep -E "^\s*(info|warning|error)\s*-" | head -20 || true
  fail_dump analyze "$out"
  FAIL=$((FAIL+1))
fi

echo "=== 门禁 2/4: 功能层（--exclude-tags perf）==="
# 功能层**顺带产出** coverage/lcov.info（第 4 步的 ratchet 据此判定），
# 不额外多跑一遍测试。SKIP_COVERAGE=1 退回裸跑。
COV_FLAG=""
if [ "${SKIP_COVERAGE:-0}" != "1" ]; then COV_FLAG="--coverage"; fi
# ⚠️ 并发**只在"撞上 VM 资源耗尽"的重跑里**下调：首次仍用默认并发，
#    这样"正常路径"的覆盖率口径与历史各轮逐字一致，不引入任何口径漂移。
FUNC_CONC=""
run_func() { flutter test --exclude-tags perf $COV_FLAG $FUNC_CONC 2>&1 | tr '\r' '\n'; }
out=$(run_func)
echo "$out" | tail -1
if echo "$out" | grep -q "All tests passed"; then
  echo "[PASS] 功能层"
elif is_vm_resource_crash "$out"; then
  echo "[?] 功能层首次撞上 Dart VM 资源耗尽（**无任何断言失败**）→ 降并发重跑确认…"
  echo "$out" | grep -E "Out of memory|Could not start thread|Crash occurred when compiling" | head -4 || true
  fail_dump 功能层 "$out"
  if [ "${FUNC_RETRY:-1}" = "1" ]; then
    FUNC_CONC="--concurrency=${FUNC_RETRY_CONC:-4}"
    out2=$(run_func)
    echo "$out2" | tail -1
    if echo "$out2" | grep -q "All tests passed"; then
      echo "[PASS] 功能层（降并发重跑确认 ✅）"
      echo "  ⚠️ 首次是**宿主内存/线程耗尽**，不是代码回归；本次重跑并发 = ${FUNC_RETRY_CONC:-4}。"
      echo "     已留证：首次完整输出在 \${GATE_LOG_DIR:-/tmp}/gates_功能层.log。"
    elif is_vm_resource_crash "$out2"; then
      echo "[BLOCKED] 功能层：连续两次 Dart VM 资源耗尽 —— **不是代码回归，也不是通过**"
      echo "  请在空闲机器上复跑： flutter test --exclude-tags perf --coverage"
      fail_dump 功能层重跑 "$out2"
      BLOCKED=$((BLOCKED+1))
    else
      echo "[FAIL] 功能层（重跑未过，且**不是** VM 资源耗尽 → 真回归）"
      echo "$out2" | grep -E "\[E\]|Expected:|Actual:" | head -6 || true
      fail_dump 功能层重跑 "$out2"
      FAIL=$((FAIL+1))
    fi
  else
    echo "[FAIL] 功能层（FUNC_RETRY=0，未降并发重跑确认）"
    FAIL=$((FAIL+1))
  fi
else
  echo "[FAIL] 功能层"
  echo "$out" | grep -E "\[E\]|Expected:|Actual:" | head -6 || true
  fail_dump 功能层 "$out"
  FAIL=$((FAIL+1))
fi

echo "=== 门禁 3/4: 压测层（--tags perf --concurrency=1，必须单并发）==="
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
      # 重跑也红 —— 但**先看负载**：墙钟预算在机器被别的项目占满时
      # 两次都会红，这不是回归，是测量无效（见 machine_load / perf_verdict）。
      LOAD_NOW=$(machine_load)
      verdict=$(perf_verdict "$LOAD_START" "$LOAD_NOW")
      echo "  · 失败时整机 CPU 负载 = ${LOAD_NOW}%（阈值 ${LOAD_SUSPECT}%）→ 定性: $verdict"
      if [ "$verdict" = "BLOCKED" ]; then
        echo "[BLOCKED] 压测层：机器负载 ${LOAD_START}% → ${LOAD_NOW}%，**墙钟预算测量无效**。"
        echo "  这不是代码回归，也**不是通过** —— 请在空闲机器上复跑："
        echo "    flutter test --tags perf --concurrency=1"
        echo "$out2" | grep -E "\[E\]|Expected:|Actual:" | head -6 || true
        fail_dump 压测层重跑 "$out2"
        BLOCKED=$((BLOCKED+1))
      else
        echo "[FAIL] 压测层（重跑仍未过，且机器负载正常 → 真回归）"
        echo "$out2" | grep -E "\[E\]|Expected:|Actual:" | head -6 || true
        fail_dump 压测层重跑 "$out2"
        FAIL=$((FAIL+1))
      fi
    fi
  else
    echo "[FAIL] 压测层（PERF_RETRY=0，未重跑确认）"
    FAIL=$((FAIL+1))
  fi
fi

# ---------- 门禁 4/4：覆盖率 ratchet ----------
# 只降不升：跌破 COVERAGE_MIN 即红。lcov.info 由第 2 步（功能层）顺带产出。
if [ "${SKIP_COVERAGE:-0}" != "1" ]; then
  echo "=== 门禁 4/4: 覆盖率 ratchet（COVERAGE_MIN=${COVERAGE_MIN}%）==="
  if [ ! -f coverage/lcov.info ]; then
    # 没有产物**不等于**通过 —— 与"设备没接上"同源（未执行 ≠ 成功）。
    echo "[BLOCKED] 覆盖率：找不到 coverage/lcov.info（功能层可能没跑成）"
    BLOCKED=$((BLOCKED+1))
  else
    out=$(dart run tool/coverage_report.dart --gate="$COVERAGE_MIN" --min-covered="$MIN_COVERED" 2>&1 | tr '\r' '\n')
    echo "$out" | grep -E "全局|可测面|门禁(通过|未过)|❌ 报告不可信" | head -6 || true
    if echo "$out" | grep -q "门禁通过"; then
      echo "[PASS] 覆盖率 ratchet"
    elif echo "$out" | grep -q "门禁未过"; then
      echo "[FAIL] 覆盖率 ratchet：跌破 ${COVERAGE_MIN}%"
      echo "  ⇒ 两条路：① 补测试把它推回去；② **有意识地**下调 COVERAGE_MIN，"
      echo "     并在 docs/12 本轮章节写明理由（下调留痕，否则 ratchet 失效）。"
      fail_dump 覆盖率 "$out"
      FAIL=$((FAIL+1))
    else
      # 工具自己报"报告不可信"（分母不完整 / 豁免幽灵文件 / 白名单失效）——
      # 这类问题的危险之处是**它会让数字变好看**，所以必须当失败处理。
      echo "[FAIL] 覆盖率报告不可信 —— 先修工具报的问题（见下方 ❌ 段）"
      echo "$out" | tail -20
      fail_dump 覆盖率 "$out"
      FAIL=$((FAIL+1))
    fi
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
    # P2-28：用户**明确**要求 WITH_DEVICE=1 却连 adb 都没有 ⇒ 这是"未执行"，
    # 不是"通过"。默认计 BLOCKED（RC=3），只有显式 ALLOW_DEVICE_SKIP=1 才放行。
    if [ "${ALLOW_DEVICE_SKIP:-0}" = "1" ]; then
      echo "[SKIP] 设备端门禁：PATH 上没有 adb（需要 \$ANDROID_HOME/platform-tools）；ALLOW_DEVICE_SKIP=1 显式放行跳过"
    else
      echo "[BLOCKED] 设备端门禁：PATH 上没有 adb —— 用户明确要求 WITH_DEVICE=1 却无法执行。"
      echo "          未执行 ≠ 通过：装好 \$ANDROID_HOME/platform-tools 后重跑，"
      echo "          或显式 ALLOW_DEVICE_SKIP=1 承认「跳过设备层」。"
      BLOCKED=$((BLOCKED+1))
    fi
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
      # 振动能力 P0 取证（docs/20 §13）：四条能力 + usage 传递 + 包络一致性 + 停止。
      # ⚠️ 本文件是 **BUG-074**（Kotlin `Long`→`Int` 赋值导致 Android 端从未构建成功）
      #    的天然回归锁 —— 它一旦被跑，就必然先过 `assembleDebug`。
      run_device_test "设备振动（vibrate_device_test，6 例）" integration_test/vibrate_device_test.dart device_vibrate
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
    # P2-28：同上 —— 没有设备时默认 BLOCKED，只有 ALLOW_DEVICE_SKIP=1 才放行。
    if [ "${ALLOW_DEVICE_SKIP:-0}" = "1" ]; then
      echo "[SKIP] 设备端门禁：没有可用设备（adb devices 为空）；ALLOW_DEVICE_SKIP=1 显式放行跳过"
    else
      echo "[BLOCKED] 设备端门禁：没有可用设备（adb devices 为空）—— 用户明确要求 WITH_DEVICE=1 却无法执行。"
      echo "          未执行 ≠ 通过：接上真机/启动模拟器后重跑，"
      echo "          或显式 ALLOW_DEVICE_SKIP=1 承认「跳过设备层」。"
      BLOCKED=$((BLOCKED+1))
    fi
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
