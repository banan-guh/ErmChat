import 'dart:async';
import 'dart:convert';

import 'package:ermchat/services/seven_tv_event_client.dart';
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

  test('a fatal close keeps pending subscriptions', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv();
      client.subscribeEmoteSet('set1');
      client.connect();
      async.flushMicrotasks();
      final first = client.channels.single;
      first.push(_hello);
      async.flushMicrotasks();
      first.peerClose(code: 4010);
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 3));
      final second = client.channels.last;
      second.push(_hello);
      async.flushMicrotasks();
      expect(
        _subscriptionFrames(second),
        1,
        reason: 'reconnecting must replay what the client asked for',
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

  test('an ack marks a subscription acknowledged', () {
    fakeAsync((async) {
      final client = _RecordingSevenTv();
      client.subscribeEmoteSet('set1');
      client.connect();
      async.flushMicrotasks();
      final channel = client.channels.single;
      channel.push(_hello);
      async.flushMicrotasks();
      expect(client.subscriptionSentCount, 1);
      expect(client.pendingSubscriptionAcks, 1);

      channel.push(
        jsonEncode({
          'op': 5,
          'd': {
            'command': 'SUBSCRIBE',
            'data': {
              'type': 'emote_set.update',
              'condition': {'object_id': 'set1'},
            },
          },
        }),
      );
      async.flushMicrotasks();
      expect(
        client.subscriptionAckCount,
        1,
        reason: 'the echoed condition identifies the subscription',
      );
      expect(client.pendingSubscriptionAcks, 0);
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

  test('the pending set cap reports the dropped channel', () {
    final client = SevenTvEventClient();
    for (var i = 0; i <= 50; i++) {
      client.subscribeEmoteSet('set$i');
    }
    expect(
      client.pendingSetsOverflowed,
      isTrue,
      reason: 'a reconnect cannot restore the set the cap dropped',
    );
    expect(client.intendedSubscriptionCount, 50);
    client.dispose();
  });

  test('a dispatch records lastDispatch', () {
    var now = DateTime(2026, 1, 1, 12);
    final client = SevenTvEventClient(now: () => now);
    expect(client.lastDispatch, isNull);

    client.handleRawMessage({
      'op': 0,
      'd': {
        'type': 'emote_set.update',
        'body': {'id': 'set1'},
      },
    });
    expect(client.lastDispatch, now);

    now = now.add(const Duration(minutes: 2));
    client.handleRawMessage({
      'op': 0,
      'd': {'type': 'unknown'},
    });
    expect(client.lastDispatch, now);
    client.dispose();
  });
}
