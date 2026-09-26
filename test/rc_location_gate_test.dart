// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';

/// **定位获取闸门锁**（第三十四轮，C-1 P0 + P1 撤销清场）。
///
/// ## 缺陷形状（C-1，实测）
///
/// `location.get` 这条命令**全链路都在**：协议常量、控制台按钮、回执事件
/// `rc.location`、控制器渲染分支、docs/14 的说明。唯独
/// `android/app/src/main/AndroidManifest.xml` 里**没有**声明
/// `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION`。
///
/// 于是 `Geolocator.getCurrentPosition` 必抛 `PermissionDeniedException`，
/// 这条命令**恒失败** —— 而且失败得很难看：端点上只有一句笼统的"定位失败"，
/// 使用者根本分不清是"没授权 / GPS 关着 / 取不到位置"。
///
/// 这正是项目最忌讳的形状：**看起来能用、结构上却不可能工作**，
/// 而且没有任何报错把它顶出来（只有真机点一次才知道）。
///
/// ## 本锁锁什么
///
/// | 组 | 不变量 |
/// |---|---|
/// | GATE  | 三步闸门的三条失败分支**各自可独立触发**，且指引文案**互不相同** |
/// | ORDER | 顺序是**权限 → 服务 → 取位置**；前面的步骤不通过时，后面的**一次都不许调** |
/// | WIRE  | 服务真的用闸门（存在 `acquireLocationOnce` 调用），而不是又写回内联逻辑 |
/// | PERM  | 清单**声明**了两个定位权限，且代码里确实有**运行时申请**（缺任一半都是 C-1 形状） |
/// | IOS   | `Info.plist` 具备相机/定位用途说明（iOS 缺键=**崩溃**，不是拒绝） |
///
/// ⚠️ **边界**：闸门是纯流程，故可穷举；但"真机上权限弹窗是否出现、证书链是否
/// 生效"本锁**证明不了** —— 那需要真机取证。本锁只保证"结构上不再恒失败"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final endpointSrc =
      File('lib/remote/endpoint_service.dart').readAsStringSync();
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final plist = File('ios/Runner/Info.plist').readAsStringSync();

  Position pos(double lat, double lng, {double acc = 5}) => Position(
        latitude: lat,
        longitude: lng,
        timestamp: DateTime(2026, 9, 24),
        accuracy: acc,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

  /// 剥掉 XML 注释后再断言 —— 与 `rc_transport_lock_test.dart` 的
  /// `stripComments` 同一理由（且是被真实红牌教出来的）：
  ///
  /// 本项目刻意在清单/plist 的注释里**写明**"为什么不加
  /// `ACCESS_BACKGROUND_LOCATION`"。不做剥离的话，`contains()` 会把这段
  /// **说明文字**当成"权限已声明"，于是 LG-13 直接把作者的正确注释判成违规。
  /// 这类假红最坏的后果不是浪费时间，而是逼下一个人**删掉最有价值的注释**。
  String stripXmlComments(String s) =>
      s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  final manifestCode = stripXmlComments(manifest);

  // ══════════════════════════════════════════════════ GATE · 三条失败分支
  group('LG-GATE 三步闸门的失败分支', () {
    test('LG-01 权限被拒 → permissionDenied，且**不碰**系统服务与取位置', () async {
      var serviceCalls = 0;
      var fixCalls = 0;
      final r = await acquireLocationOnce(
        permissionGate: () async => false,
        serviceEnabled: () async {
          serviceCalls++;
          return true;
        },
        fix: () async {
          fixCalls++;
          return pos(1, 2);
        },
      );

      expect(r.ok, isFalse);
      expect(r.position, isNull);
      expect(r.failure, RcLocationFailure.permissionDenied);
      expect(serviceCalls, 0, reason: '权限都没拿到，问 GPS 开关毫无意义');
      expect(fixCalls, 0,
          reason: '★ 核心不变量：没授权就**绝不允许**调用取位置 '
              '（否则真机上平台插件会抛，掩盖真正原因）');
      expect(r.detail, contains('权限未授予'));
    });

    test('LG-02 权限已给但系统定位服务关闭 → serviceDisabled，且**不取位置**', () async {
      var fixCalls = 0;
      final r = await acquireLocationOnce(
        permissionGate: () async => true,
        serviceEnabled: () async => false,
        fix: () async {
          fixCalls++;
          return pos(1, 2);
        },
      );

      expect(r.failure, RcLocationFailure.serviceDisabled);
      expect(fixCalls, 0, reason: 'GPS 关着时取位置必失败，不该白调一次');
      expect(r.detail, contains('定位服务已关闭'));
    });

    test('LG-03 取位置本身抛异常 → fixFailed（不冒泡、不含糊）', () async {
      final r = await acquireLocationOnce(
        permissionGate: () async => true,
        serviceEnabled: () async => true,
        fix: () async => throw StateError('timeout'),
      );

      expect(r.ok, isFalse);
      expect(r.failure, RcLocationFailure.fixFailed);
      expect(r.detail, contains('timeout'),
          reason: '原始异常信息必须留痕 —— 否则又一次"不知道为什么不成功"');
    });

    test('LG-04 全通过 → 返回坐标本体（不是包装/近似值）', () async {
      final r = await acquireLocationOnce(
        permissionGate: () async => true,
        serviceEnabled: () async => true,
        fix: () async => pos(31.2304, 121.4737, acc: 12.5),
      );

      expect(r.ok, isTrue);
      expect(r.position!.latitude, 31.2304);
      expect(r.position!.longitude, 121.4737);
      expect(r.position!.accuracy, 12.5);
      expect(r.failure, isNull);
      expect(r.detail, isEmpty, reason: '成功路径不该带失败文案');
    });

    test('LG-05 三种失败的**指引互不相同**（合并成一句就是新的静默失败）', () async {
      final denied = await acquireLocationOnce(
        permissionGate: () async => false,
        serviceEnabled: () async => true,
        fix: () async => pos(1, 2),
      );
      final off = await acquireLocationOnce(
        permissionGate: () async => true,
        serviceEnabled: () async => false,
        fix: () async => pos(1, 2),
      );
      final broke = await acquireLocationOnce(
        permissionGate: () async => true,
        serviceEnabled: () async => true,
        fix: () async => throw StateError('x'),
      );

      final details = {denied.detail, off.detail, broke.detail};
      expect(details.length, 3,
          reason: '三种原因 → 三句不同的指引。都写"定位失败"等于没说');
      // 权限被拒的指引必须指向"授权"，而不是"开 GPS"。
      expect(denied.detail.contains('权限'), isTrue);
      expect(denied.detail.contains('设置中开启定位'), isFalse,
          reason: '权限被拒时把用户引去开 GPS 是**误导**：开了还是不行');
      expect(off.detail.contains('设置'), isTrue);
    });

    test('LG-06 权限申请抛异常也走 fixFailed（不会漏出到 MQTT 回调）', () async {
      final r = await acquireLocationOnce(
        permissionGate: () async => throw StateError('plugin missing'),
        serviceEnabled: () async => true,
        fix: () async => pos(1, 2),
      );
      expect(r.ok, isFalse);
      expect(r.failure, RcLocationFailure.fixFailed,
          reason: '任何一环抛异常都要被闸门兜住并变成可展示的原因');
    });
  });

  // ══════════════════════════════════════════════════ ORDER · 顺序是语义
  group('LG-ORDER 顺序（变异证伪：调换即语义错误）', () {
    test('LG-07 调用序列恰好是 permission → service → fix', () async {
      final log = <String>[];
      await acquireLocationOnce(
        permissionGate: () async {
          log.add('perm');
          return true;
        },
        serviceEnabled: () async {
          log.add('svc');
          return true;
        },
        fix: () async {
          log.add('fix');
          return pos(1, 2);
        },
      );
      expect(log, ['perm', 'svc', 'fix']);
    });

    test('LG-08 权限被拒时序列**只有** perm（early-return 真的 return 了）', () async {
      final log = <String>[];
      await acquireLocationOnce(
        permissionGate: () async {
          log.add('perm');
          return false;
        },
        serviceEnabled: () async {
          log.add('svc');
          return true;
        },
        fix: () async {
          log.add('fix');
          return pos(1, 2);
        },
      );
      expect(log, ['perm']);
    });

    test('LG-09 服务关闭时序列恰为 perm → svc', () async {
      final log = <String>[];
      await acquireLocationOnce(
        permissionGate: () async {
          log.add('perm');
          return true;
        },
        serviceEnabled: () async {
          log.add('svc');
          return false;
        },
        fix: () async {
          log.add('fix');
          return pos(1, 2);
        },
      );
      expect(log, ['perm', 'svc']);
    });
  });

  // ══════════════════════════════════════════════════ PERM · 声明 + 申请
  group('LG-PERM 清单声明与运行时申请（缺任一半 = C-1 形状）', () {
    test('LG-10 清单声明了 COARSE + FINE 定位权限', () {
      expect(
          manifestCode.contains('android.permission.ACCESS_COARSE_LOCATION'),
          isTrue,
          reason: '只给 FINE 在部分 ROM 上会被当成拒绝（用户可能只给模糊）');
      expect(manifestCode.contains('android.permission.ACCESS_FINE_LOCATION'),
          isTrue);
    });

    test('LG-11 代码里有**运行时**申请（不是只声明不申请）', () {
      expect(endpointSrc.contains('Permission.locationWhenInUse'), isTrue);
      expect(RegExp(r'Permission\.locationWhenInUse\.request\(\)')
          .hasMatch(endpointSrc), isTrue,
          reason: '声明了权限却从不 request = 仍然拿不到（另一半个 C-1）');
    });

    test('LG-12 永久拒绝时**不再**重复弹框（避免掩盖真实状态）', () {
      expect(
          RegExp(r'isPermanentlyDenied[\s\S]{0,120}?return false')
              .hasMatch(endpointSrc),
          isTrue,
          reason: 'isPermanentlyDenied 下再 request 只会立刻返回 denied，'
              '把它当"用户又拒绝了"是错误归因');
    });

    test('LG-13 未声明 ACCESS_BACKGROUND_LOCATION（本轮是**刻意**不加）', () {
      expect(manifestCode.contains('ACCESS_BACKGROUND_LOCATION'), isFalse,
          reason: '加进来属于独立决策：必须同步 FGS 类型位、Play「始终允许」'
              '政策流程与 docs/22 C-1b 的记录。若确需支持后台定位，'
              '请连同上述三项一起改，并把本锁改成"存在即要求 FGS location 类型位"。');
    });

    test('LG-14 前台服务**没有**声明 location 类型（与上一条一致）', () {
      expect(
          RegExp(r'foregroundServiceType="[^"]*location')
              .hasMatch(manifestCode),
          isFalse,
          reason: 'FGS 类型位与权限是一对：偷偷加类型位而不加权限（或反之）'
              '会在 Android 14+ 直接 SecurityException');
    });
  });

  // ══════════════════════════════════════════════════ WIRE · 服务真的用了闸门
  group('LG-WIRE 接线锁（源码契约）', () {
    test('LG-15 `_sendLocation` 调用 `acquireLocationOnce` 并传入三个 seam', () {
      final i = endpointSrc.indexOf('Future<void> _sendLocation(');
      expect(i, greaterThan(0));
      // 从签名起截一段足够长的正文（该方法是"记账 + 回执"胶水，约 40 行）。
      final body = endpointSrc.substring(i, i + 2600);
      expect(body.contains('acquireLocationOnce('), isTrue,
          reason: '闸门抽出来了却不用 = 假修复');
      expect(body.contains('permissionGate: locationPermissionGate'), isTrue);
      expect(body.contains('serviceEnabled: locationServiceEnabled'), isTrue);
      expect(body.contains('fix: locationFix'), isTrue);
    });

    test('LG-16 失败回执**只有一个**出口形状（lat/lng 为 null + error:true）', () {
      final i = endpointSrc.indexOf('Future<void> _sendLocation(');
      final body = endpointSrc.substring(i, i + 2600);
      // 失败分支必须带 error:true 且坐标为空 —— 控制器靠这个区分成败。
      expect(RegExp(r"'lat':\s*null").hasMatch(body), isTrue);
      expect(body.contains("'error': true"), isTrue);
      // 成功分支必须带真实坐标字段。
      expect(body.contains("'lat': pos.latitude"), isTrue);
      expect(body.contains("'lng': pos.longitude"), isTrue);
    });

    test('LG-17 三个 seam 的默认实现存在且在源码里可替换（宿主测试的注入点）', () {
      for (final seam in [
        'locationPermissionGate',
        'locationServiceEnabled',
        'locationFix',
      ]) {
        // 必须是**字段声明**（`Future<...> Function() seam = ...`），
        // 否则宿主测试没法替换它 —— 那闸门就只能靠真机验证。
        final decl = RegExp('Function\\(\\)\\s+$seam\\s*=')
            .hasMatch(endpointSrc);
        final declTyped = RegExp('$seam\\s*=\\s*_system|$seam\\s*=\\s*Geolocator')
            .hasMatch(endpointSrc);
        expect(decl || declTyped, isTrue,
            reason: '$seam 必须是可替换字段（带默认实现），而不是写死的调用');
      }
      expect(endpointSrc.contains('_systemLocationPermission'), isTrue);
      expect(endpointSrc.contains('_systemLocationFix'), isTrue);
    });
  });

  // ══════════════════════════════════════════════════ IOS · 用途说明
  group('LG-IOS 平台差异（缺键=崩溃，不是拒绝）', () {
    test('LG-18 Info.plist 具备相机与定位用途说明', () {
      final code = stripXmlComments(plist);
      expect(code.contains('NSCameraUsageDescription'), isTrue);
      expect(code.contains('NSLocationWhenInUseUsageDescription'), isTrue);
      expect(code.contains('NSMicrophoneUsageDescription'), isTrue,
          reason: '原有键不能被本次编辑碰掉');
    });

    test('LG-19 两个新键都是合法的 key/string 对（XML 结构没被写坏）', () {
      final code = stripXmlComments(plist);
      for (final k in const [
        'NSCameraUsageDescription',
        'NSLocationWhenInUseUsageDescription',
      ]) {
        final pattern = RegExp(
            '<key>$k</key>\\s*<string>[^<]+</string>');
        expect(pattern.hasMatch(code), isTrue,
            reason: '$k 必须是 <key>X</key><string>非空说明</string> 的成对形态');
      }
    });
  });
}
