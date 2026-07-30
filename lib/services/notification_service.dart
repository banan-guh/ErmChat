import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final _tapController = StreamController<String>.broadcast();
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
        ? '${message.substring(0, 200)}…'
        : message;

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      '$userName pinged you in #$channel',
      body,
      details,
      payload: channel,
    );
  }

  void dispose() {
    _tapController.close();
  }
}
