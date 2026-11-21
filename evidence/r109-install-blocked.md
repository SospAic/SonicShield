# R109 真机接入与安装阻塞证据（2026-11-22）

## 设备身份

| 项 | 实测值 |
|---|---|
| 设备 | 华为 Mate 40（用户纠正型号），`model=ALP-AL00`，`product=ALP-AL00 / HWALP` |
| Android | `10` |
| 序列号 | `D3H0217B29002562` |
| ADB 状态 | `device`（授权已完成） |
| USB 接口 | `VID_12D1&PID_107E&MI_01` ADB interface；初现 `Error [5]: 拒绝访问`，管理员执行 `tool/fix_huawei_adb.ps1` 后可见 |
| APK | `releases/SonicShield-Android.apk` |
| 大小 | `270045608` bytes |
| SHA256 | `3A9F705DCDAB2CD4A2BA0AA4101CF15AE864450F68902A69566B9E5CC1EBF821` |
| 版本 | `versionCode=41`，`versionName=1.9.18`，`minSdk=24`，`targetSdk=36` |
| 包名 | `com.sonicshield.sonic_shield` |

## 安装尝试与实测结果

| # | 命令 | 结果 | 证据 |
|---|---|---|---|
| 1 | `adb install -r -t releases/SonicShield-Android.apk` | 后台挂起约 10 分钟，stdout/stderr 均为 0 字节；设备前台停在 `com.android.packageinstaller/.InstallStaging` | `_pt/adb_install_v2.txt`、`evidence/adb-install-capture/` |
| 2 | `adb install --no-streaming -r -t releases/SonicShield-Android.apk` | push 成功：`1 file pushed ... 30.4 MB/s (270045608 bytes in 8.474s)`；随后同样停在 `InstallStaging` | `_pt/adb_install_v3.txt`、`evidence/adb-install-capture-nostream/` |
| 3 | `adb shell pm install -r -t /data/local/tmp/SonicShield-Android.apk` | 挂起；前台仍为 `InstallStaging` | `_pt/pm_install_plain.txt` |
| 4 | `adb shell pm install -r -t -i com.android.vending /data/local/tmp/SonicShield-Android.apk` | 29 秒内返回真实错误：`Failure [INSTALL_FAILED_ABORTED: User rejected permissions]` | `_pt/pm_install_vending.txt` |
| 5 | `adb shell pm install -r -t -i com.android.packageinstaller /data/local/tmp/SonicShield-Android.apk` | 挂起；前台仍为 `InstallStaging` | `_pt/pm_install_sysinstaller.txt` |
| 6 | `pm install-create -S 270045608` → `pm install-write ... base ...` → `pm install-commit` | create/write 成功：`Success: created install session [103488294]`、`Success: streamed 270045608 bytes`；commit 挂起 | `_pt/pm_session_install.txt` |

安装后核对：
```text
adb shell pm path com.sonicshield.sonic_shield
# 无输出，PKG_RC=1 → 应用尚未安装
```

## 根因判定（现场证据，不是推测）

`adb shell uiautomator dump /data/local/tmp/ui_install.xml` 抓到的 UI 层级包含：

```text
text="人脸解锁或输入密码"
text="1" ... text="9" ... text="0"
resource-id="com.android.systemui:id/keyguard_lock_screen_panel"
```

即设备停在**锁屏 PIN/密码界面**。`PackageInstaller` 的确认流程在锁屏之后，`screencap -p` 在 `InstallStaging` 期间只返回 8162 字节白屏（secure surface），因此连续抓屏无法看到弹窗。用户选择“暂时无法解锁”，物理解锁动作未发生。

判定：**环境阻塞（设备锁屏未解除），不是代码回归。** 未执行真机取证 ≠ 功能失败。

## 已排除 / 未成立

- 不是设备看不到：`adb devices -l` 稳定返回 `D3H0217B29002562 device`。
- 不是传输失败：非流式 push 8.47 秒完成 270MB，30.4MB/s；会话 write 也完整成功。
- 不是存储不足：`/data` 112G，已用 34G，可用 79G（30%）。
- 不是 `adb root` 问题：全程未执行 `adb root`。
- 不是“无线调试绕过弹窗”：本轮全程 USB；且现有证据表明确认流程由 `PackageInstaller` 持有，与传输方式无关。
- `settings put global adb_install_need_confirm 0` 被华为拒绝：`--user not supported for delete and put`（RC=255）。

## 解除条件与复用命令

需要用户在设备上完成一次物理动作：

1. 输入锁屏密码解锁；
2. 若出现“USB 安装提示 / 继续安装”，点“继续安装”；
3. 保持屏幕解锁，然后可直接复用已推送的 APK：

```powershell
adb -s D3H0217B29002562 shell pm install -r -t /data/local/tmp/SonicShield-Android.apk
adb -s D3H0217B29002562 shell pm path com.sonicshield.sonic_shield
powershell -File tool/device_forensics.ps1 -Device D3H0217B29002562
```

截图与抓屏日志位于 `evidence/adb-install-capture/` 与 `evidence/adb-install-capture-nostream/`；
`_pt/**` 下的安装日志为本地诊断证据，按项目规则不入库。
