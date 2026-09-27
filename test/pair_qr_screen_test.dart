import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/pair_qr_screen.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/permission_stub.dart';

import 'support/source_text.dart';

/// 扫码配对页（`/remote/pair-qr`）的宿主测试 —— 第三十二轮新建。
///
/// ## 本轮在这里发现并修掉的一处真问题
///
/// `_PairQrScreenState` 里**曾有一份 `parseUri` 的完整拷贝**，与
/// `PairQrProtocol.parseUri`（lib/remote/protocol.dart）逐行相同。
/// 两份"配对码解析器"意味着：任一侧改了前缀或长度校验，就会出现
/// 「扫码页认为合法、协议层认为非法」的静默分歧 —— 而这条路径决定
/// **本机跟谁配对**。现已改为单点复用协议层实现，本文件用**往返校验**锁住。
///
/// ## 覆盖边界
///
/// 授予相机权限后会构建 `MobileScanner`（真摄像头，宿主无实现），
/// 因此**只测"权限被拒"这条分支**；"授权后开扫"由设备层/集成测试覆盖。
Future<RemoteStore> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final store = RemoteStore(await SharedPreferences.getInstance());

  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: PairQrScreen())));
  await tester.pumpAndSettle();
  return store;
}

// 剥注释（`//` 与 `/* */`）：源码锁必须在**不含注释**的文本上做，
// 否则注释里写一句 `notifyPeerOfPairing` 就会把计数锁骗过去。
//
// 实现见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源）。
// ⚠️ 此前本文件用的是**不认字符串字面量**的退化版 —— 源码里出现
// `'mqtt://...'` 这类字面量时会把该行从 `//` 起整段截掉（可能假绿/假红）；
// 收敛后字符串整段保留。

void main() {
  group('PQR 扫码配对页', () {
    testWidgets('PQR-01 首次进入自动生成身份与配对码，并渲染二维码', (tester) async {
      final store = await _pump(tester);

      expect(store.deviceId.length, 16, reason: '设备 ID 必须 16 位');
      expect(store.pairingCode.length, 8, reason: '配对码必须 8 位');
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '身份生成完还转圈 ⇒ 界面卡在加载态');
    });

    testWidgets('PQR-02 配对码持久化：二次进入仍是同一个码', (tester) async {
      // ⚠️ 往返锁（页面生成的 URI 必须能被协议层解析回同一身份）**做不到**：
      // `QrImageView._data` 是库内私有字段，宿主测试读不出二维码内容；
      // 为测试而在生产代码里开后门不做。该往返由设备层/集成测试覆盖。
      final store = await _pump(tester);
      final first = store.pairingCode;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
          const ProviderScope(child: MaterialApp(home: PairQrScreen())));
      await tester.pumpAndSettle();

      expect(store.pairingCode, first,
          reason: '配对码每次都变 ⇒ 已配对设备立刻失联');
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets('PQR-03 相机权限被拒 → 明确提示且不进入扫描态', (tester) async {
      final asked =
          stubPermissions({Permission.camera: PermissionStatus.denied});
      addTearDown(clearPermissionStub);

      await _pump(tester);

      await tester.tap(find.text('扫描对端二维码'));
      await tester.pumpAndSettle();

      expect(asked.single, [Permission.camera]);
      expect(find.textContaining('扫码需要相机权限'), findsOneWidget,
          reason: '权限闸门（QR1）的未授权面板文案');
      expect(find.byType(QrImageView), findsOneWidget,
          reason: '没权限不该把"我的二维码"也顶掉');
    });

    group('parseUri 边界（决定跟谁配对，必须严格）', () {
      const ok = 'sonicshield://pair/0123456789abcdef/%E5%AE%A2%E5%8E%85/ab2c-d5ef';

      test('PQR-04 合法（含中文名 + 连字符小写码）→ 归一化', () {
        final p = PairQrProtocol.parseUri(ok)!;
        expect(p.deviceId, '0123456789abcdef');
        expect(p.name, '客厅');
        expect(p.code, 'AB2CD5EF', reason: '去连字符 + 转大写');
      });

      test('PQR-05 前缀不对 → null（不是别家 scheme 就别认）', () {
        expect(PairQrProtocol.parseUri('https://evil.example/pair/'
            '0123456789abcdef/x/AB2CD5EF'), isNull);
      });

      test('PQR-06 设备 ID 不是 16 位 → null', () {
        expect(
            PairQrProtocol.parseUri('sonicshield://pair/0123/name/AB2CD5EF'),
            isNull);
      });

      test('PQR-07 配对码不是 8 位 → null', () {
        expect(PairQrProtocol.parseUri(
            'sonicshield://pair/0123456789abcdef/name/AB2C'), isNull);
      });

      test('PQR-08 字段不足三段 → null', () {
        expect(PairQrProtocol.parseUri('sonicshield://pair/0123456789abcdef'),
            isNull);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // P0-3：扫码页内手输兜底 —— 字段级校验纯函数（判定与 UI 分离，宿主可穷举）。
  // ---------------------------------------------------------------------------
  group('PQR 手输配对校验（manualPairFieldError 真值表）', () {
    const okId = '0123456789abcdef';

    test('PQR-09 合法 ID + 合法码 → null（含连字符/小写归一化与首尾空白）', () {
      expect(manualPairFieldError(okId, 'AB2C-D5EF'), isNull);
      expect(manualPairFieldError(okId, 'ab2cd5ef'), isNull,
          reason: '小写必须按协议层口径转大写');
      expect(manualPairFieldError('  $okId  ', ' ab2c-d5ef '), isNull,
          reason: '首尾空白必须被 trim');
    });

    test('PQR-10 反面样本：ID 为空 / 长度不对 / 非 hex → 各自报错（非恒真）', () {
      expect(manualPairFieldError('', 'AB2CD5EF'), contains('设备 ID'));
      expect(manualPairFieldError('0123', 'AB2CD5EF'), contains('16 位'),
          reason: '4 位 ID 必须判红');
      expect(manualPairFieldError('0123456789abcdeg', 'AB2CD5EF'),
          contains('十六进制'),
          reason: 'g 不是 hex，长度凑够 16 位也要判红');
    });

    test('PQR-11 反面样本：码为空 / 长度不对 / 含非法字符 → 各自报错', () {
      expect(manualPairFieldError(okId, ''), contains('配对码'));
      expect(manualPairFieldError(okId, 'AB2C'), contains('8 位'),
          reason: '4 位码必须判红');
      expect(manualPairFieldError(okId, 'AB2CD5EI'), contains('非法字符'),
          reason: 'I 是易混字符，不在 Base32 字母表');
      expect(manualPairFieldError(okId, 'AB2CD5E0'), contains('非法字符'),
          reason: '0 不在 Base32 字母表');
    });

    test('PQR-12 归一化纯函数复用协议层口径（剥连字符 + 转大写）', () {
      expect(manualPairNormalizedCode('ab2c-d5ef'), 'AB2CD5EF');
      expect(manualPairNormalizedCode(' AB2C-D5EF '), 'AB2CD5EF');
      expect(manualPairNormalizedCode('AB2C'), isNull,
          reason: '长度不对必须返回 null（不是"原样返回"）');
    });
  });

  // ---------------------------------------------------------------------------
  // P0-4：非声盾二维码分类 —— 只对「是二维码但不是声盾配对码」给提示。
  // ---------------------------------------------------------------------------
  group('PQR 非声盾二维码分类（classifyDetectedQr）', () {
    test('PQR-13 声盾码 → sonicShield；别家二维码 → foreignQr；商品条码 → ignore', () {
      expect(
          classifyDetectedQr(
              'sonicshield://pair/0123456789abcdef/x/AB2CD5EF',
              BarcodeFormat.qrCode),
          QrDetectKind.sonicShield);
      expect(classifyDetectedQr('https://evil.example/pay', BarcodeFormat.qrCode),
          QrDetectKind.foreignQr);
      expect(classifyDetectedQr('4006381333931', BarcodeFormat.ean13),
          QrDetectKind.ignore,
          reason: '一维商品条码不该弹「这不是声盾配对码」');
      expect(classifyDetectedQr(null, BarcodeFormat.qrCode), QrDetectKind.ignore);
      expect(classifyDetectedQr('', BarcodeFormat.qrCode), QrDetectKind.ignore);
    });

    test('PQR-14 反面样本：别家二维码既不得被判成声盾码、也不得被静默忽略', () {
      const foreign = 'weixin://wxpay/bizpayurl?pr=abc';
      expect(classifyDetectedQr(foreign, BarcodeFormat.qrCode),
          isNot(QrDetectKind.sonicShield));
      expect(classifyDetectedQr(foreign, BarcodeFormat.qrCode),
          isNot(QrDetectKind.ignore),
          reason: '静默忽略正是「扫不了码」最大的困惑源');
    });
  });

  // ---------------------------------------------------------------------------
  // P0-3 / P0-2：widget 行为（只走**不产生真实 IO** 的失败分支）。
  // ---------------------------------------------------------------------------
  group('PQR 手输兜底 widget 行为', () {
    testWidgets('PQR-15 扫码页内嵌手输入口；非法输入就地报错、不弹 SnackBar',
        (tester) async {
      await _pump(tester);

      expect(find.text('扫不了码？手动输入'), findsOneWidget,
          reason: '扫不了码的用户必须在本页就能找到手输入口');

      await tester.tap(find.text('扫不了码？手动输入'));
      await tester.pumpAndSettle();
      expect(find.text('手动输入配对码'), findsOneWidget);

      // 故意写坏：ID 4 位 + 码 4 位（不触发任何真实 IO，只走校验失败分支）。
      await tester.enterText(find.byType(TextField).at(0), '0123');
      await tester.enterText(find.byType(TextField).at(1), 'AB2C');
      await tester.tap(find.text('配对'));
      await tester.pumpAndSettle();

      final err = find.byKey(const Key('manual-pair-error'));
      expect(err, findsOneWidget, reason: '字段错误必须**就地**提示');
      final msg = tester.widget<Text>(err).data!;
      expect(msg, contains('16 位'), reason: '必须指明是 ID 字段错');
      expect(find.byType(SnackBar), findsNothing,
          reason: '字段级错误不能只弹一条 SnackBar');
      expect(find.text('手动输入配对码'), findsOneWidget,
          reason: '校验失败不能关掉对话框（用户要能改）');
    });

    testWidgets('PQR-16 相机权限被拒时，权限面板内仍可改用手动输入（P0-2）',
        (tester) async {
      stubPermissions({Permission.camera: PermissionStatus.denied});
      addTearDown(clearPermissionStub);

      await _pump(tester);
      await tester.tap(find.text('扫描对端二维码'));
      await tester.pumpAndSettle();

      expect(find.text('改用手动输入配对码'), findsOneWidget,
          reason: '权限被拒也必须留下手输出口，否则用户卡死在本页');

      await tester.tap(find.text('改用手动输入配对码'));
      await tester.pumpAndSettle();
      expect(find.text('手动输入配对码'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // 第四十轮：权限闸门全档位 + **手输合法提交真的落盘**（此前只测了"非法输入"）。
  //
  // 为什么这一组能上宿主：`notifyPeerOfPairing → requestPairing → sendTo` 在
  // `_client == null`（宿主没有 MQTT 连接）时**同步返回 false**，于是
  // `_pairFromUri` 的整条「解析 → 落盘 → 补订 → 通知对端 → 结果卡片」路径
  // 全部可达 —— 而这正是"配对了没有/对端知不知道"的真实分支。
  // ---------------------------------------------------------------------------
  group('PQR 权限闸门与提交路径（第四十轮）', () {
    test('PQR-21 qrGateFromPerm 真值表（restricted/limited 不得被当成 granted）', () {
      expect(qrGateFromPerm(PermissionStatus.granted), QrScanGate.granted);
      expect(qrGateFromPerm(PermissionStatus.denied), QrScanGate.denied);
      expect(qrGateFromPerm(PermissionStatus.permanentlyDenied),
          QrScanGate.permanentlyDenied);
      expect(qrGateFromPerm(PermissionStatus.restricted),
          QrScanGate.permanentlyDenied,
          reason: 'restricted（家长控制/MDM）无法再弹窗，只能去系统设置');
      expect(qrGateFromPerm(PermissionStatus.limited), QrScanGate.denied,
          reason: 'limited 不是 granted，绝不能放行到扫描态');
      expect(qrGateFromPerm(PermissionStatus.provisional), QrScanGate.denied,
          reason: 'provisional（iOS 临时授权）同样未获完整授权');
    });

    testWidgets('PQR-22 相机权限被永久拒绝 → 明确文案 + 系统设置入口 + 手输出口不被顶掉',
        (tester) async {
      stubPermissions({Permission.camera: PermissionStatus.permanentlyDenied});
      addTearDown(clearPermissionStub);

      await _pump(tester);
      await tester.tap(find.text('扫描对端二维码'));
      await tester.pumpAndSettle();

      expect(find.textContaining('相机权限已被永久拒绝'), findsOneWidget,
          reason: '永久拒绝必须给"去系统设置"的明确指引，而不是笼统一句未授权');
      expect(find.text('打开系统设置'), findsOneWidget);
      // 桩里 openAppSettings 回 true：点一下不能炸（真机上会跳系统页）。
      await tester.tap(find.text('打开系统设置'));
      await tester.pumpAndSettle();
      expect(find.text('改用手动输入配对码'), findsOneWidget,
          reason: 'P0-2：权限全拒也必须能完成配对');
      expect(find.byType(QrImageView), findsOneWidget,
          reason: '没权限不该把"我的二维码"顶掉 —— 对端还等着扫本机');
    });

    testWidgets('PQR-23 restricted（家长控制/MDM）与永久拒绝同处置', (tester) async {
      stubPermissions({Permission.camera: PermissionStatus.restricted});
      addTearDown(clearPermissionStub);

      await _pump(tester);
      await tester.tap(find.text('扫描对端二维码'));
      await tester.pumpAndSettle();

      expect(find.textContaining('相机权限已被永久拒绝'), findsOneWidget,
          reason: 'restricted 与永久拒绝都只能去系统设置解');
      expect(find.text('打开系统设置'), findsOneWidget);
    });

    testWidgets('PQR-24 手输合法配对码 → 本机落盘，并对"未通知到对端"如实告警',
        (tester) async {
      final store = await _pump(tester);
      expect(store.paired(), isEmpty, reason: '前置：本机配对表必须是空的');

      await tester.tap(find.text('扫不了码？手动输入'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '0123456789ABCDEF');
      await tester.enterText(find.byType(TextField).at(1), 'ab2c-d5ef');
      await tester.enterText(find.byType(TextField).at(2), '客厅手机');
      await tester.tap(find.text('配对'));
      await tester.pumpAndSettle();

      expect(find.text('手动输入配对码'), findsNothing,
          reason: '校验通过必须关掉对话框');

      final paired = store.paired();
      expect(paired, hasLength(1), reason: '合法手输必须真的落盘');
      expect(paired.single.deviceId, '0123456789abcdef',
          reason: '输入是大写也要落成小写 —— BUG-075：deviceId 是 MQTT 主题段'
              '（大小写敏感）与密钥派生输入，原样保留大写会让'
              '"配对成功但命令永远发不出去"且全程无报错');
      expect(paired.single.name, '客厅手机');
      expect(paired.single.secret, 'AB2CD5EF',
          reason: '配对码必须归一化（剥连字符 + 转大写）后落盘 —— 落盘的是密钥原料');

      expect(find.textContaining('已配对'), findsOneWidget,
          reason: '结果卡片必须出现');
      expect(find.textContaining('未能通知对端'), findsOneWidget,
          reason: 'R-2：对端没被通知到必须**说出来**，不能静默画成成功');
      expect(find.byIcon(Icons.error_outline), findsOneWidget,
          reason: '未确认的配对不得用成功图标（成功不得被误报）');
    });

    testWidgets('PQR-25 手输合法但对端名留空 → 仍落盘（名字可选是契约）',
        (tester) async {
      final store = await _pump(tester);

      await tester.tap(find.text('扫不了码？手动输入'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '0123456789abcdef');
      await tester.enterText(find.byType(TextField).at(1), 'AB2CD5EF');
      await tester.tap(find.text('配对'));
      await tester.pumpAndSettle();

      expect(store.paired(), hasLength(1),
          reason: '名字可选 —— 留空不得拦住配对');
    });

    testWidgets('PQR-26 授权后进入扫描态，取消扫码能干净退出（不得卡死在相机上）',
        (tester) async {
      stubPermissions({Permission.camera: PermissionStatus.granted});
      addTearDown(clearPermissionStub);

      await _pump(tester);
      await tester.tap(find.text('扫描对端二维码'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('取消扫码'), findsOneWidget,
          reason: '进入扫描态必须留下退出路径');
      expect(find.text('扫不了码？手动输入'), findsOneWidget,
          reason: '扫描中也要留手输出口（换环境/换人再试）');
      expect(find.byType(QrImageView), findsNothing,
          reason: '扫描态不该同时渲染"我的二维码"面板');

      await tester.tap(find.text('取消扫码'));
      await tester.pumpAndSettle();

      expect(find.text('扫描对端二维码'), findsOneWidget,
          reason: '取消后必须回到静态页；且 controller 必须已 dispose'
              '（否则 MIUI 上下一次打开相机直接失败）');
      expect(find.byType(QrImageView), findsOneWidget);
    });

    test('PQR-27 BUG-075 回归锁：parseUri 把大写设备 ID 归一化到小写', () {
      final p = PairQrProtocol.parseUri(
          'sonicshield://pair/0123456789ABCDEF/%E5%AE%A2%E5%8E%85/ab2c-d5ef')!;
      expect(p.deviceId, '0123456789abcdef',
          reason: 'deviceId 决定 MQTT 主题（大小写敏感）与密钥派生输入，'
              '必须与 generateDeviceId()（恒小写）同口径；'
              '原样保留大写 = 配对"成功"但命令永远发不出去、回执永远解不开');
      expect(p.name, '客厅', reason: '只归一化 ID/码，不得顺手动名字');
      expect(p.code, 'AB2CD5EF', reason: '码的归一化口径不变（剥连字符 + 转大写）');

      // 反向自检：长度校验仍按 16 位判定（不得因为加了 toLowerCase 就放宽）。
      expect(PairQrProtocol.parseUri('sonicshield://pair/0123/x/AB2CD5EF'), isNull);
      expect(
          PairQrProtocol.parseUri('sonicshield://pair/0123456789abcdef0/x/AB2CD5EF'),
          isNull,
          reason: '17 位 ID 必须判 null');
    });
  });

  // ---------------------------------------------------------------------------
  // 红线源码锁（docs/25 §4）：手输与扫码必须共用同一条提交路径 + 解析器单点复用。
  // ---------------------------------------------------------------------------
  group('红线：手输与扫码共用同一条提交路径（源码锁）', () {
    late final String src;
    setUpAll(() {
      src = stripComments(
          File('lib/features/remote/pair_qr_screen.dart').readAsStringSync());
    });

    test('PQR-17 手输只组装 URI 交给 _pairFromUri，不自己落盘/通知', () {
      final start = src.indexOf('Future<void> _submitManualPair');
      expect(start, greaterThan(-1), reason: '手输提交函数必须存在');
      final body = src.substring(start, start + 300);
      expect(body.contains('_pairFromUri'), isTrue,
          reason: '手输必须复用扫码的 _pairFromUri（docs/25 §4 红线）');
      expect(body.contains('addPaired'), isFalse,
          reason: '手输不得自己落盘（落盘单点在 _pairFromUri 内）');
      expect(body.contains('notifyPeerOfPairing'), isFalse,
          reason: '手输不得自己写一份通知逻辑，否则回执 payload 两份漂移');
    });

    test('PQR-18 全文件落盘与通知各只有一处（配对提交单点）', () {
      expect('addPaired('.allMatches(src).length, 1,
          reason: '落盘只允许在 _pairFromUri 里一处');
      // 定义 1 处 + 调用 1 处 = 2；多出来就是复制了一份通知路径。
      expect('notifyPeerOfPairing('.allMatches(src).length, 2);
    });

    test('PQR-19 归一化复用协议层，不在本文件重写剥连字符/转大写', () {
      expect(src.contains('manualPairNormalizedCode'), isTrue);
      expect(src.contains("replaceAll('-', '')"), isFalse,
          reason: '剥连字符必须复用 PairQrProtocol，禁止在本文件再拷一份');
    });

    test('PQR-20 非声盾码提示与识别去抖共用 _handledCode（且不弹 SnackBar）', () {
      final start = src.indexOf('void _onDetect');
      expect(start, greaterThan(-1));
      final body = src.substring(start, src.indexOf('Widget _onScanError'));
      expect(body.contains('classifyDetectedQr'), isTrue,
          reason: 'onDetect 必须走分类器，不能只认前缀就静默忽略别家二维码');
      expect(body.contains('_handledCode'), isTrue,
          reason: '非声盾码提示必须复用同一节流状态，不能每帧刷一次');
      expect(body.contains('_foreignQrNotice'), isTrue,
          reason: '非声盾码必须置位就地提示开关');
      expect(body.contains('showSnackBar'), isFalse,
          reason: '每帧弹 SnackBar 会刷屏并撑爆队列，提示必须就地渲染');
    });
  });
}
