import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/data/repositories/counter_plan_store.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/scheduling/china_holidays.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';
import 'package:sonic_shield/services/counter_plan_service.dart';
import 'package:sonic_shield/services/holiday_update_service.dart';

/// 中国节假日**一键更新**的收敛锁：
/// - 两种线上 JSON 结构解析（holiday-cn / timor.tech）与脏数据容错；
/// - 多源按序回退、单年失败不影响其它年；
/// - 全部失败 ⇒ **空表 + 如实报错**（不写空表、不冲内置表）；
/// - 自动覆盖表优先级：手动覆盖 > 自动表 > 内置表 > 按星期几；
/// - 落库往返 + `refreshHolidays` **只写表**（不重排、不删除、不新建任务 ——
///   与反击计划**完全解耦**：新表由"全局暂停窗口实时读表"与"`refreshIfNeeded` 续算"两条独立通路生效）。
void main() {
  /// 中文正文必须以 UTF-8 声明，否则 `http.Response` 默认按 latin1 编码会抛错
  /// （与真实服务端返回 `charset=utf-8` 一致）。
  http.Response okJson(String body) => http.Response.bytes(
        utf8.encode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  String holidayCnBody() => jsonEncode({
        'year': 2026,
        'papers': <Object>[],
        'days': [
          {'name': '元旦', 'date': '2026-01-01', 'isOffDay': true},
          {'name': '元旦后补班', 'date': '2026-01-04', 'isOffDay': false},
          {'name': '脏条目', 'isOffDay': true}, // 缺 date → 跳过
          {'name': '脏类型', 'date': '2026-01-05', 'isOffDay': 'yes'}, // 非 bool → 跳过
          {'name': '非法日期', 'date': '2026-13-40', 'isOffDay': true}, // 跳过
        ],
      });

  String timorBody() => jsonEncode({
        'code': 0,
        'holiday': {
          '01-01': {'holiday': true, 'name': '元旦', 'date': '2026-01-01'},
          '01-04': {'holiday': false, 'name': '补班'},
          'bogus': {'holiday': true}, // 非法键 → 跳过
        },
      });

  group('HU 解析（线上结构 → 覆盖表）', () {
    test('HU-01 holiday-cn：放假→休息日、补班→工作日，脏条目跳过', () {
      final m = parseHolidayCnPayload(jsonDecode(holidayCnBody()));
      expect(m['2026-01-01'], DayKind.restday);
      expect(m['2026-01-04'], DayKind.workday);
      expect(m.length, 2); // 三条脏数据全部跳过
    });

    test('HU-02 timor：holiday=bool 决定日类型，MM-DD 键补年份', () {
      final m = parseTimorPayload(jsonDecode(timorBody()), 2026);
      expect(m['2026-01-01'], DayKind.restday);
      expect(m['2026-01-04'], DayKind.workday);
      expect(m.containsKey('bogus'), isFalse);
    });

    test('HU-03 结构与类型不符 → 空表（不抛）', () {
      expect(parseHolidayCnPayload(null), isEmpty);
      expect(parseHolidayCnPayload('x'), isEmpty);
      expect(parseHolidayCnPayload({'days': 'nope'}), isEmpty);
      expect(parseTimorPayload(null, 2026), isEmpty);
      expect(parseTimorPayload({'holiday': 5}, 2026), isEmpty);
    });
  });

  group('HUS 服务（多源回退 / 失败可见）', () {
    test('HU-04 首个源成功即用，回填条数', () async {
      var hits = 0;
      final svc = HolidayUpdateService(
        client: MockClient((req) async {
          hits++;
          expect(req.url.toString(), contains('holiday-cn'));
          return okJson(holidayCnBody());
        }),
        sources: (_) => ['https://cdn.example/holiday-cn/2026.json'],
      );
      final r = await svc.update(years: [2026]);
      expect(hits, 1);
      expect(r.allOk, isTrue);
      expect(r.overrides['2026-01-01'], DayKind.restday);
      expect(r.years.single.offDays, 1);
      expect(r.years.single.makeupDays, 1);
    });

    test('HU-05 首源 404 → 回退次源（timor 结构）', () async {
      final svc = HolidayUpdateService(
        client: MockClient((req) async {
          if (req.url.toString().contains('timor')) {
            return okJson(timorBody());
          }
          return http.Response('nope', 404);
        }),
        sources: (_) => [
          'https://cdn.example/a/2026.json',
          'https://timor.tech/api/holiday/year/2026',
        ],
      );
      final r = await svc.update(years: [2026]);
      expect(r.allOk, isTrue);
      expect(r.overrides['2026-01-04'], DayKind.workday);
    });

    test('HU-06 全源失败 → ok=false、空表、如实回显原因', () async {
      final svc = HolidayUpdateService(
        client: MockClient((_) async => http.Response('boom', 500)),
        sources: (_) => ['https://cdn.example/a/2026.json'],
      );
      final r = await svc.update(years: [2026]);
      expect(r.anyOk, isFalse);
      expect(r.overrides, isEmpty); // 绝不写空表/半成品
      expect(r.years.single.ok, isFalse);
      expect(r.years.single.error, contains('500'));
      expect(r.describe(), contains('更新失败'));
    });

    test('HU-07 单年失败不影响其它年（合并仅含成功年）', () async {
      final svc = HolidayUpdateService(
        client: MockClient((req) async {
          if (req.url.path.contains('2027')) return http.Response('x', 500);
          return okJson(holidayCnBody());
        }),
        sources: (y) => ['https://cdn.example/holiday-cn/$y.json'],
      );
      final r = await svc.update(years: [2026, 2027]);
      expect(r.anyOk, isTrue);
      expect(r.allOk, isFalse);
      expect(r.overrides.keys.every((k) => k.startsWith('2026')), isTrue);
    });

    test('HU-08 defaultYears = 今年前后各一年', () {
      expect(HolidayUpdateService.defaultYears(now: DateTime(2026, 10, 6)),
          [2025, 2026, 2027]);
    });

    test('HU-08b defaultSources 返回三条候选且含 timor 兜底（106–109）', () {
      final s = HolidayUpdateService.defaultSources(2026);
      expect(s, hasLength(3));
      expect(s.first, contains('holiday-cn'));
      expect(s.last, contains('timor'));
      expect(s.where((u) => u.contains('2026.json')).length, 2,
          reason: 'holiday-cn 两条通路都按年份拼 URL');
    });

    test('HU-06b 网络异常（非 HTTP 错误）→ 捕获并回显简报（150/156–158）', () async {
      final svc = HolidayUpdateService(
        client: MockClient((_) async => throw Exception('net down')),
        sources: (_) => ['https://cdn.example/a/2026.json'],
        timeout: const Duration(milliseconds: 200),
      );
      final r = await svc.update(years: [2026]);
      expect(r.anyOk, isFalse);
      expect(r.overrides, isEmpty);
      expect(r.years.single.ok, isFalse);
      expect(r.years.single.error, contains('net down'),
          reason: '异常必须被 _brief 收敛成可读原因，而不是静默丢弃');
    });
  });

  group('HUC 覆盖优先级与落库', () {
    test('HU-09 优先级：手动 > 自动 > 内置', () {
      final auto = <String, DayKind>{'2026-02-14': DayKind.restday};
      final manual = <String, DayKind>{'2026-02-14': DayKind.workday};

      // 自动表压过内置表（内置 2026-02-14 是调休补班 → workday）
      expect(ChinaHolidays.dayKind(DateTime(2026, 2, 14), autoOverrides: auto),
          DayKind.restday);
      // 手动覆盖再压过自动表
      expect(
          ChinaHolidays.dayKind(DateTime(2026, 2, 14),
              overrides: manual, autoOverrides: auto),
          DayKind.workday);
      // 无覆盖时回到内置表
      expect(ChinaHolidays.dayKind(DateTime(2026, 2, 14)), DayKind.workday);
    });

    test('HU-10 物化尊重自动覆盖表（休息日/工作日互换）', () {
      // 2026-03-11 是周三（工作日）。把整段 horizon 全设为休息日。
      final plan = CounterPlan.defaults().copyWith(
        workdayDay: const CounterWindow(enabled: false),
        workdayNight: const CounterWindow(enabled: false),
        restdayDay: const CounterWindow(actionsPerHour: 1),
        restdayNight: const CounterWindow(enabled: false),
      );
      final auto = <String, DayKind>{'2026-03-11': DayKind.restday};
      final tasks = CounterPlanMaterializer.materialize(
        plan,
        planId: 'p',
        from: DateTime(2026, 3, 11),
        days: 1,
        assetIdPool: const {'a1'},
        autoOverrides: auto,
      );
      expect(tasks, isNotEmpty);
      expect(tasks.every((t) => t.name.contains('休息日')), isTrue);
    });

    test('HU-11 自动表落库往返 + 更新时间', () async {
      SharedPreferences.setMockInitialValues({});
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      final at = DateTime(2026, 10, 6, 12);
      await store.setAutoOverrides(
          {'2026-01-04': DayKind.workday, '2026-10-01': DayKind.restday},
          at: at);
      expect(store.autoOverrides()['2026-01-04'], DayKind.workday);
      expect(store.autoOverridesUpdatedAt(), at);
      // 手动覆盖是另一把键，互不影响
      await store.setOverrides({'2026-01-04': DayKind.restday});
      expect(store.autoOverrides()['2026-01-04'], DayKind.workday);
      expect(store.overrides()['2026-01-04'], DayKind.restday);
      // 清空
      await store.setAutoOverrides(const {});
      expect(store.autoOverrides(), isEmpty);
      expect(store.autoOverridesUpdatedAt(), isNull);
    });

    test('HU-12 refreshHolidays：**只写表** —— 不重排、不删除、不新建任务', () async {
      SharedPreferences.setMockInitialValues({});
      final tasks = _FakeTasks();
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      var replans = 0;
      final svc = CounterPlanService(
        tasks: tasks,
        store: store,
        resolveAudioIds: (_) async => const {'a1'},
        replan: () async => replans++,
      );

      // 尚无计划 / 未启用：表已存下，如实说明
      final r1 = await svc.refreshHolidays({'2026-01-04': DayKind.workday});
      expect(r1.ok, isTrue);
      expect(store.autoOverrides()['2026-01-04'], DayKind.workday);
      expect(replans, 0);

      // 启用之后再更新：**仍然只写表** —— 这是本轮修正点。
      // 修前此处走 `apply(replace: true)`：按命名空间**整族删除** counter 任务再重建，
      // 提示语还回「反击计划已生效：排入 N 条计划任务」（未声明的副作用 + 删历史）。
      await svc.apply(CounterPlan.defaults(), now: DateTime(2026, 3, 10));
      replans = 0;
      tasks.deletedPlanIds.clear();
      tasks.upserted.clear();
      final r2 = await svc.refreshHolidays(
          {'2026-03-11': DayKind.restday},
          now: DateTime(2026, 3, 10));
      expect(r2.ok, isTrue);
      expect(store.autoOverrides()['2026-03-11'], DayKind.restday);
      expect(store.autoOverridesUpdatedAt(), DateTime(2026, 3, 10));
      expect(replans, 0, reason: '节假日更新不得触发重排');
      expect(tasks.deletedPlanIds, isEmpty, reason: '节假日更新不得删除任何反击任务');
      expect(tasks.upserted, isEmpty, reason: '节假日更新不得新建/覆盖任务');
      expect(r2.message, isNot(contains('反击计划已生效')));

      // 空表 = 清除
      final r3 = await svc.refreshHolidays(const {});
      expect(r3.ok, isTrue);
      expect(store.autoOverrides(), isEmpty);
    });
  });
}

class _FakeTasks implements TaskRepository {
  final List<Task> upserted = [];
  final List<String> deletedPlanIds = [];

  @override
  Future<void> upsertMany(Iterable<Task> items) async => upserted.addAll(items);

  @override
  Future<int> deleteCounterTasks(String planId) async {
    deletedPlanIds.add(planId);
    return upserted.length;
  }

  @override
  Future<List<String>> counterTaskIds(String planId) async => const [];

  @override
  Future<List<Task>> listAll({bool enabledOnly = false}) async => const [];

  @override
  Future<Task?> get(String id) async => null;

  @override
  Future<void> upsert(Task t) async {}

  @override
  Future<void> setEnabled(String id, bool enabled) async {}

  @override
  Future<void> delete(String id) async {}

  // BUG-148 新增的仓储方法：本替身只服务节假日用例，无需真实语义。
  @override
  Future<int> removeAssetRef(String assetId) async => 0;
}
