import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/settings/settings_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

/// 设置页（`SettingsScreen`）的宿主回归锁。
///
/// ## 这个页面为什么值得上锁
///
/// 它一个人扛了三件"出事没人知道"的事：
/// 1. **电源策略 / 免打扰时段落库** —— 只改内存的话，重启后策略回弹、
///    免打扰时段失守，而免打扰是合规护栏（docs/08），静默失守是红线；
/// 2. **备份导出/导入** —— 导入必须"默认停用 + 批量原子"，否则用户一导入
///    就有任务自动开跑；
/// 3. **保活引导 / 精确闹钟深链** —— 打错通道名只会静默返回 null，
///    用户以为设置好了，实际后台早被杀。
///
/// ## 宿主硬约束（与 `router_test.dart` / `task_list_screen_test.dart` 同源）
///
/// 1. **开库放 `setUp`**：`AppDatabase.open` 的 isolate 往返在 `FakeAsync`
///    里会**永久挂死**。
/// 2. **用例体里的 DB 操作必须包 `tester.runAsync`**（`databaseFactoryFfi`
///    把 SQLite 放后台 isolate）。
/// 3. **不要用固定轮数 drain 等异步重读**：`ref.invalidate()` 后的重读不是
///    同步的，固定轮数会时快时慢。统一 `waitFor(cond)`，超时**显式 fail**。
/// 4. **不 `pumpAndSettle`**：本页虽然自身没有无限动画，但导入/导出期间
///    会挂 SnackBar 计时，`pumpAndSettle` 语义上不可靠。
/// 5. **收尾推掉 SnackBar 计时**，否则判 "A Timer is still pending"。
/// 6. **每个用例 `timeout: 90s`**：默认 10 分钟挂死会吃掉整轮迭代。
///
/// ## 平台另一侧怎么给
///
/// 三个插件都不能用"真机那一侧"，但**都不能靠 `implements` 伪造**：
/// - `path_provider` / `share_plus`：直接**打桩方法通道**（标准编解码器），
///   不引入 `*_platform_interface` 依赖（那会触发 `depend_on_referenced_packages`）。
/// - `file_picker`：它是直接依赖，用官方给的注入点 `FilePicker.platform = …`。
///
/// `ExportCrypto` 是纯 Dart（PBKDF2+AES-GCM），宿主可真实跑通。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const perTest = Timeout(Duration(seconds: 90));
  const kPathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const kShare = MethodChannel('dev.fluttercommunity.plus/share');
  const kNative = MethodChannel('sonic_shield/native');

  // ⚠️ 必须是**局部函数**，不能写成局部 getter —— Dart 不允许在函数体内声明
  // getter（会直接编译失败）。
  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AppDatabase db;
  late Directory tmp;
  late List<MethodCall> shareCalls;
  late List<MethodCall> nativeCalls;

  setUp(() async {
    db = await AppDatabase.open(inMemoryDatabasePath);
    BackgroundServiceManager.replanHook = () async {};
    // 非 Android/iOS 宿主上 `FlutterBackgroundServicePlatform.instance` 会**抛**
    // （见 `background_service_manager.dart` 的 `invokeHook` 注释）——
    // 不注入的话，"电源策略"这条路径在宿主上根本跑不到 `setState`。
    BackgroundServiceManager.invokeHook = (method, args) async {};
    tmp = Directory.systemTemp.createTempSync('sonic_settings_');
    shareCalls = <MethodCall>[];
    nativeCalls = <MethodCall>[];

    messenger().setMockMethodCallHandler(kPathProvider, (call) async {
      // ⚠️ 方法名是 `getTemporaryDirectory`（不是 `getTemporaryPath`）——
      // 平台接口层的方法叫 `getTemporaryPath()`，但它打到通道上的名字是前者。
      // 拼错 → 返回 null → `getTemporaryDirectory()` 抛
      // `MissingPlatformDirectoryException` → 被 `_exportTasks` 的 catch 吞成
      // 「导出失败：…」，**永远走不到密码对话框**（实测假红 3 条）。
      if (call.method == 'getTemporaryDirectory') return tmp.path;
      return null;
    });
    messenger().setMockMethodCallHandler(kShare, (call) async {
      shareCalls.add(call);
      return 'ok'; // → ShareResultStatus.success
    });
    messenger().setMockMethodCallHandler(kNative, (call) async {
      nativeCalls.add(call);
      return null;
    });
  });

  tearDown(() async {
    messenger().setMockMethodCallHandler(kPathProvider, null);
    messenger().setMockMethodCallHandler(kShare, null);
    messenger().setMockMethodCallHandler(kNative, null);
    BackgroundServiceManager.replanHook = null;
    BackgroundServiceManager.invokeHook = null;
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ───────────────────────── 夹具 ─────────────────────────

  Future<T> dbRead<T>(WidgetTester tester, Future<T> Function() body) async {
    final r = await tester.runAsync(body);
    return r as T;
  }

  Future<void> dbWrite(
      WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(body);
  }

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() cond, {
    required String reason,
    int maxRounds = 60,
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

  Task makeTask(String id,
      {String? name, bool enabled = false, TaskCondition? condition}) {
    final now = DateTime.now();
    return Task(
      id: id,
      name: name ?? '任务$id',
      enabled: enabled,
      triggerType: TriggerType.dailyAt,
      trigger: const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)),
      actionType: ActionType.playAudio,
      action: const PlayAudioAction(volumeMin: 0.3, volumeMax: 0.7),
      assetIds: const ['a1'],
      cooldownSec: 300,
      quietPolicy: QuietPolicy.skip,
      condition: condition,
      priority: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => db),
          // ⚠️ 「本月豁免次数」必须**换掉**，不能让它真去查库：
          // 真实 sqflite 往返跑在 `FakeAsync` 里会留下未完成的锁超时
          // `Timer`（10s），用例收尾时判 "A Timer is still pending"
          // 而失败，并且会**连带污染同文件后续用例**。
          // 该 provider 自身的行为由 `quiet_exempt_lock_test.dart` QE-25
          // 在真实 DB 上验证 —— 界面用例只关心"渲染得对不对"。
          quietExemptCountProvider.overrideWith((ref) async => 0),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await waitFor(
      tester,
      () => find.text('电源策略').evaluate().isNotEmpty,
      reason: '设置页应渲染出分区标题',
    );
  }

  Future<String?> prefString(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);
  Future<int?> prefInt(String key) async =>
      (await SharedPreferences.getInstance()).getInt(key);
  Future<bool?> prefBool(String key) async =>
      (await SharedPreferences.getInstance()).getBool(key);

  /// 当前电源策略分段按钮的选中值。
  Set<String> selectedSegment(WidgetTester tester) => tester
      .widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>))
      .selected;

  /// 打开第 [index] 个「免打扰时段」下拉并选中 [label]。
  ///
  /// ⚠️ 必须点 `DropdownButton` 本身，**不能点标题文字**：`开始：22:00` 是
  /// `ListTile.title`，点它不会展开菜单（实测假红 2 条）。下拉项只在展开后的
  /// overlay 里存在，所以要先展开再点。
  Future<void> pickQuietHour(
      WidgetTester tester, int index, String label) async {
    await tester.tap(find.byType(DropdownButton<int>).at(index));
    await waitFor(tester, () => find.text(label).evaluate().isNotEmpty,
        reason: '下拉菜单应展开并含 $label');
    await tester.tap(find.text(label).last);
    await waitFor(tester, () => find.text(label).evaluate().length <= 1,
        reason: '选中后 overlay 应关闭');
  }

  // ─────────────────── SET-01 渲染 ───────────────────

  group('SET-01 渲染', () {
    testWidgets('SET-01 五个分区与全部可操作项都在（不静默缺项）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
      for (final section in [
        '电源策略',
        '强制免打扰时段（合规护栏）',
        '夜间独立豁免', // v1.9 新增分区
        '后台保活',
        '任务备份',
      ]) {
        expect(find.text(section), findsOneWidget, reason: '分区「$section」');
      }
      // 电源策略三段
      for (final seg in ['性能优先', '平衡', '省电']) {
        expect(find.text(seg), findsOneWidget, reason: '电源段 $seg');
      }
      // 保活两项 + 备份两项 + 合规一项
      expect(find.text('电池优化白名单与厂商引导'), findsOneWidget);
      expect(find.text('精确闹钟权限（Android 12+）'), findsOneWidget);
      expect(find.text('导出任务（JSON）'), findsOneWidget);
      expect(find.text('导入任务（JSON）'), findsOneWidget);
      expect(find.text('合规使用须知'), findsOneWidget);
      // v1.9：夜间独立豁免主开关（合规护栏的**削弱**入口，必须在页面上可见）
      expect(find.text('夜间独立豁免（主开关）'), findsOneWidget);
      expect(find.textContaining('本月豁免次数'), findsOneWidget);
      // 省电模式的边界条件必须写出来（用户得知道"什么时候会暂停"）
      expect(find.textContaining('电量 < 15%'), findsOneWidget);
    }, timeout: perTest);

    testWidgets('SET-01b 无偏好 → 用合规默认值（平衡 + 22:00→7:00）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      expect(find.text('开始：${ComplianceGuardrails.defaultQuietStartHour}:00'),
          findsOneWidget);
      expect(find.text('结束：${ComplianceGuardrails.defaultQuietEndHour}:00'),
          findsOneWidget);
      final seg = tester.widget<SegmentedButton<String>>(
          find.byType(SegmentedButton<String>));
      expect(seg.selected, {'balanced'});
    }, timeout: perTest);

    testWidgets('SET-01c 有偏好 → 界面回填落库值（不是永远显示默认）',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'power_mode': 'saver',
        'quiet_start': 21,
        'quiet_end': 6,
      });
      await pumpSettings(tester);

      final seg = tester.widget<SegmentedButton<String>>(
          find.byType(SegmentedButton<String>));
      expect(seg.selected, {'saver'});
      expect(find.text('开始：21:00'), findsOneWidget);
      expect(find.text('结束：6:00'), findsOneWidget);
    }, timeout: perTest);
  });

  // ─────────────────── SET-02 电源策略 ───────────────────

  group('SET-02 电源策略', () {
    testWidgets('SET-02 切到「省电」→ **真的落库** power_mode', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      await tester.tap(find.text('省电'));
      // 等界面选中态变化：这一条同时锁住「落库」与「setState 真的跑了」——
      // `_savePower` 是先落库、后 `await setPowerMode`、再 `setState`，
      // 中间任何一步抛异常，界面都会停在旧值（宿主上就真实发生过：
      // `FlutterBackgroundServicePlatform.instance` 非移动端直接抛，见
      // `background_service_manager.dart` 的 `invokeHook` 注释）。
      await waitFor(
        tester,
        () => selectedSegment(tester).contains('saver'),
        reason: '分段按钮应选中 saver',
      );

      expect(await prefString('power_mode'), 'saver',
          reason: '电源策略必须持久化，否则重启回弹');
    }, timeout: perTest);

    testWidgets('SET-02b 切到「性能优先」→ 同样落库（双向都要锁）', (tester) async {
      SharedPreferences.setMockInitialValues({'power_mode': 'saver'});
      await pumpSettings(tester);

      await tester.tap(find.text('性能优先'));
      await waitFor(
        tester,
        () => selectedSegment(tester).contains('performance'),
        reason: '分段按钮应选中 performance',
      );

      expect(await prefString('power_mode'), 'performance');
    }, timeout: perTest);
  });

  // ─────────────────── SET-03 免打扰时段 ───────────────────

  group('SET-03 免打扰时段', () {
    testWidgets('SET-03 改开始小时 → 落库 quiet_start', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      // 0 号下拉 = 开始（可选 20..23）
      await pickQuietHour(tester, 0, '23:00');
      await waitFor(tester, () => find.text('开始：23:00').evaluate().isNotEmpty,
          reason: '标题应更新为 23:00');

      expect(await prefInt('quiet_start'), 23);
      // 结束时段不能被顺手改掉：`_saveQuiet` 会把**一对**值都写下去
      // （它同时服务于两个下拉），所以这里锁的是"值没变"，
      // 而不是"没写" —— 写的是内存里的原值 `defaultQuietEndHour`。
      expect(await prefInt('quiet_end'),
          ComplianceGuardrails.defaultQuietEndHour,
          reason: '改开始不应改变结束的值');
    }, timeout: perTest);

    testWidgets('SET-03b 改结束小时 → 落库 quiet_end（且不动 quiet_start）',
        (tester) async {
      SharedPreferences.setMockInitialValues({'quiet_start': 20});
      await pumpSettings(tester);

      // 1 号下拉 = 结束（可选 5..9）
      await pickQuietHour(tester, 1, '9:00');
      await waitFor(tester, () => find.text('结束：9:00').evaluate().isNotEmpty,
          reason: '标题应更新为 9:00');

      expect(await prefInt('quiet_end'), 9);
      expect(await prefInt('quiet_start'), 20, reason: '开始时段不应被动到');
    }, timeout: perTest);
  });

  // ─────────────────── SET-05 夜间独立豁免（v1.9，docs/20 §8） ───────────────────
  //
  // 这一组锁的是**削弱合规护栏**的那条路径。它不是"又一个开关"：
  // docs/08 §4 原本把免打扰标为"不可绕过"，用户拍板开的口子必须满足
  // 「默认关 / 二次确认 / 每次留痕 / 远程不可开」四条，
  // 前三条在本组，第四条在 `quiet_exempt_lock_test.dart`。

  group('SET-05 夜间独立豁免', () {
    testWidgets('SET-05 默认关闭（无偏好 ⇒ 不授权）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      final sw = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, '夜间独立豁免（主开关）'));
      expect(sw.value, isFalse, reason: '默认必须是"未授权"');
      expect(await prefBool(PrefsKeys.quietExemptMaster) ?? false, isFalse);
    }, timeout: perTest);

    testWidgets('SET-05b 点击开关 → 必须先弹二次确认；取消 ⇒ **不落库**',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      await tester.tap(find.widgetWithText(SwitchListTile, '夜间独立豁免（主开关）'));
      await waitFor(tester, () => find.text('开启夜间独立豁免？').evaluate().isNotEmpty,
          reason: '削弱护栏的操作必须二次确认');
      // 文案必须写明后果，而不是一句"确定吗"
      expect(find.textContaining('请勿用它干扰他人'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await waitFor(
          tester, () => find.text('开启夜间独立豁免？').evaluate().isEmpty,
          reason: '弹窗应关闭');
      expect(await prefBool(PrefsKeys.quietExemptMaster) ?? false, isFalse,
          reason: '取消后**绝不能**落库 —— 否则等于一键开启护栏豁免');
      final sw = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, '夜间独立豁免（主开关）'));
      expect(sw.value, isFalse, reason: '取消后界面也不应变');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-05c 确认 → 落库 true，且提示"仍需逐任务开启"',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      await tester.tap(find.widgetWithText(SwitchListTile, '夜间独立豁免（主开关）'));
      await waitFor(tester, () => find.text('开启夜间独立豁免？').evaluate().isNotEmpty,
          reason: '应弹二次确认');
      await tester.tap(find.text('我了解后果，开启'));
      await waitFor(
          tester,
          () => find.textContaining('已开启夜间豁免主开关').evaluate().isNotEmpty,
          reason: '应有成功提示');
      expect(await prefBool(PrefsKeys.quietExemptMaster), isTrue);
      // 双钥匙：主开关开启**不等于**任务已豁免，文案必须说清
      expect(find.textContaining('仍需在任务编辑器中逐任务开启'), findsOneWidget);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-05d 关闭 → 落库 false，且提示已清除豁免计划', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.quietExemptMaster: true,
      });
      await pumpSettings(tester);

      final sw = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, '夜间独立豁免（主开关）'));
      expect(sw.value, isTrue, reason: '应回填已授权状态');

      await tester.tap(find.widgetWithText(SwitchListTile, '夜间独立豁免（主开关）'));
      await waitFor(
          tester,
          () => find.textContaining('已关闭夜间豁免主开关').evaluate().isNotEmpty,
          reason: '关闭**不需要**二次确认（回到更安全的一侧），但必须给回执');
      expect(await prefBool(PrefsKeys.quietExemptMaster), isFalse);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-05e 豁免计数读不到时显示「—」而不是 0', (tester) async {
      SharedPreferences.setMockInitialValues({});
      // 让 provider 一直处于 loading：真实实现下"读库失败"也是这个形态。
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            quietExemptCountProvider.overrideWith((ref) => Completer<int>().future),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump(const Duration(milliseconds: 50));
      await waitFor(tester, () => find.textContaining('本月豁免次数').evaluate().isNotEmpty,
          reason: '设置页应渲染');
      expect(find.textContaining('本月豁免次数：—'), findsOneWidget,
          reason: '把"读不到"显示成 0 会让用户以为护栏完好，属于误导');
    }, timeout: perTest);
  });

  // ─────────────────── SET-04 弹窗与深链 ───────────────────

  group('SET-04 弹窗与深链', () {
    testWidgets('SET-04 点「合规使用须知」→ 弹窗有正文，可关闭', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      await tester.tap(find.text('合规使用须知'));
      await waitForText(tester, '严禁利用随机播放');
      expect(find.text('我已知晓'), findsOneWidget);

      await tester.tap(find.text('我已知晓'));
      await waitFor(tester, () => find.text('我已知晓').evaluate().isEmpty,
          reason: '关闭后弹窗应消失');
    }, timeout: perTest);

    testWidgets('SET-04b 点「电池优化白名单与厂商引导」→ 底部引导弹窗（含通用步骤）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      await tester.tap(find.text('电池优化白名单与厂商引导'));
      // 宿主拿不到真实厂商（device_info 通道没有另一侧）→ 必须退化成通用指引，
      // 而不是弹一个空壳让用户无从下手。
      await waitForText(tester, '通用步骤');
      expect(find.textContaining('后台保活设置（'), findsOneWidget);
      expect(find.text('申请电池白名单'), findsOneWidget);
      expect(find.text('厂商自启动页'), findsOneWidget);
    }, timeout: perTest);

    testWidgets('SET-04c 点「精确闹钟权限」→ 打到 sonic_shield/native 的 openExactAlarmSettings',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      await tester.tap(find.text('精确闹钟权限（Android 12+）'));
      await waitFor(
        tester,
        () => nativeCalls.any((c) => c.method == 'openExactAlarmSettings'),
        reason: '必须打到 native 通道的 openExactAlarmSettings',
      );
      // 方法名拼错 = 静默返回 null，用户以为跳转了、其实什么都没发生。
      expect(nativeCalls.where((c) => c.method == 'openExactAlarmSettings').length,
          1);
    }, timeout: perTest);
  });

  // ─────────────────── SET-05 导出 ───────────────────

  group('SET-05 导出任务', () {
    testWidgets('SET-05 无任务 → 明确说「没有可导出的任务」，且**不生成文件**',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      await tester.tap(find.text('导出任务（JSON）'));
      await waitForText(tester, '没有可导出的任务');

      expect(tmp.listSync(), isEmpty,
          reason: '空列表不能导出一个空备份——用户会以为备份成功');
      expect(shareCalls, isEmpty);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-05b 有任务 + 留空密码 → 明文 JSON 落盘并调起分享',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await dbWrite(tester, () => TaskRepository(db).upsert(makeTask('t1')));
      await pumpSettings(tester);

      await tester.tap(find.text('导出任务（JSON）'));
      await waitForText(tester, '加密备份（留空则明文导出）');
      // 留空 = 明文导出
      await tester.tap(find.text('确定'));
      // ⚠️ BUG-065：这里同时锁死"路径拼接正确"。旧实现写
      // `'$dir/sonic_shield_tasks_$stamp.json'`，而 `Directory.toString()`
      // 是 `Directory: 'C:\Temp\xxx'` → 插值出 `Directory: '...'/xxx.json`
      // 这种不存在的路径 → `writeAsString` 必抛 → 导出**从来没成功过**。
      //
      // ⚠️ 等待条件必须落在**最后一步**（分享）上，不能只看"文件存在"：
      // `writeAsString` 是异步的，文件会被**先创建后写满**，只看存在会读到
      // 空文件（实测 `jsonDecode('')` → FormatException）。
      await waitFor(tester, () => shareCalls.any((c) => c.method == 'shareFiles'),
          reason: '导出完成后应调起分享（写盘已完成）');

      final file = tmp
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.json'));
      final body = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(body['app'], 'sonic_shield');
      expect((body['tasks'] as List).length, 1);
      // 备份必须自带可读回的最小字段集，不能只写个 id。
      final row = (body['tasks'] as List).first as Map<String, dynamic>;
      expect(row['name'], '任务t1');
      expect(row['trigger_type'], TriggerType.dailyAt.name);
      expect(row['action_type'], ActionType.playAudio.name);
      expect(row['condition_json'], isNull);

      await waitFor(tester, () => shareCalls.isNotEmpty,
          reason: '应调起系统分享');
      final share = shareCalls.firstWhere((c) => c.method == 'shareFiles');
      expect((share.arguments as Map)['paths'], isA<List<Object?>>());
    }, timeout: perTest);

    testWidgets('SET-05c 有任务 + 设密码 → 产出 .enc（不是明文）并提示不可恢复',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await dbWrite(tester, () => TaskRepository(db).upsert(makeTask('t1')));
      await pumpSettings(tester);

      await tester.tap(find.text('导出任务（JSON）'));
      await waitForText(tester, '加密备份（留空则明文导出）');
      await tester.enterText(find.byType(TextField).at(0), 'pw-123456');
      await tester.enterText(find.byType(TextField).at(1), 'pw-123456');
      await tester.tap(find.text('确定'));

      // 等最后一步（SnackBar 在 `await Share.shareXFiles` 之后）——
      // 这样文件一定已经写满，不会读到空文件。
      await waitForText(tester, '密码丢失将无法恢复');
      expect(shareCalls.any((c) => c.method == 'shareFiles'), isTrue,
          reason: '加密备份也应交给系统分享');

      // 明文文件绝不能同时留下——"加密导出"却留一份明文等于没加密。
      expect(tmp.listSync().any((f) => f.path.endsWith('.json')), isFalse,
          reason: '加密导出不应留下明文 JSON');

      final enc = tmp
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.enc'));
      final body = jsonDecode(enc.readAsStringSync()) as Map<String, dynamic>;
      expect(body['v'], 1);
      expect(body['kdf'], contains('PBKDF2'));
      expect(body.keys, containsAll(['salt', 'nonce', 'mac', 'cipher']));
      // 明文不能出现在密文文件里（哪怕片段）。
      expect(enc.readAsStringSync().contains('任务t1'), isFalse,
          reason: '密文里不能残留明文任务名');

      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-05e 带条件的任务 → 备份里带 condition_json（不能丢条件）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      // 条件是最容易被"顺手丢掉"的字段：丢了的后果是"导入后条件消失、
      // 该受约束的任务开始不受约束地执行"。
      await dbWrite(
          tester,
          () => TaskRepository(db).upsert(
              makeTask('t1', condition: const TaskCondition(requireWifi: true))));
      await pumpSettings(tester);

      await tester.tap(find.text('导出任务（JSON）'));
      await waitForText(tester, '加密备份（留空则明文导出）');
      await tester.tap(find.text('确定'));
      await waitFor(tester, () => shareCalls.any((c) => c.method == 'shareFiles'),
          reason: '导出完成后应调起分享');

      final file = tmp
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.json'));
      final body = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final row = (body['tasks'] as List).first as Map<String, dynamic>;
      expect(row['condition_json'], isNotNull, reason: '有条件就必须写进去');
      final cond = TaskCondition.fromJsonOrNull(row['condition_json'] as String);
      expect(cond, isNotNull);
      expect(cond!.requireWifi, isTrue, reason: '条件内容要能还原');
    }, timeout: perTest);

    testWidgets('SET-05f 取不到临时目录 → 明说「导出失败」，**不静默**',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await dbWrite(tester, () => TaskRepository(db).upsert(makeTask('t1')));
      // 让 path_provider 返回 null → getTemporaryDirectory() 抛
      // MissingPlatformDirectoryException。
      messenger().setMockMethodCallHandler(kPathProvider, (c) async => null);
      await pumpSettings(tester);

      await tester.tap(find.text('导出任务（JSON）'));
      // 落库失败必须留痕并让用户知道（项目纪律：可以失败，但不能静默）。
      await waitForText(tester, '导出失败：');
      expect(tmp.listSync(), isEmpty);
      expect(shareCalls, isEmpty);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-05g 密码对话框点「取消」→ 同样不导出（BUG-066 的另一半）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await dbWrite(tester, () => TaskRepository(db).upsert(makeTask('t1')));
      await pumpSettings(tester);

      await tester.tap(find.text('导出任务（JSON）'));
      await waitForText(tester, '加密备份（留空则明文导出）');
      await tester.tap(find.text('取消'));
      await waitFor(
        tester,
        () => find.text('加密备份（留空则明文导出）').evaluate().isEmpty,
        reason: '取消后对话框应关闭',
      );
      await waitFor(tester, () => true, reason: '给异步收尾一个回合');
      await tester.pump(const Duration(milliseconds: 50));

      // 「取消」的语义是"我不导了"，不是"那给我一份明文吧"。
      expect(tmp.listSync(), isEmpty, reason: '取消不能变成明文导出');
      expect(shareCalls, isEmpty);
    }, timeout: perTest);

    testWidgets('SET-05d 两次密码不一致 → 拒绝并提示，**不产出任何文件**（BUG-066）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await dbWrite(tester, () => TaskRepository(db).upsert(makeTask('t1')));
      await pumpSettings(tester);

      await tester.tap(find.text('导出任务（JSON）'));
      await waitForText(tester, '加密备份（留空则明文导出）');
      await tester.enterText(find.byType(TextField).at(0), 'aaa111');
      await tester.enterText(find.byType(TextField).at(1), 'bbb222');
      await tester.tap(find.text('确定'));
      await waitForText(tester, '两次密码不一致');

      // ⚠️ BUG-066：`_askPassword` 用 `null` 表示"取消/不一致"，旧实现直接落到
      // 明文分支 —— 用户明确要加密、只因两次输入不一致，就得到一份**明文**备份
      // （含全部任务与音源引用）并交给分享面板。这是"隐私开关静默失效"的同源红线，
      // 所以这里同时锁死"不落文件"与"不调分享"。
      expect(tmp.listSync(), isEmpty, reason: '密码不一致必须整体中止');
      expect(shareCalls, isEmpty);
      await settleSnackBars(tester);
    }, timeout: perTest);
  });

  // ─────────────────── SET-06 导入 ───────────────────

  group('SET-06 导入任务', () {
    /// 造一个"导出格式"的备份文件。
    File writeBackup(String name, Map<String, dynamic> payload) {
      final f = File('${tmp.path}/$name');
      f.writeAsStringSync(jsonEncode(payload));
      return f;
    }

    Map<String, dynamic> taskRow(Task t) => {
          'id': t.id,
          'name': t.name,
          'trigger_type': t.triggerType.name,
          'trigger_json': jsonEncode(t.trigger.toJson()),
          'action_type': t.actionType.name,
          'action_json': jsonEncode(t.action.toJson()),
          'asset_ids': jsonEncode(t.assetIds),
          'cooldown_sec': t.cooldownSec,
          'quiet_policy': t.quietPolicy.name,
          'priority': t.priority,
          'created_at': t.createdAt.millisecondsSinceEpoch,
        };

    testWidgets('SET-06 用户取消选择 → 什么都不发生', (tester) async {
      SharedPreferences.setMockInitialValues({});
      FilePicker.platform = _FakeFilePicker(null);
      await pumpSettings(tester);

      await tester.tap(find.text('导入任务（JSON）'));
      await waitFor(tester, () => true, reason: '让回调跑完');
      await tester.pump(const Duration(milliseconds: 50));

      expect(await dbRead(tester, () => TaskRepository(db).listAll()), isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    }, timeout: perTest);

    testWidgets('SET-06b 不是声盾备份 → 说「文件格式不符」，**不写入任何任务**',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final f = writeBackup('other.json', {
        'app': 'some_other_app',
        'tasks': <Object?>[],
      });
      FilePicker.platform =
          _FakeFilePicker(FilePickerResult([_pf('other.json', f)]));
      await pumpSettings(tester);

      await tester.tap(find.text('导入任务（JSON）'));
      await waitForText(tester, '文件格式不符');

      expect(await dbRead(tester, () => TaskRepository(db).listAll()), isEmpty);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-06c 合法备份 → 批量落库、**默认停用**、给出条数',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final a = makeTask('imp-a', name: '导入甲', enabled: true);
      final b = makeTask('imp-b', name: '导入乙', enabled: true);
      final f = writeBackup('backup.json', {
        'app': 'sonic_shield',
        'version': 1,
        'tasks': [taskRow(a), taskRow(b)],
      });
      FilePicker.platform =
          _FakeFilePicker(FilePickerResult([_pf('backup.json', f)]));
      await pumpSettings(tester);

      await tester.tap(find.text('导入任务（JSON）'));
      await waitForText(tester, '导入完成：2 条任务');

      final all = await dbRead(tester, () => TaskRepository(db).listAll());
      expect(all.length, 2);
      // 导入即启用 = 用户一导入就有任务自动开跑，绝不允许。
      expect(all.every((t) => !t.enabled), isTrue,
          reason: '导入后必须全部默认停用');
      // 配置要完整还原（不能只还原名字）。
      final ja = all.firstWhere((t) => t.id == 'imp-a');
      expect(ja.name, '导入甲');
      expect(ja.triggerType, TriggerType.dailyAt);
      expect(ja.actionType, ActionType.playAudio);
      expect(ja.assetIds, ['a1']);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-06d 备份里某条损坏 → 整批不落库（不留半批中间态）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final good = makeTask('imp-ok', name: '好的');
      final bad = taskRow(makeTask('imp-bad', name: '坏的'))
        ..['trigger_type'] = 'not_a_real_type';
      final f = writeBackup('partial.json', {
        'app': 'sonic_shield',
        'tasks': [taskRow(good), bad],
      });
      FilePicker.platform =
          _FakeFilePicker(FilePickerResult([_pf('partial.json', f)]));
      await pumpSettings(tester);

      await tester.tap(find.text('导入任务（JSON）'));
      await waitForText(tester, '导入失败');

      // 关键：坏了一条 → 连好的一条也不能进去（原子性），
      // 否则用户看到"导入失败"但列表里已经多了一截。
      expect(await dbRead(tester, () => TaskRepository(db).listAll()), isEmpty,
          reason: '解析失败必须整批回滚，不能留下半批');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-06e .enc 备份 + 错密码 → 说「解密失败」，不落库',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final f = writeBackup('broken.enc', {'v': 1, 'junk': true});
      FilePicker.platform =
          _FakeFilePicker(FilePickerResult([_pf('broken.enc', f)]));
      await pumpSettings(tester);

      await tester.tap(find.text('导入任务（JSON）'));
      await waitForText(tester, '解密备份');
      await tester.enterText(find.byType(TextField).at(0), 'wrong-pw');
      await tester.tap(find.text('确定'));

      await waitForText(tester, '解密失败：密码错误或文件损坏');
      expect(await dbRead(tester, () => TaskRepository(db).listAll()), isEmpty);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-06f .enc 备份 + 空密码 → 直接中止（不做无谓解密）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final f = writeBackup('broken.enc', {'v': 1, 'junk': true});
      FilePicker.platform =
          _FakeFilePicker(FilePickerResult([_pf('broken.enc', f)]));
      await pumpSettings(tester);

      await tester.tap(find.text('导入任务（JSON）'));
      await waitForText(tester, '解密备份');
      await tester.tap(find.text('确定')); // 空密码

      await waitFor(
        tester,
        () => find.text('解密备份').evaluate().isEmpty,
        reason: '空密码应静默中止（关闭对话框），不再往下走',
      );
      expect(find.textContaining('解密失败'), findsNothing);
      expect(await dbRead(tester, () => TaskRepository(db).listAll()), isEmpty);
    }, timeout: perTest);
  });
}

/// `file_picker` 官方注入点用的假实现（`FilePicker.platform = …`）。
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.result);

  final FilePickerResult? result;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      result;
}

PlatformFile _pf(String name, File f) =>
    PlatformFile(name: name, size: f.lengthSync(), path: f.path);
