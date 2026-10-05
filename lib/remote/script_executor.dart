import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/constants.dart';
import '../services/playback_service.dart';
import 'rc_script.dart';

/// 步骤执行回调：由端点服务注入（可访问音源解析/播放/TTS/录音能力）。
///
/// 实现应当**自己响应终止**：对长动作（播放/录音）要么用可中断的等待原语
/// （`RcCancel.sleep`、[runRecordWindow]），要么轮询
/// [RcScriptExecutor.activeCancel]。执行器不再无条件等它返回（见 `run`），
/// 但"步骤能否在有限时间内真正停掉"仍取决于实现 —— 实现在
/// [RcScriptExecutor.abortGrace] 内收不了尾，执行器会如实记下降级说明。
typedef RcStepRunner = Future<void> Function(RcStep step);

/// 终止令牌。
class RcCancel {
  final Completer<void> _completer = Completer<void>();

  Future<void> get future => _completer.future;
  bool get cancelled => _completer.isCompleted;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }

  /// 便捷：可中断 sleep。
  Future<void> sleep(Duration d) async {
    try {
      await Future.any([Future<void>.delayed(d), future]);
    } on Object {
      // ignore
    }
  }
}

/// 录音窗口的执行结果。
///
/// 三种终态**必须可分**（都压成"完成"就是静默降级）：
/// - 正常到点：`ok=true`、`aborted=false`；
/// - 收到终止且已停掉：`aborted=true`、`ok=false`（**不算成功**）；
/// - 请求了停止但未获确认：`stopConfirmed=false`，[message] 明确写出
///   "文件可能仍在写入" —— 这是比"录音失败"更严重、必须让用户看见的形状
///   （docs/08 红线：用户点了停就不能还在采集）。
class RecordWindowOutcome {
  const RecordWindowOutcome({
    required this.ok,
    required this.aborted,
    required this.stopConfirmed,
    required this.message,
  });

  final bool ok;
  final bool aborted;
  final bool stopConfirmed;
  final String message;
}

/// 录音窗口：等待 [duration]（或收到 [cancel]，先醒者胜），
/// **无论走哪条路都调用 [stop]**，并把结果分成上面三种终态。
///
/// 为什么必须抽出来：端点的 `record` 步骤此前是
/// `await Future.delayed(seconds)` —— 终止令牌完全不参与，于是用户点「停止
/// 指令组」后录音**仍在写文件**（未授权的隐蔽采集）。这里把"等待"变成
/// 可中断的，并保证"停止"一定被请求、且停不掉时不报成功。
///
/// [tick] 决定终止的延迟上界（默认 100ms）。
Future<RecordWindowOutcome> runRecordWindow(
  Duration duration, {
  required Future<void> Function() stop,
  RcCancel? cancel,
  Duration tick = const Duration(milliseconds: 100),
  Duration stopTimeout = const Duration(seconds: 2),
}) async {
  final aborted = await _awaitRecordWindow(duration, cancel, tick);
  var stopConfirmed = false;
  Object? stopError;
  try {
    await stop().timeout(stopTimeout);
    stopConfirmed = true;
  } on Object catch (e) {
    stopError = e;
  }
  if (!stopConfirmed) {
    return RecordWindowOutcome(
      ok: false,
      aborted: aborted,
      stopConfirmed: false,
      message: '已请求停止录音但未获确认（$stopError）；文件可能仍在写入',
    );
  }
  return RecordWindowOutcome(
    ok: !aborted,
    aborted: aborted,
    stopConfirmed: true,
    message: aborted ? '录音取证被终止（已停止写入）' : '录音取证完成',
  );
}

/// 等待窗口：返回 true = 被终止，false = 自然到点。
Future<bool> _awaitRecordWindow(
    Duration duration, RcCancel? cancel, Duration tick) async {
  if (cancel == null) {
    await Future<void>.delayed(duration);
    return false;
  }
  var left = duration;
  while (left > Duration.zero) {
    if (cancel.cancelled) return true;
    final step = left < tick ? left : tick;
    await Future<void>.delayed(step);
    left -= step;
  }
  return cancel.cancelled;
}

/// 远程指令组执行器（端点侧）。
///
/// 生命周期与用户可见性：
/// 1. 收到 script.run → 立即发布「远程指令组执行中」高优先级通知
///    （含发送方/发送时间/步骤进度 + 【终止执行】按钮）；
/// 2. 顺序执行步骤（[runner] 注入具体能力），每步推进通知进度；
/// 3. 用户点【终止执行】（通知 action 回调）或收到 script.stop →
///    **先掐断正在出声的播放器**（[mediaStopper]），再让执行循环收尾：
///    令牌取消 → 正在进行的步骤获得一个 [abortGrace] 的收尾窗口 →
///    通知更新为「已终止」并在 3 秒后清除；
/// 4. 全部完成 → 「执行完成」通知，3 秒后自动清除（弹窗随之消失）。
///
/// ## 「任何时刻都能停」是硬约束（docs/20 §7.2 S3）
///
/// 旧实现只做两件事：取消令牌 + 在**步骤之间**检查令牌。于是一个"播放 10 分钟"
/// 的步骤会把终止拖到自然结束，端点上**继续出声 / 继续录音** —— 对 `record`
/// 更直接踩到 docs/08 的隐蔽采集红线（用户点了"停"却还在录）。
/// 现在分三层：
/// 1. [stop] 同步落标志 + 立刻 [mediaStopper]（听觉上先停）；
/// 2. [run] 用 `Future.any` 与终止令牌竞速，不再无条件 `await runner(step)`；
/// 3. 步骤若在 [abortGrace] 内没有收尾，**如实记下降级说明**（[lastStopNote]）
///    并写进终态通知 —— 绝不静默假装"已经停干净了"。
class RcScriptExecutor {
  RcScriptExecutor._();
  static final RcScriptExecutor instance = RcScriptExecutor._();

  RcScript? _current;
  RcCancel? _cancel;
  bool _stopping = false;

  /// 步骤被放弃等待前允许的**收尾窗口**。
  ///
  /// 终止到达后底层资源需要一点时间释放（播放器 stop / 录音器 stop），
  /// 先给它这个窗口；窗口内没返回就按"资源可能仍在运行"记录降级说明。
  static const Duration abortGrace = Duration(seconds: 3);

  /// 停止媒体的可注入能力（端点装配期可替换；默认掐断全部正在播放的
  /// [PlaybackService]）。注入缝的理由同 `playHandler`：执行器不该知道
  /// 端点用的是什么播放器。
  Future<int> Function() mediaStopper = PlaybackService.stopAllPlaying;

  /// 上一次终止的**降级说明**；null = 干净停止。
  ///
  /// 项目红线：失败必须让用户知道。停不掉时这里会有一行原因，并随终态
  /// 通知一并展示给端点使用者（控制端也会看到 `done:false`）。
  String? _lastStopNote;
  String? get lastStopNote => _lastStopNote;

  /// 进行中的"掐断媒体"动作；终态通知前会等它一下，否则降级说明可能赶不上
  /// 通知（race）。[stop] 不阻塞（同步接口），收尾由 [run] 兜。
  Future<void>? _halt;

  bool get isRunning => _current != null;
  String? get currentScriptId => _current?.scriptId;

  /// 当前执行的终止令牌（端点服务的步骤 runner 用它响应终止）。
  RcCancel? get activeCancel => _cancel;

  /// 注册通知终止按钮回调（main.dart 启动时调用一次）。
  static void registerStopHandler(
      FlutterLocalNotificationsPlugin plugin, void Function() onStop) {
    plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (resp) {
        if (resp.actionId == 'rc_script_stop') onStop();
      },
    );
  }

  /// 执行指令组；返回 true=完整执行，false=被终止。
  /// [onStep] 可选：每步开始回调（i, step），用于事件上报。
  Future<bool> run(
    RcScript script, {
    required RcStepRunner runner,
    void Function(int index, RcStep step)? onStep,
  }) async {
    if (isRunning) return false; // 一次一组；新组需先终止旧组
    _current = script;
    _stopping = false;
    _lastStopNote = null;
    _halt = null;
    final cancel = _cancel = RcCancel();

    await _notify(
      title: '声盾 · 远程指令组',
      body: '${script.fromName} · ${_fmt(script.sentAt)}\n'
          '${script.name}（共 ${script.steps.length} 步）执行中…',
      ongoing: true,
    );

    var aborted = false;
    for (var i = 0; i < script.steps.length; i++) {
      if (_stopping || cancel.cancelled) {
        aborted = true;
        break;
      }
      final step = script.steps[i];
      await _notify(
        title: '声盾 · 远程指令组（${i + 1}/${script.steps.length}）',
        body: '${script.fromName} · ${step.describe()}',
        ongoing: true,
      );
      onStep?.call(i, step);

      // ⚠️ 竞速而不是无条件 `await runner(step)`。
      //
      // 旧写法把「终止」拖成"等当前步骤自然结束"：一个 `play`（可能 10 分钟）
      // 或 `record`（30 秒且令牌完全不参与）步骤期间，端点**继续出声 /
      // 继续录音**。`settled` 立刻挂上 onError，因此单步失败不中断整体的
      // 语义不变，也不会产生"停止之后才抛出的未处理异步错误"。
      final settled = runner(step)
          .then<bool>((_) => true, onError: (Object e) => true);
      final finished = await Future.any<bool>([
        settled,
        cancel.future.then((_) => false),
      ]);
      if (finished) {
        if (_stopping || cancel.cancelled) {
          aborted = true;
          break;
        }
        continue;
      }

      // 终止先到。给步骤一个**有限的**收尾窗口（底层资源正在释放）；
      // 窗口内没返回就必须把"可能还在跑"说出来，而不是静默当成功。
      aborted = true;
      var unwound = false;
      try {
        unwound = await settled.timeout(abortGrace);
      } on Object {
        unwound = false; // 超时：步骤没有在窗口内收尾
      }
      if (!unwound) {
        _lastStopNote ??= '步骤 ${i + 1}（${step.kind.name}）在终止后 '
            '${abortGrace.inSeconds} 秒内未返回，其底层资源可能仍在运行';
      }
      break;
    }

    // 等收尾动作落定再发终态：否则"掐不断媒体"的降级说明会赶不上通知，
    // 用户看到"已终止"却仍在听声音（正是要修的那种静默）。
    final halt = _halt;
    if (halt != null) await halt;

    final note = _lastStopNote;
    await _notify(
      title: aborted ? '声盾 · 指令组已终止' : '声盾 · 指令组执行完成',
      body: aborted && note != null
          ? '${script.fromName} · ${script.name}\n⚠️ $note'
          : '${script.fromName} · ${script.name}',
      ongoing: false,
    );
    Timer(const Duration(seconds: 3), () {
      // 弹窗/通知的清理是 **best-effort**：平台通道不可用时（宿主测试里 mock 通道
      // 已摘除、真机上插件未就绪/被系统回收）**不能升级成"未处理的异步错误"**。
      // 2026-10-04 门禁实测：这条 3 秒计时器在 `endpoint_ptt_evidence_test.dart`
      // 的 tearDown 摘除 mock 通道后触发，抛
      // `MissingPluginException(No implementation found for method cancel ...)`；
      // 该异常落在 `Timer` 回调里无人接管，被 flutter_test 归到**当时正在跑的用例**
      // 名下 ⇒ EV-01..04 集体假红（实为计时器越界，而不是断言失败）。
      unawaited(
          FlutterLocalNotificationsPlugin().cancel(0x5C81).catchError((Object _) {
        // 通知已经不重要了：清不掉就让它自己消失，不制造未处理异步错误。
      })); // 弹窗/通知随之消失
    });

    _current = null;
    _cancel = null;
    return !aborted;
  }

  /// 终止当前执行（通知按钮 / script.stop 命令）。
  ///
  /// 「停」必须先是**听觉事实**：先同步落标志 + 立刻掐断出声中的播放器，
  /// 再让执行循环收尾。旧实现只取消令牌，而令牌只在步骤之间被检查 ——
  /// 那正是"用户点了停，端点继续出声/继续录音"的根因。
  void stop() {
    if (!isRunning) return;
    _stopping = true;
    _cancel?.cancel();
    // 不 await：stop() 是同步接口（通知 action / 命令分支都同步调用）。
    // 掐断媒体与执行循环收尾并行推进，任何一方都不拖住另一方；
    // 收尾由 [run] 在发终态通知前等一下 [_halt]。
    final halt = _haltMedia();
    _halt = halt;
    unawaited(halt);
  }

  /// 掐断端点正在出声的播放；失败**必须留痕**（不得静默）。
  Future<void> _haltMedia() async {
    try {
      await mediaStopper().timeout(abortGrace);
    } on Object catch (e) {
      // 停不掉就说出来：否则控制端以为"已经停了"，用户还会继续听见声音。
      _lastStopNote = '未能确认停止播放：$e';
    }
  }

  Future<void> _notify({
    required String title,
    required String body,
    required bool ongoing,
  }) async {
    final plugin = FlutterLocalNotificationsPlugin();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        NotificationChannels.events,
        '执行事件',
        channelDescription: '任务执行结果通知',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: ongoing,
        onlyAlertOnce: true,
        actions: ongoing
            ? <AndroidNotificationAction>[
                const AndroidNotificationAction(
                  'rc_script_stop',
                  '终止执行',
                  showsUserInterface: true,
                ),
              ]
            : const <AndroidNotificationAction>[],
      ),
      iOS: const DarwinNotificationDetails(presentAlert: true),
    );
    await plugin.show(0x5C81, title, body, details);
  }

  static String _fmt(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

/// 组装器步骤（控制器 UI 数据结构）。
class ScriptDraftStep {
  ScriptDraftStep(this.kind, this.params);

  RcStepKind kind;
  Map<String, dynamic> params;

  RcStep toStep() => RcStep(kind, params);

  String describe() => RcStep(kind, params).describe();
}

/// 组装器草稿（UI 持有；序列化为协议 payload）。
class ScriptDraft {
  ScriptDraft({required this.name, required this.steps});

  String name;
  List<ScriptDraftStep> steps;

  String? validate() => RcScript.validate([for (final s in steps) s.toStep()]);

  Map<String, dynamic> toPayload({
    required String scriptId,
    required String fromName,
  }) =>
      RcScript(
        scriptId: scriptId,
        name: name,
        fromName: fromName,
        sentAt: DateTime.now().millisecondsSinceEpoch,
        steps: [for (final s in steps) s.toStep()],
      ).toJson();
}
