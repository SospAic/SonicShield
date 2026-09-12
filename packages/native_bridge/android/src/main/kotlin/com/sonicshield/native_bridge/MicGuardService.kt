package com.sonicshield.native_bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 守卫麦克风前台服务：仅持有「麦克风访问通行证」，不做任何工作。
 *
 * Android 11+ 的 while-in-use 语义要求：应用在后台使用麦克风，必须存在
 * 一个由【前台交互】启动的 microphone 类型前台服务。用户在 UI 点击
 * 守卫开关 → NativeBridgePlugin.startMicService()（前台）→ 本服务以
 * FOREGROUND_SERVICE_TYPE_MICROPHONE 进入前台 → 引擎隔离中的
 * AudioRecord（record 插件）此后在后台合法可用。
 *
 * 服务被杀后不会被自动复活（平台语义）：守卫降级为仅前台可用，
 * 并在 UI 上明示（docs/05 §1.4 / docs/08）。
 */
class MicGuardService : Service() {

    companion object {
        const val CHANNEL_ID = "sonicshield_mic_guard"
        const val NOTIFICATION_ID = 0x0C1C
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "声音守卫",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "守卫模式运行中，状态栏显示麦克风图标"
                },
            )
        }
        val notification: Notification =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentTitle("声盾 · 声音守卫")
                .setContentText("正在监听声音事件（仅本地处理，不上传）")
                .setOngoing(true)
                .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }
}
