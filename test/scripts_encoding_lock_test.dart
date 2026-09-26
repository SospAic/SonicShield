import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 脚本编码锁（2026-09-24 新增，来自一次**真实事故**）。
//
// ## 事实（实测，不是推测）
//
// `bootstrap.ps1`、`scripts/gates.ps1`、`scripts/emulator_test.ps1` 都是
// **含中文却没有 UTF-8 BOM** 的 PowerShell 脚本。
//
// PowerShell 5.1 对**无 BOM** 的 `.ps1` 会按**本地代码页**解析（中文环境 = GBK），
// 中文字节被拆错之后**连引号一起吞掉**：
//
// | 文件 | 实测结果（用 `[Parser]::ParseFile` 判定） |
// |---|---|
// | `bootstrap.ps1` | **2 个语法错误**：`字符串缺少终止符`（:51）+ 缺 `}`（:8）⇒ **脚本整体跑不起来** |
// | `scripts/gates.ps1` | 加入新中文字符串后同样崩语法（`意外的标记 }`） |
// | `scripts/emulator_test.ps1` | 侥幸仍能解析（但中文在运行时是乱码） |
//
// 三个文件本次都由**补 BOM** 修好（补后 `parse_errors=0`）。
//
// ## 为什么必须有锁
//
// `Edit` 工具会**剥掉已有 BOM**（本项目已记录过该行为）。也就是说：
// 「现在是对的」不代表「下次编辑后还是对的」，而且**没有任何运行时症状** ——
// 只有脚本在中文 Windows 上直接崩掉。这与项目通则
// 「门禁全绿 ≠ 交付没问题 / 判据要落在真正那件事上」同源。
//
// ⚠️ 本锁只覆盖**清单里列出的文件**。新增 `.ps1` 时必须同步加进 [scriptFiles]，
// 这也是 SCR-01 存在的理由（清单失效 = 整组锁空转）。

/// 受锁的脚本清单：项目自有的 `.ps1` / `.sh`。
const List<String> scriptFiles = [
  'bootstrap.ps1',
  'bootstrap.sh',
  'scripts/gates.ps1',
  'scripts/gates.sh',
  'scripts/emulator_test.ps1',
  'scripts/emulator_test.sh',
  'scripts/install_app.sh',
];

List<int> readBytes(String path) => File(path).readAsBytesSync();

bool hasUtf8Bom(List<int> bytes) =>
    bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;

bool isPureAscii(List<int> bytes) => bytes.every((b) => b < 0x80);

void main() {
  test('SCR-01 清单里的脚本都存在 + 清单非空（防止本组锁空转）', () {
    final missing = scriptFiles.where((p) => !File(p).existsSync()).toList();
    expect(missing, isEmpty,
        reason: '清单里的脚本不存在（被改名/移动后必须同步本锁的 scriptFiles）：$missing');
    expect(scriptFiles.length, greaterThanOrEqualTo(4),
        reason: '清单被删到只剩几条 ⇒ 本组锁恒真，属假绿。');
    expect(scriptFiles.where((p) => p.endsWith('.ps1')).length,
        greaterThanOrEqualTo(2),
        reason: '受锁的 .ps1 少于 2 个 ⇒ SCR-02 覆盖不足。');
    expect(scriptFiles.where((p) => p.endsWith('.sh')).length,
        greaterThanOrEqualTo(2),
        reason: '受锁的 .sh 少于 2 个 ⇒ SCR-03 覆盖不足。');
  });

  test('SCR-02 .ps1 含非 ASCII 时必须带 UTF-8 BOM（否则 PS5.1 按 GBK 解析崩语法）', () {
    final offenders = <String>[];
    for (final p in scriptFiles.where((p) => p.endsWith('.ps1'))) {
      final bytes = readBytes(p);
      if (!hasUtf8Bom(bytes) && !isPureAscii(bytes)) offenders.add(p);
    }
    expect(offenders, isEmpty,
        reason: '以下 .ps1 含非 ASCII 却无 UTF-8 BOM，在中文 Windows 上会被 GBK 解析而崩语法'
            '（实测 bootstrap.ps1 曾因此报「字符串缺少终止符」+ 缺 }，脚本完全不可用）：\n'
            '  ${offenders.join('\n  ')}\n'
            '修法：读出后用 UTF8Encoding(\$true) 重写（带 BOM）。');
  });

  test("SCR-03 .sh 必须是 LF（CRLF 会让 bash 报 ': command not found'）", () {
    final offenders = <String>[];
    for (final p in scriptFiles.where((p) => p.endsWith('.sh'))) {
      if (readBytes(p).contains(0x0D)) offenders.add(p);
    }
    expect(offenders, isEmpty,
        reason: '以下 .sh 含 CR 字节（Windows 换行），在 bash 下会报 '
            "'\\r': command not found 之类的假错：${offenders.join(', ')}");
  });

  test('SCR-04 每个受锁脚本都非空（空文件会让 SCR-02/03 变成空转假绿）', () {
    for (final p in scriptFiles) {
      expect(readBytes(p).length, greaterThan(50),
          reason: '$p 内容异常短（< 50 字节），SCR-02/03 在它上面等于空转。');
    }
  });
}
