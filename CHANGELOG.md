# 更新日志

本项目的所有重要变更都记录在此文件中。
格式参考 Keep a Changelog，版本遵循语义化版本。

## [1.7.3] - 2026-09-19

> 主题：**真机 arm64 首次跑通设备门禁**（冒烟 4/4）+ 把人工三向覆盖比对
> **机器化**成回归锁（`test/rc_protocol_coverage_test.dart`，9 例）。
> 真机批量安装仍被厂商的**10 秒倒计时确认弹窗**挡住（详见 docs/17 §22）。

### Added（第十六轮：协议三向覆盖机器锁）
- **`test/rc_protocol_coverage_test.dart`（9 例）**：把第十三/十五轮靠人工做的
  「三向覆盖比对」（端点处理 / 控制器发送 / UI 消费）变成**功能层门禁的机器不变量**。
  直接解析 `lib/remote/protocol.dart` 的类体取出全部 `RcCmd`/`RcEvt` 常量，逐条断言：
  - `RcCmd`：端点有 `case` / 在 `RcPermGate.requiredPerm` **显式登记** / 有发送方；
  - `RcEvt`：端点会发出 / 有人消费 / **App 内**（非仅 `tool/`）有人消费。
  另含两个**防登记表腐烂**用例：缺口修复后必须删除登记条目，否则红。
  **为什么值得单独锁权限闸门**：`requiredPerm` 末尾是 `_ => denyAll`（正确的
  失败关闭），代价是漏登记**不编译报错**、只在协助会话里表现为"命令被静默拒绝"
  —— 正是最需要回归锁的静默降级。
- 新增 `test/rc_protocol_coverage_test.dart` 的**缺口登记表**，逐条写明理由与解除条件
  （见下方 Known Issues）。

### Verified（第十六轮：真机 arm64 首次设备端验收）
- **真机 `960f853`（Xiaomi `23116PN5BC` / arm64-v8a / Android 16 / SDK 36）
  冒烟测试 4/4 全绿** —— 此前所有设备端数字均来自模拟器 x86_64。
  `flutter test integration_test/app_smoke_test.dart -d 960f853` → `+4 All tests passed!`
  含「应用启动并渲染守护仪表盘」「底部导航五页可达」「音源库页面在真实运行时渲染
  （BUG-047 改动的设备端验证）」「端到端：任务定义 → 物化 → 计划条目可执行语义」。
- 真机前置侦察复核：`adb install` 曾两次 `Success`（说明「USB 安装」已开），
  设备处于**真实 5G**（Wi-Fi 关）。

### Known Issues（第十六轮新增，均为 P3 观察项）
- **BUG-050（P3）`RcEvt.callMissed` 是死常量**：协议注释写明"未接由控制器判定"，
  但主叫侧**没有接听超时**，故端点侧也无从发出、无人消费。用户可见后果：
  被叫未开启自动接通时，主叫会**无限等待**且没有任何"未接"反馈。
  同时 `rc.call`（状态镜像）在 **App 内也无消费者**（仅桌面 E2E 工具消费）——
  两者同源，应一并修复。已登记进覆盖锁的缺口表。
- **`rc.script`（指令组状态）App 内无消费者**：仅 `tool/rc_e2e_controller.dart`
  （RC-11/12）消费，控制台看不到执行进度（端点侧靠通知栏自证）。已登记进缺口表。

### Changed（第十六轮）
- 版本号四处同步：`pubspec.yaml` `1.7.3+14` / `AppMeta.version` `1.7.3` /
  本文件顶部 / `HANDOVER.md` 标题。

## [1.7.2] - 2026-09-19

> 主题：**远程音源库可点选播放** —— 修复 `sound.play` 点名被静默替换
> （BUG-048）、接通 `rc.assets`/`rc.presets` 的 UI 消费、版本一致性上锁
> （BUG-049）。真机接入尝试被厂商策略阻塞（详见 docs/17 §21）。

### Added（第十五轮：远程音源库 + 预置分类）
- **`lib/remote/remote_playback.dart`**：`PlaybackSelector`（解析 `sound.play`
  payload，优先级 `assetId` > `preset` > `category`；空串/非字符串视为**未点名**）
  + `resolvePlayback()`（纯解析，`byId`/`byTag`/`any` 由调用方注入）
  + `performRemotePlay()`（解析 → 播放 → 汇总）。
  **不依赖数据库与平台通道**，故整条决策链可在宿主机断言。
- **远程控制台「端点音源库」**：发 `asset.list{limit:50}`，渲染 `rc.assets`
  列表（名称/时长/标签）；**点某一行即以 `sound.play {assetId}` 播放那一条**。
- **远程控制台「预置分类」**：发 `preset.list`，渲染 `rc.presets` 分类 chip，
  点选按 `preset` 播放。两者此前是**端点已实现、控制台无入口也无消费方**的
  预留命令（第十三/十四轮记录的 P2 项）。
- **`test/version_consistency_test.dart`**：强制 `pubspec.yaml` / `AppMeta.version`
  / `CHANGELOG` 顶部版本三处一致，把"发版收尾靠人肉核对"变成机器不变量。
- `test/remote_playback_test.dart`（**17 例**）+ `test/remote_console_tab_test.dart`
  （**+4 例**，含**链路锁**：控制台实际发出的 payload 喂给端点决策函数，
  断言播放的就是被点选的那一条）。

### Fixed（第十五轮）
- **BUG-048（P2）`sound.play` 的点名被静默替换**：协议声明 payload 为
  `{preset|assetId|category, …}`，但端点 `_playRemote` **只读 `category`**，
  且解析不到时 `path ??= await _anyAssetPath()` 静默回落到"库里最新一条"。后果：
  ①控制器点名播 A，端点播**另一段声音**而回执仍 `ok=true`；
  ②点名分类无匹配音源时点"闹钟"响起敲击声。现改为：**点名了就必须播那一条**，
  解析不到则 `ack(false)` + 可读原因（"无此音源：X" / "分类无音源：X"）；
  只有**完全未点名**时才允许任意一条兜底（v1 兼容）。
  另新增 `_assetPathById()` 按主键精确取音源，审计日志写明解析依据。
- **BUG-049（P3）`AppMeta.version` 长期未随 pubspec 更新**：pubspec 已 1.7.1
  而该常量仍为 `1.7.0-alpha.1`，而注释写着"与 pubspec 保持同步" ——
  远程 `status`/`device` 回执上报的是**过期版本号**。已同步并加锁（见上）。
- **门禁脚本设备选择加固**：`scripts/gates.sh` 新增 `pick_device()`，
  显式 `DEV=` 优先、否则**优先模拟器**。原因：真机存在 ≠ 能跑设备门禁
  （厂商策略可禁止 adb 安装），"取第一台设备"会给出看不懂的红。
- **`test/assist_join_screen_test.dart` 视口脆性**：该文件用默认 800×600 视口，
  而控制台是 `ListView`（屏幕外条目**不构建**），断言隐含依赖"所有按钮都在首屏"。
  新增两个入口后「停止指令组」被挤出首屏 → `Found 0 widgets`。
  修法：`mount()` 设 1200×4000 视口（与 `remote_console_tab_test.dart` 一致）。

### Verified（第十五轮实测）
- `flutter analyze` → **No issues found!**（9.4s）
- `flutter test --exclude-tags perf` → **361/361**（336 → +25）
- `flutter test --tags perf --concurrency=1` → **24/24**
- `bash scripts/gates.sh` → **PASS/PASS/PASS、EXIT=0**
- 用例总数 **360 → 385**
- **证伪（四探针，全部确认"能失败"后还原）**：A 点名未命中改回静默回落 →
  3 例失败（`Actual: '/x/newest.wav'` 具象复现）；B `named` 忽略 `assetId` →
  6+ 例失败；C 控制台改发 `category` → 1 例失败（链路锁）；
  D `_playRemote` 恢复旧实现 → 2 例失败（源码契约锁）。探针残量 0。

### Known Issues（第十五轮）
- **真机路径仍阻塞，但阻塞点已变更**：设备侧需开启
  「USB 安装」（需登录小米账号）+「USB 调试（安全设置）」。
  在此之前 `adb install` 恒报 `INSTALL_FAILED_USER_RESTRICTED`，
  且 `input keyevent` 缺 `INJECT_EVENTS`（无法用 UI 自动化绕过）。
  就绪后可直接复用已备好的 debug APK 与 `tool/rc_e2e_controller.dart`。


## [1.7.1] - 2026-09-19

> 主题：**交付收口** —— 统一门禁脚本（一条命令跑完全部门禁）、三向覆盖复扫
> （BUG-046）、音源库导入的批量写入与原子性（BUG-047）。

### Added（第十三轮：统一门禁脚本）
- **统一门禁脚本**（scripts/gates.ps1 + gates.sh）：analyze/功能/压测三层 +
  可选设备端（-WithDevice）+ 可选 AOT 验收（-WithAot）；失败 EXIT=1，
  本地与 CI 同一判据。含**证伪验证**（注入必败用例 → 三层全红）。
- CI emulator-test 扩为 integration 全套（smoke + 桥接 + assist E2E），
  修复 BUG-045 暴露的"integration_test 不在门禁内"覆盖洞。

### Fixed（第十三轮）
- **BUG-046（P3）**：对讲机"对端已播放"回执（rc.pttAck）端点已广播、
  UI 无消费——PttTab 订阅事件流渲染，取值走 rcPayloadOf（BUG-023 同类）。
- task_wire 两处 if 单行块（analyze info 清零）。

### Added（第十四轮：音源库批量写入与原子性）
- **`lib/services/preset_import.dart`**（`AssetLibraryImporter`）：批量音源导入器，
  把「幂等跳过 → 全部落盘 → **一次**写库 → 失败回滚」从界面里抽出来 ——
  界面依赖 `FilePicker` / `rootBundle` / `path_provider` 无法在宿主机跑，
  而"失败会不会留下半套库"恰恰是唯一值得写回归锁的性质。
- **`AssetRepository.upsertMany`**（`batch()` 单事务 / 单次平台往返）+
  **`AssetRepository.nameSet()`**（只取 `name` 一列，作幂等判据）+
  **`AudioAsset.toRow()`**（`upsert` / `upsertMany` 共用同一份行映射，防漂移）。
- **`assetRepoProvider`**：音源库界面的唯一数据入口。
- **`test/asset_import_test.dart`（18 例）**：仓储原子性、两条写入路径行映射逐列一致、
  单批调用出口、双回滚路径、清单↔磁盘一致性（60 条 / 12 分类 / 文件存在 / 名字唯一）。
- `integration_test/app_smoke_test.dart` **+1 例**：音源库页面在真实运行时渲染
  （设备端冒烟 3 → 4）。

### Fixed（第十四轮）
- **BUG-047（P2）音源库导入逐条写入、失败留下半套库**：
  - `_importPresets()` 循环内 `await db.insert(...)` × 60 → **60 次平台往返**，
    且第 k 条失败时前面 k−1 条**已落库**（界面提示"导入失败"，列表里却已多出一截）；
  - `_import()`（本地导入）同形，中途失败留下孤儿文件 + 半批记录；
  - `_listAssets()` / 删除按钮直接操作 `db`，而 `AssetRepository` 已存在却只有
    端点服务在用 → 表结构与行映射存在两处漂移风险；
  - 删除音源**只删记录不删文件** → 每次"导入→删除"都攒一个孤儿音频。
  现全部改为：单批写库（原子）、幂等（预置库按名跳过）、失败回滚
  （库内零新增 + 清理已落盘文件）、列表返回强类型 `AudioAsset`、
  删除**先删记录再删文件**。本地导入保持"同名可多份"的原有语义。

### Verified（v1.7.1 交付实测）
- `flutter analyze` 全零；功能 **336/336**；压测 **24/24**（分层运行）；
  `bash scripts/gates.sh` → **PASS/PASS/PASS、EXIT=0**（交付前复核一次）。
- 设备端（emulator-5554 / Android 16）：冒烟 **4/4**、桥接 **6/6**；
  **AOT 绝对验收 `flutter drive --profile` → 6/6、DRIVE_EXIT=0**
  （100 任务物化 **10ms / 预算 500ms**；往返基准 1449µs）。
- 三向覆盖复扫：RcCmd 断链 0（第七轮修复保持有效）。
- **证伪**：门禁脚本注入必败用例 → 三层 `[FAIL]` + `EXIT=1`；
  音源库三探针（改回逐条写库 / 改回逐条 saveAll / 去掉回滚）分别使 1 / 4 / 2 例失败，
  其中探针 B 实测 `Actual: [[AudioAsset], [AudioAsset]]` **具象复现"半套库"**，
  随后全部还原。
- 用例总数 **342 → 360**（功能层 +18）。

## [1.7.0-alpha.1] - 2026-09-18

> 主题：**信息架构重构 + 临时协助会话（S1–S5 全链路）**。
> 远程能力从「一个藏在二级页里的调试面板」提升为一等公民，
> 并新增 ToDesk 式「临时码 + 访问密码」接入。

### Added（S3/S4/S5 补全，2026-09-18）
- **S3 控制端接入（完成）**：
  - `lib/remote/assist_join.dart`：`AssistJoinClient` —— 用临时码+密码派生
    会合主题与方向密钥、发 `assist.hello` 并**重试**（MQTT SUBSCRIBE 生效有
    往返延迟，单发一次在真实网络上经常石沉大海）、处理
    `accept/reject/perm/close`、跟随端点权限位、TTL 到期自动收敛。
    控制端**无法**自行提权或延长 TTL。
  - `lib/remote/command_channel.dart`：`RcCommandChannel` 抽象
    （`PairedChannel` / `AssistChannel`）—— 让同一个控制台既能驱动已配对端点，
    也能驱动协助会话，避免出现第二份必然漂移的命令面板。
  - `lib/features/remote/assist_join_screen.dart`：输入码+密码 → 握手 →
    **复用 `RemoteConsoleTab`** 的控制台，含会话横幅与挂断。
  - 端点服务按**主题精确路由**：一台设备可能同时托管会话又接入别人的会话。
- **S4 控制端审计视图（完成）**：`AssistJoinClient` 维护本会话收发轨迹
  （FIFO 上限 200），接入页新增「会话审计」面板，展示发出的命令与
  **端点拒绝原因** —— 否则使用者只会看到"点了没反应"。
- **S5 可选 TURN + 无 TURN 降级（完成）**：
  - `RemoteStore` 新增 TURN 配置（地址/账号/密码），默认**不内置**公共中继
    （中继会经手媒体流量，交由使用者自建）。
  - `CallService.iceServers()` 组装 STUN + 可选 TURN；**STUN 不被 TURN 顶掉**
    （打洞成功时不该绕中继）。
  - ICE 失败时给出**可操作**提示：未配置 TURN → 指向对称 NAT 与配置入口；
    已配置 → 转向排查 TURN 与 UDP 放行。
  - 「远程 → 设置」新增 TURN 中继配置项。
- **BUG-020 收尾**：远程控制台补 `script.stop`（「停止指令组」）入口，
  门控位 `script`。
- **`test/perf_bench.dart`**：性能测量辅助库（预热 + 取 N 次最小值）。
- **`integration_test/assist_e2e_test.dart`**：协助会话**真实 broker** 端到端集成
  测试 —— 端点跑真实的 `RcEndpointService` + `RcAssistHost`，控制端用**第二条
  独立 MQTT 连接**绑真实的 `AssistJoinClient`，两条连接在公网 broker 上互相投递
  （无进程内捷径）。实测在模拟器上全流程通过（8s）：握手 → `accept`（两端
  sessionId 一致）→ 默认全拒 → `ping` 回执走会合主题 → 未授权命令被显式拒绝 →
  审计双端留痕 → 放行同步 → 挂断通知端点终止。

### Fixed（2026-09-18）
- **BUG-031（P1）首次配对必然失败**：`RemoteStore.paired()` 在空表时返回
  `const []`（不可变），而 `addPaired` 写的是 `[...paired()..removeWhere(...), e]`
  —— 级联修改不可变列表抛 `Unsupported operation`。调用方
  `pair_qr_screen._pairFromUri` 无 try/catch，异常吞掉了其后的 `setState`，
  表现为**扫码后界面毫无反应、也不报错**。修复：`paired()` 始终返回可变新列表，
  两个方法改用 `where` 过滤。同时把"重新配对"改为**原位覆盖**（原实现会追加到
  末尾，而控制台默认选中 `paired().first`，等于悄悄换掉默认目标设备）。
- **BUG-030（P2）权限变更不刷新控制台**：端点放行/收回权限后按钮灰化停留在
  旧值。修复：`RcCommandChannel` 增 `updates` 流，控制台订阅后重建。
- **BUG-032（P3）审计顺序依赖传输延迟**：`send()` 在发布完成后才记账，
  快通道上"收到"会先于"发出"落账。修复：先记后发。
- **BUG-033（P3）性能用例测的是 JIT 冷启动**：`flutter test` 跑 JIT 而非 AOT，
  首次执行把编译成本算进墙钟；且多为单次采样。修复：预热 + 取最小值
  （**不放宽阈值**）。
- `remote_screen` 跨 `await` 使用 `BuildContext` 的 lint。

### Fixed（NFR-04 AOT 验收轮，2026-09-18）
- **BUG-035（P2）设备上日志写入吞吐不达标**：AOT 实测
  `exec_logs 5000 条写入` = **7755ms**（预算 3000ms，超标 2.6×），
  且两次复跑位级一致（稳定非噪声）。根因：`append` 逐条 `insert`，
  每次调用 = 一次 `Dart→平台通道→原生 SQLite` 往返（**≈1.5ms/次**）——
  交叉验证：5000 次 append = 7755ms（1.55ms/次）与 1000 次 CRUD 调用
  = 1477ms（1.48ms/次）成本一致，故瓶颈是**往返**，不是磁盘/索引/PRAGMA。
  修复：新增 `LogRepository.appendMany()`，用 `batch()` 把整批压成**一次**
  平台调用（范式与 `OccurrenceRepository.commitAll` 一致）。
  **效果：7036ms → 275ms（25.6×）**，原预算从"不可达"变为 10.9× 余量达标。
- **BUG-036（P3）JIT 性能套件误用 AOT 绝对阈值**：两个 JIT 套件的文件头都写明
  "不承担绝对验收、绝对验收在 AOT"，断言却仍套用 NFR 绝对预算
  （100 任务 ≤500ms 等）。AOT 实测 15ms vs JIT 510ms（相差 34×），
  "JIT ≤500ms" 不可满足 → 门禁在阈值边缘随机红绿（本轮 22/24）。
  修复：JIT 侧阈值改为「**实测 JIT 基线 × 3**」的数量级护栏
  （1500 / 8000 / 16000ms），绝对验收归位 AOT。

### Fixed（远程控制台审计轮，2026-09-18）
- **BUG-037（P2）设备快照永久为空 + 端点日志链路两端皆断**：控制台早就有
  「设备快照回执」卡片（电量/充电/待执行数/版本），但 `_lastDevice` 只由
  `rc.device` 赋值，而 `rc.device` 只在响应 `device.status` 时产生
  —— **全项目无任何一处发送该命令**，卡片永久不可见，
  `device.status` 与 `_sendDeviceStatus` 都是不可达代码。
  同类：`logs.recent` → `rc.logs` **收发两端皆断**（端点有处理器、
  控制端不发送也不消费）。修复：控制台新增「**设备状态**」「**端点日志**」
  两个入口、消费 `RcEvt.logs`、新增日志回执卡片（含空列表提示与时间戳占位）。
  这两项是 BUG-020 遗留清单里**唯一被漏掉**的一条。
- **BUG-038（P3）`_pendingAcks` 无界增长**：`_send()` 默认 `trackAck: true`，
  但 `status.get` / `device.status` / `location.get` / `logs.recent` 的响应是
  **专用事件**、端点不回 `rc.ack` → 条目永不清理，随使用次数线性增长。
  修复：这四条命令改传 `trackAck: false`（`ping` 原本即如此）。

### Changed（2026-09-18）
- `RcPermGate`（命令 → 所需权限位）从 `RcAssistHost` **上移到协议层
  `assist.dart`**：控制端需要同一张表来灰化按钮，端点侧需要它拒绝越权命令，
  两份必然漂移。`RcAssistHost` 只做转发。
- `RemoteConsoleTab` 改为面向 `RcCommandChannel`（不传 channel 时行为与改造前
  完全一致）。
- `AssistJoinClient` / `AssistJoinScreen` 增加可注入实例（单测需要互不干扰的
  实例与假传输）。
- 测试总数 **179 → 325**（新增 82：S3 接入 44 + 控制端 UI 11 + 配对表/TURN 13 +
  ICE 8 + appendMany 回归 2 + 远程控制台 4；另 +2 为 BUG-039 离线哨兵回归，
  +23 为条件层/音频焦点，+39 为 `NativeBridge` 宿主机契约回归锁；
  +6 为设备端桥接验证 —— 后者在 `integration_test/`，不计入 `test/` 静态总数）。
  > 注：中途文档曾记为 261 / 284 / 286，实为逐轮递增；差异来源见 docs/12 §18.9。
- **`RemoteConsoleTab` 首次有测试**（`test/remote_console_tab_test.dart`）：
  借 `RcCommandChannel` 抽象注入假通道，无需真机与 broker。

### Added（行业对标轮：条件层扩展，2026-09-18）
- **条件层新增「通话中不执行」（默认开启，安全默认）**：定时/随机音频若在通话中
  触发，声音会灌进通话里，对双方都是干扰且使用者无法预期。行业领先的自动化工具
  （MacroDroid 的 *Call State* 约束、Tasker 的 *Call* 状态）都把通话状态作为一等条件。
  - 判定走 **`AudioManager.getMode()`（MODE_IN_CALL / MODE_IN_COMMUNICATION）**，
    **不需要任何权限** —— 刻意不用需要 `READ_PHONE_STATE` 的 `TelephonyManager`
    （一个"定时放音"工具没有理由申请"读取通话状态与手机身份"，docs/08 最小权限）。
    对 VoIP/视频通话同样有效，覆盖面比只认蜂窝通话更广。
  - **对历史任务同样生效**：`TaskCondition` 缺键取 `true`，且引擎对
    `condition == null` 的老任务用默认条件兜底（而非直接放行），
    不存在"没配过条件就漏掉"的洞。编辑器显式关闭时落库 `skipInCall=false` 覆盖默认。
- **条件层新增「仅 Wi-Fi 下执行」**（补齐源码中"需 connectivity_plus，列入 v1.4"的
  遗留 TODO）：**不引入新依赖**（规避 AGP9 插件兼容矩阵风险），改为扩展自有
  `native_bridge` 插件，用 `ConnectivityManager` + `NetworkCapabilities`
  （替代 API 29 起废弃的 `NetworkInfo.getType()`）实现。仅新增
  `ACCESS_NETWORK_STATE`（normal 权限，安装即授予、无运行时弹窗）。
- **`NativeBridge` 新增 `isInCall()` / `networkType()` / `isOnWifi()`**。
- **`TaskCondition.firstUnmet()`**：返回**首个未满足条件**的人话原因，
  用于审计（原来是返回 `describe()` = "配了哪些条件"，排障时答非所问）。

### Fixed（行业对标轮，2026-09-18）
- **媒体通道音频焦点用错类型**：原实现对 `media` 与 `alarm` 都用
  `AndroidAudioFocusGainType.gain`（**永久抢占**）。对 alarm 合理（必须被听见），
  对 media 是错的 —— 会让使用者正在听的音乐**暂停再恢复**，是明显的体验损伤。
  依据 Android 官方《管理音频焦点》，短提示音应请求
  `gainTransientMayDuck`（他人**降低音量继续播放**）。
  已抽成 `PlaybackService.focusGainFor(channel)` 纯函数并加测试锁定 ——
  这条决策藏在 `AudioSession.configure` 参数里，**改错不会编译报错也不会抛异常**，
  只会"听起来很烦"，没有自动化信号能捕获。
- 删除 `TaskCondition.evaluate()` 上永远无法写入的死参数 `reasonOut`
  （Dart 字符串不可变，该参数不可能被回写）。

### Verified（v1.7 条件层**设备端验证**轮，2026-09-18）
- **新增 `integration_test/native_bridge_test.dart`（6 例）**：让 v1.7 新增的
  Kotlin 桥接方法（`callState` / `networkType`）**首次在真实 Android 运行时执行**，
  而非只验证编译通过。运行方式：
  `flutter test integration_test/native_bridge_test.dart -d emulator-5554`。
- **用模拟器制造真实通话覆盖 `MODE_IN_CALL` 分支**：
  `am start -a android.intent.action.CALL -d tel:10086` →
  `dumpsys audio` 显示 `MODE_IN_CALL`、`mCallState=2`。
  **同一套用例跑两次**，两次都全绿且取值正确翻转：
  空闲 `isInCall=false` / `firstUnmet=不在 Wi-Fi 下`；
  通话中 **`isInCall=true`** / **`firstUnmet=通话中（不打扰通话）`**。
  挂断后 `Audio mode` 回到 `MODE_NORMAL`（反向验证）。
- **"零权限判定通话"获三方证据**：`dumpsys package` 实读 16 项声明权限、
  **检索 `PHONE_STATE`/`READ_PHONE`/`CALL_LOG`/`PROCESS_OUTGOING` 零命中**；
  运行时 `Permission.phone = denied`；在此前提下 `isInCall()` 仍正确区分两态。
  同时确认 `ACCESS_NETWORK_STATE` 为 install-time `granted=true`（normal 权限）。
- **桥接调用成本实测**：600 次调用 1367ms（空闲）/ 1170ms（通话中）
  ≈ **2.0–2.3ms/次**，与 BUG-035 的"每次平台通道往返 ≈1.5ms"同量级。
  推论：一次条件评估（`isInCall` + `isOnWifi`）≈ **4ms**。
- **门禁**：`flutter analyze` No issues found!；非性能 **262/262**；
  性能 **24/24**；设备层 **6/6 × 2 种状态**。
- **计数更正**：`test/remote_console_tab_test.dart` 实为 **6 例**（含 BUG-039 的 2 例），
  此前文档只记 4 例 → 基线由 260/284 更正为 **262/286**（见 docs/12 §18.9）。

### Fixed（v1.7 条件层设备端验证轮，2026-09-18）
- **BUG-040（P3）`networkType()` 的 Dart 契约漏了 `vpn`**：Kotlin 实现会在
  `TRANSPORT_VPN` 分支返回 `vpn`，而 Dart 文档只列了
  `wifi / cellular / ethernet / none / other / unknown`。契约与实现不一致会让
  后续维护者对 `isOnWifi()` 的语义做出错误推断。修复：补全文档枚举，写明
  **判定顺序为 wifi → cellular → ethernet → vpn（物理承载优先）**，
  并显式标注 `vpn` 分支**尚未在设备上验证**（需真机 + 实际 VPN）。
  `NB-02` 的枚举断言即为此设的守卫。
- **BUG-039（P2）`rc.offline` 离线哨兵无 UI 消费**：端点服务已正确识别 broker
  的 LWT 哨兵并随事件转发 `peerId`/`peerName`，docs/14 也把"LWT 离线哨兵"列为
  可用性特性，但**界面上完全看不到** —— 使用者点命令后毫无反馈，只会以为
  "点了没反应"。修复：`_offlinePeers` 跟踪各对端在线状态 + `_offlineBanner()`
  离线横幅（说明"命令将入队，端点上线后自动执行"）+ 心跳恢复后自动消失；
  2 例回归测试覆盖"显示/恢复"与"其它端点离线不误报"。

### Verified（网络分支设备端验证轮，2026-09-18）
- **用模拟器内置虚拟 AP 造出 Wi-Fi，无需真机即可验证网络类型判定**：
  `adb shell cmd wifi connect-network AndroidWifi open`（连上后
  `dumpsys connectivity` 显示 `Active default network: 101 / ni{WIFI CONNECTED} /
  Transports: WIFI`），`adb shell svc wifi disable` 回落移动网络（`100 / MOBILE[NR]`）。
- **同一套设备端用例跑三次构成 A→B→A 往返**，每次 `+6 All tests passed!`：

  | 运行 | `networkType()` | `isOnWifi()` | `firstUnmet()` |
  |---|---|---|---|
  | 移动网络 | `cellular` | `false` | `不在 Wi-Fi 下` |
  | **Wi-Fi** | **`wifi`** | **`true`** | **`null`**（全满足） |
  | 关 Wi-Fi 回落 | `cellular` | `false` | `不在 Wi-Fi 下` |

  R2 证明 `wifi` 分支成立；R3 证明取值**跟着真实网络状态走**。
- **新增 `test/native_bridge_test.dart`（39 例）**：`NativeBridge` 此前**零覆盖**
  （本仓库此前没有任何测试用过 mock channel）。用
  `TestDefaultBinaryMessenger.setMockMethodCallHandler` 锁三层：
  ①通道/方法名**字面量**（拼错只会得到静默 `null`）；
  ②每个方法在「有值 / 返回 null / 抛异常 / 无实现」四种输入下的契约；
  ③桥读数 × `TaskCondition` 的**最终决策**（用户可见面是"拦不拦"）。
  顺带补齐既有方法的降级默认值（`exactAlarmSupported` / `setExactAlarms` /
  `serviceShouldRun` / `isIgnoringBatteryOptimizations` / `setVolume`）。
- **回归锁证伪（三个探针，全部确认"能失败"后恢复）**：探针 A（`null`→`false`）3 例失败；
  探针 B（`callState`→`callStateX`）NB-H01 失败；探针 C（`unknown`→`false`）2 例失败，
  其中串联用例 `Actual: '不在 Wi-Fi 下'` **实测复现了 BUG-041 的用户可见后果**。
- **门禁**：`flutter analyze` No issues found!；非性能 **301/301**；性能 **24/24**；
  新文件 **39/39**；设备层 **6/6 × 3 种网络状态**。用例总数 **286 → 325**。

### Fixed（网络分支设备端验证轮，2026-09-18）
- **BUG-041（P2）`isOnWifi()` 把"无法判定"当成了"不满足"**：`networkType()` 的
  `unknown` 语义是**无法判定**（原生取不到 `ConnectivityManager`、或拿到活跃网络
  却读不出 capabilities；桥不可用时 Dart 侧也回落到它），但原实现让 `unknown`
  落到 `false` —— 而 `false` 在条件层是**"确定不在 Wi-Fi 下"** → 任务被拦下，
  审计写 `不在 Wi-Fi 下`（一个我们并不知道的原因）。
  这直接违反 `TaskCondition` 文档写明的约定（"无法判定时按满足处理……
  不会因为某个平台读不到状态就把全部自动化静默停掉"）——
  **"读不到"被误报成了"不满足"**，后果是静默跳过自动化 + 错误审计原因。
  修复：`if (t == null || t == 'unknown') return null;`，并写明
  `none`（确实没有活跃网络 → `false`）与 `unknown`（读不出来 → `null`）的差别。

### Added（任务批量写入轮，2026-09-18）
- **`TaskRepository.upsertMany(Iterable<Task>)`**：单事务 / **单次平台通道往返**的
  批量写入 API。空集合直接返回，不产生任何数据库操作。
  同时抽出 `static Map<String, Object?> _row(Task t)` 供 `upsert` / `upsertMany` 共用，
  **避免两条路径的行映射漂移**（`trigger_json` / `action_json` / `asset_ids`）。
- **`test/db_repository_test.dart` +5 例回归锁**：条数与字段完整 / 保留条件层 JSON
  （`requireWifi`、`skipInCall`）/ 空集合不产生写入 / 同批重复 id 幂等 /
  **原子性：提交前失败不留下半批数据**。

### Fixed（任务批量写入轮，2026-09-18）
- **BUG-042（P2）`TaskRepository` 无批量 API**：任务导入流程
  （`settings_screen.dart`，唯一的生产调用方）逐条 `await repo.upsert(task)`，
  500 条 = **500 次平台通道往返**；且**中途失败会留下半批数据** ——
  使用者在设置页看到"导入失败"，回任务列表却发现已多出一截
  **处于启用状态**的任务（会真的按计划放音）。
  修复：导入改为先解析到列表再 `await repo.upsertMany(parsed)`。
  AOT 实测 500 条写入 **1797ms → 170ms（10.6×）**（热机 936 → 101ms）。
  > **第一收益是原子性，第二才是速度**：`batch()` 单事务提交，
  > 中途任何一条出错都一条不落库。逐条循环做不到。
- **BUG-043（P2）`任务 CRUD 500 次` 是"冷启必红"的假门禁**：
  模拟器冷启后首跑 AOT 得 `3340ms / 预算 2000ms → OVER`。排查确认**非代码回归** ——
  同一次运行里**本轮未改动**的 `exec_logs` 逐条路径**同步**劣化
  1.55 → 2.475ms/次（**1.6×**），热机复跑 1764ms 落在上一轮记录区间（1477–1679ms）内。
  根因：逐条 DB 路径成本 **∝ 平台通道往返次数**，而单次往返成本随机器状态浮动 1.6×，
  2000ms 预算在热机下余量仅 **1.13×** → 冷启必红。与 BUG-034/036 同源
  （阈值口径 ≠ 测量条件）。修复：基准测量提前，逐条路径预算改为
  **「本次实测往返成本 × 调用次数 × 3」自归一化**，与机器冷暖解耦，
  同时仍能抓结构性回归（每次调用多一次往返 = 工作量翻倍 → 超 3× 余量）。
  基准行自身**不**归一化（否则等于"3× 自己"、恒真），保留 4ms/次 绝对护栏。
  验证：归一化后复跑，该次每次往返 **2587µs（比冷启那次 2475µs 还慢）**，
  CRUD 2833ms 按旧预算仍是 OVER，新预算 7762ms → **PASS**。

### Verified（任务批量写入轮，2026-09-18）
- 原子性回归锁**已证伪**：临时把 `upsertMany` 改回逐条 `insert()` 循环，实测
  `Actual: [Instance of 'Task', Instance of 'Task']` —— 残留**恰好 2 条**，
  既证明断言非恒真，也**具象复现了 BUG-042 本身**；随后恢复并 grep 复核。
- **AOT 新增同工作量对照**（`integration_test/perf_nfr_test.dart`）：
  `任务 500 条逐条写入` vs `任务 500 条批量写入`（唯一变量 = 往返次数）。
- 门禁：`flutter analyze` No issues found!；非性能 **306/306**；性能 **24/24**；
  `flutter build apk --profile` RC=0（151.1s / 149.6MB）；
  `flutter drive --profile`（perf_nfr_test）→ **5/5**。用例总数 **325 → 330**。

### Added（条件层每轮复用轮，2026-09-18）
- **`lib/services/condition_env.dart`**：`RoundConditionEnv` —— 一轮内的平台环境
  快照缓存。**惰性**（首次需要时才读；一轮里没有任务需要评估条件时零读取），
  且缓存的是 **Future 而非结果值**（并发在途取值也只读一次）。
  暴露 `readCount` 作为"每轮只读一次"这一性质的**可断言出口**。
- **`ConditionEnv`**（`lib/domain/models/condition.dart`）：条件评估所需的
  四个**平台来源**输入（电量/充电/通话/网络）的值对象。默认值逐字复刻
  改造前引擎初值，因此"平台读不到"时的行为与改造前**完全相同**。
- **`TaskCondition.firstUnmetIn(ConditionEnv, {required DateTime now})`**：
  消费已读好的快照做判定，逻辑**完全复用 `firstUnmet`**（不存在两条路径漂移）。
- **`test/condition_env_test.dart`（12 例）**：复用机制 / 默认值契约 /
  8 条件 × 8 环境 = **64 组穷举等价性** / `now` 不进快照 / 判定优先级。
- **`integration_test/perf_nfr_test.dart` 新增 AOT 用例**：
  `条件评估 50 任务：逐任务读取 vs 每轮复用`（用**真实** `Battery` + `NativeBridge`）。

### Fixed（条件层每轮复用轮，2026-09-18）
- **BUG-044（P3）条件评估成本随任务数线性增长**：一次条件评估要读 4 次平台状态
  （电量/充电/通话/网络），每次 = **一次平台通道往返**；而引擎一轮
  `executeDue()` 会遍历**所有**到期计划 → **4N 次往返**。单任务看 ≈4ms（可忽略），
  但 50 个任务 ≈580ms、500 个 ≈5.8s，且**全部花在重复读取同一个物理环境上**。
  修复：拆成 `readConditionEnv()`（读一次）+ `conditionFailedIn(task, env)`（纯判定），
  两个遍历循环（`executeDue` / `onSoundEvent`）各持一个 `RoundConditionEnv` 快照。
  **`now` 刻意不进快照** —— 它是本地时钟（无平台通道开销），
  实时取值让时段窗口判定更准。AOT 实测 **584ms → 17ms（34×）**，
  且从 4N 次往返变为**固定 4 次，与 N 解耦**。
- **BUG-045（P2）设备冒烟测试自 v1.7 IA 重构起一直红**（本轮跑回归时发现）：
  1. **合规承诺对话框未关闭** —— 它是 `barrierDismissible: false`，会挡住底部导航
     点击；而 `flutter test integration_test/...` **每次都会卸载应用**，
     `SharedPreferences` 的"已确认"标记随之清空 → 该对话框**每次必现**（非偶发）。
     修：新增 `_dismissComplianceIfPresent()`，导航前先确认。
  2. **导航标签是 IA 重构前的旧值** —— 用例仍在找「任务 / 音源 / 守卫」，
     而 v1.7 定稿为 **5 TAB：守护 / 自动化 / 远程 / 日志 / 设置**
     （`lib/core/router.dart` 的 `_Shell._destinations`），前三页已合并进「自动化」
     → `find.text('任务').last` 命中零个控件，抛 `Bad state: No element`。
     修：改用真实标签，并把查找**精确限定在 `NavigationBar` 内**
     （正文里也有「守护」等字样，原来的 `.last` 是碰运气）。
  > **为什么长期没被发现**：`integration_test/` **不在默认门禁内**
  > （`flutter test --exclude-tags perf` 只跑 `test/`），只有手动驱动才执行 ——
  > 它红了整整一个 IA 版本。**这是"门禁覆盖面"的洞，不只是用例的 bug。**
  修复后 `flutter test integration_test/app_smoke_test.dart -d emulator-5554` → **3/3**。

### Verified（条件层每轮复用轮，2026-09-18）
- **复用锁已证伪**：把 `RoundConditionEnv.value` 退回"每次都读"，实测
  `Expected: <1> / Actual: <7>`（7 个任务读 7 次）与
  `Expected: <1> / Actual: <3>`（并发 3 个调用者各读一次）；随后恢复并 grep 复核。
- **AOT（真实平台读取，`flutter drive --profile`）**：
  `条件评估 50 任务 逐任务读取` **584ms** → `每轮复用` **17ms**（34×），
  用例内直接断言本轮实际平台读取 **1 次**。
- 门禁：`flutter analyze` No issues found!；非性能 **318/318**；性能 **24/24**；
  `flutter drive --profile` → **6/6**；设备冒烟 **3/3**。用例总数 **330 → 342**。
- **本轮踩坑（已记入 docs/17 §19.5）**：`Edit` 两度 EBUSY **静默不落盘**
  （报 success 但内容不在文件里，其中一次由 `flutter analyze` 抓出）；
  且**自己写的并发用例抓出了自己实现的缺陷**（初版缓存结果值 → 并发击穿"每轮一次"）。

### Known Issues（2026-09-18，未闭环）
- **`ethernet` / `vpn` 两种网络类型未在设备上验证**：`wifi` 与 `cellular` 已通过
  模拟器虚拟 AP 闭环；模拟器造不出以太网/VPN 场景。`vpn` 的语义
  （物理承载优先）已有文档说明与宿主机回归锁，但"真实 VPN 下是否误拦"仍需真机。
  （**通话保护已闭环**：真实通话态下 `MODE_IN_CALL` 检测实测成立。）
- **真机↔模拟器（两个独立 Android 进程）握手未执行**：无真机接入；双模拟器 UI
  自动化在本机不可行（宿主持续重载导致 `System UI ANR`，且无深链只能盲点坐标）。
  **已用真实 broker 单机双连接集成测试覆盖绝大部分链路**
  （`integration_test/assist_e2e_test.dart`，模拟器 + 公网 broker 全流程通过），
  残余未覆盖维度仅「两个不同 Android 进程/机型」。
- **对称 NAT 场景未验证**（S5 验收项）：需真实移动网络双端。
- **真实扬声器出声未验证**：链路上已验到命令被端点接受并进入 `_dispatch`。
- ~~**条件评估的平台开销 ≈4ms/任务**（`isInCall` + `isOnWifi` 各约 2ms）：
  当前每轮对每个到期任务各评估一次，规模小可忽略；若单轮到期任务数上到数百，
  应改为"每轮评估一次并复用"（同一轮内所有任务的环境条件相同）。~~
  → ✅ **第十二轮已闭环**（BUG-044）：`ConditionEnv` + `RoundConditionEnv`
  一轮固定 4 次平台往返、与任务数解耦；AOT 实测 50 任务 **215ms → 3ms**。
- **camera.snap 继续阻塞**：2026-09-18 复核 pub.dev，最新仍为 **camera 0.12.1**
  （2026-09-03），changelog 无任何 AGP9 / 内置 Kotlin 相关条目。
- **`asset.list` / `preset.list` / `task.get` 三条命令"端点有实现、控制器不发"**：
  判定为有意保留（`task.list` 已返回完整定义；音效按钮用固定分类），未加 UI 入口。
- **音源库的孤儿文件**：删除音源时文件已随之删除（第十四轮），但历史上遗留的
  孤儿音频仍留在应用私有目录（不影响功能，未做迁移清理）。
- ~~**`任务 CRUD 500 次` AOT 余量仅 1.3×**（1477–1679ms / 预算 2000ms）：
  同属"每次调用 ≈1.5ms 平台往返"结构。当前未超标，仅记录；
  若调用次数上升需同样改走 batch 路径（`TaskRepository` 暂无批量 API）。~~
  → ✅ **第十一轮已闭环**：`TaskRepository.upsertMany` 已补（BUG-042），
  任务导入改走批量；该行预算亦已自归一化（BUG-043），不再随机器冷暖红绿。
- **性能套件（JIT 层）已全绿**：`flutter test --tags perf --concurrency=1` = 24/24。
  但 JIT 数字只作数量级护栏，**绝对性能判定一律以 AOT 为准**。




### Added（新增）
- **协议 v1.7：远程任务 CRUD（与本机任务完整对齐）**。新增命令
  `task.get` / `task.upsert` / `task.delete` / `task.runNow` /
  `asset.list` / `preset.list`，回执 `rc.task` / `rc.assets` / `rc.presets`；
  `task.list` 增加 `full` 选项以回传**完整任务定义**。
  - `lib/remote/task_wire.dart`：任务线格式（嵌套 trigger/action、bool enabled、
    assetIds 数组）。**入站数据视为不可信**：枚举白名单、数值夹紧、
    集合上限、时间戳合法性；校验失败即拒绝，绝不落库。
  - 端点侧 `task.upsert` 成功后**重新物化 occurrence**
    （先清该任务的旧 pending 计划，再按新定义生成），否则改了触发器
    会出现"幽灵计划"仍在旧时刻响。
  - `task.runNow` 经 `flutter_background_service` 通道转交**引擎隔离**执行
    （插件实例在引擎侧），并把结果回投后才回 `rc.ack` ——
    避免"回执成功但实际没出声"的假阳性。
  - 「远程 → 任务」页与本机任务**共用同一个编辑器**
    （`TaskEditorScreen` 新增远程目标模式，保存动作由调用方注入），
    支持新建/编辑/启停/跳过下一次/立即执行/删除。
- **临时协助会话（S1 完成，docs/18）**：`lib/remote/assist.dart` ——
  9 位临时码 + 8 位 Crockford 访问密码、**密码认证会合主题**、
  双向会话密钥派生、会话状态机与权限位模型。
  安全核心：`topic = assist/hex(SHA-256(code|pw))[0:16]`，只知临时码者
  **无法算出主题**，因此无法观测握手密文 → 不存在离线字典攻击素材。
- **临时协助会话（S2 完成，docs/18）**：端点侧会话托管与端到端接线。
  - `lib/remote/assist_host.dart`：凭据生成、`assist.hello` 握手、
    方向密钥环、TTL 自动终止、5 次失败锁定、逐项权限门控（默认全拒、
    未登记命令**失败关闭**）、全程审计。会话状态纯内存、不落盘（C4）。
  - `lib/features/remote/assist_host_screen.dart`：端点页三态
    （未开启 / 等待接入 / 已接入），大号分组临时码 + 密码、`mm:ss` 倒计时、
    7 个权限开关（默认全关）、一键终止。未接入时**不渲染**权限开关。
  - `RcEndpointService` 改造：`_MqttAssistTransport` 提供字节通道
    （密钥不出托管模块）、按 `topicPrefix` 分流会合主题、
    注入审计（`source=assist`）与端点显示名、重连补订会合主题。
  - **业务命令门控与执行分离**：会话建立后复用 v1 命令集，
    托管侧先做权限门控再回调 `_dispatch`；未授权命令回
    `rc.ack{ok:false}`（否则控制端只看到"点了没反应"）。
  - **回执通道用 Zone 承载**（`assistReplyZone`）：协助对端不是已配对设备，
    收不到 `{deviceId}/evt`，执行层回执必须原路返回会合主题。
    用 Zone 而非实例标志位，是因为协助与配对命令可能**并发在途**，
    标志位会串台。
  - **两处反 DoS 加固**：同一密文重放不计握手失败（`_seenWires` 按密文原文
    去重 —— 消息 ID 要解密后才能读到，而解密失败的报文正是计失败数的那些）；
    会话激活后的垃圾密文不计失败（否则能从端点自身 `accept` 报文得知
    会合主题的 broker 观察者可 spam 5 条锁死会话）。
- `test/assist_session_test.dart`（22 例）：凭据生成/归一化、主题的
  密码敏感性、**主题不可由临时码单独推导**、方向密钥隔离、
  权限默认全拒、TTL 与失败锁定。
- `test/assist_host_test.dart`（33 例）：握手幂等、失败计数与 5 次作废、
  重放不计失败、激活后垃圾不计失败、TTL 终止、过期拒绝、会话替换、
  只读放行/动作默认全拒/未登记失败关闭、`record` 一律拒绝、
  业务命令门控与回执通道、审计与状态广播。
- `test/assist_host_screen_test.dart`（7 例）：端点页三态渲染、
  权限开关默认全关与写回、终止回初始态。
- `test/task_wire_test.dart`（18 例）：六种触发器 / 七种动作往返无损，
  以及畸形输入的拒绝与夹紧行为。
- `lib/core/widgets/section_scaffold.dart`：可复用「分组页 + 二级 TAB」骨架。
- `tool/rc_e2e_controller.dart`：复用项目真实 `protocol.dart` 的端到端
  实测控制器（桌面进程扮演控制端，对真实 App 端点发命令并校验回执）。
- `docs/18`：临时协助会话的行业调研、架构、技术选型与协议扩展方案。

### Changed
- **信息架构（IA）重构，底部导航 6 → 5 TAB**：原「任务/音源/守卫」合并为
  **自动化**，原「日志」+「统计」合并为**日志**，**远程遥控**（含视频通话、
  对讲）成为独立 TAB。理由：Material 3 底部导航建议 3–5 项，超过后触达率
  与可辨识度下降；语义相近功能收进二级 TAB 可在不牺牲可达性的前提下保持精简。
- 五个页面新增 `embedded` 模式（`TaskListScreen` / `SoundLibraryScreen` /
  `GuardScreen` / `LogScreen` / `StatsScreen`），作为子 TAB 时不再自带 AppBar，
  但**保留各自的操作入口**（如音源「导入预置库」、日志「导出 CSV」）。
- **版本号对齐**：`pubspec.yaml` 与 `AppMeta.version` 由 `1.6.1-alpha.1`
  升至 `1.7.0-alpha.1`（`+10` → `+11`）。此前 CHANGELOG 已声明 v1.7.0-alpha.1，
  但两处版本号仍是 v1.6.1，导致构建产物与远程 `status.get` 回执上报的版本
  与实际功能不符（`AppMeta.version` 的注释本就要求与 pubspec 同步）。

### Removed（移除）
- **设置 → 后台保活** 中的「远程遥控 / 视频通话 / 统计看板」三个条目。
  它们只是 `context.go(...)` **导航快捷方式，不含任何保活设置** ——
  放在「后台保活」分区语义不成立；且新 IA 已把「远程」「日志」提升为
  底部一级 TAB，快捷入口纯属冗余。该分区现在只保留真正的保活相关项
  （电池优化白名单 / 精确闹钟权限）。

### Fixed
- **BUG-022：冷启动 `SQLITE_BUSY: database is locked`**。后台引擎跑在
  `flutter_background_service` 的**独立 FlutterEngine** 里，与主 isolate
  不是同一个插件实例 —— `AppDatabase` 的进程内静态单例只能在一个引擎内
  去重，两个引擎各持一条原生连接写同一文件，rollback journal 模式下写锁
  互斥即报错。修复：连接级 `journal_mode=WAL` + `busy_timeout=5000`
  + `synchronous=NORMAL`（`AppDatabase._onConfigure`）。
- **BUG-023：远程回执面板恒为空**。UI 读顶层字段，而业务字段在 `payload`
  之内 → 统一走 `rcPayloadOf()`。
- 移除 `CHANGELOG.md` 中重复的 `[1.5.0]` 段落。
## [1.6.1-alpha.1] - 2026-09-16

> 主题：**打通远程链路**。v1.6 的远程中心与设备控制命令此前只做到
> 「编译通过 + 代码路径存在」，接管审计发现回执链路、密钥派生、执行能力
> 注入三处断裂，功能实际不可用。本轮修复 + 新增 10 例密钥契约回归测试。

### Fixed（修复，均由接管审计发现，详见 docs/17）
- **BUG-021（P0）端点收命令的密钥派生错误**：接收侧此前遍历对端配对表
  用 `peer.secret / peer.deviceId` 派生密钥，与发送方用「接收方身份」
  加密的参数永不相等 → **命令从未被成功解密**。现统一为「按接收方身份
  派生」：接收方用自己的配对码 + 自己的 deviceId 解密。
- **BUG-013（P0）控制器未订阅端点 evt 主题**：回执（rc.pong/rc.ack/
  rc.status/rc.device/rc.location）与通话信令（call.answer/
  call.candidate）全部不可达，视频通话必然停在 connecting。
  新增 `refreshSubscriptions()`：连接建立、心跳、新增配对三处触发订阅。
- **BUG-014（P0）v1.6 远程中心 4 Tab 未接入路由**：`RemoteHomeScreen` 等
  4 个文件为孤儿代码，`/remote` 仍指向 v1.2 旧总览页。现 `/remote` 指向
  远程中心（控制台/指令组/对讲机/通话），旧页迁至 `/remote/settings`
  并由 AppBar 齿轮入口进入（保留模块开关/身份/代理/配对管理）。
- **BUG-015（P1）端点执行能力未注入**：`playHandler`/`ttsHandler`/
  `vibrateHandler` 全库无赋值 → sound.play、指令组 play/tts/vibrate、
  PTT 播放全部空转。现于启动时注入（复用 PlaybackService / FlutterTts /
  NativeBridge），并让预置分类解析内置回落。
- **BUG-016（P1）`volume.set` 原生未实现**：Dart 侧调用但
  `NativeBridgePlugin.kt` 无对应分支 → 恒返回失败回执。现原生补齐
  （媒体/闹钟流，0..1 归一化换算，不触碰铃声音量）并提供
  `NativeBridge.setVolume` 类型化封装。
- **BUG-017（P1）端点服务无自恢复**：应用重启后即使 `rc_enabled=true`
  也不启动端点，导致长期离线。现启动时按状态自动拉起。
- **BUG-018（P2）版本与包名常量过期**：`AppMeta.version` 硬编码
  `1.0.0`、`appPackage` 与实际 applicationId 不符 → 修正为
  `1.6.1-alpha.1` / `com.sonicshield.sonic_shield`。
- 离线哨兵 `rc.offline`（broker LWT 明文）此前无人消费，现解析并广播。

### Added（新增）
- `test/remote_crypto_test.dart`（10 例）：锁定密钥派生契约（cmd/evt 双向、
  旧实现必须失败、方向隔离、配对码不符拒绝）、信封 `from` 序列化、
  时间窗、去重、AAD 绑定主题。
- 控制台在远程模块未启用时给出明确引导卡（端点未运行则命令不会被接收）。

### Changed
- `RemoteStore` 暴露 `pairingCode` / `ensurePairingCode()`，配对码读写统一。
- `RcEndpointService.sendTo` 统一补发方标识（`from`），回执与审计可溯源。

## [1.5.0] - 2026-09-15

### Added（新增）—— v1.5
- **二维码扫码配对**：端点展示本机配对二维码（qr_flutter，含设备 ID/
  名称/持久配对码），控制器 mobile_scanner 扫码即完成配对——
  物理在场即最强同意证明，替代手输配对码（对「免同意控制」需求的
  合法实现，docs/16 §8 安全决策）。
- **RTCVideoView 实时画面**：通话覆盖层接入远端全屏渲染 + 本地
  画中画小窗（镜像），渲染器随通话生命周期初始化/释放。
- 路由 /remote/pair-qr + 远程页扫码入口（手输保留为备用）。

### Fixed
- mobile_scanner 7.x 与 AGP 内置 Kotlin 不兼容（KGP classpath 缺失）
  → 锁定 6.0.11（API 兼容，构建通过）。

## [1.4.0] - 2026-09-14

### Added（新增）—— 视频通话（方案A：WebRTC P2P + MQTT E2EE 信令，docs/16）
- **App 内视频/语音呼叫**已配对端点：flutter_webrtc（DTLS-SRTP 传输加密），
  信令复用声盾 MQTT 端到端加密通道（call.invite/answer/candidate/end）。
- **自动接通**（默认关闭）：被叫端开启后自动接通已配对设备的呼入
  （家人守护场景）；通话页含挂断控制，Overlay 全屏来电界面。
- 自动接通合规红线：仅限本人/已授权设备，接通即亮屏，系统摄像头
  指示灯正常工作，不提供任何隐蔽模式（docs/16 §6）。
- Manifest 新增 CAMERA 权限；设置页新增视频通话入口。

### Security
- 明确拒绝「未经对端同意的静默信任」实现（未授权访问他人设备
  属刑事犯罪）；合法替代方案「二维码扫码配对」列入 v1.5。

### Changed
- Release 包体积 104.7MB（WebRTC native 库 +35MB，符合预期）。
- **性能压测与优化（TDD，docs/12 §9）**：新增 14 用例性能压测套件
  （白盒/灰盒/黑盒三层）；planSeed 优化（10 万次 1.7s→0.6s，
  内联混合免中间分配）；**修复 BUG-012（P0）**：远程模块三处
  List 类型转换运行时崩溃（outbox/savedScripts/paired），
  压测抓出「离线队列上线即崩」缺陷并闭环。
### Changed
- Release 包体积 104.7MB（WebRTC native 库 +35MB，符合预期）。

## [1.3.0] - 2026-09-13

### Added（新增，源自 docs/15 行业调研借鉴矩阵）
- **多轨声景混音**（对标 Tide/Soundscape）：新增 SoundscapeAction（1-4 轨，
  每轨独立音量/循环，总时长到点渐出）；编辑器可视化添加轨道。
- **任务条件层**（对标 Tasker/MacroDroid 条件段）：仅充电/最低电量/
  每日时段窗口；调度与声音触发双入口执行前评估，不满足跳过并审计。
- **任务备份**：导出全部任务为 JSON（含条件与音源引用）+ 导入（默认停用）。
- **指令组模板收藏 + 首页快捷卡**：组装器「存为模板」，仪表盘一键执行。
- **远程离线 outbox**：端点离线时命令入队，连接恢复自动按序冲刷。
- **取证哈希链**：录音文件 SHA-256 写入审计（SHA256=... path=...），
  证据完整性可校验。

### Changed
- 数据库 schema v2（tasks.condition_json 列，onCreate+onUpgrade 双路径）。

## [1.2.0] - 2026-09-13

### Added（新增）—— 远程遥控模块（默认关闭，显式开启）
- **多端点公网遥控**：MQTT 通道（TCP/TLS），设备身份 + 配对码（Crockford
  Base32 ≈40bit）配对；AES-256-GCM 端到端加密（HKDF-SHA256 派生，AAD 绑定
  主题），broker 仅中转密文；时间窗 + 消息去重防重放；LWT 离线哨兵 + 心跳。
- **即时命令**：远程播放指定分类音效、查看/启停任务、跳过下一次、
  守卫开关、状态与日志查询。
- **指令组（宏）远程执行**：组装器（随机播放/语音播报/通知/震动/录音取证/
  **时延** 六类元素，排序/编辑/校验，可由本机任务反向导出）→ 发送后端点
  **立即执行**；通知栏常驻显示发送方/发送时间/步骤进度，带【终止执行】
  按钮，执行完成或终止后 3 秒自动消失；步骤级进度回执；全程审计。
- **对讲机**（v1 整段模式，参考微信语音/Zello）：按住说话（最长 60s，
  AAC）→ 松开自动端到端加密发送 → 端点自动播放并回执。
- 远程总览页：设备身份/代理配置/配对管理/指令组装器入口/对讲/合规提示。
- 文档 docs/14（协议、安全、执行语义、broker 建议、代码地图）。

### Changed
- 通知服务暴露 plugin 句柄以注册远程指令组「终止执行」按钮回调。

## [1.1.0] - 2026-09-13

### Added（新增）
- **渐强唤醒**：播放动作支持音量 5%→目标值线性爬升（0–300 秒可配），
  Sleep Cycle 式柔和唤醒（PlayAudioAction.rampUpSec + 编辑器滑条）。
- **循环填充（声景模式）**：短音效单曲循环填满随机时长（loopFill 开关）。
- **跳过下一次**：任务列表一键跳过最近一条待执行计划（幂等，审计留痕）。
- **日志筛选与导出**：全部/成功/失败/跳过四态筛选；一键导出 CSV
  （最多 5000 条，share_plus 系统分享）。

### Fixed（修复）
- **BUG-011（P1）引擎隔离静默死亡**：未捕获异步异常（插件注册告警、
  单次 DB 抖动）会杀死引擎 isolate，Timer 通道A 停摆、TTS 审计日志
  永远缺失。修复：引擎入口包 `runZonedGuarded`（异常记录不致命）+
  动作执行改为串行 await（occurrence 状态与审计严格一致）+
  TTS 全链路超时保护（无 TTS 引擎平台 15s 超时记 failed）。
  **模拟器实测**：连续 3 次 TTS 触发（17:59:23/38/54）全部执行并审计。

## [1.0.1] - 2026-09-13

### Fixed（修复，均由模拟器端到端验证发现）
- **P0** 通知渠道缺失导致 FGS 崩溃循环：flutter_background_service 指定自定义
  `notificationChannelId` 时不会自动创建 channel（其源码 L89-95）；
  现于应用启动时统一创建全部通知渠道（BUG-007）。
- **P0** 后台服务引擎的 MethodChannel 无 handler：MainActivity 仅注册 UI 引擎，
  引擎隔离排布任务闹钟时 MissingPluginException 被静默吞掉，任务闹钟从未排布；
  新建本地插件 `packages/native_bridge`（path 插件），注册到所有 Flutter 引擎（BUG-008）。
- **P1** 主 FGS 携带 microphone 类型：Android 14+ while-in-use 语义下，
  后台复活的 FGS 携带 microphone 被 SecurityException 拒绝；类型收窄为
  `mediaPlayback|dataSync`，新增 `MicGuardService`（前台启动的 microphone
  类型通行证服务）（BUG-009）。
- **P2** Gradle wrapper 对镜像站 TLS 握手失败：`distributionUrl` 支持本地
  `file://` 发行包（BUG-010）。

### Added（新增）
- **预置音效库**：60 条程序化合成音效（12 分类 × 5 条：敲击/撞击/拖拽/
  门窗/玻璃/人声近似/动物/提示铃/警示/自然/电子/助眠底噪），
  纯 Dart 物理声学合成（`tool/gen_sfx.dart`，固定种子可复现），MIT 零版权；
  音源库页一键导入 + 单条试听。
- 声音守卫 while-in-use 合规方案：前台启动的 MicGuardService +
  状态栏麦克风提示（docs/05 §1.4）。

### Verified（模拟器端到端实测，API 36 x86_64 AVD）
- 合规门/守护开关/FGS 注册（isForeground=true）/任务创建/计划物化 14 条/
  原生精确闹钟排布（`exactAllowReason=permission`）/仪表盘倒计时与系统闹钟一致
- **ST-01 杀进程自愈**：`am kill` 后 5 秒内自动复活并重注册服务
- 真实触发两次执行并完整审计（`schedule · play · failed · 无可用音源`，
  失败为正确语义——未导入音源；导入预置库后即出声）

## [1.0.0] - 2026-09-12

### Added（新增）
- 六种触发方式：固定一次 / 每日 / 每周 / 随机窗口 / 随机间隔 / 声音触发
- 六种动作：播放音频 / TTS 播报 / 通知 / 录音取证 / 震动 / 组合
- 随机化五维：随机时刻、随机日期、随机时长、随机音量、音源加权随机
- 确定性随机引擎（DPRNG）：计划跨重启/重算零漂移
- Android 双通道后台执行：前台服务隔离 + 原生精确闹钟看门狗
- 开机/应用升级自恢复（受控于 should_run 标志）
- 电源管理三档策略 + 低电量自动降级
- 厂商保活引导：小米/华为/荣耀/OPPO/一加/vivo/iQOO/三星/魅族深链 + 兜底
- 声音守卫 v1：能量阈值 VAD（阈值/持续时间/冷却可配，仅本地计算）
- 合规护栏：首启合规门、强制免打扰（22:00–07:00）、冷却下限 60s、全量审计日志
- 六页 UI（守护/任务/音源/守卫/日志/设置），Material 3 + 中文本地化
- 单元测试 41 例（flutter test 全绿）+ 集成冒烟 + 静态分析清零
- GitHub Actions CI（分析/测试/构建/模拟器三段流水线）
- 全套工程文档 docs/00–12（立项/需求/架构/调度/保活/检测/数据/合规/测试/发布/路线图/测试报告）
- 模拟器联测脚本 scripts/emulator_test.ps1|.sh

### Notes（工程备注）
- 开发基准：Flutter 3.47.3 stable / JDK 21 / Android SDK 36（minSdk 24）
- 构建链路已内置国内镜像（Gradle 腾讯镜像 + Maven 阿里云镜像）
- 合规红线：仅限合法个人自动化与自我保护用途，禁止用于骚扰他人（docs/08）
