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
}
