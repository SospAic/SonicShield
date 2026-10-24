# 07 · 数据一致性审计

> 来源：`_work/A3-data.md`（18 条）+ A1/A2 交叉引用。

## 1. Schema 概要（v5）

| 表 | 关键列 | 约束 | 索引 |
|---|---|---|---|
| `tasks` | `id` PK / `enabled` / `trigger_type` / `action_type` / `trigger_json` / `action_json` / `quiet_exempt`(三态) / `updated_at` | PK | 无显式 |
| `occurrences` | `id` PK（`${taskId}@${ms}`）/ `task_id` **FK→tasks ON DELETE CASCADE** / `fire_at` / `status` / `quiet_exempt`(**bool 0/1，与 tasks 同名不同义**) | PK + FK | **缺 `task_id` 索引**（DAT-07） |
| `logs` | 无 FK（故意，历史独立保留） | — | — |
| `audio_assets` | 无 `UNIQUE(name)` | — | —（DAT-16） |
| `kv` | 键值（`api_config` / `counter_plan` 等） | — | — |

⚠️ **同名不同义陷阱**：`tasks.quiet_exempt` 是三态（0/1/2），`occurrences.quiet_exempt` 是 bool（0/1）。
代码注释已标注（`app_database.dart:128`），但这是易错点。

## 2. 迁移链（v1 → v5）

| 版本 | 操作 | 幂等 | 风险 |
|---|---|---|---|
| v1→v2 | 建基础表 + `ALTER` | ⚠️ **`ALTER` 非幂等**（DAT-14） | 中途失败后重试会 `duplicate column` |
| v2→v3 | 补 `tasks.quiet_exempt`（bool） | ✅ `_addIntColumnIfMissing`（`PRAGMA table_info` 判存在） | — |
| v3→v4 | 补 `occurrences.quiet_exempt` | ✅ 同上 | — |
| **v4→v5 / v79 语义变更** | `quiet_exempt` 从 **bool** 改为 **三态覆盖** | ✅ 列已存在 | 🔴 **只补列不回填 ⇒ 语义静默漂移（DAT-01，P1）** |

### 2.1 DAT-01 详解（本轮最高价值的迁移缺陷）

**旧语义（v3 时代）**：`quiet_exempt` 是布尔开关，判据 `master && task`（两者皆开才豁免）。
**新语义（v79+）**：三态覆盖，判据 `task ?? master`（`schedule_engine.dart:184-192`）。

```
DB 值   旧解释        新解释              净效果（master 已开时）
 0      "不豁免"  →  null（跟随主开关）  → 变成"豁免"   ❌ 单向放宽
 1      "豁免"    →  true（强制豁免）    → 主开关关也豁免 ❌ 单向放宽
```

迁移只做了 `_addIntColumnIfMissing`（`app_database.dart:218-221`），**没有任何回填**。
迁移注释（`:205-207`）只论证了"主开关默认 false"的情形，**漏掉了主开关已开的存量用户**。

**现场佐证**：R92 真机观察"首页下一触发落在免打扰窗口内"（`memory/2026-10-20.md`），
与"老库 `quiet_exempt=1` → 新语义强制豁免"完全吻合。

**影响**：免打扰护栏（合规红线之一）在存量用户上静默失效，夜间可能突然出声/振动。

## 3. 事务边界清单

| 方法 | 涉及表 | 事务？ | 失败后残留 | 缺陷 |
|---|---|---|---|---|
| `TaskRepository.upsert` | `tasks` | ✅ 单事务 UPDATE→INSERT | 无（刻意不用 REPLACE，避免级联删 occurrences） | ✅ |
| `OccurrenceRepository.reconcile` | `occurrences` | ✅ 单事务（删未来 pending → 删投影外 skipped → 插） | 无 | ✅ 设计正确 |
| `OccurrenceRepository.commitAll` | `occurrences` | ✅ batch | 只有 PK 去重，无 UNIQUE | DAT-13 |
| `OccurrenceRepository.markStatus` | `occurrences` | 单语句 | **无条件 UPDATE，非 CAS** | **DAT-03** |
| `skipNextForTask` | `occurrences` | ❌ SELECT→UPDATE | 返回值可能与事实不符 | DAT-17 |
| `deleteCounterTasks` | `tasks`（级联 occurrences） | 单语句 | **级联删掉全部历史** | **DAT-04** |
| `CounterPlanService.apply` | `tasks` + `occurrences` + prefs | ❌ **三个独立事务** | 旧计划已删、新计划未写 | **DAT-04** |
| 远程 `_upsertTask` | `tasks` + `occurrences` | ❌ **三段写** | 任务零计划，不自愈 | **DAT-05** |
| `removeAssetRef` | `tasks` | ❌ 读全表→批量覆盖 | 并发丢更新 | DAT-06 |
| 批量删除任务 | `tasks` | ❌ Dart 循环逐条 | 部分成功 | DAT-15 |
| 导入预置库 | `audio_assets` | ❌ `nameSet()` 判重 TOCTOU | 重复行 | DAT-16 |

**结论**：**所有跨仓储的多步写都没有共享事务**，因为 `TaskRepository` 未暴露事务句柄。

## 4. 序列化往返（`toMap` / `fromMap` 对齐）

| 模型 | 字段 | 写 | 读 | 对称？ |
|---|---|---|---|---|
| `Task` | 全部 | ✅ | ✅ | ✅（但 `toRow()` 列类型与 DB 声明不一致，靠仓储覆盖 → DAT-12） |
| `VibrateCaps` | R93 新增 2 键 | ✅ | ✅ | ✅（VC05 锁曾落后，已修） |
| `RandomVibrateAction` | 新默认值 | ✅ | ✅ | ✅ |
| `Trigger` | 时间字段 | 本地墙钟 ISO **无偏移** | ✅ | ⚠️ 与 occurrence 的 UTC epoch ms 混用 → DAT-10 |
| `CounterPlan` | 全部 | ✅ | ✅ | ✅ |

**DAT-12 说明**：`Task.toRow()` 把 `Map`/`List` 直接放进 row map，而 DB 列声明为 `TEXT`。
当前**所有写路径都经仓储层转 JSON 字符串**，所以没有触发；但任何一处误用即崩溃。
这是"高危陷阱"，不是当前缺陷（严重度已标 P2 但注明"当前无触发路径"）。

## 5. 并发写冲突

| 场景 | 现状 | 缺陷 |
|---|---|---|
| 两个 isolate 同时写 `occurrences` | 无跨连接互斥；`busy_timeout=5000` | DAT-08（**无任何重试**） |
| UI 侧 `AppDatabase.open` | **没有**引擎那样的有界重试（引擎 500ms 重试一次） | DAT-08 |
| 读-改-写（计数/状态） | 非原子 | DAT-03 / DAT-06 / DAT-17 |
| prefs JSON 列表 | 一条坏记录 ⇒ **整表清空**，且下次写入把清空结果持久化 | DAT-09 |

## 6. 数据增长与清理

| 项 | 现状 | 缺陷 |
|---|---|---|
| `purgeOlderThan` | 只在**引擎启动时跑一次**，无分批、无 LIMIT | DAT-11 |
| `occurrences` 按任务查询 | 缺 `task_id` 索引 ⇒ 全表扫描；声音事件路径 O(任务数 × 计划数) | DAT-07 |
| `logs` | 无 FK，与 tasks 生命周期解耦（刻意）；但 `deleteCounterTasks` 级联删 occurrences 后，日志与计划表出现断裂 | DAT-04 副作用 |
| 非 pending 行 | 7 天后被 `RetentionMaintenance` 清理（`retention_maintenance.dart:82`） | 崩溃停在 `failed` 的行连痕迹一起消失（SCH-04 副作用） |

## 7. 本域已审计、未发现问题的部分

| 项 | 核查点 | 结论 |
|---|---|---|
| `onCreate` 幂等 | 全部 `IF NOT EXISTS` | ✅ R89 铁律成立 |
| `openDatabase` | `singleInstance: false` | ✅ R89 铁律成立 |
| `reconcile` 语义 | 只删 `fire_at > now`，保留已到期 pending | ✅ **正确**（远程路径违反此契约 → SCH-02） |
| `TaskRepository.upsert` 不用 `REPLACE` | 避免 `ON DELETE CASCADE` 删 occurrences（BUG-147） | ✅ |
| `listAll` 行级兜底 | `onRowError` + 跳过坏行 | ✅（但 `get()` 没有 → DAT-02） |
| 外键开启 | `PRAGMA foreign_keys=ON` | ✅（需确认每个连接都开 —— 已确认 `AppDatabase.open` 内统一设置） |
| 枚举序列化 | `values.byName` | ⚠️ 对未知值会抛 ⇒ 降级安装会崩（单向前进可接受，已在 SCH-04 回归风险中记录） |
