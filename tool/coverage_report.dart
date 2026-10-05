// ignore_for_file: avoid_print
/// 覆盖率报告 —— 解析 `coverage/lcov.info`，输出**分母完整**的覆盖率。
///
/// ## 为什么不能直接看 `lcov.info` 里的总计
///
/// Dart 覆盖率只统计**运行期被加载过的库**。未被任何 import 触及的文件
/// 在 lcov 里**完全不存在**（不计分子也不计分母）→ 越不测越"好看"。
/// 本工具因此做三件事：
///
/// 1. 拿 `lib/**/*.dart` **现场枚举**当基准，逐文件核对 lcov 里有没有 `SF:`
///    记录。**缺一个就报错**（说明 `test/coverage_sentinel_test.dart` 没刷新）；
/// 2. 输出**两个口径**：`全局`（所有 lib 代码）与 `可测面`（排除设备层）；
/// 3. 设备层豁免是**显式白名单 + 每条带理由**，且**豁免文件不存在时直接失败**
///    （防止"豁免一个已删除的文件"这种静默注水）。
///
/// ## 两个口径怎么用（别混着用）
///
/// | 口径 | 含义 | 用途 |
/// |---|---|---|
/// | 全局 | 所有 `lib/` 可执行行 | **对外诚实数字**，任何汇报都用它 |
/// | 可测面 | 全局 − 设备层豁免 | **门禁阈值**用这个（宿主测试物理上跑不了 native 插件） |
///
/// ⚠️ **不要把"可测面"当成"全局"来汇报。** 两个数字必须同时出现，
/// 否则就回到了"靠口径调整来美化指标"的老路。
///
/// ## 用法
///
/// ```bash
/// dart run tool/coverage_report.dart                 # 人读报告
/// dart run tool/coverage_report.dart --top=25        # 只看缺口最大的 25 个文件
/// dart run tool/coverage_report.dart --gate=99       # 可测面 < 99% 则退出码 1
/// dart run tool/coverage_report.dart --json          # 机器可读
/// ```
library;

import 'dart:convert';
import 'dart:io';

/// 设备层豁免白名单：`文件 → 为什么宿主测不了 + 由谁覆盖`。
///
/// ⚠️ 收录标准（**严格**，别为了数字好看往里塞）：
/// 该文件的未覆盖行**主要由"只能真机/模拟器执行"的路径构成** ——
/// native 插件调用、引擎 isolate、真实音频/视频/网络设备。
/// 纯逻辑（模型、协议编解码、状态机）**一律不收**，必须写宿主测试。
///
/// 判定方法：先跑一遍 `--top`，逐个人工看未覆盖行到底是什么。
///
/// ⚠️ **收录时必须在 `reason` 里同时给出"结构证据"**，格式见
/// `test/device_exemption_lock_test.dart`（DEX 系列）：
/// 每条豁免都绑一个**必须真实存在于该文件里的字面量标记**
/// （例如引擎 isolate 的 `@pragma('vm:entry-point')`）。
/// 一旦有人把这个文件改成纯逻辑，标记消失 → 锁立刻判红，
/// 豁免就无法继续赖在白名单里。这保证了白名单**藏不住**退化的代码。
const Map<String, String> _deviceOnly = <String, String>{
  // ── 引擎 isolate 本体 ────────────────────────────────────────────────
  // 未覆盖 508/516 行。**唯一**的顶层入口是
  // `@pragma('vm:entry-point') engineEntryPoint(ServiceInstance service)`，
  // 它只在 `flutter_background_service` 拉起的**独立 isolate** 里被调用；
  // 函数体第一步就是 `DartPluginRegistrant.ensureInitialized()`，随后
  // 全部依赖真实平台能力：Battery 插件读电量、AppDatabase 开库、
  // PlaybackService 出声、NativeBridge 振动。宿主测试**无法**构造
  // `ServiceInstance`，也拿不到那条 isolate。
  // 由谁覆盖：真机/模拟器上的后台引擎集成测试（docs/12 §63.4）。
  'lib/services/background_engine.dart':
      '引擎 isolate 本体：入口 @pragma(\'vm:entry-point\') engineEntryPoint'
          '(ServiceInstance) 只在 flutter_background_service 拉起的独立 isolate '
          '里执行，函数体首句即 DartPluginRegistrant.ensureInitialized()，'
          '后续依赖 Battery/AppDatabase/PlaybackService/NativeBridge 等真实平台能力；'
          '宿主测试无法构造 ServiceInstance。覆盖方：真机后台引擎集成测试。',

  // ── 应用装配入口 ──────────────────────────────────────────────────────
  // 未覆盖 36/36 行。`main()` 是 `runApp` 之前的**原生插件装配链**：
  // NotificationService.createServiceChannel（本地通知插件）、
  // BackgroundServiceManager.init（后台服务插件）、FlutterTts 构造，
  // 且以 `runApp` 收尾 —— 在宿主测试里调用它等于把整个 App 真的跑起来。
  // 由谁覆盖：真机冷启动冒烟（docs/12 §63.4）。
  'lib/main.dart':
      '应用装配入口：main() 是 runApp 之前的原生插件装配链（本地通知渠道、'
          '后台服务 init、FlutterTts），并以 runApp(const ProviderScope(...)) 收尾；'
          '宿主测试调用它等于把整个 App 真正跑起来。覆盖方：真机冷启动冒烟。',
};

/// 声明式数据文件白名单：**整文件只有 `static const` 声明，没有可执行语句**。
///
/// 这类文件 Dart VM **不产生任何覆盖记录**（lcov 里没有 `SF:`），
/// 但它对分子/分母的贡献**都是 0** —— 排除它不会让百分比变好看，
/// 所以不算"分母漏算"。
///
/// ⚠️ **双向锁**：若哪天这类文件里出现了函数体/语句，它**必然**会出现在
/// lcov 里 → 本清单的对应条目立刻被判为"失效"，工具报错要求删除。
/// 因此这个清单**藏不住真实的覆盖漏洞** —— 它只能装"确实没有可执行行"的文件。
const Set<String> _noExecutableLines = <String>{
  'lib/core/constants.dart', // AppMeta/Channels/SchedulerConfig… 全是 static const
  // 纯抽象接口：整文件只有 `abstract interface class PttStreamSink` 的
  // 三个方法**签名**（无方法体、无字段初始化），Dart VM 不产生任何覆盖记录。
  // 具体实现（PttPlaybackSession）在 playback_service.dart 一侧照常计入分母。
  'lib/services/ptt_stream_sink.dart',
};

/// 解析 lcov.info → `文件路径(正斜杠) → (LF, LH)`。
Map<String, ({int lf, int lh})> parseLcov(String text) {
  final out = <String, ({int lf, int lh})>{};
  String? cur;
  var lf = 0, lh = 0;

  void flush() {
    if (cur != null) out[cur!] = (lf: lf, lh: lh);
    cur = null;
    lf = 0;
    lh = 0;
  }

  for (final raw in const LineSplitter().convert(text)) {
    if (raw.startsWith('SF:')) {
      flush();
      cur = raw.substring(3).trim().replaceAll(r'\', '/');
    } else if (raw.startsWith('LF:')) {
      lf = int.tryParse(raw.substring(3).trim()) ?? 0;
    } else if (raw.startsWith('LH:')) {
      lh = int.tryParse(raw.substring(3).trim()) ?? 0;
    } else if (raw == 'end_of_record') {
      flush();
    }
  }
  flush();
  return out;
}

/// `lib/` 下所有 `.dart`（正斜杠相对路径，已排序）。
List<String> libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((f) => f.path.replaceAll(r'\', '/'))
    .where((p) => p.endsWith('.dart'))
    .toList()
  ..sort();

String pct(int hit, int found) =>
    found == 0 ? '  n/a' : (hit * 100 / found).toStringAsFixed(2).padLeft(6);

void main(List<String> args) {
  final top = int.tryParse(
      args.firstWhere((a) => a.startsWith('--top='), orElse: () => '--top=20').split('=')[1]) ??
      20;
  final asJson = args.contains('--json');
  final gateArg = args.firstWhere((a) => a.startsWith('--gate='), orElse: () => '');
  final gate = gateArg.isEmpty ? null : double.tryParse(gateArg.split('=')[1]);
  // 分子硬下限（第三十四轮新增）。理由见文件末尾 `_minCoveredRationale`。
  final minCovArg = args
      .firstWhere((a) => a.startsWith('--min-covered='), orElse: () => '');
  final minCovered =
      minCovArg.isEmpty ? null : int.tryParse(minCovArg.split('=')[1]);

  final lcovFile = File('coverage/lcov.info');
  if (!lcovFile.existsSync()) {
    stderr.writeln('找不到 coverage/lcov.info —— 先跑：\n'
        '  flutter test --coverage --exclude-tags perf');
    exit(2);
  }

  final cov = parseLcov(lcovFile.readAsStringSync());
  final lib = libFiles();

  // ── 锁 1：分母完整性（lib 下每个文件都必须在 lcov 里出现） ──────────────
  final notInstrumented = lib
      .where((f) => !cov.containsKey(f) && !_noExecutableLines.contains(f))
      .toList();
  // ── 锁 2：豁免清单不得含已不存在的文件（防"豁免一个幽灵文件"注水） ──────
  final libSet = lib.toSet();
  final staleExempt = _deviceOnly.keys.where((f) => !libSet.contains(f)).toList();
  // ── 锁 3：豁免文件必须真的在 lcov 里（否则豁免毫无意义） ────────────────
  final exemptNoData =
      _deviceOnly.keys.where((f) => !cov.containsKey(f) && libSet.contains(f)).toList();
  // ── 锁 4：白名单反向自检 —— 有可执行行的文件不得躺在白名单里 ─────────────
  final staleNoExec =
      _noExecutableLines.where((f) => cov.containsKey(f)).toList();

  final problems = <String>[
    if (notInstrumented.isNotEmpty)
      '分母不完整：lib 下有 ${notInstrumented.length} 个文件没有 SF: 记录\n'
          '  ${notInstrumented.join('\n  ')}\n'
          '  修复：dart run tool/gen_coverage_sentinel.dart',
    if (staleExempt.isNotEmpty)
      '豁免清单含已不存在的文件（会静默注水）：\n  ${staleExempt.join('\n  ')}',
    if (exemptNoData.isNotEmpty)
      '豁免清单含无覆盖率数据的文件：\n  ${exemptNoData.join('\n  ')}',
    if (staleNoExec.isNotEmpty)
      '白名单失效：这些文件已有可执行行（出现在 lcov 里），必须从 '
          '_noExecutableLines 移除，否则会漏算：\n  ${staleNoExec.join('\n  ')}',
  ];

  // ── 汇总 ────────────────────────────────────────────────────────────────
  var gLf = 0, gLh = 0; // 全局
  var eLf = 0, eLh = 0; // 设备层
  final rows = <({String f, int lf, int lh, bool exempt})>[];
  for (final f in lib) {
    final c = cov[f];
    if (c == null) continue;
    final ex = _deviceOnly.containsKey(f);
    gLf += c.lf;
    gLh += c.lh;
    if (ex) {
      eLf += c.lf;
      eLh += c.lh;
    }
    rows.add((f: f, lf: c.lf, lh: c.lh, exempt: ex));
  }
  final tLf = gLf - eLf, tLh = gLh - eLh; // 可测面

  final globalPct = gLf == 0 ? 0.0 : gLh * 100 / gLf;
  final testablePct = tLf == 0 ? 0.0 : tLh * 100 / tLf;

  if (asJson) {
    print(const JsonEncoder.withIndent('  ').convert({
      'global': {'hit': gLh, 'found': gLf, 'pct': double.parse(globalPct.toStringAsFixed(2))},
      'testable': {
        'hit': tLh,
        'found': tLf,
        'pct': double.parse(testablePct.toStringAsFixed(2))
      },
      'deviceOnly': {'hit': eLh, 'found': eLf, 'files': _deviceOnly},
      'uncovered': [
        for (final r in rows.where((r) => r.lf - r.lh > 0))
          {'file': r.f, 'missing': r.lf - r.lh, 'lf': r.lf, 'lh': r.lh, 'exempt': r.exempt}
      ],
      'problems': problems,
    }));
  } else {
    print('=' * 78);
    print('声盾覆盖率报告（分母 = lib/ 全部 ${lib.length} 个文件，已由哨兵保证完整）');
    print('=' * 78);
    print('  全局（对外诚实数字）  ${pct(gLh, gLf)}%   $gLh / $gLf');
    print('  可测面（门禁阈值口径）${pct(tLh, tLf)}%   $tLh / $tLf');
    print('  设备层豁免            ${pct(eLh, eLf)}%   $eLh / $eLf'
        '（${_deviceOnly.length} 个文件）');
    print('');

    if (_deviceOnly.isEmpty) {
      print('  设备层豁免清单为空 —— 所有 lib 代码都计入可测面。');
    } else {
      print('── 设备层豁免（每条都必须有理由，否则就是橡皮章）${'─' * 26}');
      for (final e in _deviceOnly.entries) {
        final c = cov[e.key];
        print('  ${e.key}');
        print('    覆盖 ${c?.lh ?? 0}/${c?.lf ?? 0}  理由：${e.value}');
      }
    }
    print('');

    final gaps = rows.where((r) => r.lf - r.lh > 0).toList()
      ..sort((a, b) => (b.lf - b.lh).compareTo(a.lf - a.lh));
    print('── 未覆盖行最多的 $top 个文件${'─' * 44}');
    print('  ${"未覆盖".padLeft(6)} ${"LF".padLeft(6)} ${"LH".padLeft(6)}  '
        '${"%".padLeft(7)}  文件');
    for (final r in gaps.take(top)) {
      final mark = r.exempt ? '[设备]' : '      ';
      print('  ${(r.lf - r.lh).toString().padLeft(6)} ${r.lf.toString().padLeft(6)} '
          '${r.lh.toString().padLeft(6)}  ${pct(r.lh, r.lf)}%  $mark ${r.f}');
    }
    final totalGap = gaps.fold<int>(0, (s, r) => s + (r.lf - r.lh));
    print('  ${'─' * 74}');
    print('  未覆盖合计 $totalGap 行；其中设备层豁免 '
        '${gaps.where((r) => r.exempt).fold<int>(0, (s, r) => s + (r.lf - r.lh))} 行');
    print('');
  }

  if (problems.isNotEmpty) {
    print('─' * 78);
    print('❌ 报告不可信，先修这些问题：');
    for (final p in problems) {
      print('  · $p');
    }
    exit(2);
  }

  if (gate != null) {
    if (testablePct + 1e-9 < gate) {
      print('❌ 门禁未过：可测面 ${testablePct.toStringAsFixed(2)}% < $gate%');
      exit(1);
    }
    print('✅ 门禁通过：可测面 ${testablePct.toStringAsFixed(2)}% ≥ $gate%');
  }

  // ── 分子硬下限 ────────────────────────────────────────────────────────
  //
  // 为什么百分比之外**还要**一个绝对数下限：分母不是常数。
  // 每当我们**合规地**新增"宿主不可达但安全/正确性必需"的代码（平台插件
  // 胶水、MQTT 连接、原生桥调用），分母就会变大，百分比被**稀释** ——
  // 于是"什么都不做"反而比"老实加防护"更好看。这个指标会奖励错误的行为。
  //
  // [tLh]（可测面已覆盖行数）才是**真实进度**：它不随分母波动，
  // 而且"给新代码补测试"会直接抬高它。所以百分比守住"密度"，
  // 绝对数守住"总量不许倒退"。
  if (minCovered != null) {
    if (tLh < minCovered) {
      print('❌ 门禁未过：可测面已覆盖行数 $tLh < $minCovered'
          '（分母 $tLf；百分比 ${testablePct.toStringAsFixed(2)}%）');
      print('   绝对数倒退说明**已覆盖的行被删/被改掉了**（或新代码没配测试），'
          '不是"分母变大"能解释的。');
      exit(1);
    }
    print('✅ 分子下限通过：已覆盖 $tLh ≥ $minCovered（分母 $tLf）');
  }
}
