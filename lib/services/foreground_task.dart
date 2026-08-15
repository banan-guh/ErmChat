import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(ChatTaskHandler());
}

class ChatTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

Future<void> requestForegroundPermissions() async {
  if (!Platform.isAndroid) return;

  final notificationPermission =
      await FlutterForegroundTask.checkNotificationPermission();
  if (notificationPermission != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }

  if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
}

void initForegroundService() {
  if (!Platform.isAndroid) return;

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'chat_background',
      channelName: 'Chat connection',
      channelDescription: 'Shown while chat stays connected in the background.',
      channelImportance: NotificationChannelImportance.LOW,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

Future<ServiceRequestResult> startForegroundService(
  List<String> channelNames,
) async {
  if (!Platform.isAndroid) return const ServiceRequestSuccess();
  if (channelNames.isEmpty) {
    return const ServiceRequestFailure(error: 'no channels');
  }

  final title = 'g;pr[SomgomgAtYou';
  final text = 'alias of glorpKaraoke';

  if (await FlutterForegroundTask.isRunningService) {
    return FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  return FlutterForegroundTask.startService(
    serviceId: 256,
    notificationTitle: title,
    notificationText: text,
    notificationIcon: null,
    callback: startCallback,
  );
}

Future<ServiceRequestResult> stopForegroundService() async {
  if (!Platform.isAndroid) return const ServiceRequestSuccess();
  if (!(await FlutterForegroundTask.isRunningService)) {
    return const ServiceRequestSuccess();
  }
  return FlutterForegroundTask.stopService();
}
