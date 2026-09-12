# 更新日志

本项目的所有重要变更都记录在此文件中。
格式参考 Keep a Changelog，版本遵循语义化版本。

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
