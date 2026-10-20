import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../core/constants.dart';

/// 通知服务：执行结果 / 声音守卫告警 / 取证完成。
/// （前台服务常驻通知由 flutter_background_service 的 AndroidConfiguration 托管）
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// 供远程模块注册通知按钮回调（如指令组终止按钮）。
  FlutterLocalNotificationsPlugin get plugin => _plugin;
  bool _ready = false;

  Future<void> ensure() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(
          tz.getLocation(await FlutterTimezone.getLocalTimezone()));
    } on Object {
      tz.setLocalLocation(tz.getLocation('UTC'));
    }
    const init = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(init);
    _ready = true;
  }

  Future<void> requestPermission() async {
    await ensure();
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  /// 创建全部通知渠道。
  ///
  /// 关键：flutter_background_service 指定了自定义 notificationChannelId
  /// 时【不会】自动创建 channel（见其 BackgroundService.java #L89-95），
  /// channel 缺失会导致 startForeground 通知发布失败并崩溃
  /// （CannotPostForegroundServiceNotificationException）。
  Future<void> createServiceChannel() async {
    await ensure();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.service,
      '声盾后台服务',
      description: '调度引擎常驻通知（含合规文案）',
      importance: Importance.low,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.events,
      '执行事件',
      description: '任务执行结果通知',
      importance: Importance.high,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.guard,
      '声音守卫',
      description: '声音触发告警',
      importance: Importance.max,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.evidence,
      '取证记录',
      description: '录音取证完成通知',
      importance: Importance.high,
    ));
    // BUG-145：来电必须有自己的高优先级渠道（详见 NotificationChannels.calls）。
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.calls,
      '来电',
      description: '远程来电提醒（可全屏弹出，不受执行日志静音影响）',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ));
  }

  /// 来电通知的固定 id（同一时刻只该有一通来电）。
  static const int incomingCallId = 0xCA11;

  /// 弹"来电"通知（BUG-145）。
  ///
  /// ## 为什么必须有它
  /// 振铃界面（`CallOverlayHost`）是**应用内**浮层 —— App 在后台/锁屏时
  /// 根本不渲染。于是"来电"在后台是完全静默的：对端等到 45 秒超时报
  /// "对方无应答"，而这台设备的使用者**从头到尾没被通知过**。
  ///
  /// `fullScreenIntent: true` 让系统在锁屏上直接亮屏弹出来电界面
  /// （需要清单里的 `USE_FULL_SCREEN_INTENT`）；`ongoing: true` +
  /// `autoCancel: false` 保证它不会在用户点开应用前被划掉。
  Future<void> showIncomingCall({
    required String title,
    required String body,
  }) async {
    // 通知是**辅助**手段：插件未就绪（宿主测试 / 被系统回收）时抛
    // `MissingPluginException`，绝不能让"发通知失败"打断通话流程本身。
    // 调用方是 `unawaited(...)`，异常逃出去会变成未处理的异步错误
    // （真机上会冒一条无人接管的栈，测试里直接判当前用例失败）。
    try {
      await ensure();
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          NotificationChannels.calls,
          '来电',
          channelDescription: '远程来电提醒（可全屏弹出，不受执行日志静音影响）',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          playSound: true,
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      );
      await _plugin.show(incomingCallId, title, body, details);
    } on Object {
      // 通知不可用：通话照常进行（应用内振铃浮层仍会显示）。
    }
  }

  /// 收起来电通知（接听 / 拒接 / 超时收尾都要调）。
  ///
  /// `ongoing: true` 的通知**只能**由应用自己取消 —— 漏了这一步，通话结束后
  /// 通知栏会永远挂着一条"来电"，用户点它还会打开一个没有通话的界面。
  Future<void> cancelIncomingCall() async {
    try {
      await _plugin.cancel(incomingCallId);
    } on Object {
      // 通知通道不可用（宿主测试 / 插件未就绪）：无副作用。
    }
  }

  /// 事件通知的**唯一** id 序列（R90-18）。
  ///
  /// 旧实现用 `title.hashCode` 作 id：同标题的两条取证通知会互相覆盖
  /// （短时间连续两条"声盾 · 取证完成"，通知栏只剩最后一条）。事件型通知
  /// 的语义是"每条都要看见"，id 必须按**事件**唯一，而不是按标题去重。
  static int _eventSeq = 0;

  Future<void> showEvent({
    required String title,
    required String body,
    String? payload,
  }) async {
    await ensure();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        NotificationChannels.events,
        '执行事件',
        channelDescription: '任务执行结果通知',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    // 0x7000 起递增，避开其它通道的固定 id（0x600D / 0x5C81 等）。
    final id = 0x7000 + (_eventSeq++ % 0x0FFFF);
    await _plugin.show(id, title, body, details, payload: payload);
  }

  Future<void> showGuardAlert(String body) async {
    await ensure();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        NotificationChannels.guard,
        '声音守卫',
        channelDescription: '声音触发告警',
        importance: Importance.max,
        priority: Priority.max,
      ),
      iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
    );
    await _plugin.show(0x600D, '声盾 · 守卫触发', body, details);
  }
}
