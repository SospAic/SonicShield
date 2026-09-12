package com.sonicshield.native_bridge

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
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
 *       厂商自启动深链 / 震动 / 麦克风前台服务 / 开机自启标志。
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
