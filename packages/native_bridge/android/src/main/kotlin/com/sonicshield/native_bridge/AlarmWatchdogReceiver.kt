package com.sonicshield.native_bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * 通道B 看门狗：精确闹钟触发 → 拉起主前台服务（引擎隔离）。
 * occurrences 表状态机保证双通道入口幂等（docs/04 §5）。
 *
 * 用显式组件名启动 flutter_background_service 的服务，避免对 app
 * 依赖的编译期耦合（本地插件无法引用 app 级依赖的类）。
 */
class AlarmWatchdogReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        // P1-03：停止守护后残留的精确闹钟**不得**再把引擎拉起来（否则引擎"关不掉"）。
        // 双保险：① `should_run` 已是持久化的权威开关；② 代次核对兜住"关闭→重启"
        // 竞态（停止时 `setServiceShouldRun(false)` 自增代次，停止前排出的闹钟全部作废）。
        val prefs = context.getSharedPreferences(
            NativeBridgePlugin.PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(NativeBridgePlugin.KEY_SHOULD_RUN, false)) return
        val gen = intent.getIntExtra(NativeBridgePlugin.EXTRA_GENERATION, -1)
        if (gen != prefs.getInt(NativeBridgePlugin.KEY_GENERATION, 0)) return
        try {
            val svc = Intent()
                .setClassName(context, "id.flutter.flutter_background_service.BackgroundService")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(svc)
            } else {
                context.startService(svc)
            }
        } catch (e: Exception) {
            // 平台限制下可能被拒；下一轮闹钟/用户打开 App 自愈。
            // 但**不得静默**（N-3）：除 logcat 外再留一条用户可见通知，
            // 否则"引擎未能自恢复"只进 logcat，用户与审计都看不见。
            Log.w("AlarmWatchdog", "kick failed: ${e.message}")
            SelfHealNotice.failed(context, "看门狗闹钟未能拉起引擎：${e.message}")
        }
    }
}
