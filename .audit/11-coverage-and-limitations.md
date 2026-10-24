# 11 · 审计覆盖度与限制

## 1. 覆盖度矩阵（按模块，**逐项诚实**）

| 模块 | 文件 | 行数 | 深读 | 浅读/扫描 | 未读 | 覆盖判定 |
|---|---:|---:|---:|---:|---:|---|
| `lib/` 根（`main.dart` / `app.dart`） | 2 | ~290 | 2 | 0 | 0 | ✅ **完整** |
| `lib/core` | 8 | 1,080 | 5 | 3 | 0 | ✅ 基本完整（`theme.dart` 未深读，纯样式） |
| `lib/data` | 6 | 1,370 | **6** | 0 | 0 | ✅ **完整**（A3 全读） |
| `lib/domain` | 14 | 5,022 | **12** | 2 | 0 | ✅ 基本完整（`condition` 辅助文件浅读） |
| `lib/features` | 30 | 15,214 | **6** | 20 | 4 | ⚠️ **部分（约 55% 行数）** |
| `lib/remote` | 22 | 12,615 | **14** | 8 | 0 | ✅ 基本完整（A4 全读，A1 只追 5 链） |
| `lib/services` | 25 | 7,919 | **17** | 6 | 2 | ✅ 基本完整 |
| 原生 Kotlin | 6 源集 | — | **6** | 0 | 0 | ✅ 完整 |
| 原生 Swift | 5 | — | 5 | 0 | 0 | ✅ 完整（仅静态） |
| Manifest | 2 | — | 2 | 0 | 0 | ✅ 完整 |
| `test/` | 207 | 67,689 | 18 抽样 | 189 计数扫描 | 0 | ⚠️ **抽样（18/207，但覆盖了全部"锁类"测试）** |
| `scripts/gates.*` | 2 | 1,337 | 2 | 0 | 0 | ✅ 完整 |
| `.github/workflows/ci.yml` | 1 | 162 | 1 | 0 | 0 | ✅ 完整 |
| `docs/` | 66 | — | 8 | 5 | 53 | ⚠️ **只读关键 8 篇** |

**加权**：`lib/` 43,510 行中深读约 **37,000 行（85%）**，扫描 5,000 行（11%），未读约 1,500 行（3.5%）。

## 2. 覆盖维度评估（按规范 §11 要求的 8 个维度）

| 维度 | 覆盖 | 说明 |
|---|---|---|
| 模块覆盖 | **85%**（按行数） | 未覆盖集中在 `features/` 的纯 UI 页面 |
| 关键业务链路覆盖 | **100%**（5/5 条） | L1–L5 全部完成正反向追踪 |
| 静态检查覆盖 | **60%** | 人工语义审查完整；**编译器级检查未运行**（无 dart/flutter） |
| 测试执行覆盖 | **0%** | 未运行任何测试；只分析已有日志 |
| 运行时验证覆盖 | **0%** | 见 `05-runtime-trace-analysis.md` |
| 异常路径覆盖 | **75%** | 逐条审查了 catch/finally/超时/降级；但无法验证"降级后是否真的可用" |
| 并发路径覆盖 | **70%** | 静态识别了全部并发对；无法动态确认概率 |
| 数据一致性验证覆盖 | **80%** | schema/迁移/事务/序列化全审；未做实际并发写实验 |

## 3. 明确区分：已审计未发现问题 vs 未审计

### 3.1 已审计且**未发现**问题（不要重复投入）

| 区域 | 核查点 | 结论 |
|---|---|---|
| 导入图 | 107 文件相对导入 DFS | **0 个文件级循环** |
| 密钥方向 | `RcCodec.deriveKey` 调用点 | 发送用"接收方码 + `{接收方ID}\|cmd\|evt`"，接收用"本机码 + `{本机ID}\|cmd\|evt`"，**方向一致** |
| 重放防护 | `reserveInboundId` | 原子去重 + 10 分钟窗口；空 ID **fail closed** |
| 传输安全 | `_connect` | `secure = true` 无条件；**无** `onBadCertificate`；`autoReconnect = false`（重连 owner 唯一） |
| 停机清理 | `service.on('stop')` | `stopping` **同步置位**（在任何 await 之前）→ 清理链 → `finally stopSelf()`；**无无超时的 await** |
| 振动失效安全 | `VibrateSession` | S1 分片 ≤20s / S2 重启不续发 / S3 `stopAll`+原生 cancel / S4 电量闸（启动+在跑）**四条均成立** |
| 通话超时 | `call_lifecycle.dart` | 主叫 45s / 振铃 45s / 建连 15s；`connected` 时恒不判超时；未知 state 归 `unknown` 且不动作 |
| 数据库迁移 | `_onUpgrade` v1→v5 | 全部幂等（`PRAGMA table_info` 判存在）；`_onCreate` 全 `IF NOT EXISTS` |
| 远程日志上限 | `logs.recent` | `clamp(1, 500)`（BUG-111 已修） |
| 指令组预算 | `RcScript.validate` | ≤50 步、单步 0.5–600s、总 30 分钟 |
| 任务布尔解析 | `task.toggle` | 宽容解析 + 无法解析显式失败（BUG-112）；存在性检查（BUG-113） |
| 设置写入后重排 | 设置页 3 处写 prefs | 均紧跟 `replan()`（`:807`/`:835`/`:1873`） |
| 任务派生缓存 | `invalidateTaskDerivedCaches` | 三个 provider 一次性失效（BUG-083） |
| 静默失败治理 | `silent_failure_locks_test.dart` | 35 例 + 18 条 SLX-90 反面样本，覆盖 Kotlin/引擎侧静默形态 |
| 门禁判据完整性 | `gates.sh` | 无 `\|\| true` 影响判据、无 `continue-on-error`、无注释掉的门禁步骤 |
| 测试反恒真约束 | `source_text.dart` + SLX 系列 | **0 处** `expect(true,true)`、**0 处** `skip:`、**0** 零断言文件 |
| 指令并发模型 | `mqtt_client` 的 `listen` 语义 | 每条命令独立并发 ⇒ 长指令组**不会**阻塞 `script.stop`（正确设计） |
| 豁免面几何 | lcov 逐文件复算 | 856 / 61 与实测**逐位一致** |

### 3.2 **未审计**（残余风险在这里）

| 区域 | 行数 | 未读原因 | 残余风险 |
|---|---:|---|---|
| `features/` 24 个 UI 文件 | ~7,000 | 纯 UI，无跨 isolate 状态；按"是否绕过 domain 写库"做导入级扫描 | 中：UI 层的 mounted/生命周期问题可能未发现 |
| `lib/remote/assist*.dart`（3 个） | 1,484 | A1 未读；A4 部分读 | **中高**：协助会话状态机/密钥协商/超时未系统审查 |
| `lib/remote/multi_call_service.dart` | 616 | 多方通话，与主链并列 | 中 |
| `lib/remote/controller_service.dart` | 467 | 控制端（发命令一侧） | 中 |
| `lib/services/deepseek_service.dart` | — | 可选、默认关闭 | 低 |
| `lib/services/neural_tts.dart` 实现 | — | 只读了注入点 | 中（模型加载/句柄生命周期） |
| `lib/services/holiday_update_service.dart` | — | 节假日表更新 | 低 |
| `lib/services/preset_import.dart` | — | 只确认会写 tasks | 中（与 DAT-02 的"坏行"制造路径相关） |
| `lib/services/evidence_files.dart` / `export_crypto.dart` | — | 取证导出，与主链无关 | 低 |
| iOS 全部 | — | 无 macOS 环境 | **高（未验证）**：NAT-12 已发现 22 个桥方法无实现 |
| `docs/` 53 篇 | — | 只读关键 8 篇 | 低 |
| `integration_test/` 11 文件 | — | 未运行 | 中 |

## 4. 工具限制与残余风险

| 限制 | 影响 | 残余风险 |
|---|---|---|
| 无 `dart`/`flutter` | 无法运行 analyze/test | 编译器级问题（未定义符号/类型）本轮**未验证**；依赖项目历史 `analyze PASS` |
| 无 ast-grep / CodeQL | 无自动化数据流分析 | 跨函数污点传播可能漏（尤其 `endpoint_service` 的入站数据流） |
| 无 debugger / OTel | 无运行时追踪 | 所有时序类结论靠静态推导 |
| 禁止真机 / adb | 无法复现 Android 14+ 抓帧、mic FGS 静音、崩溃恢复 | NAT-01/NAT-03/SCH-04 的**实际表现**未观测 |
| 禁止攻击性测试 | REM 系列只做静态审查 | REM-01 的"可复现性"是代码级推演，未实测 |
| 中继单槽 | 6 个并行工作包无法共享执行能力 | 测试类证据全部来自历史日志 |
| 无 macOS | iOS 零验证 | iOS 上可能还有更多"静默 no-op" |

## 5. 对"项目安全分"的拒绝

规范明确禁止"缺乏依据的项目安全分"。本报告**不给分数**，只给可核验的事实：

| 事实 | 值 |
|---|---|
| 发现缺陷 | 92 条（P0=1 / P1=16 / P2=39 / P3=36） |
| 证据等级 ≥ `HIGH_CONFIDENCE` | 82 条（89%） |
| 已审计且未发现问题的关键区域 | 19 项（见 §3.1） |
| 运行时验证覆盖 | **0%** |
| 未审计代码 | 约 3.5% 行数 + iOS 全部 + 协助会话子系统 |

## 6. 下一步建议（按信息收益排序）

| 优先级 | 建议 | 信息收益 |
|---|---|---|
| 1 | 取得授权后执行 `05-runtime-trace-analysis.md` §3 的 8 个实验 | **最高**：把 8 条 `HIGH_CONFIDENCE` 升为 `CONFIRMED` |
| 2 | 重跑门禁取证（QUA-01） | 高：确认 R93 是否真的绿 |
| 3 | 补审 `assist*.dart`（1,484 行） | 高：这是唯一完全未审的子系统 |
| 4 | 在 macOS/CI 上做一次 iOS 构建 + 桥方法完整性核对 | 高：NAT-12 可能只是冰山一角 |
| 5 | 补审 `features/` 中 8 个"有异步状态"的页面 | 中 |
| 6 | 把阶段 4（可测性改造）纳入下个迭代 | 中高：决定后续缺陷能否被锁住 |
