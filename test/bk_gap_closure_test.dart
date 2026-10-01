import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/permission_stub.dart';

/// 第六十一轮：**覆盖率冲刺（第四轮）** —— 只撬既有未覆盖分支，`lib/**` 一字未动。
///
/// ## 为什么这段必须单独一个文件
///
/// 本文件驱动的是 `RcEndpointService` 上**默认的**运行时权限闸门
/// （那个字段的初始化值指向生产实现，只在"调用方没有替换过它"时才被用到）。
/// 该字段是**进程内单例上的可变字段** —— 别的文件（`deep_endpoint_dispatch2_test.dart`
/// 等）为了让用例不碰真实插件，**每个用例都替换掉它**且**不还原**。
/// 于是"默认值那条路"只有在**一个从未替换过它的文件**里才走得到
/// （`flutter test` 每个文件独立 isolate ⇒ 单例是全新的）。
///
/// 这不是"为了覆盖率造假"：走的仍是生产实现本身，只是把它的两个外部依赖
/// （`permission_handler` 通道）按插件的**真实通道名/编解码**打桩，
/// 见 `support/permission_stub.dart` 的出处表。
///
/// ## 覆盖到的分支（`lib/remote/endpoint_service.dart`）
///
/// 生产实现按"权限状态 → 是否永久拒绝 → 主动申请 → 取申请结果"四步走：
/// 1. 状态已授予 ⇒ 直接放行（不再申请，避免多弹一次系统框）；
/// 2. 状态未授予 ⇒ 先申请；申请后仍未授予 ⇒ 返回否。
/// 第 2 条正是**用户最容易撞上、此前从未被执行**的那条。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late RemoteStore store;
  late PairedEndpoint peer;

  final svc = RcEndpointService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    db = await AppDatabase.open(inMemoryDatabasePath);
    svc.debugBind(store: store, db: db);
    // 只替换"系统定位服务开关"与"取一次位置"（两者都不是本文件要驱动的对象），
    // **刻意不碰权限闸门** —— 那正是被测的那一段。
    svc.locationServiceEnabled = () async => false;
    svc.locationFix = () async => throw StateError('本文件不应取到位置');
    peer = PairedEndpoint(
      deviceId: 'CTRL0001abcdef',
      name: '测试控制端',
      secret: 'CODE0001',
      pairedAt: DateTime(2024, 1, 1),
    );
  });

  RcMessage cmd(String type, [Map<String, dynamic> payload = const {}]) =>
      RcMessage.now(type, payload);

  Future<bool> hasLog(
      {String? action, String? status, String? contains}) async {
    final rows = await LogRepository(db).recent(limit: 200);
    return rows.any((r) {
      if (action != null && r['action'] != action) return false;
      if (status != null && r['status'] != status) return false;
      if (contains != null &&
          !((r['message'] as String? ?? '').contains(contains))) {
        return false;
      }
      return true;
    });
  }

  group('BK-A 定位闸门的**生产默认实现**（权限那一步）', () {
    test('权限已授予 ⇒ 直接放行，且不再多发一次申请', () async {
      final asked = stubPermissions(
          {Permission.locationWhenInUse: PermissionStatus.granted});
      addTearDown(clearPermissionStub);

      await svc.debugDispatch(cmd(RcCmd.locationGet), peer);

      expect(asked, isEmpty,
          reason: '已经授予还去申请一次 = 每次定位都多弹一次系统框（用户会以为有毛病）');
      // 闸门放行 ⇒ 才会走到"系统定位服务关着"这一条（本文件把它钉成 false）。
      expect(await hasLog(action: 'location', status: 'failed'), isTrue);
      expect(await hasLog(contains: '系统定位服务已关闭'), isTrue,
          reason: '过了权限闸门就该报"服务关着"，而不是笼统的"定位失败"');
    });

    test('权限未授予 ⇒ 主动申请；申请后仍未授予 ⇒ 如实判"权限被拒"', () async {
      // 保守侧：`statuses` 里没列的一律视为未授予（与真机"没点允许"等价）。
      final asked = stubPermissions(const {});
      addTearDown(clearPermissionStub);

      await svc.debugDispatch(cmd(RcCmd.locationGet), peer);

      expect(asked.single, [Permission.locationWhenInUse],
          reason: '未经授权必须真的向系统申请一次，不能替端点静默放弃');
      expect(await hasLog(action: 'location', status: 'failed'), isTrue);
      expect(await hasLog(contains: '定位权限未授予'), isTrue);
      expect(await hasLog(contains: '请点亮屏幕后在前台重试'), isTrue,
          reason: '权限被拒必须给可执行的前台引导（后台定位是政策红线，不做）');
    });
  });
}
