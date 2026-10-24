# A5 · 原生桥接 / 生命周期 / 平台能力 深度审计

- 审计对象：SonicShield 1.9.9+32（Flutter / Android 为主 + iOS）
- 审计方式：**纯静态**（Read / Grep / Glob / 只读 Bash + 本地 SDK `javap` + 官方文档核对）。未构建、未连真机、未 adb、未改任何工程文件。
- 工作区状态：存在**未提交的 R93 改动**（`NativeBridgePlugin.kt` / `vibrate_caps.dart` / `vibrate_session.dart` / `action.dart` / `counter_plan_materializer.dart` / 两个测试）。本报告对 R93 只做**只读分析**，并在条目中显式标注"在飞"。
- 只写文件：本文件。

**证据等级**：`CONFIRMED`（源码/官方文档/SDK 常量可直接证实）｜`HIGH_CONFIDENCE`（源码链路确定 + 平台行为有官方文档支撑，但未真机复现）｜`SUSPECTED`（推理成立但缺一环）｜`UNVERIFIED`（必须真机/构建才能判定）。

---

## 0. 结论摘要

| 维度 | 结论 |
|---|---|
| 桥接契约完整性 | **无缺失方法**：Dart 侧 30 个调用（含独立通道 `sonic_shield/screencast`）与 Kotlin `when` 分支**逐一对应**，无 `MissingPluginException` 风险（iOS 除外，见 NAT-12） |
| 参数一致性 | 全部一致。Kotlin 用 `Number`/`List<*>` 宽松接收，`as Int` 强转只出现在 `repeat`，Dart 侧恒发 `-1`，无 `ClassCastException` 实际路径 |
| 错误回传 | 插件层 `try/catch → result.error("NATIVE_ERROR")` 覆盖所有同步分支；**但 Dart `_invoke` 把所有异常吞成 `null`**，导致"原生异常"与"平台不支持"在审计上**不可区分**（NAT-13） |
| result 恰好一次 | 插件内**成立**（含异步 `screenCaptureOnce`，服务侧 `AtomicBoolean` 兜住）；`MainActivity` 的投屏授权通道存在"**永不回投**"路径（NAT-09） |
| 权限闭环 | Manifest ↔ 运行时请求基本闭合；**`PACKAGE_USAGE_STATS` 无任何授权入口**（NAT-14）、**通知被拒后 `alert()` 仍报成功**（NAT-10） |
| FGS 类型 | `mediaPlayback`（引擎）/ `microphone`（MicGuard）/ `mediaProjection`（投屏）声明与权限齐备；**MicGuard 的 `START_STICKY` 与 microphone 类型冲突**（NAT-08） |
| 生命周期 | 引擎启停配对良好（R89/R90 成果保留）；**守卫自恢复路径缺麦克风 FGS 通行证 → 静默采集**（NAT-03，最严重）；远程关守卫不撤 FGS（NAT-11） |
| 资源 | `AudioPlayer`/`AudioRecord` 释放到位；**音频焦点只申请不放弃**（NAT-04）、**`deviceAlert` 的 `MediaPlayer` 异常路径泄漏**（NAT-15）、**依赖插件常驻 wakelock 永不释放**（NAT-07） |
| iOS | 仅振动（CoreHaptics）有实现；其余 22 个方法全缺 → 静默 no-op，且 `exactAlarmSupported()` 恒 false 造成**永久误报**（NAT-12） |

**缺陷分布：P0 = 0｜P1 = 3｜P2 = 8｜P3 = 7（共 18 条）**

最严重两条：**NAT-03**（守卫在进程被杀后自恢复，但后台拿不到麦克风 → 采到全静音、UI 仍显示"守卫运行中"，核心安全能力静默失效）与 **NAT-01**（Android 14+ 上 `createVirtualDisplay` 前未 `registerCallback`，远程单帧抓屏**必抛 `IllegalStateException`**，在主力机 Android 16 上 100% 失败）。

---

## 1. 桥接契约表

通道：`sonic_shield/native`（`NativeBridgePlugin.CHANNEL`，Kotlin 侧以 `FlutterPlugin` 注册，被注册到 **UI 引擎 + 后台服务引擎** 两份实例）。独立通道：`sonic_shield/screencast`（`MainActivity.configureFlutterEngine`）。

| # | 方法 | Dart 调用点 | Kotlin 实现点 | 参数一致性 | 错误回传 | result 恰好一次 |
|---|---|---|---|---|---|---|
| 1 | `setExactAlarms` | `native_bridge.dart:64` | `NativeBridgePlugin.kt:100-110` | `times: List<int>`→`List<*>`+`(it as Number).toLong()`；`useAlarmClock: bool` | 外层 catch→`error` | 是（Map 回执） |
| 2 | `clearAlarms` | `:71`；`background_engine.dart:1229` | `:112-115` | 无参 | 外层 catch→`error` | 是（`true`） |
| 3 | `exactAlarmSupported` | `:74` | `:116` | 无参 | 同上 | 是（Bool） |
| 4 | `openExactAlarmSettings` | `:79` | `:117-126` | 无参 | 同上 | 是（API<31 也回 `true`，见 NAT-13 备注） |
| 5 | `isIgnoringBatteryOptimizations` | `:82` | `:127-128` | 无参 | 同上 | 是 |
| 6 | `requestIgnoreBatteryOptimizations` | `:87` | `:129-140` | 无参 | `ActivityNotFoundException`→`error` | 是 |
| 7 | `openOemAutostart` | `:91` | `:210-216` | `vendor: String` | `error` | 是 |
| 8 | `setPersistentWakeLock` | `:102`；`background_engine.dart:384` | `:142-145` / `:549-573` | `enabled: bool` | 内部 try/catch 回 `false`（不上抛） | 是 |
| 9 | `standbyBucket` | `:113` | `:111` / `:459-478` | 无参 | 内部归 `"unknown"` | 是 |
| 10 | `setServiceShouldRun` | `:118` | `:282-292` | `value: bool`（**注意不是 `enabled`**，两侧一致） | `error` | 是 |
| 11 | `getShouldRun` | `:121` | `:293-296` | 无参 | `error` | 是 |
| 12 | `callState` | `:135` | `:298` | 无参 | `error` | 是 |
| 13 | `networkType` | `:151`、`:163` | `:299` | 无参 | `error` | 是 |
| 14 | `startMicService` | `:170`；`guard_screen.dart:156` | `:272-275` / `:1147-1152` | 无参 | `error`（但服务内异常**不上抛**，见 NAT-08） | 是（`true` 立即返回） |
| 15 | `stopMicService` | `:172`；`background_engine.dart:2044` | `:276-281` | 无参 | `error` | 是 |
| 16 | `vibrate` | `:180`；`background_engine.dart:1047` | `:217-228` / `:925-928` | `pattern: List<int>`→`mapNotNull Number` | `error` | 是（**Bool 回执，但 Dart 包装层丢弃**，NAT-06） |
| 17 | `vibrateCapabilities` | `:190` | `:230-231` / `:677-740` | 无参；回 `Map<String,Any>`，Dart 按 `num/bool/String` 解析 | `error` | 是 |
| 18 | `vibrateWaveform` | `:210` | `:232-243` / `:828-867` | `timings: List<int>`、`amplitudes?: List<int>`、`repeat: int`、`useAlarmUsage: bool` | `error` | 是 |
| 19 | `vibrateEnvelope` | `:200` | `:244-257` / `:878-907` | `points: List<Map>`（intensity/sharpness/durationMs 全 `Number` 取） | `error` | 是 |
| 20 | `vibrateStop` | `:224` | `:258-261` / `:910-916` | 无参 | `error` | 是 |
| 21 | `volume.set` | `:229` | `:262-266` / `:937-959` | `media/alarm: double`→`Number.toFloat()` | `error` | 是 |
| 22 | `alert` | `:244` | `:268-271` / `:981-1121` | `message: String` | **方法自兜底，永不 error**（NAT-10） | 是 |
| 23 | `accessibilityEnabled` | `:258` | `:161` / `:583-591` | 无参 | `error` | 是 |
| 24 | `screenCastStop` | `:263` | `:150-160` | 无参 | `error` | 是 |
| 25 | `inputTap` | `:267` | `:162-170` | `x/y: double→Number.toFloat`、`durationMs: int→Number.toLong` | `error` | 是 |
| 26 | `inputSwipe` | `:275` | `:171-187` | 同上（4 坐标） | `error` | 是 |
| 27 | `inputKey` | `:283` | `:188-192` | `keyCode: int→Number.toInt` | `error` | 是 |
| 28 | `inputText` | `:289` | `:193-197` | `text: String` | `error` | 是 |
| 29 | `screenCaptureOnce` | `:298` | `:198-209` | `timeoutMs: int→Number.toLong`（默认 5000） | **异步**：`f` 内部 `AtomicBoolean` 保证单次；同步抛错→`error` | 是（见"理论双回执"说明） |
| 30 | `screenCastStart`（**独立通道**） | `:310` | `MainActivity.kt:70-100` + `onActivityResult:103-125` | 无参 | **无 try/catch** | **否**（存在永不回投，NAT-09） |

### 契约层结论

1. **无"调用有、实现无"**：Dart 侧全部方法名与 Kotlin `when (call.method)` 逐字一致（含 `volume.set` 这种带点的名字）。`else -> result.notImplemented()` 只兜底未列举项。
2. **参数名一致**：`times/useAlarmClock/pattern/timings/amplitudes/repeat/useAlarmUsage/points/enabled/value/media/alarm/message/vendor/x,y,durationMs/x1..y2/keyCode/text/timeoutMs` 全部双侧同名同义。
3. **类型风险点仅 1 处**：`NativeBridgePlugin.kt:238` `call.argument<Int>("repeat")` 是**强转**。Dart `VibrateCommand.repeat` 恒为 `-1`（`vibrate_resolve.dart:113`），落在 `Integer` 范围，无实际 `ClassCastException` 路径；但若将来允许 `repeat` 取大值（>2³¹）会变成 `Long` → CCE → 被外层 catch 成 `NATIVE_ERROR`（不致崩，但振动静默失败）。
4. **`screenCaptureOnce` 的理论双回执**：`result.success` 由 `ScreenCastService.captureOnce` 的 `finish()`（`ScreenCastService.kt:158-169`，`AtomicBoolean` 守卫）回调；若 `f(timeout)` 在**已回调之后**再抛异常，外层 catch 会二次 `result.error`。当前实现内部全包 try/catch，`finish` 幂等，**不可达**；标注为结构性隐患而非缺陷。
5. **系统性弱点**：`_invoke`（`native_bridge.dart:37-50`）把 `PlatformException` / `MissingPluginException` / `TypeError` **一律归 null**。好处是 tick 不被打断（BUG-125），代价是**原生异常被伪装成"平台没这个能力"**——见 NAT-13。

---

## 2. 权限闭环表

| 权限 | Manifest | 运行时请求点 | 拒绝/永久拒绝后的降级 | 评价 |
|---|---|---|---|---|
| `RECORD_AUDIO` | 主清单 `:23` | `permission_flow.dart:121`（引擎启动）、`guard_toggle.dart:118`（守卫开关） | `GuardToggleFailure.micDenied` → SnackBar"请在系统设置中允许后重试"（**无 `openAppSettings()` 一键跳转**） | 闭合；永久拒绝时指引偏弱（P3 级体验问题，未单列条目） |
| `POST_NOTIFICATIONS` | 主清单 `:84` | `permission_flow.dart:119` | Dashboard/守卫页 SnackBar 告知"后台提醒将不出现" | 提示闭合；但**功能层未闭合**：`alert()` 与 `showEvent()` 在无权限时静默丢弃却报成功（NAT-10） |
| `SCHEDULE_EXACT_ALARM` | 主清单 `:87` | 特殊权限，无弹窗；`openExactAlarmSettings()`（`NativeBridgePlugin.kt:117-126`）+ Dashboard 常驻提示行（`dashboard_screen.dart:497-527`） | 原生返回结构化 `{denied:true}` → `alarmDiag` + 审计 `failed` | 闭合且**是全仓做得最好的一条** |
| `RECEIVE_BOOT_COMPLETED` | 主清单 `:90` | 不适用 | `BootReceiver` 先查 `should_run`，否则 no-op | 闭合 |
| `WAKE_LOCK` | 主清单 `:93` | 引擎 `performance` 档（`background_engine.dart:381-395`） | 失败仅留痕，回退"仅通道 B" | 闭合（但见 NAT-07：依赖插件另持一把永不释放的锁） |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | 主清单 `:96` | `permission_flow.dart:134-136`（仅在未加白时弹） | 用户取消 → 下次开引擎再弹；`isIgnoring…` 仍 false | 闭合 |
| `MODIFY_AUDIO_SETTINGS` | 主清单 `:99` | 不适用 | `volume.set` 异常→`error`→Dart `false` | 闭合 |
| `VIBRATE` | 主清单 `:100` | 不适用（normal） | — | 闭合 |
| `FOREGROUND_SERVICE` + `_MEDIA_PLAYBACK` | 主清单 `:9-10` | 不适用 | 缺类型→`startForeground` `SecurityException` | 闭合 |
| `FOREGROUND_SERVICE_MICROPHONE` | 主清单 `:11` + 插件清单 `:5` | 不适用 | `MicGuardService` 的 `startForeground` **无 try/catch**（NAT-08） | 声明闭合，异常处理不闭合 |
| `FOREGROUND_SERVICE_MEDIA_PROJECTION` | 主清单 `:15` | 不适用 | 无 token 时拒绝启动（`ScreenCastService.kt:58-63`） | 闭合 |
| `USE_FULL_SCREEN_INTENT` | 主清单 `:20` | 不适用 | `alert` 前查 `canUseFullScreenIntent()`；**`showIncomingCall` 未查**（系统会降级为普通通知，不崩） | 基本闭合（P3） |
| `CAMERA` / `ACCESS_*_LOCATION` | 主清单 `:57,80-81` | 远程端点（A5 范围外） | 端点回 `error:true` | 未深入（见 §5） |
| `PACKAGE_USAGE_STATS` | **插件清单 `:19`** | **无任何入口**（全仓无 `ACTION_USAGE_ACCESS_SETTINGS`） | 原生 `SecurityException`→`"unknown"`→UI 不显示 | **不闭合（死能力，NAT-14）** |
| `BIND_ACCESSIBILITY_SERVICE` | 主清单 `:184` | 系统设置手动开启 | `accessibilityEnabled()`→false→远程拒绝并提示 | 闭合 |

---

## 3. 资源生命周期表

| 资源 | 创建点 | 释放点 | 异常路径是否释放 | 备注 |
|---|---|---|---|---|
| `AudioPlayer`（solo） | `playback_service.dart:163`（每次 `play()` 新建） | `finally` → `dispose()` `:228-236` | **是**（catch 里先 `_hardStop`） | R90-07 成果，正确 |
| `AudioPlayer`（声景 N 轨） | `:400` | `:428-431` / catch `:434-440` | 是 | 正确 |
| `AudioPlayer`（对讲） | `PttPlaybackSession._player` `:491` | `dispose()` `:543-563` | 依赖调用方调用 `dispose` | 调用方未调用则泄漏（A5 未见统一 finally，属 PTT 模块，未单列） |
| `AudioSession` 音频焦点 | `play()`/`playSoundscape()`/`append()` 各调 `setActive(true)`（just_audio 内部） | **无** | — | **焦点从不放弃（NAT-04）** |
| `MediaPlayer`（device.alert） | `NativeBridgePlugin.kt:1081` | 3s 后 `postDelayed` 内 `stop()+release()` `:1086-1094` | **否**：`prepare()/start()` 抛错时既不 release 也不 stop | NAT-15 |
| `AudioRecord`（record 7.1.1） | `sound_guard_service.dart:145` | `stop()` 三层保证（`_running=false` → 取消订阅 → 带 2s 超时的 `recorder.stop()`）`:224-236`；`onError` 里 `unawaited(stop())` `:203` | 是（超时也不改"已停止"语义） | 插件不回调时原生会话可能残留（已在源码注明） |
| `TextToSpeech` | `flutter_tts` 插件级单例（每引擎 1 个，`FlutterTtsPlugin.kt:74`） | 引擎 detach 时 `shutdown()`（`:80-86`）；每次 `speakSystemTts` 的 `finally` 只 `stop()` | 是 | `FlutterTts()` 每次 new 只是通道包装，**不产生原生泄漏**（已核对 4.2.5 源码） |
| `Vibrator` | `vibratorOf()` `:657-667`（每次取，不缓存句柄） | 无需释放；`vibrateStop()` → `cancel()` | 是（全包 try/catch） | 正确 |
| `WakeLock`（常驻） | `:555-561` `acquire()` 无超时 | `setPersistentWakeLock(false)` → `release()` `:564`；引擎 stop 时 `applyPowerMode('balanced')` `background_engine.dart:2060` | 是（进程死由系统回收） | 配对正确；但**依赖插件另有一把不配对的锁**（NAT-07） |
| `WakeLock`（亮屏） | `:990-994` `acquire(8000)` | 8s 超时自动释放 | 是 | 正确 |
| `MediaProjection` | `ScreenCastService.kt:66` | `stopCast()` `:107-120` / `onDestroy()` `:122-130` | 是（`projection?.stop()` 包 try） | **未注册 `MediaProjection.Callback`**（NAT-01），用户从系统撤销投屏后服务无感知 |
| `VirtualDisplay` / `ImageReader` | `captureOnce` `:172-183` | `finish()` `:158-169`（`AtomicBoolean` 幂等） | 是 | 正确 |
| `FlutterEngine`（后台） | 依赖插件 `BackgroundService.java:211` | 插件 `onDestroy` `:118-121` | 是 | — |
| `Timer`（振动续发） | `vibrate_session.dart:339` | `_pump` 空表时 cancel `:388-391`；`stopFor` `:429-431`；`dispose` `:487` | 是 | 正确 |
| 静态注册表 | `RemoteInputRegistry` / `RemoteCaptureRegistry` | 服务 `onUnbind`/`onDestroy` 清空 | 是 | 无泄漏 |

---

## 4. 缺陷条目

### NAT-01 Android 14+ 单帧抓屏 100% 失败：`createVirtualDisplay` 前未 `registerCallback`，且复用同一 `MediaProjection` 多次抓帧

Severity: P1
Evidence Status: CONFIRMED（代码 + Android 官方文档原文核对）

Affected Files/Lines:
- `android/app/src/main/kotlin/com/sonicshield/sonic_shield/ScreenCastService.kt:144-219`（尤其 `:171-183`）
- `packages/native_bridge/android/src/main/kotlin/com/sonicshield/native_bridge/NativeBridgePlugin.kt:198-209`
- `lib/services/native_bridge.dart:297-299`、`lib/remote/endpoint_service.dart:1479-1494`

Expected Behavior: 已授权投屏会话内抓一帧，返回 JPEG base64；失败时如实回 `null` 并让上层回 `ack ok=false`。

Actual Behavior: Android 14（API 34）起，targetSdk ≥ 34 的应用**必须**先 `MediaProjection.registerCallback()` 再 `createVirtualDisplay()`，否则抛 `IllegalStateException`；本项目全仓 **0 处** `registerCallback` / `MediaProjection.Callback`（`grep -rn "registerCallback" android packages` 无结果）。因此 `captureOnce` 的 `createVirtualDisplay` 必抛 → 被 `catch` 吞成 `finish(null)` → 远程"拍一张"永远返回失败。次生问题：官方文档同时规定**同一 `MediaProjection` 实例只能调一次 `createVirtualDisplay`**（第二次抛 `SecurityException`），本实现把 `projection` 缓存在服务字段里供多次抓帧复用，即使补上 callback，第二次抓帧仍必失败。

Trigger Conditions: Android 14+（含主力机 Redmi K70 Pro / Android 16）；远程指令 `screen.cast{once:true}` 或任何 `screenCaptureOnce` 调用；无需特殊设置，**必现**。

Forward Call Chain:
`RcEndpointService._handleScreenCast`（`endpoint_service.dart:1461`）→ `NativeBridge.screenCastStart()` → `MainActivity.startCastFlow` → 系统授权 → `ScreenCastService.ACTION_START` → 登记 `RemoteCaptureRegistry.captureOnce` → `NativeBridge.screenCaptureOnce()`（`:1481`）→ `MethodChannel('sonic_shield/native').invokeMethod('screenCaptureOnce')` → `NativeBridgePlugin.kt:198-209` → `ScreenCastService.captureOnce` → `projection.createVirtualDisplay(...)` → **IllegalStateException**。

Reverse Call Chain:
`ScreenCastService.captureOnce` 的 catch（`:215-218`）→ `finish(null)` → `callback(null)` → `result.success(null)` → Dart `_invoke` 返回 `null` → `endpoint_service.dart:1482` 判 `b64 == null` → 发 `rc.ack{ok:false,data:'抓帧失败'}` → 审计 `status:'failed'`。

Data Flow / State Transition:
`projection`（服务字段，ACTION_START 时创建）--createVirtualDisplay--> 期望 `ImageReader` 出帧 --> 实际抛异常 --> `done=true` --> `vd/reader` 释放 --> `null` 上抛。状态机停在"投屏服务运行中但永远抓不到帧"，且服务与常驻通知继续存在（直到 `screenCastStop`）。

Evidence:
```kotlin
// ScreenCastService.kt:144-183
fun captureOnce(timeoutMs: Long, callback: (String?) -> Unit) {
    val mp = projection
    if (mp == null) { callback(null); return }
    ...
    vd = mp.createVirtualDisplay(          // ← 之前没有 registerCallback
        "sonicshield-capture", width, height, density,
        DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, null,
    )
```
官方文档（developer.android.com/about/versions/14/behavior-changes-14，"User consent required for each MediaProjection capture session"）：
> "If your app doesn't register this callback, `MediaProjection#createVirtualDisplay` throws an `IllegalStateException` when your app invokes it."
> "Your app invokes `MediaProjection#createVirtualDisplay` multiple times on the same `MediaProjection` instance." → `SecurityException`

Reproduction Steps:
1. 端点开启远程控制、对端发起 `screen.cast{once:true}`；2. 本机在系统弹窗点"开始共享"；3. 观察 `rc.ack` 为 `ok:false` / 审计 `screen.cast · failed · 单帧抓取失败`；4. logcat 可见 `ScreenCastService: captureOnce failed` + `IllegalStateException`。需要 Android 14+ 真机（模拟器亦可）。

Root Cause: 实现按 Android 13 及更早的 `MediaProjection` 契约编写（无需 callback、可多次建 VD）；升级 targetSdk 后未跟进 14 的行为变更。

Alternative Hypotheses: 若设备 targetSdk < 34 则第一条不成立（但 `flutter.targetSdkVersion` 随 Flutter 3.3x 已 ≥ 34，且版本号 1.9.9+32 对应的构建链为 Android 16 目标）；`registerCallback` 可能被写在别处——已全仓 grep 排除。

Business Impact: 远程"看一眼/拍一张"这一 P1 能力在主力机型上完全不可用，且**表现为"用户拒绝授权"**（`endpoint_service.dart:1467-1473` 把 `false` 记成"用户拒绝投屏授权"），排障方向被误导。

Recommended Fix:
1. `ACTION_START` 里 `projection.registerCallback(object : MediaProjection.Callback { override fun onStop() { stopCast() } }, Handler(Looper.getMainLooper()))`，在 `onDestroy` 里 `unregisterCallback`。
2. 每次抓帧**新建** `MediaProjection`（即每次抓帧前重新走一次 `createScreenCaptureIntent` 授权）**或**把 `VirtualDisplay`/`ImageReader` 长驻、抓帧只 `acquireLatestImage()`——后者符合"一次 VD、多次读帧"的官方推荐（`VirtualDisplay#resize`/`setSurface`）。
3. 抓帧失败时把异常类型回传（`result.error("CAPTURE_FAILED", e.message, null)`），别只回 `null`。

Regression Risks: 长驻 VD 会持续占用编码/合成资源（耗电）；改为"每次抓帧一次授权"会改变远程交互（每次弹窗），需产品确认。`onStop` 回调里 `stopCast()` 必须避免与服务自身 `stopSelf()` 递归。

Verification Tests:
- 仪器测试（API 34/36 模拟器）：`screenCaptureOnce` 返回非空 base64，且第二次调用同样成功（若采用长驻 VD 方案）。
- 撤销投屏（系统"停止共享"）后服务应自动 `stopSelf()` 且通知消失。
- 单测锁：`ScreenCastService` 源码中必须出现 `registerCallback`（可做源码断言锁）。

Remaining Uncertainty: `IllegalStateException` 的具体抛出点（`createVirtualDisplay` 入口 vs `getSurface`）未在真机确认；`ImageReader` 在 Android 16 上对 `RGBA_8888` 的支持未见变更。

---

### NAT-02 【R93 在飞】`ringerMode` 常量映射错误：0=静音/1=振动/2=正常，代码写成 0=正常/2=振动 → 静音不告警、正常反告警

Severity: P1
Evidence Status: CONFIRMED（用本地 `platforms/android-36/android.jar` + `javap -constants` 核对常量值）

Affected Files/Lines:
- `lib/domain/models/vibrate_caps.dart:113`（`notificationsMuted`）、`:116-121`（`ringerLabel`）
- `lib/services/vibrate_session.dart:183-187`（审计消息）
- `packages/native_bridge/.../NativeBridgePlugin.kt:712-717`（读 `am.ringerMode`，值本身正确）

Expected Behavior: `RINGER_MODE_SILENT(0)` / `RINGER_MODE_VIBRATE(1)` / `RINGER_MODE_NORMAL(2)` 分别映射为"静音/振动/正常"；"通知类振动会被吞掉"的判据是 **静音(0) 或 勿扰**，**不包括振动模式(1)**。

Actual Behavior: 代码把 `0 => 正常`、`1 => 静音`、`2 => 振动`，且 `notificationsMuted => ringerMode == 1 || ringerMode == 2`。后果**完全反了**：
- 绝大多数手机处于 `NORMAL(2)` → 被判为"振动中"且 `notificationsMuted=true` → **每条振动审计都会挂上"系统振动中…振动极可能被系统静默吞掉"**（假告警，且文案自相矛盾）；
- 真正 `SILENT(0)` 时 → 显示"正常"、`notificationsMuted=false` → **不告警**，而此刻通知类振动恰好真的会被吞。

Trigger Conditions: 任意 Android 设备、任意振动动作；R93 改动合入后即生效（当前工作区已包含）。

Forward Call Chain:
`VibrateSession.start`（`vibrate_session.dart:180-187`）→ `capabilities()` → `NativeBridge.vibrateCapabilities()` → Kotlin `:712-717` 读 `AudioManager.ringerMode`（**原值正确**）→ `VibrateCaps.fromMap` → `notificationsMuted` / `ringerLabel`（**映射错**）→ 审计 `message` / UI 降级提示。

Reverse Call Chain:
用户在静音模式下手动触发振动 → 任务执行成功但无体感 → 查审计 → 审计写"系统正常" → 排查方向被引向"设备无振动器/原生失败"。

Data Flow / State Transition:
`ringerMode: Int`（0/1/2/-1）--错误 switch--> `ringerLabel` 文案 + `notificationsMuted: bool` --> 审计/UI。**值在传输层是对的，只在展示/判据层错**。

Evidence:
```
$ javap -constants -classpath android.jar android.media.AudioManager
  public static final int RINGER_MODE_NORMAL = 2;
  public static final int RINGER_MODE_SILENT = 0;
  public static final int RINGER_MODE_VIBRATE = 1;
```
```dart
// vibrate_caps.dart:113
bool get notificationsMuted => ringerMode == 1 || ringerMode == 2 || dndActive;
// :116-121
String get ringerLabel => switch (ringerMode) {
      0 => '正常', 1 => '静音', 2 => '振动', _ => '读不到',
    };
```

Reproduction Steps:
1. 手机设为**响铃**（正常）模式；2. 触发任一随机/持续振动任务；3. 看审计 `message` 出现"系统振动中，且本动作跟随勿扰…"；4. 再把手机设为**静音**，重复 → 审计不再出现该告警（反了）。纯静态可判定，真机只用于确认文案。

Root Cause: 凭印象写常量（把 `NORMAL` 当成 0、把 `VIBRATE` 当成 2），且没有单测锁住映射。

Alternative Hypotheses: 无。`javap` 直读 SDK 常量，排除版本差异（0/1/2 自 API 1 未变）。

Business Impact: R93 要修的正是"手机震动不好使"的归因链，现在归因链**方向相反**：真实故障（静音）被漏报，正常状态被误报。审计可信度受损，且用户会看到自相矛盾的提示。

Recommended Fix:
```dart
bool get notificationsMuted => ringerMode == 0 || dndActive;  // 0 = SILENT
String get ringerLabel => switch (ringerMode) {
      0 => '静音', 1 => '振动', 2 => '正常', _ => '读不到',
    };
```
并在 `vibrate_caps` 旁加常量注释（`RINGER_MODE_SILENT=0 / VIBRATE=1 / NORMAL=2`），补一条纯函数单测锁三个值。

Regression Risks: `toMap/fromMap` 与 `==`/`hashCode` 已包含这两个字段，改判据不影响持久化；R93 的测试 `test/r93_vibrate_dnd_test.dart` 若按错误映射断言，需要同步修正。

Verification Tests: 参数化单测：`ringerMode ∈ {0,1,2,-1} × dndActive ∈ {false,true}` 断言 `notificationsMuted` 与 `ringerLabel`；再加一条"审计消息不得在 ringerMode==2 时出现"的锁。

Remaining Uncertainty: 无（映射为 SDK 常量事实）。

---

### NAT-03 守卫自恢复：引擎被闹钟唤醒后自动开守卫，但没有 microphone 型 FGS 通行证 → 采到全静音，UI 仍报"守卫运行中"

Severity: P1
Evidence Status: HIGH_CONFIDENCE（代码链路 CONFIRMED；"后台无 mic FGS 时 AudioRecord 收到静音"为 Android 11+ 官方行为，未真机复现）

Affected Files/Lines:
- `lib/services/background_engine.dart:2358-2360`（bootstrap 末尾自恢复）
- `lib/services/background_engine.dart:1918-1940`（`guard` 监听 → `guard.start`）
- `lib/services/sound_guard_service.dart:139-159`（直接 `startStream`，不做权限/前台判定）
- `lib/features/guard/guard_toggle.dart:118-126`（**唯一**会 `startMicService` 的路径）
- `packages/native_bridge/.../MicGuardService.kt:14-25`（文档明确"通行证"语义）

Expected Behavior: 守卫要恢复，必须先有 microphone 型前台服务（`MicGuardService`）在前台交互时启动并存活；拿不到通行证时应**如实报失败**（`guardError`），不得报 `guardActive:true`。

Actual Behavior: 引擎每次 bootstrap 只读 `prefs['guard_enabled']`，然后 `service.invoke('guard', {'enabled': true})`，监听器直接 `guard.start()`。整条链**没有任何** `startMicService` 调用（全仓 `startMicService` 只在 `guard_screen.dart`/`guard_toggle.dart` 出现）。进程被杀 → 看门狗/开机闹钟拉起 `BackgroundService`（类型 `mediaPlayback`）→ 引擎自恢复守卫 → `AudioRecord.startRecording()` 在后台**不抛异常**但只返回静音（Android 11+ while-in-use 语义：只有 microphone 型 FGS 才授予后台麦克风）→ 声音事件永不产生，而 `guard.isRunning=true` → `broadcast` 回投 `guardActive:true`。

Trigger Conditions: 用户曾开启守卫（`guard_enabled=true`）→ 进程被系统杀/被划掉/重启 → 由 `AlarmWatchdogReceiver` 或 `BootReceiver` 拉起引擎（非用户点开关）。此时无 UI 交互，`MicGuardService` 已被随进程杀死（或从未重启）。

Forward Call Chain:
`AlarmWatchdogReceiver.onReceive`（`:16-42`）→ `startForegroundService(BackgroundService)` → `engineEntryPoint` bootstrap → `background_engine.dart:2358` `service.invoke('guard',{'enabled':true})` → `:1925` `guard.start(cfg)` → `sound_guard_service.dart:145` `_recorder.startStream(...)` → **静音流**。

Reverse Call Chain:
`guard.start` 返回 `GuardStartResult.ok()`（取流未抛）→ `guardError=null` → `broadcast(guardActive: guard.isRunning=true)`（`:1159`）→ UI `engineStateProvider` 显示"守卫运行中" → 用户以为在守护。

Data Flow / State Transition:
`guard_enabled=true`（持久化）--进程死--> `MicGuardService` 消失（FGS 与进程同生共死）--闹钟--> 新引擎 --自恢复--> `_running=true` --无 FGS 通行证--> 系统给静音 PCM --RMS 恒 -120dBFS--> 永不达阈值 --> 无 `SoundEvent`。状态表：`guardActive=true` 但"有效采音=false"。

Evidence:
```dart
// background_engine.dart:2358-2360
if (guardEnabled) {
  service.invoke('guard', {'enabled': true}); // 守卫自恢复
}
```
```dart
// sound_guard_service.dart:144-159（无任何 FGS/前台判定，注释还明确说"必须在前台/带麦克风前台服务的上下文中调用"）
stream = await _recorder.startStream(const RecordConfig(
  encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1, ...));
```
```kotlin
// MicGuardService.kt:17-21（设计意图）
// Android 11+ 的 while-in-use 语义要求：应用在后台使用麦克风，必须存在
// 一个由【前台交互】启动的 microphone 类型前台服务。
```

Reproduction Steps:
1. 开引擎 → 开守卫（此时有 MicGuardService，采音正常）；2. 在最近任务里划掉应用（或 `adb shell am force-stop` 后由闹钟唤醒——注意本审计禁止 adb，此处为真机实验步骤）；3. 等看门狗闹钟拉起引擎；4. 在守卫页制造 >阈值 的声音；5. 观察：`guardActive=true`，但审计无任何 `guard · sound` 事件；6. `dumpsys activity services | grep MicGuard` 应无该服务。

Root Cause: "守卫状态"（prefs）与"麦克风通行证"（FGS 生命周期）是两套状态，自恢复只恢复了前者。而 `SoundGuardService.start` 刻意不做权限判定（BUG-A 的正确修复），于是失败也不会被发现。

Alternative Hypotheses: 若 OEM 把 FGS 也算作"前台"，可能仍能采音（不同 ROM 行为不一）——但 AOSP 语义明确要求 microphone 类型；另有少数设备 `startRecording` 直接抛 `SecurityException`，那反而是"好"的结果（会走 `guardError`）。

Business Impact: 核心安全能力（声音守卫/取证/动态反击）在**最需要它的场景**（应用被系统杀后长期驻留）静默失效，且 UI 与审计都说"在跑"。这是本项目最忌讳的"静默假成功"，且比单次失败更隐蔽。

Recommended Fix:
1. 引擎 bootstrap 自恢复守卫前，先探测通行证：新增桥方法 `isMicServiceRunning()`（`ActivityManager.getRunningServices` 过滤本应用 `MicGuardService`，或维护一个"服务存活"的静态标志 + `onDestroy` 置 false）。
2. 拿不到通行证 → **不启动采音**，把 `guardError` 设为"后台麦克风通行证已失效：请打开应用重新开启守卫"，并回投 `guardActive:false`。
3. 或在引擎启动时尝试 `startForegroundService(MicGuardService)`——但 Android 12+ 后台启动 FGS 受限，成功率低，不建议作为主路径。
4. 补审计：`guard · start · skipped · 无麦克风通行证`。

Regression Risks: 守卫从"看似自动恢复"变成"明确要求用户回前台重开"，是**行为可见性**的变化，需产品确认文案；`isMicServiceRunning` 依赖 `getRunningServices`（API 26+ 仅返回本应用，足够）。

Verification Tests:
- 仪器测试：force-stop 后由 `AlarmManager` 唤醒，断言 `guardActive=false` 且 `guardError` 非空。
- 单测：`SoundGuardService` 注入假 recorder，断言"未拿到通行证时不置 `_running=true`"（需引入通行证探测缝）。

Remaining Uncertainty: 具体 OEM（MIUI/HyperOS）在 `mediaPlayback` FGS 下是否仍给静音——需在 Redmi K70 Pro / Android 16 上用 `AudioRecord` 读 RMS 实测；若 OEM 给的是"真实音频"，则本条降级为"依赖 OEM 行为，不可依赖"。

---

### NAT-04 音频焦点只申请不放弃：每次播放结束都不 `setActive(false)`，其它应用的闪避/暂停不会恢复

Severity: P2
Evidence Status: CONFIRMED（全仓 0 处 `setActive(false)`；`audio_session` 仅在 `setActive(false)` 时 `abandonAudioFocus`）

Affected Files/Lines:
- `lib/services/playback_service.dart:29-41`（焦点类型：alarm→`gain`，media→`gainTransientMayDuck`）
- `lib/services/playback_service.dart:173-174`、`:397-398`、`:510-511`（只 `configure`，不 `setActive`）
- 依赖：`just_audio-0.9.46/lib/just_audio.dart:952`（只有 `setActive(true)`）；`audio_session-0.1.25/android/.../AndroidAudioManager.java:326-336,652-656`（`abandonAudioFocus` 只在 `setActive(false)`/`dispose` 时调用）

Expected Behavior: 播放结束（成功/失败/被 stop）后放弃音频焦点，让被 duck 的应用恢复音量、被暂停的应用可自动恢复。

Actual Behavior: `just_audio` 在 `play()` 时 `audioSession.setActive(true)` 申请焦点；`stop()`/`dispose()` 都不会 `setActive(false)`。本项目也未在 `PlaybackService.stop()/dispose()` 里补这一句。于是应用**从第一次播放起一直持有音频焦点**，直到进程死亡或别的应用抢焦点导致本应用收到 `AUDIOFOCUS_LOSS`（`AndroidAudioManager.java:307` 才 abandon）。

Trigger Conditions: 任一次 `alarm` 通道播放（`gain`：直接暂停别人的音乐/播客）或 `media` 通道播放（`gainTransientMayDuck`：把别人音量压低）；播放结束后观察其它播放器。

Forward Call Chain:
`PlaybackService.play`（`:153`）→ `AudioSession.configure`（`:174`）→ `player.play()` → just_audio `setActive(true)`（`:952`）→ `AndroidAudioManager.requestAudioFocus` → 结束时 `_hardStop`（`:214`）→ `player.dispose()`（`:233`）→ **无 `setActive(false)`**。

Reverse Call Chain:
用户的音乐 App 收到 `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` → 自行压低音量 → 我们播完 → 音乐 App **不会**收到 `GAIN`（因为焦点从未释放）→ 音量一直低。

Data Flow / State Transition:
`焦点: none → (play) 本应用持有 → (stop) 仍持有`；期望 `→ (stop) none`。`_activePlays` 归零只影响 `_playing` 注册表，不影响焦点。

Evidence:
```
$ grep -rn "setActive" lib/            # 无任何命中
$ grep -rn "setActive" just_audio-0.9.46/lib/
just_audio.dart:952:  if (!_handleAudioSessionActivation || await audioSession.setActive(true)) {
```
```java
// AndroidAudioManager.java:652-656
public void dispose() { abandonAudioFocus(); ... }
```

Reproduction Steps:
1. 手机播放网易云/Spotify；2. 触发一次 alarm 通道任务（如定时播放音效）；3. 任务结束、声音停止；4. 观察音乐：被暂停后**不会自动继续**，或被 duck 后**音量一直偏低**，直到手动操作。

Root Cause: 把 `AudioSession.configure`（设置参数）当成"焦点管理"，漏掉 `setActive(false)` 的配对；`just_audio` 只负责申请。

Alternative Hypotheses: 某些播放器在收到 `LOSS` 后会轮询焦点或用户点播放时重新申请（此时本应用收到 LOSS 并 abandon，能恢复）——所以症状是"暂停需手动恢复"，而非"永久无声"。

Business Impact: 每次自动化放音都会干扰用户正在听的音乐且**不自动恢复**，与产品"短提示音只闪避不打断"的设计意图（`focusGainFor` 注释）相反；用户会认为应用"抢音频"。

Recommended Fix:
在 `PlaybackService` 的 `finally`（`_activePlays` 归零时）与 `stop()`/`dispose()` 里：
```dart
final s = await AudioSession.instance;
await s.setActive(false);
```
注意多路并发时用引用计数（已有 `_activePlays`）保证"最后一路结束才释放"，否则会打断仍在播的另一路。

Regression Risks: 释放过早会让仍在播的声景/对讲被系统静音（`setActive(false)` 在 Android 上只是 abandon 焦点，不会停止播放，但其它应用会立刻恢复音量并可能盖过来）。必须与 `_activePlays`/`_pttStreams` 对齐。

Verification Tests:
- 单测（注入假 AudioSession 不可行）→ 用源码锁：`playback_service.dart` 必须包含 `setActive(false)` 且位于 `_activePlays <= 0` 分支。
- 真机：两路并发播放 + 中途 `stopAllPlaying()`，断言另一路仍在响（验证引用计数）。

Remaining Uncertainty: `audio_session` 的 `setActive(false)` 在 Android 上是否同时影响 `AudioRecord` 会话（守卫采音）——需真机验证两者共存时的行为。

---

### NAT-05 【R93 在飞】把"动态系统状态"（ringerMode / dndActive）塞进"静态能力"并永久缓存 → 勿扰变化后诊断长期失真

Severity: P2
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/services/vibrate_session.dart:147-164`（`_capsCache` 一次探测、进程内复用）
- `packages/native_bridge/.../NativeBridgePlugin.kt:707-739`（把 `ringerMode`/`dndActive` 与 `hasVibrator` 等静态能力放在**同一个 Map**）
- `lib/domain/models/vibrate_caps.dart:87-96`（`fromMap` 一并解析）

Expected Behavior: 能力（是否有振动器/振幅/包络）可以缓存；系统状态（响铃模式/勿扰）必须**每次执行时现读**，或至少不参与能力缓存。

Actual Behavior: `capabilities()` 只要 `platform != 'unknown'` 就写 `_capsCache` 并**永不再探测**（引擎生命周期内）。R93 把动态状态混进同一回执，于是：
- 引擎启动时是"正常" → 用户后来开了勿扰 → 审计仍写"正常"，**不告警**；
- 引擎启动时是"勿扰" → 用户后来关掉 → 审计永远写"勿扰中，振动极可能被吞"，**假告警**。
`VibrateSession` 在 bootstrap 创建（`background_engine.dart:410`），引擎可连续运行数天。

Trigger Conditions: 引擎运行期间用户切换静音/勿扰（极常见，尤其夜间）；随后触发振动任务。

Forward Call Chain:
`VibrateSession.start`（`:180`）→ `capabilities()`（`:156-164`，命中 `_capsCache`）→ 用**旧** `ringerMode/dndActive` 生成 `degradations`（`:183-187`）→ 写审计 / UI 提示。

Reverse Call Chain:
用户夜间开勿扰 → 振动被系统吞 → 查审计 → 审计写"系统正常，已成功" → 用户认为应用坏了。

Data Flow / State Transition:
`VibrateCaps{hasVibrator…, ringerMode, dndActive}` 一个对象承载两种生命周期不同的数据；缓存键只有"是否探测成功"，无 TTL、无失效事件（未监听 `RINGER_MODE_CHANGED_ACTION` / `INTERRUPTION_FILTER_CHANGED`）。

Evidence:
```dart
// vibrate_session.dart:156-164
Future<VibrateCaps> capabilities() async {
  final c = _capsCache;
  if (c != null) return c;                 // ← 永久复用
  final fresh = await capsProbe();
  if (fresh.platform != 'unknown') _capsCache = fresh;
  return fresh;
}
```
```kotlin
// NativeBridgePlugin.kt:731-739（静态能力与动态状态同一 Map）
return mapOf("hasVibrator" to hasVib, ..., "ringerMode" to ringerMode, "dndActive" to dndActive)
```

Reproduction Steps: 1. 开引擎（手机响铃）；2. 开勿扰；3. 触发持续振动；4. 审计中**没有**"勿扰"相关降级说明（实际被吞）。

Root Cause: 数据建模把"能力"与"环境"混为一个值对象，且缓存策略只考虑"读不到"。

Alternative Hypotheses: 若 `VibrateSession` 每次任务都重建（不是），则无此问题——已确认是 bootstrap 单例。

Business Impact: R93 的诊断结论"有时对有时错"，比没有诊断更糟；且审计是产品核心卖点（"计划即审计"）。

Recommended Fix:
- 拆成两个回执/两个方法：`vibrateCapabilities`（可缓存）与 `vibrateEnvironment`（每次现读，或监听 `RINGER_MODE_CHANGED_ACTION` + `INTERRUPTION_FILTER_CHANGED`）。
- 过渡方案：`capabilities()` 缓存静态字段，`start()` 每次调 `NativeBridge.vibrateCapabilities()` 只取 `ringerMode/dndActive`（或给桥加 `vibrateEnv()`）。

Regression Risks: 多一次通道调用（<1ms，本地）；R93 的测试需相应调整。

Verification Tests: 单测：capsProbe 返回两次不同 ringer，断言第二次 `start()` 使用新值（当前实现会失败）。

Remaining Uncertainty: 无。

---

### NAT-06 固定节奏振动恒走 `USAGE_NOTIFICATION`，且回执被丢弃 → 静音/勿扰下"没震却记 success"；远程 fixed 路径完全无审计

Severity: P2
Evidence Status: CONFIRMED（Kotlin 回执语义 + Dart 丢弃链路均可静态证实；系统"吞振动仍返回成功"为平台行为）

Affected Files/Lines:
- `packages/native_bridge/.../NativeBridgePlugin.kt:925-928`（`vibrate()` 固定 `useAlarm=false`）
- `packages/native_bridge/.../NativeBridgePlugin.kt:753-760`（`useAlarm=false` → `USAGE_NOTIFICATION`）
- `lib/services/native_bridge.dart:179-180`（`Future<void>`，**丢弃 bool**）
- `lib/main.dart:142`（`vibrateHandler = (pattern) => NativeBridge.vibrate(pattern)`）
- `lib/remote/endpoint_service.dart:2789-2791`（`await vibrateHandler!(pattern);` 无结果判定、无 stepNotes、无审计）
- `lib/domain/models/action.dart:302-330`（`VibrateAction` **没有** `respectDnd` 字段）

Expected Behavior: R93 已确认"静音/勿扰会吞掉 `USAGE_NOTIFICATION` 振动，而 API 仍返回成功"；固定节奏动作应与随机/持续一致地可配置 `USAGE_ALARM`，且回执要如实。

Actual Behavior: 随机/持续振动经 `vibrateWaveform(useAlarmUsage: ...)` 已支持 `USAGE_ALARM`（R93），但**固定节奏**（老 `VibrateAction`、远程 `mode=fixed`）走 `vibrate` → `vibrateWaveform(..., useAlarm=false)` → 永远 `USAGE_NOTIFICATION`。在静音/勿扰下系统吞掉振动、`vibrate()` 不抛异常 → 返回 `true` → 引擎 `background_engine.dart:1047-1055` 记 `success`；远程 fixed 路径连回执都不看（`vibrateHandler` 返回 `Future<void>`），也不写 `stepNotes`。

Trigger Conditions: 静音或勿扰；任一固定节奏振动任务；或远程指令组 `vibrate{mode:fixed}`。

Forward Call Chain（引擎）:
`runSingle` `case VibrateAction`（`:1024`）→ `native.invokeMethod('vibrate', {'pattern': ...})`（`:1047`）→ Kotlin `vibrate()`（`:925`）→ `vibrateWaveform(useAlarm=false)` → `vibrationAttributes(false)` → `USAGE_NOTIFICATION` → 系统吞掉 → 返回 `true` → 审计 `success`。

Forward Call Chain（远程）:
`RcScriptExecutor` → `_runVibrateStep`（`endpoint_service.dart:2780`）→ `route == legacyFixed` → `await vibrateHandler!(pattern)`（`:2790`）→ `NativeBridge.vibrate` → **丢弃 bool** → 无审计、无 `stepNotes`。

Reverse Call Chain:
控制端收到 `script.state done`，`stepNotes` 为空 → 认为已震；用户什么都没感觉到。

Data Flow / State Transition:
`VibrateAction` → `patternMs` → Kotlin `List<Long>` → `createWaveform` → `vibrate(effect, AudioAttributes(USAGE_NOTIFICATION))`。**没有** `respectDnd` 维度可传。

Evidence:
```kotlin
// NativeBridgePlugin.kt:925-928
private fun vibrate(ctx: Context, pattern: List<Long>): Boolean {
    if (pattern.isEmpty()) return false
    return vibrateWaveform(ctx, pattern, null, -1, false)   // ← 恒 false = USAGE_NOTIFICATION
}
```
```dart
// native_bridge.dart:179-180
static Future<void> vibrate(List<int> patternMs) =>
    _invoke<Object?>('vibrate', {'pattern': patternMs});   // ← 丢弃 bool
```
```dart
// endpoint_service.dart:2789-2791
case RcVibrateRoute.legacyFixed:
  ...
  await vibrateHandler!(pattern);        // ← 无 ok 判定、无 stepNotes
```

Reproduction Steps: 1. 手机静音；2. 建一个"固定节奏振动"任务并触发；3. 审计 `vibrate · success`，实际无振动；4. 远程指令组发 `mode=fixed`，`stepNotes` 不含该步。

Root Cause: R93 只改了新动作族（Random/Continuous），老动作族被"向后兼容"豁免；且 `NativeBridge.vibrate` 的返回类型在 BUG-133 补了 Kotlin 回执后**没有同步**到 Dart 签名。

Business Impact: 老任务（存量用户最多）在静音场景下 100% 静默失败且记 success；远程控制端得到"已执行"的假回执。与 BUG-133 的修复目标直接冲突。

Recommended Fix:
1. `vibrate` 通道加可选 `useAlarmUsage` 参数（Kotlin `call.argument<Boolean>("useAlarmUsage") ?: false`），`VibrateAction` 增加 `respectDnd`（默认 false，与 R93 口径一致）。
2. `NativeBridge.vibrate` 返回 `Future<bool>`；`main.dart` 的 `vibrateHandler` 改为 `Future<bool> Function(List<int>)`；`_runVibrateStep` 的 `legacyFixed` 分支按 `ok` 写 `stepNotes` + 审计。
3. 审计里带上 `useAlarmUsage` 与 `ringerMode`（NAT-02 修好后才有意义）。

Regression Risks: `vibrateHandler` 签名变更会影响 `endpoint_service.dart:243` 与所有注入点（含测试）；`VibrateAction.toJson` 新增字段需保持旧数据可读（`?? false`）。

Verification Tests:
- 单测：`routeRcVibrateStep` + 假 handler 返回 false，断言 `stepNotes` 非空。
- 源码锁：`vibrate()` 必须把 `useAlarm` 透传（禁止硬编码 false）。

Remaining Uncertainty: 不同 OEM 对 `USAGE_NOTIFICATION` 振动在静音下的处理（AOSP 是丢弃；部分 ROM 仍震）——真机确认即可，但"不可依赖"这一结论已成立。

---

### NAT-07 依赖插件持有常驻 `PARTIAL_WAKE_LOCK` 且**永不释放**，并每 5s 排一次精确闹钟 → "平衡/省电模式不持锁"不成立

Severity: P2
Evidence Status: CONFIRMED（第三方依赖源码）

Affected Files/Lines:
- 依赖：`flutter_background_service_android-6.3.1/.../BackgroundService.java:43,58-68,198`（`acquire`）、`:106-124`（`onDestroy` 无 `release`）
- 依赖：`WatchdogReceiver.java:29-57`（5s 一次 `setAndAllowWhileIdle`）、`BackgroundService.java:181-187`（每次 `onStartCommand` 重排）
- 本项目：`lib/services/background_engine.dart:374-399`、`:2058-2060`（自建锁的对称释放，逻辑正确）
- `NativeBridgePlugin.kt:77-91,549-573`（自建锁的注释明确宣称"只在 performance 档持有"）

Expected Behavior: 平衡/省电模式下进程可正常休眠；引擎停止后不再持有任何唤醒锁。

Actual Behavior: 依赖插件在 `runService()` 里 `getLock(ctx).acquire()` 一把**静态** `PARTIAL_WAKE_LOCK`，全文件**没有任何 `release()`**（`grep release()` 无命中），`onDestroy` 也不释放。因此：只要用户**曾经**开过一次引擎，进程就会一直持有唤醒锁直到进程被杀——与电源模式无关。同时 `onStartCommand` 每次 `WatchdogReceiver.enqueue(this)`（5s），形成 5 秒一次的系统闹钟循环。

Trigger Conditions: 任意一次引擎启动（含开机/看门狗自恢复）。

Forward Call Chain:
`BackgroundServiceManager.start()` → `_svc.startService()` → 插件 `onStartCommand`（`:181`）→ `runService()` → `getLock(...).acquire()`（`:198`）→ 进程级持锁。

Reverse Call Chain:
用户关闭引擎 → `engine.stop` → `service.stopSelf()` → 插件 `stopService` 分支（`:305-310`）`isManuallyStopped=true; WatchdogReceiver.remove; stopSelf()` → `onDestroy`（`:106`）销毁引擎但**不 release 锁** → 进程作为 cached process 继续持锁。

Data Flow / State Transition:
`wakelock: 未持有 → (首次 startService) 持有 → (stopSelf) 仍持有 → (进程被杀) 释放`。项目自建的 `persistentWakeLock` 与它**无关**，两把锁独立。

Evidence:
```java
// BackgroundService.java:198（runService）
getLock(getApplicationContext()).acquire();
// :58-68
synchronized public static PowerManager.WakeLock getLock(Context context) { ... lockStatic.setReferenceCounted(true); ... }
// :106-124 onDestroy —— 无 lockStatic.release()
```
```java
// BackgroundService.java:181-187
public int onStartCommand(...) { config.setManuallyStopped(false); WatchdogReceiver.enqueue(this); runService(); return START_NOT_STICKY; }
```

Reproduction Steps: 1. 开引擎 5s 后关引擎；2. `adb shell dumpsys power | grep -i "sonic_shield\|flutter_background"` 观察仍持有 `PARTIAL_WAKE_LOCK`（真机实验）；3. `dumpsys alarm | grep flutter_background_service` 观察 `RESPAWN` 闹钟。注意：`isManuallyStopped` 后闹钟会被 remove，但锁不会。

Root Cause: 依赖插件把锁当"服务级"资源管理却从未配对；项目注释误以为"只有我们自己的锁"。

Business Impact: ①7×24 待机耗电显著升高，与"平衡模式不持锁"的产品承诺矛盾；②Doze 实验结论会被这把锁污染（测"是否被冻结"时其实一直醒着），导致过往"锁屏仍准点"的结论不可信；③用户关了引擎仍耗电，属于"关不掉"的体感。

Recommended Fix:
- 短期：在本地插件加一个 `releaseBackgroundServiceLock()`（通过 `Class.forName("id.flutter.flutter_background_service.BackgroundService")` 读 `lockStatic` 并 `release()`），在引擎 `stop` 收尾与 `stopSelf()` 之后调用；或直接反射 `BackgroundService.lockStatic`（它是 `public static volatile`）。
- 中期：升级/替换 `flutter_background_service`（或 fork 修 `onDestroy` 释放 + 去掉 5s 看门狗）。
- 同时把 `setPersistentWakeLock` 的语义文档改为"额外的锁"，别宣称"唯一"。

Regression Risks: 反射依赖类名/字段名，升级插件会断（需 try/catch + 降级）；提前释放可能让"引擎刚停、收尾未完成"的窗口被 Doze 冻结（可在 `stopSelf` 之后再释放）。

Verification Tests:
- 真机：开→关引擎后 `dumpsys power` 无本应用 wakelock。
- 8 小时待机电量对比（开/关引擎各一次）。

Remaining Uncertainty: 进程成为 cached 后 Android 是否会在内存压力下更快回收（会），以及 OEM 是否额外清理 wakelock（部分 ROM 会）——但 AOSP 语义下确实泄漏。

---

### NAT-08 `MicGuardService` 返回 `START_STICKY`，与 `microphone` 型 FGS 的 while-in-use 约束冲突：后台重启时 `startForeground` 可能抛 `SecurityException` 直接崩进程

Severity: P2
Evidence Status: SUSPECTED（代码确定；系统是否重启 sticky 服务并在此场景抛异常需真机）

Affected Files/Lines:
- `packages/native_bridge/.../MicGuardService.kt:64-73`（`startForeground` 无 try/catch，返回 `START_STICKY`）
- `packages/native_bridge/.../MicGuardService.kt:22-24`（注释自述"服务被杀后不会被自动复活（平台语义）"——与 `START_STICKY` **自相矛盾**）

Expected Behavior: 服务被杀后**不要**自动复活（因为复活时没有前台交互，拿不到 while-in-use 权限）；或在 `onStartCommand` 里检测 `RECORD_AUDIO` 未授予/应用不在前台时**不**调 `startForeground` 并 `stopSelf()`。

Actual Behavior: 返回 `START_STICKY`，系统会以 `null` Intent 重启服务 → `onStartCommand` 无条件 `startForeground(NOTIF, notif, FOREGROUND_SERVICE_TYPE_MICROPHONE)`。Android 14 对 microphone 型 FGS 要求"启动时具备 while-in-use 能力"，后台重启不满足 → `SecurityException`（`MissingForegroundServiceTypeException`/`SecurityException`）→ 未被捕获 → 服务崩溃（`FATAL EXCEPTION` in `onStartCommand`），可能形成"重启-崩溃"循环。

Trigger Conditions: 用户在后台（或锁屏）时系统回收进程；或用户从系统设置撤销麦克风权限后服务被重启。

Forward Call Chain:
系统回收进程 → `START_STICKY` 重启 `MicGuardService`（Intent=null）→ `onStartCommand`（`:35`）→ `startForeground(..., MICROPHONE)`（`:64-69`）→ 权限/前台态不满足 → `SecurityException`。

Reverse Call Chain:
崩溃后进程重建 → 无 `guard_enabled` 清理 → 引擎可能再次自恢复守卫（与 NAT-03 叠加）。

Data Flow / State Transition:
`Service: running → killed → (STICKY) restarting → startForeground(mic) → SecurityException → crashed`。期望 `→ stopped`。

Evidence:
```kotlin
// MicGuardService.kt:64-73
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
    startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
} else { startForeground(NOTIFICATION_ID, notification) }
return START_STICKY
```

Reproduction Steps: 1. 开守卫（MicGuardService 在跑）；2. 锁屏/切后台；3. 让系统回收进程（低内存或 `am kill`，需真机/模拟器）；4. logcat 观察 `MicGuardService` 重启后 `SecurityException`。

Root Cause: 复制了常规 FGS 的 `START_STICKY` 模板，但 microphone 型 FGS 不具备"无前台交互重启"的资格。

Alternative Hypotheses: 部分版本对 sticky 重启豁免 while-in-use 检查（AOSP 的检查点在 `startForeground` 内部，与启动来源无关），因此更可能是"必然抛"；也可能系统直接不重启（因为 FGS 类型不允许），此时表现为"守卫悄悄没了"（仍是缺陷，只是不崩）。

Business Impact: 最坏是崩溃循环（用户看到"声盾屡次停止运行"）；最好也是守卫静默消失。两种都与注释承诺不符。

Recommended Fix:
- 改 `START_NOT_STICKY`（与 `BackgroundService` 一致），守卫恢复由 NAT-03 的显式探测 + 用户前台重开承担。
- `startForeground` 包 `try/catch`，失败时 `stopSelf()` 并留一条 `SelfHealNotice`。
- 修正 KDoc，去掉"不会被自动复活"的错误表述。

Regression Risks: 不再 sticky 后，进程被杀 → 守卫必然停（当前实际上也停），行为更诚实；需同步更新 docs/05。

Verification Tests: 仪器测试：授予权限 → 启动服务 → 撤销权限 → 强杀进程 → 断言不崩溃。

Remaining Uncertainty: Android 16 上 sticky 重启与 while-in-use 的具体交互（需实测）。

---

### NAT-09 `screenCastStart` 无超时、无异常兜底：一旦授权结果不投递或 `startActivityForResult` 抛错，`pendingCastResult` 永挂 → 该 Activity 生命周期内**永久**返回 false（并被记成"用户拒绝"）

Severity: P2
Evidence Status: CONFIRMED（逻辑确定；触发条件需特定交互）

Affected Files/Lines:
- `android/app/.../MainActivity.kt:68`（`pendingCastResult` 字段）、`:90-100`（设置后启动授权）、`:103-125`（唯一清理点）
- `lib/services/native_bridge.dart:308-320`（Dart 侧无 `.timeout`）
- `lib/remote/endpoint_service.dart:1461-1473`（false → "用户拒绝投屏授权"）

Expected Behavior: 授权流程必须在有界时间内以 `true/false/error` 之一结束；异常要回 `error` 并复位状态。

Actual Behavior:
1. `startCastFlow` 先 `pendingCastResult = result`，再 `startActivityForResult(...)`。若该调用抛 `ActivityNotFoundException` / `SecurityException`（设备策略禁用投屏、缺少 `MEDIA_PROJECTION_SERVICE`），异常从 MethodCallHandler 逃逸，`pendingCastResult` **永不复位**。
2. 此后每次 `screenCastStart` 都命中 `if (pendingCastResult != null) { result.success(false); return }` → 永久 false。
3. 用户侧表现：远程请求投屏永远"被拒绝"，审计写"用户拒绝投屏授权"，而用户根本没看到弹窗。
4. Dart 侧 `invokeMethod` 无超时，若 Activity 在系统弹窗期间被销毁（进程未死但 Activity 重建，如分屏/多窗口/开发者选项"不保留活动"），结果不会投递 → Future **永不完成** → `_handleScreenCast` 卡住（该远程请求无 ack，对端 45s 超时）。

Trigger Conditions: ①设备策略禁用屏幕捕获；②"不保留活动"开启 + 授权弹窗期间切走；③Activity 在 for-result 期间被系统销毁。

Forward Call Chain:
`endpoint_service.dart:1461` → `NativeBridge.screenCastStart()` → `_screenCastCh.invokeMethod` → `MainActivity.startCastFlow`（`:90`）→ `pendingCastResult = result` → `startActivityForResult(...)` **抛** → 无 catch → 状态残留。

Reverse Call Chain:
下一次请求 → `startCastFlow` 命中 `pendingCastResult != null` → `result.success(false)` → Dart `false` → 审计"用户拒绝投屏授权" + `ack ok=false`。

Data Flow / State Transition:
`pendingCastResult: null → Result（挂起） → 期望 onActivityResult 清空 → 实际永久非 null`。

Evidence:
```kotlin
// MainActivity.kt:90-100
private fun startCastFlow(result: MethodChannel.Result) {
    if (pendingCastResult != null) { result.success(false); return }
    val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
    pendingCastResult = result
    @Suppress("DEPRECATION")
    startActivityForResult(mpm.createScreenCaptureIntent(), REQ_SCREEN_CAPTURE)   // ← 无 try/catch
}
```

Reproduction Steps: 静态推导：在 `startActivityForResult` 前后打断点/注入异常即可复现；真机条件 = 开启开发者选项"不保留活动"，发起投屏后在系统弹窗上按 Home 并让 Activity 被回收。

Root Cause: 把"用户会给出结果"当成必然，未处理"结果可能永远不来"；Dart 侧对这条通道也没有超时（对比 `BackgroundServiceManager.start()` 的 12s 超时，是同一类问题的既有解法）。

Business Impact: 投屏能力在一次异常后**永久不可用**（直到杀进程），且错误归因指向用户，排障成本高。

Recommended Fix:
1. `startCastFlow` 用 `try { startActivityForResult } catch (e) { pendingCastResult = null; result.error("CAST_START_FAILED", e.message, null) }`。
2. `onDestroy` / `onStop` 里若 `pendingCastResult != null` → `result.error("CAST_CANCELLED", ...)` 并清空。
3. Dart 侧加 `.timeout(const Duration(minutes: 2), onTimeout: () => false)`，超时后由调用方提示"授权窗未完成"。

Regression Risks: 超时后用户再完成授权会得到一次"迟到"的 `success`（通道已关闭 → 忽略），需要在 `onActivityResult` 里判 `pendingCastResult` 是否已置空。

Verification Tests: 仪器测试（ActivityScenario）：注入 `ActivityNotFoundException`，断言 `result` 收到 error 且第二次调用能重新弹窗。

Remaining Uncertainty: Flutter 的 `MethodChannel` 对 handler 抛异常是否兜底（不同 Flutter 版本行为不同）——若兜底为 error 则第 4 点不成立，但第 1/2 点（状态残留）仍成立。

---

### NAT-10 `device.alert` 在通知权限被拒时仍返回 `true`：远程"找回告警已展示"是假成功

Severity: P2
Evidence Status: CONFIRMED（`notify()` 在无 POST_NOTIFICATIONS 时静默丢弃、不抛异常；代码 `ok = true` 无条件）

Affected Files/Lines:
- `packages/native_bridge/.../NativeBridgePlugin.kt:1002-1055`（尤其 `:1050-1051`）
- `lib/services/native_bridge.dart:243-246`
- `lib/remote/endpoint_service.dart:2325-2336`（`ok` → "找回告警已展示"）

Expected Behavior: 通知未展示时应如实说明（"已亮屏并播放提示音，但通知被系统拦截"），而不是整体 `true`。

Actual Behavior: `deviceAlert` 分三步（亮屏 / 通知 / 提示音），任一步成功即 `ok=true`。Android 13+ 用户拒绝 `POST_NOTIFICATIONS` 时 `nm.notify()` 是**静默 no-op**（不抛异常），代码照样 `ok=true`。远程收到 `ack ok=true, data=null`，审计写"找回告警已展示"。若同时提示音也失败（如音频焦点被占），用户可能只感到屏幕亮了一下。

Trigger Conditions: Android 13+ 且通知权限被拒（`requestAllPermissions` 只弹一次，用户可能拒）；远程发 `device.alert`。

Forward Call Chain:
`endpoint_service._deviceAlert`（`:2325`）→ `NativeBridge.alert` → `NativeBridgePlugin` `alert`（`:268`）→ `deviceAlert` → `nm.notify(9001, notif)`（无权限 → 丢弃）→ `ok=true` → `result.success(true)` → `ack ok=true`。

Reverse Call Chain:
控制端显示"已让对方响铃"，用户端实际只有 3 秒提示音（甚至无），错失找回窗口。

Data Flow / State Transition:
`NotificationManager.areNotificationsEnabled()` 未参与判定；`ok` 是三件事的 OR，不是 AND，也不是"用户可感知"的度量。

Evidence:
```kotlin
// NativeBridgePlugin.kt:1050-1051
nm.notify(9001, notif)
ok = true
```

Reproduction Steps: 1. 系统设置里关掉声盾通知权限；2. 远程发 `device.alert`；3. 观察 ack 为成功、审计"已展示"，通知栏无任何东西。

Root Cause: 沿用"任一步成功即成功"的宽松语义，未把"通知是否真的可见"纳入回执。

Business Impact: 设备找回是安全类能力，"假成功"直接导致用户放弃后续手段。

Recommended Fix:
- 通知步骤前判 `nm.areNotificationsEnabled()`（API 24+），false 时把原因累加进回执；
- 返回结构化 `{screen:Boolean, notification:Boolean, sound:Boolean}`，Dart 侧 `alert` 返回 `AlertResult`，`ack` 里写明缺哪一项；
- 或在通知被拒时用 `SelfHealNotice` 提示用户去开权限。

Regression Risks: `alert` 回执类型从 `bool` 变 `Map` → `NativeBridge.alert` 与远程 ack 需同步（同 NAT-13 的类型兼容问题，可用 `Object` + 解析器）。

Verification Tests: 单测（宿主）无法覆盖；用源码锁 + 仪器测试（撤销通知权限后调用，断言回执含 `notification:false`）。

Remaining Uncertainty: 部分 OEM 在通知被拒时仍会展示"静默通知"（无横幅）——`areNotificationsEnabled()` 仍为 false，判据不受影响。

---

### NAT-11 远程关闭守卫不撤 `MicGuardService`：常驻通知"正在监听声音事件"残留，与"守卫已关"矛盾

Severity: P3
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/remote/endpoint_service.dart:2349-2365`（`_setRemoteGuard` 只 `mgr.setGuard`）
- `lib/services/background_engine.dart:1918-1983`（`guard` 监听只 `guard.stop()`，**无** `stopMicService`）
- 对照：`lib/features/guard/guard_toggle.dart:143-146`（本地关闭会 `stopMicService`）；`background_engine.dart:2043-2051`（引擎停机才撤）

Expected Behavior: 任何"关闭守卫"的入口都应成对撤下麦克风通行证（本地、远程、停机三条路径一致）。

Actual Behavior: 远程 `guard.set{enabled:false}` 只停采流，`MicGuardService` 与它的 `IMPORTANCE_LOW` 常驻通知继续存在（"正在监听声音事件（仅本地处理，不上传）"）。用户从通知栏看到"正在监听"，实际没有采音；且麦克风通行证被长期占用，影响其它应用/耗电。

Trigger Conditions: 远程关闭守卫（或远程 `guard.set` 后引擎侧处理）；引擎仍在运行。

Forward Call Chain:
`_setRemoteGuard`（`:2352`）→ `mgr.setGuard(false)` → `service.invoke('guard',{enabled:false})` → 引擎监听（`:1918`）→ `guard.stop()` → 结束（FGS 未动）。

Reverse Call Chain:
通知栏常驻 → 用户以为被监听 → 手动关引擎 → 才在 `:2044` 撤下。

Data Flow / State Transition:
`MicGuardService: running` 与 `guard.isRunning: false` 出现不一致的中间态，且无超时收敛。

Evidence:
```dart
// background_engine.dart:1918-1921 + 1966-1981（关闭分支只做 guard.stop）
service.on('guard').listen((m) async {
  guardEnabled = (m?['enabled'] as bool?) ?? false;
  ...
  await guard.stop();
  await logs.append(source: 'guard', action: 'stop', status: 'success');
});
```

Reproduction Steps: 1. 本地开守卫；2. 远程发 `guard.set{enabled:false}`；3. 通知栏仍有"声盾 · 声音守卫"；4. `dumpsys` 可见 MicGuardService。

Root Cause: 三条关闭路径各自实现，未收敛到单一"关闭守卫"用例。

Business Impact: 隐私感知问题（"关了还在监听"）+ 耗电 + 麦克风占用。

Recommended Fix: 在引擎 `guard` 监听器的关闭分支里调用一次 `stopMicService`（与 `:2044` 同一句），或把"停守卫"抽成函数供三处调用。

Regression Risks: 若远程关闭后本地 UI 仍显示开（`guardActive` 由引擎回投，会变 false），无冲突；重复 `stopService` 幂等。

Verification Tests: 单测：注入假 service/guard，断言关闭分支调用了 `stopMicService`。

Remaining Uncertainty: 无。

---

### NAT-12 iOS：22 个桥方法无实现（静默 no-op），且 `exactAlarmSupported()` 恒 false 导致 iOS 上**永久**显示"精确闹钟权限未开启"

Severity: P2
Evidence Status: CONFIRMED（代码）；iOS 运行时表现 UNVERIFIED（无 macOS/真机）

Affected Files/Lines:
- `ios/Runner/HapticBridge.swift:45-67`（只实现 `vibrateCapabilities/vibrateWaveform/vibrateEnvelope/vibrateStop/vibrate`）
- `ios/Runner/AppDelegate.swift:13-20`（仅注册 HapticBridge）
- `lib/services/native_bridge.dart:73-76`（`exactAlarmSupported` → `r ?? false`）
- `lib/features/dashboard/dashboard_screen.dart:476-493,497,510-524`（`_exactAlarm == false` → 常驻告警行）
- `lib/services/background_service_manager.dart:111-115`（iOS `IosConfiguration`）
- `ios/Runner/Info.plist:40-55`（自述 `processing/fetch` 与本地通知兜底"未落地"）

Expected Behavior: iOS 上不显示 Android 专属权限告警；未实现的能力要显式标注"本平台不支持"，而不是与"权限被拒"混为一谈。

Actual Behavior:
1. `sonic_shield/native` 在 iOS 上只处理 5 个振动方法，其余（`setExactAlarms/clearAlarms/exactAlarmSupported/openExactAlarmSettings/isIgnoringBatteryOptimizations/requestIgnore.../openOemAutostart/setPersistentWakeLock/standbyBucket/setServiceShouldRun/getShouldRun/callState/networkType/startMicService/stopMicService/volume.set/alert/accessibilityEnabled/screenCastStop/inputTap/inputSwipe/inputKey/inputText/screenCaptureOnce`）返回 `FlutterMethodNotImplemented` → Dart `_invoke` → `null`。
2. `exactAlarmSupported()` 在 iOS 返回 `false`（而非 null），Dashboard 据此**永久**渲染"精确闹钟权限未开启（锁屏可能失效）"+ "去开启"按钮（点了没反应，`openExactAlarmSettings` 也是 no-op）。
3. `serviceShouldRun()` 恒 false；`setServiceShouldRun` 静默失败 → iOS 上"开机恢复"概念不存在。
4. 后台调度依赖 `flutter_background_service_ios` 的 `BGAppRefreshTask`（`earliestBeginDate = now + 15min`，系统可完全跳过）→ 定时任务在 iOS 上**没有可承诺的准时性**；`IosConfiguration.onBackground: (s) async => true` 只是占位。

Trigger Conditions: 任意 iOS 设备/模拟器；打开首页即命中第 2 点。

Forward Call Chain:
`Dashboard.initState`（`:479-482`）→ `_checkExactAlarm()`（`:484-493`）→ `NativeBridge.exactAlarmSupported()` → `_invoke<bool>` → iOS `FlutterMethodNotImplemented` → `MissingPluginException` → `null` → `r ?? false` → `_exactAlarm=false` → 渲染告警（`:497,510-524`）。

Reverse Call Chain:
用户点"去开启" → `openExactAlarmSettings()` → `_invoke` → null（无异常）→ 无任何 UI 反馈 → 再查仍 false。

Data Flow / State Transition:
`桥能力: 未实现` --被 _invoke 折叠为 null--> `exactAlarmSupported: false` --被 UI 解读为"权限未授予"--> 永久告警。

Evidence:
```swift
// HapticBridge.swift:64-66
default:
  result(FlutterMethodNotImplemented)
```
```dart
// dashboard_screen.dart:486-492
var ok = true;                       // 注释说"读不到按已就绪"
try { ok = await NativeBridge.exactAlarmSupported(); } on Object { ok = true; }
// 但 exactAlarmSupported() 内部已把 null 折成 false（native_bridge.dart:75），
// 所以 iOS 永远走不到这里的"按已就绪"分支。
```

Reproduction Steps: iOS 模拟器跑 App → 首页"电源白名单与厂商保活引导"卡片下出现"精确闹钟权限未开启（锁屏可能失效）"，点"去开启"无反应。

Root Cause: "能力未实现"与"权限被拒"在返回值上不可区分（`null` vs `false`），而 `exactAlarmSupported` 选择了 `false` 这个"确定否定"。

Business Impact: iOS 用户看到一个无法修复、也无法消失的告警（信任损耗）；同时把"平台不支持"误导成"你没给权限"。

Recommended Fix:
- `NativeBridge.exactAlarmSupported()` 改为 `Future<bool?>`（或新增 `isAndroid` 判据），Dashboard 仅在 `false` 时告警；`null` 视为"不适用"。
- iOS 侧补一个"能力矩阵"回执（或由 Dart 侧按 `Platform.isIOS` 直接短路），把"未实现"显式化。
- iOS 上隐藏厂商保活/精确闹钟整块卡片。

Regression Risks: `bool?` 变更会影响 `permission_flow.dart:129-141`（`exactAlarmDenied: !exactAlarmOk`）与相关测试；Android 语义不变（只有 true/false）。

Verification Tests: 单测：mock 通道返回 `MissingPluginException`，断言 Dashboard 不渲染告警（需把 `_checkExactAlarm` 抽出可测函数）。

Remaining Uncertainty: iOS 后台实际能跑多久、`BGAppRefresh` 是否被系统授予——必须真机 + Xcode 观察；`HapticBridge` 在后台引擎（若 iOS 侧存在独立引擎）是否注册——`flutter_background_service_ios` 复用主引擎，故应可用，但未验证。

---

### NAT-13 原生异常被统一折叠为"平台不支持"：审计/诊断给出错误结论（精确闹钟、投屏、振动同族）

Severity: P3
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/services/native_bridge.dart:37-50`（`_invoke` 三类异常全归 null）
- `lib/services/native_bridge.dart:384-408`（`fromRaw(null)` → `unsupported: true`）
- `lib/services/background_engine.dart:1188-1198`（据此写"本平台未实现精确闹钟"）
- `lib/services/native_bridge.dart:308-320`（`screenCastStart` 同理）

Expected Behavior: `PlatformException`（原生明确报错）应区别于 `MissingPluginException`（平台无此通道），前者记为 `failed` 并带原因，后者才是 `unsupported`。

Actual Behavior: 两者都变 null。于是 `setAlarmClock` 抛 `SecurityException`（例如厂商 ROM 限制特权通道）时，审计写"本平台未实现精确闹钟：进程被杀后不再补触发"——把"权限/系统拒绝"误报成"平台没这功能"，用户按提示也修不好。

Trigger Conditions: 原生分支抛任意异常（`NATIVE_ERROR`）；或通道被销毁。

Forward Call Chain:
Kotlin `scheduleExactAlarms` 内 `am.setAlarmClock` 抛 → 逐条 catch 回 `error` 字段（**这条路径其实是好的**）；但若异常发生在 `when` 外层（如 `call.argument` 类型错、`ctx` 失效），走 `:302-304 result.error` → Dart `_invoke` → null → `AlarmScheduleResult.unsupported`。

Reverse Call Chain:
`alarmDiag = '本平台未实现精确闹钟…'` → UI 显示 → 用户去查"为什么我的手机不支持"，而真实原因是原生异常。

Data Flow / State Transition:
`异常种类: PlatformException | MissingPlugin | TypeError` → 全部 `null` → `unsupported`。信息在此处**不可逆丢失**。

Evidence:
```dart
// native_bridge.dart:41-49
} on PlatformException { return null; }
} on MissingPluginException { return null; }
} on Object { return null; }
```
```dart
// native_bridge.dart:402-407
return AlarmScheduleResult(expected: expected, scheduled: 0, denied: false, unsupported: true);
```

Reproduction Steps: 在 Kotlin handler 里对任一方法 `throw RuntimeException("x")`（静态推导，不需真机）→ Dart 侧看到 `unsupported` 而非 `failed`。

Root Cause: 为修复 BUG-125（TypeError 穿透）而统一收敛，未保留"错误种类"这一维度。

Business Impact: 诊断失真，排障方向错误；对本项目"失败必须可解释"的红线是系统性削弱。

Recommended Fix: `_invoke` 增加 `on PlatformException catch (e) { lastNativeError = e; return null; }` 并让调用方读取；或提供 `_invokeRaw` 返回 `(value, errorKind)`。`AlarmScheduleResult.fromRaw` 增加 `nativeError` 维度。

Regression Risks: 调用点很多（30 处），逐处改造风险大；建议只给"诊断类"调用（alarms/screencast/alert）加。

Verification Tests: 单测：mock 通道抛 PlatformException，断言 `AlarmScheduleResult.degraded && !unsupported`。

Remaining Uncertainty: 无。

---

### NAT-14 `PACKAGE_USAGE_STATS` 声明了但全仓无授权入口 → `appStandbyBucket` 恒为 `unknown`，省电桶自检是死功能

Severity: P3
Evidence Status: CONFIRMED

Affected Files/Lines:
- `packages/native_bridge/android/src/main/AndroidManifest.xml:19-20`
- `packages/native_bridge/.../NativeBridgePlugin.kt:459-478`（`getAppStandbyBucket` 需该 appop）
- `lib/services/power_service.dart:60-79`、`lib/features/settings/settings_screen.dart:1902-1915`
- 全仓 `grep ACTION_USAGE_ACCESS_SETTINGS` 无结果

Expected Behavior: 要么提供"去授予使用情况访问权"的入口（`Settings.ACTION_USAGE_ACCESS_SETTINGS`），要么不声明该权限、不暴露该面板。

Actual Behavior: `UsageStatsManager.getAppStandbyBucket()` 需要 `PACKAGE_USAGE_STATS`（appop，只能由用户在系统设置里授予），而 App 内**没有任何入口**。因此 `SecurityException` → `"unknown"` → `standbyBucketLabel` 返回 null → UI 不显示。该能力永远不会产出信息。

Trigger Conditions: 所有设备、所有版本（API 28+）。

Forward Call Chain:
设置页 → `PowerService.standbyBucket()` → `NativeBridge.appStandbyBucket()` → Kotlin `appStandbyBucket` → `usm.appStandbyBucket` → `SecurityException` → `"unknown"`。

Reverse Call Chain:
UI 判断 label 为 null → 不渲染 → 用户永远看不到"你的应用已被打入 rare 桶"这一关键告警。

Data Flow / State Transition:
`权限: 未授予（且不可授予）` → `bucket: unknown` 恒定。

Evidence:
```kotlin
// NativeBridgePlugin.kt:462-477
val usm = ctx.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager ?: return "unknown"
when (usm.appStandbyBucket) { ... }        // 无权限 → SecurityException → "unknown"
```

Reproduction Steps: 全新安装 → 打开设置页保活自检 → 无省电桶信息；`adb shell appops get <pkg> GET_USAGE_STATS` 为 default。

Root Cause: 声明了权限但漏了引导入口；`unknown` 的"不猜"设计掩盖了"永远读不到"。

Business Impact: docs/59 缺口2 的自检承诺未兑现；用户在最需要"被系统降级"提示时看不到任何东西。

Recommended Fix: 在保活引导面板加一个"授予使用情况访问权"按钮（`Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)`），并在 `unknown` 时显示"未授权，无法判断（点此授权）"；或直接删除该能力与权限声明（减少攻击面/审核问题）。

Regression Risks: 新增系统设置跳转在部分 ROM 上 ActivityNotFound → 需 fallback 到应用详情页。

Verification Tests: 单测：`standbyBucketLabel('unknown') == null`（已有）；新增"unknown 时 UI 显示授权入口"的 widget 测试。

Remaining Uncertainty: 部分 OEM 是否默认授予该 appop（少数定制 ROM 会）——不影响"无入口"的结论。

---

### NAT-15 `deviceAlert` 的 `MediaPlayer` 在异常路径不释放（无 try/finally）

Severity: P3
Evidence Status: CONFIRMED

Affected Files/Lines: `packages/native_bridge/.../NativeBridgePlugin.kt:1078-1118`（创建 `:1081`，释放只在 `:1086-1094` 的延时回调里）

Expected Behavior: `prepare()`/`start()` 抛错时必须 `release()` 已创建的 `MediaPlayer`。

Actual Behavior: `val player = MediaPlayer()` 之后 `setDataSource/prepare/start` 任一抛错 → 跳到外层 `catch (e: Exception) { Log.w(...) }`（`:1116-1118`），`player` 既没 `stop()` 也没 `release()` → 原生解码器/文件句柄泄漏。每次远程"找回"失败一次就泄漏一个。

Trigger Conditions: 铃声 URI 不可读、`prepare()` 超时/`IOException`、音频服务异常。

Forward Call Chain:
`alert` → `deviceAlert` → `MediaPlayer()`（`:1081`）→ `setDataSource`（`:1083`）→ 抛 → 外层 catch（`:1116`）→ 泄漏。

Reverse Call Chain:
反复触发找回 → 每次泄漏一个 `MediaPlayer` → 最终 `MediaPlayer` 创建失败（系统上限）→ 提示音永久失效。

Data Flow / State Transition:
`player: created → (异常) 未 release → GC 仅回收 Java 对象，native 资源不保证释放`。

Evidence:
```kotlin
val player = MediaPlayer()
player.setAudioAttributes(...)
player.setDataSource(ctx, uri)
player.prepare()
player.start()
Handler(...).postDelayed({ try { player.stop() } ...; try { player.release() } ... }, 3000L)
```

Reproduction Steps: 把 `RingtoneManager.getDefaultUri(TYPE_ALARM)` 指到一个不可读 URI（静态推导）；或在 `prepare` 处打断点抛异常 → `dumpsys media.player` 计数不降。

Root Cause: 用"延时回调"代替 `try/finally`，把释放责任交给了成功路径。

Business Impact: 低频但会累积；且发生在"设备找回"这种安全场景。

Recommended Fix:
```kotlin
val player = MediaPlayer()
try { ...; player.start(); Handler(...).postDelayed({ runCatching { player.stop() }; runCatching { player.release() }; ... }, 3000) }
catch (e: Exception) { runCatching { player.release() }; Log.w(...) }
```
注意释放后不要再被延时回调二次 release（用 `AtomicBoolean` 或把 release 只放在延时回调、异常路径单独 release）。

Regression Risks: 双重 release 会抛 `IllegalStateException`（已用 runCatching 包住）。

Verification Tests: 源码锁 + 仪器测试（注入坏 URI，断言不抛且无泄漏）。

Remaining Uncertainty: 无。

---

### NAT-16 `replan` 只"排新"不"撤旧"：不在新计划里的旧精确闹钟不会被取消（孤儿闹钟）

Severity: P3
Evidence Status: CONFIRMED

Affected Files/Lines:
- `packages/native_bridge/.../NativeBridgePlugin.kt:345-416`（只 `set*` 并把 `saved` 覆盖写回 `KEY_ALARMS`）
- `:418-427`（`clearExactAlarms` 只在显式 `clearAlarms` / 引擎停机时调用）
- `lib/services/background_engine.dart:1183-1187`（每次 replan 全量重排）

Expected Behavior: 每轮重排应"以新集合为准"：先 `cancel` 上一轮 `KEY_ALARMS` 中不在新集合里的 PI。

Actual Behavior: `scheduleExactAlarms` 直接覆盖 `KEY_ALARMS` 为本次 `saved`，上一轮排过、本轮不在计划里的 PI **失去引用**，再也无法被 `clearAlarms` 取消（它只遍历 `KEY_ALARMS`）。这些闹钟到点仍会触发 `AlarmWatchdogReceiver` → 拉起 FGS（`should_run` 与代次都仍有效）→ 引擎空跑一轮。

Trigger Conditions: 删除/停用任务、修改触发时间、计划 horizon 滚动后时间集合变化。

Forward Call Chain:
`replan` → `pushExactAlarms(newTimes)` → `setExactAlarms` → 覆盖 `KEY_ALARMS` → 旧 PI 失联。

Reverse Call Chain:
旧时间到点 → `AlarmWatchdogReceiver`（`:24-26` 两个闸门都通过）→ `startForegroundService` → 引擎启动 → `executeDue` 无到期任务 → 空转（耗电、可能弹通知）。

Data Flow / State Transition:
`AlarmManager 中的 PI 集合` ⊋ `KEY_ALARMS`（记账集合），二者不再一致 → `clearAlarms` 只能清子集。

Evidence:
```kotlin
// NativeBridgePlugin.kt:411-412
ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    .edit().putStringSet(KEY_ALARMS, saved).apply()   // ← 直接覆盖，未 cancel 差集
```

Reproduction Steps: 1. 建两个任务（T+10min、T+20min）；2. 删掉第二个；3. 等 replan；4. T+20min 仍被唤醒（`dumpsys alarm` 可见该 PI）。

Root Cause: 把 `KEY_ALARMS` 当"记账"而非"待取消清单"，未做差集。

Business Impact: 无效唤醒（耗电）、用户"删了任务还被唤醒"的困惑；与 P1-03 的"关掉就不再拉起"是同一族问题的残留。

Recommended Fix: 在 `scheduleExactAlarms` 开头读出旧集合，计算 `old - new` 并逐条 `am.cancel(watchdogPendingIntent(ctx, t))`；或提供"全量替换"语义（先清后排，注意与代次/看门狗竞态）。

Regression Risks: 先清后排的窗口内进程被杀 → 无闹钟（可接受，下一轮自愈）；需保证 `cancel` 与 `set` 的 requestCode 计算一致（当前一致）。

Verification Tests: 单测（需抽出 PI 构造）或仪器测试：排 2 条→排 1 条→断言 `dumpsys alarm` 只剩 1 条。

Remaining Uncertainty: 引擎是否会周期性全量重排从而"碰巧"清掉——不会，只覆盖不取消。

---

### NAT-17 精确闹钟权限恢复接收器用 1s 延迟，与 `BootReceiver` 的 30s 归因窗口结论不一致（可能被 FGS 启动限制拒绝）

Severity: P3
Evidence Status: SUSPECTED

Affected Files/Lines:
- `packages/native_bridge/.../ExactAlarmPermissionReceiver.kt:83`（`KICK_DELAY_MS = 1_000L`）
- `android/app/.../BootReceiver.kt:92-111`（30s，注释详述"<20s 窗口内会被归因回广播源 → 触发 FGS 禁令"）

Expected Behavior: 两条"后台拉起 mediaPlayback FGS"的路径应采用同一套归因窗口策略（要么都等窗口过去，要么都确认该 action 有豁免）。

Actual Behavior: `BootReceiver` 实测证明"窗口内启动会被归因回广播源 → Android 15+ 禁止 → 崩溃"，因此取 30s；而 `ExactAlarmPermissionReceiver` 在权限变更广播后 **1s** 就排 kick 闹钟——若该广播同样带来临时白名单，1s 后的闹钟仍会被归因回 `SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`，同样可能被拒。被拒时 `AlarmWatchdogReceiver` 会 `SelfHealNotice`（不静默），但**功能失效**。

Trigger Conditions: Android 12+/15+，用户撤销后重新授予"闹钟和提醒"权限，且引擎本应自恢复。

Forward Call Chain:
系统广播 → `ExactAlarmPermissionReceiver.onReceive`（`:37`）→ 排 1s 后 kick（`:48-67`）→ `AlarmWatchdogReceiver`（`:31`）`startForegroundService` → 可能 `ForegroundServiceStartNotAllowedException`。

Reverse Call Chain:
异常 → `SelfHealNotice.failed`（`:40`）→ 用户看到"看门狗闹钟未能拉起引擎"，但不知道要手动开一次 App。

Data Flow / State Transition:
`权限: denied → granted` → 期望"自动重排并恢复" → 实际可能"排了但拉不起"。

Evidence:
```kotlin
// ExactAlarmPermissionReceiver.kt:82-83
/** 权限刚恢复，无需等待白名单窗口；留 1s 让系统设置页先收起。 */
private const val KICK_DELAY_MS = 1_000L
```
```kotlin
// BootReceiver.kt:109-111
// 故取 30s（20s 窗口 + 10s 余量）。这是"合法绕过"的关键，不能缩短。
private const val KICK_DELAY_MS = 30_000L
```

Reproduction Steps: Android 15+ 设备：关权限 → 重开 → 不手动打开 App，观察引擎是否自恢复；logcat 看 `ForegroundServiceStartNotAllowedException`。

Root Cause: 两条路径的"归因窗口"经验未共享；1s 的注释基于"无需等待"的假设，未实测。

Business Impact: 权限恢复后的自动重排可能失效（用户以为已恢复）。

Recommended Fix: 统一常量（如共享 `KICK_DELAY_MS = 30_000L`），或在 `AlarmWatchdogReceiver` 里对 `ForegroundServiceStartNotAllowedException` 做一次 30s 后重试。

Regression Risks: 恢复延迟从 1s 变 30s（用户感知变慢，可接受）。

Verification Tests: 真机（API 35/36）：撤销→授予→等 40s→断言引擎 `isForeground=true`。

Remaining Uncertainty: 该 action 是否真的给临时白名单（未在 AOSP 文档中明确）——需 logcat 的 `tempAllowListReason` 验证。

---

### NAT-18 `permission_flow.exactAlarmDenied` 计算后无人消费（死字段），与 Dashboard 的独立判断形成双源

Severity: P3
Evidence Status: CONFIRMED

Affected Files/Lines:
- `lib/services/permission_flow.dart:96-103,129,140`
- `lib/features/dashboard/dashboard_screen.dart:198-205`（只消费 `notificationDenied`）、`:476-527`（另一套 `_exactAlarm`）
- `lib/features/guard/guard_screen.dart:170`（只消费 `notificationDenied`）

Expected Behavior: "一站式权限申请"返回的每一项都应被消费，或不该存在于结果对象里。

Actual Behavior: `exactAlarmDenied` 在全仓**无读取点**（`grep exactAlarmDenied` 只有定义与赋值）。Dashboard 另起一套 `_exactAlarm` 状态做常驻提示。两套判断并存：一处基于 `requestAllPermissions` 的即时结果，一处基于页面 `initState` 的一次性探测；后者在用户从设置页返回后需要手动点"去开启"才刷新。

Trigger Conditions: 用户开引擎时精确闹钟未授权 → `permission_flow` 算出了 denied 但没人提示；只有回到首页看常驻卡片。

Forward Call Chain:
`requestAllPermissions`（`:129-141`）→ 返回带 `exactAlarmDenied:true` 的对象 → 调用方只读 `notificationDenied` → 字段被丢弃。

Reverse Call Chain:
用户以为"权限都给了" → 锁屏后失效 → 才在首页看到常驻告警（如果注意到）。

Data Flow / State Transition:
`PermissionRequestOutcome.exactAlarmDenied` 处于"算了但没人看"的悬空状态。

Evidence:
```dart
// permission_flow.dart:129-141
final exactAlarmOk = await NativeBridge.exactAlarmSupported();
...
return PermissionRequestOutcome(..., exactAlarmDenied: !exactAlarmOk);
```
（无任何 `perms.exactAlarmDenied` 读取点）

Reproduction Steps: 静态即可确认。

Root Cause: 两轮修复（P2-16 的 outcome 对象 / v1.9.1 的常驻卡片）各自落地，未合并。

Business Impact: 重复逻辑、易漂移；iOS 上的误报（NAT-12）正是因为两套判断都基于同一个错误前提。

Recommended Fix: 删除死字段，或让 Dashboard/守卫页统一消费 `PermissionRequestOutcome`；把 `_checkExactAlarm` 抽成共享函数。

Regression Risks: 低（纯重构）。

Verification Tests: `flutter analyze` 的 unused field 不会报（public field）；用单测锁"开引擎后必须提示 exactAlarmDenied"。

Remaining Uncertainty: 无。

---

## 5. 未覆盖范围与原因

### 5.1 必须真机验证（静态分析无法定论）

| 项 | 需要什么条件 | 关联条目 |
|---|---|---|
| `MediaProjection` 在 Android 14+/16 上的 `IllegalStateException` | Redmi K70 Pro（Android 16）+ 远程对端；抓 logcat | NAT-01 |
| 后台无 microphone FGS 时 `AudioRecord` 是否返回静音 | 同上；守卫开启 → force-stop → 闹钟唤醒 → 播 >阈值 声音，看 RMS | NAT-03 |
| sticky 重启 `MicGuardService` 是否抛 `SecurityException` | 低内存/`am kill` + 锁屏 | NAT-08 |
| 音频焦点未放弃的实际症状 | 两台设备或本机音乐 App + 一次 alarm 播放 | NAT-04 |
| 静音/勿扰下 `USAGE_NOTIFICATION` 振动是否真被吞 | 静音 → 固定节奏振动任务 | NAT-06 |
| `dumpsys power` 中依赖插件 wakelock 是否残留 | 开→关引擎后 `dumpsys power`/`dumpsys alarm` | NAT-07 |
| Doze 下 `setAlarmClock` 的准时性与 9 分钟节流 | 长时间灭屏（≥2h）+ 多条任务 | 全文"Doze"结论 |
| MIUI/HyperOS 的省电策略/自启动白名单 | 真机手动配置 | NAT-03/07 |

### 5.2 需要构建环境（沙箱无 dart/flutter/gradle）

- Kotlin 编译验证：本报告仅用 `javap` 核对了 `VibrationEffect$BasicEnvelopeBuilder.addControlPoint(float,float,long)`、`Vibrator.areEnvelopeEffectsSupported/getEnvelopeEffectInfo`、`VibratorEnvelopeEffectInfo.getMinControlPointDurationMillis():long`、`NotificationManager.canUseFullScreenIntent/getCurrentInterruptionFilter`、`ServiceInfo.FOREGROUND_SERVICE_TYPE_*` 的签名与常量值；**未**编译整包，因此 R8/ProGuard、资源引用（`R.string.screen_cast_notification_*`）、`tools:replace` 合并结果未验证。
- `flutter analyze` / 单测未运行（R93 改动是否通过现有测试未知）。

### 5.3 iOS

- 无 macOS/Xcode，**所有 iOS 结论均未在设备/模拟器上验证**：`HapticBridge` 的实际触感、`BGAppRefresh` 是否被调度、`UIBackgroundModes` 与实际能力的一致性（`Info.plist:40-44` 自述 `processing/fetch` 与本地通知兜底"未落地"）。
- iOS 侧 `HapticBridge` 只在 `didInitializeImplicitFlutterEngine` 注册；若 `flutter_background_service_ios` 复用主引擎则可覆盖后台回调，但**未验证**。

### 5.4 明确未深入（超出 A5 或属其他工作包）

- 远程端点/协议层（`RcPermGate`、定位/摄像头权限、`guard.set` 的业务语义）——仅在与桥接回执相关处引用。
- 调度正确性（免打扰窗口、反击计划物化）——A2 工作包。
- 数据库/加密/备份——A3/A4 工作包。
- `ptt_stream_sink` / `multi_call_service` 的播放器生命周期——只在资源表中标注"依赖调用方 dispose"，未逐条审计。
- 依赖插件 `flutter_background_service` 的 5s 看门狗是否会与 `AlarmWatchdogReceiver` 的精确闹钟产生配额冲突——需真机长跑。

### 5.5 对 R93（未提交改动）的立场

本报告对 R93 只做**只读**分析，未做任何修改。NAT-02 / NAT-05 直接针对 R93 新增的 `ringerMode`/`dndActive` 链路，**建议在合入前修复**：前者是常量映射错误（会让"修振动"的补丁产生反向结论），后者是数据建模问题（动态状态被静态缓存）。R93 的其余改动（`action.dart` 默认 `respectDnd=false`、`counter_plan_materializer` 显式 `USAGE_ALARM`）在静态层面自洽，未发现新缺陷；`rc_script.dart` 强制远程 `respectDnd=true` 的边界也成立。
