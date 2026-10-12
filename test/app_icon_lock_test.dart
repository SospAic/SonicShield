import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 应用图标**存在性 / 尺寸 / 入库**锁（FR-83，第八十四轮用户明文）。
///
/// ## 为什么需要它
///
/// 用户明文要求「应用图标按用户拟定样式替换」。图标是**多密度 + 双平台**资源：
/// Android 5 档 `mipmap-*/ic_launcher.png`（48/72/96/144/192）+ iOS 15 档
/// `AppIcon.appiconset/Icon-App-*.png`（20…1024）。手工替换必漂移 —— 漏一档、
/// 尺寸写错、或换了图却**忘记入库**（`git add` 漏掉 ⇒ 别人 clone 到旧图）。
///
/// 这三点都是「构建不会红、运行也不报错」的静默缺陷（装出来的包图标要么是
/// Flutter 默认蓝天白云、要么是旧图），只能靠**机械判据**盯住。
///
/// ## 判据（三条）
///
/// 1. **存在性**：20 个图标文件必须都在；
/// 2. **尺寸**：每个 PNG 的实际边长必须等于其约定值（防"图贴错密度"）；
/// 3. **入库**：每个图标必须被 `git ls-files` 收录（防"换了图没提交"）。
///
/// ⚠️ 本锁**不校验像素内容**（"是否像用户拟定的样式"是视觉判断，机器判不了）——
/// 内容一致性由 `tool/gen_icon.py --check` 的**可复现渲染**间接保证：
/// 图上样式变更走脚本，脚本一改全档同步。
void main() {
  /// Android 传统图标密度 → 约定边长（px）。
  const androidSizes = <String, int>{
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };

  /// iOS AppIcon 文件名 → 约定边长（px）。
  const iosSizes = <String, int>{
    'Icon-App-20x20@1x.png': 20,
    'Icon-App-20x20@2x.png': 40,
    'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29,
    'Icon-App-29x29@2x.png': 58,
    'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40,
    'Icon-App-40x40@2x.png': 80,
    'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120,
    'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76,
    'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
  };

  /// 读 PNG 头里的宽高（IHDR：偏移 16 起 4B 宽 + 4B 高，大端）。
  ///
  /// 不走 `dart:ui` / `image` 包：本锁要在**纯宿主机**跑且零依赖 ——
  /// PNG 头解析只需 24 字节，比引一个图像库更稳（也避免解码大图的开销）。
  (int, int) pngSize(File f) {
    final bytes = f.readAsBytesSync();
    expect(bytes.length, greaterThan(24), reason: '${f.path} 不是有效 PNG（过短）');
    // 8B 签名 + 4B 长度 + 4B 'IHDR' ⇒ 宽从偏移 16 起。
    int be32(int o) =>
        (bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3];
    return (be32(16), be32(20));
  }

  /// `git ls-files` 收录的相对路径集合（仓库根为 cwd）。
  Set<String> tracked() {
    final r = Process.runSync('git', ['ls-files'],
        stdoutEncoding: const SystemEncoding(), stderrEncoding: const SystemEncoding());
    expect(r.exitCode, 0, reason: 'git ls-files 失败：${r.stderr}');
    return (r.stdout as String)
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toSet();
  }

  group('AIC 应用图标锁（FR-83）', () {
    test('AIC-01 Android 五档 ic_launcher.png 齐备且尺寸正确', () {
      for (final e in androidSizes.entries) {
        final f = File(
            'android/app/src/main/res/mipmap-${e.key}/ic_launcher.png');
        expect(f.existsSync(), isTrue,
            reason: '缺 Android 图标：mipmap-${e.key}/ic_launcher.png（FR-83）');
        final (w, h) = pngSize(f);
        expect((w, h), (e.value, e.value),
            reason: 'mipmap-${e.key} 图标尺寸应为 $e.value×$e.value，'
                '实际 $w×$h（贴错密度会让启动器拉伸/模糊）');
      }
    });

    test('AIC-02 iOS 十五档 AppIcon 齐备且尺寸正确', () {
      const dir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
      for (final e in iosSizes.entries) {
        final f = File('$dir/${e.key}');
        expect(f.existsSync(), isTrue, reason: '缺 iOS 图标：$dir/${e.key}（FR-83）');
        final (w, h) = pngSize(f);
        expect((w, h), (e.value, e.value),
            reason: '$dir/${e.key} 尺寸应为 $e.value×$e.value，实际 $w×$h');
      }
    });

    test('AIC-03 全部图标必须已入库（git ls-files 可见）', () {
      // ⚠️ 必须在 **test 体内**取（`tracked()` 内含 `expect`）——
      // 放在 group 体里会在 `Declarer.group` 阶段调用 ⇒ `OutsideTestException`。
      final trackedFiles = tracked();
      final missing = <String>[];
      for (final k in androidSizes.keys) {
        final p = 'android/app/src/main/res/mipmap-$k/ic_launcher.png';
        if (!trackedFiles.contains(p)) missing.add(p);
      }
      for (final k in iosSizes.keys) {
        final p = 'ios/Runner/Assets.xcassets/AppIcon.appiconset/$k';
        if (!trackedFiles.contains(p)) missing.add(p);
      }
      expect(missing, isEmpty,
          reason: '以下图标文件未被 git 收录（换了图但没提交 ⇒ 别人 clone 到旧图）：\n'
              '${missing.join('\n')}');
    });

    test('AIC-04 生成脚本必须存在且可复现（tool/gen_icon.py）', () {
      final gen = File('tool/gen_icon.py');
      expect(gen.existsSync(), isTrue,
          reason: '图标须由脚本生成（可复现），不得手放 PNG：缺 tool/gen_icon.py');
      final src = gen.readAsStringSync();
      // 脚本必须覆盖双平台（否则新平台图标会靠手放 ⇒ 漂移）。
      expect(src.contains('mipmap-'), isTrue, reason: 'gen_icon.py 必须产出 Android mipmap');
      expect(src.contains('AppIcon.appiconset'), isTrue,
          reason: 'gen_icon.py 必须产出 iOS AppIcon');
    });
  });
}
