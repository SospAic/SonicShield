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
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import com.sonicshield.native_bridge.RemoteCaptureRegistry
import java.io.ByteArrayOutputStream

/**
 * 远程桌面级控制（docs/61）P0：投屏前台服务（`mediaProjection` 类型）。
 *
 * ⚠️ **本类只做壳**：起停 + 常驻可见通知 + 持有 [MediaProjection]，外加
 * docs/24 阶段 1 的**单帧抓取**。**画面传输**（WebRTC 实时流）属 P1/P2，
 * 未实现前**不得冒充完成**。
 *
 * ## Android 14+ 纪律（docs/24 阶段0）
 * **必须先**由 Activity 走 `createScreenCaptureIntent()` 拿到用户同意的
 * `resultCode` + `data`（授权弹窗是唯一的授权入口），**再**以
 * `FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION` 调 `startForeground`；顺序反了直接
 * `SecurityException`。因此本服务**拒绝**在缺少授权 token 时启动 —— 这是
 * "不可绕过授权"红线的机器锁（docs/61 §1、G2）。
 *
 * ## NAT-01（2026-10，R94）：Android 14+ 抓帧契约
 * 1. **`createVirtualDisplay` 之前必须先 `registerCallback`** —— API 34+
 *    未注册回调时 `createVirtualDisplay` 直接抛 `IllegalStateException`
 *    （官方行为变更原文）。本服务在拿到 [MediaProjection] 的**第一时间**
 *    注册，`onStop` 里退场（用户从系统 UI 撤销投屏 ⇒ 镜像会话已死）。
 * 2. **抓帧模型 = 一次 VD、多次读帧**：官方规定**同一 `MediaProjection`
 *    实例只能调用一次 `createVirtualDisplay`**（第二次抛 `SecurityException`），
 *    因此 `VirtualDisplay` + `ImageReader` 在 [ACTION_START] 时**长驻**，
 *    [captureOnce] 只读"最近一帧"（ listener 持续用最新帧替换旧帧）。
 *    旧实现"每次抓帧复用 `projection.createVirtualDisplay`"在 Android 14+
 *    上**必然失败**（第一条）+ 第二次抓帧也必失败（第二条）。
 * 3. 抓帧失败**带异常类型名**回传（`CAPTURE_FAILED`），不再只回 null ——
 *    否则审计分不清 `IllegalStateException`（契约违例）/ `SecurityException`
 *    （授权丢失）/ 超时。
 *
 * ## 可见性红线
 * 会话期间常驻通知（`setOngoing(true)`）在**任何像素出屏之前**就必须存在；
 * 停止时移除。端点用户任何时候都能停（本服务 ACTION_STOP）。
 */
class ScreenCastService : Service() {

    private var projection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null

    /** 长驻的镜像显示与取帧器（NAT-01：一次 VD、多次读帧）。 */
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null

    /** 取帧线程：ImageReader 回调走后台线程，不占主线程（60fps 帧到达）。 */
    private var readerThread: HandlerThread? = null
    private var readerHandler: Handler? = null

    /** [frameLock] 保护的最近一帧（listener 持续替换；抓帧只读不关）。 */
    private val frameLock = Any()
    private var latestImage: Image? = null

    /** 服务正在退场（stopCast 已执行）：抓帧轮询据此提前收手。 */
    private var stopping = false

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
                // R98：`getMediaProjection` 返回**可空**（token 失效 / 系统拒绝时给 null）。
                // 旧代码直接 `mp.registerCallback(...)` ⇒ 编译期即报「nullable receiver」。
                // 与上面 `data == null` 同语义：没有可用 projection 就拒绝启动，不留僵尸通知。
                val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                val mp = mpm.getMediaProjection(resultCode, data)
                if (mp == null) {
                    Log.w(TAG, "getMediaProjection 返回空（授权 token 失效），拒绝启动投屏服务")
                    stopSelf()
                    return START_NOT_STICKY
                }
                startForegroundWithNotification()
                projection = mp
                // NAT-01①：Android 14+ 硬性契约 —— createVirtualDisplay 之前
                // **必须** registerCallback，否则抛 IllegalStateException。
                // R98：`MediaProjection.Callback` 是 Java 抽象类、带隐式无参构造器
                // ⇒ Kotlin 必须写 `Callback()`，漏括号编译期报
                // 「This type has a constructor, so it must be initialized here」。
                val cb = object : MediaProjection.Callback() {
                    override fun onStop() {
                        // 用户从系统 UI（通知栏"停止共享"等）撤销投屏 ⇒ 镜像
                        // 会话已死，本服务没有存在意义，干净退场。
                        Log.i(TAG, "MediaProjection onStop：用户撤销投屏，服务退场")
                        stopCast()
                    }
                }
                projectionCallback = cb
                mp.registerCallback(cb, Handler(Looper.getMainLooper()))
                // NAT-01②：VD + ImageReader 长驻（见类文档）：建好后抓帧只读帧。
                if (!startVirtualDisplay()) {
                    Log.w(TAG, "VirtualDisplay 建立失败，投屏服务退场")
                    stopCast()
                    return START_NOT_STICKY
                }
                // P1：把「抓一帧」登记进**插件侧**注册表（依赖方向 app → native_bridge）。
                RemoteCaptureRegistry.captureOnce = { timeoutMs, cb ->
                    captureOnce(timeoutMs, cb)
                }
                Log.i(TAG, "投屏服务已启动（registerCallback + VD 长驻多次读帧）")
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

    /**
     * 建立**长驻**的 [VirtualDisplay] + [ImageReader]（NAT-01）。
     *
     * ImageReader 的后台 listener 持续用最新帧**替换**旧帧（旧帧 close），
     * 于是"拍一张"在**静止画面**上也能立刻拿到最近一帧（镜像只在内容变化时
     * 产帧，不能守候"下一帧"——那会在静止屏幕上挂到超时）。
     * 返回值 false = 建立失败（调用方退场，不留下"服务在跑但抓不到帧"的僵尸态）。
     */
    private fun startVirtualDisplay(): Boolean = try {
        val metrics = resources.displayMetrics
        val reader = ImageReader.newInstance(
            metrics.widthPixels, metrics.heightPixels, PixelFormat.RGBA_8888, 2,
        )
        imageReader = reader
        readerThread = HandlerThread("sonicshield-capture").also { it.start() }
        readerHandler = Handler(readerThread!!.looper)
        reader.setOnImageAvailableListener({ ir ->
            // acquireLatestImage 会顺手丢弃队列里更旧的未取帧；
            // 我们只保留最新一帧（不关，供多次抓帧重复读取）。
            val img = ir.acquireLatestImage() ?: return@setOnImageAvailableListener
            synchronized(frameLock) {
                latestImage?.let { prev ->
                    try {
                        prev.close()
                    } catch (_: Exception) {
                    }
                }
                latestImage = img
            }
        }, readerHandler)
        virtualDisplay = projection?.createVirtualDisplay(
            "sonicshield-capture",
            metrics.widthPixels,
            metrics.heightPixels,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            null,
        )
        virtualDisplay != null
    } catch (e: Exception) {
        Log.w(TAG, "startVirtualDisplay failed", e)
        false
    }

    /**
     * 抓**一帧**屏幕，返回 JPEG 的 base64（docs/24 阶段 1 / docs/61 P1）。
     *
     * NAT-01：只读长驻 VD 的**最近一帧**，不再 createVirtualDisplay
     * （同一 MediaProjection 实例只能建一次 VD，官方契约）。
     * 链路：`Image`（RGBA_8888，按 rowStride 去 padding）→ `Bitmap`
     * → 裁剪到真实宽高 → JPEG(70) → base64。
     *
     * **如实失败**：会话未就绪 / 首帧未到（轮询到超时）/ 任何异常 ⇒
     * `callback(null, 原因)`，原因含**异常类型名**（NAT-13），调用方据此回
     * `rc.ack{ok:false}`，**不静默**。`timeoutMs` 是硬兜底，绝不挂住调用方。
     *
     * 回调在**主线程**（本方法由插件的 MethodChannel handler 调用，即平台线程；
     * 轮询也 post 回主 Looper，与 [RemoteCaptureRegistry] 的契约一致）。
     */
    fun captureOnce(timeoutMs: Long, callback: (String?, String?) -> Unit) {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        fun attempt() {
            if (stopping) {
                callback(null, "投屏会话已停止")
                return
            }
            // 取像素副本要快（memcpy 级），故在 frameLock 内只做"拷贝"，
            // JPEG 编码放到锁外 —— listener 只可能被阻塞几毫秒。
            val frame = snapshotFrame()
            if (frame != null) {
                val b64 = try {
                    encodeJpeg(frame)
                } catch (e: Exception) {
                    Log.w(TAG, "captureOnce: encode failed", e)
                    callback(null, "${e.javaClass.simpleName}: ${e.message}")
                    return
                }
                callback(b64, null)
                return
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                callback(null, "抓帧超时：投影未产出画面")
                return
            }
            // 首帧未到（VD 刚建、系统尚未合成第一帧）：轮询等待，硬超时兜底。
            Handler(Looper.getMainLooper()).postDelayed({ attempt() }, 50)
        }
        attempt()
    }

    /** 最近一帧的像素副本（含 rowStride padding 的原始字节）。 */
    private class Frame(
        val pixels: ByteArray,
        val pixelStride: Int,
        val rowStride: Int,
        val width: Int,
        val height: Int,
    )

    /**
     * 在 [frameLock] 内取出最近一帧的像素副本；无帧 / 取帧异常返回 null。
     *
     * 为什么必须持锁拷贝：listener 可能在任意时刻 close 旧帧并替换新帧，
     * 若在锁外读 [Image]，可能读到已 close 的帧（IllegalStateException）。
     */
    private fun snapshotFrame(): Frame? = synchronized(frameLock) {
        val img = latestImage ?: return@synchronized null
        try {
            val plane = img.planes[0]
            val buf = plane.buffer
            // 同一帧可能被多次抓取（上次读完 position 已在尾部）⇒ 每次复位。
            buf.rewind()
            val pixels = ByteArray(buf.remaining())
            buf.get(pixels)
            Frame(
                pixels = pixels,
                pixelStride = plane.pixelStride,
                rowStride = plane.rowStride,
                width = img.width,
                height = img.height,
            )
        } catch (e: Exception) {
            Log.w(TAG, "snapshotFrame failed", e)
            null
        }
    }

    /**
     * 像素副本 → JPEG base64。
     *
     * ⚠️ ImageReader 的 buffer 含 rowStride padding：必须按 padding 建图再
     * 裁剪，否则图像会**横向错位**（经典坑）。
     */
    private fun encodeJpeg(frame: Frame): String {
        val rowPadding = frame.rowStride - frame.pixelStride * frame.width
        val padded = Bitmap.createBitmap(
            frame.width + rowPadding / frame.pixelStride,
            frame.height,
            Bitmap.Config.ARGB_8888,
        )
        padded.copyPixelsFromBuffer(
            java.nio.ByteBuffer.wrap(frame.pixels),
        )
        val cropped = Bitmap.createBitmap(padded, 0, 0, frame.width, frame.height)
        val baos = ByteArrayOutputStream()
        cropped.compress(Bitmap.CompressFormat.JPEG, 70, baos)
        padded.recycle()
        cropped.recycle()
        return Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
    }

    /**
     * 停止投屏会话（ACTION_STOP / 授权被撤销 / 建立失败）。
     *
     * 幂等 + 防重入：[stopping] 闸避免 `projection.stop()` 触发
     * `MediaProjection.Callback.onStop` 后再进来一圈。
     */
    private fun stopCast() {
        if (stopping) return
        stopping = true
        // 先摘回调再 stop：stop() 本身会触发 onStop，摘了就不会重入。
        val cb = projectionCallback
        projectionCallback = null
        val mp = projection
        projection = null
        if (cb != null) {
            try {
                mp?.unregisterCallback(cb)
            } catch (_: Exception) {
            }
        }
        try {
            mp?.stop()
        } catch (_: Exception) {
        }
        releaseVirtualDisplay()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun releaseVirtualDisplay() {
        synchronized(frameLock) {
            latestImage?.let { img ->
                try {
                    img.close()
                } catch (_: Exception) {
                }
            }
            latestImage = null
        }
        try {
            virtualDisplay?.release()
        } catch (_: Exception) {
        }
        virtualDisplay = null
        try {
            imageReader?.close()
        } catch (_: Exception) {
        }
        imageReader = null
        readerThread?.quitSafely()
        readerThread = null
        readerHandler = null
    }

    override fun onDestroy() {
        RemoteCaptureRegistry.captureOnce = null
        // 与 stopCast 同一套清理（stopSelf 后 onDestroy 会再来一次，幂等）。
        val cb = projectionCallback
        projectionCallback = null
        val mp = projection
        projection = null
        if (cb != null) {
            try {
                mp?.unregisterCallback(cb)
            } catch (_: Exception) {
            }
        }
        try {
            mp?.stop()
        } catch (_: Exception) {
        }
        releaseVirtualDisplay()
        super.onDestroy()
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
