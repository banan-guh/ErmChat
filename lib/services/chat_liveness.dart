import 'dart:async';

import '../client/session.dart';
import '../eventsub/transport/connection.dart';
import '../irc/transport/read.dart';
import '../irc/transport/write.dart';
import '../util/log.dart';
import 'pubsub_service.dart';
import 'seven_tv_event_client.dart';
import 'twitch_auth.dart';

/// Foreground socket liveness: the reconnect watchdog, the manual and
/// automatic reconnect paths, and the anonymous nick generator. Split from
/// connect orchestration because it reacts to socket health, not credentials.
class ChatLiveness {
  ChatLiveness({
    required this.irc,
    required this.ircRead,
    required this.eventSub,
    this.pubSub,
    required this.sevenTvClient,
    required this.session,
    required this.twitchAuth,
  });

  final IrcService irc;
  final IrcReadService ircRead;
  final EventSubService eventSub;
  final PubSubService? pubSub;
  final SevenTvEventClient? sevenTvClient;
  final Session session;
  final TwitchAuth twitchAuth;

  Timer? _watchdogTimer;
  bool _disposed = false;

  /// Anonymous IRC nick: Twitch accepts a justinfan login without credentials.
  String anonymousNick(int seed) =>
      'justinfan${(DateTime.now().millisecondsSinceEpoch + seed) % 80000 + 1000}';

  /// Foreground liveness watchdog: periodically re-arms any socket no loop
  /// is retrying (a fatal stop, a socket never started) and tears down
  /// stale ones. Each socket's loop already retries forever on ordinary
  /// drops, so this only needs to run while the app is in the foreground.
  void startWatchdog() {
    _watchdogTimer?.cancel();
    // No probe here: each IRC socket's own 60s keepalive already catches a
    // dead peer, and a second PING every 30s would triple idle traffic.
    _watchdogTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_disposed) return;
      reconnectIfNecessary(probe: false);
    });
  }

  /// Brute-force teardown + reconnect of every socket (manual "Reconnect"
  /// button). Unlike [reconnectIfNecessary], it never checks liveness - it
  /// always disconnects and re-establishes the IRC/EventSub/7TV connections.
  void forceReconnect() {
    irc.forceReconnect();
    ircRead.forceReconnect();
    unawaited(eventSub.forceReconnect());
    unawaited(pubSub?.forceReconnect());
    unawaited(sevenTvClient?.forceReconnect());
  }

  /// Reconnects whatever is down. With [probe] (a resume, where the OS may
  /// have frozen sockets), a socket that looks connected must also answer a
  /// PING, and one waiting out a backoff dials at once. Without it (the
  /// watchdog), a socket its loop is already retrying is left alone.
  void reconnectIfNecessary({bool probe = true}) {
    bool needsDial(bool connected, bool reconnecting) =>
        !connected && (probe || !reconnecting);

    final login = session.login;
    final token = twitchAuth.accessToken;
    final anonymous = login == null || token == null;
    final username = login ?? anonymousNick(1);
    final accessToken = token ?? 'anonymous';

    // A socket can exist while being dead (frozen by the OS during
    // backgrounding). When it looks connected, verify with a PING/PONG
    // round-trip instead of trusting isConnected; force a reconnect if the
    // PONG never comes back.
    if (needsDial(irc.isConnected, irc.isReconnecting)) {
      unawaited(irc.connect(username: username, accessToken: accessToken));
    } else if (irc.isConnected && probe) {
      unawaited(
        irc.checkAlive().then((alive) {
          if (!alive) {
            logDebug('[ChatConn] IRC zombie detected - forcing reconnect');
            irc.forceReconnect();
          }
        }),
      );
    }
    if (needsDial(ircRead.isConnected, ircRead.isReconnecting)) {
      unawaited(
        ircRead.connect(
          username: anonymous ? anonymousNick(2) : username,
          accessToken: accessToken,
          // The proxy rejects anonymous nicks.
          useProxy: !anonymous,
        ),
      );
    } else if (ircRead.isConnected && probe) {
      unawaited(
        ircRead.checkAlive().then((alive) {
          if (!alive) {
            logDebug('[ChatConn] IRC read zombie detected - forcing reconnect');
            ircRead.forceReconnect();
          }
        }),
      );
    }
    // EventSub/7TV have no PING/PONG equivalent, so `isConnected` alone can't
    // spot a zombie socket; a stale session is torn down and re-established.
    if (needsDial(eventSub.isConnected, eventSub.isReconnecting) ||
        eventSub.isStale) {
      unawaited(eventSub.forceReconnect());
    }
    final points = pubSub;
    if (points != null &&
        (needsDial(points.isConnected, points.isReconnecting) ||
            points.isStale)) {
      unawaited(points.forceReconnect());
    }
    final sevenTv = sevenTvClient;
    if (sevenTv != null &&
        (needsDial(sevenTv.isConnected, sevenTv.isReconnecting) ||
            sevenTv.isStale)) {
      unawaited(sevenTv.forceReconnect());
    }
  }

  void dispose() {
    _disposed = true;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }
}
