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
  }

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
    await _plugin.show(title.hashCode & 0x7fffffff, title, body, details,
        payload: payload);
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
