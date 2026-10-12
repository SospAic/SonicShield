package com.sonicshield.sonic_shield

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.util.DisplayMetrics
import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.annotation.RequiresApi
import com.sonicshield.native_bridge.RemoteInputRegistry

/**
 * 远程桌面级控制（docs/25）P0：**输入注入**（无障碍路径，docs/25 §2 选型 A）。
 *
 * ## 为什么是无障碍
 * 它是 Android 上唯一"纯 App 内、无需 root / 无需电脑"的合规注入路径：
 * - `dispatchGesture`（API 24+）表达 tap / swipe / 多指；
 * - `performGlobalAction` 表达**导航类**按键（返回 / Home / 最近任务）；
 * - 文本经活动窗口聚焦节点的 `ACTION_SET_TEXT`。
 *
 * ## 能力边界（如实，不夸大 —— docs/25 §2）
 * - **不能**注入系统级按键（电源 / 音量）—— 那需 Shizuku（P1 可选）；
 * - 部分定制 ROM 的安全输入（密码框 / 支付页）会**屏蔽**无障碍注入（系统行为，
 *   无法也不应绕过）；
 * - 未开启无障碍时本服务的 [instance] 为 null ⇒ 注入**如实返回 false**
 *   （调用方必须回 `rc.inputAck{ok:false}` 并提示"请让对方开启无障碍"，不静默降级）。
 *
 * ## 坐标口径（docs/25 §4.1）
 * 对外接口收 **归一化 0..1** 坐标；本类按当前**真实屏幕像素**（含系统栏）换算，
 * 使控制端无需知道端点分辨率，旋转 / 分辨率变化也不失效。
 *
 * ## 隐私（docs/25 §1）
 * 只用窗口内容**定位聚焦输入框**做文本注入，**不读取 / 不落盘 / 不上传**屏幕文本；
 * 不监听按键内容（配置未开 `flagRequestFilterKeyEvents`）。
 */
class RemoteInputService : AccessibilityService() {

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 本服务只做注入，不消费事件。
    }

    override fun onInterrupt() {}

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        // 把注入实现登记进**插件侧**注册表。依赖方向是 `app → native_bridge`
        // （插件无法引用 app 类），故由 app 侧反向登记 —— 见 RemoteInputRegistry 文档。
        RemoteInputRegistry.tap = { nx, ny, d -> tap(nx, ny, d) }
        RemoteInputRegistry.swipe = { x1, y1, x2, y2, d -> swipe(x1, y1, x2, y2, d) }
        RemoteInputRegistry.key = { k -> globalAction(k) }
        RemoteInputRegistry.text = { t -> setText(t) }
        Log.i(TAG, "无障碍服务已连接：可注入 tap/swipe/key/text")
    }

    override fun onUnbind(intent: Intent?): Boolean {
        RemoteInputRegistry.clear()
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        RemoteInputRegistry.clear()
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** 屏幕真实像素（含系统栏），用于把归一化坐标换算为注入像素。 */
    private fun screenSize(): Pair<Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = wm.currentWindowMetrics.bounds
            b.width() to b.height()
        } else {
            @Suppress("DEPRECATION")
            val display = wm.defaultDisplay
            val m = DisplayMetrics()
            @Suppress("DEPRECATION")
            display.getRealMetrics(m)
            m.widthPixels to m.heightPixels
        }
    }

    private fun toPx(n: Float, total: Int): Float = n.coerceIn(0f, 1f) * total

    /** 归一化 (nx,ny) 点击。[durationMs] <= 0 用系统默认短按。返回是否受理。 */
    @RequiresApi(Build.VERSION_CODES.N)
    fun tap(nx: Float, ny: Float, durationMs: Long): Boolean {
        val (w, h) = screenSize()
        val path = Path().apply { moveTo(toPx(nx, w), toPx(ny, h)) }
        val dur = if (durationMs > 0) durationMs else 60L
        return dispatchGesture(buildGesture(path, dur), null, null)
    }

    /** 归一化 (nx1,ny1) → (nx2,ny2) 滑动 / 拖拽。返回是否受理。 */
    @RequiresApi(Build.VERSION_CODES.N)
    fun swipe(
        nx1: Float, ny1: Float, nx2: Float, ny2: Float, durationMs: Long,
    ): Boolean {
        val (w, h) = screenSize()
        val path = Path().apply {
            moveTo(toPx(nx1, w), toPx(ny1, h))
            lineTo(toPx(nx2, w), toPx(ny2, h))
        }
        val dur = if (durationMs > 0) durationMs else 200L
        return dispatchGesture(buildGesture(path, dur), null, null)
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun buildGesture(path: Path, durationMs: Long): GestureDescription =
        GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, durationMs))
            .build()

    /**
     * 导航类按键（返回 / Home / 最近任务）。**系统级按键（电源 / 音量）无障碍做不到**，
     * 这里对未知 keyCode 直接返回 false（如实失败，不假装受理）。
     */
    fun globalAction(keyCode: Int): Boolean {
        val action = when (keyCode) {
            KeyEvent.KEYCODE_BACK -> GLOBAL_ACTION_BACK
            KeyEvent.KEYCODE_HOME -> GLOBAL_ACTION_HOME
            KeyEvent.KEYCODE_APP_SWITCH -> GLOBAL_ACTION_RECENTS
            else -> return false
        }
        return performGlobalAction(action)
    }

    /** 文本注入：对活动窗口**聚焦节点**走 `ACTION_SET_TEXT`；无聚焦输入框则失败。 */
    fun setText(text: String): Boolean {
        val root = rootInActiveWindow ?: return false
        val focus = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        val args = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text,
            )
        }
        return focus.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    companion object {
        private const val TAG = "RemoteInputService"

        /**
         * 当前连接的服务实例（**未开启无障碍时为 null**）。
         *
         * 这是"无障碍是否已授权"的唯一运行时真源：Dart 侧经桥查询它来决定
         * 是否允许注入、以及给用户"去开启无障碍"的引导。
         */
        @Volatile
        var instance: RemoteInputService? = null

        /** 无障碍是否已开启（供 Dart 侧探测与 UI 引导）。 */
        fun isEnabled(): Boolean = instance != null
    }
}
