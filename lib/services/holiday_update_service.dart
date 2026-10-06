/// 中国节假日安排**一键更新（联网）**——拉取公开数据源、解析为逐日覆盖表。
///
/// ## 为什么是"覆盖表"而不是改写内置表
/// 内置表（`china_holidays.dart` 的 `table`）是**编译期常量**，运行期不可变。
/// 一键更新产出的是一张 `yyyy-MM-dd → DayKind` 的**自动覆盖表**，随计划一起
/// 落库在 `counter_plan_auto_overrides`。判定优先级：
/// 手动覆盖 > 自动更新表 > 内置表 > 按星期几。好处：
/// - 内置表仍是**兜底真源**，联网失败时行为不变（`docs/53 §3.2`）；
/// - 下一次更新**整体替换**自动表，不会把历史拉取结果越积越多；
/// - 用户手改的那几天（手动覆盖）**永远不被联网更新冲掉**。
///
/// ## 失败要可见，不静默
/// 每个年份独立拉取：单年失败**不影响**其它年；全部失败时返回的 [overrides]
/// 为空，调用方据此**如实报错**且**保留内置表**（不写空表、不清旧表）。
///
/// ## 数据源（按顺序尝试，首个成功即用）
/// 1. `holiday-cn`（NateScarlet，GitHub）经 jsDelivr CDN —— 国内可达性较好；
/// 2. 同上的 `raw.githubusercontent.com` 直连（兜底）；
/// 3. `timor.tech` 节假日 API（另一套 JSON 结构，单独解析）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/models/counter_plan.dart';

/// 单年拉取结果。
class HolidayYearResult {
  const HolidayYearResult._({
    required this.year,
    required this.ok,
    required this.offDays,
    required this.makeupDays,
    this.error,
    this.source,
  });

  factory HolidayYearResult.ok(int year,
          {required int offDays, required int makeupDays, String? source}) =>
      HolidayYearResult._(
          year: year,
          ok: true,
          offDays: offDays,
          makeupDays: makeupDays,
          source: source);

  factory HolidayYearResult.fail(int year, String error) => HolidayYearResult._(
      year: year, ok: false, offDays: 0, makeupDays: 0, error: error);

  final int year;
  final bool ok;

  /// 该年放假日数 / 调休补班日数（成功时有意义）。
  final int offDays;
  final int makeupDays;

  /// 失败原因（如实回显给用户）。
  final String? error;

  /// 命中的数据源（便于排查"哪条通路可用"）。
  final String? source;

  String get describe => ok
      ? '$year：放假 $offDays 天、补班 $makeupDays 天'
      : '$year：更新失败（${error ?? '未知原因'}）';
}

/// 一次一键更新的总结果。
class HolidayUpdateResult {
  const HolidayUpdateResult({required this.years, required this.overrides});

  final List<HolidayYearResult> years;

  /// 各年成功拉取的日期覆盖合并表（全部失败 ⇒ 空表）。
  final Map<String, DayKind> overrides;

  bool get anyOk => years.any((y) => y.ok);
  bool get allOk => years.isNotEmpty && years.every((y) => y.ok);

  /// 面向用户的多行说明。
  String describe() => years.map((y) => y.describe).join('\n');
}

/// 联网拉取 + 解析节假日安排（**纯编排**：网络与解析分离，解析可单测）。
class HolidayUpdateService {
  HolidayUpdateService({
    required http.Client client,
    List<String> Function(int year)? sources,
    Duration timeout = const Duration(seconds: 12),
  })  : _client = client,
        _sources = sources ?? defaultSources,
        _timeout = timeout;

  final http.Client _client;
  final List<String> Function(int year) _sources;
  final Duration _timeout;

  /// 默认目标年份：今年以及前后各一年（覆盖"跨年更新次年安排"的常见场景）。
  static List<int> defaultYears({DateTime? now}) {
    final y = (now ?? DateTime.now()).year;
    return <int>[y - 1, y, y + 1];
  }

  /// 数据源候选（按可达性从高到低尝试）。
  static List<String> defaultSources(int year) => <String>[
        'https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/$year.json',
        'https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/$year.json',
        'https://timor.tech/api/holiday/year/$year',
      ];

  /// 拉取并解析若干年份。**不抛**：所有失败都收敛进结果对象。
  Future<HolidayUpdateResult> update({List<int>? years}) async {
    final ys = years ?? defaultYears();
    final all = <String, DayKind>{};
    final results = <HolidayYearResult>[];
    for (final y in ys) {
      final (res, ov) = await _fetchYear(y);
      results.add(res);
      if (res.ok) all.addAll(ov);
    }
    return HolidayUpdateResult(years: results, overrides: all);
  }

  Future<(HolidayYearResult, Map<String, DayKind>)> _fetchYear(int year) async {
    var last = '无可用数据源';
    for (final url in _sources(year)) {
      try {
        final resp = await _client.get(Uri.parse(url)).timeout(_timeout);
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          last = 'HTTP ${resp.statusCode}';
          continue;
        }
        final json = jsonDecode(resp.body);
        final parsed = url.contains('timor')
            ? parseTimorPayload(json, year)
            : parseHolidayCnPayload(json);
        if (parsed.isEmpty) {
          last = '返回内容不含可用日期';
          continue;
        }
        final off = parsed.values.where((k) => k == DayKind.restday).length;
        final makeup = parsed.values.where((k) => k == DayKind.workday).length;
        return (
          HolidayYearResult.ok(year,
              offDays: off, makeupDays: makeup, source: url),
          parsed
        );
      } on Object catch (e) {
        last = _brief(e);
      }
    }
    return (HolidayYearResult.fail(year, last), const <String, DayKind>{});
  }

  static String _brief(Object e) {
    final s = e.toString();
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }
}

/// 解析 `holiday-cn` 结构：
/// `{"year":2026,"days":[{"name":"元旦","date":"2026-01-01","isOffDay":true},…]}`。
///
/// 容错口径与全项目一致：读不懂的条目**跳过而不抛**；date 必须能解析成
/// 合法 `yyyy-MM-dd`，`isOffDay` 必须是布尔。全部无效 ⇒ 空表（调用方报错）。
Map<String, DayKind> parseHolidayCnPayload(Object? raw) {
  if (raw is! Map) return const <String, DayKind>{};
  final days = raw['days'];
  if (days is! List) return const <String, DayKind>{};
  final out = <String, DayKind>{};
  for (final d in days) {
    if (d is! Map) continue;
    final date = d['date'];
    final off = d['isOffDay'];
    if (date is! String || off is! bool) continue;
    final iso = date.trim();
    if (CounterPlan.parseIsoDate(iso) == null) continue;
    out[iso] = off ? DayKind.restday : DayKind.workday;
  }
  return out;
}

/// 解析 `timor.tech` 结构：`{"holiday":{"01-01":{"holiday":true,"date":"2026-01-01"},…}}`。
///
/// 键是 `MM-DD`，需补上年份；条目里也可能直接带 `date`。`holiday==true` ⇒ 放假，
/// `false` ⇒ 调休补班。非法条目跳过。
Map<String, DayKind> parseTimorPayload(Object? raw, int year) {
  if (raw is! Map) return const <String, DayKind>{};
  final h = raw['holiday'];
  if (h is! Map) return const <String, DayKind>{};
  final out = <String, DayKind>{};
  h.forEach((k, v) {
    if (v is! Map) return;
    final direct = v['date'];
    String iso;
    if (direct is String && CounterPlan.parseIsoDate(direct.trim()) != null) {
      iso = direct.trim();
    } else if (k is String && RegExp(r'^\d{2}-\d{2}$').hasMatch(k.trim())) {
      iso = '$year-${k.trim()}';
      if (CounterPlan.parseIsoDate(iso) == null) return;
    } else {
      return;
    }
    final off = v['holiday'];
    if (off is! bool) return;
    out[iso] = off ? DayKind.restday : DayKind.workday;
  });
  return out;
}
