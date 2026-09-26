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
/// ## 为什么现在要注入 host（P0-1）
/// 原用例**从不点击「生成临时码」**，只断言按钮存在 —— 这正是"看不到临时码"
/// 缺陷得以逃逸的原因：缺陷在**点击之后**的生成路径上（`_emit()` 被可抛的
/// `audit` 挡在后面）。补 UI 级用例必须能分别构造：
/// - 正常传输（点击 → 出码）；
/// - **会抛的 audit**（点击 → 码仍显示）；
/// - **无传输**（点击 → "远程模块未开启"）。
/// 三者互斥，因此页面需要 `host` 注入缝（同 [AssistJoinScreen.client]）。
///
/// 两个 testWidgets 特有的坑（见 [pump] / [finish] 注释）：
/// 1. `testWidgets` 跑在 FakeAsync 里，`RcAssistHost` 的 1 秒心跳变成
///    **fake timer**；测试体结束时若仍 pending 会触发框架不变量断言，
///    而 `tearDown` 在断言之后才跑 —— 必须在**测试体内**显式关闭会话；
/// 2. `ListView` 懒构建，默认 800×600 视口放不下权限列表，底部按钮
///    根本没被 build → finder 找不到。故显式放大测试视口。
void main() {
  late RcAssistHost host;
  late _FakeTransport bus;

  setUp(() {
    host = RcAssistHost();
    bus = _FakeTransport();
    host
      ..bind(bus)
      ..endpointName = '端点-测试机';
  });

  tearDown(() async {
    await host.close(silent: true);
  });

  /// 放大视口 + 挂载页面（视口过小会让 ListView 不构建屏外子树）。
  Future<void> pump(WidgetTester tester, {RcAssistHost? override}) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(home: AssistHostScreen(host: override ?? host)));
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

  /// 把 9 位码按 3 位分组（与页面 `_group` 一致）。
  String groupedCode(String code) =>
      '${code.substring(0, 3)} ${code.substring(3, 6)} ${code.substring(6)}';

  /// 把 8 位密码按 4 位分组。
  String groupedPw(String pw) => '${pw.substring(0, 4)} ${pw.substring(4)}';

  testWidgets('AHW-01 无会话时提示"未被控制"并给出唯一入口按钮', (tester) async {
    await pump(tester);

    expect(find.text('本机未被任何人控制'), findsOneWidget);
    expect(find.text('生成临时码'), findsOneWidget);
    expect(find.text('终止会话'), findsNothing);
    // 未建立会话时不得出现权限开关。
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('AHW-02 等待接入：显示临时码/密码/倒计时，且仍无权限开关', (tester) async {
    final s = await host.start();
    await pump(tester);

    expect(find.text('协助会话进行中'), findsOneWidget);
    expect(find.text('请把下面两个值口述给对方'), findsOneWidget);
    expect(find.text('临时码'), findsOneWidget);
    expect(find.text('访问密码'), findsOneWidget);
    // 临时码按 3 位一组显示，降低口述误读率。
    expect(find.text(groupedCode(s.code)), findsOneWidget);
    expect(find.textContaining('后自动失效'), findsOneWidget);
    expect(find.text('终止会话'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing,
        reason: '尚未接入就展示权限开关会误导使用者');

    await finish(tester);
  });

  testWidgets('AHW-03 已接入：显示控制端名 + 权限开关且默认全关', (tester) async {
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
    final s = await host.start(ttl: const Duration(minutes: 5));
    await pump(tester);

    // 注：**不能**用 tester.pump(Duration) 推进倒计时 —— FakeAsync 只虚拟化
    // Timer，`DateTime.now()` 仍是真实墙钟，elapse 会瞬间返回、剩余时间几乎不变。
    // TTL 的真实推进由 assist_host_test.dart 的 AH-14/AH-15 用真实延时覆盖；
    // 这里只锁定"渲染格式 + 绑定的是会话真实剩余时间"。
    // ⚠️ **不要断言具体的十位秒数**（原为 `'04:5'`）：`remaining` 来自真实墙钟，
    // 慢机器（或与其它用例并发）上 pumpWidget 一旦耗时 >5s 就会跨到 `04:4x`
    // → `Found 0 widgets` 假红（2026-09-20 门禁实测）。
    expect(find.textContaining(RegExp(r'剩余 \d\d:[0-5]\d')), findsOneWidget);
    // 用**宽窗口**的数值断言补回"绑定的确实是会话真实剩余时间"这一意图。
    expect(s.remaining.inSeconds, greaterThan(240));
    expect(s.remaining.inSeconds, lessThanOrEqualTo(300));

    await finish(tester);
  });

  testWidgets('AHW-06 短 TTL 渲染为 00:ss（不出现负数/越界）', (tester) async {
    final s = await host.start(ttl: const Duration(seconds: 45));
    await pump(tester);

    // 短 TTL 必须渲染成 00:ss —— 两位秒、不越界、不出现负号。
    // ⚠️ 同样不要断言 `'00:4'` 这种具体秒数（只有 5 秒窗口 → 慢机器假红）。
    expect(find.textContaining(RegExp(r'剩余 00:[0-5]\d')), findsOneWidget);
    expect(s.remaining.inSeconds, inInclusiveRange(0, 45));

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

  // ---------------- AHW-1x 生成路径（P0-1 回归锁） ----------------

  testWidgets('AHW-10 点击「生成临时码」→ 屏幕出现 9 位临时码与 8 位密码', (tester) async {
    await pump(tester);
    expect(find.text('生成临时码'), findsOneWidget);

    await tester.tap(find.text('生成临时码'));
    await tester.pump(); // 触发 _start()
    await tester.pump(const Duration(milliseconds: 200)); // 派生 + emit

    final s = host.session;
    expect(s, isNotNull, reason: '点击后必须真的建立会话');
    expect(RcAssist.isValidCode(s!.code), isTrue);
    expect(RcAssist.isValidPassword(s.password), isTrue);
    expect(bus.subscribed, [s.topic], reason: '生成时必须订阅会合主题');

    // 关键：UI 必须真的把两个值渲染出来（不是"只在内存里生成"）。
    expect(find.text('请把下面两个值口述给对方'), findsOneWidget);
    expect(find.text(groupedCode(s.code)), findsOneWidget);
    expect(find.text(groupedPw(s.password)), findsOneWidget);

    await finish(tester);
  });

  testWidgets('AHW-11 审计写入抛异常 → 临时码仍必须显示（P0-1 根因 b 回归锁）',
      (tester) async {
    // 真实场景：audit 是 sqflite insert，磁盘满/锁表都会抛。
    host.audit = (a, s, m) async => throw StateError('audit boom');
    await pump(tester);

    await tester.tap(find.text('生成临时码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final s = host.session;
    expect(s, isNotNull, reason: '审计失败不得阻断会话创建');
    // 若把 _emit() 放在 audit 之后，这里会 0 个 widget —— 正是缺陷的原始形状。
    expect(find.text('请把下面两个值口述给对方'), findsOneWidget,
        reason: '_emit 必须在 audit 之前；否则审计一抛 UI 永远收不到码');
    expect(find.text(groupedCode(s!.code)), findsOneWidget);
    expect(find.text(groupedPw(s.password)), findsOneWidget);

    await finish(tester);
  });

  testWidgets('AHW-12 模块未开启（无传输）→ 点击给出"远程模块未开启"明确提示',
      (tester) async {
    // 未 bind 的实例 = 远程模块关闭（endpoint_service 未启动）。
    final offline = RcAssistHost()..endpointName = '端点-测试机';
    await pump(tester, override: offline);

    await tester.tap(find.text('生成临时码'));
    await tester.pump(); // _start 捕获异常
    await tester.pump(const Duration(milliseconds: 400)); // SnackBar 入场

    expect(offline.session, isNull, reason: '模块未开启不得生成"必然连不上"的死码');
    expect(find.textContaining('远程模块未开启'), findsOneWidget,
        reason: '与 join() 的"远程模块未开启，无法接入"口径对称：显式拒绝');
    // 仍停留在"无会话"态，使用者可重试。
    expect(find.text('生成临时码'), findsOneWidget);
  });
}

/// 记录订阅/退订的假传输（不碰网络，便于确定性断言）。
class _FakeTransport implements AssistTransport {
  final subscribed = <String>[];
  final unsubscribed = <String>[];
  final published = <({String topic, String wire})>[];

  @override
  Future<void> subscribe(String topic) async => subscribed.add(topic);

  @override
  Future<void> unsubscribe(String topic) async => unsubscribed.add(topic);

  @override
  Future<void> publishWire(String topic, String wire) async =>
      published.add((topic: topic, wire: wire));
}
