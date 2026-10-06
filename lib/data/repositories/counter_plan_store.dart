import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/counter_plan.dart';
import '../../domain/scheduling/china_holidays.dart';
import '../../domain/scheduling/counter_plan_materializer.dart';

/// 「随机反击计划」的本机持久化（SharedPreferences，KV 简单可靠）。
///
/// ## 存什么、为什么分四把键
/// - `counter_plan_json`：计划本体（固定 schema，导出/远程下发即此文本）；
/// - `counter_plan_id`：计划的稳定标识 —— 决定任务 id 命名空间与随机种子，
///   因此**必须落盘**：重启后若 planId 变了，旧任务会全部变成"回不来的孤儿"
///   （删除按前缀整族进行，找不到前缀就删不掉）；
/// - `counter_plan_enabled`：本机是否启用（下线只清任务 + 置 false，
///   保留计划本体，方便用户一键恢复）；
/// - `counter_plan_overrides`：逐日工作日/休息日覆盖（手动或远程下发），
///   与 `ChinaHolidays` 的内置表叠加。
///
/// ## 容错口径与模型一致
/// 读不懂的 JSON **不抛**：返回 null / 空表，由调用方如实告知"未配置"或
/// "覆盖表已损坏"，而不是让一次坏读把设置页打崩。
class CounterPlanStore {
  CounterPlanStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kPlanJson = 'counter_plan_json';
  static const _kPlanId = 'counter_plan_id';
  static const _kEnabled = 'counter_plan_enabled';
  static const _kOverrides = 'counter_plan_overrides';

  /// 缺省 planId（首次生成本机随机计划时使用）。
  static const String defaultPlanId = 'local';

  /// 当前计划标识；未配置时回落 [defaultPlanId]（永不为空，便于拼前缀）。
  String get planId {
    final v = _prefs.getString(_kPlanId)?.trim() ?? '';
    return v.isEmpty ? defaultPlanId : CounterPlanMaterializer.safePlanId(v);
  }

  /// 本机是否启用反击计划（**默认关**：需要用户显式开启）。
  bool get enabled => _prefs.getBool(_kEnabled) ?? false;

  /// 读取计划本体；未配置 / 损坏 → null（不抛）。
  CounterPlan? loadPlan() {
    final raw = _prefs.getString(_kPlanJson);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return CounterPlan.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  /// 逐日覆盖表；未配置 / 损坏 → 空表（不抛）。
  Map<String, DayKind> overrides() {
    final raw = _prefs.getString(_kOverrides);
    if (raw == null || raw.trim().isEmpty) return const <String, DayKind>{};
    try {
      return ChinaHolidays.parseOverrides(jsonDecode(raw));
    } on Object {
      return const <String, DayKind>{};
    }
  }

  /// 保存计划本体（可选同时写 id / 启用状态）。
  Future<void> savePlan(CounterPlan plan, {String? id, bool? enabled}) async {
    await _prefs.setString(_kPlanJson, jsonEncode(plan.toJson()));
    if (id != null && id.trim().isNotEmpty) {
      await _prefs.setString(_kPlanId, CounterPlanMaterializer.safePlanId(id));
    }
    if (enabled != null) await _prefs.setBool(_kEnabled, enabled);
  }

  Future<void> setEnabled(bool v) => _prefs.setBool(_kEnabled, v);

  /// 保存逐日覆盖（空表即清除，回到"纯内置节假日表"）。
  Future<void> setOverrides(Map<String, DayKind> ov) async {
    if (ov.isEmpty) {
      await _prefs.remove(_kOverrides);
      return;
    }
    await _prefs.setString(_kOverrides, jsonEncode(<String, String>{
      for (final e in ov.entries) e.key: e.value.name,
    }));
  }

  /// 清空全部反击计划状态（下线并遗忘）。
  Future<void> clear() async {
    await _prefs.remove(_kPlanJson);
    await _prefs.remove(_kPlanId);
    await _prefs.remove(_kEnabled);
    await _prefs.remove(_kOverrides);
  }
}