import 'package:ermchat/services/seven_tv_event_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a rate limit waits and reads as reconnecting', () {
    fakeAsync((async) {
      final client = SevenTvEventClient();
      client.enterRateLimitForTest();
      expect(
        client.isRateLimited,
        isTrue,
        reason: 'the watchdog must leave the cooldown alone',
      );
      expect(client.isReconnecting, isTrue);
      client.dispose();
      async.flushTimers();
    });
  });
}
