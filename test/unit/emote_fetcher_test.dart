import 'dart:async';

import 'package:ermchat/models/emote_fetch_tier.dart';
import 'package:ermchat/services/emote_fetcher.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Twitch and 7TV lanes do not wait for the main fetch gate', () {
    fakeAsync((async) {
      final fetcher = EmoteFetcher(
        tier: () => EmoteFetchTier.high,
        isProviderEnabled: (_) => true,
        accessToken: () => null,
        fetchStagger: Duration.zero,
      );
      final holds = List.generate(4, (_) => Completer<void>());
      var held = 0;
      for (final hold in holds) {
        fetcher.enqueue(() {
          held++;
          return hold.future;
        });
      }
      async.elapse(Duration.zero);
      expect(held, 4, reason: 'the main gate is saturated');

      var twitch = false;
      var sevenTv = false;
      fetcher.enqueueTwitch(() async => twitch = true);
      fetcher.enqueueSevenTv(() async => sevenTv = true);
      async.elapse(Duration.zero);
      expect(
        twitch,
        isTrue,
        reason: 'a cached channel must refresh its Twitch emotes at once',
      );
      expect(
        sevenTv,
        isTrue,
        reason: 'a 7TV resync has its own lane and its own bound',
      );

      for (final hold in holds) {
        hold.complete();
      }
      async.flushMicrotasks();
      fetcher.dispose();
      async.flushTimers();
    });
  });
}
