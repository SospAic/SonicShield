import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/features/tasks/task_list_screen.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/power_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 第八十六轮**覆盖率回补**（COV-RATCHET-R85 的收口件）。
///
/// ## 为什么单独一个文件
///
/// 第八十三轮合并把可测面分母从 13726 抬到 13933（+207 行），留下 265 行
/// 未覆盖 ⇒ 可测面跌破 `COVERAGE_MIN=98.6`。补齐时发现缺口**全部是长尾
/// 小分支**（最大单块 6 行），没有"一个大函数没人测"那种便宜可捡。
///
/// 本文件专挑**最省力、最不易 flaky** 的那几块：
/// - `PowerService.standbyBucketLabel` —— 纯静态 switch，6 个分支一次覆盖；
/// - `PowerService.standbyRestricted` —— 只需 mock 一条原生通道；
/// - 任务包（`_TaskPackCard` / `_PackTaskRow`）的**组内单条启停**、`_fmtNext`
///   时间格式、删除取消路径、`nextFireAt` 为 null 时的排序沉底。
///
/// 宿主硬约束与 `task_list_pack_test.dart` 同款：DB 操作包在
/// `tester.runAsync`，用有界 `waitFor` 而非固定 drain，收尾推掉 SnackBar。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const perTest = Timeout(Duration(seconds: 90));

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const nativeChannel = MethodChannel('sonic_shield/native');

  group('CVR · PowerService 待机分桶', () {
    test('CVR-01 standbyBucketLabel：五个已知桶给人话，未知桶给 null', () {
      expect(PowerService.standbyBucketLabel('active'),
          '活跃（不受省电策略限制）');
      expect(PowerService.standbyBucketLabel('working_set'), '常用（限制很轻）');
      expect(PowerService.standbyBucketLabel('frequent'), '较常用（轻度限制）');
      expect(PowerService.standbyBucketLabel('rare'),
          '很少使用（后台任务可能被大幅推迟，建议处理）');
      expect(PowerService.standbyBucketLabel('restricted'),
          '受限（后台任务几乎被冻结，建议立即处理）');

      // 读不到 ≠ 受限：未知桶必须返回 null，让调用方决定不显示（BUG-041 纪律）。
      expect(PowerService.standbyBucketLabel('unknown'), isNull);
      expect(PowerService.standbyBucketLabel(''), isNull);
      expect(PowerService.standbyBucketLabel('working-set'), isNull);
    });

    test('CVR-02 standbyRestricted：只有 rare / restricted 判为受限', () async {
      String bucket = 'rare';
      messenger.setMockMethodCallHandler(
        nativeChannel,
        (MethodCall call) async => call.method == 'standbyBucket' ? bucket : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(nativeChannel, null));

      final svc = PowerService(Battery());

      expect(await svc.standbyRestricted(), isTrue, reason: 'rare 应判受限');

      bucket = 'restricted';
      expect(await svc.standbyRestricted(), isTrue, reason: 'restricted 应判受限');

      bucket = 'active';
      expect(await svc.standbyRestricted(), isFalse, reason: 'active 不应判受限');

      bucket = 'working_set';
      expect(await svc.standbyRestricted(), isFalse);
    });

    test('CVR-03 standbyRestricted：桥读不到（unknown）时判 false，不吓用户', () async {
      // 原生侧返回 null ⇒ NativeBridge 回落 'unknown' ⇒ 不得判为受限。
      messenger.setMockMethodCallHandler(
        nativeChannel,
        (MethodCall call) async => null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(nativeChannel, null));

      expect(await PowerService(Battery()).standbyRestricted(), isFalse);
    });
  });

  group('CVR · 任务包组内交互与时间格式', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(inMemoryDatabasePath);
      BackgroundServiceManager.replanHook = () async {};
    });

    tearDown(() async {
      BackgroundServiceManager.replanHook = null;
      await db.close();
    });

    Future<void> dbWrite(
        WidgetTester tester, Future<void> Function() body) async {
      await tester.runAsync(body);
    }

    Future<void> waitFor(
      WidgetTester tester,
      bool Function() cond, {
      required String reason,
      int maxRounds = 300,
    }) async {
      for (var i = 0; i < maxRounds; i++) {
        if (cond()) return;
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 20));
      }
      fail('等待超时（$maxRounds 轮）：$reason');
    }

    Future<void> waitForText(WidgetTester tester, String substring) => waitFor(
          tester,
          () => find.textContaining(substring).evaluate().isNotEmpty,
          reason: '应出现含「$substring」的文案',
        );

    Future<void> settleSnackBars(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 400));
    }

    Task counterTask(String planId, String key, String name) => Task(
          id: 'counter:$planId:$key',
          name: name,
          enabled: true,
          triggerType: TriggerType.fixedOnce,
          trigger: FixedOnceTrigger(at: DateTime(2026, 10, 20, 10, 15)),
          actionType: ActionType.playAudio,
          action: const PlayAudioAction(
              volumeMin: 0.3,
              volumeMax: 0.5,
              durationSecMin: 3,
              durationSecMax: 5),
          assetIds: const ['a1'],
          cooldownSec: 0,
          quietPolicy: QuietPolicy.skip,
          priority: 0,
          createdAt: DateTime(2026, 10, 15),
          updatedAt: DateTime(2026, 10, 15),
        );

    Future<void> pumpList(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (_, __) => const TaskListScreen(embedded: true),
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('CVR-04 展开任务包后点组内单条开关：只改该条 enabled', (tester) async {
      await dbWrite(tester, () async {
        final repo = TaskRepository(db);
        await repo.upsert(counterTask('p1', '20261020D00', '反击·白天 10:15'));
        await repo.upsert(counterTask('p1', '20261020N00', '反击·夜间 22:15'));
      });

      await pumpList(tester);
      await waitForText(tester, '反击计划 · p1');

      // 展开 ⇒ 包内两行出现，各自带一个 Switch
      await tester.tap(find.text('反击计划 · p1'));
      await tester.pump();
      await waitForText(tester, '反击·白天 10:15');

      // 此时卡内 Switch = 头部 1 + 组内 2
      final card = find.ancestor(
        of: find.text('反击计划 · p1'),
        matching: find.byType(Card),
      );
      final switches = find.descendant(of: card, matching: find.byType(Switch));
      expect(switches, findsNWidgets(3), reason: '头部 1 + 组内 2');

      // 点组内第一条（index 1 = 头部之后的第一个组内行）
      await tester.tap(switches.at(1));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        final repo = TaskRepository(db);
        final all = await repo.listAll();
        final target =
            all.firstWhere((t) => t.name == '反击·白天 10:15');
        expect(target.enabled, isFalse, reason: '点组内开关应停用该条');
        final other =
            all.firstWhere((t) => t.name == '反击·夜间 22:15');
        expect(other.enabled, isTrue, reason: '同包其它条目不受影响');
      });
      await settleSnackBars(tester);
    }, timeout: perTest);

    testWidgets('CVR-05 包头部显示「下次 MM-DD HH:mm」（有 pending 计划时）',
        (tester) async {
      final fireAt = DateTime.now().add(const Duration(days: 2, hours: 3));
      await dbWrite(tester, () async {
        final repo = TaskRepository(db);
        await repo.upsert(counterTask('p1', '20261020D00', '反击·白天 10:15'));
        final occ = OccurrenceRepository(db);
        await occ.commitAll(<PlannedOccurrence>[
          PlannedOccurrence(
            id: 'occ-1',
            taskId: 'counter:p1:20261020D00',
            fireAt: fireAt,
            status: OccurrenceStatus.pending,
          ),
        ]);
      });

      await pumpList(tester);
      await waitForText(tester, '反击计划 · p1');

      // _fmtNext 输出 `MM-DD HH:mm`（两位补零）
      final mm = fireAt.month.toString().padLeft(2, '0');
      final dd = fireAt.day.toString().padLeft(2, '0');
      final hh = fireAt.hour.toString().padLeft(2, '0');
      final mi = fireAt.minute.toString().padLeft(2, '0');
      await waitForText(tester, '下次 $mm-$dd $hh:$mi');
    }, timeout: perTest);

    testWidgets('CVR-06 删除整包时点「取消」：包与任务全部保留', (tester) async {
      await dbWrite(tester, () async {
        final repo = TaskRepository(db);
        await repo.upsert(counterTask('p1', '20261020D00', '反击·白天 10:15'));
        await repo.upsert(counterTask('p1', '20261020N00', '反击·夜间 22:15'));
      });

      await pumpList(tester);
      await waitForText(tester, '反击计划 · p1');

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await waitForText(tester, '删除整包');

      await tester.tap(find.text('删除整包'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await waitForText(tester, '此操作不可撤销');

      // 取消 ⇒ 不删
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await waitFor(
        tester,
        () => find.text('反击计划 · p1').evaluate().isNotEmpty,
        reason: '取消后任务包必须还在',
      );

      await tester.runAsync(() async {
        final all = await TaskRepository(db).listAll();
        expect(all.length, 2, reason: '取消删除不得落库');
      });
    }, timeout: perTest);

    testWidgets('CVR-07 组内排序：无 nextFireAt 的条目沉底（null 不参与比较）',
        (tester) async {
      final fireAt = DateTime.now().add(const Duration(days: 1));
      await dbWrite(tester, () async {
        final repo = TaskRepository(db);
        // 两条同包任务：只给 A 造 pending ⇒ B 的 nextFireAt 为 null
        await repo.upsert(counterTask('p1', 'A', '反击·有计划的'));
        await repo.upsert(counterTask('p1', 'B', '反击·没计划的'));
        await OccurrenceRepository(db).commitAll(<PlannedOccurrence>[
          PlannedOccurrence(
            id: 'occ-a',
            taskId: 'counter:p1:A',
            fireAt: fireAt,
            status: OccurrenceStatus.pending,
          ),
        ]);
      });

      await pumpList(tester);
      await waitForText(tester, '反击计划 · p1');

      await tester.tap(find.text('反击计划 · p1'));
      await tester.pump();
      await waitForText(tester, '反击·有计划的');

      // 有计划的排在前（nextFireAt 升序，null 沉底）
      final aY = tester.getTopLeft(find.text('反击·有计划的')).dy;
      final bY = tester.getTopLeft(find.text('反击·没计划的')).dy;
      expect(aY, lessThan(bY),
          reason: '有 nextFireAt 的应排在 null 之前');
    }, timeout: perTest);
  });
}
