import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:ermchat/services/connectivity_service.dart';
import 'package:ermchat/services/twitch_irc.dart';
import '../helpers/fake_web_socket.dart';

class _TestService extends IrcService {
  _TestService(this.channels, {this.onOpen, super.connectivityService});

  final List<FakeWebSocketChannel> channels;
  final void Function()? onOpen;
  int openAttempts = 0;

  @override
  Future<WebSocketChannel> openChannel() async {
    openAttempts++;
    onOpen?.call();
    final idx = (openAttempts - 1).clamp(0, channels.length - 1);
    return channels[idx];
  }
}

void main() {
  group('reconnect backoff', () {
    test('delays grow 1s, 2s, 4s, then cap at 8s and never give up', () {
      fakeAsync((async) {
        final times = <Duration>[];
        final service = _TestService(
          List.generate(12, (_) => FakeWebSocketChannel(failReady: true)),
          onOpen: () => times.add(async.elapsed),
        );
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(times, hasLength(1));

        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(times.length, greaterThanOrEqualTo(6), reason: 'keeps retrying');

        final gaps = [
          for (var i = 1; i < times.length; i++) times[i] - times[i - 1],
        ];
        // 1s, 2s, 4s, then 8s (all with ±25% jitter).
        expect(gaps[0].inMilliseconds, inInclusiveRange(700, 1300));
        expect(gaps[1].inMilliseconds, inInclusiveRange(1400, 2600));
        expect(gaps[2].inMilliseconds, inInclusiveRange(2800, 5200));
        expect(gaps[3].inMilliseconds, inInclusiveRange(5600, 10400));
        expect(
          gaps[4].inMilliseconds,
          inInclusiveRange(5600, 10400),
          reason: 'capped at 8s',
        );

        // Never gives up: keeps retrying long after the old 8-attempt cap.
        async.elapse(const Duration(seconds: 60));
        expect(times.length, greaterThan(8));

        service.dispose();
      });
    });

    test('success resets the counter (next failure retries at ~1s)', () {
      fakeAsync((async) {
        final service = _TestService([
          FakeWebSocketChannel(failReady: true),
          FakeWebSocketChannel(failReady: true),
          FakeWebSocketChannel(failReady: true),
          FakeWebSocketChannel(),
        ]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        async.elapse(const Duration(milliseconds: 1250));
        expect(service.openAttempts, 2);
        async.elapse(const Duration(milliseconds: 2600));
        expect(service.openAttempts, 3);
        // 4th attempt succeeds.
        async.elapse(const Duration(milliseconds: 5200));
        expect(service.openAttempts, 4);
        expect(statuses, contains(IrcConnectionStatus.connected));

        // Kill the healthy socket: next retry is ~1s, not 8s.
        final channel = service.channels.last;
        channel.failNow();
        async.flushMicrotasks();
        expect(statuses, contains(IrcConnectionStatus.disconnected));
        async.elapse(const Duration(milliseconds: 1250));
        expect(service.openAttempts, 5);

        service.dispose();
        channel.dispose();
      });
    });

    test('a failed connect does not leave a zombie socket behind', () {
      fakeAsync((async) {
        final service = _TestService([FakeWebSocketChannel(failReady: true)]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(
          service.isConnected,
          isFalse,
          reason: 'failed handshake must not look connected',
        );

        async.elapse(const Duration(milliseconds: 1250));
        expect(
          service.openAttempts,
          2,
          reason: 'reconnect must not bail on the stale socket',
        );

        service.dispose();
      });
    });
  });

  group('PING/PONG keepalive', () {
    test('sends keepalive PING and reconnects when no PONG arrives', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(service.openAttempts, 1);

        // Tick 1 (~60s): sends a keepalive PING.
        async.elapse(const Duration(seconds: 61));
        expect(channel.sent, contains('PING :keepalive'));
        expect(statuses, isNot(contains(IrcConnectionStatus.disconnected)));

        // The dedicated PONG timer (30s) reconnects without waiting for the
        // next keepalive tick.
        async.elapse(const Duration(seconds: 31));
        expect(statuses, contains(IrcConnectionStatus.disconnected));
        async.elapse(const Duration(milliseconds: 1250));
        expect(service.openAttempts, 2);

        service.dispose();
        channel.dispose();
      });
    });

    test('PONG within the pong window keeps the connection alive', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 61));
        expect(channel.sent, contains('PING :keepalive'));

        channel.push('PONG :keepalive');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 31));
        expect(statuses, isNot(contains(IrcConnectionStatus.disconnected)));

        service.dispose();
        channel.dispose();
      });
    });

    test('incoming PONG clears awaitingPong', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        service.awaitingPong = true;
        channel.push('PONG :tmi.twitch.tv');
        async.flushMicrotasks();
        expect(service.awaitingPong, isFalse);

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('RECONNECT command', () {
    test('reconnects when the server asks for it', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(service.openAttempts, 1);

        service.handleLine(':tmi.twitch.tv RECONNECT');
        async.flushMicrotasks();
        expect(statuses, contains(IrcConnectionStatus.disconnected));
        async.elapse(const Duration(milliseconds: 1250));
        expect(service.openAttempts, 2);

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('checkAlive', () {
    test('returns true when a PONG echoes the probe token', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        bool? result;
        service.checkAlive().then((value) => result = value);
        async.flushMicrotasks();
        expect(channel.sent, contains('PING :alive-check-0'));
        expect(result, isNull);

        channel.push(':tmi.twitch.tv PONG tmi.twitch.tv :alive-check-0');
        async.flushMicrotasks();
        expect(result, isTrue);

        service.dispose();
        channel.dispose();
      });
    });

    test('a stale keepalive PONG does not satisfy an in-flight probe', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        bool? result;
        service.checkAlive().then((value) => result = value);
        async.flushMicrotasks();

        // A PONG left over from a keepalive PING (or Twitch's bare-ping
        // answer) must not be mistaken for a response to the probe.
        channel.push('PONG :tmi.twitch.tv');
        async.flushMicrotasks();
        expect(result, isNull);

        channel.push(':tmi.twitch.tv PONG tmi.twitch.tv :alive-check-0');
        async.flushMicrotasks();
        expect(result, isTrue);

        service.dispose();
        channel.dispose();
      });
    });

    test('returns false on timeout when no PONG arrives', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        bool? result;
        service.checkAlive().then((value) => result = value);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(result, isFalse);

        service.dispose();
        channel.dispose();
      });
    });

    test('returns false when there is no socket', () async {
      final service = _TestService([FakeWebSocketChannel()]);
      expect(await service.checkAlive(), isFalse);
      service.dispose();
    });
  });

  group('forceReconnect', () {
    test('closes the zombie socket and reconnects immediately', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(service.openAttempts, 1);

        service.forceReconnect();
        async.flushMicrotasks();
        expect(statuses, contains(IrcConnectionStatus.disconnected));
        // The loop restarts right away (no backoff) on a fresh generation.
        expect(service.openAttempts, 2);
        expect(service.isConnected, isTrue);

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('disconnect status clears the socket first', () {
    // The type bar hint renders the "connected" state whenever isConnected is
    // true at rebuild time. Every disconnect path must therefore null the
    // socket BEFORE emitting `disconnected`, or the hint flickers to
    // "connected" for a frame during a disconnect (disconnect -> connect ->
    // disconnect).
    void expectDisconnectedWithSocketCleared(
      void Function(FakeAsync async, _TestService service) trigger,
    ) {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        final connectedAtDisconnect = <bool>[];
        service.onStatus.listen((s) {
          if (s == IrcConnectionStatus.disconnected) {
            connectedAtDisconnect.add(service.isConnected);
          }
        });
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        trigger(async, service);
        async.flushMicrotasks();

        expect(connectedAtDisconnect, isNotEmpty);
        expect(
          connectedAtDisconnect,
          everyElement(isFalse),
          reason: 'type bar must not read "connected" when disconnect fires',
        );

        service.dispose();
        channel.dispose();
      });
    }

    test('stream error', () {
      expectDisconnectedWithSocketCleared((_, service) {
        service.channels.last.failNow();
      });
    });

    test('RECONNECT command', () {
      expectDisconnectedWithSocketCleared((_, service) {
        service.handleLine(':tmi.twitch.tv RECONNECT');
      });
    });

    test('PONG timeout', () {
      expectDisconnectedWithSocketCleared((async, _) {
        async.elapse(const Duration(seconds: 61));
        async.elapse(const Duration(seconds: 31));
      });
    });

    test('forceReconnect', () {
      expectDisconnectedWithSocketCleared((_, service) {
        service.forceReconnect();
      });
    });
  });

  group('handshake does not report connected early', () {
    test('isConnected stays false while the handshake is pending', () {
      fakeAsync((async) {
        final ready = Completer<void>();
        final channel = FakeWebSocketChannel(readyCompleter: ready);
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        // openChannel resolved and assigned nothing yet: the handshake is
        // still in flight, so the socket must not look connected yet.
        expect(
          service.isConnected,
          isFalse,
          reason: 'type bar hint must not flip to connected mid-handshake',
        );

        ready.complete();
        async.flushMicrotasks();
        expect(service.isConnected, isTrue);

        service.dispose();
        channel.dispose();
      });
    });

    test('a hung handshake times out, releases the lock and retries', () {
      fakeAsync((async) {
        final ready = Completer<void>();
        final hanging = FakeWebSocketChannel(readyCompleter: ready);
        final service = _TestService([hanging, FakeWebSocketChannel()]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(service.openAttempts, 1);

        // The handshake never completes; the 10s connect timeout fails the
        // attempt cleanly instead of hanging `_connecting` forever.
        async.elapse(const Duration(seconds: 11));
        expect(statuses, contains(IrcConnectionStatus.disconnected));

        async.elapse(const Duration(milliseconds: 1250));
        expect(service.openAttempts, 2);
        expect(
          service.isConnected,
          isTrue,
          reason: 'the next attempt connects because the lock was released',
        );

        service.dispose();
        hanging.dispose();
      });
    });
  });

  group('JOIN rate limiting', () {
    test('JOINs are batched at the tick rate, not fired in a burst', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        // 25 channels exceed the per-tick burst cap.
        for (var i = 0; i < 25; i++) {
          service.join('c$i');
        }
        async.flushMicrotasks();

        List<String> joins() =>
            channel.sent.where((l) => l.startsWith('JOIN')).toList();

        // First flush sends up to the burst cap immediately...
        expect(joins(), hasLength(20));
        // ...the rest wait for the next tick.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(joins(), hasLength(25));

        service.dispose();
        channel.dispose();
      });
    });

    test('a duplicate join is not queued twice', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        service.join('abc');
        service.join('abc');
        async.flushMicrotasks();

        final joins = channel.sent.where((l) => l == 'JOIN #abc').toList();
        expect(joins, hasLength(1));

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('ROOMSTATE rejoin sweep', () {
    test('re-sends unconfirmed JOINs and stops once confirmed', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        service.join('abc');
        async.flushMicrotasks();
        List<String> joins() =>
            channel.sent.where((l) => l == 'JOIN #abc').toList();
        expect(joins(), hasLength(1));

        // No ROOMSTATE echoed: the sweep re-JOINs after the confirm window.
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(joins(), hasLength(2));

        // ROOMSTATE confirms the JOIN: the sweep stops re-sending.
        channel.push('@room-id=1 :tmi.twitch.tv ROOMSTATE #abc');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 22));
        async.flushMicrotasks();
        expect(
          joins(),
          hasLength(2),
          reason: 'a confirmed channel is never re-sent',
        );

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('connectivity accelerator', () {
    test('coming back online wakes the backoff sleep early', () {
      fakeAsync((async) {
        final conn = ConnectivityService();
        conn.debugSetResults(const [ConnectivityResult.none]);
        final times = <Duration>[];
        final service = _TestService(
          [FakeWebSocketChannel(failReady: true)],
          connectivityService: conn,
          onOpen: () => times.add(async.elapsed),
        );
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(times, hasLength(1));

        // Still offline: the next attempt waits on the backoff timer.
        async.elapse(const Duration(milliseconds: 200));
        expect(times, hasLength(1));

        // Back online: the sleep is woken immediately and the retry fires now.
        conn.debugSetResults(const [ConnectivityResult.wifi]);
        async.flushMicrotasks();
        expect(times, hasLength(2));
        expect(
          times[1],
          lessThan(const Duration(milliseconds: 900)),
          reason: 'the backoff wait must be shortened, not run out',
        );

        service.dispose();
        conn.dispose();
      });
    });

    test('an offline blip does not stop the retry loop (no gate)', () {
      fakeAsync((async) {
        final conn = ConnectivityService();
        conn.debugSetResults(const [ConnectivityResult.none]);
        final times = <Duration>[];
        final service = _TestService(
          [FakeWebSocketChannel(failReady: true)],
          connectivityService: conn,
          onOpen: () => times.add(async.elapsed),
        );
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        // Even fully offline, the loop keeps retrying on its own schedule.
        async.elapse(const Duration(seconds: 30));
        expect(times.length, greaterThanOrEqualTo(4));

        service.dispose();
        conn.dispose();
      });
    });
  });
}
