// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/domain/scheduling/run_pause.dart';
import 'package:sonic_shield/features/dashboard/dashboard_screen.dart';
import 'package:sonic_shield/features/remote/assist_join_screen.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_join.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/run_master_service.dart';

import 'support/permission_stub.dart';
import 'support/ui_interaction_inventory.dart';

// R104 全功能点用户仿真（现场点击 + 触发前后状态快照）。
// 与 3139 例既有 widget 测试的分工见 support/ui_interaction_inventory.dart：
// 既有用例负责「点全」，本文件负责把点之前/点之后的状态显式采集并落盘成台账。
// 三条纪律：只用 tester.tap/enterText 等真实用户动作；只用有界 pump；
// 每条都断言状态确实变了，而不是只断言按钮存在。

/// 仿真台账：运行时逐条记录，套件结束时写成 JSON 供报告消费。
class SimLedger {
  static final List<Map<String, Object?>> rows = <Map<String, Object?>>[];

  static void record({
    required String id,
    required String control,
    required String action,
    required Map<String, Object?> before,
    required Map<String, Object?> after,
    required String verdict,
    String? note,
  }) {
    rows.add(<String, Object?>{
      'id': id,
      'control': control,
      'action': action,
      'before': before,
      'after': after,
      'verdict': verdict,
      if (note != null) 'note': note,
    });
    print('[SIM] $id $verdict  before=${jsonEncode(before)}  after=${jsonEncode(after)}');
  }

  static Set<String> get ids => rows.map((r) => r['id'] as String).toSet();

  static void flush() {
    final f = File('_pt/r104_simulation_ledger.json');
    f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'generatedAt': DateTime.now().toIso8601String(),
      'total': rows.length,
      'entries': rows,
    }));
    print('[SIM] 台账已落盘：${f.path}（${rows.length} 条）');
  }
}

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 采集**触发前/触发后**同一组状态：prefs 全量镜像 + 总开关内存值 + 页面状态文案。
Future<Map<String, Object?>> snapshot(
  WidgetTester tester, {
  Map<String, Object?> extra = const <String, Object?>{},
}) async {
  final p = await SharedPreferences.getInstance();
  final keys = p.getKeys().toList()..sort();
  final statusFinder = find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').startsWith('当前状态：'));
  final status = statusFinder.evaluate().isEmpty
      ? null
      : tester.widget<Text>(statusFinder.first).data;
  return <String, Object?>{
    'prefs': <String, Object?>{for (final k in keys) k: p.get(k)},
    'runMaster': RunMasterService.instance.mode.value.name,
    'statusText': status,
    ...extra,
  };
}

/// 有界推进（禁用 pumpAndSettle：宿主上平台 Future 可能永不完成）。
Future<void> settleBounded(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 挂载守护首页：沿用 dashboard_screen_test.dart 的干净注入缝，
  /// 生产路径一字未改（权限桩 / 原生通道桩 / 引擎态注入）。
  Future<void> pumpDashboard(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'compliance_accepted_v1': true,
    });
    await SharedPreferences.getInstance();
    // 单例内存态会跨用例污染，每个用例从 auto 起步。
    RunMasterService.instance.mode.value = RunMasterMode.auto;

    BackgroundServiceManager.lastForTest =
        const EngineState(running: false, pendingCount: 0);
    BackgroundServiceManager.stateForTest =
        Stream<EngineState>.value(const EngineState(running: false, pendingCount: 0));
    stubPermissions(<Permission, PermissionStatus>{
      Permission.notification: PermissionStatus.granted,
      Permission.microphone: PermissionStatus.granted,
    });
    const nativeChannel = MethodChannel('sonic_shield/native');
    _messenger.setMockMethodCallHandler(nativeChannel, (call) async => null);
    addTearDown(() {
      BackgroundServiceManager.lastForTest = null;
      BackgroundServiceManager.stateForTest = null;
      clearPermissionStub();
      _messenger.setMockMethodCallHandler(nativeChannel, null);
    });

    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: const DashboardScreen(),
      ),
    ));
    await settleBounded(tester);
  }

  Future<void> pumpJoin(WidgetTester tester, AssistJoinClient client) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: AssistJoinScreen(client: client)),
    ));
    await settleBounded(tester);
  }

  tearDownAll(() {
    final expected = uiInteractions
        .where((e) => e.simulated)
        .map((e) => e.id)
        .toSet();
    SimLedger.flush();
    final missing = expected.difference(SimLedger.ids);
    if (missing.isNotEmpty) {
      throw StateError('现场仿真台账缺条目（清单声明 simulated=true 却没真点过）：$missing');
    }
    if (SimLedger.rows.any((r) => r['verdict'] != 'PASS')) {
      throw StateError('现场仿真台账存在非 PASS 条目');
    }
    print('[SIM] 台账完整性校验通过：${expected.length} 条全部现场点击并 PASS');
  });

  group('R104 现场仿真：首页全局执行总开关', () {
    testWidgets('SIM-DBS-01 点「强制开启」→ prefs/mode/文案三处状态同时变化',
        (tester) async {
      await pumpDashboard(tester);
      final before = await snapshot(tester);
      expect(before['runMaster'], 'auto');

      await tester.tap(find.text('强制开启').first); // ButtonSegment 的 label
      await settleBounded(tester);

      final after = await snapshot(tester);
      final p = await SharedPreferences.getInstance();
      expect(after['runMaster'], 'on', reason: '点击后内存档位必须切到 on');
      expect(p.getString(PrefsKeys.runMasterMode), 'on',
          reason: '点击必须真的落 prefs，而不只是改界面');
      expect(after['statusText'], contains('强制开启：忽略自动窗口'),
          reason: '页面状态文案必须跟着档位刷新');
      expect(after['prefs'], isNot(before['prefs']),
          reason: '触发前后 prefs 快照必须不同');

      SimLedger.record(
        id: 'SIM-DBS-01',
        control: '全局执行总开关 SegmentedButton · 强制开启',
        action: 'tap',
        before: before,
        after: after,
        verdict: 'PASS',
      );
    });

    testWidgets('SIM-DBS-02 点「强制关闭」→ 档位 off 且文案说明只跑例外任务',
        (tester) async {
      await pumpDashboard(tester);
      final before = await snapshot(tester);
      expect(before['runMaster'], 'auto');

      await tester.tap(find.text('强制关闭').first);
      await settleBounded(tester);

      final after = await snapshot(tester);
      final p = await SharedPreferences.getInstance();
      expect(after['runMaster'], 'off');
      expect(p.getString(PrefsKeys.runMasterMode), 'off');
      expect(after['statusText'], contains('强制关闭：始终暂停，仅执行例外任务'));
      expect(after['statusText'], isNot(before['statusText']));

      SimLedger.record(
        id: 'SIM-DBS-02',
        control: '全局执行总开关 SegmentedButton · 强制关闭',
        action: 'tap',
        before: before,
        after: after,
        verdict: 'PASS',
      );
    });
  });

  group('R104 现场仿真：凭据输入白名单（BUG-153 修复验收）', () {
    testWidgets('SIM-AJS-03 易混字符在输入阶段就被挡掉，不再被静默吞字',
        (tester) async {
      final client = AssistJoinClient();
      addTearDown(() => client.leave(silent: true));
      await pumpJoin(tester, client);
      const raw = 'ILOU01ABCD';
      final before = await snapshot(tester, extra: <String, Object?>{
        'passwordField': '',
      });
      await tester.enterText(find.byType(TextField).last, raw);
      await settleBounded(tester);
      final typed = tester
              .widget<TextField>(find.byType(TextField).last)
              .controller
              ?.text ??
          '';
      final after = await snapshot(tester, extra: <String, Object?>{
        'passwordField': typed,
        'normalizeEcho': RcAssist.normalizePassword(typed),
      });
      expect(typed, 'ABCD', reason: 'I/L/O/U/0/1 不许进入输入框');
      expect(after['normalizeEcho'], typed.toUpperCase(),
          reason: '用户看到的字符必须等于提交的字符，不允许静默吞字');
      expect(after['passwordField'], isNot(before['passwordField']));
      SimLedger.record(
        id: 'SIM-AJS-03',
        control: '协助会话访问密码输入框 · 易混字符',
        action: 'enterText',
        before: before,
        after: after,
        verdict: 'PASS',
        note: 'BUG-153：旧白名单 [A-Za-z0-9] 放行易混字符，normalizePassword 随后静默剔除',
      );
    });

    testWidgets('SIM-AJS-04 小写合法密码完整保留且归一化后仍合法',
        (tester) async {
      final client = AssistJoinClient();
      addTearDown(() => client.leave(silent: true));
      await pumpJoin(tester, client);
      const lower = 'abcdefghjkmn';
      final before = await snapshot(tester, extra: <String, Object?>{
        'passwordField': '',
      });
      await tester.enterText(find.byType(TextField).last, lower);
      await settleBounded(tester);
      final typed = tester
              .widget<TextField>(find.byType(TextField).last)
              .controller
              ?.text ??
          '';
      final normalized = RcAssist.normalizePassword(typed);
      final after = await snapshot(tester, extra: <String, Object?>{
        'passwordField': typed,
        'normalized': normalized,
        'valid': RcAssist.isValidPassword(normalized),
      });
      expect(typed.length, RcAssist.passwordLength);
      expect(after['valid'], isTrue,
          reason: '小写输入经归一后必须是一条完整合法密码');
      SimLedger.record(
        id: 'SIM-AJS-04',
        control: '协助会话访问密码输入框 · 小写合法密码',
        action: 'enterText',
        before: before,
        after: after,
        verdict: 'PASS',
      );
    });
  });
  group('R104 现场仿真：协助会话凭据输入（BUG-152,153 修复验收）', () {
    testWidgets('SIM-AJS-01 端点给出的 12 位合法密码能完整敲进输入框',
        (tester) async {
      final client = AssistJoinClient();
      addTearDown(() => client.leave(silent: true));
      await pumpJoin(tester, client);

      final pw = RcAssist.generatePassword();
      expect(pw.length, 12);
      final before = await snapshot(tester, extra: <String, Object?>{
        'passwordField': '',
        'phase': client.phase.name,
      });

      // ★ 真实用户动作：逐字输入端点屏幕上显示的 12 位密码。
      await tester.enterText(find.byType(TextField).last, pw);
      await settleBounded(tester);

      final field = tester.widget<TextField>(find.byType(TextField).last);
      final typed = field.controller?.text ?? '';
      final after = await snapshot(tester, extra: <String, Object?>{
        'passwordField': typed,
        'phase': client.phase.name,
      });

      expect(typed.length, 12,
          reason: '修复前 LengthLimitingTextInputFormatter(8) 会把密码截断成 8 位');
      expect(typed, pw);
      expect(
          RcAssist.isValidPassword(RcAssist.normalizePassword(typed)), isTrue,
          reason: '输入内容必须能被 join() 接受');
      expect(after['passwordField'], isNot(before['passwordField']));

      SimLedger.record(
        id: 'SIM-AJS-01',
        control: '协助会话访问密码输入框（12 位）',
        action: 'enterText',
        before: before,
        after: after,
        verdict: 'PASS',
        note: 'BUG-152,153：R94 升 12 位时漏改 UI 上限 8；宽松白名单又放行易混字符并被静默吞掉',
      );
    });
  });
}
