package com.sonicshield.native_bridge

/**
 * 远程桌面级控制（docs/61）P0：**输入注入的跨模块注册点**。
 *
 * ## 为什么需要它（一个真实的架构约束）
 * 输入注入由 **app 级** `RemoteInputService`（`AccessibilityService`，见 app 模块）
 * 实现，而桥接方法在**本地插件**（本模块）里。Gradle 依赖方向是
 * `app → native_bridge` —— 即**插件无法引用 app 级类**（与 `AlarmWatchdogReceiver`
 * 用「显式组件名 Intent」启动 app 服务同一约束）。故用本注册表**反向解耦**：
 * app 的服务在 `onServiceConnected` 时把注入实现登记进来，插件经它调用。
 *
 * ## 语义（fail-closed，不静默降级）
 * 未登记（**无障碍未开启 / 服务未连接**）时对应回调为 `null` ⇒ 插件**如实返回
 * false**，调用方必须回 `rc.inputAck{ok:false}` 并引导用户"去开启无障碍"，
 * 不得假装受理（docs/61 §1、G8）。
 *
 * 线程：`onServiceConnected` 在主线程，方法通道回调也在主线程；`@Volatile` 保证
 * 可见性（与 `NativeBridgePlugin` 的常驻唤醒锁同一纪律）。
 */
object RemoteInputRegistry {

    /** 归一化坐标点击：`(nx, ny, durationMs) -> 受理?`。 */
    @Volatile
    var tap: ((Float, Float, Long) -> Boolean)? = null

    /** 归一化坐标滑动：`(nx1, ny1, nx2, ny2, durationMs) -> 受理?`。 */
    @Volatile
    var swipe: ((Float, Float, Float, Float, Long) -> Boolean)? = null

    /** 导航类按键：`(keyCode) -> 受理?`。 */
    @Volatile
    var key: ((Int) -> Boolean)? = null

    /** 文本注入：`(text) -> 受理?`。 */
    @Volatile
    var text: ((String) -> Boolean)? = null

    /** 无障碍是否已连接（供桥接探测与 UI 引导）。 */
    val isConnected: Boolean
        get() = tap != null

    /** 服务断开 / 销毁时清空（下次连接重新登记）。 */
    fun clear() {
        tap = null
        swipe = null
        key = null
        text = null
    }
}
