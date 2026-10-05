import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/services/evidence_files.dart';

/// 取证文件服务（`EvidenceStore`，P2-11）的行为锁。
///
/// `docs/07` §4/§5 承诺：录音取证文件是**用户资产**，永不自动删除，且提供
/// **手动清理与导出**。此前这条承诺在应用内没有闭环（用户既看不到占用、也
/// 无法导出/清理）。本文件在**真实临时目录**上跑真实文件 I/O，锁住三件事：
///
/// 1. **只认取证文件**：`list()` 必须把非 `*.evidence.m4a` 的文件全挡在门外
///    —— 目录里同时存在普通 `.m4a`、`.json`、子目录时，混进去会误导用户
///    "删掉没用的文件"，而实际删的是别的东西；
/// 2. **只删取证文件**：`delete()` 收到非取证路径必须 `ArgumentError` 炸出来，
///    `docs/07` §4 明写「绝不触碰其它文件」；
/// 3. **倒序 / 幂等 / 空目录**：最新在前、重复删除不报错、目录不存在返回空。
///
/// ⚠️ 这些是**非恒真的行为断言**：每条都配了反面样本（写一个非取证文件、
/// 传一个非取证路径），证明判据真的会分流，而不是"永远返回同一结果"。
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('sonic_evf_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  EvidenceStore store() => EvidenceStore(directory: tmp);

  /// 造一个取证文件，带可控的修改时间。
  File makeEvidence(String name, {required DateTime modified, int bytes = 8}) {
    final f = File('${tmp.path}/$name')
      ..writeAsBytesSync(List<int>.filled(bytes, 0));
    f.setLastModifiedSync(modified);
    return f;
  }

  group('EVF-01 扫描与过滤', () {
    test('EVF-01 只列 *.evidence.m4a；普通 .m4a / .json / 子目录一律不计入', () async {
      final older = makeEvidence('evidence_1.evidence.m4a',
          modified: DateTime(2026, 1, 1, 8));
      final newer = makeEvidence('evidence_2.evidence.m4a',
          modified: DateTime(2026, 1, 2, 8));
      // 反面样本：这些都不该出现在结果里。
      File('${tmp.path}/normal.m4a').writeAsBytesSync([0]);
      File('${tmp.path}/backup.json').writeAsStringSync('{}');
      File('${tmp.path}/evidence_3.evidence.m4a.bak').writeAsBytesSync([0]);
      Directory('${tmp.path}/sub.evidence.m4a').createSync(); // 目录，非文件

      final list = await store().list();

      expect(list.map((e) => e.name).toSet(), {
        older.uri.pathSegments.last,
        newer.uri.pathSegments.last,
      }, reason: '只有两个真取证文件应入选，其余全是干扰项');
      expect(list.length, 2);
    });

    test('EVF-01b 按修改时间倒序（最新在前）', () async {
      makeEvidence('a.evidence.m4a', modified: DateTime(2026, 3, 1));
      makeEvidence('b.evidence.m4a', modified: DateTime(2026, 3, 3));
      makeEvidence('c.evidence.m4a', modified: DateTime(2026, 3, 2));

      final names = (await store().list()).map((e) => e.name).toList();
      expect(names, ['b.evidence.m4a', 'c.evidence.m4a', 'a.evidence.m4a']);
    });

    test('EVF-01c 大小与名称如实回带（不是永远 0 / 恒定值）', () async {
      makeEvidence('big.evidence.m4a',
          modified: DateTime(2026, 1, 1), bytes: 1234);

      final one = (await store().list()).single;
      expect(one.name, 'big.evidence.m4a');
      expect(one.sizeBytes, 1234);
      expect(one.path.endsWith('big.evidence.m4a'), isTrue);
    });

    test('EVF-01d 目录不存在 → 空表（首次运行不是错误）', () async {
      final missing = Directory('${tmp.path}/does_not_exist');
      expect(await EvidenceStore(directory: missing).list(), isEmpty);
    });

    test('EVF-01e isEvidenceName 分流判据非恒真（正/反样本）', () {
      // 正样本
      expect(EvidenceStore.isEvidenceName('x.evidence.m4a'), isTrue);
      expect(EvidenceStore.isEvidenceName('evidence_9.evidence.m4a'), isTrue);
      // 反样本：证明它并不是"永远 true"
      expect(EvidenceStore.isEvidenceName('normal.m4a'), isFalse);
      expect(EvidenceStore.isEvidenceName('x.evidence.m4a.bak'), isFalse);
      expect(EvidenceStore.isEvidenceName('x.evidence.m4a.txt'), isFalse);
      expect(EvidenceStore.isEvidenceName('X.EVIDENCE.M4A'), isFalse,
          reason: '后缀判定大小写敏感，不该把近似名当取证文件');
    });
  });

  group('EVF-02 删除', () {
    test('EVF-02 delete 真删文件，且列表随之少一条', () async {
      final f = makeEvidence('gone.evidence.m4a', modified: DateTime(2026, 1, 1));
      makeEvidence('keep.evidence.m4a', modified: DateTime(2026, 1, 2));

      await store().delete(f.path);

      expect(f.existsSync(), isFalse, reason: '必须真的从磁盘消失');
      expect((await store().list()).map((e) => e.name).toList(),
          ['keep.evidence.m4a'], reason: '只删指定的那一条，另一个不受影响');
    });

    test('EVF-02b 重复删除幂等（文件已不在也不抛）', () async {
      final f = makeEvidence('twice.evidence.m4a', modified: DateTime(2026, 1, 1));
      final s = store();
      await s.delete(f.path);
      await s.delete(f.path); // 第二次应静默成功
      expect((await s.list()), isEmpty);
    });

    test('EVF-02c 非取证路径 → ArgumentError，且文件**原封不动**', () async {
      final victim = File('${tmp.path}/important.json')
        ..writeAsStringSync('{"secret":true}');

      await expectLater(store().delete(victim.path), throwsArgumentError);
      expect(victim.existsSync(), isTrue, reason: '绝不能触碰非取证文件');
      expect(victim.readAsStringSync(), '{"secret":true}');
    });
  });
}