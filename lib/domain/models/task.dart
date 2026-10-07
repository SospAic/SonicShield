import 'dart:convert';

import 'condition.dart';
import '../../domain/models/action.dart';
import '../../domain/models/trigger.dart';

/// 一条自动化任务（聚合根）。
class Task {
  const Task({
    required this.id,
    required this.name,
    required this.enabled,
    required this.triggerType,
    required this.trigger,
    required this.actionType,
    required this.action,
    required this.assetIds,
    required this.cooldownSec,
    required this.quietPolicy,
    this.quietExempt,
    this.forceRun = false,
    this.condition,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final bool enabled;
  final TriggerType triggerType;
  final TriggerConfig trigger;
  final ActionType actionType;
  final ActionConfig action;

  /// 随机挑选的音源池（动作执行时按权重随机）。
  final List<String> assetIds;

  /// 同一任务两次执行之间的最小冷却（秒）。
  final int cooldownSec;

  final QuietPolicy quietPolicy;

  /// 夜间独立豁免的**任务级覆盖**（v79，docs/20 §8）：**三态**。
  ///
  /// - `null`（默认）= **跟随主开关** `PrefsKeys.quietExemptMaster`：主开关开 → 豁免，
  ///   关 → 不豁免。绝大多数任务都是这一态，**不会**出现在设置页「例外清单」里。
  /// - `true` = **强制豁免**：即使主开关关闭，本任务仍在免打扰时段照常执行。
  /// - `false` = **强制不豁免**：即使主开关开启，本任务仍按 `QuietPolicy` 跳过/平移。
  ///
  /// 判据真源：`ScheduleEngine._applyQuiet` 的 `exempt = taskExemptOverride ?? allowQuietExempt`。
  ///
  /// ⚠️ 主开关默认 false —— 未授权时默认全部任务**不豁免**（fail-safe 方向不变）；
  /// 任一任务要豁免，要么用户开了主开关（默认态即豁免），要么该任务被**显式**设为 `true`。
  /// ⚠️ 远程不得写主开关：`TaskWire.fromWire` 丢弃入站该字段并落 `null`
  ///   （任务跟随**本机**主开关，docs/20 §8.2 约束 1）。
  final bool? quietExempt;

  /// **全局执行总开关强制例外**（v79，docs/…）：默认 `false`。
  ///
  /// 当全局执行总开关（`PrefsKeys.runMasterMode`）处于暂停窗口内（法定休息日
  /// 前后自动关闭）或用户**强制关闭**时，任务默认被跳过；本字段为 `true`
  /// 的任务按**显式例外**照常执行。
  ///
  /// ⚠️ 与 [quietExempt] 不同，本字段是**单向布尔**：没有"强制不执行"态
  /// （要停就用任务自身的 `enabled=false`），因为它守护的是一个更粗的刹车。
  /// ⚠️ 远程下发任务一律落 `false`（远程不得单方面给本机任务开例外）。
  final bool forceRun;

  final TaskCondition? condition; // 执行前置条件（null=无条件，v1.3）
  final int priority; // 数值大者先执行（同刻冲突时）
  final DateTime createdAt;
  final DateTime updatedAt;

  Task copyWith({
    String? name,
    bool? enabled,
    TriggerConfig? trigger,
    TriggerType? triggerType,
    ActionConfig? action,
    ActionType? actionType,
    List<String>? assetIds,
    int? cooldownSec,
    QuietPolicy? quietPolicy,
    bool? quietExempt,
    bool? forceRun,
    TaskCondition? condition,
    int? priority,
    DateTime? updatedAt,
  }) =>
      Task(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        triggerType: triggerType ?? this.triggerType,
        trigger: trigger ?? this.trigger,
        actionType: actionType ?? this.actionType,
        action: action ?? this.action,
        assetIds: assetIds ?? this.assetIds,
        cooldownSec: cooldownSec ?? this.cooldownSec,
        quietPolicy: quietPolicy ?? this.quietPolicy,
        // ⚠️ 三态字段用 `??` 表达"未提供即保持"：因此 copyWith **无法把覆盖清回 null**。
        // 当前无调用方需要该能力（要清回"跟随主开关"请显式构造 Task）。
        quietExempt: quietExempt ?? this.quietExempt,
        forceRun: forceRun ?? this.forceRun,
        condition: condition ?? this.condition,
        priority: priority ?? this.priority,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, dynamic> toRow() => {
        'id': id,
        'name': name,
        'enabled': enabled ? 1 : 0,
        'trigger_type': triggerType.name,
        'trigger_json': trigger.toJson(),
        'action_type': actionType.name,
        'action_json': action.toJson(),
        'asset_ids': assetIds,
        'cooldown_sec': cooldownSec,
        'quiet_policy': quietPolicy.name,
        // 三值编码（v79）：0=跟随主开关 / 1=强制豁免 / 2=强制不豁免。
        // 注意 `occurrences.quiet_exempt` 仍是 bool（0/1），两列同名不同义，勿混。
        'quiet_exempt': switch (quietExempt) {
          null => 0,
          true => 1,
          false => 2,
        },
        'force_run': forceRun ? 1 : 0,
        'priority': priority,
        'condition_json':
            condition == null ? null : jsonEncode(condition!.toJson()),
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static Task fromRow(Map<String, dynamic> r) => Task(
        id: r['id'] as String,
        name: r['name'] as String,
        enabled: (r['enabled'] as int) == 1,
        triggerType: TriggerType.values.byName(r['trigger_type'] as String),
        trigger: TriggerConfig.fromJson(_decodeJson(r['trigger_json'])),
        actionType: ActionType.values.byName(r['action_type'] as String),
        action: ActionConfig.fromJson(_decodeJson(r['action_json'])),
        assetIds: _decodeAssetIds(r['asset_ids']),
        cooldownSec: r['cooldown_sec'] as int,
        quietPolicy: QuietPolicy.values.byName(r['quiet_policy'] as String),
        // 三值反解（v79）：0=跟随主开关（`null`）/ 1=强制豁免 / 2=强制不豁免。
        // 缺列/空值 → 0 → `null`（跟随主开关）。主开关默认 false，故老库升级后
        // 行为与升级前一致（不豁免），一旦用户开启主开关即按新语义默认豁免。
        quietExempt: switch (r['quiet_exempt'] as int? ?? 0) {
          1 => true,
          2 => false,
          _ => null,
        },
        // 单向布尔：缺列/空值 → false（默认受总开关约束，更安全的一侧）。
        forceRun: (r['force_run'] as int? ?? 0) == 1,
        condition: TaskCondition.fromJsonOrNull(r['condition_json'] as String?),
        priority: r['priority'] as int? ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      );

  static Map<String, dynamic> _decodeJson(Object? v) =>
      v is Map<String, dynamic>
          ? v
          : (v is String
              ? (jsonDecode(v) as Map<String, dynamic>)
              : <String, dynamic>{});

  /// asset_ids 兼容两种存储形态：JSON 字符串列（DB）与内存 List（测试）。
  static List<String> _decodeAssetIds(Object? v) {
    if (v is List) return v.cast<String>();
    if (v is String && v.isNotEmpty) {
      return (jsonDecode(v) as List).cast<String>();
    }
    return const [];
  }
}

/// 已物化的触发计划条目。
enum OccurrenceStatus { pending, done, skipped, failed }

class PlannedOccurrence {
  const PlannedOccurrence({
    required this.id,
    required this.taskId,
    required this.fireAt, // 本地时区 UTC 毫秒
    required this.status,
    this.volume,
    this.durationMs,
    this.quietExempt = false,
  });

  final String id;
  final String taskId;
  final DateTime fireAt;
  final OccurrenceStatus status;
  final double? volume; // 执行期落地参数（审计用）
  final int? durationMs;

  /// 本条计划是**因夜间独立豁免**才在免打扰时段存活（v1.9，docs/20 §8）。
  /// 执行层据此写 `action='quietExempt'` 审计。
  final bool quietExempt;

  Map<String, dynamic> toRow() => {
        'id': id,
        'task_id': taskId,
        'fire_at': fireAt.millisecondsSinceEpoch,
        'status': status.name,
        'volume': volume,
        'duration_ms': durationMs,
        'quiet_exempt': quietExempt ? 1 : 0,
      };

  static PlannedOccurrence fromRow(Map<String, dynamic> r) => PlannedOccurrence(
        id: r['id'] as String,
        taskId: r['task_id'] as String,
        fireAt: DateTime.fromMillisecondsSinceEpoch(r['fire_at'] as int),
        status: OccurrenceStatus.values.byName(r['status'] as String),
        volume: (r['volume'] as num?)?.toDouble(),
        durationMs: r['duration_ms'] as int?,
        // 缺列按 false 处理 —— 降级到**更安全**的一侧（不豁免）。
        quietExempt: (r['quiet_exempt'] as int? ?? 0) != 0,
      );
}
