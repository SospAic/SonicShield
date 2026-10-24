/// R96 覆盖率补测（settings_screen.dart / task_editor_screen.dart /
/// script_builder_screen.dart 的**残余未覆盖行**）。
///
/// ## 为什么单独开一个文件
/// 门禁覆盖率 ratchet 要求「可测面 ≥ 98.6%」，本轮只补**三个 widget 层文件**
/// 里 lcov 报 0 命中的行。既有 `settings_screen_test.dart`（67 例）已经把
/// 页面主链路锁死，本文件只补它**没走到**的分支，避免动既有文件（并行改动）。
///
/// ## 宿主硬约束（与 `settings_screen_test.dart` 同源，改前先读）
/// 1. **不 `pumpAndSettle` 等数据**：统一 `waitFor`（有界轮询 + 超时 `fail`）。
/// 2. **不在 `testWidgets` 里发起真实 DB 写**：本文件只碰 prefs（内存实现）与
///    被 override 的 provider，不打开 sqflite —— 三个 provider 全部换掉，
///    页面不会去查库，也就没有 FakeAsync 下永不完成的事务。
/// 3. **平台单例替身必须在 `tearDown` 还原**（`BackgroundServiceManager`
///    的两个 hook 是静态字段，漏还原会污染同进程的其它用例）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/core/app_keys.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/models/counter_plan_params.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/features/settings/settings_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/holiday_update_service.dart';

/// `HolidayUpdateService` 替身：`update()` 直接抛。
///
/// 为什么需要它：既有的 SET-07x2 只覆盖了「所有源都 500」→ `anyOk == false`
/// 的**早退**分支（settings_screen.dart:570-573），而 `_updateHolidays` 的
/// `catch`（:578-580）需要**异常真的抛出来**（例如依赖注入失败、解析期
/// 未预期异常）。真实服务内部把单源失败吞成 `HolidayYearResult.fail`，
/// 永远不抛 ⇒ 只能由替身制造。
class _ThrowingHolidayService extends HolidayUpdateService {
  _ThrowingHolidayService()
      : super(client: MockClient((_) async => http.Response('boom', 500)));

  @override
  Future<HolidayUpdateResult> update({List<int>? years}) async =>
      throw StateError('boom');
}

void main() {
  const perTest = Timeout(Duration(seconds: 60));

  setUp(() {
    // 设置页的「夜间独立豁免」写入后会调 `replan()`；宿主上没有后台服务
    // 平台实现，必须换成 no-op，否则会抛 MissingPluginException。
    BackgroundServiceManager.replanHook = () async {};
    BackgroundServiceManager.invokeHook = (method, args) async {};
  });

  tearDown(() {
    // 静态字段：不还原会污染同进程后续用例（铁律）。
    BackgroundServiceManager.replanHook = null;
    BackgroundServiceManager.invokeHook = null;
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() cond, {
    required String reason,
    int maxRounds = 200,
  }) async {
    for (var i = 0; i < maxRounds; i++) {
      if (cond()) return;
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('等待超时（$maxRounds 轮）：$reason');
  }

  Future<void> waitForText(WidgetTester tester, String substring) => waitFor(
        tester,
        () => find.textContaining(substring).evaluate().isNotEmpty,
        reason: '应出现含「$substring」的文案',
      );

  /// 推掉 SnackBar 的自动关闭计时，否则收尾判 "A Timer is still pending"。
  Future<void> settleSnackBars(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
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
          // 三个会查库的 provider 全部换掉：本文件不打开 sqflite，
          // 让它们真去查库会在 FakeAsync 里留下永不完成的事务与锁超时 Timer。
          quietExemptCountProvider.overrideWith((ref) async => 0),
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

  /// 切 TAB（`TabBarView` 惰性构建，不切过去就找不到该页控件）。
  Future<void> switchTab(WidgetTester tester, int index) async {
    const labels = ['执行与护栏', '保活与备份', '语音与音色', '反击计划', '数据与合规'];
    await tester.tap(find.text(labels[index]).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  // ══════════════════ COV-01 一次性「respectDnd 默认值变更」提示 ══════════════════
  //
  // 覆盖 settings_screen.dart:923,925,926,928,930,931,932,941,943,946（横幅本体）
  // 与 :386-390（`_dismissDndDefaultNotice` 的整套关闭逻辑）。
  // 入口：prefs 键 `dnd_default_changed_notice_pending` = true（由启动链 F5 写）。
  group('COV-01 一次性行为变更提示', () {
    testWidgets('COV-01 横幅按 prefs 键渲染，「我已知晓」立即置回 false 并消失',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        kDndDefaultChangedNoticePending: true,
      });
      await pumpSettings(tester);

      const cardKey = ValueKey<String>('dnd_default_changed_notice');
      expect(find.byKey(cardKey), findsOneWidget,
          reason: 'prefs 键为 true 时必须展示一次性提示');
      expect(find.text('振动任务行为变更提示'), findsOneWidget);
      expect(find.textContaining('穿透系统勿扰'), findsOneWidget,
          reason: '提示正文必须说清行为变更');

      await tester.tap(find.byKey(
          const ValueKey<String>('dnd_default_changed_notice_ok')));
      await tester.pump();

      expect(find.byKey(cardKey), findsNothing, reason: '点完应立即收起');
      final p = await SharedPreferences.getInstance();
      expect(p.getBool(kDndDefaultChangedNoticePending), isFalse,
          reason: '关闭必须立刻落 prefs（不等页面销毁）—— 否则下次进来还弹');
    }, timeout: perTest);

    testWidgets('COV-01b 键为 false/缺失 → 不渲染横幅（不能变成常驻骚扰）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);
      expect(
          find.byKey(const ValueKey<String>('dnd_default_changed_notice')),
          findsNothing);
    }, timeout: perTest);
  });

  // ══════════════ COV-02 一键更新节假日：异常路径（catch） ══════════════
  //
  // 覆盖 settings_screen.dart:578-580 —— `_updateHolidays` 的 `catch`。
  // 既有 SET-07x2 只覆盖 `anyOk == false` 的早退（:570-573），不抛异常。
  group('COV-02 节假日更新异常', () {
    testWidgets('COV-02 服务抛异常 → 如实报错且不写自动覆盖表', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, overrides: [
        holidayUpdateServiceProvider
            .overrideWith((ref) async => _ThrowingHolidayService()),
      ]);
      await switchTab(tester, 3);

      final tile = find.byKey(const ValueKey<String>('holiday_update'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await waitForText(tester, '正在联网更新节假日');
      // ⚠️ `ScaffoldMessenger` 是**队列**：第二条 SnackBar 要等第一条 4s 到期
      // 才会显示。不先推掉第一条，`waitFor` 会一直看到「正在联网更新…」。
      await settleSnackBars(tester);

      await waitForText(tester, '节假日更新失败（已保留内置表）');
      final p = await SharedPreferences.getInstance();
      expect(p.getString('counter_plan_auto_overrides'), isNull,
          reason: '异常时绝不能写空表（会把内置表冲掉）');
      await settleSnackBars(tester);
    }, timeout: perTest);
  });

  // ══════════════ COV-03 生成参数校验失败 ══════════════
  //
  // 覆盖 settings_screen.dart:599-601 —— 对话框返回了**不合法**参数时，
  // 不落库、只给可读提示。入口：切到「指定日期」排期但不选日期，
  // `CounterPlanParams.validate()` 必报「需要一个合法日期」。
  group('COV-03 生成参数校验', () {
    testWidgets('COV-03 参数不合法 → 提示「参数未通过校验」且不落库', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester);
      await switchTab(tester, 3);

      final edit = find.byKey(const ValueKey<String>('plan_params_edit'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await waitFor(
        tester,
        () => find.text('反击计划生成参数').evaluate().isNotEmpty,
        reason: '应弹出参数对话框',
      );

      final mode = find.byKey(
          const ValueKey<String>('pp_mode_specificDate'));
      await tester.ensureVisible(mode);
      tester.widget<ChoiceChip>(mode).onSelected!(true);
      await tester.pump();

      await tester.tap(find.text('保存'));
      await waitForText(tester, '参数未通过校验');

      final p = await SharedPreferences.getInstance();
      expect(p.getString('counter_plan_params_json'), isNull,
          reason: '校验失败不得落库（否则下次生成会带着错参数跑）');
      await settleSnackBars(tester);
    }, timeout: perTest);
  });

  // ══════════ COV-04 夜间时段被合规护栏吞掉 → 引导开启主开关 ══════════
  //
  // 覆盖 settings_screen.dart:645（计划的「休息日·夜间」取值分支）、
  // :648（参数的「休息日·夜间」取值分支）与 :688（横幅里「开启夜间豁免」
  // 按钮的 onPressed）。
  //
  // 为什么要把两个「夜间」都设成「工作日关、休息日开」：`||` 是短路的 ——
  // 只有**左操作数为 false** 时右操作数那行才会被执行，而那两行正是未覆盖行。
  group('COV-04 夜间时段被免打扰吞掉', () {
    testWidgets('COV-04 计划/参数的夜间窗口组合 + 横幅按钮可点', (tester) async {
      const plan = CounterPlan(
        workdayNight: CounterWindow(enabled: false),
        restdayNight: CounterWindow(enabled: true),
      );
      final params = CounterPlanParams.defaults().copyWith(
        workdayNight: const PlanWindowParams(enabled: false),
      );
      SharedPreferences.setMockInitialValues({
        'counter_plan_json': jsonEncode(plan.toJson()),
        'counter_plan_enabled': true,
        'counter_plan_params_json': jsonEncode(params.toJson()),
      });
      await pumpSettings(tester);
      await switchTab(tester, 3);

      // 休息日·夜间启用 + 主开关未开 ⇒ 必须把「夜间不会生成」摆到台面上。
      expect(find.text('夜间时段当前不会生成任何动作'), findsOneWidget);

      final btn =
          find.byKey(const ValueKey<String>('plan_enable_night_exempt'));
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await waitFor(
        tester,
        () => find.text('开启夜间独立豁免？').evaluate().isNotEmpty,
        reason: '削弱合规护栏前必须二次确认',
      );
      // 取消：只锁「按钮真的接到回调」，不改主开关（改开关另有既有用例）。
      await tester.tap(find.text('取消'));
      await waitFor(
        tester,
        () => find.text('开启夜间独立豁免？').evaluate().isEmpty,
        reason: '取消后确认框应关闭',
      );
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('quiet_exempt_master'), isNull,
          reason: '取消不得写主开关');
    }, timeout: perTest);
  });
}
