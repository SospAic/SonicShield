/// 第六十轮 · **覆盖率冲刺（第三轮）**：延续「先 `covgap.py` 定位未覆盖行 →
/// 判可达性 → 只写能**真的执行到那一行**的用例」的流程（`docs/12 §81`）。
///
/// ## 与第一/二轮（`bh_gap_closure_test.dart` / `bi_gap_closure2_test.dart`）的分工
///
/// 前两轮取的是 domain/仓储/`_send` 出站与 endpoint 入站的两批簇；本轮取的是
/// **第三批、更靠边的碎片**：
/// - **A 组**：模型/服务层的**运行期构造与失败审计**（`fromJson` 缺省回退、
///   非 const 构造、时区通道可用路径、活跃振动停止、随机振动被原生拒绝）；
/// - **B 组**：`RcEndpointService` 的**协助虚拟对端**与**撤销清理的副作用分支**
///   （此前只测了「无在途作业 ⇒ 空操作」，"有在途 ⇒ 真的停 + 记账"从未被执行）。
///
/// ## 纪律
///
/// - 断言的是**可观测副作用**（回退值 / 库里的审计行 / 执行器状态），不是"没抛异常"。
/// - 单例（`RcEndpointService` / `RcScriptExecutor` / `RcAssistHost` / `NotificationService`）
///   上的注入必须在 `tearDown` 还原，否则污染同进程其它用例。
/// - **明确不测**（结构性不可达，逐行证据见 `docs/40`）：
///   `PlaybackSoundscape.stopSoundscape`（被实例成员遮蔽的重复扩展方法）、
///   `rotatedPairingCode` 的 while 重试体（需 1/32^8 的随机碰撞）、
///   私有构造 `X._()`（`RcCodec` / `ExportCrypto` / `NativeBridge`）。
@Timeout(Duration(seconds: 180))
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/remote/script_executor.dart';
import 'package:sonic_shield/services/notification_service.dart';
import 'package:sonic_shield/services/playback_service.dart';
import 'package:sonic_shield/services/vibrate_session.dart';

import 'support/mqtt_client_stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const notifChannel = 'dexterous.com/flutter/local_notifications';
  const tzChannelName = 'flutter_timezone';

  final svc = RcEndpointService.instance;

  late SharedPreferences prefs;
  late RemoteStore store;
  late AppDatabase db;
  late KdfSaltStore salts;

  const ownId = 'EPJ00001abcdef12';
  const ctrlId = 'CTRLJ001abcdef12';
  const ctrlCode = 'CODEJ001';

  PairedEndpoint peerOf(String id, String name, String code) => PairedEndpoint(
      deviceId: id, name: name, secret: code, pairedAt: DateTime(2024, 1, 1));

  Future<void> bind() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    await store.setIdentity(ownId, '端点机J');
    await store.setBroker('broker.round60.invalid');
    await store.ensurePairingCode();
    salts = KdfSaltStore(prefs);
    db = await AppDatabase.open(inMemoryDatabasePath);
    svc.debugBind(store: store, db: db, saltStore: salts);
    svc.debugSetOwnCode(store.pairingCode);
    svc.debugClientFactory =
        (broker, clientId, port) => FakeMqttServerClient(broker, clientId);
  }

  setUp(() async {
    // 通知插件通道：指令组终态 / 告警都要经 `NotificationService`
    // ⇒ 宿主上必须打桩，否则 MissingPluginException 会以"无主异常"形式
    // 记在**不相干**的用例头上（`endpoint_script_run_test.dart` 同法）。
    messenger.setMockMethodCallHandler(const MethodChannel(notifChannel),
        (call) async => call.method == 'initialize' ? true : null);
    await bind();
  });

  tearDown(() async {
    svc.debugSendTo = null;
    svc.debugClientFactory = null;
    svc.playHandler = null;
    svc.resolvePresetHandler = null;
    svc.ttsHandler = null;
    svc.vibrateHandler = null;
    svc.vibrateActionHandler = null;
    svc.debugSetOwnCode('');
    RcScriptExecutor.instance.stop();
    if (svc.isRunning) await svc.stop();
    messenger.setMockMethodCallHandler(const MethodChannel(notifChannel), null);
    try {
      await db.close();
    } on Object {
      // 在飞的终态定时器可能已把库关掉 —— 忽略。
    }
  });

  RcMessage cmd(String type, [Map<String, dynamic> payload = const {}]) =>
      RcMessage.now(type, payload);

  Future<List<Map<String, Object?>>> logRows() =>
      LogRepository(db).recent(limit: 400);

  Future<bool> hasLog(String action, String status, {String? contains}) async {
    final rows = await logRows();
    return rows.any((r) {
      if (r['action'] != action || r['status'] != status) return false;
      final m = r['message'] as String? ?? '';
      return contains == null || m.contains(contains);
    });
  }

  // ══════════════════════════════════════════════════════════════════
  // A · 模型 / 服务层的运行期构造与失败审计
  // ══════════════════════════════════════════════════════════════════

  // ⚠️ 本用例必须**排在文件最前**：`NotificationService` 是单例且 `_ready`
  // 一旦被置真，`ensure()` 的时区装配段就再也不会执行（本文件内跨用例存活）。
  test('BJ-A3 NotificationService.ensure：时区通道可用 ⇒ 落到真实时区（非 UTC 兜底）',
      () async {
    messenger.setMockMethodCallHandler(
        const MethodChannel(tzChannelName), (call) async => 'Asia/Shanghai');
    addTearDown(() => messenger
        .setMockMethodCallHandler(const MethodChannel(tzChannelName), null));

    await NotificationService.instance.ensure();

    expect(tz.local.name, 'Asia/Shanghai',
        reason: '时区通道可用时必须落到真实时区 —— 落到 UTC 兜底会让"定时通知"在错误的时间响');
  });

  group('BJ-A 模型/服务兜底分支', () {
    test('BJ-A1 PairedEndpoint.fromJson：缺 pairedAt ⇒ 回退"现在"而不是 1970', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final p = PairedEndpoint.fromJson(<String, dynamic>{
        'deviceId': 'a1a1a1a1a1a1a1a1',
        'name': '设备A1',
        'secret': 'S1',
      });
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(p.pairedAt.millisecondsSinceEpoch, inInclusiveRange(before, after),
          reason: 'pairedAt 缺失时必须回退 now()；回退 1970 会让"最近配对"排序整片错乱');
      expect(p.name, '设备A1');
      expect(p.alias, isNull);
      expect(p.lastConnectedAt, isNull);
    });

    test('BJ-A2 SoundscapeTrackInput：运行期（非 const）构造 ⇒ 默认 volume 0.6 / loop true', () {
      final path = 'bj_a2_${DateTime.now().microsecondsSinceEpoch}.mp3';

      final t = SoundscapeTrackInput(path: path);
      expect(t.path, path);
      expect(t.volume, 0.6, reason: '声景轨默认音量是混音基线，改掉会整体偏响/偏轻');
      expect(t.loop, isTrue);

      final t2 = SoundscapeTrackInput(path: path, volume: 0.25, loop: false);
      expect(t2.volume, 0.25);
      expect(t2.loop, isFalse);
    });
  });

  group('BJ-A4/A5 VibrateSession 的停止与失败审计（全依赖注入，不碰平台通道）', () {
    late AppDatabase vdb;
    late LogRepository vlogs;

    setUp(() async {
      vdb = await AppDatabase.open(inMemoryDatabasePath);
      vlogs = LogRepository(vdb);
    });
    tearDown(() async {
      await vdb.close();
    });

    VibrateSession build({bool sendOk = true}) {
      final sent = <Object>[];
      final stops = <String>[];
      final clock = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      return VibrateSession(
        logs: vlogs,
        capsProbe: () async => const VibrateCaps(
          hasVibrator: true,
          hasAmplitudeControl: true,
          hasEnvelope: true,
          minControlPointMs: 20,
          platform: 'android',
        ),
        send: (c) async {
          if (!sendOk) return false;
          sent.add(c);
          return true;
        },
        stopNative: () async => stops.add('cancel'),
        battery: () async => (level: 90, charging: false),
        kvGet: (k) async => null,
        kvSet: (k, v) async {},
        now: () => clock,
        // 真实定时器故意设得远大于用例时长：续发由测试显式 `pump()` 驱动。
        tick: const Duration(hours: 1),
      );
    }

    test('BJ-A4 stopAll：有活跃振动时逐个 stopFor(skipNative) 后统一 cancel 并清表', () async {
      final s = build();
      final ok = await s.start(
        occurrenceId: 'bj-a4',
        taskId: 't-a4',
        action: const ContinuousVibrateAction(),
        durationMs: 60000,
        amplitude: 0.5,
        source: 'test',
      );
      expect(ok, isTrue);
      expect(s.activeCount, 1, reason: '前置条件：必须有活跃项才走得到"逐个 stopFor"那一格');

      await s.stopAll(reason: '远程停止');

      expect(s.activeCount, 0,
          reason: '★ S3「任何时刻都能停」：stopAll 必须把活跃表清空（留活跃项 = UI 永远显示"振动中"）');
      s.dispose();
    });

    test('BJ-A5 随机振动被原生拒绝 ⇒ 审计如实写 failed 且含原因（不假装还在震）', () async {
      final s = build(sendOk: false);
      final ok = await s.start(
        occurrenceId: 'bj-a5',
        taskId: 't-a5',
        action: const RandomVibrateAction(),
        durationMs: 3000,
        amplitude: 0.8,
        source: 'test',
      );
      expect(ok, isFalse, reason: '下发失败必须返回 false，否则引擎以为震过了');

      final rows = await vlogs.recent(limit: 20);
      final row = rows.firstWhere((r) => r['action'] == 'randomVibrate');
      expect(row['status'], 'failed');
      expect(row['message'] as String, contains('原生拒绝或桥不可用'),
          reason: '★ 必须写明"为什么没震" —— 只写"失败"会让用户无从排查（BUG-059 通则）');
      s.dispose();
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // B · 端点服务：协助虚拟对端 / 撤销清理的副作用分支
  // ══════════════════════════════════════════════════════════════════

  group('BJ-B 端点服务 · 协助对端与撤销清理', () {
    test('BJ-B1 协助会话控制端虚拟对端：无配对秘密、无名时回退占位名', () async {
      await svc.start(store, db);

      final onCmd = RcAssistHost.instance.onCommand;
      expect(onCmd, isNotNull,
          reason: 'start() 必须把协助命令入口挂上，否则协助会话永远收不到命令');

      // 无协助会话（session == null）⇒ ctrlName 取不到 ⇒ 占位名「协助控制端」。
      // 命令类型未知 ⇒ `_dispatch` 不做任何业务分支。
      await onCmd!(RcMessage.now('bj.unknown.cmd'));

      expect(RcAssistHost.instance.session, isNull,
          reason: '只有一条未知命令，不得凭空建出会话（虚拟对端 ≠ 会话存在）');
      expect(await hasLog('assist', 'success'), isFalse,
          reason: '未知命令不得产生"成功"审计');
    });

    test('BJ-B2 onPeerRevoked：该设备名下有在途指令组 ⇒ 真的停脚本 + 如实审计', () async {
      await svc.start(store, db);

      const s = RcScript(
        scriptId: 'bj-sc-1',
        name: '长宏',
        fromName: '控制端',
        sentAt: 1700000000000,
        // `delay 3s` 把执行器占住 ⇒ 制造一个"指令组在跑"的窗口。
        steps: [RcStep(RcStepKind.delay, {'seconds': 3})],
      );
      final peer = peerOf(ctrlId, '控制端J', ctrlCode);

      // ⚠️ **不能 await**：delay 步会让 dispatch 挂住 3s，而我们要在
      // 「指令组运行中」的窗口里执行撤销（这正是被修的那个形状）。
      unawaited(svc.debugDispatch(cmd(RcCmd.scriptRun, s.toJson()), peer));
      for (var i = 0; i < 40 && !RcScriptExecutor.instance.isRunning; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(RcScriptExecutor.instance.isRunning, isTrue,
          reason: '前置条件：指令组必须真的在跑，否则测不到"撤销清理"的副作用');

      await svc.onPeerRevoked(ctrlId);

      // `stop()` 是**同步接口**（先落标志 + 掐媒体），执行循环的收尾是异步的
      // ⇒ 有界等待它真正退出，而不是赌同步返回后 `isRunning` 已经变了。
      for (var i = 0; i < 40 && RcScriptExecutor.instance.isRunning; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      expect(RcScriptExecutor.instance.isRunning, isFalse,
          reason: '★ 撤销配对必须停掉被撤销设备名下的在途作业 —— '
              '否则用户点了"删除设备"，那台设备下发的宏还在继续出声');
      expect(
          await hasLog('pair.revoke', 'success',
              contains: '解除配对：已终止该设备的在途'),
          isTrue,
          reason: '停掉了就必须如实记账，否则用户看不出"到底停没停"');
    });
  });
}
