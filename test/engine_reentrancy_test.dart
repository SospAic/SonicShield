import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 引擎主循环重入锁（A2-P0-2 回归锁）。
///
/// ## 缺陷形状
///
/// `executeDue` 原本**没有重入守卫**，且 `markStatus` 在 `runAction`
/// （可阻塞至 1800s）**之后**才写。通道A 有两个**同源可叠加**的触发点 ——
/// `Timer.periodic(SchedulerConfig.engineTick)` 与 `service.on('tick')`
/// —— 于是 15s 到点时会在上一轮 `runAction` 尚未返回的情况下**再起一份**
/// `executeDue`；`OccurrenceRepository.due()` 只筛 `status='pending'`，
/// 那条计划尚未落终态 ⇒ **同一条计划被并发取出、执行两次**（双响 / 重复录音 /
/// 播放器互踩）。
///
/// ## 为什么是**源码契约锁**而不是行为测试
///
/// `executeDue` 只在 `flutter_background_service` 的隔离里运行（真实 DB /
/// 播放器 / TTS / 原生桥），宿主机上**实例化不了**（见
/// `_pt/audit/A1-feature-matrix.md` §3）。所以这里锁**结构**：
///
/// - `executeDue`/`replan` 必须有「同步置位守卫 → try」结构；
/// - 守卫必须在任何 `await` **之前**同步置位（否则并发仍能穿过）；
/// - 守卫必须 `try/finally` 复位（异常路径也要复位，否则一次异常永久卡死引擎）；
/// - `runAction` **之前**必须先乐观置状态（跨 isolate 的第二道防线）。
///
/// ⚠️ 项目铁律：**断言必须非恒真**。见 [REENT-90]：用反面样本证明检测器
/// 确实会判红（否则这些用例就是恒真的假锁）。
void main() {
  final engine = File('lib/services/background_engine.dart').readAsStringSync();

  final dueBody = withoutLineComments(functionBlock(engine, 'Future<void> executeDue()'));
  final replanBody = withoutLineComments(functionBlock(engine, 'Future<void> replan()'));
  // R94：批次循环体搬到了顶层 `executeBatch`（判定与执行解耦，SCH-01）。
  // 「先取走再执行」这条不变量现在落在**批次骨架**里，所以锁也必须跟着搬 ——
  // 否则锁还在检查一个已经不存在的循环体，变成永远判红的假锁。
  final batchBody =
      withoutLineComments(functionBodyBlock(engine, 'Future<void> executeBatch({'));

  // 反击计划续算接线 + 节假日更新解耦（同一批修正，见文件末尾 CEXT 组）。
  final planSvc =
      File('lib/services/counter_plan_service.dart').readAsStringSync();
  final extendBody =
      withoutLineComments(functionBodyBlock(engine, 'Future<void> extendCounterPlan()'));
  final holidayBody = withoutLineComments(
      functionBodyBlock(planSvc, 'Future<CounterApplyResult> refreshHolidays('));

  group('executeDue 重入守卫（源码契约锁）', () {
    test('REENT-00 抽取器锚定到正确的函数（防签名变更后锁空转）', () {
      expect(dueBody, isNotEmpty, reason: '抽不到 executeDue 的函数体 —— 签名变了？');
      expect(replanBody, isNotEmpty, reason: '抽不到 replan 的函数体 —— 签名变了？');
      // 抽到的确实是 executeDue（而不是同名调用点）。
      expect(dueBody, contains('occs.due('));
      expect(dueBody, contains('runAction('));
      // 签名找不到时必须返回空串（调用方据此判红），而不是抛异常/返回别处内容。
      expect(functionBlock(engine, 'Future<void> noSuchFunctionXyz('), isEmpty);
    });

    test('REENT-01 executeDue 存在「同步置位守卫 → try」结构', () {
      expect(entersGuardedTry(dueBody, 'executing'), isTrue,
          reason: 'executeDue 首部必须是 `if (executing) { … return; }` 拦住重入、'
              '同步 `executing = true` 后进入 `try`。缺失即回到 A2-P0-2：'
              '15s tick 重叠时同一条 pending 计划被并发执行两次。');
    });

    test('REENT-02 守卫必须在 finally 复位（不是「return 完事」）', () {
      expect(resetsInFinallyOnly(dueBody, 'executing'), isTrue,
          reason: '`executing = false;` 必须且只能出现在 `} finally { … }` 里。'
              '缺 finally ⇒ 任何一次异常都把守卫永久卡死，引擎从此不再执行任何计划'
              '（比原缺陷更糟）；出现裸复位 ⇒ 结构被改成了「happy path 复位」，'
              '异常路径仍会卡死。');
    });

    test('REENT-03 守卫在第一个 await 之前同步置位', () {
      final setPos = dueBody.indexOf('executing = true');
      final firstAwait = dueBody.indexOf('await ');
      expect(setPos, greaterThanOrEqualTo(0), reason: '找不到 `executing = true`');
      expect(firstAwait, greaterThan(setPos),
          reason: '置位必须先于任何 `await`：Dart 单线程，只有**同步**置位才能对'
              '同 isolate 的重入原子生效。若先 await 再置位，并发仍能穿过窗口。');
    });

    test('REENT-04 执行前必须先取走（CAS 抢占），终态仍由结果决定', () {
      // R94：判据分成两半 ——
      // ① 批次骨架里「claim 在 runAction 之前」；
      // ② executeDue 真的把 CAS（pending → running）接上（否则 claim 是空转）。
      expect(claimsBeforeRunAction(batchBody), isTrue,
          reason: '`executeBatch` 必须在 `runAction` 之前先把该 occurrence 取走'
              '（CAS `pending → running`），使并发（跨连接 / 守卫失效）的第二次 '
              '`due()` 必然取不到它。');
      expect(wiredCasClaim(engine), isTrue,
          reason: '`executeDue` 没有把 CAS 抢占接上：'
              '`claim: (o) => occs.markStatus(o.id, OccurrenceStatus.running, '
              'from: {OccurrenceStatus.pending})` 是跨连接防线的唯一入口。');
      expect(finalStatusFromResult(dueBody), isTrue,
          reason: '正向语义不得改变：最终状态仍必须由 `runAction` 的返回值决定'
              '（`skipped / done / failed` 三态）。这是「不改正向语义」的锁。');
    });

    test('REENT-07 executeDue 必须把批次交给 executeBatch（不是留一段死代码）', () {
      expect(dueBody.contains('executeBatch('), isTrue,
          reason: '抽出的批次骨架必须**被真正调用**：否则 SCH-01 的'
              '「判定与执行解耦」只存在于一个没人用的函数里。');
      expect(dueBody.contains('batchStart: now'), isTrue,
          reason: '批次陈旧判定必须用批次开始时刻（`batchStart`），'
              '不能退回逐条实时 `DateTime.now()`。');
    });

    test('REENT-08 executeBatch 每轮开头复检停机（SCH-07）', () {
      expect(batchBody.contains('if (isStopping()) break;'), isTrue,
          reason: '停机后不得继续起新动作：循环首行必须复检，'
              '否则"关了引擎还在响/还在录"（SCH-07）。');
    });

    test('REENT-05 replan 也有同形守卫（同源可叠加的另一条路径）', () {
      expect(entersGuardedTry(replanBody, 'replanning'), isTrue,
          reason: '`service.on(\'replan\')` 与 tick 续算同源可叠加，replan 必须同形受守卫。');
      expect(resetsInFinallyOnly(replanBody, 'replanning'), isTrue,
          reason: 'replan 的守卫同样必须 try/finally 复位。');
    });

    test('REENT-06 守卫是 _engineBody 内的局部状态（不是顶层全局）', () {
      final engineBodyDecl = engine.indexOf('Future<void> _engineBody(');
      final executeDueDecl = engine.indexOf('Future<void> executeDue()');
      final execDecl = engine.indexOf('bool executing = false;');
      final replanDecl = engine.indexOf('bool replanning = false;');
      expect(engineBodyDecl, greaterThanOrEqualTo(0));
      expect(executeDueDecl, greaterThan(engineBodyDecl));
      // 两个标志都声明在 `_engineBody` 与其内嵌的 `executeDue` 之间 ⇒ 必然在
      // `_engineBody` 体内（与 guardEnabled / lastAction 等其它引擎状态同域）。
      expect(execDecl, greaterThan(engineBodyDecl));
      expect(replanDecl, greaterThan(engineBodyDecl));
      expect(execDecl, lessThan(executeDueDecl));
      expect(replanDecl, lessThan(executeDueDecl));
      // 反向：不得是**顶层**（无缩进）全局变量。
      expect(engine.contains('\nbool executing = false;'), isFalse,
          reason: '守卫应是 _engineBody 内的局部状态，不应是顶层可变全局。');
      expect(engine.contains('\nbool replanning = false;'), isFalse);
    });
  });

  group('锁本身非恒真（检测器自检：这些样本必须被判红）', () {
    test('REENT-90 反面样本必须被检出，正面样本不得误报', () {
      // ---- 反面 1：完全没有守卫 / 没有乐观置状态 ----
      const noGuard = '''
Future<void> executeDue() async {
  final due = await occs.due(now, limit: 3);
  final ok = await runAction(task, 0.8, 0, 'schedule', occurrenceId: o.id);
  await occs.markStatus(o.id, ok ? OccurrenceStatus.done : OccurrenceStatus.failed);
}
''';
      expect(entersGuardedTry(noGuard, 'executing'), isFalse,
          reason: '无守卫必须判红，否则 REENT-01 恒真');
      expect(resetsInFinallyOnly(noGuard, 'executing'), isFalse);
      expect(claimsBeforeRunAction(noGuard), isFalse,
          reason: '没有乐观置状态必须判红，否则 REENT-04 恒真');

      // ---- 反面 2：有进入守卫，但复位在 happy path、没有 finally ----
      const noFinally = '''
Future<void> executeDue() async {
  if (executing) {
    print('reentry');
    return;
  }
  executing = true;
  try {
    final due = await occs.due(now, limit: 3);
    executing = false;
  } catch (e) {
    // 异常路径不复位 —— 守卫会被永久卡死
  }
}
''';
      expect(entersGuardedTry(noFinally, 'executing'), isTrue,
          reason: '这一段进入结构成立（对照用）');
      expect(resetsInFinallyOnly(noFinally, 'executing'), isFalse,
          reason: '复位不在 finally 里 ⇒ 异常路径会永久卡死，必须判红');

      // ---- 反面 3：复位放在 catch 而不是 finally ----
      const resetInCatch = '''
Future<void> executeDue() async {
  if (executing) {
    return;
  }
  executing = true;
  try {
    final due = await occs.due(now, limit: 3);
  } catch (e) {
    executing = false;
  }
}
''';
      expect(resetsInFinallyOnly(resetInCatch, 'executing'), isFalse,
          reason: '复位放在 catch 而不是 finally ⇒ 必须判红');

      // ---- 反面 4：把守卫整段注释掉（锁不能被注释骗过） ----
      const commentedGuard = '''
Future<void> executeDue() async {
  // if (executing) {
  //   return;
  // }
  // executing = true;
  final due = await occs.due(now, limit: 3);
}
''';
      expect(entersGuardedTry(withoutLineComments(commentedGuard), 'executing'), isFalse,
          reason: '注释掉的守卫必须判红 —— 证明锁不会被"注释掉代码"骗过');

      // ---- 反面 5：终态写死 done（与执行结果无关）—— 必须判红 ----
      const statusIgnoringResult = '''
Future<void> executeDue() async {
  final ok = await runAction(task, 0.8, 0, 'schedule', occurrenceId: o.id);
  await occs.markStatus(o.id, OccurrenceStatus.done);
}
''';
      expect(finalStatusFromResult(statusIgnoringResult), isFalse,
          reason: '不看执行结果就写 done ⇒ 失败被记成成功，必须判红');

      // ---- 正面样本：与真实代码同构，必须**不**被误报 ----
      const okSample = '''
Future<void> executeDue() async {
  if (executing) {
    print('reentry');
    return;
  }
  executing = true;
  try {
    final due = await occs.due(now, limit: 3);
    await occs.markStatus(o.id, OccurrenceStatus.failed);
    final outcome = await runAction(task, 0.8, 0, 'schedule', occurrenceId: o.id);
    final ok = outcome.ok;
    final terminal = outcome.isSkipped
        ? OccurrenceStatus.skipped
        : (ok ? OccurrenceStatus.done : OccurrenceStatus.failed);
    await occs.markStatus(o.id, terminal);
  } finally {
    executing = false;
  }
}
''';
      expect(entersGuardedTry(okSample, 'executing'), isTrue, reason: '正面样本不得误报');
      expect(resetsInFinallyOnly(okSample, 'executing'), isTrue, reason: '正面样本不得误报');
      expect(claimsBeforeRunAction(okSample), isTrue, reason: '正面样本不得误报');
      expect(finalStatusFromResult(okSample), isTrue, reason: '正面样本不得误报');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // 反击计划续算接线 + 节假日更新解耦（源码契约锁）
  //
  // ## 两个缺陷形状
  // 1. **节假日更新联动导入反击计划**：`CounterPlanService.refreshHolidays` 在
  //    "计划已启用且有计划本体"时走 `apply(..., replace: true)` —— 按命名空间
  //    **整族删除** counter 任务再整体重建。用户点的是"一键更新节假日"（拉一份
  //    日历数据），却把反击计划整族重建、连**已执行的历史任务**一起删，提示语
  //    还回「反击计划已生效：排入 N 条计划任务」。未声明的副作用 + 不可逆数据损失。
  // 2. **反击计划 7 天后静默停掉**：`CounterPlanService.refreshIfNeeded`（自动续算）
  //    全仓**只有定义、无任何生产调用方**；而引擎的 `replan` 只做**任务级**重算
  //    （`ScheduleEngine` 按每个已存在任务自己的触发器排期），**不认识**「反击计划」
  //    这个概念 ⇒ 无法生成第 8 天起的新反击任务。horizon 用尽后计划仍显示"已启用"
  //    却再也不触发 —— 典型的静默失效。
  //
  // ## 为什么是源码契约锁
  // `_engineBody` 只在 `flutter_background_service` 的隔离里运行（真实 DB /
  // 播放器 / 原生桥），宿主机上实例化不了 ⇒ 这里锁**结构**。与 REENT 组同一纪律：
  // 断言必须**非恒真**，见 CEXT-90 的反面样本（含"把接线注释掉"）。
  // ═══════════════════════════════════════════════════════════════════════
  group('反击计划续算接线 + 节假日更新解耦（源码契约锁）', () {
    test('CEXT-00 抽取器锚定到正确的函数（防签名变更后锁空转）', () {
      expect(extendBody, isNotEmpty,
          reason: '抽不到 `extendCounterPlan` 的函数体 —— 签名变了？');
      expect(holidayBody, isNotEmpty,
          reason: '抽不到 `refreshHolidays` 的函数体 —— 签名变了？');
      expect(extendBody, contains('refreshIfNeeded('),
          reason: '抽到的应确实是 `extendCounterPlan`（它必须调用 `refreshIfNeeded`）');
      expect(holidayBody, contains('setAutoOverrides('),
          reason: '抽到的应确实是 `refreshHolidays`（它必须写自动覆盖表）');
      expect(
          functionBlock(planSvc, 'Future<CounterApplyResult> noSuchFnXyz('), isEmpty);
    });

    test('CEXT-01 续算必须被 tick 与启动序列**真正调用**（不是只有定义）', () {
      expect(wiredExtendInTick(engine), isTrue,
          reason: '引擎 tick 里必须出现 `stepGuarded(\'extendCounterPlan(tick)\', '
              'extendCounterPlan)`。缺它 ⇒ 反击计划物化 7 天用尽后静默停掉（缺陷 2）。');
      expect(wiredExtendAtBoot(engine), isTrue,
          reason: '启动序列里必须同样调用一次（通道B 唤醒 / 看门狗拉起后也要续算）。');
    });

    test('CEXT-02 续算必须排在 replan **之前**', () {
      // 续排只写 `tasks`；计划条目（occurrences）由 `replan` 的 `occs.reconcile`
      // 生成 ⇒ 顺序颠倒会让新任务白等一轮 tick（15s 空窗）。
      final tickExtend = engine.indexOf("stepGuarded('extendCounterPlan(tick)'");
      final tickReplan = engine.indexOf("stepGuarded('replan(tick)'");
      expect(tickExtend, greaterThanOrEqualTo(0));
      expect(tickReplan, greaterThan(tickExtend), reason: 'tick 内：先续算、后 replan');
      final bootExtend = engine.indexOf("stepGuarded('extendCounterPlan'");
      final bootReplan = engine.indexOf("stepGuarded('replan'");
      expect(bootExtend, greaterThanOrEqualTo(0));
      expect(bootReplan, greaterThan(bootExtend), reason: '启动序列内：先续算、后 replan');
    });

    test('CEXT-03 续算必须走 replace=false（只 upsert，绝不删历史）', () {
      expect(extendBody, contains('refreshIfNeeded('));
      final rifBody = functionBodyBlock(
          planSvc, 'Future<CounterApplyResult> refreshIfNeeded(');
      expect(rifBody, isNotEmpty, reason: '抽不到 `refreshIfNeeded` 函数体');
      expect(rifBody, contains('replace: false'),
          reason: '自动续算必须 `replace: false` —— 已执行的历史任务原样保留；'
              '改成 true 就会在每轮 tick 上整族删除重建。');
      expect(rifBody, isNot(contains('replace: true')));
    });

    test('CEXT-04 节假日更新必须与反击计划**完全解耦**', () {
      expect(holidayDecoupled(holidayBody), isTrue,
          reason: '`refreshHolidays` 只能写自动覆盖表：不得调用 `apply(`、'
              '不得 `deleteCounterTasks`、也不得代跑 `refreshIfNeeded`。'
              '新表由"全局暂停窗口实时读表"与"续算通路"两条独立路径生效。');
    });

    test('CEXT-90 ★ 反面样本必须被判红，正面样本不得误报（非恒真守卫）', () {
      // ---- 反面 1：续算只有定义、没接线 ----
      const unwired = '''
Future<void> extendCounterPlan() async {
  final r = await svc.refreshIfNeeded();
}
''';
      expect(wiredExtendInTick(unwired), isFalse,
          reason: '没接线必须判红 —— 证明 CEXT-01 不是恒真');
      expect(wiredExtendAtBoot(unwired), isFalse);

      // ---- 反面 2：节假日更新重新耦合回 apply(replace: true) ----
      const recoupled = '''
Future<CounterApplyResult> refreshHolidays(Map<String, DayKind> autoOv) async {
  await _store.setAutoOverrides(autoOv);
  return apply(plan, planId: _store.planId, replace: true);
}
''';
      expect(holidayDecoupled(recoupled), isFalse,
          reason: '重新耦合必须判红 —— 证明 CEXT-04 不是恒真');

      // ---- 反面 3：续算改成 replace: true（破坏性） ----
      const destructive = '''
Future<CounterApplyResult> refreshIfNeeded() async {
  return apply(plan, planId: id, replace: true);
}
''';
      expect(destructive.contains('replace: false'), isFalse,
          reason: '破坏性续算必须判红 —— 证明 CEXT-03 不是恒真');

      // ---- 反面 4：把接线整行注释掉（锁不能被注释骗过） ----
      const commentedOut = '''
//      await stepGuarded('extendCounterPlan(tick)', extendCounterPlan);
''';
      expect(wiredExtendInTick(commentedOut), isFalse,
          reason: '注释掉的接线必须判红 —— 证明锁不会被"注释掉代码"骗过');

      // ---- 正面样本：与真实代码同构，必须**不**被误报 ----
      const okSample = '''
Future<CounterApplyResult> refreshHolidays(Map<String, DayKind> autoOv) async {
  await _store.setAutoOverrides(autoOv);
  return CounterApplyResult.ok2('已更新节假日表');
}
''';
      expect(holidayDecoupled(okSample), isTrue, reason: '正面样本不得误报');
      const wiredSample = '''
      await stepGuarded('extendCounterPlan(tick)', extendCounterPlan);
''';
      expect(wiredExtendInTick(wiredSample), isTrue, reason: '正面样本不得误报');
    });
  });
}

/// 形态：源码里是否**真正**把反击计划续算接进了引擎 tick。
///
/// ⚠️ 先 `withoutLineComments` 再匹配：本项目有"源码文本锁被注释中毒"的教训
/// （锁用 `indexOf(签名)` ⇒ 注释里写出同样文本即可骗过锁）。见 CEXT-90 反面 4。
bool wiredExtendInTick(String src) => withoutLineComments(src).contains(
    "await stepGuarded('extendCounterPlan(tick)', extendCounterPlan);");

/// 形态：源码里是否**真正**把反击计划续算接进了引擎启动序列。
bool wiredExtendAtBoot(String src) => withoutLineComments(src).contains(
    "await stepGuarded('extendCounterPlan', extendCounterPlan);");

/// 形态：`refreshHolidays` 是否**已与反击计划完全解耦**（只写表）。
///
/// 正面判据：写自动覆盖表；反面判据：不 `apply(` / 不 `deleteCounterTasks` /
/// 不代跑 `refreshIfNeeded`。
bool holidayDecoupled(String body) =>
    body.contains('setAutoOverrides(') &&
    !body.contains('apply(') &&
    !body.contains('deleteCounterTasks') &&
    !body.contains('refreshIfNeeded');

/// 取出 `signature` 之后**函数体**的第一对平衡花括号（含最外层大括号）。
///
/// 与 [functionBlock] 的区别：本函数**先跳过参数表**再从参数表闭合 `)` 之后的
/// 第一个 `{` 开始计数 —— 因为 `refreshHolidays(Map<…> ov, {DateTime? now})`
/// 这类签名里的**具名参数大括号**会被 [functionBlock] 误判成函数体
/// （它只找"签名后第一个 `{`"）。参数表本身无嵌套花括号，故只需配对圆括号。
String functionBodyBlock(String src, String signature) {
  final start = src.indexOf(signature);
  if (start < 0) return '';
  final openParen = src.indexOf('(', start);
  if (openParen < 0) return '';
  var pd = 0;
  var i = openParen;
  for (; i < src.length; i++) {
    final c = src[i];
    if (c == '(') {
      pd++;
    } else if (c == ')') {
      pd--;
      if (pd == 0) break;
    }
  }
  final open = src.indexOf('{', i);
  if (open < 0) return '';
  var depth = 0;
  for (var j = open; j < src.length; j++) {
    final c = src[j];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(open, j + 1);
    }
  }
  return '';
}

/// 取出 `signature` 之后第一对平衡花括号之间的内容（含最外层大括号）。
///
/// 花括号计数**不解析字符串/注释**：只用在本文件里 `executeDue`/`replan` 这两个
/// 函数体上（其字符串中的 `${…}` 都自有配对），够用且不脆弱。
/// 找不到签名（或括号不配平）时返回空串 —— 调用方据此判红，而不是让锁静默空转。
String functionBlock(String src, String signature) {
  final start = src.indexOf(signature);
  if (start < 0) return '';
  final open = src.indexOf('{', start);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(open, i + 1);
    }
  }
  return '';
}

/// 去掉**整行注释**后再做结构匹配。
///
/// 为什么：`} finally { <注释行> executing = false; }` 里的注释会挡住紧邻匹配，
/// 而"注释的有无"不该影响"结构是否存在"；同时这也让"把守卫注释掉"能被判红。
/// 只剔除以 `//` 开头的整行（这些函数体里没有把 `//` 放进字符串的情况），
/// 不做通用解析。
String withoutLineComments(String src) => src
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// 形态：`if (flag) { … return; … } flag = true; try {`。
bool entersGuardedTry(String body, String flag) {
  final pattern = r'if\s*\(\s*' +
      flag +
      r'\s*\)\s*\{[\s\S]*?return;[\s\S]*?\}\s*' +
      flag +
      r'\s*=\s*true\s*;\s*try\s*\{';
  return RegExp(pattern).hasMatch(body);
}

/// 复位必须出现在 `} finally { flag = false; }` 里，且全函数**仅此一处**复位。
bool resetsInFinallyOnly(String body, String flag) {
  final all = RegExp(r'\b' + flag + r'\s*=\s*false\s*;').allMatches(body).length;
  final inFinally =
      RegExp(r'\}\s*finally\s*\{\s*' + flag + r'\s*=\s*false\s*;\s*\}').allMatches(body).length;
  return all == 1 && inFinally == 1;
}

/// 形态：`occs.markStatus(o.id, OccurrenceStatus.failed);` 之后才是 `runAction(`。
///
/// 两种合法形状：
/// - **旧（R94 前）**：乐观置 `failed` 当占用标记；
/// - **新（R94 / SCH-04）**：`claim?.call(o)` 走 CAS（`pending → running`）。
/// 锁的是**顺序**（先取走、后执行），不是某个具体状态值 —— 状态值由
/// `wiredCasClaim` 单独锁住。
bool claimsBeforeRunAction(String body) {
  final legacy = RegExp(
    r'occs\.markStatus\(\s*o\.id\s*,\s*OccurrenceStatus\.failed\s*\)\s*;'
    r'[\s\S]*?await\s+runAction\(',
  ).hasMatch(body);
  final cas = RegExp(
    r'claim\?\.call\(\s*o\s*\)[\s\S]*?await\s+runAction\(',
  ).hasMatch(body);
  return legacy || cas;
}

/// 形态：`executeDue` 把 CAS 抢占接上了（`running` + `from: {pending}`）。
bool wiredCasClaim(String src) {
  final body = withoutLineComments(functionBlock(src, 'Future<void> executeDue()'));
  return RegExp(
    r'OccurrenceStatus\.running[\s\S]{0,80}?from:\s*\{\s*'
    r'OccurrenceStatus\.pending\s*\}',
  ).hasMatch(body);
}

/// 终态由 `runAction` 的结果决定。两种合法形状：
///
/// ① 内联（旧）：`await occs.markStatus(o.id, ok ? done : failed)`；
/// ② 变量（BUG-093 起）：`skipped` 必须单独落成 `skipped`，不能并进 done，
///    于是先算 `final terminal = outcome.isSkipped ? skipped : (ok ? done : failed)`，
///    再 `await occs.markStatus(o.id, terminal, from: …)`（R94 起带 CAS 条件）。
///
/// 锁的是**语义**（终态由执行结果派生），不是某一种写法。
bool finalStatusFromResult(String body) {
  final inline = RegExp(
    r'await\s+occs\.markStatus\(\s*o\.id\s*,\s*ok\s*\?\s*'
    r'OccurrenceStatus\.done\s*:\s*OccurrenceStatus\.failed\s*\)',
  ).hasMatch(body);
  if (inline) return true;
  final derived = RegExp(
    r'terminal\s*=\s*outcome\.isSkipped\s*\?\s*OccurrenceStatus\.skipped\s*'
    r':\s*\(?\s*ok\s*\?\s*OccurrenceStatus\.done\s*:\s*'
    r'OccurrenceStatus\.failed\s*\)?',
  ).hasMatch(body);
  // R94：`markStatus(o.id, terminal, from: {...})` 多了 CAS 参数，
  // 匹配 `terminal` 之后**允许**继续有参数（否则锁会逼着人删掉 CAS）。
  final written = RegExp(
    r'await\s+occs\.markStatus\(\s*o\.id\s*,\s*terminal\b',
  ).hasMatch(body);
  return derived && written;
}
