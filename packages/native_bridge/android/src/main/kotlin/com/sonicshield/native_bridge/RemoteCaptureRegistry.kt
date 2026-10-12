package com.sonicshield.native_bridge

/**
 * 远程桌面级控制（docs/25）P1：**单帧抓取的跨模块注册点**。
 *
 * 与 [RemoteInputRegistry] **同一手法**（依赖方向 `app → native_bridge`，插件无法
 * 引用 app 的 `ScreenCastService`）：app 的服务在**启动投屏时**把抓帧实现登记进来，
 * 插件经它触发。
 *
 * ## 语义（fail-closed）
 * 未登记（**未在投屏 / 未授权 / 服务已停**）时 [captureOnce] 为 `null` ⇒ 插件
 * 如实回 `null`，调用方据此回 `rc.ack{ok:false}`（**不静默**，docs/25 G2）。
 */
object RemoteCaptureRegistry {

    /**
     * 抓一帧：`(timeoutMs, callback) -> Unit`；`callback(jpegBase64 | null)`。
     *
     * 回调在**主线程**；未授权 / 超时 / 任何异常一律回 `null`（如实失败）。
     * 实现由 `ScreenCastService` 在启动时登记、销毁时清空。
     */
    @Volatile
    var captureOnce: ((Long, (String?) -> Unit) -> Unit)? = null
}
