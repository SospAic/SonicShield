import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/api_config_store.dart';
import 'package:sonic_shield/data/repositories/counter_plan_store.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/models/counter_plan_params.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/settings/settings_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/counter_plan_service.dart';
import 'package:sonic_shield/services/deepseek_service.dart';
import 'package:sonic_shield/services/holiday_update_service.dart';
import 'package:sonic_shield/services/tts_service.dart';

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

  /// ⚠️ `maxRounds` 是**防死循环的上限，不是断言**（断言是 `cond()`）——
  /// 提高它**不削弱任何检查**，只是给**真实 IO**（写盘 / 调起分享）更多轮次。
  /// 依据：2026-09-22 第二十九轮，整机负载 100% 时 60 轮（≈1.2s）不够，
  /// SET-05b 报"等待超时"而**单独跑必过** ⇒ 环境性 flaky，非回归。
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

  Future<void> pumpSettings(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
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
          // 两个"例外清单"provider 同理：它们也要查库（`TaskRepository.listAll`），
          // 真实 sqflite 往返在 FakeAsync 里会留下未完成的锁超时 Timer，
          // 收尾判 "A Timer is still pending" 而失败并污染后续用例。
          // 需要验证清单渲染的用例自带 override（见 SET-06）。
          quietExemptOverrideTasksProvider.overrideWith((ref) async => <Task>[]),
          forceRunTasksProvider.overrideWith((ref) async => <Task>[]),
          ...overrides,
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

  /// 切到设置页第 [index] 个 tab（0=通用 / 1=语音与反击）。
  ///
  /// ⚠️ 第八十二轮：设置页改 `TabBar`+`IndexedStack` 分组后，**非激活页是
  /// offstage**，`find.text` 默认 `skipOffstage: true` 会跳过它们。语音/接口/
  /// 反击计划等控件全在 tab 1，交互与渲染断言前必须先切过去；否则会报
  /// "Could not find a widget" 或断言不到文本（假红）。`取证文件管理`等
  /// 通用 tab 的控件不要切（见 SET-07o）。
  Future<void> switchTab(WidgetTester tester, int index) async {
    final label = index == 0 ? '通用' : '语音与反击';
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 50));
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

    testWidgets('SET-01d 「关于」显示 AppMeta.displayVersion（含构建号，不写死）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);

      expect(find.text('关于'), findsOneWidget);
      // 显示的版本串必须来自常量（version+buildNumber），而不是写死的字面量。
      expect(
          find.text('v${AppMeta.displayVersion} · Flutter 跨平台 · 仅限合法用途'),
          findsOneWidget);
      // 「每次迭代 APP 显示版本同步更新」：显示串必须含本轮构建号。
      expect(AppMeta.displayVersion, contains(AppMeta.buildNumber),
          reason: '界面显示串必须带构建号，否则看不出本轮迭代替换过');
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

    testWidgets('SET-05c 确认 → 落库 true，且提示"所有任务默认豁免"',
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
      // v79：主开关即**默认值**（开启后所有任务默认豁免），文案必须说清
      // —— 不能再是旧口径的"仍需逐任务开启"。（用完整前缀避免撞上开关副标题。）
      expect(find.textContaining('已开启夜间豁免主开关：所有任务默认豁免'),
          findsOneWidget);
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
            // 例外清单 provider 同样要换掉，否则真实 sqflite 往返留下 pending Timer。
            quietExemptOverrideTasksProvider.overrideWith((ref) async => <Task>[]),
            forceRunTasksProvider.overrideWith((ref) async => <Task>[]),
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

  // ─────────────── SET-07 语音与接口 / 反击计划（v2.0） ───────────────

  group('SET-07 语音与接口与反击计划', () {
    testWidgets('SET-07a 语音与接口：配置入口 + 音色分组 + 试听都在', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);
      await switchTab(tester, 1);

      expect(find.text('语音与接口'), findsOneWidget);
      expect(find.text('DeepSeek 接口配置'), findsOneWidget);
      expect(find.text('在线语音配置'), findsOneWidget);
      // 出厂默认是内置免 Key 端点（开箱可用），必须如实显示"已配置"。
      expect(find.textContaining('内置免费在线语音'), findsOneWidget);
      // 两种方言分组标题各自成组（不是把在线音色混进普通话里）。
      expect(find.text('普通话'), findsOneWidget);
      expect(find.text('东北话'), findsOneWidget);
      // 系统音色与在线东北话音色都在列表里（按 id 定位，不靠展示名）。
      expect(find.byKey(const ValueKey<String>('voice_sys_zh_female')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('voice_az_db_male_yunbiao')),
          findsOneWidget);
      expect(find.text('试听所选音色'), findsOneWidget);
    }, timeout: perTest);

    testWidgets('SET-07b 已配置 DeepSeek Key → 副标题如实显示「已配置」',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'api_base_url': 'https://api.deepseek.com',
        'api_model': 'deepseek-chat',
        'api_key': 'sk-test',
      });
      await pumpSettings(tester);
      await switchTab(tester, 1);

      expect(find.textContaining('基址 https://api.deepseek.com'), findsOneWidget);
      expect(find.textContaining('Key 已配置'), findsOneWidget,
          reason: '配了 Key 就不能还显示"未配置"');
    }, timeout: perTest);

    testWidgets('SET-07c 反击计划未配置：状态 + 五个操作都在', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);
      await switchTab(tester, 1);

      expect(find.text('反击计划'), findsOneWidget);
      expect(find.text('当前计划：未配置'), findsOneWidget);
      for (final t in [
        '本机随机生成并启用',
        '一键 AI 生成并导入',
        '导入 JSON',
        '下载 JSON 模版',
        '下线',
      ]) {
        expect(find.text(t), findsOneWidget, reason: '操作「$t」');
      }
    }, timeout: perTest);

    testWidgets('SET-07d 已落库计划 → 展示名称 + 四时段区间（含未启用说明）',
        (tester) async {
      final plan = CounterPlan.defaults();
      SharedPreferences.setMockInitialValues({
        'counter_plan_json': jsonEncode(plan.toJson()),
        'counter_plan_enabled': true,
      });
      await pumpSettings(tester);
      await switchTab(tester, 1);

      expect(find.text('当前计划：${plan.name}'), findsOneWidget);
      expect(find.textContaining('已启用'), findsOneWidget);
      for (final label in ['工作日·白天', '工作日·夜间', '休息日·白天', '休息日·夜间']) {
        expect(find.text(label), findsOneWidget, reason: '时段「$label」');
      }
      // 工作日白天启用 → 显示区间（音量/时长/次数）；休息日两段默认关 →
      // 必须显式说明"不反击"，而不是留一行空白让人猜。
      expect(find.text(describeWindow(plan.workdayDay)), findsOneWidget);
      expect(find.text('未启用（该时段不反击）'), findsNWidgets(2));
    }, timeout: perTest);

    // ───── 以下为 v2.0 新增代码（语音与接口 / 反击计划）的补测 ─────

    /// 合法计划 JSON（与 `deepseek_service_test.goodPlanJson()` 同源）。
    String goodPlanJson() => jsonEncode({
          'schema': 'sonicshield.counterPlan/1',
          'name': 'AI 反击',
          'version': 1,
          'dayStartHour': 8,
          'dayEndHour': 20,
          'cooldownSec': 900,
          'respectQuietHours': true,
          'workday': {
            'day': {
              'enabled': true,
              'volumeMin': 0.5,
              'volumeMax': 0.8,
              'durationSecMin': 3,
              'durationSecMax': 8,
              'actionsPerHour': 2,
            },
            'night': {
              'enabled': true,
              'volumeMin': 0.3,
              'volumeMax': 0.5,
              'durationSecMin': 3,
              'durationSecMax': 5,
              'actionsPerHour': 1,
            },
          },
          'restday': {
            'day': {'enabled': false},
            'night': {'enabled': false},
          },
          'presetIds': ['annoy_cough_fit', 'annoy_spit'],
          'ttsTexts': ['干啥呢？'],
          'voiceId': '',
        });

    http.Response ok200(String content) => http.Response.bytes(
          utf8.encode(content),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

    String chatBody(String content) => jsonEncode({
          'choices': [
            {
              'message': {'content': content}
            }
          ],
          'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
        });

    /// `TtsService` 替身：系统音色成功（或按 [fail] 抛错），在线音色成功；
    /// 神经音色恒 false ⇒ 走系统回落（与既有「系统成功」桩一致）。
    Override ttsOverride({bool fail = false}) =>
        ttsServiceProvider.overrideWith((ref) async => TtsService(
              speakSystem: (t, v, m) async {
                if (fail) throw StateError('boom');
              },
              speakNeural: (t, v) async => false,
              speakOnline: (t, v, n) async => true,
            ));

    /// `DeepSeekService` 替身：返回合法计划（[ok]）或恒非法内容（失败）。
    Override deepSeekOverride({required bool ok}) =>
        deepseekServiceProvider.overrideWith((ref) async {
          final prefs = await SharedPreferences.getInstance();
          return DeepSeekService(
            client: MockClient((r) async =>
                ok200(chatBody(ok ? goodPlanJson() : '这不是 JSON'))),
            config: ApiConfigStore(prefs),
          );
        });

    /// `CounterPlanService` 替身：真实 DB 仓储 + 真实 prefs 存储，音源池空
    /// （计划自带 TTS 文案，仍能物化出任务）、replan 为 no-op。
    Override counterPlanOverride() =>
        counterPlanServiceProvider.overrideWith((ref) async {
          final prefs = await SharedPreferences.getInstance();
          return CounterPlanService(
            tasks: TaskRepository(db),
            store: CounterPlanStore(prefs),
            resolveAudioIds: (ids) async => const <String>{},
            replan: () async {},
          );
        });

    /// `HolidayUpdateService` 替身：返回一年放假表（[ok]=false 时全源 500）。
    Override holidayOverride({bool ok = true}) =>
        holidayUpdateServiceProvider.overrideWith((ref) async =>
            HolidayUpdateService(
              client: MockClient((r) async {
                if (!ok) return http.Response('boom', 500);
                return http.Response.bytes(
                  utf8.encode(jsonEncode({
                    'year': 2026,
                    'days': [
                      {'name': '元旦', 'date': '2026-01-01', 'isOffDay': true},
                    ],
                  })),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                );
              }),
              sources: (_) => ['https://cdn.example/holiday/2026.json'],
            ));

    testWidgets('SET-07e DeepSeek 对话框「保存」→ 三项落库 + 回执', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);
      await switchTab(tester, 1);

      await tester.tap(find.text('DeepSeek 接口配置'));
      await waitFor(tester, () => find.text('保存').evaluate().isNotEmpty,
          reason: '应弹出 DeepSeek 配置对话框');
      await tester.enterText(
          find.byType(TextField).at(0), 'https://api.example.com');
      await tester.enterText(find.byType(TextField).at(1), 'my-model');
      await tester.enterText(find.byType(TextField).at(2), 'sk-abc');
      await tester.tap(find.text('保存'));
      await waitForText(tester, 'DeepSeek 配置已保存');

      expect(await prefString('api_base_url'), 'https://api.example.com');
      expect(await prefString('api_model'), 'my-model');
      expect(await prefString('api_key'), 'sk-abc');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07e2 DeepSeek 对话框「取消」→ 不落库', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);
      await switchTab(tester, 1);

      await tester.tap(find.text('DeepSeek 接口配置'));
      await waitFor(tester, () => find.text('保存').evaluate().isNotEmpty,
          reason: '应弹出对话框');
      await tester.enterText(
          find.byType(TextField).at(0), 'https://changed.example.com');
      await tester.tap(find.text('取消'));
      await waitFor(tester, () => find.text('保存').evaluate().isEmpty,
          reason: '取消后应关闭对话框');

      expect(await prefString('api_base_url'), isNull, reason: '取消绝不能落库');
      expect(await prefString('api_model'), isNull);
      expect(await prefString('api_key'), isNull);
    }, timeout: perTest);

    testWidgets('SET-07f 在线语音填 endpoint+key → 落库 + 回执', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);
      await switchTab(tester, 1);

      await tester.tap(find.text('在线语音配置'));
      await waitFor(
          tester, () => find.text('在线语音 Endpoint').evaluate().isNotEmpty,
          reason: '应弹出在线语音对话框');
      await tester.enterText(
          find.byType(TextField).at(0), 'https://x.tts.example.com/v1');
      await tester.enterText(find.byType(TextField).at(1), 'tts-key-1');
      await tester.tap(find.text('保存'));
      await waitForText(tester, '在线语音已配置');

      expect(await prefString('tts_endpoint'), 'https://x.tts.example.com/v1');
      expect(await prefString('tts_api_key'), 'tts-key-1');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07f2 在线语音两项留空 → 视为关闭 + 回执', (tester) async {
      SharedPreferences.setMockInitialValues({
        'tts_endpoint': 'https://old.example.com/v1',
        'tts_api_key': 'old-key',
      });
      await pumpSettings(tester);
      await switchTab(tester, 1);

      await tester.tap(find.text('在线语音配置'));
      await waitFor(tester, () => find.text('保存').evaluate().isNotEmpty,
          reason: '应弹出对话框');
      await tester.enterText(find.byType(TextField).at(0), '');
      await tester.enterText(find.byType(TextField).at(1), '');
      await tester.tap(find.text('保存'));
      await waitForText(tester, '在线语音已关闭');

      expect(await prefString('tts_endpoint'), '');
      expect(await prefString('tts_api_key'), '');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07g 试听对话框播放 → 回执「已试听」', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, overrides: [ttsOverride()]);
      await switchTab(tester, 1);

      await tester.tap(find.text('试听所选音色'));
      await waitFor(tester, () => find.text('试听').evaluate().isNotEmpty,
          reason: '应弹出试听对话框');
      await tester.tap(find.text('试听'));
      await waitForText(tester, '已试听');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07g2 试听失败（系统 TTS 抛错）→ 回执「试听失败」', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, overrides: [ttsOverride(fail: true)]);
      await switchTab(tester, 1);

      await tester.tap(find.text('试听所选音色'));
      await waitFor(tester, () => find.text('试听').evaluate().isNotEmpty,
          reason: '应弹出试听对话框');
      await tester.tap(find.text('试听'));
      await waitForText(tester, '试听失败');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07h 本机随机生成并启用 → 落库 + 回执', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      await tester.tap(find.text('本机随机生成并启用'));
      await waitForText(tester, '反击计划已生效');

      expect(await prefString('counter_plan_json'), isNotNull,
          reason: '计划本体必须落库');
      expect(await prefBool('counter_plan_enabled'), isTrue);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07s 参数开启休息日 → 本机随机生成含休息日反击',
        (tester) async {
      // 参数化选择的端到端锁：把"休息日白天/夜间是否反击"打开，本机随机生成
      // 出的计划就必须带上这两段（而不是永远沿用出厂默认的"关闭"）。
      final params = CounterPlanParams.defaults().copyWith(
        restdayDay: const PlanWindowParams(enabled: true),
        restdayNight: const PlanWindowParams(
          enabled: true,
          volumeMin: 0.1,
          volumeMax: 0.3,
          durationSecMax: 5,
        ),
      );
      SharedPreferences.setMockInitialValues({
        'counter_plan_params_json': jsonEncode(params.toJson()),
      });
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      await tester.tap(find.text('本机随机生成并启用'));
      await waitForText(tester, '反击计划已生效');

      final raw = await prefString('counter_plan_json');
      expect(raw, isNotNull);
      final plan =
          CounterPlan.fromJson(jsonDecode(raw!) as Map<String, dynamic>);
      expect(plan.restdayDay.enabled, isTrue, reason: '参数开了休息日白天就该反击');
      expect(plan.restdayNight.enabled, isTrue, reason: '参数开了休息日夜也该反击');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07t 参数对话框：切换休息日开关 → 保存落库', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      final edit = find.byKey(const ValueKey<String>('plan_params_edit'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await waitFor(tester, () => find.text('反击计划生成参数').evaluate().isNotEmpty,
          reason: '应弹出参数对话框');

      // 出厂参数里休息日两段默认关闭；打开「休息日·白天」。
      final sw = find.byKey(const ValueKey<String>('pp_enabled_休息日·白天'));
      await tester.ensureVisible(sw);
      await tester.tap(sw);
      await tester.pump();

      await tester.tap(find.text('保存'));
      await waitForText(tester, '生成参数已保存');

      final raw = await prefString('counter_plan_params_json');
      expect(raw, isNotNull, reason: '参数必须落库（重启后不丢）');
      final saved =
          CounterPlanParams.fromJson(jsonDecode(raw!) as Map<String, dynamic>);
      expect(saved.restdayDay.enabled, isTrue);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07u 参数对话框：全滑块/开关/三按钮驱动 → 参数生效',
        (tester) async {
      // 覆盖 `_PlanParamsDialog` 的所有交互回调：顶端两条区间滑块、免打扰开关、
      // 四个时段（工作日两段默认开、休息日两段默认关）的开关与区间滑块、
      // 「恢复默认」「取消」「保存」三个按钮。
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      final edit = find.byKey(const ValueKey<String>('plan_params_edit'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await waitFor(tester, () => find.text('反击计划生成参数').evaluate().isNotEmpty,
          reason: '应弹出参数对话框');

      Future<void> driveAllSliders() async {
        final sliders = find.byType(RangeSlider);
        final n = sliders.evaluate().length;
        for (var i = 0; i < n; i++) {
          final s = tester.widget<RangeSlider>(sliders.at(i));
          s.onChanged!(RangeValues(s.min, s.max));
          await tester.pump();
        }
      }

      // 1) 顶端两条：白天时段 / 动作间隔（精确驱动一次，校验文案随之变化）。
      final top = find.byType(RangeSlider);
      tester.widget<RangeSlider>(top.at(0)).onChanged!(const RangeValues(6, 22));
      await tester.pump();
      expect(find.text('白天时段：6:00 – 22:00'), findsOneWidget);
      tester
          .widget<RangeSlider>(top.at(1))
          .onChanged!(const RangeValues(300, 1800));
      await tester.pump();
      expect(find.text('动作间隔（秒）：300s – 1800s'), findsOneWidget);

      // 2) 遵循免打扰开关。
      final quiet = find.widgetWithText(SwitchListTile, '遵循免打扰时段');
      tester.widget<SwitchListTile>(quiet).onChanged!(false);
      await tester.pump();

      // 3) 工作日两段（默认开）→ 驱动其音量/时长/次数三条滑块。
      await driveAllSliders();

      // 4) 打开休息日两段 → 再驱动一遍（此时共 6 段全部启用）。
      for (final label in ['休息日·白天', '休息日·夜间']) {
        final sw = find.byKey(ValueKey<String>('pp_enabled_$label'));
        await tester.ensureVisible(sw);
        tester.widget<SwitchListTile>(sw).onChanged!(true);
        await tester.pump();
      }
      await driveAllSliders();

      // 5) 「恢复默认」→ 回到出厂区间；再「保存」落库。
      await tester.tap(find.widgetWithText(TextButton, '恢复默认'));
      await tester.pump();
      expect(find.text('白天时段：6:00 – 21:00'), findsOneWidget,
          reason: '恢复默认应回到出厂白天时段（昼夜导向：06:00–21:00）');

      await tester.tap(find.text('保存'));
      await waitForText(tester, '生成参数已保存');
      final raw = await prefString('counter_plan_params_json');
      expect(raw, isNotNull);
      final saved =
          CounterPlanParams.fromJson(jsonDecode(raw!) as Map<String, dynamic>);
      expect(saved.dayStartHour, 6);
      expect(saved.dayEndHour, 21);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07v 参数对话框：取消不落库', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      final edit = find.byKey(const ValueKey<String>('plan_params_edit'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await waitFor(tester, () => find.text('反击计划生成参数').evaluate().isNotEmpty,
          reason: '应弹出参数对话框');

      final sliders = find.byType(RangeSlider);
      tester.widget<RangeSlider>(sliders.at(0)).onChanged!(const RangeValues(9, 19));
      await tester.pump();

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(await prefString('counter_plan_params_json'), isNull,
          reason: '取消不应落库');
    }, timeout: perTest);

    testWidgets('SET-07w 参数对话框：排期六选一 + 条件字段驱动 → 落库', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      final edit = find.byKey(const ValueKey<String>('plan_params_edit'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await waitFor(tester, () => find.text('反击计划生成参数').evaluate().isNotEmpty,
          reason: '应弹出参数对话框');

      void tapMode(PlanScheduleMode m) {
        tester
            .widget<ChoiceChip>(find.byKey(ValueKey<String>('pp_mode_${m.name}')))
            .onSelected!(true);
      }

      // 默认循环随机：渲染周一至周日 7 个星期 chip，其它模式字段不出现。
      expect(find.byKey(const ValueKey<String>('pp_wd_1')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('pp_occ')), findsNothing);

      // 切「几次」→ 出现次数下拉，驱动一次。
      tapMode(PlanScheduleMode.several);
      await tester.pump();
      final occ = find.byKey(const ValueKey<String>('pp_occ'));
      expect(occ, findsOneWidget);
      tester.widget<DropdownButton<int>>(occ).onChanged!(6);
      await tester.pump();

      // 切「指定日期」→ 出现日期按钮，未设置。
      tapMode(PlanScheduleMode.specificDate);
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('pp_specific_date')), findsOneWidget);
      expect(find.text('未设置'), findsOneWidget);

      // 切「日期区间」→ 出现两个日期按钮。
      tapMode(PlanScheduleMode.dateRange);
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('pp_range_start')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('pp_range_end')), findsOneWidget);

      // 切回「循环随机」→ 关闭周三（至少保留一天）。
      tapMode(PlanScheduleMode.recurringRandom);
      await tester.pump();
      tester
          .widget<FilterChip>(find.byKey(const ValueKey<String>('pp_wd_3')))
          .onSelected!(false);
      await tester.pump();

      await tester.tap(find.text('保存'));
      await waitForText(tester, '生成参数已保存');
      final saved = CounterPlanParams.fromJson(
          jsonDecode((await prefString('counter_plan_params_json'))!)
              as Map<String, dynamic>);
      expect(saved.scheduleMode, PlanScheduleMode.recurringRandom);
      expect(saved.weekdays, isNot(contains(3)));
      expect(saved.weekdays.length, 6);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07y 参数对话框：severalDays/日期选择器/周几追加 → 全覆盖 + 落库',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      final edit = find.byKey(const ValueKey<String>('plan_params_edit'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await waitFor(tester,
          () => find.text('反击计划生成参数').evaluate().isNotEmpty,
          reason: '应弹出参数对话框');

      void tapMode(PlanScheduleMode m) {
        tester
            .widget<ChoiceChip>(find.byKey(ValueKey<String>('pp_mode_${m.name}')))
            .onSelected!(true);
      }

      /// 点开日期按钮 → 日期选择器弹出 → 直接确认（回填 initialDate）→ 关闭。
      /// 这条路径覆盖 `_dateTile` 的 `onPressed` 整体（选择器构造 + ISO 回填）。
      Future<void> pickDate(String tileKey) async {
        final tile = find.byKey(ValueKey<String>(tileKey));
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await waitFor(tester, () => find.text('OK').evaluate().isNotEmpty,
            reason: '日期选择器应弹出（$tileKey）');
        await tester.tap(find.text('OK'));
        await waitFor(tester, () => find.text('OK').evaluate().isEmpty,
            reason: '日期选择器应关闭（$tileKey）');
      }

      // 「几天内」（severalDays）：出现"天数"下拉并驱动一次（含 spanDays 回写）。
      tapMode(PlanScheduleMode.severalDays);
      await tester.pump();
      final span = find.byKey(const ValueKey<String>('pp_span'));
      expect(span, findsOneWidget, reason: 'severalDays 必须有"天数"字段');
      tester.widget<DropdownButton<int>>(span).onChanged!(7);
      await tester.pump();

      // 「指定日期」：点开日期选择器并确认 → onChanged 回填。
      tapMode(PlanScheduleMode.specificDate);
      await tester.pump();
      await pickDate('pp_specific_date');

      // 「日期区间」：起止两个日期按钮都要能点开确认。
      tapMode(PlanScheduleMode.dateRange);
      await tester.pump();
      await pickDate('pp_range_start');
      await pickDate('pp_range_end');

      // 「循环随机」：先关一天（至少留一天），再加回来 → 覆盖"追加"分支。
      tapMode(PlanScheduleMode.recurringRandom);
      await tester.pump();
      final wd3 = find.byKey(const ValueKey<String>('pp_wd_3'));
      tester.widget<FilterChip>(wd3).onSelected!(false);
      await tester.pump();
      tester.widget<FilterChip>(wd3).onSelected!(true);
      await tester.pump();

      await tester.tap(find.text('保存'));
      await waitForText(tester, '生成参数已保存');
      final saved = CounterPlanParams.fromJson(
          jsonDecode((await prefString('counter_plan_params_json'))!)
              as Map<String, dynamic>);
      expect(saved.scheduleMode, PlanScheduleMode.recurringRandom);
      expect(saved.weekdays, contains(3), reason: '追加回来的一天必须在集合里');
      expect(saved.weekdays.length, 7, reason: '关一天再加回来 = 仍是 7 天');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07x 一键更新节假日：成功落「自动覆盖表」+ 回执', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(
          tester, overrides: [holidayOverride(), counterPlanOverride()]);
      await switchTab(tester, 1);

      final tile = find.byKey(const ValueKey<String>('holiday_update'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await waitForText(tester, '已更新节假日表');
      // 落库到**自动覆盖表**（与手动覆盖 `counter_plan_overrides` 分开）
      final raw = await prefString('counter_plan_auto_overrides');
      expect(raw, isNotNull);
      expect(raw, contains('2026-01-01'));
      expect(raw, contains('restday'));
      expect(await prefInt('counter_plan_auto_overrides_at'), isNotNull);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07x2 更新失败（全源 500）→ 如实报错 + 不落表', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(
          tester, overrides: [holidayOverride(ok: false), counterPlanOverride()]);
      await switchTab(tester, 1);

      final tile = find.byKey(const ValueKey<String>('holiday_update'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await waitForText(tester, '节假日更新失败（已保留内置表）');
      expect(await prefString('counter_plan_auto_overrides'), isNull);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07i 一键 AI 生成并导入（成功）→ 落库 + 回执', (tester) async {
      SharedPreferences.setMockInitialValues({'api_key': 'sk-test'});
      await pumpSettings(
          tester, overrides: [deepSeekOverride(ok: true), counterPlanOverride()]);
      await switchTab(tester, 1);

      await tester.tap(find.text('一键 AI 生成并导入'));
      await waitForText(tester, '反击计划已生效');

      expect(await prefString('counter_plan_json'), isNotNull);
      expect(await prefBool('counter_plan_enabled'), isTrue);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07i2 AI 失败 → 提示「AI 生成失败」且不落库', (tester) async {
      SharedPreferences.setMockInitialValues({'api_key': 'sk-test'});
      await pumpSettings(
          tester, overrides: [deepSeekOverride(ok: false)]);
      await switchTab(tester, 1);

      await tester.tap(find.text('一键 AI 生成并导入'));
      await waitForText(tester, 'AI 生成失败');

      expect(await prefString('counter_plan_json'), isNull, reason: '不落库');
      expect(await prefBool('counter_plan_enabled'), isNull);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07j 导入合法 JSON 计划 → 落库 + 回执', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final f = File('${tmp.path}/plan.json')
        ..writeAsStringSync(CounterPlan.defaults().toPrettyJson());
      final prevPicker = FilePicker.platform;
      addTearDown(() => FilePicker.platform = prevPicker);
      FilePicker.platform =
          _FakeFilePicker(FilePickerResult([_pf('plan.json', f)]));
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      await tester.tap(find.text('导入 JSON'));
      await waitForText(tester, '反击计划已生效');

      expect(await prefString('counter_plan_json'), isNotNull);
      expect(await prefBool('counter_plan_enabled'), isTrue);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07j2 导入非法 JSON → 提示且不落库', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final f = File('${tmp.path}/bad.json')
        ..writeAsStringSync('{{{ not json');
      final prevPicker = FilePicker.platform;
      addTearDown(() => FilePicker.platform = prevPicker);
      FilePicker.platform =
          _FakeFilePicker(FilePickerResult([_pf('bad.json', f)]));
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      await tester.tap(find.text('导入 JSON'));
      await waitForText(tester, '不是合法 JSON');

      expect(await prefString('counter_plan_json'), isNull);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07j3 计划校验未通过 → 提示且不落库', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final f = File('${tmp.path}/badschema.json')
        ..writeAsStringSync(jsonEncode({'schema': 'other/9'}));
      final prevPicker = FilePicker.platform;
      addTearDown(() => FilePicker.platform = prevPicker);
      FilePicker.platform =
          _FakeFilePicker(FilePickerResult([_pf('badschema.json', f)]));
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      await tester.tap(find.text('导入 JSON'));
      await waitForText(tester, '计划校验未通过');

      expect(await prefString('counter_plan_json'), isNull);
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07k 下载 JSON 模版 → 写盘并分享', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);
      await switchTab(tester, 1);

      await tester.tap(find.text('下载 JSON 模版'));
      await waitFor(tester, () => shareCalls.any((c) => c.method == 'shareFiles'),
          reason: '下载模版应在写盘后调起分享');

      final f = File('${tmp.path}/sonicshield_counter_plan_template.json');
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), CounterPlan.defaults().toPrettyJson());
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07l 下线已启用计划 → counter_plan_enabled 变 false', (tester) async {
      final plan = CounterPlan.defaults();
      SharedPreferences.setMockInitialValues({
        'counter_plan_json': jsonEncode(plan.toJson()),
        'counter_plan_enabled': true,
      });
      await pumpSettings(tester, overrides: [counterPlanOverride()]);
      await switchTab(tester, 1);

      await tester.tap(find.text('下线'));
      await waitForText(tester, '已下线反击计划');

      expect(await prefBool('counter_plan_enabled'), isFalse,
          reason: '下线必须把启用状态置回 false');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07m 模版写盘失败（取不到临时目录）→ 明说「导出模版失败」',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      // 取不到临时目录 ⇒ getTemporaryDirectory 抛 ⇒ 必须被 catch 成可读文案，
      // 而不是让异步错误裸露（否则用户点了"下载模版"却毫无反应）。
      messenger().setMockMethodCallHandler(kPathProvider, (c) async => null);
      await pumpSettings(tester);
      await switchTab(tester, 1);

      await tester.tap(find.text('下载 JSON 模版'));
      await waitForText(tester, '导出模版失败：');
      expect(shareCalls, isEmpty, reason: '写盘都没成功，不得调起分享');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-07n 点音色卡片 → 选中态切到该音色（试听目标真的变了）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);
      await switchTab(tester, 1);

      const key = ValueKey<String>('voice_az_db_male_yunbiao');
      // 前置：默认选中不是该在线音色（默认是系统女声）。
      expect(
          find.descendant(
              of: find.byKey(key),
              matching: find.byIcon(Icons.radio_button_checked)),
          findsNothing);

      await tester.ensureVisible(find.byKey(key));
      await tester.tap(find.byKey(key));
      await tester.pump();

      expect(
          find.descendant(
              of: find.byKey(key),
              matching: find.byIcon(Icons.radio_button_checked)),
          findsOneWidget,
          reason: '点击必须真的切到该音色，否则试听还是旧音色（静默失效）');
    }, timeout: perTest);

    testWidgets('SET-07o 点「取证文件管理」→ 打开取证页（导航真的发生）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      // 取证页默认 store 基于应用文档目录 —— 给通道一个真实空目录，避免
      // 未打桩时抛 MissingPlatformDirectoryException 掩盖导航是否发生。
      messenger().setMockMethodCallHandler(kPathProvider, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') return tmp.path;
        if (call.method == 'getTemporaryDirectory') return tmp.path;
        return null;
      });
      await pumpSettings(tester);

      await tester.tap(find.text('取证文件管理'));
      await waitForText(tester, '录音取证文件');
      expect(find.text('录音取证文件'), findsOneWidget,
          reason: '点击必须真的打开取证页，而不是留在设置页什么都不做');
    }, timeout: perTest);

    testWidgets('SET-07p 试听对话框点「关闭」→ 对话框关掉（不留半开状态）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);
      await switchTab(tester, 1);

      await tester.tap(find.text('试听所选音色'));
      await waitFor(tester, () => find.text('关闭').evaluate().isNotEmpty,
          reason: '应弹出试听对话框');

      await tester.tap(find.text('关闭'));
      await waitFor(tester, () => find.text('关闭').evaluate().isEmpty,
          reason: '关闭后对话框应消失');
    }, timeout: perTest);

    testWidgets('SET-07r 导入计划时落库异常 → 明说「导入失败」，不静默',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final f = File('${tmp.path}/plan_boom.json')
        ..writeAsStringSync(CounterPlan.defaults().toPrettyJson());
      final prevPicker = FilePicker.platform;
      addTearDown(() => FilePicker.platform = prevPicker);
      FilePicker.platform =
          _FakeFilePicker(FilePickerResult([_pf('plan_boom.json', f)]));
      await pumpSettings(tester, overrides: [
        counterPlanServiceProvider.overrideWith((ref) async {
          final prefs = await SharedPreferences.getInstance();
          return CounterPlanService(
            tasks: TaskRepository(db),
            store: CounterPlanStore(prefs),
            // 计划本身合法，坏在下游（音源解析抛错）⇒ 只能靠 catch 兜住。
            resolveAudioIds: (ids) async => throw StateError('音源库损坏'),
            replan: () async {},
          );
        }),
      ]);
      await switchTab(tester, 1);

      await tester.tap(find.text('导入 JSON'));
      await waitForText(tester, '导入失败：');
      await settleSnackBars(tester);
    }, timeout: perTest);
  });

  // ─────────────── SET-08 全局执行总开关与例外清单（v79） ───────────────

  group('SET-08 全局执行总开关与例外清单（v79）', () {
    Task mk(String id, {bool? quietExempt, bool forceRun = false}) => Task(
          id: id,
          name: '任务$id',
          enabled: true,
          triggerType: TriggerType.dailyAt,
          trigger: const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)),
          actionType: ActionType.notify,
          action: const NotifyAction(title: 'T', body: 'B'),
          assetIds: const [],
          cooldownSec: 60,
          quietPolicy: QuietPolicy.skip,
          priority: 0,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
          quietExempt: quietExempt,
          forceRun: forceRun,
        );

    /// 起页；两个"例外清单"provider 用**非空**结果注入，专门驱动列表分支。
    ///
    /// ⚠️ 视口要**足够高**（6000）：设置页 body 是惰性 `ListView`，只构建
    /// 「视口 + cacheExtent」内的子项。4000 时刚好切在夜间豁免例外清单与
    /// 总开关例外清单之间 —— 上面那条 `任务a` 建出来了、下面 `任务b` 没有，
    /// 断言会毫无道理地找不到元素。
    Future<void> pumpMaster(WidgetTester tester, {String? mode}) async {
      SharedPreferences.setMockInitialValues(
          {if (mode != null) PrefsKeys.runMasterMode: mode});
      tester.view.physicalSize = const Size(1200, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            quietExemptCountProvider.overrideWith((ref) async => 0),
            quietExemptOverrideTasksProvider
                .overrideWith((ref) async => [mk('a', quietExempt: true)]),
            forceRunTasksProvider
                .overrideWith((ref) async => [mk('b', forceRun: true)]),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await waitFor(tester,
          () => find.textContaining('全局执行总开关').evaluate().isNotEmpty,
          reason: '设置页应渲染出总开关区块');
      // ⚠️ 进页的 post-frame 回调会 `ref.invalidate(forceRunTasksProvider)`
      // （settings_screen.dart initState），被覆盖的 provider 因此会**第二次**
      // 解析 —— 中间有一瞬是 `AsyncLoading`（清单显示 0 条）。必须等它回到
      // 非空态，否则断言会撞在这一瞬上（实测：`任务b` 找不到）。
      await waitFor(tester,
          () => find.textContaining('1 条暂停期间仍执行').evaluate().isNotEmpty,
          reason: '总开关例外清单应完成 invalidate 后的第二次解析');
    }

    testWidgets('SET-08a 例外清单非空逐条列出（夜间豁免偏离 + 强制执行）',
        (tester) async {
      await pumpMaster(tester, mode: 'off');

      expect(find.textContaining('任务a（强制豁免）'), findsOneWidget,
          reason: '夜间豁免"例外清单"必须列出偏离主开关默认值的任务，'
              '否则用户以为护栏完好、实则某条任务在免打扰时段照响');
      expect(find.textContaining('任务b（强制执行）'), findsOneWidget,
          reason: '总开关暂停期间仍执行的任务必须**显式列出**，'
              '避免"以为全停了、其实还有几条在响"');
      expect(find.textContaining('强制关闭：始终暂停'), findsOneWidget,
          reason: '强制关闭档的状态行必须如实说明"始终暂停"');
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('SET-08b 点「强制开启」→ 状态行改写并落库', (tester) async {
      await pumpMaster(tester);

      await tester.tap(find.text('强制开启'));
      await waitFor(tester,
          () => find.textContaining('强制开启：忽略自动窗口').evaluate().isNotEmpty,
          reason: '切换到强制开启后状态行必须改写');
      expect(
          (await SharedPreferences.getInstance())
              .getString(PrefsKeys.runMasterMode),
          'on',
          reason: '远程/本机都用同一个 prefs 键，点选必须真的落库');
      await settleSnackBars(tester);
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
