package com.sonicshield.sonic_shield

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 主 Activity。
 *
 * 原生能力（精确闹钟/电池白名单/厂商深链/震动/麦克风FGS）已迁移至本地插件
 * packages/native_bridge（NativeBridgePlugin），由 GeneratedPluginRegistrant
 * 自动注册到所有 Flutter 引擎（含后台服务引擎）——见 docs/03 ADR-008。
 */
class MainActivity : FlutterActivity() {
    /**
     * 🔴 BUG-078 迁移（SEC1 第 50 轮，升级路径 P0）：
     * flutter_background_service_android 6.3.1 把 foreground_service_types
     * **持久化**在 SharedPreferences（文件 `id.flutter.background_service`，
     * Config.java:75-83）。第 35 轮 F-2 收紧 manifest 只留 mediaPlayback（0x2）
     * 且 Dart 配置同步只传 mediaPlayback，但**旧版本写下的
     * "dataSync,mediaPlayback" 会残留在该文件里**。服务一旦在任何
     * configure() 之前被拉起（首页恢复守护 / 看门狗闹钟），BackgroundService.java
     * :169-173 按旧类型位算出 0x3（dataSync|mediaPlayback）调 startForeground，
     * Android 14+ 强校验「运行时类型 ⊆ 清单类型」⇒ IllegalArgumentException
     * 直接杀进程。实测（emulator-5554 / API 36，2026-09-29）：升级后点启动守护
     * 必崩，logcat crash 缓冲三次 FATAL（_pt/z3_*.txt）。
     * 迁移：进程创建第一时间把残留值里的 dataSync 剔除（其余类型位保留）；
     * 若剔除后为空则整键移除（ForegroundTypeMapper 对空串 split 会 NPE，
     * 缺键则回落 FOREGROUND_SERVICE_TYPE_MANIFEST = 读清单，语义正确）。
     * 随后 configure() 会写入权威值。幂等、无 dataSync 时零开销。
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        migrateStaleForegroundServiceTypes()
        super.onCreate(savedInstanceState)
    }

    private fun migrateStaleForegroundServiceTypes() {
        try {
            val pref = getSharedPreferences("id.flutter.background_service", MODE_PRIVATE)
            val stale = pref.getString("foreground_service_types", null) ?: return
            if (!stale.contains("dataSync")) return
            val fixed = stale.split(",")
                .map { it.trim() }
                .filter { it.isNotEmpty() && it != "dataSync" }
                .joinToString(",")
            if (fixed.isEmpty()) {
                pref.edit().remove("foreground_service_types").apply()
            } else {
                pref.edit().putString("foreground_service_types", fixed).apply()
            }
            Log.w("SonicShield", "BUG-078 migration: stale foreground_service_types \"$stale\" -> \"$fixed\"")
        } catch (e: Exception) {
            // 迁移失败不阻塞启动；configure() 稍后会写权威值。
            Log.w("SonicShield", "BUG-078 migration failed (non-fatal)", e)
        }
    }

    // ==================== 远程桌面级控制（docs/25 P0）====================

    /** 投屏授权在途的 Dart 回调（同一时刻只允许一次授权弹窗）。 */
    private var pendingCastResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAST_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "screenCastStart" -> startCastFlow(result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 发起投屏授权 → 用户同意后启动投屏前台服务。
     *
     * ⚠️ **必须由 Activity 承载**：`createScreenCaptureIntent` 的系统授权弹窗，
     * 及其返回的 `resultCode`/`data`，只能在 `onActivityResult` 里拿到 —— 这是
     * Android 的硬约束（docs/25 §1「授权不可绕过」）。因此本流程**不放插件**
     * （插件没有 Activity）。用户拒绝 ⇒ 服务不启动、回调 false，调用方据此回
     * `rc.ack{ok:false}`（不重试轰炸）。
     */
    private fun startCastFlow(result: MethodChannel.Result) {
        if (pendingCastResult != null) {
            result.success(false) // 已有一次在途，避免叠加授权弹窗
            return
        }
        val mpm =
            getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        pendingCastResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), REQ_SCREEN_CAPTURE)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_SCREEN_CAPTURE) {
            val r = pendingCastResult
            pendingCastResult = null
            val ok = resultCode == Activity.RESULT_OK && data != null
            if (ok) {
                val svc = Intent()
                    .setClassName(this, "com.sonicshield.sonic_shield.ScreenCastService")
                    .setAction("com.sonicshield.screen.START")
                    .putExtra("resultCode", resultCode)
                    .putExtra("resultData", data)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(svc)
                } else {
                    startService(svc)
                }
            }
            r?.success(ok)
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    companion object {
        private const val CAST_CHANNEL = "sonic_shield/screencast"
        private const val REQ_SCREEN_CAPTURE = 0x5C01
    }
}
