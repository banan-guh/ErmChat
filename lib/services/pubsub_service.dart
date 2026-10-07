import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../eventsub/decode/events.dart';
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

/// Unauthenticated PubSub client for channel points, hype trains,
/// predictions, polls and pinned messages.
///
/// The connection is a port of DankChat's `PubSubConnection`. None of these
/// topics need an `auth_token`, so viewers get them for every joined channel
/// (EventSub only serves the broadcaster). Deprecated upstream and able to
/// die without notice; failures degrade to the IRC highlight path and the
/// broadcaster's EventSub widgets.
class PubSubService {
  PubSubService({this.connectivityService});

  static const _wsUrl = 'wss://pubsub-edge.twitch.tv';
  static const _maxReconnectAttempts = 8;
  static const _connectTimeout = Duration(seconds: 10);

  /// DankChat's ping cadence, minus a small jitter so reconnects desync.
  static const _pingInterval = Duration(minutes: 5);
  static const _maxJitterMs = 250;
  static const _pingPayload = '{"type":"PING"}';
  static const _redemptionTypes = {
    'reward-redeemed',
    'automatic-reward-redeemed',
  };

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

  /// Topics per channel name. Re-listened on every reconnect.
  final _topicsByChannel = <String, List<String>>{};
  final _channelByTopic = <String, String>{};

  /// Last known hype train expiry per channel; level-ups may omit it.
  final _hypeExpiry = <String, DateTime>{};
  final _redemptionController =
      StreamController<PubSubPointRedemption>.broadcast(sync: true);
  final _hypeTrainController = StreamController<HypeTrainEvent>.broadcast(
    sync: true,
  );
  final _pollController = StreamController<PollEvent>.broadcast(sync: true);
  final _predictionController = StreamController<PredictionEvent>.broadcast(
    sync: true,
  );
  final _pinnedController = StreamController<PinnedMessageEvent>.broadcast(
    sync: true,
  );

  Stream<PubSubPointRedemption> get onRedemption =>
      _redemptionController.stream;
  Stream<HypeTrainEvent> get onHypeTrain => _hypeTrainController.stream;
  Stream<PollEvent> get onPoll => _pollController.stream;
  Stream<PredictionEvent> get onPrediction => _predictionController.stream;
  Stream<PinnedMessageEvent> get onPinned => _pinnedController.stream;

  static List<String> _topicsFor(String channelId) => [
    'community-points-channel-v1.$channelId',
    'hype-train-events-v1.$channelId',
    'predictions-channel-v1.$channelId',
    'polls.$channelId',
    'pinned-chat-updates-v1.$channelId',
  ];
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
    final topics = _topicsFor(channelId);
    if (_topicsByChannel[channelName]?.first == topics.first) return;
    unlistenChannel(channelName);
    _topicsByChannel[channelName] = topics;
    for (final t in topics) {
      _channelByTopic[t] = channelName;
    }
    if (isConnected) {
      _sendSingle('LISTEN', topics);
    } else {
      unawaited(connect());
    }
  }

  /// Stops listening for a channel (parted). Keeps the socket for the rest.
  void unlistenChannel(String channelName) {
    final topics = _topicsByChannel.remove(channelName);
    if (topics == null) return;
    topics.forEach(_channelByTopic.remove);
    _hypeExpiry.remove(channelName);
    if (isConnected) _sendSingle('UNLISTEN', topics);
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
        _channel = openChannel();
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
        logDebug('PubSub connect error: $e');
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

  /// One LISTEN per channel: Twitch silently drops the socket on a frame over
  /// about 1 KB, which all channels' topics together exceed.
  void _resubscribeAll() {
    for (final topics in _topicsByChannel.values) {
      _sendSingle('LISTEN', topics);
    }
  }

  @visibleForTesting
  WebSocketChannel openChannel() => WebSocketChannel.connect(Uri.parse(_wsUrl));

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
        logDebug('PubSub pong missed - reconnecting');
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
      logDebug('PubSub frame parse error: $e');
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
          logDebug('PubSub LISTEN rejected: $error');
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
      final channel = _channelByTopic[topic];
      if (channel == null) return;
      final inner = jsonDecode(rawMessage) as Map<String, dynamic>;
      final type = inner['type'] as String?;
      final kind = topic.substring(0, topic.lastIndexOf('.'));
      switch (kind) {
        case 'hype-train-events-v1':
          _handleHypeTrain(channel, type, inner['data']);
          return;
        case 'predictions-channel-v1':
          _handlePrediction(channel, type, inner['data']);
          return;
        case 'polls':
          _handlePoll(channel, type, inner['data']);
          return;
        case 'pinned-chat-updates-v1':
          _handlePinned(channel, type, inner['data']);
          return;
      }
      if (!_redemptionTypes.contains(type)) return;
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
      logDebug('PubSub message parse error: $e');
    }
  }

  void _handleHypeTrain(String channel, String? type, Object? data) {
    if (data is! Map<String, dynamic>) return;
    if (type == 'hype-train-end') {
      _hypeExpiry.remove(channel);
      _hypeTrainController.add(
        HypeTrainEvent(
          channel: channel,
          kind: HypeTrainKind.end,
          rawKind: type!,
          level: 0,
          progress: 0,
          goal: 0,
          total: 0,
        ),
      );
      return;
    }
    final kind = switch (type) {
      'hype-train-start' => HypeTrainKind.begin,
      'hype-train-progression' ||
      'hype-train-level-up' => HypeTrainKind.progress,
      _ => null,
    };
    final progress = data['progress'];
    if (kind == null || progress is! Map<String, dynamic>) return;
    final expires = DateTime.tryParse(data['expires_at'] as String? ?? '');
    if (expires != null) _hypeExpiry[channel] = expires;
    int intOf(Object? v) => v is num ? v.toInt() : 0;
    final level = progress['level'];
    _hypeTrainController.add(
      HypeTrainEvent(
        channel: channel,
        kind: kind,
        rawKind: type!,
        level: level is Map ? intOf(level['value']) : 1,
        progress: intOf(progress['value']),
        goal: intOf(progress['goal']),
        total: intOf(progress['total']),
        expiresAt: _hypeExpiry[channel],
      ),
    );
  }

  void _handlePrediction(String channel, String? type, Object? data) {
    final event = data is Map<String, dynamic> ? data['event'] : null;
    if (event is! Map<String, dynamic>) return;
    final status = event['status'] as String? ?? '';
    final kind = type == 'event-created'
        ? PredictionKind.begin
        : switch (status) {
            'ACTIVE' => PredictionKind.progress,
            'LOCKED' || 'RESOLVE_PENDING' => PredictionKind.lock,
            _ => PredictionKind.end,
          };
    _predictionController.add(
      PredictionEvent(
        channel: channel,
        kind: kind,
        rawKind: type ?? '',
        title: event['title'] as String? ?? '',
        status: status,
        outcomes: [
          for (final o in event['outcomes'] as List? ?? const [])
            if (o is Map<String, dynamic>)
              PredictionOutcome(
                title: o['title'] as String? ?? '',
                users: (o['total_users'] as num?)?.toInt() ?? 0,
                channelPoints: (o['total_points'] as num?)?.toInt() ?? 0,
              ),
        ],
      ),
    );
  }

  // Not seen live yet; shape from the PubSub poll payloads Twitch's web
  // client used.
  void _handlePoll(String channel, String? type, Object? data) {
    final poll = data is Map<String, dynamic> ? data['poll'] : null;
    if (poll is! Map<String, dynamic>) return;
    final kind = switch (type) {
      'POLL_CREATE' => PollKind.begin,
      'POLL_UPDATE' => PollKind.progress,
      _ => PollKind.end,
    };
    int votesOf(Object? v) => switch (v) {
      num n => n.toInt(),
      {'total': num n} => n.toInt(),
      _ => 0,
    };
    _pollController.add(
      PollEvent(
        channel: channel,
        kind: kind,
        rawKind: type ?? '',
        title: poll['title'] as String? ?? '',
        status: poll['status'] as String? ?? '',
        choices: [
          for (final c in poll['choices'] as List? ?? const [])
            if (c is Map<String, dynamic>)
              PollChoice(
                title: c['title'] as String? ?? '',
                votes: votesOf(c['votes']),
              ),
        ],
      ),
    );
  }

  void _handlePinned(String channel, String? type, Object? data) {
    if (data is! Map<String, dynamic>) return;
    final id = data['id'] as String? ?? '';
    if (type == 'unpin-message') {
      _pinnedController.add(
        PinnedMessageEvent(channel: channel, id: id, removed: true),
      );
      return;
    }
    if (type != 'pin-message') return;
    final message = data['message'];
    if (message is! Map<String, dynamic>) return;
    String nameOf(Object? user) => user is Map
        ? (user['display_name'] as String? ?? user['login'] as String? ?? '')
        : '';
    final content = message['content'];
    final endsAt = (message['ends_at'] as num?)?.toInt() ?? 0;
    _pinnedController.add(
      PinnedMessageEvent(
        channel: channel,
        id: id,
        senderName: nameOf(message['sender']),
        text: content is Map ? content['text'] as String? ?? '' : '',
        pinnedBy: nameOf(data['pinned_by']),
        endsAt: endsAt > 0
            ? DateTime.fromMillisecondsSinceEpoch(endsAt * 1000)
            : null,
      ),
    );
  }

  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    if (!_isOnline) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      logDebug('PubSub max reconnect attempts reached - giving up');
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
        completer.completeError(TimeoutException('PubSub timed out'));
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
    final topics = _topicsFor(channelId);
    _topicsByChannel[channelName] = topics;
    for (final t in topics) {
      _channelByTopic[t] = channelName;
    }
  }

  void dispose() {
    _disposed = true;
    disconnect();
    final listener = _connectivityListener;
    if (listener != null) connectivityService?.removeListener(listener);
    _connectivityListener = null;
    _redemptionController.close();
    _hypeTrainController.close();
    _pollController.close();
    _predictionController.close();
    _pinnedController.close();
  }
}
