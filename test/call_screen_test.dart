import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/features/remote/call_screen.dart';
import 'package:sonic_shield/remote/call_service.dart';

import 'support/permission_stub.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 视频通话页（`CallScreen`）宿主测试 —— 第三十二轮新建。
///
/// ## 为什么能测（干净缝，非后门）
///
/// 本页唯一主机可驱动的剩余行是**自动接通开关** `_toggleAuto`
/// （`lib/features/remote/call_screen.dart:83-108`）：
/// - 关：`CallService.setAutoAnswer(false)`（静态，仅写 SharedPreferences）。
/// - 开：先 `[camera, microphone].request()`（权限桩真实执行），再按
///   `autoAnswerBlockFor(micGranted, cameraGranted)` 决定放行还是拦截提示。
///   —— 这正是 BUG-062 的修复点（权限结果不得被丢弃）。
///
/// 全程用 `permission_stub`（通道名/方法名照抄真实现）真实申请权限，
/// 不写假用例；不触碰 `startCall`（WebRTC，设备端集成测试负责）。
///
/// `CallService.instance` 在本页仅用于 `phase`/`remoteStateChanges` 监听，
/// 宿主为 idle 流，不触发渲染分支，无需注入缝。
///
/// ## 断言准则
///
/// 用 `CallService.autoAnswerEnabled()`（读 SharedPreferences）断言开关真的
/// 生效，并用权限桩 `requests` 记录断言"真的申请了权限"——避免恒真断言。
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
}
