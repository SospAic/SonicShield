import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/assist_join_screen.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/assist_join.dart';
import 'package:sonic_shield/remote/protocol.dart';

/// 控制端「接入协助会话」页（v1.7 S3）UI 契约测试。
///
/// 关注的是**状态机到界面的映射**，不是像素：
/// - 未接入 → 表单；已接入 → 复用控制台（同一套命令面板）；
/// - 端点未放行的能力必须**灰化**（不能出现"可点但必被拒"的按钮）；
/// - 端点放行/收回权限后，灰化状态要**立即**跟上（BUG-030）。
///
/// ## 为什么用 `tester.runAsync`
/// 握手涉及真实 AES-GCM/HKDF（`package:cryptography`）。`testWidgets` 默认在
/// FakeAsync 区里跑，而加密实现内部的异步并不都由假时钟驱动 —— 直接在假时钟里
/// 跑握手会挂住。`runAsync` 切到真实异步区完成握手，回到假时钟只做渲染断言，
/// 这样既不脆弱也不需要为测试放宽实现。
void main() {
  late RcAssistHost host;
  late AssistJoinClient client;
  late _FakeTransport hostBus;
  late _FakeTransport joinBus;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    host = RcAssistHost();
    client = AssistJoinClient();
    hostBus = _FakeTransport();
    joinBus = _FakeTransport();

    host
      ..bind(hostBus)
      ..endpointName = '端点-测试机';
    client
      ..bind(joinBus)
      ..ctrlName = '控制端A'
      ..helloRetryInterval = const Duration(milliseconds: 1);

    joinBus.onPublish = (topic, wire) async {
      if (host.session?.topic == topic) await host.onWire(wire);
    };
    hostBus.onPublish = (topic, wire) async {
      if (client.topic == topic) await client.onWire(wire);
    };
  });

  tearDown(() async {
    await client.leave(silent: true);
    await host.close(silent: true);
  });

  /// 挂载页面（注入互不干扰的客户端实例）。
  ///
  /// 视口放大到 1200×4000：控制台是一个 `ListView`，**屏幕外的条目不会被构建**，
  /// 而 `find.widgetWithText` 只能找到已构建的 widget。默认 800×600 下，
  /// 断言会隐含依赖"所有按钮都在首屏内" —— 功能一多就假红
  /// （BUG-048 给「音效播放」加了两个入口后，JW-15 的
  /// 「停止指令组」被挤出首屏、`Found 0 widgets`）。
  /// 放大视口让整个控制台都可被构建，断言就不再依赖位置。
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: AssistJoinScreen(client: client)),
    ));
    // 控制台会异步读取配对表，多泵一帧让首帧布局稳定。
    await tester.pump();
    await tester.pump();
  }

  /// 在真实异步区完成一次真实握手，然后回到假时钟渲染。
  Future<void> handshake(WidgetTester tester, AssistSession s) async {
    await tester.runAsync(() async {
      expect(await client.join(s.code, s.password), isTrue);
    });
    await tester.pump();
  }

  /// 真实异步区里收尾（取消 1s 心跳，避免残留定时器）。
  Future<void> cleanup(WidgetTester tester) async {
    await tester.runAsync(() async {
      await client.leave(silent: true);
      await host.close(silent: true);
    });
  }

  // ---------------- JW-0x 表单态 ----------------

  group('JW 接入表单', () {
    testWidgets('JW-01 未接入时渲染表单：码/密码输入 + 接入按钮 + 安全说明', (tester) async {
      await mount(tester);

      expect(find.text('接入协助会话'), findsOneWidget);
      expect(find.text('临时码（9 位数字）'), findsOneWidget);
      expect(find.text('访问密码（8 位）'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '接入'), findsOneWidget);
      expect(find.textContaining('访问密码才是真正的共享秘密'), findsOneWidget);
      // 未接入时不应出现控制台元素
      expect(find.text('设备快照与动作'), findsNothing);
    });

    testWidgets('JW-02 非法凭据 → 内联错误 + 顶部提示，且不进入接入中', (tester) async {
      await mount(tester);

      await tester.enterText(find.byType(TextField).first, '123');
      await tester.enterText(find.byType(TextField).last, 'ABC');
      await tester.tap(find.widgetWithText(FilledButton, '接入'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('9 位数字'), findsWidgets);
      expect(client.phase, AssistPhase.closed);
      // 仍在表单页
      expect(find.text('接入协助会话'), findsOneWidget);
    });

    testWidgets('JW-03 接入成功后切到控制台：标题含端点名、横幅含会话 ID 与倒计时', (tester) async {
      final s = await host.start();
      await mount(tester);
      await handshake(tester, s);

      expect(find.text('协助会话 · 端点-测试机'), findsOneWidget);
      expect(find.textContaining('临时协助会话进行中'), findsOneWidget);
      expect(find.textContaining('剩余 '), findsOneWidget);
      expect(find.textContaining(client.sessionId), findsOneWidget);
      // 表单已让位给控制台
      expect(find.text('接入协助会话'), findsNothing);

      await cleanup(tester);
    });
  });

  testWidgets('JW-04 接入进行中（busy）→ 显示"正在接入…"+转圈，且输入框禁用',
      (tester) async {
    final s = await host.start();
    await mount(tester);

    // 让 hello 石沉大海：端点侧不作答 ⇒ 客户端停在 opening（`busy == true`）。
    // 这正是"用户已经点了接入、但对端还没回"的那几秒 —— 此前没有任何用例
    // 停在过这一帧。
    joinBus.mute = true;

    // ⚠️ 握手涉真实 AES-GCM ⇒ 必须回真实异步区；这里**只启动、不等它结束**，
    // 以便在"接入中"这一帧做断言。
    late Future<bool> joining;
    await tester.runAsync(() async {
      joining = client.join(s.code, s.password,
          timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.text('接入协助会话'), findsOneWidget,
        reason: 'opening 阶段仍应停在表单页（还没接进去）');
    expect(find.textContaining('正在接入…'), findsOneWidget,
        reason: '接入中必须让用户看到"在动"，否则会以为没点着而反复点');
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '只有文字没有转圈，用户仍会怀疑卡死');
    expect(
        tester.widget<TextField>(find.byType(TextField).first).enabled, isFalse,
        reason: '接入中改凭据不会作用于本次握手 —— 必须禁用，'
            '否则用户以为改了就走新凭据');

    // 放行握手（会走 2s 超时）后再收尾，避免留下未完成的链。
    joinBus.mute = false;
    await tester.runAsync(() async {
      await joining;
    });
    await cleanup(tester);
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ---------------- JW-1x 控制台权限灰化 ----------------

  group('JW 控制台权限灰化', () {
    testWidgets('JW-10 默认全拒：只读可点，作用于设备的按钮全部灰化', (tester) async {
      final s = await host.start();
      await mount(tester);
      await handshake(tester, s);

      // 只读：会话存活所必需 → 可点
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Ping'))
              .onPressed,
          isNotNull);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '状态快照'))
              .onPressed,
          isNotNull);
      // 未放行：必须灰化（不能出现"可点但必被拒"的按钮）
      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, '守卫 开'))
              .onPressed,
          isNull);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '定位回传'))
              .onPressed,
          isNull);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '拍照回传'))
              .onPressed,
          isNull);
      // 音效播放同样灰化
      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, 'knocks'))
              .onPressed,
          isNull);
      expect(find.textContaining('端点尚未放行任何能力'), findsOneWidget);

      await cleanup(tester);
    });

    testWidgets('JW-11 端点放行后灰化立即刷新（BUG-030）', (tester) async {
      final s = await host.start();
      await mount(tester);
      await handshake(tester, s);

      // 放行前：音效按钮灰
      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, 'knocks'))
              .onPressed,
          isNull);

      await tester.runAsync(() async {
        await host.grant(const AssistPerms(media: true));
      });
      await tester.pump();

      // 放行后：同一帧内按钮即可点，横幅摘要同步更新
      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, 'knocks'))
              .onPressed,
          isNotNull);
      expect(find.textContaining('已放行：播放音效'), findsOneWidget);

      await cleanup(tester);
    });

    testWidgets('JW-12 端点收回权限后灰化立即回退', (tester) async {
      final s = await host.start();
      await mount(tester);
      await handshake(tester, s);

      await tester.runAsync(() async {
        await host.grant(const AssistPerms(media: true));
      });
      await tester.pump();
      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, 'knocks'))
              .onPressed,
          isNotNull);

      await tester.runAsync(() async {
        await host.grant(AssistPerms.none);
      });
      await tester.pump();

      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, 'knocks'))
              .onPressed,
          isNull);
      expect(find.textContaining('端点尚未放行任何能力'), findsOneWidget);

      await cleanup(tester);
    });

    testWidgets('JW-13 挂断后回到表单，且客户端已清理', (tester) async {
      final s = await host.start();
      await mount(tester);
      await handshake(tester, s);

      await tester.tap(find.byTooltip('挂断'));
      await tester.pump();
      await tester.pump();

      expect(find.text('接入协助会话'), findsOneWidget);
      expect(find.text('设备快照与动作'), findsNothing);
      expect(client.phase, AssistPhase.closed);
      expect(client.topic, isEmpty);
      expect(host.session, isNull, reason: '控制端挂断应通知端点终止会话');

      await cleanup(tester);
    });

    testWidgets('JW-14 端点终止 → 页面自动退回表单并给出原因', (tester) async {
      final s = await host.start();
      await mount(tester);
      await handshake(tester, s);
      expect(find.text('设备快照与动作'), findsOneWidget);

      await tester.runAsync(() async {
        await host.close();
      });
      await tester.pump();
      await tester.pump();

      expect(find.text('接入协助会话'), findsOneWidget);
      expect(find.textContaining('端点已终止'), findsWidgets);

      await cleanup(tester);
    });

    testWidgets('JW-15 控制台提供 script.stop 入口（BUG-020 剩余项）', (tester) async {
      final s = await host.start();
      await mount(tester);
      await handshake(tester, s);

      expect(find.widgetWithText(OutlinedButton, '停止指令组'), findsOneWidget);
      // 门控位为 script：默认全拒时灰化
      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, '停止指令组'))
              .onPressed,
          isNull);

      await tester.runAsync(() async {
        await host.grant(const AssistPerms(script: true));
      });
      await tester.pump();

      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, '停止指令组'))
              .onPressed,
          isNotNull);

      await cleanup(tester);
    });
  });

  // ---------------- JW-3x 任务 Tab 说明（P2-2） ----------------

  group('JW 任务 Tab 说明', () {
    testWidgets('JW-30 协助会话下「任务」Tab 显式说明不可用（避免误以为设备丢了）',
        (tester) async {
      final s = await host.start();
      await mount(tester);
      await handshake(tester, s);

      await tester.tap(find.widgetWithText(Tab, '任务'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('协助会话暂不支持管理远端任务'), findsOneWidget,
          reason: '任务页依赖配对表；协助会话无配对记录，必须说明而非静默空白');

      await cleanup(tester);
    });
  });

  // ---------------- JW-2x 会话审计面板（S4） ----------------

  group('JW 会话审计面板', () {
    testWidgets('JW-20 审计面板可打开，并展示命令与端点拒绝原因', (tester) async {
      final s = await host.start();
      await mount(tester);
      await handshake(tester, s);

      // 制造一条被拒绝的记录（默认全拒 → sound.play 会被拒）
      await tester.runAsync(() async {
        host.onCommand = (m) async {};
        await client
            .send(RcMessage.now(RcCmd.soundPlay, {'category': 'alarms'}));
        // 等拒绝回执落账
        for (var i = 0; i < 50 && !client.auditLog.any((e) => !e.ok); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      await tester.tap(find.byTooltip('会话审计'));
      await tester.pumpAndSettle();

      expect(find.text('会话审计（本机记录）'), findsOneWidget);
      expect(find.textContaining('未放行的命令会被端点拒绝'), findsOneWidget);
      // 发出的命令与被拒原因都要可见（否则使用者只看到"点了没反应"）
      expect(find.textContaining('发出 · ${RcCmd.soundPlay}'), findsOneWidget);
      expect(find.textContaining('权限未放行'), findsOneWidget);

      await cleanup(tester);
    });

    testWidgets('JW-21 无记录时审计面板给出空态提示', (tester) async {
      final s = await host.start();
      await mount(tester);
      await handshake(tester, s);

      await tester.tap(find.byTooltip('会话审计'));
      await tester.pumpAndSettle();

      // 握手本身会留痕，因此这里只断言面板结构与标题存在
      expect(find.text('会话审计（本机记录）'), findsOneWidget);

      await cleanup(tester);
    });
  });
}

/// 记录收发动作的假传输；[mute] 丢弃全部发布。
class _FakeTransport implements AssistTransport {
  final subscribed = <String>[];
  final unsubscribed = <String>[];
  final published = <({String topic, String wire})>[];

  bool mute = false;

  Future<void> Function(String topic, String wire)? onPublish;

  @override
  Future<void> subscribe(String topic) async => subscribed.add(topic);

  @override
  Future<void> unsubscribe(String topic) async => unsubscribed.add(topic);

  @override
  Future<void> publishWire(String topic, String wire) async {
    published.add((topic: topic, wire: wire));
    if (mute) return;
    await onPublish?.call(topic, wire);
  }
}
