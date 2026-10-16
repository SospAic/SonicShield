package com.sonicshield.native_bridge

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.app.usage.UsageStatsManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * Android 16 / API 36（Baklava）——包络振动 API 的起始版本。
 *
 * 刻意用**本地常量**而不是 `Build.VERSION_CODES.BAKLAVA`：常量名随 SDK
 * 预发布状态变动过，写死数字可避免"升级 compileSdk 后编译期找不到符号"。
 */
private const val API_BAKLAVA = 36

/**
 * 声盾原生桥插件。
 *
 * 以 FlutterPlugin 生命周期注册（onAttachedToEngine），因此会被
 * GeneratedPluginRegistrant 注册到【每一个】Flutter 引擎——包括
 * flutter_background_service 创建的后台服务引擎。这解决了此前
 * "MainActivity 只给 UI 引擎注册 handler，后台隔离调用丢失"的缺陷。
 *
 * 通道：sonic_shield/native
 * 能力：精确闹钟（通道B 看门狗）/ 精确闹钟权限引导 / 电池白名单 /
 *       厂商自启动深链 / 震动 / 音量设置 / 找回提示（device.alert）/ 麦克风前台服务 / 开机自启标志。
 */
class NativeBridgePlugin : FlutterPlugin {

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    companion object {
        const val CHANNEL = "sonic_shield/native"
        const val PREFS = "sonic_shield_native"
        const val KEY_SHOULD_RUN = "should_run"
        private const val KEY_ALARMS = "alarm_times"

        /**
         * 启用**代次**（P1-03）。每「停止引擎」自增一次，用来给排定的闹钟打标签：
         * 停止后自增 ⇒ 停止前排出的闹钟全部作废（看门狗接收器逐条核对代次后 no-op）。
         * 只在**关闭**时自增（不在开启时）——因为开机自启 `BootReceiver` 是
         * 先读持久化代次再排 kick 闹钟的，若开启时自增会让刚排的 kick 立刻过期。
         */
        const val KEY_GENERATION = "active_generation"

        /** 闹钟 Intent 携带的代次 extra（与 [KEY_GENERATION] 对照）。 */
        const val EXTRA_GENERATION = "generation"
        private const val TAG = "NativeBridge"

        /**
         * 「性能优先」极致保活档持有的**常驻 PARTIAL_WAKE_LOCK**（进程级单例）。
         *
         * 为什么放 companion object（而非插件实例字段）：插件会被注册到**每一个**
         * Flutter 引擎（UI 引擎 + flutter_background_service 的后台服务引擎），
         * 但二者同属**同一 app 进程** ⇒ 唤醒锁必须进程级唯一，否则会出现
         * "UI 引擎持一把、后台引擎又持一把"，release 时互相看不见、锁泄漏。
         *
         * 语义：**只在电源模式 = performance 时持有**（用户显式选择的取舍）；
         * 目的 = 锁屏 / Doze 下**不让 CPU 休眠**，使通道 A（应用内 Dart Timer）
         * 也能持续运行，而不只依赖通道 B（精确闹钟）。代价 = 持续耗电。
         */
        @Volatile
        private var persistentWakeLock: PowerManager.WakeLock? = null
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                val ctx = appContext ?: binding.applicationContext
                try {
                    when (call.method) {
                        "setExactAlarms" -> {
                            val times =
                                (call.argument<List<*>>("times") ?: emptyList<Any>())
                                    .map { (it as Number).toLong() }
                            // docs/59 缺口1：useAlarmClock=false 时保持旧行为
                            // （setExactAndAllowWhileIdle）；true 走特权通道。
                            val useAlarmClock =
                                call.argument<Boolean>("useAlarmClock") ?: false
                            result.success(
                                scheduleExactAlarms(ctx, times, useAlarmClock))
                        }
                        "standbyBucket" -> result.success(appStandbyBucket(ctx))
                        "clearAlarms" -> {
                            clearExactAlarms(ctx)
                            result.success(true)
                        }
                        "exactAlarmSupported" -> result.success(canScheduleExact(ctx))
                        "openExactAlarmSettings" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                ctx.startActivity(
                                    Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                        .setData(Uri.parse("package:${ctx.packageName}"))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                )
                            }
                            result.success(true)
                        }
                        "isIgnoringBatteryOptimizations" ->
                            result.success(isIgnoringBattery(ctx))
                        "requestIgnoreBatteryOptimizations" -> {
                            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (!pm.isIgnoringBatteryOptimizations(ctx.packageName)) {
                                @Suppress("BatteryLife")
                                ctx.startActivity(
                                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                        .setData(Uri.parse("package:${ctx.packageName}"))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                )
                            }
                            result.success(true)
                        }
                        // ---- 「性能优先」极致保活：常驻唤醒锁 ----
                        "setPersistentWakeLock" -> {
                            val on = call.argument<Boolean>("enabled") == true
                            result.success(setPersistentWakeLock(ctx, on))
                        }
                        // ---- 远程桌面级控制（docs/61）P0 ----
                        // ⚠️ 输入注入是**高危能力**：本桥只做"转发 + 如实回执"；
                        // 授权（MediaProjection 弹窗 / 系统无障碍开关）与权限位
                        // （RcPermGate）在 Dart 端点层把关 —— 桥**不重复判定、也不绕过**。
                        "screenCastStop" -> {
                            // 用**显式组件名**停止 app 级投屏服务，避免插件引用 app 类
                            // （与 AlarmWatchdogReceiver 同一约束/手法）。
                            ctx.stopService(
                                Intent().setClassName(
                                    ctx.packageName,
                                    "com.sonicshield.sonic_shield.ScreenCastService",
                                ),
                            )
                            result.success(true)
                        }
                        "accessibilityEnabled" -> result.success(isAccessibilityEnabled(ctx))
                        "inputTap" -> {
                            val x = call.argument<Number>("x")?.toFloat()
                            val y = call.argument<Number>("y")?.toFloat()
                            val d = call.argument<Number>("durationMs")?.toLong() ?: 0L
                            val f = RemoteInputRegistry.tap
                            result.success(
                                if (f == null || x == null || y == null) false else f(x, y, d)
                            )
                        }
                        "inputSwipe" -> {
                            val x1 = call.argument<Number>("x1")?.toFloat()
                            val y1 = call.argument<Number>("y1")?.toFloat()
                            val x2 = call.argument<Number>("x2")?.toFloat()
                            val y2 = call.argument<Number>("y2")?.toFloat()
                            val d = call.argument<Number>("durationMs")?.toLong() ?: 0L
                            val f = RemoteInputRegistry.swipe
                            result.success(
                                if (f == null || x1 == null || y1 == null ||
                                    x2 == null || y2 == null
                                ) {
                                    false
                                } else {
                                    f(x1, y1, x2, y2, d)
                                }
                            )
                        }
                        "inputKey" -> {
                            val k = call.argument<Number>("keyCode")?.toInt()
                            val f = RemoteInputRegistry.key
                            result.success(if (f == null || k == null) false else f(k))
                        }
                        "inputText" -> {
                            val t = call.argument<String>("text")
                            val f = RemoteInputRegistry.text
                            result.success(if (f == null || t == null) false else f(t))
                        }
                        "screenCaptureOnce" -> {
                            // 抓帧是**异步**的（ImageReader 回调）⇒ `result` 延迟回投；
                            // 未登记（未投屏 / 未授权）⇒ 如实回 null（不静默）。
                            val f = RemoteCaptureRegistry.captureOnce
                            if (f == null) {
                                result.success(null)
                            } else {
                                val timeout =
                                    (call.argument<Number>("timeoutMs"))?.toLong() ?: 5000L
                                f(timeout) { b64 -> result.success(b64) }
                            }
                        }
                        "openOemAutostart" -> {
                            openVendorAutostart(
                                ctx,
                                call.argument<String>("vendor") ?: "generic",
                            )
                            result.success(true)
                        }
                        "vibrate" -> {
                            val pattern =
                                (call.argument<List<*>>("pattern") ?: emptyList<Any>())
                                    .map { (it as Number).toLong() }
                            vibrate(ctx, pattern)
                            result.success(true)
                        }
                        // ---- v1.9 振动能力（docs/20 §5.1）----
                        "vibrateCapabilities" ->
                            result.success(vibrateCapabilities(ctx))
                        "vibrateWaveform" -> {
                            val timings =
                                (call.argument<List<*>>("timings") ?: emptyList<Any>())
                                    .map { (it as Number).toLong() }
                            val amps = call.argument<List<*>>("amplitudes")
                                ?.map { (it as Number).toInt() }
                            val repeat = call.argument<Int>("repeat") ?: -1
                            val alarm = call.argument<Boolean>("useAlarmUsage") ?: false
                            result.success(
                                vibrateWaveform(ctx, timings, amps, repeat, alarm)
                            )
                        }
                        "vibrateEnvelope" -> {
                            val raw = call.argument<List<*>>("points") ?: emptyList<Any>()
                            val pts = raw.mapNotNull { e ->
                                (e as? Map<*, *>)?.let { m ->
                                    mapOf(
                                        "intensity" to (m["intensity"] ?: 0),
                                        "sharpness" to (m["sharpness"] ?: 0),
                                        "durationMs" to (m["durationMs"] ?: 20),
                                    )
                                }
                            }
                            val alarm = call.argument<Boolean>("useAlarmUsage") ?: false
                            result.success(vibrateEnvelope(ctx, pts, alarm))
                        }
                        "vibrateStop" -> {
                            vibrateStop(ctx)
                            result.success(true)
                        }
                        "volume.set" -> {
                            val media = (call.argument<Number>("media"))?.toFloat()
                            val alarm = (call.argument<Number>("alarm"))?.toFloat()
                            result.success(setVolumes(ctx, media, alarm))
                        }
                        // ---- 找回动作（Q9.B，device.alert）----
                        "alert" -> {
                            val msg = call.argument<String>("message") ?: ""
                            result.success(deviceAlert(ctx, msg))
                        }
                        "startMicService" -> {
                            startMicService(ctx)
                            result.success(true)
                        }
                        "stopMicService" -> {
                            ctx.stopService(
                                Intent(ctx, MicGuardService::class.java),
                            )
                            result.success(true)
                        }
                        "setServiceShouldRun" -> {
                            val on = call.argument<Boolean>("value") == true
                            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                            val e = prefs.edit().putBoolean(KEY_SHOULD_RUN, on)
                            // P1-03：关闭时**自增代次**，使停止前排定的闹钟全部作废
                            // （看门狗接收器核对代次后 no-op）；开启时**不动**代次，
                            // 以保证 BootReceiver 先排的 kick 闹钟不会立刻过期。
                            if (!on) e.putInt(KEY_GENERATION, prefs.getInt(KEY_GENERATION, 0) + 1)
                            e.apply()
                            result.success(true)
                        }
                        "getShouldRun" -> result.success(
                            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                                .getBoolean(KEY_SHOULD_RUN, false),
                        )
                        // ---- v1.7 条件层扩展：通话状态 / 网络类型 ----
                        "callState" -> result.success(isInCall(ctx))
                        "networkType" -> result.success(networkType(ctx))
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("NATIVE_ERROR", e.message, null)
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    // ---------- 精确闹钟（通道B 看门狗） ----------

    private fun alarmManager(ctx: Context): AlarmManager =
        ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    private fun canScheduleExact(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            alarmManager(ctx).canScheduleExactAlarms()

    /**
     * 排布精确闹钟并返回**结构化结果**（P1-04）。
     *
     * ⚠️ 旧实现权限不足时直接返回 `0`：Dart 侧只区分「null 回执」与「抛异常」，
     * 把 `0` 当成"排了 0 条"的普通成功 —— 界面继续显示运行中与计划数，而
     * 系统级定时唤醒根本没排上；服务被系统回收后 15s Timer 不能复活进程。
     *
     * 现返回 {expected, scheduled, denied, unsupported, error}：
     * - `denied`：`SCHEDULE_EXACT_ALARM` 未授予（可跳系统设置恢复）；
     * - `unsupported`：平台层面不支持（预留；本分支在 Android 上恒 false）；
     * - `scheduled`：真正排上的条数（逐条 try/catch，失败不再静默吞掉整批）。
     *
     * ## useAlarmClock（2026-10，docs/59 缺口1）
     * 传 true 走 `AlarmManager.setAlarmClock`：系统视为**用户可见闹钟**，
     * Doze/待机深度休眠中准时触发、不受 `setExactAndAllowWhileIdle` 的
     * 「9 分钟最小间隔」限制 —— Doze 中唯一保证准时的公开通道。代价是
     * 状态栏常驻闹钟图标（用户知情契约，与"定时任务对用户可见"一致）。
     * Android 12+ 同受 `canScheduleExactAlarms` 约束（denied 路径不变）；
     * 排布失败逐条回退 setExactAndAllowWhileIdle 并在 error 中说明，
     * 绝不静默假装排上了特权通道。
     */
    private fun scheduleExactAlarms(
        ctx: Context,
        times: List<Long>,
        useAlarmClock: Boolean = false,
    ): Map<String, Any> {
        val result = mutableMapOf<String, Any>(
            "expected" to times.size,
            "scheduled" to 0,
            "denied" to false,
            "unsupported" to false,
        )
        if (!canScheduleExact(ctx)) {
            result["denied"] = true
            return result
        }
        val am = alarmManager(ctx)
        val saved = mutableSetOf<String>()
        var ok = 0
        var error: String? = null
        for (t in times) {
            val pi = watchdogPendingIntent(ctx, t)
            // ⚠️ 守卫必须是 M(23)，**不是** S(31)。
            // `setExactAndAllowWhileIdle` 自 API 23 就可用（已用 SDK 的
            // `platforms/android-36/data/api-versions.xml` 核对：method@23）。
            // 曾按 S 分支 ⇒ API 24–30（Android 7.0–11）静默走 `setExact`，
            // 而 `setExact` 在 Doze 下会被推迟到下一个维护窗口（可能数小时）——
            // 于是"Doze 下可靠唤醒"在低版本上只是文档里的说法（docs/03 §, docs/05 §1.2
            // 都写的是 AllowWhileIdle），实现里并不成立。这是**向下兼容缺口**，不是新特性。
            // else 分支在 minSdk=24 下不可达，保留只为声明"更低的版本只能用 setExact"。
            try {
                if (useAlarmClock) {
                    // 特权通道：setAlarmClock（showIntent=null；状态栏闹钟图标
                    // 即用户可见性契约，不弹界面）。
                    am.setAlarmClock(
                        AlarmManager.AlarmClockInfo(t, null), pi)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, t, pi)
                } else {
                    am.setExact(AlarmManager.RTC_WAKEUP, t, pi)
                }
                saved.add(t.toString())
                ok++
            } catch (e: Exception) {
                // 逐条捕获：一条失败不再吞掉整批，并把原因如实回报给 Dart 侧。
                if (useAlarmClock) {
                    // 特权通道失败 ⇒ 回退常规精确闹钟，并在回执里写明降级
                    // （Dart 侧 alarmDiag 可见），不假装排上了 setAlarmClock。
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            am.setExactAndAllowWhileIdle(
                                AlarmManager.RTC_WAKEUP, t, pi)
                        } else {
                            am.setExact(AlarmManager.RTC_WAKEUP, t, pi)
                        }
                        saved.add(t.toString())
                        ok++
                        error = (error?.plus("；") ?: "") +
                            "setAlarmClock 失败已回退精确闹钟：${e.message}"
                    } catch (e2: Exception) {
                        error = e2.message ?: e2.toString()
                    }
                } else {
                    error = e.message ?: e.toString()
                }
            }
        }
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putStringSet(KEY_ALARMS, saved).apply()
        result["scheduled"] = ok
        if (error != null) result["error"] = error
        return result
    }

    private fun clearExactAlarms(ctx: Context) {
        val am = alarmManager(ctx)
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val saved = prefs.getStringSet(KEY_ALARMS, emptySet()) ?: emptySet()
        for (s in saved) {
            val t = s.toLongOrNull() ?: continue
            am.cancel(watchdogPendingIntent(ctx, t))
        }
        prefs.edit().remove(KEY_ALARMS).apply()
    }

    private fun watchdogPendingIntent(ctx: Context, timeMs: Long): PendingIntent {
        // P1-03：闹钟 Intent 携带**排布时的启用代次**。接收器拉起服务前会把
        // 它与当前持久化代次核对，不一致即 no-op（停止引擎后残留的旧闹钟失效）。
        val gen = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getInt(KEY_GENERATION, 0)
        val intent = Intent(ctx, AlarmWatchdogReceiver::class.java)
            .putExtra("time", timeMs)
            .putExtra(EXTRA_GENERATION, gen)
        val requestCode = ((timeMs / 1000) and 0x7FFFFFFFL).toInt()
        return PendingIntent.getBroadcast(
            ctx, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    // ---------- 环境状态（v1.7 条件层扩展） ----------

    /**
     * 本应用当前的 **App Standby Bucket**（docs/59 缺口2 自检）。
     *
     * 取值：`active` / `working_set` / `frequent` / `rare` / `restricted` /
     * `unknown`。`unknown` = **无法判定**（API<28 / 未授予使用情况访问权 /
     * 平台异常），语义是"读不到"而不是"某种确定状态" —— 与 Dart 侧
     * `isOnWifi()` 返回 null 的先例一致（BUG-041）：不能把读不到当成
     * "rare/restricted"去弹警告，也不能当成"active"假装没问题。
     *
     * 为什么需要它：rare/restricted 桶里，JobScheduler/AlarmManager 任务
     * 会被推迟数小时；app 内无法自提权（`am set-standby-bucket` 需要
     * shell/系统权限），只能**如实告诉用户**并由他跳厂商设置页处理。
     */
    private fun appStandbyBucket(ctx: Context): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return "unknown"
        return try {
            val usm = ctx.getSystemService(Context.USAGE_STATS_SERVICE)
                    as? UsageStatsManager
                ?: return "unknown"
            when (usm.appStandbyBucket) {
                UsageStatsManager.STANDBY_BUCKET_ACTIVE -> "active"
                UsageStatsManager.STANDBY_BUCKET_WORKING_SET -> "working_set"
                UsageStatsManager.STANDBY_BUCKET_FREQUENT -> "frequent"
                UsageStatsManager.STANDBY_BUCKET_RARE -> "rare"
                UsageStatsManager.STANDBY_BUCKET_RESTRICTED -> "restricted"
                else -> "unknown"
            }
        } catch (e: Exception) {
            // 典型：未授予 PACKAGE_USAGE_STATS（appop）时抛 SecurityException。
            // 如实归为 unknown，由调用方按"无法判定"处理，不猜。
            "unknown"
        }
    }

    /**
     * 是否正在通话（含 VoIP / 视频通话）。
     *
     * 用 [AudioManager.getMode] 判定而**不是** TelephonyManager：
     * 读 TelephonyManager 的通话状态需要 READ_PHONE_STATE 运行时权限，
     * 而本应用的原则是最小权限（docs/08）—— 一个"定时放音"工具没有任何理由
     * 申请"读取通话状态与手机身份"。AudioManager 的 mode 是公开 API，
     * **无需任何权限**，且对 VoIP（MODE_IN_COMMUNICATION）同样有效，
     * 覆盖面比只认蜂窝通话的 TelephonyManager 更广。
     *
     * 覆盖：MODE_IN_CALL（蜂窝）、MODE_IN_COMMUNICATION（VoIP/视频）。
     * 不含 MODE_RINGTONE（响铃中）—— 响铃时放音并非有害，且会与铃声混淆，
     * 交由使用者用时段窗口控制。
     */
    private fun isInCall(ctx: Context): Boolean {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        if (am == null) return false
        return am.mode == AudioManager.MODE_IN_CALL ||
            am.mode == AudioManager.MODE_IN_COMMUNICATION
    }

    /**
     * 当前网络类型：wifi / cellular / ethernet / none / other。
     *
     * 需要 ACCESS_NETWORK_STATE（normal 权限，安装即授予，无运行时弹窗）。
     * 用 NetworkCapabilities 判定而不是旧版 `NetworkInfo.getType()`——
     * 后者在 API 29 起已废弃。
     */
    private fun networkType(ctx: Context): String {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager
        if (cm == null) return "unknown"
        val net = cm.activeNetwork
        if (net == null) return "none"
        val caps = cm.getNetworkCapabilities(net)
        if (caps == null) return "unknown"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            else -> "other"
        }
    }

    // ---------- 电池 / 厂商 ----------

    private fun isIgnoringBattery(ctx: Context): Boolean {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(ctx.packageName)
    }

    /**
     * 「性能优先」极致保活档：持有 / 释放**常驻** `PARTIAL_WAKE_LOCK`。
     *
     * 为什么需要它（真机 `shengnong` / Android 16 实测反馈）：锁屏进入 Doze 后，
     * 系统会冻结应用进程的 CPU —— 应用内 Dart Timer（通道 A）随之停摆，只能靠
     * 原生精确闹钟（通道 B）唤醒。若用户希望"锁屏也像前台一样准点"，唯一的
     * 手段是**显式持有唤醒锁**不让 CPU 休眠。这是一个**耗电换可靠**的取舍，
     * 因此只在电源模式 = performance 时由引擎持有（默认 balanced 不持）。
     *
     * `PARTIAL_WAKE_LOCK` 自 API 1 可用（**未废弃** —— 废弃的是
     * `SCREEN_BRIGHT_WAKE_LOCK` / `FULL_WAKE_LOCK`），需要 `WAKE_LOCK` 权限
     * （Manifest 已声明）。**无超时** `acquire()`：由引擎在切档 / 停止时对称
     * `release()`；`setReferenceCounted(false)` + `isHeld` 判重避免重复持锁。
     *
     * 幂等：重复 enable 不会叠加持锁；重复 disable 不抛异常。
     * 返回 true = 调用后处于持锁状态。
     */
    private fun setPersistentWakeLock(ctx: Context, enabled: Boolean): Boolean {
        return try {
            val cur = persistentWakeLock
            if (enabled) {
                if (cur?.isHeld != true) {
                    val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                    val wl = pm.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        "sonic_shield:engine_keepalive",
                    )
                    wl.setReferenceCounted(false)
                    wl.acquire()
                    persistentWakeLock = wl
                }
            } else {
                if (cur?.isHeld == true) cur.release()
                persistentWakeLock = null
            }
            persistentWakeLock?.isHeld == true
        } catch (e: Exception) {
            // 持锁失败不致命（最坏退回"仅通道 B"的默认行为），但要留痕。
            Log.w(TAG, "setPersistentWakeLock failed", e)
            false
        }
    }

    /**
     * 无障碍服务是否已启用（docs/61 P0）。
     *
     * 读 `Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES`（形如
     * `pkg/cls:pkg/cls:…`），比对 app 的 `RemoteInputService` 全名。
     * **只比字符串、不引用 app 类** ⇒ 无跨模块耦合（同 [openVendorAutostart] 的
     * 显式组件名手法）。返回 false = 未开启 ⇒ 调用方须引导用户去系统设置开启。
     */
    private fun isAccessibilityEnabled(ctx: Context): Boolean {
        val expected =
            "${ctx.packageName}/com.sonicshield.sonic_shield.RemoteInputService"
        val enabled = Settings.Secure.getString(
            ctx.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
    }

    private fun openVendorAutostart(ctx: Context, vendor: String) {
        val attempts: List<Intent> = when (vendor) {
            "xiaomi", "redmi" -> listOf(
                Intent().setClassName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                ),
            )
            "huawei", "honor" -> listOf(
                Intent().setClassName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                ),
                Intent().setClassName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity",
                ),
            )
            "oppo", "oneplus", "realme" -> listOf(
                Intent().setClassName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                ),
                Intent().setClassName(
                    "com.oneplus.security",
                    "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
                ),
            )
            "vivo", "iqoo" -> listOf(
                Intent().setClassName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                ),
            )
            "samsung" -> listOf(
                Intent().setClassName(
                    "com.samsung.android.lool",
                    "com.samsung.android.sm.battery.ui.BatteryActivity",
                ),
            )
            "meizu" -> listOf(
                Intent().setClassName("com.meizu.safe", "com.meizu.safe.security.SHOW_APPSEC"),
            )
            else -> emptyList()
        }
        for (i in attempts) {
            try {
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(i)
                return
            } catch (_: Exception) {
                // 该厂商页面不存在则尝试下一个
            }
        }
        ctx.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:${ctx.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    // ---------- 振动（v1.9，docs/20 §5） ----------

    /** 取默认振动器（API 31+ 走 VibratorManager）。 */
    private fun vibratorOf(ctx: Context): Vibrator? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                ?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    } catch (e: Exception) {
        null
    }

    /**
     * 能力探测（FR-38）。
     *
     * ⚠️ `hasAmplitudeControl == false` 时系统会把**所有非零振幅一律当成 100%**
     * （官方文档原文），即"强度设置静默失效"。所以这个值必须如实上报给
     * Dart 侧并由 UI 明示 —— 这是 FR-34 口径从"静默降级"改为"明示降级"的依据。
     */
    @Suppress("DEPRECATION")
    private fun vibrateCapabilities(ctx: Context): Map<String, Any> {
        val v = vibratorOf(ctx)
        val hasVib = try {
            v?.hasVibrator() == true
        } catch (e: Exception) {
            false
        }
        var amp = false
        if (hasVib && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            amp = try {
                v!!.hasAmplitudeControl()
            } catch (e: Exception) {
                false
            }
        }
        var env = false
        var minCp = 20
        if (hasVib && Build.VERSION.SDK_INT >= API_BAKLAVA) {
            try {
                env = v!!.areEnvelopeEffectsSupported()
                // ⚠️ `minControlPointDurationMillis` 是 **Long**（API 36），
                // 而 `minCp` 要作为 Int 进 Map 给 Dart 侧（Dart 按 `num` 收）。
                // 漏了 `.toInt()` 会**编译失败**（BUG-074）—— 而宿主测试不编译
                // Kotlin、`flutter analyze` 也不看 Kotlin，所以这个错误能一路
                // 溜到真机构建才炸。毫秒值远小于 Int.MAX，转换安全。
                minCp = v.envelopeEffectInfo.minControlPointDurationMillis.toInt()
            } catch (e: Exception) {
                env = false
            }
        }
        return mapOf(
            "hasVibrator" to hasVib,
            "hasAmplitudeControl" to amp,
            "hasEnvelope" to env,
            "minControlPointMs" to minCp,
            "platform" to "android",
        )
    }

    /**
     * 振动属性（`AudioAttributes` 形式）的**唯一构造出口**。
     *
     * 官方文档：应用在**后台**发起振动**必须**提供振动属性（以 `AudioAttributes`
     * 形式），因为后台仅支持 attentional haptics；文档示例正是 `USAGE_ALARM`
     * （BUG-069 / docs/20 §2.2-3）。`AudioAttributes` 与
     * `Vibrator.vibrate(long[], int, AudioAttributes)` 都自 **API 21** 可用 ——
     * 所以"低版本"**没有**任何理由丢属性。抽成单一出口是为了让
     * 「API 24/25 的旧重载」与「API 26+ 的 VibrationEffect 重载」**不可能漂移**：
     * 两条路都从这里取属性，改一处即两处生效。
     */
    private fun vibrationAttributes(useAlarm: Boolean): AudioAttributes =
        audioAttributes(
            if (useAlarm) {
                AudioAttributes.USAGE_ALARM
            } else {
                AudioAttributes.USAGE_NOTIFICATION
            }
        )

    /**
     * `AudioAttributes` 的**唯一构造出口**（ATTR-02 锁定）：振动与找回告警的
     * 提示音都从这里取属性，改一处即两处生效，不可能漂移。
     */
    private fun audioAttributes(usage: Int): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(usage)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

    /**
     * 下发效果，**携带振动属性**。
     *
     * ⚠️ BUG-069（docs/20 §2.3）：旧实现一个 attributes 都没传。官方文档明确
     * "当应用处于**后台**时发起振动，**必须**提供振动属性（以 AudioAttributes
     * 形式），因为后台仅支持 attentional haptics"，文档给出的后台示例正是
     * `USAGE_ALARM`。本应用的振动**全部**发生在后台（前台服务 / AlarmManager
     * 驱动），因此必须补上 —— 否则较新 Android 上可能被忽略，
     * 表现为"任务到点了但没震"这种**静默失效**。
     *
     * 三级分级的**真实 API 等级**（已用 SDK `api-versions.xml` 核对，不要凭印象改）：
     * - `vibrate(VibrationEffect, VibrationAttributes)` → **API 33**
     *   （注意：`VibrationAttributes` **类**是 API 30，但该**重载**是 33 —— 不能按 30 放宽）
     * - `vibrate(VibrationEffect, AudioAttributes)` → **API 26**
     * - `vibrate(VibrationEffect)` → **API 26**（裸重载，无属性）
     *
     * 另：`VibrationEffect` 本身是 API 26 起，所以本函数在 API < 26 上**不可达**
     * （调用方已按 SDK 分支，走的是带 `AudioAttributes` 的旧重载）。保留 else 只为
     * 防御性兜底，不构成实际路径。
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun applyEffect(
        ctx: Context,
        effect: VibrationEffect,
        useAlarm: Boolean,
    ): Boolean {
        val v = vibratorOf(ctx) ?: return false
        return try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                    val usage = if (useAlarm) {
                        VibrationAttributes.USAGE_ALARM
                    } else {
                        VibrationAttributes.USAGE_NOTIFICATION
                    }
                    v.vibrate(effect, VibrationAttributes.createForUsage(usage))
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ->
                    v.vibrate(effect, vibrationAttributes(useAlarm))
                else -> {
                    @Suppress("DEPRECATION")
                    v.vibrate(effect)
                }
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 波形振动（`timings` 交替 静止/振动，首元素为起始静止）。
     *
     * [amplitudes] 非空且长度匹配、且设备**真的支持**振幅控制时才走振幅分支 ——
     * 否则传给系统也会被一律拉满，不如显式走 on/off 分支（与能力探测口径一致）。
     */
    private fun vibrateWaveform(
        ctx: Context,
        timings: List<Long>,
        amplitudes: List<Int>?,
        repeat: Int,
        useAlarm: Boolean,
    ): Boolean {
        if (timings.isEmpty()) return false
        val v = vibratorOf(ctx) ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ampOk = amplitudes != null &&
                    amplitudes.size == timings.size &&
                    v.hasAmplitudeControl()
                val eff = if (ampOk) {
                    VibrationEffect.createWaveform(
                        timings.toLongArray(),
                        amplitudes!!.toIntArray(),
                        repeat,
                    )
                } else {
                    VibrationEffect.createWaveform(timings.toLongArray(), repeat)
                }
                applyEffect(ctx, eff, useAlarm)
            } else {
                // API 24/25（Android 7.x）：没有 `VibrationEffect`，只能走旧重载。
                // ⚠️ 但**属性照样要传** —— `vibrate(long[], int, AudioAttributes)`
                // 自 **API 21** 就存在（api-versions.xml: method@21），旧实现却用了
                // 两参重载（无属性），等于把 BUG-069「后台振动必须带属性」在低版本上
                // 又留了一遍。这不是"低版本做不到"，是当时漏了。
                // 另外旧重载**没有振幅**（`amplitudes` 在 API < 26 无法表达），
                // 这条降级由能力探测（`hasAmplitudeControl=false`）如实上报给 Dart 侧。
                @Suppress("DEPRECATION")
                v.vibrate(timings.toLongArray(), repeat, vibrationAttributes(useAlarm))
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 包络振动（Android 16 / API 36）。**不支持时返回 false，不静默降级**。
     *
     * ⚠️ 官方文档硬约束：基础包络效果**必须以 intensity == 0 的控制点结尾**，
     * 否则抛 `IllegalStateException`。Dart 侧已保证，这里再兜一层（双保险）。
     * ⚠️ 系统**不为包络效果提供 fallback** —— 不支持时效果会被**完全忽略**，
     * 所以这里必须显式返回 false 让上层走降级链（docs/20 §5.2）。
     */
    @RequiresApi(API_BAKLAVA)
    private fun vibrateEnvelope(
        ctx: Context,
        points: List<Map<String, Any>>,
        useAlarm: Boolean,
    ): Boolean {
        if (Build.VERSION.SDK_INT < API_BAKLAVA) return false
        if (points.isEmpty()) return false
        val v = vibratorOf(ctx) ?: return false
        return try {
            if (!v.areEnvelopeEffectsSupported()) return false
            val minCp = v.envelopeEffectInfo.minControlPointDurationMillis
                .toLong().coerceAtLeast(1L)
            val builder = VibrationEffect.BasicEnvelopeBuilder()
            var last = 0f
            for (p in points) {
                val intensity =
                    ((p["intensity"] as? Number)?.toFloat() ?: 0f).coerceIn(0f, 1f)
                val sharpness =
                    ((p["sharpness"] as? Number)?.toFloat() ?: 0f).coerceIn(0f, 1f)
                val dur =
                    ((p["durationMs"] as? Number)?.toLong() ?: 20L).coerceAtLeast(minCp)
                builder.addControlPoint(intensity, sharpness, dur)
                last = intensity
            }
            if (last != 0f) builder.addControlPoint(0f, 0f, minCp)
            applyEffect(ctx, builder.build(), useAlarm)
        } catch (e: Exception) {
            false
        }
    }

    /** 停止本应用发起的所有振动（docs/20 §7.2 S3）。 */
    private fun vibrateStop(ctx: Context) {
        try {
            vibratorOf(ctx)?.cancel()
        } catch (e: Exception) {
            // 无振动能力平台：无需处理
        }
    }

    /** v1.x 固定节奏入口（向后兼容）。现已统一走 [vibrateWaveform]（带属性）。 */
    private fun vibrate(ctx: Context, pattern: List<Long>) {
        if (pattern.isEmpty()) return
        vibrateWaveform(ctx, pattern, null, -1, false)
    }

    // ---------- 音量（远程 volume.set，docs/16 §9） ----------

    /**
     * 设置媒体/闹钟音量。入参为 0..1 归一化值，按各流最大音量换算为
     * 绝对档位；只改媒体与闹钟流，不触碰铃声/通知音量（合规边界）。
     * 需要 MODIFY_AUDIO_SETTINGS 权限（Manifest 已声明）。
     */
    private fun setVolumes(ctx: Context, media: Float?, alarm: Float?): Boolean {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        var ok = false
        if (media != null) {
            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            am.setStreamVolume(
                AudioManager.STREAM_MUSIC,
                (media.coerceIn(0f, 1f) * max).roundToInt(),
                0,
            )
            ok = true
        }
        if (alarm != null) {
            val max = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            am.setStreamVolume(
                AudioManager.STREAM_ALARM,
                (alarm.coerceIn(0f, 1f) * max).roundToInt(),
                0,
            )
            ok = true
        }
        return ok
    }

    // ---------- 找回动作（Q9.B，device.alert） ----------

    /**
     * 找回动作：点亮屏幕 → 高优先级通知横幅显示 [message] →
     * 媒体音量置最大并播放约 3 秒提示音。
     *
     * ⚠️ 任何异常都【不得】抛回 Dart 侧：每个子步骤独立 try/catch，
     * 单步失败不影响其余步骤；有任一步成功即返回 true，全部失败返回 false
     * （Log.w 留痕），调用方按 false 走降级链。这与 handler 外层的
     * `catch → result.error` 不同 —— 本方法自己兜底，绝不让原生异常
     * 变成 Dart 侧的 PlatformException。
     *
     * API 等级说明（minSdk 24）：
     * - `SCREEN_BRIGHT_WAKE_LOCK` 自 API 1 可用（API 13 起标记废弃但
     *   功能保留），比 `setTurnScreenOn`（API 27）覆盖面更广，故选它；
     *   需要 WAKE_LOCK 权限（Manifest 已声明）。
     * - `NotificationChannel` 是 API 26 起，按 SDK 分支；API 24/25 走
     *   旧 `Notification.Builder(ctx)` + `setPriority(MAX)`（已废弃，同上 suppress）。
     * - `MediaPlayer.setAudioAttributes` 自 API 21 可用，无版本分支。
     */
    private fun deviceAlert(ctx: Context, message: String): Boolean {
        var ok = false

        // 1. 点亮屏幕：SCREEN_BRIGHT_WAKE_LOCK + ACQUIRE_CAUSES_WAKEUP，
        //    8 秒后自动释放（超时释放是 acquire(long) 的既有语义）。
        try {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (pm != null) {
                @Suppress("DEPRECATION")
                val wl = pm.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "sonic_shield:device_alert",
                )
                wl.acquire(8000L)
                ok = true
            }
        } catch (e: Exception) {
            Log.w(TAG, "deviceAlert: wake screen failed", e)
        }

        // 2. 高优先级通知横幅（带全屏 intent，无权限时系统自动降级为横幅）。
        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            if (nm != null) {
                val chId = "sonic_shield_alert"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            chId,
                            "设备找回提示",
                            NotificationManager.IMPORTANCE_HIGH,
                        ),
                    )
                }
                val openIntent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
                val pi = if (openIntent != null) {
                    PendingIntent.getActivity(
                        ctx, 9001, openIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                } else {
                    null
                }
                val notif: Notification
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val b = Notification.Builder(ctx, chId)
                        .setContentTitle("设备找回")
                        .setContentText(message)
                        .setStyle(Notification.BigTextStyle().bigText(message))
                        .setSmallIcon(ctx.applicationInfo.icon)
                        .setCategory(Notification.CATEGORY_ALARM)
                        .setVisibility(Notification.VISIBILITY_PUBLIC)
                        .setAutoCancel(true)
                    if (pi != null && canUseFullScreenIntent(ctx)) b.setFullScreenIntent(pi, true)
                    notif = b.build()
                } else {
                    @Suppress("DEPRECATION")
                    val b = Notification.Builder(ctx)
                        .setContentTitle("设备找回")
                        .setContentText(message)
                        .setStyle(Notification.BigTextStyle().bigText(message))
                        .setSmallIcon(ctx.applicationInfo.icon)
                        .setPriority(Notification.PRIORITY_MAX)
                        .setCategory(Notification.CATEGORY_ALARM)
                        .setVisibility(Notification.VISIBILITY_PUBLIC)
                        .setAutoCancel(true)
                    if (pi != null && canUseFullScreenIntent(ctx)) b.setFullScreenIntent(pi, true)
                    notif = b.build()
                }
                nm.notify(9001, notif)
                ok = true
            }
        } catch (e: Exception) {
            Log.w(TAG, "deviceAlert: notification failed", e)
        }

        // 3. 请求音频焦点 + 媒体音量临时置最大 + 短提示音；3 秒后**还原音量并释放焦点**。
        //    P2-16：旧实现把媒体音量顶到最大后**从不还原**，也从不申请/释放音频焦点 ——
        //    用户正在外放的音乐被这条提示音打断后无法按焦点规则恢复，且音量被永久改动。
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            var origMusicVolume = -1
            if (am != null) {
                origMusicVolume = am.getStreamVolume(AudioManager.STREAM_MUSIC)
                // MAY_DUCK：允许其它音频压低而非被静音，符合"找回提示"的短促语义。
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    null,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
                )
                am.setStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                    0,
                )
            }
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            if (uri != null) {
                val player = MediaPlayer()
                player.setAudioAttributes(audioAttributes(AudioAttributes.USAGE_MEDIA))
                player.setDataSource(ctx, uri)
                player.prepare()
                player.start()
                Handler(Looper.getMainLooper()).postDelayed({
                    try {
                        player.stop()
                    } catch (_: Exception) {
                    }
                    try {
                        player.release()
                    } catch (_: Exception) {
                    }
                    // 还原用户原音量 + 释放焦点，不把"临时最大"留成副作用。
                    if (am != null) {
                        if (origMusicVolume >= 0) {
                            try {
                                am.setStreamVolume(
                                    AudioManager.STREAM_MUSIC,
                                    origMusicVolume,
                                    0,
                                )
                            } catch (_: Exception) {
                            }
                        }
                        @Suppress("DEPRECATION")
                        try {
                            am.abandonAudioFocus(null)
                        } catch (_: Exception) {
                        }
                    }
                }, 3000L)
                ok = true
            }
        } catch (e: Exception) {
            Log.w(TAG, "deviceAlert: alert tone failed", e)
        }

        return ok
    }

    /**
     * P2-16：API 34（UPSIDE_DOWN_CAKE）起 `setFullScreenIntent` 受
     * `NotificationManager.canUseFullScreenIntent()` 约束 —— 非闹钟/来电类应用
     * 即便声明了 `USE_FULL_SCREEN_INTENT` 也可能被系统/用户关闭。不满足时
     * **不设置全屏 intent**：退回高优先级横幅（渠道已是 IMPORTANCE_HIGH，仍会
     * 抬头提醒），而不是塞一个系统不会兑现的全屏请求 —— 那会让"设备找回"
     * 看起来已全屏、实则只剩一条普通通知。
     *
     * 用数字 34 而非 `VERSION_CODES.UPSIDE_DOWN_CAKE`，与本文件 `API_BAKLAVA`
     * 的既有做法一致，避免 SDK 常量名在不同 compileSdk 下漂移。
     */
    private fun canUseFullScreenIntent(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        return nm?.canUseFullScreenIntent() ?: false
    }

    // ---------- 麦克风前台服务（守卫的 while-in-use 通行证） ----------

    /**
     * 必须由前台 UI（用户点击守卫开关）调用：以前台身份启动 microphone
     * 类型前台服务，为引擎隔离中的 AudioRecord 取得后台麦克风访问权
     * （Android 11+ while-in-use 语义，详见 docs/05 §1.4）。
     */
    private fun startMicService(ctx: Context) {
        ContextCompat.startForegroundService(
            ctx,
            Intent(ctx, MicGuardService::class.java),
        )
    }
}
