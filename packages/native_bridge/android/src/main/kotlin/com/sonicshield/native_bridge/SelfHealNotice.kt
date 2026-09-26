package com.sonicshield.native_bridge

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * 自恢复失败留痕（F-3 / N-3，SEC1 第 35 轮）。
 *
 * 开机自启（app 模块 BootReceiver）与看门狗闹钟（本插件 AlarmWatchdogReceiver）
 * 都要拉起 flutter_background_service 的前台服务。Android 15+ 在
 * BOOT_COMPLETED / 后台启动时会对若干 FGS 类型直接抛
 * ForegroundServiceStartNotAllowedException（mediaPlayback / dataSync 都在
 * 禁令内）—— 以前这两处只写 logcat，用户与审计都看不见，
 * 于是"开机自恢复"成了一句静默失效的承诺。
 *
 * 这里复用本插件既有的用户可见通道（与 MicGuardService /
 * NativeBridgePlugin.deviceAlert 同法：NotificationChannel +
 * NotificationCompat），不新增机制。
 *
 * ⚠️ 通知是"尽力而为"：Android 13+ 用户拒绝 POST_NOTIFICATIONS 时系统会
 * 静默丢弃通知。因此调用方**必须**同时保留自己的 Log.w 日志 ——
 * 本方法也会再写一条，保证即使调用方漏了也有痕。
 */
object SelfHealNotice {

    private const val TAG = "SelfHealNotice"
    private const val CHANNEL_ID = "sonicshield_self_heal"
    private const val NOTIFICATION_ID = 0x0C1F

    /** 记一条 logcat + 发一条"引擎未能自恢复"通知；本身绝不抛。 */
    fun failed(context: Context, reason: String) {
        Log.w(TAG, "self-heal blocked: $reason")
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as? NotificationManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "后台自恢复",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply { description = "引擎未能自恢复时的提示" },
                )
            }
            val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentTitle("声盾 · 引擎未能自恢复")
                .setContentText(reason)
                .setStyle(NotificationCompat.BigTextStyle().bigText(reason))
                .setAutoCancel(true)
            if (open != null) {
                builder.setContentIntent(
                    PendingIntent.getActivity(
                        context,
                        NOTIFICATION_ID,
                        open,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }
            nm.notify(NOTIFICATION_ID, builder.build())
        } catch (e: Exception) {
            // 通知本身失败（POST_NOTIFICATIONS 被拒 / 系统限制）：调用方已写 logcat。
            Log.w(TAG, "self-heal notice failed: ${e.message}")
        }
    }
}
