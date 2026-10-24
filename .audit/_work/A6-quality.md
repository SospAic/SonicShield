# A6 — 静态检查 / 测试证据 / 静默错误扫描

- **项目**：SonicShield（`E:\SonicShield`），Flutter/Dart，版本 `1.9.9+32`
- **工作包**：A6（失败用例根因 / 门禁三落点一致性 / 测试质量 / 静默错误 / 文档漂移）
- **审计方式**：**纯静态只读**。本沙箱无 `dart`/`flutter`（`dart: command not found`），**未运行任何测试、未运行 analyze、未使用计划任务中继**。
- **写入范围**：本文件是本次工作包**唯一**的写产物（`.audit/_work/A6-quality.md`）。未修改 `lib/`、`test/`、`android/`、`packages/`、`scripts/`、`.github/` 任何文件，未做任何 git 写操作。
- **代码基线**：`lib/` 107 文件 / 43,510 行；`test/` 207 文件 / 67,689 行；`integration_test/` 11 文件。
- **工作区状态（重要）**：审计时工作区有**未提交的 R93 改动**（`action.dart`、`vibrate_caps.dart`、`counter_plan_materializer.dart`、`task_editor_screen.dart`、`vibrate_session.dart`、`NativeBridgePlugin.kt`、`cov_services_test.dart`、`task_editor_vibrate_test.dart`，未跟踪 `test/r93_vibrate_dnd_test.dart`）。本报告所有行号以**工作区**为准，不是 `HEAD`。

## 证据来源与引用纪律（全文统一）

| 证据 | 位置 | 性质 |
|---|---|---|
| 最近一次完整门禁 | `_pt/r93gate.log`（63 行，mtime 2026-10-21 17:07:04） | **他人执行的产物**，本报告只做读取与解读 |
| 门禁摘要（GBK 乱码） | `_pt/r93gate.txt` | 同上 |
| 功能层完整输出 | `/tmp/gates_功能层.log`（mtime 16:56:44，547 KB） | 同上（`gates.sh` 的 `fail_dump` 落盘） |
| 压测层首次完整输出 | `/tmp/gates_压测层首次.log`（mtime 17:03） | 同上 |
| 覆盖率产物 | `coverage/lcov.info`（mtime 16:56:44） | 本次门禁功能层顺带产出 |
| 历史压测通过记录 | `_pt/envchk_perf.txt`（2026-10-18 23:35）、`_pt/r72_perf.log`、`_pt/aa3/bb3/cc3/s3/step3/u3/x3.log` | 同上 |
| 门禁执行入口 | `_pt/r93gate.sh` → `bash scripts/gates.sh` | 证明门禁走的是 `.sh` 而非 `.ps1` |

> **纪律**：凡引用门禁结论，一律写「来自 `_pt/r93gate.log` 第 N 行」，不写「我运行了测试」。

## 证据等级定义

`CONFIRMED`（有日志/产物直接证据，或源码两端闭合）/ `HIGH_CONFIDENCE`（源码事实成立，运行期依赖未实测）/ `SUSPECTED`（有迹象缺一环）/ `NOT_REPRODUCED` / `UNVERIFIED`。

---

# 1. 两个失败用例的根因判定（最高优先级）

## 1.1 VC05「toMap 键集合精确」——**测试锁未同步**（且**已在工作区修好、但从未复跑取证**）

### 结论先行

| 项 | 判定 |
|---|---|
| 性质 | **测试锁未同步**（不是产品缺陷，不是序列化不闭合） |
| 产品侧 | `VibrateCaps.toMap/fromMap` **闭合正确**（8 键一一对应） |
| 现状 | 测试已于 `17:01:34` 补齐新键，**但此后没有任何门禁复跑记录** ⇒ R93 目前**没有绿色门禁证据** |
| 证据等级 | `CONFIRMED` |

### 证据（逐条，带行号）

1. `_pt/r93gate.log:9-13` —— 失败用例名 + `Expected: {` / `Actual: {`（摘要被截断）。
2. `/tmp/gates_功能层.log:681-704` —— **完整**失败体，决定性：

```
681: 00:40 +619 -1: ... VC05 toMap 键集合精确 [E]
682:   Expected: {
683-689:  'hasVibrator': true, 'hasAmplitudeControl': false, 'hasEnvelope': true,
          'minControlPointMs': 24, 'platform': 'android', 'backgroundSupported': false
690:   Actual: {
691-699:  ...同上 6 键... + 'ringerMode': -1, 'dndActive': false
700:   Which: has different length and has extra map key 'ringerMode'
704:   test\cov_services_test.dart 94:7   main.<fn>.<fn>
```

   - `Expected` 只有 **6 键**（旧测试）；`Actual` 有 **8 键**（新模型）。
   - 失败栈指向 `cov_services_test.dart:94:7`。**当前**工作区该文件的 `expect(` 在 **97 行**（`test/cov_services_test.dart:97`），而 `94` 行现在是 `ringerMode: 1,`。二者相差正好 **3 行** —— 与 `git diff test/cov_services_test.dart` 新增的 3 行（`ringerMode` / `dndActive` 实参 + 1 行注释）**逐行吻合** ⇒ 门禁跑的是**旧测试**。

3. 时间线（决定性）：
   - `lib/domain/models/vibrate_caps.dart` mtime **15:50:46**（先改模型，`git diff` 新增 `ringerMode`/`dndActive` 两个字段 + `toMap` 两键，见 `vibrate_caps.dart:21-22, 94-95, 105-106`）
   - `/tmp/gates_功能层.log` 与 `coverage/lcov.info` mtime **16:56:44**（功能层在此时已跑完，VC05 已判红）
   - `test/cov_services_test.dart` mtime **17:01:34**（**在功能层跑完之后**才补的测试）
   - `_pt/r93gate.log` mtime **17:07:04**（门禁整体结束，`GATES_RC=1`，见 `:63`）
   ⇒ 补测试发生在门禁**运行期间但功能层之后**，因此**该门禁结论只对 16:56 之前的工作区有效**。

4. 交叉验证（静态）：当前 `vibrate_caps.dart:98-107` 的 `toMap()` 恰好产出 8 个键；`test/cov_services_test.dart:97-106` 的期望 map 恰好是同样 8 键同值 ⇒ **按当前工作区静态推演，VC05 必过**（`NOT_REPRODUCED` 为"当前不可复现"）。

### 因果链

`R93 给 VibrateCaps 加 ringerMode/dndActive（15:50）` → `toMap 多出 2 键` → `cov_services_test VC05 仍断言旧 6 键（键集合精确相等）` → `16:56 功能层判红` → `17:01 补测试` → `17:07 门禁以旧代码收尾（RC=1）` → **无复跑**。

### 修复建议

1. 重跑一次门禁（`.sh` 入口）取证，把 `GATES_RC=0` 的日志落 `_pt/r94gate.log`；
2. 把「模型增删字段 ⇒ 同文件 toMap 键集锁必须同 PR 更新」写进 R93 收口说明；
3. 建议把 VC05 的"键集合精确"改成**双向差分**断言（`actual.keys.toSet()..removeAll(expected.keys)` 为空 + 反向），失败信息可直接指出多/少了哪个键，而不是只报 `different length`。

### 为何不算产品缺陷

`fromMap` 对两个新键都取保守缺省（`-1` / `false`，`vibrate_caps.dart:94-95`），`toMap/fromMap` 往返闭合；`VC06 往返相等` 用例在门禁中**通过**（未出现在失败清单）。序列化本身没有缺口。

---

## 1.2 WT-02「parseUri 1 万次 ≤ 300ms」——**墙钟抖动（min-of-1 测量缺陷）**，非算法退化

### 结论先行

| 项 | 判定 |
|---|---|
| 性质 | **墙钟抖动**（不是回归）：同轮重跑通过 + 9 份历史记录通过 + 被测实现自 2026-10-13 未变 + 门禁自身判据认定 67% 负载下测量无效 |
| 是否算法复杂度问题 | **否**。`parseUri` 是 O(n) 的 3 段字符串处理，2026-10-13 后未改动 |
| 根因（更深一层） | 该用例用**裸 `Stopwatch` 单次采样**（min-of-1），**违背本文件头自己的约定**与项目 BUG-053/055 已定下的纪律 |
| 实测 | 321ms vs 预算 300ms（**超 7%**），首跑发生在 CPU 负载 **67%** 的机器上 |
| 证据等级 | `CONFIRMED` |

### 证据

1. `_pt/r93gate.log:31-36` —— 首次失败：`Expected: a value less than or equal to <300>` / `Actual: <321>`。
2. `/tmp/gates_压测层首次.log:172-180` —— 完整体：`00:48 +14 -1 ... Actual: <321>`，失败行 `test\performance_v2_test.dart 70:7`（即 `expect(sw.elapsedMilliseconds, lessThanOrEqualTo(300))`，`test/performance_v2_test.dart:70`）。
3. `_pt/r93gate.log:52-53` —— **同轮重跑**：`02:04 +24: All tests passed!` / `[PASS] 压测层（重跑确认 ✅）` ⇒ **同一份代码、同一台机器、几十分钟后通过**。这是"测量问题而非回归"的最强单条证据。
4. `_pt/r93gate.log:1-3` —— 门禁**自己**在开跑前打印：`整机 CPU 负载 = 67% —— 压测层（墙钟预算）结果可能不可信`。本次门禁恰好落在这个预警条件下。
   - 更关键：`scripts/gates.sh:137` `LOAD_SUSPECT="${LOAD_SUSPECT:-60}"`，`:664` 在 `LOAD_START ≥ 60` 时打印该预警，`:637` 的 `perf_verdict` 在负载 ≥60% 时把压测失败定性为 **BLOCKED（RC=3，环境阻塞）而不是 FAIL**。
   - 本次因**重跑通过**走了 `[PASS]`（`:754`），没有触发 `perf_verdict`；但按项目**自己的判据**，67% 负载下的 321ms 本就**不足以判定回归**。
5. 历史单跑通过：`_pt/envchk_perf.txt:114-115`（2026-10-18）—— WT-01 与 WT-02 在同一秒内完成（`00:15 +14` → `00:15 +15`），即 WT-02 **< 1s**（含测试框架开销）。另有 `_pt/aa3.log:70`、`bb3.log:70`、`cc3.log:73`、`f_step3.log:67`、`r72_perf.log:143`、`s3.log:67`、`step3.log:66`、`u3.log:70`、`x3.log:70` 共 9 份历史记录，WT-02 全部在 `+14→+15` 之间通过。
6. 被测实现未变：`lib/remote/protocol.dart:728-737`（`parseUri`）最近一次改动是 `7ca4590`（R84-2，2026-10-13），`git log -- lib/remote/protocol.dart` 无 R93 相关提交；文件 mtime 2026-10-13。**R93 没有碰这条路径。**
7. 算法成本：`parseUri` 只做 `startsWith` + 1 次 `substring/split` + `toLowerCase` + `Uri.decodeComponent` + `replaceAll/toUpperCase` + 2 次长度判断，**无循环、无正则、无 I/O**。20000 次调用 = 线性 20000×常数，**不存在可退化的复杂度**。

### 因果链

`WT-02 用裸 Stopwatch 单次采样` → `单次样本被 JIT/GC/调度噪声支配` → `67% CPU 负载下采到 321ms（超预算 7%）` → `门禁判红` → `PERF_RETRY 重跑` → `同一代码 24/24 通过`。

### 为什么会"偶红"——项目自己的既有结论

- `test/performance_v2_test.dart:26-31` 文件头明确写着：**「已统一用 `benchMs`/`benchMsAsync`（预热 + 取最小值）对准算法成本」**。
- `test/perf_bench.dart:10-20` 解释原因：单次采样测的是 JIT 冷启动 + GC + 页错误。
- `docs/12-测试报告.md` §28.3（BUG-053）与 §29.6（BUG-055）已两次定案：**「任何用例都不得用 `runs: 1`（min-of-1 = 没有抗噪）」「余量要和噪声幅度比，不是和基线比」**。§29.6 实测同一代码在负载下放大 **5.2×**。
- 但 `WT-01/WT-02/WT-03/GT-06` 四条（`performance_v2_test.dart:46/62/74/208`）**仍在用裸 Stopwatch**，即 `docs/12 §28` 的修复**只覆盖了 GT-07**，没覆盖 WT 组。

### 修复建议（按优先级）

1. **把 WT-01/02/03、GT-06 改成 `benchMs(...)`**（与 GT-04/05/07、MT-01 一致），阈值按"实测 JIT 基线 × 3"重定。这是**唯一能同时消除假红与收紧阈值**的改法（BUG-053 的净效果就是"不再假红 + 收紧 2.5 倍"）。
2. 若暂不改测量方式，至少把预算从 300ms 抬到与噪声幅度相称（历史单跑 <1s，含框架开销；建议先测得 min-of-5 基线再定），并在用例名里标注"JIT 护栏"。
3. **不要**把 `PERF_RETRY` 当长期方案：它只是把噪声在脚本层消化，`PERF_RETRY=0` 时仍会红（`gates.sh:756`）。

---

# 2. 门禁与 CI 三落点一致性审计

## 2.1 步骤与阈值对照表

| 维度 | `scripts/gates.sh`（1054 行） | `scripts/gates.ps1`（283 行） | `.github/workflows/ci.yml`（162 行） | 一致？ |
|---|---|---|---|---|
| 1/4 analyze | `gates.sh:674-675` `flutter analyze` | `gates.ps1:105-106` 同 | **无此步骤** | ❌（CI 缺失，见 QUA-04） |
| 2/4 功能层 | `gates.sh:697` `flutter test --exclude-tags perf --coverage` | `gates.ps1:132/147` 同 | **无** | ❌ |
| VM 资源耗尽降并发重跑 | `gates.sh:703-726`（`FUNC_RETRY`/`FUNC_RETRY_CONC`） | `gates.ps1:139-158`（同语义） | — | ✅ |
| 3/4 压测层 | `gates.sh:737` `--tags perf --concurrency=1` | `gates.ps1:170` 同命令 | **无** | ⚠️ 命令一致 |
| 压测失败→**单独重跑一次** | `gates.sh:746-778`（`PERF_RETRY`，默认开） | **完全没有** | — | ❌ **（QUA-03）** |
| 压测失败→**按 CPU 负载定性 BLOCKED** | `gates.sh:636-638` `perf_verdict()` + `:758-771` | **完全没有** | — | ❌（QUA-03） |
| 开跑前 CPU 负载预警 | `gates.sh:109-136`（`LOAD_START`） | **没有** | — | ❌（QUA-03） |
| 4/4 覆盖率 ratchet | `gates.sh:786-793` | `gates.ps1:191-215` | **无** | ⚠️ 阈值同、步骤 CI 缺 |
| 环境阻塞 RC=3 | `gates.sh`（`BLOCKED` 计数） | `gates.ps1:279 exit 3` | — | ✅ |
| 设备层 BLOCKED 语义 | `gates.sh` + `ALLOW_DEVICE_SKIP` | `gates.ps1:229-255` | — | ✅（`GEC-07/08` 锁） |
| `--exclude-tags` 滥用 | 仅用于分层（perf 与非 perf 互补），无"排除以变绿" | 同 | — | ✅ |
| `|| true` | **10 处**：9 处是 `grep ... | head | ... || true` 的**展示管道**（`gates.sh:90/684/704/721/731/748/767/772/793`）+ 1 处 `cache_real_apk || true`（`:998`，设备层 APK 缓存，best-effort） | 无 | 无 | ✅ 不影响判据 |
| `continue-on-error` | 无 | 无 | 无 | ✅ |
| 注释掉的门禁步骤 | 无（`grep '^\s*#\s*flutter (test|analyze)'` 命中 0） | 无 | — | ✅ |

## 2.2 覆盖率基线常量核对表

| 常量 | 代码定义位置与实际值 | `gates.sh` | `gates.ps1` | 文档 | 一致？ |
|---|---|---|---|---|---|
| `COVERAGE_MIN` | `gates.sh:489` `"${COVERAGE_MIN:-98.6}"` | 98.6 | `gates.ps1:191` `else { '98.6' }` | `CHANGELOG.md:138` `COVERAGE_MIN=98.6` | ✅ 三处一致 |
| `MIN_COVERED` | `gates.sh:602` `"${MIN_COVERED:-12872}"` | 12872 | `gates.ps1:192` `else { '12872' }` | `CHANGELOG.md:138` `MIN_COVERED=12872` | ✅ 三处一致 |
| `kDeviceExemptLines` | `test/doc_gate_consistency_test.dart:331` `= 710 + 72 + 74`（**856**） | 不引用 | 不引用 | `CHANGELOG.md:139` 「856 行（710+72+74）」 | ✅ |
| `kDeviceExemptCovered` | `test/doc_gate_consistency_test.dart:335` `= 61` | 不引用 | 不引用 | `CHANGELOG.md:139` 「已覆盖 61」 | ✅ |
| ps1 头部 usage 示例 | `gates.ps1:16-17` 写 `COVERAGE_MIN = '98.8'` / `MIN_COVERED = '12653'` | — | — | 与同文件 191/192 行**自相矛盾** | ❌ **陈旧**（QUA-11，P3） |

### 豁免面几何实测复核（关键）

用 `coverage/lcov.info`（R93 门禁功能层产物，16:56:44）**逐文件复算**：

| 文件 | `LF`（可执行行） | `LH`（已覆盖） |
|---|---|---|
| `lib/services/background_engine.dart` | **710** | 8 |
| `lib/main.dart` | **72** | 0 |
| `lib/services/neural_tts.dart` | **74** | 53 |
| **合计** | **856** | **61** |

- 全局 `LF=15223 / LH=14282`（106 个 record，与 `_pt/r93gate.log:57` 的 `93.82% 14282/15223` **逐位一致**）。
- 可测面 = `15223 − 856 = 14367`，`14282 − 61 = 14221` ⇒ **98.98%（14221/14367）**，与 `_pt/r93gate.log:58` **逐位一致**。
- ⇒ **`kDeviceExemptLines=856` / `kDeviceExemptCovered=61` 与 R93 实测完全对得上**；R93 **没有**改这三个豁免文件（`git status` 不含它们），几何未失配。**结论：豁免面几何没有缺陷。**

> 注意：`wc -l` 是 2388 / 250 / 220 行，与 `LF` 710 / 72 / 74 **不是同一口径** —— `LF` 是 lcov 只统计"被编译过的可执行行"。用 `wc -l` 核对会得到"失配"的**假结论**，不要这么查。

## 2.3 CI 是否存在"跳过/弱化测试"

**存在，但性质是"有意识的裁撤 + 机器锁定"，不是偷偷弱化。**

- `ci.yml:11-19` 自述：`2026-10-10：CI 收敛为只构建产物（不再跑 analyze/test/coverage/emulator —— 那部分由本地 scripts/gates.sh 门禁承担，省 Actions 计费）`。
- `ci.yml` 全部步骤只有：`pub get` → 恢复 keystore → `flutter build apk --release` → `apksigner verify` → 上传 APK；以及 iOS `build ios --no-codesign` → 打 IPA → 上传。**零 analyze、零 test、零覆盖率**。
- 这不是"漏配"，而是被 `test/gate_entrypoint_consistency_test.dart:113-136` 的 `GEC-06` **机器锁强制**为当前形状（`!code.contains('analyze-test')`、`!code.contains('--min-covered=')`）—— 也就是说**想把测试加回 CI，反而会判红**。
- `ci.yml:124` 有 `pod --version || true`，属诊断命令，不影响判据。

**判定**：不构成"规则 6：跳过/弱化测试"的**隐瞒式**违规（有注释、有机器锁、有本地门禁承接）。但客观后果必须登记：**PR/push 上没有任何自动化测试门**，唯一的质量门是"人记得在本地跑 `gates.sh`"，且这道门当前是红的（`GATES_RC=1`）。见 QUA-04。

---

# 3. 测试质量审计

## 3.1 全局计数（静态 grep，`test/` 207 文件 / 67,689 行）

| 指标 | 数量 | 说明 |
|---|---|---|
| `test(` 声明 | 2,249 | 门禁运行期计数 `+2917 -1`（`_pt/r93gate.log:26`），差 10 条来自参数化/循环生成用例 |
| `testWidgets(` 声明 | 659 | |
| `expect(` 总数 | 8,223 | 平均 **2.83 断言/用例** |
| `skip:` / `@Skip` / `solo` | **0 / 0 / 0** | ✅ **无静默禁用用例** |
| `expect(true, true)` / `expect(1, 1)` | **0** | ✅ 无字面恒真断言 |
| 零 `expect` 的测试文件 | **0** | ✅ |
| `pumpAndSettle` | 396 处，**0 处显式超时** | 全部走默认 10 分钟超时（见 QUA-13） |
| `await Future.delayed(...)` 固定等待 | **0** | ✅ 项目已系统清除固定 sleep |
| 测试内 `try/catch`（真实代码，非字符串样本） | **1**（`asset_import_test.dart:336`） | 捕获后**断言异常类型**（`expect(caught, isA<StateError>())`），非吞失败 ✅ |
| 读 `lib/` 源码的测试文件 | **48**（`readAsStringSync` 共 80 文件） | 源码文本锁，见 3.3 |
| 其中**未**使用统一 `stripComments`（`test/support/source_text.dart`） | **13** | 见 QUA-10 |
| `indexOf(` 出现次数 | 209（53 文件） | 含非源码用途；`methodBody` 等helper 被 29 文件 / 251 处引用 |

## 3.2 抽样结果表（18 个文件，逐个人工阅读）

| # | 文件 | 用例/断言 | 观察到的问题 | 严重度 |
|---|---|---|---|---|
| 1 | `test/performance_v2_test.dart` | 11 / 25 | **7 处裸 `Stopwatch` 单次采样**（`:46/62/74/118/129/140/208`），与文件头 `:29` 的「已统一用 benchMs」**自相矛盾**；WT-02 因此假红 | **P1**（QUA-02） |
| 2 | `test/performance_test.dart` | 13 / — | 9 处裸 `Stopwatch`（`:145/159/196/214/276/287/297/320/331`），同源问题 | P1（并入 QUA-02） |
| 3 | `test/cov_services_test.dart` | 56 / 155 | VC05 键集锁曾落后于模型（已修未复跑）；其余用真 mock 通道，断言实打实 | P2（QUA-01） |
| 4 | `test/doc_gate_consistency_test.dart` | 55 / 110 | 强锁（含反面样本），但只做**文档↔文档**自洽，不校验**文档↔实测** ⇒ 抓不到 R93 基线未回刷 | P2（QUA-06） |
| 5 | `test/gate_entrypoint_consistency_test.dart` | 10 / — | 自述「只比默认阈值，不比完整语义」（`:22-25`）⇒ 压测重跑/负载定性缺口无人锁 | P2（QUA-03） |
| 6 | `test/r93_vibrate_dnd_test.dart` | 10 / — | 新增；2 条 Kotlin 源码文本锁（**必要**，analyze 不覆盖 Kotlin）；`VC-05` 用 `>=3` 计数属弱断言（删掉新的 dnd catch 仍可能绿） | P3 |
| 7 | `test/task_editor_vibrate_test.dart` | 17 改 2 | 断言具体（开关态 + 副标题文案含「穿透系统勿扰」），R93 改后语义正确 | ✅ 良好 |
| 8 | `test/silent_failure_locks_test.dart` | 35 / — | SLB 行为锁 + SLS 源码锁 + **SLX-90 反面样本 18 条**（每条都证明判据非恒真） | ✅ 全仓最强项 |
| 9 | `test/support_source_text_test.dart`（STX） | — | 剥注释工具的**自测**，含反例 | ✅ 良好 |
| 10 | `test/device_exemption_lock_test.dart` | 10 / 12 | 几何锁与 lcov 实测一致（856/61） | ✅ 有效 |
| 11 | `test/foreground_service_lock_test.dart` | 4 / 4 | 纯源码锁；文件头明确「断言必须非恒真」并解释插件源码事实 | ✅ 良好 |
| 12 | `test/exempt_functional_locks_test.dart` | 11 / 21 | 源码锁 + 真 DB 行为锁混合；自行归一化 CRLF，**未用统一 stripComments** | P3（QUA-10） |
| 13 | `test/pair_qr_screen_test.dart` | 17 / 148 | 30 处 `pumpAndSettle`；断言密度 8.7/例，覆盖权限全档位与失败路径 | ✅ 良好 |
| 14 | `test/guard_screen_test.dart` | — / 43 | 历史"挂死整轮"（docs/12 §71）已修；现 4 处 settle | ✅ |
| 15 | `test/asset_import_test.dart` | — | PAW-02（`:328`）用 `try/catch`（`:336`）捕获后断言异常**原样抛出** + `.part` 清理，是"不吞失败"的正面样本 | ✅ 良好 |
| 16 | `test/task_editor_deep_test.dart` | 25 settle | TEI 系列显式覆盖异常路径（空音源告警、音源库读取失败 toast、过去时刻被拦） | ✅ 良好 |
| 17 | `test/bl_gap_closure_test.dart` | — | BL-PTT-01 为历史"并发偶红"用例，现用有界轮询 | ✅ |
| 18 | `test/engine_reentrancy_test.dart` | — | 其中的 `catch` 全部位于**字符串反面样本**里，不是真 try/catch | ✅ 无问题 |

**抽样结论**：
- **未发现**断言空转、`skip` 滥用、`pumpAndSettle` 掩盖异步（无一处用 settle 代替对异步结果的断言）、try/catch 吞掉断言失败。
- 项目对"恒真断言 = 没测"有制度化约束（`test/support/source_text.dart:1-30`、`silent_failure_locks_test.dart` 的 SLX 系列），**质量水位明显高于一般项目**。
- 真实短板集中在**测量方式**（性能层 min-of-1）与**文档/实测联动**（DGC 只做文档自洽）两处。

## 3.3 源码文本锁的规模与脆弱性

| 指标 | 值 |
|---|---|
| 读 `lib/` 源码的测试文件 | **48 / 207（23.2%）** |
| 未使用统一 `stripComments` 的文件 | **13**（`android_compat_lock_test` / `aot_budget_normalization_test` / `app_icon_lock_test` / `assist_entry_test` / `call_ice_test` / `coverage_sentinel_test` / `dir_path_interpolation_test` / `doc_gate_consistency_test` / `endpoint_by_id_test` / `evidence_files_test` / `exempt_functional_locks_test` / `feature_point_coverage_lock_test` / `log_stats_screen_test` 等） |
| `indexOf(` 出现 | 209 处 / 53 文件 |
| 统一工具被引用 | 29 文件 / 251 处 |

**脆弱性已被现实击中过一次**：`docs/12-测试报告.md` §80 记录 ——「缝的**文档注释**里写出 `_handleRaw` 完整声明签名 ⇒ 四条**没剥注释**的 `methodBody` 锁集体假红」。这正是"注释改动就红"的实证。

**维护风险评估**：48 个文件锁住源码文本，任何一次变量改名 / 提取方法 / 调整形参顺序都可能批量假红；而它们的价值是真实的（`endpoint_service`、Kotlin 侧在宿主上无法实例化）。因此**不建议减少**，建议：
1. 把剩余 13 个文件收敛到 `support/source_text.dart`（一次性，机械改动）；
2. 对"必须锁源码"的断言，统一改为**锁签名锚点 + 锁语义片段**，避免锁整段实现；
3. 新锁必须带**反面样本**（项目已有此惯例，`SLX-90*`、`GEC-06r`、`GEC-07r` 都是）。

## 3.4 覆盖率真实性抽查

抽查方式：从 `coverage/lcov.info`（R93 门禁产物）取 R93 **新增行**的 `DA` 命中数，看聚合 98.98% 是否掩盖了"新增代码零覆盖"。

| 位置 | 语义 | `DA` 命中 |
|---|---|---|
| `lib/services/vibrate_session.dart:183` | `if (caps.notificationsMuted && _respectDnd(action))` | **2** |
| `lib/services/vibrate_session.dart:184` | `degradations.add(` | **0** ❌ |
| `lib/services/vibrate_session.dart:185` | 审计文案首行 | **0** ❌ |
| `lib/domain/models/action.dart:446-459` | `RandomVibrateAction.fromJson` 新默认 | 4/4/2/7/7/7/7/7 ✅ |
| `lib/domain/models/vibrate_caps.dart` | `toMap/fromMap` 新键 | 覆盖 ✅（VC 系列驱动） |

**结论**：`vibrate_session` 的**条件行被执行了 2 次但分支体 0 次** ⇒ R93 的核心可诊断性改进（把"系统静音/勿扰导致振动被吞"写进审计行）**没有任何测试驱动过**。聚合数字 98.98% 完全掩盖了这 2 行。见 QUA-05。

> 这是"覆盖率数字好看 ≠ 新逻辑被测"的典型样本，也说明 `COVERAGE_MIN=98.6` 这类**比率**门槛对"小步新增代码"几乎无约束力（新增 2 行未覆盖只让比率动 0.01pt）。

---

# 4. 静默错误专项扫描（跨全仓）

## 4.1 分类统计表

| 类别 | 命中数 | 代表性位置 | 是否真实缺陷 |
|---|---|---|---|
| **空捕获 `catch (_) {}` / `catch (e) {}`（体为空）** | **0** | — | ✅ 无。6 处 `catch (_)` 全部带注释且是**刻意 best-effort**：`pair_qr_screen.dart:559`（未初始化时 torch 是 no-op）、`sound_library_screen.dart:193`（孤儿文件下次覆盖）、`preset_import.dart:81/85/207/211`（清理失败不得掩盖原始异常，`:88` `rethrow`） |
| **`on Exception catch` 后只 print** | 0（全仓 `on Exception catch` = **0**；`on Object catch` = 60，均带审计/提示/降级说明） | — | ✅ 无 |
| **catch 内 `return true/false/[]/null/0`** | 2 | `assist_host.dart:270-273`（回滚 `s.perms = prev` + `audit('assist.perm','failed')` + `return false`）；`background_service_manager.dart:181-183`（`_startError = '前台服务启动被拒：$e'` + `return false`） | ✅ **不是缺陷**：两者都把错误写进可见状态（审计/错误文案），属"失败要可见"的正解 |
| **`catchError` 吞异常** | 2（另 2 处是注释） | `vibrate_session.dart:490` `unawaited(stopNative().catchError((Object _) {}))`（`dispose()` 是同步接口，注释说明"通道已销毁时吞掉，不制造未处理异步错误"）；`script_executor.dart:293` 取消通知 | ✅ 可接受（低风险，见 4.2 说明） |
| **`unawaited(...)` 忘记 await** | **79** | 绝大多数是事件回调/定时器/取消订阅。**唯一可疑**：`background_engine.dart:490` `unawaited(logs.append(...))` —— `LogRepository.append`（`log_repository.dart:33-43`）**内部无 try/catch**，写库抛错会变成 isolate 内未处理异步错误 | ⚠️ **是**（QUA-08，P3） |
| **`.then(` 无 `catchError`** | 7 | `assist_join.dart:424/435`（`leave().then((_) => _fail(...))`，失败路径本就要 `_fail`）；`controller_service.dart:292`（PTT 串行链，链内自带错误处理）；`node_catalog.dart:227/240`（探测，`Future.wait` 汇总）；`script_executor.dart:245` | ✅ 无缺陷 |
| **`print(` 残留生产路径** | **13** | `main.dart:41/68/75/81`（`runApp` **之前**的降级启动，各带 `// ignore: avoid_print`）；`background_engine.dart:245/250/279/609`（**后台 isolate**，logger 不可用）；`endpoint_service.dart:686/948`（入站丢弃/审计失败） | ✅ 刻意为之（注释明确），不算缺陷。**但**：`print` 在 release 下仍输出到 logcat，含 `$e` 可能带敏感数据（如端点/密钥派生错误的异常文本）—— 属**信息卫生**问题，非静默错误（P3 观察项，未立缺陷） |
| **`?? ''` / `?? 0` / `?? false` 把缺失变合法值** | 111 / 47 / 73 | 抽样 `lib/remote/` 20 处：均为入站报文字段，下游有 `isEmpty` 校验或仅用于展示 | ✅ 未发现"缺失被当合法值写库"。**唯一例外在 Kotlin**：见下行 |
| **Kotlin 侧 `dndActive` 读不到 → `false`** | 1 | `NativeBridgePlugin.kt:727-737` `catch (e: Exception) { false }` | ⚠️ **是**（QUA-09，P3）：`ringerMode` 用 `-1` 表达"读不到"，`dndActive` 却把"读不到"说成"勿扰未开"，与 BUG-041 的教训（"读不到"≠"不满足"）不一致 |
| **`TODO` / `FIXME` / `HACK` / 先这样** | **0** | — | ✅ 全仓零标记 |
| **"临时"** | 0 处代码标记 | 24 处命中全是业务词「临时码 / 临时协助会话」 | ✅ 无 |
| **未 `await` 的写库/网络/文件** | 0（除 `background_engine:490`） | `endpoint_service.dart:694/706/749` 的 `unawaited(flushAllOutbox(...))`：`flushOutbox`（`:3485-3515`）内部逐条处理并 `_auditOutboxDrop` 留痕 | ✅ |

## 4.2 对"只报会静默吞错的那些"的取舍说明

- 本项目对静默失败有**专门的锁套件**（`test/silent_failure_locks_test.dart`，35 例，SLB/SLS/SLX-90），覆盖引擎守卫流错误、`pushExactAlarms` 回执、`clearAllAlarms` 清理失败、`runNow` 缺参、取证哈希为空、看门狗/开机自启只写 logcat 等 **Kotlin/引擎侧**静默形态，且每条都有反面样本。**这一域"已审计未发现问题"**。
- 因此本节只登记 **Dart 侧未被子系统覆盖**的两条（QUA-08）与 **Kotlin 新代码引入**的一条（QUA-09）。
- `vibrate_session.dart:490` 的 `catchError((_) {})` 不立缺陷：`dispose()` 是同步签名、调用点在引擎 teardown、通道已销毁；且注释给出了理由。若要更严，可改为 `catchError((Object e, StackTrace s) => debugPrint(...))`，属可选优化。

---

# 5. 文档与实现漂移

## 5.1 `docs/22-远程命令全量清单.md` 命令数 vs 实际

| 项 | 文档 | 实际（静态） | 判定 |
|---|---|---|---|
| 表 A 命令数 | **27 条**（`docs/22:449` 表行「表 A 命令（27）」+ `:456` 合计表 69 项） | `RcCmd` 类内 `static const` = **40**，其中带字符串字面量 = **38** | ⚠️ 数量级一致（几十条），**具体数字已过期** |
| 后续新增 | `docs/22:462` 自述「本节之后新增的 6 条命令未纳入本次审计」（`device.alert`/`vibrate.start`/`plan.apply`/`plan.get`/`plan.stop`/`run.master.set`）⇒ 口径应为 **33** | 38 | ⚠️ 差 **5 条**，且**没有任何一处维护"当前总数"** |

- `docs/22` 是**诚实的**（明确写了快照边界与"以 §1 表 A 当前行为准"），但读者拿到的仍是"27 条"这个过期锚点。细粒度核对按分工归 A4。→ QUA-12（P3）。

## 5.2 `CHANGELOG.md` vs `pubspec.yaml` vs `docs/` 基线

| 项 | 值 | 来源 | 自洽？ |
|---|---|---|---|
| `pubspec.yaml` 版本 | `1.9.9+32` | `pubspec.yaml:8` | — |
| CHANGELOG 首条 | `## [1.9.9] - 2026-10-20`（R92 收口） | `CHANGELOG.md:6` | ✅ 与 pubspec 一致 |
| R93 条目 | **不存在** | — | ⚠️ 合理（R93 未提交），但收口时必须补 |
| CHANGELOG 覆盖率基线 | 可测面 `98.98%（14206/14352）`／全局 `93.81%（14267/15208）` | `CHANGELOG.md:137` | ❌ **与 R93 实测 `14221/14367` / `14282/15223` 不一致（各差 15）** |
| CHANGELOG 残差 | `残差 936 = 141 + 795` | `CHANGELOG.md:139` | ❌ **实测应为 `941 = 146 + 795`**（`15223−14282=941`；`14367−14221=146`） |
| `docs/09` 基线 | `98.98%（14206/14352）`，残差 `941 = 146 + 795` | `docs/09:14` | ⚠️ 分数过期（R92 值），但**残差 941 是对的** ⇒ 与 CHANGELOG 的 936 **互相矛盾** |
| `docs/12 §126` | `14206/14352` / `14267/15208`，豁免 856/61 | `docs/12:12470` | ⚠️ 同上（R92 值） |
| `docs/17` / `docs/21` / `docs/22` / `README` / `HANDOVER` | 同 `14206/14352` | 多处 | ⚠️ 全库统一停在 R92 |

**判定（`CONFIRMED`）**：R93 的 `lib/**` 改动使可测面分子/分母各 +15（`14206→14221`、`14352→14367`），**百分比仍是 98.98%**，于是**所有机器锁（DGC/BAS）都发现不了**——因为 DGC 只校验"文档内部自洽 + 阈值等于 gates.sh 默认值"，不校验"文档数字 == lcov 实测"。

> 这正是项目自己在 `docs/12` §87 记下的教训（"两组百分比巧合相同 ⇒ 机器锁只比阈值与百分比抓不到，新纪律：逐位核对绝对分数"）的**第二次复发**，而且这次连"逐位核对"的落点（CHANGELOG 残差 141 vs 146）都自相矛盾了。→ QUA-06（P2）。

## 5.3 「已知限制」段与锚点

| 项 | 结果 |
|---|---|
| `### 已知限制` 出现次数 | **1 次**（`CHANGELOG.md:125`）✅ 未被复制/拆散 |
| 锚点完整性 | ✅ `CHANGELOG.md:138` 仍含 `COVERAGE_MIN=98.6` / `MIN_COVERED=12872` 的「阈值契约锚点」声明，DGC 锁可解析 |
| 段内机器锁自述 | `81/81`（DGC 55 + GEC 10 + version 12 + SCR 4）—— 与 `gate_entrypoint_consistency_test.dart` 实有 **10** 个 `test(` **吻合** ✅ |
| 段内残差 | ❌ 见 5.2（936/141 过期） |

## 5.4 其它文档漂移

| 位置 | 声明 | 实际 | 判定 |
|---|---|---|---|
| `scripts/gates.ps1:8-10` | 「CI 用 `flutter analyze --fatal-infos`，比本脚本的 grep 判据更严」 | CI **完全没有 analyze** | ❌ 陈旧（QUA-11） |
| `scripts/gates.ps1:16-17` | usage 示例 `COVERAGE_MIN='98.8'` / `MIN_COVERED='12653'` | 同文件 `:191-192` 是 `98.6` / `12872` | ❌ 陈旧（QUA-11） |
| `docs/00-文档索引.md:19` | 「当前基线：功能层 2907 + 压测 24 全绿」 | R93 门禁**不是全绿**（`GATES_RC=1`） | ⚠️ 属于"最近一次全绿"的历史陈述，可接受，但需在 R93 收口时更新 |

---

# 6. 缺陷条目

### QUA-01 VC05 失败后补了测试但从未复跑，R93 目前没有绿色门禁证据

```
Severity: P2
Evidence Status: CONFIRMED
Affected Files/Lines: test/cov_services_test.dart:93-106；lib/domain/models/vibrate_caps.dart:21-22,98-107；_pt/r93gate.log:9-13,63
Expected Behavior: 改了 VibrateCaps 的序列化键集后，同 PR 内同步 toMap 键集锁，并跑一次门禁拿到 GATES_RC=0 作为收口证据。
Actual Behavior: 模型 15:50 改了，测试 17:01:34 才补；门禁功能层 16:56:44 已判红并结束，17:07 以 GATES_RC=1 收尾。此后 _pt/ 无任何新门禁产物（最新文件即 17:07 的 r93gate.*）。
Trigger Conditions: 任何一次"改模型 → 跑门禁 → 门禁期间补测试"的操作顺序。
Evidence: /tmp/gates_功能层.log:682-700 显示 Expected 6 键 / Actual 8 键（`has extra map key 'ringerMode'`）；失败栈 `cov_services_test.dart 94:7`，而当前工作区 expect 在 :97（差 3 行 = diff 新增 3 行）⇒ 门禁跑的是旧测试。_pt/r93gate.log:63 `GATES_RC=1`。
Root Cause: 变更与测试锁未在同一原子提交内；门禁结果与工作区状态存在时间错配（门禁跑的是"提交前快照"，而测试是快照之后补的）。
Business Impact: 收口材料里"功能层红"会被误读为产品缺陷（实际是锁滞后）；反过来，若不复跑就宣布收口，等于用一份**已被自己修掉的失败**当证据，质量证据链断裂。
Recommended Fix: 重跑 `bash scripts/gates.sh`，把 `GATES_RC=0` 的日志落 `_pt/r94gate.log`；R93 收口说明中写明"VC05 为测试锁同步，非产品缺陷"。
Regression Risks: 无（纯测试/流程）。
Verification Tests: VC05（键集精确）+ VC06（往返相等）应同绿。
Remaining Uncertainty: 无法确认 17:01 之后是否有人手工跑过单文件测试（沙箱内无该记录）；但 _pt/ 无对应产物，故按"无证据"登记。
```

### QUA-02 压测层 16/24 用例用裸 Stopwatch 单次采样（min-of-1），与文件头约定及 BUG-053/055 纪律冲突，直接导致 WT-02 假红

```
Severity: P1
Evidence Status: CONFIRMED
Affected Files/Lines: test/performance_v2_test.dart:26-31（约定）,46,62,74,118,129,140,208（裸 Stopwatch）；test/performance_test.dart:145,159,196,214,276,287,297,320,331
Expected Behavior: 文件头声明「已统一用 benchMs/benchMsAsync（预热 + 取最小值）」；docs/12 §29.6 定案「任何用例都不得用 runs:1（min-of-1 = 没有抗噪）」。
Actual Behavior: 24 条压测用例里 16 条仍是裸 Stopwatch 单次采样。WT-02 在 CPU 67% 负载下采到 321ms（预算 300ms，超 7%）判红；同轮重跑 24/24 全绿。
  > 风险分层：`GT-01/02/03`（`:118/129/140`）虽有裸采样，但预算 4000ms 对基线 ≈1.05–1.13s 有 **3.5× 余量**（`performance_v2_test.dart:85-98` 有完整取值论证），风险显著低于 WT 组；WT 组与 GT-06 的余量不足 1.5×。
Trigger Conditions: 宿主有其它负载（Docker/WSL2/模拟器/构建）时跑 `--tags perf`。门禁自己在 _pt/r93gate.log:1-3 打印了 67% 负载预警。
Evidence: _pt/r93gate.log:31-36（321 > 300）；/tmp/gates_压测层首次.log:172-180（完整失败体）；_pt/r93gate.log:52-53（同轮重跑 All tests passed）；_pt/envchk_perf.txt:114-115 与 9 份历史日志（WT-02 均 <1s 通过）；lib/remote/protocol.dart:728-737 自 2026-10-13 未改动。
Root Cause: 测量方式与被测对象性质不匹配。BUG-053 的修复只覆盖了 GT-07（见 performance_v2_test.dart:223-229 的注释），WT 组与 GT-06 未同步改造；WT-02 的 300ms 预算相对真实基线（单跑 <1s，含框架开销）余量不足 1.5×，而项目自己的结论是"噪声可放大 5×"。
Business Impact: 门禁结论不可信 —— 同一份代码红绿翻转，团队被迫依赖 PERF_RETRY 消化噪声，长期会掩盖真实回归（"狼来了"）。本轮已实际发生：R93 门禁唯一的功能层失败之外，压测层也红过一次。
Recommended Fix: 把 WT-01/WT-02/WT-03/GT-06 改成 benchMs（预热 3 + 取 5 次最小值），阈值按"实测 JIT 基线 × 3"重定；用例名标注「JIT 护栏」。
Regression Risks: 改造后阈值需重新标定，若照搬旧数字可能出现"改完立刻红"；应先用 benchMs 打印一次实测基线再定阈值（BUG-053 的做法）。
Verification Tests: 连续 3 次 `flutter test --tags perf --concurrency=1` 应稳定全绿；`PERF_RETRY=0 bash scripts/gates.sh` 应能一次定生死。
Remaining Uncertainty: 未测得 WT-02 的 min-of-5 基线（沙箱无 dart），无法给出建议阈值的具体数字。
```

### QUA-03 `gates.ps1` 的压测层缺少"失败重跑 + 负载定性"，与 `gates.sh` 判据不等价，且 GEC 锁明确不覆盖

```
Severity: P2
Evidence Status: CONFIRMED
Affected Files/Lines: scripts/gates.ps1:166-179（压测层，无重跑）；scripts/gates.sh:636-638（perf_verdict）,746-778（PERF_RETRY + 负载定性）,109-136（LOAD 预警）；test/gate_entrypoint_consistency_test.dart:22-25（自述"不比对完整语义"）
Expected Behavior: 两条入口给出同一套判据（gates.ps1 头部 :6-10 明写「必须是同一套判据」）。
Actual Behavior: 同一次 WT-02 抖动，走 gates.sh 会"重跑→通过→PASS"；走 gates.ps1 直接 `[FAIL] 压测层` 并 `$fail++`。gates.ps1 也没有开跑前的 CPU 负载预警与 BLOCKED/RC=3 定性。
Trigger Conditions: 在有负载的机器上用 PowerShell 入口跑门禁。
Evidence: gates.ps1:170 只有一条 `flutter test --tags perf --concurrency=1`，失败即 `[FAIL]`（:173-178）；grep `PERF_RETRY|perf_verdict|LOAD` 在 gates.ps1 中 **0 命中**；gates.sh:746-778 有完整实现。
Root Cause: 一致性锁（GEC）刻意收窄到"只比默认阈值 + 是否传 --min-covered"，重跑/定性这类**控制流语义**从未被锁；两次历史漂移都是"人记得改一个忘了另一个"，同一失效模式在控制流层重演。
Business Impact: 假红（比假绿安全，但会训练出"ps1 的结果不作数"的坏习惯）；两条入口结论不一致会让"走哪条路"再次成为变量。
Recommended Fix: ① 给 gates.ps1 补 PERF_RETRY（默认 1 次）+ 负载采样 + BLOCKED 分支；② 新增 `GEC-09`：断言两脚本都含 `PERF_RETRY`、`ALL tests passed` 判定与 `BLOCKED` 计数，并带反面样本。
Regression Risks: 补重跑会让 ps1 单次门禁耗时 +1~4 分钟。
Verification Tests: GEC-09 正/反例；在有负载机器上分别用两入口跑同一份代码，结论应一致。
Remaining Uncertainty: 未实际执行 ps1（无 PowerShell 门禁产物）。
```

### QUA-04 CI 零测试 / 零 analyze，唯一质量门是"人记得本地跑 gates.sh"

```
Severity: P2
Evidence Status: CONFIRMED
Affected Files/Lines: .github/workflows/ci.yml:11-19（自述裁撤）,22-78（android-build）,90-162（ios-build）；test/gate_entrypoint_consistency_test.dart:113-136（GEC-06 反向锁定）
Expected Behavior: 至少对 push/PR 有 analyze 或单元测试门，避免未过门禁的提交进入 main。
Actual Behavior: CI 只 `pub get` + `flutter build apk --release` + iOS 构建；analyze/test/coverage/emulator 全部裁撤，且 `GEC-06` 会把"加回 analyze-test"判红。
Trigger Conditions: 任何 push 到 main 或开 PR。
Evidence: ci.yml 全文仅 6 个 run 步骤，无 `flutter test`/`flutter analyze`；GEC-06 断言 `!code.contains('analyze-test')` 且 `!code.contains('--min-covered=')`。
Root Cause: 2026-10-10 为省 Actions 计费做的有意识裁撤，用"本地门禁"替代；该决定被机器锁固化。
Business Impact: 质量门完全依赖人工纪律。当前本地门禁是红的（GATES_RC=1），若此时有人直接 push，CI 仍会绿（只要编译通过）——"编译通过"会被误读为"质量通过"。
Recommended Fix: 最低成本方案：在 android-build 前加一步 `flutter analyze --fatal-infos`（约 20 秒，几乎不增计费）；或加 `workflow_dispatch` 的 manual gate job。若坚持零 CI 测试，至少在 PR 模板里要求附 gates 日志。
Regression Risks: 加 analyze 后 CI 会因现存 info 级问题变红，需先 `flutter analyze` 清零（当前门禁 analyze 为 PASS，风险低）。
Verification Tests: GEC-06 需同步改写（它当前锁的是"必须没有 analyze"），否则改 CI 会立刻判红。
Remaining Uncertainty: 未核对仓库 Secrets/计费策略，无法判断加回测试的实际成本。
```

### QUA-05 R93 的核心可诊断性改进（振动被系统吞掉时写审计行）零测试覆盖，被 98.98% 的聚合数字掩盖

```
Severity: P2
Evidence Status: CONFIRMED
Affected Files/Lines: lib/services/vibrate_session.dart:182-187；coverage/lcov.info（SF:lib\services\vibrate_session.dart 段，DA:183,2 / DA:184,0 / DA:185,0）
Expected Behavior: 新增分支应有测试驱动（构造 caps.notificationsMuted=true 且 respectDnd=true 的会话），否则"回执 success 但没震"的解释链在回归时会静默失效。
Actual Behavior: 条件行命中 2 次，分支体命中 0 次 ⇒ 该分支从未真正执行。test/r93_vibrate_dnd_test.dart 只测了 VibrateCaps 与模型默认值，未测 VibrateSession 的降级文案。
Trigger Conditions: 任何改动 vibrate_session 审计拼装或 VibrateCaps.notificationsMuted 语义的提交。
Evidence: coverage/lcov.info 中 `DA:184,0`、`DA:185,0`（R93 门禁功能层产物，16:56:44）；对照 `DA:183,2` 证明条件被求值过。聚合 98.98% 不受影响（2 行 / 14367）。
Root Cause: 测试只覆盖了"值对象"，没覆盖"值对象如何进入审计输出"；覆盖率阈值是比率型，对 2 行新增无约束力。
Business Impact: 用户报障"震动不好使"的**诊断能力**本身没有被回归保护 —— 一旦文案拼接或条件写错，日志会重新变成"success 但无解释"，而所有门禁全绿。
Recommended Fix: 加一条 `VibrateSession` 级用例（用现有注入缝喂 `VibrateCaps(ringerMode:1)` + `RandomVibrateAction(respectDnd:true)`），断言 `_log` 的 message 含"极可能被系统静默吞掉"；再加一条 `respectDnd:false` 的**反向**用例断言**不**出现该文案（防恒真）。
Regression Risks: 需要 VibrateSession 的可注入能力接口（若已有 `capabilities()` 注入缝则成本很低）。
Verification Tests: 新增 VS-DND-01/02 两例；重跑后 lcov 中 `DA:184` 应 ≥1。
Remaining Uncertainty: 未确认 VibrateSession 是否有 `@visibleForTesting` 的 capabilities 注入点（若有，改造为零成本；若没有，需先开缝）。
```

### QUA-06 R93 改了 `lib/**` 但全库文档基线未回刷；CHANGELOG 残差与实测自相矛盾，且现有机器锁结构性抓不到

```
Severity: P2
Evidence Status: CONFIRMED
Affected Files/Lines: CHANGELOG.md:137,139；docs/09:14；docs/12:12470；docs/17:10063；docs/21:171；docs/22:305；HANDOVER.md:15,28；test/doc_gate_consistency_test.dart:506-539（DGC 判据范围）
Expected Behavior: 每轮收口把"可测面/全局"的**绝对分数**与残差回刷到全部落点（项目纪律见 docs/12 §87）。
Actual Behavior: 全部落点仍停在 R92 的 `14206/14352`、`14267/15208`；R93 门禁实测为 `14221/14367`、`14282/15223`（各 +15）。CHANGELOG 残差写 `936 = 141 + 795`，实测应为 `941 = 146 + 795`，且与 docs/09 的 `941 = 146 + 795` **互相矛盾**。
Trigger Conditions: 任何新增可执行代码 + 同步新增覆盖的提交（分子分母同增、比率不变）。
Evidence: coverage/lcov.info 求和 `LF=15223 / LH=14282`（106 record），可测面 `14367/14221`；_pt/r93gate.log:57-58 逐位一致；CHANGELOG.md:139 文本为 `残差 936 = 141 + 795`；docs/09:14 为 `残差 941 = 146 + 795`。
Root Cause: DGC 只做"文档↔文档自洽 + 阈值↔gates.sh 默认值"，不做"文档↔lcov 实测"；而 98.98% 这个百分比在两轮里**完全相同**，所以连"百分比变化"这条弱信号也没有。
Business Impact: 对外诚实数字失准（差 15 行）；更严重的是"文档锁全绿"给了虚假的安全感 —— 项目已为此立过 BAS 锁，这次是同一失效模式的复发。
Recommended Fix: ① 回刷全部落点至 `14221/14367`、`14282/15223`、残差 `941 = 146 + 795`；② 给 DGC 加一条 `DGC-07`：若 `coverage/lcov.info` 存在，则根节的绝对分数必须与 lcov 求和逐位相等（不存在时跳过并 `printOnFailure` 说明，不得静默通过）。
Regression Risks: `DGC-07` 会让"文档未回刷"从 P3 变红，历史上每轮都要跑一次回刷，属预期成本。
Verification Tests: DGC 全量 + BAS-03/04 复跑；`coverage/lcov.info` 与文档逐位比对。
Remaining Uncertainty: 若 R93 最终提交时改了更多 lib 代码，数字会再变；本结论只对 16:56 的 lcov 有效。
```

### QUA-07 `respectDnd` 默认值 true→false 对存量任务静默生效，升级后行为变更无迁移、无提示

```
Severity: P2
Evidence Status: HIGH_CONFIDENCE
Affected Files/Lines: lib/domain/models/action.dart:378,417-425,450（RandomVibrateAction）,490,523,546（ContinuousVibrateAction）；lib/features/tasks/task_editor_screen.dart:171,180；lib/domain/scheduling/counter_plan_materializer.dart:223-226
Expected Behavior: 默认值翻转属于**用户可感知的行为变更**（振动从"跟随勿扰"变为"穿透勿扰/USAGE_ALARM"）。要么做数据迁移显式写入旧值，要么在升级后首次运行时提示。
Actual Behavior: `fromJson` 的缺省从 `?? true` 改成 `?? false`（action.dart:448/546）⇒ 存量任务 JSON 里**没有该键**的，读出来就是 false，直接开始穿透勿扰。仓库内没有任何迁移代码或一次性提示。
Trigger Conditions: 从 1.9.8+31 升级到 1.9.9+32 后，所有历史振动任务在静音/勿扰期间开始震动。
Evidence: git diff 显示 `respectDnd: j['respectDnd'] as bool? ?? true` → `?? false`（两处）；注释自述「旧数据里没有这个键时**不能**再回落 true —— 那等于把静默失败留给存量任务」——**这是有意识的决定**，但决定的是"行为变更"，文档里没有对应的升级提示或迁移。
Root Cause: 把"修复静默失败"直接实现为"改默认值 + 改反序列化缺省"，绕过了"存量数据"这条路径。
Business Impact: 用户在夜间/会议中会被自己历史任务突然震动（此前是被系统静音的）。这是**体验与合规风险**（穿透勿扰需用户知情），也可能被应用商店/系统判定为滥用 ALARM 通道。
Recommended Fix: ① 二选一：DB 迁移时把旧任务的 `respectDnd` 显式写为 true（保持旧行为，用户可主动改），或保持新默认但在升级后首启弹一次说明；② 编辑器默认值（task_editor_screen.dart:171/180）与新默认一致即可，但需在设置页给出全局开关。
Regression Risks: 若改成"迁移为 true"，则用户报障的"震动不好使"会**原样复发**（这才是 R93 要修的问题）。所以更合理的是"新默认 + 首启一次性告知"，而不是回退。
Verification Tests: 新增升级用例：造一条无 `respectDnd` 键的 v1.9.8 任务 JSON → 断言读出的值与"产品裁定"一致；再加一条"用户显式设 true 后不被默认覆盖"。
Remaining Uncertainty: 产品是否已裁定"存量任务一并穿透勿扰"未在文档中找到依据（`CHANGELOG` 无 R93 条目）；若已裁定，本条降级为 P3 的"缺升级告知"。
```

### QUA-08 `reportBadTaskRow` 的 fire-and-forget 写库无兜底，写失败会变成 isolate 内未处理异步错误

```
Severity: P3
Evidence Status: HIGH_CONFIDENCE
Affected Files/Lines: lib/services/background_engine.dart:488-498；lib/data/repositories/log_repository.dart:33-43（append 无内部 catch）
Expected Behavior: 诊断写入失败应被捕获并降级（例如 `debugPrint`），不得产生未处理异步错误。
Actual Behavior: `unawaited(logs.append(...))` —— 若 `insert` 抛错（DB 已 close、磁盘满、行锁），错误逃逸到 zone。该 isolate 有 `onError`（background_engine.dart:250 `print('unhandled: $e')`），所以**不会完全静默**，但"哪一行坏数据导致"这条诊断本身丢失。
Trigger Conditions: 引擎停机窗口内仍有 `listAll` 触发坏行上报；或 DB 写入失败。
Evidence: 代码见上；`LogRepository.append` 直接 `_db.db.insert(...)`，无 try/catch。
Root Cause: fire-and-forget 惯用法用在**可能失败且失败有意义**的写路径上。
Business Impact: 低（诊断日志丢失），但在"任务行解析失败"这类需要追因的场景会二次丢失证据。
Recommended Fix: `unawaited(logs.append(...).catchError((Object e) => debugPrint('[engine] badRow 上报失败: $e')))`。
Regression Risks: 无。
Verification Tests: 用已关闭的 DB 调用 `reportBadTaskRow`，断言不产生未处理异步错误。
Remaining Uncertainty: 未实测 isolate 内 unhandled error 是否会导致进程退出（取决于 flutter_background_service 的 zone 配置）。
```

### QUA-09 Kotlin 侧 `dndActive` 把"读不到"报成 `false`，与 `ringerMode=-1` 的哨兵语义不一致

```
Severity: P3
Evidence Status: CONFIRMED
Affected Files/Lines: packages/native_bridge/android/src/main/kotlin/com/sonicshield/native_bridge/NativeBridgePlugin.kt:713-729（`dndActive` 的 catch 返回 false，`:728`）；对照 `:713-716`（`ringerMode` 返回 -1，`:715`）
Expected Behavior: "读不到"必须可与"确实未开"区分（项目先例：BUG-041，`NativeBridge.isOnWifi()` 返回 null 而非 false）。
Actual Behavior: `ringerMode` 用 `-1` 表达读不到 ✅；`dndActive` 用 `false` 表达读不到 ❌ ⇒ 审计日志会写"系统未开勿扰"，而真相是"读不到"。
Trigger Conditions: `NotificationManager` 获取失败 / `currentInterruptionFilter` 抛 SecurityException（部分 ROM 在受限 profile 下会抛）。
Evidence: 代码见上；`VibrateCaps.dndActive` 是 `bool` 非 `bool?`（vibrate_caps.dart:36），Dart 侧也无"未知"态。
Business Impact: 低（只影响诊断文案准确性）；但在"调用了为什么没震"的追因场景，会把用户引向错误结论。
Recommended Fix: `dndActive` 改为可空（Kotlin 返回 `null` → Dart `bool?`），或新增 `dndKnown` 布尔；审计文案区分"未开勿扰 / 读不到勿扰状态"。
Regression Risks: 改类型会波及 `toMap/fromMap` 与 VC 系列锁（正是 QUA-01 的同类风险），需同 PR 更新。
Verification Tests: VC-01 扩展：`dndActive` 缺失 ⇒ 断言为"未知"而非 false。
Remaining Uncertainty: 未在真机复现 `currentInterruptionFilter` 抛异常（无设备）。
```

### QUA-10 48 个测试文件依赖源码文本，13 个未使用统一剥注释工具

```
Severity: P3
Evidence Status: CONFIRMED
Affected Files/Lines: 48 个 `test/*.dart`（`readAsStringSync` + `lib/`）；其中 13 个未 import `test/support/source_text.dart`（含 android_compat_lock_test / aot_budget_normalization_test / app_icon_lock_test / assist_entry_test / call_ice_test / coverage_sentinel_test / dir_path_interpolation_test / doc_gate_consistency_test / endpoint_by_id_test / evidence_files_test / exempt_functional_locks_test / feature_point_coverage_lock_test / log_stats_screen_test）
Expected Behavior: 任何读源码文本的锁都必须先剥注释（`support/source_text.dart:20` 的硬性要求）。
Actual Behavior: 13 个文件绕过统一实现（部分自行归一化 CRLF 后直接 `contains`）。
Trigger Conditions: 注释里出现被断言的字面量（喂绿），或禁止性断言命中注释（假红）。
Evidence: `docs/12 §80` 已记录一次集体假红（"缝的文档注释里写出 `_handleRaw` 声明签名 ⇒ 四条没剥注释的 methodBody 锁集体假红"）。
Root Cause: 统一工具是第 36 轮才收敛的，此前的 13 个文件未回迁。
Business Impact: 维护成本 + 假红风险；不会导致漏检（假绿风险已由"存在性断言必须剥注释"这条纪律部分覆盖）。
Recommended Fix: 机械回迁 13 个文件到 `support/source_text.dart`；新锁强制带反面样本（沿用 SLX/GEC 惯例）。
Regression Risks: 回迁后若某文件原本依赖"注释也算"的宽松行为，会立刻变红 —— 这正是要暴露的问题。
Verification Tests: 每个回迁文件的锁复跑；`STX` 系列保持绿。
Remaining Uncertainty: 13 个文件中部分可能只断言非源码字符串，实际风险低于计数（未逐个通读）。
```

### QUA-11 `gates.ps1` 头部注释两处失实（阈值示例陈旧、CI 判据已不存在）

```
Severity: P3
Evidence Status: CONFIRMED
Affected Files/Lines: scripts/gates.ps1:16-17（`98.8` / `12653`）,8-10（「CI 用 flutter analyze --fatal-infos」）
Expected Behavior: 注释与实际值一致；引用其它落点时必须真实存在。
Actual Behavior: `:191-192` 实际默认值是 `98.6` / `12872`；CI 已无 analyze 步骤（ci.yml:11-19）。
Trigger Conditions: 运维照 usage 注释手工 export 阈值 ⇒ 会用 98.8 覆盖默认 98.6，把门禁**收紧**到比约定更严（可能假红）；或误以为 CI 兜底了 analyze。
Evidence: 见上三处行号。
Root Cause: 注释更新滞后于代码/CI 变更。
Business Impact: 低（假红方向），但"以为 CI 有 analyze"会让人跳过本地第 1 步。
Recommended Fix: 删掉 usage 里的具体数字（改为"默认值见第 4 步"），并改写 CI 相关说明为"CI 只构建产物，质量门全在本地"。
Regression Risks: 无。
Verification Tests: GEC-01 只解析 `$covMin = ...` 的赋值行，不受注释影响，改注释不会误伤锁。
Remaining Uncertainty: 无。
```

### QUA-12 `docs/22` 的命令总数是过期快照（27+6=33 vs 实际 38）

```
Severity: P3
Evidence Status: CONFIRMED
Affected Files/Lines: docs/22-远程命令全量清单.md:449（27 条）,456（合计 69 项）,462（"本节之后新增的 6 条"）；lib/remote/protocol.dart 的 `RcCmd` 类（40 个 `static const`，38 个带字符串字面量）
Expected Behavior: 至少有一处维护"当前命令总数"，或表 A 随新增命令同步扩行。
Actual Behavior: 表 A 停在 27 条，另声明 6 条未纳入 ⇒ 口径 33；实际 38。
Trigger Conditions: 任何按 docs/22 做覆盖面核对的人。
Evidence: `awk '/abstract final class RcCmd/,/^}/' | grep -c "static const"` = 40；带字面量 38。
Root Cause: 文档按"轮次快照"组织，没有维护滚动总数。
Business Impact: 低（细粒度由 A4 核对；文档自己也声明"以 §1 表 A 当前行为准"），但"27 条"这个数字会被外部引用。
Recommended Fix: 在 §1 表 A 顶部加一行"当前命令总数：38（随行数变化）"，并给 docs/22 加一条机器锁（`RcCmd` 常量数 == 表 A 行数）。
Regression Risks: 新增命令时锁会红，需同步改文档（预期成本）。
Verification Tests: 新增锁的正/反例。
Remaining Uncertainty: 40 与 38 的差值来自 2 个非字符串常量（可能是别名/前缀），未逐个确认。
```

### QUA-13 396 处 `pumpAndSettle` 全部使用默认 10 分钟超时，无一处显式限时

```
Severity: P3
Evidence Status: CONFIRMED
Affected Files/Lines: `test/*.dart` 共 396 处（`grep -c pumpAndSettle`）；`pumpAndSettle(const Duration` / `pumpAndSettle(Duration` = **0**
Expected Behavior: 对"理论上会停"的动画用默认值可接受；对"可能永不 settle"的页面应显式限时，让失败信息快速定位。
Actual Behavior: 全部走默认超时（10 分钟/次）。项目已发生过"挂死整轮"（`docs/12 §71`，`guard_screen_test.dart`）。
Trigger Conditions: 引入无限动画（CircularProgressIndicator 常驻、循环 AnimationController）的页面被 pump。
Business Impact: 单次挂死可吃掉整轮门禁的时间预算（本轮门禁 16:51→17:07，功能层 4:53、压测层 3:33+2:04）；`timeout 4800`（`_pt/r93gate.sh`）到点会整轮无结论。
Evidence: 计数见上；`_pt/r93gate.sh` 用 `timeout 4800` 兜底。
Root Cause: 默认值够用，历史上靠"修掉挂死用例"而非"给 settle 限时"解决。
Business Impact: 低（目前无挂死），但属**已知复发面**。
Recommended Fix: 对已知含常驻指示器的页面显式 `pumpAndSettle(const Duration(milliseconds: 200))` 或改用有界 `pump` 循环；或给测试加全局 `timeout: Timeout(Duration(seconds: 60))`。
Regression Risks: 收紧后可能暴露原本靠默认超时"侥幸通过"的用例。
Verification Tests: 全量功能层复跑，用例数与耗时对比。
Remaining Uncertainty: 未逐页确认哪些页面含常驻动画（396 处分布在 ~60 文件）。
```

---

# 7. 未覆盖范围与原因

## 7.1 已审计、未发现问题（明确结论）

| 范围 | 结论 | 依据 |
|---|---|---|
| **覆盖率基线常量四件套**（`COVERAGE_MIN` / `MIN_COVERED` / `kDeviceExemptLines` / `kDeviceExemptCovered`） | ✅ 与 `gates.sh` / `gates.ps1` / `CHANGELOG` / `lcov` 实测**全部一致**（98.6 / 12872 / 856 / 61） | `gates.sh:489,602`；`gates.ps1:191,192`；`doc_gate_consistency_test.dart:331,335`；`lcov.info` 逐文件求和 |
| **豁免面几何**（background_engine 710 + main 72 + neural_tts 74 = 856；已覆盖 61） | ✅ R93 未改这三个文件，几何未失配 | 同上 + `git status` |
| **静默禁用用例**（`skip:` / `@Skip` / `solo`） | ✅ 全仓 **0** | `grep -rn "skip:\s*true\|@Skip\|solo"` 零命中 |
| **恒真断言**（`expect(true,true)` 等） | ✅ 全仓 **0**；零断言文件 **0** | 同上 |
| **空捕获 `catch (_) {}`** | ✅ 全仓 **0**（6 处 `catch (_)` 均有注释且为刻意 best-effort） | `lib/` 逐处阅读 |
| **`TODO`/`FIXME`/`HACK`** | ✅ 全仓 **0** | grep 零命中 |
| **固定 sleep**（`await Future.delayed` 在测试里） | ✅ **0**（项目已系统清除） | grep 零命中 |
| **门禁内 `|| true` / `continue-on-error` / 注释掉的门禁步骤** | ✅ 无"跳过以变绿"痕迹（9 处 `|| true` 全在展示管道，1 处在设备层缓存） | `gates.sh` 逐处阅读 |
| **Kotlin/引擎侧静默失败** | ✅ 有专门锁套件（SLB 行为锁 + SLS 源码锁 + **SLX-90 反面样本 18 条**），抽样未见漏网 | `silent_failure_locks_test.dart` |
| **`test/` 中 try/catch 吞失败** | ✅ 仅 1 处真实 try/catch，且用于**断言异常原样抛出** | `asset_import_test.dart:328-344` |

## 7.2 未审计 / 审计不足（如实登记）

| 范围 | 原因 | 影响 |
|---|---|---|
| **任何测试的实际执行** | 沙箱无 `dart`/`flutter`；中继由主控独占，按约束不得使用 | 本报告所有"会不会通过"的判断均为**静态推演**或**引用他人日志**，无一次自跑 |
| `integration_test/` 11 个文件 | 需真机/模拟器；无设备、无执行权 | 设备层测试质量未抽样 |
| `packages/native_bridge` 全部 Kotlin 源码 | 本包只审了 R93 改动段（`vibrateCapabilities`）+ 源码锁覆盖面 | 原生层静默错误可能仍有未发现项（A5 若存在应覆盖） |
| `test/` 207 文件中未抽样的 189 个 | 抽样 18 个（8.7%） | 断言空转/异常路径覆盖的结论是**抽样结论**，不是全量 |
| `lib/` 43,510 行中未读的部分 | 静默错误用 grep 全仓扫描 + 命中处逐个阅读；未逐行通读 | `?? ''`/`?? 0`/`?? false` 共 231 处，只抽查了 `lib/remote/` 20 处 |
| `docs/` 全部文档的漂移 | 只核对了 docs/00、09、12(§126)、17、21、22、38、CHANGELOG、HANDOVER 的基线数字与已知限制段 | 其它 60+ 篇文档的过期数字未核对 |
| 覆盖率"真执行"的全量验证 | 只抽查了 R93 新增行（5 个位置） | 其余高覆盖文件的复杂分支未逐一验证 |
| `gates.ps1` 的实际运行 | 无 PowerShell 门禁产物；只做静态对照 | QUA-03 的"结论不一致"是静态推断（`HIGH_CONFIDENCE` 而非 `CONFIRMED` 的运行时证据） |
| CI 的实际运行历史 | 无 Actions 日志（离线） | 无法确认 CI 近期是否真的成功产出过 APK/IPA |

## 7.3 本报告**未**做的事（合规声明）

- 未修改 `lib/`、`test/`、`android/`、`ios/`、`packages/`、`scripts/`、`.github/` 中任何文件；
- 未执行 `git commit/push/checkout/stash/reset` 等任何写操作（仅 `git status` / `git diff` / `git log` 只读）；
- 未运行 `dart` / `flutter` / `flutter test` / `flutter analyze`；
- 未使用计划任务中继（未触碰 `_pt/job.txt`、未调用 `Start-ScheduledTask`）；
- 唯一写产物为本文件。
