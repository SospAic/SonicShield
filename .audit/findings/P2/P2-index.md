# P2 缺陷清单（39 条）

> 每条给出：证据等级 / 位置 / 一句话影响 / 修复指向。
> 完整证据与复现见 `_work/A*.md` 对应章节。

## 架构与调用链（6）

| ID | 标题 | 证据 | 位置 | 影响 | 修复指向 |
|---|---|---|---|---|---|
| ARCH-01 | 守卫自恢复是死路径，`guard_enabled` 持久化承诺无人兑现 | CONFIRMED + UNVERIFIED(平台) | `background_engine.dart:2358-2360`；UI 侧只注册 `on('state')`/`on('log')` | 应用被杀后守卫不会真的恢复，但 prefs 仍说"开着" | 见 NAT-03（两者需一起修） |
| ARCH-02 | 精确闹钟只增不删：旧批次失去引用，`clearAllAlarms` 无法回收 | **CONFIRMED**（已独立复核） | `NativeBridgePlugin.kt:361`（`saved` 每次新建）→ `:412`（整体覆盖）→ `:418-427`（clear 只清最后一批） | 孤儿精确闹钟；关机/关引擎后仍可能被唤醒 | `KEY_ALARMS` 改累加语义或按 generation 分桶 |
| ARCH-03 | 远程 `sound.play` 的 `durationSec` 无上限（与指令组 30 分钟预算不对称） | CONFIRMED | `remote_playback.dart:191` → `playback_service.dart:194-200` | 单条远程命令可长期占用媒体通道 | 夹紧到与 `RcScript` 同量级 |
| ARCH-04 | 可选远程模块阻塞首帧：`main()` 在 `runApp` 前 `await` MQTT 连接 | CONFIRMED | `main.dart:154-157` → `endpoint_service.dart:662` | broker 慢时白屏（最长 5s 超时） | 改为后台连接，不阻塞首帧 |
| ARCH-05 | 关机闸门不闭环：引擎不校验 `KEY_SHOULD_RUN`，可被保活组件复活 | HIGH_CONFIDENCE | `dashboard_screen.dart:204` + `background_service_manager.dart:230` + `WatchdogReceiver.java:87` | 用户关机后服务可能被第三方保活拉起 | 引擎 bootstrap 首句校验 `KEY_SHOULD_RUN` |
| ARCH-06 | 停用任务有两条编排：UI 不删 pending，远程删；残留计划到点静默 skipped | CONFIRMED | `task_list_screen.dart:604/700` vs `endpoint_service.dart:1242-1246`；`background_engine.dart:1518-1521`（无审计） | 同一操作两种结果；残留 pending 静默消失 | 统一 `applyTaskToggle()` |

## 调度与并发（6）

| ID | 标题 | 证据 | 位置 | 影响 | 修复指向 |
|---|---|---|---|---|---|
| SCH-05 | 主 isolate 与引擎 isolate 并发写 occurrences，且 `_rematerialize` 的"删-插"不在事务里 | CONFIRMED | `endpoint_service.dart:2148-2153`；`occurrence_repository.dart:229` | 窗口期内读到空计划 / 重复行 | 单事务 `replacePendingForTask` |
| SCH-06 | 远程 `task.upsert`/`task.delete` 不触发 `replan` | CONFIRMED | `endpoint_service.dart:1946-1948` | 通道 B（精确闹钟）与数据库脱节 | 两条路径末尾补 `replan()` |
| SCH-07 | 停机/关闭守卫**不中断**在飞动作：`recordAndLog` 无取消点，`executeDue` 循环内不复检 `stopping` | CONFIRMED | `background_engine.dart:855/877`；`:1501` 循环 | 用户关引擎后仍在录音/播放到自然结束 | 循环内复检 `stopping` + 动作取消点 |
| SCH-08 | 声音入口的冷却基准在执行**之后**才落库 | CONFIRMED | `background_engine.dart:1670-1690` + `lastDoneFor` | 长动作期间同一任务可重复触发 | 执行前写"冷却开始"标记 |
| SCH-09 | `startReactiveCounter` 可重复调用而不停止旧实例 | CONFIRMED | `reactive_counter_service.dart` 启动路径 | Timer 泄漏 + "关掉后仍会出声" | 启动前先 `stopReactiveCounter` |
| SCH-10 | 关键判据全部依赖墙钟（`DateTime.now`） | CONFIRMED | 陈旧判定 / 冷却 / 免打扰窗口 | 用户改时间或 NTP 校正后误触发或长时间静默 | 冷却与超时改用单调时钟；窗口用本地日历 |

## 数据与一致性（7）

| ID | 标题 | 证据 | 位置 | 影响 | 修复指向 |
|---|---|---|---|---|---|
| DAT-06 | `removeAssetRef` 是"读全表 → 批量覆盖"，并发写会丢失更新 | CONFIRMED | `task_repository.dart` | 并发改任务时丢字段 | 改为按 id 精确更新 |
| DAT-07 | `occurrences` 缺 `task_id` 索引 | CONFIRMED | `app_database.dart` 建表段 | `lastDoneFor` 等按任务查询全表扫描；声音路径 O(任务数 × 计划数) | 加 `INDEX(task_id, fire_at)` |
| DAT-08 | 跨连接写冲突无任何重试；UI 侧 `AppDatabase.open` 也没有引擎那样的有界重试 | CONFIRMED | `app_database.dart:36-55` vs `background_engine.dart:271-284` | `database is locked` 直接失败 | 统一有界重试 |
| DAT-09 | prefs 里的 JSON 列表"一条坏记录 ⇒ 整表清空"，且下次写入把清空结果**持久化** | CONFIRMED | prefs 列表读写 | 数据永久丢失 | 逐条容错 + 坏行隔离 |
| DAT-10 | 时间语义混用：触发器存"本地墙钟 ISO（无偏移）"，计划存"UTC 瞬时 epoch ms" | CONFIRMED | `trigger.dart` vs `occurrence` | 改时区/夏令时后两者不一致 | 统一 UTC + 显式偏移 |
| DAT-11 | 保留策略只在引擎启动时跑一次；`purgeOlderThan` 无分批/无 LIMIT | CONFIRMED | `retention_maintenance.dart` | 长期常驻不重启则永不清理；大表一次删会长时间持锁 | 每 N tick 跑一次 + 分批 |
| DAT-12 | `Task.toRow()` 的列类型与 DB 声明不一致（Map/List vs TEXT），只靠仓储层覆盖 | CONFIRMED（当前无触发路径） | `task.dart` / `task_repository.dart` | 一处误用即崩溃 | `toRow` 内做 JSON 编码 |

## 远程与安全（6）

| ID | 标题 | 证据 | 位置 | 影响 | 修复指向 |
|---|---|---|---|---|---|
| REM-05 | 未鉴权的 CPU 放大 DoS：任意人向 cmd 主题发垃圾报文即触发 N×PBKDF2(120k) | CONFIRMED | `endpoint_service.dart:865-885` 多盐候选试解 | 一条垃圾报文触发多轮 PBKDF2；可被用来打爆 CPU/电量 | 试解前加廉价前置门（长度/格式/速率） |
| REM-06 | `deviceId` 只校验长度、不校验字符集 ⇒ MQTT 通配符注入 / 主题注入 | CONFIRMED | `deviceId` 校验处 | 可订阅/发布到非预期主题 | 白名单字符集 `[A-Za-z0-9_-]` |
| REM-07 | `sound.play` 的 `durationSec` 不夹紧且无远程停止通道 | CONFIRMED | `endpoint_service.dart:2462-2479` | 可发起"永不停止"的播放 | 同 ARCH-03 |
| REM-08 | 「自动接通」开启后来电**无任何可见指示**（后台静默开麦/开摄像头） | CONFIRMED | 通话自动接通路径 | 用户不知道自己在被听/被看 —— 合规风险 | 必须有常驻通知 + 声音/振动提示 |
| REM-09 | 通话链路（含开摄像头/麦克风）**零审计留痕** | CONFIRMED | `call_service.dart` / `endpoint_service` 通话分支 | 事后无法追查"谁在什么时候开了摄像头" | 每次权限位变更写审计 |
| REM-10 | 长期凭据全部明文落盘（配对码/配对 secret、broker 密码、TURN 凭据、API Key） | CONFIRMED | `remote_store.dart` / `api_config_store.dart`（SharedPreferences） | root/备份提取即得全部凭据 | 迁移到 Keystore/Keychain |

## 原生与生命周期（8）

| ID | 标题 | 证据 | 位置 | 影响 | 修复指向 |
|---|---|---|---|---|---|
| NAT-04 | 音频焦点只申请不放弃：每次播放结束都不 `setActive(false)` | CONFIRMED（全仓 0 处 `setActive(false)`） | `playback_service.dart` | 其它应用的闪避/暂停不会恢复 | `finally` 里 `setActive(false)` |
| NAT-05 | 【R93 在飞】把"动态系统状态"（`ringerMode`/`dndActive`）塞进"静态能力"并永久缓存 | CONFIRMED | `vibrate_caps.dart` | 勿扰/静音状态变化后诊断长期失真 | 动态状态不进 `VibrateCaps`，每次现读 |
| NAT-06 | 固定节奏振动恒走 `USAGE_NOTIFICATION`，且回执被丢弃 | CONFIRMED | `vibrate_session.dart` | 静音/勿扰下"没震却记 success"；远程 fixed 路径完全无审计 | 按用途选 usage + 检查回执 |
| NAT-07 | 依赖插件持有常驻 `PARTIAL_WAKE_LOCK` 且**永不释放**，并每 5s 排一次精确闹钟 | CONFIRMED | 插件侧 + `WatchdogReceiver` | "平衡/省电模式不持锁"的声明不成立；耗电 | 明确取舍并写进文档；或改用 `setExactAndAllowWhileIdle` |
| NAT-08 | `MicGuardService` 返回 `START_STICKY`，与 `microphone` 型 FGS 的 while-in-use 约束冲突 | CONFIRMED | `MicGuardService.kt` | 后台重启时 `startForeground` 可能抛 `SecurityException` 直接崩进程 | 改 `START_NOT_STICKY` |
| NAT-09 | `screenCastStart` 无超时、无异常兜底：授权结果不投递或 `startActivityForResult` 抛错时 `pendingCastResult` 永挂 | CONFIRMED | `NativeBridgePlugin.kt` / `MainActivity` | 该 Activity 生命周期内**永久**返回 false（并被记成"用户拒绝"） | 加超时 + `finally` 清理 |
| NAT-10 | `device.alert` 在通知权限被拒时仍返回 `true` | CONFIRMED | 原生 `deviceAlert` | 远程"找回告警已展示"是假成功 | 按真实结果回执 |
| NAT-12 | iOS：22 个桥方法无实现（静默 no-op），且 `exactAlarmSupported()` 恒 false | CONFIRMED（静态） | `ios/Runner/*.swift` vs Dart 调用点 | iOS 上 22 个功能静默失效；永久显示"精确闹钟权限未开启" | 逐方法实现或显式返回"不支持" |

## 质量与门禁（6）

| ID | 标题 | 证据 | 位置 | 影响 | 修复指向 |
|---|---|---|---|---|---|
| QUA-01 | VC05 失败后补了测试但**从未复跑**，R93 目前没有绿色门禁证据 | **CONFIRMED**（`_pt/r93gate.log`） | 见 `08-test-results.md` §2 | 无法确认 R93 是否真的绿 | 重跑门禁取证 |
| QUA-03 | `gates.ps1` 的压测层缺少"失败重跑 + 负载定性"，与 `gates.sh` 判据不等价，且 GEC 锁明确不覆盖 | CONFIRMED | `gates.ps1:170` vs `gates.sh:636/746` | 用 ps1 跑会得到不同的红绿结论 | 补齐或明确声明为"快速通道" |
| QUA-04 | CI 零测试 / 零 analyze，唯一质量门是"人记得本地跑 `gates.sh`" | CONFIRMED | `ci.yml:11-19`（自述）+ `gate_entrypoint_consistency_test.dart:113-136`（GEC-06 锁死该形状） | PR/push 无任何自动化测试门 | 需先改 GEC-06 锁，再恢复测试步骤 |
| QUA-05 | R93 的核心可诊断性改进零测试覆盖，被 98.98% 的聚合数字掩盖 | **CONFIRMED**（`coverage/lcov.info` `DA=0`） | `vibrate_session.dart:184-185` | 新逻辑从未被执行过 | 补测试驱动该分支 |
| QUA-06 | R93 改了 `lib/**` 但全库文档基线未回刷；CHANGELOG 残差与实测自相矛盾，现有机器锁结构性抓不到 | **CONFIRMED** | `CHANGELOG:137/139`、`docs/09:14`、`docs/12`、`docs/17` 等 | 文档与实测漂移（**第二次复发**） | 回刷 + 新增"文档数字==lcov 实测"锁 |
| QUA-07 | `respectDnd` 默认值 true→false 对存量任务静默生效，升级后行为变更无迁移、无提示 | CONFIRMED | R93 改动 | 用户升级后振动行为变了但不知道 | 补迁移或一次性提示 |
