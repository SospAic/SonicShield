import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/services/permission_flow.dart';

import 'support/permission_stub.dart';

/// 权限与合规流程的宿主测试 —— 第四十一轮新建。
///
/// ## 为什么是**独立文件**
///
/// `permission_flow.dart` 有 **13 行**未被覆盖、且**没有任何专属测试文件**
/// （当时只有 `dashboard_screen_test` 经由 Dashboard 间接触到它，
/// 而那条路径把 `isIgnoringBatteryOptimizations` 桩成了 `true`
/// ⇒ 「未加白 → 真的请求加白」这条真实分支从未执行）。
///
/// ## 覆盖边界（刻意回避的只有一条，且**量化**）
///
/// `_detectVendor()` 在 Android 上会读 `DeviceInfoPlugin().androidInfo`，
/// 它返回的 `AndroidDeviceInfo` 只能由 `fromMap` 构造，需要 **24 个键**
/// （`device_info_plus-10.1.2/lib/src/model/android_device_info.dart:144-170`：
/// `board/bootloader/brand/device/display/fingerprint/hardware/host/id/
/// manufacturer/model/product/tags/type/isPhysicalDevice/serialNumber/
/// isLowRamDevice` + 嵌套 `version` 的 7 个）。
/// 为 **4 行**（`L98` + 厂商指引分支 `L164-165/L168`）钉一个 24 键假数据，
/// 收益低于同等成本的其它靶点，且会把测试**绑死在插件的模型内部**上
/// （插件加键即红，而应用行为其实没变）—— 故本轮明确记为延期。
/// 那条分支影响的只是**提示文案的具体程度**，不涉及任何安全判断。
/// 本文件覆盖的是：合规门的两条出口、一站式权限申请、保活引导的三个入口。
///
/// ⚠️ `NativeBridge._invoke` 对 `MissingPluginException` **静默降级**（返回 null）
/// ⇒ 不打桩的用例会"看起来很绿"，其实一个原生方法都没调到。
/// 所以本文件一律显式打桩并把 `MethodCall` **落日志后断言**，
/// 且**不认识的方法直接抛**（不给未来的调用偷偷放行）。
const MethodChannel _nativeChannel = MethodChannel('sonic_shield/native');

/// `device_info_plus` 的通道（`device_info_plus_platform_interface-7.0.3/
/// lib/method_channel/method_channel_device_info.dart:12-14`）。
const MethodChannel _deviceInfoChannel =
    MethodChannel('dev.fluttercommunity.plus/device_info');

/// 装一个可编程的"原生端"，返回调用日志。
List<MethodCall> _installNative(Map<String, Object?> returns) {
  final log = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_nativeChannel, (call) async {
    log.add(call);
    if (!returns.containsKey(call.method)) {
      throw MissingPluginException('未桩的 native 方法：${call.method}');
    }
    return returns[call.method];
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, null);
  });
  return log;
}

/// 装机信息通道的桩：**如实模拟"宿主没有 device_info 实现"**。
///
/// ⚠️ 这一步**不能省**，而且症状和"断言写错"长得一样：
/// `TestDefaultBinaryMessenger.send` 对**没打过桩**的通道会落回
/// `delegate.send` ⇒ `ui.PlatformDispatcher.sendPlatformMessage` 在无引擎的
/// 宿主上**永不回调**（`flutter_test/lib/src/test_default_binary_messenger.dart:140-150`
/// + `_binding_io.dart` 的 `_DefaultBinaryMessenger.send`）
/// ⇒ `_detectVendor` 里的 `await` **永久挂起**（不是抛错！）
/// ⇒ 底部弹窗永远不出现，断言只会说"找不到文本"。
///
/// 抛 `MissingPluginException` 正是那条 `on Object` 兜底存在的理由：
/// 桌面平台、以及机型识别失败的 Android 机，走的就是这个分支。
void _stubDeviceInfoMissing() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_deviceInfoChannel, (call) async {
    throw MissingPluginException('宿主没有 device_info 实现：${call.method}');
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_deviceInfoChannel, null);
  });
}

/// 装机信息通道的桩：**如实返回一份合法的 Android 机型数据**（厂商可指定）。
///
/// 与 [_stubDeviceInfoMissing] 相反，这是"识别成功"的一侧 —— 上一轮把它记为
/// 延期，理由是"要为 4 行钉一个 24 键假数据、且会绑死在插件模型内部"。
/// 但那 4 行（`_detectVendor` 的 Android 分支 + 厂商指引的展示分支）恰好是
/// **提示价值最高**的一条：识别不出来只能给"通用步骤"，用户按通用路径在
/// MIUI 上根本找不到对应开关。代价可控（一次性数据），故本轮补齐。
///
/// ⚠️ 键集必须与 `device_info_plus-10.1.2` 的 `AndroidDeviceInfo.fromMap` /
/// `AndroidBuildVersion._fromMap` 的 **required 字段**逐一对齐：
/// 少一个非空键 ⇒ `fromMap` 直接抛类型错误（症状是"找不到文本"，根因在键）。
/// 插件新增必填键时这里会红 —— 这正是"绑死"的代价，已明示接受。
void _stubDeviceInfoAndroid({required String manufacturer}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_deviceInfoChannel, (call) async {
    if (call.method != 'getDeviceInfo') {
      throw MissingPluginException('未桩的 device_info 方法：${call.method}');
    }
    return <String, dynamic>{
      'version': <String, dynamic>{
        'codename': 'REL',
        'incremental': '1',
        'release': '13',
        'sdkInt': 33,
        'previewSdkInt': 0,
      },
      'board': 'x',
      'bootloader': 'x',
      'brand': 'Xiaomi',
      'device': 'x',
      'display': 'x',
      'fingerprint': 'x',
      'hardware': 'x',
      'host': 'x',
      'id': 'x',
      'manufacturer': manufacturer,
      'model': 'x',
      'product': 'x',
      'tags': 'release-keys',
      'type': 'user',
      'isPhysicalDevice': true,
      'serialNumber': 'x',
      'isLowRamDevice': false,
    };
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_deviceInfoChannel, null);
  });
}

/// 承载三个流程入口的宿主页。`showComplianceGateOnce` / `requestAllPermissions`
/// 都要 `WidgetRef`，所以必须是 [ConsumerWidget]（不是 `StatelessWidget`）。
class _FlowHost extends ConsumerWidget {
  const _FlowHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton(
              onPressed: () => showComplianceGateOnce(context, ref),
              child: const Text('打开合规门'),
            ),
            FilledButton(
              onPressed: () => requestAllPermissions(ref),
              child: const Text('申请全部权限'),
            ),
            FilledButton(
              onPressed: () => showKeepAliveGuide(context),
              child: const Text('保活引导'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _FlowHost())));
  await tester.pumpAndSettle();
}

/// 合规门持久化键的**字面量**（`permission_flow.dart` 里是私有常量 `_kComplianceAccepted`）。
/// 这里断言字面量是有意的：它是**跨版本契约** —— 改掉它等于让所有老用户
/// 的"已同意"记录失效、下次启动重新弹窗。
const String _kAcceptedKey = 'compliance_accepted_v1';

void main() {
  group('PFL 权限与合规流程', () {
    testWidgets('PFL-01 合规门·首次进入 → 弹出红线须知；点"我已阅读并承诺合法使用"才落库为真',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      expect(await isComplianceAccepted(), isFalse,
          reason: '前置条件：全新安装（含 mock）必须是"未同意"');

      await _pump(tester);
      await tester.tap(find.text('打开合规门'));
      await tester.pumpAndSettle();

      expect(find.text('使用前必读 · 合规红线'), findsOneWidget,
          reason: '合规门是法律风险的第一道闸门，点开却没有弹窗 = 合规事故');
      expect(find.text('禁止用途：'), findsOneWidget,
          reason: '"禁止什么"必须写清楚，只写"请合法使用"等于没写');

      // ⚠️ 断言必须收窄到**对话框内部**：页面上的按钮文案可能与页面别处重复
      // （第三十九轮实测假红：`find.textContaining` 命中了同名的卡片标题）。
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('我已阅读并承诺合法使用')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(await isComplianceAccepted(), isTrue,
          reason: '"已同意"必须落库，否则每次启动都再弹一次（合规门变骚扰门）');
    }, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets('PFL-02 合规门·点"不同意" → 也要**显式**落库 false（不是 key 缺失）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pump(tester);
      await tester.tap(find.text('打开合规门'));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('不同意')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      // ⚠️ 这里断言的是 `false` 而不是 `isNull`：key **存在且为 false** 才是
      // "用户明确拒绝过"，key 缺失只是"没答过"。两者在将来要区分
      // 「拒绝过就不再打扰」与「问过但被关掉了」时是不同事实。
      expect(prefs.getBool(_kAcceptedKey), isFalse,
          reason: '拒绝也要写入 false —— 否则 key 缺失，两条事实被压成一条');
      expect(await isComplianceAccepted(), isFalse);
    }, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets('PFL-03 合规门·已同意过 → 一次都不打扰（不能每次进页都弹）',
        (tester) async {
      SharedPreferences.setMockInitialValues({_kAcceptedKey: true});
      expect(await isComplianceAccepted(), isTrue);

      await _pump(tester);
      await tester.tap(find.text('打开合规门'));
      await tester.pumpAndSettle();

      // ⚠️ 用「弹窗不存在」而不是「没抛异常」做判据：`showDialog` 即使弹了
      // 也不会抛异常，只看异常等于恒真。
      expect(find.byType(AlertDialog), findsNothing,
          reason: '同意过还弹 ⇒ 合规门退化成每次启动的骚扰');
    }, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets('PFL-04 一站式权限申请 → 通知+麦克风都真的申请；电池未加白 → 真的请求加白',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final asked = stubPermissions({
        Permission.notification: PermissionStatus.granted,
        Permission.microphone: PermissionStatus.granted,
      });
      addTearDown(clearPermissionStub);

      final native = _installNative({
        'exactAlarmSupported': true,
        'isIgnoringBatteryOptimizations': false, // ← 未加白
        'requestIgnoreBatteryOptimizations': null,
      });

      await _pump(tester);
      await tester.tap(find.text('申请全部权限'));
      await tester.pumpAndSettle();

      expect(asked.expand((e) => e), containsAll(<Permission>[
        Permission.notification,
        Permission.microphone,
      ]), reason: '通知（后台提醒）与麦克风（守卫/取证）必须在开引擎前申请到');

      final methods = native.map((c) => c.method).toList();
      expect(methods, contains('isIgnoringBatteryOptimizations'),
          reason: '必须先问"是否已加白"，不问就无从判断要不要弹系统框');

      // ★ 这条正是此前长期零覆盖的分支（当时唯一路径把返回值桩成 true）：
      // 无条件弹 ⇒ 每次开引擎/开守卫都弹一次，用户只能反复点掉，
      // 而已加白的情况等于白弹一次（`permission_flow.dart:77-81` 的注释即此判断）。
      expect(methods, contains('requestIgnoreBatteryOptimizations'),
          reason: '未加白时必须真的请求加白，否则进程被系统冻结 ⇒ 保活失效');
    }, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets('PFL-05 保活引导 → 未知厂商走"通用步骤"，且三个按钮都要真的打到原生',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      _stubDeviceInfoMissing();
      final native = _installNative({
        'requestIgnoreBatteryOptimizations': null,
        'openExactAlarmSettings': null,
        'openOemAutostart': null,
      });

      await _pump(tester);
      await tester.tap(find.text('保活引导'));
      await tester.pumpAndSettle();

      // 宿主上 `DeviceInfoPlugin().androidInfo` 打不到实现 ⇒ `_detectVendor`
      // 的 `on Object` 兜底返回 'generic' ⇒ 走"通用步骤"分支。
      // 这不是为测试造的路径：桌面平台与"机型识别失败"走的就是它。
      expect(find.textContaining('后台保活设置'), findsOneWidget);
      expect(find.textContaining('通用步骤'), findsOneWidget,
          reason: '识别不出机型就必须给通用步骤 —— 给空白等于让用户自己猜');

      await tester.tap(find.text('申请电池白名单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('精确闹钟权限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('厂商自启动页'));
      await tester.pumpAndSettle();

      final methods = native.map((c) => c.method).toList();
      expect(methods, containsAll(<String>[
        'requestIgnoreBatteryOptimizations',
        'openExactAlarmSettings',
        'openOemAutostart',
      ]), reason: '三个按钮都必须真的打到原生 —— 只改界面等于摆设');

      // 打开的必须是**识别出来的**那个厂商页：写死一个品牌 ⇒
      // 小米用户被丢进三星的设置页，找不到开关也让用户以为"应用坏了"。
      final autostart = native.firstWhere((c) => c.method == 'openOemAutostart');
      expect((autostart.arguments as Map)['vendor'], 'generic',
          reason: 'vendor 必须来自识别结果，不能写死');
    }, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets('PFL-06 保活引导·识别出具体厂商 → 给该厂商的设置路径，而不是通用步骤',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      // 强制 Android 平台：`_detectVendor` 的机型分支只在 android 下走。
      // ⚠️ 必须在**用例体内**复位（不能只 `addTearDown`）—— 框架在用例体结束后、
      // tearDown 之前就会跑 `debugAssertAllFoundationVarsUnset`，晚一步即报
      // "The value of a foundation debug variable was changed by the test."
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        _stubDeviceInfoAndroid(manufacturer: 'Xiaomi');
        _installNative({'requestIgnoreBatteryOptimizations': null});

        await _pump(tester);
        await tester.tap(find.text('保活引导'));
        await tester.pumpAndSettle();

        // `vendor = manufacturer.toLowerCase()` ⇒ 'xiaomi' → 命中 _guides。
        expect(find.text('后台保活设置（XIAOMI）'), findsOneWidget,
            reason: '标题必须用识别出的厂商，否则用户不知道这是给他这台机的');
        expect(find.text('小米 / 红米 (MIUI·澎湃OS)'), findsOneWidget,
            reason: '识别出小米就该点名 MIUI/澎湃OS —— 这决定了用户能不能找到开关');
        expect(find.textContaining('省电策略 → 无限制'), findsOneWidget,
            reason: '必须给具体的设置路径，而不是笼统说"去关电池优化"');
        expect(find.textContaining('通用步骤'), findsNothing,
            reason: '识别成功却退回通用步骤 = 识别白做了（通用路径在 MIUI 上对不上）');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
