package com.sonicshield.sonic_shield

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.sonicshield.native_bridge.AlarmWatchdogReceiver
import com.sonicshield.native_bridge.NativeBridgePlugin
import com.sonicshield.native_bridge.SelfHealNotice

/**
 * 开机自启：仅当用户此前显式开启过守护（should_run 标志）时恢复引擎。
 * MY_PACKAGE_REPLACED：应用升级后同样恢复，保证 7×24 场景。
 *
 * ## F-3 方案①（第 70 轮）：不再直接拉起前台服务，改排一次性精确闹钟
 *
 * 旧实现直接 `startForegroundService`，在 Android 12+ 会因「后台启动前台服务」
 * 限制、在 Android 15+（targetSdk 35+）还会因「BOOT_COMPLETED 不得启动
 * mediaPlayback / dataSync 等类型 FGS」而被拒，抛
 * `ForegroundServiceStartNotAllowedException` —— 引擎在开机后**永远起不来**。
 *
 * 现改为排一个 [KICK_DELAY_MS] 后的一次性**精确闹钟**，由插件侧既有的
 * [AlarmWatchdogReceiver] 拉起引擎。精确闹钟广播是上述两条限制的**豁免路径**
 * （与 `NativeBridgePlugin.scheduleExactAlarms` 同法，见 `NativeBridgePlugin.kt:231`）。
 *
 * 降级：Android 12+ 未授予 `SCHEDULE_EXACT_ALARM` 时退到非精确闹钟
 * （`setAndAllowWhileIdle`，无需该权限）。该降级路径的 FGS 启动是否同样被
 * 系统豁免**未单独实测**；若引擎仍起不来，由 [AlarmWatchdogReceiver]
 * 按 F-3/N-3 显式留痕告知用户（不静默失败）。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return

        val prefs = context.getSharedPreferences(
            NativeBridgePlugin.PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(NativeBridgePlugin.KEY_SHOULD_RUN, false)) return

        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val at = System.currentTimeMillis() + KICK_DELAY_MS
            val pi = PendingIntent.getBroadcast(
                context,
                KICK_REQUEST_CODE,
                Intent(context, AlarmWatchdogReceiver::class.java)
                    .putExtra("time", at)
                    // P1-03：kick 闹钟必须携带**当前持久化代次**，否则看门狗接收器
                    // 会把它当成旧代次闹钟而 no-op —— 开机自启会静默失效。
                    // 代次只在停止引擎时自增，故开机时它恰好等于"当前启用代次"。
                    .putExtra(
                        NativeBridgePlugin.EXTRA_GENERATION,
                        prefs.getInt(NativeBridgePlugin.KEY_GENERATION, 0),
                    ),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            // canScheduleExactAlarms 是 API 31(S) 起；低版本恒为可授权。
            if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S ||
                am.canScheduleExactAlarms()
            ) {
                // 守卫必须 M(23)：setExactAndAllowWhileIdle 自 API 23 起可用
                // （api-versions.xml: method@23）；而 setExact 在 Doze 下会被推迟到
                // 下一个维护窗口（可能数小时），不能用于"开机即恢复"。
                // minSdk=24 ⇒ else 分支不可达，保留只为声明更低版本只能用 setExact。
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
                } else {
                    am.setExact(AlarmManager.RTC_WAKEUP, at, pi)
                }
            } else {
                Log.w(TAG, "exact alarm not permitted, degrade to inexact kick")
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            }
        } catch (e: Exception) {
            // 排程失败（权限拒绝 / 平台限制）**不得静默**（F-3 / N-3）：
            // 除 logcat 外再留一条用户可见通知，让"开机自启排程失败"能被看见，
            // 而不是用户以为守护还在、实际开机后引擎根本没起来。
            Log.w(TAG, "boot kick blocked: ${e.message}")
            SelfHealNotice.failed(context, "开机自启排程被系统拒绝：${e.message}")
        }
    }

    companion object {
        private const val TAG = "BootReceiver"

        /**
         * 开机与踢醒闹钟之间的延迟 —— **必须大于 BOOT_COMPLETED 的临时白名单窗口（20s）**。
         *
         * ⚠️ 实测取证（API 36 模拟器，adbd 已把应用移出电池白名单、插件自带开机
         * 自启已关，即最严苛条件）：
         *
         * 1. BOOT_COMPLETED 送达时，系统给应用开一个 **20 秒**的临时白名单
         *    （logcat：`tempAllowListReason:<...BOOT_COMPLETED,duration:20000>`）。
         * 2. 若踢醒闹钟在该窗口内触发，FGS 启动会被**归因回 `code:BOOT_COMPLETED`**
         *    （而非 `ALARM_MANAGER_WHILE_IDLE`）⇒ 仍撞上 Android 15+
         *    「BOOT_COMPLETED 不得启动 mediaPlayback 型 FGS」的禁令 ⇒ 抛
         *    `ForegroundServiceStartNotAllowedException`，进程崩溃并反复重启
         *    （实测：10s 延迟**必崩**，5554/5556 均复现）。
         * 3. 闹钟在窗口**之后**触发时，归因才是 `code:ALARM_MANAGER_WHILE_IDLE`
         *    （归到 AlarmWatchdogReceiver 这条 Intent）⇒ 绕开禁令，引擎正常拉起
         *    （实测：30s 延迟成功，`isForeground=true types=0x00000002`）。
         *
         * 故取 30s（20s 窗口 + 10s 余量）。这是"合法绕过"的关键，不能缩短。
         */
        private const val KICK_DELAY_MS = 30_000L
        private const val KICK_REQUEST_CODE = 0x0B07
    }
}