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
    this.quietExempt = false,
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

  /// 夜间独立豁免（v1.9，docs/20 §8）：**任务级**开关，默认 false = 受免打扰约束。
  ///
  /// ⚠️ 单独为 true **不生效** —— 必须同时满足全局主开关
  /// `SettingsRepository.quietExemptMaster()` 为 true（双重开关 / Two-Key Safety）。
  /// 默认取 false 是因为它落在**更安全**的一侧：漏配 = 仍受护栏约束。
  /// ⚠️ 远程不得开启：`TaskWire.fromWire` 显式丢弃入站该字段（docs/20 §8.2 约束 1）。
  final bool quietExempt;

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
        quietExempt: quietExempt ?? this.quietExempt,
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
        'quiet_exempt': quietExempt ? 1 : 0,
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
        // 缺列/空值一律按 **false（不豁免）** 处理 —— 即"降级到更安全的一侧"。
        // 建表默认值本就是 0，v2→v3 迁移补列后亦为 0，故此处不会掩盖真实配置。
        quietExempt: (r['quiet_exempt'] as int? ?? 0) != 0,
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
