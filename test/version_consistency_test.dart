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
    final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.\-]+)?)',
            multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 里找不到 version: 行');
    return m!.group(1)!;
  }

  /// CHANGELOG 里所有 `## [x.y.z]` 版本号，按出现顺序。
  List<String> changelogVersions() => RegExp(r'^## \[([^\]]+)\]', multiLine: true)
      .allMatches(changelog)
      .map((m) => m.group(1)!)
      .toList();

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
}
