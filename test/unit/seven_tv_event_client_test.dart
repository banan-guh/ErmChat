import 'dart:async';
import 'dart:convert';

import 'package:ermchat/services/seven_tv_event_client.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../helpers/fake_web_socket.dart';

const _hello = '{"op":1,"d":{"heartbeat_interval":30000}}';

class _DropAfterHelloSevenTv extends SevenTvEventClient {
  _DropAfterHelloSevenTv(this.channels);

  final List<FakeWebSocketChannel> channels;
  int openAttempts = 0;

  @override
  Future<WebSocketChannel> openChannel() async {
    openAttempts++;
    final channel = channels[(openAttempts - 1).clamp(0, channels.length - 1)];
    Timer(const Duration(milliseconds: 1), () {
      channel.push(_hello);
      Timer(const Duration(milliseconds: 1), channel.dispose);
    });
    return channel;
  }
}

class _RecordingSevenTv extends SevenTvEventClient {
  _RecordingSevenTv({super.now});

  final channels = <FakeWebSocketChannel>[];
  int get openAttempts => channels.length;

  @override
  Future<WebSocketChannel> openChannel() async {
    final channel = FakeWebSocketChannel();
    channels.add(channel);
    return channel;
  }
}

int _subscriptionFrames(FakeWebSocketChannel channel) =>
    channel.sent.where((line) {
      try {
        return (jsonDecode(line) as Map)['op'] == 35;
      } catch (_) {
        return false;
      }
    }).length;

bool _hasUnsubscribe(FakeWebSocketChannel channel, String objectId) =>
    channel.sent.any((line) {
      try {
        final frame = jsonDecode(line) as Map<String, dynamic>;
        if (frame['op'] != 36) return false;
        final data = frame['d'] as Map<String, dynamic>?;
        final condition = data?['condition'] as Map<String, dynamic>?;
        return condition?['object_id'] == objectId;
      } catch (_) {
        return false;
      }
    });

void main() {
  test('a raw socket is not connected until hello', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv();
      client.connect();
      async.flushMicrotasks();
      expect(
        client.isConnected,
        isFalse,
        reason: 'the websocket upgrade alone is not a 7TV session',
      );
      expect(client.isReconnecting, isTrue);

      client.channels.single.push(_hello);
      async.flushMicrotasks();
      expect(client.isConnected, isTrue);
      client.dispose();
      async.flushTimers();
    });
  });

  test('a rate limit keeps its subscriptions and backoff', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv();
      client.subscribeEmoteSet('set1');
      client.connect();
      async.flushMicrotasks();
      final first = client.channels.single;
      first.push(_hello);
      async.flushMicrotasks();
      expect(_subscriptionFrames(first), 1);

      first.peerClose(code: 4005);
      async.flushMicrotasks();
      expect(client.isRateLimited, isTrue);

      async.elapse(const Duration(seconds: 5));
      expect(
        client.openAttempts,
        1,
        reason: 'the fatal retry must not bypass the rate-limit backoff',
      );

      // Wait out the rate limit, but answer the next hello before its
      // own timeout so only one redial is counted.
      var waited = 5;
      while (client.openAttempts == 1 && waited < 60) {
        async.elapse(const Duration(seconds: 1));
        waited++;
      }
      expect(client.openAttempts, 2);
      final second = client.channels.last;
      second.push(_hello);
      async.flushMicrotasks();
      expect(
        _subscriptionFrames(second),
        1,
        reason: 'a rate limit must not drop a live subscription',
      );
      client.dispose();
      async.flushTimers();
    });
  });

  test('a drop right after hello backs off exponentially', () {
    fakeAsync((async) {
      final channels = List.generate(20, (_) => FakeWebSocketChannel());
      final client = _DropAfterHelloSevenTv(channels);
      client.connect();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 15));
      // Hello currently resets the failure counter, so the loop redials
      // about once per second. A socket that dies right after hello should
      // back off 1s, 2s, 4s, 8s.
      expect(client.openAttempts, lessThanOrEqualTo(6));
      client.dispose();
      async.flushTimers();
    });
  });

  test('a socket that never sends hello is replaced', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv();
      client.connect();
      async.flushMicrotasks();
      expect(client.openAttempts, 1);

      async.elapse(const Duration(seconds: 15));
      expect(
        client.openAttempts,
        greaterThan(1),
        reason: 'a half-open upgrade must not stay connected forever',
      );
      client.dispose();
      async.flushTimers();
    });
  });

  test('a server reconnect request does not spin the loop', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv();
      client.connect();
      async.flushMicrotasks();

      var drives = 0;
      while (client.openAttempts < 20 && drives++ < 40) {
        final channel = client.channels.last;
        channel.push(_hello);
        async.flushMicrotasks();
        channel.push('{"op":4,"d":{}}');
        async.flushMicrotasks();
      }
      async.elapse(const Duration(seconds: 1));
      expect(
        client.openAttempts,
        lessThanOrEqualTo(5),
        reason: 'a reconnect storm must be paced, not dialed at network speed',
      );
      client.dispose();
      async.flushTimers();
    });
  });

  test('a fatal close recovers without waiting for the watchdog', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv();
      client.connect();
      async.flushMicrotasks();
      final channel = client.channels.single;
      channel.push(_hello);
      async.flushMicrotasks();
      channel.peerClose(code: 4010);
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 5));
      expect(
        client.openAttempts,
        greaterThan(1),
        reason: 'one bad object must not leave the whole feed dead for 30s',
      );
      client.dispose();
      async.flushTimers();
    });
  });

  test('a long session does not replay every historical emote set', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv();
      for (var i = 0; i < 200; i++) {
        client.subscribeEmoteSet('set$i');
      }
      client.connect();
      async.flushMicrotasks();
      final first = client.channels.single;
      first.push(_hello);
      async.flushMicrotasks();
      expect(
        _subscriptionFrames(first),
        lessThanOrEqualTo(100),
        reason: 'a long session must cap what it subscribes to',
      );

      first.peerClose();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      final second = client.channels.last;
      second.push(_hello);
      async.flushMicrotasks();
      expect(
        _subscriptionFrames(second),
        lessThanOrEqualTo(100),
        reason: 'reconnect must not replay every personal set ever seen',
      );
      client.dispose();
      async.flushTimers();
    });
  });

  test('a failed subscription write does not drop the rest of the batch', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv();
      client.subscribeEmoteSet('a');
      client.subscribeEmoteSet('b');
      client.connect();
      async.flushMicrotasks();
      final channel = client.channels.single;
      channel.failNextWrite();
      channel.push(_hello);
      async.flushMicrotasks();

      expect(
        _subscriptionFrames(channel),
        2,
        reason: 'one failed write must not abandon the remaining subscriptions',
      );
      client.dispose();
      async.flushTimers();
    });
  });

  test('hello subscription_limit caps subscriptions per connection', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv();
      client.subscribeEmoteSet('set1');
      client.subscribeEmoteSet('set2');
      client.subscribeEmoteSet('set3');
      client.connect();
      async.flushMicrotasks();
      final channel = client.channels.single;
      channel.push(
        jsonEncode({
          'op': 1,
          'd': {'heartbeat_interval': 30000, 'subscription_limit': 2},
        }),
      );
      async.flushMicrotasks();
      expect(client.subscriptionLimit, 2);
      expect(_subscriptionFrames(channel), 2);
      expect(client.subscriptionSentCount, 2);
      expect(
        client.intendedSubscriptionCount,
        3,
        reason: 'the third set is still wanted but could not be sent',
      );
      expect(client.missingSubscriptionCount, 1);

      client.subscribeEmoteSet('set4');
      expect(
        _subscriptionFrames(channel),
        2,
        reason: 'the cap must drop subscriptions past the limit',
      );

      client.unsubscribeEmoteSet('set1');
      client.subscribeEmoteSet('set5');
      expect(
        _subscriptionFrames(channel),
        3,
        reason: 'an unsubscribe frees its slot for the next subscription',
      );
      client.dispose();
      async.flushTimers();
    });
  });

  test('the foreign set cap reports the dropped set', () {
    final client = SevenTvEventClient();
    for (var i = 0; i <= 50; i++) {
      client.subscribeEmoteSet('set$i');
    }
    expect(
      client.pendingSetsOverflowed,
      isTrue,
      reason: 'the foreign cap drops the oldest set',
    );
    expect(client.intendedSubscriptionCount, 50);
    client.dispose();
  });

  test(
    'protected sets survive LRU eviction and eviction unsubscribes live',
    () {
      fakeAsync((async) {
        final client = _RecordingSevenTv(now: clock.now);
        client.subscribeEmoteSet(
          'channel-set',
          owner: SevenTvEmoteSetOwner.channel('ch'),
        );
        client.subscribeEmoteSet(
          'viewer-set',
          owner: SevenTvEmoteSetOwner.viewer('v1'),
        );
        for (var i = 0; i < 50; i++) {
          client.subscribeEmoteSet('foreign-$i');
        }
        client.connect();
        async.flushMicrotasks();
        final first = client.channels.single;
        first.push(_hello);
        async.flushMicrotasks();
        expect(client.intendedSubscriptionCount, 52);
        expect(_subscriptionFrames(first), 52);

        // A repeat refreshes age, so the next foreign set evicts foreign-1.
        client.subscribeEmoteSet('foreign-0');
        client.subscribeEmoteSet('foreign-50');
        expect(client.intendedSubscriptionCount, 52);
        expect(client.hasEmoteSetSubscription('foreign-0'), isTrue);
        expect(client.hasEmoteSetSubscription('foreign-1'), isFalse);
        expect(_hasUnsubscribe(first, 'foreign-1'), isTrue);
        expect(client.hasEmoteSetSubscription('channel-set'), isTrue);
        expect(client.hasEmoteSetSubscription('viewer-set'), isTrue);
        client.dispose();
        async.flushTimers();
      });
    },
  );

  test('first connect and clean server reconnect carry no gap', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv(now: clock.now);
      client.connect();
      async.flushMicrotasks();
      final first = client.channels.single;
      first.push(_hello);
      async.flushMicrotasks();
      expect(client.takeMissedEventGap(), isFalse);

      first.push(jsonEncode({'op': 4, 'd': {}}));
      async.flushMicrotasks();
      while (client.openAttempts < 2) {
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
      }
      client.channels.last.push(_hello);
      async.flushMicrotasks();
      expect(
        client.takeMissedEventGap(),
        isFalse,
        reason: 'a server handoff is not a missed-event gap',
      );
      client.dispose();
      async.flushTimers();
    });
  });

  test('a long dirty gap asks for reconciliation', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv(now: clock.now);
      client.connect();
      async.flushMicrotasks();
      client.channels.single.push(_hello);
      async.flushMicrotasks();
      client.channels.single.peerClose();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();
      expect(client.openAttempts, greaterThan(1));
      client.channels.last.push(_hello);
      async.flushMicrotasks();
      expect(client.takeMissedEventGap(), isTrue);
      client.dispose();
      async.flushTimers();
    });
  });

  test('a skipped subscription survives a short clean reconnect', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv(now: clock.now);
      client.subscribeEmoteSet('set1');
      client.subscribeEmoteSet('set2');
      client.connect();
      async.flushMicrotasks();
      client.channels.single.push(
        jsonEncode({
          'op': 1,
          'd': {'heartbeat_interval': 30000, 'subscription_limit': 1},
        }),
      );
      async.flushMicrotasks();
      client.channels.single.peerClose();
      async.flushMicrotasks();
      while (client.openAttempts < 2) {
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
      }
      client.channels.last.push(_hello);
      async.flushMicrotasks();
      final interrupted = client.takeInterruptedEmoteSetIds();
      expect(interrupted, contains('set2'));
      expect(client.takeMissedEventGap(), isTrue);
      client.dispose();
      async.flushTimers();
    });
  });
}
