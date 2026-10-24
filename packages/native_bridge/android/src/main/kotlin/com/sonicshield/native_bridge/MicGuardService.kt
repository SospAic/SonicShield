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
import android.util.Log
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
 * ## NAT-08（R94）：不返回 START_STICKY
 * microphone 型 FGS 受 while-in-use 约束：**没有前台交互**的后台重启
 * （系统 sticky 复活 / 进程被回收后重建）拿不到前台资格，此时
 * `startForeground(..., MICROPHONE)` 会抛 `SecurityException`
 * （Android 14+ 更严格）⇒ 旧实现返回 START_STICKY 时这就是一条
 * "重启-崩溃"循环。现在：
 * 1. 返回 `START_NOT_STICKY`（与 BackgroundService 一致）—— 服务被杀后
 *    **不自动复活**，这与本类设计意图（通行证必须由前台交互授予）一致；
 * 2. `startForeground` 包 try/catch：拿不到资格时 `stopSelf()` + 留痕，
 *    **不崩进程**；
 * 3. 守卫的恢复路径 = 引擎 bootstrap 显式探测通行证（NAT-03 的
 *    `isMicServiceRunning`）+ 用户回前台重开 —— 而不是 sticky 复活。
 */
class MicGuardService : Service() {

    companion object {
        const val CHANNEL_ID = "sonicshield_mic_guard"
        const val NOTIFICATION_ID = 0x0C1C
        private const val TAG = "MicGuardService"

        /**
         * NAT-03：服务**存活**标志（进程级静态，与插件同进程 ⇒ 权威）。
         *
         * onCreate 置 true、onDestroy 置 false。`NativeBridgePlugin.
         * isMicServiceRunning()` 读它来判断"麦克风通行证在不在"——
         * 引擎 bootstrap 自恢复守卫前的必查项（详见插件侧注释）。
         */
        @Volatile
        var running: Boolean = false
            private set
    }

    override fun onCreate() {
        super.onCreate()
        running = true
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

        // ⚠️ 守卫必须是 R(30)，**不是** Q(29)。
        // `ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE` 的官方起始版本是
        // **API 30**（已用 SDK `platforms/android-36/data/api-versions.xml` 核对：
        // field@30；同批里 LOCATION / DATA_SYNC / MEDIA_PLAYBACK 才是 @29）。
        // 曾按 Q 分支 ⇒ 在 API 29（Android 10）上会向 `startForeground` 传一个
        // 该版本尚不存在的类型位。API 29 本来就没有"麦克风前台服务类型"这个语义
        // （麦克风后台访问的 while-in-use 约束是 Android 11 / API 30 才引入的），
        // 所以低版本走两参重载是**正确**的，不是降级。
        //
        // NAT-08：startForeground 包 try/catch —— 后台重启（无前台交互）时
        // microphone 型 FGS 会被系统拒绝（SecurityException）。此时安静退场
        // （stopSelf + 留痕），绝不让异常逃逸成 FATAL（旧实现会崩进程，
        // 甚至形成"重启-崩溃"循环）。
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(
                TAG,
                "startForeground(microphone) denied (no while-in-use pass): " +
                    "${e.javaClass.simpleName}: ${e.message}",
            )
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        // NAT-08：**不返回 START_STICKY** —— microphone 型 FGS 不具备
        // "无前台交互重启"的资格（见类文档）；恢复依赖 NAT-03 探测 +
        // 用户前台重开。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }
}
