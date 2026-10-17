import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/source_text.dart';

/// 「**设置变更后的状态刷新**」全量审计的机器锁（2026-10-17，BUG-082 / BUG-083）。
///
/// ## 为什么这个文件必须存在
///
/// 用户实测报告：「豁免状态下创建任务后……已经豁免的任务不会再执行」，
/// 并明确要求"程序中所有设置变更后的状态刷新请**全量检查**"。
/// 全量审计查出两条**同族**的系统性缺陷 —— 都不是某一处漏写，而是
/// **一条链路整体断掉**，所以必须用机器钉死，而不是补一处了事：
///
/// ### BUG-082：引擎隔离的 `SharedPreferences` 缓存**永不刷新**
/// 引擎跑在 `flutter_background_service` 的**独立 `FlutterEngine` isolate** 里
/// （`BackgroundService.java:211,228`），而 `SharedPreferences` 的 Dart 侧是
/// **按 isolate 缓存**的（`shared_preferences_legacy.dart:28` 的静态
/// `_completer` + `:107` 的 `_preferenceCache`），且 Android legacy 通道
/// **没有**变更回推（`LegacySharedPreferencesPlugin.kt` 未注册
/// `OnSharedPreferenceChangeListener`）。
/// ⇒ 引擎启动后，UI isolate 改的任何设置（免打扰窗口 / 夜间豁免主开关 /
/// 全局执行总开关 / 闹钟通道 / 反击计划本体）在引擎里**全是旧值**，
/// 直到引擎重启为止。本锁钉两件事：
/// 1. **机制**（TSR-01）：`SharedPreferences` 实例确实"看不到外部写入"，
///    只有 `reload()` 之后才看得到 —— 证明修复方向成立、不是想当然；
/// 2. **接线**（TSR-02）：`background_engine` 的四个"读设置入口"
///    （`replan` / `executeDue` / `extendCounterPlan` / `admitExecution`）
///    都必须先 `await syncPrefs()`，且 `syncPrefs` 必须真的 `reload()`。
///
/// ### BUG-083：三份"派生自任务表"的 UI 缓存只失效其中一份
/// `taskListProvider` / `forceRunTasksProvider`（守护页例外清单）/
/// `quietExemptOverrideTasksProvider`（设置页例外清单）都从 `tasks` 表派生，
/// 但**彼此没有依赖关系**；后两者**刻意不是 `autoDispose`**，
/// 且所在页面在 `IndexedStack` 下常驻 ⇒ 只失效列表时，
/// 两份清单会**永远**停在旧内容（实测：`forceRunTasksProvider` 全仓
/// 此前**从未**被失效过）。本锁钉：
/// 3. **集中入口存在且完整**（TSR-10）：`invalidateTaskDerivedCaches`
///    必须同时失效三个 provider；
/// 4. **不得再裸失效列表**（TSR-11）：任务列表页不允许出现
///    `ref.invalidate(taskListProvider)`（必须走集中入口）；
/// 5. **行为**（TSR-12）：库变了但不失效 ⇒ 清单确实是旧快照；
///    走集中入口 ⇒ 两份清单同时刷新。
void main() {
  // =====================================================================
  // TSR-1 引擎隔离的设置同步（BUG-082）
  // =====================================================================
  group('TSR 引擎隔离设置同步（BUG-082）', () {
    test('TSR-01 机制：SharedPreferences 实例看不到"外部写入"，只有 reload 才看得到', () async {
      // 模拟"UI isolate 已经把值写进平台存储，而引擎 isolate 的实例是更早
      // 构造的"。宿主上只有一个 isolate，因此用**平台层桩**制造同样的现象：
      // Dart 侧缓存（`_preferenceCache`）与平台层数据**分离**。
      SharedPreferences.setMockInitialValues(
          <String, Object>{PrefsKeys.quietExemptMaster: false});
      // `setMockInitialValues` 已按平台约定补好键前缀，这里据此构造一个
      // **可外部改写**的平台层桩（不依赖硬编码前缀，避免前缀变更即失效）。
      final seeded = await SharedPreferencesStorePlatform.instance.getAll();
      final store = _MutableStore(seeded);
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefsKeys.quietExemptMaster), isFalse,
          reason: '初始值必须是"未授权"，否则下面的对照不成立');

      // ---- 外部写入（等价于 UI isolate 改设置）----
      final key =
          seeded.keys.firstWhere((k) => k.endsWith(PrefsKeys.quietExemptMaster));
      store.data[key] = true;

      expect(prefs.getBool(PrefsKeys.quietExemptMaster), isFalse,
          reason: 'Dart 侧仍是旧快照 —— 这正是 BUG-082 的机制：'
              '引擎 isolate 在启动时把 KV 读进内存后，再也看不到 UI 的写入');

      await prefs.reload();

      expect(prefs.getBool(PrefsKeys.quietExemptMaster), isTrue,
          reason: 'reload 之后必须看到外部写入 —— 这是 syncPrefs() 的依据；'
              '若本行判红，说明"跨 isolate 缓存"的修复方向不成立');
    });

    test('TSR-02 接线：四个读设置入口都必须先 syncPrefs()，且 syncPrefs 真的 reload', () {
      final src = stripComments(_read('lib/services/background_engine.dart'));

      // (1) syncPrefs 本体必须真的把平台层数据拉回来。
      final sync = methodBody(src, 'Future<void> syncPrefs() async {');
      expect(sync.contains('await prefs.reload();'), isTrue,
          reason: 'syncPrefs 必须调用 prefs.reload()；否则它只是个空壳，'
              'BUG-082 原样复发');

      // (2) 四个入口：任何一处漏接，对应的设置就"改了不生效"。
      //     - replan            → 免打扰窗口 / 夜间豁免主开关 / 闹钟通道
      //     - executeDue        → 全局执行总开关（执行期暂停判据）
      //     - extendCounterPlan → 反击计划本体 / 启用位 / 节假日覆盖表
      //     - admitExecution    → 声音触发 + 远程立即执行 两条通路的总开关判据
      const entries = <String, String>{
        'Future<void> replan() async {': '免打扰窗口 / 夜间豁免主开关 / 闹钟通道',
        'Future<void> executeDue() async {': '全局执行总开关（定时通路）',
        'Future<void> extendCounterPlan() async {': '反击计划本体 / 节假日覆盖表',
        'Future<String?> admitExecution(': '全局执行总开关（声音 / 远程通路）',
      };
      for (final e in entries.entries) {
        final body = methodBody(src, e.key);
        expect(body.contains('await syncPrefs();'), isTrue,
            reason: '${e.key} 未调用 syncPrefs() ⇒ ${e.value} 在引擎运行期间'
                '改不动（BUG-082：界面回显变了、落库也变了，行为一点没变）');
      }
    });
  });

  // =====================================================================
  // TSR-2 派生缓存的集中失效（BUG-083）
  // =====================================================================
  group('TSR 派生缓存集中失效（BUG-083）', () {
    // ⚠️ 开库/关库**必须在 `setUp`/`tearDown`**，不能放进 `testWidgets` 体内：
    // 体内跑在 FakeAsync 里，而 sqflite ffi 的往返是真异步 ⇒ 直接 await 会挂死
    // （实测：整例 10 分钟超时，0 断言失败）。与 `task_list_pack_test.dart`
    // 文件头记的宿主硬约束同源。
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    late AppDatabase db;
    setUp(() async {
      db = await AppDatabase.open(inMemoryDatabasePath);
    });
    tearDown(() async {
      await db.close();
    });

    test('TSR-10 集中入口必须同时失效三份派生缓存', () {
      final src = stripComments(_read('lib/core/providers.dart'));
      final body = methodBody(src, 'void invalidateTaskDerivedCaches(WidgetRef ref) {');
      for (final name in const [
        'taskListProvider',
        'forceRunTasksProvider',
        'quietExemptOverrideTasksProvider',
      ]) {
        expect(body.contains('ref.invalidate($name);'), isTrue,
            reason: '集中入口漏了 $name ⇒ 那一份缓存会一直停在旧内容'
                '（BUG-083 的原始形态：只失效列表，两份清单永不更新）');
      }
    });

    test('TSR-11 任务列表页不得再"裸失效"列表（必须走集中入口）', () {
      final src = stripComments(_read('lib/features/tasks/task_list_screen.dart'));
      expect(src.contains('ref.invalidate(taskListProvider)'), isFalse,
          reason: '出现裸失效 ⇒ 同一处大概率漏掉了两份例外清单；'
              '请改用 invalidateTaskDerivedCaches(ref)');
      expect(src.contains('invalidateTaskDerivedCaches(ref)'), isTrue,
          reason: '任务列表页是任务表改动的主要入口，必须真的接上集中入口');
    });

    testWidgets('TSR-12 行为：库变了不失效 ⇒ 旧快照；走集中入口 ⇒ 两份清单同时刷新', (tester) async {
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWith((_) async => db),
      ]);
      addTearDown(container.dispose);

      WidgetRef? ref;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(builder: (_, r, __) {
            ref = r;
            return const SizedBox();
          }),
        ),
      ));
      expect(ref, isNotNull, reason: '没能拿到 WidgetRef ⇒ 本用例会退化成恒真');

      final repo = TaskRepository(db);
      await tester.runAsync(() => repo.upsert(_mk('A', forceRun: true)));

      final forced0 = await tester.runAsync(
          () => container.read(forceRunTasksProvider.future));
      expect(forced0!.map((t) => t.id).toList(), ['A']);
      // ⚠️ 必须**先读一次**把 `quietExemptOverrideTasksProvider` 的缓存建起来，
      // 否则它在下面才首次创建、天然拿到新数据，"未失效即旧快照"的对照不成立
      // （实测：漏掉这一行会让断言在"缓存从未建立"的情况下判红）。
      final exempt0 = await tester.runAsync(
          () => container.read(quietExemptOverrideTasksProvider.future));
      expect(exempt0!.map((t) => t.id).toList(), isEmpty);

      // ---- 任务表被改动（新增强制例外 + 任务级强制豁免）----
      await tester.runAsync(() async {
        await repo.upsert(_mk('B', forceRun: true));
        await repo.upsert(_mk('C', quietExempt: true));
      });

      // 不失效 ⇒ 两份清单都还是旧快照（这正是"页面常驻 + 非 autoDispose"
      // 造成的用户可见现象）。
      final forcedStale = await tester.runAsync(
          () => container.read(forceRunTasksProvider.future));
      final exemptStale = await tester.runAsync(
          () => container.read(quietExemptOverrideTasksProvider.future));
      expect(forcedStale!.map((t) => t.id).toList(), ['A'],
          reason: '未失效就该是旧快照 —— 若这里已经刷新，说明本用例'
              '测不到"缓存陈旧"，断言失去意义');
      expect(exemptStale!.map((t) => t.id).toList(), isEmpty);

      // ---- 走生产用的集中失效入口 ----
      invalidateTaskDerivedCaches(ref!);
      await tester.pump();

      final forcedFresh = await tester.runAsync(
          () => container.read(forceRunTasksProvider.future));
      final exemptFresh = await tester.runAsync(
          () => container.read(quietExemptOverrideTasksProvider.future));
      expect(forcedFresh!.map((t) => t.id).toList(), ['A', 'B'],
          reason: '集中入口必须刷新守护页「例外清单」');
      expect(exemptFresh!.map((t) => t.id).toList(), ['C'],
          reason: '集中入口必须刷新设置页「例外清单」');
    });
  });
}

// =====================================================================
// 工具
// =====================================================================

/// 可被测试**外部改写**的平台层桩：模拟"另一个 isolate 写入平台存储"。
///
/// 刻意不复用 `InMemorySharedPreferencesStore` —— 它的 `_data` 是私有字段，
/// 外部无法在不经过 `setValue` 的情况下改写，也就模拟不出
/// "UI isolate 直接落平台层、引擎 isolate 的 Dart 缓存纹丝不动"这一现场。
class _MutableStore extends SharedPreferencesStorePlatform {
  _MutableStore(this.data);

  final Map<String, Object> data;

  @override
  Future<bool> clear() async {
    data.clear();
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async => Map<String, Object>.from(data);

  @override
  Future<bool> remove(String key) async {
    data.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    data[key] = value;
    return true;
  }
}

Task _mk(String id, {bool forceRun = false, bool? quietExempt}) {
  final base = DateTime(2024, 1, 1);
  return Task(
    id: id,
    name: id,
    enabled: true,
    triggerType: TriggerType.dailyAt,
    trigger: const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)),
    actionType: ActionType.notify,
    action: const NotifyAction(title: 'T', body: 'B'),
    assetIds: const [],
    cooldownSec: 60,
    quietPolicy: QuietPolicy.skip,
    priority: 0,
    createdAt: base,
    updatedAt: base,
    forceRun: forceRun,
    quietExempt: quietExempt,
  );
}

String _read(String rel) => File(p.join(_root(), rel)).readAsStringSync();

/// 仓库根目录：从当前测试文件的路径往上找 `pubspec.yaml`（不写死盘符）。
String _root() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) return dir.path;
    final up = dir.parent;
    if (up.path == dir.path) break;
    dir = up;
  }
  return Directory.current.path;
}
