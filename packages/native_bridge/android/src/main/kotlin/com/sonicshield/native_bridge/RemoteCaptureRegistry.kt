package com.sonicshield.native_bridge

/**
 * 远程桌面级控制（docs/61）P1：**单帧抓取的跨模块注册点**。
 *
 * 与 [RemoteInputRegistry] **同一手法**（依赖方向 `app → native_bridge`，插件无法
 * 引用 app 的 `ScreenCastService`）：app 的服务在**启动投屏时**把抓帧实现登记进来，
 * 插件经它触发。
 *
 * ## 语义（fail-closed）
 * 未登记（**未在投屏 / 未授权 / 服务已停**）时 [captureOnce] 为 `null` ⇒ 插件
 * 如实回 `CAST_NOT_ACTIVE` 错误，调用方据此回 `rc.ack{ok:false}`（**不静默**，
 * docs/61 G2）。
 *
 * ## R94（NAT-01）回调契约变更：`(base64, error) -> Unit`
 * 旧签名只有 `(base64 | null)`：失败时调用方只看到 null，**分不出**是
 * "没授权"、"超时"还是 `IllegalStateException`（契约违例）—— 审计只能写
 * "抓帧失败"，排障方向全靠猜。现在 error 非空即失败，且**带异常类型名**
 * （NAT-13：原生异常不得折叠成笼统失败），由插件原样回传 `CAPTURE_FAILED`。
 */
object RemoteCaptureRegistry {

    /**
     * 抓一帧：`(timeoutMs, callback) -> Unit`；
     * `callback(jpegBase64, error)` —— `error == null` 即成功。
     *
     * 回调在**主线程**；未就绪 / 超时 / 任何异常一律带原因回传（如实失败）。
     * 实现由 `ScreenCastService` 在启动时登记、销毁时清空。
     */
    @Volatile
    var captureOnce: ((Long, (String?, String?) -> Unit) -> Unit)? = null
}
