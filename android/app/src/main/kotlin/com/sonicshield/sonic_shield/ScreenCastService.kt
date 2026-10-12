package com.sonicshield.sonic_shield

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import com.sonicshield.native_bridge.RemoteCaptureRegistry
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 远程桌面级控制（docs/25）P0：投屏前台服务（`mediaProjection` 类型）。
 *
 * ⚠️ **本类只做壳**：起停 + 常驻可见通知 + 持有 [MediaProjection]。**画面采集与
 * 传输**（`VirtualDisplay`/`ImageReader` 单帧，或 WebRTC 实时流）属 docs/25 P1/P2，
 * 未实现前**不得冒充完成**（本类不含任何采集/编码/发送代码）。
 *
 * ## Android 14+ 纪律（docs/24 阶段0）
 * **必须先**由 Activity 走 `createScreenCaptureIntent()` 拿到用户同意的
 * `resultCode` + `data`（授权弹窗是唯一的授权入口），**再**以
 * `FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION` 调 `startForeground`；顺序反了直接
 * `SecurityException`。因此本服务**拒绝**在缺少授权 token 时启动 —— 这是
 * "不可绕过授权"红线的机器锁（docs/25 §1、G2）。
 *
 * ## 可见性红线
 * 会话期间常驻通知（`setOngoing(true)`）在**任何像素出屏之前**就必须存在；
 * 停止时移除。端点用户任何时候都能停（本服务 ACTION_STOP）。
 */
class ScreenCastService : Service() {

    private var projection: MediaProjection? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                @Suppress("DEPRECATION")
                val data = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
                if (data == null) {
                    // 没有用户同意的 token ⇒ 拒绝启动（授权前置的机器锁）。
                    Log.w(TAG, "缺少 MediaProjection 授权 token，拒绝启动投屏服务")
                    stopSelf()
                    return START_NOT_STICKY
                }
                startForegroundWithNotification()
                val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                projection = mpm.getMediaProjection(resultCode, data)
                // P1：把「抓一帧」登记进**插件侧**注册表（依赖方向 app → native_bridge）。
                RemoteCaptureRegistry.captureOnce = { timeoutMs, cb ->
                    captureOnce(timeoutMs, cb)
                }
                Log.i(TAG, "投屏服务已启动（P0 壳 + P1 单帧抓取已登记）")
            }
            ACTION_STOP -> stopCast()
            else -> {
                // 无 action 的（系统恢复）启动不持有 token ⇒ 直接停，不留僵尸通知。
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    private fun startForegroundWithNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "屏幕共享",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { description = "远程桌面级控制会话期间常驻（可见性红线）" },
            )
        }
        val notif: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.screen_cast_notification_title))
            .setContentText(getString(R.string.screen_cast_notification_text))
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun stopCast() {
        try {
            projection?.stop()
        } catch (_: Exception) {
        }
        projection = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        RemoteCaptureRegistry.captureOnce = null
        try {
            projection?.stop()
        } catch (_: Exception) {
        }
        projection = null
        super.onDestroy()
    }

    /**
     * 抓**一帧**屏幕，返回 JPEG 的 base64（docs/24 阶段 1 / docs/25 P1）。
     *
     * 复用 P0 已持有的 [projection]（MediaProjection 授权已在 P0 取得，**不重复弹窗**）。
     * 链路：`VirtualDisplay` → `ImageReader(RGBA_8888)` → `Bitmap`（按 rowStride 去 padding）
     * → 裁剪到真实宽高 → JPEG(70) → base64。
     *
     * **如实失败**：未授权 / 超时 / 任何异常 ⇒ `callback(null)`（调用方据此回
     * `rc.ack{ok:false}`，**不静默**）。`timeoutMs` 是硬兜底，绝不挂住调用方。
     *
     * 回调在**主线程**（`ImageReader` 用主 Looper 的 Handler）。
     */
    fun captureOnce(timeoutMs: Long, callback: (String?) -> Unit) {
        val mp = projection
        if (mp == null) {
            callback(null)
            return
        }
        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi
        val done = AtomicBoolean(false)
        var reader: ImageReader? = null
        var vd: VirtualDisplay? = null

        fun finish(b64: String?) {
            if (!done.compareAndSet(false, true)) return
            try {
                vd?.release()
            } catch (_: Exception) {
            }
            try {
                reader?.close()
            } catch (_: Exception) {
            }
            callback(b64)
        }

        try {
            val r = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
            reader = r
            vd = mp.createVirtualDisplay(
                "sonicshield-capture",
                width,
                height,
                density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                r.surface,
                null,
                null,
            )
            r.setOnImageAvailableListener({ ir ->
                try {
                    val image = ir.acquireLatestImage()
                    if (image == null) {
                        finish(null)
                        return@setOnImageAvailableListener
                    }
                    val plane = image.planes[0]
                    val pixelStride = plane.pixelStride
                    val rowStride = plane.rowStride
                    val rowPadding = rowStride - pixelStride * width
                    // ⚠️ ImageReader 的 buffer 含 rowStride padding：必须按 padding
                    // 建图再裁剪，否则图像会**横向错位**（经典坑）。
                    val padded = Bitmap.createBitmap(
                        width + rowPadding / pixelStride, height, Bitmap.Config.ARGB_8888,
                    )
                    padded.copyPixelsFromBuffer(plane.buffer)
                    val cropped = Bitmap.createBitmap(padded, 0, 0, width, height)
                    val baos = ByteArrayOutputStream()
                    cropped.compress(Bitmap.CompressFormat.JPEG, 70, baos)
                    image.close()
                    padded.recycle()
                    cropped.recycle()
                    finish(Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP))
                } catch (e: Exception) {
                    Log.w(TAG, "captureOnce: decode failed", e)
                    finish(null)
                }
            }, Handler(Looper.getMainLooper()))
            // 硬超时兜底：宁可失败，也不让调用方永久等待。
            Handler(Looper.getMainLooper()).postDelayed({ finish(null) }, timeoutMs)
        } catch (e: Exception) {
            Log.w(TAG, "captureOnce failed", e)
            finish(null)
        }
    }

    companion object {
        private const val TAG = "ScreenCastService"
        const val ACTION_START = "com.sonicshield.screen.START"
        const val ACTION_STOP = "com.sonicshield.screen.STOP"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        private const val CHANNEL_ID = "sonicshield_screencast"
        private const val NOTIF_ID = 0x5C0DE
    }
}
