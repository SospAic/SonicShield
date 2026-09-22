/// 每例上限（文件级注解）：本文件无 DB I/O，纯 prefs + widget，正常 1s 内跑完。
/// 给 60s 是为了让"万一挂死"快速暴露 —— `testWidgets` 的默认上限是 **10 分钟**，
/// 一个用例挂住就吃掉整轮迭代时间。
///
/// ⚠️ `library;` 指令必须**先于所有 import**（`library_directive_not_first`），
/// 所以它和注解只能放文件最顶部 —— 不能跟在 import 后面。
@Timeout(Duration(seconds: 60))
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/script_builder_screen.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 指令组装器（`/remote/script-builder/:endpointId`）的宿主测试。
///
/// ## 宿主硬约束（改本文件前先读这四条）
///
/// 1. **不 mock store**：`SharedPreferences.setMockInitialValues({})` 之后 prefs
///    是内存实现，`initState` 里的 `await SharedPreferences.getInstance()` 能正常
///    推进 → 直接用真实 `RemoteStore.addPaired()` 造夹具，比打桩更接近真机。
///    这也顺带覆盖了 `_load()` / `_send()` 里那两处 `getInstance()`。
///
/// 2. **`ok == true` 这一侧宿主不可达**：`_send()` 最终走
///    `RcControllerService.sendScript → RcEndpointService.sendTo`，而宿主没有 MQTT
///    客户端（`_client == null`）→ `sendTo` **恒返回 false**（并 `store.enqueue`）。
///    所以「发送成功 → `Navigator.pop()`」只能由设备层覆盖，宿主只锁失败侧。
///
/// 3. **`saveFirst: true` 没有 UI 入口**：全仓 `saveFirst` 只出现在本页，
///    唯一调用点是 `onPressed: _send`（无参）→ `if (saveFirst)` **恒假**。
///    结构不可达 —— 不要试图覆盖，也不要删（登记在 docs/17 §50）。
///
/// 4. 加步骤会把「添加步骤」chips 往下推（同一个 `ListView` 的 children），
///    步骤多时要先 `ensureVisible` 再 `tap`，否则 `tap()` 派生的 Offset 落在
///    视口外（`A call to tap() ... would not hit test`）。
const _viewport = Size(1200, 4000);

PairedEndpoint _ep(String id, String name) => PairedEndpoint(
    deviceId: id, name: name, secret: 'AB2CD5EF', pairedAt: DateTime.now());

Future<RemoteStore> _pump(
  WidgetTester tester, {
  String endpointId = 'devA',
  List<PairedEndpoint> endpoints = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = RemoteStore(await SharedPreferences.getInstance());
  for (final e in endpoints) {
    await store.addPaired(e);
  }

  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: ScriptBuilderScreen(endpointId: endpointId))));
  await tester.pumpAndSettle();
  return store;
}

/// 页面上的步骤卡片标题，按显示顺序。
List<String> _order(WidgetTester tester) => tester
    .widgetList<ListTile>(find.byType(ListTile))
    .map((t) => (t.title! as Text).data!)
    .toList();

Finder _tile(String describe) => find.widgetWithText(ListTile, describe);

Future<void> _addStep(WidgetTester tester, String label) async {
  final f = find.widgetWithText(ActionChip, label);
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _tapStepBtn(
    WidgetTester tester, String describe, IconData icon) async {
  final f =
      find.descendant(of: _tile(describe), matching: find.byIcon(icon));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester) async {
  await tester.ensureVisible(find.text('发送并立即执行'));
  await tester.tap(find.text('发送并立即执行'));
  await tester.pumpAndSettle();
}

/// 打开编辑对话框。`text` 为空则不改输入框（只读初始值 / 取消）。
Future<void> _editStep(WidgetTester tester, String describe,
    {String? text, bool confirm = true}) async {
  await tester.ensureVisible(_tile(describe));
  await tester.tap(_tile(describe));
  await tester.pumpAndSettle();
  if (text != null) {
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        text);
  }
  await tester.tap(find.text(confirm ? '确定' : '取消'));
  await tester.pumpAndSettle();
}

/// 当前编辑框里的文本（打开对话框后立即读）。
String _dialogText(WidgetTester tester) => tester
    .widget<TextField>(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField)))
    .controller!
    .text;

void main() {
  group('SBS 指令组装器', () {
    testWidgets('SBS-01 初始渲染：六种元素齐全 + 空态引导 + 名称有默认值',
        (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);

      expect(find.text('指令组装器 → 客厅音箱'), findsOneWidget);
      expect(find.text('步骤（共 0）'), findsOneWidget);
      expect(find.textContaining('从下方添加动作与时延元素'), findsOneWidget);
      expect(find.textContaining('合规提示'), findsOneWidget);

      // 六种元素一个都不能少 —— 缺一种用户就少一种能力，且不会报错。
      for (final l in ['随机播放', '语音播报', '通知', '震动', '录音取证', '时延']) {
        expect(find.widgetWithText(ActionChip, l), findsOneWidget,
            reason: '缺少元素「$l」');
      }

      // 名称有默认值，用户不填也能发。
      expect(
          tester
              .widget<TextField>(find.byType(TextField))
              .controller!
              .text,
          '远程指令组');
    });

    testWidgets('SBS-02 端点不存在：标题留「…」，发送时明确拒绝而不是静默', (tester) async {
      await _pump(tester,
          endpointId: 'ghost', endpoints: [_ep('devA', '客厅音箱')]);

      // 查不到就显示「…」—— 不能显示成别的端点名（那会让用户以为发给了它）。
      expect(find.text('指令组装器 → …'), findsOneWidget);
      expect(find.textContaining('客厅音箱'), findsNothing);

      await _addStep(tester, '震动');
      await _send(tester);
      expect(find.text('端点不存在'), findsOneWidget);
    });

    testWidgets('SBS-03 六种元素的描述文案（展示类写错不抛异常，只能靠锁）',
        (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      for (final l in ['随机播放', '语音播报', '通知', '震动', '录音取证', '时延']) {
        await _addStep(tester, l);
      }

      expect(find.text('步骤（共 6）'), findsOneWidget);
      expect(_order(tester), [
        '播放 10s',
        '播报「请注意，声盾远程指令」',
        '通知「声盾」',
        '震动',
        '录音取证 30s',
        '等待 5s',
      ]);
    });

    testWidgets('SBS-04 上移/下移：越界不动、中间真的交换', (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '震动');
      await _addStep(tester, '录音取证');

      // 首条上移 → 越界，必须原样（不能把最后一条搬到最前）。
      await _tapStepBtn(tester, '震动', Icons.arrow_upward);
      expect(_order(tester), ['震动', '录音取证 30s']);

      // 末条下移 → 越界。
      await _tapStepBtn(tester, '录音取证 30s', Icons.arrow_downward);
      expect(_order(tester), ['震动', '录音取证 30s']);

      // 末条上移 → 真的交换。
      await _tapStepBtn(tester, '录音取证 30s', Icons.arrow_upward);
      expect(_order(tester), ['录音取证 30s', '震动']);
    });

    testWidgets('SBS-05 删除只删这一条', (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '震动');
      await _addStep(tester, '录音取证');
      await _addStep(tester, '时延');

      await _tapStepBtn(tester, '录音取证 30s', Icons.delete_outline);

      expect(_order(tester), ['震动', '等待 5s']);
      expect(find.text('步骤（共 2）'), findsOneWidget);
    });

    testWidgets('SBS-06 编辑语音播报文本：改完列表上要看得见', (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '语音播报');

      await _editStep(tester, '播报「请注意，声盾远程指令」', text: '楼下集合');

      expect(_order(tester), ['播报「楼下集合」']);
    });

    testWidgets('SBS-07 编辑取消：一个字符都不许落', (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '语音播报');

      await _editStep(tester, '播报「请注意，声盾远程指令」',
          text: '不该生效', confirm: false);

      expect(_order(tester), ['播报「请注意，声盾远程指令」']);
    });

    testWidgets('SBS-08a 编辑「录音取证」：初始值是当前秒数，改完跟着变',
        (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '录音取证');

      await tester.tap(_tile('录音取证 30s'));
      await tester.pumpAndSettle();
      // 初始值必须是当前值，否则用户看不到自己在改什么。
      expect(_dialogText(tester), '30');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await _editStep(tester, '录音取证 30s', text: '45');
      expect(_order(tester), ['录音取证 45s']);
    });

    testWidgets('SBS-08b 编辑「时延」：初始值是当前秒数，支持小数',
        (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '时延');

      await tester.tap(_tile('等待 5s'));
      await tester.pumpAndSettle();
      expect(_dialogText(tester), '5');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await _editStep(tester, '等待 5s', text: '2.5');
      expect(_order(tester), ['等待 2.5s']);
    });

    testWidgets('SBS-08c 编辑「随机播放」：框里要显示当前时长（BUG-068 复发锁）',
        (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '随机播放');

      await tester.tap(_tile('播放 10s'));
      await tester.pumpAndSettle();
      // BUG-068：时长存在 `durationSec` 里，旧写法用 `??` 链取
      // text/title/seconds → 一个都取不到 → 框是空的，用户看不到自己在改什么。
      expect(_dialogText(tester), '10');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await _editStep(tester, '播放 10s', text: '20');
      expect(_order(tester), ['播放 20s']);
    });

    testWidgets('SBS-08d 编辑「通知」：框里要显示「通知内容」而不是标题（BUG-068 复发锁）',
        (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '通知');

      await tester.tap(_tile('通知「声盾」'));
      await tester.pumpAndSettle();
      // BUG-068：标签写着「通知内容」、写回 `body`，旧写法却读 `title` ——
      // 读写不是同一个字段，用户以为在改内容，框里显示的却是标题。
      expect(_dialogText(tester), '远程通知内容');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
    });

    testWidgets('SBS-08f 【登记项】改「通知内容」后列表标题仍取 title —— 待产品决策',
        (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '通知');

      await _editStep(tester, '通知「声盾」', text: '车库有异响');

      // 实测：`RcStep.describe()` 对 notify 取的是 `title`，所以改了 `body`
      // 列表上看不出任何变化 —— 用户无法确认自己改上了没有。
      //
      // 这是**展示层不一致**（不崩溃、数据也没错），修它要动 `RcStep.describe()`
      // 的展示契约（通知栏 / 端点弹窗共用，docs/14）→ 登记待产品决策，不擅自改。
      //
      // 本用例的作用：一旦有人改了 `describe()`，这里会红，逼他回来读这段原因。
      expect(_order(tester), ['通知「声盾」']);
    });

    testWidgets('SBS-08e 编辑「震动」：v1.9 起有模式选择器，默认仍是固定节奏',
        (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '震动');

      await tester.tap(_tile('震动'));
      await tester.pumpAndSettle();
      // v1.8 及以前这里是「（无可编辑参数）」；v1.9 起振动可参数化
      // （docs/20 §10.1）。默认模式仍是 `fixed` → 明确告知"固定节奏无可编辑
      // 参数"，同时把模式选择器摆出来，而不是给一个空白框让用户猜。
      expect(find.textContaining('固定节奏无可编辑参数'), findsOneWidget);
      expect(find.text('振动模式'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      // 不动任何东西 → 参数保持 `{}`（老控制器线格式一字不变）。
      expect(_order(tester), ['震动']);
    });

    testWidgets('SBS-09 空指令组：直接拒绝，不发空包', (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);

      await _send(tester);

      expect(find.text('指令组为空'), findsOneWidget);
    });

    testWidgets('SBS-10 时延越界：拒绝并说明范围', (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '时延');
      await _editStep(tester, '等待 5s', text: '0.1');

      await _send(tester);

      expect(find.text('时延超出范围（0.5–600 秒/步）'), findsOneWidget);
    });

    testWidgets('SBS-11 合法但端点离线：如实说失败、留在本页、且留下待发记录',
        (tester) async {
      final store = await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '震动');

      await _send(tester);

      // 宿主无 MQTT → sendTo 恒 false，界面必须如实说失败（不能假装成功）。
      expect(find.text('发送失败（端点离线或未连接）'), findsOneWidget);
      // 失败不能把用户从页面上踢走 —— 否则他刚编的指令组就没了。
      expect(find.text('指令组装器 → 客厅音箱'), findsOneWidget);

      // 「失败必须留痕」：outbox 里应有一条待发记录（上线后自动冲刷）。
      expect(store.outbox(), hasLength(1));
      expect(store.outbox().first['endpointId'], 'devA');
    });
  });

  group('SBS-V 振动步骤参数化（v1.9，docs/20 §10.1）', () {
    Future<void> openVibrate(WidgetTester tester) async {
      await tester.tap(_tile('震动'));
      await tester.pumpAndSettle();
    }

    Future<void> pickMode(WidgetTester tester, String label) async {
      await tester.tap(find.byType(DropdownButton<RcVibrateMode>));
      await tester.pumpAndSettle();
      // 菜单项与按钮上的当前值同名 → 取 overlay 里那一个（后插入）。
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    /// 按**标签**定位字段，而不是按下标 —— 下标顺序依赖 build 顺序，
    /// 一旦字段重排就会静默改错别的字段（BUG-068 同类）。
    Future<void> fill(WidgetTester tester, String label, String value) async {
      final f =
          find.ancestor(of: find.text(label), matching: find.byType(TextField));
      expect(f, findsOneWidget, reason: '对话框里找不到字段「$label」');
      await tester.ensureVisible(f);
      await tester.enterText(f, value);
      await tester.pump();
    }

    testWidgets('SBS-V01 切到随机脉冲 → 填参数 → 标题反映实际生效值', (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '震动');
      await openVibrate(tester);

      expect(find.textContaining('固定节奏无可编辑参数'), findsOneWidget);
      await pickMode(tester, '随机脉冲');

      // 字段由 `rcVibrateFieldsFor(mode)` 生成 —— 与执行器**同一份声明**。
      expect(find.textContaining('固定节奏无可编辑参数'), findsNothing);
      await fill(tester, '最短时长（秒）', '5');
      await fill(tester, '最长时长（秒）', '20');
      await fill(tester, '最高强度（0–1）', '0.8');

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      final title = _order(tester).single;
      expect(title, contains('随机振动'));
      expect(title, contains('5–20 秒'));
      expect(title, contains('80%'));
    });

    testWidgets('SBS-V02 取消：切了模式也不落盘', (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '震动');
      await openVibrate(tester);

      await pickMode(tester, '持续振动');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(_order(tester), ['震动']);
    });

    testWidgets('SBS-V03 持续振动：强度区间与波动周期进入标题', (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '震动');
      await openVibrate(tester);

      await pickMode(tester, '持续振动');
      await fill(tester, '最短时长（秒）', '10');
      await fill(tester, '最长时长（秒）', '30');
      await fill(tester, '最低强度（0–1）', '0.5');
      await fill(tester, '最高强度（0–1）', '1');
      await fill(tester, '强度波动周期（毫秒，0=恒定）', '800');

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      final title = _order(tester).single;
      expect(title, contains('持续振动 10–30 秒'));
      expect(title, contains('50%'));
      expect(title, contains('波动 800ms'));
    });

    testWidgets('SBS-V04 振动时长计入 30 分钟预算 → 超限即拒发', (tester) async {
      await _pump(tester, endpoints: [_ep('devA', '客厅音箱')]);
      await _addStep(tester, '震动');
      await openVibrate(tester);
      await pickMode(tester, '持续振动');
      // 单段 30 分钟正好卡在上限内（取区间**上界**判定）。
      await fill(tester, '最短时长（秒）', '1800');
      await fill(tester, '最长时长（秒）', '1800');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      // 再加 10 分钟时延 → 合计 40 分钟 → 必须拒绝。
      // ⚠️ 只发**一次**：SnackBar 是排队显示的，连发两次时第二次要等第一条
      // 超时（4s）才出现，`pumpAndSettle` 会把这一条读成"没弹出"。
      await _addStep(tester, '时延');
      await _editStep(tester, '等待 5s', text: '600');
      await _send(tester);

      expect(find.text('时延与振动合计超过 30 分钟上限'), findsOneWidget);
    });
  });
}
