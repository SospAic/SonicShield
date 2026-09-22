package com.sonicshield.native_bridge

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
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
 *       厂商自启动深链 / 震动 / 音量设置 / 麦克风前台服务 / 开机自启标志。
 */
class NativeBridgePlugin : FlutterPlugin {

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    companion object {
        const val CHANNEL = "sonic_shield/native"
        private const val PREFS = "sonic_shield_native"
        private const val KEY_SHOULD_RUN = "should_run"
        private const val KEY_ALARMS = "alarm_times"
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
                            result.success(scheduleExactAlarms(ctx, times))
                        }
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
                            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                                .edit()
                                .putBoolean(
                                    KEY_SHOULD_RUN,
                                    call.argument<Boolean>("value") == true,
                                )
                                .apply()
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

    private fun scheduleExactAlarms(ctx: Context, times: List<Long>): Int {
        if (!canScheduleExact(ctx)) return 0
        val am = alarmManager(ctx)
        val saved = mutableSetOf<String>()
        var ok = 0
        for (t in times) {
            val pi = watchdogPendingIntent(ctx, t)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, t, pi)
            } else {
                am.setExact(AlarmManager.RTC_WAKEUP, t, pi)
            }
            saved.add(t.toString())
            ok++
        }
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putStringSet(KEY_ALARMS, saved).apply()
        return ok
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
        val intent = Intent(ctx, AlarmWatchdogReceiver::class.java)
            .putExtra("time", timeMs)
        val requestCode = ((timeMs / 1000) and 0x7FFFFFFFL).toInt()
        return PendingIntent.getBroadcast(
            ctx, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    // ---------- 环境状态（v1.7 条件层扩展） ----------

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
     * 下发效果，**携带振动属性**。
     *
     * ⚠️ BUG-069（docs/20 §2.3）：旧实现一个 attributes 都没传。官方文档明确
     * "当应用处于**后台**时发起振动，**必须**提供振动属性（以 AudioAttributes
     * 形式），因为后台仅支持 attentional haptics"，文档给出的后台示例正是
     * `USAGE_ALARM`。本应用的振动**全部**发生在后台（前台服务 / AlarmManager
     * 驱动），因此必须补上 —— 否则较新 Android 上可能被忽略，
     * 表现为"任务到点了但没震"这种**静默失效**。
     */
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
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                    val attrs = AudioAttributes.Builder()
                        .setUsage(
                            if (useAlarm) {
                                AudioAttributes.USAGE_ALARM
                            } else {
                                AudioAttributes.USAGE_NOTIFICATION
                            }
                        )
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                    v.vibrate(effect, attrs)
                }
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
                @Suppress("DEPRECATION")
                v.vibrate(timings.toLongArray(), repeat)
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
