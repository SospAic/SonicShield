import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/core/constants.dart';

/// 版本号一致性锁（BUG-049）。
///
/// ## 为什么需要它
///
/// 本项目有**四处**版本号：`pubspec.yaml` / `CHANGELOG.md` 顶部 /
/// `HANDOVER.md` / `AppMeta.version`。历史上它们靠"发版收尾时人肉核对"同步，
/// 于是反复漂移：
///
/// - 第十三/十四轮收尾发现 CHANGELOG 顶部是 `[1.7.2]` 而 pubspec 还是 `1.7.1`
///   （"版本三处不一致"）；
/// - 第十五轮又发现 **`AppMeta.version` 停在 `1.7.0-alpha.1`**
///   而 pubspec 已是 `1.7.1` —— 而该常量的注释恰恰写着"与 pubspec 保持同步"。
///   后果是**用户可见**的：远程 `status` / `device` 回执上报的是过期版本号
///   （`AppMeta.version` 的用途就是上报，见 BUG-018）。
///
/// 人肉核对会漏，机器不会。本文件把这条不变量变成**门禁的一部分**：
/// 版本没同步 → 功能层直接红，而不是等到下一个人读文档时才发现。
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final changelog = File('CHANGELOG.md').readAsStringSync();

  /// 取出 `version: 1.7.2+13` 里的 `1.7.2`（丢掉 build 号，含预发布后缀）。
  String pubspecVersion() {
    final m = RegExp(
            r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.\-]+)?)',
            multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 里找不到 version: 行');
    return m!.group(1)!;
  }

  /// CHANGELOG 里所有 `## [x.y.z]` 版本号，按出现顺序。
  List<String> changelogVersions() =>
      RegExp(r'^## \[([^\]]+)\]', multiLine: true)
          .allMatches(changelog)
          .map((m) => m.group(1)!)
          .toList();

  /// 取 `version: 1.9.0-alpha+18` 里的**构建号** `18`。
  String pubspecBuild() {
    final m = RegExp(
            r'^version:\s*[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.\-]+)?\+([0-9]+)',
            multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 的 version 行必须带 `+构建号`');
    return m!.group(1)!;
  }

  /// `(a, b, c, isPrerelease)` —— 用于比较大小。
  (int, int, int, bool) semver(String v) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)(-(.+))?$').firstMatch(v);
    expect(m, isNotNull, reason: '「$v」不是 x.y.z 形式（CHANGELOG 标题需用纯版本号）');
    return (
      int.parse(m!.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      m.group(4) != null,
    );
  }

  int compare(String a, String b) {
    final x = semver(a), y = semver(b);
    if (x.$1 != y.$1) return x.$1.compareTo(y.$1);
    if (x.$2 != y.$2) return x.$2.compareTo(y.$2);
    if (x.$3 != y.$3) return x.$3.compareTo(y.$3);
    // 同版本号时：正式版 > 预发布版
    if (x.$4 != y.$4) return x.$4 ? -1 : 1;
    return 0;
  }

  test('AppMeta.version 与 pubspec.yaml 一致（远程回执上报的就是它）', () {
    expect(AppMeta.version, pubspecVersion(),
        reason: 'AppMeta.version 必须与 pubspec 同步：远程 status/device 回执'
            '上报该值，不同步会让使用者看到过期版本号（BUG-018 / BUG-049）');
  });

  test('CHANGELOG 顶部版本与 pubspec.yaml 一致', () {
    final versions = changelogVersions();
    expect(versions, isNotEmpty, reason: 'CHANGELOG 里找不到 ## [x.y.z] 标题');
    expect(versions.first, pubspecVersion(),
        reason: 'CHANGELOG 顶部必须是当前版本（新版本发布时先加标题再改 pubspec）');
  });

  test('CHANGELOG 顶部就是最高版本（条目按新→旧排列）', () {
    final versions = changelogVersions();
    final top = versions.first;
    for (final v in versions.skip(1)) {
      expect(compare(top, v), greaterThan(0),
          reason: '「$v」排在了顶部「$top」之后，但版本更高或相同 —— '
              'CHANGELOG 必须新版本在前（历史曾把 [1.7.1] 落在 [1.7.0-alpha.1] 之后）');
    }
  });

  test('CHANGELOG 不含重复版本号段', () {
    final versions = changelogVersions();
    final seen = <String>{};
    for (final v in versions) {
      expect(seen.add(v), isTrue, reason: '版本「$v」出现了两次（历史 BUG-023 修过同类问题）');
    }
  });

  // ── 第七十七轮基线新增：「每次迭代 APP 中显示的版本必须同步更新」 ──
  //
  // 上面四条只锁 `x.y.z[-pre]`，而**每次迭代抬的是构建号 `+N`**。若界面只显示
  // `version`，用户根本看不出本轮迭代已更新（历史上设置页底部还长期写死
  // `v1.0.0`，漂了多个版本没人发现）。故再上两把锁：
  //   ① `AppMeta.buildNumber` == pubspec 的 `+N`；
  //   ② 设置页「关于」区块**只从常量取**版本串，且不得再出现写死的版本号。

  test('AppMeta.buildNumber 与 pubspec.yaml 的构建号一致（界面显示的就是它）',
      () {
    expect(AppMeta.buildNumber, pubspecBuild(),
        reason: '每次迭代抬的是构建号：不同步则 APP 中显示的版本仍停在上一轮'
            '（与「每次迭代 APP 显示版本必须同步更新」的基线相悖）');
  });

  test('设置页「关于」区块必须显示 AppMeta.displayVersion，且不得写死版本号', () {
    final src =
        File('lib/features/settings/settings_screen.dart').readAsStringSync();
    expect(src.contains('AppMeta.displayVersion'), isTrue,
        reason: '「关于」区块必须从 `AppMeta.displayVersion`（= version+build）取版本串，'
            '否则迭代后用户看到的仍是旧版本');
    // 历史形状：写死 `v1.0.0`。任何 `v<数字>.<数字>.<数字>` 字面量都判红。
    final hardcoded = RegExp(r"'v[0-9]+\.[0-9]+\.[0-9]+");
    expect(hardcoded.hasMatch(src), isFalse,
        reason: '设置页不得再出现写死的版本号字面量（应统一走 AppMeta.displayVersion）');
  });

  // ── 本轮新增基线：「每次迭代版本信息后须带年月日」 ──
  //
  // 第七十七轮只锁了「构建号随版本同步」；本轮补上「版本信息后必须带迭代日期」，
  // 让用户/回执能直接看到构建日期，不必靠 +N 反推（文档真源：HANDOVER.md
  // 「★ 新增长期规则」）。

  test('AppMeta.buildDate 为 YYYY-MM-DD 格式（基线：版本信息后须带年月日）', () {
    expect(AppMeta.buildDate, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
        reason: '项目基线要求每次迭代在版本信息后追加年月日，'
            'AppMeta.buildDate 必须为 YYYY-MM-DD');
  });

  test('AppMeta.displayVersion 在版本信息后携带年月日（基线）', () {
    final dv = AppMeta.displayVersion;
    expect(dv, contains(AppMeta.buildDate),
        reason: 'displayVersion 必须在版本信息（version+build）之后附上年月日，'
            '且须与 AppMeta.buildDate 一致（项目基线：版本信息后须带年月日）');
    expect(RegExp(r'\d{4}-\d{2}-\d{2}').hasMatch(dv), isTrue,
        reason: 'displayVersion 必须包含 YYYY-MM-DD 日期（项目基线）');
  });
}
