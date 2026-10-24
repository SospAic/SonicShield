# 10 · 修复路线图

> 原则：**先止血（数据/安全），再补锁（防复发），再改架构（可测性），最后做体验**。
> 每条标注：缺陷 ID / 动作 / 为什么在这个阶段 / 回归风险。

---

## 阶段 0 · 合入 R93 之前必须做（1 天内）

R93 是**在飞改动**，如果带着下面两条上线，等于"修振动"却带着反向归因。

| # | 动作 | 缺陷 | 为什么必须现在 |
|---|---|---|---|
| 0.1 | 修正 `ringerMode` 常量映射（`0=静音/1=振动/2=正常`），`notificationsMuted => ringerMode==0 \|\| dndActive` | **NAT-02（P1）** | R93 的核心就是振动归因，方向反了会让所有后续排查走错 |
| 0.2 | 给 `respectDnd` 默认值变更补迁移或一次性提示 | **QUA-07（P2）** | 存量任务静默变更行为，用户无感知 |
| 0.3 | 重跑门禁取证 `GATES_RC=0`，落 `_pt/r94gate.log` | **QUA-01（P2）** | R93 目前**没有任何绿色门禁证据** |
| 0.4 | 把 `vibrate_session.dart:184-185`（审计文案分支）纳入测试 | **QUA-05（P2）** | 当前 `DA=0`，R93 的可诊断性改进零覆盖 |
| 0.5 | 回刷全库文档基线（`14221/14367`、残差 `941=146+795`） | **QUA-06（P2）** | 百分比巧合相同，机器锁抓不到，必须人工逐位核 |

---

## 阶段 1 · 立即处理（P0 + 安全，1 周内）

| # | 动作 | 缺陷 | 回归风险 |
|---|---|---|---|
| 1.1 | 删除 `allowUnidentified` 分支：`senderId` 为空一律 `rejectUnidentified`；`tool/rc_probe.dart` 改为填 `from` | **REM-01（P0）** | 旧版控制端若不填 `from` 会全部被拒（`sendTo` 自 v1.3 起统一填充，风险低）；探针工具需同步改 |
| 1.2 | 「删除设备」UI 文案改为「删除并吊销（需重置配对码）」或直接引导重置 | REM-01 | 文案变更，无技术风险 |
| 1.3 | 二维码页面加 `FLAG_SECURE` + 明示「此码等于钥匙，勿截图」 | REM-02（P1） | 需新增平台通道，跨包改动 |
| 1.4 | 配对码熵提升或改为一次性引导 + 端点下发 per-controller 密钥 | REM-02/03（P1） | **架构级**，会改变 HANDOVER §4.6 决策，需老板裁决 |
| 1.5 | 协助会话会合主题改用慢哈希派生（或加盐） | REM-04（P1） | 协议兼容性，需双端同步升级 |
| 1.6 | `cmd` 主题加"未鉴权报文"的廉价前置门（长度/格式/速率），避免 N×PBKDF2(120k) 放大 | REM-05（P2） | 需保证不误伤正常报文 |

---

## 阶段 2 · 数据与任务可靠性（2 周内）

| # | 动作 | 缺陷 |
|---|---|---|
| 2.1 | `markStatus` 增加 `onlyIfStatus` 并返回 `int`；执行前用 `UPDATE ... WHERE id=? AND status='pending'`，`affected==0` 即跳过 | **DAT-03（P1）** |
| 2.2 | 新增 `OccurrenceStatus.running`；claim 写 `running`；启动时把残留 `running` 统一改 `failed` + `interrupted` 审计 | **SCH-04（P1）** |
| 2.3 | `deletePendingForTask` 加 `fire_at > ?`；远程两条路径合并为 `applyTaskChange()` | **SCH-02（P1）** |
| 2.4 | `TaskRepository` 暴露 `inTransaction<T>()`；`CounterPlanService.apply` 三步合一 | **DAT-04（P1）** |
| 2.5 | `OccurrenceRepository.replacePendingForTask()`（删+插单事务）；续算判据补"单任务零计划"检测 | **DAT-05（P1）** |
| 2.6 | `TaskRepository.get()` 加行级 try/catch；`executeDue` for 体内包 per-item try/catch | **DAT-02（P1）** |
| 2.7 | v6 迁移按升级前语义回填 `quiet_exempt` + 一次性 UI 告知 | **DAT-01（P1）** |
| 2.8 | `deleteCounterTasks` 改为"先算新 id 集合 → upsert 新增 → 删不在集合里的旧 id"（无空窗、不删历史） | DAT-04 副作用 |
| 2.9 | 修 `executeDue` 的批次内陈旧判定（批次开始时刻快照）+ `runAction` 执行预算 | **SCH-01（P1）** |
| 2.10 | 引入**任务级执行表** `_runningTasks`，所有入口统一 `tryClaim(taskId)` | **SCH-03（P1）** |

---

## 阶段 3 · 原生与静默假成功（2 周内，可与阶段 2 并行）

| # | 动作 | 缺陷 |
|---|---|---|
| 3.1 | `MediaProjection.registerCallback` + 长驻 VD（抓帧只 `acquireLatestImage`）+ 异常类型回传 | **NAT-01（P1）** |
| 3.2 | 引擎自恢复守卫前探测 mic FGS 通行证；拿不到就 `guardActive:false` + `guardError` + 审计 | **NAT-03（P1）** |
| 3.3 | `KEY_ALARMS` 改为**累加**语义（或按 generation 分桶），`clearAllAlarms` 能清干净 | **ARCH-02（P2）** |
| 3.4 | `vibrate.stop` / `device.alert` 按真实结果回执，不再无条件 success | ARCH-12 / NAT-10（P2） |
| 3.5 | 原生异常不再统一折叠为"平台不支持"，保留异常类型 | NAT-13（P3） |
| 3.6 | 音频焦点 `setActive(false)` 补全 | NAT-04（P2） |
| 3.7 | `MicGuardService` 的 `START_STICKY` 与 microphone FGS 约束冲突需复核 | NAT-08（P2） |

---

## 阶段 4 · 可测性改造（1 个月内，这是"防复发"的根本）

| # | 动作 | 解决什么 |
|---|---|---|
| 4.1 | 把 `executeDue` 循环体抽成纯编排函数：`executeBatch({due, batchStart, runAction})` | SCH-01 / SCH-03 / DAT-03 当前**不可单测**，抽出来才能上锁 |
| 4.2 | 把 `_engineBody` 的 `executing`/`stopping`/`_runningTasks` 抽成可注入的 `EngineState` 对象 | 跨 isolate 并发问题可被宿主机测试覆盖 |
| 4.3 | WT-01/02/03、GT-06 改用 `benchMs(...)`，阈值按实测基线 ×3 重定 | **QUA-02（P1）**：同时消除假红与收紧阈值 |
| 4.4 | 剩余 13 个源码文本锁收敛到 `test/support/source_text.dart` | QUA-10（P3） |
| 4.5 | 新增"文档数字 == lcov 实测"的机器锁（逐位比对绝对分数，不只比百分比） | QUA-06 的**结构性防复发**（已复发两次） |
| 4.6 | 新增"模型 `toMap` 键集变更必须同 PR 更新锁"的检查（或把键集锁改为双向差分） | QUA-01 类问题的防复发 |
| 4.7 | `gates.ps1` 补压测重跑 + 负载定性；或明确声明 ps1 为"快速通道"不具等价判据 | QUA-03（P2） |

---

## 阶段 5 · 中长期架构改进（下个大版本）

| # | 动作 | 理由 |
|---|---|---|
| 5.1 | **按设备独立密钥模型**（每控制端一把 32B 密钥，可单独吊销） | REM-01/02/03 的**唯一根治**。需老板裁决是否修改 HANDOVER §4.6 |
| 5.2 | 拆分 `endpoint_service.dart`（4,468 行 → 传输/协议/鉴权/业务编排 4 个文件） | 授权模型目前嵌在巨型文件里，无法独立审查 |
| 5.3 | occurrence 状态机补 `cancelled` 态，让"撤销/丢弃"可与"用户跳过"区分 | 根因 C |
| 5.4 | 统一"任务状态"为单一状态字段，替换 4 个布尔/三态的组合判据 | 根因 A |
| 5.5 | 引擎状态机补"僵尸自愈"（`stopping` 超时可复位） | SCH-15 |
| 5.6 | 把"三个入口同一条通路"变成**编译期强制**（统一 `applyTaskChange` / `applyTaskToggle`） | ARCH-06 / SCH-02 的防复发 |
| 5.7 | 决定 CI 是否恢复测试门（当前 GEC-06 锁死"零测试"形状，需先改锁） | QUA-04 |

---

## 不建议做的事（避免"把绕过当修复"）

| 反模式 | 为什么不做 |
|---|---|
| 给 `markStatus` 加 try/catch 了事 | 不解决"两个连接都认为自己抢到了"的根因（DAT-03） |
| 把 `catchUpLimit` 调大 | 长动作 1800s 时，调到多大都可能被吃穿；真正要改的是"排队不计入迟到"（SCH-01） |
| 把 10 分钟陈旧阈值调大 | 会让"半夜补响早已过期的计划"问题复发（BUG-094 的原始症状） |
| 把 `PERF_RETRY` 当长期方案 | 只是把噪声在脚本层消化，`PERF_RETRY=0` 时仍会红（QUA-02） |
| 延长 `_awaitAck` 超时 | 不解决配对语义（L4 断点） |
| 在 `removePaired` 里轮换配对码 | 会让**所有**控制器一起失联，用户体验灾难（REM-01 备选方案已否决） |

---

## 工作量估算（相对量级，非承诺）

| 阶段 | 条目 | 相对工作量 | 阻塞关系 |
|---|---:|---|---|
| 0 · R93 合入前 | 5 | 小（0.5 天） | 阻塞 R93 收口 |
| 1 · P0 + 安全 | 6 | 中（3–5 天，1.4 需裁决） | 1.1 独立可做 |
| 2 · 数据可靠性 | 10 | **大（8–12 天）** | 2.1/2.2 需先做，其余依赖 |
| 3 · 原生 | 7 | 中（4–6 天） | 3.1 需真机验证 |
| 4 · 可测性 | 7 | 大（6–10 天） | 4.1/4.2 是 4.3 的前提 |
| 5 · 架构 | 7 | 很大（跨版本） | 5.1 需老板裁决 |
