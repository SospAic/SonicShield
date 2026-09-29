package com.sonicshield.sonic_shield

import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

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
}
