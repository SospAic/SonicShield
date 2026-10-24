# P1 缺陷清单（16 条）

> 每条给出：严重度 / 证据等级 / 位置 / 期望 / 实际 / 触发 / 根因 / 修复 / 回归风险。
> 完整证据（代码片段、最小复现用例、调用链）见对应工作包报告章节（`_work/A*.md`）。

| # | ID | 标题 | 证据 | 报告章节 |
|---|---|---|---|---|
| 1 | SCH-01 | 单执行槽 + 10 分钟陈旧阈值 + `catchUpLimit=3`：长动作吞掉同批与后续所有到期计划 | CONFIRMED | A2 §SCH-01 |
| 2 | SCH-02 | 远程 `task.upsert`/`toggle` 删**全部** pending（含已到期未执行）⇒ 计划永久丢失 | CONFIRMED | A2 §SCH-02 |
| 3 | SCH-03 | `runNow`/声音触发/守卫计划 与定时执行**不共用执行锁** ⇒ 同一任务并发跑两份 | CONFIRMED | A2 §SCH-03 |
| 4 | SCH-04 | occurrence 无 `running` 态，用 `failed` 充当"已取走"标记 ⇒ 崩溃后永久 failed、"跳过下一次"打偏 | CONFIRMED | A2 §SCH-04 |
| 5 | DAT-01 | 迁移把 `quiet_exempt` 从开关重解释为三态，老库免打扰护栏被静默放宽 | CONFIRMED | A3 §DAT-01 |
| 6 | DAT-02 | `executeDue` 对单条坏任务行无隔离 ⇒ 一条坏行让整轮到期计划全部作废 | CONFIRMED | A3 §DAT-02 |
| 7 | DAT-03 | "乐观置状态"不是 CAS ⇒ 跨连接并发可重复执行同一 occurrence | HIGH_CONFIDENCE | A3 §DAT-03 |
| 8 | DAT-04 | `CounterPlanService.apply(replace:true)` 两个独立事务 ⇒ 失败即丢整套计划 + 级联抹掉历史 | CONFIRMED | A3 §DAT-04 |
| 9 | DAT-05 | 远程 `task.upsert` 三段写非原子，且失败后**不被全局续算自愈** | CONFIRMED | A3 §DAT-05 |
| 10 | REM-02 | 配对码 = 唯一长期凭据（≈40 bit、永久、可拍照、可离线爆破、可降级绕过 PBKDF2） | HIGH_CONFIDENCE | A4 §REM-02 |
| 11 | REM-03 | 配对码随 `pair.request` 下发 ⇒ 每个已配对端点都掌握控制端全局码 | CONFIRMED | A4 §REM-03 |
| 12 | REM-04 | 协助会话会合主题是密码的快速哈希 ⇒ 「抗离线爆破」声明不成立；5 次锁定对猜密码无效 | CONFIRMED | A4 §REM-04 |
| 13 | NAT-01 | Android 14+ 单帧抓屏 100% 失败：`createVirtualDisplay` 前未 `registerCallback` | CONFIRMED | A5 §NAT-01 |
| 14 | NAT-02 | 【R93 在飞】`ringerMode` 常量映射颠倒（0/1/2 写成正常/静音/振动） | CONFIRMED | A5 §NAT-02 |
| 15 | NAT-03 | 守卫自恢复无 microphone 型 FGS 通行证 ⇒ 采到全静音，UI 仍报"运行中" | HIGH_CONFIDENCE | A5 §NAT-03 |
| 16 | QUA-02 | 压测层 16/24 用例用裸 `Stopwatch` 单次采样（min-of-1）⇒ WT-02 假红 | CONFIRMED | A6 §QUA-02 |

---

## 1. SCH-01 · 长动作吞掉同批与后续所有到期计划

```
Severity: P1        Evidence: CONFIRMED（容量算术 + 判定代码均为直接可读事实）
位置: lib/core/constants.dart:92(tick=15s)/:98(catchUpLimit=3)
      lib/services/background_engine.dart:1478-1487(executing 闸)/:1493(due limit:3)
      /:1501(串行 for)/:1507-1508(逐条实时陈旧判定)/:1572(await runAction)
      lib/domain/models/action.dart:299(录音上限 1800s)/:125(_maxActionDurationSec=86400)
      lib/remote/task_wire.dart:38(远程 maxDurationSec=3600)
```

- **期望**：一批到期计划应按到期时刻尽快执行；因资源竞争无法执行时应**显式记账**。
- **实际**：整批只持一个执行槽且**串行**。第 1 条若耗时 T，第 2/3 条要等 T 之后才做陈旧判定；`T > 10min` ⇒ 它们**必然**被判 stale ⇒ `markStatus(skipped)` ⇒ 永不执行。期间所有 tick 被 `executing` 拒绝，新条目继续堆积。
- **触发**：同一 15s 窗口 ≥2 条到期，前一条时长 > 10min（录音取证 UI 允许 1–1800s）；或一条 > 10min 播放（远程 1h、导入 24h）。
- **根因**：把"执行"与"排队"耦合在同一串行槽，用绝对墙钟差值当唯一丢弃判据；`catchUpLimit=3 × 1800s ≫ 10min` 从未被校验。
- **修复**：① 批次开始时刻快照判定（批次内排队不计入迟到）；② `runAction(...).timeout(min(声明时长+30s, 10min))`；③ 长动作不占执行槽（需配合 SCH-04 的 `running` 态）。
- **回归风险**：`REENT-01..04` 是源码契约锁（`test/engine_reentrancy_test.dart:55-86`），会检查 `executeDue` 首部形状；`BUG-094` 的"逐条实时时刻"注释会被推翻，需同步改注释与文档。
- **注**：`executeDue` 循环体是闭包，**不可单测** —— 这是本缺陷难以被锁住的原因（见阶段 4.1）。

## 2. SCH-02 · 远程改任务删掉已到期未执行的计划

```
Severity: P1        Evidence: CONFIRMED
位置: lib/remote/endpoint_service.dart:1947(_upsertTask)/:1243(task.toggle)/:2148-2153(_rematerialize)
      lib/data/repositories/occurrence_repository.dart:229-233(where 无 fire_at 过滤)
      lib/domain/scheduling/schedule_engine.dart:367-368(_inRange 不回填过去)
      对照 occurrence_repository.dart:46-58(reconcile 只删 fire_at > now)
```

- **期望**：改任务定义时只撤销"与新定义不符的**未来**计划"；已到期待补执行的必须保留。
- **实际**：`deletePendingForTask` 删**所有** pending，随后只物化 `>= now`。`fire_at <= now` 且未被取走的 occurrence **被永久删除**：不执行、不留 `skipped`。
- **触发**：T 在 10:00:00 到期 → 10:00:07 仍 pending → 10:00:08 控制端 `task.upsert`（哪怕只改名字）→ 被删 → 10:00:15 tick 查不到。
- **根因**：把"清理旧计划"实现成"清空 pending"，依赖"物化会重新生成"；但物化刻意不回填过去时刻（正确）⇒ 删除即丢失。远程路径**没有复用 `reconcile` 语义**，违反"三个入口同一条通路"。
- **修复**：`deletePendingForTask` 加 `fire_at > ?`；或暴露 `reconcile([taskId], entries, now)`；两条路径合并成 `applyTaskChange()`。
- **回归风险**：`P1-16` 的"停用任务时清 pending"依赖该行为，需改为"未来 pending 删除 + 已到期标 skipped"。

## 3. SCH-03 · 三个执行入口不共用锁 ⇒ 同一任务并发两份

```
Severity: P1        Evidence: CONFIRMED（结构性）
位置: background_engine.dart:458(executing 是局部变量)/:1478(只有 executeDue 检查)
      /:2121-2181(runNow 无锁)/:1670-1747(onSoundEvent→runGuardPlan 无锁)
      playback_service.dart:163(每次 play 新建 AudioPlayer)
```

- **期望**：同一任务在任一时刻至多一个执行实例。
- **实际**：`executing` 只保护 `executeDue` 的**自身重入**，不是任务级互斥。`runNow` 与 `executeDue` 并发 ⇒ 两条 `runAction` ⇒ 双响；录音各建 recorder ⇒ 第二个抢不到麦克风但写一条 `failed`，搅乱 `lastDoneFor`。
- **触发**：长动作执行中点"立即执行"；或控制端并发两条 `task.runNow`；或任务从 `dailyAt` 改为 `soundTriggered` 且存在已到期 pending。
- **根因**：把"防重入"当成了"互斥"。二者粒度不同，注释也把前者写成了后者。
- **修复**：引入任务级执行表 `_runningTasks`（taskId → occurrenceId），所有入口统一 `tryClaim(taskId)`，`finally` 释放；`runNow` claim 失败返回 `busy` 并如实回执。
- **回归风险**：`REENT-06` 断言守卫是 `_engineBody` 内局部状态 —— 新增表放同一闭包即可通过；远程回执文案新增 `busy`（协议是自由文本，风险低）。

## 4. SCH-04 · occurrence 无 `running` 态，`failed` 被借用为占用标记

```
Severity: P1        Evidence: CONFIRMED（状态语义）；崩溃概率 UNVERIFIED
位置: lib/domain/models/task.dart:183(仅 4 态)
      background_engine.dart:1562-1571(先标 failed 等价"已取走")/:1588(终态覆盖)
      occurrence_repository.dart:171-182(markStatus 无条件)/:237-248(skipNext 只找 pending)
      retention_maintenance.dart:82(非 pending 7 天清理)
```

- **三个可观察后果**：
  1. **崩溃 = 永久失败**：claim 写 `failed` 后进程被杀 ⇒ 重启仍 `failed`，`due()` 不再取 ⇒ 不重试、不补执行；7 天后连痕迹一起删。
  2. **"跳过下一次"打偏**：执行中那一秒点跳过，`skipNextForTask` 找 `pending` ⇒ 跳过的是**再下一条**；随后占用行被覆盖成 `done` ⇒ 这次照响、下次被吞。
  3. **UI 语义污染**：执行中的任务短暂显示"失败"；`lastDoneFor` 只认 `done`，无法区分"中断"与"失败"。
- **根因**：状态枚举缺"执行中/已中断"，"占用"只能借用终态；`markStatus` 无条件更新又让所有并发写变成"最后写入者胜"。
- **修复**：新增 `running`（`values.byName` 向后兼容）；`markStatus(id,to,{from})` 返回受影响行数（CAS 基础）；启动时残留 `running` 改 `failed` + `interrupted` 审计；`skipNextForTask` 候选集扩到 `pending|running`。
- **回归风险**：`fromRow` 的 `values.byName` 对未知值会抛 ⇒ 降级安装会崩（单向前进可接受，需在 `app_database` 版本注释记录）。

## 5. DAT-01 · 免打扰语义迁移未回填

```
Severity: P1        Evidence: CONFIRMED（代码/历史版本）；业务影响 HIGH_CONFIDENCE
位置: lib/data/db/app_database.dart:200-221(v4 只补列不回填)
      lib/domain/models/task.dart:44-57/125-129/149-156(三态语义)
      lib/domain/scheduling/schedule_engine.dart:184-192(exempt = taskExemptOverride ?? allowQuietExempt)
```

- **实际**：v3 时代 `quiet_exempt` 是布尔（判据 `master && task`）；v79 改为三态（判据 `task ?? master`）。迁移只补列（值全 0），无回填：
  - 老行 `0`（旧"不豁免"）→ 新 `null`（跟随主开关）⇒ 主开关开着就变成**豁免**；
  - 老行 `1`（旧"豁免"）⇒ 新 `true`（强制豁免）⇒ 主开关关也豁免。
  **两条路径都单向放宽了 22:00–07:00 护栏。**
- **现场佐证**：R92 真机观察"首页下一触发落在免打扰窗口内"（`memory/2026-10-20.md`）与"老库 `=1` → 强制豁免"完全吻合。
- **根因**：语义迁移缺数据回填，迁移注释只覆盖"主开关默认 false"的情形。
- **修复**：v6 迁移按升级前语义回填（`oldV<79` ⇒ 统一改 `2` 强制不豁免，或按主开关快照）+ 一次性 UI 告知 + 一条 `exec_logs` 审计。
- **回归风险**：回填为 `2` 会让原"主开关开即豁免"的用户失去豁免（收紧方向，安全但可能被投诉）。

## 6. DAT-02 · 单条坏任务行毒杀整轮执行

```
Severity: P1        Evidence: CONFIRMED（代码路径）；触发需存在坏行（SUSPECTED）
位置: background_engine.dart:1518(tasksRepo.get 裸调用)/:1487-1606(try 无 catch)
      task_repository.dart:48-52(get 无行级兜底)/task.dart:138-163(byName/jsonDecode 会抛)
```

- **实际**：`listAll` 已做行级兜底（R90-09），但 `get()` 没有。`executeDue` 循环里 `get()` 抛 ⇒ 异常穿出 `for` ⇒ **该轮剩余所有到期计划都不执行**；下一 tick 同顺序再抛，直到 10 分钟后该条被"过期丢弃"，整批才继续 —— 而此时其它条目也已过期。
- **触发**：`tasks` 存在任一行无法被 `Task.fromRow` 解析（旧版本写入的新 kind、手工改库、导入半损坏 JSON）。`settings_screen._importTasks` **不经过 TaskWire**，只做 `values.byName` ⇒ 导入即可制造坏行。
- **修复**：`get()` 内部 try/catch 返回 null + `onRowError` 回调；`executeDue` for 体内包 per-item try/catch（失败只 `markStatus(failed)` + 审计）。
- **回归风险**：`get()` 返回 null 会被现有调用点当作"任务不存在"，需区分"不存在"与"损坏"的审计文案。

## 7. DAT-03 · `markStatus` 不是 CAS

```
Severity: P1        Evidence: HIGH_CONFIDENCE（代码事实 CONFIRMED；双实例并发为条件）
位置: occurrence_repository.dart:171-182(返回 void，丢弃 update 行数，无 status 条件)
      background_engine.dart:1562-1572(乐观置状态)/:1911(注释声称"由 executing + 乐观置状态兜住")
      app_database.dart:36-55(singleInstance:false ⇒ 两个引擎各持一条连接)
```

- **实际**：`SELECT`（`due()`）→ 无条件 `UPDATE ... WHERE id=?`。两条连接同时 `due()` 会拿到同一批行，两者都"置状态成功"，两者都执行 ⇒ **同一计划播两次**。`markStatus` 连 `update()` 返回值都丢掉。
- **触发**：原生精确闹钟唤醒"第二份服务"与通道 A 的 15s tick 并发（代码注释自己承认存在：`:446`、`:1911`）；或引擎重启期间新旧实例短暂并存。
- **修复**：`markStatus` 增加 `onlyIfStatus` 并返回 `int`；执行前 `UPDATE ... WHERE id=? AND status='pending'`，`affected==0` 即跳过；终态覆盖用 `WHERE status='failed'`。
- **回归风险**："先标 failed 再按真实结果覆盖"需改成两段 CAS；`skipped` 分支（暂停/条件/概率）也要改 CAS 以免与执行路径互相覆盖。

## 8. DAT-04 · 反击计划"整族删除 + 批量插入"非原子

```
Severity: P1        Evidence: CONFIRMED
位置: lib/services/counter_plan_service.dart:96-100(delete→upsertMany→savePlan 三步独立)
      task_repository.dart:204-208(deleteCounterTasks 级联)
      app_database.dart:150-158(occurrences.task_id ON DELETE CASCADE)
```

- **实际**：删除先提交；`upsertMany` 若失败（磁盘满 / `database is locked` / 进程被杀 / 约束错误），**旧计划已删光、新计划一条没写**。`prefs.counter_plan_enabled` 仍为 true ⇒ UI 显示"已启用"，实际零任务。同时级联删掉这些任务的**全部 occurrence 历史**，而 `exec_logs` 因无外键保留 ⇒ 审计出现"日志说有执行、计划表里查不到"的断裂。
- **根因**：跨仓储"删+建"没有共享事务；`TaskRepository` 未暴露事务句柄。
- **修复**：`TaskRepository.inTransaction<T>()` 把三步合一（prefs 移到事务后 + 启动自愈）；或改为"先算新 id 集合 → upsert 新增 → 删不在集合里的旧 id"（无空窗、不删历史）。
- **回归风险**：事务内混入 prefs 会拉长写锁；需接受"DB 成功、prefs 失败"的窄窗口。

## 9. DAT-05 · 远程 `task.upsert` 三段写失败后不自愈

```
Severity: P1        Evidence: CONFIRMED（代码路径）；触发需一次写失败
位置: endpoint_service.dart:1946-1948(三段写)/:2130-2168(_rematerialize)
      background_engine.dart:2313-2321(续算判据只看全局 latestPendingFireAt)
      occurrence_repository.dart:119-127(MAX(fire_at) 全表聚合)
```

- **实际**：`commitAll` 抛错 ⇒ 任务行已更新、旧 pending 已删、新 pending 一条没有。续算判据是**全局** `MAX(fire_at)`；反击计划动辄数百条把覆盖维持在 48h ⇒ `planNeedsExtend` 恒 false ⇒ **该任务永远不会被重新物化**（稳态约 36h 一次）。表现：远程改完任务，回执"失败"，然后该任务**长期不响**。
- **修复**：① `replacePendingForTask()`（删+插单事务）；② 续算判据补"存在 enabled 且非 sound 的任务在未来 12h 内零 pending ⇒ 需要 replan"，限制为每 N 轮执行。
- **回归风险**：新增判据会增加 replan 频率（每 tick 一次 GROUP BY），需限流或加索引。

## 10. REM-02 · 配对码 = 唯一长期凭据（≈40 bit）

```
Severity: P1        Evidence: HIGH_CONFIDENCE（代码事实 CONFIRMED；"可爆破"未实测）
位置: protocol.dart:520-526(8 位 × 32 字母表 = 2^40)/:392-434(PBKDF2 120k)
      remote_store.dart:328-363(ensurePairingCode 只在长度≠8 时生成一次)
      endpoint_service.dart:3419-3433(requestPairing withSalt:false)/:865-885(cmd 试解候选首项 null)
      features/remote/pair_qr_screen.dart:204-223,240-274
```

- **实际**：
  - 配对码 = `32^8 = 2^40`，**就是**消息密钥 IKM，**永不自动轮换**；
  - 二维码明文包含它，页面**未设 `FLAG_SECURE`**（全仓 grep 无）；
  - `pair.request` **恒以无盐 v1 派生**，而 cmd 试解候选**第一项恒为 `null`** ⇒ PBKDF2 硬化可被"用无盐格式发送"绕过，且攻击者永远能拿到无盐密文样本。
  - 离线攻击成立：抓一条 `pair.request` 密文 → 对 2^40 候选做 HKDF + AES-GCM 解封验证 → 命中即得端点主密钥。
- **触发**：攻击者能在 MQTT 层看到密文（默认公共 broker 无鉴权无 ACL），且目标设备曾发生过一次配对。
- **根因**：把"人类可转录的短码"直接当密码学主密钥。40 bit 对**在线**猜测足够，对**离线**验证远远不够。
- **修复**：码熵 ≥100 bit，或保持 8 位**仅作一次性引导**（成功后端点下发 per-controller 32B 密钥）；引导报文也必须带盐；移除 cmd 试解候选中的 `null` 兜底；二维码页加 `FLAG_SECURE`。
- **回归风险**：改码长破坏现有二维码/手输/测试夹具（`PairQrProtocol.parseUri` 的 8 位硬校验、`_base32Code` 正则）；移除 `null` 候选会让旧配对设备静默失联，需过渡期。

## 11. REM-03 · 配对码随 `pair.request` 下发

```
Severity: P1        Evidence: CONFIRMED（机制）；实际影响取决于能否订阅他人 evt 主题（公共 broker 可）
位置: endpoint_service.dart:1728-1814(_handlePairRequest, secret: code)
```

- **实际**：`pair.request` 的 ack 里带上端点的配对码 ⇒ **每个已配对控制端都掌握控制端的全局码**，可横向解密/伪造该控制端与**其它**端点的全部流量。
- **修复**：ack 中只下发 per-peer 盐与 per-controller 密钥，绝不下发全局码。
- **回归风险**：需双端同步升级；旧端点在过渡期内仍依赖该字段。

## 12. REM-04 · 协助会话会合主题是密码的快速哈希

```
Severity: P1        Evidence: CONFIRMED（topic 派生与失败计数位置可证）；爆破成本 HIGH_CONFIDENCE
位置: lib/remote/assist.dart:94-114(topicFor = SHA256(code|password) 前 16 hex = 64 bit)
      /:56-67(9 位数字码 / 8 位密码)/:40-41(maxFailures=5)
      assist_host.dart:328-353(onWire 失败计数)/:507-516(_onHandshakeFailure)
      docs/18:94-109,142-143(声明"不可离线攻击")
```

- **实际**：
  - topic 是 `SHA256(code|password)` 的**确定性快速哈希**，且 **topic 对 broker 与任何订阅者可见**（MQTT 不加密主题）；
  - 文档同时明确"临时码是公开的" ⇒ **知道公开码 + 观测到 topic ⇒ 对 2^40 密码候选做单次 SHA-256 离线比对**（GPU 分钟级）；
  - 「5 次失败锁定」只在**报文到达真实会话 topic 且解密失败**时计数；密码猜错 ⇒ topic 也算错 ⇒ 报文根本不到达 ⇒ **永不计数、永不锁定**。
- **根因**：把"口令校验器"放进了**公开可见的命名空间**。设计者假设 topic 不可被观测，但 MQTT 主题始终可见且默认 broker 无 ACL；同时密码只有 40 bit 且未做慢哈希。
- **缓解**：协助会话权限默认全拒（`AssistPerms.none`），攻击者接入后仍需端点用户逐项授权 —— 这是定 P1 而非 P0 的原因。
- **修复**：topic 改用慢哈希（PBKDF2 ≥100k / Argon2id）截断；或随机 nonce + 带密码 hello；密码熵 ≥64 bit；修正 `docs/18 §4.2` 的表述（修复前不能再声称"不可离线攻击"）。
- **回归风险**：改 topic 派生会让进行中会话失效（TTL 10 分钟，可接受）；慢哈希在低端机有 100ms 级延迟（仅握手时）。

## 13. NAT-01 · Android 14+ 单帧抓屏 100% 失败

```
Severity: P1        Evidence: CONFIRMED（代码 + Android 官方文档原文核对）
位置: android/app/src/main/kotlin/com/sonicshield/sonic_shield/ScreenCastService.kt:144-219（尤其 :171-183）
      packages/native_bridge/.../NativeBridgePlugin.kt:198-209
      lib/services/native_bridge.dart:297-299、lib/remote/endpoint_service.dart:1479-1494
```

- **实际**：Android 14（API 34）起，targetSdk ≥34 必须**先 `registerCallback` 再 `createVirtualDisplay`**，否则抛 `IllegalStateException`；全仓 **0 处** `registerCallback`（`grep -rn "registerCallback" android packages` 无结果）⇒ `captureOnce` 必抛 → 被 catch 吞成 `finish(null)` → 远程"拍一张"永远失败。
  次生：官方规定**同一 `MediaProjection` 只能调一次 `createVirtualDisplay`**，本实现把 `projection` 缓存在服务字段里复用 ⇒ 即使补上 callback，第二次抓帧仍必失败。
- **触发**：Android 14+（含 Redmi K70 Pro / Android 16），`screen.cast{once:true}`。**必现**。
- **误导性**：`endpoint_service.dart:1467-1473` 把 `false` 记成"用户拒绝投屏授权" ⇒ 排障方向被带偏。
- **修复**：`ACTION_START` 里 `registerCallback`（`onDestroy` 里 unregister）；改为长驻 VD + 抓帧只 `acquireLatestImage()`（官方推荐），或每次抓帧重新授权；失败时 `result.error("CAPTURE_FAILED", e.message, null)`。
- **回归风险**：长驻 VD 持续占编码资源（耗电）；每次抓帧授权会改变交互（每次弹窗）。`onStop` 回调里 `stopCast()` 需避免与 `stopSelf()` 递归。

## 14. NAT-02 · `ringerMode` 常量映射颠倒（R93 在飞）

```
Severity: P1        Evidence: CONFIRMED（javap -constants android.jar 核对常量值）
位置: lib/domain/models/vibrate_caps.dart:113(notificationsMuted)/:116-121(ringerLabel)
      lib/services/vibrate_session.dart:183-187(审计消息)
      packages/native_bridge/.../NativeBridgePlugin.kt:712-717(读值本身正确)
```

- **SDK 事实**：`RINGER_MODE_SILENT=0` / `RINGER_MODE_VIBRATE=1` / `RINGER_MODE_NORMAL=2`。
- **实际**：代码写 `0 => 正常, 1 => 静音, 2 => 振动`，且 `notificationsMuted => ringerMode==1 || ringerMode==2` ⇒ **完全反了**：
  - 绝大多数手机处于 `NORMAL(2)` ⇒ 被判"振动中"且 `notificationsMuted=true` ⇒ **每条振动审计都挂假告警**（文案自相矛盾）；
  - 真正 `SILENT(0)` ⇒ 显示"正常"、不告警 ⇒ **真实故障被漏报**。
- **根因**：凭印象写常量，且没有单测锁住映射。
- **修复**：`notificationsMuted => ringerMode == 0 || dndActive`；`ringerLabel => 0:静音, 1:振动, 2:正常, _:读不到`；补参数化单测（`ringerMode ∈ {0,1,2,-1} × dndActive ∈ {false,true}`）。
- **回归风险**：R93 的 `test/r93_vibrate_dnd_test.dart` 若按错误映射断言，需同步修正。

## 15. NAT-03 · 守卫自恢复无 microphone FGS 通行证

```
Severity: P1        Evidence: HIGH_CONFIDENCE（代码链路 CONFIRMED；静音为 Android 11+ 官方行为，未真机复现）
位置: background_engine.dart:2358-2360(bootstrap 自恢复)/:1918-1940(guard 监听)
      lib/services/sound_guard_service.dart:139-159(直接 startStream，不做权限/前台判定)
      lib/features/guard/guard_toggle.dart:118-126(唯一会 startMicService 的路径)
      packages/native_bridge/.../MicGuardService.kt:14-25(文档明确"通行证"语义)
```

- **实际**：引擎每次 bootstrap 只读 `prefs['guard_enabled']` 然后 `service.invoke('guard')`；整条链**没有任何 `startMicService` 调用**。进程被杀 → 看门狗/开机闹钟拉起 `BackgroundService`（类型 `mediaPlayback`）→ 引擎自恢复守卫 → `AudioRecord.startRecording()` 在后台**不抛异常但只返回静音**（Android 11+ while-in-use 语义）→ 声音事件永不产生，而 `guard.isRunning=true` → 回投 `guardActive:true`。
- **触发**：用户曾开守卫 → 进程被系统杀/被划掉/重启 → 由闹钟或开机 Receiver 拉起引擎（非用户点开关）。
- **根因**："守卫状态"（prefs）与"麦克风通行证"（FGS 生命周期）是两套状态，自恢复只恢复了前者；而 `SoundGuardService.start` 刻意不做权限判定（BUG-A 的正确修复），于是失败也不会被发现。
- **修复**：新增桥方法 `isMicServiceRunning()`；拿不到通行证 ⇒ **不启动采音**，`guardError` 设为"后台麦克风通行证已失效：请打开应用重新开启守卫"，回投 `guardActive:false`；补审计 `guard · start · skipped`。
- **回归风险**：守卫从"看似自动恢复"变成"明确要求用户回前台重开"，是行为可见性变化，需产品确认文案。
- **注意**：这与 ARCH-01（`service.invoke('guard')` 消息无消费者）是**两个独立缺陷**，修好一个不等于修好另一个。

## 16. QUA-02 · 压测层 16/24 用例用 min-of-1 测量

```
Severity: P1        Evidence: CONFIRMED
位置: test/performance_v2_test.dart:46/62/74/118/129/140/208（7 处裸 Stopwatch）
      test/performance_test.dart:145/159/196/214/276/287/297/320/331（9 处）
      对照 test/perf_bench.dart:10-20(benchMs 的理由)/performance_v2_test.dart:26-31(文件头自述"已统一用 benchMs")
```

- **实际**：文件头声明"已统一用 `benchMs`/`benchMsAsync`（预热 + 取最小值）"，但 **16/24 条**仍用裸 `Stopwatch` 单次采样 ⇒ 单次样本被 JIT/GC/调度噪声支配 ⇒ WT-02 在 67% CPU 负载下采到 321ms（超预算 7%）判红，同轮重跑 24/24 通过。
- **根因**：`docs/12 §28`（BUG-053）的修复**只覆盖了 GT-07**，没覆盖 WT-01/02/03 与 GT-06 —— **文档与实现漂移**。
- **修复**：改用 `benchMs(...)`，阈值按"实测 JIT 基线 × 3"重定（BUG-053 的净效果就是"不再假红 + 收紧 2.5 倍"）。
- **不要做**：把 `PERF_RETRY` 当长期方案 —— 只是把噪声在脚本层消化，`PERF_RETRY=0` 时仍会红（`gates.sh:756`）。
