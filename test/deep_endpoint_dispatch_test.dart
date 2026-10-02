import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/native_bridge.dart';

/// 第 36 轮续四：直接驱动 `RcEndpointService._dispatch` 的**宿主可测**子处理器。
///
/// 入站链路 `_handleRaw → _dispatch` 的生产唯一调用者是真实 MQTT
/// `client.updates` 监听器，宿主机连不上 broker，且全文件此前无任何注入缝 ⇒
/// 20 余个子处理器一条都驱动不到。本文件通过 `debugBind` + `debugDispatch`
/// 接缝（见 `endpoint_service.dart` 顶部）直接喂入站消息，断言**真实副作用**
/// （配对表变更 / 任务表落库 / 审计日志），而非"执行了没抛异常"。
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
    // 注意：debugDispatch 直接注入 peer，不经过 _handleRaw 的 _peerOf 反查，
    // 因此 peer 的 deviceId 不必与配对表一致即可用于断言。
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

  final svc = RcEndpointService.instance;

  group('ED-01 配对双向化 _handlePairRequest', () {
    test('合法请求 → 控制端被登记进本机配对表', () async {
      await svc.debugDispatch(
        cmd(RcCmd.pairRequest, {
          'deviceId': 'ABCD1234efgh5678',
          'code': '12345678',
          'name': '手机A',
        }),
        peer,
      );
      expect(store.paired().any((p) => p.deviceId == 'ABCD1234efgh5678'),
          isTrue);
      // 配对成功会写成功审计（action 相同、status=success）。
      expect(await hasLog(action: 'pair.request', status: 'success'), isTrue);
    });

    test('deviceId/code 长度不符 → 显式失败且不登记（不覆盖、不静默）', () async {
      await svc.debugDispatch(
        cmd(RcCmd.pairRequest, {
          'deviceId': 'SHORT',
          'code': '12345678',
          'name': '手机B',
        }),
        peer,
      );
      expect(await hasLog(action: 'pair.request', status: 'failed'), isTrue);
      // 关键安全性：绝不能把控制端登记进配对表。
      expect(store.paired().any((p) => p.deviceId == 'SHORT'), isFalse);
    });
  });

  group('ED-02 任务开关 task.toggle', () {
    test('缺 taskId → 显式失败（回执被丢弃，但必须有痕迹）', () async {
      await svc.debugDispatch(cmd(RcCmd.taskToggle), peer);
      // _ack(false) 在宿主无 broker 时落为出站丢弃审计（action=ack 类型，
      // status=skipped，message 含「出站消息未发出」）。这证明命令已被分发、
      // 处理器走到了缺参早返分支并尝试回执——是真实行为信号。
      expect(await hasLog(status: 'skipped', contains: '出站消息未发出'),
          isTrue);
    });

    test('禁用 → 任务置为 false', () async {
      await seedTask('tk1', enabled: true);
      await svc.debugDispatch(
          cmd(RcCmd.taskToggle, {'taskId': 'tk1', 'enabled': false}), peer);
      final t = await TaskRepository(db).get('tk1');
      expect(t, isNotNull);
      expect(t!.enabled, isFalse);
      expect(await hasLog(action: 'task.toggle', status: 'success'), isTrue);
    });

    test('启用 → 任务置为 true（非协助会话下无权限否决）', () async {
      await seedTask('tk2', enabled: false);
      await svc.debugDispatch(
          cmd(RcCmd.taskToggle, {'taskId': 'tk2', 'enabled': true}), peer);
      final t = await TaskRepository(db).get('tk2');
      expect(t, isNotNull);
      expect(t!.enabled, isTrue);
    });
  });

  group('ED-03 缺参/未启用命令的显式失败与 skipped', () {
    test('task.upsert 缺 task 定义 → 回执丢弃（skipped 痕迹）', () async {
      await svc.debugDispatch(cmd(RcCmd.taskUpsert), peer);
      // 同 task.toggle 缺参：ack 落为出站丢弃审计。
      expect(await hasLog(status: 'skipped', contains: '出站消息未发出'),
          isTrue);
    });

    test('task.delete 缺 taskId → 回执丢弃（skipped 痕迹）', () async {
      await svc.debugDispatch(cmd(RcCmd.taskDelete), peer);
      expect(await hasLog(status: 'skipped', contains: '出站消息未发出'),
          isTrue);
    });

    test('camera.snap 未启用 → skipped 审计（不是静默忽略）', () async {
      await svc.debugDispatch(cmd(RcCmd.cameraSnap), peer);
      expect(await hasLog(action: 'camera.snap', status: 'skipped'), isTrue);
    });

    test('未知命令 → skipped（与「静默忽略」严格区分，回执带原因）', () async {
      await svc.debugDispatch(cmd('totally.unknown.cmd'), peer);
      expect(await hasLog(status: 'skipped', contains: '未知命令'), isTrue);
    });

    test('script.stop 无匹配脚本 → skipped（不得误报成功）', () async {
      await svc.debugDispatch(
          cmd(RcCmd.scriptStop, {'scriptId': 'nope'}), peer);
      expect(await hasLog(action: 'script.stop', status: 'skipped'), isTrue);
      expect(await hasLog(contains: '无匹配脚本'), isTrue);
    });

    test('device.alert → 处理器执行（留下 audit 痕迹）', () async {
      await svc.debugDispatch(
          cmd(RcCmd.deviceAlert, {'title': 'hi', 'body': 'there'}), peer);
      expect(await hasLog(action: 'device.alert'), isTrue);
    });

    test('device.alert 原生确认成功 → 审计写「找回告警已展示」（按真实结果回执）',
        () async {
      // 宿主默认没有原生桥 ⇒ `NativeBridge.alert` 返回 false，回执/审计都是
      // 「原生未确认…」那一侧；**成功侧此前一行都没被执行过**。
      // 这里桩原生 `alert` 返回 true，断言审计真的切成"已展示"。
      const channel = MethodChannel(ChannelsMethod.channel);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'alert') return true;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await svc.debugDispatch(
          cmd(RcCmd.deviceAlert, {'message': '找到我'}), peer);

      expect(await hasLog(action: 'device.alert', contains: '找回告警已展示'),
          isTrue,
          reason: '原生确认成功却写"未确认"= 成功被误报为失败（回执不可信）');
    });

    test('logs.recent → 不抛异常（_send 在宿主为 no-op）', () async {
      await svc.debugDispatch(cmd(RcCmd.logsRecent, {'limit': 10}), peer);
    });
  });
}
