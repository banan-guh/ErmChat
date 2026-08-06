import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../util/constants.dart';

/// A channel.moderate v2 event: a moderator performed a moderation action.
/// `action` is one of ban, timeout, unban, untimeout, clear, delete, mod,
/// unmod, vip, unvip, warn (or shared_chat_* variants).
class ModerationEvent {
  final String channel;
  final String action;
  final String moderatorName;
  final String? targetName;
  final String? reason;
  final int? durationSeconds;
  final String? messageId;
  final String? messageBody;

  ModerationEvent({
    required this.channel,
    required this.action,
    required this.moderatorName,
    this.targetName,
    this.reason,
    this.durationSeconds,
    this.messageId,
    this.messageBody,
  });
}

class EventSubService {
  static const _wsUrl = 'wss://eventsub.wss.twitch.tv/ws';
  static const _maxReconnectAttempts = 8;
  static const _connectTimeout = Duration(seconds: 10);

  final Connectivity? _connectivity;

  WebSocketChannel? _channel;
  String? _sessionId;
  // When the last frame of any kind arrived; used by [isStale] to spot a
  // zombie session on app resume.
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
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isOnline = true;
  final _channelUserIds = <String, String>{};

  final _moderationController = StreamController<ModerationEvent>.broadcast(
    sync: true,
  );
  final _statusController = StreamController<EventSubStatus>.broadcast(
    sync: true,
  );

  bool get isConnected => _channel != null;
  String? get sessionId => _sessionId;

  /// True when the socket exists but no frame has arrived for well over the
  /// keepalive window, i.e. a zombie session that never errored on its own
  /// (e.g. frozen by the OS while backgrounded).
  bool get isStale {
    if (_channel == null) return false;
    final timeoutSeconds = (_keepaliveTimeout * 1.5).round();
    return DateTime.now().difference(_lastActivity).inSeconds > timeoutSeconds;
  }

  /// Tears down a (possibly zombie) session and re-enters the reconnect path.
  /// Used on app resume where [isConnected] alone can't be trusted.
  Future<void> forceReconnect() {
    if (_disposed || _connecting) return Future.value();
    disconnect();
    return connect();
  }

  EventSubService({this._connectivity});

  Stream<ModerationEvent> get onModeration => _moderationController.stream;
  Stream<EventSubStatus> get onStatus => _statusController.stream;

  void setChannelMapping(String broadcasterUserId, String channelName) {
    _channelUserIds[broadcasterUserId] = channelName;
  }

  String? _channelFromPayload(Map<String, dynamic> msg) {
    try {
      final payload = msg['payload'] as Map<String, dynamic>;
      final sub = payload['subscription'] as Map<String, dynamic>;
      final condition = sub['condition'] as Map<String, dynamic>;
      final userId = condition['broadcaster_user_id'] as String;
      return _channelUserIds[userId];
    } catch (_) {
      debugPrint('[EventSub] failed to extract channel from payload');
      return null;
    }
  }

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
            final msg = jsonDecode(raw as String) as Map<String, dynamic>;
            _handleMessage(msg);
          },
          onError: (e) {
            debugPrint('EventSub stream error: $e');
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
        // A failed or timed-out handshake must not leave a socket behind,
        // otherwise isConnected stays true and resume-time checks skip it.
        _channel = null;
        _streamSub = null;
        _statusController.add(EventSubStatus.disconnected);
        debugPrint('EventSub connect error: $e');
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  // Faster backoff than IRC (2^(n-1) vs 2^(n-2)): EventSub reconnects are
  // cheaper since no channel rejoin is needed. Capped at 30s with jitter.
  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    if (!_isOnline) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      debugPrint('EventSub max reconnect attempts reached – giving up');
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

  /// Waits for the WebSocket handshake with an upper bound. The timeout timer
  /// is tracked and cancelled on disconnect/dispose so a torn-down connect
  /// never leaves a pending timer behind.
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
    final meta = msg['metadata'] as Map<String, dynamic>;
    final type = meta['message_type'] as String;

    switch (type) {
      case 'session_welcome':
        _onWelcome(msg);
      case 'notification':
        _onNotification(msg);
      case 'session_reconnect':
        _handleReconnect(msg);
      case 'revocation':
        debugPrint('EventSub subscription revoked');
    }

    _resetKeepalive();
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
        debugPrint('EventSub reconnecting to $reconnectUrl');
        connect(url: reconnectUrl);
      }
    } catch (e) {
      debugPrint('EventSub reconnect failed: $e');
    }
  }

  // Reset on any message, not just keepalives — Twitch may skip explicit
  // keepalive frames during active chat. 1.5x multiplier gives grace period.
  void _resetKeepalive() {
    _lastActivity = DateTime.now();
    _keepaliveTimer?.cancel();
    final timeoutSeconds = (_keepaliveTimeout * 1.5).round();
    _keepaliveTimer = Timer(Duration(seconds: timeoutSeconds), () {
      debugPrint('EventSub keepalive timeout – reconnecting');
      _scheduleReconnect();
    });
  }

  /// Routes channel.moderate v2 notifications into [ModerationEvent]s.
  void _onNotification(Map<String, dynamic> msg) {
    final meta = msg['metadata'] as Map<String, dynamic>;
    if (meta['subscription_type'] != 'channel.moderate') return;

    final payload = msg['payload'] as Map<String, dynamic>;
    final event = payload['event'] as Map<String, dynamic>;
    final channel = _channelFromPayload(msg);
    if (channel == null) return;

    final action = event['action'] as String? ?? '';
    if (action.isEmpty) return;
    final moderatorName =
        event['moderator_user_name'] as String? ?? 'A moderator';

    // Map shared_chat_* actions to their base action.
    var baseAction = action;
    if (action.startsWith('shared_chat_')) {
      baseAction = action.substring('shared_chat_'.length);
    }

    String? targetName;
    String? reason;
    int? durationSeconds;
    String? messageId;
    String? messageBody;

    final metaObj = event[baseAction] as Map<String, dynamic>?;
    switch (baseAction) {
      case 'ban':
      case 'unban':
      case 'mod':
      case 'unmod':
      case 'vip':
      case 'unvip':
      case 'untimeout':
        targetName = metaObj?['user_name'] as String?;
        reason = metaObj?['reason'] as String?;
        break;
      case 'warn':
        targetName = metaObj?['user_name'] as String?;
        reason = metaObj?['reason'] as String?;
        break;
      case 'timeout':
        targetName = metaObj?['user_name'] as String?;
        reason = metaObj?['reason'] as String?;
        final expiresAt = metaObj?['expires_at'] as String?;
        if (expiresAt != null) {
          final parsed = DateTime.tryParse(expiresAt);
          if (parsed != null) {
            durationSeconds = parsed
                .difference(DateTime.now().toUtc())
                .inSeconds
                .clamp(0, 1 << 30);
          }
        }
        break;
      case 'delete':
        targetName = metaObj?['user_name'] as String?;
        messageId = metaObj?['message_id'] as String?;
        messageBody = metaObj?['message_body'] as String?;
        break;
    }

    _moderationController.add(
      ModerationEvent(
        channel: channel,
        action: baseAction,
        moderatorName: moderatorName,
        targetName: targetName,
        reason: reason,
        durationSeconds: durationSeconds,
        messageId: messageId,
        messageBody: messageBody,
      ),
    );
  }

  void _ensureConnectivityListener() {
    if (_connectivity == null || _connectivitySub != null) return;
    _connectivitySub = _connectivity.onConnectivityChanged.listen((results) {
      final wasOffline = !_isOnline;
      _isOnline = !results.contains(ConnectivityResult.none);
      if (wasOffline && _isOnline && _channel == null && !_connecting) {
        _reconnectAttempt = 0;
        connect();
      }
    });
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
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _moderationController.close();
    _statusController.close();
  }
}

enum EventSubStatus { connecting, connected, disconnected }
