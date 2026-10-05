import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/features/remote/call_screen.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/permission_stub.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 视频通话页（`CallScreen`）宿主测试 —— 第三十二轮新建。
///
/// ## 为什么能测（干净缝，非后门）
///
/// 第三十二轮只覆盖了**自动接通开关** `_toggleAuto`
/// （`lib/features/remote/call_screen.dart:83-108`）。第四十一轮补上
/// **呼叫发起**与**主叫连接中界面**，两者此前一条用例都没驱动过：
/// - 关：`CallService.setAutoAnswer(false)`（静态，仅写 SharedPreferences）。
/// - 开：先 `[camera, microphone].request()`（权限桩真实执行），再按
///   `autoAnswerBlockFor(micGranted, cameraGranted)` 决定放行还是拦截提示。
///   —— 这正是 BUG-062 的修复点（权限结果不得被丢弃）。
/// - `_call`：`callStartBlockFor` 的四条拦截分支（无目标 / 麦克风 / 相机 /
///   媒体协商失败）全部可断言；**语音通话不得因相机被拒被拦下**
///   （`call_lifecycle.dart:204`）。
/// - `_ConnectingView`：相位由官方测试缝 `CallService.setPhaseForTest`
///   推进（只改状态、不建媒体，见 `call_service.dart:114-135`）；
///   对端振铃文案靠 `CallService.attach(events)` 投一条 `rc.call` 事件。
///
/// 全程用 `permission_stub`（通道名/方法名照抄真实现）真实申请权限，
/// 不写假用例；不触碰真实 WebRTC 媒体（宿主本就没有插件）。
///
/// ## 断言准则
///
/// 用 `CallService.autoAnswerEnabled()`（读 SharedPreferences）断言开关真的
/// 生效，并用权限桩 `requests` 记录断言"真的申请了权限"——避免恒真断言。
///
/// ⚠️ `FilledButton.icon` / `OutlinedButton.icon` 的运行时类型是**私有子类**
/// ⇒ `find.byType(FilledButton)` 匹配不到（`byType` 是 runtimeType 精确匹配），
/// 必须用 `byWidgetPredicate`（同类教训见 `sound_library_screen_test.dart:80`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<List<Permission>>> pump(
    WidgetTester tester, {
    required Map<Permission, PermissionStatus> permissions,
    bool autoAnswerInitially = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'rc_call_auto_answer': autoAnswerInitially,
    });
    await SharedPreferences.getInstance();

    final requests = stubPermissions(permissions);
    // 原生通道另一侧：本页 build/toggle 不直连原生，但 MaterialApp.builder 下
    // 可能经 CallOverlayHost 间接触达；桩成"原生返回 null"与 _invoke 降级一致。
    const nativeChannel = MethodChannel('sonic_shield/native');
    _messenger.setMockMethodCallHandler(nativeChannel, (call) async => null);
    addTearDown(() {
      clearPermissionStub();
      _messenger.setMockMethodCallHandler(nativeChannel, null);
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: const CallScreen(),
        ),
      ),
    );
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    return requests;
  }

  Future<void> tapAutoSwitch(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
  }

  // ---------------- 第四十一轮新增：呼叫发起 + 主叫连接中 ----------------

  PairedEndpoint ep(String id, String name) => PairedEndpoint(
      deviceId: id, name: name, secret: 'AB2CD5EF', pairedAt: DateTime.now());

  /// 呼叫按钮。见文件头 ⚠️：`.icon` 构造出来的是私有子类，
  /// `find.byType(FilledButton)` **匹配不到**。
  ButtonStyleButton callBtn(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));

  /// 可指定「已配对端点 / 预选端点」的宿主壳。
  ///
  /// 顺带把 `flutter_webrtc` 的两条通道桩成"原生返回 null"：
  /// 宿主没有该插件，不桩的话 `getUserMedia` 的 `onListen` 会把
  /// `MissingPluginException` 经 `FlutterError.reportError` 上报 ⇒ 直接判用例失败
  /// （同类坑见 `multi_video_screen_test.dart:73-76`）。
  Future<List<List<Permission>>> pumpCall(
    WidgetTester tester, {
    List<PairedEndpoint> endpoints = const [],
    String? preselect,
    // ⚠️ 不能写成 `const {Permission.camera: …}` 当默认值：`Permission` 没有
    // 原始相等性 ⇒ 常量求值失败（`Constant evaluation error`）。
    Map<Permission, PermissionStatus>? permissions,
  }) async {
    SharedPreferences.setMockInitialValues({
      'rc_call_auto_answer': false,
    });
    final store = RemoteStore(await SharedPreferences.getInstance());
    for (final e in endpoints) {
      await store.addPaired(e);
    }

    final requests = stubPermissions(permissions ??
        {
          Permission.camera: PermissionStatus.granted,
          Permission.microphone: PermissionStatus.granted,
        });
    _messenger.setMockMethodCallHandler(
        const MethodChannel('sonic_shield/native'), (call) async => null);
    _messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), (call) async => null);
    _messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Event'), (call) async => null);
    addTearDown(() {
      clearPermissionStub();
      _messenger.setMockMethodCallHandler(
          const MethodChannel('sonic_shield/native'), null);
      _messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'), null);
      _messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'), null);
    });

    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: CallScreen(preselectEndpointId: preselect),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return requests;
  }

  testWidgets('CSP-01 开自动接通·权限全授 → setAutoAnswer(true) 且文案更新',
      (tester) async {
    final requests = await pump(
      tester,
      permissions: {
        Permission.camera: PermissionStatus.granted,
        Permission.microphone: PermissionStatus.granted,
      },
    );
    // ⚠️ 断言顺序是判据的一部分：`CallScreen` **加载时不申请权限**
    // （权限只在 `_toggleAuto(true)` 里申请，见 call_screen.dart:93），
    // 所以 `requests` 的空/非空必须**在 tap 之后**看。放在 tap 之前会
    // 变成一条恒假断言（曾被误判为生产缺陷，实为测试自身错序）。
    expect(requests.isEmpty, isTrue,
        reason: '加载阶段不得申请权限（权限只在用户打开开关时申请）');
    await tapAutoSwitch(tester);
    // line 93：开路径必须先申请相机+麦克风权限
    expect(requests.isNotEmpty, isTrue,
        reason: '开自动接通必须真申请权限（BUG-062 修复点，不得丢弃结果）');
    // line 106-107：放行 → setAutoAnswer(true)
    expect(await CallService.autoAnswerEnabled(), isTrue,
        reason: '开关开启必须真的写入 SharedPreferences（line 106）');
    expect(find.text('自动接通已开启'), findsOneWidget,
        reason: '开启后 UI 必须反映 _autoAnswer=true（line 186）');
  });

  testWidgets('CSP-02 开自动接通·麦克风被拒 → 拦截提示且不写入',
      (tester) async {
    await pump(
      tester,
      permissions: {
        Permission.camera: PermissionStatus.granted,
        Permission.microphone: PermissionStatus.denied,
      },
    );
    await tapAutoSwitch(tester);
    // line 98-104：拦截 → 弹 SnackBar 提示，且保持关闭
    expect(find.byType(SnackBar), findsOneWidget,
        reason: '麦克风被拒必须弹拦截提示（BUG-062：权限结果不得丢弃）');
    expect(await CallService.autoAnswerEnabled(), isFalse,
        reason: '被拒时不得写入自动接通（line 98 早退，不调 setAutoAnswer）');
    expect(find.text('自动接通已关闭'), findsOneWidget,
        reason: '拦截后开关仍显示关闭（line 186 分支）');
  });

  testWidgets('CSP-03 关自动接通（初始已开）→ setAutoAnswer(false)',
      (tester) async {
    await pump(
      tester,
      permissions: {
        Permission.camera: PermissionStatus.granted,
        Permission.microphone: PermissionStatus.granted,
      },
      autoAnswerInitially: true,
    );
    expect(find.text('自动接通已开启'), findsOneWidget,
        reason: '预置已开启 → 初始 UI 应为"已开启"');
    await tapAutoSwitch(tester);
    // line 86-89：关路径直接 setAutoAnswer(false)，不申请权限
    expect(await CallService.autoAnswerEnabled(), isFalse,
        reason: '关闭必须真的写入 false（line 87）');
  });

  // ================= 第四十一轮：呼叫发起（CSP-04…08） =================

  testWidgets('CSP-04 未配对 → 两个呼叫按钮都是禁用态（不是点了没反应）',
      (tester) async {
    await pumpCall(tester);

    expect(find.textContaining('尚未配对端点'), findsOneWidget);
    expect(callBtn(tester, '视频呼叫').onPressed, isNull,
        reason: '没有可呼的端点就必须禁用 —— "点了什么都没发生"正是 BUG-D 的观感');
    expect(callBtn(tester, '语音呼叫').onPressed, isNull);
  });

  testWidgets('CSP-05 预选了一个不存在的端点 → 明确提示"请先选择一个端点"',
      (tester) async {
    await pumpCall(tester,
        endpoints: [ep('0123456789abcdef', '客厅平板')],
        preselect: 'ffffffffffffffff');

    // 按钮**可点**（`_selected != null`），但按下去找不到目标 ——
    // 这正是"静默 return"会变成"按钮坏了"的那种场景。
    expect(callBtn(tester, '视频呼叫').onPressed, isNotNull);

    await tester.tap(find.text('视频呼叫'));
    await tester.pumpAndSettle();

    expect(find.text('请先选择一个端点'), findsOneWidget,
        reason: '找不到目标端点必须说清楚，不能静默 return（BUG-D）');
  });

  testWidgets('CSP-11 点另一个单选项 → 选择真的写回（不是只改外观）', (tester) async {
    await pumpCall(tester, endpoints: [
      ep('0123456789abcdef', '客厅平板'),
      ep('fedcba9876543210', '书房音箱'),
    ]);

    // 无预选时默认选中第一个（call_screen.dart:76-77）。
    expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
            .groupValue,
        '0123456789abcdef');

    await tester.tap(find.text('书房音箱'));
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
            .groupValue,
        'fedcba9876543210',
        reason: '点了没反应 = 用户以为选中了、实际呼叫的还是上一个端点（同类观感见 BUG-D）');
  });

  testWidgets('CSP-06 视频呼叫·麦克风被拒 → 拦截并给出原因（不进入 startCall）',
      (tester) async {
    final requests = await pumpCall(tester,
        endpoints: [ep('0123456789abcdef', '客厅平板')],
        permissions: {
          Permission.microphone: PermissionStatus.denied,
          Permission.camera: PermissionStatus.granted,
        });

    await tester.tap(find.text('视频呼叫'));
    await tester.pumpAndSettle();

    expect(requests.single.toSet(),
        {Permission.microphone, Permission.camera},
        reason: '视频呼叫必须同时申请麦克风与相机（call_screen.dart:120-123），'
            '且权限结果不得丢弃（BUG-062）');
    expect(find.text('需要麦克风权限才能通话（否则对方听不到你）'), findsOneWidget,
        reason: '被拒必须给出可执行的下一步，而不是一句"呼叫失败"');
  });

  testWidgets('CSP-07 视频呼叫·相机被拒 → 提示相机（视频必需）', (tester) async {
    await pumpCall(tester,
        endpoints: [ep('0123456789abcdef', '客厅平板')],
        permissions: {
          Permission.microphone: PermissionStatus.granted,
          Permission.camera: PermissionStatus.denied,
        });

    await tester.tap(find.text('视频呼叫'));
    await tester.pumpAndSettle();

    expect(find.text('需要相机权限才能发起视频通话'), findsOneWidget);
  });

  testWidgets('CSP-08 语音呼叫不得因"相机被拒"被拦下（可用不得误报为不可用）',
      (tester) async {
    await pumpCall(tester,
        endpoints: [ep('0123456789abcdef', '客厅平板')],
        permissions: {
          Permission.microphone: PermissionStatus.granted,
          Permission.camera: PermissionStatus.denied,
        });

    await tester.tap(find.text('语音呼叫'));
    await tester.pumpAndSettle();

    expect(find.text('需要相机权限才能发起视频通话'), findsNothing,
        reason: '语音通话不需要相机 ⇒ 不能被相机权限拦下（call_lifecycle.dart:204）');
    // 宿主没有 WebRTC 插件 ⇒ 媒体协商必然失败；关键是**失败原因必须点名媒体**，
    // 不能一锅端成"呼叫失败"（BUG-D）。
    expect(find.text('打不开摄像头/麦克风：可能被其它应用占用，请关闭后重试'),
        findsOneWidget,
        reason: 'getUserMedia 失败 ⇒ lastStartBlock=mediaFailed，'
            '必须被翻译成可执行的提示（call_screen.dart:145-146）');
  });

  // ================= 第四十一轮：主叫"连接中"界面（CSP-09…10） =================

  testWidgets('CSP-09 主叫「连接中」相位 → 必须有可见反馈与挂断入口（BUG-D）',
      (tester) async {
    CallService.instance.setPhaseForTest(CallPhase.connecting);
    addTearDown(() => CallService.instance.setPhaseForTest(CallPhase.idle));

    await pumpCall(tester, endpoints: [ep('0123456789abcdef', '客厅平板')]);

    // 修 BUG-D 之前：这一段什么都不显示 —— CallOverlayHost 只覆盖
    // ringing/connected，而主叫的阶段是 connecting，进"通话页"的路由又不存在。
    expect(find.text('连接中…'), findsOneWidget,
        reason: '主叫点下按钮后必须看得见"正在连"，否则观感就是"按钮坏了"');
    expect(find.byIcon(Icons.call_end), findsOneWidget,
        reason: '这几十秒里必须能取消呼叫，否则用户被锁在"连接中"');

    await tester.tap(find.byIcon(Icons.call_end));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '取消呼叫是正常路径，绝不能抛');
    expect(CallService.instance.currentPhase, isNot(CallPhase.connecting),
        reason: '点了挂断就必须离开 connecting（_hangUp → hangUp → _teardown）');
  });

  testWidgets('CSP-10 对端振铃 → 文案切成"对方振铃中…"（可区分"在响"与"没送到"）',
      (tester) async {
    CallService.instance.setPhaseForTest(CallPhase.connecting);
    final ctrl = StreamController<Map<String, dynamic>>.broadcast();
    CallService.instance.attach(ctrl.stream);
    addTearDown(() {
      CallService.instance.setPhaseForTest(CallPhase.idle);
      unawaited(ctrl.close());
    });

    await pumpCall(tester, endpoints: [ep('0123456789abcdef', '客厅平板')]);
    expect(find.text('连接中…'), findsOneWidget);

    // 订阅建立**之后**才投递事件（`Stream.value` 单订阅，重订阅会抛）。
    ctrl.add({
      'type': RcEvt.callState,
      'payload': const {'state': 'ringing'},
    });
    await tester.pumpAndSettle();

    expect(find.text('对方振铃中…'), findsOneWidget,
        reason: '"对方在响"与"信令根本没送到"的下一步动作完全不同，必须可区分'
            '（call_lifecycle.dart:91-92）');
    expect(find.text('连接中…'), findsNothing);
  });

  // ================= 无障碍语义（P2-31） =================

  testWidgets('CSP-12 主叫挂断按钮具备读屏可播报的语义名称（P2-31）',
      (tester) async {
    CallService.instance.setPhaseForTest(CallPhase.connecting);
    addTearDown(() => CallService.instance.setPhaseForTest(CallPhase.idle));

    await pumpCall(tester, endpoints: [ep('0123456789abcdef', '客厅平板')]);

    // 修 P2-31 之前：挂断是纯图标 FAB，无 tooltip/Semantics ⇒
    // TalkBack/VoiceOver 只会播报"按钮"，用户无法分辨其作用。
    expect(find.byTooltip('挂断'), findsOneWidget,
        reason: '图标按钮必须有语义名称，否则读屏用户无法识别"挂断"');
  });
}
