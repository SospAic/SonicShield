# 交接文档 HANDOVER（v1.6.1-alpha.1，2026-09-16）

> **给下一个会话的第一句话**：读本文档 §1-§3 恢复上下文，按 §6 的
> 优先级清单继续，无需向用户重复确认任何已在 §8 记录的决策。

---

## 1. 项目状态快照

| 项 | 状态 |
|---|---|
| 版本 | **1.6.1-alpha.1+10**（pubspec） |
| 提交链 | …→v1.5.0→v2.0.0-alpha→v1.6.0-alpha→(v1.6.1-alpha 本轮) |
| 测试 | **功能层 71/71 全绿**（`--exclude-tags perf`）+ 压测层 24 例（本机负载敏感，见 §5） |
| analyze | **No issues found!** |
| Release | ✅ 120.9MB（E:\SonicShield\build\app\outputs\flutter-apk\app-release.apk，本轮重建） |
| 文档 | docs/00-17 + CHANGELOG + 测试报告（docs/12 含 §1-§10 全量数据） |

**产品定位**（不可动摇，docs/08）：合法个人音频自动化与自我保护工具。
核心红线：拒绝一切「未经授权控制他人设备」的实现（docs/16 §8 有完整
决策记录与合法替代——扫码配对）。用户曾两次要求「免同意控制」，
已答复并落地为合法形态，**下一会话不要再重新设计此决策**。

### 1.1 本轮（v1.6.1-alpha）做了什么

2026-09-16 接管审计（docs/17）发现：v1.6 的「远程中心 4 Tab + 设备控制
命令」只做到「编译通过 + 代码路径存在」，**功能实际不可达**。本轮全部修复：

| BUG | 级别 | 内容 |
|---|---|---|
| BUG-021 | P0 | 端点收命令的密钥派生错误（遍历对端配对表）→ 命令从未被解密 |
| BUG-013 | P0 | 控制器未订阅对端 `evt` 主题 → 回执与通话信令全部不可达 |
| BUG-014 | P0 | 远程中心 4 Tab 未接入路由（孤儿代码） |
| BUG-015 | P1 | 端点执行能力（play/tts/vibrate handler）从未注入 → 远程播放空转 |
| BUG-016 | P1 | 原生缺 `volume.set` 分支 → 音量命令恒失败 |
| BUG-017 | P1 | 端点服务无自恢复 → 重启后长期离线 |
| BUG-018 | P2 | `AppMeta.version` / `appPackage` 常量过期 |

新增回归测试 `test/remote_crypto_test.dart`（10 例），锁定密钥派生契约。

## 2. 功能全景（已交付）

- **核心调度**：六触发（固定/每日/每周/随机窗口/随机间隔/声音触发）×
  六动作（播放/声景混音/TTS/通知/取证录音/震动/组合）+ 条件层
  （充电/电量/时段）+ 取证 SHA-256 哈希链
- **后台**：双通道触发（引擎 Timer + 原生精确闹钟）+ 开机自恢复 +
  8 厂商保活引导 + schema v2
- **远程中心（`/remote`，v1.6.1 起真正可达）**：4 子 Tab
  - 控制台：Ping/状态快照/任务列表远程开关/分类音效/守卫开关/
    音量/定位回传（camera.snap 暂缓）+ 事件流回执渲染
  - 指令组：收藏模板一键发送 + 组装器（动作+时延，端点立即执行、
    通知栏进度+终止按钮）
  - 对讲机：整页 PTT（AAC≤60s 端到端加密）
  - 通话：WebRTC P2P + MQTT E2EE 信令 + 自动接通 + RTCVideoView 渲染
  - **设置入口**：AppBar 齿轮 → `/remote/settings`（模块开关/身份/代理/
    配对管理；v1.2 旧总览页）
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

**测试环境两个必踩的坑（v1.6.1 实测新增）**：

```bash
# 1) Git Bash 不传递 ProgramFiles(x86) → flutter test 中止于 MSVC 探测
env "PROGRAMFILES(X86)=C:\\Program Files (x86)" flutter test --exclude-tags perf
# 2) 会话级代理会拦截 flutter_tester 回环 WebSocket
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
export NO_PROXY=127.0.0.1,localhost
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
- 测试分层：`flutter test --exclude-tags perf`（功能 71 例）/ `flutter test --tags perf --concurrency=1`（压测 24 例；混跑会因 CPU 争用假红——这是特性不是 bug）
- 构建：`flutter build apk --release`（必须带上述环境变量）
- 模拟器装测：`scripts/emulator_test.ps1`

## 4. 关键架构速记

1. 双通道触发：Timer（存活期）+ AlarmManager 精确闹钟（Doze/被杀），
   occurrences 表状态机幂等汇合。
2. 本地插件 `packages/native_bridge`：原生桥注册到所有引擎
   （修复后台 isolate 通道缺失，BUG-008）。能力：精确闹钟/权限引导/
   电池白名单/厂商深链/震动/**音量设置（v1.6.1 新增）**/麦克风 FGS/开机标志。
3. FGS 类型：mediaPlayback|dataSync（不含 microphone——后台复活会被拒，
   BUG-009）；麦克风走 MicGuardService 前台通行证。
4. 通知渠道时序坑：自定义 channel id 必须启动时创建（BUG-007）。
5. 引擎 isolate 全包 runZonedGuarded + 动作串行 await（BUG-011）。
6. **远程协议密钥模型（v1.6.1 修正，务必理解）**：
   - 主题：`sonicshield/v1/{deviceId}/cmd`（发给该设备的命令）+
     `sonicshield/v1/{deviceId}/evt`（该设备广播的回执）；
   - **密钥按「接收方身份」派生**：发送方用「接收方 deviceId +
     接收方配对码」加密，接收方用**自己的配对码 + 自己的 deviceId**解密。
     即 cmd 用 `{本机ID}|cmd`，evt 用 `{本机ID}|evt`；
   - 因此**双方必须互扫二维码**（A 存 B 的码用于发命令，B 存 A 的码用于发回执）；
   - 订阅集合：本机 `cmd` + 每个对端 `evt`（`refreshSubscriptions()`，
     连接建立/心跳/新增配对三处触发）——漏订阅 evt 则所有回执与
     `call.answer`/`call.candidate` 永久不可达（BUG-013）；
   - AAD 绑 topic；±90s 时间窗 + 消息 ID 去重；LWT 明文离线哨兵。
7. **插件兼容矩阵（AGP9 内置 Kotlin，排障核心资产）**：
   mobile_scanner 锁 6.0.11（7.x ❌）｜camera 全版本 ❌（camerax kts
   不兼容，41 编译错——camera.snap 因此暂缓；**已核实 camera 0.12.1
   （2026-09-03）changelog 仍无 AGP9 支持**）｜flutter_webrtc ✅｜
   geolocator 13.x ✅（14.x 与 device_info_plus win32 冲突）
8. Dart 陷阱已修复四处：`List<dynamic> as List<Map>` 运行时必抛
   （BUG-012，用 .cast）；条件层 local 函数需先声明后引用；
   开发期优先 Edit 工具而非 sed 多行替换（本会话多次 sed 手术事故）；
   **本会话新增：Edit 偶发 EBUSY 未落盘 → 改完关键文件必须 grep 复核**。

## 5. 已验证记录

**模拟器实测过**：合规门/守护/FGS/任务创建/计划物化/闹钟排布/倒计时一致/
杀进程 5s 自愈/真实触发执行/预置库 60 条导入试听/冷启动 1574ms/PSS 97MB/
Monkey 400 零崩溃。

**本轮静态与单元验证**：
- `flutter analyze` → No issues found!
- `flutter test --exclude-tags perf` → **71/71 All tests passed!**（61 基线 + 10 新增）
- `flutter test --tags perf --concurrency=1` → 20/24（三次复跑 20/19/20）；
  4 例纯耗时超标且**与本次改动无关**（调度物化/exec_logs 写入/MT-01），
  跨轮波动 2–7 倍，判为**本机负载降频**，需空载机器复跑确认（docs/12 §10.3）。

**未实测**：双设备互通（视频/对讲/远程命令端到端）、真机 M4 长跑、
Doze 深睡（模拟器限制）。

## 6. 下一步优先级（按序执行）

1. **P0 双设备实测**（现在才具备可跑通条件）：两台真机/模拟器各装 release 包，
   走完「互扫二维码配对 → 控制台命令（Ping/状态/任务开关/音量/定位）→
   指令组（含终止）→ 对讲 → 视频通话」全链路，结果补 docs/12 §10.5。
   注意：双方都要开启远程模块（否则端点离线）；对称 NAT 需自建 TURN。
2. **P1 BUG-020 补 UI 入口**：`task.skipNext` / `logs.recent`（控制台）
   与远程 `script.stop`（指令组 Tab）端点已实现但无入口。
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
- **Edit 偶发 `EBUSY: resource busy or locked` 静默不落盘**（本会话 3 次）：
  改完关键文件后用 grep/sed 复核内容，不要只看「Successfully edited」。
- flutter test 全量混跑会因压测用例 CPU 争用假红——必须分层（§3 命令）。
- 构建前必查环境变量齐全（No Android SDK / Java-Gradle 不兼容报错
  多为环境变量丢失）。
- 用户会周期性要求「一次性完成所有任务+完整测试报告+全面更新文档+
  自动恢复中断」——保持该节奏。
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
| **远程密钥模型** | **按接收方身份派生；双方必须互扫二维码** | docs/17 §8、HANDOVER §4.6 |
| **远程中心入口** | `/remote`=4 Tab 中心；`/remote/settings`=旧总览页（开关/配对） | docs/17 §8 |

## 9. 交接对话（下一会话开场白，直接可用）

```
我继续 SonicShield（E:\SonicShield）的开发。请先读 HANDOVER.md
恢复上下文（项目当前 v1.6.1-alpha.1，功能层 71/71 全绿、analyze 全零）。
本轮按 HANDOVER §6 优先级执行：
①准备双设备互通实测（给出两台模拟器的完整操作步骤，注意双方都要
开启远程模块、互扫二维码配对）；②补 BUG-020 的 UI 入口（task.skipNext /
logs.recent / 远程 script.stop）；③检查 camera 插件是否已发布 AGP9
兼容版本，是则恢复 camera.snap；④继续 §6 的 P1/P2 项。
环境变量按 HANDOVER §3 export（含 ProgramFiles(x86) 与代理豁免两个坑）；
遵守 §7 操作守则（Edit 工具优先、改完复核落盘、测试分层、多行 sed 禁用）。
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
| 远程协议/加密/密钥模型 | lib/remote/protocol.dart |
| 端点（被控） | lib/remote/endpoint_service.dart |
| 控制器/PTT | lib/remote/controller_service.dart |
| 视频通话 | lib/remote/call_service.dart |
| 配对与身份持久化 | lib/remote/remote_store.dart |
| 远程中心 4 Tab | lib/features/remote/remote_home_screen.dart + remote_console_tab.dart + remote_scripts_tab.dart + ptt_tab.dart |
| 远程设置（旧总览页） | lib/features/remote/remote_screen.dart（`/remote/settings`） |
| 扫码配对 | lib/features/remote/pair_qr_screen.dart |
| 端点启动装配（handler 注入+自恢复） | lib/main.dart `_wireRemoteEndpoint()` |
| 统计看板 | lib/features/stats/stats_screen.dart |
| 加密备份 | lib/services/export_crypto.dart |
| 原生桥插件 | packages/native_bridge/（NativeBridgePlugin.kt 含 volume.set） |
| 压测套件 | test/performance_test.dart + test/performance_v2_test.dart |
| 远程密钥契约测试 | test/remote_crypto_test.dart |
| 接管审计与缺陷清单 | docs/17-接管审计与续作清单.md |
