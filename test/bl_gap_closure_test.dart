import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/features/remote/ptt_tab.dart';
import 'package:sonic_shield/remote/controller_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/permission_stub.dart';
import 'support/record_stub.dart';

/// 第六十二轮：**覆盖率冲刺（第五轮）** —— 只撬既有未覆盖分支，`lib/**` 一字未动。
///
/// ## 本文件为什么单独一个文件
///
/// 三条驱动都要求**进程内单例处于"干净"状态**：
/// * `RcControllerService.instance` 的 `AudioRecorder` 只在首次构造时 `create()`
///   一次（跨用例的完成时机见 `support/record_stub.dart` 第二层）；
/// * `RcEndpointService.instance` 的 `debugSendTo` 是**可变字段**，
///   别的文件每个用例都会替换它（`flutter test` 每文件独立 isolate ⇒ 这里是全新的）。
///
/// ## 覆盖到的分支
///
/// 1. **对讲机「按住 → 60 秒自动收尾」整条链**（`ptt_tab.dart` 的计时器回调
///    与 `_send()`）：此前只被驱动到"按住之前/权限被拒"两个前置判断，
///    计时与自动发送**一次都没执行过**；
/// 2. **端点回执 `rc.ptt` 的渲染**（BUG-046）：事件流此前没有行为级入口；
/// 3. **`pttStopAndSend` 的"已发出"一侧**（`controller_service.dart`）：
///    宿主连不上 broker ⇒ `sendTo` 恒 false，成功文案结构性不可达
///    ⇒ 用第 45 轮的 `debugSendTo` 缝驱动。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late RemoteStore store;
  late FakeRecordPlatform rec;

  final svc = RcEndpointService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = RemoteStore(await SharedPreferences.getInstance());
    db = await AppDatabase.open(inMemoryDatabasePath);
    svc.debugBind(store: store, db: db);
    svc.debugSendTo = null;
    // 平台层假实现：`hasPermission` 由用例给（这里的用例都要求"允许录音"）。
    rec = installFakeRecordPlatform(hasPermissionResult: true);
    // ★ `setUp` 跑在**真实 zone** ⇒ 这一次调用把 `_createFuture` 真正推完成，
    // 之后同进程所有录音调用都不会挂（见 `support/record_stub.dart` 第二层）。
    await RcControllerService.instance.pttCancel();
    rec.calls.clear();
  });

  tearDown(() async {
    restoreRecordPlatform();
    clearPermissionStub();
    svc.debugSendTo = null;
    try {
      await db.close();
    } on Object {
      // 在飞的终态定时器可能已把库关掉 —— 忽略。
    }
  });

  PairedEndpoint ep(String id, String name) => PairedEndpoint(
      deviceId: id, name: name, secret: 'AB2CD5EF', pairedAt: DateTime.now());

  Finder micButton() => find.ancestor(
      of: find.byIcon(Icons.mic), matching: find.byType(GestureDetector));

  Future<void> pumpPtt(WidgetTester tester,
      {List<PairedEndpoint> endpoints = const [],
      String selected = ''}) async {
    final prefs = await SharedPreferences.getInstance();
    final s = RemoteStore(prefs);
    for (final e in endpoints) {
      await s.addPaired(e);
    }
    if (selected.isNotEmpty) await s.setSelectedEndpoint(selected);

    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PttTab())));
    await tester.pumpAndSettle();
  }

  // ══════════════════════════════════════════════════════════════════
  // A · 对讲机整页：计时器 + 自动收尾（60 秒） + 回执渲染
  // ══════════════════════════════════════════════════════════════════

  group('BL-PTT 对讲机（计时 / 自动收尾 / 回执）', () {
    testWidgets(
        'BL-PTT-01 按住后满 60 秒 → 计时器自行收尾并如实报告，而不是一直占着麦克风',
        (tester) async {
      stubPermissions({Permission.microphone: PermissionStatus.granted});

      // `pttStopAndSend` 会 `File(path).exists()` —— 给一个**真实存在的**临时文件，
      // 让执行走到"时长判定"那一步（否则会停在"未录到音频"）。
      final f = File('${Directory.systemTemp.createTempSync('bl_ptt').path}/a.m4a')
        ..writeAsBytesSync(List<int>.filled(64, 7));
      rec.stopPath = f.path;

      await pumpPtt(tester,
          endpoints: [ep('0123456789abcdef', '客厅平板')],
          selected: '0123456789abcdef');

      // ★ 整条手势必须跑在 `runAsync` 里：
      //   ① `pttStart()` 里 `Directory.systemTemp.createTemp` 是**真实 dart:io**，
      //      fake-async 里永不完成；
      //   ② `Timer.periodic` 因此是**真实计时器**，只有一个真实秒才算一拍。
      // ⚠️ 60 秒这一拍之前**没有**任何 UI 出口能触发 `_send()` —— 这正是要补的分支。
      await tester.runAsync(() async {
        final g = await tester.startGesture(tester.getCenter(micButton()));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        // 计时器第 1 拍就已经把 `_recSec` 写进状态（顺带证明"计时中"文案会走）。
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        await Future<void>.delayed(const Duration(seconds: 59));
        await g.up();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      expect(rec.calls, contains('start'),
          reason: '按住必须真的开始录音，而不是只改界面状态');
      expect(rec.calls, contains('stop'),
          reason: '满 60 秒必须真的把录音通道关掉 —— 否则麦克风被一直占着');
      // 计时从 `pttStart()` 起算早于计时器建立 ⇒ 到点时时长必然**超过** 60 秒上限。
      expect(find.text('超过 60 秒上限'), findsOneWidget,
          reason: '超时必须如实说"超过 60 秒上限"，不能静默丢弃这段录音');
      expect(tester.takeException(), isNull);
    }, timeout: const Timeout(Duration(seconds: 180)));

    testWidgets('BL-PTT-02 端点回执 rc.ptt → 页面渲染播放结果（BUG-046）',
        (tester) async {
      const ownId = 'endpoint0000abcd';
      const ownCode = 'OWNCODE1';
      const peerId = 'CTRL0001abcdeff';
      // 接收侧的两个输入缺一不可：本机码（`debugSetOwnCode`）+ 本机 ID（落库）。
      svc.debugSetOwnCode(ownCode);
      await store.setIdentity(ownId, '声盾-endo');

      await pumpPtt(tester, endpoints: [ep(peerId, '客厅平板')]);

      // 造一条"从对端发来"的**已加密回执**：密钥模型与接收侧一致
      // （接收方自己的配对码 + `{本机ID}|evt`），走的是生产解密路径。
      const topic = 'sonicshield/v1/$peerId/evt';
      final key = await RcCodec.deriveKey(ownCode, '$ownId|evt');
      final wire = await RcCodec.encode(
          RcMessage.now(RcEvt.pttAck, {'voiceId': 'v-1', 'ok': true}),
          key,
          topic);

      await tester.runAsync(() async {
        await svc.debugHandleRaw(topic, wire);
      });
      await tester.pumpAndSettle();

      expect(find.text('对端已播放 ✓'), findsOneWidget,
          reason: '收到 rc.ptt 的 ok=true 必须让用户看见"对端已播放" ——'
              '否则按下说话后 UI 永远停在"已发送"，无从判断对端到底放没放');
      expect(tester.takeException(), isNull);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // B · pttStopAndSend 的"已发出"一侧
  // ══════════════════════════════════════════════════════════════════

  group('BL-CS 对讲发端', () {
    test('BL-CS-01 端点受理 ⇒ 回执文案带真实时长，而不是笼统的"失败"', () async {
      final dir = Directory.systemTemp.createTempSync('bl_cs');
      final f = File('${dir.path}/b.m4a')..writeAsBytesSync(List<int>.filled(32, 3));
      rec.stopPath = f.path;

      // 宿主没有 broker ⇒ `sendTo` 恒 false；用第 45 轮缝驱动"broker 已受理"。
      var sent = 0;
      svc.debugSendTo = (endpoint, msg, s, enqueueOnFail) async {
        sent++;
        expect(msg.type, RcCmd.pttVoice);
        return true;
      };

      // ★ 必须先 `pttStart()`：`RcControllerService` 是**进程内单例**，
      // 其 `_pttStopwatch` 是**跨用例残留**的字段 —— 60 秒那条例跑过之后
      // 累计时长仍在（`stop()` 不 reset）⇒ 直接调 `pttStopAndSend` 会走进
      // "超过 60 秒上限"。`pttStart()` 恰好做了 `reset()`（顺带覆盖它本身）。
      expect(await RcControllerService.instance.pttStart(), isTrue,
          reason: '平台允许 + 真实临时目录可用 ⇒ 起点必须是"真的开始录了"');

      final r = await RcControllerService.instance
          .pttStopAndSend(ep('CTRL0001abcdeff', '客厅平板'), store);

      expect(sent, 1, reason: '必须真的把加密语音交出去一次');
      expect(r.ok, isTrue);
      expect(r.message, startsWith('已发送'),
          reason: '受理后必须报"已发送（时长）" —— 与离线时的"发送失败"是两回事');
      expect(await f.exists(), isFalse,
          reason: '发出后临时录音文件必须清掉，不能留下无人回收的取证残留');
    });
  });
}
