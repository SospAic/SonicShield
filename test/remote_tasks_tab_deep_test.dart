import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_tasks_tab.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 远程「任务」子页的**深交互 + 摘要渲染**测试（第二轮）。
///
/// 与 `test/remote_tasks_tab_test.dart`（RTT-01..17，管命令收发与 BUG-063）
/// **互补**：本文件补的是那一份够不到的三块 ——
///
/// 1. **摘要渲染器**（`_triggerDetail` / `_actionDetail` / `_cooldown` /
///    `_fmtIso` / `_kindToType` / `_triggerLabel` / `_actionLabel`）。
///    它们是 `static` + 私有 → **宿主单测直接够不到**，只能靠"喂一条任务线格式
///    进去、看渲染出什么字"来覆盖。这恰恰是最该测的一层：这些函数是
///    **查表展示**（输入是 String），漏登记**不编译报错**、后果是"用户看不懂
///    这任务要干什么"而不是抛异常（与 LBL-01 同一判据）。
/// 2. **编辑入口**（`_openEditor`：FAB 新建 / 菜单编辑 / 写回 `task.upsert` /
///    解析失败提示）与**端点切换**（下拉 `onChanged`）。
/// 3. **生产路径**（`widget.channel == null`）—— 走 `RcEndpointService.instance`
///    的真实分支，RTT 全程注入假通道，所以那一整段是 0 覆盖。
///
/// ⚠️ 本文件命名的 **RTD** = Remote Tasks Deep，避免与 RTT 撞号。
///
/// ## 硬约束（与 RTT 相同）
///
/// * 页面在 `_loading || _awaiting` 时渲染 `CircularProgressIndicator`（无限动画）
///   → **不要用 `pumpAndSettle`**，用显式 `pump(duration)`；
/// * **SnackBar 是排队的**：同一个用例里连弹两条时，第二条要等第一条 4 秒后
///   才出现。需要看第二条时必须先把队列排空（见 `_drainSnacks`）；
/// * 视口要够高：任务卡片是 `ListView` 子项，视口外**不会被构建**；
/// * **宿主必须提供外层 `Scaffold`**：本页 `_load() → refresh() → _send()` 全在
///   微任务里跑完（无 Timer），`_snack()` 触发时页面**自己的** Scaffold 还没挂上
///   —— 生产靠 `SectionScaffold` 兜住，测试宿主也要补一层（见 `pumpTab`）；
/// * **线格式的 `trigger` 必须带 `kind`**：`TriggerConfig.fromJson` 按
///   `trigger['kind']` 分派，不是按外层 `triggerType`（见 `_task`）。
class _FakeChannel implements RcCommandChannel {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _updates = StreamController<void>.broadcast();
  final sent = <RcMessage>[];

  bool sendResult = true;

  @override
  String get label => '假端点';

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Stream<void> get updates => _updates.stream;

  @override
  bool get canSend => true;

  @override
  Future<bool> send(RcMessage msg) async {
    sent.add(msg);
    return sendResult;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await _updates.close();
  }

  void emit(String type, Map<String, dynamic> payload) =>
      _events.add({'type': type, 'payload': payload});

  bool sentType(String type) => sent.any((m) => m.type == type);

  int countOfType(String type) => sent.where((m) => m.type == type).length;

  RcMessage lastOfType(String type) => sent.lastWhere((m) => m.type == type,
      orElse: () => throw StateError('未发送 $type'));
}

PairedEndpoint _ep(String id, String name) => PairedEndpoint(
    deviceId: id, name: name, secret: 's', pairedAt: DateTime.now());

/// 一条可渲染的端点任务线格式（`TaskWire.toWire` 的形状）。
Map<String, dynamic> _task({
  String id = 't1',
  String name = '任务',
  bool enabled = true,
  int cooldownSec = 0,
  List<String> assetIds = const [],
  String triggerType = 'dailyAt',
  Map<String, dynamic>? trigger,
  String actionType = 'tts',
  Map<String, dynamic>? action,
}) {
  final tr = Map<String, dynamic>.from(
      trigger ?? const {'time': {'hour': 7, 'minute': 30}});
  // ⚠️ 线格式的 `trigger` 里**必须带 `kind`**：`TriggerConfig.fromJson` 是按
  // `trigger['kind']` 分派的（**不是**按外层 `triggerType`）—— 见
  // `lib/domain/models/trigger.dart` 的 `switch (j['kind'])`。
  // 少了它，`TaskWire.fromWire` 会抛 `未知触发类型: null` 并被 `on Object`
  // 吞成 null → 「编辑」按钮退化成弹一句"无法解析"。RTD-12 首跑就是这么红的。
  tr.putIfAbsent('kind', () => triggerType);
  return {
    'id': id,
    'name': name,
    'enabled': enabled,
    'triggerType': triggerType,
    'trigger': tr,
    'actionType': actionType,
    'action': action ?? const {'kind': 'tts', 'text': '早上好'},
    'cooldownSec': cooldownSec,
    'assetIds': assetIds,
  };
}

void main() {
  /// 把 `_load()/refresh()` 的异步尾巴跑干净，页面进入稳定态。
  ///
  /// [injectChannel] = false 时**不注入通道** → `widget.channel == null`
  /// → 走 `RcEndpointService.instance` 的**生产分支**（离线入队）。
  Future<_FakeChannel?> pumpTab(
    WidgetTester tester, {
    bool enabled = true,
    List<PairedEndpoint> endpoints = const [],
    String selected = '',
    bool injectChannel = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = RemoteStore(await SharedPreferences.getInstance());
    for (final e in endpoints) {
      await store.addPaired(e);
    }
    if (enabled) await store.setEnabled(true);
    if (selected.isNotEmpty) await store.selectEndpoint(selected);

    final ch = injectChannel ? _FakeChannel() : null;
    if (ch != null) addTearDown(ch.dispose);

    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // ⚠️ 外层 `Scaffold` 不是装饰，是**还原生产形状**：本页在真实 App 里被
    // `SectionScaffold`（`lib/core/widgets/section_scaffold.dart`，内部就是
    // `Scaffold`）包着。而 `_load() → refresh() → _send()` 这条链**全在微任务
    // 里跑完**（无 Timer），`_snack()` 触发时页面自己的 Scaffold **还没挂上**
    // —— `setState` 只是标脏，要等下一帧才重建。
    // 少了外层 Scaffold，`ScaffoldMessenger.showSnackBar` 会断言
    // `_scaffolds.isNotEmpty` 失败（RTD-14/15 首跑就是这么红的）。
    // ⇒ 这条"本页依赖宿主提供 Scaffold"是**隐式契约**，别把外层删掉。
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: RemoteTasksTab(channel: ch)),
      ),
    ));
    await tester.pump(); // _load() 的 setState
    await tester.pump(const Duration(seconds: 3)); // refresh 的 2s 兜底延迟
    if (ch != null) {
      ch.emit(RcEvt.status, {'pendingCount': 0, 'version': '1.9.0-alpha'});
      await tester.pump();
    }
    return ch;
  }

  /// 排空 SnackBar 队列（每条显示 4 秒；`ScaffoldMessenger` 是串行的）。
  Future<void> drainSnacks(WidgetTester tester, {int seconds = 12}) async {
    for (var i = 0; i < seconds; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  Future<void> emitTasks(
    WidgetTester tester,
    _FakeChannel ch,
    List<Map<String, dynamic>> tasks,
  ) async {
    ch.emit(RcEvt.tasks, {'tasks': tasks});
    await tester.pump();
  }

  // ══════════════════════════════════════════════════════════════════════
  // RTD-A · 摘要渲染器（`static` + 私有 → 只能从渲染结果倒推）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('RTD-01 摘要 · 五种触发类型都翻成人话（不是把枚举名甩给用户）',
      (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    await emitTasks(tester, ch!, [
      _task(
          id: 'a',
          name: 'A',
          triggerType: 'fixedOnce',
          trigger: const {'at': '2026-03-04T06:05:00'}),
      _task(
          id: 'b',
          name: 'B',
          triggerType: 'weeklyAt',
          trigger: const {
            'weekdays': [6, 2, 4], // 故意乱序：必须排成 二/四/六
            'time': {'hour': 8, 'minute': 15},
          }),
      _task(
          id: 'c',
          name: 'C',
          triggerType: 'randomWindow',
          trigger: const {
            'windowStart': {'hour': 6, 'minute': 30},
            'windowEnd': {'hour': 23, 'minute': 0},
            'timesPerDay': 7,
          }),
      _task(
          id: 'd',
          name: 'D',
          triggerType: 'randomInterval',
          trigger: const {'minGapSec': 1800, 'maxGapSec': 7200, 'maxPerDay': 12}),
      _task(
          id: 'e',
          name: 'E',
          triggerType: 'soundTriggered',
          trigger: const {'thresholdDb': 65}),
    ]);

    expect(find.textContaining('固定一次 · 03-04 06:05'), findsOneWidget);
    // 星期必须**排序后**渲染 —— 乱序直接 join 会得到"六/二/四"。
    expect(find.textContaining('每周 二/四/六 08:15'), findsOneWidget);
    expect(find.textContaining('随机窗口 06:30–23:00 · 每天 7 次'), findsOneWidget);
    // `_gap` 两个分支：≥3600s 用小时，否则用分钟。
    expect(find.textContaining('随机间隔 30min–2.0h · 每天≤12 次'), findsOneWidget);
    expect(find.textContaining('声音触发 · ≥65 dB'), findsOneWidget);
  });

  testWidgets('RTD-02 摘要 · 每周一个都没选 → 占位符（不是空白或崩溃）',
      (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    await emitTasks(tester, ch!, [
      _task(
          id: 'a',
          name: 'A',
          triggerType: 'weeklyAt',
          trigger: const {
            'weekdays': <int>[],
            'time': {'hour': 8, 'minute': 15},
          }),
    ]);
    expect(find.textContaining('每周 — 08:15'), findsOneWidget);
  });

  testWidgets('RTD-03 摘要 · 未知触发类型：空串/null 给兜底名，非空的原样显示',
      (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    await emitTasks(tester, ch!, [
      _task(id: 'a', name: 'A', triggerType: 'someFutureTrigger'),
      // ⚠️ `''` 不是 null —— 只判 null 的话会渲染成空白标签。
      _task(id: 'b', name: 'B', triggerType: ''),
      // null 同样要给兜底名（`'${raw ?? '未知触发'}'` 的老写法只在 null 时兜底）。
      {..._task(id: 'c', name: 'C'), 'triggerType': null},
    ]);
    // 契约（`_triggerLabel` 的 `_` 分支）：
    //   非空未知值 → **原样显示**。这比统一显示"未知触发"信息更多 ——
    //   用户能看见端点发来的真实枚举名，也便于判断是协议版本不一致。
    expect(find.text('someFutureTrigger'), findsOneWidget,
        reason: '未知但非空 → 原样显示，不能吞成"未知触发"');
    expect(find.text('未知触发'), findsNWidgets(2),
        reason: '空串与 null 都要给兜底名，绝不能渲染成空白');
  });

  testWidgets('RTD-04 摘要 · 固定一次的 ISO 三种形态（合法/非法/非字符串）',
      (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    await emitTasks(tester, ch!, [
      _task(
          id: 'a',
          name: 'A',
          triggerType: 'fixedOnce',
          trigger: const {'at': '2026-03-04T06:05:00'}),
      // 解析不了就原样显示 —— 让用户看到"这个值不对劲"，而不是吞掉。
      _task(
          id: 'b',
          name: 'B',
          triggerType: 'fixedOnce',
          trigger: const {'at': '不是时间'}),
      // 根本不是字符串 → 给空串（不是 'null'）。
      _task(
          id: 'c',
          name: 'C',
          triggerType: 'fixedOnce',
          trigger: const {'at': 12345}),
    ]);
    expect(find.textContaining('固定一次 · 03-04 06:05'), findsOneWidget);
    expect(find.textContaining('固定一次 · 不是时间'), findsOneWidget);
    expect(find.textContaining('固定一次 · null'), findsNothing);
  });

  testWidgets('RTD-05 摘要 · 冷却三档（小时/分钟/秒）+ 0 显示"无"', (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    await emitTasks(tester, ch!, [
      _task(id: 'a', name: 'A', cooldownSec: 0),
      _task(id: 'b', name: 'B', cooldownSec: 7200),
      _task(id: 'c', name: 'C', cooldownSec: 300),
      _task(id: 'd', name: 'D', cooldownSec: 45),
    ]);
    expect(find.textContaining('冷却 无'), findsOneWidget);
    expect(find.textContaining('冷却 2h'), findsOneWidget);
    expect(find.textContaining('冷却 5min'), findsOneWidget);
    expect(find.textContaining('冷却 45s'), findsOneWidget);
  });

  testWidgets('RTD-06 摘要 · 各动作 kind 的关键可调项都摊在卡片上', (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    await emitTasks(tester, ch!, [
      _task(
          id: 'play',
          name: 'play',
          actionType: 'playAudio',
          action: const {
            'kind': 'play',
            'volumeMin': 0.3,
            'volumeMax': 0.8,
            'durationSecMin': 4,
            'durationSecMax': 9,
          }),
      _task(
          id: 'nt',
          name: 'nt',
          actionType: 'notify',
          action: const {'kind': 'notify', 'title': '到家提醒'}),
      _task(
          id: 'record',
          name: 'record',
          actionType: 'recordEvidence',
          action: const {'kind': 'record', 'seconds': 60}),
      _task(
          id: 'sc',
          name: 'sc',
          actionType: 'soundscape',
          action: const {
            'kind': 'soundscape',
            'tracks': [
              {'presetCategory': 'nature'},
              {'presetCategory': 'doors'},
            ],
            'durationSec': 120,
          }),
      _task(
          id: 'rv',
          name: 'rv',
          actionType: 'randomVibrate',
          action: const {
            'kind': 'randomVibrate',
            'amplitudeMin': 0.4,
            'amplitudeMax': 1.0,
            'durationSecMin': 3,
            'durationSecMax': 10,
            'maxPulses': 200,
          }),
      _task(
          id: 'cv',
          name: 'cv',
          actionType: 'continuousVibrate',
          action: const {
            'kind': 'continuousVibrate',
            'amplitudeMin': 0.5,
            'amplitudeMax': 1.0,
            'durationSecMin': 10,
            'durationSecMax': 30,
            'jitterMs': 250,
          }),
      // jitterMs=0 → 恒定，不该显示"波动 0ms"（噪声）。
      _task(
          id: 'cv0',
          name: 'cv0',
          actionType: 'continuousVibrate',
          action: const {
            'kind': 'continuousVibrate',
            'amplitudeMin': 0.5,
            'amplitudeMax': 1.0,
            'durationSecMin': 10,
            'durationSecMax': 30,
            'jitterMs': 0,
          }),
      _task(
          id: 'vib',
          name: 'vib',
          actionType: 'vibrate',
          action: const {
            'kind': 'vibrate',
            'patternMs': [0, 300, 200, 300],
          }),
    ]);

    expect(find.textContaining('播放音频 · 音量 30%–80% · 4–9s'), findsOneWidget);
    // notify 分支（`$base · ${m['title'] ?? ''}`）—— 首轮唯一漏掉的一个 kind 分支。
    expect(find.textContaining('发送通知 · 到家提醒'), findsOneWidget);
    expect(find.textContaining('录音取证 · 60s'), findsOneWidget);
    expect(find.textContaining('声景混音 · 2 轨 · 120s'), findsOneWidget);
    expect(
        find.textContaining('随机振动 · 强度 40%–100% · 3–10s · ≤200 脉冲'),
        findsOneWidget);
    expect(find.textContaining('持续振动 · 强度 50%–100% · 10–30s · 波动 250ms'),
        findsOneWidget);
    expect(find.textContaining('波动 0ms'), findsNothing,
        reason: 'jitterMs=0 表示恒定，不该渲染成"波动 0ms"');
    expect(find.textContaining('震动（固定节奏） · 4 步'), findsOneWidget);
  });

  testWidgets('RTD-07 摘要 · 组合动作的主动作标签覆盖**全部** kind（漏登记 = 空标签）',
      (tester) async {
    // 为什么值得单测：`_kindToType` 的输入是 String，漏一个分支**不编译报错**，
    // 后果是摘要里出现「通知 + 」（空标签）—— 用户看不出这任务要干什么。
    // 这正是 `remote_label_perm_coverage_test.dart` LBL-01 的判据。
    const kinds = <String, String>{
      'play': '播放音频',
      'soundscape': '声景混音',
      'tts': '语音喊话',
      'notify': '发送通知',
      'record': '录音取证',
      'vibrate': '震动（固定节奏）',
      'randomVibrate': '随机振动',
      'continuousVibrate': '持续振动',
      'composite': '组合动作',
      'randomFrom': '随机指令集',
    };
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    await emitTasks(tester, ch!, [
      for (final k in kinds.keys)
        _task(
            id: k,
            name: k,
            actionType: 'composite',
            action: {
              'kind': 'composite',
              'primary': {'kind': k},
            }),
      // 未知 kind → 必须落到"未知动作"，不能是空标签。
      _task(
          id: 'unknown',
          name: 'unknown',
          actionType: 'composite',
          action: const {
            'kind': 'composite',
            'primary': {'kind': 'futureKind'},
          }),
    ]);

    for (final e in kinds.entries) {
      expect(find.textContaining('通知 + ${e.value}'), findsOneWidget,
          reason: '主动作 kind=${e.key} 应渲染成「通知 + ${e.value}」');
    }
    expect(find.textContaining('通知 + 未知动作'), findsOneWidget);
    // 反例：任何一条摘要都不该出现「通知 + ·」（空标签后面直接跟分隔符）。
    expect(find.textContaining('通知 + ·'), findsNothing,
        reason: '出现空标签说明 _kindToType 漏登记了某个 kind');
  });

  testWidgets('RTD-08 摘要 · 未知动作类型：空串/null 给兜底名，非空的原样显示',
      (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    await emitTasks(tester, ch!, [
      _task(
          id: 'a',
          name: 'A',
          actionType: 'someFutureAction',
          action: const {'kind': 'tts', 'text': 'x'}),
      _task(
          id: 'b',
          name: 'B',
          actionType: '',
          action: const {'kind': 'tts', 'text': 'x'}),
      {
        ..._task(id: 'c', name: 'C', action: const {'kind': 'tts', 'text': 'x'}),
        'actionType': null,
      },
    ]);
    // 与 RTD-03 同一条契约：非空未知值原样显示，空串/null 才兜底。
    // 注：kind 是 `tts` 时会拼上正文，所以用 `textContaining`。
    expect(find.textContaining('someFutureAction · x'), findsOneWidget,
        reason: '未知但非空 → 原样显示');
    expect(find.textContaining('未知动作 · x'), findsNWidgets(2),
        reason: '空串与 null 都要给兜底名');
  });

  // ══════════════════════════════════════════════════════════════════════
  // RTD-B · 事件与端点切换
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('RTD-09 rc.task 单条回执 → 只解除等待态（不假装刷了列表）',
      (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    await emitTasks(tester, ch!, [_task()]);
    final listBefore = ch.countOfType(RcCmd.taskList);

    await tester.tap(find.byType(Switch)); // 即时操作 → _awaiting = true
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '命令发出后应处于等待态');

    ch.emit(RcEvt.task, {'for': 'x', 'task': _task()});
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'rc.task 到达应解除等待态，否则刷新按钮会一直转圈');
    // ⚠️ 断言"**没有**多拉一次列表"：端点 upsert 后只推这一条单任务回执，
    // 列表刷新由保存路径负责（见 RTD-11）。这里顺手把契约钉住，
    // 免得有人以为 rc.task 会顺带刷新。
    expect(ch.countOfType(RcCmd.taskList), listBefore);
  });

  testWidgets('RTD-10 切换目标端点 → 清空旧端点数据并重新拉取', (tester) async {
    final ch = await pumpTab(
      tester,
      endpoints: [_ep('dev-a', 'A 机'), _ep('dev-b', 'B 机')],
      selected: 'dev-a',
    );
    await emitTasks(tester, ch!, [_task(name: 'A 机上的任务')]);
    expect(find.text('A 机上的任务'), findsOneWidget);
    final listBefore = ch.countOfType(RcCmd.taskList);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle(); // 菜单展开（此时还没触发 refresh）
    await tester.tap(find.text('B 机').last);
    await tester.pump(); // onChanged → setState + refresh
    await tester.pump(const Duration(seconds: 3)); // refresh 的 2s 兜底延迟

    // 旧端点的任务必须**立刻消失** —— 留着就是"张冠李戴"。
    expect(find.text('A 机上的任务'), findsNothing,
        reason: '切换端点后必须清空上一台设备的任务，不能继续展示');
    expect(ch.countOfType(RcCmd.taskList), greaterThan(listBefore),
        reason: '切到新端点要重新拉它的任务列表');
    expect(find.textContaining('端点暂无自动化任务'), findsOneWidget);
  });

  // ══════════════════════════════════════════════════════════════════════
  // RTD-C · 编辑入口（`_openEditor` 的三条路径）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('RTD-11 新建端点任务 → 打开编辑器 → 保存成功必须刷新并确认（BUG-073）',
      (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    final listBefore = ch!.countOfType(RcCmd.taskList);

    await tester.tap(find.text('新建端点任务'));
    await tester.pumpAndSettle(); // 编辑器路由动画（编辑器本身无无限动画）
    expect(find.text('新建端点任务 · A 机'), findsOneWidget,
        reason: '编辑器应以远程目标模式打开，标题写明是哪台端点');

    await tester.tap(find.text('保存任务'));
    await tester.pump();

    final up = ch.lastOfType(RcCmd.taskUpsert);
    expect((up.payload['task'] as Map)['name'], isNotNull,
        reason: '保存必须走 task.upsert 并带上线格式任务');

    ch.emit(RcEvt.ack, {'ok': true, 'for': up.id});
    await tester.pump(); // ack → completer 完成 → 编辑器 pop(true)
    await tester.pump(const Duration(milliseconds: 500)); // 路由退场
    await tester.pump(const Duration(seconds: 3)); // refresh 的 2s 兜底延迟
    await tester.pump(); // 让 snack 渲染

    // ⚠️ 这两条是 BUG-073 的回归锁：编辑器原先 `pop()` 不带结果 →
    // `_openEditor` 里 `saved == true` 恒假 → **任务写进端点了，但列表不刷新、
    // 也没有任何确认**，用户以为没保存成功。与"离线入队被误报成功"相反，
    // 这是**成功被误报成沉默**。
    expect(ch.countOfType(RcCmd.taskList), greaterThan(listBefore),
        reason: '保存成功后必须重新拉列表（BUG-073：否则用户看不到刚建的任务）');
    expect(find.textContaining('已写入端点'), findsOneWidget,
        reason: '保存成功必须有确认（BUG-073：否则成功等于沉默）');
  });

  testWidgets('RTD-12 编辑已有任务 → 正常解析 → 编辑器带着原定义打开', (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    // ⚠️ 这条用例的真正价值是**钉住线格式的形状**：`trigger` 里必须带 `kind`。
    // 首跑时夹具漏了 `kind`，`TriggerConfig.fromJson` 抛
    // `未知触发类型: null` → `TaskWire.fromWire` 的 `on Object` 把它吞成 null
    // → 编辑器不打开、只弹一句"无法解析"。**症状（打不开）离根因（少一个键）
    // 很远**，所以留在这里当回归锁。
    await emitTasks(tester, ch!, [
      _task(id: 't1', name: '端点上的任务'),
    ]);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('编辑端点任务 · A 机'), findsOneWidget);
    // 回填证据：名字进输入框（说明 `TaskWire.fromWire` 真的解析出了 Task）。
    expect(find.widgetWithText(TextFormField, '端点上的任务'), findsOneWidget);
  });

  testWidgets('RTD-19 编辑已有任务 → `trigger` 缺 `kind` → 明说无法解析（协议不匹配的真实形状）',
      (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    // 模拟"对端用了另一套线格式"：外层 `triggerType` 齐全、`trigger` 里没有
    // `kind`。这正是 RTD-12 首跑时的形状 —— 端点侧**不会**报错，只会拒。
    final wire = _task(id: 't1', name: '缺 kind');
    (wire['trigger'] as Map).remove('kind');
    await emitTasks(tester, ch!, [wire]);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.textContaining('无法解析'), findsOneWidget,
        reason: '协议不匹配要明说，不能静默什么都不发生');
    expect(find.textContaining('编辑端点任务'), findsNothing,
        reason: '解析失败就不该进编辑器（否则会拿一份空白定义覆盖端点）');
  });

  testWidgets('RTD-13 编辑已有任务 → 定义解析不了 → 明说，且不打开空白编辑器',
      (tester) async {
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    // `TaskWire.fromWire` 在 id 为空时返回 null → 走"解析失败"分支。
    await emitTasks(tester, ch!, [_task(id: '')]);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.textContaining('无法解析'), findsOneWidget,
        reason: '解析不了必须说清楚，不能打开一个空白编辑器让用户"以为任务空了"');
    expect(find.textContaining('编辑端点任务'), findsNothing,
        reason: '解析失败就不该进编辑器');
  });

  // ══════════════════════════════════════════════════════════════════════
  // RTD-D · 生产路径（`widget.channel == null` → `RcEndpointService.instance`）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('RTD-14 未注入通道（生产路径）· 端点离线 → 明说"已入队"而不是静默',
      (tester) async {
    // 宿主上 `RcEndpointService.instance` 的 `_client` 为 null →
    // `sendTo` 走"入队 + 返回 false"，这正是真机离线时的同一条分支。
    await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')], injectChannel: false);

    // ⚠️ **断言要在它还在屏上时做**：SnackBar 只显示 4 秒，先 `drainSnacks`
    // 再断言的话它已经被挤下屏幕了（首跑就踩了这个 —— 报"找不到文案"，
    // 看着像功能坏了，其实是断言时机错了）。
    expect(find.textContaining('端点离线：命令已入队'), findsOneWidget,
        reason: '命令没发出去必须告知，不能假装已生效');

    // 收尾：`refresh()` 的 2 秒兜底 Timer + 两条 SnackBar 的 4 秒显示 Timer
    // 都还在排队，不冲掉用例结束时会报「A Timer is still pending」。
    await drainSnacks(tester);
    await tester.pumpAndSettle();
  });

  testWidgets('RTD-15 未注入通道 · 等回执的写操作发不出去 → 编辑器明说未确认',
      (tester) async {
    await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')], injectChannel: false);
    // 先把 refresh 失败弹出的两条 SnackBar 排空，否则下面那条会被排队挡住
    // （SnackBar 是串行的 —— 这是本文件最容易被误判成"文案没出现"的坑）。
    await drainSnacks(tester);

    await tester.tap(find.text('新建端点任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存任务'));
    await tester.pump(); // _save() 走到 await remote.save(...)
    await tester.pump(const Duration(milliseconds: 400)); // SnackBar 入场动画

    expect(find.textContaining('端点未确认（离线或拒绝该定义）'), findsOneWidget,
        reason: '写操作拿不到回执时必须说"未写入端点"，不能当成功');
    expect(find.text('新建端点任务 · A 机'), findsOneWidget,
        reason: '未确认时编辑器不能关 —— 关掉等于告诉用户"存上了"');

    // 收尾：编辑器这条 SnackBar 的 4 秒显示 Timer。
    await drainSnacks(tester);
    await tester.pumpAndSettle();
  });

  testWidgets('RTD-16 卸载时仍有未决回执 → 不悬挂、不抛异常', (tester) async {
    // ⚠️ **断言强度说明（不装作更强）**：`_acks` 是私有状态，宿主层观测不到
    // "completer 是否被 complete"。本用例能证明的是**这一行确实被执行了**
    // （覆盖率是真的）且不会留下未捕获异常；它**不能**证明 completer 一定被补了值。
    // 之所以还留着：这条 `dispose` 路径在真机上是"用户删任务删到一半退出页面"，
    // 悬挂的 Completer 会让 `_sendAwait` 的 Future 永远不完成。
    final ch = await pumpTab(tester, endpoints: [_ep('dev-a', 'A 机')]);
    await emitTasks(tester, ch!, [_task()]);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump(); // `_sendAwait` 挂起，等一个永远不会来的 ack

    await tester.pumpWidget(const SizedBox()); // 卸载页面
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // ══════════════════════════════════════════════════════════════════════
  // RTD-E · 空态引导按钮真的能跳页（按钮跳不动是"看着有功能、实际没有"）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('RTD-17 空态「去配对」→ 真的跳到配对页（不是死按钮）', (tester) async {
    final ch = _FakeChannel();
    addTearDown(ch.dispose);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        // 同样包一层 Scaffold 还原生产形状（见 `pumpTab` 的注记）。
        GoRoute(
            path: '/',
            builder: (_, __) => Scaffold(body: RemoteTasksTab(channel: ch))),
        GoRoute(
            path: '/remote/pair-qr',
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('PAIR-QR-PAGE')))),
        GoRoute(
            path: '/remote/settings',
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('REMOTE-SETTINGS-PAGE')))),
      ],
    );
    await tester.pumpWidget(
        ProviderScope(child: MaterialApp.router(routerConfig: router)));
    await tester.pump();

    expect(find.text('尚未配对端点设备'), findsOneWidget);
    await tester.tap(find.text('去配对'));
    await tester.pumpAndSettle();
    expect(find.text('PAIR-QR-PAGE'), findsOneWidget,
        reason: '引导按钮必须真的能到达目标页');
  });

  testWidgets('RTD-18 未开启「去开启」→ 真的跳到远程设置页（不是死按钮）',
      (tester) async {
    final ch = _FakeChannel();
    addTearDown(ch.dispose);
    SharedPreferences.setMockInitialValues({});
    final store = RemoteStore(await SharedPreferences.getInstance());
    await store.addPaired(_ep('dev-a', 'A 机'));
    // 故意不 setEnabled(true) → 走"远程模块未开启"分支。
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        // 同样包一层 Scaffold 还原生产形状（见 `pumpTab` 的注记）。
        GoRoute(
            path: '/',
            builder: (_, __) => Scaffold(body: RemoteTasksTab(channel: ch))),
        GoRoute(
            path: '/remote/pair-qr',
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('PAIR-QR-PAGE')))),
        GoRoute(
            path: '/remote/settings',
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('REMOTE-SETTINGS-PAGE')))),
      ],
    );
    await tester.pumpWidget(
        ProviderScope(child: MaterialApp.router(routerConfig: router)));
    await tester.pump();

    expect(find.text('远程模块未开启'), findsOneWidget);
    await tester.tap(find.text('去开启'));
    await tester.pumpAndSettle();
    expect(find.text('REMOTE-SETTINGS-PAGE'), findsOneWidget,
        reason: '引导按钮必须真的能到达目标页');

    // 收尾：`_load()` 里 `_selectedId` 非空 → `refresh()` 起了 2 秒兜底 Timer
    // （即使页面在 `_disabled()` 分支也照起）。不冲掉会在用例结束时报
    // 「A Timer is still pending even after the widget tree was disposed」。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
