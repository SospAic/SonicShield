# 交接文档 HANDOVER（v1.6.0-alpha，2026-09-16）

> **给下一个会话的第一句话**：读本文档 §1-§3 恢复上下文，按 §6 的
> 优先级清单继续，无需向用户重复确认任何已在 §8 记录的决策。

---

## 1. 项目状态快照

| 项 | 状态 |
|---|---|
| 版本 | **1.6.0-alpha.1+9**（pubspec） |
| 提交链 | v1.0.0→v1.0.1→v1.1.0→v1.2.0→v1.3.0→v1.4.0→v1.5.0→v2.0.0-alpha→(v1.6.0-alpha 本轮待提交) |
| 测试 | **85/85 全绿**：61 功能（`--exclude-tags perf`）+ 24 压测（`--tags perf --concurrency=1`） |
| analyze | **No issues found!** |
| Release | ✅ 120.5MB（E:\SonicShield\build\app\outputs\flutter-apk\app-release.apk） |
| 文档 | docs/00-16 + CHANGELOG + 测试报告（docs/12 含 §1-§9 全量数据） |

**产品定位**（不可动摇，docs/08）：合法个人音频自动化与自我保护工具。
核心红线：拒绝一切「未经授权控制他人设备」的实现（docs/16 §8 有完整
决策记录与合法替代——扫码配对）。用户曾两次要求「免同意控制」，
已答复并落地为合法形态，**下一会话不要再重新设计此决策**。

## 2. 功能全景（已交付）

- **核心调度**：六触发（固定/每日/每周/随机窗口/随机间隔/声音触发）×
  六动作（播放/声景混音/TTS/通知/取证录音/震动/组合）+ 条件层
  （充电/电量/时段）+ 取证 SHA-256 哈希链
- **后台**：双通道触发（引擎 Timer + 原生精确闹钟）+ 开机自恢复 +
  8 厂商保活引导 + schema v2
- **远程中心（v1.6 重构，`/remote`）**：4 子 Tab
  - 控制台：Ping/状态快照/任务列表远程开关/分类音效/守卫开关/
    音量/定位回传（camera.snap 暂缓）+ 事件流回执渲染
  - 指令组：收藏模板一键发送 + 组装器（动作+时延，端点立即执行、
    通知栏进度+终止按钮）
  - 对讲机：整页 PTT（AAC≤60s 端到端加密）
  - 通话：WebRTC P2P + MQTT E2EE 信令 + 自动接通 + RTCVideoView 渲染
- **配对**：扫码配对（`/remote/pair-qr`）+ 手输备用
- **数据**：统计看板（7 天趋势/分布/占比）+ 加密备份（PBKDF2 12 万次+
  AES-256-GCM）+ 任务导出导入 + 审计日志 + 60 条合成音效库

## 3. 环境地图（每次新 shell 必须 export）

```bash
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
export JAVA_HOME="E:\\dev\\jdk\\jdk-21.0.2"
export ANDROID_HOME="E:\\dev\\android-sdk"
export PATH="/e/dev/flutter/bin:/e/dev/android-sdk/platform-tools:$PATH"
export MSYS_NO_PATHCONV=1   # adb shell 内 /sdcard 路径防 Git Bash 转换
```

| 组件 | 位置 |
|---|---|
| Flutter 3.47.3 | E:\dev\flutter |
| JDK 21 | E:\dev\jdk\jdk-21.0.2 |
| Android SDK（36/NDK/CMake） | E:\dev\android-sdk |
| Gradle 9.3.1 缓存 | %USERPROFILE%\.gradle\wrapper\dists\...9ot9...（wrapper 已指向 file:///E:/dev/gradle-dist/） |
| 全局镜像 init | %USERPROFILE%\.gradle\init.d\mirror.gradle |
| AVD sonic_test | headless 启动：`emulator -avd sonic_test -no-window -no-audio -gpu swiftshader_indirect -cores 2` |

**关键命令**：
- 测试分层：`flutter test --exclude-tags perf`（功能）/ `flutter test --tags perf --concurrency=1`（压测；混跑会因 CPU 争用假红——这是特性不是 bug）
- 构建：`flutter build apk --release`（必须带上述环境变量）
- 模拟器装测：`scripts/emulator_test.ps1`

## 4. 关键架构速记

1. 双通道触发：Timer（存活期）+ AlarmManager 精确闹钟（Doze/被杀），
   occurrences 表状态机幂等汇合。
2. 本地插件 `packages/native_bridge`：原生桥注册到所有引擎
   （修复后台 isolate 通道缺失，BUG-008）。
3. FGS 类型：mediaPlayback|dataSync（不含 microphone——后台复活会被拒，
   BUG-009）；麦克风走 MicGuardService 前台通行证。
4. 通知渠道时序坑：自定义 channel id 必须启动时创建（BUG-007）。
5. 引擎 isolate 全包 runZonedGuarded + 动作串行 await（BUG-011）。
6. 远程协议：MQTT（默认 broker.emqx.io:1883）+ 配对码→HKDF→
   AES-256-GCM；AAD 绑 topic；±90s 时间窗+去重。
7. **插件兼容矩阵（AGP9 内置 Kotlin，排障核心资产）**：
   mobile_scanner 锁 6.0.11（7.x ❌）｜camera 全版本 ❌（camerax kts
   不兼容，41 编译错——camera.snap 因此暂缓）｜flutter_webrtc ✅｜
   geolocator 13.x ✅（14.x 与 device_info_plus win32 冲突）
8. Dart 陷阱已修复三处：`List<dynamic> as List<Map>` 运行时必抛
   （BUG-012，用 .cast）；条件层 local 函数需先声明后引用；
   开发期优先 Edit 工具而非 sed 多行替换（本会话多次 sed 手术事故）。

## 5. 已验证记录（模拟器实测过的）

合规门/守护/FGS/任务创建/计划物化/闹钟排布/倒计时一致/杀进程 5s 自愈/
真实触发执行（schedule·play 三次 TTS 超时审计）/预置库 60 条导入试听/
冷启动 1574ms/PSS 97MB/Monkey 400 零崩溃。**未实测**：双设备互通
（视频/对讲/远程命令端到端）、真机 M4 长跑、Doze 深睡（模拟器限制）。

## 6. 下一步优先级（按序执行）

1. **P0 git 提交**：本轮 v1.6.0-alpha 全部变更（提交信息模板：
   `feat: v1.6.0-alpha —— 远程中心 4 Tab 重构 + 设备完全控制命令`，
   正文列控制台/指令组/对讲/通话 + 4 条设备命令 + camera 暂缓说明 +
   85/85 + analyze 零 + 120.5MB）。
2. **P0 双设备实测**：两台真机/模拟器各装 release 包，走完
   扫码配对→控制台命令→指令组→对讲→视频通话全链路，结果补 docs/12。
3. **P1 camera.snap 启用**：等 camera 插件发布 AGP9 兼容版（关注
   pub.dev changelog），恢复 `endpoint_service._snapPhoto`（git 历史
   提交里有完整实现可考）+ 恢复依赖 + 启用 docs/16 §9 表格项。
4. **P1 YAMNet**：模型源当前不可达（tfhub/kaggle 403/404）；接口就绪，
   用户放入 yamnet.tflite 即启用（docs/06 §6）。
5. **P2** Opus 流式对讲、锁屏 PTT 小组件、TURN 配置、Drift 迁移、en 国际化。
6. 持续：真机矩阵 M4（docs/09 §5 LT-01..05）。

## 7. 会话操作守则（血泪教训）

- 修改多行代码用 Edit 工具；sed 多行替换在本仓库已引发 5+ 次文件损坏
  （修复法：git checkout <file> 重做）。
- flutter test 全量混跑会因压测用例 CPU 争用假红——必须分层（§3 命令）。
- 构建前必查环境变量齐全（No Android SDK / Java-Gradle 不兼容报错
  多为环境变量丢失）。
- 用户会周期性要求「一次性完成所有任务+完整测试报告+全面更新文档+
  自动恢复中断」——本轮已按此模式交付，保持该节奏。
- 用户需求若触碰 §1 红线（免同意控制/隐蔽监控），按 docs/16 §8 答复
  并转向合法替代，不要反复。

## 8. 重要决策档案（不要重新讨论）

| 决策 | 结论 | 位置 |
|---|---|---|
| 免同意远程控制他人设备 | 拒绝；合法替代=扫码配对+已配对自动信任 | docs/16 §8、docs/14 §7.5 |
| 视频通话选型 | 方案 A（WebRTC+MQTT 信令），否决 SaaS/SFU | docs/16 §1 |
| 自动接通 | 仅家人守护、默认关、无隐蔽模式 | docs/16 §6 |
| camera 插件 | 全版本不兼容 AGP9，snap 暂缓（协议保留） | docs/16 §9 |
| mobile_scanner | 锁 6.0.11 | pubspec 注释 |
| 压测分层运行 | --tags perf 隔离，避免 CPU 争用假红 | test tags |

## 9. 交接对话（下一会话开场白，直接可用）

```
我继续 SonicShield（E:\SonicShield）的开发。请先读 HANDOVER.md
恢复上下文（项目当前 v1.6.0-alpha，85/85 测试全绿、analyze 全零、
release 120.5MB 已构建）。本轮按 HANDOVER §6 优先级执行：
①先 git 提交当前全部变更（信息模板见 §6.1）；②准备双设备互通实测
（给出两台模拟器的完整操作步骤）；③检查 camera 插件是否已发布
AGP9 兼容版本，是则恢复 camera.snap（实现在 git 历史里）；
④继续 §6 的 P1/P2 项。环境变量按 HANDOVER §3 export；遵守 §7
操作守则（Edit 工具优先、测试分层、多行 sed 禁用）。
完成后更新 docs/12 测试报告与 CHANGELOG 并提交。遇到中断自动恢复，
保持「一次性完成+测试报告+文档同步」的交付节奏。
```

## 10. 代码地图（新会话快速定位）

| 模块 | 文件 |
|---|---|
| 调度引擎 | lib/domain/scheduling/schedule_engine.dart |
| 条件层 | lib/domain/models/condition.dart |
| 声景/动作模型 | lib/domain/models/action.dart |
| 后台引擎 | lib/services/background_engine.dart |
| 播放/混音 | lib/services/playback_service.dart |
| 远程协议/加密 | lib/remote/protocol.dart |
| 端点（被控） | lib/remote/endpoint_service.dart |
| 控制器/PTT | lib/remote/controller_service.dart |
| 视频通话 | lib/remote/call_service.dart |
| 远程中心 4 Tab | lib/features/remote/remote_home_screen.dart + remote_console_tab.dart + remote_scripts_tab.dart + ptt_tab.dart |
| 扫码配对 | lib/features/remote/pair_qr_screen.dart |
| 统计看板 | lib/features/stats/stats_screen.dart |
| 加密备份 | lib/services/export_crypto.dart |
| 原生桥插件 | packages/native_bridge/ |
| 压测套件 | test/performance_test.dart + test/performance_v2_test.dart |
