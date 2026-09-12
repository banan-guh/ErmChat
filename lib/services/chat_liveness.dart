import 'dart:async';

import '../client/session.dart';
import '../eventsub/transport/connection.dart';
import '../irc/transport/read.dart';
import '../irc/transport/write.dart';
import '../util/log.dart';
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
    required this.sevenTvClient,
    required this.session,
    required this.twitchAuth,
  });

  final IrcService irc;
  final IrcReadService ircRead;
  final EventSubService eventSub;
  final SevenTvEventClient? sevenTvClient;
  final Session session;
  final TwitchAuth twitchAuth;

  Timer? _watchdogTimer;
  bool _disposed = false;

  /// Anonymous IRC nick: Twitch accepts a justinfan login without credentials.
  String anonymousNick(int seed) =>
      'justinfan${(DateTime.now().millisecondsSinceEpoch + seed) % 80000 + 1000}';

  /// Foreground liveness watchdog: periodically re-arms any socket whose
  /// reconnect loop died without a pending connect (e.g. a fatal-auth break
  /// or a generation bump that wasn't followed by a fresh connect). The
  /// in-socket loop already retries forever on ordinary network drops, so
  /// this only needs to run while the app is in the foreground.
  void startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_disposed) return;
      reconnectIfNecessary();
    });
  }

  /// Brute-force teardown + reconnect of every socket (manual "Reconnect"
  /// button). Unlike [reconnectIfNecessary], it never checks liveness - it
  /// always disconnects and re-establishes the IRC/EventSub/7TV connections.
  void forceReconnect() {
    irc.forceReconnect();
    ircRead.forceReconnect();
    unawaited(eventSub.forceReconnect());
    unawaited(sevenTvClient?.forceReconnect());
  }

  void reconnectIfNecessary() {
    final login = session.login;
    final token = twitchAuth.accessToken;
    final anonymous = login == null || token == null;
    final username = login ?? anonymousNick(1);
    final accessToken = token ?? 'anonymous';

    // A socket can exist while being dead (frozen by the OS during
    // backgrounding). When it looks connected, verify with a PING/PONG
    // round-trip instead of trusting isConnected; force a reconnect if the
    // PONG never comes back.
    if (irc.isConnected) {
      unawaited(
        irc.checkAlive().then((alive) {
          if (!alive) {
            logDebug('[ChatConn] IRC zombie detected - forcing reconnect');
            irc.forceReconnect();
          }
        }),
      );
    } else {
      unawaited(irc.connect(username: username, accessToken: accessToken));
    }
    if (ircRead.isConnected) {
      unawaited(
        ircRead.checkAlive().then((alive) {
          if (!alive) {
            logDebug('[ChatConn] IRC read zombie detected - forcing reconnect');
            ircRead.forceReconnect();
          }
        }),
      );
    } else {
      unawaited(
        ircRead.connect(
          username: anonymous ? anonymousNick(2) : username,
          accessToken: accessToken,
        ),
      );
    }
    // EventSub/7TV have no PING/PONG equivalent, so `isConnected` alone can't
    // spot a zombie socket; a stale session is torn down and re-established.
    if (!eventSub.isConnected || eventSub.isStale) {
      unawaited(eventSub.forceReconnect());
    }
    if (sevenTvClient != null &&
        (!sevenTvClient!.isConnected || sevenTvClient!.isStale)) {
      unawaited(sevenTvClient!.forceReconnect());
    }
  }

  void dispose() {
    _disposed = true;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }
}
