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

    test('REENT-04 runAction 之前先乐观置状态，且终态仍由结果决定', () {
      expect(claimsBeforeRunAction(dueBody), isTrue,
          reason: '`runAction` 之前必须先把该 occurrence 取走（乐观置状态），'
              '使并发（跨 isolate / 守卫失效）的第二次 `due()` 必然取不到它。');
      expect(finalStatusFromResult(dueBody), isTrue,
          reason: '正向语义不得改变：最终状态仍必须由 `runAction` 的返回值决定'
              '（`ok ? done : failed`）。这是「不改正向语义」的锁。');
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
    final ok = await runAction(task, 0.8, 0, 'schedule', occurrenceId: o.id);
    await occs.markStatus(o.id, ok ? OccurrenceStatus.done : OccurrenceStatus.failed);
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
bool claimsBeforeRunAction(String body) => RegExp(
      r'occs\.markStatus\(\s*o\.id\s*,\s*OccurrenceStatus\.failed\s*\)\s*;'
      r'[\s\S]*?await\s+runAction\(',
    ).hasMatch(body);

/// 形态：`await occs.markStatus(o.id, ok ? OccurrenceStatus.done : OccurrenceStatus.failed)`。
bool finalStatusFromResult(String body) => RegExp(
      r'await\s+occs\.markStatus\(\s*o\.id\s*,\s*ok\s*\?\s*'
      r'OccurrenceStatus\.done\s*:\s*OccurrenceStatus\.failed\s*\)',
    ).hasMatch(body);
