# SonicShield 全功能点测试 · 进度与阻塞报告

- 时间：2026-09-23 15:26
- 目标：有线真机 + 无线真机 + 模拟器 上跑 `integration_test/` 全部 8 个用例
- 本轮范围（用户拍板）：冒烟 + 关键用例，模拟器优先

---

## 一、已根治的环境级阻塞（本轮最大价值）

### 1. Gradle kotlin-dsl `NoSuchMethodError`（此前数小时无法构建的头号阻塞）
- **现象**：任何 Android 构建都失败：
  `NoSuchMethodError: 'void Settings_gradle.<init>(org.gradle.kotlin.dsl.support.KotlinScriptHost, org.gradle.api.initialization.Settings)'`
- **排除**：缓存污染、Java 版本（17/21 均失败）、代理/TUN、工程配置、`settings.gradle.kts` 内容、zip 完整性（CRC 通过）、jar 内容（**191 个 jar md5 与全新解压完全一致**）——全部无关。
- **确证手法**：路径矩阵 + junction 测试。**同一份物理文件**，经 `E:\dev\...` 访问 → 成功；经 `C:\Users\...\.gradle\wrapper\dists\...`（含指向 E: 的 junction）访问 → 必崩。
- **结论**：**Gradle 发行包必须位于 E: 盘**。C: 盘上的类加载被本机安全机制篡改。
- **修复**：`GRADLE_USER_HOME=E:\dev\ghproj`（发行包随之落在 E:）。

### 2. `transforms\*.lock (拒绝访问)`
- 沿用用户级 `~/.gradle/gradle.properties` 的既有结论：`org.gradle.parallel=false` + `org.gradle.workers.max=1`。已复制到 E: home。

### 3. 构建慢到卡死（jstack 定位）
- **现象**：`:app` 配置阶段挂住数十分钟，最终 `java.util.concurrent.TimeoutException`。
- **jstack 抓到的栈**：`WinNTFileSystem.createFileExclusively` / `RandomAccessFile.open0` → `DefaultFileLockManager$DefaultFileLock` → `LockOnDemandCrossProcessCacheAccess`。
- **含义**：**创建/打开锁文件的系统调用被拦截挂起**。
- **发现**：关闭 Agent 执行沙箱后构建速度立刻恢复正常（连续配置多个子工程）。此前 `reg.EXE` 被拦的原文即为 “The sandbox prevented a program on the configured Program Blacklist from starting”。
- **状态**：即使关沙箱，锁 I/O 仍会间歇挂起 → 疑似 360 安全软件 / Windows VBS(`Secure System`) 对文件 I/O 的拦截。

### 4. `flutter devices` 因 `reg.EXE` 被沙箱拉黑而失败
- Flutter 枚举设备时会 `reg query ...Edge\BLBeacon`。
- **绕过**：`flutter config --no-enable-web`（不再探测 Edge）。**已验证三台设备全部可枚举**。

---

## 二、设备状态（全部在线）

| 设备 | ID | 系统 | 用途 |
|---|---|---|---|
| 有线 MI MAX 2 | `dc14e06b` | Android 7.1.1 / API 25 | 向下兼容、降级链取证 |
| 无线 23116PN5BC | `192.168.2.11:35447` | Android 16 / API 36 | 最新系统 |
| 模拟器 CET AL00 | `emulator-5556` | Android 15 / API 35 | 主跑 |

- 无线真机本轮启动时**掉线**，已用 `adb connect 192.168.2.11:35447` 重连。
- 模拟器上存在**无关的门铃 App**（`com.eques.doorbell.nobrand`），会反复抢占前台，干扰截图取证。

---

## 三、已完成

1. 三台设备全部连接并可在 `flutter devices` 中枚举。
2. **预构建 APK 已成功安装并启动于模拟器**：`com.sonicshield.sonic_shield` 进程存活（pid 42539 / 310MB），`MainActivity` 正常创建，**无 crash**。
   - APK：`build/app/outputs/flutter-apk/app-debug.apk`（254MB，2026-09-22 22:40）
3. `flutter test integration_test/app_smoke_test.dart -d emulator-5556` 已启动，当前停在 `Running Gradle task 'assembleDebug'...`（构建慢/挂）。

---

## 四、当前阻塞（需处理才能出真实用例结果）

| # | 阻塞 | 影响 | 建议处置 |
|---|---|---|---|
| B1 | **★ 360 内核过滤驱动使 `mkdir` 慢 600ms~2.4s（已实测确证）** | 集成测试 APK 无法构建完成 | **你**：360 设置 → **自我保护**关闭 → **主动防御/木马防火墙**关闭 → 托盘退出；或把 `E:\dev`、`E:\SonicShield` 加入 360 **信任区** |
| B2 | 有线真机 `INSTALL_FAILED_USER_RESTRICTED` | MI MAX 2 装不上 | 开发者选项开启「USB 安装」/ 在设备上允许安装 |
| B3 | 模拟器被门铃 App 抢占前台 | 截图/UI 取证受干扰 | 卸载或冻结 `com.eques.doorbell.nobrand` |

---

## 五、已还原 / 待还原

- ✅ 已还原到 HEAD：`android/settings.gradle.kts`、`android/app/build.gradle.kts`（含被误删的 `kotlin{}` 块）、`android/gradle.properties`。
- ⏸ 临时产物**按用户要求保留现场**：`E:\dev\ghproj`、`E:\dev\gradle-fresh`、`E:\dev\gh*`、`E:\dev\gtest2`、`android/.gradle_trash_*`、`android/build_trash_*`。
- ⏸ `flutter config` 的 `enable-web=false` 待测试结束后恢复。
