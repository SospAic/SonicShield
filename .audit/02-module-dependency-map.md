# 02 · 模块依赖地图

> 统计口径：Python 遍历 `lib/` 107 个 `.dart`，解析 `^import '...'` 中的**相对路径**，按 `lib/<层>/` 归类去重计数。
> 复现命令见 `_work/A1-architecture.md` §3.1。

## 1. 层间依赖矩阵

| from \ to | core | domain | data | services | remote | features | 合计 |
|---|---:|---:|---:|---:|---:|---:|---:|
| **features** | 41 | 24 | **6** | 21 | 64 | — | 156 |
| **core** | — | 3 | 6 | 8 | 0 | **14** | 31 |
| **services** | 10 | 24 | 13 | — | **3** | **1** | 51 |
| **remote** | 3 | 12 | 5 | **8** | — | 0 | 28 |
| **data** | 0 | 4 | — | 0 | 0 | 0 | 4 |
| **domain** | 4 | — | 0 | 0 | 0 | 0 | 4 |

**读法**：`features → remote` 64 条边是全仓最粗的一条耦合；`services → features` 只有 **1** 条，但它是**反向**的（倒置）。

## 2. 循环依赖结论

### 2.1 文件级：**0 个循环**（硬结论）

对 107 个文件做 DFS 三色标记，未发现任何 `A → … → A` 的导入环。
这是可复现的静态扫描结论，**不是**"没看出来"。

### 2.2 目录级：2 组双向 + 1 条单向倒置

| 双向组 | 正向边 | 反向边 | 判定 |
|---|---|---|---|
| `core ↔ features` | `core/router.dart` → 14 个页面 | 页面 → `core/providers.dart` / `constants.dart` | **可接受**：router/DI 是组合根，天然引用页面；页面不引用 router |
| `services ↔ remote` | `device_name_service.dart` → `endpoint_service.dart` / `protocol.dart` / `remote_store.dart` | `endpoint_service.dart` → `background_service_manager.dart`、`counter_plan_service.dart`、`native_bridge.dart`、`notification_service.dart`、`ptt_stream_sink.dart`、`run_master_service.dart`（**6 个**） | **可接受但有耦合成本**：`device_name_service` 只为读 `deviceId` 就依赖整个 4,468 行单例；二者无法独立测试/裁剪 |
| `services ↔ features` | `background_engine.dart:32` → `features/guard/guard_orchestration.dart` | 无 | **不可接受（分层倒置）** → ARCH-10 |

## 3. UI 是否绕过 domain 直接写 DB

**是**，5 个文件 / 6 条 `features → data` 导入：

| 文件 | 导入 | 是否写库 |
|---|---|---|
| `features/tasks/task_editor_screen.dart:8` | `task_repository.dart show AudioAsset` | 否（只用模型类） |
| `features/guard/guard_screen.dart:11` | `task_repository.dart` | 是（读任务做编排候选） |
| `features/settings/settings_screen.dart:16-17` | `api_config_store.dart`、`counter_plan_store.dart` | 是（直接写 KV） |
| `features/sounds/sound_library_screen.dart:9` | `task_repository.dart` | 是（`removeAssetRef`） |
| `features/stats/stats_screen.dart:5` | `log_repository.dart` | 否（只读聚合） |
| `features/tasks/task_list_screen.dart:604/700`（经 `taskRepoProvider` 间接） | `TaskRepository` | 是（`setEnabled` / `delete`） |

**判定**：不是缺陷本身，但它导致**同一业务用例出现两套编排**——最典型是"停用任务"：

```
本机路径：task_list_screen.setEnabled(false) → 只写 tasks.enabled
远程路径：endpoint_service.task.toggle → setEnabled + deletePendingForTask + _rematerialize + replan
结果：本机停用后，残留的 pending 到点被 executeDue 静默标 skipped（无审计）
```

→ **ARCH-06**。

## 4. 模块规模与"上帝类"判断

| 文件 | 行数 | 承担职责 | 评价 |
|---|---:|---|---|
| `remote/endpoint_service.dart` | 4,468 | MQTT 连接/重连/加解密/去重/35 个命令分支/outbox/assist/PTT/通话信令 | **超载**（5 类职责） |
| `services/background_engine.dart` | 2,388 | 引擎生命周期 + 8 类动作执行 + 声音守卫 + 振动 + 远程执行 + 停机清理 | **超载但内聚**（刻意的取舍，代价见 §5） |
| `features/tasks/task_editor_screen.dart` | 2,143 | 全部触发器/动作编辑 | 可接受（纯 UI） |
| `features/settings/settings_screen.dart` | 1,931 | 全部设置项 | 可接受（纯 UI） |
| `remote/call_service.dart` | 1,110 | WebRTC 状态机 | 判定已抽到 `call_lifecycle.dart`（362 行纯函数） |
| `services/playback_service.dart` | 564 | 播放/焦点/代次 | 合理 |

## 5. 超载的直接代价（这是本轮多条缺陷的共同上游）

`background_engine.dart` 把**所有状态放在 `_engineBody` 的闭包里**：

```dart
// 伪结构
void _engineBody(...) {
  var executing = false;     // ← 只在 executeDue 内可见
  var stopping  = false;
  var replanning = false;
  ...
  Future<void> executeDue() async { ... }   // 闭包，无法从外部注入 now/runAction
}
```

| 后果 | 缺陷 |
|---|---|
| `executing` 只保护 `executeDue` 自身重入，不是任务级互斥 ⇒ `runNow` / `runGuardPlan` 可并发 | SCH-03 / ARCH-08 |
| `executeDue` 循环体不可单测（无法注入 `now`）⇒ SCH-01 无法被回归锁住 | SCH-01 |
| 状态是**进程内**的 ⇒ 两个引擎实例（原生闹钟拉起新实例、旧实例未退）互相看不见 | DAT-03 |
| 分层倒置：需要 `resolveGuardPlan` 只能反向 import `features/guard` | ARCH-10 |

**建议（中长期）**：把 `executeDue` 的循环体抽成 `Future<void> executeBatch({required List<PlannedOccurrence> due, required DateTime batchStart, required ActionRunner runAction})` 纯编排函数，
`_engineBody` 只负责装配。这样 SCH-01/SCH-03/DAT-03 才能被宿主机测试锁住。

## 6. 依赖健康度小结

| 指标 | 值 | 评价 |
|---|---|---|
| 文件级循环 | 0 | ✅ |
| 目录级倒置 | 1 | ⚠️（ARCH-10，P3） |
| `features → data` 直连 | 6 条 | ⚠️ 导致双编排（ARCH-06，P2） |
| 最大单文件 | 4,468 行 | ⚠️ |
| 纯函数抽取 | `schedule_engine` / `call_lifecycle` / `guard_orchestration` / `vibrate_resolve` / `decideRcAdmission` / `endpoint_security` | ✅ 可测性已有明显改善 |
