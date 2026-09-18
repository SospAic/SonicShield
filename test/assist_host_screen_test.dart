import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/features/remote/assist_host_screen.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/protocol.dart';

/// 端点侧「临时协助会话」页（docs/18 S2）渲染契约测试。
///
/// 重点不是像素，而是**状态机 ↔ UI 的绑定是否正确**：
/// 会话未建立时绝不能出现权限开关（否则使用者会以为"已经能授权"），
/// 会话激活后 7 个开关必须**全部为关**（C5 默认全拒的可见证据）。
///
/// 两个 testWidgets 特有的坑（见 [pump] / [finish] 注释）：
/// 1. `testWidgets` 跑在 FakeAsync 里，`RcAssistHost` 的 1 秒心跳变成
///    **fake timer**；测试体结束时若仍 pending 会触发框架不变量断言，
///    而 `tearDown` 在断言之后才跑 —— 必须在**测试体内**显式关闭会话；
/// 2. `ListView` 懒构建，默认 800×600 视口放不下权限列表，底部按钮
///    根本没被 build → finder 找不到。故显式放大测试视口。
void main() {
  final host = RcAssistHost.instance;

  setUp(() async {
    await host.close(silent: true);
  });

  tearDown(() async {
    await host.close(silent: true);
  });

  /// 放大视口 + 挂载页面（视口过小会让 ListView 不构建屏外子树）。
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AssistHostScreen()));
    await tester.pump();
  }

  /// 收尾：终止会话以取消心跳（fake timer 不能留到测试结束）。
  Future<void> finish(WidgetTester tester) async {
    await host.close(silent: true);
    await tester.pump();
  }

  /// 把会话推进到 active（模拟控制端完成 hello 握手）。
  Future<AssistSession> activate() async {
    final s = await host.start();
    final ctlKey = await RcAssist.ctlKey(s.code, s.password);
    await host.onWire(await RcCodec.encode(
        RcMessage.now(RcAssistCmd.hello, {'ctrlName': '小李的手机'}),
        ctlKey,
        s.topic));
    return s;
  }

  testWidgets('AHW-01 无会话时提示"未被控制"并给出唯一入口按钮', (tester) async {
    await pump(tester);

    expect(find.text('本机未被任何人控制'), findsOneWidget);
    expect(find.text('生成临时码'), findsOneWidget);
    expect(find.text('终止会话'), findsNothing);
    // 未建立会话时不得出现权限开关。
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('AHW-02 等待接入：显示临时码/密码/倒计时，且仍无权限开关',
      (tester) async {
    final s = await host.start();
    await pump(tester);

    expect(find.text('协助会话进行中'), findsOneWidget);
    expect(find.text('请把下面两个值口述给对方'), findsOneWidget);
    expect(find.text('临时码'), findsOneWidget);
    expect(find.text('访问密码'), findsOneWidget);
    // 临时码按 3 位一组显示，降低口述误读率。
    expect(find.text('${s.code.substring(0, 3)} '
        '${s.code.substring(3, 6)} ${s.code.substring(6)}'), findsOneWidget);
    expect(find.textContaining('后自动失效'), findsOneWidget);
    expect(find.text('终止会话'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing,
        reason: '尚未接入就展示权限开关会误导使用者');

    await finish(tester);
  });

  testWidgets('AHW-03 已接入：显示控制端名 + 7 个权限开关且默认全关',
      (tester) async {
    await activate();
    await pump(tester);

    expect(find.text('正在被「小李的手机」协助'), findsOneWidget);
    expect(
        find.byType(SwitchListTile), findsNWidgets(AssistPerms.labels.length));
    expect(find.text('允许对方做什么（默认全部不允许）'), findsOneWidget);

    // C5 默认全拒：所有开关必须为关。
    final switches =
        tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    expect(switches.every((s) => s.value == false), isTrue);

    await finish(tester);
  });

  testWidgets('AHW-04 拨动开关 → 会话权限位同步更新', (tester) async {
    final s = await activate();
    await pump(tester);

    await tester.tap(find.widgetWithText(SwitchListTile, '播放音效'));
    await tester.pump();

    expect(s.perms.media, isTrue, reason: 'UI 开关必须真正写回会话权限位');
    expect(s.perms.script, isFalse, reason: '只应改动被拨动的那一位');

    await finish(tester);
  });

  testWidgets('AHW-05 倒计时按 TTL 渲染为 mm:ss', (tester) async {
    await host.start(ttl: const Duration(minutes: 5));
    await pump(tester);

    // 注：**不能**用 tester.pump(Duration) 推进倒计时 —— FakeAsync 只虚拟化
    // Timer，`DateTime.now()` 仍是真实墙钟，elapse 会瞬间返回、剩余时间几乎不变。
    // TTL 的真实推进由 assist_host_test.dart 的 AH-14/AH-15 用真实延时覆盖；
    // 这里只锁定"渲染格式 + 绑定的是会话真实剩余时间"。
    expect(find.textContaining('04:5'), findsOneWidget);

    await finish(tester);
  });

  testWidgets('AHW-06 短 TTL 渲染为 00:ss（不出现负数/越界）', (tester) async {
    await host.start(ttl: const Duration(seconds: 45));
    await pump(tester);

    expect(find.textContaining('00:4'), findsOneWidget);

    await finish(tester);
  });

  testWidgets('AHW-07 终止会话后回到"未被控制"初始态', (tester) async {
    await activate();
    await pump(tester);

    await tester.tap(find.text('终止会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('本机未被任何人控制'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('生成临时码'), findsOneWidget);
  });
}
