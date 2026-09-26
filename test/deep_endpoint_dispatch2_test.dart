import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

/// 第 36 轮续六：`RcEndpointService._dispatch` **剩余 20 条分支**的宿主驱动。
///
/// 与 `deep_endpoint_dispatch_test.dart` 同一手法（`debugBind` + `debugDispatch`
/// 接缝直接喂入站消息），本文件补齐上一轮**没驱动到**的分支。
///
/// ## 宿主可观测性判据（写用例前必须知道，否则会写出假断言）
/// 1. 无 broker 时 `_send` / `_ack` 是**安全 no-op**：走 `_auditSendDrop`，
///    在 `exec_logs` 留 `status='skipped'`、`message` 含「出站消息未发出」。
///    ⇒ 对"只回执不落库"的分支，这条 drop 审计**就是**"分支确实走到了"的证据。
/// 2. 有副作用的分支（任务落库 / 配对登记）直接断言**库的真实状态**。
/// 3. 平台相关分支（定位）用服务上的 seam 字段替换，不碰真实插件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late RemoteStore store;
  late PairedEndpoint peer;

  Future<void> bind() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    db = await AppDatabase.open(inMemoryDatabasePath);
    RcEndpointService.instance.debugBind(store: store, db: db);
  }

  setUp(() async {
    await bind();
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

  /// 无 broker 时"命令已被分发、处理器走到了回执"的**唯一**宿主信号。
  Future<bool> dropped() => hasLog(status: 'skipped', contains: '出站消息未发出');

  Future<void> seedTask(String id, {bool enabled = true}) async {
    final now = DateTime(2024, 1, 1);
    await TaskRepository(db).upsert(Task(
      id: id,
      name: 't$id',
      enabled: enabled,
      triggerType: TriggerType.dailyAt,
      trigger: const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)),
      actionType: ActionType.notify,
      action: const NotifyAction(title: 'T', body: 'B'),
      assetIds: const [],
      cooldownSec: 300,
      quietPolicy: QuietPolicy.skip,
      priority: 0,
      createdAt: now,
      updatedAt: now,
    ));
  }

  Map<String, dynamic> wireTask(String id,
      {int hour = 12, int minute = 30}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'id': id,
      'name': '远程任务 $id',
      'enabled': true,
      'triggerType': TriggerType.dailyAt.name,
      'trigger': {
        'kind': 'dailyAt',
        'time': {'hour': hour, 'minute': minute},
      },
      'actionType': ActionType.notify.name,
      'action': {'kind': 'notify', 'title': 'T$id', 'body': 'B$id'},
      'assetIds': <String>[],
      'cooldownSec': 300,
      'quietPolicy': QuietPolicy.skip.name,
      'priority': 0,
      'createdAt': now,
      'updatedAt': now,
    };
  }

  Map<String, dynamic> scriptPayload(String id,
      {List<Map<String, dynamic>>? steps}) => {
        'scriptId': id,
        'name': '远程宏',
        'fromName': '控制器',
        'sentAt': DateTime.now().millisecondsSinceEpoch,
        'steps': steps ??
            [
              {'kind': 'tts', 'text': '你好'},
            ],
      };

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

  final svc = RcEndpointService.instance;

  group('ED2-01 ping / status.get（纯回执分支）', () {
    test('ping → 走到 _send（宿主留 drop 审计）', () async {
      await svc.debugDispatch(cmd(RcCmd.ping), peer);
      expect(await dropped(), isTrue);
    });

    test('status.get → 走到 _send（含 pendingCount 查询）', () async {
      await svc.debugDispatch(cmd(RcCmd.statusGet), peer);
      expect(await dropped(), isTrue);
    });
  });

  group('ED2-02 task.list / task.get', () {
    test('task.list 轻量形状（默认）→ 走到 _send', () async {
      await seedTask('tl1');
      await svc.debugDispatch(cmd(RcCmd.taskList), peer);
      expect(await dropped(), isTrue);
    });

    test('task.list full=true → 走完整线格式分支后 _send', () async {
      await seedTask('tl2');
      await svc.debugDispatch(cmd(RcCmd.taskList, {'full': true}), peer);
      expect(await dropped(), isTrue);
    });

    test('task.get 命中 → 走到 _send（不回失败）', () async {
      await seedTask('tg1');
      await svc.debugDispatch(cmd(RcCmd.taskGet, {'taskId': 'tg1'}), peer);
      expect(await dropped(), isTrue);
    });

    test('task.get 未命中 → 显式失败回执（任务不存在）', () async {
      await svc.debugDispatch(cmd(RcCmd.taskGet, {'taskId': 'nope'}), peer);
      // 与命中区分：命中会 _send（drop 审计），未命中只 _ack(false)。
      expect(await dropped(), isTrue);
    });

    test('task.get 缺 taskId → 走 null 分支（同未命中，显式失败）', () async {
      await svc.debugDispatch(cmd(RcCmd.taskGet), peer);
      expect(await dropped(), isTrue);
    });
  });

  group('ED2-03 task.upsert（含重物化）', () {
    test('合法定义 → 落库 + success 审计', () async {
      await svc.debugDispatch(
          cmd(RcCmd.taskUpsert, {'task': wireTask('up1')}), peer);
      final t = await TaskRepository(db).get('up1');
      expect(t, isNotNull, reason: '合法线格式必须真的落库');
      expect(t!.name, '远程任务 up1');
      expect(await hasLog(action: 'task.upsert', status: 'success'), isTrue);
    });

    test('再次 upsert 同一 id → 记为「更新」而非「新建」', () async {
      await seedTask('up2');
      await svc.debugDispatch(
          cmd(RcCmd.taskUpsert, {'task': wireTask('up2')}), peer);
      expect(await hasLog(action: 'task.upsert', status: 'success'), isTrue);
      expect(await hasLog(contains: '更新'), isTrue);
    });

    test('非法定义（缺 trigger）→ failed 审计 + 不落库', () async {
      final bad = Map<String, dynamic>.from(wireTask('bad1'))
        ..remove('trigger');
      await svc.debugDispatch(cmd(RcCmd.taskUpsert, {'task': bad}), peer);
      expect(await hasLog(action: 'task.upsert', status: 'failed'), isTrue);
    });
  });

  group('ED2-04 task.delete / task.runNow', () {
    test('delete 命中 → 任务真的消失', () async {
      await seedTask('dk1');
      await svc.debugDispatch(cmd(RcCmd.taskDelete, {'taskId': 'dk1'}), peer);
      expect(await TaskRepository(db).get('dk1'), isNull);
      expect(await hasLog(action: 'task.delete', status: 'success'), isTrue);
    });

    test('delete 未命中 → skipped（不误报成功）', () async {
      await svc.debugDispatch(cmd(RcCmd.taskDelete, {'taskId': 'ghost'}), peer);
      expect(await hasLog(action: 'task.delete', status: 'skipped'), isTrue);
    });

    test('runNow 缺 taskId → 显式失败', () async {
      await svc.debugDispatch(cmd(RcCmd.taskRunNow), peer);
      expect(await dropped(), isTrue);
    });

    test('runNow 未命中 → 显式失败（任务不存在）', () async {
      await svc.debugDispatch(cmd(RcCmd.taskRunNow, {'taskId': 'ghost'}), peer);
      expect(await dropped(), isTrue);
    });

    test('runNow 命中 → 引擎未运行时如实 failed（不静默成功）', () async {
      await seedTask('rn1');
      await svc.debugDispatch(cmd(RcCmd.taskRunNow, {'taskId': 'rn1'}), peer);
      expect(await hasLog(action: 'task.runNow'), isTrue);
      expect(await hasLog(contains: '调度引擎未运行'), isTrue);
    });
  });

  group('ED2-05 asset.list / preset.list', () {
    test('asset.list → 走到 _send', () async {
      await svc.debugDispatch(cmd(RcCmd.assetList), peer);
      expect(await dropped(), isTrue);
    });

    test('asset.list 带 limit → clamp 后 _send', () async {
      await svc.debugDispatch(cmd(RcCmd.assetList, {'limit': 99999}), peer);
      expect(await dropped(), isTrue);
    });

    test('preset.list → 走到 _send（空库也回空分类）', () async {
      await svc.debugDispatch(cmd(RcCmd.presetList), peer);
      expect(await dropped(), isTrue);
    });
  });

  group('ED2-06 task.skipNext / guard.set / volume.set', () {
    test('skipNext 缺 taskId → 显式失败', () async {
      await svc.debugDispatch(cmd(RcCmd.taskSkipNext), peer);
      expect(await dropped(), isTrue);
    });

    test('skipNext 无待执行计划 → skipped（不误报成功）', () async {
      await seedTask('sk1');
      await svc.debugDispatch(cmd(RcCmd.taskSkipNext, {'taskId': 'sk1'}), peer);
      expect(await hasLog(action: 'task.skipNext', status: 'skipped'), isTrue);
    });

    test('guard.set 引擎未运行 → 如实 failed（成功误报比失败更贵）', () async {
      await svc.debugDispatch(cmd(RcCmd.guardSet, {'enabled': true}), peer);
      expect(await hasLog(action: 'guard.set', status: 'failed'), isTrue);
    });

    test('volume.set → 按原生真实结果回执（宿主为 failed）', () async {
      await svc.debugDispatch(
          cmd(RcCmd.volumeSet, {'media': 0.5, 'alarm': 0.5}), peer);
      expect(await hasLog(action: 'volume.set'), isTrue);
    });
  });

  group('ED2-07 device.status', () {
    test('device.status → 走到 _send（无电池平台走 try/on Object）', () async {
      await svc.debugDispatch(cmd(RcCmd.deviceStatus), peer);
      expect(await dropped(), isTrue);
    });
  });

  group('ED2-08 location.get（用 seam 穷举，不碰真实插件）', () {
    test('权限被拒 → failed 审计 + 带可执行引导（不是笼统"定位失败"）', () async {
      svc.locationPermissionGate = () async => false;
      await svc.debugDispatch(cmd(RcCmd.locationGet), peer);
      expect(await hasLog(action: 'location', status: 'failed'), isTrue);
      expect(await hasLog(contains: '请点亮屏幕后在前台重试'), isTrue);
    });

    test('定位服务关闭 → failed 审计 + 引导', () async {
      svc.locationPermissionGate = () async => true;
      svc.locationServiceEnabled = () async => false;
      await svc.debugDispatch(cmd(RcCmd.locationGet), peer);
      expect(await hasLog(action: 'location', status: 'failed'), isTrue);
      expect(await hasLog(contains: '请点亮屏幕后在前台重试'), isTrue);
    });

    test('全部就绪 → success 审计（含经纬度）', () async {
      svc.locationPermissionGate = () async => true;
      svc.locationServiceEnabled = () async => true;
      svc.locationFix = () async => pos(31.2304, 121.4737);
      await svc.debugDispatch(cmd(RcCmd.locationGet), peer);
      expect(await hasLog(action: 'location', status: 'success'), isTrue);
      expect(await hasLog(contains: '31.2304'), isTrue);
    });
  });

  group('ED2-09 script.run / sound.play / vibrate.stop', () {
    test('script.run 空步骤 → 显式失败（指令组为空）', () async {
      await svc.debugDispatch(
          cmd(RcCmd.scriptRun, scriptPayload('sr0', steps: [])), peer);
      expect(await dropped(), isTrue);
    });

    test('script.run 步骤过多（>50）→ 显式失败', () async {
      final many = [
        for (var i = 0; i < 51; i++) {'kind': 'delay', 'seconds': 1},
      ];
      await svc.debugDispatch(
          cmd(RcCmd.scriptRun, scriptPayload('sr1', steps: many)), peer);
      expect(await dropped(), isTrue);
    });

    test('sound.play 空选择器且库内无音源 → 如实 failed（不静默换音源）', () async {
      await svc.debugDispatch(cmd(RcCmd.soundPlay), peer);
      expect(await hasLog(action: 'play', status: 'failed'), isTrue);
    });

    test('vibrate.stop → success 审计 + 回执', () async {
      // `flutter_background_service` 的 `Platform.instance` 在非 Android/iOS
      // **直接抛 UnsupportedError**（发生在任何 MethodChannel 之前，打桩无用）
      // ⇒ 必须用 `BackgroundServiceManager.invokeHook` 短路。
      // 第二步 `NativeBridge.vibrateStop()` 自身已 catch
      // PlatformException/MissingPluginException ⇒ 宿主安全。
      BackgroundServiceManager.invokeHook = (method, args) async {};
      addTearDown(() => BackgroundServiceManager.invokeHook = null);
      await svc.debugDispatch(cmd(RcCmd.vibrateStop), peer);
      expect(await hasLog(action: 'vibrate.stop', status: 'success'), isTrue);
      expect(await hasLog(contains: '已请求停止全部进行中的振动'), isTrue);
    });
  });
}
