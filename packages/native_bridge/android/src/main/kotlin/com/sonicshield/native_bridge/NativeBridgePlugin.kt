package com.sonicshield.native_bridge

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

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

    // ---------- 震动 ----------

    @Suppress("DEPRECATION")
    private fun vibrate(ctx: Context, pattern: List<Long>) {
        val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vm = ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vm.defaultVibrator
        } else {
            ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(pattern.toLongArray(), -1))
        } else {
            vibrator.vibrate(pattern.toLongArray(), -1)
        }
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
