# releases/ · 固定发布产物目录

> 🔴 **项目基线规则**（用户 2026-10-11 指定）：无论是 **Android** 还是 **iOS** 的 release，
> 一律固定生成到本目录，并使用**固定文件名**：

| 平台 | 固定文件名 | 来源 |
|---|---|---|
| Android | `SonicShield-Android.apk` | `flutter build apk --release` 的 `build/app/outputs/flutter-apk/app-release.apk` |
| iOS | `SonicShield-iOS.ipa` | CI `ios-build`（macOS）产出的未签名 IPA |

## 为什么固定名

- **一键安装**：根目录 `install_all.bat` 按固定路径 `releases\SonicShield-Android.apk` 取包，
  文件名带版本号会让脚本每轮都要改。
- **确定性**：交付/回归时不必先问「这轮包叫什么」。

## 不入库

本目录的大二进制（`.apk` / `.ipa`）**不入库**（见 `.gitignore`）—— 它们是可再生产物，
且体积大（APK ≈ 256 MB）。**保留本 README 作为约定的落点**。

## 无线设备接入

如需一键安装到**无线**设备，在 `releases\wireless.txt` 中每行写一个 `host:port`
（以 `#` 开头的行会被忽略），`install_all.bat` 会先 `adb connect` 再安装。

## 一键安装

```bat
install_all.bat
```

会枚举**所有**在线的 adb 设备（有线 + 无线），逐个安装；若遇签名不一致的旧包，
自动卸载后重装（⚠️ 会清除该设备上 App 的本地数据）。
