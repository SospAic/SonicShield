/// 「随机反击计划」的固定 JSON 模版与解析（v2.0）。
///
/// ## 为什么需要一个**固定 schema**
///
/// 本模版有三个来源：①本机按规则随机生成；②用户/AI 生成的 JSON 导入；
/// ③远程下发到另一台设备。三者**必须能互认**，否则"一键生成→自动导入"
/// 会时灵时不灵。因此：
/// - 顶层带 `schema` 字段（`sonicshield.counterPlan/1`）—— 导入前先认版本，
///   将来换结构可以并存解析，而不是让旧文件悄悄按新语义解读；
/// - [CounterPlan.fromJson] **永不抛异常**：读不懂的字段回到默认、越界值夹到
///   合法区间（[CounterWindow.clamped]）。这样"AI 返回的脏 JSON"不会把导入
///   整条链路打断（[validate] 负责把问题**如实报给用户**，而不是静默丢数据）；
/// - [validate] 是**质量门**：返回人类可读的中文问题列表，供"一键生成"在落库
///   前先拦一道（AI 返回不合格 → 回灌错误重试一次，见 `deepseek_service`）。
///
/// ## 与用户约定的区间（默认值即此约定）
/// | 时段 | 音量 | 动作时长 |
/// |---|---|---|
/// | 工作日·白天 | 50%–80% | 3–8s |
/// | 工作日·夜间 | 30%–50% | 3–5s |
/// | 休息日·白天（**可选**） | 50%–80% | 3–8s |
/// | 休息日·夜间（**可选**） | 10%–30% | 3–5s |
///
/// `enabled` 默认：工作日两段**开**、休息日两段**关**（"休息日反击可选"）——
/// 默认落在"更安静"的一侧，需要时由用户显式打开。
library;

import 'dart:convert';

/// 日类型：法定工作日 / 休息日（由 `china_holidays.dart` 判定）。
///
/// 放在本文件而不是节假日表里：计划结构按 [DayKind] 分组，模型先于日历存在。
enum DayKind {
  workday('工作日'),
  restday('休息日');

  const DayKind(this.label);
  final String label;
}

/// 反击计划的**排期模式**：生成出的任务覆盖哪些日期、共生成多少条。
///
/// ## 与"现有自动化任务的设置参数"的对应关系（一一对应）
/// 每种模式都映射到 `TriggerType` 的既有语义，而不是另造一套：
/// - [single] / [specificDate] ↔ `fixedOnce`（固定一次）；
/// - [several] / [severalDays] / [dateRange] ↔ 有界（随机窗口 / 日期区间）；
/// - [recurringRandom] ↔ **长期有效**（无结束日期，周一至周日循环随机）——默认。
///
/// ## 为什么不直接改成"一条随机窗口触发器"
/// 计划需要按"工作日 / 休息日"切换音量/时长区间（见
/// `counter_plan_materializer.dart` 顶部说明），而一条 `RandomWindowTrigger`
/// 只能携带**同一组**动作参数。因此本模式只约束"生成范围/条数"，每条反击仍
/// 逐日展开为一条普通自动化任务（`fixedOnce`），与手工任务完全同构。
enum PlanScheduleMode {
  single('单次'),
  several('几次'),
  severalDays('几日'),
  specificDate('指定日期'),
  dateRange('日期区间'),
  recurringRandom('循环随机');

  const PlanScheduleMode(this.label);
  final String label;

  /// 容错解析（读不懂 → 默认 [recurringRandom]，与出厂默认一致）。
  static PlanScheduleMode parse(Object? raw) {
    if (raw is String) {
      for (final m in values) {
        if (m.name == raw) return m;
      }
    }
    return PlanScheduleMode.recurringRandom;
  }
}

/// 一个"时段"的反击参数（工作日/休息日 × 白天/夜间 共四份）。
class CounterWindow {
  const CounterWindow({
    this.enabled = true,
    this.volumeMin = 0.5,
    this.volumeMax = 0.8,
    this.durationSecMin = 3,
    this.durationSecMax = 8,
    this.actionsPerHour = 1,
  });

  /// 该时段是否参与反击。休息日两段默认关闭（"可选"）。
  final bool enabled;

  final double volumeMin;
  final double volumeMax;
  final int durationSecMin;
  final int durationSecMax;

  /// 每小时期望的反击次数（0 = 不主动安排，仅保留时段开关语义）。
  final int actionsPerHour;

  /// 结构上界（防止畸形 JSON 把分片表算爆）。
  static const int maxActionsPerHour = 12;
  static const int maxDurationSec = 600;

  /// 返回**保证合法**的副本：越界值夹到边界、`min > max` 时交换。
  ///
  /// 存在的意义：`PlayAudioAction` 的构造函数带 assert，脏数据直接构造会**炸断言**。
  /// 所有"从外部输入进入本模型"的路径都必须先过这里。
  CounterWindow clamped() {
    var vMin = volumeMin.clamp(0.0, 1.0).toDouble();
    var vMax = volumeMax.clamp(0.0, 1.0).toDouble();
    if (vMin > vMax) {
      final t = vMin;
      vMin = vMax;
      vMax = t;
    }
    var dMin = durationSecMin.clamp(1, maxDurationSec).toInt();
    var dMax = durationSecMax.clamp(1, maxDurationSec).toInt();
    if (dMin > dMax) {
      final t = dMin;
      dMin = dMax;
      dMax = t;
    }
    return CounterWindow(
      enabled: enabled,
      volumeMin: vMin,
      volumeMax: vMax,
      durationSecMin: dMin,
      durationSecMax: dMax,
      actionsPerHour: actionsPerHour.clamp(0, maxActionsPerHour).toInt(),
    );
  }

  /// 容错解析。[fallback] 提供该时段应有的默认值（各时段默认不同）。
  factory CounterWindow.fromJson(Object? raw, CounterWindow fallback) {
    if (raw is! Map) return fallback;
    final j = raw.cast<String, dynamic>();
    return CounterWindow(
      enabled: j['enabled'] as bool? ?? fallback.enabled,
      volumeMin: _num(j['volumeMin'], fallback.volumeMin),
      volumeMax: _num(j['volumeMax'], fallback.volumeMax),
      durationSecMin: _int(j['durationSecMin'], fallback.durationSecMin),
      durationSecMax: _int(j['durationSecMax'], fallback.durationSecMax),
      actionsPerHour: _int(j['actionsPerHour'], fallback.actionsPerHour),
    ).clamped();
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'volumeMin': volumeMin,
        'volumeMax': volumeMax,
        'durationSecMin': durationSecMin,
        'durationSecMax': durationSecMax,
        'actionsPerHour': actionsPerHour,
      };

  static double _num(Object? v, double fallback) =>
      v is num ? v.toDouble() : fallback;

  static int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;
}

/// 随机反击计划（固定 schema `sonicshield.counterPlan/1`）。
class CounterPlan {
  const CounterPlan({
    this.schema = schemaId,
    this.name = '全天候随机反击',
    this.version = 1,
    this.dayStartHour = 8,
    this.dayEndHour = 20,
    this.cooldownSec = 600,
    this.respectQuietHours = true,
    this.workdayDay = const CounterWindow(),
    this.workdayNight = const CounterWindow(
      volumeMin: 0.3,
      volumeMax: 0.5,
      durationSecMax: 5,
    ),
    this.restdayDay = const CounterWindow(enabled: false),
    this.restdayNight = const CounterWindow(
      enabled: false,
      volumeMin: 0.1,
      volumeMax: 0.3,
      durationSecMax: 5,
    ),
    this.presetIds = defaultPresetIds,
    this.ttsTexts = defaultTtsTexts,
    this.voiceId = '',
    this.scheduleMode = PlanScheduleMode.recurringRandom,
    this.occurrenceCount = 3,
    this.spanDays = 3,
    this.specificDate,
    this.rangeStart,
    this.rangeEnd,
    this.weekdays = defaultWeekdays,
  });

  /// 出厂预置动作池：「招人烦」音效（对应 `presets_manifest.json` 的 id）。
  ///
  /// 默认**非空**，否则模版一导入就因"动作池为空"不可用。真实可用性由物化期
  /// 用设备实际音源库求交集决定（见 `CounterPlanMaterializer.assetIdPool`）。
  static const List<String> defaultPresetIds = <String>[
    'annoy_cough_fit',
    'annoy_throat_clear_hard',
    'annoy_spit',
    'annoy_snort_laugh',
    'annoy_jeer',
    'annoy_tsk',
    'annoy_grumble',
    'annoy_what_doing',
    'annoy_hey_you',
    'annoy_mocking_laugh',
  ];

  /// 出厂 TTS 文案池（与音效池混用；音色由 [voiceId] 决定）。
  static const List<String> defaultTtsTexts = <String>[
    '干啥呢？',
    '小点声行不行？',
    '还让不让人睡了？',
    '有完没完？',
    '咳、咳。',
    '差不多得了。',
  ];

  /// 固定 schema 标识。导入前先比对，避免"旧文件按新语义解读"。
  static const String schemaId = 'sonicshield.counterPlan/1';

  /// 白天起点小时（含），夜间 = 其余部分（跨午夜）。
  static const int defaultDayStartHour = 8;

  /// 白天终点小时（不含），也是夜间起点。
  static const int defaultDayEndHour = 20;

  final String schema;
  final String name;
  final int version;

  /// 白天窗口 `[dayStartHour, dayEndHour)`；夜间为其余小时（跨午夜）。
  final int dayStartHour;
  final int dayEndHour;

  /// 同一次反击之间的最小间隔（秒），用于抽取时刻时保证不扎堆。
  final int cooldownSec;

  /// 是否遵循全局免打扰护栏。
  ///
  /// true（默认，更安全）= 夜间时段仍受免打扰约束，命中则跳过；
  /// false = 计划内任务标记 `quietExempt` —— **但仍需全局主开关同时开启**
  /// 才生效（Two-Key Safety，见 `ScheduleEngine.allowQuietExempt`）。
  final bool respectQuietHours;

  final CounterWindow workdayDay;
  final CounterWindow workdayNight;

  /// 休息日两段（可选，默认关闭）。
  final CounterWindow restdayDay;
  final CounterWindow restdayNight;

  /// 可播放的预置音效 id 池（对应 `assets/audio/presets_manifest.json` 的 id）。
  final List<String> presetIds;

  /// 可选 TTS 文案池（与 [presetIds] 二选一或混用）。
  final List<String> ttsTexts;

  /// TTS 音色 id（见 `TtsVoices`）；空串 = 系统默认。
  final String voiceId;

  // ---- 排期模式（v2.0，见 [PlanScheduleMode]）----

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

  /// 循环随机默认覆盖周一至周日（全部）。
  static const List<int> defaultWeekdays = <int>[1, 2, 3, 4, 5, 6, 7];

  /// 单次批量的条数上界（与物化器 `maxTasksPerDay` 同量级，防畸形输入算爆）。
  static const int maxOccurrenceCount = 96;

  /// 覆盖天数上界（约一季度，足够覆盖任意连休）。
  static const int maxSpanDays = 92;

  /// 单次/指定日期 / 次数批量模式是否"有界"（不需要滚动续算）。
  bool get isRecurring => scheduleMode == PlanScheduleMode.recurringRandom;

  /// 解析 ISO 日期（读不懂 → null，**不抛**）。
  static DateTime? parseIsoDate(String? s) {
    if (s == null) return null;
    final t = s.trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(t);
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final d = int.tryParse(m.group(3)!);
    if (y == null || mo == null || d == null) return null;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return DateTime(y, mo, d);
  }

  DateTime? get specificDateValue => parseIsoDate(specificDate);
  DateTime? get rangeStartValue => parseIsoDate(rangeStart);
  DateTime? get rangeEndValue => parseIsoDate(rangeEnd);

  /// 单条 TTS 文案长度上限（与 `TaskWire.maxTextLen` 同源语义）。
  static const int maxTtsTextLen = 200;

  static const int maxCooldownSec = 86400;

  /// 计划内任务 id 的命名空间前缀（与手动任务隔离）。
  static const String taskPrefix = 'counter:';

  /// 出厂默认计划：满足用户约定的全部区间约束。
  static CounterPlan defaults() => const CounterPlan();

  /// 取某日类型 + 时段对应的参数。
  CounterWindow windowFor(DayKind kind, {required bool isNight}) =>
      switch ((kind, isNight)) {
        (DayKind.workday, false) => workdayDay,
        (DayKind.workday, true) => workdayNight,
        (DayKind.restday, false) => restdayDay,
        (DayKind.restday, true) => restdayNight,
      };

  /// 是否有任何时段启用。
  bool get anyEnabled =>
      workdayDay.enabled ||
      workdayNight.enabled ||
      restdayDay.enabled ||
      restdayNight.enabled;

  /// 校验：返回问题列表（空 = 通过）。文案面向使用者，可直接显示。
  List<String> validate() {
    final errs = <String>[];
    if (schema != schemaId) {
      errs.add('schema 不匹配：期望 $schemaId，实际「$schema」');
    }
    if (version < 1) errs.add('version 必须 ≥ 1');
    if (dayStartHour < 0 || dayStartHour > 23) errs.add('白天起点小时必须在 0–23');
    if (dayEndHour < 0 || dayEndHour > 23) errs.add('白天终点小时必须在 0–23');
    if (dayStartHour == dayEndHour) errs.add('白天起点与终点不能相同');

    void checkWindow(String label, CounterWindow w) {
      if (w.volumeMin < 0 || w.volumeMin > 1 || w.volumeMax < 0 || w.volumeMax > 1) {
        errs.add('$label 音量必须在 0–1');
      } else if (w.volumeMin > w.volumeMax) {
        errs.add('$label 音量下限不能大于上限');
      }
      if (w.durationSecMin < 1 ||
          w.durationSecMin > CounterWindow.maxDurationSec ||
          w.durationSecMax < 1 ||
          w.durationSecMax > CounterWindow.maxDurationSec) {
        errs.add('$label 时长必须在 1–${CounterWindow.maxDurationSec} 秒');
      } else if (w.durationSecMin > w.durationSecMax) {
        errs.add('$label 时长下限不能大于上限');
      }
      if (w.actionsPerHour < 0 ||
          w.actionsPerHour > CounterWindow.maxActionsPerHour) {
        errs.add('$label 每小时次数必须在 0–${CounterWindow.maxActionsPerHour}');
      }
    }

    checkWindow('工作日·白天', workdayDay);
    checkWindow('工作日·夜间', workdayNight);
    checkWindow('休息日·白天', restdayDay);
    checkWindow('休息日·夜间', restdayNight);

    if (cooldownSec < 0 || cooldownSec > maxCooldownSec) {
      errs.add('冷却间隔必须在 0–$maxCooldownSec 秒');
    }
    if (!anyEnabled) {
      errs.add('至少需要启用一个反击时段（工作日白天/夜间、休息日白天/夜间）');
    }
    if (presetIds.isEmpty && ttsTexts.isEmpty) {
      errs.add('动作池为空：至少需要一个音效 id 或一条 TTS 文案');
    }
    for (final t in ttsTexts) {
      if (t.trim().isEmpty) {
        errs.add('TTS 文案不能为空');
        continue;
      }
      if (t.length > maxTtsTextLen) {
        errs.add('TTS 文案过长（上限 $maxTtsTextLen 字）：${t.substring(0, 12)}…');
      }
    }

    // 排期模式：只校验**当前模式真正用到的**字段，避免无关默认值误报。
    if (occurrenceCount < 1 || occurrenceCount > maxOccurrenceCount) {
      errs.add('「几次」的条数必须在 1–$maxOccurrenceCount');
    }
    if (spanDays < 1 || spanDays > maxSpanDays) {
      errs.add('「几日」的天数必须在 1–$maxSpanDays');
    }
    switch (scheduleMode) {
      case PlanScheduleMode.specificDate:
        if (specificDateValue == null) {
          errs.add('「指定日期」需要一个合法日期（yyyy-MM-dd）');
        }
      case PlanScheduleMode.dateRange:
        final s = rangeStartValue;
        final e = rangeEndValue;
        if (s == null || e == null) {
          errs.add('「日期区间」需要合法的起止日期（yyyy-MM-dd）');
        } else if (s.isAfter(e)) {
          errs.add('「日期区间」的起始日期不能晚于结束日期');
        }
      case PlanScheduleMode.recurringRandom:
        if (weekdays.isEmpty ||
            weekdays.any((w) => w < 1 || w > 7)) {
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

  /// **永不抛**的容错解析。
  ///
  /// 所有字段缺失/类型不符都回到默认；所有越界值由 [CounterWindow.clamped] 收敛。
  /// `schema` 原样保留 —— 由 [validate] 判断是否受支持，而不是在这里拒绝（否则
  /// "读不懂就丢弃"会让用户完全不知道文件为什么不生效）。
  factory CounterPlan.fromJson(Object? raw) {
    final d = CounterPlan.defaults();
    if (raw is! Map) return d;
    final j = raw.cast<String, dynamic>();
    return CounterPlan(
      schema: j['schema'] as String? ?? d.schema,
      name: _str(j['name'], d.name),
      version: _int(j['version'], d.version),
      dayStartHour: _int(j['dayStartHour'], d.dayStartHour).clamp(0, 23),
      dayEndHour: _int(j['dayEndHour'], d.dayEndHour).clamp(0, 23),
      cooldownSec:
          _int(j['cooldownSec'], d.cooldownSec).clamp(0, maxCooldownSec),
      respectQuietHours: j['respectQuietHours'] as bool? ?? d.respectQuietHours,
      workdayDay: CounterWindow.fromJson(_at(j, 'workday', 'day'), d.workdayDay),
      workdayNight:
          CounterWindow.fromJson(_at(j, 'workday', 'night'), d.workdayNight),
      restdayDay: CounterWindow.fromJson(_at(j, 'restday', 'day'), d.restdayDay),
      restdayNight:
          CounterWindow.fromJson(_at(j, 'restday', 'night'), d.restdayNight),
      presetIds: _strList(j['presetIds']),
      ttsTexts: _strList(j['ttsTexts'])
          .map((t) => t.length > maxTtsTextLen ? t.substring(0, maxTtsTextLen) : t)
          .toList(),
      voiceId: _str(j['voiceId'], ''),
      scheduleMode: PlanScheduleMode.parse(j['scheduleMode']),
      occurrenceCount: _int(j['occurrenceCount'], d.occurrenceCount)
          .clamp(1, maxOccurrenceCount),
      spanDays: _int(j['spanDays'], d.spanDays).clamp(1, maxSpanDays),
      specificDate: _strOrNull(j['specificDate']),
      rangeStart: _strOrNull(j['rangeStart']),
      rangeEnd: _strOrNull(j['rangeEnd']),
      weekdays: _isoWeekdays(j['weekdays']),
    );
  }

  /// 解析文本形式的计划（供 FilePicker 导入 / 远程下发使用）；
  /// JSON 解析失败返回 null（调用方据此如实报"文件格式错误"）。
  static CounterPlan? tryParse(String text) {
    final raw = _decode(text);
    if (raw == null) return null;
    return CounterPlan.fromJson(raw);
  }

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'name': name,
        'version': version,
        'dayStartHour': dayStartHour,
        'dayEndHour': dayEndHour,
        'cooldownSec': cooldownSec,
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

  /// **规范 JSON 文本**（缩进 2）—— 供模版下载 / 导出分发。
  String toPrettyJson() => _pretty(toJson());

  /// 深拷贝（就地编辑 UI 时避免误改原对象）。
  CounterPlan copyWith({
    String? name,
    int? dayStartHour,
    int? dayEndHour,
    int? cooldownSec,
    bool? respectQuietHours,
    CounterWindow? workdayDay,
    CounterWindow? workdayNight,
    CounterWindow? restdayDay,
    CounterWindow? restdayNight,
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
      CounterPlan(
        schema: schema,
        name: name ?? this.name,
        version: version,
        dayStartHour: dayStartHour ?? this.dayStartHour,
        dayEndHour: dayEndHour ?? this.dayEndHour,
        cooldownSec: cooldownSec ?? this.cooldownSec,
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

  // ---- 内部工具 ----

  static Object? _at(Map<String, dynamic> j, String group, String slot) {
    final g = j[group];
    if (g is! Map) return null;
    return g[slot];
  }

  static String _str(Object? v, String fallback) {
    if (v is! String) return fallback;
    final t = v.trim();
    return t.isEmpty ? fallback : t;
  }

  static int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;

  /// 可空字符串字段：非字符串或空串 → null（不落库、不参与校验）。
  static String? _strOrNull(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  /// 星期集合解析：只收 1–7 的整数，去重并升序；空/非法 → 默认全周。
  static List<int> _isoWeekdays(Object? v) {
    if (v is! List) return defaultWeekdays;
    final set = <int>{
      for (final e in v)
        if (e is num && e.toInt() >= 1 && e.toInt() <= 7) e.toInt(),
    };
    if (set.isEmpty) return defaultWeekdays;
    return set.toList()..sort();
  }

  static List<String> _strList(Object? v) {
    if (v is! List) return const <String>[];
    final out = <String>[];
    for (final e in v) {
      if (e is String && e.trim().isNotEmpty) out.add(e.trim());
    }
    return out;
  }
}

/// 顶层解码辅助（`dart:convert` 的薄封装，供 [CounterPlan.tryParse] 复用）。
Object? _decode(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  try {
    return jsonDecode(t);
  } on Object {
    return null;
  }
}

String _pretty(Map<String, dynamic> m) =>
    const JsonEncoder.withIndent('  ').convert(m);

/// 便捷别名：判断某动作是否属于"反击计划"命名空间。
bool isCounterTaskId(String taskId) =>
    taskId.startsWith(CounterPlan.taskPrefix);

/// 从反击计划任务 id 中取回其来源 planId（形如 `counter:{planId}:{key}`）。
String? counterPlanIdOf(String taskId) {
  if (!isCounterTaskId(taskId)) return null;
  final rest = taskId.substring(CounterPlan.taskPrefix.length);
  final i = rest.indexOf(':');
  return i <= 0 ? null : rest.substring(0, i);
}

/// 供 UI 展示的时长/音量描述（"白天 50%–80% · 3–8 秒"）。
String describeWindow(CounterWindow w) {
  final v = '${(w.volumeMin * 100).round()}%–${(w.volumeMax * 100).round()}%';
  return '$v · ${w.durationSecMin}–${w.durationSecMax} 秒 · 每小时 ${w.actionsPerHour} 次';
}