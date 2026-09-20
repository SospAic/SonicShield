import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// BUG-060 回归锁：**"选中端点"这种跨页面共享的旧状态，找不到时不能崩。**
///
/// 修之前三处都写成 `endpoints.firstWhere((e) => e.deviceId == selectedId)`
/// —— 不带 `orElse` 时找不到会抛 `Bad state: No element`。
/// 而"选中的端点"是**旧状态**：用户在别处解配对、或配对表被清了，
/// 本页 `_selectedId` 仍是旧值 → 一点「发送 / 松开对讲 / 快捷指令」就**崩溃**，
/// 且**没有任何提示**（用户只看到界面无响应或闪退）。
const _lib = 'lib';

PairedEndpoint _ep(String id) => PairedEndpoint(
      deviceId: id,
      name: 'n-$id',
      secret: 's-$id',
      pairedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

void main() {
  test('EBI-01 找得到 → 返回该端点', () {
    final list = [_ep('a'), _ep('b')];
    expect(endpointById(list, 'b')?.deviceId, 'b');
  });

  test('EBI-02 找不到 → null，**不抛**（核心：旧状态不该崩）', () {
    final list = [_ep('a')];
    // 旧 id 指向一个已被解配对的端点 —— 以前这里会抛 `Bad state: No element`。
    expect(() => endpointById(list, 'gone'), returnsNormally);
    expect(endpointById(list, 'gone'), isNull);
    expect(endpointById(<PairedEndpoint>[], 'a'), isNull);
  });

  test('EBI-03 空 id / 空表都不抛', () {
    expect(endpointById([_ep('a')], ''), isNull);
    expect(endpointById(<PairedEndpoint>[], ''), isNull);
  });

  test('EBI-04 全局锁：lib/ 里每一处 firstWhere 都必须带 orElse', () {
    // 为什么做成全局锁而不是只查那三处：下次有人新写一处同样会踩。
    // 唯一允许不带 orElse 的情形是**调用前已显式确认存在**，那也应当写成
    // [endpointById] 这种"返回 null"的形式 —— 见 EBI-02 的理由。
    final bad = <String>[];
    var scanned = 0;
    for (final f in Directory(_lib).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      final lines = src.split('\n');
      for (final m in RegExp(r'\b(firstWhere|lastWhere|singleWhere)\(')
          .allMatches(src)) {
        final lineNo = src.substring(0, m.start).split('\n').length;
        // ⚠️ 跳过**整行注释**：文档注释为说明历史必然会提到这些名字
        // （例如 background_service_manager 里解释"刻意不用 firstWhere"那段），
        // 不跳过就会**恒红** —— 恒红的锁比没锁更坏（真修好了也红）。
        // 只跳"整行都是注释"的情形，代码行尾的 `// 注释` 不影响判定。
        final line = lineNo - 1 < lines.length ? lines[lineNo - 1].trim() : '';
        if (line.startsWith('//') ||
            line.startsWith('/*') ||
            line.startsWith('*')) {
          continue;
        }
        scanned++;
        // 取调用点后 300 字符：足够覆盖跨行的 `orElse:`。
        final tail = src.substring(
            m.start, (m.start + 300).clamp(0, src.length));
        if (tail.contains('orElse:')) continue;
        bad.add('${f.path.replaceAll(r'\', '/')}:$lineNo');
      }
    }
    // 反向自检：锁要是"什么都没扫到"，就等于没锁（正则失效/路径错都会静默通过）。
    expect(scanned, greaterThan(0), reason: 'EBI-04 没扫到任何调用点 —— 锁已失效');
    expect(bad, isEmpty,
        reason: '以下位置的 `firstWhere` 没有 `orElse`，找不到会抛 '
            '`Bad state: No element`（崩溃且无提示）→ 改用 `endpointById` 或补 `orElse`：\n'
            '  ${bad.join('\n  ')}');
  });
}
