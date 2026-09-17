import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/point_rewards.dart';
import '../util/connectivity.dart';
import '../util/constants.dart';
import '../util/log.dart';

/// One PubSub redemption, already resolved to its channel.
class PubSubPointRedemption {
  const PubSubPointRedemption({
    required this.channel,
    required this.redemption,
  });

  final String channel;
  final PointRedemption redemption;
}

/// Unauthenticated PubSub client for `community-points-channel-v1.*`.
///
/// Direct port of DankChat's `PubSubConnection` points path: the redemption
/// topic needs no `auth_token`, so viewers see every joined channel. The
/// socket is otherwise silent: a `PING` every 5 minutes plus one small
/// `reward-redeemed` frame per redeem. Deprecated upstream and able to die
/// without notice; failures degrade to the IRC-only highlight path.
class PubSubPointsService {
  PubSubPointsService({this.connectivityService});

  static const _wsUrl = 'wss://pubsub-edge.twitch.tv';
  static const _maxReconnectAttempts = 8;
  static const _connectTimeout = Duration(seconds: 10);

  /// DankChat's ping cadence, minus a small jitter so reconnects desync.
  static const _pingInterval = Duration(minutes: 5);
  static const _maxJitterMs = 250;
  static const _pingPayload = '{"type":"PING"}';

  final ConnectivityService? connectivityService;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _streamSub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _connectTimer;
  bool _awaitingPong = false;
  bool _connecting = false;
  bool _disposed = false;
  bool _isOnline = true;
  bool _reconnecting = false;
  int _reconnectAttempt = 0;
  DateTime _lastActivity = DateTime.now();
  VoidCallback? _connectivityListener;
  final _rng = Random();

  /// Full topic string per channel name. Re-listened on every reconnect.
  final _topicsByChannel = <String, String>{};
  final _redemptionController =
      StreamController<PubSubPointRedemption>.broadcast(sync: true);

  Stream<PubSubPointRedemption> get onRedemption =>
      _redemptionController.stream;
  bool get isConnected => _channel != null;

  /// True when the socket exists but nothing arrived for >1.5x the ping
  /// interval (zombie).
  bool get isStale {
    if (_channel == null) return false;
    const timeout = Duration(milliseconds: 450000);
    return DateTime.now().difference(_lastActivity) > timeout;
  }

  /// Starts (or joins) listening for a channel. Idempotent per channel.
  void listen(String channelName, String channelId) {
    final topic = 'community-points-channel-v1.$channelId';
    if (_topicsByChannel[channelName] == topic) return;
    final old = _topicsByChannel[channelName];
    if (old != null) _sendSingle('UNLISTEN', [old]);
    _topicsByChannel[channelName] = topic;
    if (isConnected) {
      _sendSingle('LISTEN', [topic]);
    } else {
      unawaited(connect());
    }
  }

  /// Stops listening for a channel (parted). Keeps the socket for the rest.
  void unlistenChannel(String channelName) {
    final topic = _topicsByChannel.remove(channelName);
    if (topic != null && isConnected) _sendSingle('UNLISTEN', [topic]);
  }

  /// Drops per-channel state (channel left). Skip sets do not exist here:
  /// unauth topics never 403.
  void forgetChannel(String channelName) => unlistenChannel(channelName);

  Future<void> connect() async {
    if (_connecting || _disposed) return;
    _connecting = true;
    try {
      _ensureConnectivityListener();
      disconnect(emitStatus: false);
      try {
        _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
        await _waitForReady();
        _lastActivity = DateTime.now();
        _awaitingPong = false;
        _reconnectAttempt = 0;
        _streamSub = _channel!.stream.listen(
          (raw) {
            if (raw is! String) return;
            _handleFrame(raw);
          },
          onError: (_) => _scheduleReconnect(),
          onDone: () => _scheduleReconnect(),
        );
        _resubscribeAll();
        _armPing();
      } catch (e) {
        logDebug('PubSub points connect error: $e');
        _channel = null;
        _streamSub = null;
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  /// Tears down a zombie session and reconnects. Used on app resume.
  Future<void> forceReconnect() {
    if (_disposed || _connecting) return Future.value();
    disconnect();
    return connect();
  }

  void reconnectIfNecessary() {
    if (_disposed || _connecting) return;
    if (!isConnected || isStale || _awaitingPong) {
      unawaited(forceReconnect());
    }
  }

  void disconnect({bool emitStatus = true}) {
    _reconnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _awaitingPong = false;
    _streamSub?.cancel();
    _streamSub = null;
    // ignore: avoid-ignoring-return-values
    _channel?.sink.close();
    _channel = null;
    if (emitStatus) {
      // No status stream: liveness polls isConnected/isStale instead.
    }
  }

  void _resubscribeAll() {
    final topics = _topicsByChannel.values.toSet();
    if (topics.isEmpty) return;
    // DankChat batches 50 topics per LISTEN; channel counts here are small,
    // so one frame suffices.
    _sendSingle('LISTEN', topics.toList());
  }

  void _sendSingle(String type, List<String> topics) {
    final channel = _channel;
    if (channel == null || topics.isEmpty) return;
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32)}';
    channel.sink.add(
      jsonEncode({
        'type': type,
        'nonce': nonce,
        'data': {'topics': topics},
      }),
    );
  }

  void _armPing() {
    _pingTimer?.cancel();
    final jitter = Duration(milliseconds: _rng.nextInt(_maxJitterMs + 1));
    final interval = _pingInterval - jitter;
    _pingTimer = Timer.periodic(interval, (_) {
      final channel = _channel;
      if (channel == null) return;
      if (_awaitingPong) {
        logDebug('PubSub points pong missed - reconnecting');
        unawaited(forceReconnect());
        return;
      }
      _awaitingPong = true;
      channel.sink.add(_pingPayload);
    });
  }

  void _handleFrame(String raw) {
    _lastActivity = DateTime.now();
    Map<String, dynamic> frame;
    try {
      frame = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      logDebug('PubSub points frame parse error: $e');
      return;
    }
    final type = frame['type'] as String?;
    switch (type) {
      case 'PONG':
        _awaitingPong = false;
      case 'RECONNECT':
        unawaited(forceReconnect());
      case 'RESPONSE':
        final error = frame['error'] as String?;
        if (error != null && error.isNotEmpty) {
          logDebug('PubSub points LISTEN rejected: $error');
        }
      case 'MESSAGE':
        _handleMessage(frame);
      default:
        break;
    }
  }

  void _handleMessage(Map<String, dynamic> frame) {
    try {
      final data = frame['data'] as Map<String, dynamic>?;
      final topic = data?['topic'] as String?;
      final rawMessage = data?['message'] as String?;
      if (topic == null || rawMessage == null) return;
      final channel = _topicChannel(topic);
      if (channel == null) return;
      final inner = jsonDecode(rawMessage) as Map<String, dynamic>;
      if (inner['type'] != 'reward-redeemed') return;
      final payload = inner['data'] as Map<String, dynamic>?;
      final redemption = payload?['redemption'] as Map<String, dynamic>?;
      final timestamp = payload?['timestamp'] as String?;
      if (redemption == null || timestamp == null) return;
      _redemptionController.add(
        PubSubPointRedemption(
          channel: channel,
          redemption: PointRedemption.fromPubSub(redemption, timestamp),
        ),
      );
    } catch (e) {
      logDebug('PubSub points message parse error: $e');
    }
  }

  String? _topicChannel(String topic) {
    for (final entry in _topicsByChannel.entries) {
      if (entry.value == topic) return entry.key;
    }
    return null;
  }

  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    if (!_isOnline) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      logDebug('PubSub points max reconnect attempts reached - giving up');
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
      unawaited(connect());
    });
  }

  Future<void> _waitForReady() {
    final channel = _channel;
    if (channel == null) return Future.value();
    final completer = Completer<void>();
    _connectTimer?.cancel();
    _connectTimer = Timer(_connectTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('PubSub points timed out'));
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

  void _ensureConnectivityListener() {
    final service = connectivityService;
    if (service == null || _connectivityListener != null) return;
    _connectivityListener = () {
      final online = service.isOnline;
      final wasOffline = !_isOnline;
      _isOnline = online;
      if (wasOffline && online && _channel == null && !_connecting) {
        _reconnectAttempt = 0;
        unawaited(connect());
      }
    };
    _isOnline = service.isOnline;
    service.addListener(_connectivityListener!);
  }

  /// Test hook into the same router the socket uses.
  @visibleForTesting
  void feedText(String raw) => _handleFrame(raw);

  /// Test hook: registers a topic mapping without opening a socket.
  @visibleForTesting
  void seedTopic(String channelName, String channelId) {
    _topicsByChannel[channelName] = 'community-points-channel-v1.$channelId';
  }

  void dispose() {
    _disposed = true;
    disconnect();
    final listener = _connectivityListener;
    if (listener != null) connectivityService?.removeListener(listener);
    _connectivityListener = null;
    _redemptionController.close();
  }
}
