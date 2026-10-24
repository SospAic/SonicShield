# 09 · 根因分析（结构化 RCA）

> 覆盖 1 条 P0 + 7 条关键 P1。每条按：Symptom → Trigger → Proximate Cause → Root Cause →
> Contributing Factors → Impact → 复现实验 → 备选假设。

---

## RCA-1 · REM-01（P0）：撤销配对后对方仍能控制本机

### Symptom
用户在「我的设备」里删除某台控制器后，该设备**仍能**下发 `sound.play` / `task.upsert` / `call.invite` 等全部指令，并收到回执。

### Trigger
1. 攻击者曾与该端点配对过（或曾被用户在列表里删除过）⇒ 持有端点的 8 位配对码；
2. 攻击者自行实现 MQTT 客户端，或把官方客户端 `from` 改成 `''`；
3. 向 `sonicshield/v1/{端点ID}/cmd` 发布 `from: ""` 的命令；
4. 端点已启用远程遥控并在线。

### Proximate Cause（直接原因）
`decideRcAdmission`（`endpoint_service.dart:3696-3714`）第 3 条判据：

```dart
if (senderId.isEmpty) return RcAdmission.allowUnidentified;   // :3711
```

`from` 是**发送方自报**的字段（`protocol.dart:46` 注释即写「不参与鉴权」），
空串直接命中 `allowUnidentified` ⇒ 绕过 `rejectRevoked` 之后的全部判定。

### Root Cause（根本原因）
**「凭据」与「授权」被设计成同一个东西：能解密 = 已授权。**
而解密能力来自**共享的、不可按设备轮换的**配对码：

```
removePaired(A) → 只改 rc_paired 列表 + rc_revoked 记账
                → _ownCode 不变 ⇒ key(A→B) 不变
                ⇒ A 仍能解密，只是"自报身份"被拒
```

因此「撤销某个设备」在密码学上**无法表达**。`from` 是唯一的身份声明，却没有完整性保护
（虽在密文内，但任何持有配对码者都能写任意值）。

### Contributing Factors
- 代码注释（`:3687-3695`）**已诚实标注**这个缺口，说明它是"已知但未修"，不是疏忽。
- 根治需"按设备独立密钥"，而那会改变 HANDOVER §4.6 的**不可改决策**（按接收方身份派生 + 双方互扫）
  ⇒ 修复被架构决策卡住。
- `allowUnidentified` 的存在理由是为 `tool/rc_probe.dart` 探针服务 —— **以生产鉴权缺口换工具便利**。

### Impact
「解除配对」是**唯一**的授权回收手段，而它当前无效。家庭守护场景下（老人机被子女控制），
一旦控制端设备被转手/丢失/恶意安装，端点**无法单方面切断控制**，除非重置配对码——
而那会让**所有**控制器一起失联。命中 `docs/08 §2` 合规红线。

### 最小复现（未执行，需授权）
1. 设备 B 与控制器 A 正常配对，B 的「我的设备」出现 A；
2. 在 B 上删除 A；
3. A 侧把 `sendTo` 里的 `from: store.deviceId` 改为 `from: ''`（一行）；
4. A 发 `sound.play` → B 照常执行并回执。

**预期**：B 拒绝并写审计。**实际**：B 执行。

### 备选假设
| 假设 | 评估 |
|---|---|
| 「撤销后必须轮换配对码才生效」是有意设计 | 部分成立（`rotatePairingCode` 注释与 UI 二次确认都这么说）。但若如此，缺陷应改写为「删除设备的 UI 语义与真实效果不一致」，**仍至少 P1**；按合规红线仍判 P0——用户点「删除」时不会预期「它还能控制我」 |
| `from` 为空仅用于探针，是有意兼容 | 成立，但**不应以生产鉴权缺口为代价** |
| broker 的 topic ACL 可补偿 | 默认公共 broker **无 ACL**（`remote_store.dart:173`），自建 broker 才可能 |

### 修复（两步走）
1. **短期（不改密钥模型）**：删除 `allowUnidentified` 分支，`senderId` 为空一律 `rejectUnidentified`
   （`pair.request` 已在最前单独放行，不受影响）；`tool/rc_probe.dart` 改为填 `from`；
   UI 文案改为「删除并吊销（需重置配对码）」。
2. **根治**：配对时由端点生成**每控制端独立的 32 字节密钥**，随 `pair.request` ack 下发；
   `removePaired` 删密钥即真正吊销；身份由「用哪把密钥解开」决定，`from` 不再参与鉴权。

---

## RCA-2 · NAT-02（P1，R93 在飞）：振动归因方向相反

### Symptom
- 手机处于**正常响铃**模式时，每条振动审计都挂上「系统振动中…振动极可能被系统静默吞掉」（假告警，且文案自相矛盾）；
- 手机处于**静音**模式时，审计显示「正常」、不告警 —— 而此刻通知类振动**恰好真的会被吞**。

### Trigger
任意 Android 设备、任意振动动作。R93 改动合入后即生效。

### Proximate Cause
```dart
// vibrate_caps.dart:113
bool get notificationsMuted => ringerMode == 1 || ringerMode == 2 || dndActive;
// :116-121
String get ringerLabel => switch (ringerMode) {
      0 => '正常', 1 => '静音', 2 => '振动', _ => '读不到',
    };
```

### Root Cause
**凭印象写常量**。SDK 事实（`javap -constants android.jar android.media.AudioManager`）：
```
RINGER_MODE_SILENT  = 0
RINGER_MODE_VIBRATE = 1
RINGER_MODE_NORMAL  = 2
```
代码把 `0` 当正常、`2` 当振动 ⇒ **完全颠倒**。
且没有单测锁住映射（R93 的新测试 `r93_vibrate_dnd_test.dart` 若按错误映射断言，会一起错）。

### Contributing Factors
- 原生侧读值**是对的**（`NativeBridgePlugin.kt:712-717`），错误只发生在 Dart 展示/判据层 ⇒ 排查时容易被"原生没问题"误导。
- 类型检查无法发现（都是 `int` / `String`），`analyze` 全绿。

### Impact
R93 要修的正是"手机震动不好使"的归因链，现在**方向相反**：真实故障（静音）被漏报，正常状态被误报。
审计可信度受损，用户会看到自相矛盾的提示。

### 修复
```dart
bool get notificationsMuted => ringerMode == 0 || dndActive;   // 0 = SILENT
String get ringerLabel => switch (ringerMode) {
      0 => '静音', 1 => '振动', 2 => '正常', _ => '读不到',
    };
```
补参数化单测：`ringerMode ∈ {0,1,2,-1} × dndActive ∈ {false,true}`。

---

## RCA-3 · NAT-01（P1）：Android 14+ 单帧抓屏 100% 失败

### Symptom
远程"看一眼/拍一张"永远返回失败，且被记成「用户拒绝投屏授权」。

### Trigger
Android 14+（含主力机 Redmi K70 Pro / Android 16）；`screen.cast{once:true}`。**必现**。

### Proximate Cause
`ScreenCastService.kt:157` 直接 `mp.createVirtualDisplay(...)`，
而全仓 **0 处** `registerCallback` / `MediaProjection.Callback`（`grep -rn "registerCallback" android packages` 无结果）。

### Root Cause
**实现按 Android 13 及更早的 `MediaProjection` 契约编写**（无需 callback、可多次建 VD）。
升级 targetSdk 后未跟进 Android 14 的行为变更。

官方文档原文（`behavior-changes-14`，"User consent required for each MediaProjection capture session"）：
> "If your app doesn't register this callback, `MediaProjection#createVirtualDisplay` throws an `IllegalStateException`."
> "Your app invokes `MediaProjection#createVirtualDisplay` multiple times on the same `MediaProjection` instance." → `SecurityException`

### Contributing Factors
- 次生问题：`projection` 被缓存在服务字段里供**多次**抓帧复用 ⇒ 即使补上 callback，第二次抓帧仍必失败。
- 失败被 `catch` 吞成 `finish(null)`（`:215-218`），异常类型丢失 ⇒ 上层只能判"抓帧失败"，
  而 `endpoint_service.dart:1467-1473` 又把 `false` 记成"用户拒绝授权" ⇒ **排障方向被误导**。

### 修复
1. `ACTION_START` 里 `projection.registerCallback(...)`，`onDestroy` 里 `unregisterCallback`；
2. 改为**长驻 VD + 抓帧只 `acquireLatestImage()`**（符合"一次 VD、多次读帧"的官方推荐），
   或每次抓帧重新走一次授权；
3. 失败时 `result.error("CAPTURE_FAILED", e.message, null)`，别只回 `null`。

---

## RCA-4 · SCH-01（P1）：长动作吞掉同批与后续所有到期计划

### Symptom
用户配了多条同一时刻的任务（或一条长录音 + 若干提醒）时，**部分任务永久不响**，
日志只有一条无 `message` 的 `skip-stale`。

### Trigger
1. 同一 15s 窗口内 ≥2 条到期计划，其中前一条动作时长 > 10 分钟（录音取证 UI 允许 1–1800s）；
2. 或一条 > 10 分钟的播放/声景（远程 1h、导入 JSON 24h）。

### Proximate Cause
```dart
// background_engine.dart:1493
final due = await occs.due(now, limit: SchedulerConfig.catchUpLimit);  // = 3
// :1501 串行 for
// :1507-1508  逐条取实时 now 做陈旧判定
final tickNow = DateTime.now();
if (tickNow.difference(o.fireAt) > const Duration(minutes: 10)) {
  await occs.markStatus(o.id, OccurrenceStatus.skipped);   // 永不执行
```

### Root Cause
**把"执行"与"排队"耦合在同一个串行槽里，且用绝对墙钟差值当唯一丢弃判据。**
`catchUpLimit=3` 与 15s tick 的组合**从未按"最长动作时长"校验过**（3 × 1800s ≫ 10min）。

`catchUpLimit=3` 的容量算术：
```
第 1 条耗时 T，第 2/3 条要等 T 之后才做陈旧判定
T > 10min  ⇒  第 2/3 条必然被判 stale ⇒ 永不执行
T = 1800s（录音上限）  ⇒  30 分钟内任何其他计划都不执行
T = 3600s（远程播放）  ⇒  1 小时内全部丢弃
T = 86400s（模型层允许）⇒  24 小时停摆
```

### Contributing Factors
- `executeDue` 的循环体是 `_engineBody` 的**闭包**，无法注入 `now` ⇒ **不可单测** ⇒ 该缺陷无法被回归锁住。
- 丢弃与"用户主动跳过"共用 `skipped` 状态 ⇒ 审计无法区分。
- BUG-094 曾把"批次开始时刻"改成"逐条实时时刻"（注释 `:1502-1506`），修好了一个问题（长动作后补响陈旧计划），但**引入了这个**。

### 修复
1. **判定与执行解耦**：批次开始时刻快照判定，批次内排队时间不计入迟到；
2. 对 `runAction` 加**执行预算** `timeout(min(声明时长+30s, 10min))`，超时落 `failed('执行超时')` 并记录；
3. 长动作（录音/长播放）改为**不占执行槽**（`unawaited` + 独立状态，需配合 SCH-04 的 `running` 态）。

---

## RCA-5 · SCH-02（P1）：远程改任务删掉已到期未执行的计划

### Symptom
控制端下发 `task.upsert`（哪怕只改名字）或 `task.toggle` 后，
**正当时的提醒/取证永久消失**：既不执行，也不留 `skipped` 审计行。

### Trigger
1. 任务 T 的 occurrence 在 10:00:00 到期；
2. 引擎 tick 是 15s 节奏，10:00:07 它还没被取走（`pending`）；
3. 10:00:08 控制端下发 `task.upsert` 或 `task.toggle`；
4. `deletePendingForTask` 删掉该行；`_rematerialize` 因 `t.at <= now` 不再生成；
5. 10:00:15 的 tick `due()` 查不到它。

### Proximate Cause
```dart
// occurrence_repository.dart:229-233 —— where 只有 task_id + status，无 fire_at 过滤
Future<int> deletePendingForTask(String taskId) => _db.db.delete(
      'occurrences',
      where: "task_id = ? AND status = 'pending'",
      whereArgs: [taskId],
    );
```
对照引擎侧 `reconcile` 的 where（`:56`）：`task_id = ? AND status='pending' AND fire_at > ?`

### Root Cause
**把"清理旧计划"实现成"清空 pending"**，依赖"物化会重新生成"这一前提；
但物化刻意不回填过去时刻（`schedule_engine.dart:368` `!t.isBefore(now)`，这是**正确**的），
于是删除即丢失。远程路径**没有复用引擎的 `reconcile` 语义**。

### Contributing Factors
`reconcile` 的注释（`:33-34`）明写"保留 `fire_at <= now` 的 pending：它们已到期、正由 `executeDue` 补执行，删掉会漏触发" ——
**同一仓库两套语义不能都成立**。这违反项目自述的"三个入口同一条通路"（`counter_plan_service.dart:9-13`）。

### 修复
`deletePendingForTask` 增加 `fire_at > ?` 参数，或直接暴露 `reconcile([taskId], entries, now)` 给远程调用；
两条远程路径合并成一个 `applyTaskChange()`，杜绝再次分叉。

---

## RCA-6 · DAT-01（P1）：免打扰语义迁移未回填

见 `07-data-consistency-audit.md` §2.1（完整证据链与现场佐证）。

**Root Cause 一句话**：**语义迁移（bool → 三态）缺少数据回填，且迁移注释只覆盖了主开关默认值的情形。**

**修复**：v6 迁移按升级前语义回填（`oldV<79` ⇒ 统一改写为 `2` 强制不豁免，或按主开关快照），
并写一条 `exec_logs` 审计说明"夜间豁免语义已变更"。

---

## RCA-7 · DAT-05（P1）：远程改任务后长期不响

### Symptom
远程改完任务，回执"失败"，然后该任务**长期不响**（最长 36h）。

### Proximate Cause
```dart
// endpoint_service.dart:1946-1948  三段写，无事务
await tasks.upsert(task);
final dropped = await occ.deletePendingForTask(task.id);
final planned = await _rematerialize(task, occ);   // 抛错即留下"无计划"任务
```

### Root Cause
跨仓储多步写无事务 **+ 续算判据是全局聚合**：
```dart
// background_engine.dart:2313-2321
latestPendingFireAt  →  MAX(fire_at) 全表聚合
planNeedsExtend(coverEnd, now, 12h)   // 只要其它任务覆盖充足就 false
```
反击计划动辄数百条，把全局覆盖维持在 48h ⇒ `planNeedsExtend` 恒 false
⇒ **该任务永远不会被重新物化**，直到全局覆盖掉到阈值内（稳态约 36h 一次）。

### 修复
1. 把"删旧计划 + 写新计划"合并为 `OccurrenceRepository.replacePendingForTask(taskId, entries, now)`（单事务）；
2. 续算判据补一条"存在 enabled 且非 sound 的任务在未来 12h 内零 pending ⇒ 需要 replan"
   （可复用 `nextPendingByTask`），并限制为每 N 轮执行一次。

---

## RCA-8 · QUA-02（P1）：压测层 16/24 用例用 min-of-1 测量

见 `08-test-results.md` §3（完整证据）。

**Root Cause**：`docs/12 §28`（BUG-053）的修复**只覆盖了 GT-07**，没覆盖 WT-01/02/03 与 GT-06。
文件头写了"已统一用 `benchMs`"，但实现没跟上 —— **文档与实现漂移**。

**修复**：把 WT-01/02/03、GT-06 改成 `benchMs(...)`，阈值按"实测 JIT 基线 × 3"重定。
这是唯一能**同时消除假红与收紧阈值**的改法（BUG-053 的净效果就是"不再假红 + 收紧 2.5 倍"）。

---

## 贯穿性根因（比单条更重要）

| # | 根因 | 投影到哪些缺陷 |
|---|---|---|
| **A** | **同一业务状态被拆成两份存储，代码只维护一份** | NAT-03（守卫 prefs vs FGS 存活）、REM-01（配对列表 vs 共享密钥）、ARCH-02（闹钟 vs KEY_ALARMS）、DAT-05（单任务 pending vs 全局 MAX）、DAT-01（旧 bool 语义 vs 新三态） |
| **B** | **检查与执行之间没有原子性** | DAT-03（非 CAS）、SCH-03（非任务级互斥）、DAT-04/05（无共享事务）、SCH-08（冷却基准后置） |
| **C** | **丢弃动作没有独立状态，全借用 `skipped`** | SCH-01、SCH-02、SCH-04、ARCH-06、ARCH-07 |
| **D** | **超载文件导致状态不可注入 ⇒ 关键路径不可单测** | SCH-01、SCH-03、DAT-03 全都无法被回归锁住 |
