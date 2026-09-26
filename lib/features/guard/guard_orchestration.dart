/// 守卫的声音编排（v1.10）。
///
/// ## 为什么**不是**一套新的编排模型
///
/// 用户需求：「守卫的声音支持选定**多个音频、动作**，并支持**随机播放**、
/// **立即或者延时播放**，以及软件中现有的功能」。逐条对照既有能力
/// （`docs/19-多条件与随机编排设计.md` §1/§3/§4/§7）：
///
/// | 需求 | 既有实现 | 状态 |
/// |---|---|---|
/// | 多选音频 + 随机挑一条 | `Task.assetIds` + `pickAssetFor()`（引擎已接线） | ✅ 已覆盖 |
/// | 多选动作 + 加权随机挑一个 | `ActionSetAction` + `ActionSetCandidate.pick()` | ✅ 已覆盖 |
/// | 触发后概率执行 | `TaskCondition.probabilityPct` 概率门 | ✅ 已覆盖 |
/// | 与音源库/TTS/振动/通知/取证打通 | 声音触发任务的动作层（`onSoundEvent` → `runAction`） | ✅ 已覆盖 |
/// | 立即执行 | 现状 | ✅ 已覆盖 |
/// | **延时 N 秒再执行** | 只有 `RcScript.delay`（**远程**通道）；`docs/19 §4` 明写"本地任务 v2 评估" | ❌ **真缺口** |
/// | **在多个候选之间随机挑一个** | `ActionSetAction` 只在**单个任务内部**随机；任务之间没有 | ❌ 真缺口 |
/// | **选定参与守卫的任务子集** | 无（守卫固定执行全部 `soundTriggered` 任务） | ❌ 真缺口 |
///
/// 结论：**内容维度（多选音频/动作 + 随机）已由 `assetIds` 与 `ActionSetAction`
/// 覆盖，守卫不重复实现**；守卫只补上面三个 ❌。因此本文件刻意**不定义任何
/// 音频/动作模型** —— 它只描述"用哪几个任务、挑几个、等多久"，
/// 动作能力一律复用任务自己的动作层。
///
/// ## 为什么**不把指令组（`RcScript`）挂到守卫上**
///
/// `RcScript` 的 6 种步骤（play/tts/notify/vibrate/record/delay）里，
/// 前 5 种在任务动作层**全部已有等价物**（播放/播报/通知/振动/取证），
/// 唯一独有的是 `delay` —— 而它正是本文件补上的那一格。
/// 接入它需要把 `endpoint_service.dart` 里那份 `RcStepRunner`
/// （约百行：音源解析/播放/TTS/录音）**在引擎隔离里重写一遍**，
/// 还会绕开 `RcScriptExecutor` 的"单实例 + 可终止"语义 ——
/// 这正是"功能重复"，得不偿失。
library;

import 'dart:convert';
import 'dart:math' as math;

/// 守卫触发后如何从候选任务里挑。
enum GuardPickMode {
  /// 全部执行（**默认**，与升级前行为一字不差）。
  all,

  /// 等概率随机挑**一个**。
  randomOne,
}

/// 解析持久化里的 `pick`。未知/缺失一律按 [GuardPickMode.all] ——
/// 这是老配置的唯一语义（等价于"没有编排"），不是降级。
GuardPickMode guardPickModeOf(Object? v) {
  for (final m in GuardPickMode.values) {
    if (m.name == v) return m;
  }
  return GuardPickMode.all;
}

/// 守卫编排配置。**纯数据 + 纯决策**，因此能在 host 单测里穷举断言。
class GuardOrchestration {
  const GuardOrchestration({
    this.taskIds = const <String>[],
    this.pick = GuardPickMode.all,
    this.delaySec = 0,
  });

  /// 参与守卫的声音触发任务 id。**空 = 全部**（向后兼容的默认值）。
  final List<String> taskIds;

  final GuardPickMode pick;

  /// 检测到声音事件后等多久再执行（秒）。0 = 立即。
  final int delaySec;

  /// 延时上限：10 分钟。
  ///
  /// 与 `RcScript.maxTotalMs`（30 分钟，宏通道）不同 —— 守卫是**常驻**监听，
  /// 单个事件的延时留太久会让"刚才那声响"和"现在响起的警报"因果脱节，
  /// 用户无法预期。上限收紧不是放宽。
  static const int maxDelaySec = 600;

  bool get isDefault =>
      taskIds.isEmpty && pick == GuardPickMode.all && delaySec == 0;

  Map<String, dynamic> toJson() => {
        'taskIds': taskIds,
        'pick': pick.name,
        'delaySec': delaySec,
      };

  static GuardOrchestration fromJson(Map<String, dynamic> j) =>
      GuardOrchestration(
        taskIds: [
          for (final e in (j['taskIds'] as List?) ?? const [])
            if (e is String && e.isNotEmpty) e,
        ],
        pick: guardPickModeOf(j['pick']),
        delaySec: _clampDelay(j['delaySec']),
      );

  /// 容错解析：kv 里的值可能被外部改坏 / 来自更老的版本。
  /// **任何解析失败都退回"默认编排"**（= 全部任务、立即执行），
  /// 而不是让守卫整个失效 —— 守卫是安全功能，不能因为一段坏 JSON 就静默停摆。
  static GuardOrchestration decode(String? raw) {
    if (raw == null || raw.isEmpty) return const GuardOrchestration();
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const GuardOrchestration();
      return fromJson(j.cast<String, dynamic>());
    } on Object {
      return const GuardOrchestration();
    }
  }

  String encode() => jsonEncode(toJson());

  static int _clampDelay(Object? v) {
    if (v is! num) return 0;
    return v.toInt().clamp(0, maxDelaySec);
  }
}

/// 一次声音事件要执行的计划。
class GuardPlan {
  const GuardPlan({required this.taskIds, required this.delayMs});

  final List<String> taskIds;
  final int delayMs;

  bool get isEmpty => taskIds.isEmpty;
}

/// **守卫编排的唯一决策点**（纯函数 ⇒ 可穷举断言、可变异证伪）。
///
/// 语义约定（与 `soundscapeTrackPath` / `routeRcVibrateStep` 同一哲学）：
///
/// 1. `config.taskIds` 为空 ⇒ 候选**全部**入选（默认值 = 升级前行为）；
/// 2. `config.taskIds` 非空 ⇒ 只保留**与候选的交集**，且**保持候选原有顺序**
///    （顺序即调度顺序，"计划即审计"）；
/// 3. 点名了却一条都不在候选里 ⇒ 返回**空计划**，**绝不**退回"随便挑一条"。
///    这正是 BUG-059 的判据：点名了就必须满足，满足不了要失败并留痕，
///    而不是让用户听到一段自己没配过的声音。
/// 4. `randomOne` 且集合非空 ⇒ 恰好一个，等概率。
///
/// [rng] 由调用方注入 ⇒ 测试可固定种子，断言"确实在随机"而非"看起来像"。
GuardPlan resolveGuardPlan({
  required List<String> candidateIds,
  required GuardOrchestration config,
  required math.Random rng,
}) {
  final selected = config.taskIds.isEmpty
      ? List<String>.from(candidateIds)
      : <String>[
          for (final id in candidateIds)
            if (config.taskIds.contains(id)) id,
        ];

  final delayMs = config.delaySec.clamp(0, GuardOrchestration.maxDelaySec).toInt() *
      1000;

  switch (config.pick) {
    case GuardPickMode.all:
      return GuardPlan(taskIds: selected, delayMs: delayMs);
    case GuardPickMode.randomOne:
      if (selected.isEmpty) return GuardPlan(taskIds: const [], delayMs: delayMs);
      return GuardPlan(
        taskIds: [selected[rng.nextInt(selected.length)]],
        delayMs: delayMs,
      );
  }
}

/// kv 存储键（守卫编排**不新增表列** —— `sound_profiles` 的列变更是 DB 迁移
/// 的事，属于 `lib/data/db/app_database.dart` 的所有者；这里用通用的 kv）。
const String guardOrchestrationKey = 'guard_orchestration';
