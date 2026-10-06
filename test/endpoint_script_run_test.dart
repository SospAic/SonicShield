/// `RcEndpointService._runScript`（远程指令组执行）的**行为**驱动 —— 第四十四轮新建。
///
/// ## 为什么这是一个"有测试文件却从没被执行过"的整块
///
/// `script.run` 此前只被 `test/endpoint_script_skipped_test.dart` 的**源码锁**
/// （RSS-04…RSS-10：`methodBody` + 文本断言）与 `test/endpoint_script_step_perm_test.dart`
/// 的**纯函数**覆盖。于是：
///
/// - `runner(RcStep)` 的 `switch (step.kind)` **九个分支一条都没跑过**；
/// - `_runVibrateStep` 三条路由（legacyFixed / actionHandler / skip）没跑过；
/// - 终态载荷 `rcScriptStatePayload(...)` 只在纯函数层被断言，**没有一条真实
///   指令组走到过它**。
///
/// 这正是第 40/41 轮判据第四问的形状：**"契约层被锁住" ≠ "这条业务路径被执行过"**。
///
/// ## 驱动方式（不伪造任何生产逻辑）
///
/// 入站链路 `_handleRaw → _dispatch` 的生产唯一调用者是真实 MQTT 监听器；
/// 本文件用既有的 `@visibleForTesting` 接缝 `debugBind` + `debugDispatch`
/// （第 36 轮续四新增，见 `endpoint_service.dart` 顶部）直接喂入站命令，
/// 与 `deep_endpoint_dispatch_test.dart` 同源。
///
/// handler 一律注入**可观测替身**（记录收到的参数），断言真实副作用：
/// 审计行真的落库、替身真的收到那组参数。
///
/// ## 本条边界（明确不测什么）
///
/// - **不测** `record` 步：它要 `path_provider` + `record` 单例（`late final`
///   + zone 绑定，见 `docs/12 §75.4`），属另一条独立夹具，本轮不并入。
/// - **不测** 出站回执/终态事件的内容：宿主无 MQTT 客户端，`_send` 是
///   安全 no-op（`_client == null`）⇒ 终态只能经**审计行**观测。
///
/// 每例上限 120s：几处 `delay` 步是**真实**等待（本文件不用 fake-async），
/// 正常 3s 内跑完；给上限是为了让"万一挂死"快速暴露，而不是等默认的 10 分钟。
@Timeout(Duration(seconds: 120))
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/remote/script_executor.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

/// 通知插件通道名（`NotificationService` 与 `RcScriptExecutor` 共用）。
const _notifChannel = 'dexterous.com/flutter/local_notifications';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final svc = RcEndpointService.instance;
  late AppDatabase db;
  late RemoteStore store;
  late PairedEndpoint peer;

  /// 被投递给通知插件的 `show` 参数（断言"通知真的发了"）。
  late List<Object?> shown;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    shown = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_notifChannel), (call) async {
      if (call.method == 'show') shown.add(call.arguments);
      // `initialize` 的平台层返回 bool（非 bool?）⇒ 桩返回 null 会炸
      // `Null is not a subtype of FutureOr<bool>`（第四十四轮实测）。
      return call.method == 'initialize' ? true : null;
    });
    db = await AppDatabase.open(inMemoryDatabasePath);
    store = RemoteStore(await SharedPreferences.getInstance());
    svc.debugBind(store: store, db: db);
    peer = PairedEndpoint(
      deviceId: 'CTRL0001abcdef',
      name: '测试控制端',
      secret: 'CODE0001',
      pairedAt: DateTime(2024, 1, 1),
    );
  });

  tearDown(() async {
    // 单例上的注入能力必须清干净，否则污染后续用例（它是全局单例）。
    svc.playHandler = null;
    svc.resolvePresetHandler = null;
    svc.ttsHandler = null;
    svc.vibrateHandler = null;
    svc.vibrateActionHandler = null;
    RcScriptExecutor.instance.stop();
    try {
      await db.close();
    } on Object {
      // 忽略：在飞的终态通知计时器可能已把库关掉。
    }
  });

  RcScript script(List<RcStep> steps, {String id = 'sc-1', String name = '宏'}) =>
      RcScript(
        scriptId: id,
        name: name,
        fromName: '控制器',
        sentAt: 1700000000000,
        steps: steps,
      );

  RcMessage runCmd(RcScript s) => RcMessage.now(RcCmd.scriptRun, s.toJson());

  Future<List<Map<String, Object?>>> logs() => LogRepository(db).recent(limit: 100);

  Future<bool> hasLog(String action, String status, {String? contains}) async {
    final rows = await logs();
    return rows.any((r) {
      if (r['action'] != action || r['status'] != status) return false;
      final m = r['message'] as String? ?? '';
      return contains == null || m.contains(contains);
    });
  }

  /// 等 `RcScriptExecutor` 的收尾定时器（3s 清通知）与终态逻辑落定，
  /// 否则下一条用例可能遇到"上一次仍在跑"（单例 `_current` 未清）。
  Future<void> settle() async {
    for (var i = 0; i < 80 && RcScriptExecutor.instance.isRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  // ─────────────────────────────── 主链路 ───────────────────────────────

  group('ESR 指令组主链路（delay / notify / 终态）', () {
    test('ESR-01 delay + notify 真实执行 → script.run 写 success 审计', () async {
      await svc.debugDispatch(
        runCmd(script([
          const RcStep(RcStepKind.delay, {'seconds': 0.5}),
          const RcStep(RcStepKind.notify, {'title': '心跳', 'body': 'B'}),
        ])),
        peer,
      );
      await settle();

      expect(await hasLog('script.run', 'success'), isTrue,
          reason: '走完全程必须留一条 success 审计（含发送方与步数）');
      // notify 步真的把标题交给通知系统（不是"执行了但什么都没发"）。
      final titles = shown
          .whereType<Map<Object?, Object?>>()
          .map((a) => a['title']?.toString() ?? '')
          .toList();
      expect(titles.any((t) => t.contains('心跳')), isTrue,
          reason: 'notify 步的标题必须真的投给通知插件');
    });

    test('ESR-02 步数非法（空指令组）→ 显式拒绝且不写 success', () async {
      await svc.debugDispatch(runCmd(script(const [])), peer);
      await settle();

      expect(await hasLog('script.run', 'success'), isFalse,
          reason: '校验失败不得留下 success 审计');
    });
  });

  // ─────────────────────────── play / tts 两条"没做成" ───────────────────────────

  group('ESR play 步：无音源要留痕、有音源要真起播', () {
    test('ESR-03 端点音源库为空 → 落 skipped 审计（不是静默跳过）', () async {
      await svc.debugDispatch(
        runCmd(script([const RcStep(RcStepKind.play, {})])),
        peer,
      );
      await settle();

      expect(await hasLog('script.run', 'skipped', contains: '（play）未执行'),
          isTrue,
          reason: '对端要"播放"，端点什么都没放 —— 必须写清楚为什么（R-4②）');
      expect(await hasLog('script.run', 'skipped', contains: '端点音源库为空'),
          isTrue);
    });

    test('ESR-04 注入能力后 play 真的起播，且音量/时长被夹紧后传下去', () async {
      final calls = <({String path, double vol, int dur, bool loop})>[];
      svc.resolvePresetHandler = (c) async => '/tmp/nature.wav';
      svc.playHandler = (path, vol, dur, {bool loop = false}) async {
        calls.add((path: path, vol: vol, dur: dur, loop: loop));
        return true;
      };

      await svc.debugDispatch(
        runCmd(script([
          const RcStep(RcStepKind.play, {
            'presetCategory': 'nature',
            'volume': 4.0, // 越界：必须夹到 1.0
            'durationSec': 3,
          }),
        ])),
        peer,
      );
      await settle();

      expect(calls.length, 1);
      expect(calls.single.path, '/tmp/nature.wav');
      expect(calls.single.vol, 1.0, reason: 'volume 必须夹到 [0,1]（对端不得要 400%）');
      expect(calls.single.dur, 3000);
      expect(calls.single.loop, isFalse);
      expect(await hasLog('script.run', 'skipped', contains: '（play）'), isFalse,
          reason: '真的起播了就不该有 skipped 记录');
    });
  });

  group('ESR tts 步', () {
    test('ESR-05 未装配语音能力 → skipped 且原因可读', () async {
      await svc.debugDispatch(
        runCmd(script([const RcStep(RcStepKind.tts, {'text': '你好'})])),
        peer,
      );
      await settle();

      expect(await hasLog('script.run', 'skipped', contains: '（tts）未执行'),
          isTrue);
      expect(await hasLog('script.run', 'skipped', contains: '端点未装配语音播报能力'),
          isTrue);
    });

    test('ESR-06 装配后文本、音量与音色原样交给能力层', () async {
      final spoken = <({String text, double vol, String voice})>[];
      svc.ttsHandler = (text, vol, {String voiceId = ''}) async =>
          spoken.add((text: text, vol: vol, voice: voiceId));

      await svc.debugDispatch(
        runCmd(script([
          const RcStep(RcStepKind.tts, {
            'text': '把门窗关好',
            'volume': 0.6,
            'voiceId': 'az_db_male_yunbiao',
          }),
        ])),
        peer,
      );
      await settle();

      expect(spoken.single.text, '把门窗关好');
      expect(spoken.single.vol, 0.6);
      expect(spoken.single.voice, 'az_db_male_yunbiao');
    });

    test('ESR-06b 未带音色 id 时交给能力层的是空串（由音色目录回落默认）', () async {
      final spoken = <String>[];
      svc.ttsHandler = (text, vol, {String voiceId = ''}) async =>
          spoken.add(voiceId);

      await svc.debugDispatch(
        runCmd(script([const RcStep(RcStepKind.tts, {'text': '你好'})])),
        peer,
      );
      await settle();

      expect(spoken.single, isEmpty);
    });
  });

  // ─────────────────────────── 振动步三条路由 ───────────────────────────

  group('ESR 振动步路由（不得静默降级到固定节奏）', () {
    test('ESR-07 fixed 且无处理器 → skip 路由 + 写明"未注入振动处理器"', () async {
      await svc.debugDispatch(
        runCmd(script([const RcStep(RcStepKind.vibrate, {})])),
        peer,
      );
      await settle();

      expect(
          await hasLog('script.run', 'skipped', contains: '端点未注入振动处理器'),
          isTrue);
    });

    test('ESR-08 fixed + legacyHandler → 走老路径并收到节奏图案', () async {
      final patterns = <List<int>>[];
      svc.vibrateHandler = (p) async => patterns.add(p);

      await svc.debugDispatch(
        runCmd(script([const RcStep(RcStepKind.vibrate, {'mode': 'fixed'})])),
        peer,
      );
      await settle();

      expect(patterns.length, 1);
      expect(patterns.single, isNotEmpty);
      expect(patterns.single.first, 0, reason: '固定节奏图案以 0ms 起振');
    });

    test('ESR-09 random + actionHandler：成功/失败都由**能力层结果**决定，并带 occurrenceId',
        () async {
      final seen = <({ActionConfig action, String occ, bool ok})>[];
      svc.vibrateActionHandler = ({required ActionConfig action, required String occurrenceId}) async {
        seen.add((action: action, occ: occurrenceId, ok: false));
        return const RunNowResult(ok: false, message: '引擎未运行');
      };

      await svc.debugDispatch(
        runCmd(script([
          const RcStep(RcStepKind.vibrate, {
            'mode': 'random',
            'durationSecMax': 5,
            'amplitudeMin': 0.3,
            'amplitudeMax': 0.8,
          }),
        ])),
        peer,
      );
      await settle();

      expect(seen.length, 1);
      expect(seen.single.occ, 'rcscript:sc-1:0',
          reason: '波动种子必须能复现：同一次执行 → 同一条曲线');
      // 能力层说失败 ⇒ 审计必须是 skipped，并写清原因（不能报 success）。
      expect(await hasLog('script.run', 'skipped', contains: '引擎未运行'), isTrue);
      expect(await hasLog('script.run', 'success', contains: '引擎未运行'), isFalse);
    });

    test('ESR-10 random 但 actionHandler 未接线 → 也走 skip，绝不退回固定节奏',
        () async {
      final patterns = <List<int>>[];
      svc.vibrateHandler = (p) async => patterns.add(p); // 只装老路径

      await svc.debugDispatch(
        runCmd(script([
          const RcStep(RcStepKind.vibrate, {
            'mode': 'continuous',
            'durationSecMax': 3,
          }),
        ])),
        peer,
      );
      await settle();

      expect(patterns, isEmpty,
          reason: '对端要"持续振动"，端点震两下就完事 = 承诺了没做到（BUG-059 通则）');
      expect(
          await hasLog('script.run', 'skipped', contains: '未接线参数化振动'),
          isTrue);
    });
  });

  // ─────────────────────────── 并发与终止 ───────────────────────────

  group('ESR 一次一组 / 终止', () {
    test('ESR-11 已有指令组在执行 → 第二条被拒并如实记账（不得报 stopped 也不得报 success）',
        () async {
      final notified = <String>[];
      svc.vibrateHandler = (p) async => notified.add('v');

      // 第一条挂住：delay 步要跑 2 秒。
      final first = svc.debugDispatch(
        runCmd(script([
          const RcStep(RcStepKind.delay, {'seconds': 2}),
          const RcStep(RcStepKind.vibrate, {}),
        ], id: 'sc-long')),
        peer,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await svc.debugDispatch(
        runCmd(script([const RcStep(RcStepKind.vibrate, {})], id: 'sc-2')),
        peer,
      );

      expect(await hasLog('script.run', 'skipped', contains: '已有指令组在执行'), isTrue,
          reason: '第二条必须被明确拒绝（旧实现会先写一条 success 审计再说谎）');
      expect(RcScriptExecutor.instance.currentScriptId, 'sc-long',
          reason: '在跑的那一组不得被第二条顶掉');

      await first;
      await settle();

      expect(await hasLog('script.run', 'success', contains: '控制器 · 宏'), isTrue,
          reason: '第一条仍须正常跑完并留痕');
    });

    test('ESR-12 script.stop 终止在途指令组 → 后续步骤不再执行', () async {
      var vibrated = 0;
      svc.vibrateHandler = (p) async => vibrated++;

      final running = svc.debugDispatch(
        runCmd(script([
          const RcStep(RcStepKind.delay, {'seconds': 5}),
          const RcStep(RcStepKind.vibrate, {}),
        ], id: 'sc-stop')),
        peer,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await svc.debugDispatch(
        RcMessage.now(RcCmd.scriptStop, {'scriptId': 'sc-stop'}),
        peer,
      );
      await running;
      await settle();

      expect(vibrated, 0, reason: '被终止后 delay 之后的步骤不得再执行');
      expect(await hasLog('script.stop', 'success'), isTrue);
    });
  });

  // ─────────────────── 远程 vibrate.start（_startVibrate） ───────────────────

  group('ESR vibrate.start 远程命令（_startVibrate 生产路径）', () {
    test('ESR-13 handler 已接线：固定振动夹紧后交给引擎，成功由结果决定', () async {
      final seen = <({ActionConfig action, String occ})>[];
      svc.vibrateActionHandler = (
          {required ActionConfig action, required String occurrenceId}) async {
        seen.add((action: action, occ: occurrenceId));
        return const RunNowResult(ok: true, message: '引擎已接受');
      };

      final m = RcMessage.now(RcCmd.vibrateStart, {
        'mode': 'fixed',
        'durationSec': 5,
        'intensity': 0.6,
      });
      await svc.debugDispatch(m, peer);
      await settle();

      expect(seen, hasLength(1),
          reason: 'vibrate.start 必须走参数化振动处理器，不能退化成"震两下"');
      expect(seen.single.occ, 'rcvibrate:${m.id}',
          reason: 'occurrenceId 必须按消息 id 唯一，便于审计与回溯');
      expect(await hasLog('vibrate.start', 'success'), isTrue,
          reason: '引擎接受 ⇒ 必须写 success 审计并回 ok=true');
    });

    test('ESR-14 handler 报失败 → 审计 failed，绝不谎报成功', () async {
      svc.vibrateActionHandler = (
          {required ActionConfig action, required String occurrenceId}) async =>
          const RunNowResult(ok: false, message: '引擎未运行');

      await svc.debugDispatch(
        RcMessage.now(RcCmd.vibrateStart, {
          'mode': 'random',
          'durationSecMax': 5,
          'amplitudeMin': 0.3,
          'amplitudeMax': 0.9,
        }),
        peer,
      );
      await settle();

      expect(
          await hasLog('vibrate.start', 'failed', contains: '引擎未运行'), isTrue);
      expect(await hasLog('vibrate.start', 'success'), isFalse,
          reason: '能力层说失败时不得留下 success（承诺了没做到）');
    });

    test('ESR-15 handler 未接线 → 如实 skipped，绝不退回固定节奏', () async {
      // tearDown 已清空处理器；这里显式再确认，避免单例残留。
      svc.vibrateActionHandler = null;
      svc.vibrateHandler = (p) async => fail('不得退回老路径震两下就完事');

      await svc.debugDispatch(
        RcMessage.now(RcCmd.vibrateStart, {'mode': 'continuous'}),
        peer,
      );
      await settle();

      expect(
          await hasLog('vibrate.start', 'skipped', contains: '端点未接线参数化振动'),
          isTrue,
          reason: '端点没接线参数化振动时必须如实 skipped（ok=false），'
              '而不是退化成固定节奏"敷衍一下"');
      expect(await hasLog('vibrate.start', 'success'), isFalse);
    });
  });
}
