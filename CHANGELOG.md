# 更新日志

本项目的所有重要变更都记录在此文件中。
格式参考 Keep a Changelog，版本遵循语义化版本。

## [1.9.0-alpha] - 2026-09-22

### Added（新增）—— 振动能力：随机振动 × 持续振动（docs/20）

- **随机振动** `RandomVibrateAction`：一次触发内产生**随机脉冲串** ——
  总时长、单脉冲时长、脉冲间隔、强度各自在区间内随机；
  `maxPulses` 防爆（超限截断并审计）、`rampUpSec` 渐强、`respectDnd` 勿扰开关。
  与既有 `RandomIntervalTrigger`（FR-14）组合即得**"随机间隔的随机振动"**：
  触发层决定"什么时候震"，动作层决定"震成什么样"——**零新触发代码**。
- **持续振动** `ContinuousVibrateAction`：一段时长内连续振动，
  **强度区间随机波动**（`jitterMs` 波动周期）、锐度区间（仅 Android 16 包络）、
  占空比、渐强/渐弱。用户决策 D1 = **不设时长硬上限**，对价是可停止 + 审计。
- **设备能力三级降级**：Android 16 包络（强度+锐度）→ 波形+振幅（强度）→
  on/off（强度满格）。每一级降级都由 `vibrateDegradations` 产出**显式说明**，
  进 `exec_logs` 与设置页「设备振动能力」卡片（FR-34 口径修正：**不得静默降级**）。
  存在理由：Android 上 `hasAmplitudeControl()==false` 时**所有非零振幅一律被当成
  100%**（官方文档原文），同一份配置在不同设备上体感完全不同**且不报错**。
- **分片续发** `VibrateSession`：每次只下发 `chunkMs`=20s 的振动，由 3s keep-alive
  续发下一片（**刻意不复用** `SchedulerConfig.engineTick`=15s）。这让
  「进程一死就没人续发」成为**结构性**保证，而不是靠自觉。
- **四条失效安全（D1 的对价，不可裁剪）**：
  S1 进程死亡即停（分片续发）｜S2 重启**绝不续发**（`recoverAfterRestart`，
  有残留时额外写审计）｜S3 任何时刻都能停（本地按钮 + 远程 `vibrate.stop`）｜
  S4 低电量自动降级（**启动闸 + 在跑检查**，只挡启动是不够的）。
- **夜间独立豁免**（用户决策 D4「默认受约束，同时增加所有功能的夜间独立豁免选项」）：
  **双钥匙** = 设置页主开关（prefs）∧ 任务级 `quiet_exempt`（DB），缺一即回到
  受约束的 `skip`/`shift`。配 **撤销即清**（`deletePendingQuietExempt`）、
  **远程丢弃**（`TaskWire.fromWire` 显式忽略入站该字段）、
  **审计计数**（设置页「本月豁免次数」）、**备份不携带**。
- 编辑器：动作类型新增「震动·固定节奏 / 震动·随机脉冲 / 震动·持续」三项，
  各自表单 + 能力降级提示条 + 「遵循系统勿扰」开关 + 夜间豁免开关。
- 远程（决策 D2「本地+远程一起做」）：
  - 新命令 `RcCmd.vibrateStop`（`vibrate.stop`）→ 停止端点**全部**进行中的振动；
    控制台新增「停止端点振动」按钮。
  - `RcStepKind.vibrate` **参数化**：`mode` ∈ {fixed, random, continuous}，
    `mode` 缺省 = `fixed` ⇒ **老控制器发的 `{}` 行为一字不变**（协议向后兼容）。
    振动步时长**计入**指令组 30 分钟总预算（此前只统计 `delay`）。
  - `RcStep.describe()` 给出人话（"持续振动 10–30 秒（强度 50–100%｜波动 800ms）"）。
  - `TaskWire._sanitizeActionMap` 新增 `randomVibrate` / `continuousVibrate` /
    `randomFrom` 三个分支，**逐字段夹紧**。

### Fixed（缺陷修复）

- **BUG-070** 免打扰窗口设置**从未被任何执行路径读取** ——
  设置页写入 `quiet_start` / `quiet_end`，而 `replan()` 与端点 `_rematerialize()`
  都使用硬编码的 22:00–07:00。用户改了窗口**完全不生效且无任何提示**（界面在说谎）。
  修法：`PrefsKeys` 收敛为唯一真源 + `normalizeQuietWindow()` 归一化
  （非法值回落默认、起止相同回落默认）+ 两处执行路径接通。
- **BUG-071** `ActionKindChoice` 里**没有任何震动选项** ——
  打开任一 `ActionType.vibrate` 任务再保存，动作会被**静默改写成播放音频**
  （`_applyTask` 缺分支 + `_save` 缺 case）。用户只看到"任务变了"，
  不知道是被自己点坏的。修法：补三个选项 + 三个回填分支 + **AK-01 满射锁**
  （每个 `ActionType` 都必须有可产生它的 `ActionKindChoice`）。
- **BUG-072** `randomFrom`（动作集）在 `_sanitizeActionMap` 里**既没有分支也不递归**
  —— 落进 `default:` 原样透传。后果不是"少夹紧一层"，而是**远程校验被整体绕过**：
  对端把未夹紧的 `continuousVibrate`（`amplitudeMin: 5`）塞进
  `candidates[0].action` 即可，release 下 `assert` 被剥离 → 自相矛盾动作写入 DB
  → 物化期崩。修法：补 `randomFrom` 分支并**递归**夹紧每个候选的 `action`
  （候选数 2–12、权重收敛到有限数 —— 权重 `Infinity` 会让选中逻辑静默失效）。
- 附带：`TaskWire.maxVibrateSteps` 与 `VibrateLimits.maxPatternSteps` 收敛为同源，
  消除固定节奏模式串步数上限的两处硬编码。

### Security / 合规

- **入站振动一律强制「遵循系统勿扰」**（`TaskWire.inboundRespectDnd` /
  `RcStep._inboundRespectDnd`）。`respectDnd=false` 会让原生改用 `USAGE_ALARM`
  即**穿透系统勿扰**；允许已配对的对端打开它，等于让对端绕过本机的合规护栏 ——
  与 `quietExempt` 同一类问题，触碰红线（docs/08 §2）。
  本机任务仍可由用户自己关闭（UI 有显式警告），**远程路径不提供这个能力**。
  对端若试图关闭，端点写审计「对端请求关闭『遵循勿扰』已被拒绝」。
- 夜间豁免**远程不可开启**，三层落地：`fromWire` 显式 `false` + 源码扫描锁
  （`lib/remote` / `lib/features/remote` 不得出现写入）+ 「只有 `settings_screen`
  可写主开关」锁。**读取允许** —— 否则远程改一次任务会把已授权的夜间计划静默清掉。
- `vibrate.stop` 权限位 = `vibrate`（能震的才能停）：本工具是自我保护用途，
  让没有振动权限的对端停掉用户自己的报警振动同样不可接受。

### Tested

- 功能层 **868/868** 全绿；压测层 **24/24**；合计 **892**（`bash scripts/gates.sh`）。
- `flutter analyze` → No issues。
- 覆盖率 **64.45%（5506/8543）**（分母 77 个 lib 文件，由 `coverage_sentinel_test` 保证完整）。
  ⚠️ 第二次实测为 **5507**（差 1 行 = 0.012pt）—— **同一份代码、同一条命令的测量抖动**，
  来源未逐行定位。这正是 ratchet 阈值必须留余量的原因（见下）。
- 新增测试文件 6 个：
  - `vibrate_resolve_test.dart`（22）—— 强度换算不为 0、包络**必须以 intensity==0 收尾**、
    三级降级选对模式、on/off 不带 amplitudes、时间轴合计 == 审计值、DPRNG 可复现、
    降级说明（含"用户没设锐度就不要吓他"）、物化期计划区间。
  - `vibrate_session_test.dart`（17）—— S1 单片不超 chunkMs、S2 重启绝不续发、
    S3 空活跃表也要下发 cancel、S4 启动闸 + 在跑掉电、勿扰透传、降级进审计。
  - `vibrate_remote_wire_test.dart`（11）—— 逐字段夹紧、上下界互换、
    `randomFrom` 递归、`respectDnd` 强制、**覆盖锁**（每个动作 kind 必须有显式
    `case`，配 `extends ActionConfig` 计数防空转）。
  - `rc_vibrate_step_test.dart`（16）—— 协议向后兼容（`{}` 描述一字不变）、
    路由**绝不退回固定节奏**、规格键 == 模型 `toJson` 键（表单↔执行器不分叉）。
  - `vibrate_remote_dispatch_test.dart`（4）—— `stopVibrate` 两条腿都走、
    引擎未运行时如实失败（不私自下发）。
  - `quiet_exempt_lock_test.dart`（21）—— 双钥匙缺一即回受约束、默认未授权、
    远程丢弃入站字段（含**源码扫描**：`lib/remote` 不得出现主开关写入口）、
    撤销即清（`deletePendingQuietExempt` 端到端不变量）、窗口归一化不整体关掉。
- 另新增 `action_kind_coverage_test.dart`（5）—— 编辑器选项 ↔ `ActionType`
  **满射/单射**锁（BUG-071 的复发锁）。
- 变异证伪 2 项（均已恢复并复验）：`case 'randomFrom':` 改名 → VW-06 红；
  路由缺处理器时退回 `legacyFixed` → RV-15 红。⚠️ 只声明**留下输出**的两项，
  不把未留痕的注入计入（见 docs/17 §52⑤ 口径声明）。

### Changed（工程）

- **覆盖率 ratchet 进门禁**：`scripts/gates.sh` 从 3 步变 **4 步** ——
  功能层顺带加 `--coverage`（**不多跑一遍测试**），第 4 步执行
  `dart run tool/coverage_report.dart --gate=$COVERAGE_MIN`（默认 **64.4**）。
  语义是 **ratchet（只降不升）**：涨了就把阈值往上改，跌了**红**，
  要下调必须**有意识地**并在 docs/12 写明理由（下调留痕，否则 ratchet 失效）。
  ⚠️ **阈值必须留余量**：同一份代码两次实测 5506 / 5507 行，第一版阈值 64.45
  正好卡在两次值中间（64.4487% / 64.4604%）⇒ **同一份代码会时红时绿**。
  改取比实测低约 0.05pt 的 64.4（容忍 ±1–2 行抖动，真回落照样红）——
  与压测层的"负载噪声"是同一类判据：**ratchet 抓真回落，不抓测量抖动**。
  两条防呆：① 门禁不自己比大小，只消费工具的结论；工具报"报告不可信"时判
  **FAIL 而非 PASS**（那类问题的危险之处正是它会让数字变好看）；
  ② 没有 `lcov.info` 记 `[BLOCKED]`（未执行 ≠ 通过）。
  逃生舱 `SKIP_COVERAGE=1` / `COVERAGE_MIN=<n>`。
  阈值方向**三向验证过**：`--gate=64.4` → RC=0；`--gate=64.5` → RC=1；`--gate=99` → RC=1。
  完整门禁实测（负载 100%）：analyze PASS / 功能层 08:16 +868 / 压测 01:56 +24 /
  覆盖率 64.46% ≥ 64.4% → **RC=0**。

### Changed（工程）· 第二十七轮补记（2026-09-22）：覆盖率冲刺 —— 编辑器振动表单面

- **补测试**：新增 `test/task_editor_vibrate_test.dart`（**21 例**，TEV-01…TEV-21），
  把 `task_editor_screen.dart` 的**振动三模式表单面**全部走一遍 ——
  三个动作 chip 的 inputs 构建、`_applyTask` 的三个振动回填分支、
  点格 +50ms 与 **≥1000ms 回卷**、4 条 / 3 条 `RangeSlider`、6 个 `_IntStepper`、
  `_dndSwitch` 双向、`_vibrateCapHint` 的**四条分支**（桥不可用 / 无振动器 /
  能力齐全不该有提示 / 能力不足逐条列出，且**设了锐度才提示锐度**）、
  `_buildTask` 三个振动分支的**参数往返一字不差**（含 `respectDnd=false` 显式落库）、
  固定节奏 < 2 值的**前置校验**、夜间豁免两把钥匙、以及按 id 读库的完整往返。
- **源码锁 3 条**：TEV-18（三个振动分支必须"先校验、再构造"且失败 `return null`）、
  TEV-19（表单状态与模型字段逐字段对齐）、TEV-20（扫描器防空转自检）。
  两条均**变异证伪**过（改掉校验提示 → 红；删掉 `rampDownSec` 映射 → 红）。
- **诚实划出 5 行不可达**（不写假用例）：`RcStepKind.delay` 的 3 处分支
  （`stepKindOfAction()` 对任何动作都不返回 delay）+ 随机/持续"区间起点 > 终点"
  的 2 处 `_toast`（回填受模型 `assert` 保护、滑块 `onChanged` 先写 min 再拿 min 夹 max
  ⇒ 恒有序）。它们会长期留在缺口里 —— 这是取证结论，不是遗漏。
- **ratchet 抬高**：`COVERAGE_MIN` **64.4 → 66.8**（"新实测值 − 0.05pt"）。
  ⚠️ 这是**地板不是目标**：补完测试不抬 = ratchet 形同虚设。
- 结果：功能层 **868 → 889**；覆盖率 **64.45% → 66.85%**（5506 → 5711 / 8543，
  分母两轮一致 ⇒ 分子是真实增长）；`task_editor_screen.dart` **202 → 5** 行未覆盖。
  门禁 **RC=0**（analyze 21.6s / 功能层 03:40 +889 / 压测 01:59 +24 / ratchet 66.85% ≥ 66.8%，
  负载 69%）。新阈值三向验证：`--gate=66.8` RC=0；`--gate=66.9` RC=1；`--gate=99` RC=1。
- **登记未修**：`_buildTask` 把 `RcStepKind.delay` 映射成 `RecordEvidenceAction`。
  当前不可达，但一旦 delay 变得可表示会**静默把"时延"变成"录音"**（BUG-068 同族）。

### Fixed（修复）· BUG-073：远程保存任务**成功被误报成沉默**

- **现象**：远程「任务」页保存端点任务时，端点确实写进去了，但**列表不刷新、
  也没有任何确认** —— 用户会以为没保存成功，**再点一次**。
- **根因**：`remote_tasks_tab._openEditor` 用 `push<bool>` + `if (saved == true)`
  决定"刷新列表 + 提示已写入端点"；而编辑器远程分支成功时调的是**无参** `pop()`
  → 结果恒 `null` → 该分支**永远不执行**。
- **为什么算真缺陷**：已核对 `endpoint_service._upsertTask` 在 upsert 后
  **只推 `RcEvt.task` 单条回执、不推 `rc.tasks`** ⇒ 列表刷新**完全依赖**
  `saved == true` 这条路径。
- **修复**：`Navigator.of(context).pop()` → `pop(true)`（`task_editor_screen.dart`）。
  与"离线入队被误报成功"方向相反 —— 这是**成功被误报成沉默**。
- **回归锁**：RTD-11；**变异证伪**：回退成 `pop()` → RTD-11 红。
- ⚠️ **目前只有宿主验证**：真机"远程保存后列表刷新 + 提示"需补一条 `WITH_DEVICE=1`。

### Changed（工程）· 第二十八轮补记（2026-09-22）：覆盖率冲刺 —— 远程任务子页

- **补测试**：新增 `test/remote_tasks_tab_deep_test.dart`（**19 例**，RTD-01…RTD-19），
  把 `lib/features/remote/remote_tasks_tab.dart` 的**111 行未覆盖全部吃干**：
  - **摘要渲染器**（`static` + 私有 → 宿主单测直接够不到，只能"喂线格式看渲染结果"）：
    五种触发措辞（含星期**排序后**渲染、`_gap` 的 h/min 两分支）、冷却三档 + 0 显示"无"、
    ISO 三形态（合法/非法/非字符串）、**各 kind 的关键可调项都摊在卡片上**
    （含 `jitterMs=0` 不该渲染成"波动 0ms"）、`_kindToType` 覆盖**全部** kind、未知类型兜底名；
  - **事件与端点切换**：`rc.task` 单条回执**只解除等待态、不假装刷了列表**（契约进断言）；
    切端点必须**立刻清空**上一台的任务（留着就是张冠李戴）；
  - **编辑入口**：新建→保存→**必须刷新 + 确认**（BUG-073 锁）/ 正常解析→带原定义打开 /
    解析失败→明说且**不打开空白编辑器**；
  - **生产路径**（`channel == null`）：离线入队要**明说**、写操作拿不到回执时编辑器**不能关**、
    卸载时未决回执不悬挂；**空态引导**「去配对」/「去开启」用真 `GoRouter` 验证**真能跳页**。
- **顺带固化两条隐式契约**（都不是 bug，但都极易踩）：
  1. 本页 `_load() → refresh() → _send()` **全在微任务里跑完**，`_snack()` 时
     页面**自己的** Scaffold 还没挂上 —— 生产靠 `SectionScaffold` 兜住，
     **测试宿主也必须补一层**（否则 `ScaffoldMessenger.showSnackBar` 断言失败）；
  2. 线格式的 `trigger` **必须带 `kind`**（`TriggerConfig.fromJson` 按 `trigger['kind']`
     分派，**不是**外层 `triggerType`）；漏了会被 `TaskWire.fromWire` 的 `on Object`
     **吞成 null** → 「编辑」退化成弹"无法解析"。**症状离根因很远**，故留正向 + 负向两条锁。
- **对照跑归因**（不接受"大概就是这个文件吧"）：把新测试文件移出 `test/`，
  同一份代码再跑一次全量覆盖率，逐行 diff 两份 lcov →
  新增 111 行**全部**来自 `remote_tasks_tab.dart`，**其他文件 0 行**；
  再加顺带补的 `notify` 分支 1 行 = 112，与 `5823 − 5711` 自洽。
- **ratchet 抬高**：`COVERAGE_MIN` **66.8 → 68.1**（"新实测值 − 0.05pt"）。
  ⚠️ 这是**地板不是目标**：补完测试不抬 = ratchet 形同虚设。
- 结果：功能层 **889 → 908**；覆盖率 **66.85% → 68.15–68.16%**（5711 → 5822/5823 / 8543）；
  `remote_tasks_tab.dart` **111 → 0** 行未覆盖（355/355）。
  门禁 **RC=0**（analyze 26.2s / 功能层 03:39 +908 / 压测 03:23 +24 / ratchet 68.15% ≥ 68.1%，
  负载 70%）。新阈值三向验证：`--gate=68.1` RC=0；`--gate=68.2` RC=1；`--gate=99` RC=1。
- ⚠️ **1 行抖动再现**：同一份代码两次全量跑出 5823 / 5822（差 1 行 = 0.0117pt）；
  抖动**不在本轮新增块**（该文件两次均 355/355），是既有的已知抖动，
  阈值 68.1 覆盖它 —— **ratchet 抓真回落，不抓测量抖动**。

### Fixed（修复）· BUG-074：**Android 端从未构建成功**（`Long` → `Int` 赋值）

- `NativeBridgePlugin.vibrateCapabilities` 里
  `minCp = v.envelopeEffectInfo.minControlPointDurationMillis` ——
  该字段是 **`Long`**（API 36），而 `minCp` 声明为 `Int`
  ⇒ **Kotlin 编译失败**：`Assignment type mismatch: actual type is 'Long', but 'Int' was expected.`
- **为什么四轮都没发现**：宿主测试（`flutter test`）**不编译 Kotlin**、
  `flutter analyze` **不看 Kotlin**、而真机构建此前**从未成功跑完**
  （被"设备链路不持久"掩盖）⇒ **三道闸门一道都没拦住**。
- **修复**：补 `.toInt()`（毫秒值远小于 `Int.MAX`，转换安全）+ 就地注释。
- **回归锁**：`integration_test/vibrate_device_test.dart` 一旦被跑就**必然先过**
  `assembleDebug` ⇒ 天然是这条锁。已登记进 `scripts/gates.sh` 设备层（`device_vibrate`）。

### Added（设备取证）· P0 振动能力实测（docs/20 §13）

- 新增 `tool/vibrate_probe.dart`（人肉探针，A–G 七段取证行）与
  `integration_test/vibrate_device_test.dart`（VD-01..06，**可回归的设备用例**）。
- 真机 `shennong`（Redmi K70 至尊版 / **Android 16 / API 36**）实测四条能力：
  `hasVibrator=true`、`hasAmplitudeControl=true`、**`hasEnvelope=false`**、`minControlPointMs=0`。
- ★ **核心结论：Android 16 ≠ 支持振动包络** —— 系统侧 `mMaxEnvelopeEffectSize = 0` 印证。
  ⇒ docs/20 的**三级降级不是过度设计，是必需品**；"包络优先"这条路径在本机永远走不到。
- `dumpsys vibrator_manager` 逐条对上号：`usage: ALARM` / `usage: NOTIFICATION` 如实传递；
  振幅 `[0,255,0,128]` → 记录 `1.00 / 0.50`（**没被一律拉满**）；
  8s 长振动被 `vibrateStop` 在 2020ms 处 `cancelled_by_user` 终止（S3「任何时刻都能停」成立）。
- **BUG-069 定性**：带 attributes 的振动**确实产生了系统侧记录** ⇒ "带了反而没震"不成立。
  ⚠️ "不带 attributes"的对照组**未做**（代码里已无该路径）；真"后台"（退后台/锁屏）场景**未覆盖**。

### Changed（工程）· 第二十九轮补记（2026-09-22）：覆盖率冲刺 —— 音效库页

- 新增 `test/sound_library_screen_test.dart`（SLB-01..21，**21 例**）。
- `lib/features/sounds/sound_library_screen.dart` 加 `@visibleForTesting` **注入缝**
  （`previewPlayer`，与 `RemoteTasksTab.channel` 同形；生产传 `null` **行为一字未变**）。
- **ratchet 抬高**：`COVERAGE_MIN` **68.1 → 69.2**（"新实测值 − 0.05pt"）。
- 结果：功能层 **908 → 929**；覆盖率 **68.15% → 69.26%**（5823 → 5918 / 8545）；
  `sound_library_screen.dart` **94 → 0** 行未覆盖（120/120）。
  分母 8543 → 8545（+2）是**可复核的源码事实**（注入缝可执行行净增 2，`git diff` 可验）。
- 对照跑归因：+95 行中 **94 行来自该文件**、1 行来自 `assist_host_screen.dart` 公共路径，
  **其余 74 个文件 0 行变化**。
- ★ 顺带固化的框架事实（一条**推翻上一轮结论**）：
  ① `testWidgets` 里 `await runAsync(回调)` **会死锁** —— 框架驱动循环只在**段与段之间**
  排空 fake 微任务 ⇒ **分段驱动**（`unawaited` 启动 + 真实 Timer + `pump()`），
  实测"675 轮零进展 → 5 轮走完"；
  ② **`flutter/assets` 打桩后 `rootBundle` 在 `runAsync` 里可用** ⇒ 预置库导入
  **整条链可端到端测**（推翻上一轮"宿主不可达"）；
  ③ `rootBundle` 是全局单例、缓存**跨用例存活** ⇒ `setUp` 必须 `rootBundle.clear()`；
  ④ `debugPrint` 的节流 Timer 会留在 fake zone → 打印全丢，**探针一律用 `print`**。

### Docs

- 新增 docs/20《振动能力设计（随机振动与持续振动）》。
- docs/07 补 `quiet_exempt` 列与振动字段语义；docs/08 §2/§4 补豁免与勿扰红线；
  docs/12 §52 本轮测试报告；docs/17 末节续作清单刷新。

## [1.8.0-alpha] - 2026-09-19

### Added（新增）—— 多条件 × 随机编排（docs/19）
- **概率门**：TaskCondition.probabilityPct（5–100%），确定性条件全部通过后
  按百分比随机决定是否执行；未命中记"概率 P% 未命中（掷出 N）"审计。
  大样本分布验证（P=50 → 0.46–0.54，P=10 → 0.08–0.12）。
- **动作集（随机指令集）**：ActionSetAction（2–12 个候选、每候选权重），
  触发命中后按权重随机选一执行；审计"权重 → 选中"可回溯；
  全零权重安全兜底等概率。支持播放/声景/TTS/通知/取证/震动全类型候选。
- 编辑器：执行概率滑条（条件区）+ 随机指令集候选编辑器（动作区），
  编辑已有任务完整回填。
- 文档 docs/19（组合集合行业谱系对照：AND/概率/N选一/叠加/OR拆分/If-Else等价）。

### Tested
- orchestration_test.dart 7 例：概率分布×3、加权分布/兜底/序列化/组合×4。
- ⚠️ **原文此处写"全量 401/401 全绿 + analyze 全零"，经复核不成立**
  （详见 docs/17 §23、docs/12 §26）：开工前实测为 `analyze PASS`
  + 功能层 **FAIL**（391 例中 1 例红 —— 本节标题当时被插在 `[1.7.2]`/`[1.7.1]`
  之间，违反 `version_consistency_test` 的"顶部即最高版本"）+ 压测 `+24 PASS`。
  **真实用例数 391 ≠ 宣称的 401，是"交接叙述与仓库脱节"的第一个信号。**

### 第十七轮补记（2026-09-20）：把"互通验证"从假绿改成真绿

> 主题：**把"互通验证"从假绿改成真绿**。上一轮宣称的 `ping ✓ 全链路闭环`
> 复跑为 **0/3**；根因不是端点故障，而是**验证工具自己用错了密钥身份**。

#### Fixed（缺陷修复）
- **BUG-052（P2，验证工具级）**：`tool/rc_probe.dart` 用 `(selfCode, '{selfId}|cmd')`
  派生**命令**密钥，而端点 `_handleRaw` 用 `(ownCode, '{ownId}|cmd')` 解密 ——
  协议规定密钥按**接收方身份**派生，两者**永不相等**，命令**从未被解密过**。
  更糟的是通过标准是"evt 主题上出现任意密文"，而端点每 60s 发一条心跳
  恰好能满足它 → **工具给出假的"全链路闭环"**。
  修复：命令密钥改用**端点**身份；回执必须**解密成功 + 类型对 + `for` 与命令 id
  一致**才算通过；失败时打印"看到多少密文/心跳"以区分「离线」与「密钥不匹配」。
- **CHANGELOG 章节顺序**：`[1.8.0-alpha]` 从 `[1.7.2]`/`[1.7.1]` 之间移回顶部，
  版本号四处同步（pubspec / `AppMeta.version` / CHANGELOG 顶部 / HANDOVER 标题）。

#### Added（新增）
- **`test/rc_probe_keys_test.dart`（16 例）**：把"探针发的命令端点能解"变成
  **宿主机可断言**的量（不需要 broker、不需要设备）：
  密钥对称性×3、端到端往返×3（含 AAD 主题绑定）、
  **旧写法必须失败**×2（否则这组锁恒真）、探针判据源码契约×5、
  CRUD 载荷 ↔ 领域模型一致性×3。
- **探针 CRUD 序列**（`probe=crud`）：远程任务增/查/计划物化/改/删/清理 8 步，
  并**显式验证免打扰语义**（03:30 + `quietPolicy=skip` → 端点应如实回 `planned=0`）。
- 探针新增 `logs`（`logs.recent`）与 `onlinewait`（等待端点上线并区分离线/密钥不符）。

#### Changed
- **BUG-051 定级下调**：上一轮据"`ping` 通、`status.get` 超时"推断
  "处理器抛异常 → 静默超时"并加了 `guardDispatch` 兜底。本轮实测
  **未复现该触发条件** —— 跑在**不含该修复的旧 APK** 上的 `status.get`
  也正常应答（641ms）。真实根因是 BUG-052（命令根本没被解密）。
  `guardDispatch` 保留为**防御性加固**（失败必须留痕且让对端知道），
  但"status.get 超时 = 处理器异常"这条因果**已证伪**，不得再作为结论引用。

#### Tested
- 仿真多机连通实测（模拟器端点 ↔ 宿主控制器，**真实公网 broker**）：
  `ping / status.get / task.list / asset.list / preset.list / device.status /
  logs.recent / sound.play` + CRUD 序列 = **9/9 通过**，
  全部回执**解密成功**且 `for` 与命令 id 一致，单程往返 ≈ 630ms。

### 第十七轮补记（二）（2026-09-20）：把"压测层假红"改成稳定绿 —— BUG-053

#### Fixed（缺陷修复）
- **BUG-053（P2，测试测量级）**：`GT-07 outbox 200 条 + 二次 drain 幂等` 是**抖动**用例 ——
  **同一份代码**在全套件负载下测到 `455ms`（红）、单独跑 **6/6 绿且 <1s**。
  根因两处叠加：
  1. 用**裸 `Stopwatch` 单次采样**，违反 `test/performance_v2_test.dart` 文件头与
     `test/perf_bench.dart` 明确要求的"统一用 `benchMs`/`benchMsAsync`
     （**预热 + 取最小值**）" —— 单次采样测的是 JIT 编译 + GC + 调度噪声；
  2. 该路径是**往返受限**的（200 次 `enqueue` = 200 次 `prefs.setString` 平台往返，
     外加对递增列表整体 `jsonEncode`），却用了紧的**绝对阈值 400ms**，
     与项目既有规矩「往返受限路径的预算必须自归一化」相悖。
  修复：改用 `benchMsAsync`（预热 3 + min-of-5），阈值按本套件约定取「基线 × 3」= **160ms**。
  - 实测基线：全套件负载 **51ms** / 单独 **53ms**（两场景差 <4%，min-of-5 高度可复现）；
  - 旧写法在负载下是 **455ms** ≈ 真实值的 **9 倍** —— 测的全是噪声；
  - **净效果：既不再假红，又比旧阈值（≈ 基线 × 7.8）收紧约 2.5 倍。**
- **证伪**：在 `RemoteStore.enqueue` 注入"按已有条数重复写盘"（1 次往返 → O(n) 次）
  → `Actual: <4595>`，红；还原后 `grep -rc "PROBE-"` = **0**。

#### Changed
- **交接文档陈旧值清扫**（"交接叙述也要复核"再次生效）：`HANDOVER.md` §1 状态表
  （版本 `1.7.3+14` → `1.8.0-alpha+16`、功能 `370/370` → `407/407`、
  `docs/00–18` → `00–19`、`docs/12 至 §25` → `至 §27`、`docs/17 至 §22` → `至 §24`）、
  §3 用例数 `336` → `407`（并补"`+330 -1` 是失败瞬间的进度、不是总数"的坑）、
  §6 第 1 项补"**设备当前不在线**"这一前置阻塞；`docs/00-文档索引.md` 同步。
- ⚠️ **更正 `HANDOVER.md` §3 中一条已被实测证伪的说法**：原文写
  "`Install canceled by user` 里的 by user **不是**用户在弹窗上点了取消，
  是厂商策略直接拒绝，**不要去屏幕上找不存在的弹窗**"。
  第十六轮实测确认：**弹窗确实存在**（`[继续安装] [拒绝（10）]`，**10 秒倒计时默认拒绝**），
  **"by user" 就是这次超时**。判据改为"看到 `by user` 必须先 `adb shell screencap`
  抓现行截图，再下结论"。**被证伪的因果比过期的数字更危险** ——
  下一个会话会照它去找一个错误的原因（第十五轮正是这么被坑的）。

#### Tested
- 标准门禁（模拟器已关闭，绑定修复后代码）：
  `flutter analyze` 零问题 / 功能层 **+407** / 压测层 **+24** /
  `bash scripts/gates.sh` → **EXIT=0 全部门禁通过 ✅**。
- **仿真多机连通复验 9/9**（冻结代码 + 冷启动模拟器 + `flutter build apk --debug`
  真包 + `run-as` 注入配对 prefs，走**真实公网 broker `broker.emqx.io:1883`**）：
  8 条单命令 + 远程任务 CRUD 8/8；`evt 密文 24（其中心跳 1、解密失败 0）`、
  明文哨兵 0；端点回执自报 `version=1.8.0-alpha`。
- 设备层（模拟器 `sonic_test` x86_64）：冒烟 **4/4（23s）**、桥接 **6/6（8s）**、
  AOT **6/6**（复跑；逐条 1824ms→批量 132ms = 13.8×；条件层每轮复用收益 51.8×）。
- **真机测试：本轮未执行** —— 真机 `960f853` 自第十五轮 `adb root` 后从
  `adb devices` 消失；本轮 `adb devices -l` / `adb reconnect offline` /
  `adb kill-server && adb start-server` **三次尝试均无法恢复**。
  阻塞点已从「厂商安装弹窗需人工点击」**前移到**「设备根本不在 adb 列表里」。

#### Known Issues（本轮新增）
- **BUG-054（P3，测试标定级）**：AOT 基准护栏
  （`exec_logs 5000 条逐条` 的 20000ms = 4ms/次 × 5000）余量假设已被证伪。
  本轮实测机器可到 **4839µs/次**（源码注释"冷启 2.475ms/次、1.6× 余量"假设的 **2×**），
  该状态下护栏**余量为零** → 假红。
  重启模拟器后基准 **2046µs/次**，同一份代码 `+6 全绿`。
  **判定为模拟器性能状态，非代码回归**（全部自归一化预算均通过）。
  建议下一轮：放宽到「最差实测 × 2」并写明标定来源，或改为与独立原语对比的相对护栏。
  **本轮不擅自放宽验收阈值。**
- **环境陷阱（已写入文档）**：`build/app/outputs/flutter-apk/app-debug.apk`
  在跑过 `flutter test integration_test/…` / `flutter drive` 之后
  **会被替换成"测试入口包"**（入口是测试文件而非 `lib/main.dart`）。
  用它 + `monkey` 拉起会**永久停在 Flutter 闪屏**（不建 DB、不连 broker、无报错），
  极易误判为"应用启动 hang"。判据：**真包 245MB / 测试包 144MB**；
  恢复用 `flutter build apk --debug`。

### 第十七轮补记（三）（2026-09-20）：主叫接听超时 + `rc.call` 接进 App（BUG-050）+ 压测层第二条假红（BUG-055）

#### Fixed（BUG-050：主叫无接听超时 + `rc.call` App 内无消费者）
- **主叫不再无限等待**：`startCall` 发出 `rc.call.invite` 后启动 **45s 等待应答计时**；
  到点未接通 → 结束通话并给出 **"对方无应答"**。
  修前：被叫未开自动接通、或 invite 被静默丢弃时，主叫**永远停在"连接中…"**，
  且**没有任何"未接"反馈**。
- **`rc.call` / `rc.call.missed` 在 App 内接通消费者**：`CallService.attach(events)`
  接端点的**已解密事件流**（`main.dart` 装配）。
  控制台/通话页现在显示 **"对方振铃中…"**，并在通话结束时弹出原因。
- **`RcEvt.callMissed` 从"死常量"变成真事件**：被叫振铃超时后由**端点**发出
  （`endpoint_service._wireCall()`），主叫据此立刻结束等待。
- **三条"不许猜"规则**：`rc.call` 未知 `state` → `unknown` 且**什么都不做**
  （否则协议加一个 state 就会挂断所有在途通话）；`call.end` 未知 `reason` → 中性；
  本端拒接用新值 `CallEndReason.declined`（'已拒接'），**不复用** `rejected`
  （'对方已拒接' —— 那句是给被拒的一方看的）。
- **已接通后绝不报"未接"**：`timedOutMeansMissed` 带 `!answered` 守卫。
- **收尾副作用不得覆盖真正的原因**：`_pc.close()` 触发的二次 `_teardown()`
  传 `reason: null`（否则"对方无应答"会被冲成空白）。

#### Added
- `lib/remote/call_lifecycle.dart` —— 通话生命周期的**纯逻辑**
  （超时上限/判定、`rc.call` 状态解析、结束原因→用户文案、是否该弹提示）。
  沿用 `remote_playback.dart` 范式：原先埋在依赖 `flutter_webrtc` 的 `CallService` 里，
  **宿主机无法实例化 → 整整一个版本没被任何用例覆盖过**。
- `test/call_lifecycle_test.dart` —— **20 例**（CL-01…CL-20）：
  判定逻辑 + **接线锁**（真的启动两个角色的计时、真的消费两个事件、
  `_teardown` 真的取消 Timer、UI 真的消费 `callEnded`、`main.dart` 真的调了 `attach`）。
- `app.dart` 增加全局 `scaffoldMessengerKey`：通话结束提示可能在**任意页面之上**弹出。

#### Changed
- 三向覆盖锁的缺口登记表**清空 3 条**（`evtWithoutEmitter/callMissed`、
  `evtWithoutConsumer/callMissed`、`evtWithoutInAppConsumer/callState`）。

#### Fixed（BUG-055：压测层 `runs: 1` 造成的假红）
- `exec_logs 5000 条写入` 是两套性能文件里**唯一的 `runs: 1`**（min-of-1 =
  一个采样点被抢占就必红）。实测**单独跑 837–1010ms / 全层跑 4654ms（5.2× 放大）**，
  3000ms 阈值看似有 3.3× 余量，实际落在噪声带里。→ `runs: 3`，**阈值不动**。
- `任务 CRUD 500 次` 同源（`runs: 2`，稳态 457–809ms，负载下测到 2360ms）→ `runs: 3`。
- **新硬规矩**（写入 `performance_test.dart` 头注释）：
  ① 任何用例都不得用 `runs: 1`；② **余量要和「噪声幅度」比，不是和「基线」比**；
  ③ **不要并发跑性能层**（两个 `--tags perf` 同时跑 = 自己制造 5× 噪声）。

#### Tested（实测）
- `flutter analyze` → **No issues found**。
- 功能层 **427/427**（`--exclude-tags perf`；原 407，**+20** = `call_lifecycle_test.dart`）。
- 压测层 **24/24**（`--tags perf --concurrency=1`）。合计 **451**。
- **证伪**：MUTANT-1（去掉 `!answered` 守卫）→ CL-02 红；
  MUTANT-2（删掉 `_startWaitTimer(isCaller: true)`）→ CL-12 红；
  其余 18 条保持绿 → 锁是**载重的**。

#### Known Issues
- **`rc.call` 的"被叫手动接听"路径仍是半成品**：`_handleCallInvite` 的
  `onManualRing` 回调**立刻**调 `acceptIncoming`（v1.4 简化），
  故 `calleeRingTimeout` 在当前 UI 下几乎不会触发。计时器与 `callMissed`
  发出路径已接好（有锁），但"真的弹来电界面让用户接/拒"未接线 → 下一轮候选。
- **真机测试仍阻塞**：`adb devices -l` 为**空**。候选路径 Android 11+「无线调试」
  （`adb pair`/`adb connect`）可绕开 USB 链路；⚠️ 但厂商确认框由**设备上的安装器
  策略**决定，**换传输不必然消除它 —— 必须实测，不得推断**。
- BUG-055 残余：`runs: 3` 能挡"单个采样点被抢占"，但**并发跑性能层**仍可能同时被打中。

### 第十七轮补记（四）（2026-09-20）：被叫手动接听闭环 + 「自动接通」开关失效（BUG-056，隐私相关）

#### Fixed（BUG-056：隐私开关静默失效）
- **「自动接通」开关关掉也照样接通。** 修前 `endpoint_service._handleCallInvite`
  把 `onManualRing` 实现成**立刻 `acceptIncoming`**（注释写着"v1.4 简化"）。
  那个开关是使用者**唯一**能表达"别自动接我的电话"的地方（设置页文案：
  仅限已配对设备呼入时自动接通，用于家人守护）。**开关失灵 = 来电被静默接通、
  摄像头/麦克风被打开，而使用者以为自己已经关掉了。**
  这不只是"功能没做完"，是**隐私问题**。
- 修后：被叫按 `calleeActionFor(autoAnswer, inCall)` 决定
  **`autoAccept` / `ringUser` / `rejectBusy`**（占线优先于开关）。
  `_handleCallInvite` **只负责发通知**，接/拒由用户在界面上点。
- **默认分支必须是 `ringUser`**：把"读不到开关"或"将来新增分支"的兜底做成
  `autoAccept`，就等于把"隐私开关默认关闭"做反了。
- 判定用**穷尽 switch 表达式**（无 `default`）→ 将来新增 `CalleeAction` 值会
  **编译报错**，而不是静默落进"振铃"。

#### Fixed（被叫此前根本没有来电界面 —— 让上面那条修复真正生效的前提）
- 来电 UI 原先挂在**通话页**（`OverlayEntry` 需要已挂载的页面 context）→
  **只有用户已经站在通话页上才可能接到来电**。被叫在别的页面时，
  "振铃等用户"实际等于"永远接不到"。
- 改为 `CallOverlayHost` 挂在 `MaterialApp.builder` 上
  （用 `Stack` 保住 `child`；不能直接 return 通话视图，否则 Navigator 会被卸载），
  **与当前路由无关**。
- `alignment: Alignment.topLeft`（**非方向性**）：`builder` 在应用根部，
  不保证有 `Directionality`。
- `scaffoldMessengerKey` 抽到 `lib/core/app_keys.dart`：断开
  `app.dart ↔ call_incoming_overlay.dart` 的 import 环。

#### Changed
- `CallService.onIncomingCall` **移除 `onManualRing` 参数**；
  新增 `acceptPending()` / `declinePending()` 作为界面入口。
- `call_screen.dart` 不再自行 `attach` 来电浮层。

#### Added
- `test/call_lifecycle_test.dart` **+11 例**（CA-01…CA-11，共 **31 例**）：
  四个开关组合全覆盖、默认值必须是 `ringUser`、来电文案、只有振铃才能接听；
  外加**接线锁**：`calleeActionFor` 必须真的被 `CallService` 用上、
  **来电处理里不得出现 `acceptIncoming`**、`onManualRing` 必须彻底消失、
  接听界面必须挂在 `builder` 上、界面「接听」必须走 `acceptPending`。
- 锁文件新增 `methodBody(src, signature)`（**大括号配对**抽方法体）：
  文件级 `isNot(contains('acceptIncoming'))` 会被同文件其它方法误伤。

#### Tested（实测）
- `flutter analyze` → **No issues found**（17.0s）。
- 功能层 **438/438**（`--exclude-tags perf`；原 427，**+11** = CA 组）。
- 压测层 **24/24**（`--tags perf --concurrency=1`）。合计 **462**。
- `bash scripts/gates.sh` → **EXIT=0，全部门禁通过**。
- **设备层（emulator-5554 / x86_64，本轮重新实测）**：冒烟 **4/4**、
  桥接 **6/6**、AOT **6/6**；**仿真多机连通 9/9**（模拟器端点 ↔ 宿主控制器，
  真实公网 `broker.emqx.io`；CRUD 8/8、解密失败 0、明文哨兵 0、**心跳 0**）。
  本轮改了 `app.dart` 的 `builder` 与通话页 → **设备冒烟正相关**，故重测而非沿用旧数据。
- **证伪**（各自只打红预期用例）：
  MUTANT-3（把 `acceptIncoming` 塞回 `_handleCallInvite`）→ **CA-08 红**；
  MUTANT-4（`calleeActionFor` 恒返回 `autoAccept`）→ **CA-01 + CA-04 红**。
- ⚠️ **CA-07 初稿就是红的**：`CalleeAction.ringUser` 在 `call_service.dart` 里
  根本不出现（手动路径当时是个隐式 `else`）。**这条锁抓住的是一个真实弱点** ——
  将来新增 `CalleeAction` 值会静默落进"振铃"。改为穷尽 switch + 抽 `_ringUser()`
  之后才绿。

#### Changed（叙述修正：BUG-054 的"必假红"过强）
- BUG-054 原称 AOT 基准护栏 `exec_logs 5000 条逐条`（20000ms）**余量为零、必假红**。
  本轮实测 **PASS**：基准平台往返 **1963µs/次** → 该用例 **9813ms**（**2.04× 余量**），
  而 BUG-054 观测到的是 4839µs/次。
- **修正定性**：**不是"必假红"，而是"余量随平台往返成本漂移"** ——
  往返成本在 **1963µs ↔ 4839µs（2.5×）**波动，余量随之在 **2.0× ↔ 0.83×** 摆动，
  **跨过 1.0 就红**。它是**唯一一条不归一化**的基准（其余都是
  `本次往返成本 × 调用次数 × 3`）。
- **修法不变**（改成自归一化预算）；但"必假红"这种**确定性表述**必须改成
  **"可能假红"**，否则下一个人看到它绿了会以为 BUG-054 已修好。
  > **"交接叙述也要复核"再次生效 —— 这次连缺陷描述本身都被复核了。**

#### Known Issues
- 真机仍阻塞（`adb devices` 里只有 `emulator-5554`）。本轮**未取得任何真机数据**，
  **不声称任何真机结论**。

### 第十七轮补记（五）（2026-09-20）：BUG-054 闭环 —— AOT 基准护栏改为**同类独立探针**归一化

#### Fixed（BUG-054：AOT 基准护栏会随机器状态假红）
- **根因：基准自己给自己当基准。** `perCallUs = singleMs / 5000`，而 `singleMs`
  正是那条 5000 次 `logs.append` 的测量值 → 被它归一化的用例自洽了，
  它**自己**只能用硬编码的 `20000ms`（按"冷启 2.475ms/次"标定）。
  实测往返成本可到 4839µs/次 → 余量在 **2.0× ↔ 0.83×** 摆动，**跨过 1.0 就红**。
- **修法**：基准改为**独立的同类探针** —— `logs.append` × **200** 次
  （带 20 次预热、min-of-3），与那条 5000 次的用例**解耦**。
  于是 5000 条那条也能走 `budgetFor(5000)`，**全文件不再有任何绝对 ms 护栏**。
- **⚠️ 修的过程中踩的第二个坑**：第一版探针用了 `tasks.get(<缺失 id>)`
  （纯 1 次 SELECT = 1 次往返）→ 它**低估**了写入路径的单位成本（写入要 2~3 次往返）
  → `任务 500 条逐条写入` 实测 3534ms / 预算 3728ms，**只剩 1.05× 余量**
  —— **等于把 BUG-054 搬到了另一条用例上**。
  **教训：归一化的单位必须与被护栏的工作量同量级。**
- **该护栏的语义**（写进代码注释）：断言**规模不变性**（5000 次调用的每次成本
  ≤ 200 次调用的每次成本的 3×）。**均匀变慢抓不住**，**超线性退化会被抓住**。
  **它不是绝对性能验收。**

#### Added
- `test/aot_budget_normalization_test.dart`（**8 例**，AN-01…AN-06）：
  宿主侧秒级锁，防止上面这条护栏被改回去。AOT 跑一次 ~75s（还要模拟器），
  **不能靠它防回归**。断言：往返受限用例必须用 `budgetFor(...)`、
  `perCallUs` 不得由 `singleMs` 反推、探针必须是**同类写入**且**已预热**、
  不得回退到绝对 `20000`、三条已知用例不得被改名（防**静默**失去覆盖）。

#### Tested（实测）
- `flutter analyze` → **No issues found**（27.7s）。
- 功能层 **446/446**（原 438，**+8**）；压测层 **24/24**；合计 **470**。
- `bash scripts/gates.sh` → **EXIT=0，全部门禁通过**。
- **AOT 绝对验收 6/6**（本轮跑了两次，对比本身即证据）：

  | 用例 | 第 1 次（SELECT 探针，冷机） | 第 2 次（同类写入探针） | 余量 |
  |---|---|---|---|
  | 基准单次成本 | 2485µs（纯往返） | **1405µs**（含 INSERT） | — |
  | exec_logs 5000 条逐条 | **26658ms** | **6568ms** | **3.21×** |
  | 任务 CRUD 500 次 | 4189ms | **1669ms** | **2.53×** |
  | 任务 500 条逐条写入 | 3534ms（1.05×） | **1287ms** | **1.64×** |

  **绝对值差 4×，余量都在安全侧** —— 这就是归一化要的效果。
  > **BUG-054 当场复现**：第 1 次的 `26658ms` 在旧的 20000ms 护栏下**就是红的**。
- **证伪**：MUTANT-A → AN-04 红；MUTANT-B → AN-02 + AN-06 红；
  MUTANT-C（改用例名）→ AN-03 红；MUTANT-D（换回廉价读探针 + 去预热）→
  AN-05b + AN-05c 红。四次都只打红预期项。

#### Changed
- `integration_test/perf_nfr_test.dart`：`exec_logs 5000 条逐条` 的
  `runs: 2 → 3`（与 BUG-055 的教训一致：min-of-2 抗噪不足）。

#### Known Issues
- **BUG-054 的残余是能力边界而非缺陷**：归一化护栏对**均匀变慢**不敏感
  （探针与被护栏用例一起变）。已写进代码注释与 docs/12 §31.3，避免被误读成绝对验收。
- **跑 `flutter analyze` 前必须先关模拟器**：本轮模拟器开着时 analyze 直接崩了
  （Dart VM 栈帧刷屏），关掉后同一条命令 No issues found。
- 真机仍阻塞（`adb devices` 里没有真机）。本轮**未取得任何真机数据**。

### 第十七轮补记（六）（2026-09-20）：`rc.script` 接进 App（协议缺口可闭环项清零）+ BUG-057

#### Added（新增）
- **`lib/remote/script_progress.dart`**（纯逻辑）：指令组执行进度的解析与文案。
  `ScriptState { running, done, stopped, unknown }` + `parseScriptProgress` +
  `shouldApplyProgress` + `describeScriptProgress`（**穷尽 switch、无 `default:`**）。
- `RemoteScriptsTab` 现在**消费 `RcEvt.scriptState`**：顶部出现执行中进度卡，
  每条收藏模板的副标题也带自己的进度（此前发完只弹一句"已发送"，看不到执行到第几步）。
- `RemoteScriptsTab({this.events})` 注入点：让部件测试能直接回灌事件。

#### Fixed（BUG-057：压测层「同一份工作量、两个预算」）
- **现象**：标准门禁压测层红 —— `GT-01 加密 50KB 备份 ≤ 4s`（实测 6213ms）与
  `GT-03 错误密码解密 ≤ 1500ms`（实测 3737ms）。
- **先怀疑测量，果然有一半是测量问题**：`TaskStop` 报"已终止"的端口扫描后台任务
  **并没有真的死**，`/usr/bin/xargs` 仍在持续 fork 子进程（`ps` 见 24 个残留）。
  杀掉后 GT-01 恢复，**但 GT-03 依然红**（3229ms）→ 是两个独立问题。
- **预算形状的证据链**：`encrypt`/`decrypt` 都走 `Pbkdf2(iterations: 120000)`，
  错密码只是最后 GCM 校验失败、**KDF 一次都不会少跑** → 三条用例工作量完全相同。
  用"把阈值临时置 0"逼出干净机器实测：GT-01 **1128ms**、GT-02 **1049ms**、GT-03 **1127ms**。
  于是 GT-03 的 1500ms 只剩 **1.33×** 余量（兄弟用例 3.5×+），
  且三条用例**标题都写「≤ 4s」**、只有 GT-03 的断言写 1500 —— 断言与自己的标题矛盾。
  CPU 争用把耗时抬到 2.9× → 余量低于噪声幅度，GT-03 必然最先红。
- **修法**：抽 `const kdfBudgetMs = 4000` 三条共用（依据写进注释）。
  ⚠️ **不是放宽阈值**：需求（4 秒）没变，改的是**形状** ——
  把"拍脑袋的 1.33×"对齐到"与兄弟用例一致的 3.5×"。绝对验收仍在 AOT 层（NFR-04）。
- **顺带修掉两个会让锁静默失效的工具缺陷**：
  ① `methodBody()` 取"签名后第一个 `{`" → Dart **具名参数也用大括号** → 抽到参数列表
  （`isNot(contains(...))` 恒真、`contains(...)` 恒假）；中间试过的"前面是 `)` 的 `{`"
  同样错（`) async {` 的 `{` 前面是 `async`）。最终**先按括号配对跳过整个参数表**，
  并给工具本身加自检；`test/call_lifecycle_test.dart` 的同名函数同步修正。
  ② `'ScriptState.$v'` 会插值成 `ScriptState.ScriptState.running`（恒假断言）→ 必须用 `v.name`。

#### Tested
- 新增回归锁 **19 例**：
  - `test/script_progress_test.dart`（11）：纯逻辑 SP-01…SP-06 + 源码契约 SP-07…SP-10 +
    **工具自检 SP-11**；
  - `test/remote_scripts_tab_test.dart`（4）：**用户看得见**的后果（进度卡与副标题、
    终止态不残留、未知状态不乱动、其他事件不误判）；
  - `test/perf_budget_consistency_test.dart`（4）：同工作量必须同预算（PB-01…PB-04）。
- **证伪 5 组变异，全部精确打红**：过滤字面量代替 `RcEvt.scriptState` → SP-08；
  绕过 `shouldApplyProgress` → SP-09；去掉 `stopped` + 加 `default:` → SP-03 + SP-07；
  GT-03 预算改回 1500 → PB-01 + PB-02；进度写进错 key → RS-02。
  > **"变异只打红一半"是本次最有价值的发现**：它暴露 RS-01/RS-03 当时只被顶部横幅满足、
  > 没覆盖"每条模板自己的副标题"。据此**补强 RS-01**，重跑 → 打红到位。
- 门禁：analyze **No issues found**；功能层 **465/465**；压测层 **24/24**；总 **489**；
  `bash scripts/gates.sh` → **EXIT=0**。

#### Known Issues
- 缺口登记表剩 3 条（`taskGet` / `photo` / `heartbeat`），**均有正当理由、非缺陷**。
  > ⚠️ 上一轮交接写「`scriptState` 是缺口登记表里**最后一条**，修好即可清空整张表」——
  > 实测本表共 4 条，`scriptState` 是**最后一条可闭环的**。**叙述修正**。
- **无线调试的端口扫描这条路已否决**：即使扫到端口，`adb pair` 仍**必须**用设备屏上的
  6 位配对码 —— 扫描无法替代向使用者索取信息；且那次扫描的残留进程正是 BUG-057 的污染源。
- **新观察项**：`RemoteScriptsTab` 发命令走 `RcEndpointService.sendTo`（未过
  `RcCommandChannel`）→ 协助会话目标目前跑不了指令组。属体验缺口，非缺陷。
- 真机仍阻塞（`adb devices` 里只有 `emulator-5554`）。本轮**未取得任何真机数据**，
  **不声称任何真机结论**。

### 第十七轮补记（七）（2026-09-20）：真机**无线调试接入** + 厂商安装弹窗的**真实边界** + 门禁工具改进

> 主题：**把真机接进来**（走 Android 11+「无线调试」），并借由拿到真机后**证伪上一轮的
> 一条错误结论**（"无线调试绕过厂商安装弹窗"）。

#### Added（新增）
- **真机接入（无线调试）**：`adb pair <ip>:<pairPort> <6位码>` → 配对成功后 mDNS 立刻可发现
  `_adb-tls-connect._tcp`，**adb 自动连上连接端口**（配对端口 ≠ 连接端口，实测 38659 / 39715）。
  设备：Xiaomi `23116PN5BC` / `shennong` / **arm64-v8a / Android 16 / SDK 36**；
  flutter 侧 id = `adb-960f853-Kmi5Mk._adb-tls-connect._tcp`。
- **`scripts/gates.sh` 新增 `fail_dump()`**：各层失败时把**完整输出**写入
  `${GATE_LOG_DIR:-/tmp}/gates_<标签>.log` 并回显尾部 15 行。

#### Fixed（缺陷修复）
- **AHW-05 / AHW-06 时间敏感假红**（`test/assist_host_screen_test.dart`）：两条用例断言
  **具体秒数**（`'04:5'` / `'00:4'`），而窗口都只有 **5 秒**，且 `_mmss(s.remaining)`
  读的是**真实墙钟**（FakeAsync 不虚拟 `DateTime.now()`）→ 功能层一次跑 465 例时，
  慢机器/并发下 `pumpWidget` 一旦 >5s 就跨过边界 → `Found 0 widgets`。
  改为**格式断言**（`RegExp(r'剩余 \d\d:[0-5]\d')`）+ **宽窗口数值断言**（`s.remaining`）。

#### 更正（推翻上一轮叙述）
- **撤回「无线调试绕过了厂商 USB 安装弹窗」**。抓屏铁证：即使走无线调试，MIUI 弹窗照旧出现，
  且**标题仍叫「USB 安装提示」** —— `[继续安装] [拒绝（10）]`，10 秒倒计时默认拒绝。
  真实边界是 **全新安装弹窗 / 覆盖安装免弹窗**：
  - 设备**无**应用 → **全新安装** → 弹窗 → 超时 → `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`（实测 **3 次**）
  - 设备**有**应用 → **覆盖安装** → `Success`，**全程无弹窗**（实测 **1 次**，无人干预，安装 15.1s）
  - 上一轮那次"成功且无弹窗"的真实原因是**使用者当场点了「继续安装」**
    （抓屏：弹窗 6 秒内消失，而倒计时是 10 秒 → 有人点了）。
  > 📌 教训：`…Install canceled by user` 里的 "by user" **必须截图抓现行**再下结论；
  > 单次采样 + 20 秒间隔的 `mCurrentFocus` 观察**不足以证明"没有弹窗"**。

#### Tested
- **真机 arm64 设备冒烟 4/4 全绿**（实测 **6 次**：verbose / 纯管道 / `$()` 包裹 /
  完整门禁序列 / 覆盖安装复跑）。
- 标准门禁：analyze **No issues**（13.6s / 8.8s / 11.0s）；功能层 **465/465**；压测层 **24/24**。
- 第二次门禁功能层出现 AHW-06 假红（已修，修后该文件 **7/7**）。
- **真机门禁内设备冒烟/桥接失败**（安装弹窗，**非代码问题**）。

#### Known Issues
- **真机设备门禁不能全自动**：需**人工点一次**「继续安装」建立初始应用；此后只要设备上应用在，
  设备测试即走覆盖安装（可自动）。
  `flutter test --[no-]uninstall`（`--no-uninstall` = 跑完保留应用）**参数存在**，
  但**本轮未实测其保留效果**（验证它需先完成一次成功安装，而首次恰好卡在弹窗）。
- **真机设备桥接（`native_bridge_test`，6 例）本轮未取得数据**（被同一弹窗拦住）。
- 缺口登记表剩 3 条（`taskGet` / `photo` / `heartbeat`），**均有正当理由、非缺陷**。

### 第十七轮补记（八）（2026-09-20）：真机门禁**前置步骤落地**（预装 + `--no-uninstall`）+ 首次**真机桥接数据** + 「链路掉了 ≠ 代码回归」

> 主题：把"**人工点一次**「继续安装」"从**口头约定**变成**门禁脚本里的一个分支**，
> 并实测确认 `--no-uninstall` 真的保留了应用。

#### Added（新增）
- `scripts/gates.sh` 设备层重做：
  - **`ensure_device_app()`**：跑设备用例前先确保设备上**已有应用**；没有就先 `adb install`
    （`PREINSTALL_TRIES` 次重试，引导人工点一次厂商确认框）。依据：厂商弹窗的触发条件是
    "设备上有没有这个应用"，与传输方式无关（见补记（七））。
  - **设备用例一律加 `--no-uninstall`**：跑完**保留应用** → 下次走**覆盖安装**（无弹窗）。
    （`flutter test` 默认 `--uninstall`，跑完卸载 → 下次又退回"全新安装"。）
  - **`device_alive()` / `is_transport_failure()` / `run_device_test()`**：把
    「传输链路掉了」从「用例失败」里分出来 → 归 **`BLOCKED`**，不污染代码红灯。
  - **`BLOCKED` 计数器 + 退出码 `3`**：`0`=全绿；`1`=门禁失败（代码回归）；
    **`3`=代码全绿但有环境阻塞（未执行 ≠ 失败）**。
  - `ONLY_DEVICE=1`（只跑设备层）、`SKIP_PREINSTALL=1`、`APP_ID=`（可覆盖，用于**证伪 BLOCKED 分支**）、
    `PREINSTALL_TRIES=N`。

#### Fixed（缺陷修复）
- **脚本自身**：字符串里的**反引号被当命令替换执行**（`` echo "…`input tap`…" `` 真的执行了
  `input tap` → `line 139: input: command not found`）。
- **脚本自身**：`adb install … | tail -1` **把失败原因吞成空行**（预装 3 次尝试输出全是空行）。
  → 改为捕获完整输出、无输出时显式打印 `[no output] RC=…`。**这是本项目已总结过的
  `tail -1` 教训在新代码里的复发**，修完立刻可见 `adb.exe: device '…' not found`。

#### Tested（真实执行数据）
- **真机设备桥接 `native_bridge_test` 首次取得数据：6/6 全绿**（此前两轮均为"未取得数据"）。
- **真机设备冒烟 `app_smoke_test`：4/4 全绿**（`--no-uninstall`）。
- **`--no-uninstall` 效果实测确认**：跑完 `pm list packages | grep sonic`
  → `package:com.sonicshield.sonic_shield` **仍在**。
- **设备层三分支全部实测**：已装→**EXIT=0**；未装+预装成功（模拟器）→**EXIT=0**；
  设备不可连→**BLOCKED / EXIT=3**。
- 宿主三层：analyze **No issues found**（12.7s）；功能层 **465/465**（00:22）；
  压测层 **24/24**（01:07）；`bash scripts/gates.sh` → **EXIT=0**。

#### Known Issues
- ⚠️ **真机无线调试链路不持久**：第二次复跑时桥接红，根因不是用例而是
  **设备侧无线调试已关闭/设备离开网络** → `adb devices` 与 `adb mdns services` 皆空、
  `192.168.2.11:{39715,38659,5555}` 三个端口全 **refused(10061)**、**adb server 亦已死掉**。
  **再次使用需设备侧重新开启无线调试**（脚本无法代劳）。
  该判据已固化为 `is_transport_failure()` → `BLOCKED`。
- **首次预装仍需人工点一次**「继续安装」（设备缺 `INJECT_EVENTS`，`input tap` 不可用）。
  ⚠️ **"引导文案 → 人工点击 → 成功"的完整时序未取到**（点击发生时正在跑门禁）。
- **BUG-022**、`ethernet`/`vpn`、`camera.snap`（等 AGP9）、YAMNet（模型源不可达）。
- 缺口登记表剩 3 条（`taskGet` / `photo` / `heartbeat`），**非缺陷**。

### 第十七轮补记（九）（2026-09-20）：「手机上打开黑屏」根因 + `scripts/install_app.sh` + `RemoteScriptsTab` 改走 `RcCommandChannel`（P3）

> 主题：用户报告"手机上打开这个软件初始黑屏" —— **不是应用缺陷**，
> 而是设备层门禁留下的**测试入口包**。本轮把根因、判据与修复做成可复用工具，
> 并顺带完成 P3 项（协助会话里跑不了指令组）。

#### Fixed（缺陷修复）
- **「打开黑屏 / 永久停在闪屏」根因定位**：`flutter test integration_test/…` 会把
  `build/app/outputs/flutter-apk/app-debug.apk` **覆盖成"测试入口包"**
  （Dart 入口 = `integration_test/xxx_test.dart`，在等 driver 连接）→
  从桌面启动永久黑屏、**无报错**（不建 DB、不连 broker）。
  硬证据：解 `assets/flutter_assets/kernel_blob.bin` →
  测试包含 `integration_test/` **22 处**、`lib/main.dart` **0 处**；
  真包（`flutter build apk --debug`，245,669,568 B）反之（0 处 / 4 处）。
  修复：装真包 245,669,568 B → `Success`（36s，同签名覆盖无弹窗）→
  `mCurrentFocus = …/MainActivity` → 抓屏确认首页正常。
- **`RemoteScriptsTab` 改走 `RcCommandChannel`（P3）**：本页原直接
  `sendTo(ep, …)`，只能驱动**已配对端点** → 协助会话目标跑不了指令组。
  改为面向通道（事件来源 `注入 > 通道 > 端点服务`；订阅 `channel.updates`），
  协助会话页加**控制台 / 指令组**两个 Tab（共用同一条命令路径，无第二套面板）；
  会话未激活 → **不发且说明原因**（不静默）；协助会话下不提供「新建指令组」入口
  （组装器路由需已配对端点 id），改为说明卡写明边界。

#### Added（新增）
- **`scripts/install_app.sh`**：把**可启动的真包**装到设备上。
  流程 = 构建 → **校验产物身份** → 覆盖安装 → 启动验证；退出码 `0`/`1`/`3`。
  支持 `--check-only`、`APK=<path>`、`DEV=<serial>`。
  身份判据：**`integration_test/` 命中 > 0 → test**；否则 `lib/main.dart` 命中 > 0 → real。
  ⚠️ 判据第一版用宽泛的 `main\.dart` → 真包与测试包因框架样板串
  （`file:///path/to/main.dart`、`http://localhost:8080/main.dart`）**双双命中**、恒为
  `unknown`；**靠证伪才发现**，改成语义判据后两个方向都验证成立。
- `scripts/gates.sh` 设备段开跑时新增提醒：设备用例会把 `app-debug.apk` 覆盖成
  测试入口包 → 手机上那个应用会黑屏，恢复用 `bash scripts/install_app.sh`。

#### Tested（真实执行数据）
- 新增 **4 例**回归锁（`test/remote_scripts_tab_test.dart` 4 → **8**）：
  RS-05 命令从通道发出 / RS-06 未激活不发且说明原因 / RS-07 不给组装入口 /
  RS-08 进度从通道回灌也要显示。
  **变异证伪**：`ch` 置空 + `_events` 忽略通道 → **RS-05 / RS-06 / RS-08 精确打红**；还原后 8/8 绿。
- 身份判据证伪：真包 → `real`(EXIT=0)；构造的测试入口包 → **`test`(EXIT=1)** ✅。
- `flutter analyze` **No issues found**（21.1s）；功能层 **469/469**（01:03，465→469）；
  压测层 **24/24**（01:17）；`bash scripts/gates.sh` → **EXIT=0**。
- 设备层（真机）：**BLOCKED / EXIT=3** —— 链路中途又掉（`adb devices` 与 mDNS 皆空）；
  脚本正确判为**环境阻塞**，未误报成"用例失败"。

#### Known Issues
- **真机无线调试链路不持久（第二次复现）**：19:26 装好并验证可用 → 19:47 再跑已空；
  连接端口每次都变（39715 → 45871 → ？）。**需设备侧重新开启无线调试**。
- ⚠️ **跑完设备门禁后手机上应用会变不可启动** → 收尾须 `bash scripts/install_app.sh`。
  当前已备好可启动真包（245,670,373 B，身份 `real`，含本轮 P3 改动），待设备在线即可装。
- 协助会话下只能执行**已收藏**的指令组模板，不能就地组装新的。
- **BUG-022**、`ethernet`/`vpn`、`camera.snap`（等 AGP9）、YAMNet（模型源不可达）。

### 第十七轮补记（十）（2026-09-20）：设备层**自动收尾**（跑完自动装回可启动真包）+ 反引号 bug 第三次复现

> 主题：把 §31 遗留的"跑完设备门禁 → 手机上应用不可启动"从**靠人记**变成**脚本自动收尾**。

#### Added（新增）
- `scripts/gates.sh` 设备层**自动收尾**（默认开，`RESTORE_APP=0` 可关）：
  - 开跑前 `cache_real_apk()`：若当前 `app-debug.apk` 是**真包**，缓存副本到
    `build/app/outputs/flutter-apk/app-debug-real.apk`；
  - 跑完后 `restore_real_apk()`：用 `--no-build` 装回缓存副本 → **省一次 ~50s 的 Gradle**；
  - 恢复失败记 **`BLOCKED`**（不是 `FAIL`）—— 设备状态异常，**不是代码回归**。
  - 设计取舍：默认开启，目标是"**门禁跑完，手机一定可用**"。
- `scripts/install_app.sh --no-build`：跳过构建、直接装现有 APK（仍校验身份后安装）。

#### Fixed（缺陷修复）
- ⚠️ **反引号 bug 第三次复现**：提醒文案里的 `` `RESTORE_APP=0` `` 被当**命令替换**执行
  → 输出成 `（ 可关）`。全量排查发现**两处**：
  - `scripts/gates.sh:247` —— 文案缺字（**靠看实际输出才发现**，静态读代码看不出）；
  - `scripts/install_app.sh:117` —— **潜在严重**：`` `flutter build apk` `` 被当命令执行
    → 每次都会**多跑一次完整构建**。
  已全部修掉；`scripts/` 内残留为 0。
  > 📌 **判据/文案写完后必须"看实际输出"** —— 这是同一类错误的第三次。

#### Tested（真实执行数据）
- 干跑验证整条新路径（`SKIP_PREINSTALL=1` + 设备离线）：
  `[缓存] 真包副本 → app-debug-real.apk` → 冒烟/桥接 `BLOCKED`（设备不可连）
  → 收尾装回（`--no-build`，身份 `real`）→ 因无设备失败 → `BLOCKED` / **EXIT=3**。
- ⚠️ **未取得"有真设备时自动恢复成功"的实测**（真机本轮一直离线）。
  验证到的是**分支逻辑与判据**，不是端到端成功 —— 如实记录。

#### Known Issues
- 真机无线调试链路不持久（已复现 2 次）：19:26 可用 → 19:47 空；连接端口每次都变
  （39715 → 45871 → ？）。需设备侧重新开启无线调试。
- 已备好可启动真包（245,670,373 B，身份 `real`，含 P3 改动）、并已缓存副本
  `app-debug-real.apk`，设备在线即可装。
- **BUG-022**、`ethernet`/`vpn`、`camera.snap`（等 AGP9）、YAMNet。
- 协助会话下只能执行**已收藏**的指令组模板，不能就地组装新的。

### 第十七轮补记（十一）（2026-09-20）：审计「带兜底分支的 switch 表」→ BUG-058 + 压测层假红**第三次** + 门禁自动重跑确认

> 主题：做 §32⑥ 的待办（继续审计 switch 兜底），21 处里抓到 1 处真缺陷；
> 顺带把**已复现 3 次**的压测层假红在脚本层面消化掉。

#### Fixed（缺陷修复）
- **BUG-058**：`lib/features/tasks/task_editor_screen.dart` 的 `_kindOfCandidate`
  用 `_ => RcStepKind.play` 兜底 → 复合 / 声景 / 嵌套动作组被**静默当成"播放音频"**
  回填。用户打开一个含这些子动作的任务、**什么都不改直接保存**，原配置就被悄悄改掉。
  更严重的是 `ActionConfig` 是 **sealed**，写 `_` 会**关掉编译器的穷尽性检查**
  → 以后新增任何子类都静默掉进兜底、不报错。
  修法：抽顶层纯函数 `stepKindOfAction(ActionConfig) → RcStepKind?`，
  **显式穷尽 8 个子类**（复合/声景/嵌套 → `null`），新增子类时**编译报错**；
  编辑器把不可表示的子动作收进 `_setPreserved`，保存时 `..._setPreserved` 原样带回来
  → **打开再保存不丢配置**；UI 给说明卡明说"已保留"。
  可达性：编辑器 UI 造不出嵌套，但 `ActionConfig.fromJson`（读库 / 导入 JSON）是真实路径。

#### Added（新增）
- `scripts/gates.sh`：**压测层失败时自动单独重跑一次确认**（`PERF_RETRY=0` 可关）。
  首次红 → 重跑绿 → 记 `PASS` 并**明确标注"首次未过是机器负载噪声，不是代码回归"**，
  首次实测仍落盘；重跑仍红 → **照旧 `FAIL`**（真回归不会被吞掉）。

#### Tested（真实执行数据）
- 新增 **5 例**锁 `test/task_editor_action_set_test.dart`（ASE-01..05），含 2 例源码级
  （不得有 `_ =>`；子类清单与 `action.dart` 同步防腐烂）。
  变异证伪：改回 `_ => RcStepKind.play`（BUG-058 原状）→ **ASE-02/03/04 精确打红**，
  ASE-01/05 保持绿；还原后 5/5 绿。
- 压测重跑分支**三个方向都验证**（用 PATH 桩替掉 `flutter`，秒级干跑）：
  A 首次红→重跑绿 = `PASS`(EXIT=0)；B 两次都红 = `FAIL`(EXIT=1)；
  C `PERF_RETRY=0` = `FAIL`(EXIT=1)。**证伪方向 B/C 通过 = 真回归不会被当成噪声吞掉。**
- `flutter analyze` No issues；功能层 **474/474**（469 → 474）；压测 **24/24**；
  `bash scripts/gates.sh` → **EXIT=0**。

#### Known Issues
- ⚠️ **压测层假红已复现 3 次**：全量门禁里压测层跑在 analyze + 功能层（约 9 分钟）之后，
  机器热/后台负载会让它整体偏慢。本次 3 条红实测 10704/8000、2978/2000、313/300，
  超出幅度（34% / 49% / 4.3%）**彼此不成比例**，且与本轮改动（纯映射函数）无因果关系；
  单独重跑 `--tags perf --concurrency=1` → **24/24 全绿**。现已由自动重跑机制覆盖。

### 第十七轮补记（十二）（2026-09-20）：21 处 switch 兜底**全部判完** + 「展示/说明类查表」覆盖锁

> 主题：做完 §33⑤ 的「继续审计剩余 switch 兜底」。**21 处全部判完**，
> 13 处良性，另修掉两处"展示/说明类漏登记"并加 5 例锁。

#### Fixed（缺陷修复）
- `remote_tasks_tab._kindToType` **漏 `composite` / `randomFrom`** →
  组合动作的主动作是"随机指令集 / 嵌套组合"时，任务摘要显示成「通知 + 」（**空标签**），
  用户看不出这任务到底要干什么。
- `_actionLabel` / `_triggerLabel` 的兜底**只判 null 不判空串**
  （`'${raw ?? '未知动作'}'`）：`raw=''` 会渲染成**空白** —— `''` 不是 null，`??` 救不了。

#### Added（新增）
- `test/remote_label_perm_coverage_test.dart`（**5 例**，LBL-01..05）：
  LBL-01 `_kindToType` 覆盖 `ActionConfig.fromJson` 的全部 kind /
  LBL-02 组合·随机指令集必须有名字 / LBL-03 `_actionLabel` 覆盖 `_kindToType` 全部产出 /
  LBL-04 兜底必须显式判空串 / LBL-05 每个权限键都在 `_permHint` 有说明文案。

#### Tested（真实执行数据）
- 变异证伪：删掉 `composite`/`randomFrom` + 兜底改回 `'${raw ?? '未知动作'}'`
  → **LBL-01 / LBL-02 / LBL-04 精确打红**，LBL-03/05 保持绿；还原后 5/5 绿。
- analyze **No issues**（16.2s）；功能层 **479/479**（474 → 479）；压测 **24/24**；
  `bash scripts/gates.sh` → **EXIT=0**（6m36s）。

#### Known Issues
- 真机本轮**全程离线**（第五次复现），设备层与"自动收尾恢复真包"的
  **端到端成功仍未取到**。

### 第十七轮补记（十三）（2026-09-20）：`??=` 静默替换审计 → **BUG-059**（声景点名了却改播任意音源）

> 主题：审计 `lib/` 全部 5 处 `??=`：3 处良性，**1 处真缺陷 = BUG-059**。

#### Fixed（缺陷修复）
- **BUG-059**：`background_engine.soundscapeAndLog` 的轨道解析链第三级是
  `pickAnyAssetPath()`（"库里任意一条"）。但 `SoundscapeTrack` 断言
  `assetId` / `presetCategory` **必居其一** → 第三级**只可能在"点名了却没找到"时
  触发**，效果是**用户挑的音源被删了 → 静默改播一条完全不相干的声音**，且不报错。
  这正是 BUG-048 判据「点名了就必须满足，满足不了要失败，绝不 `??=`」的形状。
  对照：同文件普通播放用的 `PlayAudioAction` **没有**点名字段（设计上就是随机），
  那里用随机是应有之义；声景每轨都是用户**显式挑的**，不该凑数。
- 修法：抽纯函数 `soundscapeTrackPath({byId, byCategory}) => byId ?? byCategory`
  —— **签名里没有第三级入参**，让"不兜底"成为**结构性**的（比源码锁更强）。
- 补留痕：全轨解析不出 / **部分轨解析不出**都写审计（部分失败此前**完全无声**）。
- 顺带删掉已无用的 `pickAnyAssetPath()`（留着不用等于埋雷）。

#### Added（新增）
- `test/soundscape_track_test.dart`（**5 例**，SCT-01..05）：
  assetId 优先 / 退到分类 / **两个都 null → null（绝不编造）** /
  **前提锁**（`SoundscapeTrack` 必居其一，没有这条前面的结论不成立） /
  源码锁（不得声明 `pickAnyAssetPath`、不得 `??=`、**入参集合恰好 {byId, byCategory}**）。

#### Tested（真实执行数据）
- 变异证伪**两个方向**：加回 `anyFallback` → **SCT-05 红**；
  **换成 `fallbackPath`**（旧断言"参数名含 any"会漏）→ **仍红**；还原后 5/5 绿。
- analyze No issues（11.1s）；功能层 **484/484**（479 → 484）；压测 **24/24**；
  `bash scripts/gates.sh` → **EXIT=0**（3m49s）。

#### ⚠️ 写锁时踩的两个坑（都让锁自己失效）
1. **源码锁误伤注释**：断言"文件里不得出现 `pickAnyAssetPath`"，但文档注释为说明
   历史必然提到它 → 恒红。改查**声明 + 调用点**。
2. **正则 `?` 忘转义 → 恒红**：`r'String?\s+(\w+)'` 的 `?` 是**量词**，
   匹配成 `Strin` → 入参集为空 → 永远红。**恒红的锁比没锁更坏**。
   已加 `params.isNotEmpty` 自检防正则静默失效。
3. 中途一次 `[FAIL] analyze`（info 级 `prefer_const_constructors`）：
   SCT-04 为触发**运行时**断言故意不用 `const`。**门禁只认 "No issues found"，info 也算**。

#### Known Issues
- 真机本轮全程离线，设备层与"自动收尾恢复真包"的端到端成功仍未取到。

### 第十七轮补记（十四）（2026-09-20）：`firstWhere` 审计 → **BUG-060**（"选中端点"是旧状态，找不到就崩）

> 主题：`lib/` 里 `firstWhere` 只有 4 处，1 处良性（带 `orElse: throw`），
> **3 处无 `orElse` = BUG-060**。

#### Fixed（缺陷修复）
- **BUG-060**：`dashboard/quick_scripts_card`、`features/remote/ptt_tab`、
  `features/remote/remote_scripts_tab` 三处都写成
  `endpoints.firstWhere((e) => e.deviceId == _selectedId)`（**无 `orElse`**），
  找不到会抛 `Bad state: No element`。
  而 `_selectedId` 是**跨页面共享的旧状态** —— 用户在别处解配对、或配对表被清，
  本页状态不刷新 → 一点「发送 / 松开对讲 / 快捷指令」就**崩溃且无任何提示**。
  > 判据（与 BUG-058/059 同一条纪律）：**要失败，但不要崩** ——
  > 崩溃既不留痕（无审计），用户也无从知道原因。
- 修法：新增纯函数 `endpointById(List<PairedEndpoint>, String) → PairedEndpoint?`
  （找不到返回 **null**，不抛）；三处调用点改为**明确告知"端点已不存在（可能已解配对）"**。
- `rc_script.dart:25` 那处判定**良性**：带 `orElse: () => throw ArgumentError(...)`，
  是**显式失败**（与 `action.dart` / `trigger.dart` 一致）。

#### Added（新增）
- `test/endpoint_by_id_test.dart`（**4 例**，EBI-01..04）：找得到 / **找不到 → null 不抛** /
  空 id·空表不抛 / **全局锁**：`lib/` 每处 `firstWhere`/`lastWhere`/`singleWhere`
  **必须带 `orElse:`**，失败时**报具体行号**。

#### Tested（真实执行数据）
- 变异证伪**两个方向**：`endpointById` 内部退回 `firstWhere` → **EBI-02 红**；
  `ptt_tab` 调用点改回 `firstWhere` → **EBI-04 红**，定位 `ptt_tab.dart:100`；还原后 4/4 绿。
- analyze No issues（10.4s）；功能层 **488/488**（484 → 488）；压测 **24/24**；
  `bash scripts/gates.sh` → **EXIT=0**（3m23s）。

#### Known Issues
- 真机本轮全程离线（第七次），设备层与"自动收尾恢复真包"的端到端成功仍未取到。
- 已全量审完的面：switch 兜底 **21/21**、`??=` **5/5**、`firstWhere` **4/4**；
  剩下唯一规模大的可审计面是 **`??` 兜底 262 处**。

### 第十七轮补记（十五）（2026-09-20 续）：`??` 兜底全量审计 —— 262 处**0 个真缺陷**（**可审计面已全量审完**）

> 主题：把 docs/17 §36⑥ 列的最后一个可审计面扫完。

#### Audited（审计结论）

按 BUG-048 判据「点名了就必须满足，绝不 `??=` 静默替换」筛出真正可能
"播放/操作了用户没点名的对象"的子集：
- **`?? await ...`**：**2** 处，全部良性（DB 目录配置兜底 + 协助会话密钥缓存失效重新派生）
- **`?? <list>.first` / `?? <list>[idx]`**：**0**（没出现这种危险形态）
- **`??= ...`**：续十二已审（0 缺陷）

**262 个总数里绝大多数是 `j['x'] as num? ?? 0.6` 这种 JSON 字段兜底**
（Dart `fromJson` 标准写法）—— 导入/旧版本数据缺字段给合理默认值，
不属于"用户点了某条却给了另一条"。

#### 已全量审完的 4 个面

| 面 | 出现处 | 缺陷 |
|---|---|---|
| switch 兜底 | 21 | BUG-058 |
| `??=` 静默替换 | 5 | BUG-059 |
| `firstWhere` 兜底 | 4 | BUG-060 |
| `??` 兜底 | 262（含 JSON 反序列化） | **0** |

**非硬件阻塞全部清空。** 下一个新增的可审计面要等代码变化后再扫，
新代码动手前**先跑一遍这 4 个全局锁**确认没破：EBI-04 / ASE-03 / SCT-05 / LBL-01。

### 第十七轮续十五（2026-09-20）

**Fixed（BUG-061：守卫开关失败时完全静默）**

真机复现：点守卫开关后 `value` 保持 false、`mgr.last == null`，页面文案**零解释**。
根因：`setGuard()` 是 fire-and-forget 的 `invoke`，引擎没跑时发向不存在的服务、
彻底 no-op，而 UI 只看"调用完成"就 `setState` —— 开关弹回且不说原因。

三条失败路径（引擎未运行 / 麦克风被拒 / 引擎无响应）此前表现完全相同。
修法：抽 `guard_toggle.dart`（依赖全注入）+ `waitForGuardActive()` 让"下发"与
"生效"可区分，逐条给出可操作提示。
真机修复验证：300ms 内出现「守卫需要后台引擎：请先在「守护」页开启守护」。

**Fixed：电池白名单框每次都弹** —— `requestAllPermissions()` 无条件请求，
改为先 `isIgnoringBatteryOptimizations()` 判定。

**Added：「我的设备」列表（向日葵式：保存连接 + 快速连接）**

此前 `_selectedId` 是每个 TAB 各自的局部 State，列表页选好的端点切到控制台就丢了。
- `RemoteStore`：`selectedEndpointId` 持久化 + `selectEndpoint` / `setSelectedEndpoint`
  / `renamePaired` / `touchPaired`；删掉当前目标时清空选择
- `PairedEndpoint`：新增 `alias`（备注名）+ `lastConnectedAt`，`displayName` 备注优先
- 共享纯函数 `initialSelectedId()`：优先已选（且仍在配对表里），三页统一调用
- 新页 `device_list_screen.dart`，「远程」分组新增子 TAB「我的设备」

**Tested**：新增 21 例（GTO-01..07 / DLS-01..14），四个方向变异证伪全红；
analyze No issues；功能层 **509/509**（488 → 509）；压测 24/24；gates → **EXIT=0**。

**⚠️ 源码锁误伤注释（第三次同类）**：新注释里的 `firstWhere` 字面量让 EBI-04 恒红。
这次不删注释，而是给锁加"跳过整行注释" + `scanned > 0` 反向自检，
并用注入变异验证加固后仍抓得到真违规。

### 第十七轮续十六（2026-09-20）：多设备视频同连（用户第 3 项）

**Added：多设备视频同连 —— 同时保持多路视频，点窗口切换目标，切换不断开**

`CallService`（630 行）是**单会话**设计（单 `_pc`/`_callId`/`_phase`/`_peer`），
重做成多会话会牵动来电/振铃/自动接通（BUG-050/056 那套），风险高。
改为**新增 `MultiCallService`（只管本机发起的多路）+ callId 归属隔离**：
- `Map<deviceId, MultiCallSession>`，一路一条 `RTCPeerConnection`
- **复用同一条本地 MediaStream**（为 N 路各开一次摄像头既耗资源，也会在部分机型失败）
- `setActive()` **只改焦点、不挂断任何一路** —— 这是"保持视频链接的情况下发送远程指令"的关键
- 隔离边界 `ownedCallIdOf()`：只处理自己的 callId，来电仍归 `CallService`，两者不抢信令

新页 `multi_video_screen.dart`（窗口网格 + 底部指令条对当前窗口发 ping / device.status），
入口：远程 → 通话 → **多设备视频同连**。

**⭐ 锁抓到了新代码自身的缺陷**：`ownedCallIdOf` 原本写 `m['callId'] as String?`，
远端报文字段类型不可信，收到数字会**抛异常**（整条事件流崩溃）—— **MCS-04 当场抓到**，
改为 `raw is! String` 判定。

**Tested**：新增 11 例（MCS-01..11）；变异（去掉 callId 归属检查）→ **MCS-02 红**；
analyze No issues；功能层 **520/520**（509 → 520）；压测 24/24；gates → **EXIT=0**（2m25s）；
真机验证页面可达 + 空态（`PROBE multi-video page OK`，+1 passed）。

**未闭环**：多路实际连通性需 ≥2 台设备（当前 1 台真机 + 2 个模拟器），本轮只验证页面可达。

### 第十七轮续十八（2026-09-20 末）：第 4 项开工 —— **BUG-062（权限静默失效）×2**

**Fixed（BUG-062：权限申请类"不好使"的两处真因）**

按 BUG-061 的同一判据（**失败必须让用户知道**）逐个审权限申请点，抓到两处静默失效：

| 位置 | 原实现 | 真实后果 |
|---|---|---|
| `call_screen._toggleAuto` | `await [camera, microphone].request();` 结果**被丢弃**，然后无条件开启 | 权限被拒也**照样显示"已开启"**，实际来电根本接不起来 |
| `remote_screen._pttSheet` | `if (!granted \|\| !mounted) return;` | 麦克风被拒**静默 return**，用户点了「对讲」毫无反应 |

审过且良性（勿重复排查）：`pair_qr_screen:168`（扫码，已有提示）、
`ptt_tab:71`（已有提示）、`guard_screen`（BUG-061 后统一走 `toggleGuard()`）。

**修法**：新增 `lib/remote/call_permission.dart` —— `autoAnswerBlockFor()` 纯函数
+ `autoAnswerBlockText()`；`_toggleAuto` 被阻断时**不开开关**并给出原因；`_pttSheet` 补明确提示。

**Tested**：新增 8 例（AAP-01..08），含两条**调用点源码锁**防"改回丢弃结果"；
analyze No issues（14.5s）；功能层 **528/528**（520 → 528）；压测 24/24；gates → **EXIT=0**（3m04s）。

⚠️ AAP-07 第一版**恒红**：判据写成"不得出现 `].request();`"，但修复后写法
`final status = await [...].request();` 同样含它。真正的丢弃特征是
**整条语句以 `await [` 开头**。教训（与"源码锁误伤注释"同族）：
**锁的判据必须描述特征，不能描述字面量。**

### 第二十轮（2026-09-21）：门禁可信性审计 —— 一次被"另一个项目"拖红的门禁

**本轮无新功能。** 主题：把"门禁到底可不可信"查清楚，交付可复现的绿色基线。

**查证（不是回归，是跨项目 CPU 争用）**

第一次全量门禁红了，但 `git status` 全程干净。查证链：

| 观察 | 数值 | 判据 |
|---|---|---|
| 功能层耗时 vs 基线 | `07:33 +576 -2` vs `00:25–00:38` | **12–18×** |
| 压测层耗时 vs 基线 | `13:30` vs `01:00–02:13` | **6–13×** |
| 失败形态 | 全是 `TimeoutException after 0:00:30` | **钟表敏感** |
| 超出幅度是否成比例 | 1.07× / 1.29× | **不成比例** ⇒ 负载 |
| 隔离复跑 | **`52/52 All tests passed!`** | **环境问题（实锤）** |

**根因（实测）**：另一个项目（`sports-intelligence-os`）的 **17 个 Docker 容器**
跑在 WSL2 里，`vmmemWSL` 独占 **8.2 / 16 核**（`49.48 CPU秒 / 6秒采样`），
整机 `LoadPercentage=100`。容器合计 ≈ **7.4 / 16 核 = 46%**：
`scrape-worker 417.72%` / `worker 217.50%` / `postgres 63.63%` / `browser 23.16%` / `api 19.89%`。

⚠️ `ps | grep 'dart|flutter'` **只有门禁自己那 1 个 `flutter.bat`** ——
按"查本项目残留进程"的老办法**永远查不到**（`vmmemWSL` 名字里没有 flutter 相关字样）。

**两处"红"的机理**（都是钟表敏感，非断言逻辑）：

- `assist_join_test.dart` **AJ-24**：`join()` 默认 `timeout = 20s`，用例上限 30s，
  用例内连做两次 join → 15× 拖慢下第二次烧光预算返回 false，
  于是 `TimeoutException` 与 `Expected: true / Actual: <false>` 同时出现；
- `v2_features_test.dart` GCM 篡改：`encrypt` + `decrypt` 各跑一遍 PBKDF2 → 越过 30s。

**未改一行业务代码、未放宽任何阈值。**

**Verified（干净门禁基线，Docker 栈退出后重跑）**

```
analyze      No issues found! (ran in 19.3s)   [PASS]
功能层       02:14 +578: All tests passed!      [PASS]
压测层       02:57 +24:  All tests passed!      [PASS]
全部门禁通过 ✅   RC=0（总 8m54s）
```

压测层内置的"首次未过 → 单独重跑一次"机制**本轮生效**
（首次 `13:30 +18 -6` → 重跑 `07:18 +24` → PASS），说明该机制确实在消化负载噪声。

**契约复核（用户点名项）**：`prob_gate_test.dart` 最后一条失败断言已按
**实现的实际契约**锁定 —— `TaskCondition.toJson()` 对 `probabilityPct`
**非 null 即写（含 100）**；复核 `prob_gate + edge_coverage` → **14/14 绿**。

**Docs / Tooling**

- `docs/17 §45`（第二十轮开场 = 第四次交接，含"下轮开工前必做"探针命令）
- `docs/12 §45`（门禁可信性审计完整记录）
- `HANDOVER.md §9`：开场白重写 + 第 3 步新增**"先确认整机空不空"**纪律
- 技能 `flutter-flaky-gate-triage` 新增一节
  **"更隐蔽的一类：别的项目在吃 CPU（Docker / WSL2 / 模拟器）"** + 速查表入口

**下一轮**：覆盖率冲刺（用户第 4 项要求 99%+；全局 57.5%+，设备层豁免 ≈1419 行，
可测面剩余 ≈640 行，逐文件清单见 docs/17 §45⑦）。

### 第二十一轮（2026-09-21）：覆盖率冲刺开工 —— 先修测量，再修两个真缺陷

**Fixed（BUG-063：远程任务页忽略共享选择，会静默操作错误的设备）**

`remote_tasks_tab._load()` 用的是
`_selectedId.isEmpty ? _endpoints.first.deviceId : _selectedId`，
**完全忽略 `store.selectedEndpointId`**。而设备列表 / 控制台 / 对讲 / 指令组
四处都走 `initialSelectedId(...)` —— 它是唯一漏网的。

后果：用户在「我的设备」里选中 B 并快速连接，再切到「任务」子页，
本页仍指向 **A** 且无任何提示 —— **启停/编辑/删除静默落在错误的设备上**
（删除会删掉 A 上的任务）。不是"显示不对"，是**操作对象错**。

修法：改用 `initialSelectedId(...)`，与三个兄弟页对齐。
回归锁 `RTT-16`/`RTT-17`；还原成旧写法即红（`Found 0 widgets with text "B 机"`）。

**Fixed（BUG-064：TURN 设置对话框在关闭动画期间使用了已释放的 controller）**

`remote_screen._editTurn()` 在 `await showDialog(...)` 之后**立刻** dispose
三个 `TextEditingController`。但 `showDialog` 的 future 在 `Navigator.pop`
那刻就完成，而路由**退场动画还在跑** → `TextField` 仍引用已释放的 controller
→ debug 下抛 `A TextEditingController was used after being disposed`（红屏），
**且异常会污染同文件后续用例**（RRS-12/13/14 连带红、单独跑却全绿）。

修法：抽出 `_TurnDialog`（StatefulWidget）自己持有并在 `dispose()` 里释放 ——
**时机由框架保证**；返回值改为 record `(url, user, cred)`。

**Fixed（测量缺陷：覆盖率分母漏算 40% 的代码）**

Dart 覆盖率只统计**运行期被加载过的库**：未被任何 import 触及的文件在
`lcov.info` 里**完全不存在**（不计分子也不计分母）→ **越不测越好看**。

实测 `lib/` 下 74 个 `.dart`，lcov 里只有 44 个 `SF:` 记录 ——
**30 个文件（含全部主要 UI 页）从未被 import**。

| 口径 | 数值 |
|---|---|
| 旧（错） | 57.5% = 2878/5003（分母只有 44 个文件） |
| **新（对）** | **39.68% = 2932/7390**（分母 = `lib/` 全部文件） |

修法：`test/coverage_sentinel_test.dart`（生成物，只 import 不调用）+
COV-01 自检锁（新增 lib 文件忘刷新哨兵即红）+ `tool/coverage_report.dart`
（双口径 + 4 条锁）。证伪：注入新 lib 文件 → COV-01 红并点名。

**Tested**

| 文件 | 例数 | 内容 |
|---|---|---|
| `test/remote_tasks_tab_test.dart` | 19 | 空态/禁用态/列表/摘要/开关/跳过/删除确认与取消/立即执行超时/exec 留痕/无主回执/离线入队 + BUG-063 锁 ×2 |
| `test/remote_screen_test.dart` | 14 | 开关落库/身份复制/broker 保存与取消/TURN 保存/配对校验不留半条/配对归一化/扫码入口 |

覆盖率：**39.68% → 45.52%**（3372/7408），用例 **579 → 612**。
`remote_tasks_tab` 0.30% → **71.55%**；`remote_screen` 0.84% → **73.12%**。

**Tooling**

`scripts/gates.sh`：analyze 失败时**打印具体问题行 + 落盘完整输出** ——
原先只 `tail -1`，门禁报 `[FAIL] analyze` 却看不到是哪一条
（2026-09-21 实测踩到，只能手工重跑 analyze 才知道）。已注入 lint 证伪。

**设备层豁免清单仍为空** —— 豁免必须用证据换，不先假设（判定法见 docs/17 §46⑤）。

### 第二十二轮（2026-09-21）：路由表整体 pump —— 覆盖率 45.52% → 54.82%

**Added（`test/router_test.dart`，32 例 RTR-01..06）**

路由表是**唯一**把「URL / 深链 / 底部导航 / 二级 TAB」绑在一起的地方，
而它出错的形态**全是静默的**：改路径字符串 → 旧外链 404；改 `_destinations`
顺序 → 点「日志」进「设置」；漏改 `_tabOf` → `/local?t=2` 打开的是「任务」
而不是「守卫」。逐条上锁：

| 组 | 锁什么 |
|---|---|
| RTR-01 | 4 条旧路径重定向 + **未登记路径不被改写**（`redirect` 的 `return null`） |
| RTR-02 | 底部导航 5 项顺序/文案唯一真源、点击映射、**再点当前 TAB 回分支根**、切走切回**保留分支位置** |
| RTR-03 | `?t=` 深链解析（非数字/空/越界 clamp）+ `initialIndex` **真的作用到 TabBar** |
| RTR-04 | 10 条整页路由**可达且盖掉底部导航**（沉浸式） |
| RTR-05 | **路径参数值**传递（`/tasks/:id/edit`、`script-builder/:endpointId`） |
| RTR-06 | 5 个分支各渲染正确分组页、切 TAB 不叠加渲染 |

**覆盖率：45.52% → 54.82%（+691 行 / +9.30pt），用例 612 → 644**

`lib/core/router.dart` 自己只有 **59 行（现 100% 覆盖）**，但"整壳 pump"顺带把
**5 个分组页 + 10 条整页路由**的 `build()` 全跑了一遍 —— **+691 行里 97%
来自它顺带构建出来的别的页面**。这是当前性价比最高的一档打法。

**本轮 `lib/` 零改动**（只新增测试文件 + 修门禁诊断）。

**Tooling（门禁缺陷：持续争用下会把噪声判成「真回归」）**

原逻辑"压测层首次红 → 自动重跑一次 → 还红即**真回归**"。
但压测层是**墙钟预算**，机器被别的项目占满时两次都会红 → **必然误判**。
2026-09-21 实测：另一个项目的 Docker 构建让整机 CPU 长时间 84–91%
（`vmmemWSL` 14.1 GB + `com.docker.build.exe`），两条最紧的预算用例
分别超出 **8.3%** 与 **69%**，而本轮 `lib/` 一行未改。

`scripts/gates.sh` 已补 `machine_load()` 整机负载探针：

- 开工时负载 ≥60% → **提前警告**（提示可能是别的项目的 Docker/WSL2）；
- 压测层重跑仍红 → **先看负载**：≥60% 报 `[BLOCKED]` + **RC=3（环境阻塞）**，
  并给出复跑命令；负载正常才报 `[FAIL]` + RC=1（真回归）；
- 阈值可用 `LOAD_SUSPECT=<n>` 覆盖。

**这条新分支两个方向都验证过**（只验一个方向的话，"恒报 BLOCKED"的假锁
也会看起来是绿的 —— 那正好会掩盖真回归）：

| 验证 | 结果 |
|---|---|
| `perf_verdict()` 6 个方向（含边界 59/60、取不到负载 -1） | 全部符合预期 |
| 注入失败探针 + `LOAD_SUSPECT=1` 跑完整门禁 | `[BLOCKED]` + 提前警告触发 + **RC=3** ✅ |
| 同一探针 + `LOAD_SUSPECT=100` | `[FAIL]` + 警告未触发 + **RC=1** ✅ |

**负载阈值标定**（同一份代码三次实测）：33–52% → 压测全绿；66% → 全绿；
84–91% → 两条最紧预算破线。破线点落在 66%~84% 之间，**故意取偏低的 60%**
—— 宁可多要一次人工复跑，也不误报"真回归"；且 BLOCKED 退出码是 **3（非零）**，
不会被静默放过。

⚠️ **未放宽任何性能阈值** —— `PT-*` 的预算常量一个没动，
只是把"测量无效"与"代码回归"分开报告。

**门禁（实测）**

| 轮次 | analyze | 功能层 | 压测层 | RC |
|---|---|---|---|---|
| 首次（争用中，CPU 84–91%） | No issues (19.1s) | **644/644** ✅ | ❌ 两条墙钟预算破线 | 1 → 取证为环境 |
| **复跑（争用消退）** | No issues (15.9s) | **644/644** ✅ | **24/24** ✅ | **0** |

**终局证据**：争用消退后复跑，同一份代码、同一套预算 → **全绿 + RC=0**。

**Docs / Skills**

- `docs/17 §47`、`docs/12 §47`
- 新技能 **`flutter-widget-test-harness`**：宿主 widget 测试的**四类假故障**
  （① 用例体里 `await` 真实 I/O → **永久挂死**，实测 `AppDatabase.open` 卡满 6 分钟；
  ② `go()` 在首帧之后 → **`uri` 对但屏幕是旧页**；
  ③ sqflite 锁超时 Timer（10s）残留；
  ④ Riverpod `autoDispose` 的零时长 Timer —— `pump()` 不传时长不 elapse）
  + 可抄的 harness 模板 + "这类测试怎么证伪"
- 技能 `flutter-coverage-truth` 补"**整壳 pump**"这一档 ROI

**下一轮**：压测层在空闲机器复跑；继续按未覆盖行降序补单页
（`task_editor_screen` 211 / `settings_screen` 136 / `multi_video_screen` 108 …）；
A 组逐行取证；覆盖率 ratchet 进门禁。

### 第二十三轮（2026-09-21）：`task_list_screen` + `settings_screen` —— 顺带抓到两个「功能从来没成功过」的真缺陷

**Fixed（缺陷修复）—— 本轮最大产出**

- **BUG-065（P1，功能级）：导出备份的路径从来就不存在。**
  `'$dir/sonic_shield_tasks_$stamp.json'` —— `Directory.toString()` **实测**返回
  `Directory: 'C:\Temp\abc'`（带 `Directory: ` 前缀和一层引号），插值后是**不存在的路径**
  → `writeAsString` 必抛 → **加密导出与非加密导出两条路径从未成功过**。
  全仓 7 处目录拼接**只有这一处漏了 `.path`**（所以看着"和旁边一样"）。
  修复：`'${dir.path}/…'`。
- **BUG-066（P1，隐私红线）：用户要加密，却拿到明文备份。**
  `_askPassword` 用 `null` 同时表示**「取消」**与**「两次密码不一致」**，
  旧写法两种都落进明文分支 → 用户明确选了加密，却得到**含全部任务与音源引用的明文备份**
  并交给系统分享面板。与 BUG-056（"隐私开关不得静默失效"）**同源**。
  修复：`if (password == null) return;`（取消/不一致 → **整体中止，不导出**）。

**Added（新增测试）**

- **`test/task_list_screen_test.dart`（24 例 TLS-01..08）**：空态 / 列表渲染（含"下次：MM-DD HH:MM"）/
  启停开关**双向落库** / 跳过下一次 4 分支 / 导航意图 + **返回后重读库** / 长按复制·删除
  （**级联清 occurrence**）/ 外壳与失败 / 下拉刷新。
- **`test/settings_screen_test.dart`（23 例 SET-01..06）**：渲染回填 / 电源策略落库（双向）/
  免打扰时段落库 / 两个弹窗 + `openExactAlarmSettings` 通道 / 导出 7 例 / 导入 6 例
  （含**半批回滚**、解密失败、空密码）。平台通道全部打桩
  （`path_provider` / `share_plus`），`file_picker` 走官方注入点 `FilePicker.platform`。
- **`test/dir_path_interpolation_test.dart`（3 例 DIP-01..03）**：BUG-065 **复发锁** ——
  **源码扫描**全 `lib/` 的 `$dir` 插值（不锁字面量、锁"这一类"），含**自检**（反面样本必被检出）
  与**防空转哨兵**（API 改名后锁会空转 → 必须显式报警）。

**Changed（可测性）**

- `BackgroundServiceManager` 新增 `@visibleForTesting static invokeHook` 测试缝 ——
  非 Android/iOS 上 `FlutterBackgroundServicePlatform.instance` **直接抛**，
  且异常发生在 `setState` 之前（界面停在旧值，指不到真因）。`replanHook` 早为同一原因存在，
  但 `setGuard` / `setPowerMode` / `stop` 漏了。**生产路径一行未变**。

**覆盖率：54.82% → 58.35%（4325/7412，+259 行 / +3.49pt），用例 644 → 694（+50）**

| 文件 | 轮前 | 轮后 |
|---|---|---|
| `settings_screen.dart` | 47/183 = 25.7% | **182/183 = 99.45%** |
| `task_list_screen.dart` | 19/103 = 18.4% | **100/103 = 97.09%** |

⚠️ 分母 7411 → **7412**（BUG-066 的修复多一行）；覆盖率分母是**代码行**，"修缺陷"会同时抬高分母。

**门禁（实测，一次过，未放宽任何阈值）**

| analyze | 功能层 | 压测层 | RC |
|---|---|---|---|
| No issues (17.8s) | **694/694** ✅ | **24/24** ✅ | **0** |

**Docs / Skills**

- `docs/17 §48`、`docs/12 §48`
- 技能 **`flutter-widget-test-harness` 由「四类」扩到「六类」假故障**：
  - **推翻上一轮的推论**：`databaseFactoryFfi` 把 SQLite 放**后台 isolate**，
    用例体里**查/写库同样挂死**（不只是"开库"）。实测首个文件 **10m21s**
    （1 例挂死 + 18 例级联失败，报的却是 `Guarded function conflict` —— 指不到真因），
    全包 `tester.runAsync` + `timeout: 90s` 后 **37s**。
  - **⑤ 固定轮数 drain 等异步重读 → 时红时绿**（`invalidate()` 后 `AsyncValue` 先带旧值）
    → `waitFor(cond)` 有界轮询 + **超时显式 `fail`**（静默放行会让负向断言恒真）。
  - **⑥ 按 widget 下标取值 → 顺序未定义**（`priority DESC, created_at DESC` 平局）
    → 按 `find.ancestor/descendant` **关系**定位。
  - 新增附录「给会调插件的页面打桩三条路」；速查表扩到 9 行。
  - 两条实测教训：`path_provider` 打到通道上的方法名是 **`getTemporaryDirectory`**
    （不是 `getTemporaryPath`）；`writeAsString` 异步，文件**先创建后写满**，
    等"文件存在"会读到**空文件**。

**下一轮**：① B 组 Top 继续（`task_editor_screen` 211 / `multi_video_screen` 108 /
`script_builder_screen` 100 / `sound_library_screen` 93 / `call_incoming_overlay` 91 /
`log_screen` 67 / `stats_screen` 64）；② A 组逐行取证；③ 覆盖率 ratchet 进门禁
（`COVERAGE_MIN`）；④ **BUG-065/066 补一条设备层端到端**（`WITH_DEVICE=1`）。

### 第二十四轮（2026-09-21）：`task_editor_screen` —— 覆盖率 58.35% → 61.18%，并抓到 **BUG-067**（"既崩又静默"）

**Fixed（缺陷修复）**

- **BUG-067（P2，debug 崩 + release 静默）**：任务编辑器里「声景混音」**一条轨道都没加**
  就点保存 → `SoundscapeAction` 的构造期 `assert(tracks.length >= 1)` 抛出；
  「随机指令集」候选不足 2 个同理（`ActionSetAction` 要求 2–12）。
  **两种失败形态同时成立**：
  - **debug 崩** —— `_save()` 是 `async`，断言被包成它的 **Future 错误**、无人 await
    → 走 zone 的 `onError` → 红屏；
  - **release 静默** —— assert 被剥离 → **真的存下一个 0 轨声景**，到点什么都不播，
    用户只会以为"任务没生效"。

  ⚠️ 同一个 `_buildTask` 里的「每周定时」**有**前置校验 + 提示
  （`请至少选择一个星期`）→ 说明这是**漏了**，不是设计如此。
  修复：构造**之前**校验 + 可读提示
  （`声景混音至少需要 1 条轨道` / `随机指令集至少需要 2 个候选动作`）。
  **刻意不给 `_save()` 套 `try/catch`** —— 那会把"崩"变成"静默失败"，
  还会掩盖以后新增的真缺陷。

**Tested（`test/task_editor_deep_test.dart` 重写，38 例 TEI-A..F）**

- **回填**（`_applyTask` 每个分支）：按 id 读库 / 6 种触发 / 声景 / 三种单动作 /
  组合 / 指令集含"不可编辑"子动作（明示保留）/ **条件层六字段（含显式 false）**
- **交互**（本轮缺口的主体）：声景轨道增删与滑条、条件区三个开关 + 概率门 +
  两个下拉、触发区时刻/星期/日期范围/窗口时刻/两处步进器、
  动作区两条 RangeSlider + 两个开关 + TTS 文本 + 录音时长 + 候选权重
- **保存**（`_buildTask` 每个分支）：本机落库 + pop / 远程失败提示且**不关页** /
  校验拦截 / **6 种触发产物** / **7 种动作产物** / 关掉安全默认必须落显式 false /
  BUG-067 两条复发锁

⚠️ 重写文件时删掉了原有 3 条用例，其中"条件回填"的覆盖被漏掉 ——
是**覆盖率数字**发现的（185–191 行仍红），不是人眼发现的。已补回。
**教训：重写测试文件后必须重新量覆盖率。**

**覆盖率：58.35% → 61.18%（4537/7416，+212 行 / +2.83pt），用例 694 → 729（+35）**

| 文件 | 轮前 | 轮后 |
|---|---|---|
| `task_editor_screen.dart` | 211/591 = 64.30% | **3/595 = 99.50%** |

⚠️ 分母 7412 → 7416（BUG-067 修复多 4 行）。

**逐行取证：剩余 3 行结构不可达（= 本文件可覆盖上限）**

835 / 844（`_setIcon` / `_setLabel` 的 `RcStepKind.delay`）与 972
（`_buildTask` 候选 switch 的 `delay`）：`_setCandidates` 只有两个来源 ——
`stepKindOfAction(...)`（play/tts/notify/vibrate/record 或 **null**）与
「＋候选」chips（同五种）—— **都不可能是 `delay`**。
⇒ 上限 **592/595 = 99.50%**，已打满。

⚠️ **登记一个未爆的雷（不修）**：972 行把 `delay` 映射成 `RecordEvidenceAction`
是一处**猜**（BUG-058 同形）。现在不可达所以无害；若以后给编辑器加"时延"候选，
保存会**静默产出录音取证**。**不擅自改不可达代码**（改了也无法用测试锁住）。

**门禁（实测，一次过）**

| analyze | 功能层 | 压测层 | RC |
|---|---|---|---|
| No issues (13.3s) | **729/729** ✅ | **24/24** ✅ | **0** |

⚠️ 跑门禁时整机负载 **94%**，压测层**仍然全绿** —— 说明 60% 的 `LOAD_SUSPECT`
阈值是**保守**的（只在真破线时才升级成 `[BLOCKED]`）。**未放宽任何阈值。**

**Docs / Skills**

- `docs/17 §49`、`docs/12 §49`
- 技能 **`flutter-widget-test-harness` 由「六类」扩到「七类」**，新增：
  - **陷阱 7**：**异步回调里抛的异常 `takeException()` 看不到** ——
    `onPressed: _save` 的 Future 无人 await → 抛出被包成 Future 错误 →
    走 zone 的 `onError`、**绕过 `FlutterError.onError`** → 判据必须落在
    "用户能看到什么"（提示文案 / 未落库），不能落在 `takeException()`；
  - 新增附录「驱动 Material 大对话框」：`TimeOfDay.format` 走 `MaterialLocalizations`
    （**别硬编码文案，问框架要**）、全屏选择器要**单独调小视口** + `ensureVisible`、
    拨盘改用 `Icons.keyboard_outlined` 的输入模式、**必须让值真的变**
    （只断言"对话框关了"的话，`onChanged` 没接上也能绿）；
  - 另外三条：`pumpWidget` 重入**不重置路由栈**、带集合长度断言的构造函数
    **不能 `const`**、**同一标签可能是两处代码**（别点一个就收工）。

**下一轮**：① B 组 Top 继续（`multi_video_screen` 108 / `script_builder_screen` 100 /
`sound_library_screen` 93 / `call_incoming_overlay` 91 / `log_screen` 67 /
`stats_screen` 64）；② A 组逐行取证；③ 覆盖率 ratchet 进门禁（`COVERAGE_MIN`）；
④ **BUG-065/066/067 补设备层端到端**（`WITH_DEVICE=1`）。

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
