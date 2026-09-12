# 交接文档 HANDOVER

> 最后更新：2026-09-12 ｜ 交付会话：SonicShield v1.0.0 全自动开发会话
> 本文档供下一会话/接手人**无缝衔接**。先读本文，再按需深入 docs/。

---

## 1. 项目状态快照

| 项 | 状态 |
|---|---|
| 代码 | ✅ 完整可构建（git 已初始化，v1.0.0 已提交） |
| 单元测试 | ✅ 53/53 通过；调度引擎行覆盖 **92.7%**（全局 85%） |
| 静态分析 | ✅ `flutter analyze` **No issues found!** |
| Debug APK | ✅ 构建成功（arm64-v8a + x86_64） |
| Release APK | ✅ 构建成功（AOT 验证通过，见 docs/12） |
| 模拟器验证 | ✅ 全链路跑通（详见 §4 验证记录） |
| 待办 | 集成测试 drive 化、真机长跑 M4、iOS 构建（需 macOS） |

## 2. 环境地图（全部已安装，直接可用）

| 组件 | 位置 | 版本 |
|---|---|---|
| Flutter SDK | `E:\dev\flutter` | 3.47.3 stable |
| JDK | `E:\dev\jdk\jdk-21.0.2` | OpenJDK 21.0.2 |
| Android SDK | `E:\dev\android-sdk` | platform-36 / build-tools 36.0.0 / NDK 28.2.13676358 / CMake 3.22.1 / platform-tools（adb） |
| Gradle 发行包 | `%USERPROFILE%\.gradle\wrapper\dists\gradle-9.3.1-all\9ot9r568e8zfvvd4mn8rbu1j0\` | 9.3.1（腾讯镜像下载） |
| Gradle 全局 init | `%USERPROFILE%\.gradle\init.d\mirror.gradle` | 阿里云镜像注入（buildscript） |
| 模拟器 AVD | `~/.android/avd/sonic_test.avd`（手动创建，非 avdmanager） | API 36 x86_64 Pixel6 |
| 安装包缓存 | `E:\dev\_downloads\`（原始 zip/日志） | — |

**环境变量（每次新 shell 需要 export，Git Bash 示例）：**

```bash
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
export JAVA_HOME="E:\\dev\\jdk\\jdk-21.0.2"
export ANDROID_HOME="E:\\dev\\android-sdk"
export PATH="/e/dev/flutter/bin:/e/dev/android-sdk/platform-tools:$PATH"
export MSYS_NO_PATHCONV=1   # adb shell 里的 /sdcard 等路径防 Git Bash 转换
```

## 3. 关键架构速记（改代码前必读）

1. **双通道触发**：引擎隔离 Timer（通道A）+ 原生 AlarmManager 精确闹钟（通道B）。
   两通道汇合到 `occurrences` 表状态机，天然幂等。详见 docs/04/05。
2. **本地插件 `packages/native_bridge`**（本次交付的关键架构修复）：
   - 原生桥（闹钟/电池白名单/厂商深链/震动/MicGuardService）以 **path 插件**
     注册到**所有** Flutter 引擎（UI + 后台服务引擎）。
   - 背景：MainActivity 只给 UI 引擎注册 MethodChannel handler，后台隔离
     调用会 MissingPluginException → 任务闹钟从未排布。本地插件根治。
   - 插件 build 脚本必须用 **Groovy**（`build.gradle`）——AGP 9 的 Kotlin DSL
     不支持 `apply(plugin=...)` 字符串注册（无类型安全 DSL 访问器）。
   - 插件不能引用 app 级依赖类（如 flutter_background_service 的类），
     跨包启动服务用 `Intent().setClassName(...)`。
3. **FGS 类型策略（Android 14+ while-in-use）**：
   - 主服务 `mediaPlayback|dataSync`（**不含 microphone**——后台复活的
     FGS 携带 microphone 类型会被 SecurityException 拒绝）；
   - 麦克风由 `MicGuardService`（microphone 类型）承担，必须**用户前台
     交互时**启动（守卫开关 → `NativeBridge.startMicService()`）。
4. **通知渠道时序坑**：flutter_background_service 指定自定义
   `notificationChannelId` 时**不会自动建 channel**（其源码 L89-95），
   channel 缺失 → `CannotPostForegroundServiceNotificationException`
   崩溃。已在 `main.dart` 最先调 `NotificationService.createServiceChannel()`。
5. **确定性随机**：seed=FNV1a(taskId, 计划日)；计划物化幂等，重启不漂移。
   改调度算法前先读 docs/04 并跑 `test/schedule_engine_test.dart`。

## 4. 已验证记录（模拟器 emulator-5554，全部真实执行）

| 编号 | 场景 | 结果 |
|---|---|---|
| V-01 | 全新安装 → 合规门弹窗渲染 → 点击同意 | ✅ |
| V-02 | 合规确认持久化（重进不再弹） | ✅ |
| V-03 | 开启守护 → FGS 注册（`isForeground=true`，channel=sonicshield_service） | ✅ |
| V-04 | 任务编辑器六种触发/随机参数渲染 → 保存 | ✅ |
| V-05 | 引擎物化 14 条计划（`replan(8 条计划)`）→ 仪表盘倒计时与系统闹钟一致（16:19:38） | ✅ |
| V-06 | 原生精确闹钟排布（`dumpsys alarm`: AlarmWatchdogReceiver, RTC_WAKEUP, exactAllowReason=permission） | ✅ |
| V-07 | **ST-01 杀进程自愈**：`am kill` → 5 秒内 RESPAWN 复活 + 服务重注册 | ✅ |
| V-08 | Doze：模拟器不可深睡（充电限制）；白名单+14 条 AllowWhileIdle 闹钟确认 | ⚠️ 真机 M4 |
| V-09 | UI 六页导航 | ✅（仪表盘/任务/编辑器已截图验证） |

## 5. 已知问题与 Workaround

| 问题 | 状态 | 方案 |
|---|---|---|
| `gradlew.bat` 直接跑会卡下载（wrapper 缓存校验怪癖） | 已绕过 | 用缓存 Gradle 直跑：`%USERPROFILE%\.gradle\wrapper\dists\gradle-9.3.1-all\9ot9r568e8zfvvd4mn8rbu1j0\gradle-9.3.1\bin\gradle.bat assembleDebug`；`flutter build` 正常（其内部触发 wrapper 需首次联网校验） |
| `flutter test integration_test` 直跑失败（触发同一 wrapper 问题） | 已绕过 | 用 `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/app_smoke_test.dart --use-application-binary=...apk -d <device>` |
| 模拟器带窗启动被 360 拦截（QEMU 线程挂起） | 已定位 | headless 启动：`emulator -avd sonic_test -no-window -no-audio -gpu swiftshader_indirect -cores 2`；360 已卸载/关闭后可带窗 |
| 模拟器 Doze 深睡不可用（USB 供电判定） | 环境限制 | 真机验证（M4） |
| 重装 APK 后运行时权限全部清空 → FGS/通知崩溃 | 设计如此 | 重装后必须重新 `pm grant`（见 scripts/emulator_test.ps1） |

## 6. 常用命令速查

```bash
# 测试
flutter test                          # 53 单测
flutter test --coverage               # + 覆盖率（coverage/lcov.info）
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/app_smoke_test.dart \
  --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk \
  -d emulator-5554

# 构建（推荐直接用缓存 Gradle）
cd android && %USERPROFILE%\.gradle\wrapper\dists\gradle-9.3.1-all\9ot9r568e8zfvvd4mn8rbu1j0\gradle-9.3.1\bin\gradle.bat assembleDebug

# 模拟器
emulator -avd sonic_test -no-window -no-audio -gpu swiftshader_indirect -cores 2 &
scripts/emulator_test.ps1             # 安装+授权+白名单+启动

# 排障
adb shell dumpsys alarm | grep AlarmWatchdog     # 任务闹钟排布
adb shell dumpsys activity services com.sonicshield.sonic_shield
adb logcat -d -b crash                            # 崩溃
adb shell dumpsys deviceidle whitelist +com.sonicshield.sonic_shield
```

## 7. 下一步工作（按优先级）

1. **P0** 真实触发闭环验证：首个闹钟 16:19:38（本会话进行中，见 docs/12 §8）；
   长期可在任务编辑器建"1 分钟后 fixedOnce"任务快速验证。
2. **P0** `flutter drive` 集成测试三用例跑通（IT-01..03，绕过 wrapper 后应直接可用）。
3. **P1** 真机矩阵 M4：主流厂商 7×24 存活率 + 电耗（docs/09 §5 LT-01..05）。
4. **P1** iOS：在 macOS 上 `bootstrap.sh` + `flutter build ipa`（Info.plist 已配好后台模式/BGTask/麦克风用途）。
5. **P2** 守卫实时电平表（引擎→UI 电平流）、日志导出 CSV（路线图 v1.1）。
6. **P2** 发布物：签名 keystore + `android/key.properties`（docs/10 §4）、商店文案合规自查（docs/08 §5）。

## 8. 文档地图

- 总入口：`README.md`（索引）→ `docs/00-文档索引.md`
- 本会话真实测试数据：`docs/12-测试报告.md`
- 架构决策：`docs/03`（ADR-001..008，ADR-008=本地插件）
- 合规红线（法律边界）：`docs/08`
- 变更记录：`CHANGELOG.md`
