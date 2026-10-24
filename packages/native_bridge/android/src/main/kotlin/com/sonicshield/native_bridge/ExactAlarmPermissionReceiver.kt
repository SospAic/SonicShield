package com.sonicshield.native_bridge

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * P2-33：精确闹钟权限**重新授予**后的自动重排。
 *
 * ## 为什么需要
 *
 * 用户在系统设置里撤销「闹钟和提醒」授权时，系统会**取消该应用所有未来的精确闹钟**；
 * 之后即使再次授予，已排的闹钟也不会自动恢复 —— 引擎若仍在跑，就会一直处于
 * "计划看着有、系统级唤醒为空集"的降级态，直到用户手动重开引擎。旧实现只监听
 * `BOOT_COMPLETED` 等开机事件（见 `BootReceiver.kt`），**没有**处理
 * `ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`。
 *
 * ## 行为（只重排、不滥用 FGS）
 *
 * - 仅在 `serviceShouldRun == true`（用户显式开启过守护）时才动作；用户关着引擎
 *   就不排、更不拉起前台服务。
 * - 不在接收器里**直接** `startForegroundService`：从普通广播后台启动
 *   `mediaPlayback` 型 FGS 在 Android 12+ 会被 `ForegroundServiceStartNotAllowedException`
 *   拒绝（只有闹钟/闹钟豁免路径才放行）。因此改用与 `BootReceiver` 相同的
 *   **一次性精确闹钟**踢醒 [AlarmWatchdogReceiver] —— 权限刚恢复，`setExactAndAllowWhileIdle`
 *   必然可用；由看门狗在豁免归因下启动引擎，引擎启动即重建计划与闹钟。
 *
 * ⚠️ 行为验证需 API 31+ 设备：撤销 → 重授予 → 不手动重开即恢复排布。
 * 宿主门禁不构建/运行 Android，故本条**未在真机/模拟器实测**（BLOCKED）。
 */
class ExactAlarmPermissionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        // 系统只在**授予**该权限时派发本 action（撤销不派发），故此处按恢复处理。
        if (intent.action != ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED) return

        val prefs = context.getSharedPreferences(
            NativeBridgePlugin.PREFS, Context.MODE_PRIVATE)
        // 引擎本就不该跑（用户关闭了守护）⇒ 不重排、不拉起 FGS。
        if (!prefs.getBoolean(NativeBridgePlugin.KEY_SHOULD_RUN, false)) return

        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val at = System.currentTimeMillis() + KICK_DELAY_MS
            val pi = PendingIntent.getBroadcast(
                context,
                KICK_REQUEST_CODE,
                Intent(context, AlarmWatchdogReceiver::class.java)
                    .putExtra("time", at)
                    // 与 BootReceiver 同款：携带**当前持久化代次**，否则看门狗
                    // 会把它当旧代次闹钟而 no-op，重排静默失效（P1-03）。
                    .putExtra(
                        NativeBridgePlugin.EXTRA_GENERATION,
                        prefs.getInt(NativeBridgePlugin.KEY_GENERATION, 0),
                    ),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            // 权限刚恢复 ⇒ 精确闹钟可用；低版本恒可授权（canScheduleExactAlarms 自 S 起）。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } else {
                am.setExact(AlarmManager.RTC_WAKEUP, at, pi)
            }
        } catch (e: Exception) {
            // 排程失败不得静默（N-3/F-3）：除 logcat 外留一条用户可见通知。
            Log.w(TAG, "exact-alarm re-grant kick blocked: ${e.message}")
            SelfHealNotice.failed(context, "精确闹钟授权恢复后重排失败：${e.message}")
        }
    }

    companion object {
        private const val TAG = "ExactAlarmGrant"

        /** `AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`（API 31）的字面量。 */
        const val ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED =
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"

        /**
         * 权限恢复广播 → kick 闹钟的延迟 —— **必须与 app 侧 `BootReceiver` 的
         * 30s 归因窗口对齐**（NAT-17）。
         *
         * ⚠️ 旧值 1s 的注释假设"权限刚恢复、无需等待白名单窗口"——**未实测**。
         * BootReceiver 在 API 36 模拟器上实测取证：系统给广播源开 **20s** 临时
         * 白名单，窗口内触发的 FGS 启动会被**归因回广播源**（而非
         * ALARM_MANAGER_WHILE_IDLE）⇒ 撞上"广播源不得启动 mediaPlayback 型
         * FGS"的禁令 ⇒ `ForegroundServiceStartNotAllowedException`（10s 延迟
         * 必崩，30s 成功，见 BootReceiver.KICK_DELAY_MS 的完整取证注释）。
         * 本接收器同样是"广播 → 排闹钟 → 看门狗拉 FGS"的同一形状，若 1s 就
         * 触发，kick 仍在该广播的归因窗口内 ⇒ 同样可能被拒（被拒时
         * AlarmWatchdogReceiver 会 SelfHealNotice，不静默，但**功能失效**）。
         * 故取 30s（20s 窗口 + 10s 余量）：宁可让自动重排晚半分钟，也不要
         * 一条看着排上、实则拉不起的假路径。
         */
        private const val KICK_DELAY_MS = 30_000L
        private const val KICK_REQUEST_CODE = 0x0E47
    }
}