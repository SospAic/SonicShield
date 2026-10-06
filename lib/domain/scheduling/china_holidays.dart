/// 中国法定节假日 / 调休补班表（离线内置，纯函数）。
///
/// ## 为什么要内置一张表，而不是"周末即休息日"
///
/// 反击计划按"工作日 / 休息日"分档（白天 50–80%、夜间 30–50% …），而中国的
/// 休息日**不等于周六周日**：
/// - 法定节假日常把周末连成长假（如 2026 春节 2/15–2/23 九天）；
/// - 放假前后会**调休补班**（如 2026-02-14 周六、2026-02-28 周六上班）。
///
/// 只按星期几判断，会在"春节连休"里把工作日当休息日、在"调休周六"里把上班日
/// 当休息日 —— 反击强度整档错位。因此本表把"放假"和"补班"两张清单**显式落地**。
///
/// ## 数据来源与维护
/// - 2026：[国办发明电〔2025〕7号](https://www.gov.cn/zhengce/content/202511/content_7047090.htm)；
/// - 2025：国办发明电〔2024〕7号。
///
/// ⚠️ **表外年份回落"周一至周五 = 工作日、周六周日 = 休息日"**，并**不报错**：
/// 国务院每年 11 月才公布次年安排，跨年那一刻用不到新表是常态，此时"按星期几"
/// 是**最合理且可预期**的近似（fail-safe：宁可少放假，不要多误判休息）。
/// 需要覆盖时走 [overrides]（手动/远程下发）。
library;

import '../models/counter_plan.dart';

/// 一年的法定日历：`holidays` = 放假日，`makeupWorkdays` = 调休补班日。
///
/// 两者都按 ISO `yyyy-MM-dd` 存储：**月份补零**，字符串比较即日期比较，
/// 查找是哈希命中（O(1)），不需要构造 DateTime 反查。
class YearHolidays {
  const YearHolidays({required this.holidays, required this.makeupWorkdays});

  final Set<String> holidays;
  final Set<String> makeupWorkdays;
}

abstract final class ChinaHolidays {
  /// 内置表：年份 → 法定日历。新增年份在此追加即可。
  static const Map<int, YearHolidays> table = <int, YearHolidays>{
    2025: YearHolidays(
      holidays: <String>{
        // 元旦
        '2025-01-01',
        // 春节 1/28–2/4（8 天）
        '2025-01-28', '2025-01-29', '2025-01-30', '2025-01-31',
        '2025-02-01', '2025-02-02', '2025-02-03', '2025-02-04',
        // 清明 4/4–4/6
        '2025-04-04', '2025-04-05', '2025-04-06',
        // 劳动节 5/1–5/5
        '2025-05-01', '2025-05-02', '2025-05-03', '2025-05-04',
        '2025-05-05',
        // 端午 5/31–6/2
        '2025-05-31', '2025-06-01', '2025-06-02',
        // 国庆 + 中秋 10/1–10/8
        '2025-10-01', '2025-10-02', '2025-10-03', '2025-10-04',
        '2025-10-05', '2025-10-06', '2025-10-07', '2025-10-08',
      },
      makeupWorkdays: <String>{
        '2025-01-26', // 春节前调休（周日上班）
        '2025-02-08', // 春节后调休（周六上班）
        '2025-04-27', // 劳动节前调休（周日上班）
        '2025-09-28', // 国庆前调休（周日上班）
        '2025-10-11', // 国庆后调休（周六上班）
      },
    ),
    2026: YearHolidays(
      holidays: <String>{
        // 元旦 1/1–1/3
        '2026-01-01', '2026-01-02', '2026-01-03',
        // 春节 2/15–2/23（9 天）
        '2026-02-15', '2026-02-16', '2026-02-17', '2026-02-18',
        '2026-02-19', '2026-02-20', '2026-02-21', '2026-02-22',
        '2026-02-23',
        // 清明 4/4–4/6
        '2026-04-04', '2026-04-05', '2026-04-06',
        // 劳动节 5/1–5/5
        '2026-05-01', '2026-05-02', '2026-05-03', '2026-05-04',
        '2026-05-05',
        // 端午 6/19–6/21
        '2026-06-19', '2026-06-20', '2026-06-21',
        // 中秋 9/25–9/27
        '2026-09-25', '2026-09-26', '2026-09-27',
        // 国庆 10/1–10/7
        '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04',
        '2026-10-05', '2026-10-06', '2026-10-07',
      },
      makeupWorkdays: <String>{
        '2026-01-04', // 元旦后调休（周日上班）
        '2026-02-14', // 春节前调休（周六上班）
        '2026-02-28', // 春节后调休（周六上班）
        '2026-05-09', // 劳动节后调休（周六上班）
        '2026-09-20', // 国庆前调休（周日上班）
        '2026-10-10', // 国庆后调休（周六上班）
      },
    ),
  };

  /// 判定某日本地日历属于工作日还是休息日。
  ///
  /// 判据顺序（**补班优先**）：先查调休补班（→ 工作日），再查法定放假
  /// （→ 休息日），都没有才按星期几。顺序不能反：调休补班日本就落在周末，
  /// 若先判放假会把它当休息日。
  ///
  /// [overrides] 为可选的**逐日覆盖**（ISO `yyyy-MM-dd` → [DayKind]），
  /// 供用户手动指定或远程下发；命中则优先于内置表。传 null/空表即纯内置行为。
  static DayKind dayKind(DateTime date, {Map<String, DayKind>? overrides}) {
    final key = isoDate(date);
    final ov = overrides?[key];
    if (ov != null) return ov;

    final y = table[date.year];
    if (y != null) {
      if (y.makeupWorkdays.contains(key)) return DayKind.workday;
      if (y.holidays.contains(key)) return DayKind.restday;
    }
    // 表外年份或普通日：周六（6）/ 周日（7）为休息日。
    return (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday)
        ? DayKind.restday
        : DayKind.workday;
  }

  /// 该年是否有内置表（UI 用来提示"该年份未收录，按周末规则近似"）。
  static bool hasTableFor(int year) => table.containsKey(year);

  /// ISO `yyyy-MM-dd`（本地日历日，不含时间）。
  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 解析 override 文本（`"2026-01-04":"workday"` 形式的 JSON 对象）。
  ///
  /// 供远程/文件下发使用；读不懂的键值**跳过而不抛**（与
  /// `CounterPlan.fromJson` 同一容错口径）。
  static Map<String, DayKind> parseOverrides(Object? raw) {
    if (raw is! Map) return const <String, DayKind>{};
    final out = <String, DayKind>{};
    raw.forEach((k, v) {
      if (k is! String || v is! String) return;
      final kind = switch (v.trim().toLowerCase()) {
        'workday' || 'work' || '工作日' => DayKind.workday,
        'restday' || 'rest' || '休息日' || 'holiday' => DayKind.restday,
        _ => null,
      };
      if (kind != null && k.trim().isNotEmpty) out[k.trim()] = kind;
    });
    return out;
  }
}