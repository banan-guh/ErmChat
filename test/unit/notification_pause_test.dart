import 'package:ermchat/providers/ui_state_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
