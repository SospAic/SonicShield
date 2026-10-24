# SonicShield 全栈深度代码审计 · 交付集

```
项目:   E:\SonicShield
版本:   1.9.9+32   分支: main   HEAD: a93f595 (R92 收口)
模式:   AUDIT_ONLY（未修改任何业务代码）
时间:   2026-10-22
规模:   lib/ 107 文件 / 43,510 行 · test/ 207 文件 / 67,689 行
```

## 结果速览

| 严重度 | 数量 |
|---|---:|
| P0 / Critical | **1** |
| P1 / High | **16** |
| P2 / Medium | **39** |
| P3 / Low | **36** |
| **合计** | **92** |

**证据等级**：`CONFIRMED` 58 / `HIGH_CONFIDENCE` 24 / `SUSPECTED` 7 / `UNVERIFIED` 3。

## 先读这三份

1. **`00-executive-summary.md`** —— 一句话结论、必做 5 件事、三条贯穿性根因
2. **`findings/P0/P0-001-REM-01.md`** —— 唯一的 P0（远程撤销配对失效）
3. **`10-remediation-roadmap.md`** —— 分 6 阶段的修复路线

## 文件索引

| 文件 | 内容 |
|---|---|
| `00-executive-summary.md` | 执行摘要：范围、缺陷总览、必做项、根因、工具限制、未覆盖声明 |
| `01-architecture-map.md` | 技术栈、7 层架构图、跨 isolate 拓扑、启动/停机链 |
| `02-module-dependency-map.md` | 依赖矩阵、循环依赖（0 个文件级）、分层倒置、上帝类判断 |
| `03-critical-call-chains.md` | L1–L5 五条关键链路正反向追踪 + 断点表 |
| `04-static-analysis-results.md` | 静态检查结论、跨模块契约不一致、静默错误 13 类扫描、死代码 |
| `05-runtime-trace-analysis.md` | ⚠️ **运行时未执行**声明 + 可用证据 + 待做实验清单 |
| `06-async-concurrency-audit.md` | 执行模型、竞态清单、幂等性、任务丢失面、状态机、定时器生命周期 |
| `07-data-consistency-audit.md` | Schema、迁移链、事务边界清单、序列化对齐、并发写 |
| `08-test-results.md` | 门禁四步实测、两个失败用例根因、三落点一致性、测试质量抽样 |
| `09-root-cause-analysis.md` | 8 条结构化 RCA（Symptom→Root Cause→复现→备选假设） |
| `10-remediation-roadmap.md` | 阶段 0–5 修复路线 + 不建议做的反模式 + 量级估算 |
| `11-coverage-and-limitations.md` | 覆盖度矩阵、已审计未发现问题清单、未审计清单、残余风险 |
| `findings/P0/` | 1 条完整报告 |
| `findings/P1/P1-index.md` | 16 条，含期望/实际/触发/根因/修复/回归风险 |
| `findings/P2/P2-index.md` | 39 条表格（含位置/影响/修复指向） |
| `findings/P3/P3-index.md` | 36 条表格 + 建议顺手带的 4 条 |
| `_work/A1..A6-*.md` | 6 份工作包原始报告（6,875 行，全量证据） |

## 审计方法

6 个并行工作包：

| 包 | 范围 | 报告 |
|---|---|---|
| A1 | 全局架构与关键调用链 | `_work/A1-architecture.md`（1,078 行，12 条） |
| A2 | 调度引擎 / 异步并发 / 状态机 | `_work/A2-scheduling.md`（1,242 行，15 条） |
| A3 | 数据层 / 持久化 / 一致性 | `_work/A3-data.md`（1,094 行，18 条） |
| A4 | 远程遥控 / 网络 / 安全 | `_work/A4-remote-security.md`（1,626 行，16 条） |
| A5 | 原生桥接 / 生命周期 | `_work/A5-native.md`（1,213 行，18 条） |
| A6 | 静态检查 / 测试证据 / 静默错误 | `_work/A6-quality.md`（622 行，13 条） |

主控在汇总前对 6 条关键结论做了**独立复核**（未直接采信 agent 说法）：

| 复核项 | 方法 | 结果 |
|---|---|---|
| REM-01 空 `from` 放行 | 读 `endpoint_service.dart:3696-3714` | ✅ 属实（`allowUnidentified` 在 :3711） |
| ARCH-02 闹钟引用丢失 | 读 `NativeBridgePlugin.kt:361/412/418` | ✅ 属实（`saved` 每次新建 + 整体覆盖） |
| SCH-01 陈旧阈值 | 读 `background_engine.dart:1493/1508` | ✅ 属实（`limit:3` + 10min） |
| SCH-02 删全部 pending | 读 `occurrence_repository.dart:229-233` | ✅ 属实（where 无 `fire_at`） |
| NAT-01 无 registerCallback | 全仓 grep | ✅ 属实（0 处命中，`ImageReader` 有 2 处使用） |
| DAT-01 迁移只补列 | 读 `app_database.dart:203-221` | ✅ 属实（无回填） |

## 工具使用声明

| 能力 | 状态 |
|---|---|
| 代码搜索（ripgrep / Glob / Read） | ✅ 已用 |
| `flutter analyze` / `flutter test` | ❌ **未运行**（沙箱无 dart/flutter） |
| ast-grep / CodeQL / LSP / Serena | ❌ 不可用（未安装，AUDIT_ONLY 禁止安装） |
| debugger / OTel / py-spy | ❌ 不可用（无运行时、无埋点） |
| 真机 / adb | ❌ **未使用**（规则禁止） |

> 凡涉及运行时行为的结论均已降级标注。**本轮运行时验证覆盖度为 0%**，
> 详见 `05-runtime-trace-analysis.md` 与 `11-coverage-and-limitations.md`。

## 复现方式

审计为**只读**，无脚本可复现。核对方式：

```bash
# 1. 验证未修改业务代码
git status --porcelain | grep -v '^?? .audit/'
#    预期：只出现 R93 在飞改动（mtime 均为 2026-10-21，早于本次审计）

# 2. 抽查任一结论
sed -n '3696,3714p' lib/remote/endpoint_service.dart      # REM-01
sed -n '229,233p'  lib/data/repositories/occurrence_repository.dart  # SCH-02
sed -n '1493,1517p' lib/services/background_engine.dart   # SCH-01
```

## ⚠️ 与工作区状态的关系

审计开始时工作区已有**未提交的 R93 改动**（8 改 1 增），全程未触碰。
R93 引入了 **NAT-02（P1，振动归因反向）** 与 **QUA-07（P2，默认值变更无迁移）**，
且最后一次门禁实测为 **`GATES_RC=1`**（`_pt/r93gate.log`）——
**建议合入前处理 `10-remediation-roadmap.md` 的阶段 0。**
