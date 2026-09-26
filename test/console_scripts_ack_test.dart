import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/remote_scripts_tab.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 指令组 Tab 的 R-4 修复锁：**「已发送」不等于「被执行」**。
///
/// 两个缺口此前都没有消费者：
/// 1. 端点校验失败（如"已有指令组在执行"）会回 `rc.ack{forType:'script.run',
///    ok:false}` —— 本页只处理 `rc.script` ⇒ 用户看到"已发送，进度见下方"，
///    而端点**压根没开始跑**；
/// 2. 终态 `state:done` 现在恒带 `skipped`（未执行步骤说明）—— 不消费的话
///    「跑完了」与「跑完了但 3 步没做」在界面上完全一样。
///
/// ⚠️ 本文件**不要用 `pumpAndSettle`**：进度卡里是 `CircularProgressIndicator`
/// （无限动画），会直接超时。用显式 `pump(duration)` 推固定帧。
void main() {
  const scriptId = 'sc-1';
  final saved = jsonEncode([
    {
      'id': 'saved-1',
      'name': '回家提醒',
      'savedAt': 1700000000000,
      'payload': {
        'scriptId': scriptId,
        'name': '回家提醒',
        'fromName': '我',
        'sentAt': 1700000000000,
        'steps': [
          {'kind': 'tts', 'text': '到家了', 'volume': 0.8},
          {'kind': 'delay', 'seconds': 2},
          {'kind': 'notify', 'title': '已到家'},
        ],
      },
    }
  ]);

  late StreamController<Map<String, dynamic>> bus;

  setUp(() {
    SharedPreferences.setMockInitialValues({'rc_scripts': saved});
    bus = StreamController<Map<String, dynamic>>.broadcast();
  });

  tearDown(() async => bus.close());

  /// 推进固定帧数（避开无限动画的 `pumpAndSettle`）。
  Future<void> frames(WidgetTester tester, [int n = 4]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> pump(WidgetTester tester,
      {List<String> pairedIds = const [], String selected = ''}) async {
    if (pairedIds.isNotEmpty) {
      final store = RemoteStore(await SharedPreferences.getInstance());
      for (final id in pairedIds) {
        await store.addPaired(PairedEndpoint(
            deviceId: id, name: id, secret: 's', pairedAt: DateTime.now()));
      }
      if (selected.isNotEmpty) await store.setSelectedEndpoint(selected);
    }
    final view = tester.view;
    view.physicalSize = const Size(1200, 4000);
    view.devicePixelRatio = 1.0;
    addTearDown(view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: RemoteScriptsTab(events: bus.stream)),
    ));
    await frames(tester);
  }

  void emit(String type, Map<String, dynamic> payload) => bus.add({
        'type': type,
        'payload': payload,
      });

  /// 带 `peerId` 的事件（端点广播的事件在控制器侧会被附上发送方 deviceId）。
  void emitPeer(String type, Map<String, dynamic> payload, String peerId) =>
      bus.add({'type': type, 'payload': payload, 'peerId': peerId});

  testWidgets('CS-01 端点拒绝执行（rc.ack ok=false）→ 明确说出原因，而不是"已发送"',
      (tester) async {
    await pump(tester);
    expect(find.text('回家提醒'), findsOneWidget);

    // 端点的真实回执（endpoint_service._runScript 的"已有指令组在执行"分支）。
    emit(RcEvt.ack, {
      'forType': RcCmd.scriptRun,
      'ok': false,
      'for': 'cmd-1',
      'data': '已有指令组在执行',
    });
    await frames(tester);

    expect(find.textContaining('端点未执行指令组：已有指令组在执行'), findsOneWidget,
        reason: '发出去 ≠ 被执行；端点的拒绝必须被消费，否则界面在说谎');
  });

  testWidgets('CS-02 与指令组无关的 ack（或成功 ack）不得误报', (tester) async {
    await pump(tester);

    emit(RcEvt.ack, {'forType': RcCmd.scriptRun, 'ok': true, 'for': 'cmd-1'});
    emit(RcEvt.ack,
        {'forType': RcCmd.taskDelete, 'ok': false, 'for': 'cmd-2', 'data': '任务不存在'});
    await frames(tester);

    expect(find.byType(SnackBar), findsNothing,
        reason: '只有"指令组被拒"才提示；其它 ack 与本页无关，弹出来就是噪声');
  });

  testWidgets('CS-03 终态带 skipped → 明确说"其中 N 步未执行：原因"（与"真的跑完"可区分）',
      (tester) async {
    await pump(tester);
    emit(RcEvt.scriptState,
        {'scriptId': scriptId, 'state': 'running', 'stepIndex': 0});
    await frames(tester);
    expect(find.textContaining('执行中'), findsWidgets);

    // 端点的真实终态载荷（rcScriptStatePayload：skipped 恒存在）。
    emit(RcEvt.scriptState, {
      'scriptId': scriptId,
      'state': 'done',
      'skipped': [
        '步骤 1（play）未执行：端点音源库为空',
        '步骤 3（record）未执行：麦克风权限未授予（需端点在前台授权）',
      ],
    });
    await frames(tester);

    // ① 列表副标题（持久可见，不随进度卡消失）；
    expect(
        find.textContaining('已收藏 · 我 · 已完成 · 其中 2 步未执行：步骤 1（play）未执行：端点音源库为空'),
        findsOneWidget,
        reason: '副标题必须带上跳过说明，否则"跑完了"与"跑完了但 2 步没做"看起来一样');
    // ② 一次性提示（模板不在本机时也能看到）。
    expect(find.textContaining('指令组跑完，其中 2 步未执行：'), findsOneWidget);
    expect(find.textContaining('执行中'), findsNothing);
  });

  testWidgets('CS-04 终态 skipped 为空 → 不得冒出"其中 N 步未执行"（防误报）',
      (tester) async {
    await pump(tester);
    emit(RcEvt.scriptState,
        {'scriptId': scriptId, 'state': 'running', 'stepIndex': 0});
    await frames(tester);

    emit(RcEvt.scriptState,
        {'scriptId': scriptId, 'state': 'done', 'skipped': const <String>[]});
    await frames(tester);

    expect(find.textContaining('已收藏 · 我 · 已完成'), findsOneWidget);
    expect(find.textContaining('其中'), findsNothing,
        reason: '全部步骤都做了就不该提"未执行"');
  });

  testWidgets('CS-05 被终止（stopped）同样带 skipped → 也要说出来（只认 done 会漏）',
      (tester) async {
    await pump(tester);
    emit(RcEvt.scriptState, {
      'scriptId': scriptId,
      'state': 'stopped',
      'skipped': ['步骤 2（tts）未执行：端点未装配语音播报能力'],
    });
    await frames(tester);

    expect(find.textContaining('已终止 · 其中 1 步未执行：步骤 2（tts）未执行'),
        findsOneWidget,
        reason: '被终止时跳过的那几步同样不能无声消失');
  });

  testWidgets('CS-06 另一台端点的 rc.script 不得混进本页（R-5 同类：跨设备串台）',
      (tester) async {
    await pump(tester, pairedIds: ['dev-a', 'dev-b'], selected: 'dev-a');
    expect(find.text('回家提醒'), findsOneWidget);

    // dev-b 的进度（本页目标是 dev-a）—— `rc.script` 是端点**广播**的事件，
    // 控制器侧会附上 peerId，不看它就会张冠李戴。
    emitPeer(RcEvt.scriptState,
        {'scriptId': scriptId, 'state': 'running', 'stepIndex': 1}, 'dev-b');
    await frames(tester);
    expect(find.textContaining('执行中'), findsNothing,
        reason: '另一台的进度不得混进本页 —— A 的模板会显示 B 的进度');

    emitPeer(RcEvt.scriptState,
        {'scriptId': scriptId, 'state': 'running', 'stepIndex': 1}, 'dev-a');
    await frames(tester);
    expect(find.textContaining('执行中 · 第 2/3 步'), findsWidgets,
        reason: '本目标的进度必须照常显示（不能过度过滤）');
  });
}
