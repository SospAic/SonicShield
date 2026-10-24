import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

/// **全局执行总开关 · 引擎侧源码契约锁**（v79，docs/20 §9）。
///
/// ## 为什么要用源码锁，而不是行为测试
///
/// `background_engine.dart` 只在 `flutter_background_service` 的隔离里运行
/// （真实 DB / 播放器 / TTS / 原生桥），宿主 `flutter test` **实例化不了它的
/// 引擎体**（与 `engine_reentrancy_test.dart` / `execution_outcome_lock_test.dart`
/// 同一理由）。因此 [RunPause] 的纯函数判据（`run_pause_test.dart` 17 例）+ 本文件
/// 的"**接线是否存在**"契约锁共同构成证据：前者证明算法对，后者证明引擎真的
/// 用了它、且例外/审计一条不少。
///
/// ## 锁的四条不变量
///
/// | 锁 | 锚点 | 缺失后果 |
/// |---|---|---|
/// | RPE-01 | `pausedAt` 读 `runMasterMode` → `RunPause.paused`（含覆盖表） | 模式改了不生效 / 与反击计划"休息日认定"分叉 |
/// | RPE-02 | `admitExecution` **最先**拦截，且放行 `forceRun` 例外 | 声音/远程立即执行入口绕过总开关 |
/// | RPE-03 | `executeDue` 轮首算一次 + 经 `admit` 拒绝 ⇒ 落 `skipped`/`runPause` 审计且不再执行 | 到期计划照响；或"没响"却无任何痕迹 |
/// | RPE-04 | `replan` 关主开关时保留 `quietExempt == true` 例外 | 双向覆盖被清空（v79 语义回退） |
///
/// 与项目铁律一致：判据抽成顶层纯函数，每条都配**反面样本**（`RPE-90*`），
/// 证明检测器对"坏代码"真的判红 —— 否则恒真检测器能让整组锁假绿。
/// 文本扫描一律**先剥注释**（[stripComments]）：本项目刻意在注释里写明缺陷形状，
/// 不剥注释锁会把自己的说明当成违规。
void main() {
  final src = stripComments(
      File('lib/services/background_engine.dart').readAsStringSync());

  group('RPE 全局执行总开关 · 引擎接线（源码契约锁）', () {
    test('RPE-01 pausedAt 读模式并委托 RunPause.paused（含节假日覆盖表）', () {
      final v = judgePausedAt(src);
      expect(v, isNull, reason: '$v');
    });

    test('RPE-02 admitExecution 最先拦截，且放行 forceRun 例外', () {
      final v = judgeAdmitGate(src);
      expect(v, isNull, reason: '$v');
    });

    test('RPE-03 executeDue 轮首算一次 + 落 skipped/runPause 审计后 continue', () {
      final v = judgeExecuteDueGate(src);
      expect(v, isNull, reason: '$v');
    });

    test('RPE-04 replan 关主开关时保留强制豁免例外（v79 双向覆盖）', () {
      final v = judgeReplanKeepExempt(src);
      expect(v, isNull, reason: '$v');
    });
  });

  group('RPE-90 检测器有效性（反面样本必须判红）', () {
    test('90a pausedAt 未委托 RunPause.paused / 未读 runMasterMode → 判红', () {
      expect(judgePausedAt('bool pausedAt(DateTime at) { return false; }'),
          isNotNull);
      expect(
          judgePausedAt('bool pausedAt(DateTime at) {'
              ' final m = PrefsKeys.runMasterMode;'
              ' RunPause.paused(RunMasterMode.parse(null), at,'
              ' overrides: const {}, autoOverrides: const {});'
              ' return false; }'),
          isNotNull,
          reason: '缺 CounterPlanStore 覆盖表也要判红');
    });

    test('90b admitExecution 的暂停门排在条件门之后 → 判红', () {
      const bad = 'Future<String?> admitExecution(Task task, ConditionEnv env,'
          ' String source, {String? occurrenceId}) async {'
          ' final c = conditionFailedIn(task, env);'
          ' if (!task.forceRun && pausedAt(DateTime.now())) {'
          "  action: 'runPause'; status: 'skipped'; return 'x'; }"
          ' return c; }';
      expect(judgeAdmitGate(bad), isNotNull);
    });

    test('90c executeDue 暂停后没 continue / 缺 forceRun 例外 → 判红', () {
      expect(
          judgeExecuteDueGate('Future<void> executeDue() async {'
              ' final pausedNow = pausedAt(now);'
              ' if (pausedNow) { OccurrenceStatus.skipped;'
              "  action: 'runPause'; continue; } }"),
          isNotNull,
          reason: '缺 !task.forceRun 例外判红');
      expect(
          judgeExecuteDueGate('Future<void> executeDue() async {'
              ' final pausedNow = pausedAt(now);'
              ' if (pausedNow && !task.forceRun) {'
              "  action: 'runPause'; } }"),
          isNotNull,
          reason: '缺 OccurrenceStatus.skipped / continue 判红');
    });

    test('90d replan 未保留 quietExempt==true 例外 → 判红', () {
      expect(
          judgeReplanKeepExempt('Future<void> replan() async {'
              ' final a = PrefsKeys.quietExemptMaster;'
              ' deletePendingQuietExempt();'
              ' ScheduleEngine(allowQuietExempt: allowExempt); }'),
          isNotNull);
    });

    test('90e 假解耦（只把 continue 搬走、没接 admit→discard）→ 判红', () {
      // 直接在**真实源码**上做变异：删掉 executeBatch 里那句"丢弃并留痕"。
      // 用真实源码而不是手写片段，是为了证明这条守卫钉的是**当前代码**，
      // 而不是钉一个我自己编出来的形状。
      final mutated = src.replaceFirst(
          'discardWithAudit(o, denied.action, denied.message);', '// dropped');
      expect(mutated, isNot(src), reason: '锚点失效 ⇒ 本样本空转，必须同步锚点');
      expect(judgeExecuteDueGate(mutated), isNotNull,
          reason: '★ 抽出去的是循环，不是语义：拒绝理由没有变成'
              '「落 skipped + 不执行」就是假解耦');
    });
  });
}

/// `pausedAt` 必须：模式取自 `PrefsKeys.runMasterMode`（`RunMasterMode.parse`）、
/// 判据委托 `RunPause.paused`、节假日覆盖沿用 `CounterPlanStore` 的同一份表。
String? judgePausedAt(String src) {
  final b = methodBody(src, 'bool pausedAt(DateTime at)');
  for (final need in const [
    'PrefsKeys.runMasterMode',
    'RunMasterMode.parse(',
    'RunPause.paused(',
    'CounterPlanStore(',
    'store.overrides()',
    'store.autoOverrides()',
  ]) {
    if (!b.contains(need)) return 'pausedAt 缺少 `$need`';
  }
  return null;
}

/// `admitExecution` 必须**最先**拦暂停（在条件/概率门之前），并放行 `forceRun`，
/// 且落 `runPause` + `skipped` 审计。
String? judgeAdmitGate(String src) {
  final b = methodBody(src, 'Future<String?> admitExecution(');
  final gate = b.indexOf('pausedAt(');
  if (gate < 0) return 'admitExecution 未调用 pausedAt（暂停期未拦截）';
  if (!b.contains('!task.forceRun')) return 'admitExecution 未放行 forceRun 例外';
  if (!b.contains("action: 'runPause'")) return 'admitExecution 未写 runPause 审计';
  if (!b.contains("status: 'skipped'")) return 'admitExecution 未落 skipped';
  final cond = b.indexOf('conditionFailedIn(');
  if (cond >= 0 && gate > cond) return 'admitExecution 的暂停门排在条件门之后';
  return null;
}

/// `executeDue` 必须轮首算一次 `pausedNow`，暂停时置 `skipped` + 写 `runPause`
/// 审计并 `continue`（不得继续执行）。
///
/// ## R94 / SCH-01 起 `continue` 换了归属（判定器同步收紧，不是放宽）
/// 批次循环搬到了顶层 [executeBatch]（判定与执行解耦，可被行为测试覆盖），
/// `executeDue` 只负责**产出**拒绝理由：`admit` 返回
/// `(action: 'runPause', message: …)`，由 `executeBatch` 统一
/// `discardWithAudit`（CAS 落 `skipped` + 审计）后 `continue`。
///
/// 所以判据拆成两段、**两段都必须成立**：
/// 1. `executeDue` 体内：`pausedNow` 轮首算一次、`!task.forceRun` 例外、
///    `runPause` 拒绝理由、`discard:`（CAS 落 skipped 的回调确实接上了）；
/// 2. 要么 `executeDue` 自己 `continue`，要么 `executeBatch` 里存在
///    「`admit` → 非 null → `discardWithAudit` → `continue`」这条完整链路。
///
/// 任何一段缺失都判红 —— 反面样本 `RPE-90c` 仍然红（缺 forceRun / 缺
/// skipped+continue 两种坏形状），另有 `RPE-90e` 专门证明"只把 `continue`
/// 挪走、却没接上 `admit → discard`"这种**假解耦**也会被判红。
String? judgeExecuteDueGate(String src) {
  final b = methodBody(src, 'Future<void> executeDue()');
  if (!b.contains('final pausedNow = pausedAt(now)')) {
    return 'executeDue 未在轮首算 pausedNow';
  }
  if (!b.contains('if (pausedNow && !task.forceRun)')) {
    return 'executeDue 暂停门缺 forceRun 例外（或写法已变）';
  }
  if (!b.contains("action: 'runPause'")) {
    return 'executeDue 暂停未写 runPause 审计';
  }
  // skipped 的落库点：R94 前是 `OccurrenceStatus.skipped` 直写，
  // R94 起是 `discard:` 的 CAS 回调（仍必须是 pending→skipped）。
  final writesSkipped = b.contains('OccurrenceStatus.skipped');
  final wiredDiscard = b.contains('discard:') &&
      b.contains('OccurrenceStatus.skipped');
  if (!writesSkipped) return 'executeDue 暂停未置 skipped';
  if (!wiredDiscard) return 'executeDue 未把 discard（pending→skipped CAS）接上';

  var continued = b.contains('continue;');
  if (!continued) {
    // `continue` 在共享骨架里：必须能看到「admit 拒绝 → 丢弃 → continue」。
    if (!src.contains('Future<void> executeBatch({')) {
      return 'executeDue 暂停后未 continue（会继续执行）';
    }
    final batch = methodBody(src, 'Future<void> executeBatch({');
    continued = batch.contains('final denied = await admit?.call(task, o);') &&
        batch.contains('discardWithAudit(o, denied.action, denied.message)') &&
        batch.contains('continue;');
    if (!continued) {
      return 'executeDue 的拒绝理由没有在 executeBatch 里变成'
          '「落 skipped + 不执行」（admit→discard→continue 链路断裂）';
    }
  }
  return null;
}

/// `replan` 关主开关时必须**保留** `quietExempt == true` 的例外计划
/// （v79 双向覆盖），并把主开关值传给 `ScheduleEngine`。
String? judgeReplanKeepExempt(String src) {
  final b = methodBody(src, 'Future<void> replan()');
  if (!b.contains('PrefsKeys.quietExemptMaster')) {
    return 'replan 未读夜间豁免主开关';
  }
  if (!b.contains('t.quietExempt == true')) {
    return 'replan 未识别强制豁免例外（双向覆盖）';
  }
  if (!b.contains('keepTaskIds:')) {
    return 'replan 未把例外 id 传给 deletePendingQuietExempt';
  }
  if (!b.contains('allowQuietExempt: allowExempt')) {
    return 'replan 未把主开关值传给 ScheduleEngine';
  }
  return null;
}
