import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

/// **执行结果语义与概率门覆盖锁**（P1-07）。
///
/// ## 缺陷形状（静态审查确证）
///
/// 1. 定时入口 `executeDue` 有概率门，但**声音入口**（`runGuardPlan` 及其
///    上游 `onSoundEvent`）与**远程立即执行**（`runNow`）都**没有** ——
///    用户设的"30% 概率"对这两条触发路径毫无约束。
/// 2. 动作 helper（`playAndLog` / `ttsAndLog` / `recordAndLog` /
///    `soundscapeAndLog`）返回 `void`，`runSingle` 对播放/TTS/录音/声景分支
///    **固定 `return true`** ⇒ 缺音源、TTS 超时、录音失败这些**真实失败**
///    在 occurrence / 远程 ack 里被记成成功（日志说失败、计划说成功）。
/// 3. `runGuardPlan` 忽略 `runAction` 返回值并无条件 `commit done`。
///
/// ## 为什么是源码契约锁
///
/// 与 `test/engine_reentrancy_test.dart` 同一理由：`background_engine.dart`
/// 只在 `flutter_background_service` 的隔离里运行（真实 DB / 播放器 / TTS /
/// 原生桥），宿主机**实例化不了**。所以锁结构，并用反面样本证明检测器
/// **确实会判红**（否则一个恒真检测器就能让整组锁假绿）。
void main() {
  final src = stripComments(
      File('lib/services/background_engine.dart').readAsStringSync());

  group('EOL 执行结果语义（源码契约锁）', () {
    test('EOL-01 统一结果类型存在，且 runAction/runSingle 返回它', () {
      final v = judgeOutcomeType(src);
      expect(v, isNull, reason: '$v');
    });

    test('EOL-02 四个动作 helper 都返回 ExecutionOutcome（不再是 void）', () {
      final v = judgeHelpersReturnOutcome(src);
      expect(v, isNull, reason: '$v');
    });

    test('EOL-03 概率门覆盖全部三个触发入口（定时 / 声音 / 远程立即执行）', () {
      final v = judgeProbabilityAllEntries(src);
      expect(v, isNull, reason: '$v');
    });

    test('EOL-04 动作失败会传播：runAction 异常返回 failed，终态由 outcome 决定', () {
      final v = judgeActionFailPropagation(src);
      expect(v, isNull, reason: '$v');
    });

    test('EOL-05 runGuardPlan 不再无条件记成功，按 outcome 落 done/failed', () {
      final v = judgeGuardPlanOutcome(src);
      expect(v, isNull, reason: '$v');
    });

    test('EOL-06 远程立即执行回执按 outcome 区分成败', () {
      final v = judgeRunNowOutcome(src);
      expect(v, isNull, reason: '$v');
    });
  });

  group('EOL-90 检测器有效性（反面样本必须判红）', () {
    test('90a 旧形状：runAction 返回 bool / helper 返回 void → 判红', () {
      const old = '''
Future<bool> runAction(Task task, double v, int d, String s) async { return true; }
Future<void> playAndLog(Task task, PlayAudioAction p, double volume, int durationMs, String source) async {}
Future<void> ttsAndLog(Task task, TtsAction t, String source) async {}
''';
      expect(judgeOutcomeType(old), isNotNull);
      expect(judgeHelpersReturnOutcome(old), isNotNull);
    });

    test('90b 概率门只在定时入口（声音/远程缺失）→ 判红', () {
      const partial = '''
Future<void> executeDue() async {
  final gateFail = probabilityGateMissed(task);
}
Future<String?> admitExecution(Task task, ConditionEnv env, String source) async { return null; }
Future<void> onSoundEvent(DateTime at, double peakDb) async {
  for (final t in all) { ready.add(t.id); }
}
service.on('runNow').listen((m) async {
  ok = await runAction(task, vol, dur, 'remote');
});
''';
      expect(judgeProbabilityAllEntries(partial), isNotNull,
          reason: '★ 只有定时入口有概率门 = 正是 P1-07 的缺陷形状，必须判红');
    });

    test('90c runGuardPlan 无条件 commit done（P1-07 前的形状）→ 判红', () {
      const old = '''
Future<void> runGuardPlan(GuardPlan plan, DateTime at) async {
  for (final id in plan.taskIds) {
    await runAction(t, 0.8, 0, 'sound');
    await occs.commitAll([
      PlannedOccurrence(id: '\${t.id}@sound@\${at.millisecondsSinceEpoch}', taskId: t.id, fireAt: at, status: OccurrenceStatus.done),
    ]);
  }
}
''';
      expect(judgeGuardPlanOutcome(old), isNotNull,
          reason: '★ 无条件 done = 动作失败被记成成功，必须判红');
    });

    test('90d runAction 异常吞成 success（旧形状）→ 判红', () {
      const old = '''
Future<ExecutionOutcome> runAction(Task task, double v, int d, String s) async {
  try {
    return await runSingle(task, task.action, v, d, s);
  } catch (e) {
    await logs.append(status: 'failed');
  }
}
''';
      expect(judgeActionFailPropagation(old), isNotNull,
          reason: '★ catch 分支不返回 failed 结果 = 调用方拿不到失败，必须判红');
    });
  });
}

// ═══════════════════════════ 判定器（输入剥注释后的源码） ═════════════════════

String _win(String src, String anchor, int len) {
  final i = src.indexOf(anchor);
  if (i < 0) return '';
  return src.substring(i, (i + len).clamp(0, src.length));
}

String? judgeOutcomeType(String src) {
  if (!src.contains('class ExecutionOutcome')) return '缺少 ExecutionOutcome 类型';
  if (!src.contains('enum ExecutionStatus')) return '缺少 ExecutionStatus 三态枚举';
  if (!src.contains('Future<ExecutionOutcome> runAction(')) {
    return 'runAction 未返回 ExecutionOutcome';
  }
  if (!src.contains('Future<ExecutionOutcome> runSingle(')) {
    return 'runSingle 未返回 ExecutionOutcome';
  }
  return null;
}

String? judgeHelpersReturnOutcome(String src) {
  for (final f in const [
    'playAndLog',
    'ttsAndLog',
    'recordAndLog',
    'soundscapeAndLog',
  ]) {
    if (!src.contains('Future<ExecutionOutcome> $f(')) {
      return '$f 未返回 ExecutionOutcome（失败仍会被吞成成功）';
    }
  }
  return null;
}

String? judgeProbabilityAllEntries(String src) {
  final ad = _win(src, 'Future<String?> admitExecution(', 1600);
  if (!ad.contains('probabilityGateMissed(')) {
    return '统一裁决 admitExecution 未包含概率门';
  }
  final se = _win(src, 'Future<void> onSoundEvent(', 2600);
  if (!se.contains('admitExecution(')) {
    return '声音入口 onSoundEvent 未走统一裁决（概率门缺席）';
  }
  final due = _win(src, 'Future<void> executeDue()', 4200);
  if (!due.contains('probabilityGateMissed(')) {
    return '定时入口 executeDue 概率门丢失';
  }
  final rn = _win(src, "service.on('runNow')", 4200);
  // R91（R90-03）：runNow 改为复用统一裁决 —— 概率门由 `admitExecution` 提供，
  // 同时补上了它此前缺失的 `pausedAt`（节假日暂停）闸。
  if (!rn.contains('admitExecution(')) {
    return '远程立即执行 runNow 未走统一裁决（暂停/条件/概率门缺席）';
  }
  return null;
}

String? judgeActionFailPropagation(String src) {
  final ra = _win(src, 'Future<ExecutionOutcome> runAction(', 1400);
  if (!ra.contains('ExecutionOutcome.failed(')) {
    return 'runAction 异常分支未返回 failed 结果';
  }
  final due = _win(src, 'Future<void> executeDue()', 4200);
  if (!due.contains('outcome.ok')) {
    return 'executeDue 未按 outcome.ok 决定 occurrence 终态';
  }
  return null;
}

String? judgeGuardPlanOutcome(String src) {
  final gp = _win(src, 'Future<void> runGuardPlan(', 2200);
  // R91（R90-04）：三态映射，与 executeDue 对齐。
  // 旧判据只要求区分 failed/done —— 那正是"skipped 被并进 done"的形状
  //（BUG-093 的孪生），现在必须显式区分 skipped。
  if (!gp.contains('outcome.isSkipped')) {
    return 'runGuardPlan 未区分 skipped（skipped 会被并进 done，凭空激活冷却）';
  }
  if (!gp.contains('OccurrenceStatus.skipped')) {
    return 'runGuardPlan 不会落 skipped';
  }
  if (!gp.contains('OccurrenceStatus.failed')) return 'runGuardPlan 不会落 failed';
  if (!gp.contains('OccurrenceStatus.done')) return 'runGuardPlan 不会落 done';
  return null;
}

String? judgeRunNowOutcome(String src) {
  final rn = _win(src, "service.on('runNow')", 4200);
  if (!rn.contains('outcome.ok')) return 'runNow 未按 outcome.ok 决定回执成败';
  return null;
}