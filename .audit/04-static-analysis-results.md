# 04 · 静态分析结果

## 1. 实际执行了什么 / 没执行什么

| 检查 | 状态 | 说明 |
|---|---|---|
| `flutter analyze` | ⚠️ **未运行** | 沙箱无 `dart`/`flutter`（`command not found`）。引用 `_pt/r93gate.log` 历史结果：`[PASS] analyze`（R92 收口后至今 `No issues`） |
| `dart analyze` / 类型检查 | ⚠️ 未运行 | 同上 |
| AST / 数据流（ast-grep / CodeQL） | ❌ 不可用 | 未安装；AUDIT_ONLY 禁止安装 |
| 跨文件符号引用 | ✅ 人工完成 | ripgrep + 逐文件阅读，62 个文件 |
| 导入图 / 循环依赖 DFS | ✅ 完成 | 107 文件，**0 循环** |
| 序列化字段对齐矩阵 | ✅ 完成 | `Task`/`Action`/`Trigger`/`Condition`/`CounterPlan` × `toMap`/`fromMap` |
| 迁移链逐版本审查 | ✅ 完成 | v1→v5 |
| 桥接契约表（Dart ↔ Kotlin） | ✅ 完成 | ~40 方法逐一核对 |
| 静默错误专项 grep | ✅ 完成 | 13 类模式，见 §4 |

> 结论：本轮静态分析是**人工 + grep 驱动**的深度语义审查，不是编译器级检查。
> 类型层面的问题（未定义符号、类型不匹配）由项目自身的 `analyze` 门禁保证 —— 该门禁**当前为绿**（历史实测），本轮不重复验证。

## 2. 静态检查发现的"硬缺陷"（编译器抓不到的）

### 2.1 常量映射错误（NAT-02，P1，R93 在飞）

```dart
// lib/domain/models/vibrate_caps.dart:113
bool get notificationsMuted => ringerMode == 1 || ringerMode == 2 || dndActive;
// :116-121
String get ringerLabel => switch (ringerMode) {
      0 => '正常', 1 => '静音', 2 => '振动', _ => '读不到',
    };
```

SDK 事实（`javap -constants android.jar android.media.AudioManager`）：
```
RINGER_MODE_SILENT  = 0
RINGER_MODE_VIBRATE = 1
RINGER_MODE_NORMAL  = 2
```
⇒ 映射**完全颠倒**。`analyze` 不会报，因为类型都对。

### 2.2 不可达/死路径（ARCH-01）

`background_engine.dart:2358-2360` 把 `service.invoke('guard', ...)` 发给 **UI isolate**，
而 UI 侧 `background_service_manager.dart` 只注册了 `_svc.on('state')` / `_svc.on('log')` ——
**全仓无 `on('guard')` 消费者**。这条自恢复链从未生效。

### 2.3 资源引用丢失（ARCH-02）

```kotlin
// NativeBridgePlugin.kt:361
val saved = mutableSetOf<String>()      // ← 每次调用新建
...
// :412
prefs.edit().putStringSet(KEY_ALARMS, saved).apply()   // ← 整体覆盖
```
`clearExactAlarms()`（:418-427）只能取消"最后一次"批次里记录的闹钟。
前 N-1 批次的 `PendingIntent` 失去引用，`am.cancel()` 永远找不到它们 → **孤儿精确闹钟**。

### 2.4 无条件回执成功（ARCH-12 / NAT-10）

```dart
// endpoint_service.dart:2487-2497（vibrate.stop）
_ack(msg, true);   // 引擎未运行时什么都没做，但回执成功
```
```kotlin
// deviceAlert：通知权限被拒时仍 result["ok"]=true
```
这类"假成功"是用户最难排查的形态 —— UI 说"已执行"，设备上什么都没有。

## 3. 跨模块契约不一致

| 契约 | 一侧 | 另一侧 | 缺陷 |
|---|---|---|---|
| 清理 pending 的范围 | 引擎 `reconcile`：只删 `fire_at > now`（注释明写"保留已到期的否则漏触发"） | 远程 `deletePendingForTask`：删**全部** pending | SCH-02 |
| 停用任务的编排 | 本机 UI：只 `setEnabled(false)` | 远程：`setEnabled` + 删计划 + 物化 + replan | ARCH-06 |
| `KEY_ALARMS` 语义 | `replan` 认为"排新即可" | 原生每次整体覆盖 | ARCH-02 |
| `quiet_exempt` 语义 | 新代码：三态（0 跟随/1 强制豁免/2 强制不豁免） | 老库数据：bool（0/1）且迁移只补列 | DAT-01 |
| occurrence 状态 | 引擎用 `failed` 表示"已取走" | 用户视角 `failed` = "执行失败" | SCH-04 |
| `Task.toRow()` 列类型 | Dart `Map`/`List` | DB 声明 `TEXT`，只靠仓储层覆盖 | DAT-12 |

## 4. 静默错误专项扫描（13 类）

| 类别 | 命中 | 判定 |
|---|---:|---|
| 空捕获 `catch (_) {}`（体为空） | **0** | ✅ 6 处 `catch (_)` 全部带注释且是刻意 best-effort |
| `on Exception catch` 后只 print | 0 | ✅ 全仓 `on Exception catch` = 0；`on Object catch` 60 处均带审计/降级说明 |
| catch 内 `return true/false/[]/null` | 2 | ✅ **不是缺陷**：两处都把错误写进可见状态（审计 + 错误文案） |
| `catchError` 吞异常 | 2 | ✅ 可接受（`dispose()` 同步接口，注释给出理由） |
| `unawaited(...)` | **79** | ⚠️ 1 处可疑 → **QUA-08**（`background_engine.dart:490` 写日志无兜底） |
| `.then(` 无 `catchError` | 7 | ✅ 均在失败路径本就要 `_fail` 的位置 |
| `print(` 残留生产路径 | 13 | ✅ 刻意（`runApp` 前降级 / 后台 isolate 无 logger）。P3 观察：release 下仍进 logcat |
| `?? ''` / `?? 0` / `?? false` | 111 / 47 / 73 | ✅ 抽样 20 处未发现"缺失被当合法值写库"。**例外** → **QUA-09**（Kotlin `dndActive` 读不到报 `false`） |
| `TODO` / `FIXME` / `HACK` | **0** | ✅ |
| 未 await 的写库/网络/文件 | 0（除上条） | ✅ `flushAllOutbox` 内部逐条留痕 |
| 源码文本锁未剥注释 | 13 文件 | → **QUA-10** |
| 性能用例裸 `Stopwatch` | 16/24 | → **QUA-02** |
| `pumpAndSettle` 无显式超时 | 396 处 | → **QUA-13** |

**总评**：本项目的静默错误治理**明显高于一般项目水位** —— 有专门的 `test/silent_failure_locks_test.dart`（35 例，
含 18 条 SLX-90 反面样本，每条都证明判据非恒真）。这一域**已审计、未发现新的系统性缺陷**，
只登记 Dart 侧未被子系统覆盖的 1 条与 Kotlin 新代码引入的 1 条。

## 5. 死代码 / 死参数

| 位置 | 现象 | 缺陷 |
|---|---|---|
| `schedule_engine.materialize(existing:)` | 参数从未被使用 | SCH-13（P3） |
| `Task.priority` | 不参与执行排序 | SCH-13（P3） |
| `permission_flow.exactAlarmDenied` | 计算后无人消费，Dashboard 另有独立判断（双源） | NAT-18（P3） |
| `PACKAGE_USAGE_STATS` | 声明了但全仓无授权入口 ⇒ `appStandbyBucket` 恒 `unknown` | NAT-14（P3） |
| 设置页「遵循免打扰时段」 | 自 v79 起零行为（R92 已下架） | 已修 |
