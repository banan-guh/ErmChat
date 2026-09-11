import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../services/connectivity_service.dart';
import '../../util/constants.dart';
import '../../util/log.dart';
import 'events.dart';

class EventSubService {
  static const _wsUrl = 'wss://eventsub.wss.twitch.tv/ws';
  static const _maxReconnectAttempts = 8;
  static const _connectTimeout = Duration(seconds: 10);

  final ConnectivityService? _connectivityService;

  WebSocketChannel? _channel;
  String? _sessionId;
  // Last frame arrival time; used by [isStale].
  DateTime _lastActivity = DateTime.now();
  Timer? _keepaliveTimer;
  Timer? _reconnectTimer;
  Timer? _connectTimer;
  int _keepaliveTimeout = 10;
  var _sessionCompleter = Completer<String?>();
  StreamSubscription<dynamic>? _streamSub;
  bool _reconnecting = false;
  bool _connecting = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  VoidCallback? _connectivityListener;
  bool _isOnline = true;

  final _notificationController =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _statusController = StreamController<EventSubStatus>.broadcast(
    sync: true,
  );

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
    if (_disposed || _connecting) return Future.value();
    disconnect();
    return connect();
  }

  EventSubService({this._connectivityService});

  Stream<Map<String, dynamic>> get onNotification =>
      _notificationController.stream;
  Stream<EventSubStatus> get onStatus => _statusController.stream;

  @visibleForTesting
  Future<String?> waitForSession() {
    if (_sessionId != null) return Future.value(_sessionId);
    return _sessionCompleter.future;
  }

  Future<void> connect({String? url}) async {
    if (_connecting || _disposed) return;
    _connecting = true;
    try {
      _ensureConnectivityListener();
      if (url != null) _reconnectAttempt = 0;
      disconnect(emitStatus: false);
      _sessionCompleter = Completer<String?>();
      _statusController.add(EventSubStatus.connecting);

      try {
        _channel = WebSocketChannel.connect(Uri.parse(url ?? _wsUrl));
        await _waitForReady();

        _streamSub = _channel!.stream.listen(
          (raw) {
            if (raw is! String) return;
            try {
              final msg = jsonDecode(raw) as Map<String, dynamic>;
              _handleMessage(msg);
            } catch (e) {
              logDebug('EventSub frame parse error: $e');
            }
          },
          onError: (e) {
            logDebug('EventSub stream error: $e');
            _safeComplete(null);
            _statusController.add(EventSubStatus.disconnected);
            _scheduleReconnect();
          },
          onDone: () {
            _safeComplete(null);
            _statusController.add(EventSubStatus.disconnected);
            _scheduleReconnect();
          },
        );
      } catch (e) {
        _safeComplete(null);
        // Prevent stale socket from keeping isConnected true on resume.
        _channel = null;
        _streamSub = null;
        _statusController.add(EventSubStatus.disconnected);
        logDebug('EventSub connect error: $e');
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  // Exponential backoff (2^(n-1)), capped 30s with jitter.
  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    if (!_isOnline) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      logDebug('EventSub max reconnect attempts reached - giving up');
      return;
    }
    _reconnecting = true;
    _reconnectAttempt++;
    final base = Duration(
      seconds: min(pow(2, _reconnectAttempt - 1).toInt(), 30),
    );
    final delay = applyReconnectJitter(base);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnecting = false;
      connect();
    });
  }

  void _safeComplete(String? value) {
    if (!_sessionCompleter.isCompleted) {
      _sessionCompleter.complete(value);
    }
  }

  /// Waits for handshake with a timeout; timer cleaned up on
  /// disconnect/dispose.
  Future<void> _waitForReady() {
    final channel = _channel;
    if (channel == null) return Future.value();
    final completer = Completer<void>();
    _connectTimer?.cancel();
    _connectTimer = Timer(_connectTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('EventSub connect timed out'));
      }
    });
    channel.ready.then(
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
          logDebug('EventSub subscription revoked');
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
    _reconnectAttempt = 0;
  }

  void _handleReconnect(Map<String, dynamic> msg) {
    try {
      final payload = msg['payload'] as Map<String, dynamic>;
      final session = payload['session'] as Map<String, dynamic>;
      final reconnectUrl = session['reconnect_url'] as String?;
      if (reconnectUrl != null && reconnectUrl.isNotEmpty) {
        logDebug('EventSub reconnecting to $reconnectUrl');
        connect(url: reconnectUrl);
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
      _scheduleReconnect();
    });
  }

  void _ensureConnectivityListener() {
    final service = _connectivityService;
    if (service == null || _connectivityListener != null) return;
    _connectivityListener = () {
      final online = service.isOnline;
      final wasOffline = !_isOnline;
      _isOnline = online;
      if (wasOffline && online && _channel == null && !_connecting) {
        _reconnectAttempt = 0;
        connect();
      }
    };
    _isOnline = service.isOnline;
    service.addListener(_connectivityListener!);
  }

  void disconnect({bool emitStatus = true}) {
    _reconnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _sessionId = null;
    _streamSub?.cancel();
    _streamSub = null;
    _channel?.sink.close();
    _channel = null;
    _reconnectAttempt = 0;
    _safeComplete(null);
    if (emitStatus) _statusController.add(EventSubStatus.disconnected);
  }

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
    final listener = _connectivityListener;
    if (listener != null) _connectivityService?.removeListener(listener);
    _connectivityListener = null;
    _notificationController.close();
    _statusController.close();
  }
}
