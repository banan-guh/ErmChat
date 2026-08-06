import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../util/constants.dart';

enum IrcConnectionStatus { disconnected, connecting, connected }

abstract class BaseIrcConnection {
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
  // network can hang forever while `_connecting` blocks every further attempt.
  static const _connectTimeout = Duration(seconds: 10);

  final Connectivity? connectivity;

  WebSocketChannel? channel;
  String? username;
  String? token;
  bool _reconnecting = false;
  bool _connecting = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  bool _awaitingPong = false;
  // In-flight liveness probes (checkAlive), keyed by the PING token each one
  // sends; a PONG is only accepted for the exact token it echoes.
  final _pingAwaiters = <String, Completer<bool>>{};
  int _pingSeq = 0;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isOnline = true;
  final _channels = <String>{};

  StreamSubscription<dynamic>? _streamSub;
  Timer? _pingTimer;
  Timer? _pongTimer;
  Timer? _connectTimer;
  Timer? _reconnectTimer;

  final _statusController = StreamController<IrcConnectionStatus>.broadcast(
    sync: true,
  );

  Stream<IrcConnectionStatus> get onStatus => _statusController.stream;
  bool get isConnected => channel != null;

  String get debugPrefix;

  BaseIrcConnection({this.connectivity});

  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {
    this.username = username.toLowerCase();
    token = accessToken;
    await _connect();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    try {
      if (isConnected) {
        debugPrint('[$debugPrefix] already connected, skipping reconnect');
        return;
      }
      _statusController.add(IrcConnectionStatus.connecting);
      _ensureConnectivityListener();
      _disconnect();
      _awaitingPong = false;

      WebSocketChannel? newChannel;
      try {
        newChannel = await openChannel();
        await _waitForReady(newChannel);
        // Only claim the socket once the handshake completed; isConnected
        // must stay false while the connection is still being established,
        // otherwise the type bar hint flashes "connected" during the attempt.
        channel = newChannel;

        _streamSub = channel!.stream.listen(
          (raw) => _handleLine(raw as String),
          onError: (e) {
            debugPrint('$debugPrefix stream error: $e');
            // Clear the socket before notifying so listeners rebuilding on the
            // status event (e.g. the type bar hint) never read a stale
            // "connected" state.
            _disconnect();
            _statusController.add(IrcConnectionStatus.disconnected);
            _scheduleReconnect();
          },
          onDone: () {
            debugPrint(
              '$debugPrefix stream closed '
              '(code: ${channel?.closeCode}, '
              'reason: ${channel?.closeReason})',
            );
            _disconnect();
            _statusController.add(IrcConnectionStatus.disconnected);
            _scheduleReconnect();
          },
        );

        sendLine('CAP REQ :twitch.tv/tags twitch.tv/commands');
        sendLine('PASS oauth:$token');
        sendLine('NICK $username');
        debugPrint(
          '[$debugPrefix] connected, re-joining '
          '${_channels.length} channels: $_channels',
        );

        for (final channel in _channels) {
          sendLine('JOIN #$channel');
        }

        _statusController.add(IrcConnectionStatus.connected);
        _reconnectAttempt = 0;

        _startPingTimer();
      } catch (e) {
        debugPrint('$debugPrefix connect error: $e');
        // A failed attempt must not leave a socket behind: otherwise
        // isConnected stays true and every reconnect bails out here. A
        // timed-out handshake also gets its socket closed so it can't leak.
        newChannel?.sink.close();
        channel = null;
        _statusController.add(IrcConnectionStatus.disconnected);
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  void _ensureConnectivityListener() {
    final conn = connectivity;
    if (conn == null || _connectivitySub != null) return;
    _connectivitySub = conn.onConnectivityChanged.listen((results) {
      final wasOffline = !_isOnline;
      _isOnline = !results.contains(ConnectivityResult.none);
      if (wasOffline && _isOnline && channel == null && !_connecting) {
        _reconnectAttempt = 0;
        _connect();
      }
    });
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
    debugPrint('$debugPrefix PONG timeout - reconnecting');
    // Clear the socket before the status event so listeners that rebuild on it
    // (e.g. the type bar hint) don't briefly show "connected".
    _disconnect();
    _statusController.add(IrcConnectionStatus.disconnected);
    _scheduleReconnect();
  }

  void _disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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
    _reconnecting = false;
  }

  // DankChat-style backoff: 1s, 2s, 4s, then 8s forever (±25% jitter). The
  // attempt counter survives _disconnect so it actually accumulates; it is
  // reset on a successful connect or any received line.
  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    if (!_isOnline) return;
    _reconnecting = true;
    _reconnectAttempt++;
    final capped = _reconnectAttempt.clamp(1, _maxReconnectDelayAttempts);
    final delay = applyReconnectJitter(Duration(seconds: 1 << (capped - 1)));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnecting = false;
      if (!_disposed && username != null && token != null) {
        _connect();
      }
    });
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

  /// Kills the (possibly zombie) socket and re-enters the reconnect loop;
  /// used when [checkAlive] fails but the socket never errored on its own.
  void forceReconnect() {
    if (channel == null) return;
    debugPrint('$debugPrefix force reconnect (unhealthy socket)');
    // Clear the zombie socket now; otherwise the reconnect attempt would
    // bail out on isConnected before replacing it. Do it before the status
    // event so rebuilding listeners see a real disconnect, not a stale one.
    _disconnect();
    _statusController.add(IrcConnectionStatus.disconnected);
    _reconnectAttempt = 0;
    _scheduleReconnect();
  }

  void sendLine(String message) {
    try {
      channel?.sink.add(message);
    } catch (e) {
      debugPrint('$debugPrefix send failed: $e');
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
        debugPrint('$debugPrefix server requested reconnect');
        _disconnect();
        _statusController.add(IrcConnectionStatus.disconnected);
        _scheduleReconnect();
        continue;
      }

      dispatchLine(line);
    }
  }

  @visibleForTesting
  void handleLine(String raw) => _handleLine(raw);

  @visibleForTesting
  bool get awaitingPong => _awaitingPong;

  @visibleForTesting
  set awaitingPong(bool value) => _awaitingPong = value;

  void dispatchLine(String line);

  void join(String channel) {
    debugPrint('[$debugPrefix] join channel=$channel');
    _channels.add(channel);
    if (this.channel != null) {
      sendLine('JOIN #$channel');
    }
  }

  void part(String channel) {
    debugPrint('[$debugPrefix] part channel=$channel');
    _channels.remove(channel);
    if (this.channel != null) {
      sendLine('PART #$channel');
    }
  }

  @mustCallSuper
  void dispose() {
    _disposed = true;
    _reconnecting = false;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pongTimer?.cancel();
    _connectTimer?.cancel();
    _streamSub?.cancel();
    channel?.sink.close();
    _statusController.close();
  }
}
