import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
// `databaseFactory` 的 setter 只接受 `SqfliteDatabaseFactory`（公开 API 不导出
// 该类型），要注入"开库失败"只能在测试侧实现它。
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:sqflite_common/src/factory.dart' show SqfliteDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/counter_plan_store.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/remote/inbound_seen_store.dart';
import 'package:sonic_shield/remote/peer_key_store.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// R96 覆盖率补齐：**可达但未被测到**的 14 行数据层边角（GAP-01…GAP-11）。
///
/// 覆盖点：
/// - `AppDatabase`：开库锁冲突的退避重试（L89）、schema 补建后写审计失败
///   被吞（L452）、schema 校验自身异常只记日志不阻断（L456）；
/// - `OccurrenceRepository`：`markStatus` 的审计留痕（L239/244/245）与
///   "审计写失败不得回滚状态"（L247）、`deletePendingForTask` 的
///   `fireAtAfter` 过滤（L406/407）；
/// - `CounterPlanStore.savePlan` 的 enabled 三级回落（L133）；
/// - `PeerKeyStore` 坏 JSON 兜底（L52）与 remove 后回写（L86）；
/// - `InboundSeenStore.snapshot`（L57）；
/// - `RemoteStore.revokedIds` 坏 JSON 兜底（L538）。
///
/// 纪律：全部走 FFI 内存库 / 临时文件库 + 内存 prefs 替身，不依赖墙钟、
/// 随机、网络或真实设备；每条判据都配反面样本。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 固定时间构造一条合法任务（避免墙钟依赖）。
  Task makeTask(String id) {
    final now = DateTime(2026, 10, 25, 12);
    return Task(
      id: id,
      name: '任务$id',
      enabled: true,
      triggerType: TriggerType.dailyAt,
      trigger: const DailyTrigger(time: TimeSpec(hour: 10, minute: 0)),
      actionType: ActionType.playAudio,
      action: const PlayAudioAction(volumeMin: 0.3, volumeMax: 0.7),
      assetIds: const ['a1'],
      cooldownSec: 300,
      quietPolicy: QuietPolicy.shift,
      priority: 2,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 每个用例一个独立临时目录（真文件库才会走 open → onConfigure 全链）。
  Directory newTmpDir() {
    final d = Directory.systemTemp.createTempSync('sonicshield_r96gap_');
    addTearDown(() async {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
      } on Object {
        // Windows 句柄未释放时不要把清理失败伪装成用例失败。
      }
    });
    return d;
  }

  Future<AppDatabase> openMemDb() async {
    final db = await AppDatabase.open(inMemoryDatabasePath);
    addTearDown(db.close);
    return db;
  }

  /// 内存库 + 一条父任务（`occurrences.task_id` 有外键，必须先造父行）。
  Future<({AppDatabase db, TaskRepository tasks, OccurrenceRepository occ})>
      seedDb() async {
    final db = await openMemDb();
    final tasks = TaskRepository(db);
    await tasks.upsert(makeTask('t1'));
    return (db: db, tasks: tasks, occ: OccurrenceRepository(db));
  }

  // ══════════════════════════════════════════════════════════════
  // AppDatabase：开库重试 / schema 校验兜底
  // ══════════════════════════════════════════════════════════════
  group('R96-GAP AppDatabase 开库边角', () {
    test('GAP-01 首次开库抛锁冲突：退避后重试成功，不把错误抛给调用方', () async {
      final real = databaseFactory;
      final flaky = _FlakyLockFactory(real);
      databaseFactory = flaky;
      addTearDown(() => databaseFactory = real);

      final db = await AppDatabase.open(inMemoryDatabasePath);
      addTearDown(db.close);

      expect(flaky.calls, 2,
          reason: '第一次必须因 database is locked 被重试，第二次才真正开库');
      // 反面：重试后拿到的是**可用**的库，而不是"能返回但打不开"的空壳。
      await db.kvSet('gap', '1');
      expect(await db.kvGet('gap'), '1');
    });

    test('GAP-02 补建 schema 后写 exec_logs 失败：审计异常被吞，开库不失败', () async {
      final dir = newTmpDir();
      final path = p.join(dir.path, 'sonic_shield.db');
      // 造"版本号已是 6、但一张表都没有"的库 ⇒ 必进补建分支。
      final empty = await openDatabase(
        path,
        version: AppDatabase.dbVersion,
        singleInstance: false,
        onCreate: (db, v) async {},
      );
      await empty.close();

      final real = databaseFactory;
      databaseFactory = _HookFactory(
        real,
        (inner) => _HookDatabase(inner, failInsertTable: 'exec_logs'),
      );
      addTearDown(() => databaseFactory = real);

      final db = await AppDatabase.open(dir.path);
      addTearDown(db.close);

      // 反面：补建本身是成功的（表确实建出来了），失败只发生在审计写入那一步。
      final tables = await db.db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='exec_logs'");
      expect(tables, isNotEmpty, reason: '补建分支必须先真的把表建出来');
      await db.kvSet('k', 'v');
      expect(await db.kvGet('k'), 'v', reason: '审计写失败不得让整库不可用');
    });

    test('GAP-03 schema 校验自身抛异常：只记日志，不阻断开库', () async {
      final real = databaseFactory;
      databaseFactory = _HookFactory(
        real,
        (inner) => _HookDatabase(inner, failRawQueryPrefix: 'PRAGMA table_info'),
      );
      addTearDown(() => databaseFactory = real);

      // 不抛即通过：若 L456 的 `on Object` 兜底缺失，异常会穿透 open 的重试
      // 循环（非锁错误立即重抛），这里就会红。
      final db = await AppDatabase.open(inMemoryDatabasePath);
      addTearDown(db.close);
      expect(db, isNotNull);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // OccurrenceRepository：审计留痕 / fireAtAfter 过滤
  // ══════════════════════════════════════════════════════════════
  group('R96-GAP OccurrenceRepository 审计与清理', () {
    test('GAP-04 markStatus 带 note：写一条 exec_logs 审计（含 affected 文案）',
        () async {
      final s = await seedDb();
      await s.occ.commitAll([
        PlannedOccurrence(
          id: 'o-1',
          taskId: 't1',
          fireAt: DateTime(2026, 10, 25, 13),
          status: OccurrenceStatus.pending,
        ),
      ]);

      final n = await s.occ.markStatus(
        'o-1',
        OccurrenceStatus.done,
        from: {OccurrenceStatus.pending},
        note: 'CAS 命中',
      );
      expect(n, 1);

      final logs = await s.db.db
          .query('exec_logs', where: 'action = ?', whereArgs: ['markStatus']);
      expect(logs, hasLength(1), reason: 'note 非 null 时必须留一条审计');
      final row = logs.single;
      expect(row['occurrence_id'], 'o-1');
      expect(row['source'], 'db');
      expect(row['status'], 'info');
      expect(row['message'], 'done affected=1：CAS 命中');
      expect(row['created_at'], isA<int>(),
          reason: 'created_at 必须是毫秒时间戳（NOT NULL 列）');

      // 反面：note 为 null 时不产生任何审计写入（热路径零额外写入）。
      await s.occ.markStatus('o-1', OccurrenceStatus.done);
      expect(
        await s.db.db.query('exec_logs', where: 'action = ?', whereArgs: ['markStatus']),
        hasLength(1),
        reason: 'note 为 null 时不得写审计',
      );
    });

    test('GAP-05 exec_logs 不可用：审计写失败被吞，CAS 结果照常返回', () async {
      final s = await seedDb();
      await s.occ.commitAll([
        PlannedOccurrence(
          id: 'o-2',
          taskId: 't1',
          fireAt: DateTime(2026, 10, 25, 13),
          status: OccurrenceStatus.pending,
        ),
      ]);
      await s.db.db.execute('DROP TABLE exec_logs');

      final n = await s.occ.markStatus(
        'o-2',
        OccurrenceStatus.failed,
        from: {OccurrenceStatus.pending},
        note: '审计不可用',
      );
      expect(n, 1, reason: '审计写失败不得让状态机回滚或抛异常');
      final rows = await s.db.db
          .query('occurrences', where: 'id = ?', whereArgs: ['o-2']);
      expect(rows.single['status'], 'failed', reason: '状态必须真的落库');
    });

    test('GAP-06 deletePendingForTask 带 fireAtAfter：只删该时刻之后的 pending',
        () async {
      final s = await seedDb();
      final now = DateTime(2026, 10, 25, 12);
      await s.occ.commitAll([
        PlannedOccurrence(
          id: 'past',
          taskId: 't1',
          fireAt: now.subtract(const Duration(hours: 1)),
          status: OccurrenceStatus.pending,
        ),
        PlannedOccurrence(
          id: 'future',
          taskId: 't1',
          fireAt: now.add(const Duration(hours: 1)),
          status: OccurrenceStatus.pending,
        ),
      ]);

      final n = await s.occ.deletePendingForTask('t1', fireAtAfter: now);
      expect(n, 1, reason: '只有 fire_at > now 的那一条被删');
      final left = await s.db.db.query('occurrences', columns: ['id']);
      expect(left.map((r) => r['id']), ['past'],
          reason: '已到期的 pending 必须保留（否则漏触发）');

      // 反面：不传 fireAtAfter = 删全部 pending（旧行为仍成立）。
      expect(await s.occ.deletePendingForTask('t1'), 1);
      expect(await s.db.db.query('occurrences'), isEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // CounterPlanStore / PeerKeyStore / InboundSeenStore / RemoteStore
  // ══════════════════════════════════════════════════════════════
  group('R96-GAP 持久化回落与兜底', () {
    test('GAP-07 savePlan 的 enabled 三级回落：state → 兼容键 → false', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = CounterPlanStore(prefs);

      // 第 3 级：state 无 enabled、兼容键也没有 ⇒ false（默认关）。
      await store.savePlan(CounterPlan.defaults());
      expect(store.enabled, isFalse,
          reason: '三级全空时必须回落到 false，而不是抛/默认 true');

      // 第 2 级：state 里没有 enabled，但兼容键为 true ⇒ true。
      await prefs.setString(
          CounterPlanStore.kState, jsonEncode(<String, dynamic>{'id': 'local'}));
      await prefs.setBool('counter_plan_enabled', true);
      expect(store.enabled, isTrue, reason: 'state 缺 enabled 时应读兼容键');

      // 第 1 级：state 显式 false 必须压过兼容键 true。
      await prefs.setString(CounterPlanStore.kState,
          jsonEncode(<String, dynamic>{'id': 'local', 'enabled': false}));
      expect(store.enabled, isFalse, reason: '权威快照优先于兼容键');
    });

    test('GAP-08 PeerKeyStore 坏 JSON：按空表处理，不抛也不放行', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{PeerKeyStore.storageKey: '{不是 json'});
      final prefs = await SharedPreferences.getInstance();
      final store = PeerKeyStore(prefs);

      expect(store.ids(), isEmpty);
      expect(store.keyFor('dev'), isNull, reason: '坏存储不得放行任何设备');
      // 反面：坏存储仍可被下一次配对重建。
      await store.save('dev', List<int>.generate(32, (i) => i));
      expect(store.keyFor('dev'), List<int>.generate(32, (i) => i));
    });

    test('GAP-09 PeerKeyStore.remove 后仍有剩余：回写剩余映射', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = PeerKeyStore(prefs);
      final keyA = List<int>.generate(32, (i) => i);
      final keyB = List<int>.filled(32, 7);
      await store.save('dev-a', keyA);
      await store.save('dev-b', keyB);

      await store.remove('dev-a');
      expect(store.ids(), {'dev-b'});
      expect(store.keyFor('dev-b'), keyB, reason: '删一把不得影响另一把');
      expect(prefs.getString(PeerKeyStore.storageKey), isNotNull,
          reason: '还有剩余时必须回写，而不是删键');

      // 反面：删到空时走 remove 分支（键被真正删除）。
      await store.remove('dev-b');
      expect(prefs.getString(PeerKeyStore.storageKey), isNull);
    });

    test('GAP-10 InboundSeenStore.snapshot 返回可落盘副本', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = InboundSeenStore(prefs);
      final now = DateTime(2026, 10, 25, 12).millisecondsSinceEpoch;
      expect(store.reserve('id-1', now), isTrue);
      expect(store.reserve('id-2', now + 10), isTrue);

      final snap = store.snapshot();
      expect(snap.keys, containsAll(<String>['id-1', 'id-2']));
      expect(snap['id-1'], now);

      // 反面：快照是副本，改动它不得污染去重表。
      snap['id-3'] = now;
      expect(store.contains('id-3'), isFalse);
      expect(store.length, 2);
    });

    test('GAP-11 RemoteStore.revokedIds 坏 JSON：按空表处理', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'rc_revoked': '{"不是":"数组"}'});
      final prefs = await SharedPreferences.getInstance();
      final store = RemoteStore(prefs);

      expect(store.revokedIds(), isEmpty, reason: '坏值不得让远程模块崩');
      expect(store.isRevoked('任何设备'), isFalse, reason: '坏值不得放行也不得误拒');

      // 反面：正常 JSON 必须照常读出。
      await prefs.setString('rc_revoked', jsonEncode(<String>['dev-1']));
      expect(store.revokedIds(), ['dev-1']);
      expect(store.isRevoked('dev-1'), isTrue);
    });
  });
}

// ══════════════════════════════════════════════════════════════════
// 测试替身：DatabaseFactory / Database 的**最小**注入层
// ══════════════════════════════════════════════════════════════════

/// 可构造的 [DatabaseException]（公开 API 只有抽象基类）。
class _DbException extends DatabaseException {
  // 基类构造参数是私有的 `_message`，无法用 super 形参转发。
  // ignore: use_super_parameters
  _DbException(String message) : super(message);

  @override
  int? getResultCode() => null;

  @override
  Object? get result => null;
}

/// 第一次开库抛 `database is locked`，之后透传给真实工厂。
///
/// 用于命中 `AppDatabase.open` 的退避重试分支：sqflite 没有跨平台错误码，
/// `_isLockedError` 只按文案判定，所以这里刻意只造文案、不碰真实锁。
class _FlakyLockFactory implements SqfliteDatabaseFactory {
  _FlakyLockFactory(this._real);

  final DatabaseFactory _real;

  /// 被调用的次数（用例据此断言"确实重试了一次"）。
  int calls = 0;

  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) {
    calls++;
    if (calls == 1) {
      throw _DbException('database is locked (code 5)');
    }
    return _real.openDatabase(path, options: options);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('_FlakyLockFactory 未实现 ${invocation.memberName}');
}

/// 把真实工厂返回的 [Database] 包一层钩子。
class _HookFactory implements SqfliteDatabaseFactory {
  _HookFactory(this._real, this._hook);

  final DatabaseFactory _real;
  final Database Function(Database inner) _hook;

  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) async =>
      _hook(await _real.openDatabase(path, options: options));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('_HookFactory 未实现 ${invocation.memberName}');
}

/// 只拦截"指定探针/指定表写入"的数据库代理，其余全部透传。
class _HookDatabase implements Database {
  _HookDatabase(this._inner, {this.failRawQueryPrefix, this.failInsertTable});

  final Database _inner;

  /// 以该前缀开头的 `rawQuery` 直接抛（模拟 schema 探针不可用）。
  final String? failRawQueryPrefix;

  /// 往该表 insert 直接抛（模拟审计表不可写）。
  final String? failInsertTable;

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) {
    final prefix = failRawQueryPrefix;
    if (prefix != null && sql.startsWith(prefix)) {
      throw _DbException('注入的 schema 探针失败');
    }
    return _inner.rawQuery(sql, arguments);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _inner.execute(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      _inner.query(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    if (failInsertTable != null && table == failInsertTable) {
      throw _DbException('注入的写入失败：$table');
    }
    return _inner.insert(table, values,
        nullColumnHack: nullColumnHack,
        conflictAlgorithm: conflictAlgorithm);
  }

  @override
  Future<void> close() => _inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('_HookDatabase 未实现 ${invocation.memberName}');
}
