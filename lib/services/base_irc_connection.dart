import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../util/constants.dart';
import '../util/irc_utils.dart';
import 'connectivity_service.dart';
import 'join_rate_limiter.dart';
import '../util/log.dart';

enum IrcConnectionStatus { disconnected, connecting, connected }

/// Why a channel JOIN never completed.
enum JoinFailureReason {
  /// The server sent NOTICE msg-id=msg_channel_suspended: the channel is
  /// suspended or deleted. Permanent for this socket; no point re-JOINing.
  suspended,

  /// The server never confirmed the JOIN (no ROOMSTATE) and the fast rejoin
  /// sweep gave up: usually a nonexistent channel, whose JOINs Twitch silently
  /// drops, or persistent burst loss.
  noResponse,
}

class IrcJoinFailureEvent {
  final String channel;
  final JoinFailureReason reason;

  IrcJoinFailureEvent({required this.channel, required this.reason});
}

/// Which socket this connection is: the chat write socket or the read-only
/// socket. Mirrors DankChat's ChatConnectionType: the connection loop,
/// keepalive, JOIN handling and backoff are identical for both; only the
/// message semantics differ (the write socket sends PRIVMSG, the read socket
/// only watches for own echoes).
enum IrcSocketRole { read, write }

final _loneLowSurrogateRe = RegExp(r'[\uDC00-\uDFFF]');
final _orphanedHighSurrogateRe = RegExp(r'[\uD800-\uDBFF](?![\uDC00-\uDFFF])');

/// A single Twitch IRC connection. One instance per socket (write + read);
/// both share this class and differ only in [role].
///
/// The whole lifecycle - initial connect AND every reconnect - is a single
/// loop guarded by a generation counter (the semaphore). [connect] starts one
/// run; a failure backs off (1s/2s/4s/8s capped, retrying forever) inside that
/// same loop and retries. There is no separate reconnect path that could race
/// the initial connect: exactly one run can open a socket at a time, and a
/// new [connect]/[forceReconnect]/[disconnect] bumps the generation to
/// invalidate any run still in flight.
abstract class IrcConnection {
  static const _wsUrl = 'wss://irc-ws.chat.twitch.tv:443';
  // DankChat-style backoff: delays are 1s, 2s, 4s, then capped at 8s,
  // retrying forever (no give-up). The cap is the max attempt used for the
  // delay calculation.
  static const _maxReconnectDelayAttempts = 4;
  // Twitch IRC keepalive: PING every ~60s. Answering the server's own PINGs
  // is the only strict requirement; the client-side PING keeps the TCP path
  // warm (mobile NATs drop idle connections silently) and detects a dead
  // socket within ~90s instead of the old 5-10 minute blind spot.
  static const _pingInterval = Duration(seconds: 60);
  static const _pongTimeout = Duration(seconds: 5);
  // How long a keepalive PING may go unanswered before we declare the
  // connection dead and reconnect.
  static const _keepalivePongTimeout = Duration(seconds: 30);
  // Upper bound on the connect handshake. Without it a reconnect over a dead
  // network can hang forever while the loop waits on an attempt.
  static const _connectTimeout = Duration(seconds: 10);
  // JOIN pacing: Twitch throttles connections that fire JOINs too fast, so
  // every JOIN goes through a token bucket. The bucket is shared between the
  // read and write sockets when the app wires them to one [JoinRateLimiter]
  // (see HomeScreen); standalone instances fall back to a private bucket.
  static const _joinPumpInterval = Duration(milliseconds: 500);
  // ROOMSTATE echoes a processed JOIN; a channel that hasn't confirmed within
  // this window is re-sent (up to a few rounds, then we stop nagging).
  static const _joinConfirmInterval = Duration(seconds: 10);
  static const _joinSweepMaxRounds = 4;

  final ConnectivityService? connectivityService;
  final IrcSocketRole role;

  /// Shared JOIN pacing. When the app wires both sockets to one limiter,
  /// their combined JOIN rate stays inside Twitch's command budget; a null
  /// injection falls back to a private bucket with identical semantics.
  final JoinRateLimiter? _injectedJoinBudget;
  JoinRateLimiter? _joinBudgetInstance;

  /// True while the lazily-created private bucket exists: it must be torn
  /// down with this connection so its pump timer cannot leak.
  bool get _joinBudgetIsPrivate => _injectedJoinBudget == null;

  JoinRateLimiter get _joinBudget =>
      _injectedJoinBudget ??
      (_joinBudgetInstance ??= JoinRateLimiter(
        pumpInterval: _joinPumpInterval,
      ));

  WebSocketChannel? channel;
  String? username;
  String? token;

  // Generation counter: the connect/reconnect semaphore. Every connect(),
  // forceReconnect() and disconnect() bumps it, invalidating any run still in
  // flight so exactly one loop can ever open a socket.
  int _runGeneration = 0;

  bool _disposed = false;
  int _reconnectAttempt = 0;
  bool _awaitingPong = false;
  bool _fatalAuth = false;
  // In-flight liveness probes (checkAlive), keyed by the PING token each one
  // sends; a PONG is only accepted for the exact token it echoes.
  final _pingAwaiters = <String, Completer<bool>>{};
  int _pingSeq = 0;
  VoidCallback? _connectivityListener;
  bool _wasOnline = true;
  final _channels = <String>{};
  // Channels whose JOIN was sent but not yet confirmed: Twitch may silently
  // drop JOINs fired in a burst right after connect, so anything the server
  // hasn't echoed back as ROOMSTATE gets re-sent by the sweep.
  final _joinPending = <String>{};
  // Channels the server confirmed via ROOMSTATE for this socket.
  final _joinConfirmed = <String>{};
  Timer? _joinSweepTimer;
  int _joinSweepRound = 0;
  // Channels the server explicitly refused (msg_channel_suspended). Excluded
  // from every sweep/retry for this socket's lifetime: re-JOINing would only
  // repeat the failure notice.
  final _joinFailed = <String>{};
  // Slow retry loop after the fast sweep gave up: keeps trying the unconfirmed
  // JOINs at a low rate for a bounded window, then goes silent. A nonexistent
  // channel never confirms, so this only bounds the probing; the socket dying
  // tears it down anyway and the fresh socket restarts the fast sweep.
  Timer? _joinRetryTimer;
  static const _joinRetryInterval = Duration(seconds: 60);
  static const _joinRetryMaxAttempts = 5;
  int _joinRetryAttempt = 0;

  StreamSubscription<dynamic>? _streamSub;
  Timer? _pingTimer;
  Timer? _pongTimer;
  Timer? _connectTimer;
  // The backoff sleep of the running loop: cancelled by _disconnect() and
  // completed early by the connectivity accelerator (online again -> retry
  // now instead of waiting out the remaining delay).
  Timer? _sleepTimer;
  Completer<_WakeReason>? _sleepCompleter;
  // Completes when the serving socket dies; awaited by _attemptConnect so the
  // loop knows the attempt is over.
  Completer<_DeathReason>? _socketDeath;
  bool _attemptInFlight = false;

  final _statusController = StreamController<IrcConnectionStatus>.broadcast(
    sync: true,
  );

  Stream<IrcConnectionStatus> get onStatus => _statusController.stream;
  bool get isConnected => channel != null;

  final _joinFailedController = StreamController<IrcJoinFailureEvent>.broadcast(
    sync: true,
  );

  /// Emits channels whose JOIN permanently failed for this socket: an explicit
  /// [JoinFailureReason.suspended] notice, or [JoinFailureReason.noResponse]
  /// after the fast sweep exhausted its rounds. Emitted once per channel per
  /// socket lifetime; a later ROOMSTATE confirmation supersedes it.
  Stream<IrcJoinFailureEvent> get onJoinFailed => _joinFailedController.stream;

  String get debugPrefix;

  IrcConnection({
    this.connectivityService,
    this.role = IrcSocketRole.write,
    JoinRateLimiter? joinBudget,
  }) : _injectedJoinBudget = joinBudget;

  /// Emits a status event, no-oping after [dispose] so a racing connect or
  /// reconnect can never throw on the closed controller.
  void _emitStatus(IrcConnectionStatus status) {
    if (_disposed) return;
    _statusController.add(status);
  }

  /// Starts the connection loop. Returns a future that completes once the
  /// first attempt has settled (connected or failed); the loop keeps running
  /// in the background, backing off and retrying until an explicit
  /// [disconnect]/[dispose] (or a new [connect]) supersedes it.
  Future<void> connect({
    required String username,
    required String accessToken,
  }) {
    if (_disposed) return Future.value();
    if (isConnected) {
      // Credentials only apply to a socket we are about to authenticate;
      // adopting new ones on a live socket (authenticated as the previous
      // account) would make the stored state lie about the connection.
      logDebug('[$debugPrefix] already connected, skipping reconnect');
      return Future.value();
    }
    this.username = username.toLowerCase();
    token = accessToken;
    _fatalAuth = false;
    _runGeneration++;
    final firstSettled = Completer<void>();
    unawaited(_run(_runGeneration, firstSettled));
    return firstSettled.future;
  }

  Future<void> _run(int gen, Completer<void> firstSettled) async {
    var settled = false;
    void settle() {
      if (!settled) {
        settled = true;
        firstSettled.complete();
      }
    }

    _ensureConnectivityListener();
    _reconnectAttempt = 0;
    while (!_disposed && gen == _runGeneration) {
      final outcome = await _attemptConnect(gen, settle);
      if (_disposed || gen != _runGeneration) break;
      // A server-requested reconnect is honored immediately (no backoff).
      if (outcome == _AttemptOutcome.reconnect) continue;
      if (outcome == _AttemptOutcome.stopped) break;
      // Fatal auth failure: the token is dead and retrying can't help.
      if (outcome == _AttemptOutcome.fatalAuth) break;
      _reconnectAttempt++;
      final wake = await _sleep(_backoffDelay(_reconnectAttempt), gen);
      if (_disposed || gen != _runGeneration) break;
      if (wake == _WakeReason.connectivity) _reconnectAttempt = 0;
    }
    settle();
  }

  Future<_AttemptOutcome> _attemptConnect(
    int gen,
    void Function() onSettled,
  ) async {
    if (_disposed || gen != _runGeneration) return _AttemptOutcome.stopped;
    _attemptInFlight = true;
    try {
      _emitStatus(IrcConnectionStatus.connecting);
      WebSocketChannel? newChannel;
      try {
        newChannel = await openChannel();
        await _waitForReady(newChannel);
        if (_disposed || gen != _runGeneration) {
          newChannel.sink.close();
          return _AttemptOutcome.stopped;
        }
        // Only claim the socket once the handshake completed; isConnected
        // must stay false while the connection is still being established,
        // otherwise the type bar hint flashes "connected" during the attempt.
        channel = newChannel;
        onSettled();

        final death = Completer<_DeathReason>();
        _socketDeath = death;
        _streamSub = channel!.stream.listen(
          (raw) => _handleLine(raw as String),
          onError: (e) {
            logDebug('$debugPrefix stream error: $e');
            _signalDeath(_DeathReason.error);
          },
          onDone: () {
            logDebug(
              '$debugPrefix stream closed '
              '(code: ${channel?.closeCode}, reason: ${channel?.closeReason})',
            );
            _signalDeath(_DeathReason.closed);
          },
        );

        sendLine('CAP REQ :twitch.tv/tags twitch.tv/commands');
        sendLine('PASS oauth:$token');
        sendLine('NICK $username');
        logDebug(
          '[$debugPrefix] connected, queueing '
          '${_channels.length} channels: $_channels',
        );
        // Route the re-JOINs through the limiter: a burst of JOINs right
        // after connect is exactly what Twitch drops. The ROOMSTATE sweep
        // re-sends anything the server never confirmed.
        for (final channelName in _channels) {
          _queueJoin(channelName);
        }
        _startJoinSweep();

        _emitStatus(IrcConnectionStatus.connected);
        _reconnectAttempt = 0;
        _startPingTimer();

        // Serve until the socket dies (error, close, server RECONNECT, PONG
        // timeout or an explicit disconnect).
        final deathReason = await death.future;
        // Clear the socket before the status event so listeners that rebuild
        // on it (e.g. the type bar hint) don't briefly show "connected".
        _disconnect();
        _emitStatus(IrcConnectionStatus.disconnected);
        if (deathReason == _DeathReason.authFailed) {
          return _AttemptOutcome.fatalAuth;
        }
        return _AttemptOutcome.failure;
      } catch (e) {
        logDebug('$debugPrefix connect error: $e');
        onSettled();
        // A failed attempt must not leave a socket behind: otherwise
        // isConnected stays true and every reconnect bails out here. A
        // timed-out handshake also gets its socket closed so it can't leak.
        newChannel?.sink.close();
        channel = null;
        _streamSub?.cancel();
        _streamSub = null;
        _socketDeath = null;
        _emitStatus(IrcConnectionStatus.disconnected);
        return _AttemptOutcome.failure;
      }
    } finally {
      _attemptInFlight = false;
    }
  }

  Duration _backoffDelay(int attempt) {
    final capped = attempt.clamp(1, _maxReconnectDelayAttempts);
    return applyReconnectJitter(Duration(seconds: 1 << (capped - 1)));
  }

  Future<_WakeReason> _sleep(Duration delay, int gen) {
    final completer = Completer<_WakeReason>();
    _sleepCompleter?.complete(_WakeReason.stopped);
    _sleepCompleter = completer;
    final timer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete(_WakeReason.timer);
    });
    _sleepTimer?.cancel();
    _sleepTimer = timer;
    return completer.future.then((reason) {
      timer.cancel();
      if (_sleepTimer == timer) _sleepTimer = null;
      if (_sleepCompleter == completer) _sleepCompleter = null;
      if (_disposed || gen != _runGeneration) return _WakeReason.stopped;
      return reason;
    });
  }

  void _signalDeath(_DeathReason reason) {
    final death = _socketDeath;
    _socketDeath = null;
    if (death != null && !death.isCompleted) death.complete(reason);
  }

  void _ensureConnectivityListener() {
    final service = connectivityService;
    if (service == null || _connectivityListener != null) return;
    _connectivityListener = () {
      if (service.isOnline && !_wasOnline) {
        // Back online: wake the backoff sleep so the loop retries now instead
        // of waiting out the remaining delay. The loop retries regardless of
        // connectivity (no gate), so this only shortens the wait.
        _reconnectAttempt = 0;
        final sleep = _sleepCompleter;
        if (sleep != null && !sleep.isCompleted) {
          sleep.complete(_WakeReason.connectivity);
        }
      }
      _wasOnline = service.isOnline;
    };
    _wasOnline = service.isOnline;
    service.addListener(_connectivityListener!);
  }

  /// Opens the socket; overridable in tests.
  @visibleForTesting
  Future<WebSocketChannel> openChannel() async =>
      WebSocketChannel.connect(Uri.parse(_wsUrl));

  /// Waits for the WebSocket handshake with an upper bound. The timeout timer
  /// is tracked and cancelled on disconnect/dispose so a torn-down connect
  /// never leaves a pending timer behind.
  Future<void> _waitForReady(WebSocketChannel newChannel) {
    final completer = Completer<void>();
    _connectTimer?.cancel();
    _connectTimer = Timer(_connectTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('$debugPrefix connect timed out'),
        );
      }
    });
    newChannel.ready.then(
      (_) {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
    );
    return completer.future.whenComplete(() {
      _connectTimer?.cancel();
      _connectTimer = null;
    });
  }

  // Twitch IRC keepalive (DankChat-style): PING every ~60s with jitter to
  // stagger the read/write sockets. Each PING arms a dedicated PONG timer; if
  // the PONG doesn't arrive within _keepalivePongTimeout (or the next tick
  // still sees it pending), the connection is considered dead and we reconnect.
  void _startPingTimer() {
    _pingTimer?.cancel();
    final jitter = Duration(milliseconds: Random().nextInt(251));
    _pingTimer = Timer.periodic(_pingInterval - jitter, (_) {
      if (channel == null) return;
      if (_awaitingPong) {
        _handlePongTimeout();
        return;
      }
      sendLine('PING :keepalive');
      _awaitingPong = true;
      _pongTimer?.cancel();
      _pongTimer = Timer(_keepalivePongTimeout, () {
        if (_awaitingPong) _handlePongTimeout();
      });
    });
  }

  void _handlePongTimeout() {
    logDebug('$debugPrefix PONG timeout - reconnecting');
    // Clear the socket before the status event so listeners that rebuild on it
    // (e.g. the type bar hint) don't briefly show "connected". The serving
    // loop wakes via _signalDeath and emits the status after the teardown.
    _disconnect();
    _signalDeath(_DeathReason.error);
  }

  void _disconnect() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final sleep = _sleepCompleter;
    _sleepCompleter = null;
    if (sleep != null && !sleep.isCompleted) {
      sleep.complete(_WakeReason.stopped);
    }
    _pingTimer?.cancel();
    _pingTimer = null;
    _pongTimer?.cancel();
    _pongTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _streamSub?.cancel();
    _streamSub = null;
    channel?.sink.close();
    channel = null;
    _awaitingPong = false;
    // Queued JOIN units stay put: their dispatch will fail while this socket
    // is down (and drop), and the reconnect path re-queues every channel
    // after the handshake.
    _stopJoinSweep();
    _stopJoinRetry();
    _joinPending.clear();
    _joinConfirmed.clear();
    _joinFailed.clear();
    _joinSweepRound = 0;
  }

  /// Tears down the socket and stops the loop. Used on account switch so the
  /// next [connect] can attach the new account instead of being skipped by
  /// the already-connected check.
  void disconnect({bool emitStatus = true}) {
    if (_disposed) return;
    final wasActive =
        channel != null ||
        _socketDeath != null ||
        _sleepCompleter != null ||
        _attemptInFlight;
    if (!wasActive) return;
    _runGeneration++;
    _disconnect();
    _signalDeath(_DeathReason.closed);
    if (emitStatus) _emitStatus(IrcConnectionStatus.disconnected);
  }

  void forceReconnect() {
    if (channel == null) return;
    logDebug('$debugPrefix force reconnect (unhealthy socket)');
    // Bump the generation first so the running loop breaks immediately when
    // it wakes, then clear the zombie socket before the status event so
    // rebuilding listeners see a real disconnect, not a stale one.
    _runGeneration++;
    _reconnectAttempt = 0;
    _disconnect();
    _signalDeath(_DeathReason.closed);
    _emitStatus(IrcConnectionStatus.disconnected);
    final firstSettled = Completer<void>();
    unawaited(_run(_runGeneration, firstSettled));
  }

  void sendLine(String message) {
    try {
      channel?.sink.add(message);
    } catch (e) {
      logDebug('$debugPrefix send failed: $e');
    }
  }

  /// Pings the server and waits for a PONG to confirm the socket is truly
  /// alive. A socket can exist while being dead (e.g. frozen by the OS while
  /// backgrounded); used on app resume before trusting `isConnected`.
  Future<bool> checkAlive({Duration timeout = _pongTimeout}) async {
    if (channel == null) return false;
    // Token the probe so a PONG can only satisfy the probe it answers. A
    // stale PONG from an earlier keepalive (buffered while the app was frozen
    // in the background) has a different trailing token and can't false-
    // positive a dead socket into "alive".
    final token = 'alive-check-${_pingSeq++}';
    final completer = Completer<bool>();
    _pingAwaiters[token] = completer;
    try {
      sendLine('PING :$token');
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } finally {
      _pingAwaiters.remove(token);
    }
  }

  /// Extracts the trailing of a PONG line, i.e. the text Twitch echoes back
  /// from our client PING (e.g. `PING :alive-check-3` -> `PONG :alive-check-3`).
  String? _pongToken(String line) {
    final idx = line.lastIndexOf(' :');
    if (idx == -1) return null;
    return line.substring(idx + 2);
  }

  void _handleLine(String raw) {
    for (final line in raw.split('\r\n')) {
      if (line.isEmpty) continue;

      _reconnectAttempt = 0;

      final parts = line.split(' ');
      int cmdIdx = 0;
      if (parts.length > 1 && parts[0].startsWith(':')) cmdIdx = 1;
      if (parts.length > 2 && parts[0].startsWith('@')) cmdIdx = 2;
      final cmd = parts[cmdIdx];

      if (cmd == 'PING') {
        sendLine(line.replaceFirst('PING', 'PONG'));
        continue;
      }

      if (cmd == 'PONG') {
        _awaitingPong = false;
        _pongTimer?.cancel();
        _pongTimer = null;
        // Twitch echoes a client PING's text as the PONG trailing. Only a
        // PONG that echoes an in-flight probe's token satisfies that probe.
        final token = _pongToken(line);
        if (token != null) {
          final waiter = _pingAwaiters.remove(token);
          if (waiter != null && !waiter.isCompleted) {
            waiter.complete(true);
          }
        }
        continue;
      }

      // Twitch asks clients to reconnect (maintenance / server move).
      if (cmd == 'RECONNECT') {
        logDebug('$debugPrefix server requested reconnect');
        _disconnect();
        _signalDeath(_DeathReason.reconnect);
        continue;
      }

      // ROOMSTATE is the server's acknowledgement that a JOIN was processed;
      // the sweep uses it to tell dropped JOINs from confirmed memberships.
      if (cmd == 'ROOMSTATE' && parts.length > 2) {
        final channel = parts.last.replaceFirst('#', '');
        if (_channels.contains(channel)) {
          _joinPending.remove(channel);
          _joinConfirmed.add(channel);
        }
      }

      // A JOIN aimed at a suspended/deleted channel is answered with an
      // explicit NOTICE (msg-id=msg_channel_suspended) and never a ROOMSTATE.
      // Remember the refusal so sweeps and retries stop re-JOINing (each
      // retry would only repeat the notice) and surface it exactly once.
      if (cmd == 'NOTICE') {
        final msg = parseIrcMessage(line);
        if (msg?.tags['msg-id'] == 'msg_channel_suspended' &&
            msg!.params.isNotEmpty &&
            msg.params[0].startsWith('#')) {
          final channel = msg.params[0].substring(1);
          if (_channels.contains(channel) && !_joinFailed.contains(channel)) {
            _joinFailed.add(channel);
            _joinPending.remove(channel);
            logDebug('[$debugPrefix] join refused: $channel is suspended');
            _emitJoinFailed(channel, JoinFailureReason.suspended);
          }
        }
      }

      dispatchLine(line);

      // If the subclass flagged a fatal auth error during dispatch, stop
      // processing any remaining lines in this batch.
      if (_fatalAuth) return;
    }
  }

  @visibleForTesting
  void handleLine(String raw) => _handleLine(raw);

  /// Called by subclass [dispatchLine] when a fatal auth failure is detected
  /// (e.g. Twitch NOTICE * :Login authentication failed). Signals the death
  /// of this socket and prevents any further reconnect attempts.
  @protected
  void signalFatalAuthFailure() {
    if (_fatalAuth || _socketDeath == null) return;
    _fatalAuth = true;
    _disconnect();
    _signalDeath(_DeathReason.authFailed);
  }

  @visibleForTesting
  bool get awaitingPong => _awaitingPong;

  @visibleForTesting
  set awaitingPong(bool value) => _awaitingPong = value;

  void dispatchLine(String line);

  void join(String channel) {
    logDebug('[$debugPrefix] join channel=$channel');
    _channels.add(channel);
    _queueJoin(channel);
  }

  void part(String channel) {
    logDebug('[$debugPrefix] part channel=$channel');
    _channels.remove(channel);
    _joinConfirmed.remove(channel);
    _joinPending.remove(channel);
    _joinBudget.removeEntry(channel);
    _joinFailed.remove(channel);
    if (this.channel != null) {
      sendLine('PART #$channel');
    }
  }

  /// Queues this socket's JOIN for [channel] behind the shared rate limiter.
  /// Safe while disconnected: units whose dispatch fails stay queued and
  /// retry, and the connect path re-queues every [_channels] entry after the
  /// handshake (merging into already-queued units).
  void _queueJoin(String channel) {
    _joinBudget.registerHandler(role, sendJoinNow);
    _joinBudget.enqueue(channel, role);
  }

  /// Sends one JOIN immediately. Called by the limiter's pump; returns false
  /// when the socket is down so the entry is dropped instead of consumed.
  @visibleForTesting
  bool sendJoinNow(String channel) {
    if (this.channel == null) {
      PerfLog.I.record('JOINQ', '[$debugPrefix] send $channel REFUSED (down)');
      return false;
    }
    PerfLog.I.record('JOINQ', '[$debugPrefix] send JOIN #$channel');
    sendLine('JOIN #$channel');
    _joinPending.add(channel);
    return true;
  }

  /// Watches for JOINs the server never confirmed (no ROOMSTATE echoed back).
  /// Runs a few rounds of re-queueing unconfirmed channels, then stops.
  void _startJoinSweep() {
    _joinSweepRound = 0;
    _joinSweepTimer?.cancel();
    _joinSweepTimer = Timer.periodic(_joinConfirmInterval, (_) {
      _runJoinSweep();
    });
  }

  void _runJoinSweep() {
    _joinSweepRound++;
    final unconfirmed = _channels
        .where((c) => !_joinConfirmed.contains(c) && !_joinFailed.contains(c))
        .toList();
    if (_joinSweepRound > _joinSweepMaxRounds) {
      // Fast sweep gave up: surface every channel that still never confirmed,
      // then keep trying them on the slow retry loop (still routed through
      // the rate-limited queue) for a bounded window before going silent.
      _stopJoinSweep();
      for (final ch in unconfirmed) {
        logDebug('[$debugPrefix] join never confirmed: $ch');
        _emitJoinFailed(ch, JoinFailureReason.noResponse);
      }
      _startJoinRetry(unconfirmed);
      return;
    }
    if (unconfirmed.isEmpty) {
      _stopJoinSweep();
      return;
    }
    logDebug(
      '[$debugPrefix] rejoin sweep $_joinSweepRound '
      'unconfirmed: $unconfirmed',
    );
    for (final ch in unconfirmed) {
      _queueJoin(ch);
    }
  }

  /// Probes channels the fast sweep gave up on, once per [_joinRetryInterval],
  /// up to [_joinRetryMaxAttempts] attempts before going silent. Sends via
  /// [_queueJoin], so retries share the same rate limiter as every other
  /// JOIN. Stops early once each channel confirms, fails explicitly, or is
  /// parted; the socket going down tears the loop down with everything else
  /// and the fresh socket restarts the fast sweep.
  void _startJoinRetry(List<String> channels) {
    if (channels.isEmpty) return;
    final pending = Set<String>.of(channels);
    _joinRetryAttempt = 0;
    _joinRetryTimer?.cancel();
    _joinRetryTimer = Timer.periodic(_joinRetryInterval, (_) {
      pending.removeWhere(
        (c) =>
            _joinConfirmed.contains(c) ||
            _joinFailed.contains(c) ||
            !_channels.contains(c),
      );
      if (pending.isEmpty) {
        _stopJoinRetry();
        return;
      }
      // Socket down: the connect path re-queues every channel itself.
      if (channel == null) return;
      _joinRetryAttempt++;
      if (_joinRetryAttempt > _joinRetryMaxAttempts) {
        // Capped out: stop probing a channel that never answers. A fresh
        // socket (reconnect) restarts the whole cycle anyway.
        logDebug(
          '[$debugPrefix] join retry gave up after '
          '$_joinRetryMaxAttempts attempts: $pending',
        );
        _stopJoinRetry();
        return;
      }
      logDebug('[$debugPrefix] slow join retry: $pending');
      for (final ch in pending) {
        _queueJoin(ch);
      }
    });
  }

  void _stopJoinRetry() {
    _joinRetryTimer?.cancel();
    _joinRetryTimer = null;
  }

  void _emitJoinFailed(String channel, JoinFailureReason reason) {
    if (_disposed) return;
    _joinFailedController.add(
      IrcJoinFailureEvent(channel: channel, reason: reason),
    );
  }

  void _stopJoinSweep() {
    _joinSweepTimer?.cancel();
    _joinSweepTimer = null;
  }

  @mustCallSuper
  void dispose() {
    _disposed = true;
    _runGeneration++;
    // A privately-owned bucket dies with the connection; a shared one stays
    // (its owner clears this socket's role via dropRole below).
    if (_joinBudgetIsPrivate) {
      _joinBudgetInstance?.clear();
    } else {
      _injectedJoinBudget?.dropRole(role);
    }
    _disconnect();
    _signalDeath(_DeathReason.closed);
    final listener = _connectivityListener;
    if (listener != null) connectivityService?.removeListener(listener);
    _connectivityListener = null;
    _statusController.close();
    _joinFailedController.close();
  }
}

/// The read-only socket: joins channels and watches for the current user's own
/// PRIVMSG echoes so sends can be confirmed without trusting the write socket.
class IrcReadService extends IrcConnection {
  final _ownMessageController = StreamController<IrcMessage>.broadcast();
  final _roomStateController = StreamController<IrcRoomStateEvent>.broadcast();

  Stream<IrcMessage> get onOwnMessage => _ownMessageController.stream;

  /// ROOMSTATE echoes for this socket, so consumers can track which channels
  /// the read side has actually joined (its JOINs lag the write socket's
  /// under the shared rate budget).
  Stream<IrcRoomStateEvent> get onRoomState => _roomStateController.stream;

  IrcReadService({super.connectivityService, super.joinBudget})
    : super(role: IrcSocketRole.read);

  @override
  String get debugPrefix => 'IRC read';

  @override
  void dispatchLine(String line) {
    // Fatal auth detection mirrors the write socket: without it, a dead
    // token makes this socket back off and retry forever while the write
    // socket has already given up.
    final msg = parseIrcMessage(line);
    if (msg != null && msg.command == 'NOTICE') {
      final target = msg.params.isNotEmpty ? msg.params[0] : null;
      if ((target == null || target == '*') &&
          msg.trailing?.contains('Login authentication failed') == true) {
        signalFatalAuthFailure();
        return;
      }
    }
    if (msg != null && msg.command == 'ROOMSTATE') {
      // Channel param arrives as '#name'.
      if (msg.params.isNotEmpty) {
        final channel = msg.params.first.replaceFirst('#', '');
        if (channel.isNotEmpty) {
          PerfLog.I.record('JOINQ', '[$debugPrefix] confirm #$channel');
          _roomStateController.add(
            IrcRoomStateEvent(channel: channel, tags: msg.tags),
          );
        }
      }
      return;
    }
    if (username == null) return;
    if (msg == null || msg.command != 'PRIVMSG' || msg.prefix == null) {
      return;
    }
    final sender = msg.prefix!.contains('!')
        ? msg.prefix!.split('!')[0].toLowerCase()
        : msg.prefix!.toLowerCase();
    if (sender == username) {
      _ownMessageController.add(msg);
    }
  }

  @override
  void dispose() {
    _ownMessageController.close();
    _roomStateController.close();
    super.dispose();
  }

  @visibleForTesting
  void emitOwnMessage(IrcMessage msg) => _ownMessageController.add(msg);
}

IrcMessage? parseIrcMessage(String line) {
  try {
    String? tags;
    String? prefix;
    String command;
    List<String> params = [];
    String? trailing;

    int pos = 0;

    if (line.startsWith('@')) {
      final end = line.indexOf(' ');
      if (end == -1) return null;
      tags = line.substring(1, end);
      pos = end + 1;
    }

    if (pos < line.length && line[pos] == ':') {
      final end = line.indexOf(' ', pos);
      if (end == -1) return null;
      prefix = line.substring(pos + 1, end);
      pos = end + 1;
    }

    final rest = line.substring(pos);
    final parts = rest.split(' ');
    command = parts[0];

    int i = 1;
    while (i < parts.length) {
      if (parts[i].startsWith(':')) {
        trailing = parts.sublist(i).join(' ').substring(1);
        break;
      }
      params.add(parts[i]);
      i++;
    }

    final tagMap = <String, String>{};
    if (tags != null) {
      for (final tag in tags.split(';')) {
        final eq = tag.indexOf('=');
        if (eq != -1) {
          // Twitch IRCv3 tags are backslash-escaped, not percent-encoded.
          String decoded = unescapeIrcTag(tag.substring(eq + 1));
          // Strip orphaned UTF-16 surrogates: low surrogates alone or high
          // surrogates not followed by low (Flutter's text engine crashes on
          // isolated surrogates from malformed Twitch IRC data).
          decoded = decoded.replaceAll(_loneLowSurrogateRe, '');
          decoded = decoded.replaceAll(_orphanedHighSurrogateRe, '');
          tagMap[tag.substring(0, eq)] = decoded;
        }
      }
    }

    return IrcMessage(
      tags: tagMap,
      prefix: prefix,
      command: command,
      params: params,
      trailing: trailing,
    );
  } catch (_) {
    logDebug('[parseIrcMessage] failed to parse line: $line');
    return null;
  }
}

class IrcMessage {
  final Map<String, String> tags;
  final String? prefix;
  final String command;
  final List<String> params;
  final String? trailing;

  IrcMessage({
    required this.tags,
    this.prefix,
    required this.command,
    required this.params,
    this.trailing,
  });
}

class IrcRoomStateEvent {
  final String channel;

  /// Raw tag map; updates are partial (only changed tags), so callers that
  /// need the full state must merge with the previous event.
  final Map<String, String> tags;

  IrcRoomStateEvent({required this.channel, required this.tags});
}

enum _DeathReason { error, closed, reconnect, authFailed }

enum _WakeReason { timer, connectivity, stopped }

enum _AttemptOutcome { failure, reconnect, stopped, fatalAuth }
