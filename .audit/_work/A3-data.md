# A3 · 数据层 / 持久化 / 一致性 审计报告

- 项目：SonicShield `E:\SonicShield`（Flutter 1.9.9+32，本地 SQLite / sqflite，无后端）
- 范围：`lib/data/**`、`lib/remote/remote_store.dart`、`lib/domain/models/*` 的序列化、以及 `lib/services/{background_engine,retention_maintenance,counter_plan_service}.dart`、`lib/remote/endpoint_service.dart`、`lib/features/{tasks,sounds,settings,guard}` 中的读写调用点
- 方式：纯静态只读分析（无 dart/flutter，未执行测试，未接触任何真实 DB 文件；仓库内不存在 `*.db`）
- 外部依赖源码只读核对：`sqflite_common-2.5.13`（`database_mixin.dart` / `batch.dart`）、`sqflite-2.4.4`（用于确认迁移事务、`BEGIN IMMEDIATE`、`batch.commit` 事务化、`onDowngrade` 默认值）

> 与已知历史结论（R89 双引擎铁律、R90-09 listAll 行级兜底、R91 保留策略隔离）不重复；本报告只列**新发现**或**历史结论未覆盖的侧面**。

---

## 1. Schema 全表（v5）

`PRAGMA foreign_keys` 的唯一开启点：`lib/data/db/app_database.dart:78-85` 的 `_onConfigure`，通过 `db.rawQuery('PRAGMA foreign_keys = ON')` 执行。sqflite 的 `doOpen` 中 `onConfigure` 在**版本事务之外**先执行（`sqflite_common-2.5.13/lib/src/database_mixin.dart:1128-1131`），因此不受"事务内 PRAGMA 无效"影响；`singleInstance:false` ⇒ 每个 isolate 各开一次连接 ⇒ `onConfigure` 每连接各跑一次。`test/db_repository_test.dart:601-607` 断言 `PRAGMA foreign_keys` 读回 `1`（FFI 侧）。结论：**外键在每个连接上生效（HIGH_CONFIDENCE；Android 走同一 sqflite_common 代码路径，但未在真机复核）**。

| 表 | 列 | 类型 / 约束 | 备注 |
|---|---|---|---|
| `tasks` | id | TEXT **PK** | 手动任务 UUID；计划任务 `counter:{planId}:{key}` |
| | name | TEXT **NOT NULL** | 无长度约束 |
| | enabled | INTEGER **NOT NULL DEFAULT 1** | 0/1 |
| | trigger_type / action_type | TEXT **NOT NULL** | 枚举 `name`，无 CHECK |
| | trigger_json / action_json | TEXT **NOT NULL** | JSON 文本，无 CHECK(json_valid) |
| | asset_ids | TEXT **NOT NULL DEFAULT '[]'** | JSON 数组；**无 FK**（引用 `audio_assets.id`，孤儿由 `removeAssetRef` 兜） |
| | cooldown_sec | INTEGER **NOT NULL DEFAULT 300** | 无 CHECK ≥0 |
| | quiet_policy | TEXT **NOT NULL DEFAULT 'skip'** | `skip`/`shift` |
| | quiet_exempt | INTEGER **NOT NULL DEFAULT 0** | **三值**：0=跟随主开关/1=强制豁免/2=强制不豁免 |
| | force_run | INTEGER **NOT NULL DEFAULT 0** | 单向布尔 |
| | priority | INTEGER **NOT NULL DEFAULT 0** | 无 CHECK |
| | condition_json | TEXT NULL | JSON |
| | created_at / updated_at | INTEGER **NOT NULL** | epoch ms（UTC 瞬时） |
| | 索引 | `idx_tasks_enabled(enabled)` | 无 `(priority, created_at)` 复合索引；`listAll` 排序走全表 + 临时 B 树 |
| `audio_assets` | id TEXT **PK**；name/path TEXT **NOT NULL**；duration_ms/size_bytes INTEGER NOT NULL DEFAULT 0；tags TEXT NOT NULL DEFAULT '[]'；weight REAL NOT NULL DEFAULT 1.0；created_at INTEGER NOT NULL | 无索引、**无 UNIQUE(name)**、无 UNIQUE(path) | 见 DAT-16 |
| `occurrences` | id TEXT **PK** | 形如 `{taskId}@{fireAtMs}` | |
| | task_id TEXT **NOT NULL REFERENCES tasks(id) ON DELETE CASCADE** | **外键 + 级联删除** | 删任务 ⇒ 其全部历史 occurrence 一起消失 |
| | fire_at INTEGER **NOT NULL** | epoch ms | |
| | status TEXT **NOT NULL DEFAULT 'pending'** | pending/done/skipped/failed，**无 CHECK** | 非法值会让 `values.byName` 抛（被 listAll 兜，`get` 不兜） |
| | volume REAL NULL；duration_ms INTEGER NULL | 执行期落地参数 | |
| | quiet_exempt INTEGER **NOT NULL DEFAULT 0** | **bool（0/1）**，与 `tasks.quiet_exempt` 同名不同义（已在代码注释中声明） | |
| | 索引 | `idx_occ_fire(fire_at)`、`idx_occ_status(status)` | **缺 `(task_id)` / `(task_id,status,fire_at)`**，见 DAT-07 |
| `exec_logs` | id INTEGER **PK AUTOINCREMENT**；task_id/occurrence_id TEXT NULL；source/action/status TEXT **NOT NULL**；volume REAL；duration_ms INTEGER；message TEXT；created_at INTEGER **NOT NULL** | **无外键**（刻意：日志独立于任务生命周期） | 缺 `(action, created_at)`、`(task_id)` 索引 |
| | 索引 | `idx_logs_created(created_at)` | `recent()` 的 `ORDER BY created_at DESC LIMIT` 可走索引 |
| `sound_profiles` | id TEXT PK；name TEXT NOT NULL；threshold_db REAL NOT NULL DEFAULT -35；min_duration_ms INTEGER NOT NULL DEFAULT 800；cooldown_sec INTEGER NOT NULL DEFAULT 120；only_while_charging INTEGER NOT NULL DEFAULT 0；enabled INTEGER NOT NULL DEFAULT 0 | 无索引 | 仅 `guard_screen._persist` 写单行 `id='default'`（REPLACE），无 repository 层 |
| `kv` | k TEXT **PK**；v TEXT **NOT NULL** | 值恒为字符串（JSON 文本） | `kvSet` 用 `ConflictAlgorithm.replace` |

Schema 层总体判断：
- 所有"枚举 / 状态"列都是裸 TEXT，**没有 CHECK**；唯一防线是 Dart 侧 `values.byName`（抛异常）。
- 所有时间列统一为 `INTEGER` epoch ms，**没有 ISO 字符串列** —— 这是好的一面（见 §7 时间语义）。
- **没有一张表带 `UNIQUE` 业务键**（除 PK）：`occurrences(task_id, fire_at)`、`audio_assets(name)` 都缺。

---

## 2. 迁移链（v1 → v5）

`dbVersion = 5`（`app_database.dart:18`）。迁移执行体：`_onUpgrade`（195-231）+ `_addIntColumnIfMissing`（237-244）。

| 版本跃迁 | 操作 | 幂等性 | 风险判断 |
|---|---|---|---|
| v0 → v5（新库） | `_onCreate` 全量建表，全部 `CREATE TABLE/INDEX IF NOT EXISTS` | ✅ 幂等（R89） | 无 |
| v1 → v2 | `ALTER TABLE tasks ADD COLUMN condition_json TEXT`（198） | ❌ 非幂等 | 若 v1 库已手工/异常含该列 ⇒ `duplicate column name` ⇒ 迁移事务回滚 ⇒ **整库打不开**（低概率，DAT-14） |
| v2 → v3 | 历史版本（`git show ca6c180`）：`ALTER TABLE tasks ADD COLUMN quiet_exempt INTEGER NOT NULL DEFAULT 0` | ❌ 非幂等 | 新库不经过此分支（`_onCreate` 已含列）；**该分支已在当前代码中被删除**，仅作为历史事实存在 |
| v3 → v4 | 按列存在性补 `tasks.quiet_exempt` + `occurrences.quiet_exempt`（218-221） | ✅ 幂等（`PRAGMA table_info`） | 修 BUG-079 的正确做法；**但没有回填/校正既有值** ⇒ 见 DAT-01 |
| v4 → v5 | 按列存在性补 `tasks.force_run`（228-230） | ✅ 幂等 | 老行全部 0 = 受总开关约束（安全侧），正确 |

关键结论：

1. **迁移原子性由 sqflite 保证（CONFIRMED）**：`doOpen` 把 `onCreate/onUpgrade` 与 `setVersion` 包在**同一个 `BEGIN EXCLUSIVE` 事务**里（`database_mixin.dart:1132-1179`）。中途抛异常 ⇒ 整体回滚 ⇒ `user_version` 不变 ⇒ 下次启动可重试，**不会留下半迁移状态**。
2. **不存在"版本号写了但迁移没执行"**：`setVersion` 与迁移同事务（同上）。但存在反向风险：**"表缺失但版本号已是 5"** —— `onCreate` 只在 `user_version==0` 时跑，`onUpgrade` 只在 `version>oldVersion` 时跑，两者都不会在"版本已到位、表被删"时补建（DAT-14）。
3. **表重建（rename→create→insert→drop）在本项目从未使用**：所有迁移都是 `ADD COLUMN`，因此不存在"重建丢索引/丢外键"的问题（这一点是干净的）。`_onCreate` 里 `occurrences` 的内联外键与两个索引在新库上都会建立。
4. **新增 NOT NULL 列不会失败**：`_addIntColumnIfMissing` 恒带 `DEFAULT 0`，SQLite 允许 `ADD COLUMN NOT NULL DEFAULT <常量>`。
5. **降级（v5 → v3）不删库**：sqflite 的 `onDowngrade` 默认为 `null`（`open_options.dart:13`），只有显式传 `onDatabaseDowngradeDelete` 才删库（`database_mixin.dart:1076`）。本项目未传 ⇒ 降级只是把 `user_version` 下调、保留 v5 表结构；再升级时 `_onUpgrade(3,5)` 因列已存在而空转。**安全**。
6. **迁移只做"补列"，没有任何数据回填/校验**：这是 DAT-01 的根因。

---

## 3. 写方法事务边界清单

sqflite 事实（已核对源码）：`Batch.commit()` 内部 `database.transaction(...)`（`batch.dart:197-213`），普通事务为 `BEGIN IMMEDIATE`（`database_mixin.dart:407-422`）。因此"batch = 单事务"成立。

| # | 方法 | 涉及表 | 事务？ | 失败后残留 |
|---|---|---|---|---|
| 1 | `TaskRepository.upsert` | tasks | ✅ `db.transaction`（84-88） | 无 |
| 2 | `TaskRepository.upsertMany` | tasks | ✅ batch（108-119） | 无 |
| 3 | `TaskRepository.setEnabled` | tasks | 单语句 | 无 |
| 4 | `TaskRepository.delete` | tasks +（级联）occurrences | 单语句 | 无（但历史审计被级联删除） |
| 5 | `TaskRepository.removeAssetRef` | tasks | ❌ **SELECT 全表 → batch UPDATE**（148-163） | **丢失更新**（DAT-06） |
| 6 | `TaskRepository.deleteCounterTasks` | tasks +（级联）occurrences | 单语句 | 整族任务与其**全部历史**计划不可逆消失 |
| 7 | `AssetRepository.upsert` | audio_assets | 单语句 `REPLACE`（=DELETE+INSERT） | 无（无表引用 audio_assets） |
| 8 | `AssetRepository.upsertMany` | audio_assets | ✅ batch | 无 |
| 9 | `AssetRepository.delete` | audio_assets | 单语句 | `tasks.asset_ids` 留悬空引用（由调用方 `removeAssetRef` 兜，且被 catch 吞） |
| 10 | `OccurrenceRepository.commitAll` | occurrences | ✅ batch + `ConflictAlgorithm.ignore` | 约束冲突被 `OR IGNORE` 静默跳过（PK 重复 = 设计意图） |
| 11 | `OccurrenceRepository.reconcile` | occurrences | ✅ 显式 `db.transaction` + 内层 batch（51-84） | 无 |
| 12 | `OccurrenceRepository.markStatus` | occurrences | 单语句，**无 CAS**（171-182） | 并发双执行（DAT-03） |
| 13 | `OccurrenceRepository.purgeOlderThan` | occurrences | 单语句，**无 LIMIT** | 长写锁 |
| 14 | `OccurrenceRepository.deleteForTask` | occurrences | 单语句 | 无 |
| 15 | `OccurrenceRepository.deletePendingForTask` | occurrences | 单语句 | 若后续物化失败 ⇒ 任务**无任何计划**（DAT-05） |
| 16 | `OccurrenceRepository.skipNextForTask` | occurrences | ❌ SELECT → UPDATE（237-248） | 返回 1 但实际未更新（DAT-17） |
| 17 | `OccurrenceRepository.deletePendingQuietExempt` | occurrences | 单语句 | 无 |
| 18 | `LogRepository.append` / `appendMany` | exec_logs | 单语句 / ✅ batch | 无 |
| 19 | `LogRepository.purgeOlderThan` | exec_logs | 单语句，**无 LIMIT** | 长写锁 |
| 20 | `CounterPlanService.apply` | tasks +（级联）occurrences + prefs | ❌ **三个独立事务**（96-100） | 计划整族消失 / 历史丢失 / 跨存储错配（DAT-04、DAT-18） |
| 21 | `CounterPlanService.disable` | tasks + prefs | ❌ 两个独立操作 | prefs 写失败 ⇒ 任务已删但 `enabled` 仍 true |
| 22 | `endpoint._upsertTask` | tasks + occurrences | ❌ **三个独立事务**（1946-1948） | 任务已改、计划已删、新计划写入失败 ⇒ 任务静默不响（DAT-05） |
| 23 | `endpoint._deleteTask` | tasks + occurrences | ❌ 两条语句（1993-1994） | 无害（第二条被级联清空） |
| 24 | `endpoint.task.toggle` | tasks + occurrences | ❌ 三条语句（1242-1248） | 末尾显式 `replan()` 可自愈（若引擎在跑） |
| 25 | UI 单条/批量/整包删除 | tasks + occurrences | ❌ Dart 循环逐条删（task_list_screen:123-124、241-243、783-786） | 部分成功（DAT-15） |
| 26 | `guard_screen._persist` | sound_profiles | 单语句 `REPLACE` | 无 |
| 27 | `AppDatabase.kvSet` | kv | 单语句 `REPLACE` | 无 |
| 28 | `RemoteStore.addPaired/removePaired/revoke/touchPaired/renamePaired/saveScript/enqueue/drainOutbox/removeOutbox` | prefs 单个 JSON 键 | ❌ 读-改-写（无锁） | 并发丢更新 / 坏数据整表清空（DAT-09、DAT-18） |

> 注：`_persistActive`（vibrate_session）写 `kv.vibrate_active` 也是读-改-写，但只有引擎一个写者，风险低。

---

## 4. 序列化字段对齐矩阵

图例：✅ 对称；⚠ 需要外层补偿/存在陷阱；🚫 刻意不对称。

### 4.1 `Task` / `PlannedOccurrence`（`lib/domain/models/task.dart`）

| 字段 | 写（`toRow`） | 读（`fromRow`） | 对称 |
|---|---|---|---|
| id / name / cooldown_sec / priority | 原值 | 原值 | ✅ |
| enabled | `1/0` | `==1` | ✅ |
| trigger_type / action_type | `enum.name` | `values.byName`（**未知值抛**） | ✅ |
| trigger / trigger_json | ⚠ `toRow()` 写的是 **`Map`**（112-119），不是 String | 接受 `Map` 或 JSON String（165-170） | ⚠ DAT-12 |
| action / action_json | ⚠ 同上（Map） | 同上 | ⚠ DAT-12 |
| asset_ids | ⚠ `toRow()` 写 **`List<String>`**（120） | 接受 List 或 JSON String（173-179） | ⚠ DAT-12 |
| quiet_policy | `enum.name` | `values.byName` | ✅ |
| quiet_exempt | 三值 → 0/1/2（125-129） | 0/1/2 → null/true/false（152-156） | ✅（但迁移语义见 DAT-01） |
| force_run | `1/0` | `==1`，缺列回落 false | ✅ |
| condition_json | `jsonEncode(...)` 或 null | `TaskCondition.fromJsonOrNull` | ✅ |
| created_at / updated_at | epoch ms | `fromMillisecondsSinceEpoch` | ✅ |
| `PlannedOccurrence.fireAt` | epoch ms | epoch ms | ✅（注释"本地时区 UTC 毫秒"措辞含糊，但值是 UTC 瞬时，正确） |
| `PlannedOccurrence.volume` | double? | `(as num?)?.toDouble()` | ✅ |
| `PlannedOccurrence.status` | `enum.name` | `values.byName`（**未知值抛**） | ✅ |

### 4.2 `TriggerConfig`（`trigger.dart`）

| 类型 | 写 | 读 | 对称 |
|---|---|---|---|
| FixedOnce | `at.toIso8601String()`（**本地墙钟、无偏移**） | `DateTime.parse`（按当前本地时区解释） | ⚠ DAT-10 |
| Daily / Weekly | `time{hour,minute}` + `dateRange{yyyy-MM-dd}` | 同构；`weekdays` Set↔List（顺序丢失，语义无损） | ✅ |
| RandomWindow | `dateRange/windowStart/windowEnd/timesPerDay/minGapSec/windowEndNextDay` | 全部读取 | ✅ |
| RandomInterval | `minGapSec/maxGapSec/activeStart/activeEnd/maxPerDay` | 全部读取（active* 缺省有回落） | ✅ |
| Sound | 4 字段 | 4 字段 | ✅ |
| 未知 `kind` | — | `throw ArgumentError`（100） | 见 DAT-02 |

### 4.3 `ActionConfig`（`action.dart`）

10 个子类逐一比对，**字段全部对称**（含 `PlayAudioAction` 的 10 项、`RandomVibrateAction`/`ContinuousVibrateAction` 的 `respectDnd`、`CompositeAction.prefixNotify` 可空、`SoundscapeTrack` 的 `presetCategory|assetId` 二选一、`ActionSetCandidate.weight`）。
唯一"不对称"是**有意的归一化**：`fromJson` 会夹紧/交换区间（BUG-123），因此 `toJson→fromJson` 对**非法输入**不是恒等映射（对合法输入恒等）。`TtsAction.toJson` 写 `channel.name`，`fromJson` 只判 `=='alarm'`，两者一致。

### 4.4 `CounterPlan` / `CounterPlanParams` / `CounterWindow` / `PlanWindowParams`

逐字段核对：`schema/name/version/dayStartHour/dayEndHour/cooldownSec/respectQuietHours/workday.{day,night}/restday.{day,night}/presetIds/ttsTexts/voiceId/scheduleMode/occurrenceCount/spanDays/specificDate/rangeStart/rangeEnd/weekdays` —— **写读完全对称**；`CounterPlanParams` 多出 `cooldownSecMin/Max`，同样对称。`fromJson` 永不抛（容错），`toJson` 不写 null 字段（`specificDate` 等），读侧按 null 处理 —— 一致。
`CounterPlan.version` 写入后 `validate()` 只校验 `>=1`，无版本分派逻辑（`schema` 才是真正的版本闸）。

### 4.5 prefs 侧模型

| 模型 | 对称性 |
|---|---|
| `PairedEndpoint` | ✅（`alias`/`lastConnectedAt` 为 null 时不写，读侧回落） |
| `SavedScript` | ✅ |
| `GuardOrchestration` | ✅（容错 decode） |
| `CounterPlanStore` 各键 | ✅（JSON 文本 + 容错） |
| `ApiConfigStore` | ✅（"从未配置"vs"显式空串"语义靠 `containsKey` 区分，实现正确） |
| outbox 条目 | ✅（`expiresAt` 缺省 = 无 TTL，兼容旧数据） |

### 4.6 刻意不对称（不算缺陷，但需登记）

1. `TaskWire.toWire` 出站带 `quietExempt` / `forceRun`，`fromWire` 入站**一律丢弃**（`task_wire.dart:242-263`）——授权不随数据走，符合红线。
2. 备份导出**不写** `quiet_exempt`、**不写** `updated_at`；导入 `enabled=false`、`updated_at=now`（`settings_screen.dart:104-131`、`261-292`）。后果：**恢复备份会改变计划种子**（`_seedKey` 用 `updatedAt`），随机窗口任务会重采样出另一批时刻 —— 可接受但属于"往返非恒等"。

---

## 5. 缺陷条目

### DAT-01 迁移把 `tasks.quiet_exempt` 从"开关"重解释为"三态覆盖"，老库用户的免打扰护栏被静默放宽

Severity: P1
Evidence Status: CONFIRMED（代码/历史版本可证）；业务影响 HIGH_CONFIDENCE

Affected Files/Lines:
- `lib/data/db/app_database.dart:200-221`（v4 只补列，不回填）
- `lib/domain/models/task.dart:44-57, 125-129, 149-156`（三态语义）
- 历史版本 `git show ca6c180:lib/data/db/app_database.dart`（v3 语义："默认 0 = 不豁免；主开关另存于 kv，**两者皆开才放行**"）
- `lib/domain/scheduling/schedule_engine.dart:184-192`（`exempt = taskExemptOverride ?? allowQuietExempt`）

Expected Behavior: 迁移后老任务的夜间豁免行为与升级前一致；护栏的任何放宽都必须是用户显式操作。

Actual Behavior: v3 时代 `quiet_exempt` 是**布尔开关**，判据为 `master && task`。v79 把它改成**三态覆盖**，判据变为 `task ?? master`。迁移只补列（值全为 0），没有回填，于是：
- 老行 `quiet_exempt=0` → 新语义 `null`（跟随主开关）。若用户当时**开着主开关**，这些任务从"不豁免"变成"**豁免**"；
- 老行 `quiet_exempt=1` → 新语义 `true`（强制豁免）。即使主开关关闭也豁免（升级前必须主开关开才豁免）。

两条路径都**单向放宽**了 22:00–07:00 的免打扰护栏。迁移注释只论证了 `主开关默认 false` 的情形（`app_database.dart:205-207`），漏掉了"主开关已开"的存量用户。

Trigger Conditions: 用户曾在 v1.9.0-alpha ~ v1.9.x 之间打开过「夜间豁免主开关」并升级到当前版本。

Forward Call Chain: `AppDatabase.open` → `_onUpgrade(v3→v4)` → `_addIntColumnIfMissing` → （无回填）→ `TaskRepository.listAll` → `Task.fromRow(quiet_exempt:0→null)` → `ScheduleEngine.materialize` → `_applyQuiet(exempt = null ?? master)` → 夜间计划不再被 skip。

Reverse Call Chain: `background_engine.replan()`（`background_engine.dart:1275` 读 `PrefsKeys.quietExemptMaster`）→ `occs.reconcile` → `executeDue` → `runAction`（夜间出声）。

Data Flow / State Transition: DB `tasks.quiet_exempt=0`（旧语义"关"）→ 内存 `null`（新语义"跟随"）→ `exempt=true`（master 开）→ occurrence 以 `quiet_exempt=1` 落库 → 夜间执行 + 写 `action='quietExempt'` 审计。

Evidence:
```dart
// app_database.dart:218-221（只补列）
if (oldV < 4) {
  await _addIntColumnIfMissing(db, 'tasks', 'quiet_exempt');
  await _addIntColumnIfMissing(db, 'occurrences', 'quiet_exempt');
}
// task.dart:152-156
quietExempt: switch (r['quiet_exempt'] as int? ?? 0) {
  1 => true,
  2 => false,
  _ => null,   // ← 0 被解释为"跟随主开关"
},
```

Reproduction Steps:
1. 用 v1.9.0-alpha 建库，主开关 `quiet_exempt_master=true`，任务 A 的 `quiet_exempt=0`；
2. 升级到 1.9.9+32；
3. 任务 A 的 `fire_at` 落在 22:00–07:00 —— 升级前被 skip，升级后照常执行。

Root Cause: 语义迁移（bool → 三态）缺少数据回填，且迁移注释只覆盖了主开关默认值的情形。

Alternative Hypotheses: 产品可能"有意"把老行当作"跟随主开关"（因为默认值 0 恰好对应新语义的默认值）。但代码注释明确声称"行为与升级前一致"，说明这是遗漏而非决策。

Business Impact: 免打扰护栏（合规红线之一）在存量用户上静默失效，夜间可能突然出声/振动；用户无法从 UI 看出"这是升级带来的"。

Recommended Fix: 在 v6 迁移中按"升级前语义"回填：对 `oldV<79` 的库，把 `quiet_exempt` 统一改写为 `2`（强制不豁免）或 `0`+强制主开关快照语义，并在设置页提示一次；或在 `_onUpgrade` 中写一条 `exec_logs` 审计说明"夜间豁免语义已变更"。

Regression Risks: 回填为 `2` 会让原本"主开关开即豁免"的用户失去豁免（收紧方向，安全但可能被投诉）；需配合一次性的 UI 告知。

Verification Tests: 造 v3 库（master=true、task.quiet_exempt∈{0,1}）→ 升到 v5 → 断言 `Task.quietExempt` 与 `_applyQuiet` 的放行结果与升级前一致（MIG-xx 回归锁）。

Remaining Uncertainty: 无法确认 v1.9.0-alpha 的 UI 是否允许"主开关开 + 任务关"这种组合被大量使用；实际受影响用户比例未知。

---

### DAT-02 `executeDue` 对单条坏任务行没有隔离：一条坏行会让整轮到期计划全部作废（最长 10 分钟）

Severity: P1
Evidence Status: CONFIRMED（代码路径）；触发需存在坏行（SUSPECTED 概率）

Affected Files/Lines:
- `lib/services/background_engine.dart:1518`（`tasksRepo.get(o.taskId)` 裸调用，无 try/catch）
- `lib/data/repositories/task_repository.dart:48-52`（`get()` 无行级兜底）
- `lib/domain/models/task.dart:138-163`（`byName` / `jsonDecode` 会抛）
- `lib/services/background_engine.dart:1487-1606`（`try { ... } finally` 无 `catch`）
- `lib/services/background_engine.dart:604-620`（`stepGuarded` 兜底，只留痕）

Expected Behavior: R90-09 的"单行损坏不得拖垮整表"应同样适用于执行路径：坏任务只跳过它自己的计划。

Actual Behavior: `listAll` 已做行级兜底，但 `get()` 没有。`executeDue` 的循环里 `await tasksRepo.get(o.taskId)` 一旦抛（未知 `trigger_type`/`action_type`、坏 `trigger_json`、缺 `required` 键），异常直接穿出 `for`，被 `stepGuarded` 捕获并写一条审计。**该轮剩余所有到期计划都不执行**；下一 tick 同一顺序再次抛（`due()` 按 `fire_at ASC`），直到 10 分钟后该条被"过期丢弃"分支标 skipped，整批才继续 —— 而这批里的其它条目此时也大多已过期（同样被标 skipped）。

Trigger Conditions: `tasks` 表存在任一行无法被 `Task.fromRow` 解析（旧版本写入的新 kind、手工改库、导入的半损坏 JSON、升级/降级混用），且该任务的 occurrence 已到期。

Forward Call Chain: `Timer.periodic(15s)` → `stepGuarded('executeDue(tick)')` → `executeDue` → `occs.due()` → `tasksRepo.get()` → `Task.fromRow` → `throw` → `stepGuarded` catch。

Reverse Call Chain: 用户编辑/远程下发/导入写入坏行 → `listAll` 静默跳过（`reportBadTaskRow` 只写日志）→ 该行永远留在库里 → 每次到期都毒丸。

Data Flow / State Transition: `occurrences.status=pending` →（未执行，异常）→ 仍 `pending` → 10 分钟后 → `skipped`。用户感知为"该响的没响，日志里只有一条 `executeDue(tick) failed`"。

Evidence:
```dart
// background_engine.dart:1518
final task = await tasksRepo.get(o.taskId);   // ← 可抛
// task_repository.dart:48-52
Future<Task?> get(String id) async {
  final rows = await _db.db.query('tasks', where: 'id = ?', whereArgs: [id], limit: 1);
  return rows.isEmpty ? null : Task.fromRow(rows.first);  // ← 无 try/catch
}
```

Reproduction Steps:
1. 手工把某任务的 `trigger_type` 改成 `unknownKind`（或用旧 APK 写入新 kind 后再升级）；
2. 让该任务的 occurrence 到期（或把 `fire_at` 改到当前时刻）；
3. 观察：该条与同轮其它到期条均不执行，`exec_logs` 出现 `action='executeDue(tick)' status='failed'`。

Root Cause: R90-09 只修了 `listAll`，漏了 `get()`；`executeDue` 的循环体缺少 per-item try/catch。

Alternative Hypotheses: 坏行在生产中是否常见？`TaskWire` 与编辑器都有校验，但 `settings_screen._importTasks` **不经过 TaskWire**（只做 `values.byName`），导入半损坏 JSON 即可制造坏行。

Business Impact: "所有任务突然不响"且只有一条技术性日志；比单条任务失效严重一个量级。

Recommended Fix: ① `TaskRepository.get` 内部 try/catch 并返回 null + `onRowError` 回调；② `executeDue` 的 for 体内包 per-item try/catch，失败只 `markStatus(failed)` + 审计。

Regression Risks: `get()` 返回 null 会被现有调用点当作"任务不存在"（`_upsertTask`、`runNow`、`_sendTask`），语义上可接受但需区分"不存在"与"损坏"的审计文案。

Verification Tests: 插入一行 `trigger_type='bogus'` 的任务 + 两条到期 occurrence（另一条属于正常任务），断言正常那条仍被执行。

Remaining Uncertainty: 未在真机验证"10 分钟后整批被跳过"的时序细节（取决于 `catchUpLimit=3` 与 tick 间隔）。

---

### DAT-03 "乐观置状态"不是 CAS：`markStatus` 不校验 `status='pending'` 也不检查影响行数，跨连接并发可重复执行同一 occurrence

Severity: P1
Evidence Status: HIGH_CONFIDENCE（代码事实 CONFIRMED；双实例并发为条件）

Affected Files/Lines:
- `lib/data/repositories/occurrence_repository.dart:171-182`（`markStatus` 返回 `Future<void>`，丢弃 update 的行数）
- `lib/services/background_engine.dart:1562-1572`（"乐观置状态"注释 + `markStatus(o.id, failed)`）
- `lib/services/background_engine.dart:1911`（注释声称"由 `executing` + 数据库乐观置状态兜住"）
- `lib/data/db/app_database.dart:36-55`（`singleInstance:false` ⇒ 两个引擎各持一条连接）

Expected Behavior: 取走一条 pending 计划应是原子 CAS：`UPDATE ... SET status='failed' WHERE id=? AND status='pending'`，并据 `affected==1` 决定是否执行。

Actual Behavior: 实现是 `SELECT`（`due()`）→ 无条件的 `UPDATE ... WHERE id=?`。两条连接（两个引擎实例）同时 `due()` 会拿到同一批行，两者都"置状态成功"，两者都执行 —— **同一计划播两次**。`markStatus` 连 `update()` 的返回值都丢掉了，调用方无从判断自己是否抢到。

Trigger Conditions: 原生精确闹钟唤醒"第二份服务"与通道 A 的 15s tick 并发（代码注释自己承认这种并发存在：`background_engine.dart:446`、`1911`）；或引擎被系统重启期间新旧两个实例短暂并存。

Forward Call Chain: 两份引擎实例各自 `executeDue` → `occs.due(now, limit:3)` → 同一批 rows → `markStatus(failed)` → `runAction`（播放/振动/TTS）→ `markStatus(terminal)`。

Reverse Call Chain: 原生 `AlarmManager` 唤醒 → `BackgroundService` 启动 → `_engineBody` → tick 注册；同时旧实例尚未 `stopSelf`。

Data Flow / State Transition: `pending` → 两个写者都认为"我把它标成 failed 了" → 两次 `runAction` → 最终 `done`（后写覆盖）→ 审计只有一条 done，实际响了两次。

Evidence:
```dart
// occurrence_repository.dart:171-182
Future<void> markStatus(String id, OccurrenceStatus status, {...}) =>
    _db.db.update('occurrences', {...}, where: 'id = ?', whereArgs: [id]); // 无 status 条件、无返回值

// background_engine.dart:1571
await occs.markStatus(o.id, OccurrenceStatus.failed);   // 注释称其为"第二道防线"
```

Reproduction Steps: 两个 isolate 同时 `await occs.due(now)`，各取一条相同 id，再各自 `markStatus` 并 `runAction` —— 两次都会执行（可用内存库 + 两个 AppDatabase 实例复现）。

Root Cause: 把"UPDATE 成功"误当成"我抢到了"，但 UPDATE 没有前置状态条件。

Alternative Hypotheses: 若产品保证"任何时刻只有一个引擎实例"，则风险降为 P3；但 `singleInstance:false` + 原生闹钟唤醒路径使这一保证不成立（代码注释明确提到"第二份服务"）。

Business Impact: 重复出声/重复振动（用户最反感的失败形态），审计与事实不符（无法事后判定是否双响）。

Recommended Fix: `markStatus` 增加 `onlyIfStatus` 参数并返回 `int`；执行前用 `UPDATE ... WHERE id=? AND status='pending'`，`affected==0` 即跳过。终态覆盖用同样的 `WHERE status='failed'`（区分"自己抢到的"与"别人改的"）。

Regression Risks: 现有"先标 failed 再按真实结果覆盖"的写法需要改成两段 CAS，`skipped` 分支（暂停/条件/概率）也要改成 CAS 以避免与执行路径互相覆盖。

Verification Tests: 并发两个 `executeDue`（两个连接）对同一条 pending，断言 `runAction` 只被调用一次。

Remaining Uncertainty: 未在真机抓到"双实例并存"的日志证据；该场景的时间窗可能很短。

---

### DAT-04 `CounterPlanService.apply(replace:true)` 用"整族删除 + 批量插入"两个独立事务，失败即丢整套计划，且级联抹掉历史

Severity: P1
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/services/counter_plan_service.dart:96-100`（`deleteCounterTasks` → `upsertMany` → `savePlan`，三步各自独立）
- `lib/data/repositories/task_repository.dart:204-208`（`deleteCounterTasks` 单语句删除，级联 occurrences）
- `lib/data/db/app_database.dart:150-158`（`occurrences.task_id ... ON DELETE CASCADE`）
- 同文件 `counter_plan_service.dart:161-171` 的注释已经承认"`deleteCounterTasks` 连已执行的历史任务一起删"是不可接受的数据损失

Expected Behavior: "替换一个计划的全部任务"应是一个原子操作：要么新任务全在，要么旧任务全在。

Actual Behavior: 删除先提交；随后 `upsertMany` 若失败（磁盘满、`database is locked`、进程被杀、`tasks` 表约束错误），**旧计划已被删光、新计划一条没写**。调用方拿到异常，用户看到"应用失败"，但反击计划已经整体消失，直到下一次 `apply`/`refreshIfNeeded`。同时 `deleteCounterTasks` 经外键级联删掉这些任务的**全部 occurrence 历史**（done/failed/skipped），而 `exec_logs` 里的记录因无外键而保留 —— 审计出现"日志说有执行、计划表里查不到"的断裂。

Trigger Conditions: 用户编辑/重新导入/启用反击计划（`replace` 默认 true），且第二条语句失败。

Forward Call Chain: 设置页/AI 生成/远程 `plan.apply` → `CounterPlanService.apply(replace:true)` → `deleteCounterTasks` → `upsertMany`。

Reverse Call Chain: `providers.counterPlanServiceProvider` → 设置页按钮；`endpoint_service._applyRemotePlan`；`background_engine.extendCounterPlan`（此处 `replace:false`，安全）。

Data Flow / State Transition: `tasks(counter:*)` N 行 → DELETE（+ 级联 occurrences）→ INSERT 失败 → 0 行。`prefs.counter_plan_enabled` 仍为 true（`savePlan` 未执行到）→ UI 显示"已启用"，实际零任务。

Evidence:
```dart
// counter_plan_service.dart:96-100
if (replace) await _tasks.deleteCounterTasks(id);   // 事务 1（含级联删除历史）
await _tasks.upsertMany(tasks);                     // 事务 2
await _store.savePlan(plan, id: id, enabled: true);// 事务 3（prefs）
```

Reproduction Steps: 在 `upsertMany` 前注入异常（或让 batch 里某行违反 NOT NULL），观察 `tasks` 中 `counter:{id}:*` 全空、`prefs.counter_plan_enabled=true`。

Root Cause: 跨仓储的"删+建"没有共享事务；`TaskRepository` 未暴露事务句柄，服务层无法把三步合并。

Alternative Hypotheses: 也许产品接受"重建"语义（旧任务本来就该消失）。但"失败后旧任务也消失"不是重建语义，而是数据丢失。

Business Impact: 反击计划静默失效（用户以为在反击，实际一条都不排）；历史执行记录不可逆丢失，冷却基准 `lastDoneFor` 归零。

Recommended Fix: 在 `TaskRepository` 暴露 `Future<T> inTransaction<T>(...)`，把 `deleteCounterTasks` + `upsertMany` + `savePlan` 包进同一事务（prefs 无法入事务，可改为"先写 prefs 的 pending 标记，DB 成功后再提交"）；或改为"先算新 id 集合 → upsert 新增 → 删除不在新集合里的旧 id"（无空窗）。

Regression Risks: 事务内混入 prefs 写入会拉长写锁时间；需要把 prefs 写移到事务之后并接受"DB 成功、prefs 失败"的窄窗口（配合启动自愈）。

Verification Tests: 让 `upsertMany` 抛错，断言 `counter:{id}:*` 任务数量不变。

Remaining Uncertainty: 未量化真实设备上该窗口被命中的概率（需要 `database is locked` 或进程被杀）。

---

### DAT-05 远程 `task.upsert` 的三段写（upsert → 删旧计划 → 物化新计划）非原子，且失败后**不会被全局续算自愈**

Severity: P1
Evidence Status: CONFIRMED（代码路径）；触发需一次写失败

Affected Files/Lines:
- `lib/remote/endpoint_service.dart:1946-1948`（三段写）
- `lib/remote/endpoint_service.dart:2130-2168`（`_rematerialize` → `commitAll`）
- `lib/services/background_engine.dart:2313-2321`（续算判据只看**全局** `latestPendingFireAt`）
- `lib/data/repositories/occurrence_repository.dart:119-127`（`MAX(fire_at)` 全表聚合）

Expected Behavior: 远程改任务后，任务定义与新计划要么都生效，要么都不生效；最坏也应在下一次 tick 被修复。

Actual Behavior: 若 `commitAll` 抛错（`BEGIN IMMEDIATE` 等锁超时、磁盘满），任务行已更新、旧 pending 已删、新 pending 一条没有。此后引擎的续算判据是"**全局**最晚 pending 是否进入 12h 阈值"——只要其它任务（尤其反击计划动辄数百条）把覆盖维持在 48h，`planNeedsExtend` 恒为 false，**这个任务永远不会被重新物化**，直到别的任务让全局覆盖掉到阈值内（稳态约 36h 一次）。表现：远程改完任务，回执"失败"，然后该任务**长期不响**。

Trigger Conditions: 远程 `task.upsert` 期间引擎正在跑 `reconcile`（长事务），`busy_timeout=5000` 超时；或任意一次 `commitAll` 失败。

Forward Call Chain: 对端 `task.upsert` → `endpoint_service._handleRaw` → `_upsertTask` → `tasks.upsert` → `occ.deletePendingForTask` → `_rematerialize` → `occ.commitAll`。

Reverse Call Chain: 引擎 tick → `latestPendingFireAt`（其它任务覆盖仍充足）→ `planNeedsExtend=false` → 不 replan → 该任务保持 0 条计划。

Data Flow / State Transition: `tasks.updated_at` 已变 → `occurrences` 该任务 0 行 → `due()` 永远取不到它 → 无声。

Evidence:
```dart
// endpoint_service.dart:1946-1948
await tasks.upsert(task);
final dropped = await occ.deletePendingForTask(task.id);
final planned = await _rematerialize(task, occ);   // ← 抛错即留下"无计划"任务
```

Reproduction Steps: 在 `_rematerialize` 的 `commitAll` 处注入 `DatabaseException`，观察该任务 `SELECT COUNT(*) FROM occurrences WHERE task_id=?` 为 0，且连续 10 个 tick 后仍为 0。

Root Cause: 跨仓储多步写无事务；续算判据是全局聚合，无法发现"单任务零计划"。

Alternative Hypotheses: 若 `task.upsert` 的调用方在异常后重试整条命令（控制端有重试？），则可自愈。未在 `controller_service` 中找到针对 `task.upsert` 的自动重试。

Business Impact: 远程运维最常用的"改任务"操作可能造成目标设备长期静默不执行，且回执与真实状态不一致。

Recommended Fix: ① 把"删旧计划 + 写新计划"合并为一个 `OccurrenceRepository.replacePendingForTask(taskId, entries, now)`（单事务）；② 续算判据补一条"存在 enabled 且非 sound 的任务在未来 12h 内零 pending ⇒ 需要 replan"的查询（可复用 `nextPendingByTask`）。

Regression Risks: 新增判据会增加 replan 频率（每 tick 一次 GROUP BY），需限制为"每 N 轮"或加索引。

Verification Tests: 注入 `commitAll` 失败 → 断言任务仍有旧计划（事务回滚）或下一次 tick 被修复。

Remaining Uncertainty: 未验证控制端在 `ok=false` 时是否自动重发。

---

### DAT-06 `TaskRepository.removeAssetRef` 是"读全表 → 批量覆盖"，并发写会丢失更新

Severity: P2
Evidence Status: CONFIRMED

Affected Files/Lines: `lib/data/repositories/task_repository.dart:146-165`

Expected Behavior: 删除音源时只摘掉该 id，不覆盖同一任务上并发发生的其它 `asset_ids` 变更。

Actual Behavior: 先 `SELECT id, asset_ids` 全表，再在 Dart 侧过滤，然后用**旧快照**整列覆盖。若在此期间（同一进程的 UI 或另一引擎）对该任务执行了 `upsert`（例如用户刚在编辑器里加了新音源），`asset_ids` 会被回退成"快照 - 被删 id"，**新加的音源引用丢失**。

Trigger Conditions: 删除音源与编辑任务并发（删除按钮与保存按钮几乎同时、或引擎侧远程 `task.upsert` 落库）。

Forward Call Chain: `sound_library_screen._deleteAsset` → `repo.delete` → `TaskRepository.removeAssetRef`。

Reverse Call Chain: `task_editor_screen` 保存 → `TaskRepository.upsert`（同一 `tasks` 行）。

Data Flow / State Transition: `asset_ids=[a1]` →（并发 upsert 为 `[a1,a2]`）→ `removeAssetRef(a1)` 用旧快照写回 `[]` → a2 引用丢失。

Evidence:
```dart
// task_repository.dart:148-163
final rows = await _db.db.query('tasks', columns: ['id', 'asset_ids']);
...
batch.update('tasks', {'asset_ids': jsonEncode(ids.where((x) => x != assetId).toList())},
    where: 'id = ?', whereArgs: [r['id']]);
```

Reproduction Steps: 内存库上先 `upsert(t with assetIds=[a1])`；并发 `upsert(t.copyWith(assetIds:[a1,a2]))` 与 `removeAssetRef(a1)`，最终 `asset_ids` 为空而非 `[a2]`。

Root Cause: 读-改-写跨两条语句、无事务、无版本条件。

Alternative Hypotheses: 若产品保证删除音源时无人编辑任务，则影响可忽略；但远程 `task.upsert` 不受 UI 控制。

Business Impact: 任务静默少一个音源（`pickAssetFor` 从更小的池里挑），表现为"随机性变差"而非报错，极难排查。

Recommended Fix: 改为单事务 + `SELECT ... WHERE asset_ids LIKE ?` 后再逐行 UPDATE（仍在事务内），或直接 `UPDATE tasks SET asset_ids = ? WHERE id = ? AND asset_ids = ?`（乐观并发，失败重读重试）。

Regression Risks: 事务化后与引擎的长事务竞争，可能增加 `database is locked`。

Verification Tests: 并发用例断言不丢 `a2`。

Remaining Uncertainty: 无。

---

### DAT-07 `occurrences` 缺 `task_id` 索引：`lastDoneFor` 等按任务查询全表扫描，声音事件路径是 O(任务数 × 计划数)

Severity: P2
Evidence Status: CONFIRMED（EXPLAIN 未跑，但 SQL 与索引定义可判定）

Affected Files/Lines:
- `lib/data/db/app_database.dart:159-162`（只有 `fire_at` / `status` 两个单列索引）
- `lib/data/repositories/occurrence_repository.dart:202-212`（`lastDoneFor`：`task_id=? AND status='done' ORDER BY fire_at DESC LIMIT 1`）
- 同文件 `191-199`（`allForTask`）、`222-223`（`deleteForTask`）、`229-233`（`deletePendingForTask`）、`237-248`（`skipNextForTask`）
- `lib/services/background_engine.dart:1683-1688`（声音事件里对**每个**声音任务调用 `lastDoneFor`）

Expected Behavior: 按 `task_id` 的查询走索引。

Actual Behavior: 无 `(task_id)` 前缀索引 ⇒ 每次 `lastDoneFor` 都是全表扫描 + 排序。`onSoundEvent` 对每个声音触发任务各调一次，声音事件频繁时（守卫常开）开销随 `occurrences` 行数线性增长；`reconcile` 里的 `DELETE ... WHERE task_id=?` 同理。

Trigger Conditions: `occurrences` 行数增长（反击计划 7 天 × 多任务可达数千行）+ 守卫常开。

Forward Call Chain: `SoundGuardService` 事件 → `onSoundEvent` → 循环 `occs.lastDoneFor(t.id)`。

Reverse Call Chain: `ScheduleEngine.materialize` → `reconcile` 插入行；`purgeOlderThan` 仅保留 7 天。

Data Flow / State Transition: 表行数 ↑ → 单次事件查询成本 ↑ → 引擎 tick 变慢（15s 周期内做不完）。

Evidence:
```sql
CREATE INDEX IF NOT EXISTS idx_occ_fire ON occurrences(fire_at);
CREATE INDEX IF NOT EXISTS idx_occ_status ON occurrences(status);
-- 缺：CREATE INDEX idx_occ_task ON occurrences(task_id, status, fire_at);
```

Reproduction Steps: 灌 5000 行 occurrences（多任务），`EXPLAIN QUERY PLAN SELECT ... WHERE task_id=? AND status='done' ORDER BY fire_at DESC LIMIT 1` → `SCAN occurrences`。

Root Cause: 建表时只考虑了"按时间取到期"和"按状态筛"，漏了"按任务取最近一次"。

Alternative Hypotheses: 数据量小时无感（<1000 行），因此长期未被发现。

Business Impact: 引擎 tick 超时风险；低端机上表现为"声音触发延迟/漏触发"。

Recommended Fix: v6 迁移加 `CREATE INDEX IF NOT EXISTS idx_occ_task ON occurrences(task_id, status, fire_at)`。

Regression Risks: 写入略慢、库文件略大；迁移期建索引会短暂持写锁（数千行可接受）。

Verification Tests: `EXPLAIN QUERY PLAN` 断言 `SEARCH ... USING INDEX idx_occ_task`。

Remaining Uncertainty: 未测真实设备上的耗时。

---

### DAT-08 跨连接写冲突无任何重试；UI 侧 `AppDatabase.open` 也没有引擎那样的有界重试

Severity: P2
Evidence Status: HIGH_CONFIDENCE

Affected Files/Lines:
- `lib/data/db/app_database.dart:78-85`（`busy_timeout=5000`）
- `lib/core/providers.dart:28`（`databaseProvider` 无重试）
- `lib/services/background_engine.dart:273-284`（引擎有 1 次重试）
- 全部仓储写方法（无 retry 包装）
- sqflite：普通事务 `BEGIN IMMEDIATE`（`database_mixin.dart:407-422`）

Expected Behavior: 5s 等锁超时后应退避重试（尤其 `reconcile`/`purge` 这类长事务对端）。

Actual Behavior: `busy_timeout=5000` 是唯一防线；超时即抛 `DatabaseException(database is locked)`。`reconcile` 在事务内做 N 次 delete + M 次 insert（每语句约 1.5ms 平台往返），任务/计划多时单事务可轻易超过 1s；对端若同时写（UI 保存任务、远程 upsert、日志批量写），5s 内拿不到锁就失败。UI 侧首次开库若撞上引擎正在 `PRAGMA journal_mode=WAL` 或迁移，`databaseProvider` 会**缓存错误**（FutureProvider 不会自动重试），整页数据为空。

Trigger Conditions: 主 UI 保存任务 + 引擎 replan 同时进行；或引擎启动维护（`purgeOlderThan` 大删除）与 UI 写并发。

Forward Call Chain: UI 保存 → `TaskRepository.upsert` → `db.transaction` → `BEGIN IMMEDIATE` → BUSY。

Reverse Call Chain: 引擎 tick → `reconcile`（长事务持写锁）→ UI 侧等待。

Data Flow / State Transition: 写请求 → 等待 5000ms → 抛异常 → 调用方 catch 后提示失败（用户需手动重试）。

Evidence:
```dart
await db.rawQuery('PRAGMA busy_timeout = 5000');
// 仓储层：无任何 retry / backoff（grep "retry|is locked" 在 lib/data 下 0 命中）
```

Reproduction Steps: 两个连接，A 开事务并 `sleep(6s)`，B 执行 `upsert` → B 抛 `database is locked`。

Root Cause: 把 busy_timeout 当成"足够"，没有把"锁冲突"当作可恢复错误处理。

Alternative Hypotheses: 15s tick + 5s 超时的组合可能"实际上够用"；但 `purge` 与 `reconcile` 的时长没有上界。

Business Impact: 偶发"保存失败/计划未生效"，且失败文案是英文 SQLite 异常（`_snack('任务保存失败：$e')`）。

Recommended Fix: 在 `AppDatabase` 暴露 `runWithRetry`（3 次、指数退避 50/150/400ms，仅对 `SQLITE_BUSY`/`locked` 生效），仓储写方法统一走它；`databaseProvider` 改为带重试的打开。

Regression Risks: 重试会放大长事务的等待时间；需要给重试设总时长上限，避免 ANR。

Verification Tests: 并发写用例断言最终成功且不重复写（配合 DAT-03 的 CAS）。

Remaining Uncertainty: 未在真机复现 `database is locked` 的频率（R89 后已有 WAL，概率下降）。

---

### DAT-09 prefs 里的 JSON 列表"一条坏记录 ⇒ 整表清空"，且下一次写入会把清空结果**持久化**

Severity: P2
Evidence Status: CONFIRMED（代码）；影响 HIGH_CONFIDENCE

Affected Files/Lines:
- `lib/remote/remote_store.dart:372-382`（`paired()` catch → `<PairedEndpoint>[]`）
- 同文件 `384-397`（`addPaired` 基于 `paired()` 结果整体重写）
- 同文件 `422-431`（`revokedIds()` 损坏 → 空表 ⇒ 撤销名单失效）
- 同文件 `524-535`（`savedScripts()`）、`552-561`（`outbox()`）
- `lib/remote/remote_store.dart:57-69`（`PairedEndpoint.fromJson` 对 `deviceId`/`secret` 做裸 `as String`）

Expected Behavior: 单条记录损坏应只丢该条，其余保留；撤销名单损坏应 **fail-closed**（保守方向）。

Actual Behavior: `paired()` 用 `map(PairedEndpoint.fromJson)`，任一条缺 `deviceId`/`secret` 即抛 ⇒ 整个 catch 返回空列表 ⇒ "我的设备"全空；随后 `addPaired`/`touchPaired`/`renamePaired` 会把**空列表 + 新条目**写回 prefs ⇒ 其余配对**永久丢失**（不仅是显示问题）。`revokedIds()` 同理：损坏 → 空表 → 被撤销设备重新获得配对资格（安全方向错误）。`outbox()` 损坏 → 空表 → 下一次 `enqueue` 覆盖 → 所有待发命令静默消失（而 UI 写着"端点上线后自动执行"）。

Trigger Conditions: prefs 值被写坏（进程在 `setString` 中途被杀、系统存储异常、外部工具改 prefs）、或旧版本写入的字段缺失（如 `secret` 曾经可空）。

Forward Call Chain: `RemoteStore.paired()` → `device_list_screen` / `initialSelectedId` → 空列表。

Reverse Call Chain: `addPaired`/`touchPaired`/`renamePaired`/`removePaired` → `jsonEncode(list)` → `setString`（把丢失固化）。

Data Flow / State Transition: `rc_paired` = 3 条（1 条坏）→ 读出 0 条 → 用户重新配对 1 台 → 写回 1 条 → 另外 2 台授权消失。

Evidence:
```dart
try {
  return ((jsonDecode(raw) as List).cast<Map<String, dynamic>>())
      .map(PairedEndpoint.fromJson).toList();
} on Object {
  return <PairedEndpoint>[];   // ← 整表丢弃
}
```

Reproduction Steps: 手工把 `rc_paired` 改成 `[{"deviceId":"a","secret":"s","pairedAt":1},{"name":"bad"}]`，调用 `paired()` → `[]`；再 `addPaired(b)` → prefs 只剩 b。

Root Cause: 容错粒度选在"整个集合"而不是"单条"（与 R90-09 在 DB 侧学到的教训相反）。

Alternative Hypotheses: 作者可能认为"prefs 不会被写坏"；但 `setString` 非原子（SharedPreferences 在 Android 上先写内存再异步落盘，进程被杀时可能半写）。

Business Impact: 配对关系（授权）静默丢失，需重新扫码；待发远程命令丢失；撤销名单失效（安全）。

Recommended Fix: 逐条 try/catch（坏的跳过并计数，写一条审计/提示）；`revokedIds()` 损坏时返回"全部拒绝"的保守态；写回前保留原始损坏数据到 `*_corrupt_backup` 键以便人工恢复。

Regression Risks: 逐条容错会改变现有单测对"空表"的期望。

Verification Tests: 半损坏列表 → 断言好条目仍可读、写回后好条目仍在。

Remaining Uncertainty: 未统计线上 prefs 损坏的实际发生率。

---

### DAT-10 时间语义混用：触发器存"本地墙钟 ISO（无偏移）"，计划存"UTC 瞬时 epoch ms"，改时区/夏令时后两者不一致

Severity: P2
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/domain/models/trigger.dart:104-115`（`FixedOnceTrigger`：`at.toIso8601String()` / `DateTime.parse`）
- `lib/domain/models/trigger.dart:39-41`（`TimeSpec.on` 用 `DateTime(y,m,d,h,min)` 本地墙钟）
- `lib/domain/models/task.dart:207-220`（occurrence `fire_at` = `millisecondsSinceEpoch`）
- `lib/domain/scheduling/schedule_engine.dart:253-267`（日历推进已按"年月日+1"修过 DST）

Expected Behavior: 要么全部按"瞬时"存（epoch），要么全部按"墙钟"存并显式声明时区；两者不可混用。

Actual Behavior: 触发器是**墙钟语义**（"每天 08:00" 跟随用户本地时间，正确），落库却是无偏移的本地 ISO 字符串；`DateTime.parse` 在**读回时**用当时的本地时区解释。若用户换时区：
- `fixedOnce` 的绝对时刻会**平移**（"2026-11-01T08:00" 在 +8 区是 00:00Z，在 +9 区变成 23:00Z 前一天）——与"固定一次"的直觉相反；
- 已落库的 pending occurrence 是 epoch（绝对时刻），不会平移；直到一次 `reconcile` 才按新时区重算 —— 于是"改时区后第一次响的时刻"取决于有没有触发 replan，行为不确定。

Trigger Conditions: 用户跨时区旅行/手动改时区；或系统自动切换夏令时（触发器落在跳变的小时内）。

Forward Call Chain: `TaskRepository.upsert` → `jsonEncode(trigger.toJson())` → 写 `trigger_json`。

Reverse Call Chain: `Task.fromRow` → `TriggerConfig.fromJson` → `DateTime.parse`（当前时区）。

Data Flow / State Transition: 墙钟字符串 →（读）当前时区解释 → `DateTime` 本地 → `millisecondsSinceEpoch` → occurrence。

Evidence:
```dart
Map<String, dynamic> toJson() => {'kind': 'fixedOnce', 'at': at.toIso8601String()};
// at 为本地 DateTime 时 toIso8601String() 不带 'Z'/偏移
factory FixedOnceTrigger.fromJson(Map<String, dynamic> j) =>
    FixedOnceTrigger(at: DateTime.parse(j['at'] as String));
```

Reproduction Steps: 造 `fixedOnce` 于本地 08:00，导出 `trigger_json`（无偏移）；把设备时区 +1h 后重启 → 触发时刻变为本地 09:00。

Root Cause: 序列化时未显式声明时区（`toUtc().toIso8601String()` 或带偏移），读侧按"当前本地"解释。

Alternative Hypotheses: 产品可能**希望**墙钟语义（"每天早上 8 点"应跟随本地时间）——那么 `fixedOnce` 是唯一例外，应单独处理（存 epoch 或存带偏移的 ISO）。

Business Impact: 旅行/改时区后任务在错误的时刻响（或提前/延后一天）；`fixedOnce` 最明显。

Recommended Fix: 触发器 JSON 统一写 `at.toUtc().toIso8601String()`（带 `Z`），读侧 `DateTime.parse(...).toLocal()`；`dailyAt/weeklyAt` 保留墙钟但显式注释"墙钟语义"。对 `fixedOnce` 明确产品语义（墙钟 or 瞬时）并加迁移。

Regression Risks: 改序列化格式会让**旧数据**（无 Z）被按 UTC 解释 ⇒ 必须做一次迁移或兼容读（无 Z 时按本地、有 Z 时按 UTC）。

Verification Tests: 改 `TZ` 后 `materialize` 的时刻断言。

Remaining Uncertainty: 产品对 `fixedOnce` 的语义未在 docs 中明确（未找到明文）。

---

### DAT-11 保留策略只在引擎启动时跑一次；`purgeOlderThan` 无分批/无 LIMIT

Severity: P2
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/services/background_engine.dart:288-325`（仅 `_engineBody` 启动时调用 `RetentionMaintenance.run()`）
- `lib/services/retention_maintenance.dart:70-92`
- `lib/data/repositories/log_repository.dart:110-111`、`occurrence_repository.dart:215-219`（单条无 LIMIT 的 DELETE）

Expected Behavior: 按 docs/07 的 90 天/7 天策略持续清理，且清理不阻塞前台。

Actual Behavior: 只有引擎启动时才清理。用户若从不开启守护/调度（或长期不重启服务），`exec_logs` 无限增长。清理本身是一条无 LIMIT 的 `DELETE`，在积累数十万行时单语句持写锁数秒，与 UI 写并发会触发 DAT-08 的锁超时。

Trigger Conditions: 长期运行且引擎启动频率低；或日志表已膨胀后首次清理。

Forward Call Chain: `engineEntryPoint` → `_engineBody` → `RetentionMaintenance.run`。

Reverse Call Chain: 无其他调用点（grep 仅此一处）。

Data Flow / State Transition: `exec_logs` 行数单调上升 → 一次性大删除 → 写锁长时间占用。

Evidence:
```dart
logsRemoved = await logs.purgeOlderThan(t.subtract(Duration(days: logRetentionDays)));
// SQL: DELETE FROM exec_logs WHERE created_at < ?   —— 无 LIMIT、无分批
```

Reproduction Steps: 灌 200k 行过期日志，调用 `purgeOlderThan`，测量耗时与对并发写的影响。

Root Cause: 维护调度挂在"引擎启动"这个低频事件上；删除未分批。

Business Impact: 库文件膨胀（占用存储、备份变慢）；首次清理可能造成一次明显卡顿。

Recommended Fix: 改为 `DELETE ... WHERE rowid IN (SELECT rowid ... LIMIT 500)` 循环分批；把维护挂到"引擎启动 + 每日一次"（tick 里按日期判重）。

Regression Risks: 分批删除需要处理"删除过程中新写入"（按 `created_at < t` 固定上界即可）。

Verification Tests: 断言分批后总量正确、单批耗时可控。

Remaining Uncertainty: 未测真实设备上 200k 行删除的耗时。

---

### DAT-12 `Task.toRow()` 的列类型与 DB 声明不一致（Map/List vs TEXT），只靠仓储层覆盖，属高危陷阱

Severity: P2（当前无触发路径，但一处误用即崩溃）
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/domain/models/task.dart:112-136`（`trigger_json`/`action_json` 写 `Map`、`asset_ids` 写 `List`）
- `lib/data/repositories/task_repository.dart:55-60`（唯一补偿点：`...t.toRow()` 后覆盖三列）
- `lib/domain/models/task.dart:308-318`（`AudioAsset.toRow` 已正确 `jsonEncode`，说明两处口径不一致）

Expected Behavior: `toRow()` 的契约应是"可直接喂给 `db.insert` 的行映射"（`AudioAsset.toRow` 就是这样）。

Actual Behavior: `Task.toRow()` 返回的三列是内存对象；直接 `db.insert('tasks', t.toRow())` 会抛 `Invalid argument: type 'Map<String, dynamic>' is not a subtype of type 'String'`（或 sqflite 的 `ArgumentError`）。目前只有 `TaskRepository._row` 会补偿，任何新调用点（导入、测试夹具、未来的同步模块）都会踩。

Trigger Conditions: 新增任何直接用 `Task.toRow()` 写库的代码路径。

Forward Call Chain: `TaskRepository._row` → `...t.toRow()` → 覆盖三列 → `txn.update/insert`。

Reverse Call Chain: `Task.fromRow` 已兼容两种形态（`_decodeJson` 接受 Map/String），因此**读侧不会暴露问题**，只有写侧会。

Data Flow / State Transition: `Task` → `toRow()` →（若未覆盖）Map → SQLite 绑定失败。

Evidence:
```dart
// task.dart:117-120
'trigger_json': trigger.toJson(),   // Map
'action_json': action.toJson(),     // Map
'asset_ids': assetIds,              // List<String>
// task_repository.dart:56-59（补偿）
...t.toRow(),
'trigger_json': jsonEncode(t.trigger.toJson()),
'action_json': jsonEncode(t.action.toJson()),
'asset_ids': jsonEncode(t.assetIds),
```

Reproduction Steps: `db.insert('tasks', task.toRow())` → 抛错。

Root Cause: 领域模型承担了"行映射"职责，但实现按"内存对象"写；仓储层用覆盖打补丁。

Alternative Hypotheses: 无（这是明确的契约不一致）。

Business Impact: 潜在崩溃/数据写坏；增加新持久化路径时的隐性成本。

Recommended Fix: 把 `toRow()` 改成真正返回可绑定的行（三列 `jsonEncode`），删除仓储层的覆盖；或把 `toRow` 改名为 `toMemoryMap` 并只保留仓储层的 `_row`。

Regression Risks: 改 `toRow` 会影响测试夹具与 `TaskWire` 注释中的"与 Task.toRow() 同构"表述。

Verification Tests: 单测 `db.insert('tasks', t.toRow())` 成功。

Remaining Uncertainty: 无。

---

### DAT-13 `commitAll` 注释宣称"同 id 或同 fire_at+task 不重复"，实际只有 PK 去重（无 UNIQUE 约束）

Severity: P3
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/data/repositories/occurrence_repository.dart:12-20`（注释与 `ConflictAlgorithm.ignore`）
- `lib/data/db/app_database.dart:149-158`（`occurrences` 无 `UNIQUE(task_id, fire_at)`）

Expected Behavior: 注释所述的业务去重应被约束保证。

Actual Behavior: 只有 `id` PK 生效；不同 id 但相同 `(task_id, fire_at)` 的行可以并存。当前 id 生成规则（`{taskId}@{ms}`）让二者等价，因此暂无实际重复；但一旦有新的 id 方案（如远程 `@remote@`、守卫 `@sound@`、或将来改为 uuid），去重假设即失效。

Trigger Conditions: 新增任何"同刻不同 id"的写入路径。

Forward Call Chain: `reconcile`/`_rematerialize`/`runGuardPlan` → `commitAll` → `INSERT OR IGNORE`。

Reverse Call Chain: `due()` 会取到两行同刻计划 → 双执行（与 DAT-03 叠加）。

Data Flow / State Transition: 同 `(task_id, fire_at)` 两行 → 两次执行。

Evidence:
```dart
/// 幂等合并：同 id 或同 fire_at+task 的条目不重复写入。
Future<void> commitAll(List<PlannedOccurrence> list) async { ... ConflictAlgorithm.ignore ... }
```

Reproduction Steps: 插入 `(id:'x@1000', task:'x', fire_at:1000)` 与 `(id:'y@1000', task:'x', fire_at:1000)` → 两行都在。

Root Cause: 注释描述的是设计意图，schema 未落实。

Alternative Hypotheses: 也许"计划即审计"允许同刻多条（不同来源）。但那样注释应改。

Business Impact: 低（当前 id 规则自洽），但会误导后续维护者。

Recommended Fix: 加 `CREATE UNIQUE INDEX idx_occ_task_fire ON occurrences(task_id, fire_at)`（需先清理潜在重复），或修正注释。

Regression Risks: 唯一索引会让 `commitAll` 的 `OR IGNORE` 真正按业务键去重（行为变化需评估）。

Verification Tests: 唯一索引下的插入幂等性。

Remaining Uncertainty: 线上是否已存在重复行未知（无 DB 文件可查）。

---

### DAT-14 迁移只按"版本闸/列存在性"判断，缺少 schema 完整性校验；v1→v2 的 `ALTER` 非幂等

Severity: P3
Evidence Status: CONFIRMED（逻辑）；触发概率低（SUSPECTED）

Affected Files/Lines:
- `lib/data/db/app_database.dart:195-199`（`ALTER TABLE tasks ADD COLUMN condition_json`，无存在性检查）
- 同文件 `114-193`（`onCreate` 只在 `user_version==0` 跑）
- 同文件 `30-55`（无 `onOpen` 校验）

Expected Behavior: 打开库后应能保证"版本号对应的表/列齐全"。

Actual Behavior: ① v1 库若已含 `condition_json`（异常/手工），`ALTER` 抛 `duplicate column` ⇒ 迁移事务回滚 ⇒ **每次启动都失败**，应用无法进入；② 若 `user_version=5` 但某表被删（外部工具/半恢复的备份），`onCreate` 与 `onUpgrade` 都不会跑，后续查询全部 `no such table`，且**没有任何自愈**。

Trigger Conditions: 手工改库、跨版本恢复备份、root 设备清理。

Forward Call Chain: `AppDatabase.open` → `doOpen` →（版本相同则跳过迁移）→ 首次查询失败。

Reverse Call Chain: `databaseProvider` / 引擎 `_engineBody`。

Data Flow / State Transition: `user_version=5` + 缺表 → 所有仓储抛 `no such table` → 引擎 stepGuarded 每轮失败。

Evidence:
```dart
if (oldV < 2) { await db.execute('ALTER TABLE tasks ADD COLUMN condition_json TEXT'); }
// 无 PRAGMA table_info 检查（与 v4/v5 的做法不一致）
```

Reproduction Steps: 建 v1 库后手工加 `condition_json`，再升级 → 打开失败。

Root Cause: v1→v2 分支写于 `_addIntColumnIfMissing` 之前，未回头统一。

Alternative Hypotheses: 无。

Business Impact: 极少数设备会"应用打不开/白屏"，且日志只有 SQLite 错误。

Recommended Fix: v1→v2 也改用 `_addColumnIfMissing`；增加 `onOpen` 的轻量完整性检查（`PRAGMA table_info` 关键列，缺失则补建/提示）。

Regression Risks: 迁移逻辑统一后需重跑 MIG-01/02 回归锁。

Verification Tests: 造"v1 + 已有 condition_json"库，断言可打开。

Remaining Uncertainty: 无真实坏库样本。

---

### DAT-15 批量删除任务（单条/多选/整包）是 Dart 循环逐条删，非事务，失败后部分成功

Severity: P3
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/features/tasks/task_list_screen.dart:122-124`（整包）
- 同文件 `240-243`（批量）
- 同文件 `783-786`（单条菜单）

Expected Behavior: "删除 N 条"应原子，或至少回执如实说明"已删 M/N"。

Actual Behavior: `for (...) { await repo.delete(id); await occ.deleteForTask(id); }`，中途异常即跳出，前面的已删、后面的还在；提示语只说"批量删除失败：$e"，不告诉用户删了几条。`occ.deleteForTask` 因外键级联其实已冗余。

Trigger Conditions: 批量删除时某条失败（锁超时/行被并发删）。

Forward Call Chain: 长按多选 → `_batchDelete` → 循环。

Reverse Call Chain: `invalidateTaskDerivedCaches` + `replan`（部分删除后仍会重排，状态一致但用户预期不符）。

Data Flow / State Transition: 5 条 → 删到第 3 条失败 → 2 条已消失，3 条仍在。

Evidence:
```dart
for (final id in ids) {
  await repo.delete(id);
  await occ.deleteForTask(id);   // 级联已覆盖，此句冗余
}
```

Reproduction Steps: 在循环中让第 2 次 `delete` 抛错，观察列表剩 4 条。

Root Cause: 缺少 `TaskRepository.deleteMany(ids)`（单事务 + `WHERE id IN (...)`）。

Alternative Hypotheses: 无。

Business Impact: 用户看到"失败"但实际删了一部分，容易误判数据状态。

Recommended Fix: 新增 `deleteMany`（单事务 `DELETE FROM tasks WHERE id IN (...)`），UI 改调它；删除后统一 `replan` 一次。

Regression Risks: 无。

Verification Tests: 注入失败断言零删除。

Remaining Uncertainty: 无。

---

### DAT-16 `audio_assets` 无 `UNIQUE(name)`，"导入预置库"的幂等判据是 `nameSet()`（TOCTOU）

Severity: P3
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/data/db/app_database.dart:138-148`（无 UNIQUE）
- `lib/data/repositories/task_repository.dart:222-234`（`nameSet()` 读全表 name，再逐条 insert）
- `lib/services/preset_import.dart:157` 附近（批量写库）

Expected Behavior: 预置库导入按名字幂等（重复点两次不应重复 60 条）。

Actual Behavior: `nameSet()` 是"先读后写"，两次导入并发（或快速连点）都会读到旧集合 ⇒ 重复插入同名音源（id 不同）。表本身也不阻止同名。

Trigger Conditions: 连点"导入预置库"、或在导入过程中另一入口也触发导入。

Forward Call Chain: 设置/音源页 → `AssetLibraryImporter.importAll` → `existingNames()` → `upsertMany`。

Reverse Call Chain: `AssetRepository.listAll` → 列表出现重复项；`resolvePresetAudioIds` 命中多条。

Data Flow / State Transition: `nameSet` 不含 "x" → 两条并发导入各插入一条 "x"。

Evidence:
```dart
Future<Set<String>> nameSet() async {
  final rows = await _db.db.query('audio_assets', columns: ['name']);
  return rows.map((r) => r['name'] as String).toSet();
}
```

Reproduction Steps: 并发两次 `importAll` 同一批 → 同名两条。

Root Cause: 幂等判据在应用层且非原子；schema 无业务唯一键。

Alternative Hypotheses: 产品允许"同一首歌多份"（本地导入明确允许），所以 `UNIQUE(name)` 只能用于预置库（例如 `UNIQUE(name, tags)` 或加 `source` 列）。需要产品决策。

Business Impact: 音源库出现重复项，权重随机被放大；列表噪音。

Recommended Fix: 加 `source` 列 + `UNIQUE(name, source)`（预置库用），或把"预置导入"放进单事务内做 `INSERT ... WHERE NOT EXISTS`。

Regression Risks: 唯一索引需先清理历史重复。

Verification Tests: 并发导入断言条数不变。

Remaining Uncertainty: 是否有其它入口并发导入（未穷举）。

---

### DAT-17 `skipNextForTask` 是 SELECT → UPDATE，无事务/无条件，返回值可能与事实不符

Severity: P3
Evidence Status: CONFIRMED

Affected Files/Lines: `lib/data/repositories/occurrence_repository.dart:237-248`

Expected Behavior: "跳过下一次"应恰好跳过一条并如实返回。

Actual Behavior: 两次并发调用（UI 点击 + 远程 `task.skipNext`）会读到同一行，各自 `markStatus(skipped)` 后都返回 1；实际只跳了一条，另一条"下一次"并未被跳。`markStatus` 不带 `status='pending'` 条件，也无法察觉重复。

Trigger Conditions: 同一任务在极短时间内被本地与远程同时"跳过下一次"。

Forward Call Chain: `task_list_screen:685` / `endpoint_service:1280` → `skipNextForTask`。

Reverse Call Chain: `markStatus` → `UPDATE ... WHERE id=?`。

Data Flow / State Transition: 一行 pending → skipped；第二次调用同样返回 1。

Evidence:
```dart
final rows = await _db.db.query(... limit: 1);
if (rows.isEmpty) return 0;
await markStatus(rows.first['id'] as String, OccurrenceStatus.skipped);
return 1;
```

Reproduction Steps: 连续两次调用（不 await 第一次）→ 两次都返回 1。

Root Cause: 读-改-写非原子。

Alternative Hypotheses: 影响极小（只是回执数字不准），故列 P3。

Business Impact: 回执误导控制端；用户以为跳过了两次。

Recommended Fix: `UPDATE ... WHERE id = (SELECT id ... LIMIT 1) AND status='pending'`，按 `affected` 返回 0/1。

Regression Risks: 无。

Verification Tests: 并发调用断言总返回 1。

Remaining Uncertainty: 无。

---

### DAT-18 `CounterPlanStore` 三键写入 + DB 任务写入跨存储无一致性协议，planId 错配会产生"删不掉的孤儿任务"

Severity: P3
Evidence Status: HIGH_CONFIDENCE

Affected Files/Lines:
- `lib/data/repositories/counter_plan_store.dart:78-85`（`savePlan` 依次写 plan JSON / planId / enabled）
- `lib/services/counter_plan_service.dart:96-100`（DB 写完才写 prefs）
- `lib/services/counter_plan_service.dart:113-119`（`disable` 先删任务再置 false）
- `lib/services/counter_plan_service.dart` 顶部注释："`planId` 决定任务 id 命名空间…重启后若 planId 变了，旧任务会全部变成回不来的孤儿"

Expected Behavior: `tasks` 与 `prefs.planId` 必须同生共死。

Actual Behavior: `apply` 用**新** `planId` 建任务，最后才把 `planId` 写进 prefs。若在 `upsertMany` 之后、`savePlan` 之前进程被杀（或 prefs 写失败），库里已有一整套 `counter:{newId}:*` 任务，而 prefs 仍是旧 `planId` ⇒ 下一次 `disable`/`apply` 只按旧前缀删除，新命名空间的任务**永远删不掉**且继续按旧计划触发。

Trigger Conditions: 应用在"任务已写、prefs 未写"的窗口内被杀（导入大计划 + 后台被杀）。

Forward Call Chain: `apply` → `upsertMany` → `savePlan`。

Reverse Call Chain: `disable` → `deleteCounterTasks(store.planId)`（旧 id）→ 删不到。

Data Flow / State Transition: `tasks` 有 `counter:B:*`，`prefs.planId='A'` → 下线只删 `counter:A:*`。

Evidence:
```dart
if (replace) await _tasks.deleteCounterTasks(id);
await _tasks.upsertMany(tasks);
await _store.savePlan(plan, id: id, enabled: true);   // ← 失败/被杀 ⇒ 孤儿
```

Reproduction Steps: 在 `savePlan` 前抛异常，观察 prefs.planId 未变而任务已按新 id 落库；再调用 `disable()`，断言任务仍在。

Root Cause: 跨存储（SQLite + prefs）无两阶段提交，也无"孤儿清理"。

Alternative Hypotheses: 现有 `apply` 每次都会 `deleteCounterTasks(newId)` 再重建，因此"孤儿"在下次 apply 时会被覆盖；只有"用户不再使用该计划"时才永久残留。

Business Impact: 用户"关掉反击计划"后仍可能有任务在跑（护栏失效），且删除按前缀永远够不到。

Recommended Fix: ① 先写 prefs（带 `pending=true` 标记）再写 DB，成功后清标记；② 启动时扫描 `tasks` 中所有 `counter:*` 前缀，若其 planId 不在已知集合中则告警/清理。

Regression Risks: 启动扫描需要遍历 `tasks.id LIKE 'counter:%'`（可用范围查询，避免 LIKE 通配）。

Verification Tests: 注入 prefs 写失败，断言下一次 `disable` 仍能删干净。

Remaining Uncertainty: prefs 写失败的实际概率（`SharedPreferences.setString` 返回 bool，但代码未检查返回值）。

---

## 6. 时间字段统一说明（跨条目汇总）

| 数据 | 存储形态 | 语义 | 跨时区/改钟行为 |
|---|---|---|---|
| `tasks.created_at/updated_at` | INTEGER epoch ms | 瞬时 | 不受影响（但 `updated_at` 是计划种子，改系统时间会改变随机计划） |
| `occurrences.fire_at` | INTEGER epoch ms | 瞬时 | 已落库计划不随时区平移 |
| `exec_logs.created_at` | INTEGER epoch ms | 瞬时 | `dailyCounts` 用 `date(...,'localtime')` 按**当前**时区分组 ⇒ 改时区后历史日志的"日期"会重排 |
| 触发器 `fixedOnce.at` | TEXT ISO **无偏移（本地墙钟）** | 墙钟 | **会平移**（DAT-10） |
| `dailyAt/weeklyAt.time` | `{hour,minute}` | 墙钟 | 按当前本地时区解释（符合直觉） |
| `dateRange` / `specificDate` | `yyyy-MM-dd` | 本地日历日 | 按当前本地时区解释 |
| prefs 时间戳（outbox `at/expiresAt`、`auto_overrides_at`） | INTEGER epoch ms | 瞬时 | 改钟会让 TTL 判定漂移（未做单调时钟保护） |
| `occurrenceId` | `{taskId}@{fireAtMs}` | 含绝对时刻 | 改时区后重算会产生新 id，旧行靠 `reconcile` 的"未来 pending 全删"清理 |

改系统时钟的已知后果（P3，不单列条目）：`executeDue` 的"过期 >10 分钟即丢弃"用墙钟差，**把时钟前拨 1 小时会让当轮所有 pending 被标 skipped**（错过执行）；后拨则会让陈旧计划被补执行（受 `catchUpLimit=3` 限制）。

---

## 7. 未覆盖范围与原因

1. **未执行任何代码/测试**：沙箱无 dart/flutter，禁止跑测试；所有"运行期行为"结论均来自源码与 sqflite 源码交叉核对，未经真机复现。
2. **未接触真实数据库**：仓库内不存在 `*.db`/`*.sqlite`；因此"线上是否已存在重复 occurrence / 坏行 / 孤儿任务"无法证实（DAT-13/14 标为 SUSPECTED 的部分）。
3. **未在 Android 真机验证 `PRAGMA foreign_keys`**：`test/db_repository_test.dart` 的断言跑在 FFI 上；Android 走同一 `sqflite_common` 代码路径，判定为 HIGH_CONFIDENCE 而非 CONFIRMED。
4. **未做性能实测**：DAT-07（缺索引）、DAT-11（大删除）的耗时结论为静态推断，未测行数与耗时曲线。
5. **未审计远程协议/加密层**（`protocol.dart`、`command_channel.dart`、`rc_script.dart` 的序列化与重放窗口）——属 A3 之外的通信安全面，仅在与持久化交互处（outbox、配对表）做了必要覆盖。
6. **未穷举所有 `SharedPreferences` 键**：`PrefsKeys` 之外的散落键（`run_master_service`、`device_name_service`、`remote_tts_presets`、`permission_flow`）只做了 grep 级别确认，未逐键审计读写对称性。
7. **未审计 `counter_plan_materializer.dart` 的物化正确性**（任务 id 生成、日期展开、音源池解析）——属调度/领域逻辑，A3 只覆盖其**落库与删除**语义。
8. **未审计 UI 侧全部读写调用点**：`remote_tasks_tab`、`remote_console_tab`、`ptt_tab` 等只抽查了与 DB/prefs 直接交互的部分。
