// 合并多份 lcov.info —— **分批跑覆盖率**时用。
//
// ## 为什么需要它
// `flutter test --coverage` 会把全部测试文件放进**一次**运行里跑，
// 宿主机内存被别的进程（Docker / WSL2 的 vmmemWSL）吃掉时会在中途
// **OOM 崩溃**（实测：`allocation.cc: 22: error: Out of memory.` +
// `Could not start thread DartWorker`，跑到第 534 例就死）。
// 崩溃时日志文件里**没有 `[E]` 行**，所以 `FAILURE_LINES=0` 是假绿；
// 而 `coverage/lcov.info` 仍是**上一轮的陈旧产物**，覆盖率 ratchet
// 于是拿旧数据过闸 —— 整条链都是假的。
//
// 拆批跑能绕开内存问题，但每批只会各自**覆盖**一次 `coverage/lcov.info`。
// 本工具把多份分片合成一份，语义与 `lcov -a` 一致：
//   · 同一文件的行号取**并集**；
//   · 命中次数**相加**（同一行在两批里各跑过 3 次 ⇒ 6）；
//   · `LF` = 并集行数，`LH` = 并集里命中数 > 0 的行数。
//
// ⚠️ 不能对 `LF` / `LH` 取 max：文件 X 的第 5 行只在 A 批被覆盖、
// 第 9 行只在 B 批被覆盖时，两批的 LH 都是 1，而真值是 2。
//
// 用法：dart run tool/lcov_merge.dart <输出> <分片1> [<分片2> ...]
import 'dart:io';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/lcov_merge.dart <输出> <分片1> [<分片2> ...]');
    exit(64);
  }
  final outPath = args[0];
  final merged = <String, Map<int, int>>{};
  final order = <String>[];

  for (final part in args.skip(1)) {
    final f = File(part);
    if (!f.existsSync()) {
      stderr.writeln('缺少分片: $part');
      exit(66);
    }
    var cur = '';
    for (final raw in f.readAsStringSync().split('\n')) {
      final line = raw.trimRight();
      if (line.startsWith('SF:')) {
        cur = line.substring(3).trim();
        if (!merged.containsKey(cur)) {
          merged[cur] = <int, int>{};
          order.add(cur);
        }
      } else if (line.startsWith('DA:') && cur.isNotEmpty) {
        final body = line.substring(3);
        final comma = body.indexOf(',');
        if (comma < 0) continue;
        final ln = int.tryParse(body.substring(0, comma));
        final hit = int.tryParse(body.substring(comma + 1));
        if (ln == null || hit == null) continue;
        final m = merged[cur]!;
        m[ln] = (m[ln] ?? 0) + hit;
      }
    }
  }

  final sb = StringBuffer();
  var totalLf = 0;
  var totalLh = 0;
  for (final sf in order) {
    final m = merged[sf]!;
    final lines = m.keys.toList()..sort();
    final lh = lines.where((l) => (m[l] ?? 0) > 0).length;
    totalLf += lines.length;
    totalLh += lh;
    sb.writeln('SF:$sf');
    for (final ln in lines) {
      sb.writeln('DA:$ln,${m[ln]}');
    }
    sb.writeln('LF:${lines.length}');
    sb.writeln('LH:$lh');
    sb.writeln('end_of_record');
  }
  File(outPath).writeAsStringSync(sb.toString());
  stdout.writeln('merged ${order.length} files -> $outPath '
      '(LF=$totalLf, LH=$totalLh)');
}
