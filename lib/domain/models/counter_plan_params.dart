/// 「随机反击计划」的**生成参数**（参数化模板，schema `sonicshield.counterPlanParams/1`）。
///
/// ## 为什么要与 [CounterPlan] 分开
///
/// [CounterPlan] 是**产物**（一条条具体时刻 + 具体音量/时长）；本文件是**配方**
/// ——"生成时在哪些区间里取值、哪些时段要不要、白天从几点到几点、两次动作至少
/// 间隔多久"。用户要求"反击计划生成时使用参数化选择（音量区间、时长、时间间隔、
/// 休息日白天/晚上是否反击……全部可调）"，指的就是这一层。
///
/// 三处共用同一份参数，保证**本机随机 / AI 生成 / 远程下发**语义一致：
/// - `CounterPlanRandom.generate(params:)` 在本参数区间内随机取值；
/// - `DeepSeekService.generatePlan(params:)` 把本参数拼进提示词；
/// - 参数本身可持久化（`CounterPlanStore` 的 `counter_plan_params_json`）。
///
/// ## 容错口径与 [CounterPlan] 一致
/// [fromJson] **永不抛**：读不懂的字段回默认、越界值夹紧（[clamped]）；
/// [validate] 把问题**如实报给用户**，而不是静默用错参数生成。
library;

import 'counter_plan.dart';

/// 单个时段的**生成区间**参数（在区间内随机取值）。
class PlanWindowParams {
  const PlanWindowParams({
    this.enabled = true,
    this.volumeMin = 0.5,
    this.volumeMax = 0.8,
    this.durationSecMin = 3,
    this.durationSecMax = 8,
    this.actionsPerHourMin = 1,
    this.actionsPerHourMax = 3,
  });

  /// 该时段是否参与生成（休息日两段默认关闭 = "可选"）。
  final bool enabled;

  /// 生成时音量取值的下/上限（`volumeMin` ≤ 结果 ≤ `volumeMax`）。
  final double volumeMin;
  final double volumeMax;

  /// 生成时单次动作时长的下/上限（秒）。
  final int durationSecMin;
  final int durationSecMax;

  /// 生成时每小时期望动作次数的下/上限。
  final int actionsPerHourMin;
  final int actionsPerHourMax;

  /// 结构上界（与 [CounterWindow] 同源，防止畸形输入把物化期算爆）。
  static const int maxDurationSec = CounterWindow.maxDurationSec;
  static const int maxActionsPerHour = CounterWindow.maxActionsPerHour;

  /// 返回**保证合法**的副本：越界夹到边界、`min > max` 时交换。
  PlanWindowParams clamped() {
    var vLo = volumeMin.clamp(0.0, 1.0).toDouble();
    var vHi = volumeMax.clamp(0.0, 1.0).toDouble();
    if (vLo > vHi) {
      final t = vLo;
      vLo = vHi;
      vHi = t;
    }
    var dLo = durationSecMin.clamp(1, maxDurationSec).toInt();
    var dHi = durationSecMax.clamp(1, maxDurationSec).toInt();
    if (dLo > dHi) {
      final t = dLo;
      dLo = dHi;
      dHi = t;
    }
    var aLo = actionsPerHourMin.clamp(0, maxActionsPerHour).toInt();
    var aHi = actionsPerHourMax.clamp(0, maxActionsPerHour).toInt();
    if (aLo > aHi) {
      final t = aLo;
      aLo = aHi;
      aHi = t;
    }
    return PlanWindowParams(
      enabled: enabled,
      volumeMin: vLo,
      volumeMax: vHi,
      durationSecMin: dLo,
      durationSecMax: dHi,
      actionsPerHourMin: aLo,
      actionsPerHourMax: aHi,
    );
  }

  /// 容错解析。[fallback] 提供该时段应有的默认区间（各时段默认不同）。
  factory PlanWindowParams.fromJson(Object? raw, PlanWindowParams fallback) {
    if (raw is! Map) return fallback;
    final j = raw.cast<String, dynamic>();
    return PlanWindowParams(
      enabled: j['enabled'] as bool? ?? fallback.enabled,
      volumeMin: _num(j['volumeMin'], fallback.volumeMin),
      volumeMax: _num(j['volumeMax'], fallback.volumeMax),
      durationSecMin: _int(j['durationSecMin'], fallback.durationSecMin),
      durationSecMax: _int(j['durationSecMax'], fallback.durationSecMax),
      actionsPerHourMin:
          _int(j['actionsPerHourMin'], fallback.actionsPerHourMin),
      actionsPerHourMax:
          _int(j['actionsPerHourMax'], fallback.actionsPerHourMax),
    ).clamped();
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'volumeMin': volumeMin,
        'volumeMax': volumeMax,
        'durationSecMin': durationSecMin,
        'durationSecMax': durationSecMax,
        'actionsPerHourMin': actionsPerHourMin,
        'actionsPerHourMax': actionsPerHourMax,
      };

  PlanWindowParams copyWith({
    bool? enabled,
    double? volumeMin,
    double? volumeMax,
    int? durationSecMin,
    int? durationSecMax,
    int? actionsPerHourMin,
    int? actionsPerHourMax,
  }) =>
      PlanWindowParams(
        enabled: enabled ?? this.enabled,
        volumeMin: volumeMin ?? this.volumeMin,
        volumeMax: volumeMax ?? this.volumeMax,
        durationSecMin: durationSecMin ?? this.durationSecMin,
        durationSecMax: durationSecMax ?? this.durationSecMax,
        actionsPerHourMin: actionsPerHourMin ?? this.actionsPerHourMin,
        actionsPerHourMax: actionsPerHourMax ?? this.actionsPerHourMax,
      ).clamped();

  /// 面向用户的区间摘要（设置页展示用）。
  String describe() =>
      '音量 ${_pct(volumeMin)}–${_pct(volumeMax)} · '
      '时长 $durationSecMin–$durationSecMax 秒 · '
      '每小时 $actionsPerHourMin–$actionsPerHourMax 次';

  /// 校验区间自洽；把问题追加进 [errs]（文案面向使用者）。
  void validateInto(String label, List<String> errs) {
    if (volumeMin < 0 || volumeMin > 1 || volumeMax < 0 || volumeMax > 1) {
      errs.add('$label 音量区间必须在 0–1');
    } else if (volumeMin > volumeMax) {
      errs.add('$label 音量区间下限不能大于上限');
    }
    if (durationSecMin < 1 ||
        durationSecMin > maxDurationSec ||
        durationSecMax < 1 ||
        durationSecMax > maxDurationSec) {
      errs.add('$label 时长区间必须在 1–$maxDurationSec 秒');
    } else if (durationSecMin > durationSecMax) {
      errs.add('$label 时长区间下限不能大于上限');
    }
    if (actionsPerHourMin < 0 ||
        actionsPerHourMin > maxActionsPerHour ||
        actionsPerHourMax < 0 ||
        actionsPerHourMax > maxActionsPerHour) {
      errs.add('$label 每小时次数区间必须在 0–$maxActionsPerHour');
    } else if (actionsPerHourMin > actionsPerHourMax) {
      errs.add('$label 每小时次数区间下限不能大于上限');
    }
  }

  static double _num(Object? v, double fallback) =>
      v is num ? v.toDouble() : fallback;

  static int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;
}

/// 「反击计划」的完整生成参数。
class CounterPlanParams {
  const CounterPlanParams({
    this.schema = schemaId,
    this.dayStartHour = 8,
    this.dayEndHour = 20,
    this.cooldownSecMin = 600,
    this.cooldownSecMax = 2400,
    this.respectQuietHours = true,
    this.workdayDay = const PlanWindowParams(),
    this.workdayNight = const PlanWindowParams(
      volumeMin: 0.3,
      volumeMax: 0.5,
      durationSecMax: 5,
      actionsPerHourMax: 2,
    ),
    this.restdayDay = const PlanWindowParams(enabled: false),
    this.restdayNight = const PlanWindowParams(
      enabled: false,
      volumeMin: 0.1,
      volumeMax: 0.3,
      durationSecMax: 5,
      actionsPerHourMax: 2,
    ),
    this.presetIds = CounterPlan.defaultPresetIds,
    this.ttsTexts = CounterPlan.defaultTtsTexts,
    this.voiceId = '',
    this.scheduleMode = PlanScheduleMode.recurringRandom,
    this.occurrenceCount = 3,
    this.spanDays = 3,
    this.specificDate,
    this.rangeStart,
    this.rangeEnd,
    this.weekdays = CounterPlan.defaultWeekdays,
  });

  /// 固定 schema 标识（导入前先认版本，避免旧文件按新语义解读）。
  static const String schemaId = 'sonicshield.counterPlanParams/1';

  final String schema;

  /// 白天窗口 `[dayStartHour, dayEndHour)`；夜间为其余小时（跨午夜）。
  final int dayStartHour;
  final int dayEndHour;

  /// 生成时两次动作之间的最小间隔区间（秒）。
  final int cooldownSecMin;
  final int cooldownSecMax;

  /// 生成出的计划是否遵循全局免打扰护栏。
  final bool respectQuietHours;

  final PlanWindowParams workdayDay;
  final PlanWindowParams workdayNight;
  final PlanWindowParams restdayDay;
  final PlanWindowParams restdayNight;

  /// 生成时从这些音效 id 里随机挑选（对应 `presets_manifest.json` 的 id）。
  final List<String> presetIds;

  /// 生成时从这些 TTS 文案里随机挑选。
  final List<String> ttsTexts;

  /// 生成出的计划的 TTS 音色（空串 = 系统默认）。
  final String voiceId;

  // ---- 排期模式（v2.0，与 [CounterPlan] 一一对应）----

  /// 排期模式，默认 [PlanScheduleMode.recurringRandom]（周一至周日循环随机）。
  final PlanScheduleMode scheduleMode;

  /// [PlanScheduleMode.several] 的总条数（几次）。
  final int occurrenceCount;

  /// [PlanScheduleMode.severalDays] 的覆盖天数（几日）。
  final int spanDays;

  /// [PlanScheduleMode.specificDate] 的指定日期（ISO `yyyy-MM-dd`）。
  final String? specificDate;

  /// [PlanScheduleMode.dateRange] 的起止日期（ISO `yyyy-MM-dd`，含端点）。
  final String? rangeStart;
  final String? rangeEnd;

  /// [PlanScheduleMode.recurringRandom] 的循环星期集合（1=周一 … 7=周日）。
  final List<int> weekdays;

  /// 与 [CounterPlan] 同源的长度上限。
  static const int maxTtsTextLen = CounterPlan.maxTtsTextLen;
  static const int maxOccurrenceCount = CounterPlan.maxOccurrenceCount;
  static const int maxSpanDays = CounterPlan.maxSpanDays;
  static const int maxCooldownSec = CounterPlan.maxCooldownSec;

  /// 出厂默认参数：与用户约定的区间一致（工作日白天 50–80% / 3–8s 等）。
  static CounterPlanParams defaults() => const CounterPlanParams();

  /// 取某日类型 + 时段对应的区间参数。
  PlanWindowParams windowFor(DayKind kind, {required bool isNight}) =>
      switch ((kind, isNight)) {
        (DayKind.workday, false) => workdayDay,
        (DayKind.workday, true) => workdayNight,
        (DayKind.restday, false) => restdayDay,
        (DayKind.restday, true) => restdayNight,
      };

  /// 是否有任何时段参与生成。
  bool get anyEnabled =>
      workdayDay.enabled ||
      workdayNight.enabled ||
      restdayDay.enabled ||
      restdayNight.enabled;

  /// 容错解析（**永不抛**）：结构不符回默认、越界值夹紧。
  factory CounterPlanParams.fromJson(Object? raw) {
    if (raw is! Map) return defaults();
    final j = raw.cast<String, dynamic>();
    final d = defaults();
    final workday = j['workday'];
    final restday = j['restday'];
    Map<String, dynamic>? sub(Object? v) =>
        v is Map ? v.cast<String, dynamic>() : null;
    final wd = sub(workday);
    final rd = sub(restday);
    return CounterPlanParams(
      schema: j['schema'] as String? ?? d.schema,
      dayStartHour: PlanWindowParams._int(j['dayStartHour'], d.dayStartHour),
      dayEndHour: PlanWindowParams._int(j['dayEndHour'], d.dayEndHour),
      cooldownSecMin:
          PlanWindowParams._int(j['cooldownSecMin'], d.cooldownSecMin),
      cooldownSecMax:
          PlanWindowParams._int(j['cooldownSecMax'], d.cooldownSecMax),
      respectQuietHours:
          j['respectQuietHours'] as bool? ?? d.respectQuietHours,
      workdayDay: PlanWindowParams.fromJson(wd?['day'], d.workdayDay),
      workdayNight: PlanWindowParams.fromJson(wd?['night'], d.workdayNight),
      restdayDay: PlanWindowParams.fromJson(rd?['day'], d.restdayDay),
      restdayNight: PlanWindowParams.fromJson(rd?['night'], d.restdayNight),
      presetIds: _strList(j['presetIds'], d.presetIds),
      ttsTexts: _strList(j['ttsTexts'], d.ttsTexts),
      voiceId: j['voiceId'] as String? ?? d.voiceId,
      scheduleMode: PlanScheduleMode.parse(j['scheduleMode']),
      occurrenceCount: PlanWindowParams._int(j['occurrenceCount'], d.occurrenceCount),
      spanDays: PlanWindowParams._int(j['spanDays'], d.spanDays),
      specificDate: _strOrNull(j['specificDate']),
      rangeStart: _strOrNull(j['rangeStart']),
      rangeEnd: _strOrNull(j['rangeEnd']),
      weekdays: _isoWeekdays(j['weekdays']),
    ).clamped();
  }

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'dayStartHour': dayStartHour,
        'dayEndHour': dayEndHour,
        'cooldownSecMin': cooldownSecMin,
        'cooldownSecMax': cooldownSecMax,
        'respectQuietHours': respectQuietHours,
        'workday': {
          'day': workdayDay.toJson(),
          'night': workdayNight.toJson(),
        },
        'restday': {
          'day': restdayDay.toJson(),
          'night': restdayNight.toJson(),
        },
        'presetIds': presetIds,
        'ttsTexts': ttsTexts,
        'voiceId': voiceId,
        'scheduleMode': scheduleMode.name,
        'occurrenceCount': occurrenceCount,
        'spanDays': spanDays,
        if (specificDate != null) 'specificDate': specificDate,
        if (rangeStart != null) 'rangeStart': rangeStart,
        if (rangeEnd != null) 'rangeEnd': rangeEnd,
        'weekdays': weekdays,
      };

  /// 返回**保证合法**的副本（越界夹紧 / min>max 交换 / 小时数回绕）。
  CounterPlanParams clamped() => CounterPlanParams(
        schema: schema,
        dayStartHour: dayStartHour.clamp(0, 23).toInt(),
        dayEndHour: dayEndHour.clamp(0, 23).toInt(),
        cooldownSecMin: cooldownSecMin.clamp(0, maxCooldownSec).toInt(),
        cooldownSecMax: cooldownSecMax.clamp(0, maxCooldownSec).toInt(),
        respectQuietHours: respectQuietHours,
        workdayDay: workdayDay.clamped(),
        workdayNight: workdayNight.clamped(),
        restdayDay: restdayDay.clamped(),
        restdayNight: restdayNight.clamped(),
        presetIds: presetIds.where((e) => e.trim().isNotEmpty).toList(),
        ttsTexts: ttsTexts.where((e) => e.trim().isNotEmpty).toList(),
        voiceId: voiceId,
        scheduleMode: scheduleMode,
        occurrenceCount: occurrenceCount.clamp(1, maxOccurrenceCount).toInt(),
        spanDays: spanDays.clamp(1, maxSpanDays).toInt(),
        specificDate: specificDate,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        weekdays: _normalizeWeekdays(weekdays),
      );

  /// 校验：返回问题列表（空 = 通过）。文案面向使用者，可直接显示。
  List<String> validate() {
    final errs = <String>[];
    if (schema != schemaId) {
      errs.add('schema 不匹配：期望 $schemaId，实际「$schema」');
    }
    if (dayStartHour < 0 || dayStartHour > 23) errs.add('白天起点小时必须在 0–23');
    if (dayEndHour < 0 || dayEndHour > 23) errs.add('白天终点小时必须在 0–23');
    if (dayStartHour == dayEndHour) errs.add('白天起点与终点不能相同');
    if (cooldownSecMin < 0 || cooldownSecMin > maxCooldownSec) {
      errs.add('动作间隔区间下限必须在 0–$maxCooldownSec 秒');
    }
    if (cooldownSecMax < 0 || cooldownSecMax > maxCooldownSec) {
      errs.add('动作间隔区间上限必须在 0–$maxCooldownSec 秒');
    }
    if (cooldownSecMin > cooldownSecMax) {
      errs.add('动作间隔区间下限不能大于上限');
    }

    workdayDay.validateInto('工作日·白天', errs);
    workdayNight.validateInto('工作日·夜间', errs);
    restdayDay.validateInto('休息日·白天', errs);
    restdayNight.validateInto('休息日·夜间', errs);

    if (!anyEnabled) {
      errs.add('至少需要启用一个时段（工作日白天/夜间、休息日白天/夜间）');
    }
    if (presetIds.isEmpty && ttsTexts.isEmpty) {
      errs.add('动作池为空：至少需要一个音效 id 或一条 TTS 文案');
    }
    for (final t in ttsTexts) {
      if (t.length > maxTtsTextLen) {
        errs.add('TTS 文案过长（上限 $maxTtsTextLen 字）：${t.substring(0, 12)}…');
      }
    }
    if (occurrenceCount < 1 || occurrenceCount > maxOccurrenceCount) {
      errs.add('「几次」的条数必须在 1–$maxOccurrenceCount');
    }
    if (spanDays < 1 || spanDays > maxSpanDays) {
      errs.add('「几日」的天数必须在 1–$maxSpanDays');
    }
    switch (scheduleMode) {
      case PlanScheduleMode.specificDate:
        if (CounterPlan.parseIsoDate(specificDate) == null) {
          errs.add('「指定日期」需要一个合法日期（yyyy-MM-dd）');
        }
      case PlanScheduleMode.dateRange:
        final s = CounterPlan.parseIsoDate(rangeStart);
        final e = CounterPlan.parseIsoDate(rangeEnd);
        if (s == null || e == null) {
          errs.add('「日期区间」需要合法的起止日期（yyyy-MM-dd）');
        } else if (s.isAfter(e)) {
          errs.add('「日期区间」的起始日期不能晚于结束日期');
        }
      case PlanScheduleMode.recurringRandom:
        if (weekdays.isEmpty || weekdays.any((w) => w < 1 || w > 7)) {
          errs.add('「循环随机」的星期集合必须在 1–7（周一至周日）且非空');
        }
      case PlanScheduleMode.single:
      case PlanScheduleMode.several:
      case PlanScheduleMode.severalDays:
        break;
    }
    return errs;
  }

  /// 是否通过校验。
  bool get isValid => validate().isEmpty;

  /// 排期模式摘要（设置页 / 回执展示用）。
  String scheduleSummary() => switch (scheduleMode) {
        PlanScheduleMode.single => '排期：单次',
        PlanScheduleMode.several => '排期：几次（共 $occurrenceCount 次）',
        PlanScheduleMode.severalDays => '排期：几日（$spanDays 天）',
        PlanScheduleMode.specificDate =>
          '排期：指定日期 ${specificDate ?? '未设置'}',
        PlanScheduleMode.dateRange =>
          '排期：日期区间 ${rangeStart ?? '?'} – ${rangeEnd ?? '?'}',
        PlanScheduleMode.recurringRandom =>
          '排期：循环随机（${_weekdayLabel(weekdays)}）',
      };

  /// 设置页展示用的多行摘要。
  String summary() {
    String line(String label, PlanWindowParams w) =>
        '$label：${w.enabled ? w.describe() : '不反击'}';
    return '${scheduleSummary()}\n'
        '白天 $dayStartHour:00–$dayEndHour:00 · '
        '间隔 $cooldownSecMin–$cooldownSecMax 秒\n'
        '${line('工作日·白天', workdayDay)}\n'
        '${line('工作日·夜间', workdayNight)}\n'
        '${line('休息日·白天', restdayDay)}\n'
        '${line('休息日·夜间', restdayNight)}';
  }

  /// 拼给 AI 的参数说明（**最小 token**：只给区间与开关，不写解释）。
  ///
  /// 与 [defaults] 同源的区间在此被替换为用户实际参数，因此 AI 与本机随机
  /// 落在**同一组约束**里，产物可互相导入。
  String toPromptHint() {
    String w(PlanWindowParams p) => p.enabled
        ? '音量${_two(p.volumeMin)}-${_two(p.volumeMax)}、'
            '时长${p.durationSecMin}-${p.durationSecMax}、'
            '每小时${p.actionsPerHourMin}-${p.actionsPerHourMax}'
        : '关闭';
    // 排期只给"模式 + 关键参数"，让 AI 回填同名 JSON 字段（与 [toJson] 一一对应）。
    final sched = switch (scheduleMode) {
      PlanScheduleMode.single => '排期=单次',
      PlanScheduleMode.several => '排期=几次(共$occurrenceCount次)',
      PlanScheduleMode.severalDays => '排期=几日($spanDays天)',
      PlanScheduleMode.specificDate => '排期=指定日期(${specificDate ?? '未设置'})',
      PlanScheduleMode.dateRange =>
        '排期=日期区间(${rangeStart ?? '?'}至${rangeEnd ?? '?'})',
      PlanScheduleMode.recurringRandom =>
        '排期=循环随机(${_weekdayLabel(weekdays)})',
    };
    return '生成一份 24 小时全天候随机反击计划。参数要求：$sched；'
        '白天 $dayStartHour-$dayEndHour 时；动作间隔 $cooldownSecMin-$cooldownSecMax 秒；'
        '工作日白天(${w(workdayDay)})；工作日夜(${w(workdayNight)})；'
        '休息日白天(${w(restdayDay)})；休息日夜(${w(restdayNight)})。';
  }

  CounterPlanParams copyWith({
    String? schema,
    int? dayStartHour,
    int? dayEndHour,
    int? cooldownSecMin,
    int? cooldownSecMax,
    bool? respectQuietHours,
    PlanWindowParams? workdayDay,
    PlanWindowParams? workdayNight,
    PlanWindowParams? restdayDay,
    PlanWindowParams? restdayNight,
    List<String>? presetIds,
    List<String>? ttsTexts,
    String? voiceId,
    PlanScheduleMode? scheduleMode,
    int? occurrenceCount,
    int? spanDays,
    String? specificDate,
    String? rangeStart,
    String? rangeEnd,
    List<int>? weekdays,
  }) =>
      CounterPlanParams(
        schema: schema ?? this.schema,
        dayStartHour: dayStartHour ?? this.dayStartHour,
        dayEndHour: dayEndHour ?? this.dayEndHour,
        cooldownSecMin: cooldownSecMin ?? this.cooldownSecMin,
        cooldownSecMax: cooldownSecMax ?? this.cooldownSecMax,
        respectQuietHours: respectQuietHours ?? this.respectQuietHours,
        workdayDay: workdayDay ?? this.workdayDay,
        workdayNight: workdayNight ?? this.workdayNight,
        restdayDay: restdayDay ?? this.restdayDay,
        restdayNight: restdayNight ?? this.restdayNight,
        presetIds: presetIds ?? this.presetIds,
        ttsTexts: ttsTexts ?? this.ttsTexts,
        voiceId: voiceId ?? this.voiceId,
        scheduleMode: scheduleMode ?? this.scheduleMode,
        occurrenceCount: occurrenceCount ?? this.occurrenceCount,
        spanDays: spanDays ?? this.spanDays,
        specificDate: specificDate ?? this.specificDate,
        rangeStart: rangeStart ?? this.rangeStart,
        rangeEnd: rangeEnd ?? this.rangeEnd,
        weekdays: weekdays ?? this.weekdays,
      );

  static List<String> _strList(Object? raw, List<String> fallback) {
    if (raw is! List) return fallback;
    return raw
        .whereType<String>()
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
}

/// `0.5` → `50%`（与 `counter_plan.describeWindow` 同口径）。
String _pct(double v) => '${(v * 100).round()}%';

/// `0.5` → `0.50`（提示词用，避免 `0.5-0.8` 被模型读成整数）。
String _two(double v) => v.toStringAsFixed(2);

/// 可空字符串字段：非字符串或空串 → null。
String? _strOrNull(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

/// 星期集合解析：只收 1–7 的整数，去重升序；空/非法 → 默认全周。
List<int> _isoWeekdays(Object? v) {
  if (v is! List) return CounterPlan.defaultWeekdays;
  final set = <int>{
    for (final e in v)
      if (e is num && e.toInt() >= 1 && e.toInt() <= 7) e.toInt(),
  };
  return set.isEmpty ? CounterPlan.defaultWeekdays : (set.toList()..sort());
}

/// 内部归一：保证星期集合非空且取值合法（供 [CounterPlanParams.clamped]）。
List<int> _normalizeWeekdays(List<int> ws) {
  final set = <int>{for (final w in ws) if (w >= 1 && w <= 7) w};
  return set.isEmpty ? CounterPlan.defaultWeekdays : (set.toList()..sort());
}

/// `[1,3,5]` → `周一、周三、周五`（全周 → `周一至周日`）。
String _weekdayLabel(List<int> ws) {
  const names = <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  final sorted = <int>{for (final w in ws) if (w >= 1 && w <= 7) w}.toList()..sort();
  if (sorted.isEmpty || sorted.length == 7) return '周一至周日';
  return sorted.map((w) => names[w - 1]).join('、');
}
