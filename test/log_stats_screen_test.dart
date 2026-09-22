/// 每例上限（文件级注解）：本文件有 DB 往返，正常每例 < 1s 跑完。
/// 给 90s 是为了让"万一挂死"快速暴露 —— `testWidgets` 的默认上限是 **10 分钟**，
/// 一个用例挂住就吃掉整轮迭代时间（`task_list_screen_test.dart` 实测踩过 10m21s）。
///
/// ⚠️ `library;` 指令必须**先于所有 import**（`library_directive_not_first`），
/// 所以它和注解只能放文件最顶部 —— 不能跟在 import 后面。
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/features/logs/log_screen.dart';
import 'package:sonic_shield/features/stats/stats_screen.dart';

/// 「日志」分组页的两个子 TAB —— 执行日志（`LogScreen`）与统计看板
/// （`StatsScreen`）—— 的宿主测试。
///
/// ## 为什么值得上锁
///
/// 这两个页面是**审计与复盘**的唯一入口。它们的失败形态全部是**静默**的：
/// 筛选器把不该滤掉的滤掉、副标题把音量/时长算错、导出写出一个**空文件**
/// 却提示"已导出"、统计把"失败"画成成功色。用户看不出，只有真出事去查
/// 日志时才发现"查不到"。
///
/// ## 宿主硬约束（与 `settings_screen_test.dart` 同源）
///
/// 1. **开库放 `setUp`**：`AppDatabase.open` 的 isolate 往返在 `FakeAsync` 里挂死。
/// 2. **用例体里的 DB 操作必须包 `tester.runAsync`**（`dbRead`/`dbWrite`）。
/// 3. **不要用固定轮数 drain 等异步重读**：统一 `waitFor(cond)`，超时**显式 fail**
///    （静默放行会让负向断言恒真）。
/// 4. **不 `pumpAndSettle`**：加载态是 `CircularProgressIndicator`（无限动画）→
///    数据没到就 settle 是**超时**，不是失败得清楚。
/// 5. **收尾推掉 SnackBar 计时**（默认 4s），否则判 "A Timer is still pending"。
/// 6. **每例 `timeout: 90s`**：默认 10 分钟挂死会吃掉整轮迭代时间。
///
/// ## 夹具为什么直接写 SQL
///
/// `LogRepository.append()` 把 `created_at` 取成 `DateTime.now()` —— 同批多行
/// 会落在**同一毫秒**，而 `recent()` 是 `ORDER BY created_at DESC`：平局时
/// 顺序**未定义**。所以夹具直接用 `insert` 指定递增时间戳，让"最新在最上"
/// 这件事有确定答案（否则就是"按下标取值"那一类时红时绿）。
///
/// ## 平台另一侧怎么给
///
/// `path_provider` / `share_plus` 直接**打桩方法通道**（标准编解码器），
/// 不引入 `*_platform_interface` 依赖（会触发 `depend_on_referenced_packages`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const kPathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const kShare = MethodChannel('dev.fluttercommunity.plus/share');

  // ⚠️ 必须是**局部函数**，不能写成局部 getter —— Dart 不允许在函数体内声明 getter。
  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AppDatabase db;
  late Directory tmp;
  late List<MethodCall> shareCalls;

  /// 夹具基准时刻：1 小时前，确保落在 `dailyCounts(days: 7)` 的窗口内。
  final base = DateTime.now().subtract(const Duration(hours: 1));

  setUp(() async {
    db = await AppDatabase.open(inMemoryDatabasePath);
    tmp = Directory.systemTemp.createTempSync('sonic_logs_');
    shareCalls = <MethodCall>[];

    messenger().setMockMethodCallHandler(kPathProvider, (call) async {
      // ⚠️ 方法名是 `getTemporaryDirectory`（不是 `getTemporaryPath`）——
      // 拼错 → 返回 null → `getTemporaryDirectory()` 抛。
      if (call.method == 'getTemporaryDirectory') return tmp.path;
      return null;
    });
    messenger().setMockMethodCallHandler(kShare, (call) async {
      shareCalls.add(call);
      return 'ok'; // → ShareResultStatus.success
    });
  });

  tearDown(() async {
    messenger().setMockMethodCallHandler(kPathProvider, null);
    messenger().setMockMethodCallHandler(kShare, null);
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ───────────────────────── 夹具 ─────────────────────────

  Future<void> dbWrite(
      WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(body);
  }

  /// ⚠️ `maxRounds` 是**防死循环的上限，不是断言**（断言是 `cond()`）——
  /// 提高它**不削弱任何检查**，只是给**真实 IO** 更多轮次。
  /// 依据：2026-09-22 第二十九轮（负载 100% 下 SET-05b 因 60 轮不够而假红，
  /// 单独跑必过）—— 与 `settings_screen_test.dart` 的 `waitFor` 同一处置。
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() cond, {
    required String reason,
    int maxRounds = 300,
  }) async {
    for (var i = 0; i < maxRounds; i++) {
      if (cond()) return;
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('等待超时（$maxRounds 轮）：$reason');
  }

  Future<void> waitForText(WidgetTester tester, String substring) => waitFor(
        tester,
        () => find.textContaining(substring).evaluate().isNotEmpty,
        reason: '应出现含「$substring」的文案',
      );

  Future<void> settleSnackBars(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 触发下拉刷新。
  ///
  /// ⚠️ **不用 `fling`/`drag` 驱动**：实测（本文件 LOG-10）无论幅度与速度，
  /// `RefreshIndicator` 都收不到手势 —— 手势识别是 Flutter 框架自身的行为，
  /// 在 `FakeAsync` 里要靠 `pumpAndSettle` 走完 indicator 的入场动画才生效，
  /// 而项目纪律禁止用 `pumpAndSettle` 当"等数据"用。
  /// 直接调 `RefreshIndicatorState.show()` 把**本页的接线**（`onRefresh` 里
  /// `ref.invalidate(...)` 真的让 UI 重读）测掉，手势本身交给框架。
  Future<void> pullToRefresh(WidgetTester tester) async {
    final st = tester.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator));
    unawaited(st.show());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// 直接插行：`created_at` 由调用方给，顺序才是确定的。
  Future<void> seed(WidgetTester tester, List<Map<String, Object?>> rows) =>
      dbWrite(tester, () async {
        for (final r in rows) {
          await db.db.insert('exec_logs', r);
        }
      });

  Map<String, Object?> logRow({
    required int atMs,
    String source = 'schedule',
    String action = 'play',
    String status = 'success',
    double? volume,
    int? durationMs,
    String? message,
  }) =>
      {
        'source': source,
        'action': action,
        'status': status,
        'volume': volume,
        'duration_ms': durationMs,
        'message': message,
        'created_at': atMs,
      };

  String rowTitle(int atMs,
          {String source = 'schedule',
          String action = 'play',
          String status = 'success'}) =>
      '${DateFormat('MM-dd HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(atMs))}'
      ' · $source · $action · $status';

  Future<void> pumpLog(
    WidgetTester tester, {
    bool embedded = false,
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => db),
          ...overrides,
        ],
        child: MaterialApp(home: LogScreen(embedded: embedded)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> pumpStats(
    WidgetTester tester, {
    bool embedded = false,
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => db),
          ...overrides,
        ],
        child: MaterialApp(home: StatsScreen(embedded: embedded)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  // ───────────────────────── 执行日志 ─────────────────────────

  group('LOG 执行日志', () {
    testWidgets('LOG-01 空库：说清楚"以后会有什么"，不是一片空白', (tester) async {
      await pumpLog(tester);
      await waitForText(tester, '暂无日志');

      expect(find.text('执行日志'), findsOneWidget);
      expect(find.textContaining('开启守护并添加任务后'), findsOneWidget);
    });

    testWidgets('LOG-02 一行日志的标题与副标题：时间/来源/动作/状态 + 音量/时长/说明',
        (tester) async {
      final at = base.millisecondsSinceEpoch;
      await seed(tester, [
        logRow(
            atMs: at,
            volume: 0.9,
            durationMs: 1500,
            message: '播放完成'),
      ]);
      await pumpLog(tester);
      await waitForText(tester, '播放完成');

      expect(find.text(rowTitle(at)), findsOneWidget);
      // 副标题三要素的格式（音量取整百分比、时长一位小数秒）。
      expect(find.text('音量90% · 1.5s · 播放完成'), findsOneWidget);
      // 图标跟着 action 走（写错只会显示成别的图标，不抛异常）。
      expect(
          find.descendant(
              of: find.widgetWithText(ListTile, rowTitle(at)),
              matching: find.byIcon(Icons.volume_up)),
          findsOneWidget);
    });

    testWidgets('LOG-03 六种 action 的图标各不相同（漏一种用户就分不清）',
        (tester) async {
      final t0 = base.millisecondsSinceEpoch;
      const pairs = {
        'play': Icons.volume_up,
        'tts': Icons.record_voice_over,
        'record': Icons.fiber_manual_record,
        'notify': Icons.notifications,
        'vibrate': Icons.vibration,
        'guard': Icons.bolt, // 未知值走兜底
      };
      var i = 0;
      await seed(tester, [
        for (final e in pairs.entries)
          logRow(atMs: t0 + (i++) * 1000, action: e.key),
      ]);
      await pumpLog(tester);
      await waitForText(tester, 'guard');

      for (final e in pairs.entries) {
        expect(
            find.descendant(
                of: find.widgetWithText(
                    ListTile, rowTitle(t0 + pairs.keys.toList().indexOf(e.key) * 1000, action: e.key)),
                matching: find.byIcon(e.value)),
            findsOneWidget,
            reason: 'action=${e.key} 应显示 ${e.value}');
      }
    });

    testWidgets('LOG-04 三种 status 的颜色各不相同', (tester) async {
      final t0 = base.millisecondsSinceEpoch;
      await seed(tester, [
        logRow(atMs: t0, status: 'success'),
        logRow(atMs: t0 + 1000, status: 'failed'),
        logRow(atMs: t0 + 2000, status: 'skipped'),
      ]);
      await pumpLog(tester);
      await waitForText(tester, 'skipped');

      Color colorOf(String title) => tester
          .widget<Icon>(find.descendant(
              of: find.widgetWithText(ListTile, title),
              matching: find.byType(Icon)))
          .color!;

      final ok = colorOf(rowTitle(t0, status: 'success'));
      final bad = colorOf(rowTitle(t0 + 1000, status: 'failed'));
      final skip = colorOf(rowTitle(t0 + 2000, status: 'skipped'));

      expect(ok, Colors.green);
      expect(bad, Colors.red);
      expect(skip, Colors.orange, reason: '未知/跳过走兜底色，不能与成功混淆');
      expect({ok, bad, skip}, hasLength(3), reason: '三种状态必须互相可区分');
    });

    testWidgets('LOG-05 筛选：四个分段各自只留对应状态，且能切回全部', (tester) async {
      final t0 = base.millisecondsSinceEpoch;
      await seed(tester, [
        logRow(atMs: t0, status: 'success', message: 'S'),
        logRow(atMs: t0 + 1000, status: 'failed', message: 'F'),
        logRow(atMs: t0 + 2000, status: 'skipped', message: 'K'),
      ]);
      await pumpLog(tester);
      await waitForText(tester, 'S');

      expect(find.byType(ListTile), findsNWidgets(3));

      await tester.tap(find.text('成功'));
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.text(rowTitle(t0, status: 'success')), findsOneWidget);

      await tester.tap(find.text('失败'));
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.text(rowTitle(t0 + 1000, status: 'failed')), findsOneWidget);

      await tester.tap(find.text('跳过'));
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.text(rowTitle(t0 + 2000, status: 'skipped')), findsOneWidget);

      await tester.tap(find.text('全部'));
      await tester.pump();
      expect(find.byType(ListTile), findsNWidgets(3));
    });

    testWidgets('LOG-06 筛选后为空也要给空态，而不是留白', (tester) async {
      await seed(tester, [logRow(atMs: base.millisecondsSinceEpoch)]);
      await pumpLog(tester);
      await waitForText(tester, 'schedule');

      await tester.tap(find.text('失败'));
      await tester.pump();

      expect(find.byType(ListTile), findsNothing);
      expect(find.textContaining('暂无日志'), findsOneWidget);
    });

    testWidgets('LOG-07 空库导出：明说"暂无日志可导出"，不生成文件', (tester) async {
      await pumpLog(tester);
      await waitForText(tester, '暂无日志');

      await tester.tap(find.byIcon(Icons.ios_share));
      await waitForText(tester, '暂无日志可导出');

      expect(tmp.listSync(), isEmpty, reason: '没数据就不该落文件');
      expect(shareCalls, isEmpty);
      await settleSnackBars(tester);
    });

    testWidgets('LOG-08 导出 CSV：表头齐全、逐行转义、交给分享面板',
        (tester) async {
      final t0 = base.millisecondsSinceEpoch;
      await seed(tester, [
        logRow(
            atMs: t0,
            source: 'manual',
            action: 'tts',
            status: 'success',
            volume: 0.8,
            durationMs: 2000,
            message: '含"引号"的说明'),
        logRow(atMs: t0 + 1000, status: 'failed', message: null),
      ]);
      await pumpLog(tester);
      await waitForText(tester, 'tts');

      await tester.tap(find.byIcon(Icons.ios_share));
      await waitFor(
        tester,
        () => shareCalls.any((c) => c.method == 'shareFiles'),
        reason: '导出应最终调用分享面板',
      );

      final files = tmp.listSync().whereType<File>().toList();
      expect(files, hasLength(1), reason: '应落一个 CSV');
      final csv = files.single.readAsStringSync();

      expect(csv,
          startsWith('time,source,action,status,task_id,occurrence_id,'
              'volume,duration_ms,message\n'),
          reason: '表头是列契约，少一列下游就对不上');
      // CSV 转义：内部引号要翻倍（否则表格会串列）。
      expect(csv, contains('"含""引号""的说明"'));
      // 两行数据 + 一行表头。
      expect(csv.trim().split('\n'), hasLength(3));

      final share = shareCalls.firstWhere((c) => c.method == 'shareFiles');
      expect(share.arguments.toString(), contains('声盾执行日志'));
      await settleSnackBars(tester);
    });

    testWidgets('LOG-09 embedded：作为子 TAB 时不带标题、不带返回键', (tester) async {
      await seed(tester, [logRow(atMs: base.millisecondsSinceEpoch)]);
      await pumpLog(tester, embedded: true);
      await waitForText(tester, 'schedule');

      expect(find.text('执行日志'), findsNothing);
      expect(find.byType(BackButton), findsNothing);
      // 导出按钮必须留着（embedded 只去掉标题与返回键）。
      expect(find.byIcon(Icons.ios_share), findsOneWidget);
    });

    testWidgets('LOG-10 下拉刷新会重新读库（新写入的行要出现）', (tester) async {
      final t0 = base.millisecondsSinceEpoch;
      // 空库时 body 是 `Center`（没有 `RefreshIndicator`）→ 先给一条。
      await seed(tester, [logRow(atMs: t0, message: '旧行')]);
      await pumpLog(tester);
      await waitForText(tester, '旧行');

      await seed(tester, [logRow(atMs: t0 + 999000, message: '刷新后可见')]);

      await pullToRefresh(tester);
      await waitForText(tester, '刷新后可见');
    });

    testWidgets('LOG-11 加载失败：库里抛错要有「加载失败」，不是一片空白',
        (tester) async {
      // logListProvider 依赖 logRepoProvider：覆盖成抛错 → AsyncError →
      // `logs.when(error:)` 渲染（覆盖 error 分支）。
      await pumpLog(tester, overrides: [
        logRepoProvider.overrideWith((ref) => throw StateError('注入错误')),
      ]);
      await waitForText(tester, '加载失败');
      expect(find.textContaining('注入错误'), findsOneWidget);
    });
  });

  // ───────────────────────── 统计看板 ─────────────────────────

  group('ST 统计看板', () {
    testWidgets('ST-01 空库：给出"以后会看到什么"，不是一片空白', (tester) async {
      await pumpStats(tester);
      await waitForText(tester, '暂无数据');

      expect(find.text('统计看板'), findsOneWidget);
      expect(find.textContaining('开启守护并添加任务后'), findsOneWidget);
    });

    testWidgets('ST-02 三个区块都在，且柱状图/动作分布/状态占比都吃到数据',
        (tester) async {
      final t0 = base.millisecondsSinceEpoch;
      await seed(tester, [
        logRow(atMs: t0, action: 'play', status: 'success'),
        logRow(atMs: t0 + 1000, action: 'tts', status: 'success'),
        logRow(atMs: t0 + 2000, action: 'play', status: 'failed'),
      ]);
      await pumpStats(tester);
      await waitForText(tester, '近 7 天执行趋势');

      expect(find.text('动作分布'), findsOneWidget);
      expect(find.text('状态占比'), findsOneWidget);

      // 柱状图：当天 3 条 → 柱顶数字 3。
      expect(find.text('3'), findsWidgets);
      // 动作分布两行（play=2、tts=1）。
      expect(find.text('play'), findsOneWidget);
      expect(find.text('tts'), findsOneWidget);
      // 状态占比两个 chip。
      expect(find.text('success 2'), findsOneWidget);
      expect(find.text('failed 1'), findsOneWidget);
    });

    testWidgets('ST-03 状态 chip 的图标按状态区分（success/failed/其它）',
        (tester) async {
      final t0 = base.millisecondsSinceEpoch;
      await seed(tester, [
        logRow(atMs: t0, status: 'success'),
        logRow(atMs: t0 + 1000, status: 'failed'),
        logRow(atMs: t0 + 2000, status: 'skipped'),
      ]);
      await pumpStats(tester);
      await waitForText(tester, '状态占比');

      IconData iconOf(String label) => tester
          .widget<Icon>(find.descendant(
              of: find.widgetWithText(Chip, label),
              matching: find.byType(Icon)))
          .icon!;

      expect(iconOf('success 1'), Icons.check_circle);
      expect(iconOf('failed 1'), Icons.error);
      expect(iconOf('skipped 1'), Icons.remove_circle_outline,
          reason: '第三种状态不能借用成功/失败的图标');
    });

    testWidgets('ST-04 动作分布最多 8 行（多了会撑爆看板）', (tester) async {
      final t0 = base.millisecondsSinceEpoch;
      await seed(tester, [
        for (var i = 0; i < 9; i++)
          logRow(atMs: t0 + i * 1000, action: 'act$i'),
      ]);
      await pumpStats(tester);
      await waitForText(tester, '动作分布');

      var shown = 0;
      for (var i = 0; i < 9; i++) {
        if (find.text('act$i').evaluate().isNotEmpty) shown++;
      }
      expect(shown, 8, reason: '`take(8)` 的边界：多一条就溢到屏幕外');
    });

    testWidgets('ST-05 embedded：作为子 TAB 时不自带 AppBar', (tester) async {
      await seed(tester, [logRow(atMs: base.millisecondsSinceEpoch)]);
      await pumpStats(tester, embedded: true);
      await waitForText(tester, '近 7 天执行趋势');

      expect(find.text('统计看板'), findsNothing);
    });

    testWidgets('ST-06 下拉刷新会重新聚合（新写入要计入）', (tester) async {
      final t0 = base.millisecondsSinceEpoch;
      // ⚠️ 空库时 body 是 `Center`（没有 ListView）→ 先给一条，才有得下拉。
      await seed(tester, [logRow(atMs: t0, action: 'tts')]);
      await pumpStats(tester);
      await waitForText(tester, '近 7 天执行趋势');

      await seed(tester, [
        logRow(atMs: t0 + 1000, action: 'play'),
      ]);

      await pullToRefresh(tester);
      await waitForText(tester, 'play');
    });

    testWidgets('ST-07 加载失败：聚合抛错要有「加载失败」，不是一片空白',
        (tester) async {
      // `_snapshot()` 在 initState 里 `ref.read(logRepoProvider.future)` ——
      // 覆盖成抛错 → FutureBuilder `snap.hasError` 渲染（覆盖 error 分支）。
      await pumpStats(tester, overrides: [
        logRepoProvider.overrideWith((ref) => throw StateError('注入错误')),
      ]);
      await waitForText(tester, '加载失败');
      expect(find.textContaining('注入错误'), findsOneWidget);
    });
  });
}
