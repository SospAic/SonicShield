# A2 工作包：调度引擎 / 异步并发 / 状态机 深度审计

- 项目：SonicShield 1.9.9+32（Flutter/Dart，Android FGS 常驻引擎）
- 审计方式：**AUDIT_ONLY**（只读）。未修改 `lib/`、`test/`、`android/`、`packages/` 任何文件；未运行 dart/flutter（沙箱无工具链）。本文件是本次唯一写入。
- ⚠️ 工作区在审计开始前**已存在**未提交改动（R93 振动 DND 相关：`action.dart`/`vibrate_caps.dart`/`counter_plan_materializer.dart`/`task_editor_screen.dart`/`vibrate_session.dart`/`NativeBridgePlugin.kt` 及两个测试）。本文所有行号均以**当前工作区**为准；`git status` 可见的这些改动非本次审计产生。
- 审计对象与行数：
  - `lib/domain/scheduling/schedule_engine.dart`（421）
  - `lib/domain/scheduling/run_pause.dart`（167）、`counter_plan_materializer.dart`（291）、`vibrate_resolve.dart`（482，仅作交叉核对）
  - `lib/services/background_engine.dart`（2388）
  - `lib/services/reactive_counter_service.dart`（465）
  - `lib/services/background_service_manager.dart`（448）
  - `lib/services/vibrate_session.dart`（528，交叉核对）
  - `lib/services/sound_guard_service.dart`（261，交叉核对）
  - `lib/services/playback_service.dart`（交叉核对 stop/dispose 语义）
  - `lib/data/repositories/occurrence_repository.dart`（277）
  - `lib/data/repositories/task_repository.dart`、`lib/data/db/app_database.dart`（schema）
  - `lib/remote/endpoint_service.dart`（只读其中 `_rematerialize` / `task.upsert` / `task.toggle` / `runNow` 相关段）
  - `lib/domain/models/task.dart`、`action.dart`、`trigger.dart`
  - `packages/native_bridge/.../AlarmWatchdogReceiver.kt`、`flutter_background_service_android-6.3.1/BackgroundService.java`（确认"是否可能有两个引擎 isolate"）
- 不重复的历史结论：R92（夜间不生成）、R91（runNow 暂停门 / runGuardPlan 三态 / stopping 闸门 / 停机竞态）、A2-P0-2（executeDue 重入）、BUG-086/087/089/092/093/094/095/096。凡与这些重叠处，本文只写**新增维度**（跨 isolate、原子性、语义污染、容量）。

---

## 1. 三张状态机

### 1.1 任务状态（Task）

Task **没有** `paused` 态（全仓 `grep paused` 只命中全局总开关 `RunPause`，见 `run_pause.dart:131`）。任务只有二值 `enabled`（`task.dart:30`），外加两个正交闸门：

| 闸门 | 真源 | 求值时机 | 是否持久化为"状态" |
|---|---|---|---|
| `enabled` | `tasks.enabled`（`task.dart:115`） | 物化期（`schedule_engine.dart:105`）+ 执行期（`background_engine.dart:1519`） | 是 |
| 全局暂停 `runMasterMode` | prefs（`background_engine.dart:944-953`） | **仅执行期**（`1508/1525`、`968`） | 否（派生） |
| 免打扰 `quietPolicy` | 任务字段（`task.dart:42`） | **仅物化期**（`schedule_engine.dart:126`） | 落库到 `occurrences.quiet_exempt`（仅"是否豁免"） |

转换点（写 `enabled` 的全部位置）：

| 转换 | 位置 | 备注 |
|---|---|---|
| 任意 → `enabled=1/0`（本机） | `task_list_screen.dart:93/127/198/244` → `replan` | 走引擎 `reconcile`（只删未来 pending） |
| 任意 → `enabled=1/0`（远程） | `endpoint_service.dart:1242` `tasks.setEnabled` + `1243 deletePendingForTask` | **另一条语义**：删全部 pending（见 SCH-02） |
| 新建 → `enabled=1`（反击计划物化） | `counter_plan_materializer.dart:245`、`counter_plan_service.dart:97` | `upsertMany` 不触发 DELETE，历史保留 |
| 任意 → **删除**（反击计划下线） | `counter_plan_service.dart:113` → `task_repository.deleteCounterTasks` | 级联删 occurrences（含审计行） |
| 任意 → **删除**（用户/远程） | `task_list_screen.dart:123/241/785`、`endpoint_service.dart:1993` | 级联 |

判定：**没有非法跳转**（只有布尔位）。但存在"状态未参与判定"的缺陷：`priority` 在执行期完全未使用（SCH-13）；远程与本机对"停用"采用了两种不同的副作用（SCH-02）。

### 1.2 occurrence 状态机

`enum OccurrenceStatus { pending, done, skipped, failed }`（`task.dart:183`）——**没有 `running` / `claimed` / `aborted`**。这是本工作包多个缺陷的结构性根因。

全部写入点（文件:行号）：

| # | 转换 | 位置 | 语义 |
|---|---|---|---|
| 1 | ∅ → `pending` | `occurrence_repository.dart:80`（`reconcile` insert-ignore）、`:16`（`commitAll` insert-ignore） | 物化 |
| 2 | ∅ → `skipped` | `background_engine.dart:2174`（runNow 被裁决拒绝）、`:1654-1658`（runGuardPlan 终态） | 直接落终态 |
| 3 | ∅ → `done/failed` | `background_engine.dart:2191-2195`（runNow 终态） | 直接落终态 |
| 4 | `pending` → `skipped`（陈旧） | `background_engine.dart:1509` | >10min 迟到 |
| 5 | `pending` → `skipped`（任务没了/停用） | `background_engine.dart:1520` | |
| 6 | `pending` → `skipped`（全局暂停） | `background_engine.dart:1526` | |
| 7 | `pending` → `skipped`（条件不满足） | `background_engine.dart:1539` | |
| 8 | `pending` → `skipped`（概率未命中） | `background_engine.dart:1552` | |
| 9 | `pending` → **`failed`（占用标记）** | `background_engine.dart:1571` | **不是失败**，是"已被取走" |
| 10 | `failed`（占用）→ `done/skipped/failed`（终态） | `background_engine.dart:1588` | 覆盖 9 |
| 11 | `pending` → `skipped`（用户"跳过下一次"） | `occurrence_repository.dart:246` ← `task_list_screen.dart:685`、`endpoint_service.dart:1280` | |
| 12 | `pending` → **删除** | `occurrence_repository.dart:54-58`（`reconcile`，`fire_at > now`） | |
| 13 | `pending` → **删除** | `occurrence_repository.dart:229-233`（`deletePendingForTask`，**无时间过滤**） | 远程专用 |
| 14 | `pending` → **删除** | `occurrence_repository.dart:266-276`（`deletePendingQuietExempt`） | |
| 15 | `skipped` → **删除** | `occurrence_repository.dart:76`（不在本轮投影内） | |
| 16 | 任意 → **删除** | `occurrence_repository.dart:215-219`（`purgeOlderThan`，非 pending 且 >7 天）、`:222`（任务级联） | |
| 17 | `done/failed/skipped` → `pending`（**复活**） | 无直接写入；但 `reconcile`/`commitAll` 用 `insert ignore`，若行被 12/13/14 删除后同 id 重插 → 事实上的"复活" | |

非法/危险跳转（逐条判定）：

| 判定 | 证据 | 结论 |
|---|---|---|
| `failed` 被当作"占用" | `1571` | **语义污染**：占用与真失败不可区分；崩溃后永久 `failed`（SCH-04） |
| `skipped`（用户意图）→ `done` | 执行期 `1571→1588` 覆盖 11 | **用户意图被覆盖**（SCH-04） |
| `done` 之后不会被重执行 | `insert ignore` + `due()` 只筛 pending（`occurrence_repository.dart:91`） | 正常 |
| 失败被成功覆盖 | `1584-1588` 严格按 `outcome` 三态 | 已由 BUG-093/R90-04 修正，**未发现新问题** |
| 无法退出的状态 | 无（每个非 pending 态都可被 purge/级联删除） | 正常 |
| 并发回退 | `markStatus` 无 `WHERE status='pending'`（`:171-182`） | 存在（SCH-04/05） |

### 1.3 引擎状态机

引擎**没有显式枚举**，状态由 5 个布尔/标志拼出：`stopping`（`background_engine.dart:479`）、`executing`（`:458`）、`replanning`（`:465`）、`replanQueued`（`:509`）、`_engineBootstrapDone`（`:259`，**顶层库变量**），外加回投用的 `running` 参数（`broadcast({bool running = true})` `:1147`）。

| 转换 | 位置 | 触发 |
|---|---|---|
| ∅ → `starting` | `:205 engineEntryPoint` → `:261 _engineBody` | 原生 `runService()` |
| `starting` → `starting`（失败收口） | `:233-243`（`invoke running:false` + `stopSelf`） | bootstrap 期未捕获异常 |
| `starting` → `running` | `:2346-2361`（首轮 executeDue/extend/replan/broadcast）→ `:2364 _engineBootstrapDone=true` | 启动完成 |
| `running` → `stopping` | `:2002`（`service.on('stop')` 第一条语句，同步置位） | UI/远程 stop |
| `stopping` → `stopping`（**重复进入**） | `:2000` 监听器**无幂等闸门**（没有 `if (stopping) return`） | 重复 stop 指令 |
| `stopping` → `dead` | `:2084 stopSelf()`（隐式，无状态写入） | 清理链结束 |
| `dead` → `starting` | 原生侧 `isRunning=false`（`BackgroundService.java:113 onDestroy`）后才能再启动 | 用户再次开启 |
| `running` → `running`（**回投覆盖**） | `:1602 / 1662 / 1743 / 2220 / 2285 / 1917 / 1982 / 1998` 全部 `broadcast()` 默认 `running:true` | 任一 handler |

判定：

- **`stopping` 是单向的、永不复位**（`:2002` 唯一写入，全仓无 `stopping = false`）。若 `stopSelf()` 失败（`:2085-2088` 只记日志、无重试），引擎进入"僵尸"态：FGS 通知仍在、15s Timer 仍在跑（`:2291` 只 `return`）、所有工作被跳过、UI 显示已停、原生 `isRunning` 仍为 true ⇒ 用户无法再启动（SCH-15）。
- **`running:true` 可覆盖 `running:false`**：除 `executeDue`/`replan`/`pushExactAlarms` 外，`broadcast()` 的调用点都不检查 `stopping`（见 §2 矩阵）。停机清理链有多段 `await`（`:2014-2068`），窗口内的 `runNow`/`onSoundEvent`/`vibrateStep`/`powerMode`/`reactive`/`guard` 都可能把 `running:true` 再发一次。实际影响受 `stopSelf()` 销毁 isolate 抑制（迟到回投多半发不出去），故列为 SUSPECTED（SCH-07 的附带项）。
- **`_engineBootstrapDone` 是顶层变量**（`:259`）：若同一 isolate 内 `_engineBody` 被再次调用（插件 `onStart` 重入），第二次不会重置它，同时会**再注册一套 `service.on(...)` 与第二个 `Timer.periodic`** ⇒ 双 tick。原生侧 `runService()` 有 `isRunning` 早退（`BackgroundService.java:192-195`），正常情况下不会二次 `onStart`；但 `onStartCommand` 每次都会调 `runService()`（`:181-187`），一旦 `isRunning` 被 `onDestroy` 置 false 而 FlutterEngine 未销毁，就存在双注册窗口。列为 SUSPECTED（未在真机取证）。

---

## 2. 并发 / 时序风险矩阵

图例：`✔` 有；`✘` 无；`~` 部分/有条件。

| # | 路径 | 互斥锁 | 单事务 | 执行前复检 paused/条件/概率 | 循环内复检 `stopping` | 复检 `enabled` | 运行期冷却 | 可被中断 | 备注 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | tick → `executeDue`（`:1473`） | ✔ `executing`（isolate 内） | ✘（逐条 2~3 次 update） | ✔ `:1497/1537/1550` | ✘ | ✔ `:1519` | ✘（冷却只在物化期） | ~ 播放可（`playback_service.dart:271-280` 代次），录音/TTS **不可** | 单槽串行、`catchUpLimit=3` |
| 2 | tick → `extendCounterPlan` → `replan`（`:2306`） | ✔ `replanning` | ✔ `reconcile` 内 `transaction`（`:51`） | n/a | ✔ `:1244` | ~ 用 `enabledOnly:true` 的列表 | n/a | ✘ | 每 15s 都跑 |
| 3 | `service.on('replan')`（`:1904`） | ✔ 同上 + `replanQueued` 补跑 | ✔ | n/a | ✔ | ~ | n/a | ✘ | |
| 4 | `service.on('runNow')`（`:2121`） | **✘ 与 1/5 不互斥** | ✘（`commitAll` 单语句） | ✔ `admitExecution`（`:2163`） | **✘** | **✘**（不检查 `task.enabled`） | ✘ | ✘ | SCH-03 |
| 5 | `onSoundEvent` → `runGuardPlan`（`:1670/1620`） | **✘** | ✘ | ✔（`admitExecution`，`:1689`） | **✘** | ✔（`enabledOnly`） | ~ 用 `lastDoneFor`，**执行后才落库** | ✘ | SCH-03/08 |
| 6 | `vibrateStep`（`:2232`） | ✘ | ✘ | ✘（远程指令组，按设计） | ✘ | n/a | n/a | ✔（`vibrate.stopAll`） | |
| 7 | `guard` 开/关（`:1919`） | ✘ | n/a | n/a | ✘ | n/a | n/a | ✘（在飞 `runGuardPlan` 继续） | SCH-07/09 |
| 8 | `stop`（`:2000`） | ~ `stopping` 单向 | n/a | n/a | n/a | n/a | n/a | ✘（在飞动作不取消） | SCH-07/15 |
| 9 | 主 isolate `_rematerialize`（`endpoint_service.dart:2130`） | **✘ 跨 isolate** | **✘**（delete 与 insert 分离，`:1947-1948`） | n/a | n/a | ✔ `:2131` | n/a | n/a | SCH-05 |
| 10 | 主 isolate `skipNextForTask`（`:237`） | ✘ 跨 isolate | ✘（先 select 再 update） | n/a | n/a | ✘ | n/a | n/a | SCH-04 |

补充事实（影响矩阵解读）：

- **"两个引擎 isolate"不成立**：`BackgroundService.runService()` 在 `isRunning` 为真时直接返回（`BackgroundService.java:192-195`），`onDestroy` 才复位（`:113`）。所以"跨 isolate 双执行"的真实对手是**主 isolate 的 endpoint/UI 写路径**，不是第二个引擎。历史注释（`:446-457`）里"原生闹钟唤醒的第二份服务"在当前插件版本下不会产生第二份 Dart 引擎——该注释已过期，但不构成本次缺陷（仅误导维护者）。
- **同 isolate 内 `executeDue` 与 `runNow`/`runGuardPlan` 真并发**：Dart 单线程但 `await` 处会让出，`runAction` 内部有大量 `await`（DB/平台通道/播放），因此二者可交错。
- **`PlaybackService.play()` 每次新建 `AudioPlayer`**（`playback_service.dart:163`，R90-07 有意为之）⇒ 两次并发执行 = **两路声音同时出声**，不是互相踩踏后只剩一路。这放大了 SCH-03 的用户可见后果。

---

## 3. 缺陷条目

> 证据状态取值：`CONFIRMED`（代码路径可直接读出，无需运行时）/ `HIGH_CONFIDENCE`（结构确定，运行期概率依赖时序）/ `SUSPECTED`（有线索但未取证）/ `NOT_REPRODUCED` / `UNVERIFIED`。

### SCH-01 单执行槽 + 10 分钟陈旧阈值 + `catchUpLimit=3`：一个长动作会静默丢弃同批与后续所有到期计划

Severity: **P1**
Evidence Status: **CONFIRMED**（容量算术与判定代码均为直接可读事实；具体丢多少依赖任务时长分布）

Affected Files/Lines:
- `lib/core/constants.dart:92`（`engineTick = 15s`）、`:98`（`catchUpLimit = 3`）、`:86`（`planHorizon = 48h`）
- `lib/services/background_engine.dart:1478-1487`（`executing` 闸门：整批期间拒绝一切新 tick）、`:1493`（`occs.due(now, limit: 3)`）、`:1501`（串行 for）、`:1507-1508`（逐条实时陈旧判定，>10min → skipped）、`:1572`（`await runAction`）
- `lib/domain/models/action.dart:299`（录音 `seconds` 上限 **1800**）、`:125`（`_maxActionDurationSec = 86400`，即 play/soundscape 模型层允许 24h）
- `lib/remote/task_wire.dart:38`（远程 `maxDurationSec = 3600`）
- `lib/features/tasks/task_editor_screen.dart:1725`（本机 UI 播放时长 clamp 到 120s）
- `lib/services/playback_service.dart:271-280`（播放窗口按 50ms 轮询，最长可等 `maxDurationMs`）

Expected Behavior：一批到期计划应按"到期时刻"尽快执行；因资源竞争无法执行时应**显式记账**（为什么没执行、丢了几条），而不是把它们标成 `skipped` 后静默消失。

Actual Behavior：`executeDue` 整批只持一个执行槽且**串行**。第 1 条若耗时 T，第 2、3 条要等 T 之后才做陈旧判定；当 T > 10min 时它们**必然**被判 stale → `markStatus(skipped)`（`:1509`），**永不执行**。期间所有 tick 被 `executing` 拒绝（`:1478`），新的到期条目继续堆积，等下一批时同样超时。于是：

- 一条 `RecordEvidenceAction(seconds: 1800)` ⇒ 30 分钟内**任何**其他计划都不会执行；
- 远程允许的 3600s 播放 ⇒ 1 小时内全部丢弃；
- 模型层允许的 86400s（经导入/DB 构造）⇒ 24 小时停摆。

且丢的那条只留一条 `skip-stale` 日志（`:1510-1515`，`message` 为空），用户在"执行日志"里看不到"因为前一条太长"。

Trigger Conditions：
1. 同一 15s 窗口内有 ≥2 条到期计划，其中前一条动作时长 > 10 分钟（录音取证最常见，UI 允许 1–1800s）；
2. 或一条 > 10 分钟的播放/声景（远程 1h、导入 JSON 24h）。

Forward Call Chain：`Timer.periodic(15s)`（`:2291`）→ `stepGuarded('executeDue(tick)', executeDue)`（`:2294`）→ `occs.due(limit:3)`（`:1493`）→ `runAction`（`:1572`）→ `recordAndLog`（`:855`）→ `Future.delayed(seconds)`（`:877`）→ 返回后第 2 条 `tickNow.difference(o.fireAt) > 10min`（`:1508`）→ `markStatus(skipped)`（`:1509`）。

Reverse Call Chain：`engineTick` 常量 ← `SchedulerConfig` ← `constants.dart:92`；`catchUpLimit` ← `constants.dart:98`；`RecordEvidenceAction.seconds` ← `action.dart:299` ← `runSingle` 的 `RecordEvidenceAction` 分支（`:1078-1079`）。

Data Flow / State Transition：`pending`（多条）→ 第 1 条 `failed`(claim,`:1571`) → `done`(`:1588`)；第 2/3 条 `pending` → `skipped`(`:1509`)。**没有任何字段记录"因排队超时而丢弃"与"用户跳过"的区别**。

Evidence:
```dart
// background_engine.dart:1478-1493
if (executing) { print('…重入被拒…'); return; }
executing = true;
try {
  await syncPrefs();
  final now = DateTime.now();
  final due = await occs.due(now, limit: SchedulerConfig.catchUpLimit); // = 3

// :1507-1517
final tickNow = DateTime.now();
if (tickNow.difference(o.fireAt) > const Duration(minutes: 10)) {
  await occs.markStatus(o.id, OccurrenceStatus.skipped);
  await logs.append(source: 'schedule', action: 'skip-stale', status: 'skipped', ...);
  continue;
}
```

Reproduction Steps（不改测试文件，仅给出用例）：
```dart
// test/ 建议新增（FFI 内存库，与 test/db_repository_test.dart 同装配）
test('SCH-01 单槽串行：长动作后同批剩余条目被 stale 丢弃', () async {
  final now = DateTime(2026, 1, 1, 10, 0);
  // 3 条同一分钟到期
  await occ.commitAll([
    for (var i = 0; i < 3; i++)
      PlannedOccurrence(
        id: 't$i@${now.millisecondsSinceEpoch}', taskId: 't$i',
        fireAt: now, status: OccurrenceStatus.pending),
  ]);
  final batch = await occ.due(now, limit: 3);
  expect(batch.length, 3);
  // 复刻 :1501-1517：每条在"轮到它时"才取实时 now 做陈旧判定
  var clock = now;
  var executed = 0, staled = 0;
  for (final o in batch) {
    if (clock.difference(o.fireAt) > const Duration(minutes: 10)) {
      await occ.markStatus(o.id, OccurrenceStatus.skipped); staled++;
    } else {
      await occ.markStatus(o.id, OccurrenceStatus.done); executed++;
      clock = clock.add(const Duration(minutes: 11)); // 第 1 条是 11 分钟的长录音
    }
  }
  expect(executed, 1);   // 只有第 1 条真正执行
  expect(staled, 2);     // 现状：后两条因**排队**被判 stale，永远不执行
  // 期望：后两条仍应执行（批次内排队不计入迟到），或至少落一个可区分的
  //      "因排队丢弃"原因，而不是与"用户跳过"共用 skipped
});
```
（严格复刻需把 `executeDue` 的循环体抽成可注入 `now` 的纯函数；当前它是 `_engineBody` 内的闭包，**不可单测**，本身也是本缺陷难以被回归锁住的原因。）

Root Cause：把"执行"与"排队"耦合在同一个串行槽里，且用**绝对墙钟差值**当唯一的丢弃判据；`catchUpLimit=3` 与 15s tick 的组合从未按"最长动作时长"校验过（3 × 1800s ≫ 10min）。

Alternative Hypotheses：
- 可能有人认为"迟到 10 分钟就不该再响"是产品意图。但该意图无法解释"同一批里第 2 条本来只迟到 11 分钟、而它前面那条是用户自己设的 30 分钟录音"——丢弃原因是**排队**，不是"错过"。
- 也可能是刻意的"防补跑风暴"。但防风暴的正确手段是限流 + 记账，不是把队列里的条目判死。

Business Impact：用户配了多条同一时刻的任务（或一条长录音 + 若干提醒）时，**部分任务永久不响**，日志只有一条无 message 的 `skip-stale`；"取证录音 30 分钟"这种最需要可靠性的场景反而最容易吞掉其他任务。属于"承诺了却不做到且不告知"。

Recommended Fix（最小改动、可分两步）：
1. **判定与执行解耦**：`due()` 取回后先对整批做一次"到期时刻快照判定"，把 `fire_at` 与**本轮开始时刻**比较（而不是逐条实时 `now`），即恢复 BUG-094 之前的语义但改为"批次开始时刻"——批次内的排队时间不计入迟到。真正的"跨批次迟到"仍按 10min 丢。
2. 对 `runAction` 加**执行预算**：`runAction(...).timeout(actionBudget)`，预算取 `min(动作声明时长 + 30s, 10min)`；超时按 `failed('执行超时')` 落终态并**记录**。这样单条永远不会独占槽位超过预算。
3. 长动作（录音/长播放）改为**不占执行槽**：`unawaited` 分派 + 独立状态（需要新增 `running` 态，见 SCH-04），或至少把 `catchUpLimit` 与预算联动（`catchUpLimit = ceil(budget / tick)`）。

Regression Risks：`REENT-01..04` 是**源码契约锁**（`test/engine_reentrancy_test.dart:55-86`），会检查 `executeDue` 首部形状与"`runAction` 之前先乐观置状态"。改动必须保持该形状，否则 4 条锁判红。`BUG-094` 的"逐条实时时刻"注释（`:1502-1506`）会被推翻，需同步改注释与相关文档，否则 `DOC` 类锁（`test/doc_gate_consistency_test.dart`）可能报漂移。

Verification Tests：
- 上例（批次内不因排队判 stale）；
- 单条 `recordAndLog(seconds:1800)` 注入假 `runAction` 后，断言总占用 ≤ 预算且其余条目落 `done` 而非 `skipped`；
- 断言 `skip-stale` 的 `message` 非空且包含"排队/预算"原因。

Remaining Uncertainty：真机上 3 条同刻到期的实际频率未知；若用户几乎不配长录音，影响面小。但 `seconds` 默认 60、UI 上限 1800，风险是真实可达的。

---

### SCH-02 远程 `task.upsert` / `task.toggle` 用 `deletePendingForTask` 删除**全部** pending（含已到期未执行）⇒ 计划永久丢失

Severity: **P1**
Evidence Status: **CONFIRMED**

Affected Files/Lines:
- `lib/remote/endpoint_service.dart:1947`（`_upsertTask`：`await occ.deletePendingForTask(task.id)`）、`:1948`（`_rematerialize`）
- `lib/remote/endpoint_service.dart:1243`（`task.toggle`：同款）
- `lib/data/repositories/occurrence_repository.dart:229-233`（`deletePendingForTask` 的 where 只有 `task_id` + `status='pending'`，**无 `fire_at` 过滤**）
- `lib/remote/endpoint_service.dart:2148-2153`（`_rematerialize` 用 `ScheduleEngine.materialize(task, DateTime.now())`）
- `lib/domain/scheduling/schedule_engine.dart:367-368`（`_inRange`：`!t.isBefore(now)` ⇒ 已过去时刻**不会**再生）
- 对照：`lib/data/repositories/occurrence_repository.dart:46-58`（引擎侧 `reconcile` 只删 `fire_at > now`，并有长注释解释"保留已到期的 pending 否则漏触发"）

Expected Behavior：改任务定义时只应撤销"与新定义不符的**未来**计划"；已到期、正待补执行的条目必须保留（这正是 `reconcile` 的设计契约，`:33-34` 注释明写）。

Actual Behavior：远程两条路径都调用 `deletePendingForTask`，把**所有** pending 删掉，然后只物化 `>= now` 的条目。于是任何 `fire_at <= now` 且尚未被 `executeDue` 取走的 occurrence **被永久删除**：既不会执行，也不会留 `skipped` 审计行（只剩 `task.upsert` 日志里一个混合计数"清理 N 条旧计划"）。

同一件事本机与远程语义不同（本机走 `replan → reconcile`，远程走 `deletePendingForTask`），违反项目自述的"三个入口同一条通路"（`counter_plan_service.dart:9-13` 的同一原则）。

Trigger Conditions（最小）：
1. 任务 T 的 occurrence 在 10:00:00 到期；
2. 引擎 tick 是 15s 节奏，10:00:07 时它还没被取走（`pending`）；
3. 10:00:08 控制端下发 `task.upsert`（哪怕只改名字）或 `task.toggle`（关→开）；
4. `deletePendingForTask` 删掉该行；`_rematerialize` 因 `t.at <= now` 不再生成；
5. 10:00:15 的 tick `due()` 查不到它 ⇒ **该次任务永不执行**，也无 `skipped` 记录。

Forward Call Chain：`RcCmd.taskUpsert`（`:1172`）→ `_upsertTask`（`:1921`）→ `tasks.upsert`（`:1946`）→ `occ.deletePendingForTask`（`:1947`）→ `_rematerialize`（`:1948`）→ `ScheduleEngine.materialize`（`:2148`）→ `_inRange` 过滤掉过去时刻（`schedule_engine.dart:368`）。

Reverse Call Chain：`deletePendingForTask` 唯一调用方就是这两处远程路径（`grep` 结果：`endpoint_service.dart:1243,1947`）。

Data Flow / State Transition：`pending` → **行被删除**（不是 `skipped`/`failed`）。状态机里没有"被撤销"这个态，审计面因此无法表达"这次到期被远程更新吃掉了"。

Evidence:
```dart
// occurrence_repository.dart:229-233
Future<int> deletePendingForTask(String taskId) => _db.db.delete(
      'occurrences',
      where: "task_id = ? AND status = 'pending'",
      whereArgs: [taskId],
    );
// 对照 reconcile 的 where（:56）："task_id = ? AND status = 'pending' AND fire_at > ?"
```

Reproduction Steps：
```dart
test('SCH-02 远程 upsert 不得删除已到期的 pending', () async {
  final now = DateTime(2026, 1, 1, 10, 0);
  final past = now.subtract(const Duration(seconds: 5)); // 已到期、未被取走
  await occ.commitAll([
    PlannedOccurrence(id: 't1@${past.millisecondsSinceEpoch}', taskId: 't1',
        fireAt: past, status: OccurrenceStatus.pending),
  ]);
  // 复刻 _upsertTask 的两步
  await occ.deletePendingForTask('t1');
  final after = await occ.allForTask('t1');
  expect(after.where((o) => o.status == OccurrenceStatus.pending), isEmpty); // 现状：丢了
  // 期望：仍保留 1 条 pending（由下一次 due() 补执行或明确标 skipped）
});
```

Root Cause：把"清理旧计划"实现成"清空 pending"，依赖"物化会重新生成"这一前提；但物化刻意不回填过去时刻（正确），于是删除即丢失。远程路径没有复用引擎的 `reconcile` 语义。

Alternative Hypotheses：有人可能主张"远程改任务 = 旧计划全部作废，包括已到期未执行的"。但这与 `reconcile` 的注释（`:33-34`："保留 fire_at <= now 的 pending：它们已到期、正由 executeDue 补执行，删掉会漏触发"）直接冲突，同一仓库两套语义不能都成立。

Business Impact：远程控制是主场景之一（配对端批量下发）。一次改名/开关操作可能吞掉正当时的提醒/取证，且用户在日志里看不到"漏了一条"，只看到"清理 3 条旧计划"。

Recommended Fix：远程路径改为与引擎同源：
1. `deletePendingForTask` 增加 `fire_at > ?` 参数（默认 `now`），或直接暴露 `reconcile([taskId], entries, now)` 供远程调用；
2. `_rematerialize` 改为返回 `(planned, keptDue)` 并写进审计文本，让"保留了几条已到期"可见；
3. 两条路径（`task.upsert`/`task.toggle`）合并成一个 `applyTaskChange()` 帮助函数，杜绝再次分叉。

Regression Risks：`test/db_repository_test.dart` 里可能已有对 `deletePendingForTask` 全删语义的断言（需同步改）；`P1-16` 的"停用任务时清 pending"依赖该行为——停用场景应改为"把未来 pending 删掉、把已到期 pending 标 skipped"（更贴近语义）。`test/console_tasks_isolation_test.dart` 等远程用例需回归。

Verification Tests：
- 上述用例；
- `task.toggle(false)` 后断言：未来 pending 为 0、已到期 pending 变为 `skipped` 而非消失；
- 反向断言：`reconcile` 与远程路径对同一输入产生**相同**的最终行集（同源锁）。

Remaining Uncertainty：远程下发频率未知；若控制端只在用户操作时下发，命中窗口（0–15s）较小但确实存在（每 15s 一个窗口，且长动作期间窗口会拉长到分钟级）。

---

### SCH-03 `runNow` / 声音触发 / 守卫计划 与定时执行**不共用执行锁**，同一任务可并发跑两份

Severity: **P1**
Evidence Status: **CONFIRMED**（结构性；并发是否发生取决于用户/环境时序）

Affected Files/Lines:
- `lib/services/background_engine.dart:458`（`executing` 是 `_engineBody` 局部变量）、`:1478`（**只有** `executeDue` 检查它）
- `lib/services/background_engine.dart:2121-2181`（`runNow` 监听器：直接 `runAction`，**无** `executing`、**无** `stopping`）
- `lib/services/background_engine.dart:1670-1747`（`onSoundEvent` → `runGuardPlan`，无 `executing`）
- `lib/services/background_engine.dart:1620-1663`（`runGuardPlan` 逐任务 `runAction`）
- `lib/services/playback_service.dart:163`（每次 `play()` 新建 `AudioPlayer` ⇒ 两路同时出声）
- `lib/services/background_engine.dart:1518-1522`（`executeDue` 只检查 `task.enabled`，**不检查 `triggerType`**）——BUG-089 的残留面：已到期（`fire_at <= now`）的幽灵 pending 不会被 `reconcile` 删除（只删未来），仍会被执行

Expected Behavior：同一任务在任一时刻至多一个执行实例（用户按"立即执行"时若已在执行，应拒绝或排队并告知）。

Actual Behavior：三套执行入口各自为政。`executing` 只保护 `executeDue` 的**自身重入**，不是"任务级互斥"：
- `runNow` 与 `executeDue` 并发 → 同一任务两条 `runAction` → `PlaybackService` 各建播放器 → **双响**；`recordAndLog` 各建 `AudioRecorder` → 两个录音器（Android 上第二个通常抢不到麦克风，但会写一条 `failed`，把 `lastDoneFor` 语义搅乱）。
- 两次远程 `runNow`（不同 reqId）并发 → 同样双份。
- `onSoundEvent` 与 `executeDue`：同一任务若刚从"定时"改成"声音触发"，其**已到期** pending 仍在（`reconcile` 不删过去），`executeDue` 不看 `triggerType` ⇒ 与声音路径各跑一次。

Trigger Conditions：
1. 长动作执行中（如 60s 播放），用户点"立即执行"同一任务；
2. 或控制端并发下发两条 `task.runNow`；
3. 或把某任务从 `dailyAt` 改为 `soundTriggered`，且切换时存在 `fire_at <= now` 的 pending，随后发生一次声音事件。

Forward Call Chain：`service.on('runNow')`（`:2121`）→ `admitExecution`（`:2163`）→ `runAction`（`:2181`）→ `playAndLog`（`:711`）→ `playback.play`（`:723`）→ `AudioPlayer()`（`playback_service.dart:163`）。

Reverse Call Chain：`BackgroundServiceManager.runNow`（`background_service_manager.dart:336`）← `task_list_screen.dart:76`、`endpoint_service.dart:2061`、`remote_tasks_tab.dart:316`。

Data Flow / State Transition：两次执行各自 `commitAll` 一条 occurrence（id 用毫秒时间戳，`:2171/2187`），互不冲突 ⇒ 审计上看到"两条成功"，无法判定是重复。

Evidence:
```dart
// :2121
service.on('runNow').listen((m) async {
  ...
  final outcome = await runAction(task, vol, dur, 'remote');   // :2181 无任何锁
```
```dart
// :1478 —— 锁的作用域只到 executeDue 的 finally
if (executing) { ... return; }
executing = true;
```

Reproduction Steps：
```dart
// 引擎隔离不可实例化（见 test/engine_reentrancy_test.dart:20-23），故用源码契约锁 + 纯逻辑用例：
test('SCH-03 runNow 与 executeDue 必须共享任务级执行锁', () {
  final src = File('lib/services/background_engine.dart').readAsStringSync();
  final runNow = functionBlock(src, "service.on('runNow').listen((m) async {");
  expect(runNow, contains('executing'),   // 现状：不含 ⇒ 判红
      reason: 'runNow 必须与 executeDue 共用同一把执行锁（或任务级锁）');
});
```
行为级用例（需要先把 `runAction` 抽出可注入）：注入一个"记录并发度"的假 `runAction`，同时触发 `runNow` 与 `executeDue`，断言同一 `taskId` 的最大并发度为 1。

Root Cause：把"防重入"当成了"互斥"。`executing` 的语义是"executeDue 这一轮别重入"，而需求是"同一任务别并发"。二者粒度不同，注释（`:444-457`）也把前者写成了后者。

Alternative Hypotheses：`runNow` 可能被有意设计成"不受调度锁约束的紧急通道"（用户手动优先）。但代码里没有任何"抢占/取消在跑的那一份"的逻辑，结果不是"优先"而是"叠加"；且 `vibrateStep` 的注释（`:2223-2231`）明确要求"与定时任务走同一条执行路径"，说明设计意图是统一而非旁路。

Business Impact：双响（用户投诉"点了两次/响了两遍"）、双份取证录音（第二份通常失败但污染审计）、振动会话被同 id 接管（`vibrate_session.dart:273-291` 会记一条"被接管"）。

Recommended Fix：引入**任务级执行表**：`final _runningTasks = <String, String>{}`（taskId → occurrenceId）。所有入口统一 `tryClaim(taskId)`；`executeDue` 在 claim 成功后仍保留 `failed` 乐观标记（跨进程），`runNow`/`runGuardPlan` 在 claim 失败时返回 `busy` 并如实回执。`finally` 释放。

Regression Risks：`REENT-06` 断言守卫是 `_engineBody` 内局部状态（`test/engine_reentrancy_test.dart:95`）——新增表同样放在闭包内即可通过。`runNow` 的远程回执文案（`background_service_manager.dart:338` 的 `RunNowResult`）会新增 `busy` 原因，控制端需容忍新 message（协议是自由文本，风险低）。

Verification Tests：并发度断言；`runNow` 在 `executeDue` 执行中返回 `ok:false, message contains '正在执行'`；`vibrateStep` 与定时振动不互相接管。

Remaining Uncertainty：`runNow` 并发双响在真机上是否已被用户报告未知（本包无 issue 数据）。

---

### SCH-04 occurrence 无 `running` 态：用 `failed` 充当"已取走"标记 ⇒ 崩溃后永久 failed、用户"跳过下一次"打偏

Severity: **P1**
Evidence Status: **CONFIRMED**（状态语义与代码路径确定）；崩溃窗口的**概率**为 UNVERIFIED

Affected Files/Lines:
- `lib/domain/models/task.dart:183`（枚举只有 4 态）
- `lib/services/background_engine.dart:1562-1571`（注释明说"先标 `failed` 等价于已被取走"）
- `lib/services/background_engine.dart:1588`（终态覆盖）
- `lib/data/repositories/occurrence_repository.dart:171-182`（`markStatus` 无 `WHERE status=...`，**无 CAS**）
- `lib/data/repositories/occurrence_repository.dart:237-248`（`skipNextForTask` 只在 `status='pending'` 里找"下一次"）
- `lib/data/repositories/occurrence_repository.dart:202-212`（`lastDoneFor` 只认 `done`）
- `lib/services/retention_maintenance.dart:82`（非 pending 7 天后被清理）

Expected Behavior：执行中的 occurrence 应有独立状态（`running`），中断（进程被杀/崩溃/超时）应可识别并可重试或明确记 `aborted`；`failed` 只表示"动作执行失败"。

Actual Behavior：三个可观察的错误后果：

1. **崩溃 = 永久失败**：claim 写入 `failed` 后进程被杀（FGS 被系统回收、OOM、用户强杀），重启后该行仍是 `failed`，`due()` 不会再取（只筛 pending）⇒ **不重试、不补执行**，且与"播放失败"完全同形。`purgeOlderThan` 7 天后连痕迹一起删。
2. **"跳过下一次"打偏**：用户在执行中的那一秒点"跳过下一次"，`skipNextForTask` 查 `status='pending'`（`:240`），此时该行是 `failed`（占用），于是它跳过的是**再下一条**；同时 `executeDue` 随后把占用行覆盖成 `done` ⇒ 用户以为跳过了"这次"，实际这次照响、下次被吞。反向时序（先 skip 后 claim）则 `skipped` 被 `failed→done` 覆盖 ⇒ **用户意图被覆盖**。
3. **UI 语义污染**：任何执行中的任务在任务列表/统计里短暂显示为"失败"；`lastDoneFor` 只认 `done`，与 `failed` 混用使"成功/失败计数"无法区分"中断"。

Trigger Conditions：
1. 执行期进程被杀（长录音/长播放期间被系统回收，7×24 常驻场景下不罕见）；
2. 用户在任务到点的同一秒点"跳过下一次"（窗口 = `due()` 到 `markStatus(failed)` 之间的若干次 await：`tasksRepo.get` + 电量/通话/网络平台读 + 概率门，实测量级 5–50ms，但长动作批次里被拉长到秒级）；
3. 远程 `task.skipNext` 同窗口。

Forward Call Chain：`due()`（`:1493`）→ 逐条门禁（`:1507-1561`）→ `markStatus(failed)`（`:1571`）→ `runAction`（`:1572`，可 1800s）→ `markStatus(terminal)`（`:1588`）。

Reverse Call Chain：`skipNextForTask` ← `task_list_screen.dart:685`、`endpoint_service.dart:1280`。

Data Flow / State Transition：
```
pending --claim--> failed --terminal--> done|skipped|failed
   |                  ^ 崩溃点：永久停留，无出路
   +--用户 skip--> skipped --被 claim 覆盖--> failed --> done   （意图丢失）
```

Evidence:
```dart
// :1562-1571（注释即自证）
// 因此在执行**之前**先把它标成 `failed`（等价于"已被本次执行取走"）…
await occs.markStatus(o.id, OccurrenceStatus.failed);
```
```dart
// occurrence_repository.dart:171-182 —— 无状态条件，最后写入者胜
Future<void> markStatus(String id, OccurrenceStatus status, {...}) =>
    _db.db.update('occurrences', {'status': status.name, ...}, where: 'id = ?', whereArgs: [id]);
```

Reproduction Steps：
```dart
test('SCH-04 占用标记必须是独立状态，且 skipNext 不得跨过占用行', () async {
  final t = DateTime(2026, 1, 1, 10, 0);
  await occ.commitAll([
    PlannedOccurrence(id: 'a', taskId: 't1', fireAt: t, status: OccurrenceStatus.pending),
    PlannedOccurrence(id: 'b', taskId: 't1',
        fireAt: t.add(const Duration(days: 1)), status: OccurrenceStatus.pending),
  ]);
  await occ.markStatus('a', OccurrenceStatus.failed);  // 复刻 :1571 的占用
  final n = await occ.skipNextForTask('t1');
  expect(n, 1);
  expect((await occ.allForTask('t1')).firstWhere((o) => o.id == 'b').status,
      OccurrenceStatus.skipped);      // 现状：跳过了"下一条"，而不是正在跑的那条
  // 期望：skipNext 命中占用中的 'a'（把它标成 cancelRequested/skipped），'b' 不受影响
});
```
崩溃路径：在 `markStatus(failed)` 之后、`runAction` 返回之前杀进程（真机 `adb shell am force-stop`），重启引擎后断言 `allForTask` 里该行仍为 `failed` 且 `due()` 不再返回它。

Root Cause：状态枚举缺少"执行中/已中断"，于是"占用"只能借用某个终态；而借用 `failed` 同时污染了审计语义与用户操作语义。`markStatus` 无条件更新又让所有并发写入变成"最后写入者胜"。

Alternative Hypotheses：用 `failed` 作占用可能是为了"零迁移成本"（注释 `:1567-1570` 明说"不引入新状态值"）。这解释了动机，但不改变后果；且新增枚举值对 `values.byName` 是**向后兼容**的（老库不会出现新值），迁移成本被高估。

Business Impact：① 一次系统回收就永久吞掉一条任务且看起来像"失败"；② "跳过下一次"在边界时刻行为不可预期（跳过错的、或跳过后照响）；③ 统计口径失真（失败数虚高）。

Recommended Fix：
1. 新增 `OccurrenceStatus.running`（`values.byName` 兼容），claim 写 `running`；
2. `markStatus` 改为条件更新：`markStatus(id, to, {required Set<OccurrenceStatus> from})` → `WHERE id=? AND status IN (...)`，返回受影响行数，**0 行即视为"已被别人取走"**（这也是 SCH-05 的 CAS 基础）；
3. 启动时（`_engineBody` 的 retention 之后）把残留 `running` 统一改成 `failed` 并写一条 `action:'interrupted'` 审计，明确"上次中断"；
4. `skipNextForTask` 的候选集扩到 `pending|running`，命中 `running` 时置 `skipped` 并让执行侧在终态写入前复查（配合 2 的 CAS 即可自然实现）。

Regression Risks：`fromRow` 的 `values.byName` 对未知值会抛（`task.dart:221`）——降级版本读新库会崩。本项目只单向前进（无降级安装），可接受，但需在 `app_database` 版本注释中记录。UI 若对状态做穷举 switch，会编译期报红（好事）。`test/db_repository_test.dart` 里对状态字符串的断言需更新。

Verification Tests：上述用例；CAS 用例（两次 `markStatus(from:{pending})`，第二次返回 0）；启动自愈用例（预置 `running` 行 → 启动后变 `failed` 且有一条 `interrupted` 日志）。

Remaining Uncertainty：`OccurrenceStatus` 是否被远程协议序列化（`task_wire.dart`）——已查：occurrence 不走 wire，风险低。

---

### SCH-05 主 isolate 与引擎 isolate 并发写 occurrences，且 `_rematerialize` 的"删-插"不在事务里

Severity: **P2**
Evidence Status: **HIGH_CONFIDENCE**（缺原子性 = CONFIRMED；可观察的数据丢失 = SUSPECTED）

Affected Files/Lines:
- `lib/remote/endpoint_service.dart:1947-1948`、`:1243-1248`（delete 与 insert 是两条独立语句）
- `lib/remote/endpoint_service.dart:2154-2165`（`commitAll` 单独一次 batch）
- `lib/data/repositories/occurrence_repository.dart:51-84`（引擎侧 `reconcile` **在事务里**）
- `lib/services/background_engine.dart:1324-1335`（调用 reconcile）
- `lib/data/db/app_database.dart:150-162`（`occurrences` 只有 id 主键，无 (task_id, fire_at) 唯一约束）

Expected Behavior：对同一任务的计划重建应是原子的、与引擎的 `reconcile` 互斥（或至少可串行化）。

Actual Behavior：远程路径是"删（提交）→ 算 → 插（提交）"，中间存在可观测空窗；引擎 `replan` 的事务与此**无任何协调**（不同 isolate、不同连接）。交错结果：

- 远程 delete 提交后、insert 前，引擎 `reconcile` 跑完（删未来 + 插新）→ 远程 insert（`ignore`）追加一批按**旧快照**算出的条目 ⇒ 若 id 不同（定义版本/时刻不同）则**幽灵计划**并存；
- 引擎 reconcile 插完后，远程 delete 才落地 ⇒ 引擎刚生成的新 pending 被清空，远程再插入自己那批 ⇒ 多数情况下 id 相同自愈，但若 `now` 跨过某个触发点，两边算出的集合不同 ⇒ 丢一条或多一条；
- 两个连接同时写同一文件，还可能撞 `SQLITE_BUSY`（sqflite 每 isolate 一连接），表现为 `replan` 抛错被 `stepGuarded` 吞成一条审计。

Trigger Conditions：远程下发任务的同时引擎 tick 正在 `replan`（每 15s 一次 `extendCounterPlan` 都可能触发 `replan`；`planNeedsExtend` 为真时全量重算），或用户在本机保存任务（`task_list_screen.dart:93` 等）与远程下发重叠。

Forward Call Chain（远程）：`RcCmd.taskUpsert`（`:1172`）→ `_upsertTask`（`:1921`）→ `deletePendingForTask`（`:1947`）→ `_rematerialize`（`:1948`）→ `commitAll`（`:2154`）。
Forward Call Chain（引擎）：`Timer.periodic`（`:2291`）→ `extendCounterPlan`（`:2306`）→ `replan`（`:1242`）→ `reconcile`（`:1324`）。

Reverse Call Chain：两条链没有共同的上游锁；唯一的共享资源是 DB 文件。

Data Flow / State Transition：`pending` 集合被两条链各自"整体替换"，无版本号/无 CAS/无 `WHERE` 条件 ⇒ 最后提交者胜。

Evidence:
```dart
// endpoint_service.dart:1947-1948（无事务包裹）
final dropped = await occ.deletePendingForTask(task.id);
final planned = await _rematerialize(task, occ);
```
```dart
// occurrence_repository.dart:51 —— 引擎侧有事务
await _db.db.transaction((txn) async { ... });
```

Reproduction Steps：
```dart
test('SCH-05 计划重建必须原子（删除+插入同事务）', () async {
  // 用一个可控的 AppDatabase 包装，在 delete 与 insert 之间插入一次 reconcile
  // （FFI 下可直接在两次调用之间执行另一条"引擎侧"调用，模拟交错）
  final now = DateTime(2026, 1, 1, 10, 0);
  final f = occ.deletePendingForTask('t1');       // 远程 delete
  await f;
  await occ.reconcile(['t1'], [                     // 引擎插入（新定义）
    PlannedOccurrence(id: 'new1', taskId: 't1',
        fireAt: now.add(const Duration(hours: 1)), status: OccurrenceStatus.pending),
  ], now);
  await occ.commitAll([                             // 远程插入（旧快照）
    PlannedOccurrence(id: 'old1', taskId: 't1',
        fireAt: now.add(const Duration(hours: 2)), status: OccurrenceStatus.pending),
  ]);
  final rows = await occ.allForTask('t1');
  expect(rows.length, 1);   // 现状 2 ⇒ 幽灵计划
});
```

Root Cause：计划写入有两个"权威"（引擎 isolate 与主 isolate），但没有单一写入者、没有版本号、没有事务边界；`_rematerialize` 是 `reconcile` 的**语义复制品**而非调用者。

Alternative Hypotheses：sqflite 的语句级串行化可能让交错概率很低（每条语句原子）。但 delete 与 insert 是**两条**语句，语句级原子性无法覆盖它们之间的窗口，因此结论不变，只是频率低。

Business Impact：罕见的"改了任务却仍按旧时刻响一次"（幽灵计划）或"新计划少一条"。与 `P2-03`（幽灵计划）同族，但触发面从"单入口"扩到"跨 isolate"。

Recommended Fix：把 `_rematerialize` 删掉，改为 `OccurrenceRepository.reconcile([task.id], entries, now)`（远程侧算 entries 仍可用 `ScheduleEngine`），并把"算 entries"与"写库"放在同一次调用里；进一步可在 `tasks` 表加 `plan_version`，`reconcile` 用 `WHERE plan_version < ?` 做乐观并发。

Regression Risks：远程 `task.upsert` 现在会**保留**已到期 pending（与 SCH-02 同修），回执里的 `planned` 数值会变；`test/cov_remote_ctrl*_test.dart` 可能断言了行数。

Verification Tests：上述交错用例；并发压测（两 isolate 各 100 次 upsert + 10 次 replan，断言不出现 id 集合差集）。

Remaining Uncertainty：FFI 单进程下无法完全复刻 Android 的双连接行为；真机取证需要日志埋点（建议在 `reconcile` 与 `_rematerialize` 前后各记一条 `dbg` 行）。

---

### SCH-06 远程 `task.upsert` / `task.delete` 不触发 `replan` ⇒ 通道B（精确闹钟）与数据库脱节

Severity: **P2**
Evidence Status: **CONFIRMED**（缺调用 = 代码事实）；后果严重度依赖"进程被杀"场景 = HIGH_CONFIDENCE

Affected Files/Lines:
- `lib/remote/endpoint_service.dart:1946-1977`（`_upsertTask` 全程无 `replan`，只有日志与 `_ack`）
- `lib/remote/endpoint_service.dart:1993-1995`（`_deleteTask` 同）
- 对照：`lib/remote/endpoint_service.dart:1249-1251`（`task.toggle` **有** `replan`）、`:2406`（`run.master.set` 有）
- `lib/services/background_engine.dart:1179-1221`（`pushExactAlarms` **只**被 `replan` 调用，`:1365`）
- `lib/services/background_engine.dart:2315-2320`（tick 只在 `planNeedsExtend` 为真时 replan）
- `lib/domain/scheduling/schedule_engine.dart:414-421`（阈值 12h / 视界 48h ⇒ 稳态约 36h 才重算一次）

Expected Behavior：任务定义变更后，原生精确闹钟应立即按新计划重排（与 `task.toggle` 的既有做法一致）。

Actual Behavior：`task.upsert` 只改 DB（并删/插 occurrences），**不请求 replan** ⇒ AlarmManager 里仍是旧时刻集合（旧条目已被删除，新条目没有闹钟）。由于 tick 的续算判据是"覆盖末端 < now+12h"，稳态下最长 **36 小时**内不会触发全量重排。后果：
- 进程存活时：通道A（15s Timer）仍能执行，只是没有精确闹钟；
- 进程被杀/深度 Doze 时：新计划**完全没有通道B**，到点不响（这正是通道B存在的理由，`docs/05`）；
- 删除任务：旧闹钟仍会到点唤醒一次引擎（白耗电 + `executeDue` 空转）。

Trigger Conditions：控制端 `task.upsert`（改名/改时刻/新建）或 `task.delete` 之后，设备进入 Doze 或进程被杀，且 36h 内没有其他 replan 触发源。

Forward Call Chain：`_upsertTask`（`:1921`）→ `commitAll`（`:2154`）→ 返回 → **无** `pushExactAlarms`。真正的排布只在 `replan`（`:1365`）里。

Reverse Call Chain：`replan` 的调用点：`background_engine.dart:1904/2319/2357/1387`、`counter_plan_service.dart:99/115`、`task_list_screen.dart:93/127/198/244/606/702/788`、`settings_screen.dart:807/835/1873`、`endpoint_service.dart:1251/1628/2406`。**`_upsertTask` 不在其中**。

Data Flow / State Transition：DB pending 集合（新）≠ AlarmManager 集合（旧）。两个"计划真源"分叉。

Evidence:
```dart
// endpoint_service.dart:1976-1977 —— 直接 ack，没有 replan
await _ack(msg, true, data: '${existed ? 'updated' : 'created'};planned=$planned');
```
```dart
// :1249-1251 —— 同文件的 toggle 却做了
var replanRequested = true;
try { await BackgroundServiceManager.instance.replan(); } ...
```

Reproduction Steps：
```dart
test('SCH-06 远程任务变更必须请求引擎重排（通道B 同步）', () {
  final src = File('lib/remote/endpoint_service.dart').readAsStringSync();
  final upsert = functionBodyBlock(src, 'Future<void> _upsertTask(');
  expect(upsert, contains('replan'),   // 现状：不含 ⇒ 判红
      reason: '远程 upsert 后不重排 ⇒ AlarmManager 仍是旧时刻，进程被杀后新计划无通道B');
});
```
行为级：`NativeBridge.setExactAlarms` 注入假实现，记录入参；下发 upsert 后断言闹钟集合包含新 occurrence 的时刻。

Root Cause：三个远程写任务的入口各自实现副作用，`toggle` 补齐了（P1-16），`upsert`/`delete` 漏了；没有"任务变更 → 必重排"的统一收口。

Alternative Hypotheses：可能有意"不打扰引擎"，靠 tick 自愈。但 tick 的续算判据被 BUG-086 改成"覆盖末端"后，自愈周期从"每 tick"退化为"约 36h"，该假设已不成立（这正是 BUG-086 修复带来的**新耦合**）。

Business Impact：远程改排期后，灭屏/被杀场景下新计划不响；用户侧表现是"远程改了时间，晚上没响"，且日志无异常。

Recommended Fix：在 `_upsertTask` / `_deleteTask` 末尾统一调用 `BackgroundServiceManager.instance.replan()`，失败时把 `replan=failed` 写进 ack（照抄 `:1249-1262` 的既有形状）。

Regression Risks：replan 是 `invoke` fire-and-forget（`background_service_manager.dart:289`），不会阻塞 ack；引擎未运行时 `invoke` 无副作用（`_svc.invoke` 不抛），需注意 `BUG-097` 的 try/catch 形状（`:378-383`）。

Verification Tests：源码契约锁 + 假 `NativeBridge` 断言闹钟集合；断言 ack 里带 `replan=requested|failed`。

Remaining Uncertainty：`setExactAlarms` 是否内部会"清空后重设"（若是追加语义，旧闹钟残留会更严重）——`NativeBridgePlugin.kt:100-118` 未展开细读，列为未覆盖项。

---

### SCH-07 停机/关闭守卫**不中断**在飞动作：`recordAndLog` 无取消点，`executeDue` 循环内不复检 `stopping`

Severity: **P2**
Evidence Status: **CONFIRMED**（无取消机制）；实际持续时长取决于 stopSelf 是否成功 = HIGH_CONFIDENCE

Affected Files/Lines:
- `lib/services/background_engine.dart:855-931`（`recordAndLog`：`rec.start` → `Future.delayed(Duration(seconds: seconds))` → `rec.stop`；**全程无取消令牌**）
- `lib/services/background_engine.dart:877`（唯一的等待点，最长 1800s）
- `lib/services/background_engine.dart:1501-1601`（`executeDue` 循环：`stopping` 只在**入口** `:1475` 检查，循环体内从不复检）
- `lib/services/background_engine.dart:2000-2091`（stop 清理链：`:2015-2023` 停守卫/播放，**未调用 `vibrate.stopAll()`**）
- `lib/services/background_engine.dart:1964-1981`（关守卫：取消订阅 + `guard.stop()`，但在飞的 `runGuardPlan` 不受影响）
- `lib/services/vibrate_session.dart:400-410`（`stopAll` 存在但 stop 路径未调用）

Expected Behavior：用户停引擎/关守卫后，任何"正在出声/正在录音"的动作应在有限时间内停止，并把该 occurrence 落成可解释的终态（`aborted`/`failed('已停止')`）。

Actual Behavior：
- 播放：可中断（`playback.stop()` 推进 `_stopGen`，`playback_service.dart:293`；`_waitPlayWindow` 50ms 轮询退出）——**这一条是好的**。
- 录音：**不可中断**。`Future.delayed` 无法取消；关守卫后 `recordAndLog` 会继续录到 `seconds` 结束（默认 60s，上限 1800s）。麦克风被本应用占用，用户以为"关了"。
- TTS：`speakSystemTts` 最长 120s（`:779-780`），stop 路径不调 `tts.stop()`（只有 `speakSystemTts` 自己的 finally）。
- `executeDue` 批次：stop 只让**入口**返回；已经进入循环的批次会把剩余 2 条继续跑完（`:1501` 无 `if (stopping) break;`），其中每条的 `runAction` 都在 `playback.stop()/dispose()` **之后**启动新的播放器（`play()` 每次新建，`playback_service.dart:163`）。
- 振动：stop 不调 `vibrate.stopAll()` ⇒ 当前 20s 分片继续震到自然结束（`vibrate_session.dart:9`）。

Trigger Conditions：长录音/长播放/长 TTS 执行期间用户停引擎或关守卫；或振动分片进行中停引擎。

Forward Call Chain（录音）：`executeDue`（`:1572`）→ `runSingle`（`:1078`）→ `recordAndLog`（`:855`）→ `Future.delayed`（`:877`）。
Forward Call Chain（停机）：`service.on('stop')`（`:2000`）→ `stopping=true`（`:2002`）→ `playback.stop/dispose`（`:2023/2033`）→ `stopSelf`（`:2084`）。

Reverse Call Chain：UI 首页引擎开关 → `BackgroundServiceManager.stop()`（`background_service_manager.dart:233`）；守卫页开关 → `setGuard(false)`（`:303`）。

Data Flow / State Transition：occurrence 在执行前已是 `failed`（占用）；被中断时若 `recordAndLog` 抛错 → `failed`；若正常录完 → `done`。**没有任何"aborted"语义**，"用户停止"与"执行失败/成功"不可区分（与 SCH-04 同根）。

Evidence:
```dart
// :877 —— 唯一等待点，无取消
await Future<void>.delayed(Duration(seconds: seconds));
```
```dart
// :1501 —— 循环体内没有 stopping 复检
for (final o in due) {
  final tickNow = DateTime.now();
```

Reproduction Steps：
```dart
test('SCH-07 停机必须中断在飞录音', () async {
  // 以注入的 fake recorder + fake clock 跑 recordAndLog 的等价逻辑（需先抽出纯逻辑），
  // 断言：stop 令牌置位后 ≤1s 内 rec.stop() 被调用。
  // 当前实现无法通过 —— Future.delayed 无取消点。
});
test('SCH-07 executeDue 批次内必须复检 stopping', () {
  final body = functionBlock(File('lib/services/background_engine.dart').readAsStringSync(),
      'Future<void> executeDue()');
  final loop = body.substring(body.indexOf('for (final o in due)'));
  expect(loop, contains('stopping'), reason: '循环体内必须能中途退出'); // 现状：不含
});
```

Root Cause：执行链是"无取消令牌的串行 await"；`stopping` 只是一个"入口闸门"，不是"执行期取消信号"。录音/TTS 又是自建资源，不受 `PlaybackService` 的代次机制保护。

Alternative Hypotheses：可能认为"stopSelf 会杀 isolate，一切自然结束"。这在 `stopSelf` 成功时成立，但：① 清理链有多段 await（`:2014-2068`），期间仍在跑；② `stopSelf` 失败时（`:2085-2088` 只记日志）引擎继续活着并继续录音；③ **关守卫**根本不杀 isolate（`:1964-1981`），录音会完整跑完。

Business Impact：隐私敏感（"关了还在录"）、耗电、麦克风被占导致其他应用/守卫无法启动。属于项目红线"承诺了停止就必须停止"的违反。

Recommended Fix：
1. 给 `recordAndLog` 加可取消等待：`await Future.any([Future.delayed(seconds), _stopSignal.future])`，`_stopSignal` 由 stop / guard-off 触发；取消时 `rec.stop()` 并把 outcome 标 `skipped('已停止')`；
2. `executeDue` 循环首行加 `if (stopping) break;`（并把剩余条目**保留为 pending**，不标 skipped——引擎下次启动会补）；
3. stop 清理链补 `await vibrate.stopAll(reason: '引擎停止')`；
4. TTS 路径暴露 `stop` 句柄（或在 stop 时调用 `FlutterTts().stop()` 的等价通道）。

Regression Risks：`S2`（重启绝不续发）与 `S3`（任何时刻都能停）是既有锁（`vibrate_session.dart:29-30`）；新增 `vibrate.stopAll()` 与它们一致，风险低。`executeDue` 的 `break` 会改变"停止时剩余条目是否被 skip"的语义，需确认 UI 上不会显示"已跳过"。

Verification Tests：假 recorder 断言 stop 延迟 ≤1s；`executeDue` 批次中途 stop 后剩余条目仍为 pending；振动在 stop 后 ≤1 tick 内 cancel。

Remaining Uncertainty：`stopSelf` 到 isolate 销毁的实际延迟（真机未测）；关守卫路径下 `runGuardPlan` 是否会被 `guardSub.cancel()` 阻止——**不会**（已启动的 Future 不受订阅取消影响）。

---

### SCH-08 声音入口的冷却基准在执行**之后**才落库 ⇒ 长动作期间同一任务可重复触发

Severity: **P2**
Evidence Status: **HIGH_CONFIDENCE**

Affected Files/Lines:
- `lib/services/background_engine.dart:1683-1686`（`lastDoneFor` + `at.difference(last) < cooldown`）
- `lib/services/background_engine.dart:1640-1660`（`runAction` 完成后才 `commitAll` 一条 `done`）
- `lib/data/repositories/occurrence_repository.dart:202-212`（`lastDoneFor` 只查 `status='done'`）
- `lib/services/background_engine.dart:1941-1946`（`guardSub` 对每个事件 `unawaited(onSoundEvent(...))` ⇒ 事件之间也不串行）

Expected Behavior：冷却应"从决定执行那一刻起算"（`reactive_counter_service.dart:390-391` 的注释就是这么写的），保证同一任务在冷却窗口内至多执行一次。

Actual Behavior：定时入口的冷却靠物化期保证（`schedule_engine.dart:371-381`），声音入口靠 `lastDoneFor`。而 `lastDoneFor` 只认 `done`，`done` 在 `runAction` **返回后**才写。若动作耗时 > 冷却窗口（例如 `SoundTrigger.cooldownSec` 设为 30s，动作为 60s 录音），期间到来的第二个声音事件查 `lastDoneFor` 仍是 null（或更早的时间）⇒ 再次执行。叠加 `unawaited` 派发，两个 `runGuardPlan` 完全并行。

Trigger Conditions：声音触发任务的 `cooldownSec` < 动作时长，且窗口内有两次声音事件（守卫自身 `cooldownSec` 也参与，默认 120s；但 `sound_profiles.cooldown_sec` 可由用户调小，且 `task.cooldownSec` 与 `cfg.cooldownSec` 取 `max`（`:1685`）——用户可把两者都设成 10s）。

Forward Call Chain：`guardSub`（`:1941`）→ `onSoundEvent`（`:1670`）→ `lastDoneFor`（`:1683`）→ `admitExecution`（`:1689`）→ `runGuardPlan`（`:1747`）→ `runAction`（`:1640`）→ `commitAll`（`:1642`）。

Reverse Call Chain：`SoundGuardService._events`（`sound_guard_service.dart:180`）← 采流阈值判定。

Data Flow / State Transition：`lastDoneFor` 的语义是"最近一次成功完成的时刻"，被当作"最近一次开始的时刻"使用 ⇒ 时间基准错位。

Evidence:
```dart
// :1683-1686
final last = await occs.lastDoneFor(t.id);
final cooldown = Duration(seconds: math.max(cfg.cooldownSec, t.cooldownSec));
if (last != null && at.difference(last) < cooldown) continue;
```

Reproduction Steps：
```dart
test('SCH-08 声音冷却必须从"开始执行"起算', () async {
  final t0 = DateTime(2026, 1, 1, 10, 0, 0);
  // 第一次执行开始（尚无 done 记录）
  expect(await occ.lastDoneFor('t1'), isNull);
  // 60s 动作尚未结束，10s 后第二个事件到来
  final t1 = t0.add(const Duration(seconds: 10));
  final last = await occ.lastDoneFor('t1');
  expect(last, isNull);            // 现状：冷却判据看不到"正在执行"
  // 期望：以 running 记录或内存 claim 时间为基准 ⇒ 第二次被拒绝
});
```

Root Cause：冷却基准依赖终态记录，而终态天然晚于开始；`runGuardPlan` 也没有"任务级 claim"（SCH-03 同一根因）。

Alternative Hypotheses：守卫层 `cfg.cooldownSec` 通常 ≥120s，可能覆盖大多数动作时长。但 `task.cooldownSec` 与 profile 都可被用户调小，且远程可下发小值（`task_wire.dart:27 maxCooldownSec` 只设上界）。

Business Impact：同一声音在短时间内触发两次反击/两次取证；对"反击"产品语义尤其糟（叠加出声、暴露位置）。

Recommended Fix：与 SCH-03 的 `_runningTasks` 合流——`tryClaim` 成功即写内存 claim 时间，冷却判据取 `max(lastDoneFor, claimAt)`；或在 `runGuardPlan` 开始时就 `commitAll` 一条 `running`（配合 SCH-04 的新状态）。

Regression Risks：`R90-04`/`BUG-093` 要求 `skipped` 不并入 `done`，改动不得回退三态映射（`:1654-1658`）。

Verification Tests：上述用例 + 并发两事件的端到端（假 `runAction` 延迟 60s，断言只执行 1 次）。

Remaining Uncertainty：默认配置下（120s 冷却、≤60s 动作）不触发；需用户/远程把冷却调到 < 动作时长。

---

### SCH-09 `startReactiveCounter` 可重复调用而不停止旧实例 ⇒ Timer 泄漏 + "关掉后仍会出声"

Severity: **P2**
Evidence Status: **CONFIRMED**（代码路径确定）；是否命中取决于 UI 重复下发

Affected Files/Lines:
- `lib/services/background_engine.dart:1829-1860`（`startReactiveCounter`：直接 `reactive = ReactiveCounterService(...)..start()`，**不检查/不停止** `reactive` 旧值）
- `lib/services/background_engine.dart:1990-1999`（`service.on('reactive')`：`on=true` 时无条件 `startReactiveCounter()`）
- `lib/services/background_engine.dart:1953-1955`（守卫启动成功时也会 `startReactiveCounter()`）
- `lib/services/sound_guard_service.dart:140`（`if (_running) return ok` ⇒ 重复开守卫不会失败）
- `lib/services/reactive_counter_service.dart:261-267`（`start()` 幂等，但**只对自己**）、`:277-286`（`_scheduleSilence` 布置 15–25min Timer）
- `lib/services/reactive_counter_service.dart:270-274`（`stop()` 取消 Timer —— 但旧实例没人调用它）

Expected Behavior：任一时刻至多一个 `ReactiveCounterService`；重复开启应是幂等 no-op。

Actual Behavior：每次 `startReactiveCounter()` 都 `new` 一个实例并 `start()`（布置一个 15–25 分钟 Timer），旧实例被**直接丢弃但仍在运行**：`_running=true`、`_silenceTimer` 仍 armed。旧实例的 `handleSilence` 到期后会 `_counter(...)` 直接调 `playback.play`（`:405-413`）——**即使 UI 上"动态反击"已关闭**（`stopReactiveCounter` 只停新实例，`reactive_counter_service.dart:270`）。用户听到一次无来源的噪音，且没有任何引用能停它。

Trigger Conditions：
1. 动态反击开启状态下，用户再次点"开"（UI 每次点击都 `invoke('reactive')`，`background_service_manager.dart:316`）；
2. 或守卫开启状态下重复点"守卫开"（`service.on('guard')` → `guard.start` 早退 ok → `startReactiveCounter`）；
3. 或"守卫开"与"反击开"两条指令先后到达（`:1953` 与 `:1994` 都会启动）。

Forward Call Chain：`service.on('reactive')`（`:1990`）→ `startReactiveCounter`（`:1829`）→ `ReactiveCounterService.start`（`:261`）→ `_scheduleSilence`（`:277`）→ `Timer(15–25min)`。

Reverse Call Chain：UI 动态反击开关 → `BackgroundServiceManager.setReactiveCounter`（`background_service_manager.dart:316`）。

Data Flow / State Transition：`reactive` 引用被覆盖；旧实例成为**不可达但仍活跃**的对象（Dart 不会因不可达而取消 Timer）。

Evidence:
```dart
// :1829-1859
Future<void> startReactiveCounter() async {
  if (!guard.isRunning) return;
  final pool = await buildReactivePool();
  reactive = ReactiveCounterService(...)..start();   // 旧 reactive 未 stop
}
```

Reproduction Steps：
```dart
test('SCH-09 重复开启动态反击不得泄漏实例', () {
  // 纯逻辑：ReactiveCounterService 可注入 timerFactory / clock（:210-212）
  final timers = <FakeTimer>[];
  final a = ReactiveCounterService(pool: [...], timerFactory: (d, cb) { ... });
  a.start();
  // 复刻 startReactiveCounter：第二次启动必须先 stop 旧的
  final b = ReactiveCounterService(...); b.start();
  // 断言：a 的 timer 已被 cancel（当前实现：不会）
  expect(timers.where((t) => !t.cancelled).length, 1);   // 现状 2
});
```

Root Cause：`reactive` 是"可覆盖引用"而不是"受管单例"；启动路径没有"先停旧的"这一条不变量，也没有 `dispose`。

Alternative Hypotheses：可能认为 `ReactiveCounterService.start()` 的 `if (_running) return` 足够——但它只对**同一实例**生效，跨实例无效。

Business Impact：关闭后仍有幽灵反击出声（合规风险：用户明确关闭后设备仍出声）；长驻 Timer 耗电。

Recommended Fix：`startReactiveCounter` 首行 `reactive?.stop(); reactive = null;`（或 `await reactive?.stop()`）；更好是把 reactive 的装配收口到 `_applyReactive(enabled)` 单一函数，`guard`/`reactive` 两条监听都调它。

Regression Risks：`stop()` 是同步的（`:270`），在飞 `_counter` 不会被中断（`_acting` 仍在）——这是 SCH-07 的同类问题，改动时一并考虑。

Verification Tests：上述用例；端到端：开→开→关，推进假时钟 20min，断言无 `counter` 审计新增。

Remaining Uncertainty：UI 是否会对同一开关重复下发（取决于开关控件实现，未读 `guard` 页）。`setReactiveCounter` 是 fire-and-forget，重复点击很可能重复下发。

---

### SCH-10 关键判据全部依赖墙钟（`DateTime.now`），系统时间跳变会导致误触发或长时间静默

Severity: **P2**
Evidence Status: **CONFIRMED**（依赖墙钟）；具体跳变场景为 HIGH_CONFIDENCE / 频率 UNVERIFIED

Affected Files/Lines:
- `lib/services/reactive_counter_service.dart:220`（`_clock = clock ?? DateTime.now`）、`:368-372`（冷却 `now.isBefore(cd)`）、`:339-350`（静默判定 `now.difference(last) < silenceMin`）
- `lib/services/sound_guard_service.dart:161-179`（`loudSince` / `lastFired` 墙钟）
- `lib/services/vibrate_session.dart:353`（`now().difference(s.startedAt)` 决定振动是否结束）
- `lib/services/background_engine.dart:1507-1508`（stale 判定 `tickNow.difference(o.fireAt) > 10min`）
- 对照：`Timer` 本身走单调时钟（Dart VM 实现），所以"定时器"与"判据"用了两个不同时间源

Expected Behavior：冷却/静默/时长这类"间隔"语义应使用单调时钟（`Stopwatch` / `elapsedRealtime`）；只有"日历/窗口"语义才应使用墙钟。

Actual Behavior：
- **时钟前跳**（NTP 校正、用户改时间、时区切换后手动校正）：`_cooldownUntil` 立即过期（反击可立刻再来一次）；`handleSilence` 立即判"已静默"⇒ 可能在白天/有人时触发静默反制；引擎侧所有 `fire_at` 落在跳变量内的 pending 一次性变成"迟到 >10min" ⇒ **全部被 stale-skip**（前跳 1 小时 = 丢掉 1 小时内所有计划）。
- **时钟回跳**：`_cooldownUntil` 变成"未来"⇒ 反击被静默禁用（回跳多久就禁多久）；`handleSilence` 的 `difference` 为负 ⇒ 每次都判"近期仍有声音"，静默反制同样停摆；引擎侧 pending 全部"还没到"⇒ 任务延迟（延迟量 = 回跳量），且 `planNeedsExtend` 为假 ⇒ 不重算。
- 振动：`elapsed` 为负 ⇒ 提前续发所有分片（总时长仍受 `coveredMs < totalMs` 限制，用户感知是"节奏乱了"）；前跳 ⇒ 提前结束（**少震**）。

Trigger Conditions：设备长时间关机后开机（RTC 漂移）、跨时区飞行后手动改时间、运营商 NTP 大校正、开发者调试改时间。时区切换本身**不影响**（`DateTime` 比较走 epoch），只有"墙钟数值变化"才触发。

Forward Call Chain（前跳丢任务）：`Timer.periodic`（`:2291`）→ `executeDue`（`:1473`）→ `due()` 返回跳变窗口内的全部 pending → 逐条 `tickNow.difference(o.fireAt) > 10min`（`:1508`）→ `skipped`（`:1509`）。

Reverse Call Chain：`SchedulerConfig.engineTick` / `planHorizon` 全部以墙钟毫秒落库（`task.dart:210` `fire_at`）。

Data Flow / State Transition：`pending` → `skipped`（批量，且不可恢复）。冷却/静默的内部状态（`_cooldownUntil`/`_lastSoundAt`）是墙钟 `DateTime`，跳变后语义反转。

Evidence:
```dart
// reactive_counter_service.dart:368-372
final cd = _cooldownUntil;
if (cd != null && now.isBefore(cd)) { ... '冷却中（约剩 ${left}s）' ... }
// :391
_cooldownUntil = now.add(config.cooldown);
```

Reproduction Steps：
```dart
test('SCH-10 冷却必须用单调时钟（墙钟前跳不得解除冷却）', () async {
  var wall = DateTime(2026, 1, 1, 10, 0);
  final svc = ReactiveCounterService(
    pool: [const CounterAction.audio('a.mp3')],
    clock: () => wall,                       // 注入墙钟（:212 已支持）
    playAudio: ({required path, required volume, required durationMs}) async =>
        const PlayResult(ok: true, playedMs: 100),
    isBusy: () => false,
  );
  svc.start();
  SoundEvent ev() => SoundEvent(detectedAt: wall, peakDb: -5, durationMs: 4000);
  await svc.onSound(ev());                      // 第一次：重声音 → 反击，冷却 120s
  wall = wall.add(const Duration(hours: 1));    // 模拟 NTP 前跳 1 小时（真实只过了 0s）
  final r = await svc.onSound(ev());
  expect(r.reason, 'cooldown');                 // 现状：acted=true（冷却被墙钟跳变绕过）
});
test('SCH-10 墙钟前跳不得把整批计划判 stale', () async {
  // 3 条 fire_at = now 的 pending，把 tickNow 设为 now+1h
  // 期望：按"批次开始时刻"或单调时钟判定；现状：全部 skipped
});
```

Root Cause：把"时间间隔"与"日历时刻"混用同一个时间源；`SchedulerConfig` 的所有阈值都是 Duration，但判据实现全部是 `DateTime.now().difference(...)`。

Alternative Hypotheses：中国区设备普遍有网络对时，大跳变少见。但"关机数天后开机"（RTC 漂移数十秒到数分钟）+ 10 分钟阈值并不遥远；且前跳 5 分钟不会丢任务，前跳 11 分钟就会。

Business Impact：偶发的"整批任务不响"或"半夜突然反击"，且日志里表现为一串 `skip-stale`，用户/排障者很难归因到"改了时间"。

Recommended Fix：
1. 引擎侧引入 `Clock` 抽象（`now()` + `elapsed()`），stale 判定用 `elapsed`（进程内单调）或"批次开始时刻"；
2. `ReactiveCounterService` 的冷却/静默改用 `Stopwatch` 或注入的单调时钟（其 `clock` 注入点已存在，只需把语义从"墙钟"改为"单调"）；
3. `VibrateSession` 的 `elapsed` 同理；
4. 开机/时间变更时（`ACTION_TIME_CHANGED`）主动 `replan` 一次并写审计。

Regression Risks：`ReactiveCounterService` 的 `clock` 注入被既有测试大量使用（`test/reactive_counter_test.dart` 等），语义从墙钟改成单调会改变测试里"推进时间"的写法；需同步。`BUG-094` 的"逐条实时 now"注释需重写（与 SCH-01 的修法合并）。

Verification Tests：上述两例；再加"回跳 1 小时 → 冷却仍按真实经过时间计算"。

Remaining Uncertainty：真机上时间跳变的实际幅度未知（无埋点）。

---

### SCH-11 `latestPendingFireAt` / `pendingCountAfter` 不排除停用任务 ⇒ 续算被抑制、UI 倒计时指向永不触发的计划

Severity: **P3**
Evidence Status: **CONFIRMED**（查询无 join）；实际影响窗口 ≤36h

Affected Files/Lines:
- `lib/data/repositories/occurrence_repository.dart:119-127`（`latestPendingFireAt`：`WHERE status='pending' AND fire_at > ?`，**不 join tasks.enabled**）
- `lib/data/repositories/occurrence_repository.dart:100-106`（`pendingCountAfter` 同）、`:130-140`（`pendingWithin` 同）
- `lib/services/background_engine.dart:2315-2320`（续算判据）
- `lib/services/background_engine.dart:1149-1151`（`broadcast` 的 `pendingCount`/`nextFireAt`）
- `lib/services/background_engine.dart:1263`（`replan` 只处理 `enabledOnly: true` 的任务 ⇒ **停用任务的 pending 永不删除**）
- `lib/services/background_engine.dart:1519-1521`（停用任务的 pending 到点后被标 `skipped`）

Expected Behavior：续算判据与 UI 展示应只统计"会真正触发"的计划。

Actual Behavior：停用任务在 `replan` 里被 `enabledOnly:true` 过滤掉，其既有 pending **既不删除也不重算**（只有到点后由 `executeDue` 标 skipped）。于是：
- 若某停用任务有一条 40 小时后的 pending，`latestPendingFireAt` 返回它 ⇒ `planNeedsExtend` 为假 ⇒ tick **不再 replan**（最长 36h）；期间新建/修改的任务只靠 UI 的显式 `replan` 才生效（远程 upsert 不 replan，见 SCH-06 ⇒ 双重叠加）。
- `broadcast` 的 `pendingCount` / `nextFireAt` 包含停用任务 ⇒ 首页显示"下次触发 22:00"而那条永远不会执行。

Trigger Conditions：停用一个仍有未来 pending 的任务（`enabledOnly` 过滤使其残留），之后依赖 tick 自愈而不是显式 replan。

Forward Call Chain：`Timer.periodic`（`:2291`）→ `latestPendingFireAt`（`:2316`）→ `planNeedsExtend`（`:2317`，`schedule_engine.dart:414-421`）→ 跳过 `replan`。

Reverse Call Chain：`replan` 的 `listAll(enabledOnly: true)`（`:1263`）——正是"停用任务不进对账面"的源头。

Data Flow / State Transition：停用任务的 `pending` 行长期驻留，成为"覆盖末端"的虚假支撑。

Evidence:
```sql
-- occurrence_repository.dart:121-124
SELECT MAX(fire_at) AS m FROM occurrences WHERE status = 'pending' AND fire_at > ?
```

Reproduction Steps：
```dart
test('SCH-11 续算判据必须只统计启用任务的 pending', () async {
  final now = DateTime(2026, 1, 1, 10, 0);
  await occ.commitAll([
    PlannedOccurrence(id: 'dis', taskId: 'disabled_task',
        fireAt: now.add(const Duration(hours: 40)), status: OccurrenceStatus.pending),
  ]);
  final coverEnd = await occ.latestPendingFireAt(now);
  expect(planNeedsExtend(coverEnd, now: now,
      threshold: const Duration(hours: 12)), isFalse);   // 现状：false ⇒ 不续算
  // 期望：停用任务的 pending 不计入 ⇒ true（需要续算）
});
```

Root Cause：仓储层查询面向"全局计划"，但调用方需要"可执行计划"；没有 join `tasks`。

Alternative Hypotheses：停用任务的 pending 由 `executeDue` 到点清理（`:1519-1521`），所以残留是有界的（≤48h 视界）。这解释了"为何没造成永久停摆"，但不改变"最长 36h 不续算"的事实。

Business Impact：停用一条任务后，新任务可能延迟最长 36h 才被 tick 自动排上（若恰好没走显式 replan 的入口）；首页倒计时误导。

Recommended Fix：`latestPendingFireAt` / `pendingCountAfter` / `pendingWithin` 增加 `JOIN tasks t ON t.id = occurrences.task_id AND t.enabled = 1`（或调用方传 `taskIds` 白名单）；`replan` 的对账面改为"全部任务"（`enabledOnly:false`），停用任务的未来 pending 由 `reconcile` 删除（这才是"停用"的正确副作用）。

Regression Risks：`reconcile` 改为全量任务后，停用任务的 pending 会被删（语义变化，需与 SCH-02 的修法统一）；`test/db_repository_test.dart` 里对 `pendingCountAfter` 的断言可能不含 join。

Verification Tests：上述用例 + 停用后 `nextFireAt` 不再指向该任务。

Remaining Uncertainty：UI 是否在每次任务保存后都 replan（已确认本地保存路径都调 `replan`，`task_list_screen.dart:93/127/198/244/606/702/788`）——所以本缺陷主要影响"远程下发 + tick 自愈"组合。

---

### SCH-12 跨午夜窗口用 `Duration(days: 1)`（绝对 24h）构造 ⇒ DST 时区窗口错 1 小时

Severity: **P3**
Evidence Status: **SUSPECTED**（代码事实 CONFIRMED；中国无夏令时 ⇒ 实际不可复现，需目标时区有 DST）

Affected Files/Lines:
- `lib/domain/scheduling/schedule_engine.dart:204-217`（`_applyQuiet`：`DateTime(...).add(const Duration(days: 1))` / `.subtract(...)`）
- `lib/domain/scheduling/schedule_engine.dart:299-301`（`_randomWindow`：`windowEndNextDay ? add(Duration(days:1))`）
- `lib/domain/scheduling/schedule_engine.dart:326-336`（`_randomInterval`：`activeEnd ... add(Duration(days:1))`）
- 对照：`:251` / `:268` 已修正为"年月日 +1"（BUG-096），说明同类问题在本文件内**已有前例**

Expected Behavior：跨午夜的窗口端点应落在"次日同一本地钟点"。

Actual Behavior：`Duration(days:1)` 是绝对 24 小时。DST 前跳日（23h）加 24h ⇒ 次日 08:00（应为 07:00）；DST 回拨日（25h）⇒ 次日 06:00。后果：免打扰窗口多/少 1 小时（护栏要么过度收紧、要么漏 1 小时）；随机窗口的采样区间长度漂移 1 小时（同一天重算仍确定性，但跨天不一致）。

Trigger Conditions：设备时区有 DST（欧美/澳洲），且 `quietStartHour > quietEndHour`（默认 22>7 满足）或使用跨午夜随机窗口/随机间隔。

Forward Call Chain：`replan`（`:1242`）→ `materialize`（`:1318`）→ `_applyQuiet`（`:126`）→ 窗口构造（`:204-217`）。

Reverse Call Chain：`normalizeQuietWindow`（`:27-38`）← prefs。

Data Flow / State Transition：`pending` 的 `fire_at` 被平移 1 小时（`QuietPolicy.shift`），或整条被跳过（`skip`）。

Evidence:
```dart
// :205-216
windows = [
  (DateTime(day.year, day.month, day.day, quietStartHour),
   DateTime(day.year, day.month, day.day, quietEndHour).add(const Duration(days: 1))),
  ...
];
```

Reproduction Steps（需 TZ 支持，宿主可用 `TZ=Europe/Berlin`）：
```dart
test('SCH-12 跨午夜免打扰窗口在 DST 前跳日必须仍落在 07:00', () {
  // 2026-03-29 是欧洲 DST 前跳日
  final fire = DateTime(2026, 3, 29, 23, 0);
  final r = const ScheduleEngine(quietStartHour: 22, quietEndHour: 7)
      .materialize(taskWith(fire, QuietPolicy.shift), DateTime(2026,3,29,20));
  expect(r.single.fireAt, DateTime(2026, 3, 30, 7, 0));  // 现状：08:00
});
```
（`_applyQuiet` 是私有方法，需通过 `materialize` 间接测；或用 `@visibleForTesting` 暴露。）

Root Cause：`DateTime.add` 的绝对时长语义与"日历日 +1"的语义混用；BUG-096 只修了迭代游标，没修窗口端点。

Alternative Hypotheses：产品只面向中国区（`china_holidays.dart` 存在），DST 不适用。但应用未限制时区，出国使用即触发；且这是"同一 bug 家族未清完"的一致性问题。

Business Impact：出国/海外用户夜间护栏偏 1 小时（可能多静默 1 小时，或多响 1 小时——后者是合规风险）。

Recommended Fix：把三处 `.add(const Duration(days: 1))` 改为 `DateTime(y, m, d + 1, h)`（与 `:251` 同一写法）；`_randomWindow` 的 `winEndNextDay` 与 `_randomInterval` 的跨午夜同理。

Regression Risks：非 DST 时区行为完全不变（`DateTime(d+1)` 与 `add(24h)` 等价），风险极低。

Verification Tests：上述用例 + 回拨日（2026-10-25 欧洲）用例。

Remaining Uncertainty：宿主测试进程的时区设置能否稳定复现（Dart 的 `DateTime` 依赖系统 TZ，Windows 宿主可能不支持 `TZ` 环境变量）。

---

### SCH-13 契约与实现不符：`Task.priority` 不参与执行排序；`materialize(existing:)` 是死参数

Severity: **P3**
Evidence Status: **CONFIRMED**

Affected Files/Lines:
- `lib/domain/models/task.dart:71`（注释："数值大者先执行（同刻冲突时）"）
- `lib/data/repositories/occurrence_repository.dart:93`（`due()` 只 `orderBy: 'fire_at ASC'`）
- `lib/services/background_engine.dart:1493`（`due(now, limit: catchUpLimit)`，无 priority 参与）
- `lib/domain/scheduling/schedule_engine.dart:99-104`（`Set<int> existing` 参数 + 注释"用于幂等去重"）
- `lib/domain/scheduling/schedule_engine.dart:131`（`if (existing.contains(ms)) continue;`）
- 调用方：`lib/services/background_engine.dart:1318`（`engine.materialize(t, now)`，**不传 existing**）、`lib/remote/endpoint_service.dart:2152`（同）

Expected Behavior：同刻冲突时按 `priority` 降序执行；`existing` 提供"跳过已提交条目"的幂等能力。

Actual Behavior：`priority` 只影响 `listAll` 的返回顺序（`task_repository.dart:34`）与任务列表展示（`task_list_screen.dart:177`），执行顺序恒为 `fire_at ASC`，同刻时退化为 SQLite 的物理/rowid 顺序（不确定）。`existing` 自 `reconcile` 引入后已无调用方传入，成为死参数——同时其注释（"已提交的条目由仓库层幂等合并"）会误导维护者以为存在该保护。

Trigger Conditions：多条任务同一分钟到期（`dailyAt 07:00` 很常见），且用户/远程设置过 `priority`。

Forward Call Chain：`executeDue`（`:1493`）→ `due`（`:88-97`）→ 顺序执行（`:1501`）。

Reverse Call Chain：`Task.priority` ← `task_wire.dart:225-226`（远程可设，clamp ±max）← 编辑器。

Data Flow / State Transition：无状态变化，仅"执行顺序"与文档不一致。

Evidence:
```dart
// occurrence_repository.dart:89-95
final rows = await _db.db.query('occurrences',
    where: "status = 'pending' AND fire_at <= ?",
    orderBy: 'fire_at ASC', limit: limit);
```

Reproduction Steps：
```dart
test('SCH-13 同刻到期应按 priority 降序执行', () async {
  final t = DateTime(2026, 1, 1, 7, 0);
  await occ.commitAll([
    PlannedOccurrence(id: 'low@x', taskId: 'low', fireAt: t, status: OccurrenceStatus.pending),
    PlannedOccurrence(id: 'high@x', taskId: 'high', fireAt: t, status: OccurrenceStatus.pending),
  ]);
  final due = await occ.due(t, limit: 10);
  expect(due.first.taskId, 'high');   // 现状：顺序由 rowid 决定，与 priority 无关
});
```

Root Cause：`due()` 是纯 SQL 查询，无法看到 `tasks.priority`；要么 join，要么在 Dart 侧排序。

Alternative Hypotheses：`priority` 可能只是"列表排序"字段，注释写错了。这同样需要修——文档与实现必须有一处改。

Business Impact：同刻多任务时"谁先响"不可预期；长动作场景下（SCH-01）甚至决定"谁能被 stale 丢掉"。属于可解释性/可预期性缺陷。

Recommended Fix：`due()` 增加 `ORDER BY fire_at ASC, (SELECT priority FROM tasks WHERE id = task_id) DESC`，或调用方拿到后在 Dart 侧按 `(fireAt, -priority)` 排序；`existing` 参数删除（或在 `replan` 里真正传入已提交集合）。

Regression Risks：排序变化会改变既有测试对 `due()` 顺序的断言；`existing` 删除是 API 变更（仅内部调用）。

Verification Tests：上述用例；`materialize` 不再有未使用参数（analyzer `unused` 不会报参数，需人工/源码锁）。

Remaining Uncertainty：是否有外部（远程协议）依赖 `priority` 的执行语义——`task_wire.dart` 只透传数值，未声明语义。

---

### SCH-14 `guardDelayTimer` 单槽覆盖：新的延时计划静默丢弃旧的（无审计）

Severity: **P3**
Evidence Status: **CONFIRMED**

Affected Files/Lines:
- `lib/services/background_engine.dart:1728-1745`（`guardDelayTimer?.cancel(); guardDelayTimer = Timer(...)`）
- `lib/services/background_engine.dart:1967-1968` / `:2015-2016`（关闭/停机时取消，正确）
- `lib/services/background_engine.dart:1736-1742`（回调里只复检 `guardEnabled`，不复检 `stopping`）

Expected Behavior：每个"延时执行"决策都应有归宿：执行、或被明确取消并留痕（与 `replanQueued` 的 BUG-087 教训同源——"触发源不得静默消失"）。

Actual Behavior：同一时刻只能有一个待发延时计划；第二个声音事件到来时，第一个被 `cancel()` 且**没有任何日志**（对比 `replan` 的 `replanQueued` 与 `logs.append('guardDelay')` 只在排定时写一条 success）。用户/审计无法知道"那次计划被后来的事件顶掉了"。另外回调里没有 `stopping` 检查，理论上可在停机清理链期间触发 `runGuardPlan`（`unawaited`，`stopping` 不拦它，见 SCH-03/07）。

Trigger Conditions：`plan.delayMs > 0`（编排配置了延时）且两次声音事件间隔 < 延时。

Forward Call Chain：`onSoundEvent`（`:1728`）→ `guardDelayTimer?.cancel()`（`:1735`）→ 新 `Timer`（`:1736`）→ 回调 `runGuardPlan`（`:1741`）。

Reverse Call Chain：`GuardOrchestration.delayMs` ← `db.kvGet(guardOrchestrationKey)`（`:1616-1617`）。

Data Flow / State Transition：计划被丢弃，无状态、无审计。

Evidence:
```dart
// :1735-1742
guardDelayTimer?.cancel();
guardDelayTimer = Timer(Duration(milliseconds: plan.delayMs), () {
  guardDelayTimer = null;
  if (!guardEnabled) return;          // 没有 stopping 检查
  unawaited(runGuardPlan(plan, DateTime.now()));
});
```

Reproduction Steps：
```dart
test('SCH-14 延时计划被覆盖时必须留痕', () {
  final src = File('lib/services/background_engine.dart').readAsStringSync();
  final body = functionBlock(src, 'Future<void> onSoundEvent(');
  final i = body.indexOf('guardDelayTimer?.cancel()');
  final seg = body.substring(i, i + 400);
  expect(seg, contains('logs.append'), reason: '取消旧延时计划必须写审计'); // 现状：不含
});
```

Root Cause：单槽 Timer + 无"队列/取消记账"；`guardDelayTimer` 只解决了"能取消"，没解决"取消要可见"。

Alternative Hypotheses：产品可能刻意"只保留最后一次"，避免连续噪音触发多次反击。若是意图，也应写一条 `guardDelay`/`skipped` 说明"被新事件顶替"。

Business Impact：低（延时编排是可选增强），但属于"静默丢失触发源"，与本项目 BUG-087 的定性同族。

Recommended Fix：取消前写一条 `action:'guardDelay', status:'skipped', message:'被新的声音事件顶替'`；回调首行加 `if (stopping) return;`。

Regression Risks：审计条数增加，可能影响"日志条数"类断言。

Verification Tests：上述源码锁 + 行为用例（两次事件、推进假时钟，断言只执行最后一次且有一条 skipped 日志）。

Remaining Uncertainty：`GuardOrchestration` 的 UI 是否暴露延时配置（未读 `guard` 页）。

---

### SCH-15 `stopping` 永不复位且 `stopSelf` 失败无自愈 ⇒ 僵尸引擎（无法再次启动、无法自愈）

Severity: **P3**
Evidence Status: **SUSPECTED**（逻辑确定；`stopSelf` 失败频率未知）

Affected Files/Lines:
- `lib/services/background_engine.dart:479`（`bool stopping = false;`）、`:2002`（**唯一**写入 true）、全仓无 `stopping = false`
- `lib/services/background_engine.dart:2080-2090`（`finally` 里 `stopSelf()` 失败只 `_diagStep` + print，**无重试、无回退**）
- `lib/services/background_engine.dart:2291-2293`（tick 首行 `if (stopping) return;`）
- `lib/services/background_engine.dart:2000`（stop 监听器无 `if (stopping) return` 幂等闸门）
- 对照：`BackgroundService.java:192-195`（`isRunning` 为真时 `runService()` 直接返回 ⇒ 用户再点开不会拉起新引擎）

Expected Behavior：`stopSelf` 失败时应重试（或至少 `stopping` 可复位、允许用户再次 stop/start 自愈）；重复 stop 应幂等。

Actual Behavior：
- `stopping` 一旦置位永不撤销，引擎即使活着也不再做任何工作（tick 全 `return`），但 FGS 通知仍在、Timer 仍在空转；
- `stopSelf` 失败时（`:2085-2088`）没有任何补救 ⇒ 原生 `isRunning` 保持 true ⇒ 用户下次点"开启"时原生 `runService()` 早退 "Service already running" ⇒ **开关永久假死**（这正是 R89 描述的现场，只是根因从"清理链抛错"变成"stopSelf 自身失败"）；
- 重复 `stop` 指令会**并发跑两遍清理链**（无幂等闸门），包括两次 `CounterPlanService.disable()`（删任务 + 写日志）与两次 `stopSelf`。

Trigger Conditions：`stopSelf()` 抛错（原生侧异常/通道异常）；或用户在清理链未完成时重复点"关闭"。

Forward Call Chain：`service.on('stop')`（`:2000`）→ `stopping=true`（`:2002`）→ 清理链 → `finally stopSelf()`（`:2084`）→ 失败 → `_diagStep`（`:2086`）。

Reverse Call Chain：`BackgroundServiceManager.stop()`（`background_service_manager.dart:233`）→ `_invoke('stop')`（fire-and-forget）。

Data Flow / State Transition：`running → stopping`（终态，无出路）；原生 `isRunning=true`（不一致）。

Evidence:
```dart
// :2083-2089
try { await service.stopSelf(); }
on Object catch (e) { _diagStep('stop-self-ERR:$e'); print('…stopSelf 失败…'); }
```

Reproduction Steps：
```dart
test('SCH-15 stop 必须幂等，且 stopSelf 失败要能自愈', () {
  final src = File('lib/services/background_engine.dart').readAsStringSync();
  final handler = functionBlock(src, "service.on('stop').listen((_) async {");
  expect(handler, contains('if (stopping) return'),
      reason: '重复 stop 不得并发跑两遍清理链');       // 现状：不含
  expect(src, contains('stopping = false'),
      reason: '必须有复位路径（或明确的一次性语义 + 自愈）'); // 现状：不含
});
```

Root Cause：把 `stopping` 设计成"单向终态"，其正确性完全依赖"随后一定 `stopSelf` 成功"这一未保证的前提。

Alternative Hypotheses：`stopping` 单向可能是刻意的（"引擎即将退出，任何新工作都没有意义"，`:478` 注释）。该论证在 `stopSelf` 成功时成立；失败时没有任何兜底，属于前提未校验。

Business Impact：低概率但后果严重（用户开关永久假死，只能杀进程/重启手机）。R89 已经踩过一次同类现场。

Recommended Fix：
1. stop 监听器首行 `if (stopping) return;`（幂等）；
2. `stopSelf` 失败时重试 1 次（间隔 500ms），仍失败则 `invoke('state', running:false)` + 写一条用户可见审计（"引擎未能退出，请重启应用"），并**复位 `stopping`** 让引擎回到可服务状态（至少 tick 能继续，用户还能再试一次）。

Regression Risks：复位 `stopping` 会让"停机后迟到的 tick"重新开始工作（R90-06 要防的正是这个）。因此复位必须只在 `stopSelf` **确认失败**后做，并且要在 `clearAllAlarms` 之后（否则闹钟会被重排）。这是本修复最需要小心的地方。

Verification Tests：假 `ServiceInstance` 让 `stopSelf` 首次抛错、二次成功 ⇒ 断言调用两次；两次 `stop` 指令 ⇒ 断言清理链只跑一遍。

Remaining Uncertainty：`stopSelf` 在真机上的失败率（R89 记录的失败是"清理链抛错导致走不到 stopSelf"，与"stopSelf 本身失败"不同）。

---

## 4. 未覆盖范围与原因

| 范围 | 原因 |
|---|---|
| `lib/domain/scheduling/vibrate_resolve.dart`（482 行）全文逐行 | 属"参数解析/波形生成"纯函数，与调度并发无关；仅交叉核对了 `resolveVibratePlan` 的确定性（`schedule_engine.dart:147`）与 `VibrateLimits` 上界。深度审查应由"振动/动作"工作包负责 |
| `lib/domain/scheduling/counter_plan_random.dart`（128）、`china_holidays.dart`（153） | 纯函数/静态表；`ChinaHolidays.dayKind` 的覆盖优先级只做了调用面核对（`run_pause.dart:160-166`），未验证 2026 全年数据正确性 |
| `lib/services/counter_plan_service.dart` 的完整业务语义 | 只审查了与调度写入相关的 `apply/refreshIfNeeded/disable` 三处；`plan.validate()` 的规则集未展开 |
| `lib/domain/models/counter_plan.dart`（747）/`counter_plan_params.dart`（703） | 只读了与物化参数相关的 `windowFor`/`scheduleMode` 分支；其余校验/序列化归"数据模型"包 |
| `endpoint_service.dart` 其余 ~2400 行 | 只读了 occurrence 写入与 `replan` 触发相关的 5 段（`1172-1290`、`1921-1995`、`2129-2167`、`2348-2420`）；协议/鉴权/配对归 A3 |
| `NativeBridgePlugin.kt` 的 `setExactAlarms`/`clearAlarms` 实现 | 未展开：`setExactAlarms` 是"清空后重设"还是"追加"会直接影响 SCH-06 的严重度（若是追加，旧闹钟残留更久）。属原生桥工作包 |
| `flutter_background_service` 的 `onDestroy`/`WatchdogReceiver` 细节 | 只核对了 `runService()` 的 `isRunning` 早退与 `onStartCommand` 调用链；`WatchdogReceiver`（插件自带 15min 唤醒）未读，可能影响"僵尸态"的最终自愈 |
| 真机/模拟器运行验证 | 沙箱无 dart/flutter，且硬性要求不运行测试。所有"运行时概率"结论均标注为 HIGH_CONFIDENCE / SUSPECTED，未升级为 CONFIRMED |
| `run_pause.dart` 的节假日窗口边界（20:00/21:00） | 纯函数逻辑已读，未做全年数据回归（需 `ChinaHolidays` 的 2026 表） |
| 远程 `task.runNow` 的协议层去重（reqId 重复） | 只看了引擎侧监听器；控制端是否可能重发同一 reqId 未查 |
