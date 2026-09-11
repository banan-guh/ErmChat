import 'dart:async';

import 'package:flutter/widgets.dart';

import '../chat/chat.dart';
import '../client/session.dart';
import '../eventsub/topics.dart';
import '../eventsub/transport/connection.dart';
import '../eventsub/transport/events.dart';
import '../irc/transport/events.dart';
import '../irc/transport/read.dart';
import '../irc/transport/write.dart';
import '../services/chat_channel_setup.dart';
import '../services/chat_readiness.dart';
import '../services/chat_sender.dart';
import '../services/join_progress_tracker.dart';
import '../services/seven_tv_event_client.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_oauth.dart';
import '../util/log.dart';

/// Connection lifecycle: connect orchestration, socket status listeners,
/// watchdog, reconnect, token expiry and identity resolution.
class ChatLifecycle {
  ChatLifecycle({
    required this.irc,
    required this.ircRead,
    required this.eventSub,
    required this.sevenTvClient,
    required this.twitchApi,
    required this.twitchAuth,
    required this.session,
    required this.chat,
    required this.readiness,
    required this.joinProgress,
    required this.eventSubTopics,
    required this.sender,
    required this.channelSetup,
    required this.connectionStateNotifier,
    required this.setupSubscriptions,
    required this.subscribeAll,
    required this.clearSelfBadges,
    required this.onSystemMessage,
    required this.onBanner,
    required this.onReconnected,
  });

  final IrcService irc;
  final IrcReadService ircRead;
  final EventSubService eventSub;
  final SevenTvEventClient? sevenTvClient;
  final TwitchApi twitchApi;
  final TwitchAuth twitchAuth;
  final Session session;
  final Chat chat;
  final ChatReadiness readiness;
  final JoinProgressTracker joinProgress;
  final EventSubTopics eventSubTopics;
  final ChatSender sender;
  final ChatChannelSetup channelSetup;
  final ValueNotifier<int> connectionStateNotifier;
  final void Function() setupSubscriptions;
  final void Function() subscribeAll;
  final void Function() clearSelfBadges;
  final void Function(
    String channel,
    String text, {
    Color? accent,
    String? messageId,
  })
  onSystemMessage;
  final void Function(String message)? onBanner;
  final VoidCallback? onReconnected;

  bool _wasConnected = false;
  bool _wasDisconnected = false;
  // Guards the one-shot read-connect waiter below: connect() re-runs on
  // every auth change, and each call must not stack another broadcast
  // listener while the read socket stays down.
  bool _readConnectWaiterArmed = false;
  DateTime? _lastSubscribeAll;
  // Credentials the IRC sockets were last told to use. Compared against the
  // desired account on connect() so an account switch tears the sockets down
  // (an already-connected socket otherwise skips the reconnect).
  String? _lastIrcUsername;
  String? _lastIrcToken;
  bool _isConnecting = false;
  // Set when a connect() call is dropped by the re-entrancy guard above (e.g.
  // a login landing while a startup connect is still in-flight). Drained at
  // the end of the in-flight connect so the dropped credentials are honored.
  bool _connectRetryRequested = false;
  // Expired-token handling: deduplicates the global expiry message and tracks
  // the last anonymous-vs-authed state so the sockets actually tear down when
  // expiry flips us from authed to anonymous mid-session.
  bool _expiryHandled = false;
  bool _lastIrcAnonymous = true;
  String? _lastValidatedToken;
  bool _disposed = false;

  StreamSubscription<EventSubStatus>? statusSub;
  StreamSubscription<IrcConnectionStatus>? ircStatusSub;
  StreamSubscription<IrcConnectionStatus>? ircReadStatusSub;
  StreamSubscription<void>? ircAuthFailedSub;
  StreamSubscription<void>? ircReadAuthFailedSub;
  Timer? _watchdogTimer;

  Future<Map<String, dynamic>?>? _currentUserFetch;

  /// Whether the read socket participates in readiness gating: yes for
  /// authenticated sessions, no for anonymous read-only sessions.
  bool get readExpected => !_lastIrcAnonymous;

  void dispose() {
    _disposed = true;
    statusSub?.cancel();
    ircStatusSub?.cancel();
    ircReadStatusSub?.cancel();
    ircAuthFailedSub?.cancel();
    ircReadAuthFailedSub?.cancel();
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  Future<Map<String, dynamic>?> ensureCurrentUser(TwitchAuth auth) {
    return _currentUserFetch ??= () {
      // Attribute the resolution to the credential it was made with so a
      // late result landing after an account switch is discarded (setUser).
      final tokenAtStart = auth.accessToken;
      return twitchApi
          .getCurrentUser(auth)
          .then((user) {
            if (user != null) {
              auth.setUser(
                user['login'],
                user['id'],
                profileImageUrl: user['profile_image_url'],
                resolvedWithToken: tokenAtStart,
              );
            }
            return user;
          })
          .whenComplete(() => _currentUserFetch = null);
    }();
  }

  Future<void> connect() async {
    if (_disposed) return;
    if (_isConnecting) {
      _connectRetryRequested = true;
      return;
    }
    _isConnecting = true;
    try {
      final auth = twitchAuth;

      setupSubscriptions();
      joinProgress.ensureTicker();
      _startWatchdog();

      sevenTvClient?.connect();

      // EventSub session lifecycle: subscriptions are session-scoped, so drop
      // moderation-channel state when the session dies (IRC fallback resumes)
      // and re-subscribe when a new session comes up (session_reconnect or
      // keepalive reconnect) - otherwise moderation and the broadcaster
      // widgets stay dead until the next IRC reconnect.
      statusSub?.cancel();
      statusSub = eventSub.onStatus.listen((status) {
        if (_disposed) return;
        if (status == EventSubStatus.disconnected ||
            status == EventSubStatus.connecting) {
          // Connecting clears too: session_reconnect/keepalive paths replace
          // the session inside connect() without emitting disconnected, so
          // without this the stale active sets would skip every resubscribe
          // on the new session (subs are session-scoped and die with it).
          eventSubTopics.clearSessionState();
        } else if (status == EventSubStatus.connected) {
          eventSubTopics.resubscribeEventSubChannels(chat.names);
        }
      });

      ircStatusSub?.cancel();
      ircStatusSub = irc.onStatus.listen((status) async {
        if (_disposed) return;
        connectionStateNotifier.value++;
        if (status == IrcConnectionStatus.connected && irc.isConnected) {
          readiness.noteWriteSocketConnected();
          // Edge-triggered: subscribeAll once per connect with 30s throttle.
          // The 500ms settle delay only applies on reconnect - the sockets
          // rejoin channels themselves on reconnect.
          if (!_wasConnected) {
            final isReconnect = _wasDisconnected;
            _wasConnected = true;
            _wasDisconnected = false;
            // Re-fetch history after a reconnect (not on first connect) so
            // messages missed while disconnected are recovered. Fires before
            // the 30s throttle so reconnect flapping still re-fetches; the
            // throttle only gates Helix re-subscriptions.
            if (isReconnect) {
              onReconnected?.call();
            }
            final now = DateTime.now();
            if (_lastSubscribeAll != null &&
                now.difference(_lastSubscribeAll!).inSeconds < 30) {
              return;
            }
            final firstConnect = _lastSubscribeAll == null;
            _lastSubscribeAll = now;
            if (!firstConnect) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
            // Per-channel "Connected" now waits for that channel's own JOIN
            // confirmation (see the ROOMSTATE listener) - a socket being up
            // says nothing about whether the channel can receive PRIVMSG.
            subscribeAll();
          }
        }
        if (status == IrcConnectionStatus.disconnected && !_wasDisconnected) {
          _wasDisconnected = true;
          _wasConnected = false;
          readiness.resetForWriteDisconnect();
          _lastSubscribeAll = null;
          joinProgress.clearAllWaits();
          // Failure state is per socket lifetime: the fresh socket runs its
          // own fast sweep, so it may legitimately fail (and re-announce)
          // again.
          channelSetup.resetJoinFailureState();
          for (final channel in chat.names) {
            onSystemMessage(channel, 'Disconnected');
          }
        }
      });

      // The read-only socket reconnects independently of the write socket. A
      // read-socket outage alone (DNS failure, server move) would otherwise be
      // invisible: chat freezes with no "Disconnected" (the write socket is
      // still fine) and no recovery notice. Surface it as an explicit status.
      // Its JOIN confirmations die with the socket, so the input gate must
      // re-lock and the frame must rebuild.
      ircReadStatusSub?.cancel();
      ircReadStatusSub = ircRead.onStatus.listen((status) {
        if (_disposed) return;
        if (status == IrcConnectionStatus.connected &&
            readiness.noteReadSocketRecovered()) {
          for (final channel in chat.names) {
            // Same ack as the JOIN-confirm path below: a flapping write
            // socket reports the same recovery, keep one line.
            if (readiness.acknowledgeConnected(channel)) {
              onSystemMessage(channel, 'Reconnected');
            }
          }
          connectionStateNotifier.value++;
        } else if (status == IrcConnectionStatus.disconnected &&
            readiness.noteReadSocketDisconnected()) {
          connectionStateNotifier.value++;
          for (final channel in chat.names) {
            onSystemMessage(channel, 'Chat reconnecting...');
          }
        }
      });

      // Arm the read requirement on its very first connect (not just
      // recoveries), so the pipe gate covers this session from the start.
      // Armed once: connect() re-runs on every auth change and must not
      // stack another waiter while the read socket stays down. The
      // controller closing on dispose completes with an error; ignore.
      if (!readiness.readEverConnected && !_readConnectWaiterArmed) {
        _readConnectWaiterArmed = true;
        unawaited(
          ircRead.onStatus
              .firstWhere((s) => s == IrcConnectionStatus.connected)
              .then((_) {
                _readConnectWaiterArmed = false;
                if (!_disposed && !readiness.readEverConnected) {
                  readiness.noteReadSocketEverConnected();
                  connectionStateNotifier.value++;
                }
              })
              .catchError((_) {
                _readConnectWaiterArmed = false;
              }),
        );
      }

      ircAuthFailedSub?.cancel();
      ircAuthFailedSub = irc.onAuthFailed.listen((_) {
        if (_disposed) return;
        _handleExpiredToken();
      });

      ircReadAuthFailedSub?.cancel();
      ircReadAuthFailedSub = ircRead.onAuthFailed.listen((_) {
        if (_disposed) return;
        _handleExpiredToken();
      });

      // Use the cached account if available so cold start skips the Helix
      // user lookup entirely.
      if (session.login == null && auth.login != null && auth.userId != null) {
        session.apply(auth.login, userId: auth.userId);
      }

      // Account-switch fast path (runs before any await): a different account
      // was requested while the previous session's socket may still be up, so
      // the new credentials take over instead of riding the old account's
      // socket while this connect() is still validating.
      final pendingUsername = (session.login ?? auth.login)?.toLowerCase();
      final hadPreviousSession =
          _lastIrcUsername != null || _lastIrcToken != null;
      if (hadPreviousSession &&
          pendingUsername != null &&
          pendingUsername != _lastIrcUsername) {
        // The write socket never JOINs, so there are no per-channel JOIN
        // confirmations to drop; sends simply use whatever write socket is up.
      }

      // EventSub needs no credentials - connect it in parallel with the
      // current-user lookup. Only IRC needs the login, so the sockets wait
      // for the lookup but not for each other.
      var hasToken = auth.accessToken != null;

      // Validate the token on startup / credential change, off the critical
      // path: the IRC sockets below must not wait an HTTPS round trip for
      // this answer before joining. Only HTTP 401 counts as definitively
      // dead; network errors leave the token alone so offline users aren't
      // punished. A dead token flips to anonymous via _handleExpiredToken's
      // listener chain (notifyListeners -> connect rerun) or the IRC
      // login-failure NOTICE.
      final validatedToken = auth.accessToken;
      if (hasToken && _lastValidatedToken != validatedToken) {
        unawaited(() async {
          try {
            final result = await twitchApi.validateToken(auth);
            if (result == null && twitchApi.lastErrorStatus == 401) {
              // Attribute the verdict to the credential being validated: if
              // the active account changed while the request was in flight,
              // the 401 says nothing about the new token.
              if (auth.accessToken == validatedToken) {
                _handleExpiredToken();
              }
            }
            if (result != null && auth.accessToken == validatedToken) {
              // Grant predates scopes added after login: prompt re-login
              // instead of failing Tier 3 calls with 403s.
              if (TwitchOAuth.missingScopes(result.scopes).isNotEmpty) {
                auth.markScopeStale();
              }
            }
            // Only update _lastValidatedToken on definitive outcomes (success
            // or 401). Network errors re-trigger validation next time.
            if (result != null || twitchApi.lastErrorStatus == 401) {
              _lastValidatedToken = validatedToken;
            }
          } catch (_) {
            // Network error - proceed normally.
          }
        }());
      }

      final Future<void> eventSubFuture;
      if (hasToken) {
        // Replacing an existing EventSub session (account switch / re-auth):
        // its subscriptions are session-scoped and die with the socket, but
        // connect() suppresses the disconnected status that normally drops
        // this state. Clear it here so the new session's connected edge
        // resubscribes every channel instead of skipping "already
        // subscribed" ones.
        eventSubTopics.clearSessionState();
        // Skip sets reset here too when the identity already differs: the
        // post-lookup reset below runs after awaits, and a fast handshake
        // would otherwise resubscribe against the old account's rejections.
        // Best-effort (login may resolve below); the later reset re-checks.
        final preUsername = (session.login ?? auth.login)?.toLowerCase();
        if (_lastIrcUsername != preUsername ||
            _lastIrcToken != (auth.accessToken ?? 'anonymous')) {
          eventSubTopics.resetAccountScope();
        }
        eventSubFuture = eventSub.connect();
      } else {
        // Leaving authenticated mode: any live EventSub session belongs to
        // the departed account and would keep delivering moderation/widget
        // events. disconnect() emits status, which clears session-scoped
        // state via the listener below.
        if (eventSub.sessionId != null || eventSub.isConnected) {
          eventSub.disconnect();
        }
        eventSubFuture = Future<void>.value();
      }
      Future<Map<String, dynamic>?>? userFuture;
      if (session.login == null && hasToken) {
        userFuture = ensureCurrentUser(auth);
      }

      Map<String, dynamic>? currentUser;
      if (userFuture != null) {
        try {
          currentUser = await userFuture;
        } catch (_) {
          logDebug('[ChatConn] getCurrentUser failed');
        }
      }
      if (currentUser != null) {
        session.apply(currentUser['login'], userId: currentUser['id']);
      }

      // Account switch: an already-connected socket would skip the reconnect
      // and stay on the previous account. Tear the sockets down when the
      // desired account differs from what they were last told to use. Login
      // alone distinguishes accounts (the token always follows it); anonymous
      // mode is a distinct, stable state (null) so it doesn't flap.
      final desiredAnonymous = session.login == null || !hasToken;
      final desiredUsername = desiredAnonymous
          ? null
          : (session.login ?? auth.login)?.toLowerCase();
      final desiredToken = hasToken
          ? (auth.accessToken ?? 'anonymous')
          : 'anonymous';
      if (_lastIrcUsername != desiredUsername ||
          _lastIrcToken != desiredToken ||
          _lastIrcAnonymous != desiredAnonymous) {
        irc.disconnect(emitStatus: false);
        ircRead.disconnect(emitStatus: false);
        // 403 skip sets are account-scoped: a non-mod account's rejection
        // must not permanently disable moderation/widgets for a mod account
        // on the same channel after a switch.
        eventSubTopics.resetAccountScope();
        channelSetup.resetJoinFailureState();
        // New credentials re-arm expiry handling; without this a second dead
        // token after a mid-session re-auth would fail silently forever.
        _expiryHandled = false;
        // The suppressed disconnect skips the status-listener cleanup, so the
        // switch drops per-session/per-account state here explicitly: old
        // JOIN confirmations must not gate sends, self badges and slow-mode/
        // timeout anchors belong to the old account, and duplicate-bypass
        // wire text must not carry across accounts.
        readiness.resetForAccountSwitch();
        _lastSubscribeAll = null;
        clearSelfBadges();
        sender.clearAccountScope();
        // The queue belongs to the old account's moderation scope.
        for (final name in chat.names) {
          chat.channelFor(name)?.moderation.clearHeld();
        }
        // Make the new socket take the full connect edge (history backfill,
        // Helix re-subscriptions, Connected lines) even though no user-facing
        // disconnected status was emitted for this deliberate swap. Only for
        // an established prior session: a virgin cold start must keep its
        // ordinary first-connect semantics (no backfill, no reconnect).
        if (_lastIrcToken != null) {
          _wasConnected = false;
          _wasDisconnected = true;
        }
      }

      if (session.login != null && hasToken) {
        // An authenticated session gets BOTH sockets; arming happens via
        // _lastIrcAnonymous below (readExpected = !anonymous), so the
        // handshake window counts as "read pending" instead of "read
        // absent" - no premature Connected, no early input unlock.
        try {
          await Future.wait([
            irc.connect(
              username: session.login!,
              accessToken: auth.accessToken!,
            ),
            ircRead.connect(
              username: session.login!,
              accessToken: auth.accessToken!,
            ),
          ]);
        } catch (e) {
          logDebug('IRC connect failed: $e');
        }
        _lastIrcUsername = session.login?.toLowerCase();
        _lastIrcToken = auth.accessToken;
        _lastIrcAnonymous = false;
      } else {
        // Read-only anonymous mode: Twitch accepts a justinfan NICK without
        // credentials, which still delivers chat (with the emotes tag) but
        // can't send messages or call Helix.
        try {
          await Future.wait([
            irc.connect(username: _anonymousNick(1), accessToken: 'anonymous'),
            ircRead.connect(
              username: _anonymousNick(2),
              accessToken: 'anonymous',
            ),
          ]);
        } catch (e) {
          logDebug('Anonymous IRC connect failed: $e');
        }
        _lastIrcUsername = null;
        _lastIrcToken = 'anonymous';
        _lastIrcAnonymous = true;
      }

      await eventSubFuture;
    } finally {
      _isConnecting = false;
      // A connect dropped by the re-entrancy guard (e.g. a login landing
      // while a startup connect is still in-flight) is re-run now that the
      // current connect finished, so the dropped credentials are honored
      // instead of the app staying on the previous (or anonymous) account
      // until a restart.
      if (!_disposed && _connectRetryRequested) {
        _connectRetryRequested = false;
        unawaited(connect());
      }
    }
  }

  /// Central handler for an expired/dead access token. Marks the active
  /// account expired, broadcasts a message to every open channel, and
  /// signals the snackbar. Subsequent calls are no-ops until the
  /// credentials change (which resets [_expiryHandled]).
  void _handleExpiredToken() {
    if (_expiryHandled) return;
    _expiryHandled = true;
    twitchAuth.markActiveExpired();
    session.apply(null);
    // Logged-out identity keeps no queue, and the dead token's subs will
    // not resolve it; IRC fallback resumes moderation echoes.
    for (final name in chat.names) {
      chat.channelFor(name)?.moderation.clearHeld();
    }
    eventSubTopics.clearSessionState();
    for (final channel in chat.names) {
      onSystemMessage(
        channel,
        'Login expired - reconnect your account in Settings',
      );
    }
    onBanner?.call('Login expired');
  }

  String _anonymousNick(int seed) {
    return 'justinfan${(DateTime.now().millisecondsSinceEpoch + seed) % 80000 + 1000}';
  }

  /// Foreground liveness watchdog: periodically re-arms any socket whose
  /// reconnect loop died without a pending connect (e.g. a fatal-auth break
  /// or a generation bump that wasn't followed by a fresh connect). The
  /// in-socket loop already retries forever on ordinary network drops, so
  /// this only needs to run while the app is in the foreground.
  void _startWatchdog() {
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
    final username = login ?? _anonymousNick(1);
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
          username: anonymous ? _anonymousNick(2) : username,
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
}
