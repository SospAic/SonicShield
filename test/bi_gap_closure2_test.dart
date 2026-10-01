/// 第五十九轮 · **覆盖率冲刺（第二轮）**：继续按「先 `covgap.py` 定位未覆盖行 →
/// 判可达性 → 只写能**真的执行到那一行**的用例」的流程推进（`docs/12 §81`）。
///
/// ## 与第一轮（`bh_gap_closure_test.dart`）的分工
///
/// 第一轮取的是 domain/仓储 + `_send` 的出站丢弃审计；本轮取的是**第二轮可达簇**：
/// - **A 组**：纯逻辑/模型层的**防御性兜底分支**（浮点余量、非法子动作回落、
///   JSON 字符串入参、损坏持久化数据）；
/// - **B 组**：`RcEndpointService` 入站链路上**此前从未被行为驱动过**的分支
///   （占位对端、配对码不符拒绝、重配对复用盐、预置分类下发、
///   动作级权限裁决的**协助会话区**、通话信令分发臂、`_resolvePreset` 内置查询）。
///
/// ## 纪律
///
/// - 断言的是**可观测副作用**（库里的审计行 / 真正发出的密文 / 物化结果），
///   不是"没抛异常"；不写「为覆盖率而覆盖率」的空用例。
/// - 单例（`RcEndpointService` / `CallService` / `RcScriptExecutor`）上的注入
///   必须在 `tearDown` 还原，否则污染同进程其它用例。
/// - A-01（浮点余量）那条**断言与 549 行同值**（两条路径都返回最后一个候选），
///   它的价值是**锁住契约**（"roll 越界不得返回 null/抛异常"）；行覆盖由门禁
///   lcov 实测，不靠断言推断 —— 这条边界如实登记在报告里。
@Timeout(Duration(seconds: 180))
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/remote/script_executor.dart';
import 'package:sonic_shield/remote/task_wire.dart';

import 'support/mqtt_client_stub.dart';

/// `nextDouble()` 恒返回 1.0（roll 取满）⇒ 打中"浮点余量导致循环未提前返回"那一格。
class _MaxRandom implements Random {
  const _MaxRandom();

  @override
  double nextDouble() => 1.0;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  /// 通知插件通道（`NotificationService`）——来电用例需要它别把异常漏出来。
  const notifChannel = 'dexterous.com/flutter/local_notifications';

  final svc = RcEndpointService.instance;

  late SharedPreferences prefs;
  late RemoteStore store;
  late AppDatabase db;
  late KdfSaltStore salts;

  const ownId = 'EPI00001abcdef12';
  const ctrlId = 'CTRL0001abcdef12';
  const ctrlCode = 'CODE0001';

  PairedEndpoint peerOf(String id, String name, String code) => PairedEndpoint(
      deviceId: id, name: name, secret: code, pairedAt: DateTime(2024, 1, 1));

  Future<void> bind() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    await store.setIdentity(ownId, '端点机');
    await store.ensurePairingCode();
    salts = KdfSaltStore(prefs);
    db = await AppDatabase.open(inMemoryDatabasePath);
    svc.debugBind(store: store, db: db, saltStore: salts);
    svc.debugSetOwnCode(store.pairingCode);
  }

  setUp(() async {
    // 通知插件通道：`_runScript` 的终态与来电都要经 `NotificationService`
    // ⇒ 宿主上必须打桩，否则 MissingPluginException 会以"无主异常"形式
    // 记在**不相干**的用例头上（`endpoint_script_run_test.dart` 同法）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(notifChannel),
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(notifChannel), null);
    if (svc.isRunning) await svc.stop();
    try {
      await db.close();
    } on Object {
      // 在飞的终态定时器可能已把库关掉 —— 忽略。
    }
  });

  RcMessage cmd(String type, [Map<String, dynamic> payload = const {}]) =>
      RcMessage.now(type, payload);

  Future<List<Map<String, Object?>>> logs() => LogRepository(db).recent(limit: 400);

  Future<bool> hasLog(String action, String status, {String? contains}) async {
    final rows = await logs();
    return rows.any((r) {
      if (r['action'] != action || r['status'] != status) return false;
      final m = r['message'] as String? ?? '';
      return contains == null || m.contains(contains);
    });
  }

  String cmdTopic() => 'sonicshield/v1/$ownId/cmd';

  /// 造一条"从 [from] 发来"的命令信封（`RcMessage.now` 随机 ⇒ 天然去重安全）。
  RcMessage inbound(String type,
      {Map<String, dynamic> payload = const {}, String from = ctrlId}) {
    final n = RcMessage.now(type, payload);
    return RcMessage(
        id: n.id, ts: n.ts, type: n.type, payload: n.payload, from: from);
  }

  /// cmd 方向：控制端用「端点配对码 + 端点ID|cmd」加密（密钥模型见 `_handleRaw`）。
  Future<String> sealCmd(RcMessage msg) async {
    final key = await RcCodec.deriveKey(store.pairingCode, '$ownId|cmd');
    return RcCodec.encode(msg, key, cmdTopic());
  }

  // ══════════════════════════════════════════════════════════════════
  // A · 纯逻辑 / 模型层的防御性兜底分支
  // ══════════════════════════════════════════════════════════════════

  group('A 纯逻辑/模型兜底分支', () {
    test('A-01 动作集 pick：roll 取满且权重和出现浮点余量 ⇒ 返回最后一个候选', () {
      final set = ActionSetAction(candidates: [
        const ActionSetCandidate(
            weight: 0.1, action: NotifyAction(title: 'A', body: '')),
        const ActionSetCandidate(
            weight: 0.2, action: NotifyAction(title: 'B', body: '')),
      ]);

      // 0.1 + 0.2 == 0.30000000000000004；roll = 1.0 * total 逐项相减后
      // 仍余 ~4.16e-17 > 0 ⇒ 循环自然走完，落到"取最后一个"的兜底。
      final picked = set.pick(const _MaxRandom());

      expect(picked.action.toJson()['title'], 'B',
          reason: 'roll 越界（浮点余量）不得返回 null、不得抛异常 ——'
              '必须落到确定的最后一个候选，否则到点触发会静默什么都不做');
    });

    test('A-02 TaskWire.fromWire：composite 的 prefixNotify 非法 ⇒ 回落默认通知映射', () {
      final t = TaskWire.fromWire({
        'id': 'tw-bi-1',
        'name': '组合任务',
        'enabled': true,
        'triggerType': TriggerType.dailyAt.name,
        'trigger': {
          'kind': 'dailyAt',
          'time': {'hour': 10, 'minute': 0},
        },
        'actionType': ActionType.notify.name,
        'action': {
          'kind': 'composite',
          'primary': {'kind': 'notify', 'title': 'P', 'body': 'B'},
          // 非法子动作（vibrate 的 patternMs 既非 List 又非空）⇒
          // `_sanitizeActionMap` 返回 null ⇒ 必须回落默认通知，不得整单拒收。
          'prefixNotify': {'kind': 'vibrate', 'patternMs': 'not-a-list'},
        },
        'assetIds': <String>[],
        'cooldownSec': 300,
        'quietPolicy': QuietPolicy.skip.name,
        'priority': 0,
        'createdAt': 1,
        'updatedAt': 1,
      });

      expect(t, isNotNull, reason: '子动作非法只该降级，不该把整条任务判为非法');
      final pn = t!.action.toJson()['prefixNotify'] as Map;
      expect(pn['kind'], 'notify',
          reason: '回落值必须是**可执行的通知**（kind=notify），'
              '而不是原样透传一个 release 下会崩的非法配置');
      expect(pn['title'], '声盾');
      expect(pn['body'], '');
    });

    test('A-03 TaskWire.requiredPermBitsForTaskAction：入参是 JSON 字符串也要认', () {
      expect(TaskWire.requiredPermBitsForTaskAction('{"kind":"record"}'),
          equals({'record'}),
          reason: '线格式与 DB 列同构（都是 JSON 字符串）——'
              '只认 Map 会让"从库里读出来的动作"绕过采集红线判定');
      expect(
          TaskWire.requiredPermBitsForTaskAction(
              '{"kind":"composite","primary":{"kind":"record"}}'),
          equals({'record'}),
          reason: '字符串形态也必须递归 composite');
    });

    test('A-04 RemoteStore.savedScripts：持久化内容损坏 ⇒ 返回空表而不是抛异常', () async {
      SharedPreferences.setMockInitialValues({'rc_scripts': '[{损坏'});
      final s = RemoteStore(await SharedPreferences.getInstance());

      expect(s.savedScripts(), isEmpty,
          reason: '历史脏数据不得让"我的指令组"整页崩掉');
    });

    test('A-05 RemoteStore.outbox：持久化内容损坏 ⇒ 返回空表而不是抛异常', () async {
      SharedPreferences.setMockInitialValues({'rc_outbox': 'not-json-at-all'});
      final s = RemoteStore(await SharedPreferences.getInstance());

      expect(s.outbox(), isEmpty,
          reason: 'outbox 是补发链路的入口，抛异常等于"端点上线后自动执行"整条死掉');
    });

    test('A-06 物化随机振动动作：音量/时长取自振动计划（不走播放分支）', () {
      const engine = ScheduleEngine();
      final now = DateTime(2026, 9, 12, 0);
      final t = Task(
        id: 'bi-vib-1',
        name: '随机振动',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 10)),
        actionType: ActionType.randomVibrate,
        action: const RandomVibrateAction(
            durationSecMin: 3, durationSecMax: 10,
            amplitudeMin: 0.4, amplitudeMax: 1.0),
        assetIds: const [],
        cooldownSec: 0,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: now,
        updatedAt: now,
      );

      final list = engine.materialize(t, now);

      expect(list, isNotEmpty, reason: 'dailyAt 命中当天 10:00，必须物化出一条');
      final e = list.first;
      expect(e.durationMs, inInclusiveRange(3000, 10000),
          reason: '时长必须来自 RandomVibrateAction 的区间 ——'
              '落到 else 分支会变成 0（"到点不震"）');
      expect(e.volume, inInclusiveRange(0.4, 1.0),
          reason: '强度必须来自 amplitude 区间 —— 落到 else 会变成固定 0.8');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // B · 端点服务入站链路（此前只有源码文本锁、从未被行为驱动）
  // ══════════════════════════════════════════════════════════════════

  group('B 端点服务入站分支', () {
    test('B-01 发送方自报为空 ⇒ 走占位对端（不查表、不拒收）', () async {
      // 配对请求 + 非法 payload 长度：这样处理器**在拿到占位对端之后**失败，
      // 失败审计里带着 `peer.name` ⇒ 占位名可被观测（否则名字只进广播、看不见）。
      final seen = <Map<String, dynamic>>[];
      final sub = svc.events.listen(seen.add);
      await svc.debugHandleRaw(
          cmdTopic(),
          await sealCmd(inbound(RcCmd.pairRequest,
              payload: {'deviceId': 'short', 'code': 'ABC'}, from: '')));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(
          await hasLog('pair.request', 'failed', contains: '配对信息不完整'),
          isTrue,
          reason: '命令必须被分发（说明空 from 没有被准入拦掉）');
      expect(
          await hasLog('pair.request', 'failed', contains: '已配对控制器'),
          isTrue,
          reason: '★ 空 from ⇒ 占位对端名必须回落"已配对控制器"，'
              '而不是把空串当设备名写进审计（审计要能读懂）');
      // 广播里 peerId 为空 ⇒ 该键必须**不存在**（不是写了空串）。
      expect(seen, hasLength(1));
      expect(seen.single.containsKey('peerId'), isFalse);
    });

    test('B-02 已配对控制端带错配对码重新配对 ⇒ 拒绝且绝不覆盖已存秘密', () async {
      await store.addPaired(peerOf(ctrlId, '控制端A', ctrlCode));

      await svc.debugDispatch(
          cmd(RcCmd.pairRequest, {
            'deviceId': ctrlId,
            'code': 'WRONGCOD',
            'name': '冒名者',
          }),
          peerOf(ctrlId, '控制端A', ctrlCode));

      expect(await hasLog('pair.request', 'failed', contains: '配对码不符'),
          isTrue);
      final kept = store.paired().firstWhere((p) => p.deviceId == ctrlId);
      expect(kept.secret, ctrlCode,
          reason: '★ 覆盖 secret 等于把该控制端的回执密钥换掉 ——'
              '发件人从此能读走本该只给它的回执（提权面）');
    });

    test('B-03 重配对（同码）⇒ 保留本机备注名并复用已存盐', () async {
      await store.addPaired(PairedEndpoint(
        deviceId: ctrlId,
        name: '控制端A',
        secret: ctrlCode,
        pairedAt: DateTime(2024, 1, 1),
        alias: '爸妈的手机',
      ));

      await svc.debugDispatch(
          cmd(RcCmd.pairRequest, {
            'deviceId': ctrlId,
            'code': ctrlCode,
            'name': '对端自称的新名字',
          }),
          peerOf(ctrlId, '控制端A', ctrlCode));

      expect(
          await hasLog('pair.request', 'success', contains: '（重新确认）'), isTrue,
          reason: '同码重配对是合法路径（对端重装），必须成功');
      final kept = store.paired().firstWhere((p) => p.deviceId == ctrlId);
      expect(kept.alias, '爸妈的手机',
          reason: '★ 备注是本机数据 —— 对端重装不能抹掉本机给它起的名字');
      expect(salts.saltFor(ctrlId), isNotNull,
          reason: '重配对后必须**已有**存盐（复用而非每次新生成，'
              '否则双向密钥不一致 ⇒ 静默失联）');
    });

    test('B-04 presetList：按「预置/」标签解析分类，并真的把密文发出去', () async {
      await db.db.insert('audio_assets', {
        'id': 'a1',
        'name': '闹钟',
        'path': '/tmp/a1.wav',
        'duration_ms': 1000,
        'size_bytes': 10,
        'tags': '["预置/闹钟","环境音"]',
        'weight': 1.0,
        'created_at': 1,
      });
      // 一条**非 JSON** 的历史脏标签：解析必须跳过而不是整条崩溃。
      await db.db.insert('audio_assets', {
        'id': 'a2',
        'name': '脏数据',
        'path': '/tmp/a2.wav',
        'duration_ms': 1000,
        'size_bytes': 10,
        'tags': '预置/未加引号',
        'weight': 1.0,
        'created_at': 2,
      });

      final peer = peerOf(ctrlId, '控制端A', ctrlCode);
      await store.addPaired(peer);
      final fake = FakeMqttServerClient('broker.bi.invalid', ownId);
      svc.debugClientFactory = (b, c, p) => fake;
      await svc.start(store, db);

      await svc.debugDispatch(cmd(RcCmd.presetList), peer);

      expect(fake.sentWires, isNotEmpty,
          reason: '预置分类是**响应式回执** —— 不发出去，控制端的分类下拉永远是空的');
      final out = fake.sentWires.last;
      final key = await RcCodec.deriveKey(ctrlCode, '$ctrlId|evt');
      final back = await RcCodec.decode(out.wire, key, out.topic);
      expect(back, isNotNull, reason: '发出去的必须是能按对端身份解开的真密文');
      expect(back!.type, RcEvt.presets);
      expect(back.payload['categories'], equals(['闹钟']),
          reason: '★ 标签里的「预置/」前缀必须被剥掉成分类名；'
              '脏标签（非 JSON）必须被跳过且不影响正常分类');
    });

    test('B-05 sound.play 点名分类 ⇒ 走内置预置查询并真的起播', () async {
      await db.db.insert('audio_assets', {
        'id': 'a1',
        'name': '闹钟',
        'path': '/tmp/alarm.wav',
        'duration_ms': 1000,
        'size_bytes': 10,
        'tags': '["预置/闹钟"]',
        'weight': 1.0,
        'created_at': 1,
      });
      final played = <String>[];
      svc.playHandler = (path, vol, dur, {bool loop = false}) async {
        played.add(path);
        return true;
      };
      // ⚠️ 刻意**不**注入 resolvePresetHandler ⇒ 必须走内置 DB 查询。

      await svc.debugDispatch(
          cmd(RcCmd.soundPlay, {'category': '闹钟'}), peerOf(ctrlId, '控制端A', ctrlCode));

      expect(played, equals(['/tmp/alarm.wav']),
          reason: '★ 未注入替身时，"点名了分类"必须落到内置查询并起播 ——'
              '静默回落成"随便放一条"就是 BUG-048 的同一形状');
      expect(await hasLog('play', 'success'), isTrue);
    });

    test('B-06 指令组 play 步点名不存在的分类 ⇒ 如实回 skipped 并说明原因', () async {
      const s = RcScript(
        scriptId: 'bi-sc-1',
        name: '宏',
        fromName: '控制器',
        sentAt: 1700000000000,
        steps: [
          RcStep(RcStepKind.play, {'presetCategory': '不存在的分类'}),
        ],
      );

      await svc.debugDispatch(cmd(RcCmd.scriptRun, s.toJson()),
          peerOf(ctrlId, '控制端A', ctrlCode));
      for (var i = 0; i < 60 && RcScriptExecutor.instance.isRunning; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(
          await hasLog('script.run', 'skipped',
              contains: '端点无「不存在的分类」分类的音源'),
          isTrue,
          reason: '★ 对端点要"播放"而端点点名的分类没有音源 ——'
              '必须随终态回传说明，不得静默跳过（R-4②）');
    });

    test('B-07 协助会话区：采集类任务的 runNow / toggle 被动作级权限裁决拦下', () async {
      final now = DateTime(2024, 1, 1);
      await TaskRepository(db).upsert(Task(
        id: 'bi-rec-1',
        name: '取证任务',
        enabled: false,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 10)),
        actionType: ActionType.recordEvidence,
        action: const RecordEvidenceAction(seconds: 5),
        assetIds: const [],
        cooldownSec: 300,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: now,
        updatedAt: now,
      ));
      final peer = peerOf(ctrlId, '协助控制端', '');
      // 协助会话的业务命令永远跑在 `assistReplyZone` 里（`RcAssistHost._onBusiness`
      // 用 `runZoned` 注入）；本会话未建立 ⇒ 权限位 = none ⇒ 采集类动作必须被拒。
      Future<void> inAssistZone(Future<void> Function() body) =>
          runZoned(body, zoneValues: {assistReplyZone: true});

      await inAssistZone(() async {
        await svc.debugDispatch(
            cmd(RcCmd.taskRunNow, {'taskId': 'bi-rec-1'}), peer);
      });
      expect(
          await hasLog('task.runNow', 'skipped', contains: '任务动作需要权限'),
          isTrue,
          reason: '★ 命令级只映射到 script 位 —— 不做动作级裁决，'
              '只放行 script 位的协助方就能触发录音（采集红线）');

      await inAssistZone(() async {
        await svc.debugDispatch(
            cmd(RcCmd.taskToggle, {'taskId': 'bi-rec-1', 'enabled': true}),
            peer);
      });
      expect(await hasLog('task.toggle', 'skipped', contains: '任务动作需要权限'),
          isTrue);
      // 反例对照：**关闭**任务永远放行（安全的一侧不得被权限卡住）。
      await inAssistZone(() async {
        await svc.debugDispatch(
            cmd(RcCmd.taskToggle, {'taskId': 'bi-rec-1', 'enabled': false}),
            peer);
      });
      expect(await hasLog('task.toggle', 'success'), isTrue,
          reason: '关掉是更安全的一侧 —— 因缺权限而拒绝关闭会把越权打开的任务锁死');
    });

    test('B-08 call.invite 分发臂：通知 + 振铃 + 回 ringing，且不自动接通', () async {
      await store.addPaired(peerOf(ctrlId, '控制端A', ctrlCode));
      // 「自动接通」默认关闭（本用例刻意不打开）—— BUG-056：开关关掉**绝不能**自动接通。
      expect(CallService.instance.inCall, isFalse);

      final peer = peerOf(ctrlId, '控制端A', ctrlCode);
      await svc.debugDispatch(
          cmd(RcCmd.callInvite, {
            'callId': 'bi-call-1',
            'video': true,
            'fromName': '客厅平板',
          }),
          peer);

      expect(CallService.instance.currentPhase, CallPhase.ringing,
          reason: '开关关闭 ⇒ 只能振铃；自动接通等于麦/摄像头被静默打开');
      expect(CallService.instance.peerDeviceId, ctrlId);

      // 其余三条通话信令分发臂（answer / candidate / end）都必须走到。
      await svc.debugDispatch(
          cmd(RcCmd.callAnswer, {'callId': 'bi-call-1'}), peer);
      await svc.debugDispatch(
          cmd(RcCmd.callCandidate, {
            'callId': 'bi-call-1',
            'candidate': {'candidate': 'candidate:1 1 udp 1 127.0.0.1 1 typ host'},
          }),
          peer);
      await svc.debugDispatch(cmd(RcCmd.callEnd, {'reason': 'remoteEnd'}), peer);

      expect(CallService.instance.inCall, isFalse,
          reason: 'call.end 必须收尾 —— 留在振铃态会让下一通来电被判为占线');
    });
  });
}
