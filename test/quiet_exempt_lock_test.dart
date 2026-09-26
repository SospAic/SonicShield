import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:sonic_shield/remote/task_wire.dart';

import 'support/source_text.dart';

/// 夜间独立豁免锁（v1.9，docs/20 §8）。
///
/// ## 为什么这个文件必须存在
///
/// 夜间豁免是**削弱合规护栏**的功能：docs/08 §4 原本把免打扰标注为
/// "不可绕过"。用户拍板要开这个口子（D4），代价是必须把"口子有多小"
/// 用机器钉死，而不是靠注释和自觉。
///
/// 三条不变量，任何一条被改坏都必须让本文件变红：
/// 1. **双钥匙**：主开关 ∧ 任务级开关，缺一即回到受约束状态。
/// 2. **远程不可开启**：`TaskWire.fromWire` 丢弃入站 `quietExempt`；
///    `lib/remote/` 与远程 UI 不得出现主开关的**写入口**。
/// 3. **撤销即时生效**：关掉主开关后，已落库的豁免计划必须被清除，
///    不能靠"等重算"（`commitAll` 是 ignore 语义，不会覆盖已提交计划）。
///
/// ⚠️ 本文件还额外锁定 **BUG-070**（免打扰窗口设置从未被引擎读取）。
void main() {
  // =====================================================================
  // 1. 双钥匙（Two-Key Safety）
  // =====================================================================
  group('QE 双钥匙', () {
    Task task({
      required QuietPolicy quiet,
      bool quietExempt = false,
      TimeSpec time = const TimeSpec(hour: 23, minute: 0),
    }) {
      final now = DateTime.now();
      return Task(
        id: 't-qe',
        name: '夜间任务',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: DailyTrigger(time: time),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(),
        assetIds: const [],
        cooldownSec: 60,
        quietPolicy: quiet,
        quietExempt: quietExempt,
        priority: 0,
        createdAt: now,
        updatedAt: now,
      );
    }

    // 免打扰默认 22:00–07:00。取 23:00 作为触发点，必落在窗口内。
    final now = DateTime(2026, 9, 12, 12);

    test('QE-01 主开关关 + 任务级开 ⇒ 仍然跳过（缺一把钥匙不生效）', () {
      const engine = ScheduleEngine(); // allowQuietExempt 默认 false
      final list = engine.materialize(
          task(quiet: QuietPolicy.skip, quietExempt: true), now);
      expect(list.where((e) => e.fireAt.hour == 23), isEmpty,
          reason: '只有任务级开关时，免打扰必须照常生效');
    });

    test('QE-02 主开关开 + 任务级关 ⇒ 仍然跳过（缺另一把钥匙不生效）', () {
      const engine = ScheduleEngine(allowQuietExempt: true);
      final list = engine.materialize(
          task(quiet: QuietPolicy.skip, quietExempt: false), now);
      expect(list.where((e) => e.fireAt.hour == 23), isEmpty);
    });

    test('QE-03 双钥匙皆开 ⇒ 放行，且条目标记 quietExempted', () {
      const engine = ScheduleEngine(allowQuietExempt: true);
      final list = engine.materialize(
          task(quiet: QuietPolicy.skip, quietExempt: true), now);
      final at23 = list.where((e) => e.fireAt.hour == 23).toList();
      expect(at23, isNotEmpty, reason: '双钥匙皆开时 23:00 必须被放行');
      expect(at23.first.quietExempted, isTrue,
          reason: '放行必须带标记，否则执行层写不出豁免审计');
      // 未豁免的条目不得被误标（否则"本月豁免次数"会虚高）。
      for (final e in list.where((e) => e.fireAt.hour != 23)) {
        expect(e.quietExempted, isFalse);
      }
    });

    test('QE-04 豁免优先于 QuietPolicy.shift（不平移，按原时刻）', () {
      const engine = ScheduleEngine(allowQuietExempt: true);
      final list = engine.materialize(
          task(quiet: QuietPolicy.shift, quietExempt: true), now);
      final at23 = list.where((e) => e.fireAt.hour == 23).toList();
      expect(at23, isNotEmpty, reason: '豁免时 shift 不应把 23:00 平移到 07:00');
      expect(at23.first.fireAt.hour, 23);
    });

    test('QE-05 窗口外的条目一律不标记豁免（避免虚高计数）', () {
      const engine = ScheduleEngine(allowQuietExempt: true);
      final list = engine.materialize(
          task(
              quiet: QuietPolicy.skip,
              quietExempt: true,
              time: const TimeSpec(hour: 12)),
          now);
      expect(list, isNotEmpty);
      for (final e in list) {
        expect(e.quietExempted, isFalse);
      }
    });
  });

  // =====================================================================
  // 2. 远程不可开启
  // =====================================================================
  group('QE 远程不可开启', () {
    test('QE-10 fromWire 丢弃入站 quietExempt（核心锁）', () {
      final wire = <String, dynamic>{
        'id': 't1',
        'name': '对端任务',
        'enabled': true,
        'triggerType': 'dailyAt',
        'trigger': const DailyTrigger(time: TimeSpec(hour: 8)).toJson(),
        'actionType': 'playAudio',
        'action': const PlayAudioAction().toJson(),
        'assetIds': <String>[],
        'cooldownSec': 300,
        'quietPolicy': 'skip',
        // 对端**试图**打开豁免：
        'quietExempt': true,
      };
      final t = TaskWire.fromWire(wire);
      expect(t, isNotNull, reason: '合法定义不应因多一个字段而被拒');
      expect(t!.quietExempt, isFalse,
          reason: '入站 quietExempt 必须被丢弃 —— 否则已配对的对端可绕过本机合规护栏');
    });

    test('QE-11 toWire 携带 quietExempt（供对端只读展示）', () {
      final now = DateTime.now();
      final t = Task(
        id: 't2',
        name: '本机任务',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 8)),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(),
        assetIds: const [],
        cooldownSec: 300,
        quietPolicy: QuietPolicy.skip,
        quietExempt: true,
        priority: 0,
        createdAt: now,
        updatedAt: now,
      );
      // 与 QE-10 合起来构成**非对称契约**：出站有、入站无视。
      // 若有人"顺手把 fromWire 也接上"，QE-10 会红；
      // 若有人从 toWire 删掉它，本条会红。
      expect(TaskWire.toWire(t)['quietExempt'], isTrue);
    });

    test('QE-12 源码扫描：task_wire 代码中不读取入站 quietExempt', () {
      final code = stripComments(_read('lib/remote/task_wire.dart'));
      expect(code.contains("j['quietExempt']"), isFalse,
          reason: '入站解析不得引用该键 —— 即使"读出来再强制置 false"也不允许，'
              '因为下一个改动者很容易把那个 false 改成变量');
      expect(code.contains('quietExempt: false'), isTrue,
          reason: '必须是**显式** false，而不是省略参数（省略时靠默认值，'
              '读者看不出这是有意的安全决策）');
    });

    test('QE-13 源码扫描：远程侧不得出现主开关的**写入口**', () {
      for (final f in _dartFiles('lib/remote')) {
        final code = stripComments(_read(f));
        // 读是允许的（`_rematerialize` 必须知道本地是否已授权，
        // 否则远程改一次任务就会把已豁免的计划静默清掉）；**写**绝不允许。
        expect(code.contains('setBool(PrefsKeys.quietExemptMaster'),
            isFalse,
            reason: '$f 出现主开关写入口 —— 远程不得开启夜间豁免（docs/20 §8.2）');
      }
      for (final f in _dartFiles('lib/features/remote')) {
        final code = stripComments(_read(f));
        expect(code.contains('setBool(PrefsKeys.quietExemptMaster'),
            isFalse,
            reason: '$f 是**控制端**界面；在控制端放主开关等于给对端开护栏后门');
      }
    });

    test('QE-14 源码扫描：主开关写入口只允许出现在设置页', () {
      final writers = <String>[];
      for (final f in _dartFiles('lib')) {
        final code = stripComments(_read(f));
        if (code.contains('setBool(PrefsKeys.quietExemptMaster')) {
          writers.add(p.basename(f));
        }
      }
      expect(writers, ['settings_screen.dart'],
          reason: '主开关只能由用户在本机设置页开启；出现新的写入方必须显式评审');
    });

    test('QE-15 源码扫描：任务备份导出/导入不携带 quietExempt', () {
      final code =
          stripComments(_read('lib/features/settings/settings_screen.dart'));
      // ⚠️ 只扫**导出/导入两个函数体**，不能扫整份文件 ——
      // 设置页本来就含主开关（`_quietExemptMaster`），扫全文必然误报。
      // 先确认标记存在，否则 indexOf 返回 -1 会让切片变成空串而"静默通过"。
      final a = code.indexOf('Future<void> _exportTasks');
      final b = code.indexOf('Future<String?> _askPassword');
      final c = code.indexOf('Future<void> _importTasks');
      final d = code.indexOf('void initState');
      expect([a, b, c, d].every((i) => i >= 0), isTrue,
          reason: '函数标记未找到 —— 锁的实现需要跟着重构一起更新，'
              '否则它会退化成恒真断言');
      final backup = code.substring(a, b) + code.substring(c, d);
      // ⚠️ 判据必须是**豁免专属**的字符串，不能写成 `contains('quiet')` ——
      // 备份本来就带 `quiet_policy` / `quietPolicy`（免打扰策略属于任务定义，
      // 应当随备份走）；写成 'quiet' 会把它们一起判红。
      expect(backup.contains('quiet_exempt'), isFalse,
          reason: '授权不随数据走：备份文件里出现该字段，'
              '意味着"导入一份他人任务"就可能带上夜间豁免意图');
      expect(backup.contains('quietExempt'), isFalse,
          reason: '同上（Dart 侧字段名也不得出现在备份读写里）');
    });
  });

  // =====================================================================
  // 3. 持久化与撤销即时生效
  // =====================================================================
  group('QE 持久化', () {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    late AppDatabase appDb;

    setUp(() async {
      appDb = await AppDatabase.open(inMemoryDatabasePath);
      // occurrences.task_id 有外键约束（REFERENCES tasks(id)），
      // 因此必须先落一条任务，否则插入计划会报 FOREIGN KEY constraint failed。
      final now = DateTime.now();
      await TaskRepository(appDb).upsert(Task(
        id: 't',
        name: '宿主任务',
        enabled: true,
        triggerType: TriggerType.dailyAt,
        trigger: const DailyTrigger(time: TimeSpec(hour: 8)),
        actionType: ActionType.playAudio,
        action: const PlayAudioAction(),
        assetIds: const [],
        cooldownSec: 60,
        quietPolicy: QuietPolicy.skip,
        priority: 0,
        createdAt: now,
        updatedAt: now,
      ));
    });

    tearDown(() async {
      await appDb.close();
    });

    test('QE-20 主开关默认 false（缺失 → 未授权，不是"已授权"）', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await SharedPreferences.getInstance();
      expect(p.getBool(PrefsKeys.quietExemptMaster) ?? false, isFalse,
          reason: '默认必须是"未授权"，否则升级即等于静默放宽护栏');
      await p.setBool(PrefsKeys.quietExemptMaster, true);
      expect(p.getBool(PrefsKeys.quietExemptMaster), isTrue);
      await p.setBool(PrefsKeys.quietExemptMaster, false);
      expect(p.getBool(PrefsKeys.quietExemptMaster), isFalse);
    });

    test('QE-21 缺列/空值读作 false（降级到更安全的一侧）', () {
      final o = PlannedOccurrence.fromRow({
        'id': 'x',
        'task_id': 't',
        'fire_at': 0,
        'status': 'pending',
        // 故意不给 quiet_exempt
      });
      expect(o.quietExempt, isFalse);
    });

    test('QE-22 豁免标记随计划落库并读回', () async {
      final occ = OccurrenceRepository(appDb);
      final now = DateTime.now();
      await occ.commitAll([
        PlannedOccurrence(
            id: 'a',
            taskId: 't',
            fireAt: now.add(const Duration(hours: 1)),
            status: OccurrenceStatus.pending,
            quietExempt: true),
        PlannedOccurrence(
            id: 'b',
            taskId: 't',
            fireAt: now.add(const Duration(hours: 2)),
            status: OccurrenceStatus.pending),
      ]);
      final rows = await occ.pendingWithin(now, now.add(const Duration(days: 1)));
      expect(rows.length, 2);
      expect(rows.firstWhere((r) => r.id == 'a').quietExempt, isTrue);
      expect(rows.firstWhere((r) => r.id == 'b').quietExempt, isFalse);
    });

    test('QE-23 deletePendingQuietExempt 只清"待执行且带豁免标记"的计划', () async {
      final occ = OccurrenceRepository(appDb);
      final now = DateTime.now();
      final future = now.add(const Duration(hours: 3));
      await occ.commitAll([
        // 应被清除
        PlannedOccurrence(
            id: 'exempt-pending',
            taskId: 't',
            fireAt: future,
            status: OccurrenceStatus.pending,
            quietExempt: true),
        // 不该被清除：普通待执行计划
        PlannedOccurrence(
            id: 'normal-pending',
            taskId: 't',
            fireAt: future,
            status: OccurrenceStatus.pending),
        // 不该被清除：已执行的豁免计划（是审计历史，不是待办）
        PlannedOccurrence(
            id: 'exempt-done',
            taskId: 't',
            fireAt: now.subtract(const Duration(hours: 1)),
            status: OccurrenceStatus.done,
            quietExempt: true),
      ]);
      final purged = await occ.deletePendingQuietExempt();
      expect(purged, 1, reason: '只应清掉那一条 pending 的豁免计划');
      final left = await occ.pendingWithin(now, now.add(const Duration(days: 1)));
      expect(left.map((e) => e.id), ['normal-pending']);
    });

    test('QE-25 countQuietExemptSince 只数豁免审计、只数本月', () async {
      final logs = LogRepository(appDb);
      final now = DateTime.now();
      await logs.appendMany([
        // 本月、豁免 → 计入
        (
          source: 'schedule',
          action: 'quietExempt',
          status: 'success',
          taskId: 't',
          occurrenceId: null,
          volume: null,
          durationMs: null,
          message: '用户豁免免打扰（任务级）',
        ),
        // 其它动作 → 不计
        (
          source: 'schedule',
          action: 'condition',
          status: 'skipped',
          taskId: 't',
          occurrenceId: null,
          volume: null,
          durationMs: null,
          message: null,
        ),
      ]);
      expect(await logs.countQuietExemptSince(DateTime(now.year, now.month)), 1);
      // 下个月起点之后 → 0（证明是按时间过滤，不是全表计数）
      final nextMonth =
          DateTime(now.year, now.month + 1);
      expect(await logs.countQuietExemptSince(nextMonth), 0);
    });

    test('QE-24 撤销主开关后，库中不再存在待执行的豁免计划（端到端不变量）',
        () async {
      final occ = OccurrenceRepository(appDb);
      final now = DateTime.now();
      await occ.commitAll([
        PlannedOccurrence(
            id: 'x',
            taskId: 't',
            fireAt: now.add(const Duration(hours: 1)),
            status: OccurrenceStatus.pending,
            quietExempt: true),
      ]);
      // 模拟"用户关掉主开关 → replan 发现未授权 → 清除"
      await occ.deletePendingQuietExempt();
      final r = await appDb.db.rawQuery(
          "SELECT COUNT(*) AS c FROM occurrences WHERE quiet_exempt = 1 AND status = 'pending'");
      expect(r.first['c'], 0,
          reason: '主开关关闭后不得留下任何待执行的豁免计划（否则护栏名义恢复、实际仍被绕过）');
    });
  });

  // =====================================================================
  // 4. BUG-070：免打扰窗口必须真的被使用
  // =====================================================================
  group('QE 免打扰窗口（BUG-070）', () {
    test('QE-30 normalizeQuietWindow 透传合法值', () {
      final r = normalizeQuietWindow(23, 6);
      expect(r.start, 23);
      expect(r.end, 6);
    });

    test('QE-31 越界/缺失 → 回落合规默认（不是夹到边界）', () {
      for (final v in [null, -1, 24, 99]) {
        final r = normalizeQuietWindow(v, null);
        expect(r.start, ComplianceGuardrails.defaultQuietStartHour,
            reason: '损坏配置必须回到默认护栏，而不是"猜一个边界值"');
        expect(r.end, ComplianceGuardrails.defaultQuietEndHour);
      }
    });

    test('QE-32 start == end ⇒ 回落默认（不允许把护栏整体关掉）', () {
      // start==end 会让引擎判成零长度窗口 → 免打扰完全失效。
      final r = normalizeQuietWindow(22, 22);
      expect(r.start, ComplianceGuardrails.defaultQuietStartHour);
      expect(r.end, ComplianceGuardrails.defaultQuietEndHour);
      expect(r.start, isNot(r.end));
    });

    test('QE-33 引擎确实使用传入的窗口（而非硬编码常量）', () {
      final now = DateTime(2026, 9, 12, 12);
      Task t(int hour) {
        final n = DateTime.now();
        return Task(
          id: 'w$hour',
          name: '窗口任务',
          enabled: true,
          triggerType: TriggerType.dailyAt,
          trigger: DailyTrigger(time: TimeSpec(hour: hour)),
          actionType: ActionType.playAudio,
          action: const PlayAudioAction(),
          assetIds: const [],
          cooldownSec: 60,
          quietPolicy: QuietPolicy.skip,
          priority: 0,
          createdAt: n,
          updatedAt: n,
        );
      }

      // 窗口 22–07 时，01:00 属于免打扰 → 被跳过。
      const defaultWindow = ScheduleEngine();
      expect(defaultWindow.materialize(t(1), now).where((e) => e.fireAt.hour == 1),
          isEmpty);
      // 窗口收窄成 23–06 时，01:00 仍在窗口内 → 仍被跳过；
      // 但 **02:00 在 23–06 内**、**在 22–07 内也**在窗口内，不能用来区分。
      // 用 06:00 区分：22–07 窗口内（跳过），23–06 窗口外（放行）。
      const narrow = ScheduleEngine(quietStartHour: 23, quietEndHour: 6);
      expect(narrow.materialize(t(6), now).where((e) => e.fireAt.hour == 6),
          isNotEmpty,
          reason: '收窄后的窗口边界 06:00 必须被放行 —— 证明引擎用的是传入值');
      expect(defaultWindow.materialize(t(6), now).where((e) => e.fireAt.hour == 6),
          isEmpty,
          reason: '默认 22–07 窗口下 06:00 必须被跳过 —— 与上一行构成对照');
    });
  });
}

// =====================================================================
// 工具
// =====================================================================

String _read(String rel) => File(p.join(_root(), rel)).readAsStringSync();

/// 仓库根目录：从当前测试文件的路径往上找 `pubspec.yaml`。
///
/// 不写死盘符 —— CI/他人机器上路径不同（BUG-065 的同族教训：
/// 凡是"环境相关"的东西都不能靠硬编码）。
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

List<String> _dartFiles(String relDir) {
  final d = Directory(p.join(_root(), relDir));
  if (!d.existsSync()) return const [];
  return d
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path)
      .where((f) => f.endsWith('.dart'))
      .toList();
}

/// 去掉注释后的源码。
///
/// 源码扫描锁必须**排除注释**：本仓库的注释里大量引用被禁止的写法
/// （例如 `task_wire.dart` 的注记里就写着"绝不读 `j['quietExempt']`"）。
/// 不剥注释的扫描会把"解释为什么不能这么做"误判成"正在这么做"。
///
/// 实现见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源）。
/// ⚠️ 此前本文件用的是**行级粗糙版**（`split('//').first` 家族）——
/// 它会把 `'mqtt://...'` 这类字符串字面量从 `//` 起截断；收敛后整段保留。
