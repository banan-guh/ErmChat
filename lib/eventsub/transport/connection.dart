import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../util/connectivity.dart';
import '../../util/constants.dart';
import '../../util/log.dart';
import '../../util/socket_loop.dart';
import 'events.dart';
import '../../util/data_usage.dart';

class EventSubService {
  static const _wsUrl = 'wss://eventsub.wss.twitch.tv/ws';
  static const _maxReconnectAttempts = 8;
  static const _connectTimeout = Duration(seconds: 10);

  WebSocketChannel? _channel;
  String? _sessionId;
  // Last frame arrival time; used by [isStale].
  DateTime _lastActivity = DateTime.now();
  Timer? _keepaliveTimer;
  int _keepaliveTimeout = 10;
  var _sessionCompleter = Completer<String?>();
  StreamSubscription<dynamic>? _streamSub;
  bool _disposed = false;

  // Completes when the serving socket ends, with how the loop goes on.
  Completer<SocketEnd>? _socketEnd;
  SocketRun? _run;
  // Where the next attempt dials: a session_reconnect URL, once.
  String? _reconnectUrl;

  late final SocketLoop _loop;

  final _notificationController =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _statusController = StreamController<EventSubStatus>.broadcast(
    sync: true,
  );
  final _revocationController =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  bool get isConnected => _channel != null;
  String? get sessionId => _sessionId;

  /// True when socket exists but no frame arrived for >1.5x keepalive
  /// (zombie).
  bool get isStale {
    if (_channel == null) return false;
    final timeoutSeconds = (_keepaliveTimeout * 1.5).round();
    return DateTime.now().difference(_lastActivity).inSeconds > timeoutSeconds;
  }

  /// Tears down zombie session and reconnects. Used on app resume.
  Future<void> forceReconnect() {
    if (_disposed) return Future.value();
    disconnect();
    return connect();
  }

  EventSubService({ConnectivityService? connectivityService}) {
    _loop = SocketLoop(
      name: 'EventSub',
      attempt: _attempt,
      // Exponential (2^(n-1)), capped 30s with jitter.
      backoff: (failures) => applyReconnectJitter(
        Duration(seconds: min(pow(2, failures - 1).toInt(), 30)),
      ),
      maxAttempts: _maxReconnectAttempts,
      connectivity: connectivityService,
      connectTimeout: _connectTimeout,
    );
  }

  Stream<Map<String, dynamic>> get onNotification =>
      _notificationController.stream;
  Stream<EventSubStatus> get onStatus => _statusController.stream;

  /// Revoked subscriptions (the payload's `subscription` object), e.g.
  /// `moderator_removed` when the user loses mod in a channel.
  Stream<Map<String, dynamic>> get onRevocation => _revocationController.stream;

  @visibleForTesting
  Future<String?> waitForSession() {
    if (_sessionId != null) return Future.value(_sessionId);
    return _sessionCompleter.future;
  }

  /// Opens a new session, replacing any socket or retry in flight.
  /// Completes once the first handshake opened or failed.
  Future<void> connect() {
    if (_disposed) return Future.value();
    _teardown();
    _reconnectUrl = null;
    return _loop.start();
  }

  /// One socket: dials, serves it until it ends, and says how the loop goes
  /// on.
  Future<SocketEnd> _attempt(SocketRun run) async {
    _run = run;
    final url = _reconnectUrl ?? _wsUrl;
    _reconnectUrl = null;
    if (_sessionCompleter.isCompleted) _sessionCompleter = Completer<String?>();
    _statusController.add(EventSubStatus.connecting);
    final channel = openChannel(url);
    try {
      await run.ready(channel);
    } catch (e) {
      // A timed-out handshake gets its socket closed so it can't leak.
      channel.sink.close();
      _safeComplete(null);
      if (!run.live) return SocketEnd.dropped;
      logDebug('EventSub connect error: $e');
      _statusController.add(EventSubStatus.disconnected);
      return SocketEnd.dropped;
    }
    _channel = channel;
    final end = Completer<SocketEnd>();
    _socketEnd = end;
    _streamSub = channel.stream.listen(
      (raw) {
        if (raw is! String) return;
        DataUsageStats.I.recordEvent(DataUsageStats.utf8Length(raw));
        try {
          final msg = jsonDecode(raw) as Map<String, dynamic>;
          _handleMessage(msg);
        } catch (e) {
          logDebug('EventSub frame parse error: $e');
        }
      },
      onError: (e) {
        logDebug('EventSub stream error: $e');
        _endSocket(SocketEnd.dropped);
      },
      onDone: () => _endSocket(SocketEnd.dropped),
    );
    final how = await end.future;
    // A disconnect or restart already tore this socket down.
    if (!run.live) return SocketEnd.dropped;
    _teardown();
    _statusController.add(EventSubStatus.disconnected);
    return how;
  }

  /// Opens the socket; overridable in tests.
  @visibleForTesting
  WebSocketChannel openChannel(String url) =>
      WebSocketChannel.connect(Uri.parse(url));

  void _endSocket(SocketEnd how) {
    final end = _socketEnd;
    _socketEnd = null;
    if (end != null && !end.isCompleted) end.complete(how);
  }

  void _safeComplete(String? value) {
    if (!_sessionCompleter.isCompleted) {
      _sessionCompleter.complete(value);
    }
  }

  void _handleMessage(Map<String, dynamic> msg) {
    try {
      final meta = msg['metadata'] as Map<String, dynamic>?;
      final type = meta?['message_type'] as String?;
      if (type == null) return;

      switch (type) {
        case 'session_welcome':
          _onWelcome(msg);
        case 'notification':
          _notificationController.add(msg);
        case 'session_reconnect':
          _handleReconnect(msg);
        case 'revocation':
          final payload = msg['payload'] as Map<String, dynamic>?;
          final sub = payload?['subscription'] as Map<String, dynamic>?;
          logDebug('EventSub subscription revoked: ${sub?['status']}');
          if (sub != null) _revocationController.add(sub);
      }

      _resetKeepalive();
    } catch (e) {
      logDebug('EventSub message parse error: $e');
    }
  }

  void _onWelcome(Map<String, dynamic> msg) {
    final payload = msg['payload'] as Map<String, dynamic>;
    final session = payload['session'] as Map<String, dynamic>;
    _sessionId = session['id'] as String;
    _safeComplete(_sessionId);
    _keepaliveTimeout = session['keepalive_timeout_seconds'] as int? ?? 10;
    _resetKeepalive();
    _statusController.add(EventSubStatus.connected);
    _run?.opened();
  }

  void _handleReconnect(Map<String, dynamic> msg) {
    try {
      final payload = msg['payload'] as Map<String, dynamic>;
      final session = payload['session'] as Map<String, dynamic>;
      final reconnectUrl = session['reconnect_url'] as String?;
      if (reconnectUrl != null && reconnectUrl.isNotEmpty) {
        logDebug('EventSub reconnecting to $reconnectUrl');
        _reconnectUrl = reconnectUrl;
        _endSocket(SocketEnd.reconnectNow);
      }
    } catch (e) {
      logDebug('EventSub reconnect failed: $e');
    }
  }

  // Reset on any message (Twitch may skip keepalives). 1.5x grace period.
  void _resetKeepalive() {
    _lastActivity = DateTime.now();
    _keepaliveTimer?.cancel();
    final timeoutSeconds = (_keepaliveTimeout * 1.5).round();
    _keepaliveTimer = Timer(Duration(seconds: timeoutSeconds), () {
      logDebug('EventSub keepalive timeout - reconnecting');
      _endSocket(SocketEnd.dropped);
    });
  }

  /// Closes the session and stops reconnecting until the next [connect].
  void disconnect({bool emitStatus = true}) {
    _loop.stop();
    _teardown();
    if (emitStatus) _statusController.add(EventSubStatus.disconnected);
  }

  void _teardown() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _sessionId = null;
    _streamSub?.cancel();
    _streamSub = null;
    _channel?.sink.close();
    _channel = null;
    _safeComplete(null);
    _endSocket(SocketEnd.dropped);
  }

  @visibleForTesting
  int get reconnectAttempt => _loop.failures;

  @visibleForTesting
  void handleRawMessage(Map<String, dynamic> msg) => _handleMessage(msg);

  @visibleForTesting
  void emitConnected() {
    _sessionId = 'test-session-id';
    _keepaliveTimeout = 10;
    _statusController.add(EventSubStatus.connected);
  }

  void dispose() {
    _disposed = true;
    disconnect();
    _loop.dispose();
    _notificationController.close();
    _statusController.close();
    _revocationController.close();
  }
}
