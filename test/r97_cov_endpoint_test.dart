/// 第九十七轮：`lib/remote/**` 覆盖率长尾补测（「按文件补完」第 1 组）。
///
/// ## 目标行（R96 lcov 实测未覆盖，共 18 行）
///
/// - `endpoint_service.dart`：2843 / 2856 / 2876 / 2883 / 3030 / 3031 /
///   3130 / 3134 / 3135 / 3679 / 3954 / 3955 / 3956；
/// - `protocol.dart`：419 / 677；`assist.dart`：191；`assist_join.dart`：353；
///   `credential_sealer.dart`：42。
///
/// ## 本文件只装**真能驱动到**的行
///
/// 覆盖：`assist.dart:191`、`endpoint_service.dart:2876 / 2883`。
///
/// 其余 15 行**结构不可达**，逐行理由见文件末尾「R97 不可达清单」，并用
/// `R97-EP-02/03/04` 三条**证据用例**把"为什么到不了"钉成行为断言
/// （折叠成 null 的通道 / 封顶的限流表 / 同参解密的两次调用）。
/// 刻意不写 `expect(true)` 式的假覆盖 —— 那只会把死代码藏得更深。
///
/// ## 驱动方式（与 r96 同源，不新造 harness）
///
/// - `RcEndpointService.instance` + `debugBind` + `debugDispatch`
///   （等价于"解密 / 准入 / 限流均已通过"之后的那一步）；
/// - 数据库：`sqflite_common_ffi` 内存库；偏好：`SharedPreferences` 桩；
/// - 播放器：`PlaybackService` 子类覆写 `stop()`（与
///   `test/cov_services_test.dart` 的 `_StopCountingPlayer` 同款 ——
///   `stopAllPlaying` 走动态派发，因此不依赖任何音频插件）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/native_bridge.dart';
import 'package:sonic_shield/services/playback_service.dart';

/// 在隔离区里必然失败的任务（顶层函数 ⇒ 一定可发送到子隔离区）。
///
/// 用它而不是内联闭包：闭包只要捕获了任何东西就**不可发送**，
/// `Isolate.run` 会在**派生阶段**就失败 —— 那样测到的不是"业务体抛错"。
Future<void> _boomInIsolate() async => throw StateError('cov97 isolate boom');

/// `stop()` 必抛的播放器替身。
///
/// 用 `extends` 而非 `implements`：只需覆写要观测的那一个方法，
/// 基类新增成员也不会让本文件编译失败（与 `cov_services_test.dart:845` 同款）。
class _ThrowingStopPlayer extends PlaybackService {
  @override
  Future<void> stop() async => throw StateError('cov97 stop boom');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const ownId = 'EP97own0000000ab';
  const ctrlId = 'CTRL97peer000001';
  const nativeChannel = 'sonic_shield/native';

  final svc = RcEndpointService.instance;

  late SharedPreferences prefs;
  late RemoteStore store;
  late AppDatabase db;
  late PairedEndpoint peer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = RemoteStore(prefs);
    await store.setIdentity(ownId, '端点机97');
    db = await AppDatabase.open(inMemoryDatabasePath);
    peer = PairedEndpoint(
      deviceId: ctrlId,
      name: '控制端97',
      secret: 'CODE9701',
      pairedAt: DateTime(2024, 1, 1),
    );
    await store.addPaired(peer);
    svc.debugBind(store: store, db: db);
  });

  tearDown(() async {
    PlaybackService.resetRegistryForTest();
    NativeBridge.lastNativeError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(nativeChannel), null);
    try {
      await db.close();
    } on Object {
      // 已关闭 / 句柄滞后：本文件不依赖库的存活状态。
    }
  });

  Future<List<Map<String, Object?>>> logs() =>
      LogRepository(db).recent(limit: 200);

  // ══════════════════════════════════════ A · assist：隔离区回退臂

  group('R97-A 协助凭据派生', () {
    test('R97-AS-01 隔离区失败 ⇒ 回退主隔离区重算，错误原样抛出（assist:191）',
        () async {
      // 生产契约（assist.dart:184-192）：低端机 / 沙箱里 `Isolate.run` 可能
      // 直接失败；此时退回主隔离区算一遍 —— 慢，但**不挂死、不吞错**。
      // 业务体本身抛错时，异常必须原样穿出（而不是被折叠成"派生失败"）。
      await expectLater(
        RcAssist.offThread<void>(_boomInIsolate),
        throwsA(isA<StateError>()),
        reason: '★ 回退臂执行后错误必须原样上抛（191 = `return await body();`）',
      );
    });
  });

  // ══════════════════════════════════════ B · 端点：停止类命令的失败腿

  group('R97-B 端点停止类命令', () {
    test('R97-EP-01 sound.stop：停止请求抛错 ⇒ 如实回 ok=false（2876 / 2883）',
        () async {
      PlaybackService.resetRegistryForTest();

      // 把"一停就炸"的实例登记进静态在播表。
      // `openPttStream()` 的构造体**同步**登记（无 await），因此登记状态能
      // 一直保持到本用例结束 —— 不会像 `play()` 那样在失败路径的 finally 里
      // 把自己摘掉（那会让本用例变成随机红）。
      // 构造 `AudioPlayer()` 时 just_audio 会尝试初始化平台；那一路的失败与
      // 本用例无关（与 `test/cov_services_test.dart` 的 `_quarantine` 同款处置）。
      final bad = _ThrowingStopPlayer();
      runZonedGuarded<void>(() {
        bad.openPttStream();
      }, (e, st) {});
      expect(PlaybackService.anyPlaying, isTrue,
          reason: '前置：登记表必须非空，否则走的是 stopped=0 的成功腿');

      await svc.debugDispatch(
          RcMessage.now(RcCmd.soundStop, const {}, ctrlId), peer);

      final rows = (await logs()).where((r) => r['action'] == 'sound.stop');
      expect(rows, hasLength(1), reason: '一条 sound.stop 只写一条审计');
      final row = rows.single;
      expect(row['status'], 'failed',
          reason: '★ 停止请求抛错时**不得**记 success（"点了停却还在响"的静默形状）');
      final message = (row['message'] as String? ?? '').replaceAll('\r\n', '\n');
      expect(message, contains('stopped=0'));
      expect(message, contains('cov97 stop boom'),
          reason: '2883 的失败原因插值必须写出来（why 非空的那条腿）');
    });
  });

  // ══════════════════════════════════════ C · 不可达行的证据

  group('R97-C 不可达行的证据', () {
    test('R97-EP-02 NativeBridge 把平台异常折叠成 null ⇒ 2843 / 2856 不可达',
        () async {
      // endpoint_service.dart:2839-2844 的原生失败腿要求
      // `NativeBridge.vibrateStop()` **抛出**。而 native_bridge.dart:59-77
      // 的 `_invoke` 对 PlatformException / MissingPluginException / Object
      // **一律 return null** ⇒ 该 await 永不抛 ⇒ nativeOk 恒为 true。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(nativeChannel),
              (call) async {
        throw PlatformException(code: 'VIBRATE_DENIED', message: 'no vibrator');
      });

      NativeBridge.lastNativeError = null;
      await NativeBridge.vibrateStop(); // 不抛
      expect(NativeBridge.lastNativeError, isA<PlatformException>(),
          reason: '错误只被**记住**（NAT-13），没有被抛出 —— 这正是 2843 的死因');
    });

    test('R97-EP-03 限流把窗口内条数封在 30 ⇒ 3679 的 200 条硬上限不可达', () {
      // endpoint_service.dart:1091-1097：**先**判限流，被拒的命令**不入表**；
      // 3677 的 removeWhere 与 1091 的 rateLimitFor 用的是**同一个** 60s 截止线。
      // 于是同一窗内表长 ≤ rcRateLimitMaxPerWindow(30) < 200 ⇒ 3678 的
      // `while (list.length > 200)` 恒假。
      const now = 1700000000000;
      final ts = <int>[
        for (var i = 0; i < rcRateLimitMaxPerWindow; i++) now - i,
      ];
      final verdict = rateLimitFor('dev97', now, ts);
      expect(verdict.allowed, isFalse, reason: '第 31 条必须被拒（调用方据此不入表）');
      expect(verdict.retryAfterMs, greaterThan(0));
      expect(rcRateLimitMaxPerWindow, lessThan(maxCmdTsPerEndpoint),
          reason: '配额 < 硬上限 ⇒ 裁剪臂在单 isolate 正常时钟下不可达');
    });

    test('R97-EP-04 peek 与 prepare 同参解密 ⇒ 3954-3956 不可达', () async {
      // flushOutbox 先在 3942 `peekOutboxType` 拿类型，再在 3951
      // `prepareOutboxReplay` 重编码；两者对 `RcCodec.decode` 的入参**完全相同**
      // （同 key / 同 topic / 同 3650 天窗口 / 同候选 key）。
      // 因此"peek 成功但 prepare 返回 null"不可能发生；而 peek 失败时
      // 3944 的判据已把它判成 undecodable，在 3946 就丢弃 —— 走不到 3953。
      final key = RcCodec.newPeerKey();
      const topic = 'sonicshield/v1/$ctrlId/cmd';
      const ctx = '$ctrlId|cmd';
      final wire = await RcCodec.encode(
        RcMessage.now(RcCmd.ping, const {'n': 97}, ownId),
        const <int>[],
        topic,
        peerKey: key,
        peerContext: ctx,
      );

      expect(
          await peekOutboxType(wire, const <int>[], topic,
              peerKey: key, peerContext: ctx),
          RcCmd.ping);
      expect(
          await prepareOutboxReplay(wire, const <int>[], topic,
              peerKey: key, peerContext: ctx),
          isNotNull,
          reason: '★ peek 能解 ⇒ prepare 必能解（同一段解密参数）');

      expect(
          await peekOutboxType('not-a-wire', const <int>[], topic,
              peerKey: key, peerContext: ctx),
          isNull);
      expect(
          decideOutboxReplay(type: null, expiresAt: null, nowMs: 0),
          RcOutboxReplay.undecodable,
          reason: '类型未知 ⇒ 判据直接给 undecodable，在 3946 分支就丢弃');
    });
  });
}

// ══════════════════════════════════════════════════════════════════════
// R97 不可达清单（逐行理由 + 证据；本文件**刻意不覆盖**这些行）
// ══════════════════════════════════════════════════════════════════════
//
// endpoint_service.dart
//   2843  `_stopVibrate` 原生 catch 的 `why = describeFailure(e)`
//         证据：唯一触发条件是 `NativeBridge.vibrateStop()` 抛出，而
//         native_bridge.dart:59-77 的 `_invoke` 把 PlatformException /
//         MissingPluginException / 其它 Object **全部** return null。
//         → 行为锁：R97-EP-02。
//   2856  `_ack(..., data: '原生振动器未受理停止请求…')`
//         证据：同上。`ok = nativeOk` 恒为 true ⇒ 三元永远走 `null` 腿。
//   2876  `_stopSound` 的 catch —— **已覆盖**（R97-EP-01）。
//   2883  `_stopSound` 审计里的 ` · $why` —— **已覆盖**（R97-EP-01）。
//   3030  `delay` 步 `cancel?.sleep(...) ?? Future<void>.delayed(...)` 的右腿
//   3031  同上的 Duration 实参
//         证据：runner 只由 `RcScriptExecutor.run` 调用（script_executor.dart:241），
//         而 `run` 在进入步骤循环**之前**已 `_cancel = RcCancel()`（:202），
//         仅在 `finally` 里置 null（:300-303）—— 即 runner 执行期间
//         `activeCancel` 恒非 null ⇒ `??` 右侧是死分支。
//   3130  `script.run` 的"执行器被占用"审计
//   3134  同上（message 续行）
//   3135  同上（`_ack(msg, false, data: '已有指令组在执行')`）
//         证据：`run()` 的**同步前缀**先 `if (isRunning) return false;`
//         （:197）再 `_current = script`（:198）。忙 ⇒ 旧 `_current` 非 null；
//         闲 ⇒ 新 `_current` 非 null。两条路 `isRunning` 都真，且
//         `run()` 调用与 `isRunning` 检查之间**没有 await**（:3119-3127）
//         ⇒ 3127 的 `if (!isRunning)` 恒假。
//   3679  `_rememberCmdTs` 的 `list.removeAt(0)` 硬上限裁剪
//         证据：入表只发生在限流放行之后（:1091-1097），窗内配额 30 < 200，
//         且 removeWhere 的截止线与 rateLimitFor 相同 ⇒ 表长到不了 200。
//         → 行为锁：R97-EP-03。
//   3954  `flushOutbox` 的 `reEnc == null` 丢弃
//   3955  同上（审计调用）
//   3956  同上（续行）
//         证据：peek（:4908-4920）与 prepare（:4401-4424）对
//         `RcCodec.decode` 的入参逐项相同；peek 失败时 3944 的判据返回
//         undecodable，在 3946 已 continue。→ 行为锁：R97-EP-04。
//
// protocol.dart
//   419   `RcCodec._();` —— `final class` + 私有构造 + 全静态成员，
//         库外无法调用，库内无一处实例化（`RcCodec(` 全仓 0 处调用）。
//   677   `rotatedPairingCode` 的 `while` 重试体 —— 需要 `Random.secure()`
//         连出与旧码**逐字符相同**的 8 位 Base32（1/32^8 ≈ 1/10^12），
//         无法确定性驱动；随机源不可注入。
//
// assist.dart
//   191   `offThread` 的 catch 回退 —— **已覆盖**（R97-AS-01）。
//
// assist_join.dart
//   353   `send()` 的 `_publish == false` 记录臂 —— 需要"phase 非 closed、
//         topic 非空，但 transport 或 ctlKey 为 null"。但 `_topic` 与
//         `_ctlKey` 在 join 的同一段同步区里成对赋值（:230-233，先于
//         `_phase = opening`），在 leave 里成对清空并置 closed（:299-313）；
//         `_transport` 只由 `bind()`（:189）赋值，**永不为 null**。
//         故 send() 的守卫（:343）放行时三者必全非 null。
//
// credential_sealer.dart
//   42    `CredentialSealer._();` —— 同上（私有构造 + 全静态），无实例化点。
