import 'package:ermchat/models/highlight_state.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/providers/feature_providers.dart';
import 'package:ermchat/providers/ui_state_providers.dart';
import 'package:ermchat/services/notification_service.dart';
import 'package:ermchat/util/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNotifications extends NotificationService {
  final channels = <String>[];

  @override
  Future<void> showMentionNotification({
    required String channel,
    required String userName,
    required String message,
  }) async => channels.add(channel);
}

void main() {
  test('foreground mentions notify when opted in and off-screen', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = _FakeNotifications();
    final container = ProviderContainer(
      overrides: [notificationServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.read(mentionPushProvider.notifier).set(true);
    container.read(selectedChannelProvider.notifier).set('viewed');
    var n = 0;
    void ping(String channel) => container
        .read(mentionNotifierProvider)
        .handle(
          channel,
          TwitchMessage(login: 'a', text: 'hi', messageId: 'm${n++}')
            ..highlight = const HighlightState(
              types: {HighlightType.username},
              notify: true,
            ),
        );

    ping('other');
    expect(fake.channels, isEmpty, reason: 'foreground pref off');

    await Settings.mentionNotifyForeground.set(true);
    ping('Viewed');
    expect(fake.channels, isEmpty, reason: 'channel already on screen');
    ping('other');
    expect(fake.channels, ['other']);
  });

  // A mute that never ends silences notifications for good, quietly.
  test('a mute ends on its own or when unmuted', () {
    SharedPreferences.setMockInitialValues({});
    var now = DateTime.utc(2026, 10, 3, 22);
    final container = ProviderContainer(
      overrides: [
        notificationPauseProvider.overrideWith(
          () => NotificationPauseNotifier(now: () => now),
        ),
      ],
    );
    addTearDown(container.dispose);
    final pause = container.read(notificationPauseProvider.notifier);

    pause.pauseFor(const Duration(hours: 1));
    now = now.add(const Duration(minutes: 59));
    expect(pause.paused, isTrue);
    now = now.add(const Duration(minutes: 1));
    expect(pause.paused, isFalse, reason: 'hour is up');

    pause.pauseFor(const Duration(hours: 8));
    pause.resume();
    expect(pause.paused, isFalse, reason: 'unmuted early');

    final expired = now.subtract(const Duration(minutes: 1));
    pause.restore(expired.millisecondsSinceEpoch);
    expect(
      container.read(notificationPauseProvider),
      isNull,
      reason: 'pause ran out while the app was closed',
    );
  });
}
