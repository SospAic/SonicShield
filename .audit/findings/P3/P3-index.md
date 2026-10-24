# P3 缺陷清单（36 条）

> 低影响、低概率或非关键。**不建议在阶段 1–3 处理**，留待阶段 4（可测性）与阶段 5（架构）。
> 但其中 4 条（标记 ⭐）建议顺手带上，因为改动量极小。

## 架构与调用链（6）

| ID | 标题 | 证据 | 位置 | 影响 |
|---|---|---|---|---|
| ARCH-07 | 守卫延时执行是单槽定时器：新计划静默覆盖旧计划，审计与实际不符 | CONFIRMED | `background_engine.dart:1728-1745` | 同时段多次声音事件只执行最后一次，无记录 |
| ARCH-08 | 声音响应路径绕过全局执行锁，可与计划执行并发 | CONFIRMED | `background_engine.dart:1620-1663` | 并发执行（与 SCH-03 同源） |
| ARCH-09 | 播放无优先级仲裁：计划 / 远程 / TTS 三路可同时出声 | HIGH_CONFIDENCE | `playback_service.dart:162`（每次 new `AudioPlayer`） | 混音叠响，用户听不清 |
| ARCH-10 | 分层倒置：引擎（服务层）反向 import `features/guard` | CONFIRMED | `background_engine.dart:32` | 引擎不可独立测试/裁剪 |
| ARCH-11 | 引擎 bootstrap 在首次 `syncPrefs()` 之前读取设置 | HIGH_CONFIDENCE | `background_engine.dart:407/434` | 引擎 isolate 被复用时读到旧快照 |
| ARCH-12 | 远程 `vibrate.stop` 无条件回执成功（引擎未运行时是假成功） | CONFIRMED | `endpoint_service.dart:2487-2497` | 用户以为停了，实际没停 |

## 调度与并发（5）

| ID | 标题 | 证据 | 位置 | 影响 |
|---|---|---|---|---|
| SCH-11 | `latestPendingFireAt` / `pendingCountAfter` 不排除停用任务 ⇒ 续算被抑制、UI 倒计时指向永不触发的计划 | CONFIRMED | `occurrence_repository.dart:119-127` | 首页显示"下一触发"但实际不会响 |
| SCH-12 | 跨午夜窗口用 `Duration(days: 1)`（绝对 24h）构造 ⇒ DST 时区窗口错 1 小时 | CONFIRMED | `schedule_engine.dart` 窗口构造 | 夏令时地区窗口偏移 |
| SCH-13 | 契约与实现不符：`Task.priority` 不参与执行排序；`materialize(existing:)` 是死参数 | CONFIRMED | `schedule_engine.dart` / `task.dart` | 死代码误导读者 |
| SCH-14 | `guardDelayTimer` 单槽覆盖：新的延时计划静默丢弃旧的（无审计） | CONFIRMED | `background_engine.dart:1728-1745` | 同 ARCH-07 |
| SCH-15 | `stopping` 永不复位且 `stopSelf` 失败无自愈 ⇒ 僵尸引擎（无法再次启动、无法自愈） | SUSPECTED | `background_engine.dart` 停机段 | 极端情况下需杀进程才能恢复 |

## 数据与一致性（6）

| ID | 标题 | 证据 | 位置 | 影响 |
|---|---|---|---|---|
| DAT-13 | `commitAll` 注释宣称"同 id 或同 fire_at+task 不重复"，实际只有 PK 去重（无 UNIQUE 约束） | CONFIRMED | `occurrence_repository.dart` | 注释与实现不符，未来改动易踩坑 |
| DAT-14 | 迁移只按"版本闸/列存在性"判断，缺 schema 完整性校验；v1→v2 的 `ALTER` 非幂等 | CONFIRMED | `app_database.dart` v1→v2 | 中途失败后重试会 `duplicate column` |
| DAT-15 | 批量删除任务（单条/多选/整包）是 Dart 循环逐条删，非事务 | CONFIRMED | 任务列表批量操作 | 失败后部分成功 |
| DAT-16 | `audio_assets` 无 `UNIQUE(name)`，"导入预置库"的幂等判据是 `nameSet()`（TOCTOU） | CONFIRMED | `sound_library` 导入路径 | 并发导入产生重复行 |
| DAT-17 | `skipNextForTask` 是 SELECT → UPDATE，无事务/无条件，返回值可能与事实不符 | CONFIRMED | `occurrence_repository.dart:237-248` | "跳过"可能没生效 |
| DAT-18 | `CounterPlanStore` 三键写入 + DB 任务写入跨存储无一致性协议，planId 错配会产生"删不掉的孤儿任务" | CONFIRMED | `counter_plan_store.dart` | 孤儿任务占位但不可见 |

## 远程与安全（6）

| ID | 标题 | 证据 | 位置 | 影响 |
|---|---|---|---|---|
| REM-11 | `call.end` 与 `screen.cast.stop` 不校验会话归属 —— 任意已配对控制端可打断他人通话/投屏 | CONFIRMED | `endpoint_service` 通话/投屏分支 | 多控制端场景下互相干扰 |
| REM-12 | `from` 为空时回执退化为广播 —— 定向投递（R-6）保证被绕过 | CONFIRMED | 回执投递路径 | 回执被所有订阅者看到 |
| REM-13 | 异常文本原样回传对端 + `print` 未脱敏 | CONFIRMED | `describeFailure` / `print` 点 | 信息卫生（可能泄露路径/端点） |
| REM-14 | 审计日志落盘精确 GPS 坐标与本地文件路径 | CONFIRMED | 审计写入点 | 隐私风险（本地文件，未外传） |
| REM-15 | 去重表仅存内存：进程重启后 90s 窗口内的重放会重复执行副作用 | CONFIRMED | `reserveInboundId` | 重启窗口内可重放 |
| REM-16 | （**UNVERIFIED**）`package:http` 跟随重定向时是否会把 `Authorization` 转发到降级/跨域目标 | UNVERIFIED | `package:http` 行为 | 需查库实现，未完成 |

## 原生与生命周期（7）

| ID | 标题 | 证据 | 位置 | 影响 |
|---|---|---|---|---|
| NAT-11 | 远程关闭守卫不撤 `MicGuardService`：常驻通知"正在监听声音事件"残留 | CONFIRMED | 守卫关闭路径 | 通知与实际状态矛盾 |
| NAT-13 | 原生异常被统一折叠为"平台不支持"：审计/诊断给出错误结论 | CONFIRMED | 桥接错误映射 | 排障被误导（精确闹钟/投屏/振动同族） |
| NAT-14 | `PACKAGE_USAGE_STATS` 声明了但全仓无授权入口 ⇒ `appStandbyBucket` 恒 `unknown` | CONFIRMED | Manifest + 省电桶自检 | 省电桶自检是死功能 |
| NAT-15 | `deviceAlert` 的 `MediaPlayer` 在异常路径不释放（无 try/finally） | CONFIRMED | 原生 `deviceAlert` | 资源泄漏 |
| NAT-16 | `replan` 只"排新"不"撤旧"：不在新计划里的旧精确闹钟不会被取消（孤儿闹钟） | CONFIRMED | `pushExactAlarms` | 同 ARCH-02 的另一面 |
| NAT-17 | 精确闹钟权限恢复接收器用 1s 延迟，与 `BootReceiver` 的 30s 归因窗口结论不一致 | CONFIRMED | 权限恢复接收器 | 可能被 FGS 启动限制拒绝 |
| NAT-18 | `permission_flow.exactAlarmDenied` 计算后无人消费（死字段），与 Dashboard 的独立判断形成双源 | CONFIRMED | `permission_flow.dart` / `dashboard_screen.dart` | 两处判断可能不一致 |

## 质量与门禁（6）

| ID | 标题 | 证据 | 位置 | 影响 |
|---|---|---|---|---|
| QUA-08 | `reportBadTaskRow` 的 fire-and-forget 写库无兜底，写失败会变成 isolate 内未处理异步错误 | CONFIRMED | `background_engine.dart:490` | 未处理异步错误 |
| QUA-09 | Kotlin 侧 `dndActive` 把"读不到"报成 `false`，与 `ringerMode=-1` 的哨兵语义不一致 | CONFIRMED | `NativeBridgePlugin.kt:727-737` | "读不到"≠"勿扰未开"（BUG-041 教训） |
| QUA-10 | 48 个测试文件依赖源码文本，13 个未使用统一剥注释工具 | CONFIRMED | 见 `08-test-results.md` §5 | 注释改动即批量假红（已被击中过一次） |
| QUA-11 | `gates.ps1` 头部注释两处失实（阈值示例陈旧、CI 判据已不存在） | CONFIRMED | `gates.ps1:8-10/16-17` | 误导读者 |
| QUA-12 | `docs/22` 的命令总数是过期快照（27+6=33 vs 实际 38） | CONFIRMED | `docs/22:449/456/462` | 文档与实现漂移 |
| QUA-13 | 396 处 `pumpAndSettle` 全部使用默认 10 分钟超时，无一处显式限时 | CONFIRMED | `test/` 全局 | 挂死时排查困难 |

---

## ⭐ 建议顺手带上的 4 条（改动量极小，收益明确）

| ID | 动作 | 为什么顺手 |
|---|---|---|
| **ARCH-12** | `vibrate.stop` 按真实结果回执 | 与阶段 3.4（`device.alert` 假成功）同一处代码，一起改 |
| **QUA-11** | 修 `gates.ps1` 头部两处失实注释 | 纯注释，零风险 |
| **NAT-11** | 远程关守卫时撤 `MicGuardService` | 与 NAT-03 的守卫修复同一路径 |
| **QUA-09** | Kotlin `dndActive` 改用 `-1` 哨兵 | 与 NAT-02 的振动修复同一批 |
