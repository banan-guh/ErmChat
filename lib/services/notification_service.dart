import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final _tapController = StreamController<String>.broadcast();
  final _postedIds = <int>{};
  String? _pendingLaunchChannel;

  Stream<String> get onNotificationTap => _tapController.stream;
  String? get pendingLaunchChannel => _pendingLaunchChannel;

  Future<void> init() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onResponse,
    );

    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp == true) {
      _pendingLaunchChannel = details?.notificationResponse?.payload;
    }

    const androidChannel = AndroidNotificationChannel(
      'chat_mentions',
      'Mentions',
      description: 'Notifications when someone mentions you in chat',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(androidChannel);
  }

  void _onResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.isNotEmpty) {
      _tapController.add(payload);
    }
  }

  Future<void> showMentionNotification({
    required String channel,
    required String userName,
    required String message,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'chat_mentions',
      'Mentions',
      channelDescription: 'Notifications when someone mentions you in chat',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final body = message.length > 200
        ? '${message.substring(0, 200)}...'
        : message;

    final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _postedIds.add(id);

    await _plugin.show(
      id,
      '$userName pinged you in #$channel',
      body,
      details,
      payload: channel,
    );
  }

  /// Cancels all mention notifications posted by this service, e.g. when the
  /// app returns to the foreground. Only tracks IDs this service posted, so
  /// the foreground service notification is never affected.
  Future<void> clearMentionNotifications() async {
    for (final id in _postedIds) {
      await _plugin.cancel(id);
    }
    _postedIds.clear();
  }

  void dispose() {
    _tapController.close();
  }
}
