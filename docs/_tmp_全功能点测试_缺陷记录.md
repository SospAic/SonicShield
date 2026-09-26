# 全功能点测试 · 缺陷记录（人工验收发现）

- 时间：2026-09-23 18:47
- 背景：构建链路打通后，用户在真机上人工验收，发现以下功能缺陷
- 关联：本轮集成测试 `app_smoke_test.dart` 在 **两台真机均 4/4 通过**（见 docs/_tmp_全功能点测试进度报告.md）
  ⇒ 这些缺陷**未被 app_smoke 覆盖**，属于人工验收增量发现

---

## BUG-A：Mi 14 Pro（23116PN5BC / Android 16 / API 36）后台守护引擎无法打开

- **现象**：打开 App → 「守护」页 → 点「启动后台引擎」开关，无法开启。
- **代码路径**：`lib/features/guard/guard_toggle.dart` → `toggleGuard(wanted: true)`：
  1. `if (!engineRunning) return GuardToggleFailure.engineNotRunning;`
  2. `requestMic()` → 失败则 `micDenied`
  3. `persist()` → `startMicService()` → `setGuard(true)`
  4. `waitForGuardActive(true)` → 超时则 `engineNoResponse`
- **可疑方向（待设备取证）**：
  - Android 14+ 前台服务（FGS）启动限制 + `FOREGROUND_SERVICE_TYPE_MICROPHONE` 权限；
  - 通知权限（`POST_NOTIFICATIONS`）未授予时 FGS 无法显示通知；
  - 厂商省电策略拦截（小米 HyperOS 后台限制）。
- **状态**：待复现取证

## BUG-B：MI MAX 2（dc14e06b / Android 7.1.1 / API 25）守护打开后无法关闭

- **现象**：守护开启后，再点开关无法关闭。
- **代码路径**：同一函数的 `else` 分支：`stopMicService()` → `setGuard(false)` → `waitForGuardActive(false)`
- **可疑方向（待设备取证）**：
  - `stopMicService()` 在 API 25 上未真正停止前台服务；
  - 引擎停止后未回投 `false` 状态 → `waitForGuardActive(false)` 超时 → `engineNoResponse`；
  - 与 BUG-A 方向相反 ⇒ 提示"启动"与"停止"两条路径的**状态回投**可能不对称。
- **状态**：待复现取证

## BUG-C：扫码配对后**未建立双向链接**（用户澄清：应建立双向链接并保存）

- **现象**：远程机器扫码配对后，未自动识别并保存到列表。
- **用户期望（澄清）**：**扫码后应建立双向链接并保存**。
- **根因（已确证为设计缺口，非单纯 UI 刷新）**：
  1. `lib/remote/protocol.dart` 的 `RcCmd` **完全没有 `pair.*` 类命令**（已逐条核对 ping/status/sound/task/guard/logs/script/ptt/call/device/camera/location/volume… 均无配对握手）
     ⇒ 配对**只有单向**：控制端 `addPaired` 保存了端点；**端点侧从不记录控制端**。
  2. 扫码路径 `lib/features/remote/pair_qr_screen.dart:77-90` 只做 `addPaired` + `refreshSubscriptions()`，**没有向对端回执自身身份**，也**没有通知远程页刷新**。
- **对比：手动填表配对** `lib/features/remote/remote_screen.dart:161-169` —— 同样只有单向 `addPaired`，但它多调了一次 `await _load()`，所以**列表能刷新**（因此该入口表现为"能保存"，掩盖了双向缺失）。
- **已排除**：`RemoteStore.addPaired`（`lib/remote/remote_store.dart:223`）本身正确写入 prefs（同 deviceId 原位覆盖，否则追加）。
- **结论**：要满足"双向链接"，需**新增配对握手命令**（如 `pair.hello {deviceId,name}` → `pair.ack`），让端点在收到后用同一把配对秘密回执并把控制端写入自己的配对表；同时扫码页返回后需刷新列表。
- **状态**：根因已定位（协议缺口 + UI 未刷新），待设计与实现

---

## BUG-D：视频通话 / 语音通话功能无效

- **现象**：发起视频通话/语音通话无效果。
- **相关实现**：`lib/remote/call_service.dart`、`lib/remote/call_lifecycle.dart`、`lib/features/remote/call_screen.dart`（WebRTC + MQTT 信令，docs/16 §…）
- **可疑方向（待设备取证）**：
  1. **MQTT 信令链路不通** —— 通话信令走 `call.invite/answer/candidate/end`，全部经 MQTT；若 broker 不可达则完全无反应；
  2. **与 BUG-A/B 强相关** —— 通话依赖「已配对端点 + 后台引擎运行」，而引擎状态机在真机上已表现出异常；
  3. 摄像头/麦克风权限 + 前台服务类型（`camera`/`microphone` FGS type）；
  4. WebRTC 在 Android 16（API 36）上的兼容性。
- **状态**：待复现取证

---

## 复现前置（本轮已具备）

```bash
export PATH="/e/dev/flutter/bin:/e/dev/android-sdk/platform-tools:$PATH"
export ANDROID_HOME='E:/dev/android-sdk'      # ⚠️ 必须；缺失则 flutter.bat 报 "Android SDK could not be found"
export ANDROID_SDK_ROOT='E:/dev/android-sdk'
export JAVA_HOME='E:\dev\jdk\jdk-17.0.20.1+1'
export GRADLE_USER_HOME='E:/dev/ghproj'        # ⚠️ 必须指 E: 盘（C: 盘发行包会被安全驱动损坏）
# ⚠️ 不要用 `env 'PROGRAMFILES(X86)=...' flutter ...` 前缀 —— 会让 flutter 完全静默（零输出、退出 0）
```
