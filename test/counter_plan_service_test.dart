import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/data/repositories/counter_plan_store.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/china_holidays.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';
import 'package:sonic_shield/services/counter_plan_service.dart';

/// 反击计划「落库编排 + 持久化」的纯逻辑锁：
/// - `CounterPlanService`：校验前置、命名空间整族替换、自动续算语义；
/// - `CounterPlanStore`：缺省值 / 往返 / 覆盖表 / 清除；
/// - 顶层解析工具：任务 id 取日、点名音效回查。
///
/// 仓储与音源解析都用**替身**表达（`implements TaskRepository`），
/// 从而这些"落哪几条、删哪一族、续不续算"的判断能在宿主测试里被穷举。
void main() {
  group('CPST 反击计划持久化', () {
    test('CPST-01 空存储：id 回落 local、enabled=false、plan=null', () async {
      SharedPreferences.setMockInitialValues({});
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      expect(store.planId, CounterPlanStore.defaultPlanId);
      expect(store.enabled, isFalse);
      expect(store.loadPlan(), isNull);
      expect(store.overrides(), isEmpty);
    });

    test('CPST-02 计划本体 JSON 往返 + enabled 同写', () async {
      SharedPreferences.setMockInitialValues({});
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      final plan = CounterPlan.defaults().copyWith(name: '我的计划');
      await store.savePlan(plan, id: 'my plan!', enabled: true);
      expect(store.planId, 'my_plan_'); // 归一化：非 [A-Za-z0-9_-] → _
      expect(store.enabled, isTrue);
      final back = store.loadPlan()!;
      expect(back.name, '我的计划');
      expect(back.schema, CounterPlan.schemaId);
      expect(back.workdayDay.volumeMin, plan.workdayDay.volumeMin);
    });

    test('CPST-03 覆盖表往返；空表即清除', () async {
      SharedPreferences.setMockInitialValues({});
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      await store.setOverrides({'2026-02-14': DayKind.restday});
      expect(store.overrides()['2026-02-14'], DayKind.restday);
      await store.setOverrides(const {});
      expect(store.overrides(), isEmpty);
    });

    test('CPST-04 损坏 JSON → null / 空表（不抛）', () async {
      SharedPreferences.setMockInitialValues({
        'counter_plan_json': '{不是 json',
        'counter_plan_overrides': '[不该是数组',
      });
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      expect(store.loadPlan(), isNull);
      expect(store.overrides(), isEmpty);
    });

    test('CPST-05 clear 清空全部状态', () async {
      SharedPreferences.setMockInitialValues({});
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      await store.savePlan(CounterPlan.defaults(), id: 'x', enabled: true);
      await store.setOverrides({'2026-01-04': DayKind.workday});
      await store.clear();
      expect(store.loadPlan(), isNull);
      expect(store.enabled, isFalse);
      expect(store.planId, CounterPlanStore.defaultPlanId);
      expect(store.overrides(), isEmpty);
    });
  });

  group('CPSV 反击计划编排', () {
    Future<(CounterPlanService, _FakeTasks, CounterPlanStore)> build({
      Set<String> audio = const {'a1', 'a2'},
      List<String> existing = const [],
    }) async {
      SharedPreferences.setMockInitialValues({});
      final tasks = _FakeTasks(existing: existing);
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      var replans = 0;
      final svc = CounterPlanService(
        tasks: tasks,
        store: store,
        resolveAudioIds: (ids) async => audio,
        replan: () async => replans++,
      );
      // 把 replan 计数挂在 tasks 上便于断言。
      tasks.replanCount = () => replans;
      return (svc, tasks, store);
    }

    CounterPlan planFor({
      bool restday = false,
      List<String> presets = const ['annoy_cough_fit'],
      List<String> tts = const [],
    }) =>
        CounterPlan(
          presetIds: presets,
          ttsTexts: tts,
          workdayDay: const CounterWindow(
              volumeMin: 0.5, volumeMax: 0.8, durationSecMin: 3, durationSecMax: 8),
          workdayNight: const CounterWindow(
              volumeMin: 0.3, volumeMax: 0.5, durationSecMin: 3, durationSecMax: 5),
          restdayDay: CounterWindow(enabled: restday),
          restdayNight: CounterWindow(enabled: restday),
        );

    test('CPSV-01 合规计划 → 落库 + 启用 + 触发重算；音量区间与时段一致', () async {
      final (svc, tasks, store) = await build();
      // 2026-03-10 周二 → 之后 7 天含两个休息日（3/14、3/15，未启用）。
      final r = await svc.apply(planFor(),
          planId: 'local', now: DateTime(2026, 3, 10), days: 7);
      expect(r.ok, isTrue, reason: r.message);
      expect(r.taskCount, greaterThan(0));
      expect(store.enabled, isTrue);
      expect(store.loadPlan(), isNotNull);
      expect(tasks.replanCount!(), 1);
      expect(tasks.deletedPlanIds, ['local']);

      final fires = tasks.upserted.toList();
      for (final t in fires) {
        // 未启用休息日 ⇒ 不生成"休息日来源"的任务（id 段含来源日 + D/N）。
        expect(t.trigger is FixedOnceTrigger, isTrue);
        final seg = t.id.substring(t.id.lastIndexOf(':') + 1);
        final day = DateTime(int.parse(seg.substring(0, 4)),
            int.parse(seg.substring(4, 6)), int.parse(seg.substring(6, 8)));
        final isNight = seg[8] == 'N';
        expect(ChinaHolidays.dayKind(day), DayKind.workday,
            reason: '出现了休息日来源的任务 ${t.id}');
        final a = t.action;
        expect(a, isA<PlayAudioAction>());
        final pa = a as PlayAudioAction;
        if (isNight) {
          expect(pa.volumeMin, 0.3);
          expect(pa.volumeMax, 0.5);
          expect(pa.durationSecMin, 3);
          expect(pa.durationSecMax, 5);
        } else {
          expect(pa.volumeMin, 0.5);
          expect(pa.volumeMax, 0.8);
          expect(pa.durationSecMin, 3);
          expect(pa.durationSecMax, 8);
        }
        expect(t.assetIds.length, 1);
      }
      expect(tasks.upserted.length, r.taskCount);
    });

    test('CPSV-02 不合格计划 → 如实失败，不落库不重算', () async {
      final (svc, tasks, store) = await build();
      final bad = planFor().copyWith(name: 'x');
      // 用 schema 不匹配触发校验失败。
      final broken = CounterPlan(
        schema: 'other/9',
        presetIds: bad.presetIds,
        ttsTexts: bad.ttsTexts,
      );
      final r = await svc.apply(broken, now: DateTime(2026, 3, 10));
      expect(r.ok, isFalse);
      expect(r.message, contains('schema'));
      expect(tasks.upserted, isEmpty);
      expect(tasks.deletedPlanIds, isEmpty);
      expect(store.loadPlan(), isNull);
      expect(tasks.replanCount!(), 0);
    });

    test('CPSV-03 点名音效本机没有且无 TTS → 失败并给出可操作提示', () async {
      final (svc, tasks, _) = await build(audio: const {});
      final r = await svc.apply(planFor(tts: const []),
          now: DateTime(2026, 3, 10));
      expect(r.ok, isFalse);
      expect(r.message, contains('音源库'));
      expect(tasks.upserted, isEmpty);
    });

    test('CPSV-04 无可用音效 → 如实失败（2026-10 起不再有 TTS 兜底）', () async {
      // 产品决策（docs/59 + v2.x）：守护反击只播随机噪音，不播 TTS 语音。
      // 因此「无音效」不再是"退化 TTS 池"，而是如实失败 + 引导导入音源库。
      // 旧契约（无音效→生成 TTS 任务）在此显式作废。
      final (svc, tasks, _) = await build(audio: const {});
      final r = await svc.apply(planFor(tts: const ['干啥呢？']),
          now: DateTime(2026, 3, 10), days: 3);
      expect(r.ok, isFalse);
      expect(r.message, contains('音源库'));
      expect(tasks.upserted, isEmpty);
    });

    test('CPSV-05 下线：清空该计划命名空间 + 置未启用（保留计划本体）', () async {
      final (svc, tasks, store) = await build();
      await svc.apply(planFor(), planId: 'local', now: DateTime(2026, 3, 10));
      final n = tasks.upserted.length;
      final r = await svc.disable(planId: 'local');
      expect(r.ok, isTrue);
      expect(r.taskCount, n);
      expect(store.enabled, isFalse);
      expect(store.loadPlan(), isNotNull); // 计划本体保留，便于恢复
    });

    test('CPSV-06 refreshIfNeeded：未启用 → 失败，不写入', () async {
      final (svc, tasks, _) = await build();
      final r = await svc.refreshIfNeeded(now: DateTime(2026, 3, 10));
      expect(r.ok, isFalse);
      expect(tasks.upserted, isEmpty);
    });

    test('CPSV-07 refreshIfNeeded：horizon 充足 → 不重算、无写入', () async {
      SharedPreferences.setMockInitialValues({});
      final tasks = _FakeTasks();
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      // 预先排到 2026-03-18（> 3/10 + 3 天）。
      final pre = CounterPlanMaterializer.taskIdPrefix('local');
      tasks.existingIds.addAll(['${pre}20260317D00', '${pre}20260318D00']);
      await store.savePlan(planFor(), id: 'local', enabled: true);
      final svc = CounterPlanService(
        tasks: tasks,
        store: store,
        resolveAudioIds: (ids) async => {'a1'},
        replan: () async {},
      );
      final r = await svc.refreshIfNeeded(now: DateTime(2026, 3, 10));
      expect(r.ok, isTrue);
      expect(r.taskCount, 0);
      expect(tasks.upserted, isEmpty);
    });

    test('CPSV-08 refreshIfNeeded：horizon 不足 → 无删除续排（replace=false）', () async {
      SharedPreferences.setMockInitialValues({});
      final tasks = _FakeTasks();
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      final pre = CounterPlanMaterializer.taskIdPrefix('local');
      tasks.existingIds.add('${pre}20260311D00'); // 只排到 3/11
      await store.savePlan(planFor(), id: 'local', enabled: true);
      final svc = CounterPlanService(
        tasks: tasks,
        store: store,
        resolveAudioIds: (ids) async => {'a1'},
        replan: () async {},
      );
      final r = await svc.refreshIfNeeded(now: DateTime(2026, 3, 10));
      expect(r.ok, isTrue, reason: r.message);
      expect(tasks.upserted, isNotEmpty);
      expect(tasks.deletedPlanIds, isEmpty); // 续算不删除历史
    });

    test('CPSV-09 访问器：planId/currentPlan()/enabled 如实反映 store', () async {
      final (svc, _, store) = await build();
      // 空 store：回落默认 planId、无计划、未启用。
      expect(svc.planId, CounterPlanStore.defaultPlanId);
      expect(svc.currentPlan(), isNull);
      expect(svc.enabled, isFalse);
      await svc.apply(planFor(), planId: 'local', now: DateTime(2026, 3, 10));
      // 落库后三个访问器同步变化。
      expect(svc.planId, 'local');
      expect(svc.currentPlan(), isNotNull);
      expect(svc.currentPlan()!.name, CounterPlan.defaults().name);
      expect(svc.enabled, isTrue);
    });

    test('CPSV-10 refreshIfNeeded：已启用但无计划本体 → fail(尚无反击计划)', () async {
      SharedPreferences.setMockInitialValues({});
      final tasks = _FakeTasks();
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      await store.setEnabled(true); // 启用标志置真，但没有落盘任何计划
      final svc = CounterPlanService(
        tasks: tasks,
        store: store,
        resolveAudioIds: (ids) async => {'a1'},
      );
      final r = await svc.refreshIfNeeded(now: DateTime(2026, 3, 10));
      expect(r.ok, isFalse);
      expect(r.message, contains('尚无反击计划'));
      expect(tasks.upserted, isEmpty);
      expect(tasks.deletedPlanIds, isEmpty);
    });

    test('CPSV-11 默认通路：省略 now 仍可用（有音源 ⇒ 只出播放动作）',
        () async {
      SharedPreferences.setMockInitialValues({});
      final tasks = _FakeTasks();
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      // 2026-10 契约：反击只出随机噪音（TTS 池已废弃）。本用例保留的覆盖点是
      // 「省略 now → 走 now ?? DateTime.now() 默认通路」与「默认 replan 为 noop」。
      final plan = planFor(presets: const ['annoy_cough_fit'], tts: const []);
      final svc = CounterPlanService(
        tasks: tasks,
        store: store,
        resolveAudioIds: (ids) async => const {'a1'},
      );
      final r = await svc.apply(plan);
      expect(r.ok, isTrue, reason: r.message);
      expect(tasks.upserted, isNotEmpty);
      expect(tasks.upserted.every((t) => t.action is PlayAudioAction), isTrue,
          reason: '新契约：只出噪音播放动作，绝无 TtsAction');

      // 续算同样省略 now（覆盖 refreshIfNeeded 内 `now ?? DateTime.now()`）。
      final r2 = await svc.refreshIfNeeded();
      expect(r2, isNotNull);
    });

    test('CPSV-12 disable 返回值语义：planId 归一化 + 精确清除条数', () async {
      SharedPreferences.setMockInitialValues({});
      final tasks = _FakeTasks(existing: const [
        'counter:my_plan_:20260310D00',
        'counter:my_plan_:20260311D00',
        'counter:other:20260310D00',
      ]);
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      await store.savePlan(planFor(), id: 'my plan!', enabled: true);
      final svc = CounterPlanService(
          tasks: tasks, store: store, resolveAudioIds: (ids) async => {'a1'});
      // planId 含非法字符 → safePlanId 归一化为 my_plan_。
      final r = await svc.disable(planId: 'my plan!');
      expect(r.ok, isTrue);
      expect(r.planId, 'my_plan_');
      expect(r.taskCount, 2);
      expect(r.message, contains('2'));
      expect(store.enabled, isFalse);
      expect(store.loadPlan(), isNotNull); // 计划本体保留，便于恢复
      // 只清该前缀，其它计划任务不受影响。
      expect(tasks.existingIds, ['counter:other:20260310D00']);
    });
  });

  group('CPU 顶层解析工具', () {
    test('CPU-01 任务 id 取日：合法 / 畸形', () {
      expect(dayOfCounterTaskId('counter:local:20260310D03'),
          DateTime(2026, 3, 10));
      expect(dayOfCounterTaskId('counter:local:2026-0310D03'), isNull);
      expect(dayOfCounterTaskId('no-colon'), isNull);
      expect(dayOfCounterTaskId('counter:local:20269999D00'), isNull);
      expect(lastPlannedDay([
        'counter:local:20260310D00',
        'counter:local:20260317N00',
        'counter:local:20260311D01',
      ]), DateTime(2026, 3, 17));
      expect(lastPlannedDay(const []), isNull);
    });

    test('CPU-02 点名音效回查：按 tag 命中库内资产 id', () {
      final assets = [
        AudioAsset(
            id: 'uuid-1',
            name: '[预置]连咳',
            path: '/a',
            tags: ['预置', 'annoy', 'annoy_cough_fit'],
            createdAt: DateTime(2026)),
        AudioAsset(
            id: 'uuid-2',
            name: '[预置]咂嘴',
            path: '/b',
            tags: ['预置', 'annoy', 'annoy_tsk'],
            createdAt: DateTime(2026)),
        AudioAsset(
            id: 'uuid-3',
            name: '自己的录音',
            path: '/c',
            tags: ['自定义'],
            createdAt: DateTime(2026)),
      ];
      expect(resolvePresetAudioIds(assets, ['annoy_cough_fit']), {'uuid-1'});
      expect(resolvePresetAudioIds(assets, ['annoy_cough_fit', 'annoy_tsk']),
          {'uuid-1', 'uuid-2'});
      expect(resolvePresetAudioIds(assets, ['not_installed']), isEmpty);
      expect(resolvePresetAudioIds(assets, const []), isEmpty);
    });
  });

  group('COV67 编排剩余分支（有界计划 / 访问器 / 无计划本体）', () {
    CounterPlan bounded() => const CounterPlan(
          presetIds: ['annoy_cough_fit'],
          workdayDay: CounterWindow(
              volumeMin: 0.5, volumeMax: 0.8, durationSecMin: 3, durationSecMax: 8),
          workdayNight: CounterWindow(
              volumeMin: 0.3, volumeMax: 0.5, durationSecMin: 3, durationSecMax: 5),
          scheduleMode: PlanScheduleMode.specificDate,
          specificDate: '2026-03-12',
        );

    test('COV67-01 有界计划 apply 的成功文案含排期标签（102）', () async {
      SharedPreferences.setMockInitialValues({});
      final tasks = _FakeTasks();
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      final svc = CounterPlanService(
          tasks: tasks, store: store, resolveAudioIds: (_) async => {'a1'});
      final r = await svc.apply(bounded(),
          planId: 'local', now: DateTime(2026, 3, 10), days: 7);
      expect(r.ok, isTrue, reason: r.message);
      expect(r.taskCount, greaterThan(0));
      expect(r.message, contains('排期')); // 非循环 ⇒ 走 100–102 的 else 分支
    });

    test('COV67-02 refreshIfNeeded：有界计划不滚动续算（141–142）', () async {
      SharedPreferences.setMockInitialValues({});
      final tasks = _FakeTasks();
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      await store.savePlan(bounded(), id: 'local', enabled: true);
      final svc = CounterPlanService(
          tasks: tasks, store: store, resolveAudioIds: (_) async => {'a1'});
      final r = await svc.refreshIfNeeded(now: DateTime(2026, 3, 10));
      expect(r.ok, isTrue, reason: r.message);
      expect(r.taskCount, 0);
      expect(r.message, contains('有界'));
      expect(tasks.upserted, isEmpty);
    });

    test('COV67-03 autoOverrides / autoOverridesUpdatedAt 直读 store（157/160）', () async {
      SharedPreferences.setMockInitialValues({});
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      final svc = CounterPlanService(tasks: _FakeTasks(), store: store);
      expect(svc.autoOverrides(), isEmpty);
      expect(svc.autoOverridesUpdatedAt(), isNull);
      final at = DateTime(2026, 10, 6, 9);
      await store.setAutoOverrides({'2026-01-04': DayKind.workday}, at: at);
      expect(svc.autoOverrides()['2026-01-04'], DayKind.workday);
      expect(svc.autoOverridesUpdatedAt(), at);
    });

    test('COV67-04 refreshHolidays：已启用但无计划本体 → 仍只写表（不重排）', () async {
      SharedPreferences.setMockInitialValues({});
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      await store.setEnabled(true); // 启用标志置真但没有落盘计划
      final svc = CounterPlanService(tasks: _FakeTasks(), store: store);
      final r = await svc.refreshHolidays({'2026-01-04': DayKind.workday});
      expect(r.ok, isTrue);
      // 修前此处回「尚无反击计划，生成后即按新表排期」—— 该分支已随解耦一并删除：
      // 无论有没有计划本体，本方法都**只写表**，不再分情况去碰反击计划。
      expect(r.message, contains('已更新节假日表'));
      expect(store.autoOverrides()['2026-01-04'], DayKind.workday);
    });
  });
}

/// `TaskRepository` 的替身：只实现反击计划相关的读/删/批写，
/// 其余成员（本项目其它功能用）无需在此实现。
class _FakeTasks implements TaskRepository {
  _FakeTasks({List<String> existing = const []})
      : existingIds = [...existing];

  final List<Task> upserted = [];
  final List<String> deletedPlanIds = [];
  final List<String> existingIds;
  int Function()? replanCount;

  @override
  Future<void> upsertMany(Iterable<Task> items) async {
    upserted.addAll(items);
    existingIds.addAll(items.map((e) => e.id));
  }

  @override
  Future<int> deleteCounterTasks(String planId) async {
    deletedPlanIds.add(planId);
    final p = CounterPlanMaterializer.taskIdPrefix(planId);
    final n = existingIds.where((e) => e.startsWith(p)).length;
    existingIds.removeWhere((e) => e.startsWith(p));
    return n;
  }

  @override
  Future<List<String>> counterTaskIds(String planId) async {
    final p = CounterPlanMaterializer.taskIdPrefix(planId);
    return existingIds.where((e) => e.startsWith(p)).toList();
  }

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

  // BUG-148 新增的仓储方法：本替身只服务反击计划用例，无需真实语义。
  @override
  Future<int> removeAssetRef(String assetId) async => 0;
}