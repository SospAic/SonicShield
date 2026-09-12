package com.sonicshield.sonic_shield

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import id.flutter.flutter_background_service.BackgroundService

/**
 * 开机自启：仅当用户此前显式开启过守护（should_run 标志）时恢复前台服务。
 * MY_PACKAGE_REPLACED：应用升级后同样恢复，保证 7×24 场景。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return

        val shouldRun = context.getSharedPreferences("sonic_shield_native", Context.MODE_PRIVATE)
            .getBoolean("should_run", false)
        if (!shouldRun) return

        try {
            val svc = Intent(context, BackgroundService::class.java)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                context.startForegroundService(svc)
            } else {
                context.startService(svc)
            }
        } catch (e: Exception) {
            // 平台限制（如 Android 15 对 BOOT_COMPLETED 的类型约束）时静默：
            // 用户打开 App 后引擎自动恢复。
            Log.w(TAG, "boot restart blocked: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "BootReceiver"
    }
}
