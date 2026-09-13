import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/constants.dart';
import 'rc_script.dart';

/// 步骤执行回调：由端点服务注入（可访问音源解析/播放/TTS/录音能力）。
/// 实现内部应通过 [RcCancel.check] 响应终止并尽快返回。
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

/// 远程指令组执行器（端点侧）。
///
/// 生命周期与用户可见性：
/// 1. 收到 script.run → 立即发布「远程指令组执行中」高优先级通知
///    （含发送方/发送时间/步骤进度 + 【终止执行】按钮）；
/// 2. 顺序执行步骤（[runner] 注入具体能力），每步推进通知进度；
/// 3. 用户点【终止执行】（通知 action 回调）或收到 script.stop →
///    令牌取消，当前步骤尽快中断，通知更新为「已终止」并在 3 秒后清除；
/// 4. 全部完成 → 「执行完成」通知，3 秒后自动清除（弹窗随之消失）。
class RcScriptExecutor {
  RcScriptExecutor._();
  static final RcScriptExecutor instance = RcScriptExecutor._();

  RcScript? _current;
  RcCancel? _cancel;
  bool _stopping = false;

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
      try {
        await runner(step);
      } on Object {
        // 单步失败不中断整体（与本地动作语义一致），继续下一步。
      }
      if (_stopping || cancel.cancelled) {
        aborted = true;
        break;
      }
    }

    await _notify(
      title: aborted ? '声盾 · 指令组已终止' : '声盾 · 指令组执行完成',
      body: '${script.fromName} · ${script.name}',
      ongoing: false,
    );
    Timer(const Duration(seconds: 3), () {
      FlutterLocalNotificationsPlugin().cancel(0x5C81); // 弹窗/通知随之消失
    });

    _current = null;
    _cancel = null;
    return !aborted;
  }

  /// 终止当前执行（通知按钮 / script.stop 命令）。
  void stop() {
    if (!isRunning) return;
    _stopping = true;
    _cancel?.cancel();
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
