import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/core/utils/endpoint_security.dart';
import 'package:sonic_shield/data/repositories/api_config_store.dart';
import 'package:sonic_shield/remote/multi_call_service.dart';

import 'support/source_text.dart';

/// R91 全量修复的回归锁（R90 审计 26 条 + 3 体验项）。
///
/// ## 为什么大多是「源码锁」
///
/// 本轮缺陷集中在**引擎闭包 / 平台通道 / 私有字段**上（`_engineBody` 内的
/// `runNow` 处理器、`PlaybackService` 的并发路径、`_PttSheetState` 的生命周期），
/// 宿主上**无法实例化**（依赖 `flutter_background_service` 的 isolate、真实
/// 播放器、系统权限弹窗）。按项目既定纪律（`docs/17 §62.2`），这类分支用
/// **源码锁 + 变异证伪**，而不是写一个替身把断言变成恒真。
///
/// 纯函数（端点安全判据）与常量（并发上限）用**行为断言**。
///
/// ⚠️ 锁的纪律：每条锁都必须能**失败**（判据非恒真）。正向断言之外尽量带一条
/// **反面样本**（如"不该再出现的旧写法"），否则 `contains` 可能在注释里命中。
void main() {
  final engineRaw =
      File('lib/services/background_engine.dart').readAsStringSync();
  final engine = stripComments(engineRaw);
  final playback = stripComments(
      File('lib/services/playback_service.dart').readAsStringSync());
  final remoteScreen = stripComments(
      File('lib/features/remote/remote_screen.dart').readAsStringSync());
  final executor = stripComments(
      File('lib/remote/script_executor.dart').readAsStringSync());
  final viewer = stripComments(
      File('lib/features/remote/screen_viewer.dart').readAsStringSync());
  final multi = stripComments(
      File('lib/remote/multi_call_service.dart').readAsStringSync());
  final pttTab = stripComments(
      File('lib/features/remote/ptt_tab.dart').readAsStringSync());
  final builder = stripComments(
      File('lib/features/remote/script_builder_screen.dart').readAsStringSync());
  final join = stripComments(
      File('lib/remote/assist_join.dart').readAsStringSync());
  final host = stripComments(
      File('lib/remote/assist_host.dart').readAsStringSync());
  final notify = stripComments(
      File('lib/services/notification_service.dart').readAsStringSync());
  final retention = stripComments(
      File('lib/services/retention_maintenance.dart').readAsStringSync());
  final editor = stripComments(
      File('lib/features/tasks/task_editor_screen.dart').readAsStringSync());
  final taskRepo = stripComments(
      File('lib/data/repositories/task_repository.dart').readAsStringSync());

  /// 取 [start] 之后、[end] 之前的片段（找不到返回空串，锁会因此失败）。
  String region(String src, String start, String end) {
    final i = src.indexOf(start);
    if (i < 0) return '';
    final j = src.indexOf(end, i + start.length);
    return j > i ? src.substring(i, j) : '';
  }

  group('R90-01 内置密钥', () {
    test('R91-01a 内置 DeepSeek Key 默认值必须为空（不得再随仓库分发凭据）', () {
      // 行为判据：从未配置时 `hasApiKey == false`。
      expect(ApiConfigStore.defaultApiKey, isEmpty,
          reason: '内置默认 Key 必须为空 —— 真实凭据不得进版本库');
    });

    test('R91-01b lib/ 下不得出现 `sk-` 形态的密钥字面量', () {
      final re = RegExp(r'sk-[0-9a-zA-Z]{20,}');
      final offenders = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        if (re.hasMatch(f.readAsStringSync())) offenders.add(f.path);
      }
      expect(offenders, isEmpty,
          reason: '发现疑似 API Key 字面量：$offenders（密钥请走 --dart-define）');
    });
  });

  group('R90-02 legacy 对讲面板', () {
    test('R91-02 必须有按住复核 / 60 秒上限 / dispose 撤销录音', () {
      final sheet = region(remoteScreen, 'class _PttSheetState', 'class _PttSheet');
      final body = sheet.isEmpty
          ? remoteScreen.substring(remoteScreen.indexOf('class _PttSheetState'))
          : sheet;
      expect(body, contains('_pressing'), reason: '缺少松手复核（跨 await 竞态）');
      expect(body, contains('_maxRecSec'), reason: '缺少录音时长上限');
      expect(body, contains('_limitTimer'),
          reason: '缺少 60 秒上限计时器（一次性 Timer，不用周期计时器）');
      expect(body, contains('void dispose()'), reason: '缺少 dispose 兜底');
      final disposeBody = methodBody(body, 'void dispose()');
      expect(disposeBody, contains('onCancel'),
          reason: 'dispose 必须撤销仍在进行的录音');
    });
  });

  group('R90-03/04/05/14 引擎裁决一致性', () {
    test('R91-03 远程 runNow 必须复用 admitExecution（含 pausedAt 闸）', () {
      final rn = region(
          engine, "service.on('runNow')", "service.on('vibrateStep')");
      expect(rn, isNotEmpty, reason: 'runNow 处理器定位失效，请同步更新本锁');
      expect(rn, contains('admitExecution'),
          reason: 'runNow 必须走统一裁决（暂停 → 条件 → 概率）');
      expect(rn, isNot(contains('probabilityGateMissed')),
          reason: 'runNow 不得再内联概率门（与 admitExecution 分叉）');
    });

    test('R91-04 声音守卫计划必须三态落库（skipped 不得并进 done）', () {
      final guard = region(engine, 'Future<void> runGuardPlan', 'Future<void> onSoundEvent');
      expect(guard, isNotEmpty, reason: 'runGuardPlan 定位失效');
      expect(guard, contains('outcome.isSkipped'),
          reason: 'skipped 必须单独落 OccurrenceStatus.skipped（BUG-093 孪生）');
    });

    test('R91-05 声音任务不得显示免打扰豁免控件（死设置必须下架）', () {
      expect(editor, contains('TriggerType.soundTriggered'),
          reason: '编辑器必须对声音任务分支处理免打扰区');
      expect(editor, contains('不受免打扰时段约束'),
          reason: '必须给出"为何无需设置"的说明，而不是静默隐藏');
    });

    test('R91-14 反击计划续算失败必须留痕（不得只在成功时写日志）', () {
      final ext = region(engine, 'Future<void> extendCounterPlan', 'Future<void> executeDue');
      expect(ext, contains('!r.ok'),
          reason: '失败分支必须落日志（旧实现只在 taskCount > 0 时写）');
      expect(ext, contains('lastCounterFailMsg'),
          reason: '失败日志必须去重，否则每 15s 刷一条');
    });
  });

  group('R90-06 停机闸门', () {
    test('R91-06 stop 先置 stopping，且 tick / executeDue / replan / 闹钟全查', () {
      final stop =
          region(engine, "service.on('stop')", "service.on('vibrateStop')");
      expect(stop, isNotEmpty, reason: 'stop 处理器定位失效');
      // 第一条语句置位：在第一个 await 之前。
      // 用 region（剥注释后的片段）而不是 methodBody：region 的起点就是
      // 处理器签名，里面的第一个 `await` 必然是真正的第一个 await。
      expect(stop, contains('stopping = true'),
          reason: 'stop 处理器必须在任何 await 之前置位停机闸门');
      final setStop = stop.indexOf('stopping = true');
      final firstAwait = stop.indexOf('await');
      expect(setStop, greaterThan(-1), reason: '找不到 stopping = true');
      expect(firstAwait, greaterThan(setStop),
          reason: '`stopping = true` 必须在第一个 await 之前');
      expect(engine, contains('if (stopping) return;'),
          reason: 'tick / executeDue / replan / pushExactAlarms 必须有闸门');
      expect('if (stopping) return;'.allMatches(engine).length, greaterThanOrEqualTo(4),
          reason: '四条路径都要查闸门（tick / executeDue / replan / pushExactAlarms）');
    });
  });

  group('R90-07 播放并发隔离', () {
    test('R91-07 play 每路独立播放器 + 代次停止', () {
      expect(playback, contains('_stopGen'),
          reason: '停止必须用代次（bool 会被后一次播放清掉）');
      expect(playback, contains('_soloPlayers'),
          reason: '在飞播放器必须逐路登记');
      expect(playback, isNot(contains('_player ??=')),
          reason: '不得再复用共享播放器（并发互踩的根因）');
      final playBody =
          region(playback, 'Future<PlayResult> play({', 'Future<void> _hardStop(');
      expect(playBody, contains('AudioPlayer()'),
          reason: 'play() 必须新建播放器');
      expect(playBody, contains('_soloPlayers.remove(player)'),
          reason: 'finally 必须摘登记');
      expect(playBody, contains('_playing.remove(this)'),
          reason: '登记表必须在最后一个播放结束时摘除');
    });
  });

  group('R90-08 端点安全判据（行为）', () {
    test('R91-08 公网明文拒绝，https/回环/私有网段放行', () {
      expect(isSecureEndpoint('https://api.deepseek.com'), isTrue);
      expect(isSecureEndpoint('wss://speech.example.com/x'), isTrue);
      expect(isSecureEndpoint('http://api.deepseek.com'), isFalse,
          reason: '公网明文会泄露 Bearer Key');
      expect(isSecureEndpoint('http://localhost:8080/v1'), isTrue);
      expect(isSecureEndpoint('http://127.0.0.1:9000'), isTrue);
      expect(isSecureEndpoint('http://192.168.0.5:8080'), isTrue);
      expect(isSecureEndpoint('http://10.1.2.3'), isTrue);
      expect(isSecureEndpoint('http://172.20.0.1'), isTrue);
      expect(isSecureEndpoint('http://172.32.0.1'), isFalse,
          reason: '172.32 不在 172.16/12 内');
      expect(isSecureEndpoint(''), isFalse);
      expect(isSecureEndpoint('ftp://x'), isFalse);
    });
  });

  group('R90-09 单行损坏隔离', () {
    test('R91-09 listAll 必须逐行兜底并回调 onRowError', () {
      final body = region(taskRepo, 'Future<List<Task>> listAll({',
          'static Map<String, Object?> _row(');
      expect(body, contains('onRowError'),
          reason: '必须把坏行交给调用方留痕');
      expect(body, contains('try {'), reason: '必须逐行 try/catch');
      expect(body, isNot(contains('rows.map(Task.fromRow)')),
          reason: '不得再整表 map（一行坏数据会拖垮全部）');
    });
  });

  group('R90-10/11/12/13/15/16/17/18 远程路径', () {
    test('R91-10 指令组执行必须 finally 复位 _current', () {
      final run = region(executor, 'Future<bool> run(', 'void stop()');
      expect(run, contains('finally'), reason: '缺 finally 会把指令组通道永久焊死');
      final finIdx = run.indexOf('finally');
      final curIdx = run.indexOf('_current = null');
      expect(curIdx, greaterThan(finIdx),
          reason: '`_current = null` 必须在 finally 内');
    });

    test('R91-11 观看页必须消费 rc.inputAck（按 castId 过滤）', () {
      expect(viewer, contains('RcEvt.inputAck'),
          reason: '不消费回执 = 远程控制失败在观看页不可见');
      expect(viewer, contains("p['castId']"),
          reason: '回执必须按 castId 匹配当前会话');
    });

    test('R91-12 多视频必须有全局路上限', () {
      expect(MultiCallService.maxConcurrentSessions, 4);
      expect(multi, contains('atCapacity'),
          reason: 'connect() 必须先查上限，再申请摄像头');
    });

    test('R91-13 对讲回执必须按来源端点过滤', () {
      expect(pttTab, contains('peer != _selectedId'),
          reason: 'R-5 同族：跨端点回执会张冠李戴');
    });

    test('R91-15 组装器 _load 必须查 mounted', () {
      final load = methodBody(builder, 'Future<void> _load() async {');
      expect(load, contains('if (!mounted) return;'),
          reason: 'await 之后 setState 必须复核 mounted');
    });

    test('R91-16 协助接入必须 try/catch（失败可见且复位 opening）', () {
      expect(join, contains("_fail('接入失败：\$e')"),
          reason: '未预期异常必须落成可见失败');
    });

    test('R91-17 权限发布必须先发后改（失败回退）', () {
      final grant = region(host, 'Future<bool> grant(', 'static String _permSummary');
      expect(grant, isNotEmpty, reason: 'grant() 定位失效');
      final pub = grant.indexOf('_publish');
      final assign = grant.indexOf('s.perms = perms');
      expect(pub, greaterThan(-1));
      expect(assign, greaterThan(pub),
          reason: '必须发布成功后才改本地权限（否则两端状态静默不一致）');
      expect(grant, contains('s.perms = prev'),
          reason: '发布失败必须回退');
    });

    test('R91-18 事件通知 id 不得由标题哈希决定', () {
      final body = region(
          notify, 'Future<void> showEvent({', 'Future<void> showGuardAlert(');
      expect(body, isNot(contains('title.hashCode')),
          reason: '同标题通知会互相覆盖');
      expect(body, contains('_eventSeq'),
          reason: '事件型通知必须按事件唯一');
    });
  });

  group('R90-19/20/21/22/23/24/25/26 其余', () {
    test('R91-19 引擎停机必须释放播放器句柄', () {
      expect(engine, contains('playback.dispose()'),
          reason: 'stop 链必须 dispose 引擎独占的播放器');
    });

    test('R91-20 不得保留无生产者的 tick 监听', () {
      expect(engine, isNot(contains("service.on('tick')")),
          reason: '全仓无 invoke(tick)，死登记会误导触发源数量');
    });

    test('R91-21 runNow 任务不存在必须写本机审计', () {
      final rn = region(
          engine, "service.on('runNow')", "service.on('vibrateStep')");
      final notExist = rn.indexOf("message = '任务不存在'");
      expect(notExist, greaterThan(-1));
      final after = rn.substring(notExist);
      expect(after, contains('logs.append'),
          reason: '相邻失败分支都留痕，这一条不能例外');
    });

    test('R91-22 振动步骤未执行必须落审计（回执承诺"已记入"）', () {
      expect(engine, contains('已记入执行日志'),
          reason: '回执文案承诺了留痕，就必须真的有一条');
      expect(engine, isNot(contains('见审计')),
          reason: '不得再承诺一条不存在的审计');
    });

    test('R91-23 保留策略两步必须互相隔离', () {
      final run = methodBody(retention, 'Future<RetentionOutcome> run() async {');
      expect('try {'.allMatches(run).length, greaterThanOrEqualTo(2),
          reason: 'logs / occurrences 两步各自 try（一步失败不得阻断另一步）');
      expect(run, contains('onError'),
          reason: '失败必须可上报');
    });

    test('R91-24 诊断文件必须有界轮转', () {
      expect(engine, contains('256 * 1024'),
          reason: '诊断文件无限增长需轮转');
    });

    test('R91-25 组装器页面控制器必须释放', () {
      final dispose = methodBody(builder, 'void dispose()');
      expect(dispose, contains('_nameCtrl.dispose()'));
    });

    test('R91-26 音源 tags 坏 JSON 不得拖垮列表', () {
      expect(taskRepo, contains('_decodeTags'),
          reason: '裸 jsonDecode 会让单行坏数据炸掉整张音源表');
    });
  });
}
