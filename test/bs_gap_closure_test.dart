/// 第六十九轮 · 覆盖率冲刺（第十二轮）—— 撬开 4 处**此前被登记为
/// 「宿主不可达」但其实可达**的落点。
///
/// ## 为什么这 4 处此前被记为不可达（以及为什么那是误判）
///
/// 1. `remote_screen.dart` **开关打开**（138–140 / 142–143）与
///    **已开启时改 broker**（326–329）：
///    `test/remote_screen_test.dart` 文件头写着「要 `databaseProvider`
///    （宿主无实现）并真正 `RcEndpointService.start()` 连 MQTT」⇒ 判不可达。
///    但本仓库**两样都有现成接缝**：`databaseProvider.overrideWith`（内存库）
///    与 `RcEndpointService.debugClientFactory`（第 48 轮的纯 Dart 替身）。
///    ⇒ 这两条是**宿主可达**的，只是当时的测试没去接。
/// 2. `script_builder_screen.dart` 的 `if (ok) Navigator.pop()`（187）：
///    `test/script_builder_screen_test.dart` 文件头写着「宿主无 MQTT ⇒ `sendTo`
///    恒 false ⇒ 成功侧只能设备层覆盖」。但 `sendTo` 上有 `debugSendTo` 接缝
///    （第 48 轮起用于注入投递结果）⇒ 成功侧同样**宿主可达**。
/// 3. `endpoint_service.dart` 的 `_assistPeer()`（340）里 `s?.ctrlName ?? ''`
///    的**空会话侧**：只在协助会话为 `null` 时求值。会话非空那条路径已被
///    其它用例走过（故只有这一行的 RHS 是 0 命中）。直接驱动 `start()`
///    注册的 `onCommand` 回调（与 MQTT 测试驱动 `onConnected` 同一手法）
///    即可在**无会话**下命中它。
///
/// 判据不变：**只撬真实可达行**；替身只复刻平台侧返回形状，跑的是生产代码本身。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/features/remote/remote_screen.dart';
import 'package:sonic_shield/features/remote/script_builder_screen.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

import 'support/mqtt_client_stub.dart';

/// 一个"写库必炸"的仓储替身 —— 用来驱动保存失败分支（见 BS-03）。
///
/// 只覆写 `upsert`（**唯一的写入出口**），其余行为原样继承 ⇒ 跑的还是真实的
/// 仓储实现，不是它的复制品。
class _BoomRepo extends TaskRepository {
  _BoomRepo(super.db);

  @override
  Future<void> upsert(Task t) async {
    throw StateError('BS-03：模拟写库失败');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const perTest = Timeout(Duration(seconds: 90));
  const ownId = 'EPBS000000000abc';

  final svc = RcEndpointService.instance;

  late AppDatabase db;
  late FakeMqttServerClient fake;
  late RemoteStore store;

  /// 工厂被真正调用时收到的 broker（`null` = 压根没调用）。
  String? seenBroker;

  setUp(() async {
    seenBroker = null;
    SharedPreferences.setMockInitialValues({});
    db = await AppDatabase.open(inMemoryDatabasePath);
    store = RemoteStore(await SharedPreferences.getInstance());
    fake = FakeMqttServerClient('broker.ignored.invalid', ownId);
    svc.debugClientFactory = (broker, clientId, port) {
      seenBroker = broker;
      return fake;
    };
  });

  tearDown(() async {
    // 必须先停服务（`stop()` 里取消 60s 周期心跳），否则：
    // ① 下一例 `start()` 会在 `if (_running) return;` 上直接早退 ⇒ 假绿；
    // ② 单例上捕获了本用例 `db` 的 `audit` / `onCommand` 闭包会写进已关闭的库。
    await svc.stop();
    svc.debugClientFactory = null;
    svc.debugSendTo = null;
    RcAssistHost.instance.audit = null;
    RcAssistHost.instance.onCommand = null;
    BackgroundServiceManager.replanHook = null;
    await fake.dispose();
    await db.close();
  });

  void bigViewport(WidgetTester tester, [Size size = const Size(1200, 4000)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  PairedEndpoint ep(String id, String name) => PairedEndpoint(
      deviceId: id, name: name, secret: 'AB2CD5EF', pairedAt: DateTime(2026));

  /// 挂载远程设置页（带内存库覆盖 ⇒ `databaseProvider.future` 可在宿主兑现）。
  Future<void> pumpRemote(
    WidgetTester tester, {
    bool enabled = false,
    String deviceId = '',
    String broker = '',
  }) async {
    if (enabled) await store.setEnabled(true);
    if (deviceId.isNotEmpty) {
      await store.setIdentity(deviceId, '声盾-${deviceId.substring(0, 4)}');
    }
    if (broker.isNotEmpty) await store.setBroker(broker);

    bigViewport(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWith((ref) async => db)],
      child: const MaterialApp(home: RemoteScreen()),
    ));
    await tester.pumpAndSettle();
  }

  // ══════════════════════════════════════════════════════════════════
  // BS-A · 远程设置页的两个「宿主不可达」分支
  // ══════════════════════════════════════════════════════════════════

  testWidgets('BS-01 开启开关 → 真生成设备身份 + 真装配端点服务（不是"只改界面"）',
      (tester) async {
    expect(store.enabled, isFalse, reason: '前提：默认关闭');
    expect(store.deviceId, isEmpty, reason: '前提：尚无身份');

    await pumpRemote(tester);
    expect(find.text('端点已关闭'), findsOneWidget);
    expect(find.text('开启后自动生成'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, '端点已关闭'));
    await tester.pumpAndSettle();

    // ① 身份真的生成了（16 位十六进制）—— 不是只在界面上显示。
    expect(store.deviceId.length, 16,
        reason: '首次开启必须生成 16 位设备 ID 并落库');
    expect(store.enabled, isTrue, reason: '开关必须真落库，否则重启即"没开过"');
    // ② 服务真的起来了，且用的是 store 里的 broker。
    expect(svc.isRunning, isTrue,
        reason: '不开服务就显示"端点在线"＝对用户撒谎');
    expect(seenBroker, RemoteStore.defaultBroker,
        reason: '未配置 broker ⇒ 回落到共享默认值（与 MQ-01 同判据）');
    expect(find.text('端点在线'), findsOneWidget);

    // ⚠️ 必须在**用例体内**停服务：`start()` 里的 `Timer.periodic(60s)` 心跳
    // 会在用例体结束后、`tearDown` 之前被 `_verifyInvariants` 判为
    // "A Timer is still pending"（实测：只放 tearDown 会红）。
    await svc.stop();
  }, timeout: perTest);

  testWidgets('BS-02 已开启时改 MQTT 代理 → 真的 stop+start 重启端点服务',
      (tester) async {
    await pumpRemote(tester, enabled: true, deviceId: ownId, broker: 'old.broker');
    expect(find.text('端点在线'), findsOneWidget);
    expect(svc.isRunning, isFalse, reason: '前提：本页只显示状态，尚未真正连');

    await tester.tap(find.text('MQTT 代理'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'new.broker.bs');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(store.broker, 'new.broker.bs', reason: '新地址必须落库');
    expect(svc.isRunning, isTrue,
        reason: '已开启时改 broker 必须重启服务，否则新地址要等下次重启才生效');
    expect(seenBroker, 'new.broker.bs',
        reason: '重启后的连接必须用**新** broker —— 用旧的等于没重启');
    expect(fake.connectCalls, 1, reason: 'stop→start 应恰好重连一次');

    await svc.stop(); // 同上：必须在用例体内取消 60s 周期心跳
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════
  // BS-B · 任务编辑器：本机保存失败必须可见
  // ══════════════════════════════════════════════════════════════════

  testWidgets('BS-03 本机保存失败 → 明确提示，不静默吞异常（也不谎报成功）',
      (tester) async {
    BackgroundServiceManager.replanHook = () async {};
    bigViewport(tester, const Size(1080, 4000));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => db),
        taskRepoProvider.overrideWith((ref) async => _BoomRepo(db)),
      ],
      child: const MaterialApp(home: TaskEditorScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存任务'));
    // ⚠️ 不用 `pumpAndSettle`：保存失败提示是 SnackBar，settle 到底会启动它的
    // 自动消失计时器（4s）。用有界推帧读到提示即止。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.textContaining('保存失败：'), findsOneWidget,
        reason: '仓储抛错必须变成可见提示 —— 否则用户以为"点了没反应"，'
            '而真实原因是写库失败');
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════
  // BS-C · 指令组装器：发送成功必须真的返回上一页
  // ══════════════════════════════════════════════════════════════════

  testWidgets('BS-04 发送成功 → 真的 pop 回上一页（此前记为"仅设备层可达"）',
      (tester) async {
    // `debugSendTo` 是第 48 轮起就有的注入缝（MQTT 测试在用）——
    // 交付成果设为 true ⇒ 走"成功侧"。
    svc.debugSendTo = (endpoint, msg, s, enqueueOnFail) async => true;
    await store.addPaired(ep('devA', '客厅音箱'));

    bigViewport(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWith((ref) async => db)],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
                    builder: (_) =>
                        const ScriptBuilderScreen(endpointId: 'devA'))),
                child: const Text('HOST-OPEN'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HOST-OPEN'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ActionChip, '时延'));
    await tester.pumpAndSettle();
    expect(find.text('步骤（共 1）'), findsOneWidget, reason: '前置：草稿里有一步');

    await tester.tap(find.text('发送并立即执行'));
    await tester.pumpAndSettle();

    expect(find.text('发送并立即执行'), findsNothing,
        reason: '发送成功必须真的返回上一页 —— 停在原页会让用户以为没发出去');
    expect(find.text('HOST-OPEN'), findsOneWidget, reason: '回到了宿主页');
  }, timeout: perTest);

  // ══════════════════════════════════════════════════════════════════
  // BS-D · 端点服务：协助回调下的虚拟对端（无会话侧）
  // ══════════════════════════════════════════════════════════════════

  test('BS-05 协助 onCommand 在无会话时构造虚拟对端（默认名兜底）', () async {
    await svc.start(store, db);
    expect(RcAssistHost.instance.session, isNull,
        reason: '前提：本用例不建立协助会话 ⇒ 走 `s?.ctrlName ?? ""` 的兜底侧');
    expect(RcAssistHost.instance.onCommand, isNotNull,
        reason: 'start() 必须装配协助命令回调，否则协助会话的业务命令无处可去');

    // ★ 驱动 `start()` 注册的**生产回调本身**（与 MQTT 测试驱动 `onConnected`
    //   同一手法），不是绕过它。
    await RcAssistHost.instance.onCommand!(RcMessage.now(RcCmd.ping));
    await Future<void>.delayed(Duration.zero);

    expect(svc.isRunning, isTrue, reason: '回调不该把服务搞挂');
  }, timeout: perTest);
}
