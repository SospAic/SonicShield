import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/main.dart' as app;
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sqflite/sqflite.dart';

/// 守护引擎总开关真机（模拟器）诊断探针 v10 = R89 终版验证（API 36）。
///
/// ## 背景（v8 定死的根因一）
///
/// v8 按集成测试标准模板显式跑 `app.main()`（真实 bootstrap）后复现了
/// 1.9.6+29 用户报障原型：configure 完整落盘、原生 FGS 起来、
/// `start()` 返回 true，但引擎在 `AppDatabase.open()` 处抛
/// `DatabaseException(table tasks already exists)` 死亡、状态零回投
/// ⇒ 开关永远"关"且零提示。
///
/// 根因：sqflite 的 `onCreate` 只判 `PRAGMA user_version == 0`、不判表
/// 存在性；主 UI 引擎与后台引擎（两个 FlutterEngine、两条原生连接）并发
/// 打开同一新库时，败者连接撞上胜者刚提交的 `CREATE TABLE`。
/// 修复：`_onCreate` 幂等化（IF NOT EXISTS）+ 引擎打开一次有界重试。
///
/// ## v9 定死的根因二（stop → start 永久假死）
///
/// v9 主路径全绿（引擎完整启动、`switches=[true]`、FGS 通知在栏），但
/// stop 后再 start 起不来。取证链：探针自己的只读 dump **收养并关闭**了
/// 引擎的原生连接（sqflite_android `_singleInstancesByPath` 进程级静态表
/// 只按路径键、不区分 readOnly）⇒ 引擎 stop 清理链的 `broadcast(false)`
/// 抛 `database_closed 2` ⇒ **`stopSelf()` 从未执行** ⇒ 原生
/// `isRunning` 保持 true ⇒ 二启 `runService()` 早退「Service already
/// running」⇒ `startService()` 返回 true 但无新引擎、无状态回投。
///
/// 修复：① `AppDatabase.open()` 显式 `singleInstance: false`（两引擎各持
/// 独立连接，与 BUG-022 注释宣称的一致）；② 引擎 stop 清理链收口
/// try/finally，`stopSelf()` 必须执行；③ 探针 dump 同样
/// `singleInstance: false`。
///
/// ## v10 验证判据（全绿才算修好）
///
/// 1. **竞态窗口**：configure 一落盘就 `start()`，引擎必须走完
///    m0-entry → m1-registrant → … → m7-handlers-registered 并回投
///    `running:true`；
/// 2. **库一致性**：引擎打开前后只读 dump `user_version` + 表清单；
/// 3. **主 isolate 不受损**：主 isolate 显式 `AppDatabase.open()` 必须成功；
/// 4. **稳态库二启**：stop 后再 start 必须拉起**全新引擎**（诊断文件
///    出现第二段 m0-entry）并回投 `running:true`；
/// 5. **零晚发异常**：诊断文件不得出现 `m-2-unhandled`。
const _kDiagPath = 'r89_engine_diag.txt';
const _kPkg = 'com.sonicshield.sonic_shield';

Future<void> _settle(WidgetTester tester, {int ms = 1500}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

Future<void> _preAcceptCompliance() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('compliance_accepted_v1', true);
}

File get _diagFile => File('${Directory.systemTemp.path}/$_kDiagPath');

/// 只读 dump 业务库状态（不写、不建文件、不开 onCreate）。
///
/// ⚠️ **必须 `singleInstance: false`**：sqflite_android 的
/// `_singleInstancesByPath` 是进程级静态表、只按路径键、不区分 readOnly ——
/// 默认值下这次只读打开会**收养引擎/主 isolate 已持有的那条原生连接**，
/// 随后的 `close()` 直接把它杀死（R89 v9 实证：dump 之后引擎立刻
/// `database_closed 2`）。取证工具不能破坏被测系统。
Future<String> _dumpDb() async {
  final path =
      p.join(await databaseFactory.getDatabasesPath(), 'sonic_shield.db');
  final exists = await databaseFactory.databaseExists(path);
  if (!exists) return 'NOT_EXISTS ($path)';
  try {
    final ro = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    try {
      final v = await ro.rawQuery('PRAGMA user_version');
      final tables = await ro.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
      final names = tables.map((r) => r['name']).join(',');
      return 'version=${v.first.values.first} tables=[$names] ($path)';
    } finally {
      await ro.close();
    }
  } on Object catch (e) {
    return 'READ_ERR=$e ($path)';
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('I 修复验证：双引擎 DB 并发 + 引擎全链路启动', (tester) async {
    // 0) 清诊断残留，写主 isolate 对照行。
    try {
      if (_diagFile.existsSync()) _diagFile.deleteSync();
    } on Object {
      // 删不掉不阻断。
    }
    try {
      _diagFile.writeAsStringSync('CONTROL main-isolate ok\n',
          mode: FileMode.append, flush: true);
      // ignore: avoid_print
      print('PROBE_I channelControl=${_diagFile.readAsStringSync().trim()}');
    } on Object catch (e) {
      // ignore: avoid_print
      print('PROBE_I channelControl_ERR=$e');
    }

    await _preAcceptCompliance();

    // 1) 真实 bootstrap。
    unawaited(app.main().catchError((Object e) {
      // ignore: avoid_print
      print('PROBE_I app.main_ERR=$e');
    }));

    // 2) 等 configure 落盘（与 v8 同一时序：一落盘就起服务）。
    final mgr = BackgroundServiceManager.instance;
    var sawConfigure = false;
    for (var i = 0; i < 40; i++) {
      await _settle(tester, ms: 250);
      final f = File('/data/data/$_kPkg/shared_prefs/'
          'id.flutter.background_service.xml');
      if (f.existsSync() &&
          f.readAsStringSync().contains('background_handle')) {
        sawConfigure = true;
        break;
      }
      if (mgr.initError != null) break;
    }
    // ignore: avoid_print
    print('PROBE_I sawConfigure=$sawConfigure initError=${mgr.initError}');
    // ignore: avoid_print
    print('PROBE_I db_before=${await _dumpDb()}');

    // 3) 竞态窗口启动（复刻 v8 现场：configure 落盘即 start）。
    final ok1 = await mgr.start();
    // ignore: avoid_print
    print('PROBE_I start1_ok=$ok1 startError=${mgr.startError}');
    for (var i = 0; i < 15; i++) {
      await _settle(tester, ms: 1000);
    }
    final last1 = mgr.last;
    // ignore: avoid_print
    print('PROBE_I after_start1.running=${last1?.running} '
        'pendingCount=${last1?.pendingCount}');
    try {
      final switches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .map((w) => '${w.value}')
          .toList();
      // ignore: avoid_print
      print('PROBE_I switches=$switches');
    } on Object catch (e) {
      // ignore: avoid_print
      print('PROBE_I switches_ERR=$e');
    }
    // ignore: avoid_print
    print('PROBE_I db_after_engine=${await _dumpDb()}');

    // 4) 主 isolate 打开业务库必须成功（不被引擎的打开带崩）。
    try {
      await AppDatabase.open();
      // ignore: avoid_print
      print('PROBE_I main_open=OK');
    } on Object catch (e) {
      // ignore: avoid_print
      print('PROBE_I main_open_ERR=$e');
    }
    // ignore: avoid_print
    print('PROBE_I db_after_main=${await _dumpDb()}');

    // 5) 稳态库二启：stop 后再 start。
    await mgr.stop();
    for (var i = 0; i < 5; i++) {
      await _settle(tester, ms: 1000);
    }
    final ok2 = await mgr.start();
    // ignore: avoid_print
    print('PROBE_I start2_ok=$ok2 startError=${mgr.startError}');
    for (var i = 0; i < 10; i++) {
      await _settle(tester, ms: 1000);
    }
    final last2 = mgr.last;
    // ignore: avoid_print
    print('PROBE_I after_start2.running=${last2?.running}');

    final diag = _diagFile.existsSync() ? _diagFile.readAsStringSync() : null;
    final lines = (diag ?? '')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    // ignore: avoid_print
    print('PROBE_I diag=${lines.join(' | ')}');
    final booted = lines.any((l) => l.contains('m7-handlers-registered'));
    final broadcast1 = last1?.running == true;
    final broadcast2 = last2?.running == true;
    // 二启必须拉起**全新引擎**（第二段 m0-entry）。
    final boots = lines.where((l) => l.contains('m0-entry')).length;
    // 零晚发异常（stop 清理链 / tick 续算链抛错都会在这里现形）。
    final noUnhandled =
        !lines.any((l) => l.contains('m-2-unhandled'));
    // ignore: avoid_print
    print('PROBE RESULT I = booted=$booted broadcast1=$broadcast1 '
        'broadcast2=$broadcast2 boots=$boots noUnhandled=$noUnhandled '
        'configure=$sawConfigure');
  });
}
