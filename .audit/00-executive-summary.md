# 00 · 执行摘要

> **审计模式**：`AUDIT_ONLY`（只读；未修改任何 `lib/` / `test/` / `android/` / `ios/` / `packages/` 文件）
> **审计时间**：2026-10-22
> **审计对象**：`E:\SonicShield`，Flutter/Dart，版本 `1.9.9+32`，分支 `main`，HEAD `a93f595`（R92 收口）
> **工作区状态**：存在**未提交的 R93 在飞改动**（8 改 1 增，见 §6），审计期间保持原样未触碰

---

## 1. 一句话结论

> 项目在**单条路径的正常流程**上已经相当扎实（前几轮修掉了大量表层缺陷，207 个测试文件 / 67,689 行测试代码），
> 但本轮深挖在**授权模型、跨异步状态、事务边界**三个维度找到了 92 条缺陷，其中
> **1 条 P0（远程撤销配对失效，命中项目自定的合规红线）** 与 **16 条 P1**。
> 最危险的共性不是"某个函数写错"，而是**"状态被拆成两份、只有一份被恢复/撤销/事务化"**。

---

## 2. 审计范围与规模

| 维度 | 数值 |
|---|---|
| 审计代码 | `lib/` 107 文件 / **43,510 行** |
| 原生代码 | Kotlin 6 个源集文件 + Swift 5 个 + Manifest 2 份 |
| 测试代码（只读评估） | `test/` 207 文件 / **67,689 行** |
| 深读文件 | 约 62 个（含全部 >400 行的核心文件） |
| 审计工作包 | 6 个并行（A1 架构 / A2 调度并发 / A3 数据 / A4 远程安全 / A5 原生 / A6 质量门禁） |
| 产出报告 | 6 份工作包报告（6,875 行）+ 本交付集 |

---

## 3. 缺陷总览

| 严重度 | 数量 | 定义 |
|---|---:|---|
| **P0 / Critical** | **1** | 重大安全问题 / 核心服务不可用 |
| **P1 / High** | **16** | 重要业务错误、任务丢失、严重一致性问题 |
| **P2 / Medium** | **39** | 可恢复但有实质业务影响 |
| **P3 / Low** | **36** | 低影响、低概率或非关键 |
| **合计** | **92** | |

### 3.1 按工作包分布

| 工作包 | P0 | P1 | P2 | P3 | 合计 |
|---|---:|---:|---:|---:|---:|
| A1 架构与调用链（`ARCH-`） | 0 | 0 | 6 | 6 | 12 |
| A2 调度与并发（`SCH-`） | 0 | 4 | 6 | 5 | 15 |
| A3 数据与一致性（`DAT-`） | 0 | 5 | 7 | 6 | 18 |
| A4 远程与安全（`REM-`） | **1** | 3 | 6 | 6 | 16 |
| A5 原生与生命周期（`NAT-`） | 0 | 3 | 8 | 7 | 18 |
| A6 质量与门禁（`QUA-`） | 0 | 1 | 6 | 6 | 13 |

### 3.2 按证据等级分布

| 证据等级 | 数量 | 含义 |
|---|---:|---|
| `CONFIRMED` | 58 | 代码路径逐行可证 / 有运行或日志证据 |
| `HIGH_CONFIDENCE` | 24 | 静态分析 + 明确逻辑条件，未完成动态复现 |
| `SUSPECTED` | 7 | 合理怀疑，需进一步验证 |
| `UNVERIFIED` | 3 | 缺环境或证据（含 1 条第三方库行为待查） |
| `NOT_REPRODUCED` | 0 | — |

---

## 4. 必须立刻处理的 5 件事

| # | 缺陷 | 为什么是现在 |
|---|---|---|
| 1 | **REM-01（P0）** 撤销配对不使旧凭据失效；`from` 为空即放行 | 「删除设备」是**唯一**的授权回收手段，而它当前无效。命中 `docs/08 §2` 合规红线 |
| 2 | **NAT-02（P1，R93 在飞）** `ringerMode` 常量映射颠倒（0/1/2 写成正常/静音/振动） | R93 正在"修振动归因"，归因方向**反了**：静音漏报、正常误报。**在合入前必须改** |
| 3 | **NAT-01（P1）** Android 14+ 抓帧必失败（无 `registerCallback`） | 主力机 Redmi K70 Pro / Android 16 **100% 复现**，且被误报成"用户拒绝授权" |
| 4 | **SCH-01 / SCH-02（P1）** 长动作吞掉同批任务；远程改任务删掉已到期计划 | 用户视角是"任务该响没响，日志里查不到原因" |
| 5 | **QUA-01（P2）** R93 当前**没有绿色门禁证据** | 门禁最后一次实测 `GATES_RC=1`（`_pt/r93gate.log`），补测试后未复跑 |

---

## 5. 三条贯穿性根因（比单条缺陷更重要）

### 5.1 「双份状态，只恢复/撤销/事务化一份」

同一个业务状态被拆成两处存储，代码只维护其中一处，另一处漂移后无人发现：

| 现象 | 两份状态 | 缺陷 |
|---|---|---|
| 守卫"在跑"但采不到声音 | `prefs.guard_enabled` vs `MicGuardService` 存活 | NAT-03 |
| 撤销了配对但对方还能控制 | `rc_paired` 列表 vs 共享配对码（凭据未变） | REM-01 |
| 闹钟只增不删 | `AlarmManager` 实际闹钟 vs `KEY_ALARMS` 记录（每次覆盖） | ARCH-02 |
| 任务零计划但全局覆盖充足 | 单任务 pending 数 vs 全局 `MAX(fire_at)` | DAT-05 |
| 免打扰语义变了但老数据没变 | 旧 bool 语义 vs 新三态语义（迁移只补列） | DAT-01 |

**这是本轮最高价值的发现**：它不是 5 个独立 bug，而是同一个建模习惯在 5 个模块上的投影。

### 5.2 「检查与执行之间没有原子性」

- `markStatus` 无 `WHERE status='pending'` ⇒ 不是 CAS，两个连接可重复执行同一计划（DAT-03）
- `executing` 只保护 `executeDue` 自身重入，不是任务级互斥 ⇒ `runNow` 可与定时并发双响（SCH-03）
- 跨仓储"删 + 建"无共享事务 ⇒ 中途失败留下零计划 / 零任务（DAT-04 / DAT-05）
- 声音冷却基准在执行**之后**才落库 ⇒ 长动作期间可重复触发（SCH-08）

### 5.3 「静默假成功」仍是主要失败形态

- 远程 `vibrate.stop` / `device.alert` 无条件回执成功（ARCH-12 / NAT-10）
- 原生异常被统一折叠为"平台不支持"（NAT-13）
- `catch` 后返回默认值，UI 显示完成（A6 §5 分类统计）

---

## 6. 关于工作区的 R93 在飞改动（重要）

审计开始时工作区已有未提交改动，**审计全程未触碰**：

```
M lib/domain/models/action.dart
M lib/domain/models/vibrate_caps.dart
M lib/domain/scheduling/counter_plan_materializer.dart
M lib/features/tasks/task_editor_screen.dart
M lib/services/vibrate_session.dart
M packages/native_bridge/.../NativeBridgePlugin.kt
M test/cov_services_test.dart
M test/task_editor_vibrate_test.dart
?? test/r93_vibrate_dnd_test.dart
```

**门禁实测（来自 `_pt/r93gate.log`，非本次运行）**：`GATES_RC=1`
- analyze `PASS`
- 功能层 `FAIL`：`cov_services_test.dart:94` VC05（**测试锁未同步，非产品缺陷**，见 QUA-01）
- 压测层 `PASS`（重跑 24/24），首次 `WT-02` 假红 321ms/300ms（**墙钟抖动**，见 QUA-02）
- 覆盖率 ratchet `PASS`：可测面 98.98%（14221/14367）/ 全局 93.82%

⚠️ **R93 在这套改动里引入了 NAT-02（P1 真实缺陷）与 QUA-07（P2 默认值变更无迁移）**，
建议在合入前处理，否则"修振动"会带着反向归因上线。

---

## 7. 实际使用的工具与不可用能力

| 能力 | 状态 | 说明 |
|---|---|---|
| 代码搜索 / 符号定位 | ✅ 可用 | ripgrep（Grep 工具）、Glob、Read |
| 跨文件调用链追踪 | ✅ 人工 + grep 完成 | 无 LSP / Serena MCP |
| `flutter analyze` | ⚠️ **未运行** | 沙箱内无 `dart`/`flutter`（`command not found`）；引用 `_pt/r93gate.log` 的历史结果 |
| `flutter test` | ⚠️ **未运行** | 同上。执行需走计划任务中继，本轮**保留给主控独占**，未派发 |
| ast-grep / CodeQL | ❌ 不可用 | 未安装，且安装会改动环境（AUDIT_ONLY 禁止） |
| 调试器 / py-spy / OTel | ❌ 不可用 | 无运行时；无 tracing 埋点 |
| Playwright / Schemathesis | ❌ 不适用 | 非 Web 项目 |
| 真机 / 模拟器 | ❌ **未使用** | 审计规则禁止 adb / 安装 APK；所有真机结论标 `UNVERIFIED` |
| SQLite 只读检查 | ✅ 可用 | 仅读 schema，未写任何 `.db` |

**因此**：本轮**没有**完成第五阶段（运行时深度检查）的实际执行。凡涉及运行时行为的结论，均已降级标注
（`HIGH_CONFIDENCE` / `UNVERIFIED`），详见 `11-coverage-and-limitations.md`。

---

## 8. 未覆盖范围（诚实声明）

- **完全未读**：`lib/remote/assist.dart`、`assist_host.dart`、`assist_join.dart`、`multi_call_service.dart`、
  `controller_service.dart`（A1 未读，A4 部分读）、`lib/services/deepseek_service.dart`、`neural_tts.dart`、
  `holiday_update_service.dart`、`preset_import.dart`、`evidence_files.dart`、`export_crypto.dart`。
- **UI 层**：`lib/features/` 15,214 行只深读了 6 个文件（dashboard / task_editor / task_list / settings /
  guard_toggle / remote 4 个），其余按"是否有跨 isolate 状态"做导入级扫描。
- **iOS**：只做静态核对，**零运行时验证**（无 macOS 环境）。
- **运行时**：全部未执行（见 §7）。

---

## 9. 交付物索引

| 文件 | 内容 |
|---|---|
| `01-architecture-map.md` | 分层架构、启动链、跨 isolate 拓扑 |
| `02-module-dependency-map.md` | 依赖矩阵、循环依赖、分层倒置 |
| `03-critical-call-chains.md` | 5 条关键链路正反向追踪 |
| `04-static-analysis-results.md` | 静态检查结论与静默错误扫描 |
| `05-runtime-trace-analysis.md` | 运行时证据来源与**未执行**声明 |
| `06-async-concurrency-audit.md` | 竞态、幂等、状态机 |
| `07-data-consistency-audit.md` | 事务、迁移、序列化 |
| `08-test-results.md` | 门禁实测、失败用例根因、测试质量 |
| `09-root-cause-analysis.md` | P0/P1 结构化 RCA |
| `10-remediation-roadmap.md` | 四阶段修复路线 |
| `11-coverage-and-limitations.md` | 覆盖度矩阵与残余风险 |
| `findings/P0/` `P1/` `P2/` `P3/` | 分严重度缺陷清单 |
| `_work/A1..A6-*.md` | 6 份工作包原始报告（6,875 行，全量细节） |
